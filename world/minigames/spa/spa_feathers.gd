extends RefCounted
## Stray feathers for the spa wing service (plan 3.C, step 10). Each one is the Blender-made
## stray_feather.glb, tinted in her own coat colours and pinned to one of her real open-wing feather
## bones (the bones hybrid_open_wings.gd skins its meshes to), sticking out crooked. Plucked, it
## becomes a LooseFeather that drifts down, can be dropped in the basket and fades after a while.
## Nothing visible is built from code: only the GLB is instanced.
const FEATHER := "res://world/props/spa/stray_feather.glb"
const FILE := "res://world/props/spa/hoof_file.glb"
const BELL := "res://world/props/spa/spa_bell.glb"
## Open-wing feather bones a stray may sit on (both wings). Tip and middle rows, where a loose one
## shows; the base rows lie under the coverts.
const BONES: Array[String] = ["pony_FeatherTipF_L", "pony_FeatherTipM_L", "pony_FeatherTipR_L", "pony_FeatherBaseM_001_L",
	"pony_FeatherTipF_R", "pony_FeatherTipM_R", "pony_FeatherTipR_R", "pony_FeatherBaseM_001_R"]
## How crooked a stray sticks out of its feather row.
const CROOKED_DEG := Vector2(28.0, 48.0)
## The feather mesh's quill is at its origin and the vane runs toward -Z (stray_feather.glb).
const LENGTH := 0.074


static func load_prop(path: String) -> Node3D:
	# Imported normally; before the editor has imported a fresh GLB, read it from disk.
	if ResourceLoader.exists(path):
		var packed := load(path) as PackedScene
		if packed != null: return packed.instantiate() as Node3D
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK: return null
	return doc.generate_scene(state) as Node3D


static func meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node == null: return out
	if node is MeshInstance3D: out.append(node as MeshInstance3D)
	for child in node.get_children(): out.append_array(meshes(child))
	return out


## Her coat fill, a touch toward her coat line at the tip (one material per feather).
static func tint(node: Node3D, coat: Color) -> void:
	for mi in meshes(node):
		for surface in mi.mesh.get_surface_count():
			var source := mi.get_active_material(surface) as StandardMaterial3D
			var tinted: StandardMaterial3D = source.duplicate() if source != null else StandardMaterial3D.new()
			tinted.albedo_color = coat
			mi.set_surface_override_material(surface, tinted)


static func coat_of(actor: Node3D) -> Color:
	if actor.has_method("coat_fill"): return actor.coat_fill()
	var identity: Resource = actor.get("identity")
	return identity.get("coat_fill") if identity != null else Color.WHITE


## Where each open-wing bone's feather really lies: the open-wing meshes skinned on the CPU in her
## current pose (bone heads sit at the wing root, so a bone origin alone is not the feather).
## Returns {bone index: {"head": skeleton-space head, "far": skeleton-space farthest vertex that
## bone mainly moves}}. Empty without open-wing meshes.
static func wing_points(skeleton: Skeleton3D, wing_meshes: Array) -> Dictionary:
	var out := {}
	for mi: Variant in wing_meshes:
		if not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null or (mi as MeshInstance3D).skin == null: continue
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		var skin: Skin = (mi as MeshInstance3D).skin
		var binds: Array[Transform3D] = []
		var bones: Array[int] = []
		for i in skin.get_bind_count():
			var bone := skin.get_bind_bone(i)
			bones.append(bone)
			binds.append(skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(i) if bone >= 0 else Transform3D.IDENTITY)
		for surface in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var vb: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
			var vw: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
			if verts.is_empty() or vb.size() < verts.size(): continue
			var per := vb.size() / verts.size()
			for v in verts.size():
				var point := Vector3.ZERO
				var main := -1
				var main_weight := 0.0
				for k in per:
					var w := vw[v * per + k]
					if w <= 0.0: continue
					var bind := vb[v * per + k]
					if bind >= binds.size(): continue
					point += (binds[bind] * verts[v]) * w
					if w > main_weight: main_weight = w; main = bones[bind]
				if main < 0 or main_weight < 0.6: continue
				var head := skeleton.get_bone_global_pose(main).origin
				var entry: Dictionary = out.get(main, {"head": head, "far": head, "reach": 0.0})
				var reach := point.distance_to(head)
				if reach > float(entry.reach):
					entry.far = point; entry.reach = reach
				out[main] = entry
	return out


