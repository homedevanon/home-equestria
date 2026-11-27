extends Node
## One flight of Derpy's post (letter_courier.gd, docs/LETTERS_PLAN_2026_10_29.md section 10).
##
## "send": Derpy swoops from out of sight to Anon's letter hand, takes the letter from it in her
## mouth, says a cheerful line and flies off toward the recipient's house. "give": the reverse, for
## a reply while he has no home mailbox: she brings it in her mouth and hands it to his free hand.
## "drop" (mailbox_swoop.gd, which extends this): she brings his mail to his own mailbox.
##
## The courier Derpy is a fresh derpy_hooves.tscn (child of this node, not a resident, never
## registered with the director): she spawns 25 m behind and 15 m above him outside the view,
## passes over his head, turns in front of him and comes in facing him, so her body never covers
## his eyes. She climbs away after the grab and despawns past 80 m or 12 s. The town's own Derpy
## (town = true) takes off from where she is under navigator owner "courier:derpy_hooves", lands
## at the recipient's front door (pony_flight.gd arrive) and then gets her day back.
##
## Motion: real ponies fly in pony_flight.gd's "piloted" state with the Pilot model below in place
## of the player's wing model, so the flight clips (hover/fly/glide, rotations only, inside the
## joint limits) and the 60 Hz pony physics tick move her; this node only says where. Collisions
## are off while she flies a scripted path (restored before any landing). A test double without
## `flight` is moved by step() directly. The grab reads the held item's position and never moves
## the hand.
const PONY_SNACK := preload("res://world/life/day/pony_snack.gd")
const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")
const LETTER := "res://world/props/ponyville_kit/activity/letter.scn"
const OWNER := "courier:derpy_hooves"
const SPAWN_BACK := 25.0
const SPAWN_UP := 15.0
const TOP_SPEED := 14.0
const ACCEL := 20.0
const BRAKE := 9.0
## Metres in front of his hand where she turns to come in facing him.
const FRONT := 2.2
const GRAB_REACH := 0.12
## On the last leg this close for this long counts as reached (a jittering hand).
const GRAB_SLACK := 0.3
const GRAB_SETTLE := 1.2
const HOLD_SECONDS := 0.45
const APPROACH_LIMIT := 9.0
const TOWN_APPROACH_LIMIT := 45.0
const COURIER_LIFE := 12.0
const DESPAWN_DISTANCE := 80.0
const TOWN_DELIVERY_LIMIT := 120.0
const LANDING_LIMIT := 20.0
const CRUISE_CLEARANCE := 16.0
const SPEECH_SECONDS := 3.5
## A hand-over that found his bag full: she keeps the letter and tries again later.
const NO_ROOM := "Oh! Your bag's all full. I'll come back later!"
## Mouth point in her body frame when the head skeleton is unavailable (test doubles).
const MOUTH := Vector3(0.0, 0.95, -0.55)

## Stand-in for player/wing_flight.gd in pony_flight.gd's piloted state: returns the velocity this
## sortie steers, and advances the wingbeat phase the fly/hover clips are seeked to.
class Pilot extends RefCounted:
	var steer: Callable
	var scale := 1.0
	var initial := Vector3.ZERO
	var charge := 8.0
	var landing := false
	var beating := true
	var phase := 0.0
	var period := 0.42
	var bank_angle := 0.0
	var bank_input := 0.0
	func begin(_velocity: Vector3, _forward: Vector3) -> Vector3: return initial / scale
	func resume() -> Vector3: return initial / scale
	func finish() -> void: beating = false
	func step(velocity: Vector3, _view: Basis, _input: Vector2, _flap: bool, _boost: bool, _retract: bool, delta: float) -> Vector3:
		var wanted: Vector3 = steer.call(velocity * scale, delta) if steer.is_valid() else velocity * scale
		if beating: phase = fposmod(phase + delta / period, 1.0)
		return wanted / scale

