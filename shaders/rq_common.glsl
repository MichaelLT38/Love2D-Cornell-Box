// Shared hardware ray query plumbing: the TLAS, the scene's vertex data, and
// the two questions every ray-traced pass asks -- "what did this ray hit" and
// "is this shadow ray blocked". main.lua prepends this (after common.glsl) to
// every shader that traces: the hardware path tracer and the ray-traced
// variants of the deferred passes. One copy, so the Cornell box means the
// same thing to all of them.

#pragma rayquery

uniform accelerationStructureEXT uTLAS;

// Vertex data for the scene instance. Indexed by primitive, three per triangle.
// The emitter instance needs none of this: it is one flat quad whose normal and
// material are known constants, so it is handled by custom index alone.
// readonly because love requires it of storage buffers in vertex and pixel
// shaders unless writes are explicitly enabled -- and nothing here writes.
readonly buffer Verts { vec4 vpos[]; };
readonly buffer Norms { vec4 vnrm[]; };
readonly buffer Mats  { float vmat[]; };

// The tall block is its own instance (custom index 2) so its placement is a
// TLAS transform and it can move without a rebuild. Its normals are stored in
// LOCAL space; the hit reports them through the instance's object-to-world.
readonly buffer BlockNorms { vec4 bnrm[]; };

bool traceHW(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float id) {
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, uTLAS, gl_RayFlagsOpaqueEXT, 0xFF, ro, 0.0005, rd, tmax);
	while (rayQueryProceedEXT(rq)) {}

	if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT)
		return false;

	t = rayQueryGetIntersectionTEXT(rq, true);

	int ci = rayQueryGetIntersectionInstanceCustomIndexEXT(rq, true);

	if (ci == 1) {
		n  = LIGHT_N;
		id = M_LIGHT;
		return true;
	}

	if (ci == 2) {
		// Tall block: flat-shaded box, so the first vertex normal is the face
		// normal; rotate it from instance space to world. The transform is
		// rigid, so the normal transforms by the same matrix as positions.
		int p = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
		n  = normalize(mat3(rayQueryGetIntersectionObjectToWorldEXT(rq, true)) * bnrm[p * 3].xyz);
		id = M_WHITE;
		return true;
	}

	int  p  = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
	vec2 bc = rayQueryGetIntersectionBarycentricsEXT(rq, true);

	// Barycentrics are (b1, b2); the first vertex carries 1 - b1 - b2. Smooth
	// normals matter for exactly one object -- the sphere is tessellated here
	// and analytic in the SDF, and flat shading it would show up as facets in
	// the one surface in the scene that reflects everything else.
	vec3 n0 = vnrm[p * 3 + 0].xyz;
	vec3 n1 = vnrm[p * 3 + 1].xyz;
	vec3 n2 = vnrm[p * 3 + 2].xyz;
	n  = normalize(n0 * (1.0 - bc.x - bc.y) + n1 * bc.x + n2 * bc.y);
	id = vmat[p];
	return true;
}

bool occludedHW(vec3 ro, vec3 rd, float dist) {
	rayQueryEXT rq;
	// Cull mask 0x01: scene only. TerminateOnFirstHit because a shadow ray asks
	// "is anything in the way", not "what is nearest" -- which is the same
	// reason the marched version returns the moment h < 0.0005.
	rayQueryInitializeEXT(rq, uTLAS,
		gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT,
		0x01, ro, 0.0005, rd, dist);
	while (rayQueryProceedEXT(rq)) {}
	return rayQueryGetIntersectionTypeEXT(rq, true) != gl_RayQueryCommittedIntersectionNoneEXT;
}
