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

// The integrator, one sample. The entry point lives in a driver snippet that
// main.lua appends: the reference driver additively accumulates the radiance,
// the denoiser driver also wants the first hit's normal, view depth, albedo
// and material id as guide data, so they are returned here. Capturing them
// adds no rnd() calls -- the sample sequence is identical either way, which
// is what keeps the reference images bit-stable across this refactor.
vec3 pathtracePixel(vec2 uv, inout uint seed,
                    out vec3 gN, out float gZ, out vec3 gAlb, out float gId,
                    out float gReflT) {
	vec3 ro = uCamPos;
	vec3 rd = rayDir(uv);

	// Miss defaults, matching the G-buffer's conventions. Albedo is 1 so the
	// denoiser's demodulation is a no-op where there is no surface. gReflT is
	// the mirror-bounce hit distance -- how far BEHIND a pure-specular first
	// hit its reflected content lives -- which the denoiser reprojects with.
	gN = -rd; gZ = 1e6; gAlb = vec3(1.0); gId = -1.0; gReflT = 0.0;
	bool firstPure = false;

	vec3 radiance   = vec3(0.0);
	vec3 throughput = vec3(1.0);
	bool specularPath = true;      // primary rays may see the emitter
	int  maxB = int(uBounces);

	for (int b = 0; b < 8; b++) {
		if (b >= maxB) break;

		float t, id;
		if (!trace(ro, rd, 40.0, t, id)) break;         // escaped through the open face

		if (b == 1 && firstPure) gReflT = t;

		vec3 P = ro + rd * t;
		vec3 N = calcNormal(P);
		if (dot(N, -rd) < 0.0) N = -N;
		vec3 V = -rd;

		vec3 albedo, emis; float rough, metal;
		getMaterial(id, albedo, rough, metal, emis);

		if (b == 0) {
			gN = N;
			gZ = dot(P - uCamPos, uCamFwd);
			// The emitter's albedo is black; demodulating emission by it would
			// blow up, so the light keeps an albedo of 1 in the guide buffer.
			gAlb = (id > 4.5) ? vec3(1.0) : albedo;
			gId = id;
		}

		if (id > 4.5) {                                  // hit the emitter
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

	return min(radiance, vec3(60.0));       // clamp fireflies
}
