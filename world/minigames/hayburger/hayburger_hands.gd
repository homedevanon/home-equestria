extends Node
## Both adapters carry the same kitchen objects and release into the same stations.
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const BENCH_SCRIPT := preload("res://world/minigames/hayburger/hayburger_workbench.gd")
var bench: Node3D
var inventory: Node
var restaurant: Node
var _pressed: Dictionary = {"left":true,"right":true}
var _claims: Dictionary = {}
var _desktop_pose_owned := false
var _desktop_helper_owned := false

func _ready() -> void:
	process_physics_priority = -60
	add_to_group("interaction_hint_sources")
	add_to_group("grab_providers")

func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not available() or bench.held.has(side): return {}
	var pose: Transform3D = sample.get("pose",Transform3D.IDENTITY)
	var point: Vector3 = sample.get("grip_position",pose.origin)
	var target: Node3D = bench.reachable(point)
	if target == null: return {}
	var action: String = bench.pickup_text(target)
	return {} if action.is_empty() else {"target":target,"text":side.capitalize()+" grip · "+action}

func grab_take(side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	return pick(side,offer.target)

func setup(host: Node, kitchen: Node3D, ui: Node) -> void:
	restaurant = host; bench = kitchen; inventory = ui

func available() -> bool:
	if not is_instance_valid(inventory) or not is_instance_valid(restaurant) or not is_instance_valid(inventory.camera): return false
	if get_tree().paused or inventory._map_open(): return false
	if inventory._desktop and not _desktop_ready(): return false
	if not restaurant.menus_available(): return false
	if is_instance_valid(inventory.case) and inventory.case.visible: return false
	if is_instance_valid(inventory.customizer) and inventory.customizer.opened: return false
	return restaurant.can_work()

func _desktop_ready() -> bool:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT_INPUT.mouse_banking(inventory.player_body): return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return false
	var owner: Variant = inventory.get_meta("desktop_activity_owner") if inventory.has_meta("desktop_activity_owner") else null
	return not is_instance_valid(owner) or owner == self

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(bench) or not is_instance_valid(inventory): return
	for side: String in _claims.keys():
		if not bench.held.has(side): _unclaim(side)
	if inventory._desktop:
		if bench.held.has("desktop"):
			if not available(): release("desktop",false)
			else: _move_desktop()
		return
	for side: String in ["left","right"]:
		var sample: Dictionary = inventory.hand_sample(side)
		var pose: Transform3D = sample.get("pose",sample.get("aim",Transform3D.IDENTITY))
		var active: bool = available() and sample.get("active",false) and (sample.has("pose") or sample.has("aim")) and pose.is_finite()
		var down: bool = active and float(sample.get("grip",0.0)) > (.25 if bench.held.has(side) or _pressed[side] else .45)
		if bench.held.has(side):
			if not active: release(side,false)
			else:
				_move(side,Transform3D(bench.global_basis.orthonormalized(),pose.origin))
				if not down: release(side)
		elif inventory.get("grab_router") == null and active and down and not _pressed[side] and not inventory.hand_busy(side):
			var target: Node3D = bench.reachable(pose.origin)
			if target != null: pick(side,target)
		_pressed[side] = down if active else true

func pick(side: String, target: Node3D) -> bool:
	if not available() or inventory.hand_busy(side): return false
	if not bench.take(side,target): return false
	if bench.held.has(side):
		var hand: Node = inventory.hands.get(side)
		if is_instance_valid(hand):
			hand.set_meta("kitchen_grip",self); hand.set_meta("inventory_busy",true)
		_claims[side] = true
		if side == "desktop": inventory.set_meta("desktop_activity_owner", self)
	inventory._haptic(side)
	if side == "desktop" and bench.held.has(side): _move_desktop()
	return true

func release(side: String, intentional: bool = true) -> bool:
	var accepted: bool = bench.release(side,intentional)
	_unclaim(side)
	return accepted

func _unclaim(side: String) -> void:
	_claims.erase(side)
	if not is_instance_valid(inventory): return
	if side == "desktop" and inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner") == self:
		_clear_desktop_pose()
		inventory.remove_meta("desktop_activity_owner")
	if side == "desktop":
		_desktop_pose_owned = false; _desktop_helper_owned = false
	var hand: Node = inventory.hands.get(side)
	if is_instance_valid(hand) and hand.has_meta("kitchen_grip") and hand.get_meta("kitchen_grip") == self:
		hand.remove_meta("kitchen_grip"); hand.remove_meta("inventory_busy")

func _move(side: String, pose: Transform3D) -> void:
	var item: Node3D = bench.held.get(side)
	if not is_instance_valid(item): return
	# Carrying cannot drag food through a wall. Offset from contact before release.
	var from: Vector3 = item.global_position + Vector3.UP*.04
	var to: Vector3 = pose.origin + Vector3.UP*.04
	if from.distance_squared_to(to) > .000001:
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from,to,1)
		query.exclude = _player_excludes()
		var hit: Dictionary = bench.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty(): pose.origin = hit.position + hit.normal*.045
	bench.move_held(side,pose)
	if side == "desktop": _present_desktop()

