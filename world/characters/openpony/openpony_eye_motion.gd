extends SkeletonModifier3D
## Native iris controls and skinned lids. The devkit uses mFaceNoseLeft/Right
## for pupils (Copy Location + normal-tracking Shrinkwrap onto IKEye), not mEye*.
## Keep that curved surface, original weights, facial topology and textures.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const FK := preload("res://world/characters/locomotion/limb_solver.gd")
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md) runs the modifier pass with the same
## result; null keeps the GDScript below.
var native: RefCounted
@export var convergence_degrees := 5.0
var closure := 0.0
## Temporary expression underneath the blink; zero is the fully open default.
var expression_closure := 0.0
var expression_brows: Dictionary = {}
var _brow_shapes: Dictionary = {}
var expression_eyes: Dictionary = {}
var expression_ears: Dictionary = {}
var _eye_shapes: Dictionary = {}
var _ear_shapes: Dictionary = {}
var gaze := Vector2.ZERO # head-local yaw/pitch; radians
## Optional curved iris artwork shares the resolved target/saccade and native lid clock.
var surface_update: Callable
var target_world := Vector3.ZERO
var target_weight := 0.0
var saccades_enabled := true
## PonyCrowd NEAR mares (6 m and beyond): full run every `rate_divisor`-th physics tick,
## the cached bone writes in between. Nobody sees a 20 Hz glance at that range.
var rate_divisor := 1
var rate_phase := 0
var _written: Dictionary = {}
## Unchanged inputs reuse the last full run (0.1.0 perf pass). Between blinks and saccades, with no
## moving target, a full run recomputed the very poses it wrote last time (lids, brows, ears and both
## eyes are a pure function of the values in _inputs() on this rig). Such a run re-applies the
## cached writes instead, as the clip tiers' in-between ticks already do, and skips the identical
## eye surface update. Rollback: REUSE_UNCHANGED = false.
const REUSE_UNCHANGED := true
var _last_inputs: Array = []
## The head's AnimationPlayer (bind): a playing clip moves brow/ear source poses, so no reuse.
var _player: AnimationPlayer
var blink_enabled := true
## Closed smiling expressions already have lid contact; their blink clock keeps
## running without briefly pulling that pose back toward an open native eye.
var blink_strength := 1.0
var _rests: Array[Transform3D] = []
var _parents: Array[int] = []
var _rest_globals: Array[Transform3D] = []
var _lid_open: Dictionary = {}
var _lid_closed: Dictionary = {}
var _eye_bones: Array[int] = []
var _head_bone := -1
var _eye_center_head := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _wait := 2.0
var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _offset := Vector2.ZERO
var _scan_offset := Vector2.ZERO
var _fixation := 0.0
var _elapsed := 1.0
var _duration := 0.08
var _blink_wait := 3.0
var _blink_time := -1.0
var _blink_close := .13
var _blink_hold := .025
var _blink_open := .23
var _paired_blink := false

