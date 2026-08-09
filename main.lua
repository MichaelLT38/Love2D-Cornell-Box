-- =====================================================================
--  Cornell Box - SSAO / SSGI / SSR in LOVE2D (11.5)
--
--  A deferred, screen-space renderer built entirely out of love.graphics
--  canvases and GLSL3 pixel shaders, plus a ground-truth path tracer over
--  the same signed-distance scene so the approximations can be checked
--  against the real answer.
--
--  Per frame:
--    1  G-buffer     raymarch the SDF -> position / normal / albedo (MRT)
--    2  SSAO         hemisphere kernel + depth-aware separable blur
--    3  Lighting     area-light NEE  +  screen-space GI gather
--    4  SSR          screen-space ray march + binary refinement
--    5  Accumulate   running mean of all three while the camera is still
--    6  Composite    ACES tonemap, debug views, A/B wipe
-- =====================================================================

local W, H              -- window size
local RW, RH            -- render size (window * renderScale)
local renderScale = 1.0

local shaders = {}
local cv      = {}      -- canvases
local quad              -- 1x1 white image used for full-screen passes
local font

-- ------------------------------------------------------------- settings --
local S = {
	ao        = true,
	gi        = true,
	ssr       = true,
	aoRadius  = 0.28,
	aoPower   = 1.8,
	aoSamples = 16,
	giRays    = 4,
	giSteps   = 20,
	giRadius  = 2.6,
	giStrength= 1.0,
	ssrSteps  = 40,
	ssrDist   = 3.0,
	ssrThick  = 0.20,
	exposure  = 1.15,
	bounces   = 5,
	mode      = 0,
	split     = false,
	autoOrbit = false,
	showHelp  = true,
	pathTrace = false,
	denoise   = false,   -- path traced view: SVGF-lite instead of accumulation
	dnView    = 0,       -- denoiser debug view, see dnresolve.glsl
	animate   = false,   -- spin the tall block via TLAS refit (hw path only)
	-- Deferred pipeline, per-effect: real rays instead of screen space.
	rtShadows = false,
	rtAO      = false,
	rtRefl    = false,
}
local animTime = 0

local DN_VIEW_NAMES = {
	[0] = "denoised", [1] = "raw 1 spp", [2] = "variance",
	[3] = "history length", [4] = "albedo", [5] = "normals",
}

local MODE_NAMES = {
	[0] = "Full (direct + SSGI + SSR)",
	[1] = "Direct lighting only",
	[2] = "Indirect (SSGI) only",
	[3] = "Ambient occlusion",
	[4] = "Screen-space reflections",
	[5] = "Albedo",
	[6] = "World normals",
	[7] = "Linear depth",
	[8] = "Roughness",
}

-- --------------------------------------------------------------- camera --
-- pitch is deliberately not 0.06: that puts the eye exactly level with the
-- tall block's top face, and the razor-thin sliver aliases badly.
local cam = { yaw = 0.0, pitch = 0.11, dist = 3.35, fov = 42, tx = 0, ty = 0, tz = 0 }
local function cameraKey()
	return ("%0.6f|%0.6f|%0.6f|%0.4f"):format(cam.yaw, cam.pitch, cam.dist, cam.fov)
end
local camKey = ""

local frame     = 0     -- monotonic, only feeds the RNG
local accFrames = 0     -- samples merged into the accumulation buffers
local ptSamples = 0

-- Last frame's camera, for the denoiser's temporal reprojection. nil until
-- the first denoised frame has run.
local prevCam = nil

-- Hardware ray tracing. `rtScene` holds the acceleration structures and the
-- buffers the shader reads; nil means this build or this GPU cannot do it, and
-- `rtStatus` says which. Everything about it is optional -- the SDF path tracer
-- is the reference and stays the default.
local rtScene, rtStatus = nil, "not attempted"
local useHW = false

-- screenshot automation (love . --shot [frames])
local shotAt, shotDone = nil, false

-- bench automation (love . --bench [frames]). Measures the CURRENT mode and
-- quits, so the two path tracers are compared by running the app twice rather
-- than by switching mid-run -- no shader-swap or cache effects in the numbers.
local benchFrames, benchStart, benchWarm = nil, nil, 0
local benchTag = ""

-- ======================================================================
--  helpers
-- ======================================================================

local function normalize(x, y, z)
	local l = math.sqrt(x * x + y * y + z * z)
	if l < 1e-9 then return 0, 0, 0 end
	return x / l, y / l, z / l
end

local function cross(ax, ay, az, bx, by, bz)
	return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function camVectors()
	local cp = math.cos(cam.pitch)
	local px = cam.tx + cam.dist * cp * math.sin(cam.yaw)
	local py = cam.ty + cam.dist * math.sin(cam.pitch)
	local pz = cam.tz + cam.dist * cp * math.cos(cam.yaw)

	local fx, fy, fz = normalize(cam.tx - px, cam.ty - py, cam.tz - pz)
	local rx, ry, rz = normalize(cross(fx, fy, fz, 0, 1, 0))
	local ux, uy, uz = cross(rx, ry, rz, fx, fy, fz)

	return { px, py, pz }, { rx, ry, rz }, { ux, uy, uz }, { fx, fy, fz }