var kind := "send"
var letter_id := ""
var town := false
var body: Node3D
var courier: Node
## () -> Vector3: where the letter is in his hand now; INF once it is gone.
var hand: Callable
## () -> Transform3D: his eyes.
var view: Callable
var destination := Vector3.INF
## send: the letter in his hand (PAPER's held item node).
var item: Node3D
var line := ""
var phase := "approach"
var grabbed := false
var delivered := false
var _route: Array[Vector3] = []
var _leg_from := Vector3.INF
var _age := 0.0
var _phase_age := 0.0
var _grab_age := 0.0
var _settle := 0.0
var _velocity := Vector3.ZERO
var _pilot: Pilot
var _carried: Node3D
var _speech: Node3D
var _speech_left := 0.0
var _near_front := false
var _layers := Vector2i(-1, -1)
var _nav: Node
var _skeleton: Skeleton3D
var _bone := -2
var _ended := false
var _letter_from := Transform3D.IDENTITY

## The spawn point for a courier: behind and above his eyes, outside `in_view` (Callable(Vector3)
## -> bool); turned further round when the plain one would be seen.
static func spawn_point(eyes: Transform3D, in_view: Callable) -> Vector3:
	var back := eyes.basis.z; back.y = 0.0
	back = back.normalized() if back.length_squared() > 0.0001 else Vector3.BACK
	for turn: float in [0.0, 0.7, -0.7, 1.4, -1.4, 2.1, -2.1]:
		var at: Vector3 = eyes.origin + back.rotated(Vector3.UP, turn) * SPAWN_BACK + Vector3.UP * SPAWN_UP
		var seen := false
		for offset: Vector3 in [Vector3.ZERO, Vector3.UP * 1.5, Vector3.DOWN * 1.5, Vector3.LEFT * 1.5, Vector3.RIGHT * 1.5]:
			if bool(in_view.call(at + offset)): seen = true; break
		if not seen: return at
	return eyes.origin + back * SPAWN_BACK * 0.4 + Vector3.UP * SPAWN_UP * 2.5

## A courier Derpy spawned at `spawn` (transform set before add_child: Jolt keeps the scale a body
## enters with).
func begin_courier(spawned: Node3D, spawn: Vector3) -> bool:
	body = spawned
	var eyes: Transform3D = view.call()
	var toward := eyes.origin - spawn; toward.y = 0.0
	body.transform = Transform3D(Basis(Vector3.UP, atan2(-toward.x, -toward.z)), spawn)
	add_child(body)
	if body.is_in_group("ai_characters"): body.remove_from_group("ai_characters")
	_quiet_touch()
	_set_layers(true)
	var over: Vector3 = eyes.origin + _flat(-eyes.basis.z) * 1.5 + Vector3.UP * 3.5
	_route = [over]
	_velocity = (over - spawn).normalized() * TOP_SPEED * 0.7
	return _take_off()

## The town's Derpy, loaded, near and free (letter_courier.gd checked): she flies here herself.
func begin_town(actor: Node3D) -> bool:
	body = actor
	town = true
	_nav = actor.get_node_or_null("Navigator")
	if _nav != null:
		if _nav.has_method("reserve"): _nav.reserve(OWNER, ["courier:"])
		_nav.set("command_owner", OWNER)
		if _nav.has_method("stay"): _nav.stay()
	var eyes: Transform3D = view.call()
	var start := actor.global_position
	var toward := _flat(eyes.origin - start)
	var rise := start + Vector3.UP * 10.0 + toward * 3.0
	rise.y = maxf(rise.y, _ground(rise) + 10.0)
	var front := _front(eyes)
	var high := front + Vector3.UP * 8.0
	high.y = maxf(high.y, _ground(high) + 8.0)
	_route = [rise, high]
	_velocity = Vector3.UP * 3.0
	_set_layers(true)
	if _take_off(): return true
	_set_layers(false)
	_release_nav()
	return false

