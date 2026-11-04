shader_type spatial;

#define USE_ALPHA 0
#define USE_ALPHA_CUTOFF 0
#define USE_EMISSION 0
#define USE_REFLECTIONS 0
#define USE_NORMAL_MAP 0
#define USE_OCCLUSION 0
#define USE_HEIGHT_MAP 0
#define USE_ANISOTROPY 0
#define USE_BACKLIGHT 0
#define USE_REFRACTION 0

#if USE_ALPHA
render_mode depth_draw_always;
#endif

#include "includes/base-cel-shader.gdshaderinc"

#if USE_EMISSION
#include "includes/emission.gdshaderinc"
#endif

#if USE_REFLECTIONS
#include "includes/reflections.gdshaderinc"
#endif

#if USE_NORMAL_MAP
#include "includes/normal-map.gdshaderinc"
#endif

#if USE_OCCLUSION
#include "includes/occlusion.gdshaderinc"
#endif

#if USE_HEIGHT_MAP
#include "includes/height-map.gdshaderinc"
#endif

#if USE_ANISOTROPY
#include "includes/anisotropy.gdshaderinc"
#endif

#if USE_BACKLIGHT
#include "includes/backlight.gdshaderinc"
#endif

#if USE_REFRACTION
#include "includes/refraction.gdshaderinc"
#elif !USE_REFRACTION && USE_ALPHA
#include "includes/transparency.gdshaderinc"
#endif

group_uniforms BaseProperties;
#if USE_ALPHA_CUTOFF
uniform float alpha_cutoff: hint_range(0.0, 1.0) = 0.5;
#endif
uniform vec4 color: source_color = vec4(0.7, 0.12, 0.86, 1.0);
uniform sampler2D base_texture: source_color;
// Optional two-color palette replacement; original UV pattern is retained.
uniform bool replace_texture_palette = false;
uniform vec4 texture_palette_source_a: source_color = vec4(0.0);
uniform vec4 texture_palette_source_b: source_color = vec4(1.0);
uniform vec4 texture_palette_a: source_color = vec4(0.0);
uniform vec4 texture_palette_b: source_color = vec4(1.0);

vec3 coat_texture_rgb(vec2 uv) {
	vec3 rgb = texture(base_texture, uv).rgb;
	if (!replace_texture_palette) return rgb;
	vec3 axis = texture_palette_source_b.rgb - texture_palette_source_a.rgb;
	float blend = clamp(dot(rgb - texture_palette_source_a.rgb, axis) / max(dot(axis, axis), 0.000001), 0.0, 1.0);
	return mix(texture_palette_a.rgb, texture_palette_b.rgb, blend);
}
uniform vec4 specular: source_color = vec4(0.3, 0.3, 0.3, 0.5);
uniform sampler2D specular_texture: hint_default_white;
uniform vec4 fresnel: source_color = vec4(0.2, 0.2, 0.2, 0.3);
// HOME-EQUESTRIA: show-style two-tone. With alpha > 0 the unlit band takes this
// colour (scaled by the base texture, still under ambient light so night and
// AO darken it) while the lit band keeps `color`. Alpha 0 = eldskald's original.
uniform vec4 shadow_color: source_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform sampler2D fresnel_texture: hint_default_white;
group_uniforms;

varying vec3 SPECULAR_COLOR;
varying float SPECULAR_STRENGTH;
varying vec3 FRESNEL_COLOR;
varying float FRESNEL_STRENGTH;

varying vec2 base_uv;

group_uniforms Tiling;
uniform vec2 uv_scale = vec2(1,1);
uniform vec2 uv_offset = vec2(0,0);
group_uniforms;

// HOME-EQUESTRIA: pony coat slap wobble (off unless pony_flank_touch.gd drives it).
#include "res://world/characters/hybrid_mare/flank_jiggle.gdshaderinc"
#include "res://world/characters/openpony/lid_color.gdshaderinc"

void vertex() {
	eyelid_region = COLOR.rg;
	eyelid_position = (eyelid_rest_from_pose * vec4(VERTEX, 1.0)).xyz;
	VERTEX += flank_jiggle(VERTEX);
	UV = UV * uv_scale.xy + uv_offset.xy;
	#if !USE_HEIGHT_MAP
		base_uv = UV;
	#endif
}