end

-- love errors when you send to a uniform the compiler stripped, and
-- common.glsl deliberately declares more than any single pass uses.
local function send(sh, name, ...)
	if sh:hasUniform(name) then sh:send(name, ...) end
end

local function sendCamera(sh, resW, resH)
	local p, r, u, f = camVectors()
	send(sh, "uRes",      { resW, resH })
	send(sh, "uCamPos",   p)
	send(sh, "uCamRight", r)
	send(sh, "uCamUp",    u)
	send(sh, "uCamFwd",   f)
	send(sh, "uTanHalf",  math.tan(math.rad(cam.fov) * 0.5))
	send(sh, "uAspect",   resW / resH)
	send(sh, "uFrame",    frame % 65536)
end

local function fullscreen(w, h)
	love.graphics.draw(quad, 0, 0, 0, w, h)
end

local function resetAccum()
	accFrames = 0
	ptSamples = 0
	if cv.pt then
		love.graphics.setCanvas(cv.pt)
		love.graphics.clear(0, 0, 0, 0)
		love.graphics.setCanvas()
	end
	for i = 1, 2 do
		if cv.acc then
			love.graphics.setCanvas(cv.acc[i][1], cv.acc[i][2], cv.acc[i][3])
			love.graphics.clear(0, 0, 0, 1)
			love.graphics.setCanvas()
		end
	end
	-- Zeroed history data means histLen 0, which the reprojection pass treats
	-- as "no history"; zeroed nrmZ fails its depth test. No reset flag needed.
	if cv.dn then
		for i = 1, 2 do
			love.graphics.setCanvas(cv.dn.histData[i])
			love.graphics.clear(0, 0, 0, 0)
			love.graphics.setCanvas(cv.dn.nrmZ[i])
			love.graphics.clear(0, 0, 0, 0)
			love.graphics.setCanvas()
		end
		prevCam = nil
	end
end

local function settingsKey()
	return table.concat({
		tostring(S.ao), tostring(S.gi), tostring(S.ssr),
		tostring(S.rtShadows), tostring(S.rtAO), tostring(S.rtRefl),
		S.aoRadius, S.aoPower, S.aoSamples,
		S.giRays, S.giSteps, S.giRadius, S.giStrength,
		S.ssrSteps, S.ssrDist, S.ssrThick, S.bounces,
	}, "|")
end
local setKey = ""

-- ======================================================================
--  resources
-- ======================================================================

-- The path tracer files define pathtracePixel() and no entry point; one of
-- these two drivers is appended. Seed and jitter live here so the rnd()
-- sequence is identical in both -- the reference images depend on that.
local DRIVER_ACCUM = [[
vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	uint seed = seedPixel(love_PixelCoord.xy, uFrame);
	vec2 uv = (love_PixelCoord.xy + rnd2(seed)) / uRes;
	vec3 n; float z; vec3 alb; float id; float reflT;
	vec3 rad = pathtracePixel(uv, seed, n, z, alb, id, reflT);
	return vec4(rad, 1.0);
}
]]

-- The denoiser wants the same sample DEMODULATED (albedo divided out, so the
-- filter works on irradiance and texture detail is never at risk) plus the
-- first-hit guides. pathtracePixel sets alb = 1 for the emitter and misses,
-- so the division is a no-op exactly where demodulation makes no sense.
local DRIVER_DENOISE = [[
void effect() {
	uint seed = seedPixel(love_PixelCoord.xy, uFrame);
	vec2 uv = (love_PixelCoord.xy + rnd2(seed)) / uRes;
	vec3 n; float z; vec3 alb; float id; float reflT;
	vec3 rad = pathtracePixel(uv, seed, n, z, alb, id, reflT);
	// Alpha carries the mirror-bounce hit distance; the reprojection pass
	// uses it to track reflections by their virtual depth.
	love_Canvases[0] = vec4(rad / max(alb, vec3(1e-3)), reflT);
	love_Canvases[1] = vec4(n, z);
	love_Canvases[2] = vec4(alb, id);
}
]]

