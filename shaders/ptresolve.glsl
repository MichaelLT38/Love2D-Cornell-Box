// Resolves the additively-accumulated path tracer target.
//
// The sample count comes in as a uniform rather than out of the target's
// alpha: LOVE's "add" blend mode sets srcFactorA to ZERO, so it deliberately
// leaves destination alpha untouched and alpha can never act as a counter.

uniform Image ptTex;
uniform float uExposure;
uniform float uSamples;

vec4 effect(vec4 vcol, Image tex, vec2 tc, vec2 sc) {
	vec3 sum = Texel(ptTex, pixUV()).rgb;
	vec3 c   = uSamples > 0.0 ? sum / uSamples : vec3(0.0);
	return vec4(toSRGB(acesFilm(c * uExposure)), 1.0);
}
