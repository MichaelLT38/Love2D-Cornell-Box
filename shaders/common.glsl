// =====================================================================
//  common.glsl
//  Shared scene description, camera projection, RNG and BRDF helpers.
//  main.lua prepends this to every pixel shader in the pipeline, so the
//  path tracer and the real-time passes are guaranteed to be looking at
//  exactly the same geometry.
// =====================================================================

#define PI      3.141592653589793
#define INV_PI  0.3183098861837907

// ------------------------------------------------------------- camera --
uniform vec2  uRes;        // resolution of the *current* render target
uniform vec3  uCamPos;
uniform vec3  uCamRight;
uniform vec3  uCamUp;
uniform vec3  uCamFwd;
uniform float uTanHalf;    // tan(fov/2)
uniform float uAspect;
uniform float uFrame;      // frame index, used to decorrelate the RNG

// G-buffer position target: xyz = world position, w = view depth (1e6 = miss).
// Declared here because the screen-space ray marcher below needs it.
uniform Image gPos;

vec2 pixUV() { return love_PixelCoord.xy / uRes; }

vec3 rayDir(vec2 uv) {
	vec2 ndc = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
	return normalize(uCamFwd
	               + uCamRight * (ndc.x * uTanHalf * uAspect)
	               + uCamUp    * (ndc.y * uTanHalf));
}

// World position -> (uv, view depth). Exact inverse of rayDir, which is what
// lets the screen-space passes get away without any matrix uniforms.
vec3 project(vec3 wp) {
	vec3 d = wp - uCamPos;
	float z = dot(d, uCamFwd);
	vec2 ndc = vec2(dot(d, uCamRight) / (z * uTanHalf * uAspect),
	                dot(d, uCamUp)    / (z * uTanHalf));
	return vec3(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, z);
}

// ---------------------------------------------------------------- RNG --
uint uhash(uint x) {
	x ^= x >> 16u; x *= 0x7feb352du;
	x ^= x >> 15u; x *= 0x846ca68bu;
	x ^= x >> 16u; return x;
}

float rnd(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint r = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	r = (r >> 22u) ^ r;
	return float(r) * 2.3283064365387e-10;
}

// Two rnd() calls inside one expression is undefined with an inout parameter -
// the compiler may hand both the same value. Always sequence them.
vec2 rnd2(inout uint s) { float a = rnd(s); float b = rnd(s); return vec2(a, b); }

uint seedPixel(vec2 px, float frame) {
	return uhash(uint(px.x) + 1973u * uint(px.y) + 9277u * uint(frame) + 1u);
}

// Duff et al. branchless orthonormal basis.
void basis(vec3 n, out vec3 t, out vec3 b) {
	float s = n.z >= 0.0 ? 1.0 : -1.0;
	float a = -1.0 / (s + n.z);
	float d = n.x * n.y * a;
	t = vec3(1.0 + s * n.x * n.x * a, s * d, -s * n.x);
	b = vec3(d, s + n.y * n.y * a, -n.y);
}

vec3 cosineHemisphere(vec3 n, float u1, float u2) {
	float r = sqrt(u1), phi = 2.0 * PI * u2;
	vec3 t, b; basis(n, t, b);
	return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1.0 - u1)));
}

vec3 sampleGGX(vec3 n, float rough, float u1, float u2) {
	float a = max(rough * rough, 1e-4);
	float phi = 2.0 * PI * u1;
	float ct = sqrt(clamp((1.0 - u2) / (1.0 + (a * a - 1.0) * u2), 0.0, 1.0));
	float st = sqrt(max(0.0, 1.0 - ct * ct));
	vec3 t, b; basis(n, t, b);
	return normalize(t * (st * cos(phi)) + b * (st * sin(phi)) + n * ct);
}

// --------------------------------------------------------------- BRDF --
float D_GGX(float NoH, float a) {
	float a2 = a * a;
	float d = (NoH * a2 - NoH) * NoH + 1.0;
	return a2 / max(PI * d * d, 1e-8);
}

// Height-correlated Smith visibility (already contains the 1/(4 NoL NoV)).
float V_SmithGGX(float NoV, float NoL, float a) {
	float a2 = a * a;
	float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
	float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
	return 0.5 / max(gv + gl, 1e-6);
}

// Smith geometry term (not the visibility form) - used by the path tracer.
float G_SmithGGX(float NoV, float NoL, float a) {
	float a2 = a * a;
	float gv = 2.0 * NoV / max(NoV + sqrt(a2 + (1.0 - a2) * NoV * NoV), 1e-6);
	float gl = 2.0 * NoL / max(NoL + sqrt(a2 + (1.0 - a2) * NoL * NoL), 1e-6);
	return gv * gl;
}

