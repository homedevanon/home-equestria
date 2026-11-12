shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;
// The fallen leaves of the leaf carpet (world/seasons/leaf_carpet.gd, dev 2026-11-10: "why are
// there no leaves on the floor"). A MultiMesh quad lying on the ground under a tree. It is either
// - one whole real leaf from world/vfx/textures/leaf_atlas.png (4 x 4 maple, oak and elm leaves), or
// - a handful of about a dozen of those leaves from world/vfx/textures/leaf_litter.png (2 x 2
//   patches), each leaf of the handful with its own colour.
// Both pictures are cut from CC0 scans by the private tools/vfx/build_leaf_atlas.py: red = shape,
// green = veins and blotches around 0.5, blue (litter only) = each leaf's own number. Either may be
// swapped for a picture of the same layout.
// INSTANCE_CUSTOM: x = how late its tree turns, y = the tree's colour kind (both as
// vegetation_autumn_tree gives them, so the carpet matches the crown above it), z = this quad's
// own number 0..1, w = 1 for a handful, 0 for one leaf, 2 for a handful of spring petals (then y
// = the tree's blossom kind, vegetation_blossom_kind).
// A leaf on the ground is further along than the leaves still on its tree, and browner.
// Leaves shrink to nothing toward the edge of the carpet's reach (no pop) and under snow.
#include "res://world/foliage/vegetation_color.gdshaderinc"

uniform sampler2D leaf_atlas : hint_default_black, filter_linear_mipmap;
uniform sampler2D leaf_litter : hint_default_black, filter_linear_mipmap;
// Spring: a handful of fallen petals (2 x 2 patches like leaf_litter, the petals much smaller).
uniform sampler2D petal_litter : hint_default_black, filter_linear_mipmap;
uniform float fade_from = 38.0;
uniform float fade_to = 48.0;
uniform float backlight = 0.3;

varying flat vec2 leaf_cell;
varying flat vec3 leaf_colour;
// A handful's other colour (its leaves lie between the two by their own numbers) and the mark.
varying flat vec3 leaf_other;
varying flat float handful;

// Fallen-leaf colour of a tree of this kind: `own` = how far the leaf has turned, `brown` = how
// far it has dried.
vec3 fallen_colour(float own, float kind_of, float brown) {
	vec4 kind = vegetation_autumn_kind(clamp(own, 0.0, 1.0), kind_of);
	// The same lightness rule as a leaf on the tree: a leaf's own albedo, lifted by its kind.
	vec3 bright = kind.rgb * (0.26 * kind.a / max(dot(kind.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0001));
	// Dry leaf brown, as light as straw paper: at (0.30, 0.185, 0.085) a brown carpet in the sun
	// read as black smudges on pale grass (shots of 2026-11-10).
	return mix(bright, vec3(0.41, 0.26, 0.12), brown);
}

void vertex() {
	float own_number = INSTANCE_CUSTOM.z;
	handful = INSTANCE_CUSTOM.w;
	int cell = int(fract(own_number * 7.31) * 16.0) & 15;
	leaf_cell = handful > 0.5 ? vec2(float(cell & 1), float((cell >> 1) & 1)) : vec2(float(cell & 3), float(cell >> 2));
	vec3 at = MODEL_MATRIX[3].xyz;
	float keep = 1.0 - smoothstep(fade_from, fade_to, distance(at, MAIN_CAM_INV_VIEW_MATRIX[3].xyz));
	if (season_snow_cover > 0.001) keep *= 1.0 - season_snow_on(vec3(0.0, 1.0, 0.0), at);
	VERTEX *= keep;
	float vary = (fract(own_number * 3.17) - 0.5) * 0.5;
	float own = season_leaf_turn * 2.2 - INSTANCE_CUSTOM.x * 0.7 + vary + 0.35;
	// Dry brown comes late (dev 2026-11-10: "as it approaches winter it should turn fully brown"):
	// a mid-autumn carpet is still gold, orange and red.
	float brown = smoothstep(0.6, 0.95, season_leaf_turn + vary * 0.5 + 0.08);
	float shade = mix(0.8, 1.1, fract(own_number * 13.7));
	if (handful > 1.5) {
		// Petals: the tree's blossom colour, some of them paler.
		vec3 petal = vegetation_blossom_kind(INSTANCE_CUSTOM.y);
		leaf_colour = petal * shade;
		leaf_other = mix(petal, vec3(0.95, 0.9, 0.92), 0.55) * shade;
	} else {
		leaf_colour = fallen_colour(own, INSTANCE_CUSTOM.y, brown) * shade;
		// The other end of a handful: a fresher leaf, now and then one blown over from another kind of tree.
		float kind_other = fract(own_number * 5.3) < 0.3 ? fract(INSTANCE_CUSTOM.y + 0.37) : INSTANCE_CUSTOM.y;
		leaf_other = fallen_colour(own - 0.3, kind_other, brown * 0.55) * shade;
	}
}

void fragment() {
	vec3 leaf = vec3(0.0);
	if (handful > 1.5) leaf = texture(petal_litter, (leaf_cell + UV) * 0.5).rgb;
	else if (handful > 0.5) leaf = texture(leaf_litter, (leaf_cell + UV) * 0.5).rgb;
	else leaf = vec3(texture(leaf_atlas, (leaf_cell + UV) * 0.25).rg, 0.0);
	if (leaf.r < 0.45) { discard; }
	vec3 colour = handful > 0.5 ? mix(leaf_colour, leaf_other, smoothstep(0.3, 0.8, leaf.b)) * mix(0.7, 1.15, fract(leaf.b * 7.3)) : leaf_colour;
	colour *= 0.55 + 0.9 * leaf.g;
	ALBEDO = colour;
	BACKLIGHT = colour * backlight;
	// Petals keep their pink in the blue shade under the crown (as the blossom does).
	if (handful > 1.5) EMISSION = colour * (0.18 * sky_daylight);
	ROUGHNESS = 1.0;
}
