extends CharacterBody3D
## Grounded VR body for the xr-kit physics-hand rig.
##
## xr-kit ships a zero-gravity spacewalk body (thrusters, momentum, no floor).
## This replacement walks: gravity, stick locomotion relative to where the
## player looks, snap turn, and a capsule that follows the headset so the
## physical body stands where the player actually is inside the room-scale
## origin — not where the rig node happens to be.
##
## The physics hands are separate top-level RigidBody3D nodes that chase the
## controllers, so they need nothing from this script except that the body
## moves the XROrigin under them.

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
var companion_pace := preload("res://player/companion_pace.gd").new()
@export var walk_speed := 4.0
## Run (dev 2026-09-28): flick the move stick forward twice quickly. Running lasts until the
## stick returns to centre.
@export var run_speed := 6.0
const RUN_TAP_WINDOW := .32
const RUN_FIRST_TAP_MAX := .20
const RUN_RELEASE_MIN := .06
const RUN_FORWARD_THRESHOLD := .85
const RUN_NEUTRAL_THRESHOLD := .22
var running := false
## Optional cider effects (world/life/player_needs.gd): a tipsy sideways drift.
var drunk_drift := Vector3.ZERO
## Lying down, holding A sleeps (world/life/player_sleep.gd) and a short tap of B stands. B is also
## push-to-talk, so a longer B hold is speech and keeps you lying (playtester 2026-10-20: "the talk
## button and the sleep button weren't the same").
var _b_hold := 0.0
var _sleep_hold := 0.0
var _slept_hold := false
const SLEEP_HOLD := 1.5
const STAND_TAP := 0.6
var _stick_forward := false
var _forward_tap_at := -1.0
var _forward_release_at := -1.0
## A on the right controller (standard ax_button action). Height is in world metres.
@export_range(0.1, 2.0, 0.05) var jump_height := 0.55
@export var jump_action: StringName = &"ax_button"
const JUMP_BUFFER := 0.12
const COYOTE_TIME := 0.10
var _jump_buffer := 0.0
var _coyote := 0.0
## F (keyboard) toggles flight: constant propulsion along the headset's look direction,
## no gravity; the left stick forward/back scales it (back = crawl). Collisions stay on.
@export var fly_speed := 7.0
var flying := false
var wing_flight := preload("res://player/wing_flight.gd").new()
var wing_sandals_equipped := false
var _wing_air_time := 0.0
## Map sticks are UI input; room-scale capsule, gravity and hands still run.
var controls_locked := false:
	set(value):
		controls_locked = value
		if value:
			_jump_buffer = 0.0
			_reset_run_taps()
## Smooth turn by default. Snap turn stays available for guests who need it.
@export var smooth_turn := true
## Full-deflection smooth turn rate. Tuned for a veteran VR user.
@export var turn_speed_degrees := 140.0
@export var turn_deadzone := 0.15
@export var snap_angle_degrees := 30.0

var _walk := Vector2.ZERO
var _snap_latched := false
var _capsule: CapsuleShape3D

## The runtime can hand Godot a non-finite head or controller pose for a
## moment (WiVRn while head tracking drops as dev bends down to a pony; the
## log shows "OpenXR head space location not valid" on every flank smack).
## Godot applies any pose whose VALID bits are set, so one NaN camera used to
## cascade into the head collider, the body velocity, the full-body IK and
## the desktop mirror, printing thousands of engine errors per second: that
## flood was the one-second hitch. Hold the last finite pose instead.
const TRACKED_NODES := ["XRCamera", "XRControllerLeft", "XRControllerRight",
	"XRHandTrackerLeft", "XRHandTrackerRight"]
var _tracked: Dictionary = {}   # node name -> Node3D (XROrigin included)
var _last_finite: Dictionary = {}
var _rejected_poses := 0
var _ground_step: RefCounted = preload("res://player/ground_step.gd").new()
var swimming := preload("res://player/player_swimming.gd").new()


