shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;
// Small town kit plants through the seasons (world/props/ponyville_kit/kit_dressing.gd, dev
// 2026-11-10: "green shrubbery appearing in winter and fall ... not being affected by anything.
// there are little patches of grass still"). The kit's grass tufts and flower clumps came with a
// plain material, so they stood summer green on straw in autumn and on snow in winter.
// Here their green parts turn with the ground they stand on (the terrain's own rule, so a tuft
// matches the grass around it), and snow whitens them and presses them down until only the tips
// show. Petals keep their colour.
#include "res://world/seasons/season.gdshaderinc"

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_texture = false;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform bool vertex_tint = false;
// Below this alpha a texel is cut away; 0 = the material is opaque.
uniform float scissor = 0.0;
// A plant that is grass and nothing else: every texel turns with the ground. The kit paints some
// tuft blades so dark a green that the hue test below let them through unturned (shots of 2026-11-10).
uniform bool all_green = false;
// How much of the ground's lightness the turned green takes (the rest stays the plant's own).
uniform float ground_light = 0.25;

varying float snow_here;

void vertex() {
	snow_here = 0.0;
	if (season_snow_cover > 0.001) {
		vec3 root = MODEL_MATRIX[3].xyz;
		snow_here = season_snow_on(vec3(0.0, 1.0, 0.0), root);
		if (snow_here > 0.001) {
			// Pressed down by the snow: a fifth of its height is left at full cover.
			vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
			world.y = root.y + (world.y - root.y) * (1.0 - 0.8 * snow_here);
			VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
		}
	}
}

void fragment() {
	vec4 colour = albedo_tint;
	if (has_texture) colour *= texture(albedo_texture, UV);
	if (vertex_tint) colour.rgb *= COLOR.rgb;
	if (scissor > 0.0 && colour.a < scissor) discard;
	ALBEDO = colour.rgb;
	// The terrain's rule (world/terrain/gaea_fragment.gdshaderinc): green turns toward the
	// season's ground colour, keeping how light or dark it was.
	vec3 luma = vec3(0.2126, 0.7152, 0.0722);
	vec3 chroma = ALBEDO / max(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), 0.0001);
	float green = all_green ? 1.0 : smoothstep(0.0, 0.12, chroma.g - chroma.r) * smoothstep(0.0, 0.14, chroma.g - chroma.b);
	// Most of the ground's lightness as well as its hue: the tufts are painted a dark green that
	// stayed a dark blot on pale autumn grass when only the hue turned (first shots).
	// Flower stems keep most of their own darkness: as light as the ground they vanished (sunflowers).
	vec3 turned = season_ground.rgb * mix(dot(ALBEDO, luma) / max(dot(season_ground.rgb, luma), 0.00001), 0.8, ground_light);
	ALBEDO = mix(ALBEDO, turned, clamp(season_ground.a * green, 0.0, 1.0));
	ALBEDO = season_snow_albedo(ALBEDO, snow_here * 0.9);
	ROUGHNESS = 1.0;
	// Grass is lit like the ground it grows from (as world/foliage/grass/ground_grass.gdshader does):
	// with their own normals, blades turned from the sun stood near black on sunlit straw.
	if (all_green) NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}
