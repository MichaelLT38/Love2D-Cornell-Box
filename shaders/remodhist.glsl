// Deferred denoiser, gather-feed -- turn the diffuse irradiance history back
// into radiance (multiply the albedo in) so the screen-space GI gather can
// read it. In denoised mode this replaces the running-mean accumulation as
// the gather's light source: it survives camera motion, so bounce light no
// longer collapses to one noisy frame the moment the camera moves.

uniform Image texHist;   // diffuse irradiance history (first atrous output)
uniform Image gAlb;

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	vec4 ab = Texel(gAlb, uv);
	vec3 alb = (ab.w > 4.5) ? vec3(1.0) : ab.rgb;
	return vec4(Texel(texHist, uv).rgb * alb, 1.0);
}