local function loadShaders()
	local common = love.filesystem.read("shaders/common.glsl")
	local function build(name, driver)
		local body = love.filesystem.read("shaders/" .. name .. ".glsl")
		assert(body, "missing shaders/" .. name .. ".glsl")
		local src = "#pragma language glsl3\n" .. common .. "\n" .. body .. (driver or "")
		local ok, res = pcall(love.graphics.newShader, src)
		if not ok then
			error(("shader '%s' failed to compile:\n%s"):format(name, tostring(res)))
		end
		return res
	end

	shaders.gbuffer   = build("gbuffer")
	shaders.ssao      = build("ssao")
	shaders.blur      = build("blur")
	shaders.light     = build("light")
	shaders.ssr       = build("ssr")
	shaders.accum     = build("accum")
	shaders.composite = build("composite")
	shaders.pathtrace = build("pathtrace", DRIVER_ACCUM)
	shaders.ptresolve = build("ptresolve")

	shaders.pathtrace_dn = build("pathtrace", DRIVER_DENOISE)
	shaders.reproject    = build("reproject")
	shaders.variance     = build("variance")
	shaders.atrous       = build("atrous")
	shaders.dnresolve    = build("dnresolve")

	-- Hardware ray query variant. GLSL 4 rather than 3 because rayQueryEXT
	-- needs #version 460, and `#pragma rayquery` is what makes love emit the
	-- version and the extension line. Optional in every sense: a build or a GPU
	-- without ray queries just does not get this shader, and the SDF path
	-- tracer above remains the reference.
	if rtScene and love.graphics.getSupported().rayquery then
		local rq = love.filesystem.read("shaders/rq_common.glsl")
		local function buildHW(name, driver)
			local body = love.filesystem.read("shaders/" .. name .. ".glsl")
			if not body or not rq then return nil end
			local src = "#pragma language glsl4\n" .. common .. "\n" .. rq .. "\n" .. body .. (driver or "")
			local ok, res = pcall(love.graphics.newShader, src)
			if not ok then
				rtStatus = ("hw shader '%s' failed: %s"):format(name, tostring(res))
				return nil
			end
			return res
		end
		shaders.pathtrace_hw    = buildHW("pathtrace_hw", DRIVER_ACCUM)
		shaders.pathtrace_hw_dn = buildHW("pathtrace_hw", DRIVER_DENOISE)

		-- Ray-traced variants of the deferred passes: same pipeline, the
		-- screen-space visibility swapped for real rays. Each is optional and
		-- toggleable, so every screen-space failure mode can be A/B'd live.
		shaders.light_hw = buildHW("light_hw")
		shaders.rtao     = buildHW("rtao")
		shaders.ssr_hw   = buildHW("ssr_hw")
	end
end

local function newCanvas(w, h, fmt, filter)
	local c = love.graphics.newCanvas(w, h, { format = fmt })
	c:setFilter(filter or "linear", filter or "linear")
	c:setWrap("clamp", "clamp")
	return c
end

local function buildCanvases()
	RW = math.max(64, math.floor(W * renderScale))
	RH = math.max(64, math.floor(H * renderScale))

	-- MRT groups share a format: LOVE wants matching targets in one batch.
	cv.gPos = newCanvas(RW, RH, "rgba32f", "nearest")
	cv.gNrm = newCanvas(RW, RH, "rgba32f", "nearest")
	cv.gAlb = newCanvas(RW, RH, "rgba32f", "nearest")

	cv.aoA  = newCanvas(RW, RH, "rgba8")
	cv.aoB  = newCanvas(RW, RH, "rgba8")

	cv.litD = newCanvas(RW, RH, "rgba16f")
	cv.litG = newCanvas(RW, RH, "rgba16f")
	cv.ssr  = newCanvas(RW, RH, "rgba16f")

	cv.acc = {
		{ newCanvas(RW, RH, "rgba32f"), newCanvas(RW, RH, "rgba32f"), newCanvas(RW, RH, "rgba32f") },
		{ newCanvas(RW, RH, "rgba32f"), newCanvas(RW, RH, "rgba32f"), newCanvas(RW, RH, "rgba32f") },
	}
	cv.accIndex = 1

	cv.pt = newCanvas(RW, RH, "rgba32f")

	-- Denoiser targets, all rgba32f (MRT batches must share a format). Data
	-- canvases sample nearest; the two history pairs sample linear because
	-- the reprojected lookup lands between pixels.
	cv.dn = {
		color = newCanvas(RW, RH, "rgba32f", "nearest"),   -- raw 1 spp, demodulated
		alb   = newCanvas(RW, RH, "rgba32f", "nearest"),   -- albedo + material id
		nrmZ  = { newCanvas(RW, RH, "rgba32f", "nearest"),
		          newCanvas(RW, RH, "rgba32f", "nearest") },
		acc   = newCanvas(RW, RH, "rgba32f", "nearest"),   -- reprojected color
		var   = newCanvas(RW, RH, "rgba32f", "nearest"),   -- color + variance
		histColor = { newCanvas(RW, RH, "rgba32f", "linear"),
		              newCanvas(RW, RH, "rgba32f", "linear") },
		histData  = { newCanvas(RW, RH, "rgba32f", "linear"),
		              newCanvas(RW, RH, "rgba32f", "linear") },
		at    = { newCanvas(RW, RH, "rgba32f", "nearest"),
		          newCanvas(RW, RH, "rgba32f", "nearest") },
		idx = 1,
	}

	resetAccum()
end

-- ======================================================================
--  passes
-- ======================================================================

local function passGBuffer()
	local sh = shaders.gbuffer
	love.graphics.setCanvas(cv.gPos, cv.gNrm, cv.gAlb)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "uJitter", 1.0)
	fullscreen(RW, RH)
	love.graphics.setShader()
	love.graphics.setCanvas()
end

