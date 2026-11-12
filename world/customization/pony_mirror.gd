extends SubViewport
## Mesh-only live pony mirror: copies skins and poses, no second actor/AI/collision rig.
var camera: Camera3D
var source: Node3D
var profile: RefCounted
var active := false
var yaw := 0.0
var zoom := 3.0
var _scene: Node3D
var _model: Node3D
var _skeletons: Dictionary = {}
func setup(settings: RefCounted, actual_player: Node3D) -> void:
	profile = settings; source = actual_player
	size = Vector2i(480,576); own_world_3d = true
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	_scene = Node3D.new(); add_child(_scene)
	var env := WorldEnvironment.new(); env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("424c4b")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color("d3d9d8")
	env.environment.ambient_light_energy = 0.7; _scene.add_child(env)
	var light := DirectionalLight3D.new(); light.rotation_degrees = Vector3(-30,-30,0); _scene.add_child(light)
	camera = Camera3D.new(); camera.fov = 35
	# Placed from _process: no physics interpolation (else "Interpolated Camera3D triggered from outside physics process").
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_scene.add_child(camera)
	profile.changed.connect(_rebuild)
	_rebuild(); set_active(false)
func _rebuild() -> void:
	if not is_instance_valid(source): return
	if is_instance_valid(_model): _model.free()
	_model = Node3D.new(); _scene.add_child(_model); _skeletons.clear()
	var relative := source.global_transform.affine_inverse()
	for original: Skeleton3D in source.find_children("*", "Skeleton3D", true, false):
		var copy := Skeleton3D.new(); _model.add_child(copy)
		copy.transform = relative * original.global_transform
		for i in original.get_bone_count():
			copy.add_bone(original.get_bone_name(i)); copy.set_bone_parent(i, original.get_bone_parent(i))
			copy.set_bone_rest(i, original.get_bone_rest(i)); copy.set_bone_pose(i, original.get_bone_pose(i))
		_skeletons[original] = copy
	for original: MeshInstance3D in source.find_children("*", "MeshInstance3D", true, false):
		if not original.is_visible_in_tree() or original.mesh == null or original.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY: continue
		var copy := MeshInstance3D.new(); copy.mesh = original.mesh; copy.skin = original.skin
		copy.material_override = original.material_override
		for i in original.mesh.get_surface_count(): copy.set_surface_override_material(i, original.get_surface_override_material(i))
		_model.add_child(copy); copy.transform = relative * original.global_transform
		if not original.skeleton.is_empty():
			var original_sk := original.get_node_or_null(original.skeleton)
			if _skeletons.has(original_sk): copy.skeleton = copy.get_path_to(_skeletons[original_sk])
	_update_camera()
func _update_camera() -> void:
	var size_factor := float(source.get("body_scale")) if is_instance_valid(source) else 1.0
	camera.position = Vector3(sin(yaw)*zoom*0.64,0.54,-cos(yaw)*zoom*0.64)*size_factor
	camera.look_at(Vector3(0,0.51,0.06)*size_factor)
func set_active(value: bool) -> void:
	active = value; set_process(value)
	render_target_update_mode = SubViewport.UPDATE_ALWAYS if value else SubViewport.UPDATE_DISABLED
func _process(_delta: float) -> void:
	for original: Skeleton3D in _skeletons:
		if not is_instance_valid(original): continue
		var copy: Skeleton3D = _skeletons[original]
		for i in original.get_bone_count(): copy.set_bone_pose(i,original.get_bone_pose(i))
	_update_camera()
