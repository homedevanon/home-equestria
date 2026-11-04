extends RefCounted
## Desktop body animation for the human player (dev 2026-11-03: "proper walking, sitting,
## crouching, et cetera animations to Anon"). Plays the retargeted clips in
## player/animations/anon_motion.res (built by tools/anon/build_anon_motion.gd) as the base
## pose of the accepted rig; anon_body.gd then takes the animated pelvis, feet, knees and resting
## hands as IK targets, so the camera head, actions and held items stay authoritative.
##
## Gaits share one normalised phase aligned on the left heel strike, so walk/jog/sprint and
## crouch-walk blend without the feet crossing. A gait plays at the rate that carries its planted
## foot at the body's speed (clamped to stay natural); the rest of any mismatch is absorbed by
## world foot locking, so a planted foot never slides.
##
## Headset bodies never use this: tracked head and hands own the VR body.
const LIBRARY := preload("res://player/animations/anon_motion.res")
## Model bones the clips animate (fingers stay with the grip code).
const BONES := ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes"]
const GAITS := ["walk", "jog", "sprint", "crouch_walk"]
## Body-unit speeds (m/s at model scale 1) where each standing gait is played alone. The desktop
## stroll (1.8) and walk (5.5) both play the walk; sprint (8) plays the sprint (dev 2026-11-03:
## "play the walk in normal speed motion"). The jog only shows while speeding up to a sprint.
const WALK_FULL := 1.0
const WALK_TOP := 5.6
const JOG_SPEED := 6.8
const SPRINT_SPEED := 8.0
## The walk's cadence stops at this multiple of its authored rate (about 200 steps a minute); above
## its matching speed the planted feet glide rather than the legs blurring.
const WALK_MAX_RATE := 2.2
## Every gait's cadence is slowed to this share of the rate above (dev 2026-11-03: "slow down the
## pace of the animations, make them go slower"); the planted feet glide the difference.
const GAIT_PACE := 0.8
const CROUCH_WALK_FULL := .6
## A gait never plays slower or faster than this fraction of its authored rate.
const MIN_RATE := .7
const MAX_RATE := 2.2
## Weight easing time and the airborne grace before the fall pose.
const BLEND_TIME := .14
## Standing idles play slower than authored: a calm breath, not a beat (dev 2026-11-03).
const IDLE_RATE := .7
const AIR_GRACE := .12
## Strafing turns the legs toward travel at most this far; the head and hands keep the view.
const MAX_LEG_TURN := 0.8727
## A locked foot lets go when the animation lifts it, or when the leg would have to reach
## farther than this (body units) from the animated spot.
const LOCK_SLACK := .3
const LOCK_RELEASE_TIME := .12

var skeleton: Skeleton3D
## 0..1: how much of the body the animation owns (fades in and out with availability).
var amount := 0.0
## Share of the feet that follow the clips rather than anon_body's stepped standing feet.
var feet_amount := 0.0
## Leg turn toward the travel direction (radians, about up).
var leg_yaw := 0.0
var seated := 0.0
## Model-space globals of BONES after the latest update (rig rest faces +Z, feet at y 0).
var globals: Array[Transform3D] = []
var _ids := PackedInt32Array()
var _parent := PackedInt32Array()
var _rest_origin := PackedVector3Array()
var _rest_rotation: Array[Quaternion] = []
var _rest_global_inverse: Array[Basis] = []
var _clips: Dictionary = {}
var _weights: Dictionary = {}
var _times: Dictionary = {}
var _phase := 0.0
var _air := 0.0
var _land := -1.0
var _was_airborne := false
var _crouch := 0.0
var _locks: Array[Dictionary] = [{}, {}]
var _index: Dictionary = {}