func _ready() -> void:
	collision_mask |= 1 << 18 # Solid cloud platforms support Anon too.
	# The capsule resource is shared with the scene file. Duplicate it so
	# height changes at runtime cannot leak into the saved resource.
	var col := %BodyCollider as CollisionShape3D
	_capsule = (col.shape as CapsuleShape3D).duplicate()
	col.shape = _capsule
	%XRControllerRight.button_pressed.connect(_on_jump_button)
	# Sanitize poses before any sibling reads them: the XR server writes the
	# tracked nodes right before _process, and SmoothCamera precedes Body.
	process_priority = -1000
	set_physics_process(true) # The loading-screen hold flag; see _process.
	_remember_finite_poses()
	XRServer.tracker_added.connect(func(_name, _type): _watch_trackers())
	_watch_trackers()
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		_apply_comfort()
		settings.changed.connect(_on_setting_changed)

	# The visible Anon body follows the camera and the CONTROLLERS. It used
	# to follow the PID physics hands, which read as jelly in the headset:
	# the hands wobbled and sat off the controllers (dev, 2026-09-06). The
	# physics hands still collide and grab. Anon uses their resolved pose only
	# during pony contact; in free space the drawn hands follow tracking exactly.
	var anon := get_node_or_null("AnonBody")
	if anon:
		# Anon's own hands replace the floating xr-kit gloves. The glove
		# skeletons stay (they drive the finger colliders and grab shapecast);
		# only their meshes go dark, and come back in HANDS body mode.
		var gloves: Array[Node] = []
		for hand_vis in ["left_hand", "right_hand"]:
			var h := get_node_or_null(hand_vis)
			if h:
				gloves.append_array(h.find_children("*", "MeshInstance3D", true, false))
		anon.call("setup", %XRCamera, %XRControllerLeft, %XRControllerRight, gloves)
		anon.call("set_physics_hands", %PhysicsHandLeft, %PhysicsHandRight)


var knockdown := preload("res://player/player_knockdown.gd").new()

func receive_buck(impulse: Vector3) -> void:
	knockdown.start(self,impulse)
	preload("res://player/buck_daze.gd").play(%XRCamera)

## Locomotion runs every rendered frame, not on 60 Hz physics ticks: under a higher headset
## rate a physics-rate rig moved the view on some frames and not others, so walking and
## smooth turning juddered (dev 2026-09-28: "hitched when I walk forward").
## Body's scene interpolation is OFF as well: applying physics interpolation to these
## render-frame transforms made the visible torso/arms lag the tracked headset.
## game.gd holds the rig still under the loading screen with set_physics_process(false);
## locomotion honours that flag.
func _process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_process_step(delta)
	if started > 0: CPU_PROFILE.record("vr_rig", started)

