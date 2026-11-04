extends RefCounted
## Far render LOD for the hybrid mare: one ArrayMesh per identity, every visible surface of the
## Native body, OpenPony head and devkit hair (LOD1) skinned onto the native skeleton alone.
##
## Native body surfaces are copied as exported (same skeleton, same binds). Every OpenPony and
## hair vertex is skinned at the current pose through its own skin binds (those skeletons carry
## a 180° rotation in their binds), then expressed in the bind space of the native bone that
## drives its original bone at runtime, through that bone's current pose, so the bake is exact
## whatever pose the first pony of an identity is in when asked. Link pairs: the neck link
## pairs (mChest→pony_spine3, mNeck→pony_neck2, mHead→pony_head, every face bone→pony_head), the hair link
## pairs (mPelvis→pony_hips, mTail1..6→pony_tail_01..05). The result moves rigidly with the body rig,
## which is what the links do anyway, at one draw per material instead of ~120 passes.
##
## Built once per identity on a worker thread from a live pony (`request`), cached for every
## other pony of that identity; `build_now` is the synchronous path for tools and tests.
##
## Draw calls (dev 2026-09-25: a far pony cost ~89 draws, one per colour region x colour,
## outline and ink-mask passes): every cel-shaded or standard surface is merged into ONE
## surface whose colours come from a small atlas (one 64 px tile per source material, its
## `color` times its texture baked in) and whose two-tone and outline colour/width ride on the
## vertices (far_pony.gdshader + far_pony_outline.gdshader). Eyes (iris, lashes) keep
## their own shaders in a separate mesh (`eyes_cache`), drawn without outline or ink mask like
## the rig's. Anything else stays one surface per material, as before.
##
## Far eye draws (perf push 2026-10-14: six per far pony, 180 for 30): the two lash rings share
## one surface when their materials match uniform for uniform, the two irises share one through
## far_iris.gdshader (iris.gdshader with the second eye's textures and gaze picked per vertex),
## and the brows are left out because FarEyes never shows them (hybrid_mare sets its brow_amount
## to 0, where openpony_brows.gdshader discards every fragment). Two draws, same pixels.

const BODY_MESH := "MareBody"
## Surfaces per OpenPony mesh kept at distance ("*" = all). Only the mouth interior is dropped
## (closed mouth). The whole eye stacks, lashes and brows stay: dev 2026-09-18, with the iris
## bases alone "you can literally see their eyes aren't there" at the near/far switch.
const HEAD_KEEP := {"Head": "*", "Ears1": "*", "Eye": "*", "Pupil": "*", "Pupil_001": "*",
	"Eyelashes": "*", "Eyebrows": "*", "Unicorn Horn": "*"}
const BONE_MAP := {"mChest": "pony_spine3", "mNeck": "pony_neck2", "mHead": "pony_head", "mTorso": "pony_spine2",
	"mPelvis": "pony_hips", "mTail1": "pony_tail_01", "mTail2": "pony_tail_02", "mTail3": "pony_tail_03",
	"mTail4": "pony_tail_04", "mTail5": "pony_tail_05", "mTail6": "pony_tail_05"}

static var cache: Dictionary = {}     # identity id -> ArrayMesh
static var shadow_cache: Dictionary = {}  # identity id -> shadows-only ArrayMesh (one surface per weight stride)
static var eyes_cache: Dictionary = {}    # identity id -> ArrayMesh of the eye surfaces (own shaders)
const NEAR_MESH := preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd")
const FAR_SHADER := preload("res://world/characters/hybrid_mare/far_pony.gdshader")
const FAR_OUTLINE_SHADER := preload("res://world/characters/hybrid_mare/far_pony_outline.gdshader")
const FAR_IRIS_SHADER := preload("res://world/characters/hybrid_mare/far_iris.gdshader")
## iris.gdshader uniforms that differ per eye; far_iris.gdshader carries a "_b" copy of each.
const IRIS_SIDE := ["tint_mask", "ink", "gaze_uv"]
const TILE := 64
const TILE_PAD := 4
const ATLAS_COLUMNS := 8
static var _pending: Dictionary = {}  # identity id -> {task, job}
## Process frame of the last main-thread step (gather or assemble). One step per frame (thread
## 43671981 D1): a gather reads every source surface and texture back from the GPU, and several
## identities asking in the same frame after a load stacked into 100-200 ms frames. Callers poll
## every frame while they wait (hybrid_mare.gd _poll_far_mesh, _set_shadow_proxy), so the rest
## simply go next frame. build_now (tools, tests) is not limited.
static var _step_frame := -1

static func discard_pending() -> void:
	for pending: Dictionary in _pending.values():
		WorkerThreadPool.wait_for_task_completion(pending.task)
	_pending.clear()


## The shadows-only proxy for `pony`'s identity: the far mesh's surfaces merged into one (two
## when 4- and 8-weight surfaces mix), no materials. Null while the far mesh is being built.
static func shadow_proxy(pony: Node) -> ArrayMesh:
	var id := _id(pony)
	if not shadow_cache.has(id) and request(pony) == null:
		return null
	return shadow_cache.get(id)


## The cached far mesh for `pony`'s identity without gathering; null when not built yet.
static func cached(pony: Node) -> ArrayMesh:
	return cache.get(_id(pony))


