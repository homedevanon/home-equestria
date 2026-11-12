extends RefCounted
## NEAR render detail for the hybrid mare (HERO and NEAR tiers): the rig meshes of each skeleton
## merged into as few MeshInstance3D and surfaces as the look allows, at full detail.
##
## Why (tools/profile/skin_bench.gd, 2026-09-25, 47 walking ponies on the real renderer): a pony
## drew ~17 visible skinned MeshInstance3D over three skeletons (native body, OpenPony head, devkit
## hair) with ~42 surfaces, most of them cel-shaded with a hull outline pass; the cost was CPU
## side, per instance, per surface and per draw, while the GPU sat mostly idle.
##
## What merges: rig meshes on the same skeleton AND the same Skin with the same instance settings
## (render layers, shadow casting, world-ink mask eligibility, visibility range, ...). Inside one
## merged mesh:
## - cel-shaded surfaces (cel-shader-base / cel-shader-occlusion with the lit outline hull) become
##   ONE surface per shader and texture. near_pony*.gdshader are the rig shaders with their
##   material values moved into palette arrays, one entry per source surface (CUSTOM1.x), so every
##   colour, shade, specular, line colour and outline width stays exactly as it was;
## - other surfaces with equal materials (the two cutie mark patches) are concatenated;
## - anything else stays a surface of its own with its own material.
## Kept apart, untouched: meshes with any other shader (the eye, brows and lashes: per-eye
## uniforms that animate, and a blend shape), with blend shapes, with a material_override, not
## skinned (the hat on its BoneAttachment3D), with compressed vertex data, and meshes other code
## shows and hides at runtime (the folded wings swap with the open ones in flight,
## hybrid_open_wings.gd). The hair gets a second merged mesh for its LOD1 copies.
##
## The merged vertex data is the rig's, byte for byte: positions, UVs, bones and weights survive
## surface_get_arrays exactly, and the octahedral normal/tangent stream, which does not survive a
## decode/encode round trip, is copied from the rig meshes' stored bytes. Skinning stays with
## each mesh's own skeleton and Skin (bind indices unchanged), so face bones, mouth, lids, ears,
## tail and hair springs move exactly as before and no skin upload is added. The rig meshes' own
## LODs are carried over level by level: at each merged edge length every source contributes its
## coarsest level whose edge length is not above it, so no source is ever coarser than it was on
## its own (it can be a little finer: the merged mesh has one bounding box). Sources without LODs
## (the head: removed on purpose, snout_detail.gd) stay at full detail in every level.
##
## The geometry is built once per identity (gathered on the main thread, concatenated on a
## worker, like hybrid_far_mesh.gd) and cached; materials are built per pony from its own rig
## materials. The rig meshes stay in the tree, hidden (meta `near_hidden`, holding whether each
## was shown), as the fallback and as the far mesh's gather sources. `--near-mesh off` on the
## command line disables it (A/B).

const PALETTE := preload("res://world/characters/hybrid_mare/near_pony.gdshader")
const PALETTE_OCCLUSION := preload("res://world/characters/hybrid_mare/near_pony_occlusion.gdshader")
const PALETTE_OUTLINE := preload("res://world/characters/hybrid_mare/near_pony_outline.gdshader")
const CEL_BASE := preload("res://addons/cel-shader/cel-shader-base.gdshader")
const CEL_OCCLUSION := preload("res://addons/cel-shader/cel-shader-occlusion.gdshader")
const CEL_CUTOUT := preload("res://addons/cel-shader/cel-shader-cutout.gdshader")
const OUTLINE_LIT := preload("res://addons/cel-shader/cel-outline-lit.gdshader")
const OUTLINE_TINTED := preload("res://addons/cel-shader/outline-tinted.gdshader")
const ENTRIES := 32  # palette size, as declared in near_pony*.gdshader
## Rig meshes other code shows and hides at runtime; never merged.
const KEEP_APART := ["wing folded", "HornMagic"]
## A merged LOD level starts where a source level's edge length exceeds the previous merged
## level's by this ratio (fewer index buffers; in between, sources stay one level finer).
const LOD_STEP := 1.5
const SOURCES := preload("res://world/characters/crowd/mesh_source_cache.gd")
const META := &"near_mesh"
const HIDDEN := &"near_hidden"
const INK := &"near_ink"
const CUSTOM_FORMATS := 0x1FFE000  # ARRAY_FORMAT_CUSTOM0..3 format bits

static var enabled := _enabled_from_args()
static var cache: Dictionary = {}     # key -> plan {"groups": [...]} (no groups = nothing to merge)
static var _pending: Dictionary = {}  # key -> {task, job}

## Scene teardown must join even builds whose pony unloaded before requesting
## the result. Completed pool tasks otherwise retain their source materials.
static func discard_pending() -> void:
	for pending: Dictionary in _pending.values():
		WorkerThreadPool.wait_for_task_completion(pending.task)
	_pending.clear()
	SOURCES.clear()