func _take_off() -> bool:
	_leg_from = body.global_position
	if body.get("flight") == null and body.has_method("_ensure_flight") and body.has_method("request_flight"):
		body.call("_ensure_flight")
	var flight: Variant = body.get("flight")
	if flight == null:
		set_physics_process(true)   # a test double: step() moves it
		return true
	_pilot = Pilot.new()
	_pilot.steer = _steer
	_pilot.scale = maxf(float(body.get("body_scale")), 0.01)
	_pilot.initial = _velocity
	return bool(flight.call("pilot", _pilot))

## Courier bodies never touch hands or ponies: no petting hulls, no boop.
func _quiet_touch() -> void:
	for part: String in ["touch_body", "boop_node", "_flank"]:
		var node: Variant = body.get(part)
		if node is Node: (node as Node).process_mode = Node.PROCESS_MODE_DISABLED

## Off (true) while she flies a scripted path; back exactly as they were (false).
func _set_layers(off: bool) -> void:
	if not body is CollisionObject3D: return
	var solid := body as CollisionObject3D
	if off:
		if _layers.x < 0: _layers = Vector2i(solid.collision_layer, solid.collision_mask)
		solid.collision_layer = 0; solid.collision_mask = 0
	elif _layers.x >= 0:
		solid.collision_layer = _layers.x; solid.collision_mask = _layers.y
		_layers = Vector2i(-1, -1)

func _release_nav() -> void:
	if not is_instance_valid(_nav): return
	if _nav.has_method("release_reservation"): _nav.release_reservation(OWNER)
	if str(_nav.get("command_owner")) == OWNER: _nav.set("command_owner", "")
	_nav = null

func _flat(v: Vector3) -> Vector3:
	v.y = 0.0
	return v.normalized() if v.length_squared() > 0.0001 else Vector3.FORWARD

func _ground(at: Vector3) -> float:
	if is_instance_valid(WorldTerrain.instance):
		var height: float = WorldTerrain.instance.height_at(at)
		if is_finite(height): return height
	return at.y - 10.0

## Where she turns in, in front of his letter hand at about its height.
func _front(eyes: Transform3D) -> Vector3:
	var at: Vector3 = hand.call()
	if not at.is_finite(): at = eyes.origin
	return at + _flat(-eyes.basis.z) * FRONT + Vector3.UP * 0.5

func mouth_point() -> Vector3:
	if _bone == -2:
		_bone = -1
		var boop: Variant = body.get("boop_node")
		var skeleton: Variant = (boop as Object).get("head_skeleton") if boop is Object else null
		if skeleton is Skeleton3D:
			_skeleton = skeleton
			_bone = _skeleton.find_bone("mFaceLipUpperCenter")
			if _bone < 0: _bone = _skeleton.find_bone("mFaceNoseBase")
	if _bone >= 0 and is_instance_valid(_skeleton):
		return (_skeleton.global_transform * _skeleton.get_bone_global_pose(_bone)).origin
	return body.global_transform * MOUTH

## Velocity toward `goal`, braking to arrive; the last half metre is matched exactly. `final`
## (mouth to hand) eases in slower still, so the turn toward her motion (pony_flight.gd yaw follows
## a flat speed over 0.3 m/s) settles before the mouth arrives.
func _seek(goal: Vector3, delta: float, top := TOP_SPEED, final := false) -> Vector3:
	var offset := goal - body.global_position
	var distance := offset.length()
	if distance < 0.5:
		var exact := offset / maxf(delta, 0.001)
		_velocity = exact.limit_length(clampf(distance * 3.0, 0.2, 2.5) if final else 2.5)
		return _velocity
	var speed := minf(top, sqrt(2.0 * BRAKE * distance))
	_velocity = _velocity.move_toward(offset / distance * speed, ACCEL * delta)
	return _velocity