func _process_step(delta: float) -> void:
	_sanitize_poses()
	if not is_physics_processing(): return
	if wing_flight.resume_pending:
		if wing_sandals_equipped: velocity = wing_flight.resume(); _wing_air_time = 0.0
		else: wing_flight.resume_pending = false
	if not wing_flight.active and not wing_flight.resume_pending and wing_flight.charge < wing_flight.CAPACITY: wing_flight.recover(delta)
	var cam := %XRCamera as XRCamera3D
	if not cam.global_transform.is_finite():
		# Ancestry is broken (not the pose); never feed Jolt a NaN capsule.
		velocity = Vector3.ZERO
		return
	if knockdown.step(self,delta,%XRControllerRight.is_button_pressed(jump_action)):
		%HeadCollider.global_transform=cam.global_transform
		return

	# Head collider rides on the camera (kept from xr-kit).
	%HeadCollider.global_transform = cam.global_transform

	# The body capsule stands under the headset. Camera position is expressed
	# in Body space so room-scale walking moves the capsule, not just the view.
	var cam_local: Vector3 = to_local(cam.global_position)
	var head_h: float = clampf(cam_local.y, 0.6, 2.2)
	_capsule.height = head_h
	%BodyCollider.position = Vector3(cam_local.x, head_h * 0.5, cam_local.z)

	if seat != null:
		# Seated, the turn stick still turns the view about the head (dev 2026-09-28: "can't turn
		# my head to orient myself"). Reclined couch/bed rest keeps its own frame.
		if not is_instance_valid(_couch_rest): _process_turn(delta, cam)
		_seated_tick()
		return
	_seat_by_trigger()
	if is_instance_valid(seat): return

	_process_turn(delta, cam)

	# Stick locomotion, flattened to the ground plane.
	var fwd: Vector3 = -cam.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right: Vector3 = cam.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var dir: Vector3 = (right * _walk.x + fwd * _walk.y)
	# A deep kiss holds him where he stands (pony_kisser.gd kiss_hold); turning still works.
	if controls_locked or has_meta("kiss_hold"): dir = Vector3.ZERO
	if dir.length() > 1.0:
		dir = dir.normalized()
	# Query beneath the actual room-scale headset, rather than the origin's X/Z.
	var feet := Vector3(cam.global_position.x, global_position.y, cam.global_position.z)
	swimming.sample(get_world_3d().direct_space_state, feet, head_h, delta, not flying)
	if not flying and not controls_locked and swimming.bank_exit(self,feet,head_h,dir,%XRControllerRight.is_button_pressed(jump_action),delta):
		return
	if flying or controls_locked: swimming.climbing = false

	if flying:
		_jump_buffer = 0.0; _coyote = 0.0
		var look: Vector3 = -cam.global_transform.basis.z
		velocity = look.normalized() * fly_speed * clampf(1.0 + _walk.y * 0.85, 0.15, 1.85)
		if controls_locked: velocity = Vector3.ZERO
	elif wing_flight.active:
		_jump_buffer = 0.0; _coyote = 0.0; _wing_air_time += delta
		var input := Vector2.ZERO if controls_locked else Vector2(_walk.x, -_walk.y)
		velocity = wing_flight.step(velocity, cam.global_basis, input,
			not controls_locked and %XRControllerRight.is_button_pressed(jump_action),
			running, false, delta)
	elif swimming.active:
		_jump_buffer = 0.0; _coyote = 0.0
		velocity.x = dir.x * swimming.SPEED
		velocity.z = dir.z * swimming.SPEED
		var held_jump: bool = not controls_locked and %XRControllerRight.is_button_pressed(jump_action)
		velocity.y = swimming.vertical(velocity.y, feet.y, head_h, held_jump, delta)
	else:
		var speed := run_speed if running else walk_speed
		if companion_pace.enabled: speed = companion_pace.speed(self, delta)
		var drift := drunk_drift if dir.length_squared() > 0.01 else Vector3.ZERO
		velocity.x = dir.x * speed + drift.x
		velocity.z = dir.z * speed + drift.z
		var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
		_coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, _coyote - delta)
		if _jump_buffer > 0.0 and _coyote > 0.0:
			velocity.y = sqrt(2.0 * gravity * jump_height)
			_jump_buffer = 0.0; _coyote = 0.0
		elif not is_on_floor():
			velocity.y -= gravity * delta
		else:
			velocity.y = 0.0
		_jump_buffer = maxf(0.0, _jump_buffer - delta)

	var attempted := velocity
	var stepped := false
	if flying or wing_flight.active or swimming.active or controls_locked or dir == Vector3.ZERO: _ground_step.reset()
	else: stepped = _ground_step.move(self, delta)
	if not stepped: move_and_slide()
	if wing_flight.active and ((_wing_air_time > 0.6 and is_on_floor() and velocity.y <= 0.0) or swimming.active): wing_flight.finish()
	preload("res://player/pony_body_contact.gd").transfer(self, attempted, delta)

	# Walking into a loose object shoves it instead of sliding off it.
	var collision := get_last_slide_collision()
	if collision:
		var collider: Object = collision.get_collider(0)
		if collider is RigidBody3D:
			var push: float = clampf((collider as RigidBody3D).mass / 80.0, 0.0, 1.0)
			(collider as RigidBody3D).apply_impulse(
				-collision.get_normal(0) * velocity.length() * push * delta * 60.0,
				collision.get_position(0) - (collider as RigidBody3D).global_position)


## Connect after XRCamera3D/XRNode3D did, so our handler runs after theirs
## on the same pose_changed emission and can undo a non-finite write at once.
func _watch_trackers() -> void:
	for tracker_name in ["head", "left_hand", "right_hand"]:
		var tracker := XRServer.get_tracker(tracker_name)
		if tracker == null or not tracker.has_signal("pose_changed"): continue
		if not tracker.pose_changed.is_connected(_on_tracker_pose):
			tracker.pose_changed.connect(_on_tracker_pose)


func _on_tracker_pose(_pose: XRPose) -> void:
	_sanitize_poses()


func _remember_finite_poses() -> void:
	_tracked = {"XROrigin": %XROrigin}
	for node_name in TRACKED_NODES:
		var node := find_child(node_name, true, false) as Node3D
		if node != null: _tracked[node_name] = node
	for node_name in _tracked:
		if (_tracked[node_name] as Node3D).transform.is_finite():
			_last_finite[node_name] = (_tracked[node_name] as Node3D).transform