## Behind the loading cover (game_loading.gd): assembles worker builds that finished but that no
## pony collected (the one that asked changed tier or stopped waiting), so they do not wait for a
## frame in play; returns the builds still running.
static func harvest() -> int:
	var running := 0
	for k: String in _pending.keys():
		var pending: Dictionary = _pending[k]
		if not WorkerThreadPool.is_task_completed(pending.task):
			running += 1
			continue
		WorkerThreadPool.wait_for_task_completion(pending.task)
		_pending.erase(k)
		cache[k] = _assemble(pending.job)
	return running


static func _enabled_from_args() -> bool:
	var args := preload("res://world/dev_tools.gd").user_args()
	var i := args.find("--near-mesh")
	return not (i >= 0 and i + 1 < args.size() and args[i + 1] == "off")


static func key(pony: Node) -> String:
	var identity: Resource = pony.get("identity")
	return "%s%s|v%d" % [String(identity.id) if identity != null else "default",
		":reference-face" if pony.get("reference_face_enabled") else "", int(pony.get("shading_version"))] + ("|geometry=" + str(pony.get_meta(&"geometry_variant")) if pony.has_meta(&"geometry_variant") and not str(pony.get_meta(&"geometry_variant")).is_empty() else "")


## True for rig meshes that show, or showed before the near mesh hid them (the far mesh gathers these).
static func shown(mi: Node3D) -> bool:
	return mi.visible or bool(mi.get_meta(HIDDEN, false))


## The cached plan for `pony`'s identity, or null while it is being built (kicks the build).
static func request(pony: Node) -> Variant:
	var k := key(pony)
	if cache.has(k):
		return cache[k]
	if _pending.has(k):
		var pending: Dictionary = _pending[k]
		if not WorkerThreadPool.is_task_completed(pending.task):
			return null
		WorkerThreadPool.wait_for_task_completion(pending.task)
		_pending.erase(k)
		cache[k] = _assemble(pending.job)
		return cache[k]
	preload("res://world/debug/hitch_monitor.gd").mark("near mesh gather " + k)
	var job := _gather(pony)
	var task := WorkerThreadPool.add_task(_build.bind(job), false, "Near mesh " + k)
	_pending[k] = {"task": task, "job": job}
	return null


## Synchronous build (tools, tests); also fills the cache.
static func build_now(pony: Node) -> Dictionary:
	var k := key(pony)
	if not cache.has(k):
		var job := _gather(pony)
		_build(job)
		cache[k] = _assemble(job)
	return cache[k]


# --- Gather (main thread) ----------------------------------------------------------------------

## Rig meshes to merge per skeleton: [label, skeleton, {variant: [MeshInstance3D]}].
static func _skeleton_sets(pony: Node) -> Array:
	var sets := []
	var body: Skeleton3D = pony.get("skeleton")
	var model: Node = pony.get("_model")
	if body != null and model != null:
		sets.append(["Body", body, {"full": _shown_meshes(model)}])
	var head: Node = pony.get("head")
	var head_model: Node = pony.get("_head_model")
	if head != null and head_model != null and head.get("skeleton") != null:
		sets.append(["Head", head.get("skeleton"), {"full": _shown_meshes(head_model)}])
	var hair: Node = pony.get("hair")
	var hair_skeleton: Skeleton3D = pony.get("hair_skeleton")
	var identity: Resource = pony.get("identity")
	if hair != null and hair_skeleton != null and identity != null:
		var full := _hair_meshes(hair, identity, false)
		var lod := _hair_meshes(hair, identity, true)
		var variants := {"full": full}
		if lod != full:
			variants["lod"] = lod
		sets.append(["Hair", hair_skeleton, variants])
	return sets


static func _shown_meshes(root: Node) -> Array:
	var out := []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if mi.visible and not mi.has_meta(META):
			out.append(mi)
	return out


## The hair meshes shown at one hair LOD (hybrid_mare._apply_hair_lod): mane and tail, their
## LOD1 copies where the export carries them, and the identity's accessories.
static func _hair_meshes(hair: Node, identity: Resource, lod: bool) -> Array:
	var out := []
	for mi in hair.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta(META):
			continue
		var n := String(mi.name)
		var is_lod := n.ends_with("LOD1")
		var base := n.trim_suffix("LOD1")
		if base == identity.hair_prefix + "DevkitMane" or base == identity.hair_prefix + "DevkitTail":
			var has_lod: bool = hair.find_child(base + "LOD1", true, false) != null
			if (is_lod if has_lod and lod else not is_lod):
				out.append(mi)
		elif n in identity.accessories and mi.visible:
			out.append(mi)
	return out


