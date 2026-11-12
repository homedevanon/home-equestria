shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;
#include "res://world/foliage/vegetation_color.gdshaderinc"
varying vec4 local_ground_color;
uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
varying flat vec2 atlas_cell;
// Seasons: x = deciduous share, y = snow response at the plant (vegetation_season_local). Green
// texels thin in square patches, thin_cells across the quad, by the leaf cards' hash rule.
uniform float thin_cells = 16.0;
// Winter twigs: fallen green texels show bare-twig pictures, twig_cells across the quad.
uniform float twig_cells = 8.0;
varying flat vec2 season_local;
varying flat float plant_seed;
varying flat vec3 autumn_tree;
void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	local_ground_color = vegetation_ground(centre.xz);
	season_local = vegetation_season_local(centre.xz);
	plant_seed = float(vegetation_seed(centre) & 65535u);
	autumn_tree = vegetation_autumn_tree(centre);
	vec3 size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	// Use the viewport camera in both the color and shadow passes, including XR.
	vec3 toward = normalize(MAIN_CAM_INV_VIEW_MATRIX[3].xyz - centre + vec3(0.0, 0.0, 0.00001));
	vec3 local_view = vec3(dot(toward, MODEL_MATRIX[0].xyz) / max(size.x, 0.00001),
		dot(toward, MODEL_MATRIX[1].xyz) / max(size.y, 0.00001),
		dot(toward, MODEL_MATRIX[2].xyz) / max(size.z, 0.00001));
	float azimuth = mod(floor(atan(local_view.x, local_view.z) * 8.0 / TAU + 0.5), 8.0);
	float elevation = clamp(floor(asin(clamp(local_view.y, -1.0, 1.0)) / radians(35.0) + 0.5), 0.0, 2.0);
	atlas_cell = vec2(azimuth, elevation);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.00001), toward));
	vec3 up = cross(toward, right);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(right * max(size.x, size.z), 0.0),
		vec4(up * size.y, 0.0), vec4(toward * size.z, 0.0), vec4(centre, 1.0));
}
void fragment() {
	vec4 color = texture(atlas, (UV + atlas_cell) / vec2(8.0, 3.0));
	float green = vegetation_green_mask(color.rgb);
	float kept = 1.0;
	float bloom = 0.0;
	vec2 twig_q = UV * twig_cells;
	vec2 twig_dx = vec2(0.0);
	vec2 twig_dy = vec2(0.0);
	// This plant's spring (vegetation_spring_tree).
	vec4 spring_tree = season_local.x > 0.001 ? vegetation_spring_tree(autumn_tree, blossom_tree) : vec4(1.0, 0.0, 0.0, 1.0);
	bool growing = vegetation_spring_active(spring_tree);
	if (season_leaf_drop > 0.001 || growing) { twig_dx = dFdx(twig_q); twig_dy = dFdy(twig_q); }
	if (green > 0.3 && (season_leaf_drop > 0.001 || season_blossom > 0.001)) {
		float patch_hash = vegetation_cell_hash(vec3(floor(UV * thin_cells) + vec2(plant_seed, 0.0), 0.0), 1.0);
		kept = vegetation_patch_kept(vegetation_leaf_kept(patch_hash, 1.0, season_local.x, evergreen, blossom_tree), patch_hash, season_local.x, evergreen);
		if (LOOK_SPRING <= 0.0) bloom = vegetation_blossom_on(fract(patch_hash * 16.0));
	}
	// Spring: the whole crown buds, flowers and leafs out together (vegetation_spring_far).
	float bloom_kind = 0.0;
	if (green > 0.3 && growing) {
		vec2 far = vegetation_spring_far(spring_tree, UV * 26.0, fract(float(plant_seed) / 977.0));
		kept = far.x;
		bloom_kind = far.y;
	}
	if (kept < 0.5) {
		// Bare twigs where the leaves have fallen.
		vec4 twig = vegetation_twig_lace(twig_q, twig_dx, twig_dy, uint(plant_seed), 0.6);
		ALBEDO = season_snow_albedo(twig.rgb, vegetation_twig_snow(1.0 - UV.y * 1.3, season_local.y, 0.0) * 0.4);
		ALPHA = color.a * twig.a;
	} else {
		ALBEDO = vegetation_ground_hue(color.rgb, local_ground_color, 0.85 * green);
		ALBEDO = vegetation_season_tint_tree(ALBEDO, green, season_local.x, evergreen, 0.0, autumn_tree);
		ALBEDO = vegetation_spring_young(ALBEDO, green, season_local.x);
		ALBEDO = vegetation_blossom(ALBEDO, bloom);
		ALBEDO = vegetation_blossom_tree(ALBEDO, bloom_kind, spring_tree.z, 0.0);
		EMISSION = vegetation_spring_light(ALBEDO, bloom_kind, green, season_local.x);
		// A broad canopy: snow settles on its upper half (the quad's top in UV).
		ALBEDO = vegetation_crown_snow(ALBEDO, 1.0 - UV.y * 1.3, season_local.y);
		ALPHA = color.a;
	}
	ALPHA_SCISSOR_THRESHOLD = 0.35;
	// A broad canopy receives daylight from above; avoid view-facing lighting changes.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = 1.0;
}
