// Pass 6 - composite, debug views and tonemap. Runs at window resolution and
// samples the (possibly lower-res) buffers with normalised uv.

uniform Image gNrm;
uniform Image gAlb;
uniform Image texAO;
uniform Image accDirect, accGI, accSSR;

uniform float uExposure;
uniform float uMode;      // see the switch below
uniform float uSplit;     // < 0 disables; otherwise screen-x of the wipe
uniform float uAOEnable;
uniform float uSSREnable;

// Denoised deferred mode: the diffuse terms (direct + GI) arrive as one
// FILTERED irradiance texture and get the albedo multiplied back here.
uniform Image texDnDiff;
uniform Image texDnSSR;
uniform float uDnDeferred;

vec3 shade(vec2 uv, bool full) {
	if (uDnDeferred > 0.5) {
		if (!full) return Texel(accDirect, uv).rgb;   // wipe compares raw direct
		vec4 ab  = Texel(gAlb, uv);
		vec3 alb = (ab.w > 4.5) ? vec3(1.0) : ab.rgb;
		vec3 ssr = (uSSREnable > 0.5) ? Texel(texDnSSR, uv).rgb : vec3(0.0);
		return Texel(texDnDiff, uv).rgb * alb + ssr;
	}
	vec3 ssr = (full && uSSREnable > 0.5) ? Texel(accSSR, uv).rgb : vec3(0.0);
	vec3 direct = Texel(accDirect, uv).rgb;
	vec3 gi     = Texel(accGI,     uv).rgb;
	if (!full) return direct;
	return direct + gi + ssr;
}

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	int  mode = int(uMode + 0.5);

	vec4  g  = Texel(gPos, uv);
	bool  bg = g.w > 1e5;

	vec3 outc;

	if (mode == 1) {                                   // direct only
		outc = Texel(accDirect, uv).rgb;
	} else if (mode == 2) {                            // indirect only
		outc = Texel(accGI, uv).rgb;
	} else if (mode == 3) {                            // ambient occlusion
		float ao = bg ? 1.0 : Texel(texAO, uv).r;
		return vec4(vec3(ao), 1.0);
	} else if (mode == 4) {                            // reflections only
		outc = Texel(accSSR, uv).rgb;
	} else if (mode == 5) {                            // albedo
		return vec4(bg ? vec3(0.02) : toSRGB(Texel(gAlb, uv).rgb), 1.0);
	} else if (mode == 6) {                            // world normals
		return vec4(bg ? vec3(0.02) : Texel(gNrm, uv).xyz * 0.5 + 0.5, 1.0);
	} else if (mode == 7) {                            // linear depth
		float d = bg ? 0.0 : 1.0 - clamp((g.w - 1.5) / 3.5, 0.0, 1.0);
		return vec4(vec3(d), 1.0);
	} else if (mode == 8) {                            // roughness
		return vec4(bg ? vec3(0.02) : vec3(Texel(gNrm, uv).w), 1.0);
	} else {                                           // 0 = full beauty
		bool full = true;
		if (uSplit >= 0.0) full = (uv.x < uSplit);
		outc = shade(uv, full);
	}

	if (bg) outc = vec3(0.012, 0.013, 0.016);

	vec3 col = toSRGB(acesFilm(outc * uExposure));

	// Thin marker line for the A/B wipe.
	if (mode == 0 && uSplit >= 0.0) {
		float d = abs(uv.x - uSplit) * uRes.x;
		col = mix(vec3(1.0, 0.85, 0.3), col, smoothstep(0.0, 1.2, d - 0.5));
	}
	return vec4(col, 1.0);
}