## The cached far mesh for `pony`'s identity, or null while it is being built (kicks the build).
static func request(pony: Node) -> ArrayMesh:
	var id := _id(pony)
	if cache.has(id):
		return cache[id]
	if _pending.has(id):
		var pending: Dictionary = _pending[id]
		if WorkerThreadPool.is_task_completed(pending.task) and _take_step():
			WorkerThreadPool.wait_for_task_completion(pending.task)
			_pending.erase(id)
			preload("res://world/debug/hitch_monitor.gd").mark("far mesh assemble " + id)
			cache[id] = _assemble(pending.job)
			shadow_cache[id] = _assemble_shadow(pending.job)
			eyes_cache[id] = _assemble_eyes(pending.job)
			return cache[id]
		return null
	if not _take_step():
		return null
	preload("res://world/debug/hitch_monitor.gd").mark("far mesh gather " + id)
	var job := _gather(pony)
	if job.is_empty():
		return null
	var task := WorkerThreadPool.add_task(_skin_all.bind(job), false, "Far mesh " + id)
	_pending[id] = {"task": task, "job": job}
	return null


static func _take_step() -> bool:
	var frame := Engine.get_process_frames()
	if frame == _step_frame:
		return false
	_step_frame = frame
	return true


## Synchronous build (tools, tests); also fills the cache.
static func build_now(pony: Node) -> ArrayMesh:
	var id := _id(pony)
	if cache.has(id):
		return cache[id]
	var job := _gather(pony)
	if job.is_empty():
		return null
	_skin_all(job)
	cache[id] = _assemble(job)
	shadow_cache[id] = _assemble_shadow(job)
	eyes_cache[id] = _assemble_eyes(job)
	return cache[id]


static func _id(pony: Node) -> String:
	var identity: Resource = pony.get("identity")
	# Keep width A/B variants separate: neutral face poses are gathered with the live rig.
	var width: float = pony.get("head_width_factor")
	var base_width: float = pony.get("head_width")
	return (String(identity.id) if identity != null else "default") + (":reference-face" if pony.get("reference_face_enabled") else "") + ":head-width=" + str(base_width) + ":head-width-factor=" + str(width) + ("|geometry=" + str(pony.get_meta(&"geometry_variant")) if pony.has_meta(&"geometry_variant") and not str(pony.get_meta(&"geometry_variant")).is_empty() else "")


## The meshes the far mesh is made of: [MeshInstance3D, kept surfaces ("*" or indices), Skeleton3D,
## attachment bone (-1 for skinned meshes; accessories such as the hat hang unskinned under a
## BoneAttachment3D and ride that bone rigidly)]. Always the rig meshes: the merged near meshes
## (hybrid_near_mesh.gd) are skipped and the rig meshes they hide count as shown.
static func sources(pony: Node) -> Array[Array]:
	var body: Skeleton3D = pony.get("skeleton")
	var sources: Array[Array] = []
	var model: Node = pony.get("_model")
	if model == null or body == null:
		return sources
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		if NEAR_MESH.shown(mi) and not mi.has_meta(NEAR_MESH.META) and mi.mesh != null and mi.skin != null:
			sources.append([mi, "*", body, -1])
	var head: Node = pony.get("head")
	var head_model: Node = pony.get("_head_model")
	if head != null and head_model != null:
		var head_skeleton: Skeleton3D = head.get("skeleton")
		for mi in head_model.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null or mi.skin == null or not HEAD_KEEP.has(String(mi.name)):
				continue
			if not NEAR_MESH.shown(mi):
				continue
			sources.append([mi, HEAD_KEEP[String(mi.name)], head_skeleton, -1])
	var hair: Node = pony.get("hair")
	var hair_skeleton: Skeleton3D = pony.get("hair_skeleton")
	var identity: Resource = pony.get("identity")
	if hair != null and hair_skeleton != null and identity != null:
		for mi in hair.find_children("*", "MeshInstance3D", true, false):
			if mi.mesh == null or mi.has_meta(NEAR_MESH.META):
				continue
			var n := String(mi.name)
			if mi.skin == null:
				var attachment := mi.get_parent() as BoneAttachment3D
				if attachment != null and n in identity.accessories and NEAR_MESH.shown(mi):
					sources.append([mi, "*", hair_skeleton, hair_skeleton.find_bone(attachment.bone_name)])
				continue
			var lod := n.ends_with("LOD1")
			var base := n.trim_suffix("LOD1")
			var is_hair: bool = base == identity.hair_prefix + "DevkitMane" or base == identity.hair_prefix + "DevkitTail"
			var wanted := false
			if is_hair:
				# The decimated copy where the export carries one, else the full mesh.
				var has_lod: bool = hair.find_child(base + "LOD1", true, false) != null
				wanted = lod if has_lod else not lod
			else:
				wanted = n in identity.accessories and NEAR_MESH.shown(mi)
			if wanted:
				sources.append([mi, "*", hair_skeleton, -1])
	return sources