func _player_excludes() -> Array[RID]:
	var out: Array[RID] = []
	if inventory.player_body is CollisionObject3D: out.append(inventory.player_body.get_rid())
	return out

func _desktop_hit(mask: int, distance: float) -> Dictionary:
	var camera: Camera3D = inventory.camera
	if not is_instance_valid(camera): return {}
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(camera.global_position,camera.global_position-camera.global_basis.z*distance,mask)
	query.exclude = _player_excludes()
	return camera.get_world_3d().direct_space_state.intersect_ray(query)

## Where a desktop click puts the held food: the top surface under the crosshair. A short pony
## (eye 0.82 m, below the 1.03 m worktop) aims at the counter's front edge: the top just behind
## that edge counts, as reaching up onto it (M-INV-02, 2026-11-08: food "falling through").
func _desktop_destination() -> Dictionary:
	var hit: Dictionary = _desktop_hit(1, 1.65)
	if hit.is_empty(): return {}
	if Vector3(hit.normal).y < .75: hit = _top_behind_edge(hit)
	if hit.is_empty(): return {}
	var point: Vector3 = hit.position + hit.normal * .04
	return {"pose": Transform3D(bench.global_basis.orthonormalized(), point), "point": point, "collider": hit.collider, "over_edge": bool(hit.get("over_edge", false))}

## A steep face (the counter's front edge) hit by a view from below its top: the flat top
## behind it that the aim points at. The nearest work spot (build board, grill, serving mat,
## scraps bin) within EDGE_SIDE of the aim line and EDGE_DEPTH beyond the edge, else the top
## EDGE_REACH behind the edge. The top is found by a ray down from EDGE_RISE above, so nothing
## sits on it. {} when there is none.
const EDGE_REACH := .14
const EDGE_RISE := .45
const EDGE_SIDE := .3
const EDGE_DEPTH := 1.0
func _top_behind_edge(hit: Dictionary) -> Dictionary:
	var normal: Vector3 = hit.normal
	var flat := Vector3(normal.x, 0.0, normal.z)
	if flat.length_squared() < .01 or not is_instance_valid(inventory.camera): return {}
	var edge: Vector3 = hit.position
	if (inventory.camera as Camera3D).global_position.y > edge.y + .05: return {}
	var camera: Camera3D = inventory.camera
	var aim: Vector3 = -camera.global_basis.z; aim.y = 0.0
	if aim.length_squared() < .0001: return {}
	aim = aim.normalized()
	var spot: Vector3 = edge + aim * EDGE_REACH
	var gap := EDGE_SIDE
	for local: Vector3 in [BENCH_SCRIPT.PREP, BENCH_SCRIPT.GRILL, BENCH_SCRIPT.PASS, BENCH_SCRIPT.BIN]:
		var centre: Vector3 = bench.to_global(local)
		var along := (centre - edge).dot(aim)
		var side := absf((centre - edge).dot(Vector3(-aim.z, 0.0, aim.x)))
		if along > 0.0 and along < EDGE_DEPTH and side < gap: spot = Vector3(centre.x, edge.y, centre.z); gap = side
	var query := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * EDGE_RISE, spot - Vector3.UP * .6, 1)
	query.exclude = _player_excludes()
	var top: Dictionary = bench.get_world_3d().direct_space_state.intersect_ray(query)
	# The top must be the one over the face that was hit (the bin's floor is the exception: it is
	# a drop into an open box), never a surface far below a face seen higher up.
	if top.is_empty(): return {}
	var y: float = Vector3(top.position).y
	if Vector3(top.normal).y < .75 or y > edge.y + EDGE_RISE or (y < edge.y - .05 and gap >= EDGE_SIDE): return {}
	top["over_edge"] = true
	return top

