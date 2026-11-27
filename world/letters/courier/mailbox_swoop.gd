extends "res://world/letters/courier/courier_swoop.gd"
## Derpy at Anon's own mailbox (letter_courier.gd starts these flights while he watches). A courier
## Derpy (a fresh derpy_hooves.tscn, as the other courier flights use) appears out of sight beyond
## the mailbox, flies over it, comes down in front of its open door facing it and reaches her mouth
## to the slot. The swoop underneath does the flying (pony_flight.gd piloted state, wingbeats, the
## letter in her mouth); this only says where to go.
## - "drop": she brings his mail, puts it in from her mouth, hovers a moment and flies off the way
##   she came. When `fumble` is set (one watched drop in five) she lets it go early: it flutters to
##   the ground before the door ("fumble_fall"), she says "Oops! My bad!", dips to pick it up in her
##   mouth ("fumble_dip"), and comes back to the slot to post it as normal.
## - "pickup": she collects his posted letters; the letter glides out of the box to her mouth and she
##   flies off toward the recipient (`destination`).
## If she never gets there, letter_courier.gd delivers or collects the letters the quiet way.

const DROP_APPROACH_LIMIT := 40.0
## Metres in front of the door where she stops before the last slow reach to the slot.
const STAND_OFF := 1.1
const DROP_SPAWN_BACK := 38.0
const DROP_SPAWN_UP := 18.0
## Pickup: seconds the letter takes to glide from the box to her mouth (player_mailbox.gd slide_out).
const PICK_SECONDS := 0.35
## The fumble: the letter lands FUMBLE_OUT metres out from the door in FUMBLE_FALL seconds with
## FUMBLE_SPIN radians of turn; she picks it up once her mouth is within FUMBLE_REACH of it. A fumble
## phase lasting FUMBLE_LIMIT seconds gives up (the letter then goes in quietly).
const FUMBLE_OUT := 0.35
const FUMBLE_FALL := 0.5
const FUMBLE_SPIN := 2.4
const FUMBLE_REACH := 0.25
const FUMBLE_LIMIT := 6.0
const OOPS := "Oops! My bad!"

## Every letter on this flight (letter_id is the first); all go in or out together.
var letter_ids: Array[String] = []
## Where the letters go in or out (just outside the open door), the door's outward direction and
## the ground under the box (world y).
var slot := Vector3.INF
var door_out := Vector3.FORWARD
var ground_y := 0.0
## Drop only: she drops the letter before the door once and picks it up again.
var fumble := false
var _in_front := false
var _fumbled := false
## The dropped letter on its way down and on the ground (child of this node), and its fall.
var _loose: Node3D
var _fall_from := Transform3D.IDENTITY
var _fall_to := Transform3D.IDENTITY


## Her spawn point: out of `camera`'s view, beyond the mailbox at `box` as seen from him and up
## high; `fallback_out` (the door's direction) when he stands on top of it.
static func spawn_beyond(box: Vector3, fallback_out: Vector3, camera: Camera3D) -> Vector3:
	var away := Vector3(box.x - camera.global_position.x, 0.0, box.z - camera.global_position.z)
	away = away.normalized() if away.length_squared() > 0.01 else fallback_out
	var first := Vector3.INF
	for turn: float in [0.0, 0.6, -0.6, 1.2, -1.2, 1.9, -1.9, 2.6, -2.6, PI]:
		var at := box + away.rotated(Vector3.UP, turn) * DROP_SPAWN_BACK + Vector3.UP * DROP_SPAWN_UP
		if not first.is_finite(): first = at
		if not camera.is_position_in_frustum(at): return at
	return first + Vector3.UP * 40.0


## Courier body at `spawn`, routed over the mailbox instead of over his head; with his mail in her
## mouth for a drop.
func begin_mailbox(spawned: Node3D, spawn: Vector3) -> bool:
	if not begin_courier(spawned, spawn): return false
	var above := slot + door_out * 3.0 + Vector3.UP * 6.0
	_route = [above]
	_velocity = (above - spawn).normalized() * TOP_SPEED * 0.7
	_leg_from = spawn
	if kind == "drop":
		_carry_letter()
		if is_instance_valid(_carried): _carried.set("carry_seconds", DROP_APPROACH_LIMIT + 20.0)
	destination = spawn
	return true


func _steer(current: Vector3, delta: float) -> Vector3:
	if kind not in ["drop", "pickup"] or phase not in ["approach", "hold", "fumble_fall", "fumble_dip"]: return super._steer(current, delta)
	if _ended or not is_instance_valid(body): return Vector3.ZERO
	if phase == "hold":
		# Pickup: the letter reaches her mouth as the glide out of the box ends.
		if kind == "pickup" and not is_instance_valid(_carried) and _phase_age >= PICK_SECONDS: _carry_letter()
		return super._steer(current, delta)
	_age += delta
	_phase_age += delta
	if phase == "fumble_fall": return _steer_fall(delta)
	if phase == "fumble_dip": return _steer_dip(delta)
	if not _route.is_empty():
		var goal: Vector3 = _route[0]
		if _passed(goal, 2.0): _next_leg()
		_beat(_seek(goal, delta, 10.0))
		return _velocity
	var front := slot + door_out * STAND_OFF + Vector3.UP * 0.25
	if not _in_front:
		_in_front = body.global_position.distance_to(front) < 0.6
		_beat(_seek(front, delta, 6.0), body.global_position.distance_to(front) < 4.0)
		return _velocity
	# Facing the box, head first: as the swoop reaches a hand, but toward the slot.
	_face_box(delta)
	_seek(slot - _mouth_reach(), delta, 3.0, true)
	_beat(_velocity, true)
	var gap := mouth_point().distance_to(slot)
	_settle = _settle + delta if gap < GRAB_SLACK else 0.0
	if gap <= GRAB_REACH or _settle >= GRAB_SETTLE: _at_slot()
	return _velocity


