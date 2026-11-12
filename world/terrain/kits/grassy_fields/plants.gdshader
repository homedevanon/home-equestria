shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;
#include "res://world/terrain/kits/grassy_fields/wind.gdshaderinc"
#include "res://world/foliage/vegetation_color.gdshaderinc"
uniform float ground_hue_strength : hint_range(0.0,1.0) = 0.85;
varying vec4 local_ground_color;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D mask_texture : filter_linear_mipmap_anisotropic;
uniform vec4 tint_color : source_color;
uniform float tint_strength = 0.3;
uniform float gradient_strength = 0.5;
uniform float bend_m = 0.15;
uniform float affect_radius_m = 0.8;
uniform float trample_m = -0.4;
uniform float wind_influence = 3.0;
uniform float wind_directional_strength_m = 0.05;
uniform vec2 wind_direction = vec2(-1.0, 0.0);
uniform float wind_intensity = 2.0;
uniform float wind_speed = 0.1;
uniform bool effects_enabled = true;
uniform float review_time = -1.0;
uniform bool interaction_enabled = false;
uniform vec3 interaction_position = vec3(0.0);
// Seasons: x = deciduous share, y = snow response of the biome (vegetation_season_local); tip =
// 0 at the plant's foot, 1 at its tips (crown snow settles on the upper half).
varying vec2 season_local;
varying float plant_tip;
void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_ground_color=vegetation_ground(wp.xz);
	float tip_weight = clamp(1.0 - UV2.y, 0.0, 1.0);
	season_local = vegetation_season_local(wp.xz);
	plant_tip = tip_weight;
	float weight = tip_weight * gradient_strength;
	if (effects_enabled) {
		vec3 directional = grassy_directional_wind(wind_direction, wind_intensity,
			wind_directional_strength_m);
		vec3 offset = grassy_simple_wind(wp, grassy_effect_time(review_time),
			wind_intensity * wind_influence, 0.25, wind_speed, directional) * weight;
		if (interaction_enabled) offset += grassy_interaction(wp, interaction_position,
			affect_radius_m, bend_m, trample_m, tip_weight);
		VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
	}
}
void fragment() {
	vec4 albedo = texture(albedo_texture, UV);
	ALBEDO = mix(albedo.rgb, tint_color.rgb, tint_strength);
	float green = vegetation_green_mask(ALBEDO);
	ALBEDO = vegetation_ground_hue(ALBEDO, local_ground_color, ground_hue_strength * green);
	ALBEDO = vegetation_season_tint(ALBEDO, green, season_local.x, evergreen, 0.0);
	// The surface normal is forced up here, so snow follows the plant's height instead.
	ALBEDO = vegetation_crown_snow(ALBEDO, 0.2 + 0.6 * plant_tip, season_local.y);
	ALPHA = texture(mask_texture, UV).r;
	ALPHA_SCISSOR_THRESHOLD = 0.3333;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}
