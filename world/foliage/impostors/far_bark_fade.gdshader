shader_type spatial;
render_mode diffuse_burley, specular_disabled;
#include "res://world/foliage/impostors/impostor_fade.gdshaderinc"
// The far tree's bark (its StandardMaterial3D: albedo texture, rough, no specular) with the
// impostor crossfade, used only by far tiles whose species has an impostor.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
varying float fade_t;

void vertex() {
	fade_t = impostor_fade_amount(MAIN_CAM_INV_VIEW_MATRIX[3].xyz, MODEL_MATRIX[3].xyz);
}

void fragment() {
	// The bark is read before the dither discard: that discard removes single pixels of a 2x2 quad,
	// and the texture's mip (screen derivatives) taken after it is undefined in Vulkan (AMD report
	// 2026-11-12, docs/THREAD_FIX_AMD_TREES_2026_11_19.md). Same value wherever it was defined.
	vec3 bark = texture(albedo_texture, UV).rgb;
	if (impostor_dither(FRAGCOORD.xy) < fade_t) { discard; }
	ALBEDO = albedo_color.rgb * bark;
	ROUGHNESS = 1.0;
}