-- Send everything a ray-traced deferred variant needs on top of the G-buffer.
local function sendTLAS(sh)
	send(sh, "uTLAS", rtScene.tlas)
	send(sh, "Verts", rtScene.pos)
	send(sh, "Norms", rtScene.nrm)
	send(sh, "Mats",  rtScene.mat)
	send(sh, "BlockNorms", rtScene.blockNrm)
end

local function passSSAO()
	local rt = S.rtAO and shaders.rtao and rtScene
	local sh = rt and shaders.rtao or shaders.ssao
	love.graphics.setCanvas(cv.aoA)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "gPos", cv.gPos)
	send(sh, "gNrm", cv.gNrm)
	send(sh, "uAORadius",  S.aoRadius)
	send(sh, "uAOPower",   S.aoPower)
	send(sh, "uAOSamples", S.aoSamples)
	if rt then sendTLAS(sh) end
	fullscreen(RW, RH)

	-- two-tap depth-aware blur, horizontal then vertical
	local b = shaders.blur
	love.graphics.setShader(b)
	sendCamera(b, RW, RH)
	send(b, "gPos", cv.gPos)
	send(b, "uRadius", 4)

	love.graphics.setCanvas(cv.aoB)
	send(b, "src", cv.aoA); send(b, "uDir", { 1, 0 })
	fullscreen(RW, RH)

	love.graphics.setCanvas(cv.aoA)
	send(b, "src", cv.aoB); send(b, "uDir", { 0, 1 })
	fullscreen(RW, RH)

	love.graphics.setShader()
	love.graphics.setCanvas()
end

local function passLight(prev)
	local rt = S.rtShadows and shaders.light_hw and rtScene
	local sh = rt and shaders.light_hw or shaders.light
	love.graphics.setCanvas(cv.litD, cv.litG)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	if rt then sendTLAS(sh) end
	send(sh, "gPos", cv.gPos)
	send(sh, "gNrm", cv.gNrm)
	send(sh, "gAlb", cv.gAlb)
	send(sh, "texAO", cv.aoA)
	send(sh, "texPrevDirect", prev[1])
	send(sh, "texPrevGI",     prev[2])
	send(sh, "uGIRays",     S.giRays)
	send(sh, "uGISteps",    S.giSteps)
	send(sh, "uGIRadius",   S.giRadius)
	send(sh, "uGIStrength", S.giStrength)
	send(sh, "uAOEnable",   S.ao and 1 or 0)
	send(sh, "uGIEnable",   S.gi and 1 or 0)
	fullscreen(RW, RH)
	love.graphics.setShader()
	love.graphics.setCanvas()
end

local function passSSR(prev)
	local rt = S.rtRefl and shaders.ssr_hw and rtScene
	local sh = rt and shaders.ssr_hw or shaders.ssr
	love.graphics.setCanvas(cv.ssr)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	if rt then sendTLAS(sh) end
	send(sh, "gPos", cv.gPos)
	send(sh, "gNrm", cv.gNrm)
	send(sh, "gAlb", cv.gAlb)
	send(sh, "texPrevDirect", prev[1])
	send(sh, "texPrevGI",     prev[2])
	send(sh, "uSSRSteps",     S.ssrSteps)
	send(sh, "uSSRDist",      S.ssrDist)
	send(sh, "uSSRThickness", S.ssrThick)
	send(sh, "uSSREnable",    S.ssr and 1 or 0)
	fullscreen(RW, RH)
	love.graphics.setShader()
	love.graphics.setCanvas()
end

local function passAccum(prev, cur)
	accFrames = accFrames + 1
	local blend = 1.0 / math.min(accFrames, 1024)

	local sh = shaders.accum
	love.graphics.setCanvas(cur[1], cur[2], cur[3])
	love.graphics.setShader(sh)
	send(sh, "uRes", { RW, RH })
	send(sh, "curDirect", cv.litD)
	send(sh, "curGI",     cv.litG)
	send(sh, "curSSR",    cv.ssr)
	send(sh, "prvDirect", prev[1])
	send(sh, "prvGI",     prev[2])
	send(sh, "prvSSR",    prev[3])
	send(sh, "uBlend", blend)
	fullscreen(RW, RH)
	love.graphics.setShader()
	love.graphics.setCanvas()
end

local function passComposite(cur)
	local sh = shaders.composite
	love.graphics.setShader(sh)
	sendCamera(sh, W, H)
	send(sh, "gPos", cv.gPos)
	send(sh, "gNrm", cv.gNrm)
	send(sh, "gAlb", cv.gAlb)
	send(sh, "texAO", cv.aoA)
	send(sh, "accDirect", cur[1])
	send(sh, "accGI",     cur[2])
	send(sh, "accSSR",    cur[3])
	send(sh, "uExposure",  S.exposure)
	send(sh, "uMode",      S.mode)
	send(sh, "uAOEnable",  S.ao  and 1 or 0)
	send(sh, "uSSREnable", S.ssr and 1 or 0)
	if S.split then
		send(sh, "uSplit", math.min(0.98, math.max(0.02, love.mouse.getX() / W)))
	else
		send(sh, "uSplit", -1)
	end
	fullscreen(W, H)
	love.graphics.setShader()
end

