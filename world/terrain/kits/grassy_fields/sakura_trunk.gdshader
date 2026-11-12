shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// The foot fades into ground_color; that colour follows the seasons (season_ground_turn).
#include "res://world/seasons/season.gdshaderinc"
uniform sampler2D bark_color : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D bark_orm : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D bark_normal : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D base_normal : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D moss_variation : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D noise_texture : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform vec4 moss_color : source_color;
uniform vec4 ground_color : source_color;
uniform float uv_scale_base;
uniform float upvector_sharpness;
uniform float upvector_bias;
uniform float noise_uv_scale;
uniform float terrain_blend_m;
uniform float gradient_height;
uniform float ground_height_m;
uniform bool ground_from_instance = false;
// How much the foot takes the ground's colour, and how much moss lies on the bark's upper sides
// (1 = as authored). Both are 0 on the trunk material: plain brown bark down to the ground (dev
// 2026-11-10; tools/look/set_trunk_foot.gd writes them into the material).
uniform float foot_fade : hint_range(0.0, 1.0) = 1.0;
uniform float moss_amount : hint_range(0.0, 1.0) = 1.0;
varying vec3 world_position;
varying vec3 world_normal;
varying vec3 world_tangent;
varying vec3 world_binormal;
varying vec2 source_uv2;
varying float instance_ground;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	instance_ground = MODEL_MATRIX[3].y;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	world_tangent = normalize(MODEL_NORMAL_MATRIX * TANGENT);
	world_binormal = normalize(MODEL_NORMAL_MATRIX * BINORMAL);
	// Godot's glTF importer maps TEXCOORD_2 to ARRAY_CUSTOM0.xy.
	source_uv2 = CUSTOM0.xy;
}

vec3 unpack_unreal_normal(vec3 encoded) {
	vec3 n = encoded * 2.0 - 1.0;
	n.y = -n.y;
	return normalize(n);
}

void fragment() {
	vec2 bark_uv = source_uv2 * uv_scale_base;
	vec3 bark = texture(bark_color, bark_uv).rgb;
	float rough = texture(bark_orm, bark_uv).g;
	vec3 detail_n = unpack_unreal_normal(texture(bark_normal, bark_uv).xyz);
	float moss_variation_value = texture(moss_variation, bark_uv).r;
	// BlendMaterialAttributes selects source TEXCOORD_2 and TEXCOORD_1 with
	// vertex red. Godot exposes them as CUSTOM0.xy and UV2 respectively.
	vec3 second_bark = texture(bark_color, UV2 * uv_scale_base).rgb;
	float second_rough = texture(bark_orm, UV2 * uv_scale_base).g;
	vec3 second_detail_n = unpack_unreal_normal(texture(bark_normal, UV2 * uv_scale_base).xyz);
	float second_moss_variation = texture(moss_variation, UV2 * uv_scale_base).r;
	bark = mix(bark, second_bark, COLOR.r);
	rough = mix(rough, second_rough, COLOR.r);
	detail_n = normalize(mix(detail_n, second_detail_n, COLOR.r));
	moss_variation_value = mix(moss_variation_value, second_moss_variation, COLOR.r);
	vec3 shape_n = unpack_unreal_normal(texture(base_normal, UV).xyz);
	vec3 combined_n = normalize(vec3(detail_n.xy + shape_n.xy, detail_n.z * shape_n.z));
	vec3 explicit_world_normal = normalize(world_tangent * combined_n.x
		+ world_binormal * combined_n.y + world_normal * combined_n.z);
	float moss_alpha = clamp(dot(explicit_world_normal, vec3(0.0, 1.0, 0.0))
		* 0.5 * upvector_sharpness + upvector_bias, 0.0, 1.0) * moss_amount;
	vec3 moss = (moss_variation_value + 0.5) * moss_color.rgb;
	vec3 local_color = mix(bark, moss, moss_alpha);
	float contact = clamp(texture(noise_texture, UV * noise_uv_scale).r
		+ (world_position.y - (ground_from_instance ? instance_ground : ground_height_m)) / max(terrain_blend_m, 0.00001)
		+ gradient_height, 0.0, 1.0);
	contact = mix(1.0, contact, foot_fade);
	ALBEDO = mix(season_ground_turn(ground_color.rgb, world_position), local_color, contact);
	NORMAL_MAP = normalize(mix(vec3(0.0, 0.0, 1.0), combined_n, contact)) * 0.5 + 0.5;
	ROUGHNESS = mix(1.0, rough, contact);
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
