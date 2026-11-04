extends Node
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
## Trunk-only physical fist adapter. Desktop animates a visible fist into the
## actual first ray contact; VR uses tracked closed fists and tracking-space speed.
const INTENT := preload("res://world/minigames/apple_bucking/punch_intent.gd")
var activity: Node3D
var intent: RefCounted = INTENT.new()
var _previous: Dictionary = {}
var _punch_time: float = -1.0
var _punch_id: String = ""
var _punch_end: Vector3 = Vector3.ZERO
var _punch_camera: Transform3D = Transform3D.IDENTITY
var _hit_done: bool = false
var _presentation: Node
var _contact_pending := false
const DESKTOP_REACH := 1.05

func setup(owner_activity: Node3D) -> void:
	activity = owner_activity
	process_physics_priority = -50
	add_to_group("interaction_hint_sources")

## Only a ripe, reachable trunk; never advances punch intent or starts an action.
func interaction_hint() -> Dictionary:
	var ui: Node = inventory()
	if ui == null or not is_instance_valid(activity.orchard): return {}
	if ui.get("_desktop") == true:
		if not available("desktop") or _punch_time >= 0.0 or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return {}
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit: return {}
		var camera: Camera3D = ui.get("camera") as Camera3D
		if camera == null: return {}
		var presentation: Node = _desktop_presentation()
		if not is_instance_valid(presentation) or presentation.is_busy(): return {}
		return _trunk_hint(_ray(camera.global_position, camera.global_position-camera.global_basis.z*_desktop_reach()), "[LMB] Punch trunk · Shake ripe apples", true)
	for hand_side: String in ["right", "left"]:
		if not available(hand_side): continue
		var sample: Dictionary = ui.hand_sample(hand_side)
		var pose: Transform3D = sample.get("aim", sample.get("pose", Transform3D.IDENTITY))
		if not sample.get("active", false) or not (sample.has("aim") or sample.has("pose")) or not pose.is_finite(): continue
		for tree: Dictionary in activity.nearby_trees(pose.origin):
			var centre: Vector3 = tree.position
			var height: float = pose.origin.y-centre.y
			if height < .25 or height > float(tree.height): continue
			centre.y = pose.origin.y
			var reach: float = float(tree.radius)+INTENT.CONTACT+INTENT.WITHDRAWAL
			if pose.origin.distance_to(centre) > reach: continue
			var hit: Dictionary = _ray(pose.origin, centre)
			var hint: Dictionary = _trunk_hint(hit, hand_side.capitalize()+" grip + trigger, punch trunk · Buck ripe apples", true)
			if not hint.is_empty(): return hint
	return {}

## `explain`: a trunk that cannot be bucked says why (a player punched a bare tree at dusk and
## nothing happened, thread report 2026-10-31); without it only a buckable trunk counts.
func _trunk_hint(hit: Dictionary, text: String, explain := false) -> Dictionary:
	var id: String = activity.orchard.tree_from_hit(hit)
	if id.is_empty() or not activity.trees.has(id): return {}
	var tree: Dictionary = activity.trees[id]
	if activity.player_position().distance_to(tree.position) > 3.2: return {}
	var blocked: bool = not activity.can_strike(id)
	if blocked:
		if not explain: return {}
		text = str(activity.strike_block_reason(id))
		if text.is_empty(): return {}
	var collider: CollisionObject3D = hit.get("collider") as CollisionObject3D
	if collider == null or not hit.has("shape"): return {}
	# All trunks share a body. Outline only the shape actually hit, not the
	# body containing every tree and not the canopy MultiMesh.
	var target: Node3D = collider.shape_owner_get_owner(collider.shape_find_owner(int(hit.shape))) as Node3D
	if not is_instance_valid(target): return {}
	if blocked: return {"target":target, "text":text, "point":hit.position, "collider":collider, "outline":null}
	return {"target":target, "text":text, "point":hit.position, "collider":collider}

func inventory() -> Node:
	return activity.host.get("inventory") as Node if is_instance_valid(activity) and is_instance_valid(activity.host) else null

func available(side: String) -> bool:
	var ui: Node = inventory()
	if ui == null or not activity.player_near_orchard(8.0): return false
	var body: Node = ui.get("player_body") as Node
	if is_instance_valid(body) and body.get("controls_locked") == true: return false
	if ui.hand_busy(side): return false
	for key: String in ["save_menu", "settings_menu", "pause_menu"]:
		var menu: Node = activity.host.get(key) as Node
		if is_instance_valid(menu) and menu.get("opened") == true: return false
	if ui.has_method("_map_open") and ui._map_open(): return false
	var case_node: Node3D = ui.get("case") as Node3D
	if is_instance_valid(case_node) and case_node.visible: return false
	for key: String in ["customizer", "inspector"]:
		var panel: Node = ui.get(key) as Node
		if is_instance_valid(panel) and panel.get("opened") == true: return false
	var camera: Camera3D = ui.get("camera") as Camera3D
	if is_instance_valid(camera):
		for child: Node in camera.get_children():
			if child.get_script() == preload("res://player/interactor.gd") and is_instance_valid(child.get("held")): return false
	var hand: Node = ui.hands.get(side)
	if is_instance_valid(hand) and (hand.get_meta("pony_inspection", false) or hand.has_meta("door_grip") or hand.has_meta("kitchen_grip")): return false
	return true