void fragment() {
#if USE_HEIGHT_MAP
	base_uv = height_map_fragment(UV, VERTEX, TANGENT, BINORMAL, NORMAL);
#endif

#if USE_ALPHA
	float alpha = color.a * texture(base_texture, base_uv).a;
	ALBEDO *= alpha;
#elif USE_ALPHA_CUTOFF
	ALPHA = color.a * texture(base_texture, base_uv).a;
	ALPHA_SCISSOR_THRESHOLD = color.a * texture(base_texture, base_uv).a;
#endif

#if USE_REFRACTION && USE_ALPHA
	EMISSION += refraction_fragment(alpha, NORMAL, SCREEN_UV, FRAGCOORD.z);
#elif !USE_REFRACTION && USE_ALPHA
	EMISSION += transparency_fragment(alpha, SCREEN_UV);
#endif

	SPECULAR_COLOR = specular.rgb * texture(specular_texture, base_uv).rgb;
	SPECULAR_STRENGTH = specular.a * texture(specular_texture, base_uv).a;
	FRESNEL_COLOR = fresnel.rgb * texture(fresnel_texture, base_uv).rgb;
	FRESNEL_STRENGTH = fresnel.a * texture(fresnel_texture, base_uv).a;

#if USE_EMISSION
	EMISSION += emission_fragment(base_uv);
#endif

#if USE_REFLECTIONS
	Surface surf = reflections_fragment(UV);
	METALLIC = surf.metallic;
	ROUGHNESS = surf.roughness;
#endif

#if USE_NORMAL_MAP
	NormalData normal = normal_map_fragment(base_uv, NORMAL, TANGENT, BINORMAL);
	NORMAL = normal.vector;
	NORMAL_MAP = normal.map;
	NORMAL_MAP_DEPTH = normal.depth;
#endif

#if USE_OCCLUSION
	OcclusionData occlusion = occlusion_fragment(base_uv);
	AO = occlusion.ao;
	AO_LIGHT_AFFECT = occlusion.ao_light_affect;
#endif

#if USE_ANISOTROPY
	AnisotropyData aniso = anisotropy_fragment(UV);
	ANISOTROPY_DIR = aniso.direction;
	ANISOTROPY_RATIO = aniso.ratio;
#endif

#if USE_BACKLIGHT
	BACKLIGHT = backlight_fragment(base_uv);
#endif

	vec3 fill = color.rgb * coat_texture_rgb(base_uv);
	vec3 shade = shadow_color.rgb * coat_texture_rgb(base_uv);
	fill = freckled(colored_lid(fill, vec3(1.0)), vec3(1.0), base_uv);
	shade = freckled(colored_lid(shade, shadow_color.rgb / max(color.rgb, vec3(0.001))), shadow_color.rgb / max(color.rgb, vec3(0.001)), base_uv);
	ALBEDO = mix(fill, shade, shadow_color.a);
	// HOME-EQUESTRIA: no environment specular. The shader does its own banded
	// specular in light(); Godot's default SPECULAR 0.5 on top added a flat sky
	// sheen that kept cel surfaces glowing at night.
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
#if USE_BACKLIGHT
	DIFFUSE_LIGHT += backlight_diffuse(
			ALBEDO,
			LIGHT_COLOR,
			LIGHT,
			NORMAL,
			ATTENUATION,
			BACKLIGHT
	);
#else
	vec3 lit_fill = mix(ALBEDO, freckled(colored_lid(color.rgb * coat_texture_rgb(base_uv), vec3(1.0)), vec3(1.0), base_uv), shadow_color.a);
	DIFFUSE_LIGHT += diffuse_light(
			lit_fill,
			LIGHT_COLOR,
			LIGHT,
			NORMAL,
			ATTENUATION
	);
#endif

#if USE_ANISOTROPY
	SPECULAR_LIGHT += anisotropy_specular(
			LIGHT_COLOR,
			SPECULAR_COLOR,
			SPECULAR_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION,
			UV,
			ANISOTROPY_DIR,
			ANISOTROPY_RATIO
	);
#else
	SPECULAR_LIGHT += specular_light(
			LIGHT_COLOR,
			SPECULAR_COLOR,
			SPECULAR_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION
	);
#endif

	SPECULAR_LIGHT += fresnel_light(
			LIGHT_COLOR,
			FRESNEL_COLOR,
			FRESNEL_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION
	);
}
