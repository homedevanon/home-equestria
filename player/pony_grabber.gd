extends Node
## Lets the player's hands pick the locomotion mare up.
##
## Squeeze the grip with a hand near one of her chest grips and that hand
## latches to the grip point: the mare's carry solver is told to follow the
## hand, and the visible Anon hand is parked on her instead of on the
## controller, so the pickup reads as one contact instead of two things
## floating near each other. Both hands can hold her; letting go of one keeps
## the other; a fast final release throws her, a gentle release sets her down.
##
## Grip input comes from the XRController3D nodes (real controllers and the
## desktop simulator alike); tests drive it through set_grip_input().

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const SIDES := ["left", "right"]
## Either hand takes whichever chest grip is nearest, front or behind
## (dev, headset round 5: "grab her left with my right and be normal about it").
const GRIP_NAMES := ["left_chest", "right_chest"]
## Metres, per unit of body scale, that a chest grip can lie from its pony's origin at most (about
## 0.7 on a mare, more on a princess); only used to skip ponies that cannot be the nearest.
const GRIP_SPAN := 2.0
const SQUEES := [preload("res://world/audio/pony/squee_1.ogg"), preload("res://world/audio/pony/squee_2.ogg")]

## A hand this close to a grip point can take it.
@export var reach := 0.35
@export var grip_threshold := 0.5

## The pony currently targeted/held; picked from `ponies` by the nearest free grip.
var cuddle_input:Node
var pony: Node
## Every pony the hands may take (six in town); setup() adds the first, add_pony() the rest.
var ponies: Array = []
var _hands: Dictionary = {}
var _controllers: Dictionary = {}
var _camera: Node3D
var _anon: Node
var _holding: Dictionary = {"left": false, "right": false}
var _grip_of: Dictionary = {"left": "", "right": ""}
var _hand_yaw0: Dictionary = {"left": 0.0, "right": 0.0}
var _pony_yaw0 := 0.0 # Compatibility for older inspection tools.
var _held_ponies: Dictionary = {}
var _pony_yaws: Dictionary = {}
var _squee: AudioStreamPlayer3D
## Weight: the held grip rides a hair below the hand and trails it by a few
## frames, so she feels carried rather than glued (dev, round 5).
@export var sag_depth := 0.03
@export var sag_lag := 0.06
var _sag := 0.0
var _carried: Dictionary = {"left": Vector3.INF, "right": Vector3.INF}
@export var squee_db := -20.0
var _forced_grip: Dictionary = {}
## Sample controller motion in tracking-origin space so walking/teleporting the
## player cannot count as an arm swing. Tests without controllers use the hand.
var _throw_samples: Dictionary = {"left": [], "right": []}
var _throw_previous: Dictionary = {}
@export var throw_threshold := 2.0
@export var throw_gain := 1.7
## Print why a squeezed grip did not take (once a second per side).
@export var debug_log := false
var _debug_timer := 0.0
var hoof_grabber:=preload("res://player/pony_hoof_grabber.gd").new()


func setup(target_pony: Node, left_hand: Node3D, right_hand: Node3D,
		left_controller: Node3D, right_controller: Node3D, camera: Node3D, anon_body: Node = null) -> void:
	hoof_grabber.bind(self)
	pony = target_pony
	if target_pony != null and target_pony not in ponies:
		ponies.append(target_pony)
	_hands = {"left": left_hand, "right": right_hand}
	_controllers = {"left": left_controller, "right": right_controller}
	_camera = camera
	_anon = anon_body


## Another pony the hands may take. The nearest free grip across all of them wins.
func add_pony(target: Node) -> void:
	if target != null and target not in ponies:
		ponies.append(target)
	if pony == null:
		pony = target


## Test hook: overrides the controller reading for one side (null clears).
func set_grip_input(side: String, pressed: Variant) -> void:
	if pressed == null:
		_forced_grip.erase(side)
	else:
		_forced_grip[side] = bool(pressed)


func is_carrying(actor: Node) -> bool:
	return actor in _held_ponies.values()

func held_pony(side: String) -> Node:
	var actor: Variant = _held_ponies.get(side)
	return actor if is_instance_valid(actor) else null

func is_holding(side: String) -> bool:
	return bool(_holding[side]) or hoof_grabber.is_holding(side) or (is_instance_valid(cuddle_input) and cuddle_input.holding(side))


func _grip_pressed(side: String) -> bool:
	var hand: Node = _hands.get(side)
	if is_instance_valid(hand) and hand.get_meta("inventory_busy", false): return false
	var tracker:Node=_controllers.get(side)
	if is_instance_valid(tracker) and tracker.has_method("get_is_active") and not tracker.get_is_active():return false
	if _forced_grip.has(side):
		return bool(_forced_grip[side])
	var controller: Node3D = _controllers.get(side)
	if controller == null or not controller is XRController3D:
		return false
	# Grip AND trigger: the full fist takes her, a grip alone (pointing) does
	# not (dev, 2026-09-07).
	var c := controller as XRController3D
	return c.get_float("grip") > grip_threshold and c.get_float("trigger") > grip_threshold