local function passPathTrace()
	local hw = useHW and shaders.pathtrace_hw and rtScene
	local sh = hw and shaders.pathtrace_hw or shaders.pathtrace
	love.graphics.setCanvas(cv.pt)
	love.graphics.setBlendMode("add", "premultiplied")
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "uBounces", S.bounces)
	if hw then
		send(sh, "uTLAS", rtScene.tlas)
		send(sh, "Verts", rtScene.pos)
		send(sh, "Norms", rtScene.nrm)
		send(sh, "Mats",  rtScene.mat)
		send(sh, "BlockNorms", rtScene.blockNrm)
	end
	fullscreen(RW, RH)
	love.graphics.setShader()
	love.graphics.setBlendMode("alpha")
	love.graphics.setCanvas()
	ptSamples = ptSamples + 1

	local r = shaders.ptresolve
	love.graphics.setShader(r)
	send(r, "uRes", { W, H })
	send(r, "ptTex", cv.pt)
	send(r, "uExposure", S.exposure)
	send(r, "uSamples", ptSamples)
	fullscreen(W, H)
	love.graphics.setShader()
end

-- The denoised path traced frame: 1 spp with guides, temporal reprojection,
-- variance estimate, five a-trous iterations, resolve. The first a-trous
-- iteration renders into the history color buffer -- SVGF feeds the first
-- FILTERED image back as next frame's history, which is what keeps the
-- feedback loop stable at 1 spp.
local function passDenoise()
	local hw = useHW and shaders.pathtrace_hw_dn and rtScene
	local d  = cv.dn
	local cur, prv = d.idx, 3 - d.idx

	-- 1 spp + guide MRT
	local sh = hw and shaders.pathtrace_hw_dn or shaders.pathtrace_dn
	love.graphics.setCanvas(d.color, d.nrmZ[cur], d.alb)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "uBounces", S.bounces)
	if hw then
		send(sh, "uTLAS", rtScene.tlas)
		send(sh, "Verts", rtScene.pos)
		send(sh, "Norms", rtScene.nrm)
		send(sh, "Mats",  rtScene.mat)
		send(sh, "BlockNorms", rtScene.blockNrm)
	end
	fullscreen(RW, RH)

	-- temporal reprojection through last frame's camera
	sh = shaders.reproject
	love.graphics.setCanvas(d.acc, d.histData[cur])
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	local pc = prevCam or { camVectors() }
	send(sh, "texCur",       d.color)
	send(sh, "texNrmZ",      d.nrmZ[cur])
	send(sh, "texPrevNrmZ",  d.nrmZ[prv])
	send(sh, "texHistColor", d.histColor[prv])
	send(sh, "texHistData",  d.histData[prv])
	send(sh, "texAlb",       d.alb)
	send(sh, "uPrevCamPos",   pc[1])
	send(sh, "uPrevCamRight", pc[2])
	send(sh, "uPrevCamUp",    pc[3])
	send(sh, "uPrevCamFwd",   pc[4])
	send(sh, "uPrevTanHalf",  pc[5] or math.tan(math.rad(cam.fov) * 0.5))
	send(sh, "uPrevAspect",   pc[6] or RW / RH)
	send(sh, "uMaxHist",      64)
	-- 32 rather than the original 8: the reprojection now tracks mirror
	-- content by its virtual depth, so mirror history is mostly trustworthy.
	send(sh, "uMetalMaxHist", 32)
	fullscreen(RW, RH)

	-- variance estimate rides into alpha
	sh = shaders.variance
	love.graphics.setCanvas(d.var)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "texColor",    d.acc)
	send(sh, "texHistData", d.histData[cur])
	send(sh, "texNrmZ",     d.nrmZ[cur])
	fullscreen(RW, RH)

	-- five a-trous iterations; the first one is also next frame's history
	local src = d.var
	local stepsList = { 1, 2, 4, 8, 16 }
	sh = shaders.atrous
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "texNrmZ",  d.nrmZ[cur])
	send(sh, "uSigmaL",  4.0)
	for i, st in ipairs(stepsList) do
		local dst = (i == 1) and d.histColor[cur] or d.at[i % 2 + 1]
		love.graphics.setCanvas(dst)
		send(sh, "texColor", src)
		send(sh, "uStep", st)
		fullscreen(RW, RH)
		src = dst
	end

	-- remodulate + tonemap to the screen
	love.graphics.setCanvas()
	love.graphics.setBlendMode("alpha")
	sh = shaders.dnresolve
	love.graphics.setShader(sh)
	send(sh, "uRes", { W, H })
	send(sh, "texColor",    src)
	send(sh, "texAlb",      d.alb)
	send(sh, "texRaw",      d.color)
	send(sh, "texHistData", d.histData[cur])
	send(sh, "texNrmZ",     d.nrmZ[cur])
	send(sh, "uExposure",   S.exposure)
	send(sh, "uDnView",     S.dnView)
	fullscreen(W, H)
	love.graphics.setShader()

	local p, r, u, f = camVectors()
	prevCam = { p, r, u, f, math.tan(math.rad(cam.fov) * 0.5), RW / RH }
	d.idx = prv
