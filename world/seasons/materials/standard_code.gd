extends RefCounted
## Seasons WP-C (W2-SEAS-C, M-SEA-14): the engine's own StandardMaterial3D shader code plus snow and
## wetness, for the material variants the town's roofs, fences, benches and props use.
##
## The text below follows Godot 4.5-stable BaseMaterial3D::_update_shader (scene/resources/
## material.cpp) line for line for the supported subset: opaque, alpha scissor and alpha hash;
## every cull, depth-draw, diffuse, specular, filter and roughness-channel mode; per-pixel and
## per-vertex shading; vertex colour, forced sRGB, normal map, emission (UV1). A material that uses
## anything else (ORM, triplanar, detail, rim, refraction, billboards, fades, stencil...) returns an
## empty variant and is left untouched. The engine cannot hand out its generated code headless (the
## dummy renderer returns ""), so the code is reproduced here; the season block goes at the end of
## fragment(), behind one uniform branch.
##
## variant(material) -> Dictionary of the shader-relevant settings ({} = unsupported)
## key(variant) -> String, the manifest key; code(variant) -> String, the full shader text
## material_for(source, shader) -> ShaderMaterial with the source's parameters (textures shared)

const GENERATOR_VERSION := 1
const INCLUDE := "res://world/seasons/season.gdshaderinc"
## Roof slopes hold snow up to ~60 degrees: the contract's up-facing test gets this much lift.
const ROOF_LIFT := 0.2

const FILTERS := ["filter_nearest", "filter_linear", "filter_nearest_mipmap", "filter_linear_mipmap",
		"filter_nearest_mipmap_anisotropic", "filter_linear_mipmap_anisotropic"]
const DEPTH_DRAW := [", depth_draw_opaque", ", depth_draw_always", ", depth_draw_never"]
const CULL := [", cull_back", ", cull_front", ", cull_disabled"]
const DIFFUSE := [", diffuse_burley", ", diffuse_lambert", ", diffuse_lambert_wrap", ", diffuse_toon"]
const SPECULAR := [", specular_schlick_ggx", ", specular_toon", ", specular_disabled"]
const ROUGHNESS_HINT := ["hint_roughness_r", "hint_roughness_g", "hint_roughness_b", "hint_roughness_a", "hint_roughness_gray"]
const ROUGHNESS_MASK := ["vec4(1.0, 0.0, 0.0, 0.0)", "vec4(0.0, 1.0, 0.0, 0.0)", "vec4(0.0, 0.0, 1.0, 0.0)",
		"vec4(0.0, 0.0, 0.0, 1.0)", "vec4(0.333333, 0.333333, 0.333333, 0.0)"]
const TEXTURE_MASKS := [Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0), Vector4(0, 0, 0, 1),
		Vector4(0.3333333, 0.3333333, 0.3333333, 0)]
## Features and flags this port does not reproduce: any of them set = unsupported.
const UNSUPPORTED_TRUE := ["rim_enabled", "clearcoat_enabled", "anisotropy_enabled", "ao_enabled",
		"heightmap_enabled", "subsurf_scatter_enabled", "subsurf_scatter_transmittance_enabled",
		"backlight_enabled", "refraction_enabled", "detail_enabled", "bent_normal_enabled",
		"uv1_triplanar", "uv2_triplanar", "albedo_texture_msdf", "use_point_size", "fixed_size",
		"use_particle_trails", "grow", "proximity_fade_enabled", "no_depth_test", "use_z_clip_scale",
		"use_fov_override", "emission_on_uv2"]

