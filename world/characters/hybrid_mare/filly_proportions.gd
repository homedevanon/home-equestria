extends PonyFillyProportionsNative
## Shared head width, filly neck and wings. Runs after the locomotion/posture modifiers;
## the neck link carries the posed motion onto the original OpenPony head, face and mane.
## Overall size is body_scale; thicker legs are baked into body_shapes/filly.scn.
##
## Native pony step (2026-11-21, lane body): the values live in the native base
## PonyFillyProportionsNative (native/pony_solver/src/body_modifiers_native.cpp), still exported
## under their names: neck_scale (default 0.9), head_scale (1.0; cancels inherited neck shrink on
## the head bone: the intact head is enlarged as a node frame and the body neck loft is fitted
## offline, so do not scale this bone to enlarge the face), head_width (1.0; narrows the posed head
## along the model-rest X axis, leaving its pivot and source rig intact) and wing_scale (1.0;
## folded wings, identity.wing_scale; Scootaloo's are comically small), and the bones found in
## _ready(): _neck, _head, _local_width_basis, _wings. native_step() is the pass below in C++.
## Rollback: NATIVE_STEP = false (or `--native-body=off`; `--native-body=on` or
## `--native-body=filly` turns it on for one run).
const NATIVE_STEP := false  # rollback switch; true only after parity passes
static var _native_on: bool = (NATIVE_STEP and not ("--native-body=off" in OS.get_cmdline_user_args())) \
		or "--native-body=on" in OS.get_cmdline_user_args() or "--native-body=filly" in OS.get_cmdline_user_args()
## Physics frame whose pass the native body batch took over (rig_batch.gd); this script's pass
## returns at once in that frame. 0: never.
var rig_batch_step := 0

func _ready() -> void:
	var sk := get_skeleton()
	if sk == null: return
	_neck = sk.find_bone("pony_neck1")
	_head = sk.find_bone("pony_head")
	if _head >= 0:
		var rest_basis := sk.get_bone_global_rest(_head).basis.orthonormalized()
		_local_width_basis = rest_basis.inverse() * Basis.from_scale(Vector3(head_width, 1.0, 1.0)) * rest_basis
	# Built here and handed over whole (the array lives in the native base).
	var wings := PackedInt32Array()
	for wing in ["pony_foldedWing_L", "pony_foldedWing_R"]:
		if sk.find_bone(wing) >= 0: wings.append(sk.find_bone(wing))
	_wings = wings

func _process_modification() -> void:
	if rig_batch_step > 0 and rig_batch_step == Engine.get_physics_frames() and Engine.is_in_physics_frame(): return
	if _native_on and native_step(): return
	_script_step()

## The pass in GDScript: the fallback of native_step() and the rollback path.
func _script_step() -> void:
	var sk := get_skeleton()
	if sk == null or _neck < 0 or _head < 0: return
	# Scale propagates down the chain: the head's own factor divides out the neck's.
	if not is_equal_approx(neck_scale, 1.0):
		sk.set_bone_pose_scale(_neck, sk.get_bone_pose_scale(_neck) * neck_scale)
	var head_factor := head_scale / neck_scale
	if not is_equal_approx(head_factor, 1.0):
		sk.set_bone_pose_scale(_head, sk.get_bone_pose_scale(_head) * head_factor)
	if not is_equal_approx(head_width, 1.0):
		# Conjugate model-rest X into the head frame; keep all existing posed scale.
		var posed_head := sk.get_bone_global_pose(_head)
		posed_head.basis = posed_head.basis * _local_width_basis
		sk.set_bone_global_pose(_head, posed_head)
	if not is_equal_approx(wing_scale, 1.0):
		for wing in _wings: sk.set_bone_pose_scale(wing, sk.get_bone_pose_scale(wing) * wing_scale)