end

-- ======================================================================
--  HUD
-- ======================================================================

local function panel(x, y, w, h)
	love.graphics.setColor(0, 0, 0, 0.62)
	love.graphics.rectangle("fill", x, y, w, h, 4, 4)
	love.graphics.setColor(1, 1, 1, 0.10)
	love.graphics.rectangle("line", x, y, w, h, 4, 4)
	love.graphics.setColor(1, 1, 1, 1)
end

local function drawHUD()
	if S.hideHUD then return end
	love.graphics.setFont(font)

	local lines
	if S.pathTrace and S.denoise then
		lines = {
			("DENOISED PATH TRACING  (1 spp + SVGF-lite%s)")
				:format((useHW and shaders.pathtrace_hw_dn and rtScene) and ", hw rays" or ""),
			("view: %s   bounces: %d"):format(DN_VIEW_NAMES[S.dnView] or "?", S.bounces),
			"",
			"One new sample per frame. Reprojection keeps the",
			"history alive while the camera moves; an edge-aware",
			"wavelet filter eats the noise that remains.",
			"",
			"N    accumulation mode     V   cycle debug views",
			"TAB  real-time renderer    , . bounces",
			(useHW and rtScene and rtScene.canAnimate)
				and ("B    block motion: " .. (S.animate and "ON" or "off")) or "",
		}
	elseif S.pathTrace then
		lines = {
			"PATH-TRACED REFERENCE  (ground truth)",
			("samples: %d   bounces: %d"):format(ptSamples, S.bounces),
			"",
			"Everything here is traced against the SDF, so it has",
			"the occlusion, bounce light and reflections that the",
			"screen-space passes can only approximate.",
			"",
			"TAB  back to the real-time renderer",
			"N    denoised mode (1 spp, camera-motion stable)",
			"[ ]  resolution scale        , .  bounces",
		}
	else
		lines = {
			("view: %s"):format(MODE_NAMES[S.mode] or "?"),
			("accumulated: %d spp"):format(accFrames),
			"",
			("AO  [A] %s   radius %.2f  (%d taps)%s"):format(S.ao and "ON " or "off", S.aoRadius, S.aoSamples,
				S.rtAO and "   [F3] RAY TRACED" or ""),
			("GI  [G] %s   %d rays x %d steps, r=%.2f%s"):format(S.gi and "ON " or "off", S.giRays, S.giSteps, S.giRadius,
				S.rtShadows and "   [F2] RT SHADOWS" or ""),
			("SSR [R] %s   %d steps, %.1f units%s"):format(S.ssr and "ON " or "off", S.ssrSteps, S.ssrDist,
				S.rtRefl and "   [F4] RAY TRACED" or ""),
			shaders.light_hw and "T    toggle all ray-traced passes" or "",
			"",
			"0-8  view modes      TAB  path-traced reference",
			"C    A/B wipe (mouse x)   O  auto orbit",
			"[ ]  resolution scale     - =  exposure",
			"drag / wheel  orbit + zoom      F1 help",
		}
	end

	local wpx = 0
	for _, l in ipairs(lines) do wpx = math.max(wpx, font:getWidth(l)) end
	local ph = #lines * font:getHeight() + 16

	panel(10, 10, wpx + 20, ph)
	for i, l in ipairs(lines) do
		if i == 1 then love.graphics.setColor(1, 0.86, 0.45, 1)
		else love.graphics.setColor(0.86, 0.88, 0.92, 1) end
		love.graphics.print(l, 20, 18 + (i - 1) * font:getHeight())
	end

	-- perf readout, bottom right
	love.graphics.setColor(0.7, 0.75, 0.8, 1)
	local st = love.graphics.getStats()
	-- getAverageDelta is the mean frame time over the last second: steadier
	-- than fps for judging a budget, and it is whole-frame wall clock, the
	-- same thing --bench measures.
	local perf = ("%.2f ms   %d fps   %dx%d (%.0f%%)   vram %.0f MB")
		:format(love.timer.getAverageDelta() * 1000, love.timer.getFPS(), RW, RH, renderScale * 100, st.texturememory / 1048576)
	love.graphics.print(perf, W - font:getWidth(perf) - 14, H - font:getHeight() - 10)

	if S.split and not S.pathTrace then
		love.graphics.setColor(1, 0.86, 0.45, 1)
		love.graphics.print("full", 14, H - 30)
		local t = "direct only"
		love.graphics.print(t, W - font:getWidth(t) - 14, H - 30)
	end

	if S.showHelp then
		local help = {
			"KEYS",
			"1 / 2 / 3 / 4    direct | SSGI | AO | SSR isolated",
			"0                full composite",
			"5 6 7 8          albedo | normals | depth | roughness",
			"A / G / R        toggle AO / GI / SSR",
			"F2 / F3 / F4     ray traced shadows / AO / reflections",
			"T                all three ray traced passes at once",
			"TAB              path-traced reference",
			"N                denoised path tracing (in TAB view)",
			"V                denoiser debug views",
			"C                A/B wipe, follows the mouse",
			"O                slow auto orbit",
			"[ / ]            render scale down / up",
			"- / =            exposure",
			", / .            path tracer bounces",
			"F5               save a screenshot",
			"F1               hide this panel",
			"ESC              quit",
		}
		local hw = 0
		for _, l in ipairs(help) do hw = math.max(hw, font:getWidth(l)) end
		local hh = #help * font:getHeight() + 16
		panel(W - hw - 30, 10, hw + 20, hh)
		for i, l in ipairs(help) do
			if i == 1 then love.graphics.setColor(1, 0.86, 0.45, 1)
			else love.graphics.setColor(0.82, 0.85, 0.9, 1) end
			love.graphics.print(l, W - hw - 20, 18 + (i - 1) * font:getHeight())
		end
	end

	love.graphics.setColor(1, 1, 1, 1)
