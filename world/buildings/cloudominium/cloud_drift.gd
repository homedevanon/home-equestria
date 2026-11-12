extends Node
## Rainbow Dash's Cloudominium floats (dev 2026-11-04: "float around in the wind and turn VERY VERY
## GENTLY and VERY VERY SLOWLY"). Its pose is a pure function of TimeOfDay.active_seconds, which the
## save keeps, so anything saved inside comes back inside and nothing else is stored.
## Bodies in the home move in steps of about a millimetre at STEP_SECONDS: fast enough to look
## continuous at this speed, and it spares the physics a transform for every piece of furniture
## each tick. Ponies ride as on the balloon (set_moving_support), the player as balloon.gd moves
## them. Loose props ride too (2026-11-08, M-NAV-06): items on the loose-item layer inside ABOARD
## are listed with the riders once a second (one box query) and carried by each step. Their saved
## pose is their world pose at checkpoint time, and the home's pose is a function of the saved
## clock, so a reload puts them back inside. Placed furnishing is only possible in the player's own
## home (home_furnishing.gd), never this one; if it ever is, it rides like any loose item but its
## saved pose is the placement pose (see hazards.md). Rollback: CARRY_LOOSE = false.
const CLOCK := "/root/TimeOfDay"
const STEP_SECONDS := 0.1
const RIDERS_SECONDS := 1.0
## Past this the player cannot tell: no transforms, and the next step lands on the true pose.
const FAR_METRES := 500.0
## One turn an hour.
const TURN_SECONDS := 3600.0
## Metres and seconds of the slow waves. Periods share no factor, so the path never repeats soon.
const WAVES_X := [[6.0, 1373.0, 0.0], [2.0, 531.0, 1.1]]
const WAVES_Z := [[5.0, 1109.0, 0.6], [2.0, 613.0, 0.0]]
const WAVES_Y := [[0.5, 139.0, 0.0], [0.2, 67.0, 2.0]]
## The cloud and tower in the home's frame (measured, tools/cloudominium/test_cloud_drift.gd).
const ABOARD := AABB(Vector3(-26.0, -16.0, -30.0), Vector3(57.0, 43.0, 73.0))
const CARRY_LOOSE := true
## Dropped and loose items (briefcase_drops.gd, home_furnishing.gd ITEM_LAYER).
const LOOSE_LAYER := 1 << 17
const LOOSE_MAX := 64

var shell: Node3D
var frame: Node3D
var pivot := Vector3.ZERO
var _shell_rest := Transform3D.IDENTITY
var _frame_rest := Transform3D.IDENTITY
var _applied := Transform3D.IDENTITY
var _step_left := 0.0
var _riders_left := 0.0
var _riders: Array[Node] = []
var _loose: Array[RigidBody3D] = []
var _loose_query: PhysicsShapeQueryParameters3D
## Told the new frame after each step: painted surfaces read it in world space (materials.gd).
var on_moved: Callable
## The running game, for the player's body. Null in tools.
var game: Node

func bind(existing: Node3D, runtime: Node3D) -> void:
	shell = existing
	frame = runtime
	_shell_rest = existing.global_transform
	_frame_rest = runtime.global_transform
	pivot = _frame_rest.origin
	_move(_clock(), null)

static func _wave(rows: Array, t: float) -> float:
	var sum := 0.0
	for row: Array in rows: sum += float(row[0]) * sin(TAU * t / float(row[1]) + float(row[2]))
	return sum

## Where the home is at clock time t, as a transform of its resting pose about the tower.
static func motion(t: float, around: Vector3) -> Transform3D:
	var offset := Vector3(_wave(WAVES_X, t), _wave(WAVES_Y, t), _wave(WAVES_Z, t))
	var turn := Basis(Vector3.UP, TAU * fposmod(t, TURN_SECONDS) / TURN_SECONDS)
	return Transform3D(turn, around + offset) * Transform3D(Basis.IDENTITY, -around)

func _clock() -> float:
	var clock := get_node_or_null(CLOCK)
	return float(clock.active_seconds) if clock != null else 0.0

## The rig's "Body" is looked up once per rig (again each RIDERS_SECONDS while the rig has none,
## or when the found one left it), not by a recursive find_child over the whole player every step.
var _rig_id := 0
var _body_cached: Node3D
var _had_body := false
var _body_recheck := 0.0

