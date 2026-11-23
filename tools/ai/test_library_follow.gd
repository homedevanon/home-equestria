extends SceneTree
## Recorded loft blockage with actual Golden Oak furniture and physics queries.
## The player's save, inference services and real character base are never loaded.
class Actor extends CharacterBody3D:
	var profile: Resource
	var _collision: CollisionShape3D
	var facing_request := Vector3.ZERO
	func face_direction(direction: Vector3) -> void: facing_request = direction.normalized()
class Navigator extends Node:
	enum State { MOVING, WAITING }
	var pony: CharacterBody3D
	var _indoor_follow_cache := {}
	var arrival_distance := .65
	var house_travel: RefCounted
	var commands: Script
	var path := PackedVector3Array()
	var _native_authored := false
	var _native_speed_cap := 0.0
	var _needs_path := true
	var _path_serial := 0
	var _stuck_time := 0.0
	var state := State.WAITING
	var reason := ""
	var ticks := 0
	func _native_tick(_dt: float) -> void: ticks += 1
	func _halt() -> void: pass
	func command_target_floor(at: Vector3) -> Vector3: return commands.command_target_floor(self, at)
	func _indoor_follow_support(home: Node3D, at: Vector3, floor_y: float) -> Vector3:
		return commands.indoor_follow_support(self, home, at, floor_y)