## Main thread: collect surface arrays, per-bind world matrices and target bind indices.
static func _gather(pony: Node) -> Dictionary:
	var body: Skeleton3D = pony.get("skeleton")
	var body_mesh: MeshInstance3D = pony.find_child(BODY_MESH, true, false)
	if body == null or body_mesh == null or body_mesh.skin == null:
		return {}
	var body_skin: Skin = body_mesh.skin
	var target_bind := {}
	for j in body_skin.get_bind_count():
		var name := String(body_skin.get_bind_name(j))
		if name == "":
			name = body.get_bone_name(body_skin.get_bind_bone(j))
		target_bind[name] = j
	var into_body := body.global_transform.affine_inverse()
	# Inverse of the runtime matrix Godot applies per native bind right now: a world position
	# through it lands in that bind's space, exact for the current pose.
	var target_inverse: Array[Transform3D] = []
	# Gathering runs outside skeleton_updated, after modifier poses have been restored.
	# Match the body frames that actually drove the linked head, not the plain body pose;
	# otherwise head width and filly neck scale would be baked and then applied again.
	var linked_poses: Dictionary = pony.neck_link.source_poses if pony.neck_link != null else {}
	for j in body_skin.get_bind_count():
		var name := String(body_skin.get_bind_name(j))
		var bone := body.find_bone(name) if name != "" else body_skin.get_bind_bone(j)
		var posed: Transform3D = linked_poses.get(bone, body.get_bone_global_pose(bone))
		target_inverse.append((body.global_transform * posed * body_skin.get_bind_pose(j)).affine_inverse())
	var groups := {}  # material -> surface group
	var order: Array = []
	var head_skeleton: Skeleton3D = pony.head.skeleton
	var face_pose: Array[Transform3D] = pony.eye_motion.neutral_global_poses()
	if pony.get("reference_face") != null:
		face_pose = pony.reference_face.remap_snapshot(face_pose)
	for source in sources(pony):
		var mi: MeshInstance3D = source[0]
		var keep = source[1]
		var skeleton: Skeleton3D = source[2]
		var attachment_bone: int = source[3]
		var skin: Skin = mi.skin
		# World matrix per bind at the current (standing) pose, and the native bind it maps to.
		var matrices: Array[Transform3D] = []
		var remap := PackedInt32Array()
		if skin == null:
			# Rigid accessory: its node transform, all weight on the attachment bone's target.
			matrices.append(mi.global_transform)
			remap.append(_target_for(skeleton, attachment_bone, skeleton == body, target_bind))
		for j in (skin.get_bind_count() if skin != null else 0):
			var name := String(skin.get_bind_name(j))
			var bone := skeleton.find_bone(name) if name != "" else skin.get_bind_bone(j)
			if bone < 0:
				matrices.append(Transform3D.IDENTITY)
				remap.append(target_bind.get("pony_hips", 0))
				continue
			var pose: Transform3D = face_pose[bone] if skeleton == head_skeleton else skeleton.get_bone_global_pose(bone)
			matrices.append(skeleton.global_transform * pose * skin.get_bind_pose(j))
			remap.append(_target_for(skeleton, bone, skeleton == body, target_bind))
		for si in mi.mesh.get_surface_count():
			if keep is Array and not (si in keep):
				continue
			var material := mi.get_active_material(si)
			if material == null:
				continue
			# Far faces use neutral gaze, independent of the first instance's live target.
			if material.has_meta("show_iris"):
				material = material.duplicate()
				var side := 0 if material.get_meta("left_eye") else 1
				var angles: Vector2 = pony.eye_motion.surface_angles(side,Vector2.ZERO)
				(material as ShaderMaterial).set_shader_parameter("gaze_uv",pony.head.show_gaze_uv(angles))
			var key := material.get_rid()
			if not groups.has(key):
				var kind := _kind(material)
				groups[key] = {"material": material, "eight": false, "parts": [], "kind": kind,
					"tile": _tile_source(material) if kind == "merge" else {}}
				order.append(key)
			var arrays: Array = mi.mesh.surface_get_arrays(si)
			if skin == null:
				# Synthesise a single full-weight bind on the accessory's matrix.
				var count: int = arrays[Mesh.ARRAY_VERTEX].size()
				var bones := PackedInt32Array()
				var weights := PackedFloat32Array()
				bones.resize(count * 4)
				weights.resize(count * 4)
				for v in count:
					weights[v * 4] = 1.0
				arrays[Mesh.ARRAY_BONES] = bones
				arrays[Mesh.ARRAY_WEIGHTS] = weights
			if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
				continue
			var eight: bool = skin != null and (mi.mesh.surface_get_format(si) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0
			groups[key].eight = groups[key].eight or eight
			groups[key].parts.append({"arrays": arrays, "eight": eight, "matrices": matrices, "remap": remap,
				"copy": skeleton == body and skin != null, "primitive": mi.mesh.surface_get_primitive_type(si)})
	var shadow := {}
	for stride in [4, 8]:
		shadow[stride] = {"vertices": PackedVector3Array(), "bones": PackedInt32Array(),
			"weights": PackedFloat32Array(), "indices": PackedInt32Array()}
	return {"id": _id(pony), "groups": groups, "order": order, "into_body": into_body,
		"target_inverse": target_inverse, "shadow": shadow, "eye_plan": _plan_eyes(groups, order)}


## Main thread: which eye groups share one far surface ([{members, iris}]); marks brows dropped.
static func _plan_eyes(groups: Dictionary, order: Array) -> Array:
	var plan: Array = []
	var irises: Array = []
	for key in order:
		var group: Dictionary = groups[key]
		if group.kind != "eye":
			continue
		var material: Material = group.material
		var shader: Shader = (material as ShaderMaterial).shader if material is ShaderMaterial else null
		var path := shader.resource_path if shader != null else ""
		if "brows" in path:
			group["dropped"] = true
			continue
		if material.has_meta("show_iris") and path.ends_with("show_eyes/iris.gdshader"):
			irises.append(key)
			continue
		var signature := _signature(material, [])
		var joined := false
		for entry: Dictionary in plan:
			if not entry.iris and entry.signature == signature:
				entry.members.append(key)
				joined = true
				break
		if not joined:
			plan.append({"members": [key], "iris": false, "signature": signature})
	if irises.size() == 2 and _signature(groups[irises[0]].material, IRIS_SIDE) == _signature(groups[irises[1]].material, IRIS_SIDE):
		plan.append({"members": irises, "iris": true})
	else:
		for key in irises:
			plan.append({"members": [key], "iris": false})
	return plan


## What a material draws with: two with equal signatures render the same. Only shader materials
## compare uniform by uniform (`skip` names left out); anything else only equals itself.
static func _signature(material: Material, skip: Array) -> Array:
	var out: Array = [material.get_class(), material.render_priority, material.next_pass]
	var sm := material as ShaderMaterial
	if sm == null or sm.shader == null:
		out.append(material)
		return out
	out.append(sm.shader)
	for uniform: Dictionary in sm.shader.get_shader_uniform_list():
		var name := String(uniform.name)
		if not (name in skip):
			out.append([name, sm.get_shader_parameter(name)])
	return out


## Which native bind a source bone maps to. Body bones map to themselves; OpenPony/hair bones to
## the link pair of their nearest mapped ancestor (face bones → mHead → pony_head).
static func _target_for(skeleton: Skeleton3D, bone: int, is_body: bool, target_bind: Dictionary) -> int:
	if is_body:
		return target_bind.get(skeleton.get_bone_name(bone), 0)
	var b := bone
	while b >= 0:
		var name := skeleton.get_bone_name(b)
		if BONE_MAP.has(name) and target_bind.has(BONE_MAP[name]):
			return target_bind[BONE_MAP[name]]
		b = skeleton.get_bone_parent(b)
	return target_bind.get("pony_hips", 0)


## Worker thread: skin every part at the standing pose into body space, re-weight, and append.
static func _skin_all(job: Dictionary) -> void:
	var target_inverse: Array[Transform3D] = job.target_inverse
	for key in job.order:
		var group: Dictionary = job.groups[key]
		var stride := 8 if group.eight else 4
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		var indices := PackedInt32Array()
		var has_uv := true
		var has_normal := true
		for part in group.parts:
			var arrays: Array = part.arrays
			var src_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var src_normals = arrays[Mesh.ARRAY_NORMAL]
			var src_uvs = arrays[Mesh.ARRAY_TEX_UV]
			var src_bones = arrays[Mesh.ARRAY_BONES]
			var src_weights = arrays[Mesh.ARRAY_WEIGHTS]
			var src_indices = arrays[Mesh.ARRAY_INDEX]
			var src_stride: int = 8 if part.eight else 4
			var matrices: Array[Transform3D] = part.matrices
			var remap: PackedInt32Array = part.remap
			var copy: bool = part.copy
			var base := vertices.size()
			var count := src_vertices.size()
			for v in count:
				if copy:
					# Native body: already in these binds' space.
					vertices.append(src_vertices[v])
					if src_normals != null: normals.append(src_normals[v])
					else: has_normal = false
				else:
					var position := Vector3.ZERO
					var normal := Vector3.ZERO
					var total := 0.0
					var dominant := 0
					var dominant_weight := -1.0
					for k in src_stride:
						var w: float = src_weights[v * src_stride + k]
						if w <= 0.0:
							continue
						var m: Transform3D = matrices[int(src_bones[v * src_stride + k])]
						position += (m * src_vertices[v]) * w
						if src_normals != null:
							normal += (m.basis * src_normals[v]) * w
						total += w
						if w > dominant_weight:
							dominant_weight = w; dominant = int(src_bones[v * src_stride + k])
					if total > 0.0 and absf(total - 1.0) > 0.001:
						position /= total
					# Into the dominant target bind's space through that bone's current pose.
					var into: Transform3D = target_inverse[remap[dominant]]
					vertices.append(into * position)
					if src_normals != null:
						normals.append((into.basis * normal).normalized())
					else:
						has_normal = false
				if src_uvs != null:
					uvs.append(src_uvs[v])
				else:
					has_uv = false
				for k in stride:
					if k < src_stride:
						var w: float = src_weights[v * src_stride + k]
						bones.append(remap[int(src_bones[v * src_stride + k])] if w > 0.0 else 0)
						weights.append(w)
					else:
						bones.append(0)
						weights.append(0.0)
			if src_indices != null and src_indices.size() > 0:
				for i in src_indices.size():
					indices.append(int(src_indices[i]) + base)
			else:
				for i in count:
					indices.append(i + base)
		var out: Array = []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = vertices
		if has_normal:
			out[Mesh.ARRAY_NORMAL] = normals
		if has_uv:
			out[Mesh.ARRAY_TEX_UV] = uvs
		out[Mesh.ARRAY_BONES] = bones
		out[Mesh.ARRAY_WEIGHTS] = weights
		out[Mesh.ARRAY_INDEX] = indices
		group["out"] = out
		group["vertex_count"] = vertices.size()
		# Shadow proxy: every surface of this stride in one, no uv/normal/material.
		var shadow: Dictionary = job.shadow[stride]
		var offset: int = shadow.vertices.size()
		shadow.vertices.append_array(vertices)
		shadow.bones.append_array(bones)
		shadow.weights.append_array(weights)
		for i in indices.size():
			shadow.indices.append(indices[i] + offset)
	_merge(job)
	_merge_eyes(job)
	# dev 2026-09-26: "add simplified models for the ponies at far FAR distances ... if i can see
	# them off in the distance and SEE the transition youve failed". Continuous index LODs: the
	# engine picks a simpler index set as the pony gets smaller on screen (about one pixel of
	# error), with no separate model to pop to. Worked out here on the worker thread.
	if job.has("merged"):
		job.merged["lods"] = _lods(job.merged.arrays, job.merged.flags)
	for key in job.order:
		var group: Dictionary = job.groups[key]
		if not group.has("out") or group.vertex_count == 0 or group.get("merged", false) or group.get("folded", false) or group.get("dropped", false):
			continue
		# Eyes: only the lash rings (2,464 triangles each side) simplify; the iris cards and brows
		# are small and their shaders draw from the UVs, so they stay whole.
		if (group.kind != "eye" or _is_lashes(group.material)) and not group.has("lods"):
			group["lods"] = _lods(group.out, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if group.eight else 0)
	# One shadow surface instead of two: the four-weight part is padded to eight weights (the
	# extra four are zero), so the shadow copy is one draw per cascade, not two.
	var four: Dictionary = job.shadow[4]
	var eight: Dictionary = job.shadow[8]
	if not four.vertices.is_empty() and not eight.vertices.is_empty():
		var offset: int = eight.vertices.size()
		eight.vertices.append_array(four.vertices)
		for v in four.vertices.size():
			for k in 4:
				eight.bones.append(four.bones[v * 4 + k]); eight.weights.append(four.weights[v * 4 + k])
			for k in 4:
				eight.bones.append(0); eight.weights.append(0.0)
		for i in four.indices: eight.indices.append(i + offset)
		job.shadow[4] = {"vertices": PackedVector3Array(), "bones": PackedInt32Array(),
			"weights": PackedFloat32Array(), "indices": PackedInt32Array()}
	for stride in [4, 8]:
		var shadow: Dictionary = job.shadow[stride]
		if shadow.vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = shadow.vertices
		arrays[Mesh.ARRAY_BONES] = shadow.bones
		arrays[Mesh.ARRAY_WEIGHTS] = shadow.weights
		arrays[Mesh.ARRAY_INDEX] = shadow.indices
		shadow["lods"] = _lods(arrays, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if stride == 8 else 0)


static func _is_lashes(material: Material) -> bool:
	return material is ShaderMaterial and (material as ShaderMaterial).shader != null \
		and "lashes" in (material as ShaderMaterial).shader.resource_path


## Index LODs for one surface ({lod size: indices}), as Godot's importer makes them for GLBs.
static func _lods(arrays: Array, flags: int) -> Dictionary:
	var out := {}
	if (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() < 3 * 400:
		return out   # small surfaces stay whole
	var importer := ImporterMesh.new()
	importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, null, "", flags)
	importer.generate_lods(60.0, 25.0, [])
	for i in importer.get_surface_lod_count(0):
		out[importer.get_surface_lod_size(0, i)] = importer.get_surface_lod_indices(0, i)
	return out


## Main thread: the shadows-only proxy, one surface per bone-weight stride.
static func _assemble_shadow(job: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.resource_name = "shadow_" + String(job.id)
	for stride in [4, 8]:
		var shadow: Dictionary = job.shadow[stride]
		if shadow.vertices.is_empty():
			continue
		var out: Array = []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = shadow.vertices
		out[Mesh.ARRAY_BONES] = shadow.bones
		out[Mesh.ARRAY_WEIGHTS] = shadow.weights
		out[Mesh.ARRAY_INDEX] = shadow.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out, [], shadow.get("lods", {}),
			Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if stride == 8 else 0)
	return mesh


## Main thread: ArrayMesh with one surface per material. Materials are shared with the rigs,
## hull pass included, so a far mare keeps the show outline (two passes per surface).
## Potato tier: the merged far mesh (42 k triangles) gets generated LODs, so Godot's
## mesh_lod_threshold draws a fraction of it past a few metres (quality.gd far_mesh_lods).
static func _with_lods(mesh: ArrayMesh) -> ArrayMesh:
	var quality: Node = Engine.get_main_loop().root.get_node_or_null("/root/Quality") if Engine.get_main_loop() is SceneTree else null
	if quality == null or not bool(quality.get_value("far_mesh_lods", false)): return mesh
	var importer := ImporterMesh.new()
	for s in mesh.get_surface_count():
		importer.add_surface(mesh.surface_get_primitive_type(s), mesh.surface_get_arrays(s), [], {}, mesh.surface_get_material(s), mesh.surface_get_name(s), mesh.surface_get_format(s))
	importer.generate_lods(25.0, 60.0, [])
	var out: ArrayMesh = importer.get_mesh()
	out.custom_aabb = mesh.custom_aabb
	return out

static func _assemble(job: Dictionary) -> ArrayMesh:
	return _with_lods(_assemble_raw(job))

static func _assemble_raw(job: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.resource_name = "far_" + String(job.id)
	if job.has("merged"):
		var merged: Dictionary = job.merged
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged.arrays, [], merged.get("lods", {}), merged.flags)
		mesh.surface_set_material(0, _merged_material(merged))
	for key in job.order:
		var group: Dictionary = job.groups[key]
		if not group.has("out") or group.vertex_count == 0 or group.kind == "eye" or group.get("merged", false):
			continue
		var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if group.eight else 0
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, group.out, [], group.get("lods", {}), flags)
		mesh.surface_set_material(mesh.get_surface_count() - 1, group.material)
	return mesh


