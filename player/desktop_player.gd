extends CharacterBody3D
## Development player. Not a shipping feature -- it exists so the world can be
## walked, framed and debugged without putting a headset on, and so the capture
## harness has something to spawn.
##
## Eye height matches the VR default so anything judged here reads the same in
## the headset.
##
## Also the seated VR rig (player/seated_player.tscn, dev 2026-10-01: "just VR but you use the
## keyboard"): the same keyboard and mouse controls, but the eye is ViewAnchor/XROrigin/XRCamera
## and the headset gives pitch. And the AnonPony rig: with a form driver (player/pony_form.gd)
## the pony body walks itself, this rig follows it, and the driver places the view
## (docs/ANONPONY_DESIGN_2026_10_01.md, 6.2 and 12.3).

const EYE_HEIGHT := 1.7
var companion_pace := preload("res://player/companion_pace.gd").new()
## Fraction of standing height when crouched.
const CROUCH_RATIO := 0.55
const CROUCH_LERP := 12.0

@export var walk_speed := 5.5
@export var sprint_speed := 8.0
@export var crouch_speed := 1.3
## Walk (Settings binding "move_walk", Alt by default; a human's Ctrl already crouches): tap it to
## toggle walking, or hold it to walk only while held. Sprint (Shift) still overrides a toggled walk. AnonPony walks on Ctrl as well.
@export var stroll_speed := 1.8
const WALK_TAP := 0.3
var walk_toggled := false
var _walk_key_down := false
var _walk_key_since := 0.0
@export var fly_speed := 30.0
@export var mouse_sensitivity := 0.0022
@export var jump_velocity := 5.0

## Head bob. Deliberately gentle: this is a VR project, and while the desktop
## rig is only a dev tool, tuning bob to feel good here and then carrying those
## numbers into the headset is how people get motion sick. Vertical only, no
## roll, and it settles to zero the moment you stop.
@export var bob_enabled := true
@export var bob_frequency := 1.9
@export var bob_amplitude := 0.055
@export var bob_sprint_scale := 1.5

## Desktop: $Camera3D (labs use it by that path). Seated VR: the headset camera.
@onready var camera: Camera3D = (get_node_or_null("Camera3D") if has_node("Camera3D") else find_child("XRCamera", true, false)) as Camera3D
## Seated VR only (null on desktop): the tracked origin, and its plain parent that carries the
## physics-interpolation offset (XRServer reads the origin's non-interpolated transform).
@onready var view_origin: XROrigin3D = find_child("XROrigin", true, false) as XROrigin3D
@onready var view_anchor: Node3D = find_child("ViewAnchor", true, false) as Node3D
## The eye is in a headset (seated_player.tscn).
var headset_view := false
## Someone else owns the eye (the wake's lying and sitting views): no eye writes, no view placing.
var view_hold := false
## AnonPony: player/pony_form.gd. drive() once per physics tick; place_view() for the eye.
var form_driver: Node = null

var flying := false
## Debug fly that ignores collision (Shift+\).
var noclip := false
## Shared across footwear and pony form; grounded full stamina has no recovery work.
var wing_flight := preload("res://player/wing_flight.gd").new()
var wing_sandals_equipped := false
var _wing_air_time := 0.0
var controls_locked := false
## Optional cider effects (world/life/player_needs.gd): a tipsy sideways drift.
var drunk_drift := Vector3.ZERO
## Holding Space while lying down sleeps (world/life/player_sleep.gd); a tap still stands.
var _space_hold := 0.0
var _slept_hold := false
const SLEEP_HOLD := 1.5
var crouching := false
var _pitch := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

var _stand_eye := EYE_HEIGHT
var _eye_height := EYE_HEIGHT
var _stand_capsule_height := 1.8
var _bob_phase := 0.0
var _bob_offset := 0.0
var _ground_step: RefCounted = preload("res://player/ground_step.gd").new()
var swimming := preload("res://player/player_swimming.gd").new()
var knockdown := preload("res://player/player_knockdown.gd").new()

func receive_buck(impulse: Vector3) -> void:
	knockdown.start(self,impulse)
	preload("res://player/buck_daze.gd").play(camera)