var checks := 0
var failures := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1; print("LIBRARY_FOLLOW ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func run() -> void:
	Engine.print_error_messages = true
	var shell: Script = load("res://world/buildings/golden_oak/shell.gd")
	var source := Node3D.new(); root.add_child(source)
	source.position = Vector3(-13.206, -13.163347, -254.363)
	source.rotation.y = -2.19911; source.scale = Vector3.ONE * 2
	var frame := Node3D.new(); root.add_child(frame)
	frame.global_transform = Transform3D(source.global_basis.orthonormalized(), source.to_global(shell.ROOM_ORIGIN))
	shell._build_room(frame)
	var furniture: Node3D = load("res://world/buildings/golden_oak/interior.gd").new(); frame.add_child(furniture); furniture.build()
	var home: Node3D = load("res://world/buildings/golden_oak/home.gd").new()
	frame.add_child(home); home.configure({}, furniture, null)
	var actor := Actor.new(); actor.profile = load("res://world/characters/locomotion/pony_gait_profile.gd").new()
	actor.collision_layer = 2; actor.collision_mask = 1
	actor._collision = CollisionShape3D.new()
	# Unchanged standing controller dimensions from pony_rig_setup.gd; its planning
	# profile is deliberately wider, as in the recorded runtime body diagnostics.
	var body := CapsuleShape3D.new(); body.radius = .19; body.height = .85
	var original_body_radius := body.radius
	var original_planning_radius: float = actor.profile.radius
	actor._collision.shape = body; actor._collision.position.y = .425; actor.add_child(actor._collision)
	root.add_child(actor)
	actor.global_position = Vector3(-17.4936332702637, -8.98334503173828, -254.277969360352)
	var nav := Navigator.new(); actor.add_child(nav); nav.pony = actor
	nav.commands = load("res://world/characters/navigation/navigator_commands.gd")
	nav.house_travel = load("res://world/characters/navigation/house_travel.gd").new()
	await physics_frame; await physics_frame
	var leader := Vector3(-15.3264961242676, -7.82293748855591, -255.309494018555)
	var floor: Vector3 = nav.command_target_floor(leader)
	check(floor.is_finite() and absf(home.to_local(floor).y - 3.4) < .05, "recorded player is on the loft, not an old navigator destination downstairs")
	check(home.contains(actor.global_position) and home.contains(leader), "both recorded participants are inside the real library")
	var destination: Vector3 = home.to_global(Vector3(-.7,3.4,-1.65))
	var direct: Vector3 = nav.house_travel._waypoint(home, actor, actor.global_position, destination)
	var departure: Vector3 = nav.house_travel._departure(nav, home, destination)
	print("LIBRARY_FOLLOW_DIAGNOSTIC from=", home.to_local(actor.global_position), " direct=", home.to_local(direct), " departure=", home.to_local(departure) if departure.is_finite() else departure)
	check(direct.distance_to(actor.global_position) < .05, "recorded standing position overlaps the wider planning envelope beside the bed")
	check(departure.is_finite(), "unchanged controller can make a swept short departure into the certified aisle")
	nav.house_travel.clear(actor)
	var goal := Vector3(leader.x + 1.5, floor.y, leader.z)
	var chosen: Vector3 = nav.commands.command_follow_goal(nav, goal, leader)
	print("LIBRARY_FOLLOW_DIAGNOSTIC chosen=", home.to_local(chosen) if chosen.is_finite() else chosen)
	check(chosen.is_finite(), "follow slot validation allows the same certified departure as house execution")
	if chosen.is_finite():
		check(absf(home.to_local(chosen).y - 3.43) < .05, "follow destination retains full supported standing clearance on the leader's floor")
		nav.house_travel.native_walk(nav, chosen, home, chosen)
		check(nav.path.size() == 2 and nav.ticks == 1, "native execution receives the controller-certified departure corridor")
		if nav.path.size() == 2:
			check(nav.house_travel.controller_clear(actor, nav.path[1]), "short leg clears unchanged body, furniture and peers")
			var before := actor.global_position
			var hit := actor.move_and_collide(nav.path[1] - before)
			check(hit == null and actor.global_position.distance_to(before) > .1, "recorded body physically moves out of the blocked planning start")
			var next: Vector3 = nav.house_travel._waypoint(home, actor, actor.global_position, chosen)
			check(next.distance_to(actor.global_position) > .05, "normal authored route takes over after the short departure")
	# A downstairs leader still uses the staircase after departing the bed aisle.
	actor.global_position = Vector3(-17.4936332702637, -8.98334503173828, -254.277969360352)
	nav.house_travel.clear(actor); nav._indoor_follow_cache.clear()
	var downstairs := home.to_global(Vector3(0,1.7,3.8))
	var down_goal := home.to_global(Vector3(1.5,0,3.8))
	var down: Vector3 = nav.commands.command_follow_goal(nav, down_goal, downstairs)
	check(down.is_finite() and absf(home.to_local(down).y - .03) < .05, "blocked loft start can follow a supported leader downstairs")
	if down.is_finite():
		var leave: Vector3 = nav.house_travel._departure(nav, home, down)
		check(leave.is_finite() and absf(leave.y-actor.global_position.y) < .15, "departure stays on its own storey")
		if leave.is_finite():
			var at := leave
			var landing: Vector3 = home.to_global(home.stair_path[-1])
			var stayed_upstairs := true
			for i in 12:
				if at.distance_to(landing) < .05: break
				var next: Vector3 = nav.house_travel._waypoint(home, actor, at, down)
				stayed_upstairs = stayed_upstairs and absf(next.y-actor.global_position.y) < .15
				if next.distance_to(at) < .05: break
				at = next
			check(at.distance_to(landing) < .05 and stayed_upstairs, "remaining floor change reaches the stair landing before descending")
	# Clip-tier locomotion disables the body while its geometry still describes the pony.
	actor._collision.disabled = true
	await physics_frame; await physics_frame
	nav.house_travel.clear(actor)
	var ticks_before := nav.ticks
	var stopped := actor.global_position
	var toward_aisle := (departure - stopped).slide(Vector3.UP).normalized()
	actor.look_at(stopped - toward_aisle)
	nav.house_travel.native_walk(nav, destination, home, destination)
	check(nav.ticks == ticks_before and actor.facing_request.dot(toward_aisle) > .99,
			"a pony facing away turns toward the clear aisle before receiving a walking step")
	actor.look_at(stopped + actor.facing_request)
	nav.house_travel.native_walk(nav, destination, home, destination)
	check(nav.ticks == ticks_before + 1 and nav.path.size() == 2 and nav.path[1].distance_to(departure) < .05,
			"an ordinary indoor trip reaches the same aisle with body collision disabled")
	check(actor._collision.disabled and actor.global_position == stopped, "planning leaves clip-tier physics and position alone")

	# Block the already chosen leg between navigation ticks.
	var obstacle := StaticBody3D.new(); root.add_child(obstacle)
	var block := CollisionShape3D.new(); var box := BoxShape3D.new(); box.size = Vector3(.7,1,.7)
	block.shape = box; obstacle.add_child(block); obstacle.position = actor.global_position + Vector3.UP * .5
	await physics_frame; await physics_frame
	ticks_before = nav.ticks
	nav.house_travel.native_walk(nav, destination, home, destination)
	check(nav.state == nav.State.WAITING and nav.ticks == ticks_before, "a new solid obstruction stops the cached departure")
	nav.house_travel.clear(actor); nav._indoor_follow_cache.clear()
	check(not nav.commands.command_follow_goal(nav, goal, leader).is_finite(), "a disabled body still rejects a blocked follow slot")
	actor._collision.disabled = false
	await physics_frame; await physics_frame
	nav.house_travel.clear(actor); nav._indoor_follow_cache.clear()
	check(not nav.commands.command_follow_goal(nav, goal, leader).is_finite(), "actual controller obstruction keeps follow blocked")
	check(actor.global_position == stopped and body.radius == original_body_radius and actor.profile.radius == original_planning_radius, "queries do not move the actor or shrink physical/planning shapes")
	obstacle.free()
	actor.free(); frame.free(); source.free()
	print("LIBRARY_FOLLOW_DONE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
