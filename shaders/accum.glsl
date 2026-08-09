// Pass 5 - temporal accumulation. All three stochastic buffers converge in
// lockstep. uBlend is 1/n while the camera is still (a true running mean) and
// snaps back to 1 the moment anything moves.

uniform Image curDirect, curGI, curSSR;
uniform Image prvDirect, prvGI, prvSSR;
uniform float uBlend;

void effect() {
	vec2 uv = pixUV();
	love_Canvases[0] = vec4(mix(Texel(prvDirect, uv).rgb, Texel(curDirect, uv).rgb, uBlend), 1.0);
	love_Canvases[1] = vec4(mix(Texel(prvGI,     uv).rgb, Texel(curGI,     uv).rgb, uBlend), 1.0);
	love_Canvases[2] = vec4(mix(Texel(prvSSR,    uv).rgb, Texel(curSSR,    uv).rgb, uBlend), 1.0);
}
