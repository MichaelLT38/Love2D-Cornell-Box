// Deferred denoiser, AO leg -- temporal reprojection of the (already
// spatially blurred) ambient occlusion. AO is scalar and low-frequency, so
// this is the whole treatment: no wavelet chain, just history carried
// through camera motion with the same reprojection and validity tests as
// the color signals.
//
//   out: r = stabilized AO (what the light pass and composite consume)
//        g = history length / 64
//
// This texture is BOTH the output and next frame's history.

uniform Image texCurAO;      // this frame's blurred AO
uniform Image texNrmZ;       // packed current guides (normal, viewZ)
uniform Image texPrevNrmZ;   // last frame's guides
uniform Image texAOHist;     // last frame's output of this pass

uniform vec3  uPrevCamPos;
uniform vec3  uPrevCamRight;
uniform vec3  uPrevCamUp;
uniform vec3  uPrevCamFwd;
uniform float uPrevTanHalf;
uniform float uPrevAspect;

vec3 projectPrev(vec3 wp) {
	vec3 d = wp - uPrevCamPos;
	float z = dot(d, uPrevCamFwd);
	vec2 ndc = vec2(dot(d, uPrevCamRight) / (z * uPrevTanHalf * uPrevAspect),
	                dot(d, uPrevCamUp)    / (z * uPrevTanHalf));
	return vec3(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, z);
}

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv  = pixUV();
	vec4 nz  = Texel(texNrmZ, uv);
	float ao = Texel(texCurAO, uv).r;

	if (nz.w > 1e5)
		return vec4(1.0, 0.0, 0.0, 1.0);

	vec3 rd = rayDir(uv);
	vec3 P  = uCamPos + rd * (nz.w / dot(rd, uCamFwd));
	vec3 pr = projectPrev(P);

	float n = 0.0;
	float histAO = 0.0;

	if (pr.z > 0.0 && pr.x > 0.0 && pr.x < 1.0 && pr.y > 0.0 && pr.y < 1.0) {
		vec4 pnz = Texel(texPrevNrmZ, pr.xy);
		if (pnz.w < 1e5
		    && dot(nz.xyz, pnz.xyz) > 0.90
		    && abs(pr.z - pnz.w) < 0.02 * pr.z + 0.02) {
			vec4 h = Texel(texAOHist, pr.xy);
			histAO = h.r;
			n = h.g * 64.0;
		}
	}

	n = min(n + 1.0, 32.0);
	float a = 1.0 / n;

	return vec4(mix(histAO, ao, a), n / 64.0, 0.0, 1.0);
}
