extends "res://world/characters/hybrid_mare/hybrid_mare.gd"
## Additional identities reuse the approved hybrid without changing its source files.
const ANCHORS=preload("res://world/characters/hybrid_mare/hybrid_tail_anchor.gd")
const PHYSICS=preload("res://world/characters/hybrid_mare/hybrid_tail_physics.gd")

func _apply_show_shading(model: Node) -> void:
	super._apply_show_shading(model)
	if identity != null and identity.character() == "strawberry_sunrise":
		_solid_strawberry_hair(model)
	if identity == null or identity.character() != "braeburn": return
	var meshes: Array = [model] if model is MeshInstance3D else model.find_children("*", "MeshInstance3D", true, false)
	for mi: MeshInstance3D in meshes:
		if not String(mi.name).begins_with("BraeburnDevkit"): continue
		for surface in mi.mesh.get_surface_count():
			var material := mi.get_active_material(surface) as ShaderMaterial
			if material != null:
				# Original texture's two colors -> Braeburn's published show palette.
				# https://mlpvector.club/cg/pony/v/121-Braeburn
				material.set_shader_parameter("replace_texture_palette", true)
				material.set_shader_parameter("texture_palette_source_a", Color("f7a433"))
				material.set_shader_parameter("texture_palette_source_b", Color("f8d45a"))
				material.set_shader_parameter("texture_palette_a", Color("db9e44"))
				material.set_shader_parameter("texture_palette_b", Color("e3cc6f"))

## Cheerilee's borrowed painted bands survive the generic HSL recolour as pink.
## Strawberry's full hair palette is one existing dark red; keep cel light/shadow and ink.
## Per-surface copies isolate other identities sharing this source hair.
func _solid_strawberry_hair(model: Node) -> void:
	var meshes: Array = [model] if model is MeshInstance3D else model.find_children("*", "MeshInstance3D", true, false)
	for mesh: MeshInstance3D in meshes:
		var name_lower := str(mesh.name).to_lower()
		if mesh.mesh == null or not (name_lower.contains("mane") or name_lower.contains("tail")): continue
		for surface in mesh.mesh.get_surface_count():
			var active := mesh.get_active_material(surface) as ShaderMaterial
			if active == null: continue
			var material := active.duplicate() as ShaderMaterial
			var red: Color = identity.mane_line
			material.set_shader_parameter("replace_texture_palette", true)
			material.set_shader_parameter("texture_palette_source_a", Color.BLACK)
			material.set_shader_parameter("texture_palette_source_b", Color.WHITE)
			material.set_shader_parameter("texture_palette_a", red)
			material.set_shader_parameter("texture_palette_b", red)
			var ink := material.next_pass as ShaderMaterial
			if ink != null:
				ink = ink.duplicate() as ShaderMaterial
				var line: Color = red.darkened(.4)
				if ink.shader.resource_path.ends_with("outline-tinted.gdshader"):
					ink.set_shader_parameter("outline_color", line)
				else:
					ink.set_shader_parameter("color", line)
					ink.set_shader_parameter("shadow_color", _shade_of(line))
				material.next_pass = ink
			mesh.set_surface_override_material(surface, material)

func _dress_body_for_race() -> void:
	for patch in _model.find_children("Cutie mark*", "MeshInstance3D", true, false):
		var variant := "stallion/" if identity != null and identity.stallion else ""
		var path := "res://world/characters/background/support/"+variant+String(patch.name)+".res"
		if ResourceLoader.exists(path): patch.mesh = load(path)
	super._dress_body_for_race()

func _ready()->void:
	if identity!=null:
		for suffix in ["","LOD1"]:
			var path:String="res://world/characters/background/support/"+identity.id+suffix+".res"
			if not ResourceLoader.exists(path):continue
			var anchored:ArrayMesh=load(path)
			if anchored.get_meta("anchor_version",-1)!=ANCHORS.VERSION or int(anchored.get_meta("source_mtime",-1))!=FileAccess.get_modified_time(identity.hair_scene):continue
			ANCHORS.cache[String(identity.id)+suffix]=anchored
			if suffix=="" and anchored.get_meta("contact_version",-1)==PHYSICS.CONTACT_VERSION:
				PHYSICS._contact_cache[anchored.get_instance_id()]=anchored.get_meta("contacts")
	super._ready()
	if identity != null and identity.character() == "vinyl_scratch": _attach_vinyl_glasses()
	if identity != null and identity.character() == "braeburn": _attach_braeburn_hat()
	if tail_motion != null and tail_motion.springs != null:
		var previous_springs = tail_motion.springs
		var springs = preload("res://world/characters/background/background_tail_physics.gd").new()
		for property in ["bone_names", "mount_name", "angle_limits", "terminal_length", "segment_radii"]:
			springs.set(property, previous_springs.get(property))
		springs.bind(self, hair_skeleton)
		tail_motion.springs = springs
	if identity != null and identity.character() == "derpy_hooves" and eye_motion != null:
		var previous := eye_motion
		var sk: Skeleton3D = head.skeleton
		var index := previous.get_index()
		sk.remove_child(previous)
		eye_motion = preload("res://world/characters/background/background_eye_motion.gd").new()
		eye_motion.name = "NativeEyeMotion"
		eye_motion.asymmetric_gaze = true
		sk.add_child(eye_motion)
		sk.move_child(eye_motion, index)
		eye_motion.bind(head.player)
		eye_motion.surface_update = head.update_show_eyes
		expressions.bind(head.mouth, eye_motion)
		previous.free()

func _attach_braeburn_hat() -> void:
	var path := "res://world/characters/background/accessories/braeburn_hat.glb"
	if hair_skeleton == null or not ResourceLoader.exists(path): return
	identity = identity.duplicate()
	if "BraeburnHat" not in identity.accessories: identity.accessories.append("BraeburnHat")
	var attachment := BoneAttachment3D.new()
	attachment.name = "BraeburnHatAttachment"; attachment.bone_name = "mHead"
	hair_skeleton.add_child(attachment)
	var source: Node3D = load(path).instantiate()
	attachment.add_child(source)
	for mesh: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		mesh.reparent(attachment, false); mesh.name = "BraeburnHat"
		_apply_show_shading(mesh)
	source.queue_free()
	_exclude_world_ink()

func _attach_vinyl_glasses() -> void:
	var path := "res://world/characters/background/accessories/vinyl_glasses.scn"
	if hair_skeleton == null or not ResourceLoader.exists(path): return
	# Duplicate the identity, so shared resources and generated inputs stay untouched.
	identity = identity.duplicate()
	if "VinylGlasses" not in identity.accessories: identity.accessories.append("VinylGlasses")
	var attachment := BoneAttachment3D.new()
	attachment.name = "VinylGlassesAttachment"; attachment.bone_name = "mHead"
	hair_skeleton.add_child(attachment)
	var packed: PackedScene = load(path)
	var source := packed.instantiate()
	attachment.add_child(source)
	var meshes: Array[Node] = source.find_children("*", "MeshInstance3D", true, false)
	if source is MeshInstance3D: meshes.append(source)
	for mesh: MeshInstance3D in meshes:
		mesh.reparent(attachment, false)
		mesh.name = "VinylGlasses"
	if source.get_parent() == attachment and not source is MeshInstance3D: source.queue_free()
