// Ground grass: world-stable cells around the camera, several independent blades per cell.
// Every blade gets its own spot, height, width, lean and quadratic-Bezier curve from world
// hashes (no repeated clump shape), finds its ground on the GPU from the Terrain3D maps, and
// is removed on paths, rock, sand, steep slopes, holes and under buildings/props.
// Colour: the terrain's own albedo under the blade (GroundGrass colour probe) with a dark
// root, warm lighter tip, two layers of world-noise patches and per-blade jitter. Normals
// are tilted outward (rounded blade) and blended toward the terrain normal so the grass
// lights like the ground it grows from.
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

// Seasons (res://world/seasons/season.gdshaderinc; season_state.gd writes it): winter grass is
// short and flattened under snow (season_snow = snow cover), wet grass darker.
#include "res://world/seasons/season.gdshaderinc"
// Tree-crown shelter near the camera, bound by res://world/seasons/snow_trail.gd on these
// materials exactly as on the terrain (gaea_surface.gdshaderinc season_canopy).
uniform sampler2D season_shelter_map : filter_linear, repeat_disable;
uniform vec4 season_shelter_rect = vec4(0.0);
float season_canopy(vec2 xz) {
	if (season_shelter_rect.z <= 0.0) return 0.0;
	vec2 suv = (xz - season_shelter_rect.xy) / season_shelter_rect.zw;
	float edge = min(min(suv.x, suv.y), min(1.0 - suv.x, 1.0 - suv.y));
	if (edge <= 0.0) return 0.0;
	return textureLod(season_shelter_map, suv, 0.0).r * smoothstep(0.0, .12, edge);
}

uniform sampler2DArray height_maps : filter_nearest, repeat_disable;
uniform sampler2DArray control_maps : filter_nearest, repeat_disable;
uniform int region_map[1024];
uniform float region_size = 1024.0;
uniform float vertex_spacing = 1.0;
uniform sampler2D ground_color : source_color, filter_linear, repeat_disable;
// The same probe pre-blurred once per probe render (ground_grass.gd _build_probe): one read per
// vertex instead of the old five-tap blur.
uniform sampler2D ground_color_soft : source_color, filter_linear, repeat_disable;
uniform vec4 ground_color_rect;   // x0, z0, width, depth
uniform sampler2D block_mask : filter_linear, repeat_disable;
uniform vec4 block_rect;
uniform bool block_enabled = false;
uniform float id_density[32];     // grass coverage per terrain texture id
uniform float spacing = 0.5;      // grid step of this LOD
uniform float clump_scale = 1.0;  // (unused, kept for older materials)
uniform float blade_width = 0.035;
uniform float tuft_radius = 0.0;  // >0: most blades gather in tufts of this radius (m)
uniform float grass_height = 0.34;
const float LOOK_LEAF_PRESS = 0.55;
uniform float inner_radius = 0.0;
uniform float outer_radius = 22.0;
uniform float band = 6.0;
// Dither band at this ring's inner and outer radius; neighbouring rings share each value.
uniform float inner_band = 6.0;
uniform float outer_band = 6.0;
// Coverage share kept per world cell (camera-relative rings cannot thin by instance count:
// the kept subset would change with every step). Same cells at any camera position.
uniform float coverage = 1.0;
uniform float fade_out = 0.0;     // last LOD shrinks to nothing over this distance
// The near ring's outer edge meets a ring of the very same blades (same grid and blade ids):
// both sides then dither their shared edge with the same hash, so every blade is drawn once.
uniform bool shared_outer = false;
uniform float sea_level = -80.0;
uniform vec2 wind = vec2(0.8, 0.35);