## The settings that shape this material's shader, or {} when the port does not cover it.
static func variant(source: Material) -> Dictionary:
	if not source is StandardMaterial3D: return {}   # ORMMaterial3D and ShaderMaterial are not converted
	var m := source as StandardMaterial3D
	if m.next_pass != null: return {}
	if m.blend_mode != BaseMaterial3D.BLEND_MODE_MIX: return {}
	if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED: return {}
	if m.transparency not in [BaseMaterial3D.TRANSPARENCY_DISABLED, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, BaseMaterial3D.TRANSPARENCY_ALPHA_HASH]: return {}
	if m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED: return {}
	if m.distance_fade_mode != BaseMaterial3D.DISTANCE_FADE_DISABLED: return {}
	if m.depth_test != BaseMaterial3D.DEPTH_TEST_DEFAULT: return {}
	if m.stencil_mode != BaseMaterial3D.STENCIL_MODE_DISABLED: return {}
	for flag: String in UNSUPPORTED_TRUE:
		if bool(m.get(flag)): return {}
	var scissor_or_hash := m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
	return {
		"transparency": int(m.transparency),
		"alpha_aa": int(m.alpha_antialiasing_mode) if scissor_or_hash else 0,
		"depth_draw": int(m.depth_draw_mode),
		"cull": int(m.cull_mode),
		"diffuse": int(m.diffuse_mode),
		"specular": int(m.specular_mode),
		"vertex_lighting": m.shading_mode == BaseMaterial3D.SHADING_MODE_PER_VERTEX,
		"filter": int(m.texture_filter),
		"repeat": m.texture_repeat,
		"vertex_srgb": m.vertex_color_is_srgb,
		"vertex_albedo": m.vertex_color_use_as_albedo,
		"force_srgb": m.albedo_texture_force_srgb,
		"no_shadows": m.disable_receive_shadows,
		"no_ambient": m.disable_ambient_light,
		"shadow_to_opacity": m.shadow_to_opacity,
		"no_fog": m.disable_fog,
		"no_spec_occlusion": m.disable_specular_occlusion,
		"roughness_channel": int(m.roughness_texture_channel),
		"detail_uv2": m.detail_uv_layer == BaseMaterial3D.DETAIL_UV_2,
		"normal": m.normal_enabled,
		"emission": m.emission_enabled,
		"emission_multiply": m.emission_enabled and m.emission_operator == BaseMaterial3D.EMISSION_OP_MULTIPLY,
	}

static func key(v: Dictionary) -> String:
	var names: Array = v.keys()
	names.sort()
	var parts := PackedStringArray()
	for name: String in names: parts.append("%s=%s" % [name, str(v[name])])
	return "g%d:%s" % [GENERATOR_VERSION, ",".join(parts)]