## Reject non-finite tracked transforms and hold the last good one. Also
## covers XROrigin, whose turn maths compounds a bad camera origin forever.
func _sanitize_poses() -> void:
	for node_name in _tracked:
		var node := _tracked[node_name] as Node3D
		if not is_instance_valid(node): continue
		if node.transform.is_finite():
			_last_finite[node_name] = node.transform
		elif _last_finite.has(node_name):
			node.transform = _last_finite[node_name]
			_note_rejected(node_name)


func _note_rejected(node_name: String) -> void:
	_rejected_poses += 1
	if _rejected_poses <= 5 or _rejected_poses % 500 == 0:
		print("[xr] non-finite %s pose held at last good value (%d rejected)" % [node_name, _rejected_poses])


## Turning reads the right stick directly. Both view modes rotate the origin
## around the camera, so the view pivots in place instead of orbiting the
## rig node.
func _unhandled_input(event: InputEvent) -> void:
	if controls_locked: return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F:
		toggle_wing_flight()
	elif event is InputEventKey and event.pressed and not event.echo and (event.physical_keycode == KEY_BACKSLASH or event.keycode == KEY_BACKSLASH) and preload("res://world/dev_tools.gd").enabled():
		wing_flight.finish()
		flying = not flying
		if not flying:
			velocity = Vector3.ZERO
		print("[xr] fly %s" % ("on" if flying else "off"))
		get_viewport().set_input_as_handled()


func _on_setting_changed(key: String) -> void:
	if key.begins_with("vr/"): _apply_comfort()


## VR comfort from the Settings autoload: turn mode, snap angle, smooth turn rate, and
## which stick moves (the other one turns).
var turn_with_left := false
func _apply_comfort() -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings == null: return
	smooth_turn = str(settings.get_value("vr/turn_mode")) != "snap"
	snap_angle_degrees = float(settings.get_value("vr/snap_angle"))
	turn_speed_degrees = float(settings.get_value("vr/turn_speed"))
	turn_with_left = str(settings.get_value("vr/move_hand")) == "right"
	_walk = Vector2.ZERO
	_reset_run_taps()


func _process_turn(delta: float, cam: XRCamera3D) -> void:
	if controls_locked: return
	var stick: float = 0.0
	var ctrl := (%XRControllerLeft if turn_with_left else %XRControllerRight) as XRController3D
	if ctrl:
		stick = ctrl.get_vector2("primary").x

	var angle := 0.0
	if smooth_turn:
		if absf(stick) < turn_deadzone:
			return
		# Squared response: small deflection turns slowly, full deflection
		# turns at the configured rate.
		angle = -stick * absf(stick) * deg_to_rad(turn_speed_degrees) * delta
	else:
		if absf(stick) < 0.1:
			_snap_latched = false
			return
		if _snap_latched or absf(stick) < 0.9:
			return
		_snap_latched = true
		angle = -signf(stick) * deg_to_rad(snap_angle_degrees)

	var t1 := Transform3D()
	var t2 := Transform3D()
	t1.origin = cam.transform.origin
	t2.origin = -cam.transform.origin
	var spin := Transform3D.IDENTITY.rotated(Vector3.UP, angle)
	%XROrigin.transform = %XROrigin.transform * t1 * spin * t2

	# After a snap jump the unloaded hands teleport to the controllers.
	# Smooth turn needs no reset: the PID follows the moving controllers.
	if not smooth_turn:
		for hand in [%PhysicsHandLeft, %PhysicsHandRight]:
			if not hand.held_object:
				hand.reset_hand()


## Rigid move of the whole rig (origin, camera, hands) to a world point. The physics hands
## snap to the controllers instead of chasing them across the map.
## Sitting (dev 2026-09-26): aim the right controller at a seat (world/life/seat.gd, furniture
## or a town bench) and pull the trigger with an empty hand. The rig translates so your head is
## 78 cm above the seat, retaining the tracked view orientation;
## gravity and the body capsule rest while seated. Push the move stick or press B to stand up in
## front of the seat.
const SEATED_EYE := 0.78
var seat: Node3D
var _seat_trigger := false
var _stand_armed := false
var _seat_return := Vector3.ZERO
var _couch_rest: Node
var _rest_trigger := true
const SEAT_EXIT = preload("res://world/life/couch/exit_space.gd")