## Main thread: the eye surfaces (iris, brows, lashes) with their own materials.
static func _assemble_eyes(job: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.resource_name = "far_eyes_" + String(job.id)
	for key in job.order:
		var group: Dictionary = job.groups[key]
		if group.kind != "eye" or not group.has("out") or group.vertex_count == 0 or group.get("folded", false) or group.get("dropped", false):
			continue
		var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if group.eight else 0
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, group.out, [], group.get("lods", {}), flags)
		var material: Material = group.material
		if group.has("iris_pair"):
			material = _far_iris_material(group.iris_pair[0], group.iris_pair[1])
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	return mesh


## Worker thread: fold each eye_plan set into its first group's surface ("folded" marks the rest).
## The iris pair also gets UV2.x = 0 / 1 so far_iris.gdshader knows which eye a vertex is on.
static func _merge_eyes(job: Dictionary) -> void:
	for entry: Dictionary in job.get("eye_plan", []):
		var parts: Array = []
		for key in entry.members:
			var group: Dictionary = job.groups[key]
			if group.has("out") and group.vertex_count > 0:
				parts.append(group)
		if parts.size() < 2:
			continue
		# Only surfaces with the same attributes fold together.
		var first: Array = parts[0].out
		var same := true
		for group: Dictionary in parts:
			var arrays: Array = group.out
			if (arrays[Mesh.ARRAY_NORMAL] == null) != (first[Mesh.ARRAY_NORMAL] == null) or (arrays[Mesh.ARRAY_TEX_UV] == null) != (first[Mesh.ARRAY_TEX_UV] == null):
				same = false
		if not same or (entry.iris and (parts.size() != 2 or first[Mesh.ARRAY_TEX_UV] == null)):
			continue
		# Lash rings keep each eye's own index LODs (paired level by level below), so the folded
		# ring simplifies exactly as the two did.
		var part_lods: Array = []
		if not entry.iris and _is_lashes(parts[0].material):
			for group: Dictionary in parts:
				part_lods.append(_lods(group.out, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if group.eight else 0))
		var bases: Array = []
		var eight: bool = parts.any(func(g): return g.eight)
		var stride := 8 if eight else 4
		var vertices := PackedVector3Array(); var normals := PackedVector3Array(); var uvs := PackedVector2Array()
		var uv2 := PackedVector2Array(); var bones := PackedInt32Array(); var weights := PackedFloat32Array()
		var indices := PackedInt32Array()
		for p in parts.size():
			var src: Array = parts[p].out
			var src_stride := 8 if parts[p].eight else 4
			var src_bones: PackedInt32Array = src[Mesh.ARRAY_BONES]
			var src_weights: PackedFloat32Array = src[Mesh.ARRAY_WEIGHTS]
			var src_indices: PackedInt32Array = src[Mesh.ARRAY_INDEX]
			var base := vertices.size()
			bases.append(base)
			var src_vertices: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
			var count := src_vertices.size()
			vertices.append_array(src_vertices)
			if src[Mesh.ARRAY_NORMAL] != null: normals.append_array(src[Mesh.ARRAY_NORMAL])
			if src[Mesh.ARRAY_TEX_UV] != null: uvs.append_array(src[Mesh.ARRAY_TEX_UV])
			if entry.iris:
				for v in count: uv2.append(Vector2(float(p), 0.0))
			for v in count:
				for k in stride:
					bones.append(src_bones[v * src_stride + k] if k < src_stride else 0)
					weights.append(src_weights[v * src_stride + k] if k < src_stride else 0.0)
			for i in src_indices.size():
				indices.append(src_indices[i] + base)
		var out: Array = []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = vertices
		if first[Mesh.ARRAY_NORMAL] != null: out[Mesh.ARRAY_NORMAL] = normals
		if first[Mesh.ARRAY_TEX_UV] != null: out[Mesh.ARRAY_TEX_UV] = uvs
		if entry.iris: out[Mesh.ARRAY_TEX_UV2] = uv2
		out[Mesh.ARRAY_BONES] = bones
		out[Mesh.ARRAY_WEIGHTS] = weights
		out[Mesh.ARRAY_INDEX] = indices
		var into: Dictionary = parts[0]
		into["out"] = out
		into["vertex_count"] = vertices.size()
		into["eight"] = eight
		if entry.iris:
			into["iris_pair"] = [parts[0].material, parts[1].material]
		if not part_lods.is_empty():
			into["lods"] = _paired_lods(part_lods, bases)
		for p in range(1, parts.size()):
			parts[p]["folded"] = true


