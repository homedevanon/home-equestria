extends SceneTree
## Native navigation and locomotion in the furnished room with the player waiting outside.
const FEET := Vector3(152.069443, -19.001764, -12.352576)
const YAW := .34508434

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var room: Node3D = load("res://world/buildings/fluttershy/cottage.tscn").instantiate()
	room.position = Vector3(151, -19.863147, -10)
	room.rotation.y = -1.51204
	world.add_child(room)
	var home: Node3D = room.home
	var inside: Vector3 = home.inside()
	var outside: Vector3 = home.outside()
	var outward := (outside - inside).slide(Vector3.UP).normalized()

	# The exported building ends at its ramp. Supply the terrain on the far side.
	var yard := StaticBody3D.new()
	world.add_child(yard)
	yard.global_position = outside + outward * 10.0 + Vector3.DOWN * .29
	yard.look_at(yard.global_position + outward)
	var ground := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8, .5, 22)
	ground.shape = box
	yard.add_child(ground)
	var service: Node3D = load("res://world/navigation/walk_grid_service.gd").bake(world, {"id": "indoor_departure"})

	var leader := Node3D.new()
	world.add_child(leader)
	leader.position = outside + outward * 15.0
	var camera := Camera3D.new()
	leader.add_child(camera)
	camera.position.y = 1.6
	camera.look_at(FEET)
	camera.make_current()

	var pony: CharacterBody3D = load("res://world/characters/mane6/fluttershy.tscn").instantiate()
	pony.position = FEET
	pony.rotation.y = YAW
	world.add_child(pony)
	pony.set_physics_process(false)
	var nav: Node = load("res://world/characters/navigation/pony_navigator.gd").new()
	nav.name = "Navigator"
	pony.add_child(nav)
	nav.wander_enabled = false
	nav._service = service
	var door: Node3D = home.door()
	door.rotation.y = 1.1624813
	door.target = door.opening_angle()
	await physics_frame
	await physics_frame
	pony.set_sim_tier(pony.SimTier.NEAR)
	var cramped: bool = home.local_waypoint(FEET, inside).distance_to(FEET) < .05
	var reduced_physics: bool = pony._collision.disabled and pony.sim_tier == pony.SimTier.NEAR
	pony.set_physics_process(true)
	nav.follow(leader)
	var moved_in_near := false
	var crossed := false
	for tick in 1800:
		await physics_frame
		if pony.sim_tier == pony.SimTier.NEAR and pony._collision.disabled and FEET.direction_to(inside).dot(pony.global_position - FEET) > .4:
			moved_in_near = true
		var past_exit := (pony.global_position - outside).dot(outward) > .1
		if past_exit and not home.contains(pony.global_position) and not nav.house_travel.active():
			crossed = true
			print("INDOOR_DEPARTURE crossed after ", tick + 1, " physics ticks")
			break
	var passed: bool = cramped and reduced_physics and nav.native_follow and moved_in_near and crossed
	if not passed:
		printerr("INDOOR_DEPARTURE cramped=", cramped, " reduced_physics=", reduced_physics, " moved_in_near=", moved_in_near, " crossed=", crossed, " position=", pony.global_position, " reason=", nav.reason)
	world.free()
	print("INDOOR_DEPARTURE_DONE checks=1 failures=", 0 if passed else 1)
	quit(0 if passed else 1)
