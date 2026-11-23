extends SceneTree
## Drive the production action executor with controlled navigator certificates.
## Exercise both travel directions using transformed, furnished home entrances.
class FakeProfile extends RefCounted:
	var walk_speed := Vector2(.4, .8)
	var max_travel_speed := 4.5
	var braking := 3.5
class FakeActor extends Node3D:
	var profile := FakeProfile.new()
	var pose := {"kind":"stand", "requested":"stand", "settled":true, "refusal":""}
	var stand_requests := 0
	func posture_status() -> Dictionary: return pose
	func request_posture(value: String) -> bool:
		stand_requests += 1; pose.requested = value; return true
	func action_interruption_reason() -> String: return ""
class FakeNavigator extends Node:
	signal arrived
	signal route_failed(reason: String)
	var command_owner := "fixture"
	var command_speed_limit := INF
	var command_target_speed := 0.0
	var command_target_velocity := Vector3.ZERO
	var command_pace_target := -1.0
	var follow_gain := 1.0
	var wander_enabled := false
	var reserved_by := ""
	var destinations: Array[Vector3] = []
	var stops := 0
	var side_queries := 0
	var footprint_queries := 0
	var use_world_floor := false
	func _indoor_follow_support(_home: Node3D, at: Vector3, _floor: float) -> Vector3:
		footprint_queries += 1
		return at
	func stay() -> void: stops += 1
	func command_target_floor(at: Vector3) -> Vector3:
		return at if use_world_floor else Vector3(at.x, 0, at.z)
	func command_target_visible(_target: Node3D) -> bool: return true
	func command_support(at: Vector3) -> Vector3: return at
	func command_follow_goal(goal: Vector3, _leader: Vector3) -> Vector3:
		side_queries += 1
		return goal
	func command_destination(goal: Vector3, _pace: String, _refresh: bool) -> bool:
		destinations.append(goal)
		if not goal.is_finite():
			route_failed.emit("Destination is not finite")
			return false
		return true

