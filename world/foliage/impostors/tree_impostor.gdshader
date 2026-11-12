shader_type spatial;
render_mode world_vertex_coords, cull_disabled, diffuse_burley, specular_disabled;
#include "res://world/foliage/vegetation_color.gdshaderinc"
#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"
// A distant tree as one quad (tools/impostors/bake_trees.gd): pictures of the full tree from
// `frames` directions around it, `grid` x `grid` cells per atlas. Albedo atlas: colour before
// ground hue and season (sRGB), alpha = coverage. Normal atlas: tree-space normal in rgb, leaf
// mask in a. The quad stands upright on the tree root and turns about Y toward the main camera
// (XR: the point between the eyes, so both eyes see the same quad); the two frames nearest to
// the view direction are blended. Lit like the trees themselves (burley, crown normals), with
// the same ground hue and season tint as the leaf cards and the far crown.
uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : filter_linear_mipmap, repeat_disable;
uniform float frames = 16.0;
uniform float grid = 4.0;
// Square picture side and the height of its centre above the root, in tree units.
uniform float quad_size = 20.0;
uniform float quad_centre_y = 8.0;
// Cells are grid x grid in the atlas: never sample mips small enough to reach a neighbour.
uniform float max_lod = 5.0;
uniform float ground_hue_strength = 0.35;
uniform float alpha_cutoff = 0.5;
// Seasons: leaf texels (normal atlas a) thin in square patches, thin_cells across the quad, by the
// leaf cards' hash rule (one baked picture already shows every card: coverage = 1 - drop). No
// second "bare" atlas (D-03): the trunk shows where the bake saw it, the rest of the crown opens.
uniform float thin_cells = 24.0;
// Winter twigs: fallen leaf texels show bare-twig pictures, twig_cells across the quad (cards
// cannot be told apart in the baked picture, so a grid of upright sprays stands in for them; at
// this distance they read as a soft grey-brown lace in the crown's outline).
uniform float twig_cells = 10.0;
// Spring: about this many small sprays of young leaf or blossom across the quad.
uniform float spring_sprays = 26.0;
varying flat vec4 cells;
varying flat float frame_mix;
varying flat vec3 tree_x;
varying flat vec3 tree_z;
varying flat vec4 ground;
varying flat float fade_t;
varying flat vec2 season_local;
varying flat float tree_seed;
varying flat vec3 autumn_tree;
// This tree's spring (vegetation_spring_tree).
varying flat vec4 spring_tree;

vec2 cell_of(float k) {
	return vec2(mod(k, grid), floor(k / grid));
}

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float scale = length(MODEL_MATRIX[0].xyz);
	tree_x = MODEL_MATRIX[0].xyz / scale;
	tree_z = MODEL_MATRIX[2].xyz / scale;
	vec3 eye = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 to_eye = eye - root;
	vec2 toward = to_eye.xz;
	toward = dot(toward, toward) > 1e-8 ? normalize(toward) : vec2(0.0, 1.0);
	// Frame k was baked from azimuth k * TAU / frames in tree space (x = sin, z = cos).
	float f = fract(atan(dot(to_eye, tree_x), dot(to_eye, tree_z)) / TAU) * frames;
	float k0 = floor(f);
	frame_mix = f - k0;
	cells = vec4(cell_of(k0), cell_of(mod(k0 + 1.0, frames)));
	vec3 right = vec3(toward.y, 0.0, -toward.x);
	VERTEX = root + (right * (UV.x - 0.5) * quad_size + vec3(0.0, quad_centre_y + (0.5 - UV.y) * quad_size, 0.0)) * scale;
	NORMAL = vec3(toward.x, 0.0, toward.y);
	ground = vegetation_ground(root.xz);
	season_local = vegetation_season_local(root.xz);
	tree_seed = float(vegetation_seed(root) & 65535u);
	autumn_tree = vegetation_autumn_tree(root);
	spring_tree = season_local.x > 0.001 ? vegetation_spring_tree(autumn_tree, blossom_tree) : vec4(1.0, 0.0, 0.0, 1.0);
	fade_t = impostor_fade.y > 0.0 ? impostor_fade_amount(eye, root) : 1.0;
}

