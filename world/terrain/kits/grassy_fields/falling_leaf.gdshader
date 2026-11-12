shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, shadows_disabled;
// Ported M_FallingLeaf, used since W2-SEAS-E (2026-11-08) by world/seasons/season_particles.gd for
// autumn leaves and spring petals. Each particle shows one whole leaf cut from the Everfree
// leaf_mask (a 256 px cluster mask): INSTANCE_CUSTOM.x (the particle's seed) picks one of four
// isolated leaves in it. COLOR is the particle colour (season tint) and COLOR.a its fade: landed
// leaves dissolve with a screen-space dither, so the material stays opaque (no sorting).
uniform sampler2D leaf_texture : hint_default_white, filter_linear_mipmap;
// Autumn leaves (dev 2026-11-10): real leaf shapes from world/vfx/textures/leaf_atlas.png, cells x
// cells whole leaves (red = shape, green = veins around 0.5). 0 = the leaf mask windows below
// (spring petals).
uniform sampler2D leaf_atlas : hint_default_black, filter_linear_mipmap;
uniform int atlas_cells = 0;
uniform vec4 leaf_color : source_color = vec4(1.0);
uniform float opacity_cutoff = 0.3333;
// Light through thin leaves.
uniform float backlight = 0.35;

// Pixel windows (x, y, w, h of 256) of four single leaves in leaf_mask.res.
const vec4 WINDOWS[4] = vec4[4](
	vec4(0.316406, 0.000000, 0.097656, 0.074219),
	vec4(0.867188, 0.718750, 0.078125, 0.078125),
	vec4(0.468750, 0.863281, 0.078125, 0.070312),
	vec4(0.097656, 0.050781, 0.070312, 0.070312));

varying flat int leaf_window;
varying flat vec2 atlas_cell;

void vertex() {
	leaf_window = int(fract(INSTANCE_CUSTOM.x * 7.31) * 4.0) & 3;
	int cells = max(atlas_cells, 1);
	int cell = int(fract(INSTANCE_CUSTOM.x * 11.13) * float(cells * cells));
	atlas_cell = vec2(float(cell % cells), float(cell / cells));
}

float dither(vec2 frag) {
	return fract(52.9829189 * fract(dot(floor(frag), vec2(0.06711056, 0.00583715))));
}

void fragment() {
	vec4 window = WINDOWS[leaf_window];
	float leaf;
	float veins = 1.0;
	if (atlas_cells > 0) {
		vec2 picked = texture(leaf_atlas, (atlas_cell + UV) / float(atlas_cells)).rg;
		leaf = picked.r > 0.5 ? 1.0 : 0.0;
		veins = 0.55 + 0.9 * picked.g;
	} else {
		leaf = texture(leaf_texture, window.xy + UV * window.zw).r;
	}
	if (leaf < opacity_cutoff || COLOR.a <= dither(FRAGCOORD.xy)) { discard; }
	vec3 albedo = COLOR.rgb * leaf_color.rgb * veins;
	ALBEDO = albedo;
	BACKLIGHT = albedo * backlight;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