func sit_on(target: Node3D) -> bool:
	if target == null or flying or wing_flight.active or controls_locked: return false
	var occupant: Variant = (target.get_meta("occupant") if target.has_meta("occupant") else null)
	if is_instance_valid(occupant) and occupant != self: return false
	var cam := %XRCamera as XRCamera3D
	if cam.global_position.distance_to(target.global_position) > 3.0: return false
	var seating: Node = get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating.player_seat_accessible(target, self): return false
	if is_instance_valid(seat):
		stand_up()
		if is_instance_valid(seat): return false
	_seat_return = global_position
	seat = target
	seat.set_meta("occupant", self)
	# Face the way the seat faces (dev 2026-09-28: you sat facing wherever you happened to look).
	# The whole rig turns about the head, so the tracked view and the head position stay put;
	# the turn stick still turns afterwards.
	var looking: Vector3 = -cam.global_basis.z; looking.y = 0.0
	# Seats look along -Z (seating.gd builds them with Basis.looking_at(forward)).
	var facing: Vector3 = -target.global_basis.z; facing.y = 0.0
	if looking.length_squared() > .01 and facing.length_squared() > .01:
		var about_head := Transform3D(Basis.IDENTITY, cam.transform.origin)
		var spin := Transform3D.IDENTITY.rotated(Vector3.UP, looking.normalized().signed_angle_to(facing.normalized(), Vector3.UP))
		%XROrigin.transform = %XROrigin.transform * about_head * spin * about_head.affine_inverse()
	var head := cam.global_position
	var aim := target.global_position + target.global_basis.z.normalized() * 0.06 + Vector3.UP * SEATED_EYE
	global_position += aim - head
	velocity = Vector3.ZERO
	%BodyCollider.disabled = true
	_stand_armed = false
	_jump_buffer = 0.0
	_rest_trigger = true
	_set_avatar_seated(true)
	for hand in [%PhysicsHandLeft, %PhysicsHandRight]:
		if not hand.held_object: hand.reset_hand()
	preload("res://world/audio/interaction_sounds.gd").play_at(self, "prop_rest")
	return true

func _finish_couch_rest() -> void:
	if is_instance_valid(_couch_rest): _couch_rest.finish()
	_couch_rest = null

func toggle_couch_sleep() -> bool:
	if controls_locked or not is_instance_valid(seat): return false
	if is_instance_valid(_couch_rest):
		_couch_rest.wake()
		return true
	var couch: Variant = (seat.get_meta("couch") if seat.has_meta("couch") else null)
	if not is_instance_valid(couch): return false
	var avatar := get_parent().find_child("AnonBody", true, false)
	_couch_rest = couch.begin_player(self, seat, %XRCamera, avatar)
	return _couch_rest != null

func stand_up() -> void:
	var old: Variant = seat
	if not is_instance_valid(old): old = null
	var floor_at := SEAT_EXIT.find_exit(self, old, _seat_return, _capsule.height, _capsule.radius)
	if not floor_at.is_finite(): return
	_finish_couch_rest()
	seat = null
	%BodyCollider.disabled = false
	_set_avatar_seated(false)
	if is_instance_valid(old) and (old.get_meta("occupant") if old.has_meta("occupant") else null) == self: old.remove_meta("occupant")
	var cam := %XRCamera as XRCamera3D
	var head_offset := cam.global_position - global_position
	global_position = Vector3(floor_at.x - head_offset.x, floor_at.y, floor_at.z - head_offset.z)
	velocity = Vector3.ZERO
	for hand in [%PhysicsHandLeft, %PhysicsHandRight]:
		if not hand.held_object: hand.reset_hand()

