extends "res://world/life/couch.gd"
## A temporary physical rest at the player's current supported ground position.
## No furniture, collision replacement, saved occupancy or automatic relationship acceptance.
const SEAT := preload("res://world/life/seat.gd")
const WATER := preload("res://world/water/water_contact.gd")
const GROUND_OWNER := "leisure:grass:"
var player: Node3D
var _ending := false
var _elapsed := 0.0
var temporary := true
var rest_label := "grass"
var seat_offsets: Array[Vector3] = [Vector3.ZERO, Vector3(.60, 0, 0)]

## Open ground has no cushion ends: a mare of any size setting lies here (couch.gd fits() measures
## sofas); her hop and lie-down still check the room around her.
func fits(_actor: Node3D) -> bool:
	return true

## Physical blanket adapter: caller validates and owns support and placement. It supplies
## world frame and two edge seats; food/blanket save ownership stays with the caller.
static func create_surface(parent: Node, world_frame: Transform3D, offsets: Array[Vector3]) -> Node3D:
	if offsets.size() != 2 or not world_frame.is_finite(): return null
	var surface := load("res://world/relationships/shared_nap_grass.gd").new() as Node3D
	surface.name = "SharedGroundRest"; surface.temporary = false; surface.seat_offsets.assign(offsets)
	parent.add_child(surface); surface.global_transform = world_frame; surface.layout()
	return surface

static func supported_ground(body: Node3D, eye: Camera3D) -> Dictionary:
	if not is_instance_valid(body) or not is_instance_valid(eye): return {}
	var at := Vector3(eye.global_position.x, body.global_position.y, eye.global_position.z)
	var excludes: Array[RID] = []
	if body is CollisionObject3D: excludes.append(body.get_rid())
	var form: Variant = body.get("form_driver")
	if is_instance_valid(form) and is_instance_valid(form.get("avatar")) and form.avatar is CollisionObject3D: excludes.append(form.avatar.get_rid())
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .35, at - Vector3.UP * .7, 1, excludes)
	var hit := body.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.y < .9: return {}
	var collider := hit.collider as Node
	if collider == null: return {}
	var natural: bool = collider is Terrain3D or "terrain" in collider.name.to_lower() or collider.get_meta("nap_ground", false)
	if not natural: return {}
	if is_finite(WATER.surface_above(body.get_world_3d().direct_space_state, hit.position + Vector3.UP * .01)): return {}
	var forward := -eye.global_basis.z; forward.y = 0.0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	var facing := Basis.looking_at(forward.normalized(), Vector3.UP)
	# Both bodies require clear floor on the same shallow slope.
	for offset: Vector3 in [Vector3(.65, 0, 0), Vector3(-.65, 0, 0), Vector3(0, 0, .75)]:
		var rotated: Vector3 = facing * offset
		var sample := PhysicsRayQueryParameters3D.create(hit.position + rotated + Vector3.UP * .3, hit.position + rotated - Vector3.UP * .3, 1, excludes)
		var floor_hit := body.get_world_3d().direct_space_state.intersect_ray(sample)
		if floor_hit.is_empty() or floor_hit.normal.y < .9 or absf(floor_hit.position.y - hit.position.y) > .12: return {}
		if is_finite(WATER.surface_above(body.get_world_3d().direct_space_state, floor_hit.position + Vector3.UP * .01)): return {}
	var clearance := BoxShape3D.new(); clearance.size = Vector3(1.55, .85, 1.65)
	var overlap := PhysicsShapeQueryParameters3D.new(); overlap.shape = clearance; overlap.collision_mask = 1 | 2 | 2048
	overlap.exclude = excludes; overlap.transform = Transform3D(facing, hit.position + facing * Vector3(.25, .58, .1))
	if not body.get_world_3d().direct_space_state.intersect_shape(overlap, 1).is_empty(): return {}
	return hit