## Eye life on a target (dev 2026-11-03: "her pupils are just dead solid facing me"). While she
## fixates (target_weight), a second clock darts both eyes together between the viewer's face points
## (each eye, between them, now and then the mouth), lets them drift a little between darts and
## sometimes glances away and straight back. target_world itself never moves, so she keeps tracking
## it; eye_pose()/show_gaze_uv() clamp the result to the usual gaze limits. The mood
## (set_gaze_mood, from the expression face) sets how often, how far and how slowly:
## [mean seconds between darts, dart size, chance a dart is a glance away, glance radians,
##  glance dwell seconds, speed, drift, downward glance bias].
const GAZE_MOODS := {
	"neutral": [0.85, 1.0, 0.09, 0.15, 0.45, 1.0, 1.0, 0.3],
	"focused": [1.7, 0.55, 0.02, 0.10, 0.18, 1.3, 0.45, 0.2],
	"happy": [0.95, 0.95, 0.07, 0.14, 0.45, 1.0, 0.9, 0.3],
	"relaxed": [1.25, 0.85, 0.06, 0.12, 0.6, 0.85, 0.8, 0.4],
	"shy": [0.5, 1.15, 0.2, 0.16, 0.45, 1.0, 1.3, 0.85],
	"fearful": [0.5, 1.3, 0.18, 0.18, 0.3, 1.2, 1.5, 0.2],
	"surprised": [1.3, 0.8, 0.04, 0.12, 0.3, 1.2, 0.6, 0.2],
	"confused": [0.7, 1.05, 0.11, 0.15, 0.45, 1.0, 1.0, 0.0],
	"sad": [1.7, 0.8, 0.14, 0.14, 0.9, 0.6, 0.7, 0.9],
	"sleepy": [2.0, 0.75, 0.10, 0.10, 0.9, 0.55, 0.6, 0.7],
}
## Expression face (face_poses.gd LINE_FACES) -> gaze mood; anything unlisted reads as neutral.
const FACE_GAZE_MOODS := {"angry": "focused", "ponyrage": "focused", "annoyed": "focused",
	"suspicious": "focused", "anticipation": "focused", "angersmug": "focused",
	"happy": "happy", "delighted": "happy", "silly": "happy", "amused": "happy", "crookedsmile": "happy",
	"relaxed": "relaxed", "affectionate": "relaxed", "shy": "shy", "disgusted": "shy",
	"fearful": "fearful", "surprised": "surprised", "ooo": "surprised", "confused": "confused",
	"sad": "sad", "pain": "sad"}
## The viewer's face in half-eye-spacings: left eye, right eye, between them, mouth; and how often
## each is the next dart's landing point.
const FACE_POINTS: Array[Vector2] = [Vector2(-1, 0), Vector2(1, 0), Vector2(0, 0), Vector2(0, -2.2)]
const FACE_POINT_ODDS: Array[float] = [.37, .37, .16, .10]
## Half the distance between a viewer's eyes (metres), drawn 1.5x larger so the darts read on a
## cartoon eye; the angle is clamped so a far viewer still gets visible darts and a near one no jumps.
const FACE_HALF_EYES := .032
const FACE_POINT_GAIN := 1.5
var gaze_mood := "neutral"
var _mood := PackedFloat32Array(GAZE_MOODS.neutral)
var _mood_goal := PackedFloat32Array(GAZE_MOODS.neutral)
var _focus_from := Vector2.ZERO
var _focus_to := Vector2.ZERO
var _focus_offset := Vector2.ZERO
var _focus_elapsed := 1.0
var _focus_duration := .05
var _focus_wait := .3
var _focus_point := -1
var _glance_left := -1.0
var _drift := Vector2.ZERO
var _drift_goal := Vector2.ZERO
## Darts and glances made on a target since bind (labs read them).
var focus_saccades := 0
var focus_glances := 0


## `face`: an expression face or a GAZE_MOODS name; "" or unknown -> neutral. Eased in advance().
func set_gaze_mood(face: String) -> void:
	var mood: String = FACE_GAZE_MOODS.get(face, face if GAZE_MOODS.has(face) else "neutral")
	if mood == gaze_mood: return
	gaze_mood = mood
	var values: Array = GAZE_MOODS[mood]
	for i in values.size(): _mood_goal[i] = float(values[i])


## Every clip bind() samples. With the rig's bones they are all its poses depend on.
const BIND_CLIPS := ["blink_left", "blink_right", "brows_angry", "brows_sad", "brows_wide", "brows_confused_left",
	"brows_happy_right", "eyes_mad", "eyes_sad", "eyes_wide", "ears_alert", "ears_side", "ears_agitated"]
## [bone names, rests, parents, clips] -> the sampled lid, brow, eye and ear poses. Every head of a
## model shares the rig and the clip library; sampling ~200 clip poses with FK cost each spawn
## a large synchronous stall. The shared dictionaries are only read after bind().
static var _bound := {}

