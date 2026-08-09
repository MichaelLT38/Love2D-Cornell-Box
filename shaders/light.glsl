// Pass 3 - direct lighting + screen-space global illumination.
//
//   RT0 = direct (area light, 1 stochastic sample/frame) + emitters
//   RT1 = indirect bounce gathered in screen space, modulated by AO
//
// The GI gather reads the *previous* temporally-accumulated frame, so light
// that has already bounced once is available to bounce again: the number of
// effective bounces grows with the accumulation, which is what makes the
// colour bleed off the red/green walls build up the way it does.

uniform Image gNrm;
uniform Image gAlb;
uniform Image texAO;
uniform Image texPrevDirect; // previous accumulated radiance, split so the
uniform Image texPrevGI;     // composite can still isolate each term

uniform float uGIRays;
uniform float uGISteps;
uniform float uGIRadius;
uniform float uGIStrength;
uniform float uAOEnable;
uniform float uGIEnable;

vec3 directLight(vec3 P, vec3 N, vec3 V, vec3 albedo, float rough, float metal, inout uint seed) {
	// Sample a point on the ceiling quad.
	vec2 ul = rnd2(seed) * 2.0 - 1.0;
	vec3 lp = LIGHT_C + vec3(ul.x * LIGHT_H.x, -0.013, ul.y * LIGHT_H.y);
	vec3 L = lp - P;
	float d2 = dot(L, L);
	float d  = sqrt(d2);
	L /= d;

	float NoL = dot(N, L);
	float lnl = dot(LIGHT_N, -L);
	if (NoL <= 0.0 || lnl <= 0.0) return vec3(0.0);

	float vis = shadowRay(P + N * 0.004, L, d - 0.02, 64.0);
	if (vis <= 0.0) return vec3(0.0);

	// Solid-angle weight for uniform area sampling.
	float G = NoL * lnl * LIGHT_AREA / max(d2, 1e-4);

	vec3  f0   = mix(vec3(0.04), albedo, metal);
	vec3  H    = normalize(L + V);
	float NoV  = max(dot(N, V), 1e-4);
	float NoH  = max(dot(N, H), 0.0);
	float VoH  = max(dot(V, H), 0.0);
	float a    = max(rough * rough, 1e-4);

	vec3 F    = F_Schlick(f0, VoH);
	vec3 spec = F * D_GGX(NoH, a) * V_SmithGGX(NoV, NoL, a);
	vec3 diff = (1.0 - F) * (1.0 - metal) * albedo * INV_PI;

	return (diff + spec) * LIGHT_E * G * vis;
}

vec3 screenSpaceGI(vec3 P, vec3 N, inout uint seed) {
	int rays = int(uGIRays);
	int steps = int(uGISteps);
	vec3 acc = vec3(0.0);

	for (int i = 0; i < 8; i++) {
		if (i >= rays) break;

		// Cosine-weighted hemisphere sampling: pdf cancels the cos/PI term,
		// so the estimator is just the mean of the gathered radiance.
		vec2 ug = rnd2(seed);
		vec3 dir = cosineHemisphere(N, ug.x, ug.y);
		float jitter = rnd(seed);

		vec2 hUV; vec3 hP;
		if (!ssTrace(P + N * 0.006, dir, uGIRadius, steps, 0.22, jitter, hUV, hP)) continue;

		// Reject back-facing hits - light does not leave the far side.
		vec3 hN = normalize(Texel(gNrm, hUV).xyz);
		if (dot(hN, -dir) <= 0.0) continue;

		// Skip the emitter: its contribution is already in the direct term.
		if (Texel(gAlb, hUV).w > 4.5) continue;

		acc += Texel(texPrevDirect, hUV).rgb + Texel(texPrevGI, hUV).rgb;
	}
	return acc / float(max(rays, 1));
}

void effect() {
	vec2 uv = pixUV();
	vec4 g  = Texel(gPos, uv);

	if (g.w > 1e5) {                       // background
		love_Canvases[0] = vec4(0.0, 0.0, 0.0, 1.0);
		love_Canvases[1] = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}

	vec4  nr  = Texel(gNrm, uv);
	vec4  ab  = Texel(gAlb, uv);
	vec3  P   = g.xyz;
	vec3  N   = normalize(nr.xyz);
	float rough = nr.w;
	vec3  albedo = ab.rgb;
	float id  = ab.w;
	vec3  V   = normalize(uCamPos - P);

	vec3 dummyA, emis; float dummyR, metal;
	getMaterial(id, dummyA, dummyR, metal, emis);

	uint seed = seedPixel(love_PixelCoord.xy, uFrame);

	vec3 direct = emis;
	if (id < 4.5) direct += directLight(P, N, V, albedo, rough, metal, seed);

	float ao = (uAOEnable > 0.5) ? Texel(texAO, uv).r : 1.0;

	vec3 gi = vec3(0.0);
	if (uGIEnable > 0.5 && id < 4.5 && metal < 0.5) {
		gi = screenSpaceGI(P, N, seed) * albedo * uGIStrength * ao;
	}

	love_Canvases[0] = vec4(direct, 1.0);
	love_Canvases[1] = vec4(gi, 1.0);
}
