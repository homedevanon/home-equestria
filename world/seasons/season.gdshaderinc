// Seasons shader contract (W1-SEAS-A, 2026-11-08; design captures/overhaul-2026-11-08/seasons
// AUDIT_AND_DESIGN.md 6.1). Every season_* global below is written only by
// res://world/seasons/season_state.gd, at most four times a second and only when it moves.
// A shader that includes this file must not declare any of these uniforms itself: include this
// first and drop its own `global uniform ... season_*` lines. Every function returns its input
// (or 0) at once while the uniform it depends on is zero, so a summer or dry scene pays only a
// uniform branch.
#ifndef SEASON_GDSHADERINC
#define SEASON_GDSHADERINC

// Day-stepped palettes (unchanged from the weather.gd era). rgb = colour, a = amount.
global uniform vec4 season_leaf;
global uniform vec4 season_ground;
// Kept for older readers: always equal to season_snow_cover.
global uniform float season_snow;
global uniform float season_flowers;
// Driven quantities, 0..1.
global uniform float season_snow_cover;   // snow lying on the ground (grows while it snows)
global uniform float season_snow_fresh;   // 1 while snowing, fades over a day
global uniform float season_leaf_turn;    // autumn colour: 0 green .. 1 fully turned (dev 2026-11-09)
global uniform float season_leaf_drop;    // canopy thinning (0 full, 0.85 bare)
global uniform float season_leaf_litter;  // fallen leaves on the ground
global uniform float season_blossom;      // spring blossom on flowering trees
// How far spring has come: 0 outside spring, else the season's day ramp (0.001 first day .. 1 last).
// Trees leaf out and flower by it, each a little apart (vegetation_spring_tree), and the meadow
// flowers come up by it (ground_flowers.gdshader) (dev 2026-11-10).
global uniform float season_spring;
// 1 in full day, 0 at night (world/sky_controller.gd writes it): spring blossom, petals and
// flowers carry a little light of their own by day only.
global uniform float sky_daylight;
global uniform float season_wetness;      // rain-wet ground
global uniform float season_ice;          // still water frozen
// Per-biome response (world/seasons/climate_map.gd): R snow susceptibility, G deciduous share,
// B wetness response, A ice allowed. rect = (origin x, origin z, size x, size z) in metres;
// size 0 = no map baked: every channel reads 1 (old behaviour, snow everywhere).
global uniform sampler2D season_climate_map : filter_linear, repeat_disable;
global uniform vec4 season_climate_rect;
// Trodden snow near the camera (world/seasons/snow_trail.gd): R 1 = fully trodden.
global uniform sampler2D snow_trail_map : filter_linear, repeat_disable;
global uniform vec4 snow_trail_rect;

float season_climate(vec2 xz, int channel) {
	if (season_climate_rect.z <= 0.0) return 1.0;
	vec2 uv = clamp((xz - season_climate_rect.xy) / season_climate_rect.zw, vec2(0.0), vec2(1.0));
	return textureLod(season_climate_map, uv, 0.0)[channel];
}

// How trodden the snow is at a world point (0 outside the trail window).
float season_snow_trail(vec2 xz) {
	if (snow_trail_rect.z <= 0.0) return 0.0;
	vec2 uv = (xz - snow_trail_rect.xy) / snow_trail_rect.zw;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 0.0;
	return textureLod(snow_trail_map, uv, 0.0).r;
}