## Index LODs of folded surfaces from each one's own LODs ({size: indices} per part, offset by
## its vertex base): level n joins every part's level n (its last when it has fewer) at the
## largest of their sizes, so no part drops detail earlier than it did alone.
static func _paired_lods(part_lods: Array, bases: Array) -> Dictionary:
	var levels: Array = []
	var count := 0
	for lods: Dictionary in part_lods:
		if lods.is_empty():
			return {}
		var sizes: Array = lods.keys()
		sizes.sort()
		levels.append(sizes)
		count = maxi(count, sizes.size())
	var out := {}
	for level in count:
		var size := 0.0
		var indices := PackedInt32Array()
		for p in part_lods.size():
			var sizes: Array = levels[p]
			var key: float = sizes[mini(level, sizes.size() - 1)]
			size = maxf(size, key)
			var part: PackedInt32Array = part_lods[p][key]
			var base: int = bases[p]
			for i in part.size():
				indices.append(part[i] + base)
		if not out.has(size):
			out[size] = indices
	return out


## Main thread: both irises' material, uniforms from the first eye and the per-eye ones of the
## second as far_iris.gdshader's "_b" copies.
static func _far_iris_material(a: ShaderMaterial, b: ShaderMaterial) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = FAR_IRIS_SHADER
	material.render_priority = a.render_priority
	for uniform: Dictionary in a.shader.get_shader_uniform_list():
		var name := String(uniform.name)
		var value: Variant = a.get_shader_parameter(name)
		if value != null: material.set_shader_parameter(name, value)
	for name: String in IRIS_SIDE:
		var value: Variant = b.get_shader_parameter(name)
		if value != null: material.set_shader_parameter(name + "_b", value)
	return material