varying float v_height;
varying vec3 v_color;
varying float v_rand;
varying float v_patch;
varying float v_fade;
varying vec3 v_normal;
// Spring: rgb = the petal colour this blade's tip carries, a = 1 when it does (far flower drifts).
varying vec4 v_flower;
// Spring flower drifts past the reach of the real flowers (ground_flowers.gdshader, 34 m): there a
// share of the blades inside a drift carry a petal-coloured tip, so the drifts run on to where
// the grass ends instead of stopping in a ring round the player (shots of 2026-11-10).
// 0.0 = no coloured tips.
const float LOOK_SPRING_FAR_FLOWERS = 1.0;

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
// Height plus the ground normal from the same four texels (the bilinear slope), instead of two
// more four-texel lookups 1 m away (2026-10-23 grass cost pass: 8 fewer reads per vertex).
float ground_height_n(vec2 xz, out vec3 n) {
	vec2 uv = xz / vertex_spacing;
	vec2 f = fract(uv); ivec2 t = ivec2(floor(uv));
	float a = height_at(t), b = height_at(t + ivec2(1, 0)), c = height_at(t + ivec2(0, 1)), d = height_at(t + ivec2(1, 1));
	n = normalize(vec3(-mix(b - a, d - c, f.y) / vertex_spacing, 1.0, -mix(c - a, d - b, f.x) / vertex_spacing));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 bezier(vec3 a, vec3 b, vec3 c, float t) { return mix(mix(a, b, t), mix(b, c, t), t); }

#ifdef DEPLOYED_FRAGMENT_CLIP
varying vec2 deployed_world_xz;
#endif

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float t = UV.y;
	float side = UV.x * 2.0 - 1.0;
	// Each blade has its own random spot anywhere in the cell: no clump pattern to repeat.
	vec2 cell = origin.xz;
	vec2 seed = cell * 1.3 + COLOR.g * vec2(37.17, 91.73);
	vec2 xz = cell + (hash22(seed) - 0.5) * spacing;
	if (tuft_radius > 0.0 && hash12(seed + 5.5) < 0.75) {
		// Four tufts per cell; blades cluster round them, leaving natural gaps.
		float tuft = floor(fract(COLOR.g * 7.13) * 4.0);
		vec2 centre = cell + (hash22(cell * 0.77 + tuft * 13.1) - 0.5) * spacing;
		vec2 r = hash22(seed + 2.2);
		xz = centre + vec2(cos(r.x * 6.2831853), sin(r.x * 6.2831853)) * sqrt(r.y) * tuft_radius;
	}
	float h1 = hash12(seed + 17.3);
	float h2 = hash12(seed * 1.7 + 3.1);
	float h3 = hash12(seed * 0.63 + 11.9);
	float dist = distance(xz, CAMERA_POSITION_WORLD.xz);
	bool keep = dist > inner_radius + (h1 - 0.5) * inner_band && dist < outer_radius + ((shared_outer ? h1 : h2) - 0.5) * outer_band;
	keep = keep && (coverage >= 0.999 || hash12(cell * 0.913 + vec2(4.7, 1.3)) < coverage);
	// Blades outside this ring are collapsed below; skip their height and ground lookups
	// (GLSL evaluates only the chosen side of ?:).
	vec3 slope_n = vec3(0.0, 1.0, 0.0);
	float y = 0.0;
	if (keep) y = ground_height_n(xz, slope_n);
	ivec3 ct = texel(ivec2(floor(xz / vertex_spacing + 0.5)));
	float density = 0.0;
	vec3 ground_n = vec3(0.0, 1.0, 0.0);
	if (keep && ct.z >= 0 && y > sea_level + 0.4) {
		uint c = floatBitsToUint(texelFetch(control_maps, ct, 0).r);
		int base = int((c >> 27u) & 31u); int over = int((c >> 22u) & 31u);
		float blend = float((c >> 14u) & 255u) / 255.0;
		bool hole = ((c >> 2u) & 1u) == 1u;
		density = hole ? 0.0 : mix(id_density[base], id_density[over], smoothstep(0.25, 0.75, blend));
		// River bed (id 18) reads as water: no blades even where it only half-blends in.
		float river = (base == 18 ? 1.0 - blend : 0.0) + (over == 18 ? blend : 0.0);
		density *= clamp(1.0 - river * 4.0, 0.0, 1.0);
		ground_n = slope_n;
		density *= smoothstep(0.76, 0.88, ground_n.y);
		if (block_enabled) {
			vec2 buv = (xz - block_rect.xy) / block_rect.zw;
			if (all(greaterThanEqual(buv, vec2(0.0))) && all(lessThanEqual(buv, vec2(1.0))))
				density *= 1.0 - textureLod(block_mask, buv, 0.0).r;
		}
		// meadow patches: broad variation of cover
		density *= mix(0.6, 1.0, value_noise(xz * 0.07));
	}
	vec2 guv = (xz - ground_color_rect.xy) / ground_color_rect.zw;
	vec4 gc = keep ? textureLod(ground_color_soft, guv, 0.0) : vec4(0.0);
	if (any(lessThan(guv, vec2(0.0))) || any(greaterThan(guv, vec2(1.0)))) gc = vec4(0.0);
	if (keep && deployed_footprint(xz)) density = 0.0;
	float cover = density;
	bool alive = keep && density > hash12(seed + 91.7) * 0.35 + 0.02 && gc.a >= 0.5;
	// Winter snow: the terrain's own season_snow_on (gaea_fragment.gdshaderinc), minus the tree-
	// crown shelter; the colour probe holds the terrain's snow, so where the ground shows bare
	// (trodden roads and their verges, forest floor) blades are neither buried nor whitened.
	// Only live blades pay for it.
	float snow_cover = 0.0;
	if (alive && season_snow_cover > 0.001) {
		snow_cover = season_snow_on(ground_n, vec3(xz.x, y, xz.y)) * (1.0 - season_canopy(xz) * 0.85);
		snow_cover *= smoothstep(0.15, 0.45, min(gc.r, min(gc.g, gc.b)));
	}
	v_flower = vec4(0.0);
	if (!alive || snow_cover > hash12(seed + 61.3) * 0.5 + 0.35) {
		VERTEX = origin;   // collapse: nothing rasterized
		v_color = vec3(0.0);
	} else {
		if (season_spring > 0.0005 && LOOK_SPRING_FAR_FLOWERS > 0.0 && dist > 22.0) {
			float far = smoothstep(22.0, 32.0, dist);
			// The cheap test first: the drift (three noise lookups) only lowers the limit, and few blades pass.
			float pick = hash12(seed + 44.1);
			float most = season_flower_bloom() * far * 0.4;
			if (pick < most) {
				if (pick < most * season_flower_drift(xz))
					v_flower = vec4(season_flower_palette(int(season_flower_pick(xz) * 8.0)), 1.0);
			}
		}
		// a few metres of rendered ground, so single texture flecks do not tint a blade
		v_color = gc.rgb;
		v_color = mix(v_color, vec3(0.9, 0.93, 0.98), snow_cover);
		// Rain-wet grass darkens with the ground (the probe leaves wetness out so it never lags).
		if (season_wetness > 0.001) v_color *= mix(1.0, 0.7, clamp(season_wet_amount(vec3(xz.x, y, xz.y)), 0.0, 1.0));
		// Two scales of world patches: lush and dry swathes, tall and short.
		v_patch = value_noise(xz * 0.045 + 3.0) * 0.65 + value_noise(xz * 0.21 - 8.0) * 0.35;
		// Heights vary gently, and grass shortens toward paths and thin cover instead of stopping at a line.
		// Blade kinds: most are ordinary blades; some short broad leaves, some tall thin stalks,
		// some long blades that droop over. Each also gets its own taper, bulge, droop and twist.
		float kind = hash12(seed + 33.3);
		float h4 = hash12(seed * 2.3 + 7.7);
		float h5 = hash12(seed * 0.41 + 19.1);
		float hmul = 1.0; float wmul = 1.0; float taper = mix(1.1, 2.4, h4); float droop = mix(0.0, 0.35, h5 * h5);
		float bulge = mix(0.0, 0.5, h5);
		if (kind < 0.09) { hmul = mix(1.45, 1.8, h4); wmul = 0.45; taper = 0.9; droop = 0.05; bulge = 0.0; }        // stalk
		else if (kind < 0.27) { hmul = mix(0.45, 0.65, h4); wmul = mix(1.5, 2.1, h5); taper = 1.3; bulge = 0.55; }  // broad leaf
		else if (kind < 0.40) { hmul = mix(1.15, 1.35, h4); droop = mix(0.45, 0.8, h5); taper = 1.8; }               // droopy
		float tall = grass_height * hmul * mix(0.8, 1.15, h2) * mix(0.8, 1.15, v_patch) * smoothstep(0.0, 0.9, cover);
		tall *= (1.0 - season_snow * 0.65) * (1.0 - snow_cover * 0.6);
		// Autumn: under a crown the grass lies pressed down by the leaves fallen on it, so the leaf
		// carpet (world/seasons/leaf_carpet.gd) rests on top and shows instead of drowning in
		// 0.3 m blades (shots of 2026-11-10). LOOK_LEAF_PRESS = 0.0 keeps the full height.
		if (season_leaf_litter > 0.001) tall *= 1.0 - LOOK_LEAF_PRESS * season_canopy(xz) * smoothstep(0.05, 0.45, season_leaf_litter);
		float width = blade_width * wmul * mix(0.7, 1.35, h3);
		if (fade_out > 0.0) { v_fade = smoothstep(outer_radius, outer_radius - fade_out, dist); tall *= v_fade; } else { v_fade = 1.0; }
		// Neighbouring blades lean the same way (a slow world flow field), like brushed fur.
		float flow = value_noise(xz * 0.06 + 11.0) * 6.2831853 * 1.5;
		float yaw = flow + (h1 - 0.5) * 1.5;
		vec3 facing = vec3(cos(yaw), 0.0, sin(yaw));      // the way the blade bends
		float lean = (mix(0.12, 0.45, h3) + droop) * tall;
		// Wind: a gust field that travels over the meadow plus a small per-blade flutter.
		vec2 wdir = normalize(wind);
		float gust = value_noise(xz * 0.09 - wdir * TIME * 0.55);
		float flutter = sin(TIME * (2.2 + h2) + h1 * 6.2831853) * 0.08;
		vec3 push = vec3(wdir.x, 0.0, wdir.y) * (gust * 0.55 + flutter) * length(wind) * tall;
		vec3 tip = vec3(0.0, tall, 0.0) + facing * lean + push;
		tip.y = sqrt(max(tall * tall - dot(tip.xz, tip.xz) * 0.6, tall * tall * 0.08));   // bending keeps the length
		// Stiff blades bend near the top, drooping ones arch from low down.
		vec3 mid = vec3(0.0, tall * mix(0.7, 0.5, droop), 0.0) + facing * lean * mix(0.1, 0.45, droop);
		vec3 spine = bezier(vec3(0.0), mid, tip, t);
		vec3 tangent = normalize(mix(mid, tip - mid, t) + vec3(0.0, 1e-4, 0.0));
		// Twist: the flat of the blade turns along its length.
		float twist = (h4 - 0.5) * 2.2 * t;
		vec3 across = normalize(vec3(-facing.z, 0.0, facing.x) * cos(twist) + facing * sin(twist));
		float half_w = width * 0.5 * (1.0 - pow(t, taper)) * (1.0 + bulge * sin(3.14159 * t));
		vec3 root = vec3(xz.x, y - 0.02, xz.y);
		VERTEX = root + spine + across * side * half_w;
		// Rounded blade: normal tilted outward across the width, then toward the ground normal.
		vec3 n = normalize(cross(across, tangent));
		n = normalize(n + across * side * 0.55);
		// Lit like the ground it grows from: mostly the terrain normal, a hint of roundness.
		v_normal = normalize(mix(n, ground_n, 0.8));
		NORMAL = v_normal;
	}
#ifdef DEPLOYED_FRAGMENT_CLIP
	deployed_world_xz = VERTEX.xz;
#endif
	v_height = t;
	v_rand = COLOR.b;
}