// Where snow lies first and melts last: 0..1 over the land, about half on average. Three sizes
// of soft noise (patches some 35 m, 12 m and 4 m across, each turned so no grid lines up).
// Whole-number hash, so the CPU mirror gives the same patches to the metre.
// Until 2026-11-10 this was a sum of two sines, and a thaw left the snow as a regular grid of
// ovals over the whole valley (dev: "a pattern of snow circles across the entire world").
float season_drift_cell(ivec2 c) {
	uint h = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u;
	h ^= h >> 16u; h *= 0x7feb352du; h ^= h >> 15u; h *= 0x846ca68bu; h ^= h >> 16u;
	return float(h >> 8u) * (1.0 / 16777216.0);
}
float season_drift_noise(vec2 p) {
	vec2 i = floor(p); vec2 f = p - i; f = f * f * (3.0 - 2.0 * f);
	ivec2 c = ivec2(i);
	return mix(mix(season_drift_cell(c), season_drift_cell(c + ivec2(1, 0)), f.x), mix(season_drift_cell(c + ivec2(0, 1)), season_drift_cell(c + ivec2(1, 1)), f.x), f.y);
}
float season_snow_drift(vec2 xz) {
	vec2 a = vec2(xz.x * .8 - xz.y * .6, xz.x * .6 + xz.y * .8);
	vec2 b = vec2(xz.x * .28 + xz.y * .96, xz.y * .28 - xz.x * .96);
	return season_drift_noise(xz * .028) * .55 + season_drift_noise(a * .083 + 31.0) * .3 + season_drift_noise(b * .26 + 7.0) * .15;
}

// Snow cover on a surface: up-facing, biome-allowed, in drifts, minus trodden trails.
// Thin cover (the first snow, a thaw) lies in ragged patches with a firm edge, and stays longer
// on slopes that face one way (the shaded side); full cover lies everywhere.
// The CPU mirror is res://world/seasons/snow_cover_query.gd; keep the two identical.
float season_snow_on(vec3 world_normal, vec3 world_pos) {
	if (season_snow_cover <= 0.001) return 0.0;
	float s = season_snow_cover * season_climate(world_pos.xz, 0);
	if (s <= 0.001) return 0.0;
	float cover = smoothstep(.55, .85, world_normal.y);
	// Deep cover lies everywhere: above s = 0.907 the drift term below is 1 for any drift and any
	// slope direction (lowest value -.35 (1 - s) + .5 s against the upper edge 1.1 - .75 s), so its
	// three noise lookups are skipped. Same result; the CPU mirror needs no change.
	if (s < .93) {
		float drift = season_snow_drift(world_pos.xz) + world_normal.z * .35 * (1.0 - s);
		cover *= smoothstep(1.0 - s, 1.0 - s + mix(.1, .35, s), drift + s * .5);
	}
	cover *= 1.0 - season_snow_trail(world_pos.xz) * .85;
	return clamp(cover, 0.0, 1.0);
}

// Snow colour over an albedo: bright, a touch blue in the shade of deep cover; fresh powder whiter.
// Parameter names must not match a uniform of an including shader: Godot resolves them to the
// uniform (StandardMaterial3D code declares `albedo` and `roughness`), and the generated snow
// materials then failed to compile ("0:910: 'return' : cannot convert return value", W3-PERF-GATE).
vec3 season_snow_albedo(vec3 base_albedo, float cover) {
	if (cover <= 0.001) return base_albedo;
	vec3 snow = mix(vec3(.86, .9, .97), vec3(.94, .96, 1.0), season_snow_fresh);
	return mix(base_albedo, snow, clamp(cover, 0.0, 1.0));
}