func bind(player: AnimationPlayer) -> void:
	var sk := get_skeleton()
	_player = player
	_last_inputs = []
	# From the global generator: random in game, repeatable in a test that calls seed().
	_rng.seed = randi()
	_blink_wait = _rng.randf_range(1.2, 6.0)
	_wait = _rng.randf_range(.4, 3.5)
	var names := PackedStringArray()
	for i in sk.get_bone_count():
		_rests.append(sk.get_bone_rest(i))
		_parents.append(sk.get_bone_parent(i))
		names.append(sk.get_bone_name(i))
	var clips := []
	for clip: String in BIND_CLIPS:
		clips.append(player.get_animation(clip) if player.has_animation(clip) else null)
	var key := [names, _rests.duplicate(), _parents.duplicate(), clips]
	var bound: Dictionary = _bound.get(key, {})
	if bound.is_empty():
		var errors := PackedStringArray()
		_bind_poses(sk, player, errors)
		_bound[key] = {"rest_globals": _rest_globals.duplicate(), "head": _head_bone, "eyes": _eye_bones.duplicate(),
			"open": _lid_open, "closed": _lid_closed, "brows": _brow_shapes, "eye_shapes": _eye_shapes,
			"ears": _ear_shapes, "center": _eye_center_head, "errors": errors}
	else:
		for message in bound.errors: push_error(message)
		_rest_globals.assign(bound.rest_globals)
		_head_bone = bound.head
		_eye_bones.assign(bound.eyes)
		_lid_open = bound.open
		_lid_closed = bound.closed
		_brow_shapes = bound.brows
		_eye_shapes = bound.eye_shapes
		_ear_shapes = bound.ears
		_eye_center_head = bound.center
	native = NATIVE.create() if NATIVE.enabled("eyes") else null
	if native != null:
		native.bind_eyes(_lid_open, _lid_closed, _eye_shapes, _brow_shapes, _ear_shapes, PackedInt32Array(_eye_bones),
			_head_bone, _eye_center_head, _rest_globals, PackedInt32Array(_parents))


func _bind_poses(sk: Skeleton3D, player: AnimationPlayer, errors: PackedStringArray) -> void:
	_rest_globals = FK.forward_kinematics(_parents, _rests)
	_head_bone = sk.find_bone("mHead")
	for side in ["Left", "Right"]:
		_eye_bones.append(sk.find_bone("mFaceNose" + side))
		var clip: String = "blink_" + side.to_lower()
		var upper := sk.find_bone("mFaceEyeLidUpper" + side)
		var lower := sk.find_bone("mFaceEyeLidLower" + side)
		if not player.has_animation(clip) or upper < 0 or lower < 0:
			errors.append("OpenPony eye motion: missing native blink pose " + side)
			push_error(errors[-1])
			continue
		var anim := player.get_animation(clip)
		var times: Array[float] = [0.0]
		for track in anim.get_track_count():
			if "EyeLid" not in str(anim.track_get_path(track)): continue
			for key in anim.track_get_key_count(track):
				var t := anim.track_get_key_time(track, key)
				if t not in times: times.append(t)
		var max_gap := -INF
		var min_gap := INF
		var opened: Array[Transform3D] = []
		var closed: Array[Transform3D] = []
		for t in times:
			var pose := _sample(anim, t)
			var globals := FK.forward_kinematics(_parents, pose)
			var gap := globals[upper].origin.y - globals[lower].origin.y
			if gap > max_gap:
				max_gap = gap
				opened = pose
			if gap < min_gap:
				min_gap = gap
				closed = pose
		for i in sk.get_bone_count():
			var name := sk.get_bone_name(i)
			if name.ends_with(side) and (name.begins_with("mFaceEyeLid") \
					or name.begins_with("mFaceEyecorner") or name.begins_with("mFaceEyebrow") \
					or name.begins_with("mFaceCheekUpper") or name.begins_with("mFaceForehead")):
				_lid_open[i] = opened[i]
				_lid_closed[i] = closed[i]
	if _head_bone >= 0 and _eye_bones[0] >= 0 and _eye_bones[1] >= 0:
		_bind_brows(player)
		_bind_expression_shapes(player)
	_eye_center_head = _rest_globals[_head_bone].affine_inverse() * \
			((_rest_globals[_eye_bones[0]].origin + _rest_globals[_eye_bones[1]].origin) * .5)


