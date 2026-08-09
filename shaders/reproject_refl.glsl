// Deferred denoiser, reflection leg -- temporal reprojection of the traced
// reflections by VIRTUAL depth. Reflected content does not live on the
// reflecting surface; it lives at the reflection hit distance behind it, and
// the SSR pass reports that distance in its alpha channel. Reprojecting the
// virtual point (exact for the planar floor, close enough for the sphere) is
// what keeps reflections locked in place under camera motion.
//
// Validity is by material identity, not surface depth -- the virtual point
// projects onto whatever pixel shows that content now, where surface tests
// are meaningless. Same trick the path traced denoiser uses for the sphere.
//
//   RT0  rgb = accumulated reflection, a = unused
//   RT1  x = luminance mean, y = second moment, z = history length, w = id

uniform Image texCurSSR;     // this frame's reflections, a = hit distance
uniform Image gAlb;          // material id
uniform Image texNrmZ;       // packed current guides
uniform Image texPrevNrmZ;
uniform Image texHistColor;  // reflection history
uniform Image texHistData;

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
	vec2 uv   = pixUV();
	vec4 curT = Texel(texCurSSR, uv);
	vec3 cur  = curT.rgb;
	float hitT = curT.a;
	vec4 nz   = Texel(texNrmZ, uv);
	float id  = Texel(gAlb, uv).w;
	float l   = luma(cur);

	if (nz.w > 1e5) {
		love_Canvases[0] = vec4(cur, 0.0);
		love_Canvases[1] = vec4(l, l * l, 1.0, id);
		return;
	}

	vec3 rd = rayDir(uv);
	float tPrim = nz.w / dot(rd, uCamFwd);

	// hitT = 0 means no reflection here; the signal is black and plain
	// surface reprojection keeps it stable.
	vec3 Prep = uCamPos + rd * (tPrim + hitT);
	vec3 pr = projectPrev(Prep);

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
		     && hd.z > 0.5
		     && abs(hd.w - id) < 0.25;   // same reflective surface
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
