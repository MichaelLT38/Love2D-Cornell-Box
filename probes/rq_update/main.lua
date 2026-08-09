-- Phase 2 probe: TLAS update and BLAS refit through the public API.
--
-- One triangle, one instance, one ray from the origin straight down +z.
-- The triangle starts at z = 2 and is then moved twice -- once by giving the
-- INSTANCE a transform (tlas:update), once by rewriting the VERTICES and
-- refitting (blas:update + tlas:update, because a refit BLAS leaves any TLAS
-- referencing it with stale bounds). The ray reports where the hit landed
-- after each move, plus error-path and timing checks.
--
-- Writes a verdict to probe_result.txt in the save directory and quits.

local COMPUTE_SRC = [[
#pragma language glsl4
#pragma rayquery

uniform accelerationStructureEXT uTLAS;
buffer Results { float rt[]; };

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
void computemain() {
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, uTLAS, gl_RayFlagsOpaqueEXT, 0xFF,
		vec3(0.0), 0.001, vec3(0.0, 0.0, 1.0), 100.0);
	while (rayQueryProceedEXT(rq)) {}

	if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT)
		rt[0] = -1.0;
	else
		rt[0] = rayQueryGetIntersectionTEXT(rq, true);
}
]]

local IDENTITY = { 1,0,0,0, 0,1,0,0, 0,0,1,0 }

local function report(text)
	love.filesystem.write("probe_result.txt", text)
	print(text)
end

local function run()
	if not love.graphics.getSupported().rayquery then
		return "SKIP: rayquery not supported on this system"
	end

	local ffi = require("ffi")
	local out = {}
	local pass = true
	local function check(label, got, want)
		local ok = math.abs(got - want) < 1e-3
		pass = pass and ok
		out[#out + 1] = ("%s  %-34s got %8.4f  want %8.4f"):format(ok and "ok  " or "FAIL", label, got, want)
	end

	local verts = love.graphics.newBuffer(
		{ { name = "v", location = 0, format = "floatvec4" } },
		{ { -10, -10, 2, 0 }, { 10, -10, 2, 0 }, { 0, 10, 2, 0 } },
		{ shaderstorage = true, usage = "dynamic" })

	local blas = love.graphics.newAccelerationStructure("bottom", {
		{ vertexbuffer = verts, vertexcount = 3, vertexstride = 16 },
	}, { updatable = true, debugname = "probe triangle" })

	local tlas = love.graphics.newAccelerationStructure("top", {
		{ blas, transform = IDENTITY },
	}, { updatable = true, debugname = "probe tlas" })

	local results = love.graphics.newBuffer(
		{ { name = "r", location = 0, format = "float" } }, { 99 },
		{ shaderstorage = true, usage = "dynamic" })

	local shader = love.graphics.newComputeShader(COMPUTE_SRC)
	shader:send("uTLAS", tlas)
	shader:send("Results", results)

	local function trace()
		love.graphics.dispatchThreadgroups(shader, 1, 1, 1)
		local data = love.graphics.readbackBuffer(results)
		return ffi.cast("const float*", data:getFFIPointer())[0]
	end

	-- 1. as built: triangle at z = 2
	check("initial build", trace(), 2.0)

	-- 2. instance moved +3 in z by the TLAS
	tlas:update({ { blas, transform = { 1,0,0,0, 0,1,0,0, 0,0,1,3 } } })
	check("tlas:update, instance at z+3", trace(), 5.0)

	-- 3. back to identity
	tlas:update({ { blas, transform = IDENTITY } })
	check("tlas:update, back to identity", trace(), 2.0)

	-- 4. vertices moved to z = 4, BLAS refit, TLAS refreshed
	verts:setArrayData({ { -10, -10, 4, 0 }, { 10, -10, 4, 0 }, { 0, 10, 4, 0 } })
	blas:update()
	tlas:update({ { blas, transform = IDENTITY } })
	check("blas refit, vertices at z=4", trace(), 4.0)

	-- 5. both at once: refit vertices at z=4 plus instance z+3
	tlas:update({ { blas, transform = { 1,0,0,0, 0,1,0,0, 0,0,1,3 } } })
	check("refit + instance transform", trace(), 7.0)

	-- 6. error paths: non-updatable structures refuse, count changes refuse
	local staticBlas = love.graphics.newAccelerationStructure("bottom", {
		{ vertexbuffer = verts, vertexcount = 3, vertexstride = 16 },
	})
	local okA = pcall(function() staticBlas:update() end)
	local okB = pcall(function()
		tlas:update({ { blas, transform = IDENTITY }, { blas, transform = IDENTITY } })
	end)
	pass = pass and not okA and not okB
	out[#out + 1] = (okA and "FAIL" or "ok  ") .. "  non-updatable blas:update() errors"
	out[#out + 1] = (okB and "FAIL" or "ok  ") .. "  instance-count change errors"
	out[#out + 1] = ("      updatable flags: blas %s, static %s")
		:format(tostring(blas:isUpdatable()), tostring(staticBlas:isUpdatable()))

	-- 7. timing: how much CPU does one tlas:update cost, amortized
	local N = 300
	local t0 = love.timer.getTime()
	for i = 1, N do
		tlas:update({ { blas, transform = { 1,0,0,0, 0,1,0,0, 0,0,1, (i % 7) * 0.5 } } })
	end
	local recordMs = (love.timer.getTime() - t0) * 1000 / N
	local t1 = love.timer.getTime()
	local final = trace()   -- forces every recorded update to actually execute
	local flushMs = (love.timer.getTime() - t1) * 1000
	-- vertices sit at z = 4 since step 4; the last loop iteration left the
	-- instance at z + (300 % 7) * 0.5
	check("after 300 recorded updates", final, 4.0 + (N % 7) * 0.5)
	out[#out + 1] = ("      cpu record %.4f ms/update, gpu flush of all 300 + trace %.2f ms")
		:format(recordMs, flushMs)

	return ("%s: acceleration structure update/refit\n%s\n")
		:format(pass and "PASS" or "FAIL", table.concat(out, "\n"))
end

function love.load()
	local ok, res = pcall(run)
	report(ok and res or ("FAIL: error:\n" .. tostring(res)))
	love.event.quit()
end

function love.draw() end
