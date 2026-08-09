-- Phase 5 probe: multiple geometries per BLAS, and compaction.
--
-- Multi-geometry: one bottom-level structure holding two triangles from two
-- separate vertex buffers, hit independently, then one of them refit after a
-- vertex rewrite -- exercising the per-geometry range array in both build and
-- update mode.
--
-- Compaction: the same dense mesh built twice, with and without
-- { compact = true }; the compacted one must be smaller and trace the same.
--
-- Writes a verdict to probe_result.txt in the save directory and quits.

local COMPUTE_SRC = [[
#pragma language glsl4
#pragma rayquery

uniform accelerationStructureEXT uTLAS;
buffer Results { float rt[]; };

layout(local_size_x = 3, local_size_y = 1, local_size_z = 1) in;
void computemain() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= 3u) return;
	vec3 origins[3] = vec3[3](vec3(0.0), vec3(30.0, 0.0, 0.0), vec3(60.0, 0.0, 0.0));
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, uTLAS, gl_RayFlagsOpaqueEXT, 0xFF,
		origins[i], 0.001, vec3(0.0, 0.0, 1.0), 100.0);
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

local function tri(cx, cy, z)
	return { { cx - 10, cy - 10, z, 0 }, { cx + 10, cy - 10, z, 0 }, { cx, cy + 10, z, 0 } }
end

local function vec4Buffer(t)
	return love.graphics.newBuffer(
		{ { name = "v", location = 0, format = "floatvec4" } }, t,
		{ shaderstorage = true, usage = "dynamic" })
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
		out[#out + 1] = ("%s  %-36s got %8.4f  want %8.4f"):format(ok and "ok  " or "FAIL", label, got, want)
	end
	local function checkTrue(label, ok)
		pass = pass and ok
		out[#out + 1] = (ok and "ok  " or "FAIL") .. "  " .. label
	end

	----------------------------------------------------------------- multi --
	local bufA = vec4Buffer(tri(0, 0, 2))    -- geometry 1: triangle at z=2
	local bufB = vec4Buffer(tri(30, 0, 5))   -- geometry 2: triangle at z=5, x+30

	local blas = love.graphics.newAccelerationStructure("bottom", {
		{ vertexbuffer = bufA, vertexcount = 3, vertexstride = 16 },
		{ vertexbuffer = bufB, vertexcount = 3, vertexstride = 16 },
	}, { updatable = true, debugname = "two geometries" })

	local tlas = love.graphics.newAccelerationStructure("top", { { blas } },
		{ updatable = true })

	local results = love.graphics.newBuffer(
		{ { name = "r", location = 0, format = "float" } }, { 99, 99, 99 },
		{ shaderstorage = true, usage = "dynamic" })

	local shader = love.graphics.newComputeShader(COMPUTE_SRC)
	shader:send("uTLAS", tlas)
	shader:send("Results", results)

	local function trace()
		love.graphics.dispatchThreadgroups(shader, 1, 1, 1)
		local data = love.graphics.readbackBuffer(results)
		local p = ffi.cast("const float*", data:getFFIPointer())
		return p[0], p[1], p[2]
	end

	local a, b, c = trace()
	check("geometry 1 hit", a, 2.0)
	check("geometry 2 hit", b, 5.0)
	check("miss stays a miss", c, -1.0)

	-- refit with two geometries: move only geometry 1's triangle to z=3
	bufA:setArrayData(tri(0, 0, 3))
	blas:update()
	tlas:update({ { blas } })
	a, b, c = trace()
	check("geometry 1 refit to z=3", a, 3.0)
	check("geometry 2 untouched by refit", b, 5.0)

	----------------------------------------------------------- compaction --
	-- A dense slab of triangles far behind the probe rays, plus nothing else;
	-- enough primitives that the build-size estimate visibly overshoots.
	-- Grid offset by -1 so the probe ray at (0,0) lands strictly INSIDE a
	-- triangle -- a ray through a shared vertex may resolve as hit or miss
	-- under watertight rules (see HARDWARE_RAYTRACING.md).
	local dense = {}
	for gy = 0, 39 do
		for gx = 0, 49 do
			local x, y = -101 + gx * 4, -81 + gy * 4
			dense[#dense + 1] = { x, y, 50, 0 }
			dense[#dense + 1] = { x + 3, y, 50, 0 }
			dense[#dense + 1] = { x, y + 3, 50, 0 }
		end
	end
	local denseBuf = vec4Buffer(dense)
	local geo = { { vertexbuffer = denseBuf, vertexcount = #dense, vertexstride = 16 } }

	local plain     = love.graphics.newAccelerationStructure("bottom", geo)
	local compacted = love.graphics.newAccelerationStructure("bottom", geo, { compact = true })

	checkTrue(("compacted is smaller: %d -> %d bytes (%.0f%%)")
		:format(plain:getSize(), compacted:getSize(),
			100 * compacted:getSize() / math.max(plain:getSize(), 1)),
		compacted:getSize() < plain:getSize())

	-- and the compacted structure still traces correctly
	local tlas2 = love.graphics.newAccelerationStructure("top", { { compacted } })
	shader:send("uTLAS", tlas2)
	a = select(1, trace())
	check("compacted structure traces", a, 50.0)

	--------------------------------------------------------------- errors --
	local okA = pcall(function()
		love.graphics.newAccelerationStructure("bottom", geo, { compact = true, updatable = true })
	end)
	local okB = pcall(function()
		love.graphics.newAccelerationStructure("top", { { plain } }, { compact = true })
	end)
	checkTrue("compact + updatable refused", not okA)
	checkTrue("compact top level refused", not okB)

	return ("%s: multi-geometry + compaction\n%s\n")
		:format(pass and "PASS" or "FAIL", table.concat(out, "\n"))
end

function love.load()
	local ok, res = pcall(run)
	report(ok and res or ("FAIL: error:\n" .. tostring(res)))
	love.event.quit()
end

function love.draw() end
