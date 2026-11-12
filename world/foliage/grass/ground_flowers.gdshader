// Wildflowers (dev 2026-09-23): cartoon 2.5D flowers in patches through the grass and in a
// band along roads. Same terrain sampling as ground_grass.gdshader: every grid cell may hold
// one flower, placed, coloured and sized from world hashes, found on the GPU from the
// Terrain3D maps. Only on grass, never on the path itself, under buildings or on slopes.
// A flower is a thin stem plus a camera-facing head whose petals are drawn in the fragment
// shader (five rounded petals, a centre and an ink rim), so it reads flat like the show.
shader_type spatial;
render_mode cull_disabled, world_vertex_coords, specular_disabled, depth_draw_opaque;


// Session-owned deployed cloth footprints. Local materials only; removed by token.
uniform sampler2D exclusion_rects : filter_nearest, repeat_disable;
uniform int exclusion_count = 0;
uniform vec4 exclusion_bounds;
bool deployed_footprint(vec2 xz) {
	if (exclusion_count == 0 || any(lessThan(xz,exclusion_bounds.xy)) || any(greaterThan(xz,exclusion_bounds.zw))) return false;
	for (int i = 0; i < exclusion_count; i++) {
		vec4 rect = texelFetch(exclusion_rects, ivec2(0,i), 0);
		vec4 inv = texelFetch(exclusion_rects, ivec2(1,i), 0);
		vec2 delta = xz - rect.xy;
		vec2 local = vec2(dot(inv.xy,delta),dot(inv.zw,delta));
		if (all(lessThanEqual(abs(local),rect.zw))) return true;
	}
	return false;
}

uniform sampler2DArray height_maps : filter_nearest, repeat_disable;
uniform sampler2DArray control_maps : filter_nearest, repeat_disable;
uniform int region_map[1024];
uniform float region_size = 1024.0;
uniform float vertex_spacing = 1.0;
uniform sampler2D block_mask : filter_linear, repeat_disable;
uniform vec4 block_rect;
uniform bool block_enabled = false;
uniform float id_density[32];
uniform float spacing = 0.4;
uniform float inner_radius = 0.0;
uniform float outer_radius = 32.0;
uniform float fade_out = 8.0;
uniform float sea_level = -80.0;
uniform float road_chance = 0.2;    // inside a flowering stretch of road verge    // cells beside a road that hold a flower
uniform float patch_chance = 0.28;  // inside a patch: patches are clusters, rare across the grass  // cells inside a meadow patch
uniform float stray_chance = 0.0;
// season_flowers: spring many, summer some, autumn few, winter none. It and the snow cover come from
// res://world/seasons/season.gdshaderinc (season_state.gd writes them).
#include "res://world/seasons/season.gdshaderinc"

// Spring (dev 2026-11-10: "we need a FUCKTon of blooming flowers"). Outside spring the meadow has
// its few patches and road verges. In spring whole drifts flower: a few big swathes, each some
// 50 to 100 m across and covering about a sixth of the meadow, where up to SPRING_DRIFT of the
// cells hold a flower (about three to the square metre); between the drifts the grass is nearly
// bare of them (dev 2026-11-10: "WAY too many ... more frequent in bigger patches"). A quarter
// of that on the forest floor. They come up over
// the first half of spring (season_spring, the season's day ramp): a new flower is a small bud
// and opens over the next days. Spring flowers stand taller than the grass, come in three kinds
// (five petals, daisy, tulip) and their colours run in soft bands a few metres wide instead of
// one colour per 3.5 m square. LOOK_SPRING_FLOWERS = 0.0 restores the patches-only meadow.
const float LOOK_SPRING_FLOWERS = 1.0;
const float SPRING_DRIFT = 0.5;
const float SPRING_SCATTER = 0.004;
// The drift rule itself is shared with the grass and the ground (season.gdshaderinc).
float spring_bloom() { return LOOK_SPRING_FLOWERS <= 0.0 ? 0.0 : season_flower_bloom(); }