## The next fixed waypoint is passed within `reach` or once she is beyond it along her leg.
func _passed(goal: Vector3, reach: float) -> bool:
	var here := body.global_position
	if here.distance_to(goal) < reach: return true
	return _leg_from.is_finite() and _velocity.length() > 3.0 and (here - goal).dot(goal - _leg_from) > 0.0

func _next_leg() -> void:
	_route.pop_front()
	_leg_from = body.global_position

## Called from the pony's physics tick (Pilot.step) or step(): the velocity she flies this tick.
func _steer(_current: Vector3, delta: float) -> Vector3:
	if _ended or not is_instance_valid(body): return Vector3.ZERO
	_age += delta
	_phase_age += delta
	if grabbed: _grab_age += delta
	var eyes: Transform3D = view.call()
	match phase:
		"approach":
			var at: Vector3 = hand.call()
			if not at.is_finite(): _abort(); return _velocity
			if not _route.is_empty():
				var goal: Vector3 = _route[0]
				if _passed(goal, 2.0): _next_leg()
				_beat(_seek(goal, delta))
				return _velocity
			if not _near_front:
				var front := _front(eyes)
				_near_front = body.global_position.distance_to(front) < 0.6
				_beat(_seek(front, delta, 8.0))
				return _velocity
			# Facing him, head first: the mouth's offset turned to that facing places her body, so the
			# goal does not swing with her current yaw.
			var face := eyes.origin - body.global_position
			var want := atan2(-face.x, -face.z) if Vector2(face.x, face.z).length_squared() > 0.01 else body.rotation.y
			body.rotation.y = lerp_angle(body.rotation.y, want, 1.0 - exp(-delta * 8.0))
			var reach := (mouth_point() - body.global_position).rotated(Vector3.UP, wrapf(want - body.rotation.y, -PI, PI))
			_seek(at - reach, delta, 4.0, true)
			_beat(_velocity, true)
			var gap := mouth_point().distance_to(at)
			_settle = _settle + delta if gap < GRAB_SLACK else 0.0
			if gap <= GRAB_REACH or _settle >= GRAB_SETTLE: _at_hand()
			return _velocity
		"hold":
			_velocity = Vector3.ZERO
			_beat(_velocity, true)
			if _phase_age >= HOLD_SECONDS: _leave(eyes, "away")
			return _velocity
		"away", "leave":
			if not _route.is_empty():
				if _passed(_route[0], 3.0): _next_leg()
			if _route.is_empty():
				if town and phase == "away": _set_phase("cruise")
				else: _route = [body.global_position + _flat(_velocity) * 40.0 + Vector3.UP * 6.0]
			if not _route.is_empty(): _beat(_seek(_route[0], delta))
			return _velocity
		"cruise":
			var high := destination + Vector3.UP * CRUISE_CLEARANCE
			var ahead := body.global_position + _flat(_velocity) * 15.0
			high.y = maxf(high.y, maxf(_ground(ahead), _ground(body.global_position)) + CRUISE_CLEARANCE)
			var flat := Vector2(destination.x - body.global_position.x, destination.z - body.global_position.z).length()
			if flat < 8.0: _set_phase("descend")
			_beat(_seek(high if flat >= 8.0 else destination + Vector3.UP * 1.6, delta))
			return _velocity
		"descend":
			var hover := destination + Vector3.UP * 1.6
			_beat(_seek(hover, delta, 5.0), true)
			if body.global_position.distance_to(hover) < 0.4 or _phase_age > 15.0: _arrive()
			return _velocity
		"landing":
			# Glide down where she is; the piloted path ends when she touches the floor.
			_velocity = _flat(_velocity) * 1.2 + Vector3.DOWN * 2.0
			_beat(_velocity)
			return _velocity
	return _velocity

## Wings: glide on a fast dive, beat otherwise.
func _beat(velocity: Vector3, hover := false) -> void:
	if _pilot == null: return
	_pilot.beating = hover or not (velocity.y < -2.5 and velocity.length() > 6.0)

