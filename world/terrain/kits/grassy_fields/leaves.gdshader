shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

#include "res://world/terrain/kits/grassy_fields/wind.gdshaderinc"
#include "res://world/foliage/vegetation_color.gdshaderinc"
uniform float ground_hue_strength : hint_range(0.0,1.0) = 0.85;
varying vec4 local_ground_color;

// M_TreeLeaves: card expansion + Inflate, source normal gradient, cutout,
// Fresnel-coloured transmission, MPC wind. Authored distances are centimetres.
uniform sampler2D opacity_mask : repeat_enable, filter_linear_mipmap;
uniform vec4 leaf_color : source_color;
uniform vec4 underside_color : source_color;
uniform vec4 highlight_color : source_color;
uniform float gradient_height = 1.0;
uniform float gradient_strength = 0.511615;
uniform float fresnel_exponent = 1.5;
uniform float highlight_strength = 0.35;
uniform float billboard_size_cm = 5.0;
uniform float inflate_cm = -1.5;
uniform float billboard_scale = 9.0;
uniform float cutoff = 0.333333;
uniform float wind_intensity = 1.0;
uniform float wind_speed = 1.0;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_influence = 1.0;
uniform float wind_directional_strength = 10.0;
uniform float review_time = -1.0;
uniform bool effects_enabled = true;
// Seasons (world/foliage/vegetation_color.gdshaderinc): about how many cards cover a point of the
// crown; leaf drop thins cards by hash^leaf_overlap so the visible coverage falls with the drop.
uniform float leaf_overlap = 8.0;
// Winter twigs: the share of cards that show a bare-twig picture once their leaves are gone (the
// rest fall away as before). A card's leaves thin in patches over the twig picture before it is
// bare, so autumn crowns turn into twigs card by card.
uniform float twig_density : hint_range(0.0, 1.0) = 0.0;  // twigs off (dev 2026-11-09)
// A bare twig card is this much larger than its leaf card (the spray needs room to read as
// branches); it grows as the card's leaves go.
uniform float twig_scale = 1.6;
varying vec3 source_world_normal;
// x = deciduous share, y = snow response of the biome under the card (vegetation_season_local).
varying vec2 season_local;
// 1 = card on the tree, 0 = fallen; flat so a card's two triangles agree (both read one vertex).
varying flat float leaf_kept;
varying flat float card_vary;
// This tree in autumn (vegetation_autumn_tree).
varying flat vec3 autumn_tree;
varying flat float blossom_card;
// Spring (vegetation_spring_tree): x = how much this card is in flower, y = the tree's leaf
// growth 0..1, z = the tree's blossom kind.
varying flat vec3 spring_card;
// Winter twigs: leaf_amount = share of the card's leaves still on (1 in summer), twig_card = twig
// picture variant + 1 (0 = no twigs). twig_uv = the turned picture's uv; twig_up = world up in it
// (xy) and how much the view looks up at the card (z).
varying flat float leaf_amount;
varying flat float twig_card;
varying vec2 twig_uv;
varying vec3 twig_up;