## Pins `count` stray feathers onto her open-wing feather bones (wings must be open). Each sits 70%
## along its real feather, leaving it at a crooked angle, inside a BoneAttachment3D on her own
## skeleton so it follows the wing. Returns the feather nodes.
static func spawn(actor: Node3D, count: int, rng: RandomNumberGenerator, wing_meshes: Array = []) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var skeleton: Skeleton3D = actor.get("skeleton") as Skeleton3D
	if skeleton == null: return out
	var points := wing_points(skeleton, wing_meshes)
	var free_bones: Array[String] = []
	for bone: String in BONES:
		var index := skeleton.find_bone(bone)
		if index >= 0 and points.has(index) and float(points[index].reach) > 0.03: free_bones.append(bone)
	var size := float(actor.get("body_scale")) if actor.get("body_scale") != null else 1.0
	var skeleton_scale := maxf(skeleton.global_basis.get_scale().y, 0.001)
	var coat := coat_of(actor)
	for n in mini(count, free_bones.size()):
		var bone: String = free_bones.pop_at(rng.randi_range(0, free_bones.size() - 1))
		var index := skeleton.find_bone(bone)
		var feather := load_prop(FEATHER)
		if feather == null: break
		var head: Vector3 = points[index].head
		var far: Vector3 = points[index].far
		var at := head.lerp(far, rng.randf_range(0.6, 0.8))
		var along := (far - head).normalized()
		# Crooked: turned out of its row about the vertical, and lifted a little off the wing.
		var crooked := deg_to_rad(rng.randf_range(CROOKED_DEG.x, CROOKED_DEG.y)) * (1.0 if bone.ends_with("_L") else -1.0)
		var direction := (along.rotated(Vector3.UP, crooked) + Vector3.UP * 0.3).normalized()
		# Feather -Z along `direction`, its flat face up (skeleton space).
		var basis := Basis.looking_at(direction, Vector3.UP).scaled(Vector3.ONE * size / skeleton_scale)
		var mount := BoneAttachment3D.new()
		mount.name = "SpaStrayFeather_" + bone
		mount.bone_name = bone
		mount.set_meta("spa_mount", true)
		skeleton.add_child(mount, true)
		mount.add_child(feather)
		feather.transform = skeleton.get_bone_global_pose(index).affine_inverse() * Transform3D(basis, at)
		tint(feather, coat.lerp(Color.WHITE, 0.08))
		feather.set_meta("spa_feather_bone", bone)
		out.append(feather)
	return out


## The massage line on each open wing (world): from the wing root to its farthest feather, both
## held in their own bones' frames so they follow the wing. [[root, tip], ...]
## Each line also carries two empty BoneAttachment3D mounts (tagged "spa_mount", removed by clear()):
## outside the skeleton's own update, get_bone_global_pose() is the pose before modifiers, so the
## spa's half-open hold (a modifier in hybrid_open_wings.gd) is only seen through attachments.
static func wing_lines(skeleton: Skeleton3D, wing_meshes: Array) -> Array:
	var out := []
	var points := wing_points(skeleton, wing_meshes)
	for suffix: String in ["_L", "_R"]:
		var root := skeleton.find_bone("pony_WingBase" + suffix)
		if root < 0: continue
		var root_point := skeleton.get_bone_global_pose(root).origin
		var best := Vector3.INF
		var best_bone := -1
		var reach := 0.0
		for bone: Variant in points:
			var name := skeleton.get_bone_name(int(bone))
			if not name.ends_with(suffix): continue
			var far: Vector3 = points[bone].far
			if far.distance_to(root_point) > reach: reach = far.distance_to(root_point); best = far; best_bone = int(bone)
		if best_bone < 0: continue
		out.append([root, Vector3.ZERO, best_bone, skeleton.get_bone_global_pose(best_bone).affine_inverse() * best,
			_line_mount(skeleton, root), _line_mount(skeleton, best_bone)])
	return out


static func _line_mount(skeleton: Skeleton3D, bone: int) -> BoneAttachment3D:
	var mount := BoneAttachment3D.new()
	mount.name = "SpaWingLine_%d" % bone
	mount.bone_name = skeleton.get_bone_name(bone)
	mount.set_meta("spa_mount", true)
	skeleton.add_child(mount, true)
	mount.transform = skeleton.get_bone_global_pose(bone)
	return mount


## World [root, tip] pairs for wing_lines() entries in her current pose.
static func lines_world(skeleton: Skeleton3D, lines: Array) -> Array:
	var out := []
	for line: Array in lines:
		var root: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(int(line[0])).origin
		var tip: Vector3 = skeleton.global_transform * (skeleton.get_bone_global_pose(int(line[2])) * Vector3(line[3]))
		if line.size() >= 6 and is_instance_valid(line[4]) and is_instance_valid(line[5]):
			root = (line[4] as Node3D).global_position
			tip = (line[5] as Node3D).global_transform * Vector3(line[3])
		out.append([root, tip])
	return out


## Where the quill meets her wing, and the tip a hand pinches (world).
static func root_point(feather: Node3D) -> Vector3:
	return feather.global_position


static func tip_point(feather: Node3D) -> Vector3:
	return feather.global_transform * (Vector3.FORWARD * LENGTH * 0.7)