func _ready() -> void:
	headset_view = view_origin != null
	collision_mask |= 1 << 18 # Solid cloud platforms support Anon too.
	if headset_view:
		# Seated VR: the mouse turns the body at once; the view never bobs.
		bob_enabled = false
		if view_anchor != null: view_anchor.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_sanitize_head()
		XRServer.tracker_added.connect(_on_tracker_added)
		_watch_head()
		var openxr := XRServer.find_interface("OpenXR")
		if openxr != null and openxr.has_signal("pose_recentered"): openxr.connect("pose_recentered", recenter_view)
		get_tree().create_timer(0.5).timeout.connect(recenter_view)
	else:
		# Optional terrain review opens beside dev's other game; capture only on Esc or a click.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_process(headset_view)
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		_apply_settings()
		settings.changed.connect(_on_setting_changed)


func _exit_tree() -> void:
	if not headset_view: return
	# The OpenXR interface outlives the world scene.
	var openxr := XRServer.find_interface("OpenXR")
	if openxr != null and openxr.has_signal("pose_recentered") and openxr.is_connected("pose_recentered", recenter_view):
		openxr.disconnect("pose_recentered", recenter_view)


func _on_setting_changed(key: String) -> void:
	if key.begins_with("controls/") or key == "access/reduced_motion": _apply_settings()
	elif key == "player/height_cm": apply_height(false)


## Mouse sensitivity, invert Y, field of view and reduced motion from the Settings autoload.
var invert_y := false
func _apply_settings() -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings == null: return
	mouse_sensitivity = settings.mouse_sensitivity()
	invert_y = bool(settings.get_value("controls/invert_y"))
	if not headset_view: camera.fov = float(settings.get_value("controls/fov"))
	bob_enabled = not bool(settings.get_value("access/reduced_motion")) and not headset_view and form_driver == null