## The generated shader text for a variant (deterministic: the file name is its md5).
static func code(v: Dictionary) -> String:
	var t: int = v.transparency
	var scissor := t == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var hashed := t == BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
	var aa: int = v.alpha_aa
	var tf: String = FILTERS[int(v.filter)] + (", repeat_enable" if v.repeat else ", repeat_disable")
	var c := "// NOTE: Shader automatically converted from Godot Engine 4.5.stable's StandardMaterial3D.\n"
	c += "// Seasons WP-C: generated by tools/seasons/build_snow_materials.gd (world/seasons/materials/standard_code.gd).\n"
	c += "// Do not edit; regenerate. Season block at the end of fragment().\n\n"
	c += "shader_type spatial;\nrender_mode blend_mix"
	c += DEPTH_DRAW[int(v.depth_draw)] + CULL[int(v.cull)] + DIFFUSE[int(v.diffuse)] + SPECULAR[int(v.specular)]
	if v.vertex_lighting: c += ", vertex_lighting"
	if v.no_shadows: c += ", shadows_disabled"
	if v.no_ambient: c += ", ambient_light_disabled"
	if v.shadow_to_opacity: c += ", shadow_to_opacity"
	if v.no_fog: c += ", fog_disabled"
	if v.no_spec_occlusion: c += ", specular_occlusion_disabled"
	if scissor or hashed:
		if aa == BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE: c += ", alpha_to_coverage"
		elif aa == BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE: c += ", alpha_to_coverage_and_one"
	c += ";\n"
	c += "\n#include \"%s\"\n" % INCLUDE
	c += "\nuniform vec4 albedo : source_color;\nuniform sampler2D texture_albedo : source_color, %s;\n" % tf
	if scissor: c += "uniform float alpha_scissor_threshold : hint_range(0.0, 1.0, 0.001);\n"
	elif hashed: c += "uniform float alpha_hash_scale : hint_range(0.0, 2.0, 0.01);\n"
	if aa != BaseMaterial3D.ALPHA_ANTIALIASING_OFF and (scissor or hashed):
		c += "uniform float alpha_antialiasing_edge : hint_range(0.0, 1.0, 0.01);\n"
	c += "uniform ivec2 albedo_texture_size;\n"
	c += "uniform float point_size : hint_range(0.1, 128.0, 0.1);\n"
	c += "\nuniform float roughness : hint_range(0.0, 1.0);\nuniform sampler2D texture_metallic : hint_default_white, %s;\nuniform vec4 metallic_texture_channel;\n" % tf
	c += "uniform sampler2D texture_roughness : %s, %s;\n" % [ROUGHNESS_HINT[int(v.roughness_channel)], tf]
	c += "\nuniform float specular : hint_range(0.0, 1.0, 0.01);\nuniform float metallic : hint_range(0.0, 1.0, 0.01);\n"
	if v.emission:
		c += "\nuniform sampler2D texture_emission : source_color, hint_default_black, %s;\nuniform vec4 emission : source_color;\nuniform float emission_energy : hint_range(0.0, 100.0, 0.01);\n" % tf
	if v.normal:
		c += "\nuniform sampler2D texture_normal : hint_roughness_normal, %s;\nuniform float normal_scale : hint_range(-16.0, 16.0);\n" % tf
	c += "\nuniform vec3 uv1_scale;\nuniform vec3 uv1_offset;\nuniform vec3 uv2_scale;\nuniform vec3 uv2_offset;\n"
	# Vertex.
	c += "\nvoid vertex() {"
	if v.vertex_srgb:
		c += "\n\t// Vertex Color is sRGB: Enabled\n\tif (!OUTPUT_IS_SRGB) {\n\t\tCOLOR.rgb = mix(\n\t\t\t\tpow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),\n\t\t\t\tCOLOR.rgb * (1.0 / 12.92),\n\t\t\t\tlessThan(COLOR.rgb, vec3(0.04045)));\n\t}\n"
	if v.vertex_lighting:
		c += "\n\t// Shading Mode: Per Vertex\n\tROUGHNESS = roughness;\n"
	c += "\n\tUV = UV * uv1_scale.xy + uv1_offset.xy;\n"
	if v.detail_uv2:
		c += "\t// Detail UV Layer: UV2\n\tUV2 = UV2 * uv2_scale.xy + uv2_offset.xy;\n"
	c += "}\n"
	# Fragment.
	c += "\nvoid fragment() {"
	c += "\n\tvec2 base_uv = UV;\n"
	c += "\n\tvec4 albedo_tex = texture(texture_albedo, base_uv);\n"
	if v.force_srgb:
		c += "\n\t// Albedo Texture Force sRGB: Enabled\n\talbedo_tex.rgb = mix(\n\t\t\tpow((albedo_tex.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)),\n\t\t\talbedo_tex.rgb.rgb * (1.0 / 12.92),\n\t\t\tlessThan(albedo_tex.rgb, vec3(0.04045)));\n"
	if v.vertex_albedo:
		c += "\n\t// Vertex Color Use as Albedo: Enabled\n\talbedo_tex *= COLOR;\n\n"
	c += "\tALBEDO = albedo.rgb * albedo_tex.rgb;\n"
	c += "\n\tfloat metallic_tex = dot(texture(texture_metallic, base_uv), metallic_texture_channel);\n"
	c += "\tMETALLIC = metallic_tex * metallic;\n\tSPECULAR = specular;\n"
	c += "\n\tvec4 roughness_texture_channel = %s;\n" % ROUGHNESS_MASK[int(v.roughness_channel)]
	c += "\tfloat roughness_tex = dot(texture(texture_roughness, base_uv), roughness_texture_channel);\n"
	c += "\tROUGHNESS = roughness_tex * roughness;\n"
	if v.normal:
		c += "\n\t// Normal Map: Enabled\n\tNORMAL_MAP = texture(texture_normal, base_uv).rgb;\n\tNORMAL_MAP_DEPTH = normal_scale;\n"
	if v.emission:
		c += "\n\t// Emission: Enabled\n\tvec3 emission_tex = texture(texture_emission, base_uv).rgb;\n"
		if v.emission_multiply:
			c += "\t// Emission Operator: Multiply\n\tEMISSION = (emission.rgb * emission_tex) * emission_energy;\n"
		else:
			c += "\t// Emission Operator: Add\n\tEMISSION = (emission.rgb + emission_tex) * emission_energy;\n"
	if t != BaseMaterial3D.TRANSPARENCY_DISABLED or v.shadow_to_opacity:
		c += "\tALPHA *= albedo.a * albedo_tex.a;\n"
	if hashed: c += "\tALPHA_HASH_SCALE = alpha_hash_scale;\n"
	elif scissor: c += "\tALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;\n"
	if aa != BaseMaterial3D.ALPHA_ANTIALIASING_OFF and (scissor or hashed):
		c += "\tALPHA_ANTIALIASING_EDGE = alpha_antialiasing_edge;\n\tALPHA_TEXTURE_COORDINATE = UV * vec2(albedo_texture_size);\n"
	c += season_block(v.normal)
	c += "}\n"
	return c

