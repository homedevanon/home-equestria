extends PonyIdleBodyNative
## Standing body life on the NEAR clip tier (dev 2026-10-14: "her head moves i guess but not her
## body"). The NEAR tier plays the baked stand, one frozen pose, and ClipHead only brings the neck
## and head to life; this layers the rest of what HERO's solver shows on top of that pose:
## - breath: the loins lift the back a hair and the withers level it again
##   (pony_secondary_motion.gd apply_pose(), same bones, same amount);
## - weight: her barrel rolls onto the side she settles on and tips a little back or forward,
##   following the secondary's standing weight shifts (pony_secondary_motion.gd shift_weight()).
##   The four leg roots (flanks, shoulders) turn back by the same amount, so the legs keep hanging
##   as the clip posed them and the hooves stay where they stood (a few millimetres at most).
## Rotations only, every bone through pony_joint_limits. The secondary's values come on the 20 Hz
## logic beat and are eased here every step. hybrid_mare.gd switches it on only while the stand
## clip plays in NEAR within 15 m of the player, with no posture, hold, carry or kiss on her, and
## fades it out before switching it off. Placed right after ClipHead.
##
## Native pony step (2026-11-21, lane body): the state lives in the native base
## PonyIdleBodyNative (native/pony_solver/src/body_modifiers_native.cpp) under the names it had
## here: pony, wanted, fade, _hips, _hips_parent, _legs, _leg_parents, _model_to_skeleton,
## _frame_ready, _roll, _pitch, _breath, applied_roll, _last_pass_frame (and _breath_arch, the
## secondary's BREATH_ARCH). Its native_step() is the pass below in C++; it declines, changing
## nothing, when her joint limits are not on the native solver, and _script_step() runs instead.
## Rollback: NATIVE_STEP = false (or `--native-body=off`; `--native-body=on` or
## `--native-body=idle` turns it on for one run).
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under --profile-cpu / the benches
const SECONDARY := preload("res://world/characters/locomotion/pony_secondary_motion.gd")
const LEG_ROOTS := ["pony_flank_L", "pony_flank_R", "pony_shoulder_L", "pony_shoulder_R"]
## Pitch (radians) per metre of the secondary's back/forward weight offset.
const PITCH_PER_METRE := 0.8
const FADE_SECONDS := 0.6
const NATIVE_STEP := true  # rollback switch; true only after parity passes
static var _native_on: bool = (NATIVE_STEP and not ("--native-body=off" in OS.get_cmdline_user_args())) \
		or "--native-body=on" in OS.get_cmdline_user_args() or "--native-body=idle" in OS.get_cmdline_user_args()

## Parked rigs (0.1.0 perf pass): while PonyCrowd hides her and her rigs are parked
## (pony_locomotion.gd HIDDEN_RIG_PARK), a pass that still comes (a pose write on the parked rig
## re-runs the modifiers) is skipped: nothing of her draws. Shown again, catch_up() does at once
## what the skipped passes would have done (fade and easing over the time she was hidden), so the
## first frame seen is the body life she would have shown all along. Rollback: HIDDEN_SKIP = false.
## `_last_pass_frame` (native) is the physics frame of the last pass that ran (catch_up's clock).
const HIDDEN_SKIP := true
## Physics frame whose pass the native body batch took over (rig_batch.gd); this script's pass
## returns at once in that frame. 0: never.
var rig_batch_step := 0


func _init() -> void:
	_breath_arch = SECONDARY.BREATH_ARCH


func bind(skeleton: Skeleton3D) -> void:
	# Built here and handed over whole (the arrays live in the native base).
	var legs: Array[int] = []
	var leg_parents: Array[int] = []
	_hips = skeleton.find_bone("pony_hips")
	_hips_parent = skeleton.get_bone_parent(_hips) if _hips >= 0 else -1
	for name: String in LEG_ROOTS:
		var bone := skeleton.find_bone(name)
		if bone < 0 or skeleton.get_bone_parent(bone) < 0:
			_hips = -1
			break
		legs.append(bone)
		leg_parents.append(skeleton.get_bone_parent(bone))
	_legs = legs
	_leg_parents = leg_parents