func _sample(anim: Animation, time: float) -> Array[Transform3D]:
	var pose := _rests.duplicate()
	var sk := get_skeleton()
	for track in anim.get_track_count():
		var path := anim.track_get_path(track)
		if path.get_subname_count() == 0: continue
		var i := sk.find_bone(path.get_subname(0))
		if i < 0: continue
		match anim.track_get_type(track):
			Animation.TYPE_POSITION_3D: pose[i].origin = anim.position_track_interpolate(track, time)
			Animation.TYPE_ROTATION_3D:
				pose[i].basis = Basis(anim.rotation_track_interpolate(track, time)).scaled_local(pose[i].basis.get_scale())
	return pose


func advance(delta: float) -> void:
	# Attention already owns target_weight for listening, looking and carrying.
	# Fixation competes with exploratory scans regardless of target identity/distance.
	_fixation = lerpf(_fixation, clampf(target_weight, 0.0, 1.0), 1.0 - exp(-delta * 5.0))
	_wait -= delta
	if saccades_enabled and _wait <= 0.0:
		_from = _scan_offset
		var angle := _rng.randf_range(-PI, PI)
		var radius := sqrt(_rng.randf_range(.12, 1.0))
		_to = Vector2(cos(angle) * .044, sin(angle) * .027) * radius
		if _rng.randf() < .18: _to *= .18 # Small corrective return, not a regular reset.
		_duration = _rng.randf_range(.035, .065) + _from.distance_to(_to) * .35
		_elapsed = 0.0
		# Occasional paired shifts amid unequal longer fixations avoid a metronome.
		_wait = _rng.randf_range(.18, .38) if _rng.randf() < .16 else _rng.randf_range(.8, 4.8)
	_elapsed += delta
	var t := clampf(_elapsed / _duration, 0.0, 1.0)
	var eased := t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
	_scan_offset = _from.lerp(_to, eased) if saccades_enabled else Vector2.ZERO
	if saccades_enabled and _fixation > .02:
		_advance_focus(delta)
	elif _focus_point != -1 or _glance_left >= 0.0 or _focus_offset != Vector2.ZERO:
		_focus_offset = Vector2.ZERO
		_drift = Vector2.ZERO
		_focus_point = -1
		_glance_left = -1.0
		_focus_wait = _rng.randf_range(.1, .4)
	# On a target the face darts replace the idle exploration.
	var fixed := smoothstep(0.0, 1.0, _fixation)
	_offset = _scan_offset.lerp(_focus_offset + _drift, fixed) if saccades_enabled else Vector2.ZERO
	if not blink_enabled: return
	_blink_wait -= delta
	if _blink_wait <= 0.0 and _blink_time < 0.0:
		_blink_time = 0.0
		# Fast close, brief contact, softer reopening. Each blink has its own
		# timing; occasional pairs never turn into an endless chain.
		_blink_close = _rng.randf_range(.105, .155)
		_blink_hold = _rng.randf_range(.012, .045)
		_blink_open = _rng.randf_range(.19, .29)
		if _paired_blink:
			_paired_blink = false
			_blink_wait = _rng.randf_range(3.0, 7.5)
		else:
			_paired_blink = _rng.randf() < .09
			_blink_wait = _blink_close + _blink_hold + _blink_open + _rng.randf_range(.10, .22) \
				if _paired_blink else _rng.randf_range(3.0, 7.5)
	closure = 0.0
	if _blink_time >= 0.0:
		_blink_time += delta
		var opening := _blink_close + _blink_hold
		var finished := opening + _blink_open
		closure = smoothstep(0.0, _blink_close, _blink_time) if _blink_time < _blink_close \
			else 1.0 - smoothstep(opening, finished, _blink_time)
		if _blink_time >= finished: _blink_time = -1.0
	closure *= clampf(blink_strength, 0.0, 1.0)