func _physics_process(_delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(_delta)
	if started > 0: CPU_PROFILE.record("grabber", started)

func _physics_step(_delta: float) -> void:
	if _hands.is_empty(): return
	# Desktop: no physics hands. With nothing held and nothing settling, the rest of the tick
	# only re-clears the (already clear) hand overrides. Checked before the validity scan of every
	# pony below (45 ponies each tick, 2026-11-08): nothing in an idle desktop tick reads them, and
	# game_residents.gd already drops a despawned pony from `ponies` and `pony`.
	if not is_instance_valid(_hands.get("left")) and not is_instance_valid(_hands.get("right")) \
			and not (_holding.left or _holding.right) and hoof_grabber.held.is_empty() and _sag == 0.0:
		return
	for p in ponies:
		if p == null or not is_instance_valid(p):
			ponies = ponies.filter(func(q): return q != null and is_instance_valid(q))
			break
	if ponies.is_empty():
		for side: String in SIDES:
			if _holding[side]: _release(side)
		return
	if pony == null or not is_instance_valid(pony):
		pony = ponies[0]
	if not (_holding.left or _holding.right):
		_retarget()
	hoof_grabber.process(_delta)
	var head: Vector3 = _camera.global_position if _camera else Vector3.ZERO
	var any_held: bool = _holding.left or _holding.right
	_sag = move_toward(_sag, sag_depth if any_held else 0.0, _delta * 0.15)
	for side in SIDES:
		var hand: Node3D = _hands[side]
		if _holding[side] and (held_pony(side) == null or not is_instance_valid(hand)):
			_release(side)
		if not is_instance_valid(hand): continue
		if not _holding[side]: _retarget(side)
		if hoof_grabber.is_holding(side) or (is_instance_valid(cuddle_input) and cuddle_input.holding(side)):continue
		_sample_throw(side, _delta)
		var raw: Vector3 = hand.global_position - Vector3.UP * _sag
		var prev: Vector3 = _carried[side]
		_carried[side] = raw if not prev.is_finite() or not _holding[side] else prev.lerp(raw, 1.0 - exp(-_delta / sag_lag))
		var pressed := _grip_pressed(side)
		if _holding[side] and not pressed:
			_release(side)
		elif not _holding[side] and pressed and _near_grip(side, hand):
			_grab(side, head)
		elif not _holding[side] and pressed and debug_log and pony.has_method("get_grip_transform"):
			_debug_timer -= _delta
			if _debug_timer <= 0.0:
				_debug_timer = 1.0
				var nearest := INF
				for name: String in GRIP_NAMES:
					nearest = minf(nearest, hand.global_position.distance_to(pony.get_grip_transform(name).origin))
				print("[grabber] %s grip pressed, nearest chest grip %.2f m away (reach %.2f)" % [side, nearest, reach])
	# Follow: one hand steers its grip and turns her with the wrist; two
	# hands steer their own grips and her yaw comes from the hand pair.
	var count := int(_holding.left) + int(_holding.right)
	if count == 2 and held_pony("left") == held_pony("right"):
		pony = held_pony("left")
		for side in SIDES:
			pony.update_hand_grab(_grip_of[side], _carried[side], head)
		var left_side: String = "left" if _grip_of.left == "left_chest" else "right"
		var right_side: String = "right" if left_side == "left" else "left"
		# Her left grip sits on her -X; the vector right-grip -> left-grip is -X.
		var across: Vector3 = (_hands[left_side] as Node3D).global_position - (_hands[right_side] as Node3D).global_position
		across.y = 0.0
		if across.length() > 0.05:
			var right_axis := -across.normalized()
			var forward := Vector3(right_axis.z, 0.0, -right_axis.x)
			pony.set_hold_yaw(atan2(-forward.x, -forward.z))
	else:
		for side: String in SIDES:
			var actor: Node = held_pony(side)
			if actor == null: continue
			actor.update_grab(_carried[side], head)
			actor.set_hold_yaw(float(_pony_yaws[side]) + angle_difference(_hand_yaw0[side], _hand_yaw(side)))
	# Park the visible hands on her grips while holding.
	if _anon != null and _anon.has_method("set_hand_override"):
		for side in SIDES:
			if is_instance_valid(cuddle_input) and cuddle_input.holding(side):
				_anon.set_hand_override(side,cuddle_input.grip_transform(side))
			elif hoof_grabber.is_holding(side):
				_anon.set_hand_override(side,Transform3D((_hands[side] as Node3D).global_basis,hoof_grabber.transform(side).origin))
			elif _holding[side]:
				var grip: Transform3D = held_pony(side).get_grip_transform(_grip_of[side])
				_anon.set_hand_override(side, Transform3D((_hands[side] as Node3D).global_basis, grip.origin))
			elif is_instance_valid(_hands[side]) and _hands[side].has_meta("balloon_control"):
				var controls:Node=_hands[side].get_meta("balloon_control") as Node
				_anon.set_hand_override(side,controls.grip_transform(side) if is_instance_valid(controls) else null)
			else:
				_anon.set_hand_override(side, null)


func _near_grip(side: String, hand: Node3D) -> bool:
	return _nearest_free_grip(side, hand) != ""


## With nothing held, the targeted pony is whoever has a grip nearest to a pressed hand
## (else nearest to either hand), so six ponies share one grabber.
func _retarget(only_side: String = "") -> void:
	var best: Node = pony
	var best_distance := INF
	# Hands, their grip state and each pony's grips are fixed for this call: read them once
	# (the same comparisons in the same order as reading them per pony, side and grip).
	var sides: Array[String] = []
	var hand_at: Array[Vector3] = []
	var pressed: Array[bool] = []
	for side: String in SIDES:
		if _holding[side] or (only_side != "" and side != only_side): continue
		var hand: Node3D = _hands.get(side)
		if hand == null or not is_instance_valid(hand):
			continue
		sides.append(side); hand_at.append(hand.global_position); pressed.append(_grip_pressed(side))
	if sides.is_empty():
		return
	# Grips are read only for ponies that could still hold the nearest one. A chest grip lies within
	# GRIP_SPAN metres (per unit of body scale) of her origin, so her score is within that span of
	# the same score taken at her origin. A pony whose lowest possible score is above another
	# pony's highest possible score cannot win. Same winner as reading every pony's grips, which
	# cost two bone transforms per pony per call, up to three calls a tick in VR (2026-11-12).
	var lows: Array[float] = []
	var cutoff := INF
	for candidate in ponies:
		var low := -INF
		if candidate is Node3D and candidate.has_method("get_grip_transform"):
			var at: Vector3 = candidate.global_position
			var size: Variant = candidate.get("body_scale")
			var span: float = GRIP_SPAN * maxf(1.0, float(size) if size != null else 1.0)
			var score := INF
			for s in sides.size():
				score = minf(score, hand_at[s].distance_to(at) - (100.0 if pressed[s] else 0.0))
			low = score - span
			cutoff = minf(cutoff, score + span)
		lows.append(low)
	var index := -1
	for candidate in ponies:
		index += 1
		if lows[index] > cutoff or not candidate.has_method("get_grip_transform"):
			continue
		var grips: Array[Vector3] = []
		for name: String in GRIP_NAMES:
			grips.append(candidate.get_grip_transform(name).origin)
		for s in sides.size():
			for g in grips.size():
				var d: float = hand_at[s].distance_to(grips[g])
				if pressed[s]:
					d -= 100.0  # a squeezing hand decides
				if d < best_distance:
					best_distance = d
					best = candidate
	pony = best


## The closest chest grip within reach that the other hand does not hold.
func _nearest_free_grip(side: String, hand: Node3D) -> String:
	if pony.get_meta("cuddle_active",false):return ""
	if pony.has_meta("spa_client"):return ""   # no chest pickup at the spa (SPA_PLAN_2026_10_29.md section 3)
	if pony.get("hoof_hold")!=null and pony.hoof_hold.leg_index>=0:return ""
	if not pony.has_method("get_grip_transform"):
		return ""
	var other: String = "right" if side == "left" else "left"
	var best := ""
	var best_distance := reach
	for name: String in GRIP_NAMES:
		if held_pony(other) == pony and _grip_of[other] == name:
			continue
		var d: float = hand.global_position.distance_to(pony.get_grip_transform(name).origin)
		if d <= best_distance:
			best_distance = d
			best = name
	return best


## Yaw of a hand's pointing direction on the ground plane.
func _hand_yaw(side: String) -> float:
	var f: Vector3 = -(_hands[side] as Node3D).global_basis.z
	f.y = 0.0
	if f.length() < 0.2:
		f = (_hands[side] as Node3D).global_basis.y
		f.y = 0.0
	return atan2(-f.x, -f.z) if f.length() > 0.001 else 0.0


func _grab(side: String, head: Vector3) -> void:
	var other: String = "right" if side == "left" else "left"
	var grip := _nearest_free_grip(side, _hands[side])
	if grip == "":
		return
	_holding[side] = true
	_held_ponies[side] = pony
	_pony_yaws[side] = (pony as Node3D).rotation.y
	_throw_samples[side].clear()
	_throw_previous.erase(side)
	_grip_of[side] = grip
	_hand_yaw0[side] = _hand_yaw(side)
	_pony_yaw0 = (pony as Node3D).rotation.y
	if held_pony(other) == pony:
		# Second hand joins: the two-hand grab owns both targets from here.
		var left_side: String = side if grip == "left_chest" else other
		var right_side: String = other if left_side == side else side
		pony.begin_two_hand_grab((_hands[left_side] as Node3D).global_position,
			(_hands[right_side] as Node3D).global_position, head)
	else:
		pony.begin_grab(grip, (_hands[side] as Node3D).global_position, head)
		_play_squee()


## A faint squee when the first hand takes her; never on the second hand.
func _play_squee() -> void:
	if _squee == null:
		_squee = AudioStreamPlayer3D.new()
		_squee.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		_squee.max_distance = 12.0
		_squee.unit_size = 2.0
		add_child(_squee)
	_squee.global_position = pony.get_grip_transform("chest").origin
	_squee.stream = SQUEES[randi() % SQUEES.size()]
	_squee.volume_db = squee_db
	_squee.pitch_scale = randf_range(0.97, 1.05)
	_squee.play()


func _release(side: String) -> void:
	var released: Node = held_pony(side)
	_held_ponies.erase(side)
	_pony_yaws.erase(side)
	if released == null:
		_holding[side] = false
		_grip_of[side] = ""
		_throw_samples[side].clear(); _throw_previous.erase(side)
		if is_instance_valid(_anon): _anon.set_hand_override(side, null)
		return
	pony = released
	var other: String = "right" if side == "left" else "left"
	_holding[side] = false
	var grip: String = _grip_of[side]
	_grip_of[side] = ""
	if held_pony(other) == pony:
		pony.release_hand_grab(grip)
		# The remaining hand steers alone from here; re-zero its wrist.
		_hand_yaw0[other] = _hand_yaw(other)
		_pony_yaw0 = (pony as Node3D).rotation.y
		_pony_yaws[other] = _pony_yaw0
	else:
		var momentum := _release_velocity(side)
		if momentum.length() < throw_threshold or not pony.has_method("throw_pony") or not pony.throw_pony(momentum * throw_gain):
			pony.end_interaction()
	_throw_samples[side].clear()
	_throw_previous.erase(side)
	if _anon != null and _anon.has_method("set_hand_override"):
		_anon.set_hand_override(side, null)


func _sample_throw(side: String, delta: float) -> void:
	if not _holding[side]: return
	var source: Node3D = _controllers.get(side)
	if not is_instance_valid(source): source = _hands.get(side)
	var hand: Node3D = _hands.get(side)
	if not is_instance_valid(source) or (is_instance_valid(hand) and hand.get_meta("inventory_busy",false)) or (source.has_method("get_is_active") and not source.get_is_active()):
		_throw_samples[side].clear(); _throw_previous.erase(side); return
	var origin := source.get_parent() as Node3D
	var at := source.position if origin != null else source.global_position
	if not at.is_finite() or delta <= 0.0 or delta > .1:
		_throw_samples[side].clear(); _throw_previous.erase(side); return
	if _throw_previous.has(side):
		var speed: Vector3 = (at - Vector3(_throw_previous[side])) / delta
		# A tracking discontinuity is not a throw; require fresh valid samples.
		if speed.length() > 25.0:
			_throw_samples[side].clear()
		else:
			var samples: Array = _throw_samples[side]
			samples.append({"motion": speed * delta, "seconds": delta})
			var duration := 0.0
			for sample: Dictionary in samples: duration += sample.seconds
			while samples.size() > 1 and duration > .1:
				duration -= float(samples[0].seconds); samples.pop_front()
	_throw_previous[side] = at


func _release_velocity(side: String) -> Vector3:
	var motion := Vector3.ZERO
	var duration := 0.0
	for sample: Dictionary in _throw_samples[side]:
		motion += Vector3(sample.motion); duration += float(sample.seconds)
	if duration < .05: return Vector3.ZERO
	var source: Node3D = _controllers.get(side)
	if not is_instance_valid(source): source = _hands.get(side)
	if not is_instance_valid(source): return Vector3.ZERO
	var origin := source.get_parent() as Node3D
	return (origin.global_basis.orthonormalized() if origin != null else Basis.IDENTITY) * motion / duration


func _exit_tree() -> void:
	if is_instance_valid(_squee):_squee.stop()
	hoof_grabber.release_all()
	if is_instance_valid(_anon) and _anon.has_method("set_hand_override"):
		for side in SIDES:_anon.set_hand_override(side,null)
