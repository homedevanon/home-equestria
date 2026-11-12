shader_type spatial;
render_mode diffuse_burley, specular_disabled;
#include "res://world/foliage/vegetation_color.gdshaderinc"
#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"
// Far Everfree crown (tools/everfree_trees/build_trees.gd): the RNL blob in the leaf cards'
// colours, lighter on top and darker underneath like the cards, with the same ground hue
// and season tint, so the swap from cards past 110 m keeps its colour. Far tiles with an
// impostor set impostor_fade on a copy, dissolving it into the impostor past 500 m.
uniform vec4 leaf_color : source_color;
uniform vec4 underside_color : source_color;
uniform float ground_hue_strength : hint_range(0.0, 1.0) = 0.35;
// Seasons: the crown thins in patches of this size (metres) as the leaves fall, by the same hash
// rule as the leaf cards (a solid blob has no card overlap, so coverage = 1 - drop).
uniform float thin_cell_m = 1.6;
// Winter twigs: where the leaves are gone the blob shows bare-twig pictures this many metres
// across (vegetation_twig_world), a lace of branches instead of a hole.
uniform float twig_cell_m = 2.4;
// Spring: one small spray of young leaf or blossom is about this many metres across.
uniform float spring_spray_m = 0.3;
varying vec4 local_ground_color;
varying vec3 world_normal;
varying vec3 world_pos;
varying float fade_t;
varying flat vec2 season_local;
varying flat vec3 autumn_tree;
varying flat vec4 spring_tree;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_ground_color = vegetation_ground(world_pos.xz);
	season_local = vegetation_season_local(MODEL_MATRIX[3].xz);
	autumn_tree = vegetation_autumn_tree(MODEL_MATRIX[3].xyz);
	spring_tree = season_local.x > 0.001 ? vegetation_spring_tree(autumn_tree, 0.0) : vec4(1.0, 0.0, 0.0, 1.0);
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	fade_t = impostor_fade_amount(MAIN_CAM_INV_VIEW_MATRIX[3].xyz, MODEL_MATRIX[3].xyz);
}

void fragment() {
	if (impostor_dither(FRAGCOORD.xy) < fade_t) { discard; }
	vec3 dpdx = vec3(0.0);
	vec3 dpdy = vec3(0.0);
	bool growing = vegetation_spring_active(spring_tree);
	if (season_leaf_drop > 0.001 || growing) { dpdx = dFdx(world_pos); dpdy = dFdy(world_pos); }
	float patch_hash = vegetation_cell_hash(world_pos, thin_cell_m);
	bool bare = season_leaf_drop > 0.001 && vegetation_patch_kept(vegetation_leaf_kept(patch_hash, 1.0, season_local.x, evergreen, 0.0), patch_hash, season_local.x, evergreen) < 0.5;
	// Spring: the whole crown buds, flowers and leafs out together (vegetation_spring_far, world metres).
	float in_flower = 0.0;
	if (growing) {
		vec2 q = vec2(world_pos.x + world_pos.z * 0.7, world_pos.y + world_pos.z * 0.4) / spring_spray_m;
		vec2 far = vegetation_spring_far(spring_tree, q, fract(autumn_tree.x * 13.7));
		bare = far.x < 0.5;
		in_flower = far.y;
	}
	if (bare) {
		vec4 twig = vegetation_twig_world(world_pos, dpdx, dpdy, world_normal, twig_cell_m, 0.8);
		if (twig.a < 0.5) { discard; }
		ALBEDO = season_snow_albedo(twig.rgb, vegetation_twig_snow(normalize(world_normal).y, season_local.y, 0.0) * 0.4);
		ROUGHNESS = 1.0;
	} else {
		float top = pow(max((world_normal.y + 1.0) * 0.5, 0.0), 0.511615);
		vec3 base = mix(underside_color.rgb, leaf_color.rgb, top);
		ALBEDO = vegetation_ground_hue(base, local_ground_color, ground_hue_strength * vegetation_green_mask(leaf_color.rgb));
		ALBEDO = vegetation_season_tint_tree(ALBEDO, vegetation_green_mask(base), season_local.x, evergreen, 0.0, autumn_tree);
		ALBEDO = vegetation_spring_young(ALBEDO, vegetation_green_mask(base), season_local.x);
		ALBEDO = vegetation_blossom_tree(ALBEDO, in_flower, spring_tree.z, 0.0);
		EMISSION = vegetation_spring_light(ALBEDO, in_flower, vegetation_green_mask(base), season_local.x);
		ALBEDO = vegetation_crown_snow(ALBEDO, normalize(world_normal).y, season_local.y);
		ROUGHNESS = 1.0;
	}
}