func _player() -> Node3D:
	var rig: Node3D = game.get("player") as Node3D if is_instance_valid(game) else null
	if rig == null: return null
	_body_recheck -= STEP_SECONDS
	var lost := _had_body and not (is_instance_valid(_body_cached) and rig.is_ancestor_of(_body_cached))
	if rig.get_instance_id() != _rig_id or lost or (not _had_body and _body_recheck <= 0.0):
		_rig_id = rig.get_instance_id()
		_body_cached = rig.find_child("Body", true, false) as Node3D
		_had_body = _body_cached != null
		_body_recheck = RIDERS_SECONDS
	return _body_cached if _had_body else rig

func holds(point: Vector3) -> bool:
	return ABOARD.has_point(frame.to_local(point))

func _physics_process(delta: float) -> void:
	if not is_instance_valid(shell) or not is_instance_valid(frame): return
	_step_left -= delta
	if _step_left > 0.0: return
	_step_left = STEP_SECONDS
	var player := _player()
	if player != null and player.global_position.distance_squared_to(frame.global_position) > FAR_METRES * FAR_METRES: return
	_riders_left -= STEP_SECONDS
	if _riders_left <= 0.0:
		_riders_left = RIDERS_SECONDS
		_update_riders()
	_move(_clock(), player)

func _move(t: float, player: Node3D) -> void:
	var next := motion(t, pivot)
	var step := next * _applied.affine_inverse()
	var aboard := player != null and holds(_feet(player))
	_applied = next
	shell.global_transform = next * _shell_rest
	frame.global_transform = next * _frame_rest
	if aboard: player.global_position = step * player.global_position
	if not _loose.is_empty(): _carry_loose(step)
	if on_moved.is_valid(): on_moved.call(frame.global_transform)

## Loose items aboard move with the floor under them. A sleeping item stays asleep (a 1 mm step
## must not wake every cup on the shelf into a physics simulation ten times a second); a held one
## is the hand's.
func _carry_loose(step: Transform3D) -> void:
	var held: Array = _held_items()
	for item: RigidBody3D in _loose:
		if not is_instance_valid(item) or not item.is_inside_tree() or item in held: continue
		# Through the server: setting the node's transform wakes the body, and its sleeping flag
		# only follows the server on the next sync.
		var rid := item.get_rid()
		var asleep := bool(PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING))
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, step * item.global_transform)
		if asleep: PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, true)

func _held_items() -> Array:
	var inventory: Node = game.get("inventory") as Node if is_instance_valid(game) else null
	var held: Variant = inventory.get("held") if is_instance_valid(inventory) else null
	return (held as Dictionary).values() if held is Dictionary else []

## One box query over ABOARD on the loose-item layer, at the riders' 1 s rate.
func _update_loose() -> void:
	_loose.clear()
	if not CARRY_LOOSE or not frame.is_inside_tree(): return
	if _loose_query == null:
		var box := BoxShape3D.new(); box.size = ABOARD.size
		_loose_query = PhysicsShapeQueryParameters3D.new()
		_loose_query.shape = box
		_loose_query.collision_mask = LOOSE_LAYER
		_loose_query.collide_with_areas = false
	_loose_query.transform = frame.global_transform * Transform3D(Basis.IDENTITY, ABOARD.get_center())
	for hit: Dictionary in frame.get_world_3d().direct_space_state.intersect_shape(_loose_query, LOOSE_MAX):
		var item := hit.get("collider") as RigidBody3D
		if item != null and item not in _loose: _loose.append(item)

## The VR Body node is the room-scale origin, often a metre from where the player stands.
func _feet(player: Node3D) -> Vector3:
	var view := get_viewport().get_camera_3d()
	if view is XRCamera3D and player.is_ancestor_of(view):
		return Vector3(view.global_position.x, player.global_position.y, view.global_position.z)
	return player.global_position

func _update_riders() -> void:
	_update_loose()
	for pony: Node in _riders.duplicate():
		if not is_instance_valid(pony):
			_riders.erase(pony)
		elif pony.moving_support != frame or not holds(pony.global_position):
			if pony.moving_support == frame: pony.set_moving_support(null)
			_riders.erase(pony)
	for navigator: Node in get_tree().get_nodes_in_group("pony_navigators"):
		var pony: Node3D = navigator.get("pony") as Node3D
		if pony == null or not pony.has_method("set_moving_support") or pony.moving_support != null: continue
		if holds(pony.global_position):
			pony.set_moving_support(frame)
			_riders.append(pony)
