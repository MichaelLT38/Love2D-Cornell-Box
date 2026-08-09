// Deferred denoiser pass 0 -- pack the G-buffer's normal and view depth into
// the (normal.xyz, viewZ) layout every shared denoiser pass consumes. One
// cheap blit, and in exchange variance.glsl and atrous.glsl run over the
// deferred pipeline byte-for-byte unchanged. The packed target is ping-ponged,
// which is also what gives reprojection its previous-frame guides.

uniform Image gNrm;

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec2 uv = pixUV();
	vec4 g = Texel(gPos, uv);
	vec3 n = normalize(Texel(gNrm, uv).xyz);
	return vec4(n, g.w);   // g.w is view depth, 1e6 on miss -- the PT convention
}
