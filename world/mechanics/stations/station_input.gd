extends RefCounted
## One desktop/VR input and hint adapter for every physical station (P3 of
## docs/MECHANICS_ARCHITECTURE_2026_11_01.md, 6.3), mirroring world/cooking/cooking_input.gd and
## wired at the same points (briefcase click chain, VR grip, interaction_hints.gd).
## Station nodes join group "mechanics_station_nodes" and implement:
##   func station_hint(ui: Node, side: String) -> Dictionary   # {target, point, text, outline} or {}
##   func station_use(ui: Node, side: String, down: bool) -> bool  # true when it handled the press
## A node that handled a press (down) also gets that side's release (down = false), so a held
## action (desktop hold-click, VR grip on a crank) knows when it ends.
const COOKING := preload("res://world/cooking/cooking_input.gd")
const GROUP := "mechanics_station_nodes"
const REACH := 3.0
## side -> the node that took the press on that side.
static var _engaged: Dictionary = {}

## The nearest station node within REACH of the view (desktop) or the hand (VR), nearest first.
static func _nodes(ui: Node, side: String) -> Array[Node3D]:
	var found: Array[Node3D] = []
	var tree: SceneTree = ui.get_tree() if is_instance_valid(ui) and ui.is_inside_tree() else null
	if tree == null or not tree.has_group(GROUP): return found
	var from := _origin(ui, side)
	if not from.is_finite(): return found
	var near: Array = []
	for node: Node in tree.get_nodes_in_group(GROUP):
		if not node is Node3D or not (node as Node3D).is_visible_in_tree(): continue
		var gap := (node as Node3D).global_position.distance_to(from)
		if gap <= REACH: near.append([gap, node])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for pair: Array in near: found.append(pair[1])
	return found

static func _origin(ui: Node, side: String) -> Vector3:
	if side == "desktop":
		var camera: Variant = ui.get("camera")
		return (camera as Node3D).global_position if camera is Node3D and is_instance_valid(camera) else Vector3.INF
	var sample: Dictionary = ui.hand_sample(side) if ui.has_method("hand_sample") else {}
	if not sample.get("active", false): return Vector3.INF
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var point: Variant = sample.get("grip_position", pose.origin)
	return point if point is Vector3 else pose.origin

## True while a station node holds this side's press.
static func engaged(side: String) -> bool:
	return is_instance_valid(_engaged.get(side))

## A press (down) goes to the nearest node that handles it; a release goes to the node that took
## the press. True when a station handled it.
static func offer(ui: Node, side: String, down: bool) -> bool:
	if not down:
		var holder: Variant = _engaged.get(side)
		_engaged.erase(side)
		return is_instance_valid(holder) and bool((holder as Node).call("station_use", ui, side, false))
	if not COOKING.allowed(ui): return false
	for node: Node3D in _nodes(ui, side):
		if node.has_method("station_use") and bool(node.call("station_use", ui, side, true)):
			_engaged[side] = node
			return true
	return false

## The hint of the nearest station node with something to offer, or {}.
static func hint(ui: Node) -> Dictionary:
	if not is_instance_valid(ui) or not ui.is_inside_tree() or not ui.get_tree().has_group(GROUP) or not COOKING.allowed(ui): return {}
	for side: String in (["desktop"] if bool(ui.get("_desktop")) else ["right", "left"]):
		for node: Node3D in _nodes(ui, side):
			if not node.has_method("station_hint"): continue
			var shown: Variant = node.call("station_hint", ui, side)
			if shown is Dictionary and not (shown as Dictionary).is_empty(): return shown
	return {}