func _init(target: Skeleton3D) -> void:
	skeleton = target
	for bone_name: String in BONES:
		var id := skeleton.find_bone(bone_name)
		_index[bone_name] = _ids.size()
		_ids.append(id)
	for i in _ids.size():
		var id := _ids[i]
		var parent_name := skeleton.get_bone_name(skeleton.get_bone_parent(id)) if id >= 0 and skeleton.get_bone_parent(id) >= 0 else ""
		_parent.append(int(_index.get(parent_name, -1)))
		var rest := skeleton.get_bone_rest(id) if id >= 0 else Transform3D.IDENTITY
		_rest_origin.append(rest.origin)
		_rest_rotation.append(rest.basis.get_rotation_quaternion())
		_rest_global_inverse.append((skeleton.get_bone_global_rest(id).basis if id >= 0 else Basis.IDENTITY).inverse())
		globals.append(skeleton.get_bone_global_rest(id) if id >= 0 else Transform3D.IDENTITY)
	for clip_name: StringName in LIBRARY.get_animation_list():
		var animation: Animation = LIBRARY.get_animation(clip_name)
		var tracks := PackedInt32Array()
		for bone_name: String in BONES:
			tracks.append(animation.find_track(NodePath("Model/an_new_anon_ARM/Skeleton3D:" + bone_name), Animation.TYPE_ROTATION_3D))
		var contact: PackedByteArray = animation.get_meta("contact", PackedByteArray()) if animation.has_meta("contact") else PackedByteArray()
		_clips[String(clip_name)] = {"animation": animation, "tracks": tracks,
			"hips": animation.find_track(NodePath("Model/an_new_anon_ARM/Skeleton3D:Hips"), Animation.TYPE_POSITION_3D),
			"contact": contact, "contact_fps": float(animation.get_meta("contact_fps", 30.0)) if animation.has_meta("contact_fps") else 30.0,
			"speed": float(animation.get_meta("ground_speed", 1.0)) if animation.has_meta("ground_speed") else 1.0,
			"strike": float(animation.get_meta("left_strike", 0.0)) if animation.has_meta("left_strike") else 0.0}
		_weights[String(clip_name)] = 0.0
		_times[String(clip_name)] = 0.0

func valid() -> bool:
	return _ids.find(-1) == -1 and _clips.has("idle")

## state: speed (horizontal m/s, world), move_angle (travel direction from facing, radians,
## positive to the left), on_floor, crouch (0..1), seated (bool), scale (model scale).
## An empty state fades the animation out to the rest pose (couch rests, swimming, knockdown).
func update(delta: float, state: Dictionary) -> void:
	delta = clampf(delta, 0.0, .1)
	var on := not state.is_empty()
	amount = move_toward(amount, 1.0 if on else 0.0, delta / .2)
	var scale := maxf(float(state.get("scale", 1.0)), .05)
	var speed := float(state.get("speed", 0.0)) / scale
	var on_floor := bool(state.get("on_floor", true))
	var sitting := bool(state.get("seated", false))
	_crouch = move_toward(_crouch, clampf(float(state.get("crouch", 0.0)), 0.0, 1.0), delta / .15)
	_air = 0.0 if on_floor or sitting else _air + delta
	var airborne := _air > AIR_GRACE
	if _was_airborne and not airborne and not sitting: _land = 0.0
	_was_airborne = airborne
	var wanted: Dictionary = {}
	for clip: String in _weights: wanted[clip] = 0.0
	var angle := wrapf(float(state.get("move_angle", 0.0)), -PI, PI)
	var backward := absf(angle) > deg_to_rad(110.0) and speed > .1
	var leg_target := 0.0
	if sitting:
		wanted["sit_idle"] = 1.0
	elif airborne:
		wanted["jump_loop"] = 1.0
	else:
		var stand := _stand_weights(speed)
		var crouched := {"crouch_idle": 1.0 - clampf(speed / CROUCH_WALK_FULL, 0.0, 1.0)}
		crouched["crouch_walk"] = 1.0 - float(crouched.crouch_idle)
		for clip: String in stand: wanted[clip] = float(stand[clip]) * (1.0 - _crouch)
		for clip: String in crouched: wanted[clip] = float(wanted.get(clip, 0.0)) + float(crouched[clip]) * _crouch
		if speed > .1:
			leg_target = clampf(wrapf(angle + PI, -PI, PI) if backward else angle, -MAX_LEG_TURN, MAX_LEG_TURN)
		if _land >= 0.0:
			var land_weight := (1.0 - clampf(speed / 1.5, 0.0, 1.0)) * (1.0 - smoothstep(.55, .85, _land))
			for clip: String in wanted: wanted[clip] = float(wanted[clip]) * (1.0 - land_weight)
			wanted["jump_land"] = land_weight
	seated = move_toward(seated, 1.0 if sitting else 0.0, delta / BLEND_TIME)
	leg_yaw = lerp_angle(leg_yaw, leg_target, 1.0 - exp(-delta / .2))
	var blend := 1.0 - exp(-delta / BLEND_TIME)
	var total := 0.0
	for clip: String in _weights:
		_weights[clip] = lerpf(float(_weights[clip]), float(wanted.get(clip, 0.0)), blend)
		if float(_weights[clip]) < .002: _weights[clip] = 0.0
		total += float(_weights[clip])
	if total > 0.0:
		for clip: String in _weights: _weights[clip] = float(_weights[clip]) / total
	# Shared gait phase: the blended cycle frequency at the rate each gait's planted foot needs.
	var frequency := 0.0
	var gait_weight := 0.0
	for clip: String in GAITS:
		var w := float(_weights.get(clip, 0.0))
		if w <= 0.0 or not _clips.has(clip): continue
		var data: Dictionary = _clips[clip]
		var animation: Animation = data.animation
		var rate := clampf(speed / maxf(float(data.speed), .05), MIN_RATE, WALK_MAX_RATE if clip == "walk" else MAX_RATE) * GAIT_PACE
		frequency += w * rate / animation.length
		gait_weight += w
	if gait_weight > 0.0: _phase = fposmod(_phase + (-1.0 if backward else 1.0) * frequency / gait_weight * delta, 1.0)
	for clip: String in _times:
		if clip in GAITS: continue
		_times[clip] = float(_times[clip]) + delta * (IDLE_RATE if clip == "idle" or clip == "crouch_idle" else 1.0)
	if _land >= 0.0:
		_land += delta
		_times["jump_land"] = .08 + _land
		if _land > 1.0: _land = -1.0
	if not airborne: _times["jump_loop"] = 0.0
	# Planted standing idle keeps anon_body's stepped feet (turning on the spot steps).
	var idle_feet := float(_weights.get("idle", 0.0)) + float(_weights.get("jump_land", 0.0))
	feet_amount = amount * clampf(1.0 - idle_feet, 0.0, 1.0)
	_sample(scale)