## Snow on up-facing outside faces (roof slopes, sills, seats, rails), wet darkening in rain. Back
## faces (a two-sided shell seen from inside the house) never take either. One uniform branch while
## the season is dry and bare; ~20 ALU and two small fetches per fragment otherwise.
static func season_block(normal_map: bool) -> String:
	var c := "\n\t// Seasons WP-C: snow and wetness (world/seasons/season.gdshaderinc contract).\n"
	c += "\tif (FRONT_FACING && (season_snow_cover > 0.001 || season_wetness > 0.001)) {\n"
	c += "\t\tvec3 season_n = mat3(INV_VIEW_MATRIX) * NORMAL;\n"
	c += "\t\tvec3 season_p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;\n"
	c += "\t\tfloat season_cover = season_snow_on(vec3(season_n.x, season_n.y + %s, season_n.z), season_p);\n" % str(ROOF_LIFT)
	c += "\t\tALBEDO = season_snow_albedo(ALBEDO, season_cover);\n"
	c += "\t\tROUGHNESS = mix(ROUGHNESS, 0.9, season_cover);\n"
	c += "\t\tMETALLIC = mix(METALLIC, 0.0, season_cover);\n"
	if normal_map:
		c += "\t\tNORMAL_MAP = mix(NORMAL_MAP, vec3(0.5, 0.5, 1.0), season_cover);\n"
	c += "\t\tfloat season_wet_here = season_wet_amount(season_p) * (0.5 + 0.5 * clamp(season_n.y, 0.0, 1.0)) * (1.0 - season_cover);\n"
	c += "\t\tseason_wet(ALBEDO, ROUGHNESS, season_wet_here);\n"
	c += "\t}\n"
	return c

## A ShaderMaterial on `shader` carrying the source's parameters exactly as BaseMaterial3D pushes them
## to the renderer (textures are the source's own objects: no copy, no extra VRAM).
static func material_for(source: StandardMaterial3D, shader: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.resource_name = source.resource_name + " (season)"
	m.render_priority = source.render_priority
	for entry: Array in parameters(source):
		m.set_shader_parameter(entry[0], entry[1])
	return m

## [uniform name, value] pairs for a source material (the subset the generated code declares).
static func parameters(s: StandardMaterial3D) -> Array:
	var out: Array = [
		["albedo", s.albedo_color],
		["texture_albedo", s.albedo_texture],
		["point_size", s.point_size],
		["roughness", s.roughness],
		["texture_metallic", s.metallic_texture],
		["metallic_texture_channel", TEXTURE_MASKS[int(s.metallic_texture_channel)]],
		["texture_roughness", s.roughness_texture],
		["specular", s.metallic_specular],
		["metallic", s.metallic],
		["uv1_scale", s.uv1_scale],
		["uv1_offset", s.uv1_offset],
		["uv2_scale", s.uv2_scale],
		["uv2_offset", s.uv2_offset],
	]
	if s.albedo_texture != null:
		out.append(["albedo_texture_size", Vector2i(s.albedo_texture.get_width(), s.albedo_texture.get_height())])
	if s.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR: out.append(["alpha_scissor_threshold", s.alpha_scissor_threshold])
	if s.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_HASH: out.append(["alpha_hash_scale", s.alpha_hash_scale])
	if s.alpha_antialiasing_mode != BaseMaterial3D.ALPHA_ANTIALIASING_OFF: out.append(["alpha_antialiasing_edge", s.alpha_antialiasing_edge])
	if s.emission_enabled:
		var energy := s.emission_energy_multiplier
		if bool(ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)):
			energy *= s.emission_intensity
		out.append(["emission", s.emission])
		out.append(["emission_energy", energy])
		out.append(["texture_emission", s.emission_texture])
	if s.normal_enabled:
		out.append(["normal_scale", s.normal_scale])
		out.append(["texture_normal", s.normal_texture])
	return out