void vertex() {
	source_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vec3 world_m = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_ground_color=vegetation_ground(world_m.xz);
	season_local = vegetation_season_local(world_m.xz);
	autumn_tree = vegetation_autumn_tree(MODEL_MATRIX[3].xyz);
	// A card is four consecutive vertices (Everfree build_trees.gd and the Grassy LOD0 cards), so
	// VERTEX_ID / 4 names the card on all four corners; the root seeds it per tree.
	float card_hash = vegetation_hash(uint(VERTEX_ID / 4) ^ vegetation_seed(MODEL_MATRIX[3].xyz));
	leaf_kept = vegetation_leaf_kept(card_hash, leaf_overlap, season_local.x, evergreen, blossom_tree);
	leaf_amount = 1.0;
	twig_card = 0.0;
	twig_uv = UV;
	twig_up = vec3(0.0);
	// Spring: the tree's leaf growth and blossom today; this card's share of both.
	vec4 spring = season_local.x > 0.001 ? vegetation_spring_tree(autumn_tree, blossom_tree) : vec4(1.0, 0.0, 0.0, 1.0);
	bool in_spring = vegetation_spring_active(spring);
	float flower = in_spring ? vegetation_spring_flower(spring, fract(card_hash * 16.0)) : 0.0;
	// Every card of the crown is there and they grow together; a card is at most a sixth larger
	// or smaller than its neighbours while it grows.
	float card_size = 1.0;
	if (in_spring) {
		card_size = vegetation_spring_size(spring, flower);
		card_size *= mix(1.0 + (fract(card_hash * 37.7) - 0.5) * 0.34, 1.0, smoothstep(0.7, 1.0, card_size));
	}
	spring_card = vec3(flower, spring.x, spring.z);
	if ((season_leaf_drop > 0.001 || in_spring) && !evergreen && season_local.x > 0.001) {
		leaf_amount = vegetation_leaf_amount(vegetation_leaf_life(card_hash, leaf_overlap, season_local.x, evergreen, blossom_tree));
		// Twig cards cast no sun shadow (an orthographic pass): thin twigs barely shade the ground
		// and the shadow cascades would draw them again several times a frame.
		if (fract(card_hash * 53.17) < twig_density && PROJECTION_MATRIX[3][3] < 0.5) {
			twig_card = 1.0 + floor(fract(card_hash * 29.3) * 4.0);
			// Turn the picture so its stem points away from the trunk on screen: from a point on
			// the trunk axis about half the card's height up, out through the card.
			vec3 root = MODEL_MATRIX[3].xyz;
			vec3 outward = mat3(VIEW_MATRIX) * (world_m - root - vec3(0.0, max(world_m.y - root.y, 0.0) * 0.55, 0.0));
			vec2 d = vec2(outward.x, -outward.y);
			float turn = (fract(card_hash * 91.7) - 0.5) * 0.9;
			float angle = dot(d, d) > 1e-6 ? atan(d.x, -d.y) + turn : turn * 3.0;
			float c = cos(angle);
			float s = sin(angle);
			vec2 p = UV - 0.5;
			twig_uv = 0.5 + vec2(c * p.x + s * p.y, -s * p.x + c * p.y);
			vec3 up_view = mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0);
			vec2 up = vec2(c * up_view.x - s * up_view.y, -s * up_view.x - c * up_view.y);
			if (fract(card_hash * 13.1) > 0.5) { twig_uv.x = 1.0 - twig_uv.x; up.x = -up.x; }
			twig_up = vec3(up, normalize(world_m - INV_VIEW_MATRIX[3].xyz).y);
		}
	}
	// Spring: a card is whole (no leaf eaten away in patches) and there as soon as its tree buds.
	if (in_spring) { leaf_kept = card_size > 0.001 ? 1.0 : 0.0; leaf_amount = 1.0; }
	card_vary = (fract(card_hash * 7.31) - 0.5) * 0.3;
	blossom_card = LOOK_SPRING > 0.0 ? 0.0 : vegetation_blossom_on(fract(card_hash * 16.0));
	// Multiply_4/5 -> AppendVector_0 -> ViewToInstance -> Normalize ->
	// BillboardSize -> InstanceToWorld. Keep instance scale in the displacement.
	vec2 corner = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	vec3 facing_world = mat3(INV_VIEW_MATRIX) * vec3(corner, 0.0);
	vec3 facing_local = inverse(mat3(MODEL_MATRIX)) * facing_world;
	facing_local /= max(length(facing_local), 0.00001);
	vec3 card_offset = (mat3(MODEL_MATRIX) * facing_local * billboard_size_cm
		+ source_world_normal * inflate_cm) * billboard_scale * 0.01;
	// Spring: blossom trees fill out, their cards grow up to a fifth at the blossom peak.
	if (LOOK_SPRING <= 0.0) card_offset *= 1.0 + 0.2 * season_blossom * blossom_tree;
	if (twig_card > 0.5) card_offset *= mix(twig_scale, 1.0, leaf_kept > 0.5 ? leaf_amount : 0.0);
	// Spring: the card grows from a bud to its full size about its own middle.
	else if (in_spring) card_offset *= card_size;
	vec3 displacement = card_offset;
	// A fallen card without twigs is not expanded or blown: it stays its small source quad and
	// every fragment of it is discarded first thing, so bare crowns draw fewer leaf fragments.
	if (leaf_kept < 0.5 && twig_card < 0.5) displacement = vec3(0.0);
	else if (effects_enabled) {
		float t = review_time < 0.0 ? TIME : review_time;
		vec2 direction = wind_direction / max(length(wind_direction), 0.00001);
		displacement += vec3(direction.x * wind_directional_strength, 1.0,
			direction.y * wind_directional_strength) * wind_intensity * 0.01;
		displacement += grassy_wind_offset(world_m, t, wind_intensity * wind_influence, 0.25, wind_speed);
	}
	VERTEX += inverse(mat3(MODEL_MATRIX)) * displacement;
}

