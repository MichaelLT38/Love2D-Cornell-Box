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

-- screenshot automation (love . --shot [frames])
local shotAt, shotDone = nil, false

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
end

local function settingsKey()
	return table.concat({
		tostring(S.ao), tostring(S.gi), tostring(S.ssr),
		S.aoRadius, S.aoPower, S.aoSamples,
		S.giRays, S.giSteps, S.giRadius, S.giStrength,
		S.ssrSteps, S.ssrDist, S.ssrThick, S.bounces,
	}, "|")
end
local setKey = ""

-- ======================================================================
--  resources
-- ======================================================================

local function loadShaders()
	local common = love.filesystem.read("shaders/common.glsl")
	local function build(name)
		local body = love.filesystem.read("shaders/" .. name .. ".glsl")
		assert(body, "missing shaders/" .. name .. ".glsl")
		local src = "#pragma language glsl3\n" .. common .. "\n" .. body
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
	shaders.pathtrace = build("pathtrace")
	shaders.ptresolve = build("ptresolve")
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

local function passSSAO()
	local sh = shaders.ssao
	love.graphics.setCanvas(cv.aoA)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "gPos", cv.gPos)
	send(sh, "gNrm", cv.gNrm)
	send(sh, "uAORadius",  S.aoRadius)
	send(sh, "uAOPower",   S.aoPower)
	send(sh, "uAOSamples", S.aoSamples)
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
	local sh = shaders.light
	love.graphics.setCanvas(cv.litD, cv.litG)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
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
	local sh = shaders.ssr
	love.graphics.setCanvas(cv.ssr)
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
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
	local sh = shaders.pathtrace
	love.graphics.setCanvas(cv.pt)
	love.graphics.setBlendMode("add", "premultiplied")
	love.graphics.setShader(sh)
	sendCamera(sh, RW, RH)
	send(sh, "uBounces", S.bounces)
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
	if S.pathTrace then
		lines = {
			"PATH-TRACED REFERENCE  (ground truth)",
			("samples: %d   bounces: %d"):format(ptSamples, S.bounces),
			"",
			"Everything here is traced against the SDF, so it has",
			"the occlusion, bounce light and reflections that the",
			"screen-space passes can only approximate.",
			"",
			"TAB  back to the real-time renderer",
			"[ ]  resolution scale        , .  bounces",
		}
	else
		lines = {
			("view: %s"):format(MODE_NAMES[S.mode] or "?"),
			("accumulated: %d spp"):format(accFrames),
			"",
			("AO  [A] %s   radius %.2f  (%d taps)"):format(S.ao and "ON " or "off", S.aoRadius, S.aoSamples),
			("GI  [G] %s   %d rays x %d steps, r=%.2f"):format(S.gi and "ON " or "off", S.giRays, S.giSteps, S.giRadius),
			("SSR [R] %s   %d steps, %.1f units"):format(S.ssr and "ON " or "off", S.ssrSteps, S.ssrDist),
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
	local perf = ("%d fps   %dx%d (%.0f%%)   vram %.0f MB")
		:format(love.timer.getFPS(), RW, RH, renderScale * 100, st.texturememory / 1048576)
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
			"TAB              path-traced reference",
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
	end

	love.graphics.setDefaultFilter("linear", "linear")
	font = love.graphics.newFont(13)

	local id = love.image.newImageData(1, 1)
	id:setPixel(0, 0, 1, 1, 1, 1)
	quad = love.graphics.newImage(id)

	W, H = love.graphics.getDimensions()
	loadShaders()
	buildCanvases()

	camKey = cameraKey()
	setKey = settingsKey()
end

function love.resize(w, h)
	W, H = w, h
	buildCanvases()
end

function love.update(dt)
	if S.autoOrbit then cam.yaw = cam.yaw + dt * 0.12 end

	-- Any camera or quality change invalidates the running mean.
	local ck, sk = cameraKey(), settingsKey()
	if ck ~= camKey or sk ~= setKey then
		camKey, setKey = ck, sk
		resetAccum()
	end
end

function love.draw()
	frame = frame + 1
	-- "replace" defaults to the alphamultiply alpha mode, which would scale
	-- every RGB write by its own alpha - fatal when alpha carries depth or
	-- roughness rather than coverage.
	love.graphics.setBlendMode("replace", "premultiplied")

	if S.pathTrace then
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
end

function love.keypressed(k)
	if k == "escape" then love.event.quit() return end

	if k == "tab" then
		S.pathTrace = not S.pathTrace
		resetAccum()
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
