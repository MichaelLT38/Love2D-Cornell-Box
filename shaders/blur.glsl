// Depth-aware separable blur, used to clean up the noisy AO buffer without
// bleeding occlusion across silhouettes.

uniform Image src;
uniform vec2  uDir;      // (1,0) then (0,1), in pixels
uniform float uRadius;

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	vec2 texel = 1.0 / uRes;
	float centerZ = Texel(gPos, uv).w;

	vec4  sum = vec4(0.0);
	float wsum = 0.0;
	int   r = int(uRadius);

	for (int i = -6; i <= 6; i++) {
		if (i < -r || i > r) continue;
		vec2 o = uv + uDir * texel * float(i);
		if (o.x < 0.0 || o.x > 1.0 || o.y < 0.0 || o.y > 1.0) continue;

		float z = Texel(gPos, o).w;
		float dw = exp(-abs(z - centerZ) * 24.0);            // depth similarity
		float sw = exp(-float(i * i) / (2.0 * 9.0));         // spatial gaussian
		float w  = dw * sw;

		sum  += Texel(src, o) * w;
		wsum += w;
	}
	return wsum > 0.0 ? sum / wsum : Texel(src, uv);
}