end

-- ======================================================================
--  love callbacks
-- ======================================================================

-- Mirror any crash into the save directory as well as the screen; LOVE is a
-- GUI subsystem app on Windows so stdout is not available.
local defaultErrorHandler = love.errorhandler
function love.errorhandler(msg)
	local trace = debug.traceback(tostring(msg), 2)
	pcall(love.filesystem.write, "error.txt", trace)
	return defaultErrorHandler(msg)
end

function love.load(args)
	for i, a in ipairs(args or {}) do
		if a == "--shot"  then shotAt = tonumber(args[i + 1]) or 240 end
		if a == "--scale" then renderScale = tonumber(args[i + 1]) or 1.0 end
		if a == "--mode"  then S.mode = tonumber(args[i + 1]) or 0 end
		if a == "--pt"    then S.pathTrace = true end
		if a == "--nohud" then S.showHelp = false; S.hideHUD = true end
		if a == "--hw"    then S.pathTrace = true; useHW = true end
		if a == "--dn"    then S.pathTrace = true; S.denoise = true end
		if a == "--anim"  then S.animate = true end
		if a == "--rt"    then S.rtShadows = true; S.rtAO = true; S.rtRefl = true end
		if a == "--dnview" then S.dnView = tonumber(args[i + 1]) or 0 end
		if a == "--orbit" then S.autoOrbit = true end
		if a == "--bench" then benchFrames = tonumber(args[i + 1]) or 300 end
		if a == "--bounces" then S.bounces = tonumber(args[i + 1]) or 5 end
		if a == "--tag"   then benchTag = args[i + 1] or "" end
	end

	love.graphics.setDefaultFilter("linear", "linear")
	font = love.graphics.newFont(13)

	local id = love.image.newImageData(1, 1)
	id:setPixel(0, 0, 1, 1, 1, 1)
	quad = love.graphics.newImage(id)

	W, H = love.graphics.getDimensions()

	-- Before loadShaders: the hardware shader is only built when there is
	-- something for it to trace.
	rtScene, rtStatus = require("rt_scene").build()
	if rtScene then
		rtStatus = ("%d triangles, %.1f KB of structures")
			:format(rtScene.tris, rtScene.bytes / 1024)
	else
		useHW = false
	end

	loadShaders()
	if useHW and not shaders.pathtrace_hw then useHW = false end
	buildCanvases()

	-- LOVE is a GUI subsystem app on Windows, so stdout is not available; the
	-- save directory is where anything diagnostic has to go.
	pcall(love.filesystem.write, "rt_status.txt", ("rayquery supported: %s\nstructures: %s\nhw shader: %s\nuseHW: %s\n")
		:format(tostring(love.graphics.getSupported().rayquery), tostring(rtStatus),
			shaders.pathtrace_hw and "compiled" or "absent", tostring(useHW)))

	camKey = cameraKey()
	setKey = settingsKey()
end

function love.resize(w, h)
	W, H = w, h
	buildCanvases()
end

function love.update(dt)
	if S.autoOrbit then cam.yaw = cam.yaw + dt * 0.12 end

	-- Spin the tall block: one TLAS refit per frame, nothing rebuilt. Only
	-- meaningful in the hardware path traced view -- the SDF and the deferred
	-- pipeline march a scene function that does not know the block moved.
	if S.animate and S.pathTrace and useHW and rtScene and rtScene.canAnimate then
		animTime = animTime + dt
		rtScene.setBlockAngle(animTime * 0.5)
	end

	-- Any camera or quality change invalidates the running mean -- except in
	-- denoised path tracing, where surviving camera motion is the entire
	-- point: reprojection carries the history, and quality changes still
	-- reset because they change what the history means.
	local ck, sk = cameraKey(), settingsKey()
	if ck ~= camKey or sk ~= setKey then
		local cameraOnly = (sk == setKey)
		camKey, setKey = ck, sk
		if not (S.pathTrace and S.denoise and cameraOnly) then
			resetAccum()
		end
	end
end