## The on-target clock: per-pony floats only, no allocation.
func _advance_focus(delta: float) -> void:
	var ease := 1.0 - exp(-delta * 3.0)
	for i in _mood.size(): _mood[i] = lerpf(_mood[i], _mood_goal[i], ease)
	_focus_wait -= delta
	if _glance_left >= 0.0:
		_glance_left -= delta
		if _glance_left < 0.0: _focus_wait = 0.0 # straight back to her face
	if _focus_wait <= 0.0: _focus_start()
	_focus_elapsed += delta
	var t := clampf(_focus_elapsed / _focus_duration, 0.0, 1.0)
	_focus_offset = _focus_from.lerp(_focus_to, t * t * t * (t * (t * 6.0 - 15.0) + 10.0))
	# Slow drift while fixating, corrected by the next dart. Close (full-rate) ponies only: it
	# changes the offset every tick, which would end the clip tiers' unchanged-input reuse.
	if rate_divisor == 1 and t >= 1.0 and _glance_left < 0.0:
		_drift = _drift.lerp(_drift_goal, 1.0 - exp(-delta * 1.2))


func _focus_start() -> void:
	var spacing := _face_spacing()
	var to: Vector2
	if _glance_left < 0.0 and _focus_point >= 0 and _rng.randf() < _mood[2]:
		# A brief look away; the return is the next dart, after the mood's dwell.
		var angle := _rng.randf_range(-PI, PI)
		var direction := Vector2(cos(angle), sin(angle) * .8)
		if _rng.randf() < _mood[7]: direction = Vector2(direction.x, -absf(direction.y) - .35).normalized()
		to = direction * _mood[3] * _rng.randf_range(.7, 1.25)
		_glance_left = _mood[4] * _rng.randf_range(.6, 1.5)
		_focus_point = -1
		_focus_wait = INF
		focus_glances += 1
	else:
		_glance_left = -1.0
		var point := _focus_point
		for _attempt in 3:
			if point != _focus_point: break
			var roll := _rng.randf()
			point = FACE_POINTS.size() - 1
			for i in FACE_POINT_ODDS.size():
				roll -= FACE_POINT_ODDS[i]
				if roll < 0.0:
					point = i
					break
		_focus_point = point
		var size := spacing * _mood[1]
		to = FACE_POINTS[point] * size + Vector2(_rng.randf_range(-.18, .18), _rng.randf_range(-.18, .18)) * size
		_focus_wait = _mood[0] * _rng.randf_range(.45, 1.6)
	var drift_angle := _rng.randf_range(-PI, PI)
	_drift_goal = Vector2(cos(drift_angle), sin(drift_angle)) * spacing * .3 * _mood[6] * _rng.randf()
	_focus_from = _focus_offset + _drift
	_drift = Vector2.ZERO
	_focus_to = to
	_focus_duration = (_rng.randf_range(.03, .05) + _focus_from.distance_to(to) * .35) / maxf(_mood[5], .1)
	_focus_elapsed = 0.0
	focus_saccades += 1


## Half the viewer's eye spacing as an angle from her head (radians).
func _face_spacing() -> float:
	var distance := 1.2
	var sk: Skeleton3D = get_skeleton() if is_inside_tree() else null
	if sk != null and _head_bone >= 0:
		distance = (sk.global_transform * sk.get_bone_global_pose(_head_bone).origin).distance_to(target_world)
	return clampf(FACE_POINT_GAIN * FACE_HALF_EYES / maxf(distance, .1), .02, .06)