void fragment() {
	if (impostor_dither(FRAGCOORD.xy) >= fade_t) { discard; }
	vec2 atlas_px = vec2(textureSize(albedo_atlas, 0));
	vec2 dx = dFdx(UV) * atlas_px / grid;
	vec2 dy = dFdy(UV) * atlas_px / grid;
	float lod = clamp(0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-8)), 0.0, max_lod);
	vec2 uv0 = (cells.xy + UV) / grid;
	vec2 uv1 = (cells.zw + UV) / grid;
	vec4 albedo = mix(textureLod(albedo_atlas, uv0, lod), textureLod(albedo_atlas, uv1, lod), frame_mix);
	vec4 packed = mix(textureLod(normal_atlas, uv0, lod), textureLod(normal_atlas, uv1, lod), frame_mix);
	float kept = 1.0;
	float bloom = 0.0;
	vec2 twig_q = UV * twig_cells;
	vec2 twig_dx = vec2(0.0);
	vec2 twig_dy = vec2(0.0);
	bool growing = vegetation_spring_active(spring_tree);
	if (season_leaf_drop > 0.001 || growing) { twig_dx = dFdx(twig_q); twig_dy = dFdy(twig_q); }
	if (packed.a > 0.5 && (season_leaf_drop > 0.001 || season_blossom > 0.001)) {
		vec2 patch_cell = floor(UV * thin_cells) + vec2(tree_seed, 0.0);
		float patch_hash = vegetation_cell_hash(vec3(patch_cell, 0.0), 1.0);
		kept = vegetation_patch_kept(vegetation_leaf_kept(patch_hash, 1.0, season_local.x, evergreen, blossom_tree), patch_hash, season_local.x, evergreen);
		if (LOOK_SPRING <= 0.0) bloom = vegetation_blossom_on(fract(patch_hash * 16.0));
	}
	// Spring: the whole crown buds, flowers and leafs out together (vegetation_spring_far).
	float bloom_kind = 0.0;
	if (packed.a > 0.5 && growing) {
		vec2 far = vegetation_spring_far(spring_tree, UV * spring_sprays, fract(tree_seed / 977.0));
		kept = far.x;
		bloom_kind = far.y;
	}
	vec3 n = packed.rgb * 2.0 - 1.0;
	vec3 world_n = normalize(tree_x * n.x + vec3(0.0, n.y, 0.0) + tree_z * n.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	if (kept < 0.5) {
		// Bare twigs where the leaves have fallen.
		vec4 twig = vegetation_twig_lace(twig_q, twig_dx, twig_dy, uint(tree_seed), 0.6);
		ALPHA = albedo.a * twig.a;
		ALBEDO = season_snow_albedo(twig.rgb, vegetation_twig_snow(world_n.y, season_local.y, 0.0) * 0.4);
	} else {
		ALPHA = albedo.a;
		ALBEDO = vegetation_ground_hue(albedo.rgb, ground, ground_hue_strength * packed.a);
		ALBEDO = vegetation_season_tint_tree(ALBEDO, vegetation_green_mask(albedo.rgb), season_local.x, evergreen, 0.0, autumn_tree);
		ALBEDO = vegetation_spring_young(ALBEDO, vegetation_green_mask(albedo.rgb), season_local.x);
		ALBEDO = vegetation_blossom(ALBEDO, bloom);
		ALBEDO = vegetation_blossom_tree(ALBEDO, bloom_kind, spring_tree.z, 0.0);
		EMISSION = vegetation_spring_light(ALBEDO, bloom_kind, vegetation_green_mask(albedo.rgb), season_local.x);
		ALBEDO = vegetation_crown_snow(ALBEDO, world_n.y, season_local.y);
	}
	ROUGHNESS = 1.0;
}