function love.draw()
	frame = frame + 1
	-- "replace" defaults to the alphamultiply alpha mode, which would scale
	-- every RGB write by its own alpha - fatal when alpha carries depth or
	-- roughness rather than coverage.
	love.graphics.setBlendMode("replace", "premultiplied")

	if S.pathTrace and S.denoise then
		passDenoise()   -- canvas passes need the replace blend set above
	elseif S.pathTrace then
		love.graphics.setBlendMode("alpha")
		passPathTrace()
	else
		local prev = cv.acc[cv.accIndex]
		local cur  = cv.acc[3 - cv.accIndex]

		passGBuffer()
		passSSAO()
		passLight(prev)
		passSSR(prev)
		passAccum(prev, cur)

		love.graphics.setBlendMode("alpha")
		passComposite(cur)

		cv.accIndex = 3 - cv.accIndex
	end

	love.graphics.setBlendMode("alpha")
	drawHUD()

	if shotAt and not shotDone and frame >= shotAt then
		shotDone = true
		love.graphics.captureScreenshot("shot.png")
	elseif shotDone then
		love.event.quit()
	end

	if benchFrames then
		-- 30 frames of warmup discarded: shader compilation, canvas allocation
		-- and the acceleration structure build all land in the first few, and
		-- none of them are what is being measured.
		benchWarm = benchWarm + 1
		if benchWarm == 30 then
			benchStart = love.timer.getTime()
		elseif benchStart and benchWarm >= 30 + benchFrames then
			local elapsed = love.timer.getTime() - benchStart
			local benchMode
			if S.pathTrace then
				benchMode = (useHW and "hardware" or "sdf") .. (S.denoise and "+dn" or "")
			else
				benchMode = "deferred"
					.. (S.rtShadows and "+rtS" or "")
					.. (S.rtAO and "+rtA" or "")
					.. (S.rtRefl and "+rtR" or "")
			end
			local report = ("%s\t%s\t%d\t%d\t%dx%d\t%.4f\t%.2f\t%.4f\n"):format(
				benchTag, benchMode,
				S.bounces, benchFrames,
				RW, RH, elapsed, benchFrames / elapsed, elapsed * 1000.0 / benchFrames)
			love.filesystem.append("bench.txt", report)
			love.event.quit()
		end
	end
end

function love.keypressed(k)
	if k == "escape" then love.event.quit() return end

	if k == "tab" then
		S.pathTrace = not S.pathTrace
		resetAccum()
	elseif k == "n" then
		if S.pathTrace then
			S.denoise = not S.denoise
			resetAccum()
		end
	elseif k == "v" then
		if S.pathTrace and S.denoise then
			S.dnView = (S.dnView + 1) % 6
		end
	elseif k == "b" then
		if S.pathTrace and useHW and rtScene and rtScene.canAnimate then
			S.animate = not S.animate
			-- Coming to rest somewhere other than the SDF's block angle would
			-- quietly break every SDF-vs-hardware comparison from then on.
			if not S.animate then rtScene.setBlockAngle(0) end
		end
	elseif k == "h" then
		-- Only meaningful inside the path traced view; the deferred pipeline
		-- has no ray query variant.
		if shaders.pathtrace_hw and rtScene then
			useHW = not useHW
			resetAccum()
		end
	elseif k == "f2" then
		if shaders.light_hw then S.rtShadows = not S.rtShadows end
	elseif k == "f3" then
		if shaders.rtao then S.rtAO = not S.rtAO end
	elseif k == "f4" then
		if shaders.ssr_hw then S.rtRefl = not S.rtRefl end
	elseif k == "t" then
		-- one key for the whole hybrid: everything ray-traced, or nothing
		if shaders.light_hw then
			local on = not (S.rtShadows and S.rtAO and S.rtRefl)
			S.rtShadows, S.rtAO, S.rtRefl = on, on, on
		end
	elseif k >= "0" and k <= "8" and #k == 1 then
		S.mode = tonumber(k)
	elseif k == "a" then S.ao  = not S.ao
	elseif k == "g" then S.gi  = not S.gi
	elseif k == "r" then S.ssr = not S.ssr
	elseif k == "c" then S.split = not S.split
	elseif k == "o" then S.autoOrbit = not S.autoOrbit
	elseif k == "f1" then S.showHelp = not S.showHelp
	elseif k == "f5" then love.graphics.captureScreenshot(os.time() .. ".png")
	elseif k == "[" then renderScale = math.max(0.25, renderScale - 0.125); buildCanvases()
	elseif k == "]" then renderScale = math.min(2.00, renderScale + 0.125); buildCanvases()
	elseif k == "-" then S.exposure = math.max(0.1, S.exposure - 0.1)
	elseif k == "=" then S.exposure = math.min(6.0, S.exposure + 0.1)
	elseif k == "," then S.bounces = math.max(1, S.bounces - 1)
	elseif k == "." then S.bounces = math.min(8, S.bounces + 1)
	end
end

function love.mousemoved(x, y, dx, dy)
	if love.mouse.isDown(1) and not S.split then
		cam.yaw   = cam.yaw - dx * 0.005
		cam.pitch = math.max(-1.25, math.min(1.25, cam.pitch + dy * 0.005))
	end
end

function love.wheelmoved(x, y)
	cam.dist = math.max(1.2, math.min(9.0, cam.dist - y * 0.18))
end