func _unprofiled_process_modification() -> void:
	if not is_inside_tree(): return
	var sk := get_skeleton()
	if not is_instance_valid(sk) or not sk.is_inside_tree(): return
	if _rest_globals.is_empty(): return
	if rate_divisor > 1 and ((Engine.get_physics_frames() + rate_phase) % rate_divisor) != 0:
		# Clip-tier mare: re-apply the last full run (Skeleton3D reverts modifier writes).
		if native != null:
			native.eye_rewrite(sk)
			return
		for b in _written: sk.set_bone_pose(b, _written[b])
		return
	if REUSE_UNCHANGED:
		var inputs := _inputs(sk)
		if not inputs.is_empty() and inputs == _last_inputs:
			if native != null: native.eye_rewrite(sk)
			else:
				for b in _written: sk.set_bone_pose(b, _written[b])
			return
		# Stored with copies: the expression dictionaries are edited in place by their owners.
		if not inputs.is_empty():
			for k in range(10, 13): inputs[k] = (inputs[k] as Dictionary).duplicate()
		_last_inputs = inputs
	if native != null:
		var scalars := PackedFloat64Array([closure, expression_closure, target_weight, convergence_degrees])
		scalars.append_array(_native_asymmetry())
		native.eye_process(sk, scalars, gaze, _offset, target_world, expression_eyes, expression_brows,
			expression_ears, surface_update)
		return
	_written.clear()
	var lid_closure := 1.0 - (1.0 - clampf(closure, 0.0, 1.0)) * (1.0 - clampf(expression_closure, 0.0, 1.0))
	for i in _lid_open:
		var opened: Transform3D = _lid_open[i]
		# Blend the original eye poses as a convex mix, then close the actual lids.
		# Blinks must still reach the same native closed pose under every expression.
		var total := 0.0
		for shape in expression_eyes:
			if _eye_shapes.get(shape,{}).has(i):total+=clampf(expression_eyes[shape],0.0,1.0)
		var mass := maxf(0.0,1.0-total)
		for shape in expression_eyes:
			if not _eye_shapes.get(shape,{}).has(i):continue
			var weight := clampf(float(expression_eyes[shape]),0.0,1.0)
			if weight < .0001:continue
			mass+=weight
			opened=opened.interpolate_with(_eye_shapes[shape][i],weight/mass)
		var pose: Transform3D = opened.interpolate_with(_lid_closed[i], lid_closure)
		_write(sk, i, pose)
	# Apply only original brow/forehead deltas, above the freshly reset blink pose.
	for shape in _brow_shapes:
		var weight := clampf(float(expression_brows.get(shape,0.0)),0.0,1.0)*(1.0-lid_closure)
		if weight < .0001: continue
		for b in _brow_shapes[shape]:
			var delta: Transform3D = _brow_shapes[shape][b]
			var pose := sk.get_bone_pose(b)
			pose.origin += delta.origin * weight
			pose.basis = pose.basis * Basis(Quaternion.IDENTITY.slerp(delta.basis.get_rotation_quaternion(),weight))
			_write(sk, b,pose)
	# Native ear rotations add to this frame's source pose; no persistent bone reset.
	for shape in expression_ears:
		var weight := clampf(float(expression_ears[shape]),0.0,1.0)
		if weight < .0001:continue
		for b in _ear_shapes.get(shape,{}):
			var delta:Transform3D=_ear_shapes[shape][b]
			var pose:=sk.get_bone_pose(b)
			pose.origin+=delta.origin*weight
			pose.basis=pose.basis*Basis(Quaternion.IDENTITY.slerp(delta.basis.get_rotation_quaternion(),weight))
			_write(sk, b,pose)
	var aim := gaze
	if target_weight > 0.0 and _head_bone >= 0:
		# Read the actual linked head inside its modifier, after body/neck motion.
		# Native head forward is +Z; this avoids guessing native/XR yaw signs.
		var frame := sk.global_transform * sk.get_bone_global_pose(_head_bone)
		var direction := frame.affine_inverse() * target_world - _eye_center_head
		if direction.length_squared() > .0001:
			var directed := Vector2(atan2(direction.x, direction.z),
				atan2(direction.y, Vector2(direction.x, direction.z).length()))
			aim = aim.lerp(directed, clampf(target_weight,0.0,1.0))
	if surface_update.is_valid():
		surface_update.call(surface_angles(0,aim + _offset),surface_angles(1,aim + _offset),lid_closure)
	for side_index in _eye_bones.size():
		var bone := _eye_bones[side_index]
		if bone < 0: continue
		_write(sk, bone, eye_pose(side_index, aim + _offset))


