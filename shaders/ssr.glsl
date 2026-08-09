// Pass 4 - screen-space reflections.
//
// Coarse linear march against the depth in the G-buffer, then a binary
// refinement of the crossing point. Roughness perturbs the reflection vector
// through a GGX lobe; the per-frame noise that introduces is cleaned up by the
// temporal accumulator downstream, which is how it stays cheap.

uniform Image gNrm;
uniform Image gAlb;
uniform Image texPrevDirect;
uniform Image texPrevGI;

uniform float uSSRSteps;
uniform float uSSRDist;
uniform float uSSRThickness;
uniform float uSSREnable;

vec3 radianceAt(vec2 uv) {
	return Texel(texPrevDirect, uv).rgb + Texel(texPrevGI, uv).rgb;
}

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	if (uSSREnable < 0.5) return vec4(0.0, 0.0, 0.0, 1.0);

	vec2 uv = pixUV();
	vec4 g  = Texel(gPos, uv);
	if (g.w > 1e5) return vec4(0.0, 0.0, 0.0, 1.0);

	vec4  nr = Texel(gNrm, uv);
	vec4  ab = Texel(gAlb, uv);
	float id = ab.w;
	if (id > 4.5) return vec4(0.0, 0.0, 0.0, 1.0);   // emitter

	vec3  P = g.xyz;
	vec3  N = normalize(nr.xyz);
	float rough = nr.w;
	vec3  V = normalize(uCamPos - P);
	float NoV = max(dot(N, V), 1e-4);

	vec3 dummyA, emis; float dummyR, metal;
	getMaterial(id, dummyA, dummyR, metal, emis);

	// Past ~0.8 roughness the specular lobe is so wide that a single
	// screen-space ray is a terrible estimator - it produces structured
	// ghosts instead of a blur - and the SSGI diffuse term already carries
	// that energy. Fade out rather than fight it.
	float roughFade = 1.0 - smoothstep(0.35, 0.80, rough);
	if (roughFade <= 0.002) return vec4(0.0, 0.0, 0.0, 1.0);

	vec3 f0 = mix(vec3(0.04), ab.rgb, metal);

	uint seed = seedPixel(love_PixelCoord.xy, uFrame);

	// Importance-sample the specular lobe, then reflect about the sampled
	// microfacet normal rather than the geometric one.
	vec2 uh = rnd2(seed);
	vec3 H = sampleGGX(N, rough, uh.x, uh.y);
	vec3 R = reflect(-V, H);
	float NoL = dot(N, R);
	if (NoL <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);   // sample went below the horizon

	// brdf * cos / pdf for an NDF-sampled GGX lobe. Collapses to plain
	// Fresnel as roughness -> 0, and correctly dims grazing angles through
	// the Smith masking term - which plain Fresnel does not.
	float VoH = max(dot(V, H), 1e-4);
	float NoH = max(dot(N, H), 1e-4);
	float a   = max(rough * rough, 1e-4);
	vec3  F   = F_Schlick(f0, VoH);
	vec3  weight = min(F * G_SmithGGX(NoV, NoL, a) * VoH / (NoV * NoH), vec3(4.0));

	int steps = int(uSSRSteps);
	float jitter = rnd(seed);

	// --- coarse march --------------------------------------------------
	vec3 ro = P + N * 0.006;
	float tHit = -1.0, tPrev = 0.0;
	vec2 hitUV = vec2(0.0);
	bool offscreen = false;

	for (int i = 1; i <= 64; i++) {
		if (i > steps) break;
		float ti = uSSRDist * (float(i) - jitter) / float(steps);
		vec3 pr = project(ro + R * ti);
		if (pr.z <= 0.0) { offscreen = true; break; }
		if (pr.x < 0.0 || pr.x > 1.0 || pr.y < 0.0 || pr.y > 1.0) { offscreen = true; break; }

		float sceneZ = Texel(gPos, pr.xy).w;
		float diff = pr.z - sceneZ;
		if (diff > 0.0015 && diff < uSSRThickness) { tHit = ti; hitUV = pr.xy; break; }
		tPrev = ti;
	}
	if (tHit < 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

	// --- binary refinement ---------------------------------------------
	float lo = tPrev, hi = tHit;
	for (int k = 0; k < 6; k++) {
		float mid = 0.5 * (lo + hi);
		vec3 pr = project(ro + R * mid);
		float sceneZ = Texel(gPos, pr.xy).w;
		if (pr.z - sceneZ > 0.0015) { hi = mid; hitUV = pr.xy; }
		else                        { lo = mid; }
	}

	// --- confidence -----------------------------------------------------
	// Fade at the screen border and when the ray comes back at the camera,
	// the two places where the screen-space assumption visibly falls apart.
	vec2 e = smoothstep(vec2(0.0), vec2(0.08), hitUV) *
	         (1.0 - smoothstep(vec2(0.92), vec2(1.0), hitUV));
	float edgeFade = e.x * e.y;
	// Rays travelling back toward the eye are the ones screen space resolves
	// worst, but the march already rejects anything that goes behind the near
	// plane - so this only needs to be a gentle taper, not a cliff.
	float toEye = max(dot(R, V), 0.0);
	float backFade = clamp(1.0 - 0.55 * toEye * toEye, 0.0, 1.0);

	vec3 hitN = normalize(Texel(gNrm, hitUV).xyz);
	if (dot(hitN, -R) <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

	vec3 col = radianceAt(hitUV) * weight * edgeFade * backFade * roughFade;
	return vec4(col, 1.0);
}
