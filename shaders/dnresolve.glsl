// Denoiser pass 4 -- remodulate, tonemap, and the debug views.
//
// The whole pipeline filtered IRRADIANCE (radiance with the first-hit albedo
// divided out), so texture detail was never something the filter had to
// preserve. Multiplying the albedo back in is what makes the walls red and
// green again.

uniform Image texColor;    // filtered irradiance (final atrous output)
uniform Image texAlb;      // albedo + material id
uniform Image texRaw;      // this frame's raw 1 spp (demodulated)
uniform Image texHistData; // moments + history length
uniform Image texNrmZ;     // guides
uniform float uExposure;
uniform float uDnView;     // 0 final | 1 raw 1spp | 2 variance | 3 history
                           // 4 albedo | 5 normals

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	int  v  = int(uDnView + 0.5);

	if (v == 1) {
		vec3 c = Texel(texRaw, uv).rgb * Texel(texAlb, uv).rgb;
		return vec4(toSRGB(acesFilm(c * uExposure)), 1.0);
	}
	if (v == 2) {   // remaining variance, sqrt for visibility
		float s = sqrt(max(Texel(texColor, uv).a, 0.0));
		return vec4(vec3(clamp(s, 0.0, 1.0)), 1.0);
	}
	if (v == 3) {   // history length: black = fresh, white = full
		float h = Texel(texHistData, uv).z / 64.0;
		return vec4(vec3(clamp(h, 0.0, 1.0)), 1.0);
	}
	if (v == 4)
		return vec4(toSRGB(Texel(texAlb, uv).rgb), 1.0);
	if (v == 5)
		return vec4(Texel(texNrmZ, uv).xyz * 0.5 + 0.5, 1.0);

	vec3 c = Texel(texColor, uv).rgb * Texel(texAlb, uv).rgb;
	return vec4(toSRGB(acesFilm(c * uExposure)), 1.0);
}