func _seated_tick() -> void:
	velocity = Vector3.ZERO
	_jump_buffer = 0.0
	if not is_instance_valid(seat):
		stand_up()
		return
	_couch_by_touch()
	var b_pressed: bool = %XRControllerRight.is_button_pressed("by_button")
	var wants_up: bool
	if is_instance_valid(_couch_rest) and float(_couch_rest.amount) >= 0.99:
		# Lying down: the stick shifts you along the bed toward her; only B gets you up
		# (dev 2026-09-29). Rolling off the mattress is still ended by player_rest.
		if not controls_locked: _couch_rest.shift(_walk, get_physics_process_delta_time())
		# A tap of B (under STAND_TAP) stands; a longer B hold is talking. Holding A SLEEP_HOLD seconds
		# sleeps (dev 2026-09-29 sleep mechanic; moved off the talk button 2026-10-20).
		wants_up = false
		if has_meta("shared_nap_surface") and not controls_locked and _walk.length() > .7: wants_up = true
		var step := get_physics_process_delta_time()
		if b_pressed and _stand_armed and not controls_locked: _b_hold += step
		elif not b_pressed:
			if _b_hold > 0.0 and _b_hold < STAND_TAP and not controls_locked: wants_up = true
			_b_hold = 0.0
		var a_pressed: bool = %XRControllerRight.is_button_pressed(jump_action)
		if a_pressed and not controls_locked:
			_sleep_hold += step
			if _sleep_hold >= SLEEP_HOLD and not _slept_hold:
				_slept_hold = true
				var sleeper: Node = get_tree().get_first_node_in_group("player_sleep")
				if sleeper != null: sleeper.sleep()
		else:
			# Locked (asleep, map open) or released: a new deliberate hold is needed.
			_sleep_hold = 0.0
			if not a_pressed: _slept_hold = false
	else:
		_sleep_hold = 0.0
		wants_up = not controls_locked and (_walk.length() > 0.7 or b_pressed)
	# The press that sat you down (or a stick still held) must be released first.
	if wants_up and _stand_armed: stand_up()
	elif not wants_up: _stand_armed = true

## Deliberate cushion touch: empty right hand on the mattress, squeeze trigger after release.
## Beds too (dev 2026-09-28: "cuddle a mare in vr on a bed"): aim at any bed and pull the right
## trigger to sit on it, touch the mattress and pull again to lie back. A willing companion
## nearby climbs in and lies against you (world/relationships/shared_bed.gd); grip + trigger on
## her poses the cuddle. Trigger on the mattress sits you up. Lying down, the move stick shifts
## you along the mattress and only B stands you up; sat up, the stick or B stands.
func _couch_by_touch() -> void:
	var controller: XRController3D = %XRControllerRight
	if not controller.get_is_active():
		_rest_trigger = true
		return
	var pull := controller.get_float("trigger")
	var pressed := pull > 0.8 and not _rest_trigger
	_rest_trigger = pull > 0.5
	if not pressed or controls_locked: return
	var hand: Node = %PhysicsHandRight
	if hand.get("held_object") != null or hand.get_meta("inventory_busy", false) or hand.get_meta("pony_inspection", false): return
	var couch: Variant = (seat.get_meta("couch") if seat.has_meta("couch") else null)
	if not is_instance_valid(couch): return
	# Each furniture knows its own cushions: a sofa's seat band, a bed's whole mattress.
	if not couch.touch_zone(controller.global_position): return
	toggle_couch_sleep()

func _seat_by_trigger() -> void:
	var pull: float = %XRControllerRight.get_float("trigger")
	var pressed := pull > 0.8 and not _seat_trigger
	_seat_trigger = pull > 0.5
	if not pressed or controls_locked or flying or wing_flight.active: return
	var hand: Node = %PhysicsHandRight
	if hand.get("held_object") != null or hand.get_meta("inventory_busy", false) or hand.get_meta("pony_inspection", false): return
	if hand.get_meta("candle_reach", false): return # the trigger lights a candle instead
	if hand.get_meta("lamp_reach", false): return # touching a lamp owns its trigger
	var aim: Transform3D = %XRControllerRight.global_transform
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(aim.origin, aim.origin - aim.basis.z * 2.5, 1))
	if hit.is_empty(): return
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating.has_method("player_seat_near"): return
	var target: Node3D = seating.player_seat_near(hit.position, 0.9, self, hit.collider)
	if target != null: sit_on(target)
	# A full fist (grip and trigger) is a grab, never a nap: reaching low for a pony's leg lay the
	# player down in the grass instead (Quest player, 2026-11-12). Trigger alone still lies down.
	elif not is_instance_valid(seat) and hit.position.y < global_position.y + .25 and hand.global_position.y < global_position.y + .4 \
			and %XRControllerRight.get_float("grip") < 0.5:
		preload("res://world/relationships/shared_nap_grass.gd").toggle(self, %XRCamera)