## Everything a full run reads besides constants and the brow/ear source poses (which only a playing
## head clip moves). Empty while a head clip plays (never reused).
func _inputs(sk: Skeleton3D) -> Array:
	if _player != null and is_instance_valid(_player) and _player.is_playing(): return []
	var aim_frame := Transform3D.IDENTITY
	if target_weight > 0.0 and _head_bone >= 0:
		aim_frame = sk.global_transform * sk.get_bone_global_pose(_head_bone)
	return [closure, expression_closure, target_weight, convergence_degrees, gaze, _offset, cross_inward,
		_native_asymmetry(), target_world if target_weight > 0.0 else Vector3.ZERO, aim_frame,
		expression_eyes, expression_brows, expression_ears, surface_update]


## Radians both eyes turn inward toward something right at her nose (a booping finger,
## hybrid_mare.gd): the same per-eye path as background_eye_motion.gd's asymmetric gaze, which the
## native eye pass applies (angles * 0.2 plus the inward shift). 0 = ordinary gaze.
var cross_inward := 0.0

func surface_angles(side_index: int, angles: Vector2) -> Vector2:
	if cross_inward > 0.0:
		var side := 1.0 if side_index == 0 else -1.0
		return angles * 0.2 + Vector2(-side * cross_inward, 0.0)
	return angles


## For the native pass: [1 when surface_angles() shifts the eyes, inward, vertical radians].
func _native_asymmetry() -> PackedFloat64Array:
	return PackedFloat64Array([1.0 if cross_inward > 0.0 else 0.0, cross_inward, 0.0])


func eye_pose(side_index: int, angles: Vector2) -> Transform3D:
	var side := 1.0 if side_index == 0 else -1.0
	var bone := _eye_bones[side_index]
	var rest := _rest_globals[bone]
	# Least-squares quadric of the devkit IKEye helper (4097 vertices/side),
	# transformed from Blender Z-up to native skeleton space. No new eye shape.
	var center := Vector3(side * 0.07155437, 0.91847255, 0.31813008)
	var metric := Basis(Vector3(477.04993, 0.0, side * 378.63708),
		Vector3(0.0, 60.65196, 0.0), Vector3(side * 378.63708, 0.0, 493.82285))
	var neutral := (metric * (rest.origin - center)).normalized()
	var yaw := -side * deg_to_rad(convergence_degrees) + clampf(angles.x, -0.08, 0.08)
	var normal := (Basis(Vector3.UP, yaw) * neutral).normalized()
	# The devkit helper is a tall ellipsoid, so equal normal angles cause far
	# more vertical travel. Limit it to the visible socket instead of rolling
	# the pupil almost completely behind a lid on an ordinary upward glance.
	normal.y = clampf(normal.y + clampf(angles.y, -.25, .25) * .2, -.06, .06)
	normal = normal.normalized()
	var inverse := metric.inverse()
	var surface := center + inverse * normal / sqrt(normal.dot(inverse * normal))
	# Calibrate the fitted surface to the exact authored rest (fit residual <2%).
	var rest_surface := center + inverse * neutral / sqrt(neutral.dot(inverse * neutral))
	var posed := Transform3D(Basis(Quaternion(neutral, normal)) * rest.basis,
		rest.origin + surface - rest_surface)
	return _rest_globals[_parents[bone]].affine_inverse() * posed


## A cached distant face must not depend on modifier callback timing, a blink,
## or where the first instance happened to look. Build a snapshot without touching
## the live skeleton: Skeleton3D restores modifier writes after rendering.
func neutral_global_poses() -> Array[Transform3D]:
	var sk := get_skeleton()
	var poses: Array[Transform3D] = []
	for b in sk.get_bone_count():
		poses.append(_lid_open.get(b, sk.get_bone_pose(b)))
	for side in _eye_bones.size():
		if _eye_bones[side] >= 0:
			poses[_eye_bones[side]] = eye_pose(side, Vector2.ZERO)
	return FK.forward_kinematics(_parents, poses)