varying vec3 v_petal;
varying flat float v_kind;
varying vec3 v_centre;
varying vec3 v_stem;
varying float v_head;
varying vec3 v_normal;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}
float value_noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}
ivec3 texel(ivec2 t) {
	ivec2 loc = ivec2(floor(vec2(t) / region_size));
	ivec2 p = loc + 16;
	if (any(lessThan(p, ivec2(0))) || any(greaterThanEqual(p, ivec2(32)))) return ivec3(0, 0, -1);
	return ivec3(t - loc * int(region_size), region_map[p.y * 32 + p.x] - 1);
}
float height_at(ivec2 t) {
	ivec3 c = texel(t);
	return c.z < 0 ? -1e6 : texelFetch(height_maps, c, 0).r;
}
float ground_height(vec2 xz) {
	vec2 uv = xz / vertex_spacing;
	vec2 f = fract(uv); ivec2 t = ivec2(floor(uv));
	float a = height_at(t), b = height_at(t + ivec2(1, 0)), c = height_at(t + ivec2(0, 1)), d = height_at(t + ivec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
// Terrain texture id under a point (the dominant of base/overlay), -1 off the map or in a hole.
int ground_id(vec2 xz) {
	ivec3 ct = texel(ivec2(floor(xz / vertex_spacing + 0.5)));
	if (ct.z < 0) return -1;
	uint c = floatBitsToUint(texelFetch(control_maps, ct, 0).r);
	if (((c >> 2u) & 1u) == 1u) return -1;
	float blend = float((c >> 14u) & 255u) / 255.0;
	return blend > 0.5 ? int((c >> 22u) & 31u) : int((c >> 27u) & 31u);
}
bool is_road(int id) { return id == 1 || id == 4 || id == 5; }
// Rollback switch (perf 0.1.0 GPU pass): the road-verge search (up to 16 control reads per
// vertex) runs only where a verge flower could still win: where road_chance * verge exceeds the
// cell's other chance and the cell's roll is under it. Elsewhere road_near could not change the
// final chance test (every later factor is monotonic and at most 1, the glade term does not
// depend on it), so the same cells flower.
const bool FLOWER_ROAD_LATE = true;

const vec3 PALETTE[8] = vec3[8](
	vec3(1.0, 0.3, 0.62), vec3(1.0, 0.8, 0.08), vec3(0.98, 0.95, 0.9), vec3(0.62, 0.36, 1.0),
	vec3(0.3, 0.55, 1.0), vec3(1.0, 0.2, 0.22), vec3(1.0, 0.5, 0.1), vec3(0.95, 0.45, 0.9));

#ifdef DEPLOYED_FRAGMENT_CLIP
varying vec2 deployed_world_xz;
#endif

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec2 cell = origin.xz;
	vec2 xz = cell + (hash22(cell * 1.7 + 4.1) - 0.5) * spacing * 0.9;
	float dist = distance(xz, CAMERA_POSITION_WORLD.xz);
	bool keep = dist > inner_radius && dist < outer_radius;
	// Most cells hold no flower: decide that first, before any terrain read (2026-10-23 grass
	// cost pass). The roll is the one tested below and `most` bounds every chance it can face,
	// so the result is unchanged. Outside the ring the flower would be grown to zero anyway.
	float roll = hash12(cell * 0.93 + 2.7);
	float most = max(max(stray_chance, patch_chance), max(road_chance, 0.30)) * season_flowers;
	float bloom = spring_bloom();
	most = max(most, SPRING_DRIFT * bloom);
	float spring_chance = 0.0;
	bool maybe = roll < most && keep;
	float y = maybe ? ground_height(xz) : 0.0;
	int id = maybe ? ground_id(xz) : -1;
	float chance = 0.0;
	if (keep && id >= 0 && id_density[id] > 0.5 && y > sea_level + 0.4) {
		// Patches: small clusters (a few metres) where a fine and a broad noise both peak, so
		// they appear sparsely, tens of metres apart, not as a continuous meadow.
		float meadow = smoothstep(0.78, 0.84, value_noise(xz * 0.22 + 17.0)) * smoothstep(0.55, 0.7, value_noise(xz * 0.018 + 3.0));
		chance = max(stray_chance, meadow * patch_chance);
		// Only some stretches of verge flower (about one in five), in clumps along them.
		float verge = smoothstep(0.68, 0.74, value_noise(xz * 0.05 + 41.0)) * smoothstep(0.5, 0.65, value_noise(xz * 0.4 + 5.0));
		// Beside a road: any road texel within about 2.5 m. The 16-read search can only matter
		// when the verge chance beats the cell's other chance and its roll (FLOWER_ROAD_LATE).
		float verge_chance = road_chance * verge;
		if (!FLOWER_ROAD_LATE || (verge_chance > chance && roll < verge_chance * season_flowers)) {
			bool road_near = false;
			for (int k = 0; k < 8 && !road_near; k++) {
				float a = float(k) * 0.785398;
				vec2 d = vec2(cos(a), sin(a));
				road_near = is_road(ground_id(xz + d * 1.3)) || is_road(ground_id(xz + d * 2.6));
			}
			if (road_near) chance = max(chance, verge_chance);
		}
		if (bloom > 0.0) {
			float drift = season_flower_drift(xz);
			spring_chance = bloom * mix(SPRING_SCATTER, SPRING_DRIFT, drift);
		}
		float hx = ground_height(xz + vec2(1.0, 0.0)) - y;
		float hz = ground_height(xz + vec2(0.0, 1.0)) - y;
		vec3 n = normalize(vec3(-hx, 1.0, -hz));
		chance *= smoothstep(0.82, 0.9, n.y);
		spring_chance *= smoothstep(0.82, 0.9, n.y);
		if (block_enabled) {
			vec2 buv = (xz - block_rect.xy) / block_rect.zw;
			if (all(greaterThanEqual(buv, vec2(0.0))) && all(lessThanEqual(buv, vec2(1.0))))
				{ float open_ground = 1.0 - textureLod(block_mask, buv, 0.0).r; chance *= open_ground; spring_chance *= open_ground; }
		}
		v_normal = normalize(mix(n, vec3(0.0, 1.0, 0.0), 0.3));
	}
	// Shaded forest has sparse wildflowers; the authored poison-joke clearing is blue.
	float joke_glade = 1.0 - smoothstep(22.0, 31.0, distance(xz, vec2(200.0, 650.0)));
	if (id == 10 || id == 11) { chance = max(chance * 0.12, joke_glade * 0.30); spring_chance *= 0.25; }
	chance *= season_flowers;
	chance = max(chance, spring_chance);
	if (maybe && deployed_footprint(xz)) chance = 0.0;
	// A late-autumn dusting or winter snow buries the flowers it covers (only cells that would flower pay).
	if (maybe && roll < chance && season_snow_cover > 0.001 && season_snow_on(vec3(0.0, 1.0, 0.0), vec3(xz.x, y, xz.y)) > 0.35) chance = 0.0;
	if (!maybe || roll >= chance) {
		VERTEX = origin;   // collapse: no flower in this cell
	} else {
		float grow = fade_out > 0.0 ? smoothstep(outer_radius, outer_radius - fade_out, dist) : 1.0;
		// Spring: a flower that has only just come up (its roll just under today's chance) is a
		// bud and opens as the chance rises over the next days.
		if (bloom > 0.0 && bloom < 0.999) grow *= clamp((chance - roll) / 0.1, 0.4, 1.0);
		float h = mix(0.18, 0.28, hash12(cell + 9.1)) * grow;   // heads peek out at grass-tip height
		float r = mix(0.05, 0.08, hash12(cell + 3.3)) * grow;
		if (bloom > 0.0) {
			// Spring flowers stand over the grass and carry bigger heads.
			h = mix(h, mix(0.26, 0.46, hash12(cell + 9.1)) * grow, bloom);
			r = mix(r, mix(0.055, 0.105, hash12(cell + 3.3)) * grow, bloom);
		}
		vec2 lean = (hash22(cell + 7.7) - 0.5) * 0.08;
		vec3 top = vec3(xz.x + lean.x, y + h, xz.y + lean.y);
		vec3 to_cam = CAMERA_POSITION_WORLD - top; to_cam.y *= 0.35;
		vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), normalize(to_cam)));
		v_head = COLOR.r;
		if (COLOR.r > 0.5) {
			// head: a camera-facing square around the top of the stem, tipped a little back
			vec3 up = normalize(vec3(0.0, 1.0, 0.0) + normalize(to_cam) * 0.35);
			VERTEX = top + (right * (UV.x * 2.0 - 1.0) + up * (UV.y * 2.0 - 1.0)) * r;
		} else {
			float w = 0.006 * grow;
			VERTEX = mix(vec3(xz.x, y - 0.02, xz.y), top, UV.y) + right * (UV.x * 2.0 - 1.0) * w;
		}
		// A patch shares a colour; now and then one of another colour grows in it.
		vec2 group = floor(xz / 3.5);
		float pick = hash12(cell + 1.9) < 0.15 ? hash12(cell + 11.3) : hash12(group + 0.5);
		// Spring: colours run in soft bands a few metres wide, mingling at their edges.
		if (bloom > 0.0 && hash12(cell + 1.9) >= 0.15)
			pick = season_flower_pick(xz);
		int colour = int(pick * 8.0) % 8;
		vec3 petal = PALETTE[colour];
		// Kind: 0 five petals, 1 daisy, 2 tulip. White is mostly daisies; red, yellow and orange are
		// often tulips. Only spring has the other two kinds.
		float kind_roll = hash12(cell + 21.7);
		v_kind = 0.0;
		if (bloom > 0.0) {
			if (colour == 2) v_kind = kind_roll < 0.8 ? 1.0 : 0.0;
			else if (colour == 1 || colour == 5 || colour == 6) v_kind = kind_roll < 0.55 ? 2.0 : (kind_roll < 0.7 ? 1.0 : 0.0);
			else v_kind = kind_roll < 0.2 ? 1.0 : (kind_roll < 0.4 ? 2.0 : 0.0);
		}
		if (id == 10 || id == 11) petal = mix(petal, vec3(0.18, 0.44, 0.95), joke_glade);
		v_petal = petal * mix(0.9, 1.05, hash12(cell + 6.2));
		v_centre = petal.g > 0.8 && petal.b < 0.5 ? vec3(0.95, 0.55, 0.15) : vec3(1.0, 0.85, 0.25);
		v_stem = vec3(0.3, 0.55, 0.22) * mix(0.85, 1.1, hash12(cell + 8.8));
		NORMAL = v_normal;
	}