func _physics_process(delta: float) -> void:
	var ui: Node = inventory()
	if ui == null: return
	if ui.get("_desktop") == true:
		_animate_desktop(delta)
		return
	for side: String in ["left", "right"]:
		var sample: Dictionary = ui.hand_sample(side)
		var reference: Transform3D = Transform3D.IDENTITY
		var controller: Node3D = ui.controllers.get(side) as Node3D
		if is_instance_valid(controller) and controller.get_parent() is Node3D:
			reference = (controller.get_parent() as Node3D).global_transform
		advance_vr(side, sample, reference, delta)

func advance_vr(side: String, sample: Dictionary, reference: Transform3D, delta: float) -> bool:
	var pose: Transform3D = sample.get("aim", sample.get("pose", Transform3D.IDENTITY))
	var active: bool = sample.get("active", false) and (sample.has("aim") or sample.has("pose")) and available(side)
	var closed: bool = float(sample.get("grip", 0.0)) >= .65 and float(sample.get("trigger", 0.0)) >= .65
	if not active or not pose.is_finite():
		intent.reset(side); _previous.erase(side); return false
	var from: Vector3 = _previous.get(side, pose.origin)
	_previous[side] = pose.origin
	var id: String = intent.sample(side, pose.origin, reference, closed, active, delta, activity.nearby_trees(pose.origin))
	if id.is_empty(): return false
	var motion: Vector3 = pose.origin - from
	if motion.length_squared() < .000001: return false
	# Include the fist's contact radius, but let the nearest real wall/body win.
	var hit: Dictionary = _ray(from, pose.origin + motion.normalized() * .10)
	if activity.orchard.tree_from_hit(hit) != id: return false
	var accepted: bool = activity.strike(id, 1.0)
	if accepted: inventory()._haptic(side)
	return accepted

func _unhandled_input(event: InputEvent) -> void:
	var ui: Node = inventory()
	if ui == null or ui.get("_desktop") != true or not available("desktop"): return
	if FLIGHT_INPUT.reserves_mouse(event,ui.player_body): return
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT or not event.pressed: return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or _punch_time >= 0.0: return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	if start_desktop(): get_viewport().set_input_as_handled()

func start_desktop() -> bool:
	if not available("desktop") or _punch_time >= 0.0: return false
	var ui: Node = inventory()
	var camera: Camera3D = ui.get("camera") as Camera3D
	if camera == null: return false
	var presentation: Node = _desktop_presentation()
	if not is_instance_valid(presentation) or presentation.is_busy(): return false
	var hit: Dictionary = _ray(camera.global_position, camera.global_position - camera.global_basis.z * _desktop_reach())
	var id: String = activity.orchard.tree_from_hit(hit) if activity.orchard != null else ""
	if id.is_empty() or _trunk_hint(hit, "").is_empty(): return false
	_punch_id = id; _punch_camera = camera.global_transform
	_punch_end = hit.position
	if not presentation.request_action("punch", _punch_end, hit.normal, "right"):
		_punch_id = ""
		return false
	_punch_time = 0.0; _hit_done = false; _contact_pending = false
	return true

func _animate_desktop(delta: float) -> void:
	if _punch_time < 0: return
	if not available("desktop") or not is_instance_valid(_presentation):
		_cancel_desktop(); return
	var camera: Camera3D = inventory().get("camera") as Camera3D
	if camera == null or camera.global_position.distance_to(_punch_camera.origin) > .2:
		_cancel_desktop(); return
	_punch_time += delta
	if _contact_pending and not _hit_done:
		_contact_pending = false
		_hit_done = true
		# Contact is driven by the real rig animation. Recheck its actual palm
		# after IK updated, and let the nearest wall/body win over the trunk.
		var hand: Dictionary = _presentation.avatar.interaction_hand("right")
		var from: Vector3 = hand.get("palm_center", _presentation.hand_frame("right").origin)
		if from.distance_to(_punch_end) <= .18:
			var hit: Dictionary = _ray(from, _punch_end + (_punch_end - from).normalized() * .10)
			if activity.orchard.tree_from_hit(hit) == _punch_id: activity.strike(_punch_id, 1.0)
	if not _presentation.is_busy():
		_punch_time = -1.0; _punch_id = ""

func _desktop_presentation() -> Node:
	var ui: Node = inventory()
	var presentation: Node = ui.get("desktop_presentation") as Node if ui != null else null
	if presentation != _presentation:
		if is_instance_valid(_presentation) and _presentation.action_contact.is_connected(_on_action_contact):
			_presentation.action_contact.disconnect(_on_action_contact)
		_presentation = presentation
		if is_instance_valid(_presentation): _presentation.action_contact.connect(_on_action_contact)
	return _presentation

func _desktop_reach() -> float:
	return DESKTOP_REACH * float(_presentation.avatar.model_scale) if is_instance_valid(_presentation) and is_instance_valid(_presentation.avatar) else DESKTOP_REACH

func _on_action_contact(kind: String, _target: Vector3, _side: String) -> void:
	if kind == "punch" and _punch_time >= 0.0: _contact_pending = true

func _cancel_desktop() -> void:
	var owned_punch := _punch_time >= 0.0
	_punch_time = -1.0; _punch_id = ""
	_contact_pending = false
	if owned_punch and is_instance_valid(_presentation) and _presentation.is_busy(): _presentation.cancel_action()

func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, 1 | 2)
	var ui: Node = inventory()
	var body: CollisionObject3D = ui.get("player_body") as CollisionObject3D if ui != null else null
	if body != null: query.exclude = [body.get_rid()]
	return activity.get_world_3d().direct_space_state.intersect_ray(query)

func _exit_tree() -> void:
	_cancel_desktop()