func _stand_weights(speed: float) -> Dictionary:
	if speed < WALK_FULL: return {"idle": 1.0 - speed / WALK_FULL, "walk": speed / WALK_FULL}
	if speed < WALK_TOP: return {"walk": 1.0}
	if speed < JOG_SPEED:
		var t := (speed - WALK_TOP) / (JOG_SPEED - WALK_TOP)
		return {"walk": 1.0 - t, "jog": t}
	var u := clampf((speed - JOG_SPEED) / (SPRINT_SPEED - JOG_SPEED), 0.0, 1.0)
	return {"jog": 1.0 - u, "sprint": u}

func _clip_time(clip: String) -> float:
	var data: Dictionary = _clips[clip]
	var animation: Animation = data.animation
	if clip in GAITS: return fposmod(float(data.strike) + _phase * animation.length, animation.length)
	var t := float(_times.get(clip, 0.0))
	return fposmod(t, animation.length) if animation.loop_mode != Animation.LOOP_NONE else clampf(t, 0.0, animation.length)

## Blended contact of one foot (0 left, 1 right) under the current weights.
func contact(foot: int) -> float:
	var value := 0.0
	for clip: String in _weights:
		var w := float(_weights[clip])
		if w <= 0.0: continue
		var data: Dictionary = _clips[clip]
		var flags: PackedByteArray = data.contact
		if flags.is_empty():
			value += w
			continue
		var frame := clampi(int(round(_clip_time(clip) * float(data.contact_fps))), 0, flags.size() - 1)
		if flags[frame] & (1 << foot): value += w
	return value

func _sample(scale: float) -> void:
	var count := _ids.size()
	var rotations: Array[Quaternion] = []
	rotations.assign(_rest_rotation)
	var hips := _rest_origin[0]
	var accumulated := 0.0
	for clip: String in _weights:
		var w := float(_weights[clip])
		if w <= 0.0: continue
		var data: Dictionary = _clips[clip]
		var animation: Animation = data.animation
		var tracks: PackedInt32Array = data.tracks
		var t := _clip_time(clip)
		accumulated += w
		var share := w / accumulated
		for i in count:
			if tracks[i] < 0: continue
			var q: Quaternion = animation.rotation_track_interpolate(tracks[i], t)
			rotations[i] = q if share >= 1.0 else rotations[i].slerp(q, share)
		if int(data.hips) >= 0:
			var p: Vector3 = animation.position_track_interpolate(int(data.hips), t)
			hips = p if share >= 1.0 else hips.lerp(p, share)
	for i in count:
		var q := _rest_rotation[i].slerp(rotations[i], amount) if amount < 1.0 else rotations[i]
		var origin := _rest_origin[0].lerp(hips, amount) if i == 0 else _rest_origin[i]
		skeleton.set_bone_pose_rotation(_ids[i], q)
		if i == 0: skeleton.set_bone_pose_position(_ids[0], origin)
		var local := Transform3D(Basis(q), origin)
		globals[i] = globals[_parent[i]] * local if _parent[i] >= 0 else local