## "eye": iris/brows/lashes (procedural shaders, kept apart); "merge": cel-shaded or standard
## surfaces baked into the atlas; "other": anything else, kept as its own surface.
static func _kind(material: Material) -> String:
	if material.has_meta("show_iris"): return "eye"
	if material is ShaderMaterial:
		var shader: Shader = (material as ShaderMaterial).shader
		var path := shader.resource_path if shader != null else ""
		if path.ends_with("iris.gdshader") or "brows" in path or "lashes" in path: return "eye"
		if "cel-shader" in path: return "merge"
		return "other"
	if material is BaseMaterial3D: return "merge"
	return "other"


static func _param(material: ShaderMaterial, name: String, fallback: Variant) -> Variant:
	var value: Variant = material.get_shader_parameter(name)
	if value == null and material.shader != null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), name)
	return fallback if value == null else value


## Main thread: what one source material looks like, for its atlas tile and vertex attributes.
static func _tile_source(material: Material) -> Dictionary:
	var info := {"color": Color.WHITE, "image": null, "shade": Color(0, 0, 0, 0), "alpha": false, "palette": [],
		"line": Color.BLACK, "line_shade": Color(0, 0, 0, 0), "width": 0.0, "eye_socket_mask": false,
		"specular": Color(0.3, 0.3, 0.3, 0.5), "fresnel": Color(0.2, 0.2, 0.2, 0.3)}
	if material is ShaderMaterial:
		var sm := material as ShaderMaterial
		info.color = _param(sm, "color", Color.WHITE)
		info.shade = _param(sm, "shadow_color", Color(0, 0, 0, 0))
		info.specular = _param(sm, "specular", info.specular)
		info.fresnel = _param(sm, "fresnel", info.fresnel)
		var texture: Variant = sm.get_shader_parameter("base_texture")
		if texture is Texture2D: info.image = (texture as Texture2D).get_image()
		info.alpha = sm.shader != null and "cutout" in sm.shader.resource_path
		if bool(_param(sm, "replace_texture_palette", false)):
			info.palette = [_param(sm, "texture_palette_source_a", Color.BLACK), _param(sm, "texture_palette_source_b", Color.WHITE),
				_param(sm, "texture_palette_a", Color.BLACK), _param(sm, "texture_palette_b", Color.WHITE)]
		var hull := sm.next_pass as ShaderMaterial
		if hull != null and hull.shader != null and hull.shader.resource_path.ends_with("cel-outline-lit.gdshader"):
			info.line = _param(hull, "color", Color.BLACK)
			info.line_shade = _param(hull, "shadow_color", Color(0, 0, 0, 0))
			info.width = float(_param(hull, "outline_width", 0.0035))
			info.eye_socket_mask = bool(_param(hull, "native_eye_socket_mask", false))
	elif material is BaseMaterial3D:
		var bm := material as BaseMaterial3D
		info.color = bm.albedo_color
		if bm.albedo_texture != null: info.image = bm.albedo_texture.get_image()
		info.alpha = bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
	return info