func _face_box(delta: float) -> void:
	var face := -door_out
	body.rotation.y = lerp_angle(body.rotation.y, atan2(-face.x, -face.z), 1.0 - exp(-delta * 8.0))

## Her mouth's offset from her body, turned to the facing she is settling on, so a goal for the mouth
## does not swing with her current yaw.
func _mouth_reach() -> Vector3:
	var face := -door_out
	var want := atan2(-face.x, -face.z)
	return (mouth_point() - body.global_position).rotated(Vector3.UP, wrapf(want - body.rotation.y, -PI, PI))


func _at_slot() -> void:
	if kind == "drop" and fumble and not _fumbled:
		_begin_fumble()
		return
	grabbed = true
	if kind == "pickup":
		if courier != null: courier.picked_from_mailbox(self, Transform3D(body.global_basis.orthonormalized(), mouth_point()))
	else:
		var from := _carried.global_transform if is_instance_valid(_carried) else Transform3D(Basis.IDENTITY, slot)
		_drop_carried()
		if courier != null: courier.dropped_in_mailbox(self, from)
	if not line.is_empty(): say(line)
	_set_phase("hold")


## The letter slips from her mouth at the slot: it flutters down before the door.
func _begin_fumble() -> void:
	_fumbled = true
	line = ""
	_fall_from = _carried.global_transform if is_instance_valid(_carried) else Transform3D(Basis.IDENTITY, mouth_point())
	_fall_from.basis = _fall_from.basis.orthonormalized()
	_drop_carried()
	var scene := load(LETTER) as PackedScene
	_loose = scene.instantiate() as Node3D if scene != null else null
	var land := slot + door_out * FUMBLE_OUT
	land.y = ground_y + 0.005
	var flat := Basis(Vector3.UP, atan2(-door_out.x, -door_out.z) + FUMBLE_SPIN)
	_fall_to = Transform3D(flat, land)
	if _loose != null:
		_loose.name = "DroppedLetter"
		_loose.transform = _fall_from
		add_child(_loose)
	say(OOPS)
	_set_phase("fumble_fall")

## Hovering while the letter falls (a little sideways flutter and a spin), then down after it.
func _steer_fall(delta: float) -> Vector3:
	_velocity = _velocity.move_toward(Vector3.ZERO, ACCEL * delta)
	_beat(_velocity, true)
	var t := clampf(_phase_age / FUMBLE_FALL, 0.0, 1.0)
	if is_instance_valid(_loose):
		var drop := ease(t, 1.6)
		var at := _fall_from.origin.lerp(_fall_to.origin, drop)
		var side := door_out.cross(Vector3.UP)
		at += side * sin(t * TAU) * 0.06 * (1.0 - t)
		var turn := Basis(Vector3.UP, (t - 1.0) * FUMBLE_SPIN)
		_loose.global_transform = Transform3D(turn * _fall_from.basis.slerp(_fall_to.basis, t), at)
	if t >= 1.0:
		if is_instance_valid(_loose): _loose.global_transform = _fall_to
		_set_phase("fumble_dip")
	elif _phase_age > FUMBLE_LIMIT:
		_abort()
	return _velocity

## Her mouth down to the letter on the ground; it goes back in her mouth and she returns to the slot.
func _steer_dip(delta: float) -> Vector3:
	var target := _fall_to.origin
	_face_box(delta)
	_seek(target - _mouth_reach(), delta, 2.5, true)
	_beat(_velocity, true)
	if mouth_point().distance_to(target) <= FUMBLE_REACH:
		if is_instance_valid(_loose): _loose.queue_free()
		_loose = null
		_carry_letter()
		if is_instance_valid(_carried): _carried.set("carry_seconds", DROP_APPROACH_LIMIT + 20.0)
		_in_front = false
		_settle = 0.0
		_set_phase("approach")
	elif _phase_age > FUMBLE_LIMIT:
		_abort()
	return _velocity


func _abort() -> void:
	if is_instance_valid(_loose): _loose.queue_free()
	_loose = null
	super._abort()


## After the hold (HOLD_SECONDS) she rises off and flies to `destination` (back where she came
## from, or the recipient for a pickup), and despawns once far from both him and the mailbox.
func _watchdog() -> void:
	if kind not in ["drop", "pickup"]:
		super._watchdog()
		return
	if phase in ["approach", "fumble_fall", "fumble_dip"] and _age > DROP_APPROACH_LIMIT: _abort()
	if phase in ["away", "leave"]:
		var eyes: Transform3D = view.call()
		var far := body.global_position.distance_to(eyes.origin) > DESPAWN_DISTANCE and body.global_position.distance_to(slot) > 40.0
		if far or _grab_age > COURIER_LIFE or (not grabbed and _phase_age > COURIER_LIFE): _end()