#ifdef DEPLOYED_FRAGMENT_CLIP
	deployed_world_xz = VERTEX.xz;
#endif
}

void fragment() {
#ifdef DEPLOYED_FRAGMENT_CLIP
	// Clip leaning edges at the cloth boundary; roots beyond it remain untouched.
	if (deployed_footprint(deployed_world_xz)) discard;
#endif
	vec3 col;
	if (v_head > 0.5) {
		vec2 p = (UV - 0.5) * 2.0;
		float r = length(p);
		float a = atan(p.y, p.x);
		if (v_kind > 1.5) {
			// tulip, seen from the side: a cup of three pointed petals
			float cup = length(vec2(p.x / 0.62, (p.y + 0.2) / 0.78));
			float top = 0.2 + 0.62 * pow(abs(cos(p.x * 3.9)), 1.6);
			if (cup > 1.0 || p.y > top) discard;
			col = v_petal * mix(0.8, 1.05, smoothstep(-0.9, 0.6, p.y));
			// the seams between the petals, and the drawn rim
			if (abs(abs(p.x) - 0.22) < 0.035 && p.y > -0.45) col *= 0.72;
			if (cup > 0.86 || p.y > top - 0.09) col *= 0.45;
		} else if (v_kind > 0.5) {
			// daisy: many thin petals round a broad centre
			float edge = 0.4 + 0.58 * pow(abs(cos(a * 5.5)), 0.45);
			if (r > edge) discard;
			col = v_petal * mix(1.0, 0.86, smoothstep(0.3, 1.0, r));
			if (r < 0.34) col = v_centre;
			if (r > edge - 0.08 || abs(r - 0.34) < 0.045) col *= 0.5;
		} else {
			// five rounded petals
			float edge = 0.55 + 0.42 * pow(abs(cos(a * 2.5)), 0.6);
			if (r > edge) discard;
			col = v_petal * mix(1.0, 0.82, smoothstep(0.2, 1.0, r));
			if (r < 0.3) col = v_centre;
			// ink rim and a darker ring round the centre, like a drawn outline
			if (r > edge - 0.1 || abs(r - 0.3) < 0.05) col *= 0.45;
		}
	} else {
		col = v_stem;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(v_normal, 0.0)).xyz);
	ALBEDO = col;
	// A touch of self-light keeps petals as vivid as the show's in shade and haze.
	EMISSION = v_head > 0.5 ? col * (0.18 * sky_daylight) : vec3(0.0);
	ROUGHNESS = 0.95;
	BACKLIGHT = col * 0.2;
}