func _set_phase(next: String) -> void:
	phase = next
	_phase_age = 0.0
	_leg_from = body.global_position if is_instance_valid(body) else Vector3.INF

func _at_hand() -> void:
	if kind == "send":
		if is_instance_valid(item): _letter_from = item.global_transform
		grabbed = true
		if courier != null: courier.call("_grabbed", self)
		_carry_letter()
	else:
		var handed := courier != null and bool(courier.call("_handed", self))
		if handed:
			grabbed = true
			_drop_carried()
		else:
			line = NO_ROOM
	if not line.is_empty(): say(line)
	_set_phase("hold")

## Away from his face first (up and back from him), then off toward the recipient.
func _leave(eyes: Transform3D, next: String) -> void:
	var here := body.global_position
	var away := _flat(destination - here) if destination.is_finite() else _flat(-eyes.basis.z)
	var from_him := _flat(here - eyes.origin)
	_route = [here + from_him * 2.0 + Vector3.UP * 3.0, here + away * 30.0 + Vector3.UP * 14.0]
	_route[1].y = maxf(_route[1].y, _ground(_route[1]) + CRUISE_CLEARANCE)
	_set_phase(next)

func _abort() -> void:
	if town:
		_land_here()
		return
	_leave(view.call(), "leave")

## The town Derpy over the recipient's door: collisions back, then pony_flight's own landing.
func _arrive() -> void:
	_set_layers(false)
	var flight: Variant = body.get("flight")
	if flight == null:
		_landed(); _end(); return
	flight.call("cancel")
	var spot: Vector3 = flight.call("landing_surface", destination)
	if spot.is_finite() and bool(flight.call("arrive", spot)):
		_pilot = null
		_set_phase("arriving")
		return
	_land_here()

## Pilot landing at the current spot (aborted swoop, no landing at the door, or the time limit).
func _land_here() -> void:
	_set_layers(false)
	if _pilot != null:
		_pilot.landing = true
		_set_phase("landing")
	else:
		var flight: Variant = body.get("flight")
		if flight != null and bool(flight.call("active")): _set_phase("arriving")
		else: _end()

func _landed() -> void:
	if delivered or not grabbed or kind != "send": return
	delivered = true
	if courier != null: courier.call("_landed", self)

## The letter in her mouth (pony_snack.gd carry), gliding in from where it was in his hand.
func _carry_letter() -> void:
	var scene := load(LETTER) as PackedScene
	if scene == null: return
	_carried = PONY_SNACK.hold(body, scene, Transform3D.IDENTITY)
	if is_instance_valid(_carried):
		_carried.set("carry_seconds", TOWN_DELIVERY_LIMIT + LANDING_LIMIT + 10.0 if town else COURIER_LIFE + 5.0)
		_carried.call("_process", 0.0)
		if kind == "send": _carried.call("glide_from", _carried.global_transform.affine_inverse() * _letter_from, 0.25)
		return
	# No head rig (a test double): the letter rides at the mouth point.
	var letter := scene.instantiate() as Node3D
	if letter == null: return
	body.add_child(letter)
	letter.position = MOUTH
	_carried = letter

func _drop_carried() -> void:
	if is_instance_valid(_carried): _carried.queue_free()
	_carried = null

## The cheerful line as her words over her head (overhead_dialogue.gd); no AI call.
func say(text: String) -> void:
	if is_instance_valid(_speech): _speech.queue_free()
	var speech: Node3D = OVERHEAD.new()
	var identity: Variant = body.get("identity")
	var speaker := str((identity as Resource).get("display_name")) if identity is Resource else "Derpy Hooves"
	speech.call("set_fallback_labels", null, null, speaker)
	speech.set("text", text)
	speech.set("caption_full", text)
	add_child(speech)
	var camera: Variant = courier.call("_camera") if courier != null else null
	speech.call("show_for", body, camera if camera is Node3D else null)
	_speech = speech
	_speech_left = SPEECH_SECONDS