// ---- Spring flower drifts (dev 2026-11-10: "a FUCKTon of blooming flowers"). One rule for the
// three things that draw them, so they agree to the metre: the flowers themselves near the eye
// (world/foliage/grass/ground_flowers.gdshader, to 34 m), petal-coloured grass tips past them
// (ground_grass.gdshader, to 125 m) and a tint of the ground beyond (gaea_fragment.gdshaderinc).
float season_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * .1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float season_noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(season_hash12(i), season_hash12(i + vec2(1, 0)), f.x), mix(season_hash12(i + vec2(0, 1)), season_hash12(i + vec2(1, 1)), f.x), f.y);
}
// How far the spring bloom has come today (0 outside spring): up over the first half of the
// season, a little down over its last two days.
float season_flower_bloom() {
	if (season_spring <= .0005) return 0.0;
	return smoothstep(.1, .5, season_spring) * (1.0 - .45 * smoothstep(.9, 1.0, season_spring));
}
// 1 inside a flower drift (broad swathes tens of metres across), 0 between them.
float season_flower_drift(vec2 xz) {
	return smoothstep(.6, .72, season_noise(xz * .011 + 9.0) * .6 + season_noise(xz * .034 + 4.0) * .28 + season_noise(xz * .19 + 2.0) * .12);
}
// The flower colours, and which of them grows at a spot: soft bands a few metres wide.
vec3 season_flower_palette(int index) {
	const vec3 flower_colours[8] = vec3[8](
		vec3(1.0, .3, .62), vec3(1.0, .8, .08), vec3(.98, .95, .9), vec3(.62, .36, 1.0),
		vec3(.3, .55, 1.0), vec3(1.0, .2, .22), vec3(1.0, .5, .1), vec3(.95, .45, .9));
	return flower_colours[index % 8];
}
float season_flower_pick(vec2 xz) {
	return fract(season_noise(xz * .11 + 13.0) * 2.6 + season_noise(xz * .47 + 29.0) * .5);
}

// A material's own fixed ground colour (the foot of a trunk fades into it) through the seasons, by
// the terrain's rule (world/terrain/gaea_fragment.gdshaderinc): toward the season's ground colour,
// keeping how light or dark it was, then under the snow that lies at this point. Without this the
// feet of the Grassy trees stood summer green on straw and on snow (dev 2026-11-10: "green
// shrubbery ... not being affected by anything").
vec3 season_ground_turn(vec3 fixed_ground, vec3 world_pos) {
	vec3 turned_luma = vec3(.2126, .7152, .0722);
	vec3 turned = fixed_ground;
	if (season_ground.a > .001)
		turned = mix(turned, season_ground.rgb * (dot(turned, turned_luma) / max(dot(season_ground.rgb, turned_luma), .00001)), clamp(season_ground.a, 0.0, 1.0));
	if (season_snow_cover > .001) turned = season_snow_albedo(turned, season_snow_on(vec3(0.0, 1.0, 0.0), world_pos));
	return turned;
}

// How wet a surface at this point gets (rain-wet ground x the biome's wetness response).
float season_wet_amount(vec3 world_pos) {
	if (season_wetness <= 0.001) return 0.0;
	return season_wetness * season_climate(world_pos.xz, 2);
}

// Wet look: darker albedo, shinier surface. `wet` is the local amount (season_wet_amount).
void season_wet(inout vec3 wet_albedo, inout float wet_roughness, float wet) {
	if (wet <= 0.001) return;
	float w = clamp(wet, 0.0, 1.0);
	wet_albedo *= mix(1.0, .62, w);
	wet_roughness = mix(wet_roughness, min(wet_roughness, .18), w * .85);
}

// 1 = this leaf card is still on the tree, 0 = it has fallen. card_hash is a stable 0..1 per card.
float season_leaf_kept(float card_hash) {
	if (season_leaf_drop <= 0.001) return 1.0;
	return step(season_leaf_drop, card_hash);
}

// Season tint for a leaf colour. green = how green the source pixel is (vegetation_green_mask);
// evergreens only darken a little toward a cold pine green and never turn orange. Multiply green
// by season_climate(xz, 1) where the position is known (jungle and desert stay green).
vec3 season_leaf_tint(vec3 c, float green, bool evergreen) {
	if (season_leaf.a <= 0.001) return c;
	vec3 luma = vec3(.2126, .7152, .0722);
	vec3 target = evergreen ? vec3(.2, .4, .26) : season_leaf.rgb;
	float amount = season_leaf.a * green * (evergreen ? .3 : 1.0);
	vec3 turned = target * (dot(c, luma) / max(dot(target, luma), .00001));
	return mix(c, turned, clamp(amount, 0.0, 1.0));
}

#endif
