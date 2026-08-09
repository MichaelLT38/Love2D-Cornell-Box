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

// The TLAS, scene buffers, traceHW and occludedHW all live in rq_common.glsl,
// which main.lua prepends -- they are shared with the ray-traced variants of
// the deferred passes.

uniform float uBounces;

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

// Same driver-snippet arrangement as pathtrace.glsl: main.lua appends either
// the accumulating reference entry point or the denoiser's MRT one. First-hit
// guide data is captured without any extra rnd() calls, so the sample
// sequence -- and therefore the reference images -- are unchanged.
vec3 pathtracePixel(vec2 uv, inout uint seed,
                    out vec3 gN, out float gZ, out vec3 gAlb, out float gId,
                    out float gReflT) {
	vec3 ro = uCamPos;
	vec3 rd = rayDir(uv);

	gN = -rd; gZ = 1e6; gAlb = vec3(1.0); gId = -1.0; gReflT = 0.0;
	bool firstPure = false;

	vec3 radiance   = vec3(0.0);
	vec3 throughput = vec3(1.0);
	bool specularPath = true;
	int  maxB = int(uBounces);

	for (int b = 0; b < 8; b++) {
		if (b >= maxB) break;

		float t, id; vec3 N;
		if (!traceHW(ro, rd, 40.0, t, N, id)) break;   // escaped through the open face

		if (b == 1 && firstPure) gReflT = t;

		vec3 P = ro + rd * t;
		if (dot(N, -rd) < 0.0) N = -N;
		vec3 V = -rd;

		vec3 albedo, emis; float rough, metal;
		getMaterial(id, albedo, rough, metal, emis);

		if (b == 0) {
			gN = N;
			gZ = dot(P - uCamPos, uCamFwd);
			gAlb = (id > 4.5) ? vec3(1.0) : albedo;   // emission stays undivided
			gId = id;
		}

		if (id > 4.5) {
			if (specularPath) radiance += throughput * emis;
			break;
		}

		bool pureSpec = (metal > 0.5 && rough < 0.12);
		if (b == 0) firstPure = pureSpec;

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

	return min(radiance, vec3(60.0));
}
