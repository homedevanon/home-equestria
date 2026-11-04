extends Node
## Batch driver of the native follower (docs/NAVIGATION_PHASE_2_2026_10_02.md, phase 2 of
## docs/NAVIGATION_OVERHAUL_COMPLETE_2026_10_02.txt). One per scene tree, beside the world root;
## pony_navigator.gd adds it on first use when native following is enabled (the default).
##
## Tick order (PART 2 of the plan), in one physics frame:
##   1. navigators (process priority -10) apply ownership first (held, thrown, flight, posture,
##      interaction stop them before they queue anything), plan routes and journey legs, gather
##      their pony's state from the last physical move and queue one row each with submit();
##   2. this driver (priority -5) publishes changed walk-grid chunks to the native worlds and adds
##      every other navigating pony as an observer row (a neighbour, commanded nothing);
##   3-5. one PonyNavigationNative.step_batch() advances progress from actual motion, accepts
##      routes, steers along validated arcs and classifies progress for every row;
##   6. each command is handed to its pony's locomotion once (accept_navigation_motion), which
##      applies it in its own _physics_process (priority 0) with move_and_slide;
##   7. the motor records what it executed (speed, yaw rate, wall contact, refusal), which the
##      navigator sends back as the next tick's inputs; avoidance gets the preferred velocity now
##      and its answer is tagged when it arrives.
## Wire format: actor_keys int64 slot/generation pairs, one position, velocity and heading per row,
## INPUT_STRIDE floats of inputs per row, COMMAND_STRIDE floats out per row (valid, forward speed,
## yaw rate, command mode). A deliberate stop is a valid zero command.
const BACKEND := preload("res://world/navigation/native_navigation_backend.gd")
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd")
const INPUT_STRIDE := 13
const COMMAND_STRIDE := 4
const STATE_STRIDE := 8

## Navigators queued this physics frame (each submits at most once per frame).
var _rows: Array[Node] = []
var _peer_snapshot: Array[WeakRef] = []
var _peer_snapshot_dirty := true
var _followers: Array[Node] = []
var _observers: Array[Node3D] = []
## Counter for the actual group rebuild, independent of native batch count.
var peer_refreshes := 0

## Reuse the observer batch; clip-tier bodies deliberately have no physics collider.
func nearby_navigators(at:Vector3,radius:float) -> Array[Node]:
	var result:Array[Node]=[]
	for reference:WeakRef in _peer_snapshot:
		var nav:Node=reference.get_ref()
		if is_instance_valid(nav) and is_instance_valid(nav.pony) and nav.pony.global_position.distance_squared_to(at)<=radius*radius:
			result.append(nav)
	return result

var _keys := PackedInt64Array()
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _headings := PackedFloat32Array()
var _inputs := PackedFloat32Array()
var _services: Array[Node] = []
## One observer row of inputs (all zero), appended per observer.
var _zero_row := PackedFloat32Array()
## Counters for labs.
var batches := 0
var rows_stepped := 0
var observers_added := 0
var invalid_buffers := 0
var last_batch_us := 0


func _ready() -> void:
	process_physics_priority = -5
	add_to_group("native_follow_drivers")
	# Navigators call _invalidate_peers when they join or leave the tree (pony_navigator.gd _ready).
	# tree_changed fired on every node added anywhere and rebuilt the list each time (2026-10-23 CPU pass).
	_invalidate_peers()


func _invalidate_peers() -> void:
	_peer_snapshot_dirty = true


func _refresh_peer_snapshot() -> void:
	if not _peer_snapshot_dirty: return
	_peer_snapshot_dirty = false
	_peer_snapshot.clear()
	# Production navigators join their group in _ready, after entering the tree.
	# Rebuild on the next batch so both additions and removals are reflected.
	for navigator: Node in get_tree().get_nodes_in_group("pony_navigators"):
		_peer_snapshot.append(weakref(navigator))
	peer_refreshes += 1


func submit(navigator: Node) -> void:
	_rows.append(navigator)