## Resizes the rig. Ponyville was authored around pony-height cameras, so an
## adult-human player reads as a giant in it; game.gd drives this from a single
## constant shared with the VR rig. Speeds scale too -- a smaller body covering
## ground at full adult pace feels like skating. Anon's own height (Settings
## player/height_cm) sizes eye and capsule on top of this: apply_height().
func apply_scale(s: float) -> void:
	_rig_scale = s
	walk_speed *= s
	sprint_speed *= s
	crouch_speed *= s
	stroll_speed *= s
	jump_velocity *= sqrt(s)
	# Bob is a body-scale motion, so it shrinks with the body.
	bob_amplitude *= s

	var col := $Collision as CollisionShape3D
	# Duplicated so the .tscn's shared sub-resource is not mutated in place.
	var capsule := (col.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	capsule.radius *= s
	col.shape = capsule
	apply_height(true)


## The 6 ft Anon's standing eye and capsule height before the rig scale (the former 182 cm
## default: eye 12 cm below the crown), so 6 ft 0 in keeps exactly the rig every check was tuned on.
const REFERENCE_EYE := 1.70
const REFERENCE_CAPSULE := 1.82
var _rig_scale := 1.0

## Anon's chosen real height over 6 ft (Settings.anon_height_scale), 1.0 without Settings.
func height_scale() -> float:
	var settings := get_node_or_null("/root/Settings")
	return float(settings.call("anon_height_scale")) if settings != null and settings.has_method("anon_height_scale") else 1.0

## Standing eye and capsule from Anon's height (dev 2026-11-03). At spawn they are placed at once;
## a live change sets the targets the crouch ease moves the eye and capsule to. Radius and walking
## speeds keep the rig scale alone, so doors and paths fit as before. AnonPony's form owns both.
func apply_height(snap: bool) -> void:
	if is_instance_valid(form_driver): return
	var k := height_scale()
	_stand_eye = REFERENCE_EYE * _rig_scale * k
	var col := $Collision as CollisionShape3D
	var capsule := col.shape as CapsuleShape3D
	_stand_capsule_height = maxf(capsule.radius * 2.0, REFERENCE_CAPSULE * _rig_scale * k)
	if is_instance_valid(seat) and _seated_eye > 0.0: _seated_eye = SEATED_EYE * k
	if not snap: return
	_eye_height = _stand_eye
	_set_eye_y(_stand_eye)
	capsule.height = _stand_capsule_height
	col.position.y = capsule.height * 0.5


## The rig's own eye height above its feet. Desktop: the camera. Seated: the tracked origin
## (the head sits on it after recenter_view), held while the wake owns the eye. AnonPony's eye
## is placed only by the form driver.
func _set_eye_y(h: float) -> void:
	if is_instance_valid(form_driver): return
	if not headset_view:
		# Leaning down to a pony in his arms (interactor.gd lean_down).
		camera.position.y = h - float(get_meta("lean_down", 0.0))
	elif not view_hold and view_origin != null:
		view_origin.position = Vector3(0.0, h, 0.0)


func uses_mouse_flight_controls() -> bool:
	return true

func _input(event: InputEvent) -> void:
	if wing_flight.reserves_mouse(event,self): get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	# Re-centring the headset works even while menus hold the controls.
	if headset_view and event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_HOME:
		recenter_view()
		get_viewport().set_input_as_handled()
		return
	if controls_locked: return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		if headset_view:
			# The headset gives pitch; the mouse only turns the body.
			_turn_seated(-mm.relative.x * mouse_sensitivity)
		else:
			rotate_y(-mm.relative.x * mouse_sensitivity)
			_pitch = clampf(_pitch - mm.relative.y * mouse_sensitivity * (-1.0 if invert_y else 1.0), -1.5, 1.5)
			# AnonPony sitting or lying: the head cannot turn past what her body allows.
			if is_instance_valid(form_driver) and form_driver.has_method("clamp_view"): form_driver.clamp_view()
			# AnonPony: place_view applies the pitch to the top-level camera.
			if form_driver == null: camera.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and get_tree().get_first_node_in_group("pause_menu") != null:
		# With the pause menu owning Escape, a click on the world takes the mouse back.
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed:
		# AnonPony on her hooves jumps on Space (player/pony_form.gd); the human jumps in _physics_process.
		if event.is_action_pressed("move_jump") and not event.is_echo() and not controls_locked and not flying \
				and is_instance_valid(form_driver) and form_driver.has_method("jump"):
			form_driver.jump()
		# Get up (Settings: "Get up / stay awake", Q by default) gets AnonPony up from sitting or
		# lying on the ground (seats: _physics_process).
		if InputMap.has_action("stand_up") and event.is_action_pressed("stand_up") and not event.is_echo():
			if seat == null and is_instance_valid(form_driver) and form_driver.has_method("stand_from_ground"):
				form_driver.stand_from_ground()
		match (event as InputEventKey).physical_keycode:
			KEY_CAPSLOCK:
				if not event.echo:
					companion_pace.toggle()
					get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				# The game's pause menu (world/ui/pause_menu.gd) owns Escape; labs keep the toggle.
				if get_tree().get_first_node_in_group("pause_menu") != null: return
				Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
					else Input.MOUSE_MODE_CAPTURED)
			KEY_F:
				# A pegasus AnonPony takes off and lands with F (player/pony_form.gd); dev
				# 2026-10-01: "change debug fly to \\".
				if not event.is_echo() and not controls_locked and is_instance_valid(form_driver) and form_driver.has_method("toggle_flight"):
					form_driver.toggle_flight()
				elif not event.is_echo() and not controls_locked:
					toggle_wing_flight()
			KEY_BACKSLASH:
				if not preload("res://world/dev_tools.gd").enabled(): return  # debug fly: developer builds only
				if is_instance_valid(seat): stand_up()
				if is_instance_valid(form_driver) and form_driver._piloting(): form_driver.avatar.flight.cancel()
				elif wing_flight.active: wing_flight.finish()
				# Shift+\ flies through walls and ground (noclip, dev 2026-10-27: stuck under the floor).
				var through := (event as InputEventKey).shift_pressed
				if flying and noclip != through: noclip = through
				else:
					flying = not flying
					noclip = flying and through
			KEY_Z, KEY_X:
				# AnonPony: Z sits down on the ground, X lies down; again (or Space, or walking) stands.
				if (event as InputEventKey).physical_keycode == KEY_X and not flying:
					if preload("res://world/relationships/shared_nap_grass.gd").toggle(self, camera): return
				if not flying and is_instance_valid(form_driver) and form_driver.has_method("toggle_ground_posture"):
					form_driver.toggle_ground_posture("sit" if (event as InputEventKey).physical_keycode == KEY_Z else "lie_down")
				print("[player] fly: ", flying)
			KEY_P:
				# Camera position, not the body origin -- this is fed straight to
				# the capture harness's --at, which places a camera.
				print("[player] --at %.1f,%.1f,%.1f --dir %.4f,%.4f,%.4f" % [
					camera.global_position.x, camera.global_position.y,
					camera.global_position.z,
					-camera.global_transform.basis.z.x,
					-camera.global_transform.basis.z.y,
					-camera.global_transform.basis.z.z])


