// Denoiser pass 1 -- temporal reprojection.
//
// The old accumulation threw its history away the moment the camera moved.
// This pass instead *finds* the history: reconstruct the pixel's world
// position from the guide depth, project it through LAST frame's camera, and
// if the surface that was there last frame is the same surface (normal and
// depth agree), blend toward it. History survives camera motion; it dies only
// where it genuinely should -- disocclusions, screen edges, the first frame.
//
//   RT0  rgb = temporally accumulated demodulated radiance, a = unused
//   RT1  x = luminance mean, y = luminance second moment, z = history length
//
// The moments are what the variance pass turns into a noise estimate, which
// is what lets the spatial filter be aggressive exactly where the image is
// still noisy and gentle where it has converged.

uniform Image texCur;        // this frame's 1 spp demodulated radiance
uniform Image texNrmZ;       // this frame's first-hit normal + view depth
uniform Image texPrevNrmZ;   // last frame's normal + depth guide
uniform Image texHistColor;  // last frame's color history (first atrous output)
uniform Image texHistData;   // last frame's moments + history length
uniform Image texAlb;        // albedo + material id (for the metal clamp)

uniform vec3  uPrevCamPos;
uniform vec3  uPrevCamRight;
uniform vec3  uPrevCamUp;
uniform vec3  uPrevCamFwd;
uniform float uPrevTanHalf;
uniform float uPrevAspect;

uniform float uMaxHist;      // frames of history a diffuse pixel may keep
uniform float uMetalMaxHist; // ... and a mirror pixel, whose reprojection lies

// project(), but through last frame's camera. Same algebra as common.glsl.
vec3 projectPrev(vec3 wp) {
	vec3 d = wp - uPrevCamPos;
	float z = dot(d, uPrevCamFwd);
	vec2 ndc = vec2(dot(d, uPrevCamRight) / (z * uPrevTanHalf * uPrevAspect),
	                dot(d, uPrevCamUp)    / (z * uPrevTanHalf));
	return vec3(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, z);
}

void effect() {
	vec2 uv   = pixUV();
	vec4 curT = Texel(texCur, uv);
	vec3 cur  = curT.rgb;
	vec4 nz   = Texel(texNrmZ, uv);
	float l   = luma(cur);
	float id  = Texel(texAlb, uv).w;

	// No surface (the open face): nothing to reproject onto.
	if (nz.w > 1e5) {
		love_Canvases[0] = vec4(cur, 0.0);
		love_Canvases[1] = vec4(l, l * l, 1.0, id);
		return;
	}

	// World position back from the guide depth, then into last frame's screen.
	vec3 rd = rayDir(uv);
	float tPrim = nz.w / dot(rd, uCamFwd);
	vec3 P  = uCamPos + rd * tPrim;

	// A mirror's content does not live on its surface: it lives at the
	// reflected hit distance BEHIND it (exactly so, for a planar mirror;
	// close enough, for the sphere). Reprojecting that VIRTUAL point instead
	// of the surface is what makes the reflection track under camera motion
	// rather than smear.
	bool  isMetal = (id > 3.5 && id < 4.5);
	float reflT   = curT.a;
	bool  virt    = isMetal && reflT > 0.0;

	vec3 pr = projectPrev(virt ? uCamPos + rd * (tPrim + reflT) : P);

	bool valid = pr.z > 0.0
	          && pr.x > 0.0 && pr.x < 1.0
	          && pr.y > 0.0 && pr.y < 1.0;

	float histLen = 0.0;
	vec3  prevC   = vec3(0.0);
	vec2  prevM   = vec2(0.0);

	if (valid) {
		vec4 pnz = Texel(texPrevNrmZ, pr.xy);
		vec4 hd  = Texel(texHistData, pr.xy);
		if (virt) {
			// The virtual point lands on whichever pixel shows that reflected
			// content now; surface depth/normal tests are meaningless there.
			// Require the same mirror material instead -- the history id
			// rides in histData.w for exactly this.
			valid = pnz.w < 1e5 && hd.z > 0.5 && abs(hd.w - id) < 0.25;
		} else {
			// Same surface? The normal must agree and the depth we EXPECT at
			// that pixel must match the depth that was STORED there. A
			// cleared history buffer fails these, so reset needs no flag.
			valid = pnz.w < 1e5
			     && dot(nz.xyz, pnz.xyz) > 0.90
			     && abs(pr.z - pnz.w) < 0.02 * pr.z + 0.02
			     && hd.z > 0.5;
		}
		if (valid) {
			prevC   = Texel(texHistColor, pr.xy).rgb;
			prevM   = hd.xy;
			histLen = hd.z;
		}
	}

	float maxH = isMetal ? uMetalMaxHist : uMaxHist;

	histLen = min(histLen + 1.0, maxH);
	float a = 1.0 / histLen;

	love_Canvases[0] = vec4(mix(prevC, cur, a), 0.0);
	love_Canvases[1] = vec4(mix(prevM.x, l, a), mix(prevM.y, l * l, a), histLen, id);
}
