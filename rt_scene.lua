-- The Cornell box as triangles, plus the acceleration structures a hardware
-- ray query traces against.
--
-- WHY THIS FILE EXISTS
--
-- The renderer here is built on a signed distance field, and the path tracer
-- finds surfaces by sphere marching it. That costs, per bounce: up to 160
-- `map()` calls to find the hit, 4 more for the gradient normal, and up to 96
-- `mapOcc()` calls for the shadow ray -- and every one of those evaluates all
-- nine primitives in the scene. Call it two thousand primitive evaluations per
-- bounce, done in the shader core.
--
-- Hardware ray tracing answers the same two questions -- what did this ray hit,
-- and is this shadow ray blocked -- with dedicated traversal silicon. The
-- scene has to be triangles for that, so this file emits them.
--
-- THE GEOMETRY IS TRANSCRIBED, NOT REDESIGNED. Every centre, half-extent,
-- rotation and material below is copied from `mapEx()` in shaders/common.glsl.
-- If the two drift apart the comparison stops meaning anything, so they are
-- listed in the same order with the same comments and the tessellated sphere is
-- the only intentional difference.
--
-- TWO STRUCTURES, NOT ONE, AND THAT IS THE INTERESTING PART. The SDF has two
-- scene functions: `map()` includes the emitter and `mapOcc()` excludes it, so
-- shadow rays do not stop on the light itself. The hardware equivalent is an
-- instance mask -- the emitter goes in its own instance, and a shadow ray is
-- issued with a cull mask that excludes it. Same rule, expressed to the
-- traversal hardware instead of to a branch.

local rt = {}

-- Materials, matching the #defines in common.glsl.
local M_WHITE, M_RED, M_GREEN, M_FLOOR, M_METAL, M_LIGHT = 0, 1, 2, 3, 4, 5

-- Emitter, matching LIGHT_C / LIGHT_H.
local LIGHT_C = { 0.0, 0.982, -0.04 }
local LIGHT_H = { 0.33, 0.012, 0.27 }

-- Sphere tessellation. The SDF sphere is analytic and this one is not, which is
-- the single place the two scenes genuinely differ; 64x32 keeps the silhouette
-- smooth enough that the difference does not show up in an image diff.
local SPH_LON, SPH_LAT = 64, 32

---------------------------------------------------------------------------
-- triangle soup
---------------------------------------------------------------------------

local function newSoup()
	return { pos = {}, nrm = {}, mat = {}, tris = 0 }
end