func _physics_process(delta: float) -> void:
	if _rows.is_empty():
		return
	var started := Time.get_ticks_usec()
	var frame := Engine.get_physics_frames()
	var native: RefCounted = BACKEND.instance()
	if native == null:
		_rows.clear()
		return
	# Followers first, in submission order; rows from an earlier frame (the driver joined the tree
	# late) are dropped: their navigators queue a fresh one next tick.
	_followers.clear()
	var followers: Array[Node] = _followers
	# Members are read directly (one named lookup each), never through Node.get() with a String.
	for navigator: Node in _rows:
		if is_instance_valid(navigator) and navigator._native_row_frame == frame and navigator._native_handle.size() == 2:
			followers.append(navigator)
	_rows.clear()
	if followers.is_empty():
		return
	_services.clear()
	for navigator: Node in followers:
		var service: Node = navigator._native_service
		if is_instance_valid(service) and service not in _services:
			_services.append(service)
	for service: Node in _services:
		service.native_follow_sync()
	var count := followers.size()
	_keys.resize(count * 2)
	_positions.resize(count)
	_velocities.resize(count)
	_headings.resize(count)
	_inputs.clear()
	for i in count:
		var navigator: Node = followers[i]
		var pony: Node3D = navigator.pony as Node3D
		var handle: PackedInt64Array = navigator._native_handle
		_keys[i * 2] = handle[0]
		_keys[i * 2 + 1] = handle[1]
		_positions[i] = pony.global_position
		var velocity: Variant = pony.get(&"_ground_velocity")
		_velocities[i] = velocity if velocity is Vector3 else Vector3.ZERO
		_headings[i] = pony.rotation.y
		var row: PackedFloat32Array = navigator._native_inputs
		_inputs.append_array(row)
	# Observers: every other navigating pony is a neighbour (clip tiers queue on their own beat).
	# Their rows follow the followers' and carry no inputs (zeros; the native step reads none).
	if _zero_row.size() != INPUT_STRIDE:
		_zero_row.resize(INPUT_STRIDE)
		_zero_row.fill(0.0)
	_observers.clear()
	var observers: Array[Node3D] = _observers
	_refresh_peer_snapshot()
	for reference: WeakRef in _peer_snapshot:
		var navigator: Node = reference.get_ref()
		if not is_instance_valid(navigator) or not navigator.is_inside_tree(): continue
		if navigator._native_row_frame == frame:
			continue
		var pony: Node3D = navigator.pony as Node3D
		if not is_instance_valid(pony) or not pony.is_inside_tree(): continue
		observers.append(pony)
		# Slot -1: commanded nothing. The second key names her across ticks (a committed pass round
		# her in navigation_steering.cpp): her native handle, the same id her follower row has on
		# the ticks she walks, else her instance id.
		_keys.append(-1)
		var handle: PackedInt64Array = navigator._native_handle
		_keys.append((handle[0] << 32) | handle[1] if handle.size() == 2 else (1 << 62) | (navigator.get_instance_id() & 0xffffffffffff))
		_positions.append(pony.global_position)
		var velocity: Variant = pony.get(&"_ground_velocity")
		_velocities.append(velocity if velocity is Vector3 else Vector3.ZERO)
		_headings.append(pony.rotation.y)
		_inputs.append_array(_zero_row)
	var total := count + observers.size()
	var lap := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	if lap > 0: CPU_PROFILE.record("nav_driver_gather", started)
	var commands: PackedFloat32Array = native.step_batch(_keys, _positions, _velocities, _headings, delta, _inputs)
	if lap > 0:
		CPU_PROFILE.record("nav_driver_step_batch", lap)
		lap = Time.get_ticks_usec()
	batches += 1
	rows_stepped += count
	observers_added += observers.size()
	if commands.size() != total * COMMAND_STRIDE:
		# Never leave yesterday's velocity running: every follower stops and replans.
		invalid_buffers += 1
		push_error("Native follower returned %d command floats for %d rows; stopping the followers" % [commands.size(), total])
		for navigator: Node in followers:
			var pony: Node3D = navigator.get("pony") as Node3D
			pony.call("stop")
		return
	var states: PackedFloat32Array = native.batch_state()
	var preferred: PackedVector3Array = native.batch_preferred_velocities()
	for i in count:
		var navigator: Node = followers[i]
		if is_instance_valid(navigator) and is_instance_valid(navigator.pony):
			navigator._native_apply(commands, states, preferred[i], i)
	var events: Array = native.take_follow_events()
	for event: Dictionary in events:
		for navigator: Node in followers:
			var handle: PackedInt64Array = navigator._native_handle
			if handle[0] == int(event.get("slot", -1)) and handle[1] == int(event.get("generation", -1)):
				navigator._on_native_event(event)
				break
	if lap > 0: CPU_PROFILE.record("nav_driver_apply", lap)
	last_batch_us = Time.get_ticks_usec() - started
	if CPU_PROFILE.enabled:
		CPU_PROFILE.record("navigators", started)