vec3 F_Schlick(vec3 f0, float u) {
	float m = clamp(1.0 - u, 0.0, 1.0);
	float m2 = m * m;
	return f0 + (1.0 - f0) * (m2 * m2 * m);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// ---------------------------------------------------------- tonemapping --
vec3 acesFilm(vec3 x) {
	const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
	return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

vec3 toSRGB(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }

// ================================================================ SCENE =
//  The Cornell Box. Walls are modelled as real slabs (not an inverted box)
//  so the SDF stays valid with the camera sitting outside the room.
//  Interior spans [-1,1] on every axis; the +Z face is open.
// =======================================================================

#define M_WHITE 0.0
#define M_RED   1.0
#define M_GREEN 2.0
#define M_FLOOR 3.0
#define M_METAL 4.0
#define M_LIGHT 5.0

const vec3 LIGHT_C = vec3(0.0, 0.982, -0.04);   // centre of the ceiling quad
const vec2 LIGHT_H = vec2(0.33, 0.27);          // half extents in x / z
const vec3 LIGHT_N = vec3(0.0, -1.0, 0.0);
const vec3 LIGHT_E = vec3(1.0, 0.855, 0.62) * 34.0;
#define LIGHT_AREA (4.0 * LIGHT_H.x * LIGHT_H.y)

// Classic Cornell Box reflectances, converted from the original spectra.
void getMaterial(float id, out vec3 albedo, out float rough, out float metal, out vec3 emis) {
	albedo = vec3(0.725, 0.710, 0.680); rough = 1.0; metal = 0.0; emis = vec3(0.0);
	if      (id < 0.5) { }                                                              // white walls
	else if (id < 1.5) { albedo = vec3(0.630, 0.065, 0.050); }                          // left  (red)
	else if (id < 2.5) { albedo = vec3(0.140, 0.450, 0.091); }                          // right (green)
	else if (id < 3.5) { albedo = vec3(0.700, 0.690, 0.670); rough = 0.20; }            // polished floor
	else if (id < 4.5) { albedo = vec3(0.960, 0.940, 0.890); rough = 0.06; metal = 1.0; } // chrome sphere
	else               { albedo = vec3(0.0); emis = LIGHT_E; }                          // emitter
}

float sdBox(vec3 p, vec3 b) {
	vec3 q = abs(p) - b;
	return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

vec3 rotY(vec3 p, float a) {
	float c = cos(a), s = sin(a);
	return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

vec2 opU(vec2 a, vec2 b) { return (a.x < b.x) ? a : b; }

vec2 mapEx(vec3 p, bool withLight) {
	vec2 r = vec2(1e9, -1.0);
	r = opU(r, vec2(sdBox(p - vec3( 0.00, -1.05,  0.00), vec3(1.10, 0.05, 1.10)), M_FLOOR)); // floor
	r = opU(r, vec2(sdBox(p - vec3( 0.00,  1.05,  0.00), vec3(1.10, 0.05, 1.10)), M_WHITE)); // ceiling
	r = opU(r, vec2(sdBox(p - vec3( 0.00,  0.00, -1.05), vec3(1.10, 1.10, 0.05)), M_WHITE)); // back
	r = opU(r, vec2(sdBox(p - vec3(-1.05,  0.00,  0.00), vec3(0.05, 1.00, 1.05)), M_RED));   // left
	r = opU(r, vec2(sdBox(p - vec3( 1.05,  0.00,  0.00), vec3(0.05, 1.00, 1.05)), M_GREEN)); // right

	// tall rotated block
	r = opU(r, vec2(sdBox(rotY(p - vec3(-0.38, -0.40, -0.30),  0.29), vec3(0.28, 0.60, 0.28)), M_WHITE));
	// short rotated block
	r = opU(r, vec2(sdBox(rotY(p - vec3( 0.38, -0.70,  0.26), -0.32), vec3(0.30, 0.30, 0.30)), M_WHITE));
	// chrome sphere resting on the short block
	r = opU(r, vec2(length(p - vec3(0.38, -0.14, 0.26)) - 0.26, M_METAL));

	if (withLight) {
		r = opU(r, vec2(sdBox(p - LIGHT_C, vec3(LIGHT_H.x, 0.012, LIGHT_H.y)), M_LIGHT));
	}
	return r;
}

vec2  map   (vec3 p) { return mapEx(p, true);    }
float mapOcc(vec3 p) { return mapEx(p, false).x; } // shadow rays must ignore the emitter

bool trace(vec3 ro, vec3 rd, float tmax, out float t, out float id) {
	t = 0.0; id = -1.0;
	for (int i = 0; i < 160; i++) {
		vec2 h = map(ro + rd * t);
		if (h.x < 0.0006 * max(t, 1.0)) { id = h.y; return true; }
		t += h.x;
		if (t > tmax) break;
	}
	return false;
}

vec3 calcNormal(vec3 p) {
	const vec2 k = vec2(1.0, -1.0);
	const float h = 0.0006;
	return normalize(k.xyy * map(p + k.xyy * h).x +
	                 k.yyx * map(p + k.yyx * h).x +
	                 k.yxy * map(p + k.yxy * h).x +
	                 k.xxx * map(p + k.xxx * h).x);
}

float shadowRay(vec3 ro, vec3 rd, float tmax, float k) {
	float res = 1.0, t = 0.008;
	for (int i = 0; i < 56; i++) {
		float h = mapOcc(ro + rd * t);
		if (h < 0.0008) return 0.0;
		res = min(res, k * h / t);
		t += clamp(h, 0.008, 0.25);
		if (t > tmax) break;
	}
	return clamp(res, 0.0, 1.0);
}

// ------------------------------------------- screen-space ray marching --
// Walks a world-space ray forward, re-projecting each step into screen space
// and testing it against the depth stored in the G-buffer. This is the shared
// core of both SSGI and SSR: it is the *only* visibility they have, which is
// exactly the limitation the path-traced reference exists to expose.
bool ssTrace(vec3 ro, vec3 rd, float maxDist, int steps, float thickness,
             float jitter, out vec2 hitUV, out vec3 hitP)
{
	hitUV = vec2(0.0); hitP = vec3(0.0);
	for (int i = 1; i <= 48; i++) {
		if (i > steps) break;
		float ti = maxDist * (float(i) - jitter) / float(steps);
		vec3 pr = project(ro + rd * ti);
		if (pr.z <= 0.0) return false;
		if (pr.x < 0.0 || pr.x > 1.0 || pr.y < 0.0 || pr.y > 1.0) return false;

		vec4 g = Texel(gPos, pr.xy);
		float diff = pr.z - g.w;
		if (diff > 0.0015 && diff < thickness) {
			hitUV = pr.xy; hitP = g.xyz;
			return true;
		}
	}
	return false;
}
