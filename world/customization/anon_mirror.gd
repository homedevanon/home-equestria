extends SubViewport
## Actual player scene, isolated World3D. Source IK pose copied before head hiding.
var avatar: Node3D
var skeleton: Skeleton3D
var camera: Camera3D
var source: Node3D
var _modifier: SkeletonModifier3D
var _pending_pose: Array[Transform3D] = []
var active := false
var yaw := 0.
var zoom := 3.
var _timer := 0.
func setup(profile: RefCounted, actual_player: Node3D):
	size=Vector2i(480,576);own_world_3d=true;transparent_bg=false;render_target_update_mode=SubViewport.UPDATE_DISABLED
	var scene:=Node3D.new();add_child(scene)
	var env:=WorldEnvironment.new();env.environment=Environment.new();env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color("424c4b");env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color("d3d9d8");env.environment.ambient_light_energy=.7;scene.add_child(env)
	var light:=DirectionalLight3D.new();light.rotation_degrees=Vector3(-30,-30,0);light.light_energy=1.2;scene.add_child(light)
	avatar=load("res://world/customization/anon_preview.tscn").instantiate()
	# Run the established driver only for the neutral desktop stance. No gameplay groups,
	# collision, voice or population systems exist in this isolated preview world.
	scene.add_child(avatar)
	var head:=Node3D.new();head.position=Vector3(0,1.68,0);scene.add_child(head)
	var left:=Node3D.new();left.position=Vector3(-.28,1.04,-.14);scene.add_child(left)
	var right:=Node3D.new();right.position=Vector3(.28,1.04,-.14);scene.add_child(right)
	avatar.setup(head,left,right)
	avatar.standing_eye_height=1.68
	avatar.find_child("HeadHide",true,false).active=false
	avatar.find_child("LegHide",true,false).active=false
	skeleton=avatar.find_child("Skeleton3D",true,false)
	profile.attach(avatar)
	source=actual_player
	if is_instance_valid(source):
		_modifier=source.find_child("BodyIK",true,false)
		if _modifier!=null:
			_modifier.modification_processed.connect(_capture_pose)
			avatar.find_child("BodyIK",true,false).active=false
			avatar.set_process(false);avatar.set_physics_process(false)
			avatar.get_node("Model").scale=source.get_node("Model").scale
	camera=Camera3D.new();camera.fov=42;camera.near=.05;camera.far=10;camera.current=true
	# Placed from _process: no physics interpolation (else "Interpolated Camera3D triggered from outside physics process").
	camera.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF
	scene.add_child(camera)
	_update_camera()
	set_active(false)
func _capture_pose():
	if not active:return
	var sk:Skeleton3D=_modifier.get_skeleton()
	_pending_pose.resize(sk.get_bone_count())
	for i in sk.get_bone_count():_pending_pose[i]=sk.get_bone_pose(i)
func _update_camera():
	# The preview Anon faces -Z (its head and hands targets sit ahead of him there); yaw 0 is
	# the "Front" button, so the camera starts on that side.
	camera.position=Vector3(sin(yaw)*zoom,1.,-cos(yaw)*zoom)
	camera.look_at(Vector3(0,.90,0))
func set_active(value: bool):
	active=value;set_process(value)
	if avatar!=null:avatar.process_mode=Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED
	render_target_update_mode=SubViewport.UPDATE_ONCE if value else SubViewport.UPDATE_DISABLED
func _process(delta: float):
	_timer+=delta
	if _timer<.05:return
	_timer=0.
	if not _pending_pose.is_empty():
		for i in mini(_pending_pose.size(),skeleton.get_bone_count()):skeleton.set_bone_pose(i,_pending_pose[i])
	_update_camera();render_target_update_mode=SubViewport.UPDATE_ONCE
func _exit_tree():
	if is_instance_valid(_modifier) and _modifier.modification_processed.is_connected(_capture_pose):_modifier.modification_processed.disconnect(_capture_pose)