func _set_avatar_seated(value: bool) -> void:
	var avatar := get_parent().find_child("AnonBody", true, false) if get_parent() != null else null
	if avatar != null and "force_seated" in avatar: avatar.force_seated = value

func teleport(to: Vector3) -> void:
	if is_instance_valid(seat): stand_up()
	global_position = to
	velocity = Vector3.ZERO
	for hand in [%PhysicsHandLeft, %PhysicsHandRight]:
		if not hand.held_object: hand.reset_hand()


func _on_thruster(value: Vector2) -> void:
	_walk = value if value.is_finite() else Vector2.ZERO
	if _run_tap(value, Time.get_ticks_msec() * .001):
		var ctrl := (%XRControllerRight if turn_with_left else %XRControllerLeft) as XRController3D
		ctrl.trigger_haptic_pulse("haptic", 0.0, 0.25, 0.06, 0.0)

func _reset_run_taps() -> void:
	running = false
	_stick_forward = false
	_forward_tap_at = -1.0
	_forward_release_at = -1.0

## Two strong forward taps, separated by a real neutral pause. Crossing the
## forward threshold repeatedly while walking is not a double tap.
func _run_tap(value: Vector2, now: float) -> bool:
	if not value.is_finite() or controls_locked or is_instance_valid(seat):
		_reset_run_taps(); return false
	if running:
		if value.length_squared() < .09: _reset_run_taps()
		return false
	if value.length_squared() < RUN_NEUTRAL_THRESHOLD * RUN_NEUTRAL_THRESHOLD:
		if _stick_forward:
			_forward_release_at = now if _forward_tap_at >= 0.0 and now - _forward_tap_at <= RUN_FIRST_TAP_MAX else -1.0
			if _forward_release_at < 0.0: _forward_tap_at = -1.0
		_stick_forward = false
		return false
	if _forward_release_at >= 0.0 and now - _forward_release_at < RUN_RELEASE_MIN:
		_forward_tap_at = -1.0; _forward_release_at = -1.0
	if value.y < 0.0 or absf(value.x) > .35:
		_forward_tap_at = -1.0; _forward_release_at = -1.0
		_stick_forward = true # Return to neutral before a new forward tap.
		return false
	if value.y < RUN_FORWARD_THRESHOLD or _stick_forward: return false
	_stick_forward = true
	if _forward_tap_at >= 0.0 and _forward_release_at >= 0.0 \
			and now - _forward_tap_at <= RUN_TAP_WINDOW and now - _forward_release_at >= RUN_RELEASE_MIN:
		running = true; _forward_tap_at = -1.0; _forward_release_at = -1.0
		return true
	_forward_tap_at = now; _forward_release_at = -1.0
	return false


func request_jump() -> void:
	if wing_sandals_equipped and not controls_locked and not flying and not is_instance_valid(seat):
		if not wing_flight.active: toggle_wing_flight()
		return
	if not flying and not controls_locked: _jump_buffer = JUMP_BUFFER


func _on_jump_button(action: StringName) -> void:
	if action == jump_action: request_jump()
	elif action == &"by_button" and wing_flight.active and not controls_locked: wing_flight.landing = true
	elif action == &"primary_click" and not controls_locked:
		companion_pace.toggle()
		_reset_run_taps()
		%XRControllerRight.trigger_haptic_pulse("haptic", 0.0, 0.25, 0.08, 0.0)

func set_wing_sandals_equipped(value: bool) -> void:
	wing_sandals_equipped = value
	if not value: wing_flight.finish()

func toggle_wing_flight() -> bool:
	if controls_locked or flying or is_instance_valid(seat): return false
	if wing_flight.active: wing_flight.landing = true; return true
	if not wing_sandals_equipped or swimming.active or wing_flight.charge < 1.0: return false
	velocity = wing_flight.begin(velocity, -%XRCamera.global_basis.z)
	_wing_air_time = 0.0
	return wing_flight.active


func _on_thruster_brake(_value: bool) -> void:
	pass


## Legacy connection targets from the scene wiring; turning is polled now.
func _on_turned_x(_direction: int, _controller: Node3D) -> void:
	pass


func _on_turned_y(_direction: int, _controller: Node3D) -> void:
	pass
