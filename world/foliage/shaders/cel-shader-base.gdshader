// Derived by tools/build_vegetation_shaders.py; original cel shading retained. Hand-edited since
// 2026-11-08 (seasons: evergreen flag, autumn ramp, crown snow, leaf thinning); do not regenerate.
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

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"

#if USE_EMISSION
#include "res://addons/cel-shader/includes/emission.gdshaderinc"
#endif

#if USE_REFLECTIONS
#include "res://addons/cel-shader/includes/reflections.gdshaderinc"
#endif

#if USE_NORMAL_MAP
#include "res://addons/cel-shader/includes/normal-map.gdshaderinc"
#endif

#if USE_OCCLUSION
#include "res://addons/cel-shader/includes/occlusion.gdshaderinc"
#endif

#if USE_HEIGHT_MAP
#include "res://addons/cel-shader/includes/height-map.gdshaderinc"
#endif

#if USE_ANISOTROPY
#include "res://addons/cel-shader/includes/anisotropy.gdshaderinc"
#endif

#if USE_BACKLIGHT
#include "res://addons/cel-shader/includes/backlight.gdshaderinc"
#endif

#if USE_REFRACTION
#include "res://addons/cel-shader/includes/refraction.gdshaderinc"
#elif !USE_REFRACTION && USE_ALPHA
#include "res://addons/cel-shader/includes/transparency.gdshaderinc"
#endif

group_uniforms BaseProperties;
#if USE_ALPHA_CUTOFF
uniform float alpha_cutoff: hint_range(0.0, 1.0) = 0.5;
#endif
uniform vec4 color: source_color = vec4(0.7, 0.12, 0.86, 1.0);
uniform sampler2D base_texture: source_color;
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

#include "res://world/foliage/vegetation_color.gdshaderinc"
uniform float ground_hue_strength = 0.85;
varying vec4 local_ground_color;
// Seasons: x = deciduous share, y = snow response of the biome (vegetation_season_local);
// veg_fill = the lit band colour, worked out once in fragment() and reused by light().
varying vec2 season_local;
varying vec3 veg_fill;
varying vec3 veg_world_pos;
varying flat vec3 autumn_tree;
void vertex() {
veg_world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
local_ground_color=vegetation_ground(veg_world_pos.xz);
season_local=vegetation_season_local(veg_world_pos.xz);
autumn_tree=vegetation_autumn_tree(MODEL_MATRIX[3].xyz);
	UV = UV * uv_scale.xy + uv_offset.xy;
	#if !USE_HEIGHT_MAP
		base_uv = UV;
	#endif
}

void fragment() {
#if USE_HEIGHT_MAP
	base_uv = height_map_fragment(UV, VERTEX, TANGENT, BINORMAL, NORMAL);
#endif
	vec3 veg_dpdx = vec3(0.0);
	vec3 veg_dpdy = vec3(0.0);
	if (season_leaf_drop > 0.001) { veg_dpdx = dFdx(veg_world_pos); veg_dpdy = dFdy(veg_world_pos); }

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

	vec3 veg_texel = texture(base_texture, base_uv).rgb;
	// Seasons: leaf texels (not bark) thin in 0.8 m patches as the leaves fall (evergreens keep
	// theirs) and the fallen patches show bare twigs (vegetation_twig_world, 2026-11-09).
	// Opaque: a hole would need a discard, which costs every season, so the patch turns a dark
	// twig mass with the twig picture drawn over it.
	bool veg_bare = false;
	vec3 veg_twig_rgb = vec3(0.0);
	if (season_leaf_drop > 0.001 && vegetation_green_mask(color.rgb * veg_texel) > 0.3
			&& vegetation_patch_kept(vegetation_leaf_kept(vegetation_cell_hash(veg_world_pos, 0.8), 2.0, season_local.x, evergreen, 0.0), vegetation_cell_hash(veg_world_pos, 0.8), season_local.x, evergreen) < 0.5) {
		vec3 veg_n = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
		vec4 veg_twig = vegetation_twig_world(veg_world_pos, veg_dpdx, veg_dpdy, veg_n, 1.2, 0.6);
		veg_twig_rgb = mix(twig_color.rgb * 0.45, veg_twig.rgb, veg_twig.a);
		veg_twig_rgb = season_snow_albedo(veg_twig_rgb, vegetation_twig_snow(veg_n.y, season_local.y, 0.0) * 0.4);
		veg_bare = true;
	}
	float veg_strength = ground_hue_strength*vegetation_green_mask(color.rgb * veg_texel);
	// Crown snow on the upper hemisphere of the surface normal (world space).
	float veg_snow = season_snow_cover > 0.001 ? vegetation_crown_snow_amount((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, season_local.y) : 0.0;
	vec3 fill = vegetation_cel(color.rgb * veg_texel,local_ground_color,veg_strength,season_local,veg_snow,autumn_tree);
	vec3 shade = vegetation_cel(shadow_color.rgb * veg_texel,local_ground_color,veg_strength,season_local,veg_snow,autumn_tree);
	if (veg_bare) { fill = veg_twig_rgb; shade = veg_twig_rgb; }
	veg_fill = fill;
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
	vec3 lit_fill = mix(ALBEDO, veg_fill, shadow_color.a);
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