## Seated mouse turning follows the VR comfort settings: smooth, or snap in vr/snap_angle steps
## once the mouse has travelled that far.
var _snap_travel := 0.0
func _turn_seated(angle: float) -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings == null or str(settings.get_value("vr/turn_mode")) != "snap":
		rotate_y(angle)
		return
	var step := deg_to_rad(float(settings.get_value("vr/snap_angle")))
	if step <= 0.001:
		rotate_y(angle)
		return
	_snap_travel += angle
	if absf(_snap_travel) >= step:
		var steps := int(_snap_travel / step)
		rotate_y(steps * step)
		_snap_travel -= steps * step


## Sitting (dev 2026-09-26): E on a seat (world/life/seat.gd, a furniture seat or a town bench).
## Hips on the seat, eyes 78 cm above it, facing the way the seat faces. Walking, jumping or E
## again stands you up in front of it.
const SEATED_EYE := 0.78
var seat: Node3D
var _seated_eye := 0.0
var _seat_return := Vector3.ZERO
var _couch_rest: Node
var _rest_held := false
var _q_held := false
const SEAT_EXIT = preload("res://world/life/couch/exit_space.gd")

func sit_on(target: Node3D) -> bool:
	if target == null or flying or wing_flight.active or controls_locked: return false
	var occupant: Variant = (target.get_meta("occupant") if target.has_meta("occupant") else null)
	if is_instance_valid(occupant) and occupant != self: return false
	if global_position.distance_to(target.global_position) > 3.0: return false
	var seating: Node = get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating.player_seat_accessible(target, self): return false
	if is_instance_valid(seat):
		stand_up()
		if is_instance_valid(seat): return false
	_seat_return = global_position
	seat = target
	seat.set_meta("occupant", self)
	var forward := -target.global_basis.z
	forward.y = 0.0
	rotation.y = atan2(-forward.x, -forward.z)
	global_position = target.global_position
	velocity = Vector3.ZERO
	($Collision as CollisionShape3D).disabled = true
	_seated_eye = SEATED_EYE * height_scale()
	_rest_held = Input.is_key_pressed(KEY_CTRL)
	preload("res://world/audio/interaction_sounds.gd").play_at(self, "prop_rest")
	return true

func _finish_couch_rest() -> void:
	if is_instance_valid(_couch_rest): _couch_rest.finish()
	_couch_rest = null

func toggle_couch_sleep() -> bool:
	if controls_locked or not is_instance_valid(seat): return false
	# AnonPony lies down on the seat itself (lie down <-> sit).
	if is_instance_valid(form_driver): return bool(form_driver.toggle_rest())
	if is_instance_valid(_couch_rest):
		_couch_rest.wake()
		return true
	var couch: Variant = (seat.get_meta("couch") if seat.has_meta("couch") else null)
	if not is_instance_valid(couch): return false
	# Settle first to the ordinary seated eye height, so the rest has a stable start.
	_set_eye_y(SEATED_EYE * height_scale())
	_eye_height = SEATED_EYE * height_scale()
	_couch_rest = couch.begin_player(self, seat, camera)
	return _couch_rest != null

