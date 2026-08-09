// Pass 4, ray-traced variant. The same GGX lobe sampling and BRDF weight as
// ssr.glsl -- the estimator is unchanged -- but the reflection ray is traced
// against the scene instead of marched against the depth buffer. So the two
// SSR failure modes this demo documents simply do not exist here:
//
//   * nothing fades at the screen edge, because there is no screen edge --
//     no edgeFade, no backFade, both were apologies for the depth buffer
//   * geometry that left the frame still reflects, because the TLAS does not
//     care what the camera sees
//
// Alpha carries the reflection HIT DISTANCE for the denoiser's
// virtual-depth reprojection (0 where there is no reflection).
//
// The hit is shaded with the same next-event estimation as everywhere else,
// plus the previous accumulated frame's bounce light when the hit point
// happens to be on screen (the same trick SSR uses for its whole result --
// here it is only garnish on top of real direct lighting).
//
// The roughness fade is kept IDENTICAL to ssr.glsl, so toggling between the
// two compares visibility sources and nothing else.

uniform Image gNrm;
uniform Image gAlb;
uniform Image texPrevDirect;
uniform Image texPrevGI;

uniform float uSSRSteps;      // unused here; kept so the pass interface matches
uniform float uSSRDist;
uniform float uSSRThickness;
uniform float uSSREnable;

// Diffuse next-event estimation at the reflected hit point: one jittered
// sample of the area light, one hardware shadow ray. Reflections of rough
// surfaces are overwhelmingly diffuse, so the specular term is deliberately
// dropped -- it is not worth a second set of BRDF plumbing here.
vec3 directAtHit(vec3 P, vec3 N, vec3 albedo, float metal, inout uint seed) {
	vec2 ul = rnd2(seed) * 2.0 - 1.0;
	vec3 lp = LIGHT_C + vec3(ul.x * LIGHT_H.x, -0.013, ul.y * LIGHT_H.y);
	vec3 L = lp - P;
	float d2 = dot(L, L), d = sqrt(d2);
	L /= d;

	float NoL = dot(N, L);
	float lnl = dot(LIGHT_N, -L);
	if (NoL <= 0.0 || lnl <= 0.0) return vec3(0.0);

	if (occludedHW(P + N * 0.003, L, d - 0.02)) return vec3(0.0);

	return albedo * (1.0 - metal) * INV_PI
	     * LIGHT_E * (NoL * lnl * LIGHT_AREA / max(d2, 1e-4));
}

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	if (uSSREnable < 0.5) return vec4(0.0);

	vec2 uv = pixUV();
	vec4 g  = Texel(gPos, uv);
	if (g.w > 1e5) return vec4(0.0);

	vec4  nr = Texel(gNrm, uv);
	vec4  ab = Texel(gAlb, uv);
	float id = ab.w;
	if (id > 4.5) return vec4(0.0);   // emitter

	vec3  P = g.xyz;
	vec3  N = normalize(nr.xyz);
	float rough = nr.w;
	vec3  V = normalize(uCamPos - P);
	float NoV = max(dot(N, V), 1e-4);

	vec3 dummyA, emis; float dummyR, metal;
	getMaterial(id, dummyA, dummyR, metal, emis);

	// Same fade as ssr.glsl: a single ray is still a bad estimator for a very
	// wide lobe, hardware or not, and the diffuse GI term carries that energy.
	float roughFade = 1.0 - smoothstep(0.35, 0.80, rough);
	if (roughFade <= 0.002) return vec4(0.0);

	vec3 f0 = mix(vec3(0.04), ab.rgb, metal);

	uint seed = seedPixel(love_PixelCoord.xy, uFrame);

	vec2 uh = rnd2(seed);
	vec3 H = sampleGGX(N, rough, uh.x, uh.y);
	vec3 R = reflect(-V, H);
	float NoL = dot(N, R);
	if (NoL <= 0.0) return vec4(0.0);

	float VoH = max(dot(V, H), 1e-4);
	float NoH = max(dot(N, H), 1e-4);
	float a   = max(rough * rough, 1e-4);
	vec3  F   = F_Schlick(f0, VoH);
	vec3  weight = min(F * G_SmithGGX(NoV, NoL, a) * VoH / (NoV * NoH), vec3(4.0));

	// --- one real ray ----------------------------------------------------
	float t; vec3 hN; float hId;
	if (!traceHW(P + N * 0.004, R, 40.0, t, hN, hId))
		return vec4(0.0);   // out through the open face

	if (hId > 4.5)                          // the mirror sees the light itself
		return vec4(LIGHT_E * weight * roughFade, t);

	vec3 HP = P + N * 0.004 + R * t;
	if (dot(hN, -R) < 0.0) hN = -hN;

	vec3 hAlb, hEmis; float hRough, hMetal;
	getMaterial(hId, hAlb, hRough, hMetal, hEmis);

	vec3 col = directAtHit(HP, hN, hAlb, hMetal, seed);

	// Bounce light at the hit, when the previous accumulated frame happens to
	// know it: project the hit point and check it is actually the surface the
	// screen shows there, not something in front of or behind it.
	vec3 pr = project(HP);
	if (pr.z > 0.0 && pr.x > 0.0 && pr.x < 1.0 && pr.y > 0.0 && pr.y < 1.0) {
		float sceneZ = Texel(gPos, pr.xy).w;
		if (abs(sceneZ - pr.z) < 0.02 * pr.z + 0.01)
			col += Texel(texPrevGI, pr.xy).rgb;
	}

	return vec4(col * weight * roughFade, t);
}
