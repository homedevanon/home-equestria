shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, shadows_disabled;
// One autumn leaf pile (world/seasons/leaf_piles.gd, W2-SEAS-E 2026-11-08): a MultiMesh of LEAVES
// unit quads with identity transforms; every leaf's place comes from INSTANCE_ID here.
// - Untouched (kick.z == 0): the leaves lie in a mound around the node origin.
// - kick = (from.x, from.z, strength, 0) in pile space: the hoof came from `from`, so the leaves fly
//   away from it. kick_t runs 0 -> 1 over the flight (a Tween on the instance parameter, no
//   per-frame script): each leaf goes up ballistically, tumbles, drifts out and settles flat in a
//   scattered patch. kick_t stays 1 for the rest of the season (saved).
// - raked 0..1 pulls the scattered leaves back towards the mound (a rake, WP-F).
uniform sampler2D leaf_texture : hint_default_white, filter_linear_mipmap;
uniform float opacity_cutoff = 0.3333;
uniform float leaf_size = 0.13;
uniform float mound_radius = 0.8;
uniform float mound_height = 0.42;
uniform vec4 colour_a : source_color = vec4(0.93, 0.62, 0.16, 1.0);
uniform vec4 colour_b : source_color = vec4(0.8, 0.28, 0.08, 1.0);
uniform vec4 colour_c : source_color = vec4(0.5, 0.31, 0.13, 1.0);
uniform float backlight = 0.25;

instance uniform vec4 kick = vec4(0.0);
instance uniform float kick_t = 0.0;
instance uniform float raked = 0.0;
instance uniform float pile_seed = 0.0;

const vec4 WINDOWS[4] = vec4[4](
	vec4(0.316406, 0.000000, 0.097656, 0.074219),
	vec4(0.867188, 0.718750, 0.078125, 0.078125),
	vec4(0.468750, 0.863281, 0.078125, 0.070312),
	vec4(0.097656, 0.050781, 0.070312, 0.070312));

varying flat int leaf_window;
varying vec3 leaf_colour;

uint uhash(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

vec4 hash4(uint n) {
	uint a = uhash(n);
	uint b = uhash(a);
	uint c = uhash(b);
	uint d = uhash(c);
	return vec4(uvec4(a, b, c, d) & uvec4(65535u)) / 65535.0;
}

mat3 rot_y(float a) {
	float c = cos(a); float s = sin(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}

mat3 rot_x(float a) {
	float c = cos(a); float s = sin(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}

void vertex() {
	uint id = uint(INSTANCE_ID) + uhash(uint(pile_seed * 65535.0));
	vec4 h = hash4(id);
	vec4 k = hash4(id ^ 1431655765u);
	// The mound: leaves near its surface, denser towards the middle.
	float r = mound_radius * sqrt(h.x);
	float a = h.y * 6.2831853;
	vec2 xz = vec2(cos(a), sin(a)) * r;
	float rr = r / mound_radius;
	float top = mound_height * (1.0 - rr * rr);
	vec3 mound = vec3(xz.x, top * mix(0.55, 1.0, h.z) + 0.02, xz.y);
	float yaw = h.w * 6.2831853;
	// Lying along the mound's slope, plus some random tilt.
	float tilt = rr * 0.6 + (k.x - 0.5) * 0.7;
	vec3 p = mound;
	float strength = kick.z;
	if (strength > 0.0) {
		vec2 away = mound.xz - kick.xy;
		vec2 dir = normalize(away + (k.yz - 0.5) * 0.9 + vec2(0.0001, 0.0));
		float dist = 0.25 + strength * mix(0.5, 2.0, k.w);
		vec2 land = mix(mound.xz + dir * dist, mound.xz, clamp(raked, 0.0, 1.0));
		float land_y = 0.012 + k.x * 0.03;
		// Each leaf flies for its own share of the kick.
		float s = clamp(kick_t / mix(0.55, 1.0, h.x), 0.0, 1.0);
		float e = 1.0 - pow(1.0 - s, 2.2);
		float apex = strength * mix(0.35, 1.1, h.y) * (1.0 - rr * 0.4);
		p.xz = mix(mound.xz, land, e) + vec2(sin(s * 9.0 + k.y * 6.0), cos(s * 7.0 + k.z * 6.0)) * 0.08 * s * (1.0 - s);
		p.y = mix(mound.y, land_y, s) + 4.0 * apex * s * (1.0 - s);
		// Tumbling in the air, flat on the ground once it lands (unless raked back up).
		float spin = s * (1.0 - s) * strength * mix(6.0, 16.0, k.z);
		tilt = mix(tilt, (k.x - 0.5) * 0.25, s * (1.0 - raked)) + spin;
		yaw += s * strength * (k.w - 0.5) * 4.0;
	}
	mat3 basis = rot_y(yaw) * rot_x(-1.5707963 + tilt);
	float size = leaf_size * mix(0.75, 1.25, k.y);
	VERTEX = p + basis * (VERTEX * size);
	NORMAL = basis * NORMAL;
	leaf_window = int(k.w * 4.0) & 3;
	float pick = fract(h.z * 3.7 + k.x);
	vec3 colour = pick < 0.5 ? mix(colour_a.rgb, colour_b.rgb, pick * 2.0) : mix(colour_b.rgb, colour_c.rgb, pick * 2.0 - 1.0);
	leaf_colour = colour * mix(0.8, 1.08, k.z);
}

void fragment() {
	vec4 window = WINDOWS[leaf_window];
	float leaf = texture(leaf_texture, window.xy + UV * window.zw).r;
	if (leaf < opacity_cutoff) { discard; }
	ALBEDO = leaf_colour;
	BACKLIGHT = leaf_colour * backlight;
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
	SPECULAR = 0.1;
}