void fragment() {
	if (leaf_kept < 0.5 && twig_card < 0.5) { discard; }
	// Twig derivatives in uniform control flow (twig_card is flat, one value per card).
	vec2 tdx = vec2(0.0);
	vec2 tdy = vec2(0.0);
	if (twig_card > 0.5) { tdx = dFdx(twig_uv); tdy = dFdy(twig_uv); }
	bool leaf = leaf_kept > 0.5 && texture(opacity_mask, UV).r >= cutoff;
	if (leaf && leaf_amount < 0.999) leaf = vegetation_leaf_patch(UV, card_vary + 0.5) < leaf_amount;
	if (!leaf) {
		if (twig_card < 0.5) { discard; }
		// Bare twigs where the leaves are gone: bark coloured, snow on their upper side.
		vec4 twig = vegetation_twig(twig_uv, tdx, tdy, twig_card - 1.0, 0.25);
		if (twig.a < 0.5) { discard; }
		float twig_snow = vegetation_twig_snow(normalize(source_world_normal).y, season_local.y, twig_up.z);
		if (twig_snow > 0.001) {
			twig_snow *= vegetation_twig_snow_edge(twig_uv, tdx, tdy, twig_card - 1.0, 0.25, twig_up.xy);
			// Far off a twig is thinner than a pixel: keep it mostly bark, not a white (sky-blue) haze.
			twig_snow *= 1.0 - 0.6 * smoothstep(3.0, 10.0, max(length(tdx), length(tdy)) * 512.0);
		}
		ALBEDO = season_snow_albedo(twig.rgb, twig_snow);
		// Lit mostly as the twigs' upper side (where the snow lies) rather than the crown surface:
		// leaves glow through on the crown's far side (BACKLIGHT), bare twigs cannot, and lit by the
		// blue sky ambient alone they turned navy blue in town.
		NORMAL = normalize((VIEW_MATRIX * vec4(normalize(normalize(source_world_normal) * 0.35 + vec3(0.0, 1.0, 0.0)), 0.0)).xyz);
		ROUGHNESS = 1.0;
	} else {
		// LinearInterpolate_0: Leaf -> Underside by 1-pow((normal.z+height)*.5,strength).
		float top_weight = pow(max((normalize(source_world_normal).y + gradient_height) * 0.5, 0.0), gradient_strength);
		ALBEDO = mix(underside_color.rgb, leaf_color.rgb, top_weight);
		float leaf_green = vegetation_green_mask(leaf_color.rgb);
		float source_green = vegetation_green_mask(ALBEDO);
		float snow = vegetation_crown_snow_amount(normalize(source_world_normal).y, season_local.y);
		ALBEDO = vegetation_ground_hue(ALBEDO, local_ground_color, ground_hue_strength * leaf_green);
		ALBEDO = vegetation_season_tint_tree(ALBEDO, source_green, season_local.x, evergreen, card_vary, autumn_tree);
		// Spring: young leaves are a light yellow green; a growing share of a flowering tree's cards flower.
		ALBEDO = vegetation_spring_young(ALBEDO, source_green, season_local.x);
		ALBEDO = vegetation_blossom(ALBEDO, blossom_card);
		ALBEDO = vegetation_blossom_tree(ALBEDO, spring_card.x, spring_card.z, card_vary);
		// The last leaves on a bare tree are dead brown ones.
		if (leaf_amount < 0.999) ALBEDO = vegetation_dead_leaves(ALBEDO);
		vec3 highlight = vegetation_ground_hue(highlight_color.rgb, local_ground_color, ground_hue_strength * leaf_green);
		highlight = vegetation_season_tint_tree(highlight, vegetation_green_mask(highlight_color.rgb), season_local.x, evergreen, card_vary, autumn_tree);
		highlight = vegetation_blossom(highlight, blossom_card);
		highlight = vegetation_blossom_tree(highlight, spring_card.x, spring_card.z, card_vary);
		ALBEDO = season_snow_albedo(ALBEDO, snow);
		float facing = max(dot(normalize(NORMAL), normalize(VIEW)), 0.0);
		float fresnel = 0.04 + 0.96 * pow(1.0 - facing, fresnel_exponent);
		// Native output is SubsurfaceColor (not Emissive). Godot backlighting avoids
		// screen-space subsurface blur; different lighting model, same source colour.
		// Snow on the crown is not translucent: it takes the leaf glow away where it lies.
		BACKLIGHT = (ALBEDO + highlight * fresnel * highlight_strength) * (1.0 - snow);
		EMISSION = vegetation_spring_light(ALBEDO, spring_card.x, source_green, season_local.x);
		ROUGHNESS = 1.0;
	}
}