static func toggle(body: Node3D, eye: Camera3D) -> bool:
	if not is_instance_valid(body) or body.get("controls_locked") == true or body.get("flying") == true: return false
	var swimming: Variant = body.get("swimming")
	if swimming != null and swimming.get("active") == true: return false
	var current: Variant = body.get_meta("shared_nap_surface") if body.has_meta("shared_nap_surface") else null
	if is_instance_valid(current): body.stand_up(); return true
	if is_instance_valid(body.get("seat")): return false
	var hit := supported_ground(body, eye)
	if hit.is_empty(): return false
	var node := load("res://world/relationships/shared_nap_grass.gd").new() as Node3D
	node.name = "GrassNap"; node.player = body
	var root: Node = body.get_tree().current_scene
	if root == null: root = body.get_tree().root
	root.add_child(node)
	var forward := -eye.global_basis.z; forward.y = 0.0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	node.global_transform = Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), Vector3(hit.position.x, hit.position.y + .015, hit.position.z))
	node.layout()
	if not body.sit_on(node.seats[0]): node.queue_free(); return false
	body.set_meta("shared_nap_surface", node)
	if not body.toggle_couch_sleep(): body.stand_up(); node.queue_free(); return false
	return true

func _ready() -> void:
	add_to_group("couches")
	process_physics_priority = -20
	autonomous = true; opened = true; extension = 1.0

func layout() -> void:
	for i in 2:
		var seat := SEAT.new(); seat.name = "GroundRest%d" % i; seat.depth = .1
		seat.for_player = i == 0 or not temporary; seat.for_ponies = i == 1 or not temporary
		add_child(seat); seat.position = seat_offsets[i]
		seat.set_meta("couch", self); seats.append(seat)
	if not temporary: rest_label = "blanket"

func head_side(_seat: Node3D) -> float: return 1.0
func rest_word() -> String: return rest_label
func rest_frame(_seat: Node3D) -> Node3D: return self
func sleep_eye(_seat: Node3D) -> Vector3: return to_global(Vector3(0, .28, -.28))
func rest_floor(_seat: Node3D) -> float: return global_position.y + .12
func rest_contains(_seat: Node3D, head: Vector3) -> bool:
	var local := to_local(head)
	return Vector2(local.x, local.z).length() < 1.15
func shift_contains(_seat: Node3D, _head: Vector3) -> bool: return false
func touch_zone(point: Vector3) -> bool:
	var local := to_local(point)
	return absf(local.x) < .8 and absf(local.z) < .8 and absf(local.y) < .25
func approach(seat: Node3D) -> Vector3: return seat.global_position + global_basis.z * .3
func pony_transform(seat: Node3D, actor: Node3D = null) -> Transform3D:
	var at := seat.global_position + Vector3.UP * .01
	if temporary and actor != null:
		var mode := NAP_COMPANY.closeness(actor)
		if mode == "shoulder": at = to_global(Vector3(.18, .01, -.22))
		elif mode == "snuggle": at = to_global(Vector3(.18, .01, -.20))
	return Transform3D(global_basis.orthonormalized(), at)
func hop_clear(actor: CharacterBody3D, from: Vector3, to: Vector3) -> bool:
	# Ground arrival uses the same small Seating boarding arc, guarded against world obstacles.
	var shape := CapsuleShape3D.new(); shape.radius = actor.profile.radius
	shape.height = maxf(actor.profile.clearance, shape.radius * 2.0)
	for i in range(1, 9):
		var t := float(i) / 8.0
		var query := PhysicsShapeQueryParameters3D.new(); query.shape = shape; query.collision_mask = 1
		query.exclude = [actor.get_rid()]
		query.transform = Transform3D(Basis.IDENTITY, from.lerp(to, t) + Vector3.UP * (shape.height * .5 + .04 + sin(PI * t) * .3 * actor.body_scale))
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	return true
func pony_rest_closeness(actor: Node3D) -> String: return NAP_COMPANY.closeness(actor)
func invite(actor: Node3D, seat: Node3D) -> bool:
	if NAP_COMPANY.closeness(actor) == "none": return false
	return super.invite(actor, seat)
func _physics_process(delta: float) -> void:
	_elapsed += delta
	if not temporary:
		player = null
		for seat: Node3D in seats:
			var occupant: Variant = seat.get_meta("occupant") if seat.has_meta("occupant") else null
			if is_instance_valid(occupant) and occupant.get("controls_locked") != null: player = occupant
		super._physics_process(delta)
		return
	if not is_instance_valid(player) or (player.get("seat") != seats[0] and _elapsed > .2):
		_ending = true
	if _ending:
		for id in _ponies.keys(): _release_pony(id, true)
		queue_free(); return
	super._physics_process(delta)
func _exit_tree() -> void:
	if is_instance_valid(player) and player.has_meta("shared_nap_surface") and player.get_meta("shared_nap_surface") == self: player.remove_meta("shared_nap_surface")
	super._exit_tree()
	for seat: Node3D in seats:
		if is_instance_valid(seat): seat.queue_free()