static func _gather(pony: Node) -> Dictionary:
	var job := {"key": key(pony), "groups": []}
	var identity: Resource = pony.get("identity")
	SOURCES.begin(String(identity.id) if identity != null else "default")
	for entry in _skeleton_sets(pony):
		var label: String = entry[0]
		var skeleton: Skeleton3D = entry[1]
		var variants: Dictionary = entry[2]
		var skin := _common_skin(variants, skeleton)
		if skin == null:
			continue
		# Candidates per instance-settings key, per variant.
		var by_key := {}
		var seen := {}  # a mesh in both hair variants is read once
		for vname in variants:
			for mi in variants[vname]:
				if not seen.has(mi):
					seen[mi] = _candidate(pony, mi, skeleton, skin)
				var info: Dictionary = seen[mi]
				if info.is_empty():
					continue
				var group: Dictionary = by_key.get(info.group_key, {})
				var list: Array = group.get(vname, [])
				list.append(info)
				group[vname] = list
				by_key[info.group_key] = group
		var index := 0
		for gk in by_key:
			var group: Dictionary = by_key[gk]
			if not group.has("full"):
				continue
			var built := {}
			var worthwhile := false
			for vname in group:
				var outputs := _outputs(group[vname])
				var surfaces := 0
				var sources := []
				var counts := {}
				for info in group[vname]:
					surfaces += (info.counts as Array).size()
					sources.append(info.path)
					counts[info.path] = info.counts
				worthwhile = worthwhile or group[vname].size() > 1 or outputs.size() < surfaces
				built[vname] = {"outputs": outputs, "sources": sources, "counts": counts}
			if not worthwhile:
				continue
			job.groups.append({"name": "Near%s%s" % [label, "" if index == 0 else str(index)],
				"skeleton": pony.get_path_to(skeleton), "skin": skin, "ink": group.full[0].ink, "variants": built})
			index += 1
	return job


## The Skin most rig meshes of this skeleton use (they normally all share the import's one).
static func _common_skin(variants: Dictionary, skeleton: Skeleton3D) -> Skin:
	var counts := {}
	var best: Skin = null
	for vname in variants:
		for mi in variants[vname]:
			var m := mi as MeshInstance3D
			if m.skin == null or m.get_node_or_null(m.skeleton) != skeleton:
				continue
			counts[m.skin] = int(counts.get(m.skin, 0)) + 1
			if best == null or counts[m.skin] > counts[best]:
				best = m.skin
	return best