## Bends a pinched feather toward the hand (0..1 of a small turn) before it pops.
static func bend(feather: Node3D, toward: Vector3, amount: float) -> void:
	if not feather.has_meta("spa_rest"): feather.set_meta("spa_rest", feather.transform)
	var rest: Transform3D = feather.get_meta("spa_rest")
	var parent := feather.get_parent() as Node3D
	if parent == null or not toward.is_finite(): return
	var local := parent.global_transform.affine_inverse() * toward - rest.origin
	var tip := rest.basis * Vector3.FORWARD
	if local.length() < 0.001: return
	var axis := tip.cross(local.normalized())
	if axis.length() < 0.0001: return
	var turn := minf(tip.angle_to(local.normalized()), deg_to_rad(25.0)) * clampf(amount, 0.0, 1.0)
	feather.transform = Transform3D(Basis(axis.normalized(), turn) * rest.basis, rest.origin)


## Pops a pinned feather off her wing into the world as a loose one. Returns the loose node.
static func detach(feather: Node3D, world: Node) -> LooseFeather:
	var placed := feather.global_transform
	var mount := feather.get_parent()
	var loose := LooseFeather.new()
	loose.name = "SpaLooseFeather"
	world.add_child(loose)
	loose.global_transform = Transform3D(placed.basis.orthonormalized(), placed.origin)
	var scale := placed.basis.get_scale()
	mount.remove_child(feather)
	loose.add_child(feather)
	feather.transform = Transform3D(Basis.from_scale(scale), Vector3.ZERO)
	if feather.has_meta("spa_rest"): feather.remove_meta("spa_rest")
	if mount != null and mount.get_child_count() == 0: mount.queue_free()
	return loose


## Removes every stray still on her wings and the wing-line mounts (she leaves, or the visit ends).
static func clear(actor: Node3D) -> void:
	var skeleton: Skeleton3D = actor.get("skeleton") as Skeleton3D if is_instance_valid(actor) else null
	if skeleton == null: return
	for child in skeleton.get_children():
		# Matched by tag, not name: Godot renames a duplicate child name to @BoneAttachment3D@N.
		if child is BoneAttachment3D and child.has_meta("spa_mount"):
			drop_tints(child)
			skeleton.remove_child(child)
			child.queue_free()


## Takes the tinted (one per feather) materials off its meshes before the node is freed. Freed
## with the node, a tint went before the mesh's render instance, whose free still read it
## ("Parameter material is null", M-TST-03). Off first, the instance holds none of them.
static func drop_tints(node: Node) -> void:
	var held: Array[Material] = []
	for mi in meshes(node):
		if mi.mesh == null: continue
		for surface in mi.mesh.get_surface_count():
			var tinted := mi.get_surface_override_material(surface)
			if tinted == null: continue
			held.append(tinted)
			mi.set_surface_override_material(surface, null)
	held.clear()


## A plucked feather: follows a hand while held, otherwise drifts down with a little sway and rests on
## the floor. In the basket it stays put. It fades out after LIFETIME seconds either way.
class LooseFeather:
	extends Node3D
	const FALL_SPEED := 0.22
	const SWAY := 0.05
	const LIFETIME := 90.0
	const FADE := 1.5
	var held_by := ""
	var in_basket := false
	var _age := 0.0
	var _resting := false
	var _phase := randf() * TAU

	func _physics_process(delta: float) -> void:
		_age += delta
		if _age >= LIFETIME:
			scale = Vector3.ONE * maxf(0.01, 1.0 - (_age - LIFETIME) / FADE)
			if _age >= LIFETIME + FADE:
				# As drop_tints(): the tint off its mesh before the node (and the tint) are freed.
				for mi in find_children("*", "MeshInstance3D", true, false):
					var mesh := (mi as MeshInstance3D).mesh
					for surface in (mesh.get_surface_count() if mesh != null else 0): (mi as MeshInstance3D).set_surface_override_material(surface, null)
				queue_free()
			return
		if not held_by.is_empty() or _resting or in_basket: return
		_phase += delta * 2.4
		var step := Vector3(sin(_phase) * SWAY, -FALL_SPEED, cos(_phase * 0.7) * SWAY * 0.5) * delta
		var space := get_world_3d().direct_space_state
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(global_position, global_position + step + Vector3.DOWN * 0.01, 1))
		if not hit.is_empty():
			global_position = Vector3(hit.position) + Vector3.UP * 0.003
			_resting = true
			# Lie flat on what it landed on.
			global_basis = Basis(Vector3.UP, global_rotation.y)
			return
		global_position += step
		rotate_object_local(Vector3.FORWARD, sin(_phase) * delta * 0.8)

	func hold(side: String) -> void:
		held_by = side; _resting = false

	func drop() -> void:
		held_by = ""; _resting = false

	func into_basket(at: Vector3) -> void:
		held_by = ""; in_basket = true
		global_position = at
