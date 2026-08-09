// The same reference path tracer, tracing hardware acceleration structures
// instead of sphere-marching the signed distance field.
//
// THIS FILE IS A CONTROLLED EXPERIMENT, so everything that is not the
// intersector is copied from pathtrace.glsl verbatim: same next-event
// estimation, same GGX lobe choice, same Russian roulette, same firefly clamp,
// same seeding. If the two images differ, the difference is the intersector.
//
// WHAT ACTUALLY CHANGED, and it is only these three things:
//
//   trace()       160 sphere-marching steps, each evaluating all nine
//                 primitives          ->  one rayQueryEXT traversal
//   calcNormal()  four more map() calls for a gradient
//                                     ->  the hit triangle's own normal,
//                                         interpolated by barycentrics
//   the shadow    96 mapOcc() steps   ->  one rayQueryEXT with
//   march                                 TerminateOnFirstHit
//
// The emitter is excluded from shadow rays by INSTANCE MASK rather than by
// calling a different scene function -- see rt_scene.lua. Bit 0 means
// "occludes"; the emitter does not set it.

#pragma rayquery

uniform float uBounces;

uniform accelerationStructureEXT uTLAS;

// Vertex data for the scene instance. Indexed by primitive, three per triangle.
// The emitter instance needs none of this: it is one flat quad whose normal and
// material are known constants, so it is handled by custom index alone.
// readonly because love requires it of storage buffers in vertex and pixel
// shaders unless writes are explicitly enabled -- and nothing here writes.
readonly buffer Verts { vec4 vpos[]; };
readonly buffer Norms { vec4 vnrm[]; };
readonly buffer Mats  { float vmat[]; };

bool traceHW(vec3 ro, vec3 rd, float tmax, out float t, out vec3 n, out float id) {
	rayQueryEXT rq;
	rayQueryInitializeEXT(rq, uTLAS, gl_RayFlagsOpaqueEXT, 0xFF, ro, 0.0005, rd, tmax);
	while (rayQueryProceedEXT(rq)) {}

	if (rayQueryGetIntersectionTypeEXT(rq, true) == gl_RayQueryCommittedIntersectionNoneEXT)
		return false;

	t = rayQueryGetIntersectionTEXT(rq, true);

	if (rayQueryGetIntersectionInstanceCustomIndexEXT(rq, true) == 1) {
		n  = LIGHT_N;
		id = M_LIGHT;
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

vec3 sampleEmitterNEE(vec3 P, vec3 N, vec3 V, vec3 albedo, float rough, float metal, inout uint seed) {
	vec2 ul = rnd2(seed) * 2.0 - 1.0;
	vec3 lp = LIGHT_C + vec3(ul.x * LIGHT_H.x, -0.013, ul.y * LIGHT_H.y);
	vec3 L = lp - P;
	float d2 = dot(L, L), d = sqrt(d2);
	L /= d;

	float NoL = dot(N, L);
	float lnl = dot(LIGHT_N, -L);
	if (NoL <= 0.0 || lnl <= 0.0) return vec3(0.0);

	if (occludedHW(P + N * 0.003, L, d - 0.02)) return vec3(0.0);

	vec3  f0  = mix(vec3(0.04), albedo, metal);
	vec3  H   = normalize(L + V);
	float NoV = max(dot(N, V), 1e-4);
	float NoH = max(dot(N, H), 0.0);
	float VoH = max(dot(V, H), 0.0);
	float a   = max(rough * rough, 1e-4);

	vec3 F    = F_Schlick(f0, VoH);
	vec3 spec = F * D_GGX(NoH, a) * V_SmithGGX(NoV, NoL, a);
	vec3 diff = (1.0 - F) * (1.0 - metal) * albedo * INV_PI;

	return (diff + spec) * LIGHT_E * (NoL * lnl * LIGHT_AREA / max(d2, 1e-4));
}

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	uint seed = seedPixel(love_PixelCoord.xy, uFrame);

	vec2 uv = (love_PixelCoord.xy + rnd2(seed)) / uRes;
	vec3 ro = uCamPos;
	vec3 rd = rayDir(uv);

	vec3 radiance   = vec3(0.0);
	vec3 throughput = vec3(1.0);
	bool specularPath = true;
	int  maxB = int(uBounces);

	for (int b = 0; b < 8; b++) {
		if (b >= maxB) break;

		float t, id; vec3 N;
		if (!traceHW(ro, rd, 40.0, t, N, id)) break;   // escaped through the open face

		vec3 P = ro + rd * t;
		if (dot(N, -rd) < 0.0) N = -N;
		vec3 V = -rd;

		vec3 albedo, emis; float rough, metal;
		getMaterial(id, albedo, rough, metal, emis);

		if (id > 4.5) {
			if (specularPath) radiance += throughput * emis;
			break;
		}

		bool pureSpec = (metal > 0.5 && rough < 0.12);

		if (!pureSpec) {
			radiance += throughput * sampleEmitterNEE(P, N, V, albedo, rough, metal, seed);
			specularPath = false;
		} else {
			specularPath = true;
		}

		vec3  f0  = mix(vec3(0.04), albedo, metal);
		float NoV = max(dot(N, V), 1e-4);
		float pSpec = clamp(luma(F_Schlick(f0, NoV)) + metal, 0.04, 1.0);

		if (rnd(seed) < pSpec) {
			vec2 uh = rnd2(seed);
			vec3 H = sampleGGX(N, rough, uh.x, uh.y);
			vec3 L = reflect(-V, H);
			float NoL = dot(N, L);
			if (NoL <= 0.0) break;

			float VoH = max(dot(V, H), 1e-4);
			float NoH = max(dot(N, H), 1e-4);
			float a   = max(rough * rough, 1e-4);
			vec3  F   = F_Schlick(f0, VoH);

			throughput *= F * G_SmithGGX(NoV, NoL, a) * VoH / (NoV * NoH) / pSpec;
			rd = L;
		} else {
			vec2 ud = rnd2(seed);
			vec3 L = cosineHemisphere(N, ud.x, ud.y);
			throughput *= albedo * (1.0 - metal) / (1.0 - pSpec);
			rd = L;
			specularPath = false;
		}

		ro = P + N * 0.004;

		if (b >= 2) {
			float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 1.0);
			if (rnd(seed) > q) break;
			throughput /= q;
		}
	}

	radiance = min(radiance, vec3(60.0));
	return vec4(radiance, 1.0);
}