void fragment() {
#ifdef DEPLOYED_FRAGMENT_CLIP
	// Clip leaning edges at the cloth boundary; roots beyond it remain untouched.
	if (deployed_footprint(deployed_world_xz)) discard;
#endif
	// The ground's own colour: a blade is the ground grown upward. Slightly shaded at the root,
	// slightly sunlit and warm at the tip; soft patches and per-blade jitter stay small.
	vec3 base = v_color;
	vec3 col = base * mix(0.97, 1.05, v_patch);
	col = mix(col * 0.74, col * vec3(1.1, 1.1, 1.0), smoothstep(0.0, 1.0, v_height));
	col *= mix(0.95, 1.05, v_rand);
	// Far blades settle toward the plain ground colour so the fade into terrain is invisible.
	col = mix(v_color, col, v_fade);
	// Spring: the tip of a far blade in a flower drift is the flower.
	float flower_tip = v_flower.a * smoothstep(0.45, 0.65, v_height) * v_fade;
	col = mix(col, v_flower.rgb, flower_tip);
	// Both faces of a blade use the same normal: no dark/light flip as blades turn.
	NORMAL = normalize((VIEW_MATRIX * vec4(v_normal, 0.0)).xyz);
	ALBEDO = col;
	ROUGHNESS = 0.9;
	SPECULAR = 0.3;
	BACKLIGHT = col * 0.15 * v_height;
	EMISSION = v_flower.rgb * (0.18 * flower_tip * sky_daylight);
}