## One rig mesh as a merge source, or {} when it stays apart.
static func _candidate(pony: Node, mi: MeshInstance3D, skeleton: Skeleton3D, skin: Skin) -> Dictionary:
	var mesh := mi.mesh as ArrayMesh
	if mesh == null or mesh.get_blend_shape_count() > 0 or mi.material_override != null:
		return {}
	if mi.skin != skin or mi.get_node_or_null(mi.skeleton) != skeleton:
		return {}
	if not (skeleton.global_transform.affine_inverse() * mi.global_transform).is_equal_approx(Transform3D.IDENTITY):
		return {}
	for prefix in KEEP_APART:
		if String(mi.name).begins_with(prefix):
			return {}
	if mi.material_overlay != null and not mi.has_meta(&"post_outline_exclusion"):
		return {}
	var surfaces := []
	var counts := []
	for si in mesh.get_surface_count():
		var format := mesh.surface_get_format(si)
		if mesh.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES or (format & Mesh.ARRAY_FORMAT_INDEX) == 0 \
				or (format & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0 or (format & Mesh.ARRAY_FORMAT_BONES) == 0:
			return {}
		var material := mi.get_active_material(si)
		var kind := _kind(material, format)
		if kind.is_empty():
			return {}
		counts.append(mesh.surface_get_array_len(si))
		surfaces.append({"si": si, "material": material, "kind": kind[0], "class": kind[1], "format": format})
	var settings := [mi.layers, mi.cast_shadow, mi.gi_mode, mi.visibility_range_begin, mi.visibility_range_end,
		mi.visibility_range_begin_margin, mi.visibility_range_end_margin, mi.visibility_range_fade_mode,
		mi.extra_cull_margin, mi.lod_bias, mi.transparency, mi.ignore_occlusion_culling, _ink_eligible(mi)]
	# Mesh data (GPU readback, once per identity). The stored form ("_surfaces", the saved-resource
	# layout) gives the exact normal/tangent bytes and the LOD index buffers
	# (RenderingServer.mesh_get_surface returns a "lods" array that contains itself in 4.5).
	# Shared imported meshes are read once per session (mesh_source_cache.gd), not per identity.
	var stored: Array = SOURCES.stored(mesh)
	for s in surfaces:
		var raw: Dictionary = stored[s.si] if s.si < stored.size() else {}
		s["arrays"] = SOURCES.arrays(mesh, s.si)
		s["lods"] = _lods(raw)
		s["normals"] = _normal_stream(raw)
	return {"mi": mi, "path": pony.get_path_to(mi), "surfaces": surfaces, "counts": counts,
		"ink": _ink_eligible(mi), "group_key": var_to_str(settings)}


## hybrid_mare._exclude_world_ink's rule: the mesh gets the world-ink mask when its first
## surface wears a hull outline.
static func _ink_eligible(mi: MeshInstance3D) -> bool:
	var mat := mi.get_active_material(0) as ShaderMaterial
	if mat == null or mat.next_pass == null:
		return false
	var hull := mat.next_pass as ShaderMaterial
	return hull != null and (hull.shader == OUTLINE_LIT or hull.shader == OUTLINE_TINTED)


## The stored normal/tangent stream of one surface: {bytes, stride} (after the positions in
## vertex_data, 4 bytes of octahedral normal and 4 of tangent per vertex), or {}.
static func _normal_stream(raw: Dictionary) -> Dictionary:
	var format := int(raw.get("format", 0))
	var count := int(raw.get("vertex_count", 0))
	if (format & Mesh.ARRAY_FORMAT_NORMAL) == 0 or count == 0:
		return {}
	var offset := RenderingServer.mesh_surface_get_format_offset(format, count, Mesh.ARRAY_NORMAL)
	var stride := RenderingServer.mesh_surface_get_format_normal_tangent_stride(format, count)
	var data: PackedByteArray = raw.get("vertex_data", PackedByteArray())
	if data.size() != offset + count * stride:
		return {}
	return {"bytes": data.slice(offset), "stride": stride}


## LOD levels of one stored surface as [[edge_length, index bytes, bytes per index], ...].
static func _lods(raw: Dictionary) -> Array:
	var out := []
	var flat: Array = raw.get("lods", [])
	var count := int(raw.get("index_count", 0))
	var width := 2
	if count > 0 and (raw.get("index_data", PackedByteArray()) as PackedByteArray).size() >= count * 4:
		width = 4
	for i in range(0, flat.size() - 1, 2):
		out.append([float(flat[i]), flat[i + 1], width])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out


## [kind, class] for one surface: "palette"/"occlusion" (merged through near_pony*.gdshader,
## class = what the entries must share), "copy" (concatenated with equal materials); [] = apart.
static func _kind(material: Material, format: int) -> Array:
	if material == null:
		return []
	var needed := Mesh.ARRAY_FORMAT_VERTEX | Mesh.ARRAY_FORMAT_NORMAL | Mesh.ARRAY_FORMAT_TEX_UV
	if material is ShaderMaterial:
		var sm := material as ShaderMaterial
		if sm.shader != CEL_BASE and sm.shader != CEL_OCCLUSION and sm.shader != CEL_CUTOUT:
			return []
		if not _hull_ok(sm.next_pass):
			return []
		if (format & needed) == needed and _palette_ok(sm):
			var hull := sm.next_pass as ShaderMaterial
			if sm.shader == CEL_BASE:
				return ["palette", [sm.get_shader_parameter("base_texture"), hull != null]]
			if sm.shader == CEL_OCCLUSION:
				return ["occlusion", [sm.get_shader_parameter("base_texture"), hull != null,
					sm.get_shader_parameter("ao_map"), _param(sm, "ao_light_affect", 0.0)]]
		return ["copy", sm]
	if material is BaseMaterial3D and material.next_pass == null:
		return ["copy", material]
	return []


static func _hull_ok(pass_material: Material) -> bool:
	if pass_material == null:
		return true
	var hull := pass_material as ShaderMaterial
	return hull != null and hull.next_pass == null and (hull.shader == OUTLINE_LIT or hull.shader == OUTLINE_TINTED)


## Only the uniforms near_pony*.gdshader carry per entry may differ from the defaults.
static func _palette_ok(sm: ShaderMaterial) -> bool:
	if sm.render_priority != 0 or bool(_param(sm, "replace_texture_palette", false)):
		return false
	for material in [sm, sm.next_pass]:
		if material == null:
			continue
		var m := material as ShaderMaterial
		if m.shader == OUTLINE_TINTED or m.render_priority != 0:
			return false
		if _param(m, "uv_scale", Vector2.ONE) != Vector2.ONE or _param(m, "uv_offset", Vector2.ZERO) != Vector2.ZERO:
			return false
		if m.get_shader_parameter("specular_texture") != null or m.get_shader_parameter("fresnel_texture") != null:
			return false
		if m != sm and m.get_shader_parameter("base_texture") != null:
			return false
	return true


static func _param(material: ShaderMaterial, name: String, fallback: Variant) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	if value == null and material.shader != null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), name)
	return fallback if value == null else value


## Two materials draw the same (same shader and values, same passes).
static func _same_material(a: Material, b: Material) -> bool:
	if a == b:
		return true
	if a == null or b == null or a.get_class() != b.get_class() or a.render_priority != b.render_priority:
		return false
	if not _same_material(a.next_pass, b.next_pass):
		return false
	if a is ShaderMaterial:
		var sa := a as ShaderMaterial
		var sb := b as ShaderMaterial
		if sa.shader != sb.shader:
			return false
		for uniform in sa.shader.get_shader_uniform_list(true):
			var name: String = uniform.name
			if sa.get_shader_parameter(name) != sb.get_shader_parameter(name):
				return false
		return true
	for property in a.get_property_list():
		var name: String = property.name
		if (property.usage & PROPERTY_USAGE_STORAGE) == 0 or name.begins_with("resource_") or name == "script" or name == "next_pass":
			continue
		if a.get(name) != b.get(name):
			return false
	return true


