// Pass 2 - SSAO. Textbook hemisphere-kernel occlusion, except that we have
// real world positions in the G-buffer so the sample points can be built and
// re-projected without ever touching a projection matrix.

uniform Image gNrm;
uniform float uAORadius;
uniform float uAOPower;
uniform float uAOSamples;

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	vec4 g  = Texel(gPos, uv);
	if (g.w > 1e5) return vec4(1.0);

	vec3 P = g.xyz;
	vec3 N = normalize(Texel(gNrm, uv).xyz);

	uint seed = seedPixel(love_PixelCoord.xy, uFrame);
	int  n    = int(uAOSamples);
	float occ = 0.0;

	for (int i = 0; i < 32; i++) {
		if (i >= n) break;

		// Cosine-distributed offset inside the hemisphere, pushed toward the
		// origin so short-range contact darkening dominates.
		vec2 u = rnd2(seed);
		vec3 dir = cosineHemisphere(N, u.x, u.y);
		float s  = rnd(seed);
		float r  = uAORadius * (0.1 + 0.9 * s * s);
		vec3 sp  = P + dir * r;

		vec3 pr = project(sp);
		if (pr.z <= 0.0 || pr.x < 0.0 || pr.x > 1.0 || pr.y < 0.0 || pr.y > 1.0) continue;

		float sceneZ = Texel(gPos, pr.xy).w;
		if (sceneZ > 1e5) continue;

		// The sample sits behind visible geometry -> occluded.
		if (sceneZ < pr.z - 0.0015) {
			// Range check stops distant background from occluding foreground.
			float range = smoothstep(0.0, 1.0, uAORadius / max(abs(pr.z - sceneZ), 1e-4));
			occ += range;
		}
	}

	float ao = 1.0 - occ / float(max(n, 1));
	ao = pow(clamp(ao, 0.0, 1.0), uAOPower);
	return vec4(ao, ao, ao, 1.0);
}