## Test doubles fly here; real ponies fly in their own physics tick. Always: the watchdog.
func _physics_process(delta: float) -> void:
	step(delta)

func step(delta: float) -> void:
	if _ended: return
	if _speech_left > 0.0:
		_speech_left -= delta
		if _speech_left <= 0.0 and is_instance_valid(_speech): _speech.queue_free()
	if not is_instance_valid(body) or not body.is_inside_tree():
		_end(); return
	var flight: Variant = body.get("flight")
	if flight == null:
		if phase == "arriving": _end(); return
		var velocity := _steer(_velocity, delta)
		body.global_position += velocity * delta
		# Yaw as pony_flight.gd's piloted path turns her.
		var flat := Vector2(velocity.x, velocity.z)
		if flat.length() > 0.3: body.rotation.y = lerp_angle(body.rotation.y, atan2(-velocity.x, -velocity.z), 1.0 - exp(-delta * 10.0))
		if phase == "landing" and _phase_age > 0.5: _end(); return
	else:
		var flying: bool = flight.call("active")
		if phase == "arriving":
			# pony_flight.gd's own landing: no Pilot ticks count the time.
			_phase_age += delta; _grab_age += delta
			if not flying:
				_landed(); _end(); return
		elif not flying or str(flight.get("state")) != "piloted" or bool(body.get("_held")):
			# Grabbed, thrown or landed out from under the script: let her be.
			if bool(body.get("_held")) and flying: flight.call("cancel")
			_set_layers(false)
			_end(); return
		elif phase == "landing" and _phase_age > LANDING_LIMIT:
			flight.call("cancel"); _end(); return
	_watchdog()

func _watchdog() -> void:
	if phase == "approach" and _age > (TOWN_APPROACH_LIMIT if town else APPROACH_LIMIT):
		_abort()
	if not town and phase in ["away", "leave"]:
		var eyes: Transform3D = view.call()
		var far := body.global_position.distance_to(eyes.origin) > DESPAWN_DISTANCE
		if far or _grab_age > COURIER_LIFE or (not grabbed and _phase_age > COURIER_LIFE):
			_end()
	if town and grabbed and not delivered and _grab_age >= TOWN_DELIVERY_LIMIT:
		_landed()
		if phase in ["cruise", "away", "descend"]: _land_here()
	if town and phase == "arriving" and _phase_age > LANDING_LIMIT:
		# pony_flight.gd finishes the landing on its own; the errand is over.
		_landed(); _end()

## Ends the sortie: collisions and navigator back for the town Derpy, the courier despawns with
## this node.
func _end() -> void:
	if _ended: return
	_ended = true
	if town and is_instance_valid(body):
		var flight: Variant = body.get("flight")
		if flight != null and bool(flight.call("active")) and str(flight.get("state")) == "piloted": flight.call("cancel")
		_set_layers(false)
		_drop_carried()
	_release_nav()
	if is_instance_valid(_speech) and _speech_left > 0.0:
		# The line finishes over her head even as she leaves; the courier body goes with this node.
		if town: _speech.reparent(courier if courier != null else get_parent()); _free_later(_speech, _speech_left)
	if courier != null: courier.call("_sortie_done", self)
	queue_free()

func _free_later(node: Node, seconds: float) -> void:
	var tree := get_tree()
	if tree == null: node.queue_free(); return
	tree.create_timer(seconds).timeout.connect(func() -> void: if is_instance_valid(node): node.queue_free())

func _exit_tree() -> void:
	if not _ended and town and is_instance_valid(body):
		# Freed mid-errand (the courier node went): her steered flight ends too, or she would
		# drift on at the last speed with nopony steering.
		var flight: Variant = body.get("flight")
		if flight != null and bool(flight.call("active")) and str(flight.get("state")) == "piloted": flight.call("cancel")
		_set_layers(false)
		_drop_carried()
		_release_nav()