## Output surfaces of one merged mesh: palette surfaces per shader class (up to ENTRIES sources
## each), copy surfaces per equal material and array layout. Entries are [source path, surface].
static func _outputs(infos: Array) -> Array:
	var outputs := []
	for info in infos:
		for s in info.surfaces:
			var layout: int = s.format & ((1 << 26) - 1)
			var out: Dictionary = {}
			for candidate in outputs:
				if candidate.kind != s.kind:
					continue
				if s.kind == "copy":
					if candidate.layout == layout and _same_material(candidate.material, s.material):
						out = candidate; break
				elif candidate["class"] == s["class"] and candidate.parts.size() < ENTRIES:
					out = candidate; break
			if out.is_empty():
				out = {"kind": s.kind, "class": s["class"], "material": s.material, "layout": layout,
					"eight": false, "parts": [], "entries": []}
				outputs.append(out)
			out.eight = out.eight or (s.format & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0
			out.parts.append({"arrays": s.arrays, "lods": s.lods, "normals": s.normals,
				"eight": (s.format & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0, "entry": out.entries.size()})
			out.entries.append([info.path, s.si])
	return outputs


# --- Build (worker thread) ---------------------------------------------------------------------

static func _build(job: Dictionary) -> void:
	for group in job.groups:
		for vname in group.variants:
			for out in group.variants[vname].outputs:
				_concatenate(out)


static func _concatenate(out: Dictionary) -> void:
	var stride := 8 if out.eight else 4
	var palette: bool = out.kind != "copy"
	# Palette surfaces keep what their shaders read (the cel shaders read no tangent or colour);
	# copy surfaces keep every array of their (shared) layout.
	var slots := [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]
	if not palette:
		slots = [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV,
			Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	var entry := PackedFloat32Array()
	var snout := PackedFloat32Array()
	var normals := PackedByteArray()
	var exact_normals := true
	var normal_stride := 0
	var offsets := PackedInt32Array()
	var total := 0
	for part in out.parts:
		var src: Array = part.arrays
		var count: int = (src[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		offsets.append(total)
		for slot in slots:
			if src[slot] == null:
				continue
			if arrays[slot] == null:
				arrays[slot] = src[slot].duplicate()
			else:
				arrays[slot].append_array(src[slot])
		# Bones and weights at the output stride (8 when any part has 8; the extra weights are 0).
		var src_bones: PackedInt32Array = src[Mesh.ARRAY_BONES]
		var src_weights: PackedFloat32Array = src[Mesh.ARRAY_WEIGHTS]
		var src_stride := 8 if part.eight else 4
		if src_stride == stride:
			bones.append_array(src_bones)
			weights.append_array(src_weights)
		else:
			for v in count:
				for k in stride:
					bones.append(src_bones[v * src_stride + k] if k < src_stride else 0)
					weights.append(src_weights[v * src_stride + k] if k < src_stride else 0.0)
		var src_indices: PackedInt32Array = src[Mesh.ARRAY_INDEX]
		if total == 0:
			indices.append_array(src_indices)
		else:
			for i in src_indices.size():
				indices.append(src_indices[i] + total)
		if palette:
			var ids := PackedFloat32Array()
			ids.resize(count)
			ids.fill(float(part.entry))
			entry.append_array(ids)
			if out.kind == "occlusion":
				var rest: Variant = src[Mesh.ARRAY_CUSTOM0]
				if rest is PackedFloat32Array and (rest as PackedFloat32Array).size() == count * 4:
					snout.append_array(rest)
				else:
					var zeros := PackedFloat32Array()
					zeros.resize(count * 4)
					snout.append_array(zeros)
		# The stored normal and tangent bytes (the engine adds a tangent stream where a surface
		# has normals and no tangents, so palette surfaces carry one too).
		var stream: Dictionary = part.normals
		if stream.is_empty() or (normal_stride > 0 and int(stream.stride) != normal_stride):
			exact_normals = false
		else:
			normal_stride = int(stream.stride)
			normals.append_array(stream.bytes)
		total += count
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if out.eight else 0
	if palette:
		arrays[Mesh.ARRAY_CUSTOM1] = entry
		flags |= Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT
		if out.kind == "occlusion":
			arrays[Mesh.ARRAY_CUSTOM0] = snout
			flags |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	else:
		flags |= out.layout & CUSTOM_FORMATS
	out["arrays"] = arrays
	out["flags"] = flags
	out["normals"] = normals if exact_normals else PackedByteArray()
	out["lods"] = _merge_lods(out.parts, offsets)
	out.erase("parts")  # source arrays are no longer needed


## Merged LOD levels: at each merged edge length E every part contributes its coarsest level
## whose edge length is <= E (its full indices when it has none), so no part is ever coarser than
## it was on its own at the same distance.
static func _merge_lods(parts: Array, offsets: PackedInt32Array) -> Dictionary:
	var lengths: Array = []
	for part in parts:
		_decode_lods(part.lods)
		for lod in part.lods:
			lengths.append(float(lod[0]))
	lengths.sort()
	var levels: Array = []
	for length in lengths:
		if length > 0.0 and (levels.is_empty() or length > float(levels[-1]) * LOD_STEP):
			levels.append(length)
	var result := {}
	for level in levels:
		var indices := PackedInt32Array()
		for p in parts.size():
			var part: Dictionary = parts[p]
			var chosen: PackedInt32Array = part.arrays[Mesh.ARRAY_INDEX]
			for lod in part.lods:
				if float(lod[0]) <= level:
					chosen = lod[1]
			var base := offsets[p]
			if base == 0:
				indices.append_array(chosen)
			else:
				for i in chosen.size():
					indices.append(chosen[i] + base)
		result[level] = indices
	return result


static func _decode_lods(lods: Array) -> void:
	for lod in lods:
		if lod[1] is PackedInt32Array:
			continue
		var bytes: PackedByteArray = lod[1]
		var indices := PackedInt32Array()
		if int(lod[2]) == 4:
			indices = bytes.to_int32_array()
		else:
			indices.resize(bytes.size() / 2)
			for i in indices.size():
				indices[i] = bytes.decode_u16(i * 2)
		lod[1] = indices


# --- Assemble (main thread) --------------------------------------------------------------------

static func _assemble(job: Dictionary) -> Dictionary:
	var plan := {"key": job.key, "groups": []}
	for group in job.groups:
		var variants := {}
		for vname in group.variants:
			var v: Dictionary = group.variants[vname]
			var mesh := ArrayMesh.new()
			mesh.resource_name = "near_%s_%s_%s" % [job.key, group.name, vname]
			var outputs := []
			for out in v.outputs:
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out.arrays, [], out.lods, out.flags)
				outputs.append({"kind": out.kind, "class": out["class"], "entries": out.entries})
				out.erase("arrays")
			_restore_normals(mesh, v.outputs)
			variants[vname] = {"mesh": mesh, "outputs": outputs, "sources": v.sources, "counts": v.counts}
		plan.groups.append({"name": group.name, "skeleton": group.skeleton, "skin": group.skin, "ink": group.ink,
			"variants": variants})
	return plan


## Put the rig meshes' stored normal/tangent bytes back: add_surface_from_arrays re-encodes the
## decoded normals, which moves some by one octahedral step (a cel band edge can then flip a pixel).
## The stream is [positions][normal+tangent per vertex]; only the second part is replaced.
static func _restore_normals(mesh: ArrayMesh, outputs: Array) -> void:
	var stored: Array = mesh.get("_surfaces")
	var changed := false
	for i in outputs.size():
		var normals: PackedByteArray = outputs[i].normals
		if normals.is_empty() or i >= stored.size():
			continue
		var raw: Dictionary = stored[i]
		var format := int(raw.format)
		var count := int(raw.vertex_count)
		var offset := RenderingServer.mesh_surface_get_format_offset(format, count, Mesh.ARRAY_NORMAL)
		var data: PackedByteArray = raw.vertex_data
		if data.size() != offset + normals.size():
			push_warning("Near mesh: %s surface %d normal stream layout differs; keeping re-encoded normals" % [mesh.resource_name, i])
			continue
		data = data.slice(0, offset)
		data.append_array(normals)
		raw.vertex_data = data
		changed = true
	if changed:
		mesh.set("_surfaces", stored)


# --- Per pony ----------------------------------------------------------------------------------

## Show `plan`'s merged meshes on `pony` and hide the rig meshes they replace. Returns the state
## for `detach`/`set_lod` ({} when nothing merged). A group whose rig meshes or materials no
## longer match the plan keeps its rig meshes.
static func attach(pony: Node, plan: Dictionary, lod: bool) -> Dictionary:
	var state := {"groups": [], "hidden": []}
	for group in plan.groups:
		var skeleton := pony.get_node_or_null(group.skeleton) as Skeleton3D
		if skeleton == null:
			continue
		var built := {}
		var ok := true
		for vname in group.variants:
			var v: Dictionary = group.variants[vname]
			var sources := []
			for path in v.sources:
				var mi := pony.get_node_or_null(path) as MeshInstance3D
				if mi == null or mi.mesh == null or mi.skin != group.skin or mi.mesh.get_surface_count() != (v.counts[path] as Array).size():
					ok = false; break
				for si in mi.mesh.get_surface_count():
					if mi.mesh.surface_get_array_len(si) != int(v.counts[path][si]):
						ok = false
				sources.append(mi)
			if not ok:
				break
			var materials := []
			for out in v.outputs:
				var material := _output_material(pony, out)
				if material == null:
					ok = false; break
				materials.append(material)
			if not ok:
				break
			built[vname] = {"sources": sources, "materials": materials}
		if not ok:
			push_warning("Near mesh: %s %s no longer matches its rig meshes; keeping them" % [pony.name, group.name])
			continue
		var first: MeshInstance3D = built.full.sources[0]
		var mi := MeshInstance3D.new()
		mi.name = group.name
		mi.set_meta(META, true)
		if group.ink:
			mi.set_meta(INK, true)
		for property in ["layers", "cast_shadow", "gi_mode", "visibility_range_begin", "visibility_range_end",
				"visibility_range_begin_margin", "visibility_range_end_margin", "visibility_range_fade_mode",
				"extra_cull_margin", "lod_bias", "transparency", "ignore_occlusion_culling"]:
			mi.set(property, first.get(property))
		skeleton.add_child(mi)
		mi.skin = group.skin
		mi.skeleton = mi.get_path_to(skeleton)
		var entry := {"mi": mi, "group": group, "built": built, "variant": ""}
		_show_variant(entry, "lod" if lod and built.has("lod") else "full")
		# Every variant's rig meshes hide; the meta keeps whether each was shown.
		for vname in built:
			for source in built[vname].sources:
				if source.has_meta(HIDDEN):
					continue
				source.set_meta(HIDDEN, source.visible)
				source.visible = false
				state.hidden.append(source)
		state.groups.append(entry)
	return state if not state.groups.is_empty() else {}


## Restore the rig meshes and free the merged ones. With `hold`, body rig meshes under
## `hold_root` stay hidden for the far mesh swap (meta far_hidden) instead of showing.
static func detach(state: Dictionary, hold := false, hold_root: Node = null) -> void:
	for entry in state.get("groups", []):
		var mi: MeshInstance3D = entry.mi
		if is_instance_valid(mi):
			if mi.get_parent() != null:
				mi.get_parent().remove_child(mi)
			mi.queue_free()
	for source in state.get("hidden", []):
		if not is_instance_valid(source):
			continue
		var was_shown := bool(source.get_meta(HIDDEN, false))
		source.remove_meta(HIDDEN)
		if not was_shown:
			continue
		if hold and hold_root != null and hold_root.is_ancestor_of(source):
			source.set_meta(&"far_hidden", true)
		else:
			source.visible = true
	state.clear()


## Swap the hair's merged mesh between its full and LOD1 variants.
static func set_lod(state: Dictionary, lod: bool) -> void:
	for entry in state.get("groups", []):
		if entry.built.has("lod"):
			_show_variant(entry, "lod" if lod else "full")


static func instances(state: Dictionary) -> Array:
	var out := []
	for entry in state.get("groups", []):
		if is_instance_valid(entry.mi):
			out.append(entry.mi)
	return out


static func _show_variant(entry: Dictionary, vname: String) -> void:
	if entry.variant == vname:
		return
	entry.variant = vname
	var mi: MeshInstance3D = entry.mi
	mi.mesh = entry.group.variants[vname].mesh
	var materials: Array = entry.built[vname].materials
	for i in materials.size():
		mi.set_surface_override_material(i, materials[i])


## This pony's material for one merged surface; null when its rig materials no longer fit.
static func _output_material(pony: Node, out: Dictionary) -> Material:
	var sources := []
	for e in out.entries:
		var mi := pony.get_node_or_null(e[0]) as MeshInstance3D
		if mi == null:
			return null
		var material := mi.get_active_material(e[1])
		var kind := _kind(material, mi.mesh.surface_get_format(e[1]))
		if kind.is_empty() or kind[0] != out.kind or (out.kind != "copy" and kind[1] != out["class"]):
			return null
		sources.append(material)
	if out.kind == "copy":
		for material in sources:
			if not _same_material(sources[0], material):
				return null
		return sources[0]
	var first := sources[0] as ShaderMaterial
	var mat := ShaderMaterial.new()
	mat.shader = PALETTE if out.kind == "palette" else PALETTE_OCCLUSION
	var texture: Variant = first.get_shader_parameter("base_texture")
	if texture != null:
		mat.set_shader_parameter("base_texture", texture)
	if out.kind == "occlusion":
		mat.set_shader_parameter("ao_map", first.get_shader_parameter("ao_map"))
		mat.set_shader_parameter("ao_light_affect", _param(first, "ao_light_affect", 0.0))
		var snout := PackedFloat32Array(); snout.resize(ENTRIES)
		for i in sources.size():
			snout[i] = 1.0 if bool(_param(sources[i], "native_snout_detail", false)) else 0.0
		mat.set_shader_parameter("pal_snout", snout)
	_fill_palette(mat, sources, true)
	_mark_lip_tone(pony, out, mat)
	if first.next_pass != null:
		var hulls := []
		for material in sources:
			hulls.append((material as ShaderMaterial).next_pass)
		var hull := ShaderMaterial.new()
		hull.shader = PALETTE_OUTLINE
		_fill_palette(hull, hulls)
		var width := PackedFloat32Array(); width.resize(ENTRIES)
		var facing := PackedFloat32Array(); facing.resize(ENTRIES)
		var eye_mask := PackedFloat32Array(); eye_mask.resize(ENTRIES)
		for i in hulls.size():
			# A rig lip hull thinned for speech (hybrid_mare.set_lip_hull_open) keeps its full width.
			width[i] = float(hulls[i].get_meta(&"lip_width")) if hulls[i].has_meta(&"lip_width") else float(_param(hulls[i], "outline_width", 0.0035))
			facing[i] = 1.0 if bool(_param(hulls[i], "face_viewer", true)) else 0.0
			eye_mask[i] = 1.0 if bool(_param(hulls[i], "native_eye_socket_mask", false)) else 0.0
		hull.set_shader_parameter("pal_width", width)
		hull.set_shader_parameter("pal_face_viewer", facing)
		hull.set_shader_parameter("pal_eye_socket_mask", eye_mask)
		# The Head's Lip entries, whose width hybrid_mare.set_lip_hull_open drops while speaking.
		var lips := PackedInt32Array()
		for i in out.entries.size():
			var rig := pony.get_node_or_null(out.entries[i][0]) as MeshInstance3D
			var source: Material = rig.mesh.surface_get_material(out.entries[i][1]) if rig != null and rig.name == "Head" else null
			if source != null and source.resource_name.ends_with(" Lip"): lips.append(i)
		if not lips.is_empty():
			hull.set_meta(&"lip_entries", lips)
			hull.set_meta(&"lip_widths", width)
		mat.next_pass = hull
	return mat


## Hull width of the merged Head Lip entries: `width`, or < 0 for their built width.
static func set_lip_width(state: Dictionary, width: float) -> void:
	for entry in state.get("groups", []):
		for vname in entry.built:
			for material in entry.built[vname].materials:
				var hull := (material as Material).next_pass as ShaderMaterial
				if hull == null or not hull.has_meta(&"lip_entries"):
					continue
				var built: PackedFloat32Array = hull.get_meta(&"lip_widths")
				var widths := built.duplicate()
				for i: int in hull.get_meta(&"lip_entries"):
					widths[i] = built[i] if width < 0.0 else width
				hull.set_shader_parameter("pal_width", widths)


## The Head's Lip entries and their same-side Snout entries, for set_lip_tone (viseme review round 3:
## the pursed "oo" lights the lip colour toward the snout's while speaking).
static func _mark_lip_tone(pony: Node, out: Dictionary, mat: ShaderMaterial) -> void:
	var names := {}
	for i in out.entries.size():
		var rig := pony.get_node_or_null(out.entries[i][0]) as MeshInstance3D
		var source: Material = rig.mesh.surface_get_material(out.entries[i][1]) if rig != null and rig.name == "Head" else null
		if source != null: names[source.resource_name] = i
	var lips := PackedInt32Array()
	var snouts := PackedInt32Array()
	for name: String in names:
		if name.ends_with(" Lip") and names.has(name.trim_suffix(" Lip") + " Snout"):
			lips.append(names[name])
			snouts.append(names[name.trim_suffix(" Lip") + " Snout"])
	if lips.is_empty(): return
	mat.set_meta(&"lip_tone_entries", [lips, snouts])
	mat.set_meta(&"lip_pal_color", mat.get_shader_parameter("pal_color"))
	mat.set_meta(&"lip_pal_shadow", mat.get_shader_parameter("pal_shadow"))


## Lip entries of the merged Head blended `tone` of the way to their snout's colour and shade.
static func set_lip_tone(state: Dictionary, tone: float) -> void:
	for entry in state.get("groups", []):
		for vname in entry.built:
			for material in entry.built[vname].materials:
				var mat := material as ShaderMaterial
				if mat == null or not mat.has_meta(&"lip_tone_entries"):
					continue
				var pairs: Array = mat.get_meta(&"lip_tone_entries")
				for param: String in ["pal_color", "pal_shadow"]:
					var built: PackedVector4Array = mat.get_meta(StringName("lip_" + param))
					var values := built.duplicate()
					for k in (pairs[0] as PackedInt32Array).size():
						var lip: int = pairs[0][k]
						values[lip] = built[lip].lerp(built[pairs[1][k]], tone)
					mat.set_shader_parameter(param, values)


## Colour, shade, specular and fresnel of each source, linear as the engine uploads source_color.
## `lip_base`: a rig lip material toned for speech (hybrid_mare.set_lip_tone) gives its built colour.
static func _fill_palette(target: ShaderMaterial, sources: Array, lip_base := false) -> void:
	for pair in [["pal_color", "color", Color(0.7, 0.12, 0.86, 1.0)], ["pal_shadow", "shadow_color", Color(0, 0, 0, 0)],
			["pal_specular", "specular", Color(0.3, 0.3, 0.3, 0.5)], ["pal_fresnel", "fresnel", Color(0.2, 0.2, 0.2, 0.3)]]:
		var values := PackedVector4Array(); values.resize(ENTRIES)
		for i in sources.size():
			var value: Variant = _param(sources[i], pair[1], pair[2])
			var base_key := StringName("lip_base_" + String(pair[1]))
			if lip_base and (sources[i] as Material).has_meta(base_key): value = (sources[i] as Material).get_meta(base_key)
			var c: Color = value if value is Color else Color((value as Vector4).x, value.y, value.z, value.w)
			var linear := c.srgb_to_linear()
			values[i] = Vector4(linear.r, linear.g, linear.b, linear.a)
		target.set_shader_parameter(pair[0], values)