## Q (dev 2026-10-22: "q should FORCE dismount no matter what"): stand up even when no exit
## passes the usual checks (a pony, a cuddle, a lock): the normal exit if there is one, else where
## you were before sitting, else a step in front of the seat. Collision always comes back on.
func force_stand_up() -> void:
	if seat == null: return
	var old: Variant = seat
	if not is_instance_valid(old): old = null
	for meta in ["shared_nap_surface", "couch_sleeping", "shared_rest_sleeping", "kiss_hold"]:
		if has_meta(meta): remove_meta(meta)
	stand_up()
	if seat == null: return
	var col := $Collision as CollisionShape3D
	var target := _seat_return if _seat_return.is_finite() and _seat_return != Vector3.ZERO else Vector3.INF
	if not target.is_finite() and old != null:
		target = (old as Node3D).global_position - (old as Node3D).global_basis.z.normalized() * 1.0
	if not target.is_finite(): target = global_position
	_finish_couch_rest()
	seat = null
	if old != null and (old.get_meta("occupant") if old.has_meta("occupant") else null) == self: old.remove_meta("occupant")
	global_position = target + Vector3.UP * 0.1
	col.disabled = false
	velocity = Vector3.ZERO

func stand_up() -> void:
	var old: Variant = seat
	if not is_instance_valid(old): old = null
	var col := $Collision as CollisionShape3D
	var capsule := col.shape as CapsuleShape3D
	var exit := SEAT_EXIT.find_exit(self, old, _seat_return, _stand_capsule_height, capsule.radius)
	if not exit.is_finite(): return
	_finish_couch_rest()
	seat = null
	if is_instance_valid(old) and (old.get_meta("occupant") if old.has_meta("occupant") else null) == self: old.remove_meta("occupant")
	global_position = exit
	col.disabled = false
	velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if not wing_flight.active and not wing_flight.resume_pending and wing_flight.charge < wing_flight.CAPACITY: wing_flight.recover(delta)
	var pony := is_instance_valid(form_driver)
	if knockdown.step(self,delta,Input.is_action_just_pressed("move_jump")):
		if pony: _drive(delta, Vector2.ZERO, false, false)
		return
	if seat != null:
		if not is_instance_valid(seat):
			stand_up()
		else:
			if not is_instance_valid(_couch_rest): global_position = seat.global_position
			velocity = Vector3.ZERO
			var rest_pressed := Input.is_key_pressed(KEY_CTRL)
			if rest_pressed and not _rest_held and not controls_locked: toggle_couch_sleep()
			_rest_held = rest_pressed
			var stick := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
			var lying: bool = bool(form_driver.is_lying()) if pony else (is_instance_valid(_couch_rest) and float(_couch_rest.amount) >= 0.99)
			# Lying down: WASD shifts you along the bed (W toward the foot) (dev 2026-09-29). Q gets you up
			# from any seat, bed or nap, always; Space never does, Ctrl lies down / sits up (dev 2026-10-22).
			if lying and not controls_locked and not pony: _couch_rest.shift(Vector2(stick.x, -stick.y), delta)
			var wants_up := not controls_locked and not lying and stick.length() > 0.5
			if has_meta("shared_nap_surface") and not controls_locked and stick.length() > .5: wants_up = true
			if lying and not controls_locked:
				if Input.is_action_pressed("move_jump"):
					_space_hold += delta
					if _space_hold >= SLEEP_HOLD and not _slept_hold:
						_slept_hold = true
						var sleeper: Node = get_tree().get_first_node_in_group("player_sleep")
						if sleeper != null: sleeper.sleep()
				else:
					_space_hold = 0.0; _slept_hold = false
			# Typing (the chat box, the game board's talk line) is not getting up: the key is a
			# physical one, so on AZERTY a message with an "a" in it stood Anon up (dev 2026-10-26).
			var focus := get_viewport().gui_get_focus_owner()
			var typing := focus is LineEdit or focus is TextEdit
			var q_pressed := not typing and InputMap.has_action("stand_up") and Input.is_action_pressed("stand_up")
			# Q in the wake picker means "stay awake" (world/life/wake_picker.gd), not "get up".
			var force_up := q_pressed and not _q_held and not has_meta("sleep_picking")
			_q_held = q_pressed
			if force_up:
				force_stand_up()
				if pony: _drive(delta, Vector2.ZERO, false, false)
				return
			if not pony and not is_instance_valid(_couch_rest):
				_eye_height = lerpf(_eye_height, _seated_eye, minf(1.0, CROUCH_LERP * delta))
				_set_eye_y(_eye_height)
			if wants_up: stand_up()
			if pony: _drive(delta, Vector2.ZERO, false, false)
			return
	# A deep kiss holds him where he stands (pony_kisser.gd kiss_hold); looking still works.
	var input := Vector2.ZERO if controls_locked or has_meta("kiss_hold") or has_meta("lay_hold") else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if pony:
		_pony_step(delta, input)
		return
	if wing_flight.resume_pending:
		if wing_sandals_equipped: velocity = wing_flight.resume(); _wing_air_time = 0.0
		else: wing_flight.resume_pending = false
	var dir := (transform.basis * Vector3(input.x, 0, input.y)).normalized()
	var sprinting := not controls_locked and Input.is_action_pressed("move_sprint")
	swimming.sample(get_world_3d().direct_space_state, global_position, _eye_height, delta, not flying)
	if not flying and not controls_locked and swimming.bank_exit(self,global_position,_eye_height,dir,Input.is_action_pressed("move_jump"),delta):
		return
	if flying or controls_locked: swimming.climbing = false

	if flying:
		_fly(input, sprinting)
		return
	if wing_flight.active:
		wing_flight.bank_input = wing_flight.bank_buttons(self)
		_wing_air_time += delta
		velocity = wing_flight.step(velocity, camera.global_basis, input,
			not controls_locked and Input.is_action_pressed("move_jump"), sprinting,
			not controls_locked and Input.is_key_pressed(KEY_CTRL), delta)
		move_and_slide()
		if (_wing_air_time > 0.6 and is_on_floor() and velocity.y <= 0.0) or swimming.active: wing_flight.finish()
		_update_crouch(delta)
		_bob_offset = 0.0; _set_eye_y(_eye_height)
		return

	# Ctrl crouches on foot and descends while flying, so one key covers the
	# "go down" intent in both modes.
	crouching = not swimming.active and not controls_locked and Input.is_key_pressed(KEY_CTRL)

	if swimming.active:
		velocity.y = swimming.vertical(velocity.y, global_position.y, _eye_height, not controls_locked and Input.is_action_pressed("move_jump"), delta)
	elif not is_on_floor():
		velocity.y -= _gravity * delta
	elif not controls_locked and Input.is_action_just_pressed("move_jump") and not crouching:
		velocity.y = jump_velocity

	var strolling := _walking() and not sprinting
	var speed := crouch_speed if crouching else (sprint_speed if sprinting else (stroll_speed if strolling else walk_speed))
	if companion_pace.enabled and not crouching and not strolling: speed = companion_pace.speed(self, delta)
	if swimming.active: speed = swimming.SPEED
	if dir != Vector3.ZERO:
		velocity.x = dir.x * speed + drunk_drift.x
		velocity.z = dir.z * speed + drunk_drift.z
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 4.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 4.0 * delta)
	var attempted := velocity
	var stepped := false
	if swimming.active or controls_locked or dir == Vector3.ZERO: _ground_step.reset()
	else: stepped = _ground_step.move(self, delta)
	if not stepped: move_and_slide()
	preload("res://player/pony_body_contact.gd").transfer(self, attempted, delta)

	_update_crouch(delta)
	_update_bob(delta, speed)
	_set_eye_y(_eye_height + _bob_offset)


