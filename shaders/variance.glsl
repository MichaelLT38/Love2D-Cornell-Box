// Denoiser pass 2 -- per-pixel noise estimate.
//
// Writes the accumulated color through unchanged and puts an estimate of its
// remaining variance in alpha, which is the form the a-trous passes consume.
//
// With enough history the temporal moments are the estimate: E[l^2] - E[l]^2.
// With fewer than four frames (disocclusions, the first frames after reset)
// the moments are garbage, so fall back to a 7x7 spatial estimate over
// depth/normal-compatible neighbours -- noisy pixels near an edge must not
// borrow variance from across it.

uniform Image texColor;    // reprojected color (rgb)
uniform Image texHistData; // moments + history length
uniform Image texNrmZ;     // guides

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	vec3 c  = Texel(texColor, uv).rgb;
	vec4 nz = Texel(texNrmZ, uv);

	if (nz.w > 1e5)
		return vec4(c, 0.0);

	vec4 hd = Texel(texHistData, uv);

	if (hd.z >= 4.0)
		return vec4(c, max(0.0, hd.y - hd.x * hd.x));

	// Spatial fallback. dFdx/dFdy give the local depth slope so the depth
	// tolerance scales with how slanted the surface is on screen.
	float zgrad = abs(dFdx(nz.w)) + abs(dFdy(nz.w)) + 1e-4;
	float m1 = 0.0, m2 = 0.0, wsum = 0.0;

	for (int dy = -3; dy <= 3; dy++)
	for (int dx = -3; dx <= 3; dx++) {
		vec2 q   = uv + vec2(dx, dy) / uRes;
		vec4 nzq = Texel(texNrmZ, q);
		if (nzq.w > 1e5) continue;

		float wz = exp(-abs(nz.w - nzq.w) / (zgrad * length(vec2(dx, dy)) + 1e-3));
		float wn = pow(max(dot(nz.xyz, nzq.xyz), 0.0), 32.0);
		float w  = wz * wn;

		float lq = luma(Texel(texColor, q).rgb);
		m1 += lq * w;
		m2 += lq * lq * w;
		wsum += w;
	}

	m1 /= max(wsum, 1e-4);
	m2 /= max(wsum, 1e-4);

	// Boosted: a spatial estimate from a 1-3 frame image understates how
	// wrong the pixel still is, and underestimated variance makes the
	// luminance weight clamp down exactly where filtering is needed most.
	return vec4(c, max(0.0, m2 - m1 * m1) * 4.0);
}