## Worker thread: bake every "merge" group into one surface and the atlas image.
static func _merge(job: Dictionary) -> void:
	var tiles: Array = []
	for key in job.order:
		var group: Dictionary = job.groups[key]
		if group.kind == "merge" and group.has("out") and group.vertex_count > 0:
			tiles.append(group)
	if tiles.is_empty():
		return
	var rows := ceili(float(tiles.size()) / ATLAS_COLUMNS)
	var atlas := Image.create(TILE * ATLAS_COLUMNS, TILE * rows, false, Image.FORMAT_RGBA8)
	var size := Vector2(atlas.get_width(), atlas.get_height())
	var eight: bool = tiles.any(func(g): return g.eight)
	var stride := 8 if eight else 4
	var vertices := PackedVector3Array(); var normals := PackedVector3Array(); var uvs := PackedVector2Array()
	var bones := PackedInt32Array(); var weights := PackedFloat32Array(); var indices := PackedInt32Array()
	var colors := PackedColorArray(); var line := PackedByteArray(); var line_tone := PackedByteArray()
	var alpha := false
	var first: Dictionary = tiles[0].tile
	for t in tiles.size():
		var group: Dictionary = tiles[t]
		var info: Dictionary = group.tile
		alpha = alpha or bool(info.alpha)
		var cell := Vector2i(t % ATLAS_COLUMNS, t / ATLAS_COLUMNS) * TILE
		atlas.blit_rect(_tile_image(info), Rect2i(0, 0, TILE, TILE), cell)
		var inner := float(TILE - 2 * TILE_PAD)
		var fill := (info.color as Color).srgb_to_linear()
		var shade := (info.shade as Color).srgb_to_linear()
		var tone := Color(_ratio(shade.r, fill.r), _ratio(shade.g, fill.g), _ratio(shade.b, fill.b), (info.shade as Color).a)
		var line_fill := (info.line as Color).srgb_to_linear()
		var line_shade := (info.line_shade as Color).srgb_to_linear()
		var src: Array = group.out
		var src_vertices: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		var src_normals: Variant = src[Mesh.ARRAY_NORMAL]
		var src_uvs: Variant = src[Mesh.ARRAY_TEX_UV]
		var src_bones: PackedInt32Array = src[Mesh.ARRAY_BONES]
		var src_weights: PackedFloat32Array = src[Mesh.ARRAY_WEIGHTS]
		var src_stride := 8 if group.eight else 4
		var base := vertices.size()
		for v in src_vertices.size():
			vertices.append(src_vertices[v])
			normals.append(src_normals[v] if src_normals != null else Vector3.UP)
			var uv: Vector2 = (src_uvs[v] as Vector2).clamp(Vector2.ZERO, Vector2.ONE) if src_uvs != null else Vector2(0.5, 0.5)
			uvs.append((Vector2(cell) + Vector2(TILE_PAD, TILE_PAD) + uv * inner) / size)
			for k in stride:
				bones.append(src_bones[v * src_stride + k] if k < src_stride else 0)
				weights.append(src_weights[v * src_stride + k] if k < src_stride else 0.0)
			colors.append(tone)
			# Atlas UVs lose the native socket region. Bake its zero hull width
			# before remapping; keep the authored eyelash rim in the eye mesh.
			var socket := bool(info.eye_socket_mask) and uv.x >= .480 and uv.x <= .610 and uv.y >= .690 and uv.y <= .820
			line.append_array([_byte(line_fill.r), _byte(line_fill.g), _byte(line_fill.b), 0 if socket else _byte(float(info.width) / 0.01)])
			line_tone.append_array([_byte(_ratio(line_shade.r, line_fill.r)), _byte(_ratio(line_shade.g, line_fill.g)),
				_byte(_ratio(line_shade.b, line_fill.b)), _byte((info.line_shade as Color).a)])
		var src_indices: PackedInt32Array = src[Mesh.ARRAY_INDEX]
		for i in src_indices.size():
			indices.append(src_indices[i] + base)
		group["merged"] = true
	atlas.generate_mipmaps()
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = vertices
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_COLOR] = colors
	out[Mesh.ARRAY_CUSTOM0] = line
	out[Mesh.ARRAY_CUSTOM1] = line_tone
	out[Mesh.ARRAY_BONES] = bones
	out[Mesh.ARRAY_WEIGHTS] = weights
	out[Mesh.ARRAY_INDEX] = indices
	var flags: int = (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	if eight: flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
	job["merged"] = {"arrays": out, "flags": flags, "atlas": atlas, "alpha": alpha,
		"specular": first.specular, "fresnel": first.fresnel}


## shade / fill per channel, halved into 0..1 (the shaders double it back).
static func _ratio(shade: float, fill: float) -> float:
	return clampf(shade / maxf(fill, 0.0001), 0.0, 2.0) * 0.5


static func _byte(value: float) -> int:
	return clampi(roundi(value * 255.0), 0, 255)


## One atlas tile: the source texture shrunk to the tile (edge pixels repeated into the padding
## so mipmaps do not bleed), times the material colour, as a linear product stored in sRGB.
static func _tile_image(info: Dictionary) -> Image:
	var inner := TILE - 2 * TILE_PAD
	var source: Image = null
	if info.image != null:
		source = (info.image as Image).duplicate()
		if source.is_compressed(): source.decompress()
		source.convert(Image.FORMAT_RGBA8)
		source.clear_mipmaps()
		while source.get_width() >= inner * 2 and source.get_height() >= inner * 2:
			source.shrink_x2()
		source.resize(inner, inner, Image.INTERPOLATE_BILINEAR)
	var color := (info.color as Color).srgb_to_linear()
	var palette: Array = info.palette
	var tile := Image.create(TILE, TILE, false, Image.FORMAT_RGBA8)
	for y in TILE:
		for x in TILE:
			var texel := source.get_pixel(clampi(x - TILE_PAD, 0, inner - 1), clampi(y - TILE_PAD, 0, inner - 1)) if source != null else Color.WHITE
			var rgb := Color(texel.r, texel.g, texel.b).srgb_to_linear()
			if not palette.is_empty():
				var a := (palette[0] as Color).srgb_to_linear(); var b := (palette[1] as Color).srgb_to_linear()
				var axis := Vector3(b.r - a.r, b.g - a.g, b.b - a.b)
				var blend := clampf(Vector3(rgb.r - a.r, rgb.g - a.g, rgb.b - a.b).dot(axis) / maxf(axis.dot(axis), 0.000001), 0.0, 1.0)
				rgb = (palette[2] as Color).srgb_to_linear().lerp((palette[3] as Color).srgb_to_linear(), blend)
			var out := Color(rgb.r * color.r, rgb.g * color.g, rgb.b * color.b).linear_to_srgb()
			out.a = texel.a * color.a
			tile.set_pixel(x, y, out)
	return tile


## Main thread: the merged surface's material, outline hull chained as next_pass.
static func _merged_material(merged: Dictionary) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = FAR_SHADER
	material.set_shader_parameter("atlas", ImageTexture.create_from_image(merged.atlas))
	material.set_shader_parameter("alpha_test", merged.alpha)
	material.set_shader_parameter("specular", merged.specular)
	material.set_shader_parameter("fresnel", merged.fresnel)
	var hull := ShaderMaterial.new()
	hull.shader = FAR_OUTLINE_SHADER
	hull.set_shader_parameter("specular", merged.specular)
	hull.set_shader_parameter("fresnel", merged.fresnel)
	material.next_pass = hull
	return material