func set_wing_sandals_equipped(value: bool) -> void:
	wing_sandals_equipped = value
	if not value and not is_instance_valid(form_driver): wing_flight.finish()

func toggle_wing_flight() -> bool:
	if controls_locked or flying or is_instance_valid(seat) or is_instance_valid(form_driver): return false
	if wing_flight.active: wing_flight.landing = true; return true
	if not wing_sandals_equipped or swimming.active or wing_flight.charge < 1.0: return false
	velocity = wing_flight.begin(velocity, -camera.global_basis.z)
	_wing_air_time = 0.0
	return wing_flight.active

func _fly(input: Vector2, sprinting: bool) -> void:
	var speed := fly_speed * (3.0 if sprinting else 1.0)
	var vertical := 0.0
	if not controls_locked and Input.is_action_pressed("move_jump"):
		vertical += 1.0
	if not controls_locked and Input.is_key_pressed(KEY_CTRL):
		vertical -= 1.0
	# Fly follows gaze so surveying a 1 km map does not need a separate
	# altitude control for every hill.
	var fwd := -camera.global_transform.basis.z * -input.y
	var right := camera.global_transform.basis.x * input.x
	velocity = (fwd + right).normalized() * speed + Vector3.UP * vertical * speed
	if noclip: global_position += velocity * get_physics_process_delta_time()
	else: move_and_slide()


