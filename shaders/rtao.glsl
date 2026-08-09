// Pass 2, ray-traced variant. The SSAO kernel asked "does this sample point
// sit behind something in the depth buffer" -- visibility inferred from one
// camera's view of the scene. This asks the scene itself: short cosine-
// distributed rays into the hemisphere, hardware traversal, occlusion
// weighted by how close the hit is. No self-view blindness, no halo where
// the depth buffer runs out of information.
//
// Fewer rays than the SSAO tap count on purpose: a real ray is worth more
// than a depth-buffer peek, and the per-frame jitter is averaged by the same
// depth-aware blur and temporal accumulation that clean up SSAO.

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
	int  n    = min(int(uAOSamples), 8);
	float reach = uAORadius * 2.0;
	float occ = 0.0;

	for (int i = 0; i < 8; i++) {
		if (i >= n) break;

		vec2 u = rnd2(seed);
		vec3 dir = cosineHemisphere(N, u.x, u.y);

		rayQueryEXT rq;
		rayQueryInitializeEXT(rq, uTLAS,
			gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT,
			0x01, P + N * 0.004, 0.0005, dir, reach);
		while (rayQueryProceedEXT(rq)) {}

		if (rayQueryGetIntersectionTypeEXT(rq, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
			// Close hits occlude fully, hits near the reach barely at all --
			// the same falloff intent as SSAO's range check.
			float t = rayQueryGetIntersectionTEXT(rq, true);
			float x = clamp(t / reach, 0.0, 1.0);
			occ += 1.0 - x * x;
		}
	}

	float ao = 1.0 - occ / float(max(n, 1));
	ao = pow(clamp(ao, 0.0, 1.0), uAOPower);
	return vec4(ao, ao, ao, 1.0);
}