var checks := 0
var failures := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	print("DOORWAY_FOLLOW ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func run() -> void:
	for scene: String in ["res://world/buildings/fluttershy/cottage.tscn", "res://world/towns/ponyville/sugarcube.scn"]:
		await test_entrance(load(scene).instantiate(), scene.contains("sugarcube"))
	print("DOORWAY_FOLLOW_DONE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

## Exercise the production executor with the release building's own transformed
## entrance. Positions are stepped explicitly; collider and motor behavior are
## covered separately by the exported placement and house-travel checks.
func test_entrance(site: Node3D, bakery: bool) -> void:
	if bakery: site.scale = Vector3.ONE * 14
	site.position = Vector3(151, -19.863147, -10)
	site.rotation.y = -1.51204
	root.add_child(site)
	# Buildings finish entrance setup on deferred calls. Step the live tree before
	# traversing or replacing its set of house interiors.
	await process_frame
	await physics_frame
	var home: Node3D = site.find_child("HouseInterior", true, false)
	if home == null:
		check(false, "real building exposes its entrance")
		site.free()
		return
	var inside: Vector3 = home.inside()
	var outside: Vector3 = home.outside()
	var axis := outside - inside
	axis.y = 0
	axis = axis.normalized()
	var context := "bakery entry" if bakery else "cottage exit"
	var approach := outside if bakery else inside
	var far_side := inside if bakery else outside
	if bakery: axis = -axis
	var actor := FakeActor.new()
	root.add_child(actor)
	actor.global_position = approach - axis * 4.5
	var target := Node3D.new()
	root.add_child(target)
	var nav := FakeNavigator.new()
	nav.name = "Navigator"
	actor.add_child(nav)
	nav.use_world_floor = true
	var ex: Node = load("res://world/ai/pony_action_executor.gd").new()
	root.add_child(ex)
	ex.bind(actor)
	ex.submit([{"id":"entrance","type":"follow","target_id":"player","distance_m":1.5,"formation":"right"}], {"player":target}, 1, true)
	for distance: float in [4.0, 3.1, 2.2, 1.3, .4]:
		target.global_position = approach - axis * distance
		ex._physics_step(.21)
	check(ex._doorway_follow.home == home, context + " uses shared single-file follow on approach")
	check(nav.side_queries == 1, context + " stops the ordinary side-slot probes after approach begins")
	var held: Vector3 = ex._last_goal
	check(held.is_finite() and (approach - held).dot(axis) > 1.5, context + " targets a previously passed floor position behind the leader")
	var queries := nav.footprint_queries
	target.global_position -= axis * .65
	ex._physics_step(.21)
	check(ex._last_goal == held and nav.footprint_queries == queries, context + " backs up with the handle without changing target")
	target.global_position = approach - axis * 2.8
	ex._physics_step(.21)
	check(ex._doorway_follow.home == null and nav.side_queries > 1, context + " turning away restores ordinary following")
	for distance: float in [2.0, 1.1, .2]:
		target.global_position = approach - axis * distance
		ex._physics_step(.21)
	var steps := ceili(approach.distance_to(far_side))
	for i in range(1, steps + 1):
		target.global_position = approach.lerp(far_side, float(i) / steps)
		ex._physics_step(.21)
	for distance: float in [.9, 1.8, 2.7, 3.6]:
		target.global_position = far_side + axis * distance
		ex._physics_step(.21)
	check(ex._doorway_follow.home == home, context + " keeps a trailing destination while the pony has yet to cross")
	check(ex._last_goal.is_finite() and (ex._last_goal - far_side).dot(axis) > .1, context + " submits a destination beyond the passage")
	actor.global_position = far_side + axis * 1.5
	ex._physics_step(.21)
	check(ex._doorway_follow.home == null, context + " resumes formation when the pony clears the passage even if the leader stops")
	# Acquiring follow again at the same door must not inherit old footsteps.
	ex.submit([{"id":"stop","type":"stay","duration_s":30.0}], {"player":target}, 2, true)
	check(ex._doorway_follow._trail.is_empty(), context + " stay discards route history")
	ex.free()
	actor.free()
	target.free()
	if not bakery: test_recorded_footsteps(home)
	site.free()

class StandingPony extends CharacterBody3D:
	var profile: Resource
class FootprintNavigator extends Node:
	var pony: StandingPony
	var probes: Array[Vector3] = []
	var commands: Script
	func _indoor_follow_support(home: Node3D, at: Vector3, floor_y: float) -> Vector3:
		probes.append(at)
		return commands.indoor_follow_support(self, home, at, floor_y)

func test_recorded_footsteps(home: Node3D) -> void:
	var pony := StandingPony.new()
	pony.profile = load("res://world/characters/locomotion/pony_gait_profile.gd").new()
	root.add_child(pony)
	pony.global_position = Vector3(145.43, -19.0, -7.64)
	var nav := FootprintNavigator.new()
	nav.commands = load("res://world/characters/navigation/navigator_commands.gd")
	nav.pony = pony
	pony.add_child(nav)
	var formation: RefCounted = load("res://world/characters/navigation/doorway_follow.gd").new()
	# A path across the furnished cottage, including a footstep too close to furniture.
	var issued := Vector3.INF
	var safe := Vector3.INF
	var leader := Vector3.INF
	for xz: Vector2 in [Vector2(149.53,-9.87), Vector2(150.22,-10.62), Vector2(151.18,-11.50), Vector2(154.42,-12.0)]:
		leader = nav.commands.command_target_floor(nav, Vector3(xz.x, -17.74, xz.y))
		if formation.update(self, leader, pony.global_position):
			safe = issued
			issued = formation.goal(nav, leader, pony.global_position, 1.5)
	check(safe.is_finite() and home.contains(safe), "real recorded trail admits a pony-sized standing spot")
	check(issued == safe and nav.probes.size() == 2, "narrow recorded footstep retains the last supported spot after one probe")
	var blocked: Vector3 = nav.probes.back()
	issued = formation.goal(nav, leader, pony.global_position, 1.5)
	check(issued.is_finite() and nav.probes.count(blocked) == 1, "next decision skips the blocked footprint")
	formation.route_failed()
	check(not formation._supported.is_finite(), "an obstructed route invalidates its cached footprint")
	check(not formation.update(self, leader + Vector3(20,0,0), pony.global_position) and formation._trail.size() == 1, "teleport starts a new trail")
	pony.free()