## AnonPony on foot: the pony walks itself (player/pony_form.gd drive) and this rig follows it,
## so no ground movement, swimming, jump, crouch or bob here. Debug fly still flies the rig
## (the pony waits hidden). Exactly one drive() per tick, with no input while flying.
func _pony_step(delta: float, input: Vector2) -> void:
	var sprinting := not controls_locked and Input.is_action_pressed("move_sprint")
	if flying:
		_fly(input, sprinting)
		_drive(delta, Vector2.ZERO, false, false)
		return
	var walking := _walking() and not sprinting
	var unheld := not controls_locked and not has_meta("kiss_hold")
	_drive(delta, input, unheld and sprinting, unheld and (Input.is_key_pressed(KEY_CTRL) or walking))

## The walk key: a short tap flips walk_toggled; while held it walks either way.
func _walking() -> bool:
	var down := not controls_locked and InputMap.has_action("move_walk") and Input.is_action_pressed("move_walk")
	var now := Time.get_ticks_msec() * .001
	if down and not _walk_key_down: _walk_key_since = now
	elif not down and _walk_key_down and now - _walk_key_since < WALK_TAP: walk_toggled = not walk_toggled
	_walk_key_down = down
	# Sprinting ends a toggled walk.
	if not controls_locked and Input.is_action_pressed("move_sprint"): walk_toggled = false
	return walk_toggled or down


func _drive(delta: float, move: Vector2, sprint: bool, slow: bool) -> void:
	if is_instance_valid(form_driver): form_driver.drive(delta, move, sprint, slow)


## Eye height eases rather than snapping, and the collision capsule shrinks with
## it so crouching actually fits under things.
func _update_crouch(delta: float) -> void:
	var target := _stand_eye * (CROUCH_RATIO if crouching else 1.0)
	_eye_height = lerpf(_eye_height, target, minf(1.0, CROUCH_LERP * delta))

	var col := $Collision as CollisionShape3D
	var capsule := col.shape as CapsuleShape3D
	var target_h := _stand_capsule_height * (CROUCH_RATIO if crouching else 1.0)
	capsule.height = lerpf(capsule.height, target_h, minf(1.0, CROUCH_LERP * delta))
	col.position.y = capsule.height * 0.5


## Vertical-only head bob, driven by distance travelled rather than by time, so
## it stays in step with the stride at any speed and stops dead when you do.
func _update_bob(delta: float, speed: float) -> void:
	if not bob_enabled:
		_bob_offset = 0.0
		return

	var ground_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and not swimming.active and ground_speed > 0.1:
		_bob_phase += delta * bob_frequency * ground_speed
		var amp := bob_amplitude
		if speed >= sprint_speed:
			amp *= bob_sprint_scale
		if crouching:
			amp *= 0.5
		# abs(sin) gives two dips per cycle -- one per footfall -- instead of the
		# floaty single rise of a plain sine.
		_bob_offset = lerpf(_bob_offset, -absf(sin(_bob_phase)) * amp, 12.0 * delta)
	else:
		_bob_offset = lerpf(_bob_offset, 0.0, 8.0 * delta)


# ------------------------------------------------------------------ form driver (AnonPony)
## Pony mode on: the desktop camera leaves the rig (top level, not interpolated) and is placed
## only through place_view; no bob. Seated keeps its anchor, now placed by the driver too.
func set_form_driver(driver: Node) -> void:
	form_driver = driver
	_bob_offset = 0.0
	crouching = false
	_apply_settings()
	if driver == null:
		if not headset_view:
			camera.top_level = false
			camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
			camera.transform = Transform3D(Basis.from_euler(Vector3(_pitch, 0.0, 0.0)), Vector3(0.0, _eye_height, 0.0))
			camera.reset_physics_interpolation()
		return
	if not headset_view:
		camera.top_level = true
		camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	place_view(global_position + Vector3.UP * eye_height())


