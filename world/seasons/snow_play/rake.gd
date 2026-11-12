extends Node3D
## The leaf rake (W2-SEAS-F, design 6.3 'Raking'): the visual of the briefcase item "rake"
## (world/props/seasons/rake.tscn, Blender MCP model rake.glb). Held in a VR hand, dragging its
## tines over the ground through a scattered leaf patch pulls the patch back into a pile; on
## desktop, hold click with the rake in hand and sweep (turn or walk). The leaf piles are WP-E's
## (world/seasons/leaf_piles.gd, group "leaf_piles", rake(point, radius, amount) -> patches moved);
## without them the rake does nothing.
## A station node (world/mechanics/stations/station_input.gd) for the desktop click; its own timer
## runs only while the rake is out of the briefcase: 2 Hz idle, 10 Hz while held near leaves.
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const STATION_GROUP := "mechanics_station_nodes"
const LEAF_GROUP := "leaf_piles"
## The middle of the fan of tines in the model frame (origin at the upper grip, handle down -Y).
const HEAD_LOCAL := Vector3(0, -1.25, -0.03)
const RAKE_RADIUS := 0.45
const GROUND_GAP := 0.3
const DESKTOP_AHEAD := 1.3
const IDLE := 0.5
const ACTIVE := 0.1
const MIN_STEP := 0.04
## Metres of raking that pull a scattered patch fully back into its pile.
const METRES_PER_PILE := 2.0

var raked_metres := 0.0
var _timer: Timer
var _last := Vector3.INF
var _desktop_on := false

func _ready() -> void:
	if get_node_or_null("Mesh") == null:
		var mesh := FX.instance("Rake"); mesh.name = "Mesh"
		add_child(mesh)
	add_to_group(STATION_GROUP)
	_timer = Timer.new(); _timer.name = "RakeTick"; _timer.wait_time = IDLE
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_timer.start()

## The briefcase item body (world/inventory/briefcase_drops.gd) asks for its collision.
func configure_body(_body: RigidBody3D, collision: CollisionShape3D) -> void:
	var shape := BoxShape3D.new(); shape.size = Vector3(0.5, 1.6, 0.09)
	collision.shape = shape
	collision.position = Vector3(0, -0.5, -0.02)

func _body() -> RigidBody3D:
	return get_parent() as RigidBody3D

## The briefcase inventory: the item body's parent, else the game's.
func _ui() -> Node:
	var at: Node = get_parent()
	while at != null:
		if at.has_method("hand_sample") and "held" in at: return at
		at = at.get_parent()
	var seasons: Node = get_tree().get_first_node_in_group("season_state") if is_inside_tree() else null
	var game: Variant = seasons.get("game") if seasons != null else null
	var found: Variant = (game as Node).get("inventory") if game is Node and is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

## The hand holding this rake ("desktop", "left", "right") or "".
func held_side(ui: Node) -> String:
	var body := _body()
	if ui == null or body == null: return ""
	var held: Variant = ui.get("held")
	if not held is Dictionary: return ""
	for side: Variant in (held as Dictionary):
		if (held as Dictionary)[side] == body: return str(side)
	return ""

## Where the tines touch: the model's fan (VR) or the ground ahead of the view (desktop).
func head_point(ui: Node, side: String) -> Vector3:
	if side == "desktop":
		var camera: Variant = ui.get("camera")
		if not camera is Node3D or not is_instance_valid(camera): return Vector3.INF
		var ahead: Vector3 = -(camera as Node3D).global_basis.z; ahead.y = 0.0
		if ahead.length() < 0.01: return Vector3.INF
		var at: Vector3 = (camera as Node3D).global_position + ahead.normalized() * DESKTOP_AHEAD
		return Vector3(at.x, _ground(at), at.z)
	var head := global_transform * HEAD_LOCAL
	return head if head.y - _ground(head) < GROUND_GAP else Vector3.INF

func _ground(at: Vector3) -> float:
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.has_ground(at): return WorldTerrain.instance.height_at(at)
	return at.y - 0.2

func _tick() -> void:
	var ui := _ui()
	var side := held_side(ui)
	var leaves := is_inside_tree() and get_tree().has_group(LEAF_GROUP)
	var working := leaves and side != "" and (side != "desktop" or _desktop_on)
	_timer.wait_time = ACTIVE if leaves and side != "" else IDLE
	if not working: _last = Vector3.INF; return
	var head := head_point(ui, side)
	if not head.is_finite(): _last = Vector3.INF; return
	if not _last.is_finite(): _last = head; return
	var moved := Vector2(head.x - _last.x, head.z - _last.z).length()
	if moved < MIN_STEP: return
	_last = head
	if rake_at(head, moved): FX.sound(self, "snow_play_rake", head)

## Pulls scattered leaves at `point` back toward their pile; true when any patch took it.
func rake_at(point: Vector3, metres: float) -> bool:
	var any := false
	for piles: Node in get_tree().get_nodes_in_group(LEAF_GROUP):
		if piles.has_method("rake"): any = int(piles.call("rake", point, RAKE_RADIUS, metres / METRES_PER_PILE)) > 0 or any
	if any: raked_metres += metres
	return any

## A scattered patch within reach of `point` (leaf_piles.piles_near), for the hint.
func _scattered_near(point: Vector3) -> bool:
	for piles: Node in get_tree().get_nodes_in_group(LEAF_GROUP):
		if not piles.has_method("piles_near"): return true
		for pile: Variant in piles.call("piles_near", point, 4.0):
			if pile is Dictionary and bool((pile as Dictionary).get("scattered", false)): return true
	return false

# ------------------------------------------------------------------ station node (desktop hold-click)

func station_hint(ui: Node, side: String) -> Dictionary:
	if side != "desktop" or held_side(ui) != "desktop" or not get_tree().has_group(LEAF_GROUP): return {}
	var head := head_point(ui, side)
	if not head.is_finite() or not _scattered_near(head): return {}
	return {"target": self, "point": head, "text": "Hold click and sweep · Rake the leaves into a pile", "outline": null}

func station_use(ui: Node, side: String, down: bool) -> bool:
	if side != "desktop": return false
	if not down:
		if _desktop_on: _desktop_on = false; return true
		return false
	if held_side(ui) != "desktop" or not get_tree().has_group(LEAF_GROUP): return false
	_desktop_on = true
	_last = Vector3.INF
	_timer.wait_time = ACTIVE
	return true
