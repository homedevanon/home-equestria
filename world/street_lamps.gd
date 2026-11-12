extends RefCounted
## Runtime upgrade of streamed lamps, including old bakes with nonpersistent groups.
const GROUP := "night_lights"
const GLOW_SHADER := preload("res://shaders/street_lamp_glow.gdshader")
## Look 2026-11-10: lamp halos use a real glow sprite, twice the old size. Rollback: LOOK_HALO = false.
const LOOK_HALO := true
const HALO_TEXTURE := preload("res://world/vfx/textures/glint_soft.png")
const PREFIXES := ["lamp_lod0", "candle lantern", "lamp post", "lamppost", "circlelantern", "lantern"]
static var _glow_mesh: QuadMesh
static var _glow_material: ShaderMaterial

static func prepare(root: Node) -> void:
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	for node in nodes:
		if node is OmniLight3D and node.has_meta("night_energy"):
			# Old prefix matching also lit lamp collider nodes. Those are duplicates.
			if node.get_parent() is CollisionObject3D:
				node.remove_from_group(GROUP)
				node.visible = false
				node.queue_free()
				continue
			_setup(node)
	for node in nodes:
		if not node is MeshInstance3D or node.mesh == null: continue
		var matched := false
		for prefix in PREFIXES:
			if str(node.name).to_lower().begins_with(prefix): matched = true; break
		if not matched or _has_light(node): continue
		# A marker above this mesh may already own the legacy light.
		if _has_light(node.get_parent(), false): continue
		var light := OmniLight3D.new()
		light.light_cull_mask &= ~(1<<16) # House interiors use their own light sources.
		light.name = "NightLight"
		light.light_color = Color(1.0, 0.74, 0.42)
		light.set_meta("night_energy", 4.0)
		light.omni_range = 11.0
		light.light_energy = 0.0
		node.add_child(light)
		_setup(light)
	root.get_tree().call_group("sky_controller", "_refresh_lamps")

static func _has_light(node: Node, recursive := true) -> bool:
	if node == null: return false
	for light in node.find_children("*", "OmniLight3D", recursive, false):
		if light.has_meta("night_energy"): return true
	return false

static func _setup(light: OmniLight3D) -> void:
	light.light_cull_mask &= ~(1<<16)
	light.add_to_group(GROUP, true)
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = fade_begin()
	light.distance_fade_length = 20.0
	if light.has_node("Glow"): return
	var parent := light.get_parent() as Node3D
	var mesh := parent as MeshInstance3D
	if mesh == null:
		for child in parent.find_children("*", "MeshInstance3D", true, false):
			mesh = child; break
	if mesh != null and mesh.mesh != null:
		var bounds: AABB = mesh.global_transform * mesh.get_aabb()
		var pos := bounds.get_center()
		var post := str(mesh.name).to_lower().begins_with("lamppost")
		pos.y = bounds.end.y - bounds.size.y * (0.23 if post else 0.45)
		light.global_transform = Transform3D(Basis.IDENTITY, pos)
	if _glow_mesh == null:
		_glow_mesh = QuadMesh.new(); _glow_mesh.size = Vector2(1.7, 1.7) if LOOK_HALO else Vector2(0.8, 0.8)
		_glow_material = ShaderMaterial.new(); _glow_material.shader = GLOW_SHADER
		if LOOK_HALO:
			_glow_material.set_shader_parameter("use_halo", true)
			_glow_material.set_shader_parameter("halo", HALO_TEXTURE)
	var glow := MeshInstance3D.new()
	glow.name = "Glow"
	glow.mesh = _glow_mesh
	glow.material_override = _glow_material
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.visibility_range_end = 100.0
	glow.set_instance_shader_parameter("glow_color", light.light_color)
	glow.set_instance_shader_parameter("glow_level", 0.0)
	light.add_child(glow)
	# The sky may have processed node_added before this glow existed.
	light.set_meta("night_needs_update", true)

## Where a lamp's light starts fading (quality.gd lamp_fade_begin: 45 m, Low 35, Very Low 25);
## sky_controller re-applies it to the lit group when the tier changes.
static func fade_begin() -> float:
	var loop := Engine.get_main_loop() as SceneTree
	var quality: Node = loop.root.get_node_or_null("Quality") if loop != null else null
	return float(quality.get_value("lamp_fade_begin", 45.0)) if quality != null else 45.0

static func apply(light: OmniLight3D, level: float) -> void:
	light.light_energy = float(light.get_meta("night_energy", 3.0)) * level
	light.visible = level > 0.001
	var glow := light.get_node_or_null("Glow") as MeshInstance3D
	if glow != null: glow.set_instance_shader_parameter("glow_level", level)
	light.remove_meta("night_needs_update")