## Return every animated bone to its rest pose (the body leaves animation entirely).
func reset_pose() -> void:
	for i in _ids.size():
		skeleton.set_bone_pose_rotation(_ids[i], _rest_rotation[i])
		if i == 0: skeleton.set_bone_pose_position(_ids[0], _rest_origin[0])
	amount = 0.0
	feet_amount = 0.0
	for lock: Dictionary in _locks: lock.clear()

## World transform of an animated bone as an IK target: the target's basis composes with the
## bone's global rest in valve_body_ik.gd, so the rest is divided out here.
func target(bone_name: String, frame: Transform3D, scale: float) -> Transform3D:
	var i := int(_index.get(bone_name, -1))
	if i < 0: return Transform3D.IDENTITY
	var g := globals[i]
	return Transform3D(frame.basis * g.basis * _rest_global_inverse[i], frame.origin + frame.basis * (g.origin * scale))

func point(bone_name: String, frame: Transform3D, scale: float) -> Vector3:
	var i := int(_index.get(bone_name, -1))
	return frame.origin + frame.basis * (globals[i].origin * scale) if i >= 0 else frame.origin

## Model-space pelvis position of the seated clip (for anchoring the hips on a seat).
func seated_hips() -> Vector3:
	var data: Dictionary = _clips.get("sit_idle", {})
	if data.is_empty() or int(data.hips) < 0: return _rest_origin[0]
	var animation: Animation = data.animation
	return animation.position_track_interpolate(int(data.hips), 0.0)

## Animated foot target, held where it landed while the clip says it is planted. The part of the
## foot on the ground (heel/ankle while flat, the ball once the heel lifts) is kept still by
## cancelling its horizontal world motion, so the clip's own heel-to-toe roll still plays.
func foot_target(foot: int, frame: Transform3D, scale: float, delta: float) -> Transform3D:
	var animated := target("LeftFoot" if foot == 0 else "RightFoot", frame, scale)
	var ball := point("LeftToes" if foot == 0 else "RightToes", frame, scale)
	var roll := smoothstep(.13, .17, (animated.origin.y - frame.origin.y) / scale)
	var lock: Dictionary = _locks[foot]
	var planted := contact(foot) >= .5 and seated < .5 and _air <= AIR_GRACE and feet_amount > .5
	var shift := Vector3.ZERO
	if lock.has("ankle"): shift = lock["shift"]
	elif lock.has("shift"): shift = Vector3(lock["shift"]) * (1.0 - smoothstep(0.0, 1.0, float(lock.get("release", 0.0)) / LOCK_RELEASE_TIME))
	if planted and lock.has("ankle"):
		var moved: Vector3 = (animated.origin - Vector3(lock["ankle"])).lerp(ball - Vector3(lock["ball"]), roll)
		moved.y = 0.0
		shift -= moved
		if shift.length() > LOCK_SLACK * scale: planted = false
	if planted:
		lock["shift"] = shift
		lock.erase("release")
		lock["ankle"] = animated.origin
		lock["ball"] = ball
		return Transform3D(animated.basis, animated.origin + shift)
	lock.erase("ankle")
	lock.erase("ball")
	if lock.has("shift"):
		# Let go: ease the held offset back onto the clip.
		lock["release"] = float(lock.get("release", 0.0)) + delta
		var t := smoothstep(0.0, 1.0, float(lock["release"]) / LOCK_RELEASE_TIME)
		if t >= 1.0:
			lock.clear()
			return animated
		return Transform3D(animated.basis, animated.origin + Vector3(lock["shift"]) * (1.0 - t))
	return animated

## A foot is held in place this tick.
func foot_locked(foot: int) -> bool:
	return _locks[foot].has("ankle")

func weights() -> Dictionary:
	return _weights.duplicate()
