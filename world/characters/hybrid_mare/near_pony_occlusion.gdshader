shader_type spatial;

// Near pony, occlusion variant (hybrid_near_mesh.gd): addons/cel-shader/cel-shader-occlusion
// .gdshader (the OpenPony head: baked AO plus the native snout ridge) with its colour uniforms
// moved into palette arrays, one entry per merged source surface (CUSTOM1.x). The AO map and its
// light affect are shared by every entry; the snout ridge is per entry (pal_snout), reading the
// rest-space coordinates the head carries in CUSTOM0 (snout_detail.gd).
// Lid colour and freckles (lid_color.gdshaderinc, the sculpted head's upper-lid skin in COLOR.rg) as
// on the rig: per entry (pal_lid) for the surfaces face_sculpt.gd dresses; the lid uniforms are the
// same on every such surface, so they stay single (perf 2026-11-21, draws lane).

#include "res://addons/cel-shader/includes/base-cel-shader.gdshaderinc"
#include "res://addons/cel-shader/includes/occlusion.gdshaderinc"
#include "res://world/characters/openpony/lid_color.gdshaderinc"

const int ENTRIES = 32;
uniform vec4 pal_color[ENTRIES];
uniform vec4 pal_specular[ENTRIES];
uniform vec4 pal_fresnel[ENTRIES];
uniform vec4 pal_shadow[ENTRIES];
uniform float pal_snout[ENTRIES];
uniform float pal_lid[ENTRIES];
uniform sampler2D base_texture: source_color;
uniform sampler2D specular_texture: hint_default_white;
uniform sampler2D fresnel_texture: hint_default_white;

varying vec3 SPECULAR_COLOR;
varying float SPECULAR_STRENGTH;
varying vec3 FRESNEL_COLOR;
varying float FRESNEL_STRENGTH;

varying vec2 base_uv;
varying flat int pal;
varying vec4 snout_rest;

// shaders/native_snout_detail.gdshaderinc with the switch per palette entry. `pal` is flat,
// so it is the same across a fragment quad and fwidth() stays well defined.
float snout_segment(vec3 p, vec3 a, vec3 b) {
	vec3 ab = b - a;
	return length(p - a - ab * clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0));
}

vec3 snout_tint() {
	if (!(pal_snout[pal] > 0.5)) return vec3(1.0);
	vec3 p = vec3(abs(snout_rest.x), snout_rest.yz);
	float d = snout_segment(p, vec3(0.0, .85981, -.45212), vec3(.00787, .85936, -.45119));
	d = min(d, snout_segment(p, vec3(.00787, .85936, -.45119), vec3(.01495, .85811, -.44885)));
	d = min(d, snout_segment(p, vec3(.01495, .85811, -.44885), vec3(.02096, .85608, -.44584)));
	d = min(d, snout_segment(p, vec3(.02096, .85608, -.44584), vec3(.02567, .85306, -.44259)));
	d = min(d, snout_segment(p, vec3(.02567, .85306, -.44259), vec3(.02955, .85165, -.43727)));
	float aa = max(fwidth(d), .00008);
	float line = 1.0 - smoothstep(.0007, .0007 + aa, d);
	line *= 1.0 - smoothstep(.022, .030, p.x);
	vec3 bridge = mix(vec3(1.0), vec3(.75, .85, .92), snout_rest.w);
	return mix(bridge, vec3(.51, .62, .74), line);
}

// Slap wobble, as on the rig coat (pony_flank_touch.gd drives it).
#include "res://world/characters/hybrid_mare/flank_jiggle.gdshaderinc"

// 1 for the palette entries that are her coat (pony_flank_touch.gd).
uniform float jiggle_entry[ENTRIES];

void vertex() {
	eyelid_region = COLOR.rg;
	eyelid_position = (eyelid_rest_from_pose * vec4(VERTEX, 1.0)).xyz;
	snout_rest = CUSTOM0;
	pal = int(CUSTOM1.x + 0.5);
	VERTEX += flank_jiggle(VERTEX) * jiggle_entry[pal];
	base_uv = UV;
}

void fragment() {
	vec4 color = pal_color[pal];
	vec4 specular = pal_specular[pal];
	vec4 fresnel = pal_fresnel[pal];
	vec4 shadow_color = pal_shadow[pal];
	SPECULAR_COLOR = specular.rgb * texture(specular_texture, base_uv).rgb;
	SPECULAR_STRENGTH = specular.a * texture(specular_texture, base_uv).a;
	FRESNEL_COLOR = fresnel.rgb * texture(fresnel_texture, base_uv).rgb;
	FRESNEL_STRENGTH = fresnel.a * texture(fresnel_texture, base_uv).a;

	OcclusionData occlusion = occlusion_fragment(base_uv);
	AO = occlusion.ao;
	AO_LIGHT_AFFECT = occlusion.ao_light_affect;

	vec3 fill = color.rgb * texture(base_texture, base_uv).rgb;
	vec3 shade = shadow_color.rgb * texture(base_texture, base_uv).rgb;
	// Computed for every entry (fwidth inside), kept only where the rig surface wears it.
	bool lid = pal_lid[pal] > 0.5;
	vec3 ratio = shadow_color.rgb / max(color.rgb, vec3(0.001));
	vec3 lid_fill = freckled(colored_lid(fill, vec3(1.0)), vec3(1.0), base_uv);
	vec3 lid_shade = freckled(colored_lid(shade, ratio), ratio, base_uv);
	fill = lid ? lid_fill : fill;
	shade = lid ? lid_shade : shade;
	ALBEDO = mix(fill, shade, shadow_color.a) * snout_tint();
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	vec4 color = pal_color[pal];
	vec4 shadow_color = pal_shadow[pal];
	vec3 base_fill = color.rgb * texture(base_texture, base_uv).rgb;
	vec3 lid_base = freckled(colored_lid(base_fill, vec3(1.0)), vec3(1.0), base_uv);
	vec3 lit_fill = mix(ALBEDO, (pal_lid[pal] > 0.5 ? lid_base : base_fill) * snout_tint(), shadow_color.a);
	DIFFUSE_LIGHT += diffuse_light(
			lit_fill,
			LIGHT_COLOR,
			LIGHT,
			NORMAL,
			ATTENUATION
	);
	SPECULAR_LIGHT += specular_light(
			LIGHT_COLOR,
			SPECULAR_COLOR,
			SPECULAR_STRENGTH,
			NORMAL,
			VIEW,
			LIGHT,
			ATTENUATION
	);
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