## Back on screen after a parked spell (hybrid_mare.gd _rigs_unparked, after `wanted` is current):
## the fade moves on by the time she was hidden, and the eased weight and breath move toward the
## secondary's values as the skipped passes would have, so nothing eases in once she is seen.
func catch_up() -> void:
	if not HIDDEN_SKIP or _last_pass_frame < 0: return
	var elapsed := float(Engine.get_physics_frames() - _last_pass_frame) / float(Engine.physics_ticks_per_second)
	_last_pass_frame = Engine.get_physics_frames()
	if elapsed <= 0.0: return
	fade = move_toward(fade, 1.0 if wanted else 0.0, elapsed / FADE_SECONDS)
	var secondary: RefCounted = pony.secondary if is_instance_valid(pony) else null
	if secondary == null: return
	var ease := 1.0 - exp(-elapsed / 0.08)
	var offset: Vector3 = secondary.offset
	_roll = lerpf(_roll, float(secondary.roll), ease)
	_pitch = lerpf(_pitch, offset.z * PITCH_PER_METRE, ease)
	_breath = lerpf(_breath, float(secondary.breath), ease)


func _process_modification_with_delta(delta: float) -> void:
	if rig_batch_step > 0 and rig_batch_step == Engine.get_physics_frames() and Engine.is_in_physics_frame(): return
	if HIDDEN_SKIP and _native_on:
		var started := Time.get_ticks_usec() if PROFILE.enabled else 0
		if native_step(delta):
			if PROFILE.enabled and fade > 0.0 and _hips >= 0 and _last_pass_frame == Engine.get_physics_frames():
				PROFILE.record("idle_body", started)
			return
	_script_step(delta)


## The pass in GDScript: the fallback of native_step() and the rollback path.
func _script_step(delta: float) -> void:
	if HIDDEN_SKIP and is_instance_valid(pony) and pony.get(&"_hidden_parked") == true: return
	_last_pass_frame = Engine.get_physics_frames()
	fade = move_toward(fade, 1.0 if wanted else 0.0, delta / FADE_SECONDS)
	if fade <= 0.0 or _hips < 0 or not is_instance_valid(pony): return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	_apply(delta)
	if PROFILE.enabled: PROFILE.record("idle_body", started)


func _apply(delta: float) -> void:
	var skeleton := get_skeleton()
	var secondary: RefCounted = pony.secondary
	var limits: RefCounted = pony.joint_limits
	if skeleton == null or secondary == null or limits == null: return
	if not _frame_ready:
		var pivot: Node3D = pony.pivot
		if pivot == null or not pivot.is_inside_tree(): return
		# Model frame (the pivot: forward -Z, up +Y) to skeleton space, rotation only.
		_model_to_skeleton = (pivot.global_basis.orthonormalized().inverse() * skeleton.global_basis.orthonormalized()).inverse()
		_frame_ready = true
	var ease := 1.0 - exp(-delta / 0.08)
	var offset: Vector3 = secondary.offset
	_roll = lerpf(_roll, float(secondary.roll), ease)
	_pitch = lerpf(_pitch, offset.z * PITCH_PER_METRE, ease)
	_breath = lerpf(_breath, float(secondary.breath), ease)
	applied_roll = maxf(applied_roll, absf(_roll * fade))
	# The legs' orientation as the clip (and any earlier modifier) left it.
	var leg_globals: Array[Basis] = []
	for bone: int in _legs:
		leg_globals.append(skeleton.get_bone_global_pose(bone).basis)
	# Weight: roll and tip the whole body about the hips.
	var turn := _model_to_skeleton * Basis.from_euler(Vector3(_pitch, 0.0, _roll) * fade) * _model_to_skeleton.inverse()
	var parent := skeleton.get_bone_global_pose(_hips_parent).basis.orthonormalized() if _hips_parent >= 0 else Basis.IDENTITY
	var hips := skeleton.get_bone_pose(_hips)
	hips.basis = parent.inverse() * turn * parent * hips.basis
	skeleton.set_bone_pose(_hips, hips)
	# Breath along the back, as the solver tier's secondary applies it.
	var spine: Array[int] = secondary._spine
	var frames: Array[Basis] = secondary._spine_frames
	if spine.size() == 2 and absf(_breath) > 0.0005:
		for i in 2:
			var bone := spine[i]
			var frame := frames[i]
			var pitch: float = SECONDARY.BREATH_ARCH * _breath * fade * (1.0 if i == 0 else -1.0)
			var pose := skeleton.get_bone_pose(bone)
			pose.basis = limits.constrain(bone, frame.inverse() * Basis(Vector3.RIGHT, pitch) * frame * pose.basis)
			skeleton.set_bone_pose(bone, pose)
	# The legs hang as before: each root turns back under its moved parent.
	for i in _legs.size():
		var bone: int = _legs[i]
		var moved := skeleton.get_bone_global_pose(_leg_parents[i]).basis
		var pose := skeleton.get_bone_pose(bone)
		pose.basis = limits.constrain(bone, moved.inverse() * leg_globals[i])
		skeleton.set_bone_pose(bone, pose)
