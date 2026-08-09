-- Phase 0 probe: do hardware ray queries work from a COMPUTE shader?
--
-- Same shape as the fork's pixel-shader test: one triangle at z = 2, five
-- rays -- three hits at t = 2.0, two misses. The only variable is the stage.
-- Writes a verdict to probe_result.txt in the save directory and quits.

local COMPUTE_SRC = [[
#pragma language glsl4
#pragma rayquery

uniform accelerationStructureEXT uTLAS;
buffer Results { float rt[]; };

layout(local_size_x = 5, local_size_y = 1, local_size_z = 1) in;
void computemain() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= 5u) return;

	// (+-4, 0) are strictly interior: at y = 0 the triangle spans (-5, 5)
	// exclusive, and a ray exactly on an edge may resolve either way.
	vec3 origins[5] = vec3[5](
		vec3(0.0, 0.0, 0.0), vec3(4.0, 0.0, 0.0), vec3(-4.0, 0.0, 0.0),
		vec3(0.0, 0.0, 0.0), vec3(100.0, 100.0, 0.0));
	vec3 dirs[5] = vec3[5](
		vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, 1.0), vec3(0.0, 0.0, 1.0),
		vec3(0.0, 0.0, -1.0), vec3(0.0, 0.0, 1.0));

	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, uTLAS, gl_RayFlagsOpaqueEXT, 0xFF,
		origins[i], 0.001, dirs[i], 100.0);
	while (rayQueryProceedEXT(rq)) {}

	if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT)
		rt[i] = -1.0;
	else
		rt[i] = rayQueryGetIntersectionTEXT(rq, true);
}
]]

local function report(text)
	love.filesystem.write("probe_result.txt", text)
	print(text)
end

local function run()
	if not love.graphics.getSupported().rayquery then
		return "SKIP: rayquery not supported on this system"
	end

	-- One big triangle in the z = 2 plane.
	local verts = love.graphics.newBuffer(
		{ { name = "v", location = 0, format = "floatvec4" } },
		{ { -10, -10, 2, 0 }, { 10, -10, 2, 0 }, { 0, 10, 2, 0 } },
		{ shaderstorage = true, usage = "static" })

	local blas = love.graphics.newAccelerationStructure("bottom", {
		{ vertexbuffer = verts, vertexcount = 3, vertexstride = 16 },
	}, { debugname = "probe triangle" })

	local tlas = love.graphics.newAccelerationStructure("top", {
		{ blas },
	}, { debugname = "probe tlas" })

	local results = love.graphics.newBuffer(
		{ { name = "r", location = 0, format = "float" } },
		{ 99, 99, 99, 99, 99 },
		{ shaderstorage = true, usage = "dynamic" })

	local ok, shader = pcall(love.graphics.newComputeShader, COMPUTE_SRC)
	if not ok then
		return "FAIL: compute shader did not compile:\n" .. tostring(shader)
	end

	shader:send("uTLAS", tlas)
	shader:send("Results", results)
	love.graphics.dispatchThreadgroups(shader, 1, 1, 1)

	local data = love.graphics.readbackBuffer(results)
	local ffi = require("ffi")
	local p = ffi.cast("const float*", data:getFFIPointer())

	local got, expect = {}, { 2.0, 2.0, 2.0, -1.0, -1.0 }
	local pass = true
	for i = 0, 4 do
		got[i + 1] = p[i]
		if math.abs(p[i] - expect[i + 1]) > 1e-4 then pass = false end
	end

	return ("%s: ray query in COMPUTE shader\nexpected  2.0 2.0 2.0 -1.0 -1.0\ngot       %.4f %.4f %.4f %.4f %.4f\n")
		:format(pass and "PASS" or "FAIL", got[1], got[2], got[3], got[4], got[5])
end

function love.load()
	local ok, res = pcall(run)
	report(ok and res or ("FAIL: error:\n" .. tostring(res)))
	love.event.quit()
end

function love.draw() end