func _move_desktop() -> void:
	var scale := 1.0
	var visual: Node = inventory.get("desktop_presentation") as Node
	if is_instance_valid(visual) and is_instance_valid(visual.get("avatar")):
		scale = float(visual.avatar.model_scale)
	var camera: Camera3D = inventory.camera
	var at: Vector3 = camera.global_transform.orthonormalized() * (Vector3(.14, -.18, -.60) * scale)
	_move("desktop", Transform3D(bench.global_basis.orthonormalized(), at))

func _desktop_place_clear(destination: Dictionary) -> bool:
	if destination.is_empty(): return false
	var item: Node3D = bench.held.get("desktop")
	if not is_instance_valid(item): return false
	var space := bench.get_world_3d().direct_space_state
	# Over a worktop edge (a short pony): the crosshair's own ray reached the edge, so the way is
	# the reach up and over it; only the drop onto the top must be free.
	var from: Vector3 = Vector3(destination.point) + Vector3.UP * EDGE_RISE if bool(destination.get("over_edge", false)) else item.global_position + Vector3.UP * .04
	var query := PhysicsRayQueryParameters3D.create(from, Vector3(destination.point) + Vector3.UP * .04, 1)
	query.exclude = _player_excludes()
	return space.intersect_ray(query).is_empty()

func _place_desktop() -> bool:
	var destination: Dictionary = _desktop_destination()
	if not _desktop_place_clear(destination): return false
	# Already checked clear: set it down there (the carry ray would stop a reach over an edge).
	bench.move_held("desktop", destination.pose)
	_present_desktop()
	var item: Node3D = bench.held.get("desktop")
	return is_instance_valid(item) and item.global_position.distance_to(destination.point) < .02

func _present_desktop() -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	var item: Node3D = bench.held.get("desktop")
	if not is_instance_valid(visual) or not is_instance_valid(item): return
	if not inventory.has_meta("desktop_activity_owner") or inventory.get_meta("desktop_activity_owner") != self: return
	var helper: bool = item.get_meta("kitchen_role", "") == "burger"
	var frame := Transform3D(inventory.camera.global_basis.orthonormalized(), item.global_position)
	var across: Vector3 = frame.basis.x
	var palm_offset: Vector3 = frame.basis.z * .08 - frame.basis.y * .07
	frame.origin += palm_offset + across * (.13 if helper else 0.0)
	visual.set_hold_target("right", frame, "hold"); _desktop_pose_owned = true
	if helper:
		frame.origin = item.global_position + palm_offset - across * .13
		visual.set_hold_target("left", frame, "hold"); _desktop_helper_owned = true
	elif _desktop_helper_owned:
		visual.clear_hold_target("left"); _desktop_helper_owned = false

func _clear_desktop_pose() -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	if not is_instance_valid(visual): return
	if _desktop_pose_owned: visual.clear_hold_target("right")
	if _desktop_helper_owned: visual.clear_hold_target("left")

func _desktop_offer() -> Dictionary:
	if not available() or inventory.hand_busy("desktop"): return {}
	return desktop_pick()

## The kitchen object under the crosshair (no input gates; tests call it). The first collider, or
## for a short pony whose view meets the counter's edge just under it, the kitchen object sitting
## on the top just behind that edge (M-INV-02, 2026-11-08: food "not clickable" on desktop).
func desktop_pick() -> Dictionary:
	var hit: Dictionary = _desktop_hit(3, 1.8)
	if hit.is_empty(): return {}
	var target: Node = hit.collider as Node
	if target == null or target.get_parent() != bench or not target.has_meta("kitchen_role"):
		target = _behind_edge(hit)
		if target == null: return {}
	var action: String = bench.pickup_text(target)
	return {} if action.is_empty() else {"target": target, "point": hit.position, "text": "[LMB/E] " + action, "visible_pick": true}

