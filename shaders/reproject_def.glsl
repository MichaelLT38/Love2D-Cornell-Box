// Deferred denoiser pass 1 -- temporal reprojection of the merged diffuse
// signal (direct lighting + screen-space GI), demodulated by albedo so the
// filter chain works on irradiance.
//
// Same skeleton as the path tracer's reproject.glsl: reconstruct the pixel's
// world position from the guide depth, project it through LAST frame's
// camera, and blend toward the history found there if it belonged to the
// same surface. The differences: the noisy signal arrives as two lit-color
// textures instead of tracer MRT output, and there is no virtual-depth
// branch -- reflections get their own chain.
//
//   RT0  rgb = temporally accumulated diffuse irradiance, a = unused
//   RT1  x = luminance mean, y = second moment, z = history length, w = id

uniform Image texCurDirect;  // this frame's litD (lit color, albedo baked in)
uniform Image texCurGI;      // this frame's litG (AO already applied)
uniform Image gAlb;          // albedo + material id, for demodulation
uniform Image texNrmZ;       // packed current guides (normal, viewZ)
uniform Image texPrevNrmZ;   // last frame's guides
uniform Image texHistColor;  // last frame's irradiance history
uniform Image texHistData;   // last frame's moments + history length + id

uniform vec3  uPrevCamPos;
uniform vec3  uPrevCamRight;
uniform vec3  uPrevCamUp;
uniform vec3  uPrevCamFwd;
uniform float uPrevTanHalf;
uniform float uPrevAspect;

uniform float uMaxHist;

vec3 projectPrev(vec3 wp) {
	vec3 d = wp - uPrevCamPos;
	float z = dot(d, uPrevCamFwd);
	vec2 ndc = vec2(dot(d, uPrevCamRight) / (z * uPrevTanHalf * uPrevAspect),
	                dot(d, uPrevCamUp)    / (z * uPrevTanHalf));
	return vec3(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, z);
}

void effect() {
	vec2 uv = pixUV();
	vec4 nz = Texel(texNrmZ, uv);
	vec4 ab = Texel(gAlb, uv);
	float id = ab.w;

	// Demodulate: the emitter's albedo is black (its light is emission, not
	// reflection), so it keeps an albedo of 1 -- the same convention the
	// path tracer's denoiser uses.
	vec3 alb = (id > 4.5) ? vec3(1.0) : max(ab.rgb, vec3(1e-3));
	vec3 cur = (Texel(texCurDirect, uv).rgb + Texel(texCurGI, uv).rgb) / alb;
	float l  = luma(cur);

	if (nz.w > 1e5) {                     // background
		love_Canvases[0] = vec4(cur, 0.0);
		love_Canvases[1] = vec4(l, l * l, 1.0, id);
		return;
	}

	vec3 rd = rayDir(uv);
	vec3 P  = uCamPos + rd * (nz.w / dot(rd, uCamFwd));
	vec3 pr = projectPrev(P);

	bool valid = pr.z > 0.0
	          && pr.x > 0.0 && pr.x < 1.0
	          && pr.y > 0.0 && pr.y < 1.0;

	float histLen = 0.0;
	vec3  prevC   = vec3(0.0);
	vec2  prevM   = vec2(0.0);

	if (valid) {
		vec4 pnz = Texel(texPrevNrmZ, pr.xy);
		vec4 hd  = Texel(texHistData, pr.xy);
		valid = pnz.w < 1e5
		     && dot(nz.xyz, pnz.xyz) > 0.90
		     && abs(pr.z - pnz.w) < 0.02 * pr.z + 0.02
		     && hd.z > 0.5
		     && abs(hd.w - id) < 0.25;   // same material, not a neighbour's history
		if (valid) {
			prevC   = Texel(texHistColor, pr.xy).rgb;
			prevM   = hd.xy;
			histLen = hd.z;
		}
	}

	histLen = min(histLen + 1.0, uMaxHist);
	float a = 1.0 / histLen;

	love_Canvases[0] = vec4(mix(prevC, cur, a), 0.0);
	love_Canvases[1] = vec4(mix(prevM.x, l, a), mix(prevM.y, l * l, a), histLen, id);
}