## Resizes the rig capsule (AnonPony: pony-sized), keeping doors' and seat exits' checks honest.
func set_body_capsule(radius: float, height: float) -> void:
	var col := $Collision as CollisionShape3D
	# Duplicated so the .tscn's shared sub-resource is not mutated in place.
	var capsule := (col.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	capsule.radius = maxf(0.05, radius)
	capsule.height = maxf(capsule.radius * 2.0, height)
	col.shape = capsule
	col.position.y = capsule.height * 0.5
	_stand_capsule_height = capsule.height


## Standing eye above the feet: the pony's when there is one, else the rig's.
func eye_height() -> float:
	if is_instance_valid(form_driver) and form_driver.has_method("eye_height"): return float(form_driver.eye_height())
	return _stand_eye


## The form driver's eye placement. Desktop: the whole camera transform, yaw from the rig and
## pitch from the mouse. Seated: the anchor at the eye with the rig's yaw; the headset adds the
## head pose on top of the origin.
func place_view(eye_world: Vector3) -> void:
	if view_hold or not eye_world.is_finite(): return
	if not headset_view:
		camera.global_transform = Transform3D(Basis.from_euler(Vector3(_pitch, rotation.y, 0.0)), eye_world)
	elif view_anchor != null and view_origin != null:
		view_anchor.global_transform = Transform3D(Basis(Vector3.UP, rotation.y), eye_world)
		view_origin.position = Vector3.ZERO


func view_is_held() -> bool:
	return view_hold or knockdown.active


## The body that really moves on foot: the pony, else this rig (pocket walls, story placement).
func motion_body() -> CharacterBody3D:
	if is_instance_valid(form_driver):
		var avatar: Variant = form_driver.get("avatar")
		if is_instance_valid(avatar) and avatar is CharacterBody3D: return avatar as CharacterBody3D
	return self


## Seated: the tracked head becomes the origin (facing kept level), so the origin's height is
## the eye height. 0.5 s after start, on Home, and when the runtime recentres.
func recenter_view() -> void:
	if not headset_view or not is_inside_tree(): return
	XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, false)


# ------------------------------------------------------------------ seated VR view
## Human seated: the anchor carries only the interpolation offset, so the origin sits on the
## interpolated body and a rig moved by other code carries the view at once. AnonPony: the form
## driver places the anchor (place_view) before this runs.
func _process(_delta: float) -> void:
	_sanitize_head()
	if not is_instance_valid(form_driver) and view_anchor != null:
		view_anchor.transform = Transform3D(Basis.IDENTITY, global_transform.affine_inverse() * get_global_transform_interpolated().origin)


## The runtime can hand Godot a non-finite head pose for a moment (player/xr_grounded_body.gd):
## hold the last finite one, before anything reads the camera.
var _last_head := Transform3D.IDENTITY
var _has_head := false
var _rejected_heads := 0

func _sanitize_head() -> void:
	if camera == null: return
	if camera.transform.is_finite():
		_last_head = camera.transform
		_has_head = true
	elif _has_head:
		camera.transform = _last_head
		_rejected_heads += 1
		if _rejected_heads <= 5 or _rejected_heads % 500 == 0:
			print("[seated] non-finite head pose held at last good value (%d rejected)" % _rejected_heads)


## Connected after XRCamera3D's own handler, so a bad pose is undone on the same emission.
func _watch_head() -> void:
	var tracker := XRServer.get_tracker("head")
	if tracker == null or not tracker.has_signal("pose_changed"): return
	if not tracker.is_connected("pose_changed", _on_head_pose): tracker.connect("pose_changed", _on_head_pose)


func _on_tracker_added(_tracker_name: StringName, _type: int) -> void:
	_watch_head()


func _on_head_pose(_pose: XRPose) -> void:
	_sanitize_head()
