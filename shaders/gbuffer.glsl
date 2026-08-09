// Pass 1 - G-buffer. Raymarches the SDF once and lays down everything the
// screen-space passes need. MRT via love_Canvases[] (LOVE 11 + glsl3).
//
//   RT0  xyz = world position, w = view depth (1e6 on miss)
//   RT1  xyz = world normal,   w = roughness
//   RT2  rgb = albedo,         w = material id

uniform float uJitter;   // sub-pixel jitter amount -> free temporal AA

void effect() {
	uint jseed = seedPixel(love_PixelCoord.xy, uFrame);
	vec2 uv = (love_PixelCoord.xy + (rnd2(jseed) - 0.5) * uJitter) / uRes;
	vec3 rd = rayDir(uv);

	float t, id;
	bool hit = trace(uCamPos, rd, 40.0, t, id);

	vec3 P = uCamPos + rd * t;
	vec3 N = hit ? calcNormal(P) : -rd;

	vec3 albedo, emis; float rough, metal;
	getMaterial(hit ? id : 0.0, albedo, rough, metal, emis);

	float vz = hit ? dot(P - uCamPos, uCamFwd) : 1e6;

	love_Canvases[0] = vec4(P, vz);
	love_Canvases[1] = vec4(N, rough);
	love_Canvases[2] = vec4(albedo, hit ? id : -1.0);
}