func _bind_brows(player: AnimationPlayer) -> void:
	var sk := get_skeleton()
	for name in ["brows_angry","brows_sad","brows_wide","brows_confused_left","brows_happy_right"]:
		if not player.has_animation(name): continue
		var anim := player.get_animation(name)
		var best := -1.0
		var chosen: Dictionary = {}
		# Native pose clips include returns to neutral; sample their maximum authored pose.
		for sample_index in 17:
			var pose := _sample(anim,anim.length*sample_index/16.0)
			var deltas: Dictionary = {}
			var amount := 0.0
			for b in _lid_open:
				var bone := sk.get_bone_name(b)
				if not (bone.begins_with("mFaceEyebrow") or bone.begins_with("mFaceForehead")): continue
				var delta := Transform3D(_rests[b].basis.inverse()*pose[b].basis,pose[b].origin-_rests[b].origin)
				amount += delta.origin.length()+absf(delta.basis.get_rotation_quaternion().get_angle())*.02
				deltas[b]=delta
			if amount > best: best=amount;chosen=deltas
		_brow_shapes[name]=chosen


func _bind_expression_shapes(player: AnimationPlayer) -> void:
	var sk := get_skeleton()
	for name in ["eyes_mad","eyes_sad","eyes_wide","ears_alert","ears_side","ears_agitated"]:
		if not player.has_animation(name):continue
		var anim := player.get_animation(name)
		var ear: bool = name.begins_with("ears_")
		var best := -INF
		var chosen:Dictionary={}
		for sample_index in 17:
			var pose:=_sample(anim,anim.length*sample_index/16.0)
			var amount:=0.0
			var values:Dictionary={}
			for b in sk.get_bone_count():
				var bone:=sk.get_bone_name(b)
				if ear:
					if not bone.begins_with("mFaceEar"):continue
					var delta:=Transform3D(_rests[b].basis.inverse()*pose[b].basis,pose[b].origin-_rests[b].origin)
					values[b]=delta
					amount+=absf(delta.basis.get_rotation_quaternion().get_angle())
				elif _lid_open.has(b) and (bone.begins_with("mFaceEyeLid") or bone.begins_with("mFaceEyecorner") or bone.begins_with("mFaceCheekUpper")):
					values[b]=pose[b]
			if not ear:
				var globals:=FK.forward_kinematics(_parents,pose)
				for side in ["Left","Right"]:
					var upper:=sk.find_bone("mFaceEyeLidUpper"+side)
					var lower:=sk.find_bone("mFaceEyeLidLower"+side)
					amount+=(globals[upper].origin.y-globals[lower].origin.y)*(1.0 if name=="eyes_wide" else -1.0)
			if amount>best:best=amount;chosen=values
		if ear:_ear_shapes[name]=chosen
		else:_eye_shapes[name]=chosen
	_bind_pinned_ears(sk)


## Flustered ears (dev 2026-09-28): folded back along the skull. No source clip has this pose,
## so each ear root turns back about the head's side axis and the ear tip follows it.
const EAR_PIN_ANGLE := deg_to_rad(55.0)
func _bind_pinned_ears(sk: Skeleton3D) -> void:
	var head := sk.find_bone("mHead")
	if head < 0: return
	var side_axis: Vector3 = _rest_globals[head].basis.x.normalized()
	var back: Vector3 = -_rest_globals[head].basis.z.normalized()
	var pinned := {}
	for side in ["Left", "Right"]:
		var root := sk.find_bone("mFaceEar1" + side)
		var tip := sk.find_bone("mFaceEar2" + side)
		if root < 0 or tip < 0: continue
		var frame: Basis = _rest_globals[root].basis.orthonormalized()
		var along: Vector3 = (_rest_globals[tip].origin - _rest_globals[root].origin).normalized()
		var turn := Basis(side_axis, EAR_PIN_ANGLE)
		var other := Basis(side_axis, -EAR_PIN_ANGLE)
		if (other * along).dot(back) > (turn * along).dot(back): turn = other
		pinned[root] = Transform3D(frame.inverse() * turn * frame, Vector3.ZERO)
	if not pinned.is_empty(): _ear_shapes["ears_pinned"] = pinned


func _process_modification() -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process_modification()
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("eye_motion", started)


func _write(sk: Skeleton3D, bone: int, pose: Transform3D) -> void:
	sk.set_bone_pose(bone, pose)
	_written[bone] = pose
