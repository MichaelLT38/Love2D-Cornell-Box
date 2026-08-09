// Ground-truth reference path tracer over the same SDF.
//
// One sample per pixel per frame, additively blended into an rgba32f target
// (alpha counts the samples). Next-event estimation to the ceiling quad on
// every rough surface; the near-mirror sphere is handled as a pure specular
// bounce that is allowed to see the emitter directly.
//
// Nothing here is screen-space, so it renders the reflections, contact
// shadows and colour bleed that the real-time passes can only approximate -
// which is the point of having it side by side.

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

	// Hard visibility - march the scene with the emitter removed.
	float t = 0.006;
	for (int i = 0; i < 96; i++) {
		float h = mapOcc(P + N * 0.003 + L * t);
		if (h < 0.0005) return vec3(0.0);
		t += h;
		if (t > d - 0.02) break;
	}

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
	bool specularPath = true;      // primary rays may see the emitter
	int  maxB = int(uBounces);

	for (int b = 0; b < 8; b++) {
		if (b >= maxB) break;

		float t, id;
		if (!trace(ro, rd, 40.0, t, id)) break;         // escaped through the open face

		vec3 P = ro + rd * t;
		vec3 N = calcNormal(P);
		if (dot(N, -rd) < 0.0) N = -N;
		vec3 V = -rd;

		vec3 albedo, emis; float rough, metal;
		getMaterial(id, albedo, rough, metal, emis);

		if (id > 4.5) {                                  // hit the emitter
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

		// ---- choose a lobe and continue ------------------------------
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

			// brdf * cos / pdf for NDF-sampled GGX
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

		// Russian roulette once the path has dimmed.
		if (b >= 2) {
			float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.05, 1.0);
			if (rnd(seed) > q) break;
			throughput /= q;
		}
	}

	radiance = min(radiance, vec3(60.0));   // clamp fireflies
	return vec4(radiance, 1.0);             // alpha accumulates the sample count
}
