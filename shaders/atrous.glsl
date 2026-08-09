// Denoiser pass 3 -- one iteration of the edge-aware a-trous wavelet filter.
//
// Run five times with uStep = 1, 2, 4, 8, 16: a 5x5 kernel whose taps spread
// apart each iteration, so five cheap passes act like one enormous bilateral
// filter. Three edge-stopping weights keep it honest:
//
//   depth      don't blur across a silhouette (tolerance scaled by the local
//              depth slope from dFdx/dFdy, so slanted floors aren't edges)
//   normal     don't blur around a corner
//   luminance  don't blur real signal -- differences are measured against the
//              pixel's own noise estimate, so a noisy pixel accepts its
//              neighbours and a converged one keeps its detail
//
// Variance rides in alpha and is filtered alongside with squared weights,
// which is what lets later iterations know how much noise is left.

uniform Image texColor;   // rgb = color, a = variance
uniform Image texNrmZ;    // guides
uniform float uStep;      // tap spacing in pixels
uniform float uSigmaL;    // luminance edge sensitivity (~4)

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	vec4 cp = Texel(texColor, uv);
	vec4 nz = Texel(texNrmZ, uv);

	if (nz.w > 1e5)                      // open face: nothing to filter
		return cp;

	float lp    = luma(cp.rgb);
	float zgrad = abs(dFdx(nz.w)) + abs(dFdy(nz.w)) + 1e-4;

	// 3x3-blurred variance drives the luminance weight; SVGF's trick to stop
	// a single lucky (low-variance) pixel from rejecting its whole
	// neighbourhood while everything around it is still noisy.
	float gvar = 0.0;
	{
		const float g[3] = float[3](0.25, 0.125, 0.0625);
		float wsum = 0.0;
		for (int dy = -1; dy <= 1; dy++)
		for (int dx = -1; dx <= 1; dx++) {
			float w = g[abs(dx) + abs(dy)];
			gvar += Texel(texColor, uv + vec2(dx, dy) / uRes).a * w;
			wsum += w;
		}
		gvar /= wsum;
	}
	float sigmaL = uSigmaL * sqrt(max(gvar, 0.0)) + 1e-4;

	// B3-spline weights by |offset|: 3/8, 1/4, 1/16.
	const float h[3] = float[3](0.375, 0.25, 0.0625);

	vec3  sumC = vec3(0.0);
	float sumV = 0.0;
	float sumW = 0.0;

	for (int dy = -2; dy <= 2; dy++)
	for (int dx = -2; dx <= 2; dx++) {
		vec2 q   = uv + vec2(dx, dy) * uStep / uRes;
		vec4 nzq = Texel(texNrmZ, q);
		if (nzq.w > 1e5) continue;

		vec4  cq = Texel(texColor, q);
		float lq = luma(cq.rgb);

		float dist = length(vec2(dx, dy)) * uStep;
		float wz = exp(-abs(nz.w - nzq.w) / (zgrad * dist + 1e-3));
		float wn = pow(max(dot(nz.xyz, nzq.xyz), 0.0), 128.0);
		float wl = exp(-abs(lp - lq) / sigmaL);
		float w  = wz * wn * wl * h[abs(dx)] * h[abs(dy)] * 2.6667;

		sumC += cq.rgb * w;
		sumV += cq.a * w * w;
		sumW += w;
	}

	return vec4(sumC / max(sumW, 1e-6),
	            sumV / max(sumW * sumW, 1e-6));
}