## The kitchen object on the top behind a counter edge the view meets from below: nearest to the
## aim line (within EDGE_SIDE), at most EDGE_DEPTH beyond the edge, resting no lower than the edge.
func _behind_edge(hit: Dictionary) -> Node3D:
	var normal: Vector3 = hit.normal
	if Vector3(normal.x, 0.0, normal.z).length_squared() < .01 or not is_instance_valid(inventory.camera): return null
	var edge: Vector3 = hit.position
	if (inventory.camera as Camera3D).global_position.y > edge.y + .05: return null
	var camera: Camera3D = inventory.camera
	var aim: Vector3 = -camera.global_basis.z; aim.y = 0.0
	if aim.length_squared() < .0001: return null
	aim = aim.normalized()
	var best: Node3D = null
	var gap := EDGE_SIDE * .7
	for child: Node in bench.get_children():
		if not child is PhysicsBody3D or not child.has_meta("kitchen_role") or child in bench.held.values() or child.is_queued_for_deletion(): continue
		var at: Vector3 = (child as Node3D).global_position
		var along := (at - edge).dot(aim)
		var side := absf((at - edge).dot(Vector3(-aim.z, 0.0, aim.x)))
		if along > 0.0 and along < EDGE_DEPTH and at.y > edge.y - .05 and at.y < edge.y + EDGE_RISE and side < gap: best = child; gap = side
	return best

func _input(event: InputEvent) -> void:
	if event is InputEventKey and preload("res://world/ui/typing_guard.gd").active(): return  # typing never drives the game
	if not is_instance_valid(inventory) or not inventory._desktop or not available(): return
	if bench.held.has("desktop"):
		var place: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
		var drop: bool = event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_Q
		if place or drop or (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E):
			var intentional: bool = not drop and _place_desktop()
			if not intentional: _move_desktop()
			release("desktop", intentional); get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.physical_keycode in [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_G]:
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		var offer: Dictionary = _desktop_offer()
		if not offer.is_empty() and pick("desktop", offer.target): get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(inventory) or not inventory._desktop or not available(): return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var offer: Dictionary = _desktop_offer()
		if not offer.is_empty() and pick("desktop", offer.target): get_viewport().set_input_as_handled()

func cancel_desktop_activity() -> void:
	if is_instance_valid(bench) and bench.held.has("desktop"): release("desktop", false)
	else: _unclaim("desktop")

func presentation() -> Dictionary:
	var item: Node3D = bench.held.get("desktop") if is_instance_valid(bench) else null
	if not is_instance_valid(item): return {}
	return {"action": "hold", "held": item, "target": item, "point": item.global_position,
		"normal": Vector3.UP, "helper": item.get_meta("kitchen_role", "") == "burger", "progress": 0.0}

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(inventory) and inventory._desktop:
		cancel_desktop_activity()

func _exit_tree() -> void:
	if is_instance_valid(bench):
		for side: String in bench.held.keys(): release(side,false)
	for side: String in _claims.keys(): _unclaim(side)

## Read-only; the same reach checks and availability gates used by actual input.
func interaction_hint() -> Dictionary:
	if not available(): return {}
	if inventory._desktop:
		if bench.held.has("desktop"):
			var destination: Dictionary = _desktop_destination()
			var hint: Dictionary = bench.release_hint("desktop", destination.point) if _desktop_place_clear(destination) else {"target": bench.held.desktop, "text": "Drop"}
			if not hint.is_empty(): hint.text = "[LMB/E] " + hint.text + "   [Q] Drop"
			return hint
		return _desktop_offer()
	for side: String in ["right","left"]:
		var sample: Dictionary = inventory.hand_sample(side)
		if not sample.get("active",false): continue
		if bench.held.has(side):
			var hint: Dictionary = bench.release_hint(side)
			if not hint.is_empty(): hint.text = "Release " + side + " grip · " + hint.text
			return hint
		if inventory.hand_busy(side): continue
		if inventory.get("grab_router") != null: continue
		var pose: Transform3D = sample.get("pose",sample.get("aim",Transform3D.IDENTITY))
		var target: Node3D = bench.reachable(pose.origin)
		if target == null: continue
		var action: String = bench.pickup_text(target)
		if not action.is_empty(): return {"target":target,"text":side.capitalize() + " grip · " + action}
	return {}