local function addTri(s, a, b, c, na, nb, nc, m)
	local p, n = s.pos, s.nrm
	p[#p + 1] = { a[1], a[2], a[3], 0 }
	p[#p + 1] = { b[1], b[2], b[3], 0 }
	p[#p + 1] = { c[1], c[2], c[3], 0 }
	n[#n + 1] = { na[1], na[2], na[3], 0 }
	n[#n + 1] = { nb[1], nb[2], nb[3], 0 }
	n[#n + 1] = { nc[1], nc[2], nc[3], 0 }
	s.mat[#s.mat + 1] = m
	s.tris = s.tris + 1
end

--- `mapEx` evaluates the box in a ROTATED FRAME: a point is inside when
--- `rotY(p - centre, a)` is in the box. So the box in world space is the
--- centre plus the INVERSE rotation of its local corners -- rotY(v, -a).
--- Getting this backwards produces two blocks rotated the wrong way, which
--- still looks like a Cornell box and is wrong in every reflection.
local function xform(v, centre, angle)
	local x, y, z = v[1], v[2], v[3]
	if angle ~= 0 then
		local c, s = math.cos(angle), math.sin(angle)
		x, z = c * x + s * z, -s * x + c * z
	end
	return { x + centre[1], y + centre[2], z + centre[3] }
end

local function rotOnly(v, angle)
	if angle == 0 then return v end
	local c, s = math.cos(angle), math.sin(angle)
	return { c * v[1] + s * v[3], v[2], -s * v[1] + c * v[3] }
end

-- Corner i has +half on axis k when bit k of i is set.
local FACES = {
	{ idx = { 1, 5, 7, 3 }, n = {  1,  0,  0 } },
	{ idx = { 0, 4, 6, 2 }, n = { -1,  0,  0 } },
	{ idx = { 2, 3, 7, 6 }, n = {  0,  1,  0 } },
	{ idx = { 0, 1, 5, 4 }, n = {  0, -1,  0 } },
	{ idx = { 4, 5, 7, 6 }, n = {  0,  0,  1 } },
	{ idx = { 0, 2, 3, 1 }, n = {  0,  0, -1 } },
}

local function addBox(s, centre, half, m, angle)
	angle = angle or 0

	local corner = {}
	for i = 0, 7 do
		corner[i] = {
			(i % 2 == 1)            and half[1] or -half[1],
			(math.floor(i / 2) % 2 == 1) and half[2] or -half[2],
			(math.floor(i / 4) % 2 == 1) and half[3] or -half[3],
		}
	end

	for _, f in ipairs(FACES) do
		local q = {}
		for k = 1, 4 do q[k] = xform(corner[f.idx[k]], centre, angle) end
		local n = rotOnly(f.n, angle)
		addTri(s, q[1], q[2], q[3], n, n, n, m)
		addTri(s, q[1], q[3], q[4], n, n, n, m)
	end
end

local function addSphere(s, centre, r, m)
	local function at(i, j)
		local th = math.pi * (j / SPH_LAT)
		local ph = 2 * math.pi * (i / SPH_LON)
		local n = { math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph) }
		return { centre[1] + r * n[1], centre[2] + r * n[2], centre[3] + r * n[3] }, n
	end

	for j = 0, SPH_LAT - 1 do
		for i = 0, SPH_LON - 1 do
			local p00, n00 = at(i,     j)
			local p10, n10 = at(i + 1, j)
			local p11, n11 = at(i + 1, j + 1)
			local p01, n01 = at(i,     j + 1)
			-- Degenerate triangles at the poles are skipped rather than built:
			-- a zero-area triangle has no normal and its barycentrics are junk.
			if j > 0            then addTri(s, p00, p10, p11, n00, n10, n11, m) end
			if j < SPH_LAT - 1  then addTri(s, p00, p11, p01, n00, n11, n01, m) end
		end
	end
end

---------------------------------------------------------------------------
-- build
---------------------------------------------------------------------------

-- The tall block's placement, matching mapEx. It lives in its OWN instance
-- so the placement is a TLAS transform rather than baked vertices -- which is
-- what lets rt.setBlockAngle spin it per frame with tlas:update() instead of
-- rebuilding anything.
local BLOCK_C = { -0.38, -0.40, -0.30 }
local BLOCK_H = {  0.28,  0.60,  0.28 }
local BLOCK_A = 0.29

local function buildScene()
	local s = newSoup()
	addBox(s, {  0.00, -1.05,  0.00 }, { 1.10, 0.05, 1.10 }, M_FLOOR)  -- floor
	addBox(s, {  0.00,  1.05,  0.00 }, { 1.10, 0.05, 1.10 }, M_WHITE)  -- ceiling
	addBox(s, {  0.00,  0.00, -1.05 }, { 1.10, 1.10, 0.05 }, M_WHITE)  -- back
	addBox(s, { -1.05,  0.00,  0.00 }, { 0.05, 1.00, 1.05 }, M_RED)    -- left
	addBox(s, {  1.05,  0.00,  0.00 }, { 0.05, 1.00, 1.05 }, M_GREEN)  -- right
	-- tall block is its own instance now, see buildBlock
	addBox(s, {  0.38, -0.70,  0.26 }, { 0.30, 0.30, 0.30 }, M_WHITE, -0.32) -- short block
	addSphere(s, { 0.38, -0.14, 0.26 }, 0.26, M_METAL)                  -- chrome sphere
	return s
end

-- The tall block in LOCAL space: centred on the origin, unrotated. Placement
-- and spin are entirely the instance transform's job.
local function buildBlock()
	local s = newSoup()
	addBox(s, { 0, 0, 0 }, BLOCK_H, M_WHITE)
	return s
end

--- The block's instance transform for a spin of `extra` radians on top of its
--- resting angle. Row-major 3x4, same rotation convention as xform(): world =
--- centre + rotY(local, -(angle)) expressed as a matrix.
function rt.blockTransform(extra)
	local a = BLOCK_A + (extra or 0)
	local c, s = math.cos(a), math.sin(a)
	return {  c, 0, s, BLOCK_C[1],
	          0, 1, 0, BLOCK_C[2],
	         -s, 0, c, BLOCK_C[3] }
end

local function buildEmitter()
	local s = newSoup()
	addBox(s, LIGHT_C, LIGHT_H, M_LIGHT)
	return s
end

--- Vertex positions double as the acceleration structure's build input AND as a
--- storage buffer the shader reads to interpolate normals, so one buffer wears
--- both hats. floatvec4 rather than floatvec3: the build reads three floats at
--- each stride and ignores the fourth, and vec4 keeps the std430 indexing in
--- the shader trivial.
local function vec4Buffer(t)
	return love.graphics.newBuffer(
		{ { name = "v", location = 0, format = "floatvec4" } }, t,
		{ shaderstorage = true, usage = "static" })
end

--- Returns nil plus a reason when the system cannot do this, rather than
--- erroring: the caller falls back to the SDF path tracer, which is the whole
--- point of having both.
function rt.build()
	if not love.graphics.getSupported().rayquery then
		return nil, "love.graphics.getSupported().rayquery is false"
	end
	if not love.graphics.newAccelerationStructure then
		return nil, "this LOVE build has no love.graphics.newAccelerationStructure"
	end

	local ok, res = pcall(function()
		local scene, emitter, block = buildScene(), buildEmitter(), buildBlock()

		local scenePos = vec4Buffer(scene.pos)
		local sceneNrm = vec4Buffer(scene.nrm)
		local sceneMat = love.graphics.newBuffer(
			{ { name = "m", location = 0, format = "float" } }, scene.mat,
			{ shaderstorage = true, usage = "static" })
		local emitPos  = vec4Buffer(emitter.pos)
		local blockPos = vec4Buffer(block.pos)
		local blockNrm = vec4Buffer(block.nrm)

		-- All three bottom levels are static geometry (the block MOVES by
		-- instance transform, its triangles never change), so all three are
		-- compacted: a one-time build stall for smaller structures all run.
		-- On builds whose wrap layer predates the option it is ignored.
		local sceneBlas = love.graphics.newAccelerationStructure("bottom", {
			{ vertexbuffer = scenePos, vertexcount = scene.tris * 3, vertexstride = 16 },
		}, { compact = true, debugname = "cornell scene" })

		local emitBlas = love.graphics.newAccelerationStructure("bottom", {
			{ vertexbuffer = emitPos, vertexcount = emitter.tris * 3, vertexstride = 16 },
		}, { compact = true, debugname = "cornell emitter" })

		local blockBlas = love.graphics.newAccelerationStructure("bottom", {
			{ vertexbuffer = blockPos, vertexcount = block.tris * 3, vertexstride = 16 },
		}, { compact = true, debugname = "cornell tall block" })

		-- Instance masks are the `map` / `mapOcc` split. Bit 0 is "occludes";
		-- the emitter does not set it, so a shadow ray issued with cull mask
		-- 0x01 never sees the light, exactly as mapOcc drops it from the union.
		-- The block occludes like the rest of the scene.
		local function instanceList(extra)
			return {
				{ sceneBlas, customindex = 0, mask = 0x01 },
				{ emitBlas,  customindex = 1, mask = 0x02 },
				{ blockBlas, customindex = 2, mask = 0x01, transform = rt.blockTransform(extra) },
			}
		end

		-- updatable so setBlockAngle can refit it per frame. On a build whose
		-- wrap layer predates the option this is silently ignored and the
		-- update method simply does not exist -- canAnimate says which.
		local tlas = love.graphics.newAccelerationStructure("top", instanceList(0),
			{ updatable = true, debugname = "cornell tlas" })

		local result = {
			tlas = tlas, blas = { sceneBlas, emitBlas, blockBlas },
			pos = scenePos, nrm = sceneNrm, mat = sceneMat, emitPos = emitPos,
			blockNrm = blockNrm, blockPos = blockPos,
			tris = scene.tris + emitter.tris + block.tris,
			sceneTris = scene.tris,
			bytes = sceneBlas:getSize() + emitBlas:getSize() + blockBlas:getSize() + tlas:getSize(),
			canAnimate = tlas.update ~= nil,
		}

		--- Spin the tall block: one TLAS refit, nothing rebuilt.
		function result.setBlockAngle(extra)
			tlas:update(instanceList(extra))
		end

		return result
	end)

	if not ok then return nil, tostring(res) end
	return res
end

return rt
