extends SkeletonModifier3D
## Full-body IK for the ValveBiped player avatar. Small and rig-specific on
## purpose: the vendored renik solvers assume VRM-convention bone axes and
## fold this Source-derived rig through itself (verified by render). What a
## VR body needs is textbook: place the pelvis, bend the spine toward the
## head target, then analytic two-bone IK per limb. Everything below works
## in rest-relative rotations, so the source rig's axis conventions never
## matter.
##
## Targets are plain Node3D markers, driven every frame by anon_body.gd.

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
@export var pelvis_bone: StringName = &"Hips"
@export var head_bone: StringName = &"Head"
@export var head_target: Node3D
@export var hip_target: Node3D
@export var left_hand_target: Node3D
@export var right_hand_target: Node3D
@export var left_foot_target: Node3D
@export var right_foot_target: Node3D

## How much of the head-target orientation the head bone takes (1 = rigid).
@export_range(0.0, 1.0, 0.01) var head_orient := 1.0
## Preferred reach before shifting the shoulder. This is a body-compensation
## threshold, never a clamp on tracked hand position.
@export var max_arm_stretch := 1.25
var _stretch_demand := 0.0
var _poles: Dictionary = {}
var _arm_axes: Dictionary = {}

var _ready_ids := false
var _pelvis := -1
var _head := -1
var _spine_chain: PackedInt32Array          # pelvis-exclusive chain up to head
var _spine_weights: PackedFloat64Array
## Fixed rig metadata, bound at the same lifetime as the original rest transforms.
## Live global poses, targets, calibration scale and pole history are never cached here.
var _parents: PackedInt32Array
var _rest_offsets: PackedVector3Array
var _rest_axes: PackedVector3Array
var _rest_lengths: PackedFloat64Array
var _rest_bases: Array[Basis] = []
var _limbs: Array = []                      # [upper, lower, leaf, target, pole]
## Animated desktop body (player/anon_motion.gd via anon_body.gd): world points the knees bend
## toward, keyed "left"/"right"; empty uses the fixed forward knee pole. While animated the legs
## keep their native length (the clip's feet are reachable by construction).
var knee_hints: Dictionary = {}
var leg_stretch := true


func _resolve(skel: Skeleton3D) -> void:
	_pelvis = skel.find_bone(pelvis_bone)
	_head = skel.find_bone(head_bone)
	if _pelvis == -1 or _head == -1:
		return
	_spine_chain = PackedInt32Array()
	var b := _head
	while b != -1 and b != _pelvis:
		_spine_chain.insert(0, b)
		b = skel.get_bone_parent(b)
	_spine_weights.resize(_spine_chain.size())
	for i in _spine_chain.size():
		_spine_weights[i] = (float(i + 1) / float(_spine_chain.size())) * .8
	var count := skel.get_bone_count()
	_parents.resize(count); _rest_offsets.resize(count); _rest_axes.resize(count)
	_rest_lengths.resize(count); _rest_bases.resize(count)
	for i in count:
		_parents[i] = skel.get_bone_parent(i)
		var offset := skel.get_bone_rest(i).origin
		_rest_offsets[i] = offset
		_rest_axes[i] = offset.normalized()
		_rest_lengths[i] = offset.length()
		# Global rest bases are the orientation offsets: a target whose
		# basis is plain view-yaw must reproduce the rest orientation.
		_rest_bases[i] = skel.get_bone_global_rest(i).basis

	# Limb table: [upper, lower, leaf, target, pole direction in hip space].
	# Elbows point back and down, knees point forward. Standard humanoid
	# bone names, produced by tools/convert_anon_humanoid.py.
	_limbs = [
		# The rig rests facing +Z, so its LEFT is +X. Arms use the sign only;
		# _arm_pole chooses a relaxed bend plane for the actual wrist position.
		[_find(skel, "LeftUpperArm"), _find(skel, "LeftLowerArm"),
			_find(skel, "LeftHand"), left_hand_target, Vector3.RIGHT],
		[_find(skel, "RightUpperArm"), _find(skel, "RightLowerArm"),
			_find(skel, "RightHand"), right_hand_target, Vector3.LEFT],
		[_find(skel, "LeftUpperLeg"), _find(skel, "LeftLowerLeg"),
			_find(skel, "LeftFoot"), left_foot_target, Vector3(0.0, 0.3, 1.0)],
		[_find(skel, "RightUpperLeg"), _find(skel, "RightLowerLeg"),
			_find(skel, "RightFoot"), right_foot_target, Vector3(0.0, 0.3, 1.0)],
	]
	_ready_ids = true


func _find(skel: Skeleton3D, suffix: String) -> int:
	for i in skel.get_bone_count():
		if skel.get_bone_name(i).ends_with(suffix):
			return i
	return -1


func _process_modification() -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_modification_step()
	if started > 0: CPU_PROFILE.record("anon_ik", started)

func _modification_step() -> void:
	# A deferred skeleton pass may outlive removal of the owning world.
	if not is_inside_tree():
		return
	var skel := get_skeleton()
	if not is_instance_valid(skel) or not skel.is_inside_tree():
		return
	if not _ready_ids:
		_resolve(skel)
		if not _ready_ids:
			return
	if not is_instance_valid(head_target) or not is_instance_valid(hip_target):
		return
	if not head_target.is_inside_tree() or not hip_target.is_inside_tree():
		return

	var to_skel: Transform3D = skel.global_transform.affine_inverse()
	var head_t: Transform3D = (to_skel * head_target.global_transform).orthonormalized()
	var hip_t: Transform3D = (to_skel * hip_target.global_transform).orthonormalized()
	# One NaN here used to fan out into every bone write below, each printing an
	# engine error: ~100 lines per frame, the hitch dev felt on a tracking drop.
	if not to_skel.is_finite() or not head_t.is_finite() or not hip_t.is_finite():
		return
	var delta := get_process_delta_time()
	var leg_pole_blend := 1.0 - exp(-delta / .08)

	# --- pelvis: position from the hip target, yaw from its basis, and the
	# rest orientation on top so the rig's own axes never matter.
	var pelvis_pose := Transform3D(
		hip_t.basis * _rest_bases[_pelvis], hip_t.origin)
	_write_global(skel, _pelvis, pelvis_pose)

	# --- spine: one weighted aim pass, root to tip. Each joint rotates a
	# share of the remaining error, so the bend distributes naturally.
	var n := _spine_chain.size()
	# The last entry is the head itself: its head-to-tip vector is always zero.
	# Keep its share in the original weights, but avoid that provably empty pass.
	for ci in maxi(0, n - 1):
		var bone_id := _spine_chain[ci]
		var parent_g: Transform3D = skel.get_bone_global_pose(_parents[bone_id])
		var cur: Transform3D = parent_g * skel.get_bone_pose(bone_id)
		# Where the head lands if the rest of the chain stays as-is.
		var tip: Vector3 = (skel.get_bone_global_pose(_head)).origin
		var to_tip: Vector3 = tip - cur.origin
		var to_target: Vector3 = head_t.origin - cur.origin
		if to_tip.length() < 0.001 or to_target.length() < 0.001:
			continue
		var full := Quaternion(to_tip.normalized(), to_target.normalized())
		var partial := Quaternion.IDENTITY.slerp(full, _spine_weights[ci])
		var new_basis: Basis = Basis(partial) * cur.basis
		_write_global(skel, bone_id, Transform3D(new_basis, cur.origin))

	# Head bone takes the target orientation (rest-relative), so looking
	# around turns the head, not just the camera.
	var head_g: Transform3D = skel.get_bone_global_pose(_head)
	var head_basis: Basis = head_t.basis * _rest_bases[_head]
	head_g.basis = head_g.basis.slerp(head_basis, head_orient).orthonormalized()
	_write_global(skel, _head, head_g)
	# The observed head anchors the inferred torso. A short spine may not
	# pull the shoulders/head away from the headset while reclining.
	var pelvis_g := skel.get_bone_global_pose(_pelvis)
	var head_shift := head_t.origin - skel.get_bone_global_pose(_head).origin
	# Animated legs keep their length, so the body follows the camera only as far as both planted
	# feet still reach; the hidden head may then sit a few centimetres off the eye.
	if not leg_stretch: head_shift = _reachable_shift(skel, to_skel, head_shift)
	pelvis_g.origin += head_shift
	_write_global(skel, _pelvis, pelvis_g)

	# --- limbs: analytic two-bone IK.
	for limb in _limbs:
		var upper: int = limb[0]
		var lower: int = limb[1]
		var leaf: int = limb[2]
		var target: Node3D = limb[3]
		if upper == -1 or lower == -1 or leaf == -1 or not is_instance_valid(target):
			continue
		if not target.is_inside_tree():
			continue
		var target_t := (to_skel * target.global_transform).orthonormalized()
		if not target_t.is_finite():
			continue
		var is_arm: bool = absf((limb[4] as Vector3).x) > 0.5
		var pole_dir: Vector3 = (hip_t.basis * (limb[4] as Vector3)).normalized()
		if is_arm:
			var shoulder: Vector3 = skel.get_bone_global_pose(upper).origin
			pole_dir = _arm_pole(upper, shoulder, target_t, hip_t.basis,
				signf((limb[4] as Vector3).x), delta)
		else:
			var hint: Variant = knee_hints.get("left" if upper == _limbs[2][0] else "right")
			if hint is Vector3 and (hint as Vector3).is_finite():
				var knee: Vector3 = to_skel * (hint as Vector3) - skel.get_bone_global_pose(upper).origin
				if knee.length_squared() > .000001: pole_dir = knee.normalized()
			if _poles.has(upper):
				pole_dir = (_poles[upper] as Vector3).slerp(pole_dir, leg_pole_blend)
			_poles[upper] = pole_dir
		if is_arm:
			_solve_tracked_arm(skel,upper,lower,leaf,target_t,pole_dir)
		else:
			_solve_two_bone(skel,upper,lower,leaf,target_t,pole_dir,1.0,max_arm_stretch if leg_stretch else 1.0)
	_stretch_demand = 0.0


## The largest part of a pelvis shift that keeps both leg targets within native leg reach
## (skeleton units). A shift that only brings the hips closer to the feet always applies.
func _reachable_shift(skel: Skeleton3D, to_skel: Transform3D, shift: Vector3) -> Vector3:
	if _leg_slack(skel, to_skel, shift) >= 0.0: return shift
	var low := 0.0
	var high := 1.0
	if _leg_slack(skel, to_skel, Vector3.ZERO) < 0.0:
		# Already out of reach: allow only the part of the shift that moves the hips down.
		return Vector3(0.0, minf(shift.y, 0.0), 0.0)
	for i in 6:
		var mid := (low + high) * .5
		if _leg_slack(skel, to_skel, shift * mid) >= 0.0: low = mid
		else: high = mid
	return shift * low

func _leg_slack(skel: Skeleton3D, to_skel: Transform3D, shift: Vector3) -> float:
	var slack := INF
	for li in [2, 3]:
		if li >= _limbs.size(): continue
		var limb: Array = _limbs[li]
		var target: Node3D = limb[3]
		if int(limb[0]) == -1 or int(limb[2]) == -1 or not is_instance_valid(target) or not target.is_inside_tree(): continue
		var hip: Vector3 = skel.get_bone_global_pose(int(limb[0])).origin + shift
		var foot: Vector3 = to_skel * target.global_position
		var length: float = _rest_lengths[int(limb[1])] + _rest_lengths[int(limb[2])] - .002
		slack = minf(slack, length - hip.distance_to(foot))
	return slack if slack != INF else 0.0


## Solve the entire connected chain to the observed wrist. The old solver
## calculated stretched lengths, then _write_global stripped the scale; its
## final wrist was still the short FK endpoint. Write all three solved joint
## positions explicitly so the wrist and fingers keep their original size.
func _solve_tracked_arm(skel:Skeleton3D,upper:int,lower:int,leaf:int,
		target:Transform3D,pole_dir:Vector3)->void:
	var upper_g := skel.get_bone_global_pose(upper)
	var a := upper_g.origin
	var u := _rest_lengths[lower]
	var l := _rest_lengths[leaf]
	var axis := target.origin-a
	var distance := axis.length()
	var direction := axis/distance if distance>.00001 else pole_dir.normalized()
	# Shoulder girdle yields before the sleeve must elongate. Beyond calibrated
	# reach the remaining shoulder translation keeps the endpoint authoritative.
	var excess := maxf(0,distance-(u+l)*.98)
	var shoulder_shift := minf(.08,excess*.6)
	shoulder_shift=maxf(shoulder_shift,distance-(u+l)*max_arm_stretch+.002)
	a += direction*shoulder_shift
	distance = target.origin.distance_to(a)
	var minimum := absf(u-l)+.002
	if distance<minimum:
		a-=direction*(minimum-distance)
		distance=minimum
	var stretch := maxf(1.0,(distance+.002)/(u+l))
	u*=stretch;l*=stretch
	var cosine := clampf((u*u+distance*distance-l*l)/(2*u*distance),-1,1)
	var side := pole_dir-direction*pole_dir.dot(direction)
	if side.length_squared()<.00001:
		side=direction.cross(Vector3.UP if absf(direction.y)<.9 else Vector3.RIGHT)
	side=side.normalized()
	var elbow := a+direction*(u*cosine)+side*(u*sqrt(maxf(0,1-cosine*cosine)))
	var upper_axis := (upper_g.basis * _rest_offsets[lower]).normalized()
	upper_g=Transform3D(Basis(Quaternion(upper_axis,(elbow-a).normalized()))*upper_g.basis.orthonormalized(),a)
	_write_global(skel,upper,upper_g)
	var lower_g := skel.get_bone_global_pose(lower)
	var lower_axis := (lower_g.basis * _rest_offsets[leaf]).normalized()
	lower_g=Transform3D(Basis(Quaternion(lower_axis,(target.origin-elbow).normalized()))*lower_g.basis.orthonormalized(),elbow)
	_write_global(skel,lower,lower_g)
	_write_global(skel,leaf,Transform3D(target.basis * _rest_bases[leaf],target.origin))


## Bend below the shoulder-to-wrist line, with a little room beside the ribs.
## Raising the wrist changes that line naturally; it must not independently
## lift the pole until the upper arm sticks straight out sideways. The small
## back-of-hand contribution lets pronation influence the elbow without letting
## a controller twist flip the whole arm. Targets already include hand offsets.
func _arm_pole(key: int, shoulder: Vector3, target: Transform3D,
		hip_basis: Basis, outward_sign: float, delta: float) -> Vector3:
	var axis: Vector3 = target.origin - shoulder
	if axis.length_squared() < 0.000001:
		axis = _arm_axes.get(key, hip_basis.z)
	axis = axis.normalized()
	var down := -hip_basis.y
	var outward := hip_basis.x * outward_sign
	var back := -hip_basis.z
	var preferred := down + outward * 0.30 + back * 0.18 + target.basis.y * 0.08
	var desired := preferred - axis * preferred.dot(axis)
	var previous: Vector3 = _poles.get(key, Vector3.ZERO)
	if previous.length_squared() > 0.0:
		# Carry the previous plane with the reach axis. Merely interpolating
		# unprojected poles can cross the axis and invert a nearly straight arm.
		var old_axis: Vector3 = _arm_axes.get(key, axis)
		var transport := Quaternion(old_axis, axis) if old_axis.dot(axis) > -0.9999 \
			else Quaternion(previous, PI)
		previous = transport * previous
		previous = (previous - axis * previous.dot(axis)).normalized()
	if desired.length_squared() < 0.0001:
		desired = previous
	if desired.length_squared() < 0.0001:
		desired = outward - axis * outward.dot(axis)
	if desired.length_squared() < 0.0001:
		desired = back - axis * back.dot(axis)
	desired = desired.normalized()
	if previous.length_squared() > 0.0:
		var angle := atan2(axis.dot(previous.cross(desired)), previous.dot(desired))
		var dt := clampf(delta, 0.0, 0.1)
		var step := clampf(angle * (1.0 - exp(-dt / 0.10)), -PI * dt, PI * dt)
		desired = previous.rotated(axis, step).normalized()
	_arm_axes[key] = axis
	_poles[key] = desired
	return desired


## Two-bone IK: law of cosines for the bend, pole vector for the plane,
## rest-relative leaf orientation from the target basis.
func _solve_two_bone(skel: Skeleton3D, upper: int, lower: int, leaf: int,
		target: Transform3D, pole_dir: Vector3, base_scale: float = 1.0, stretch_limit: float = -1.0) -> void:
	var root_g: Transform3D = skel.get_bone_global_pose(_parents[upper])
	var upper_g: Transform3D = root_g * skel.get_bone_pose(upper)
	var a: Vector3 = upper_g.origin
	var rest_upper: float = _rest_lengths[lower]
	var rest_lower: float = _rest_lengths[leaf]

	var to_target: Vector3 = target.origin - a
	var target_distance := to_target.length()
	# Stretch: beyond rest reach the segments grow (capped) so the hand still
	# lands on the controller; the leaf is written absolutely, so it and the
	# fingers keep their size.
	var stretch: float = base_scale
	var reach: float = (rest_upper + rest_lower) * base_scale
	if target_distance > reach - 0.001:
		var limit := max_arm_stretch if stretch_limit < 0.0 else stretch_limit
		stretch = clampf(target_distance / (rest_upper + rest_lower), base_scale, maxf(base_scale, limit))
		if base_scale < limit:
			_stretch_demand = maxf(_stretch_demand, stretch)
	var len_upper: float = rest_upper * stretch
	var len_lower: float = rest_lower * stretch
	var d: float = clampf(target_distance, 0.01, len_upper + len_lower - 0.001)
	var dir: Vector3 = to_target.normalized()

	# Elbow/knee position: triangle solved in the plane picked by the pole.
	var cos_a: float = clampf(
		(len_upper * len_upper + d * d - len_lower * len_lower) / (2.0 * len_upper * d),
		-1.0, 1.0)
	var bend_angle: float = acos(cos_a)
	var side: Vector3 = (pole_dir - dir * pole_dir.dot(dir))
	if side.length() < 0.001:
		side = Vector3.UP - dir * Vector3.UP.dot(dir)
	side = side.normalized()
	var elbow: Vector3 = a + (dir * cos(bend_angle) + side * sin(bend_angle)) * len_upper
	var wrist: Vector3 = target.origin

	# Upper bone: rotate its rest aim onto a->elbow. The child's rest origin
	# direction IS the bone axis in this rig, whatever that axis is.
	var upper_axis: Vector3 = (upper_g.basis
		* _rest_offsets[lower]).normalized()
	var q1 := Quaternion(upper_axis, (elbow - a).normalized())
	var upper_new := Transform3D(Basis(q1) * upper_g.basis, a)
	if stretch != 1.0:
		upper_new.basis = _stretched(upper_new.basis, _rest_axes[lower], stretch)
	_write_global(skel, upper, upper_new)

	# Lower bone likewise, elbow -> wrist.
	var lower_g: Transform3D = skel.get_bone_global_pose(lower)
	var lower_axis: Vector3 = (lower_g.basis
		* _rest_offsets[leaf]).normalized()
	var q2 := Quaternion(lower_axis, (wrist - lower_g.origin).normalized())
	var lower_new := Transform3D(Basis(q2) * lower_g.basis.orthonormalized(), lower_g.origin)
	if stretch != 1.0:
		lower_new.basis = _stretched(lower_new.basis, _rest_axes[leaf], stretch)
	_write_global(skel, lower, lower_new)

	# Leaf: orientation from the target, rest-relative.
	var leaf_g: Transform3D = skel.get_bone_global_pose(leaf)
	leaf_g.basis = target.basis * _rest_bases[leaf]
	_write_global(skel, leaf, leaf_g)


## Scale a bone basis along its own (local) axis only.
static func _stretched(basis: Basis, local_axis: Vector3, s: float) -> Basis:
	var k := s - 1.0
	var stretch := Basis(
		Vector3(1.0 + k * local_axis.x * local_axis.x, k * local_axis.x * local_axis.y, k * local_axis.x * local_axis.z),
		Vector3(k * local_axis.y * local_axis.x, 1.0 + k * local_axis.y * local_axis.y, k * local_axis.y * local_axis.z),
		Vector3(k * local_axis.z * local_axis.x, k * local_axis.z * local_axis.y, 1.0 + k * local_axis.z * local_axis.z))
	return basis * stretch


func _write_global(skel: Skeleton3D, bone: int, pose: Transform3D) -> void:
	var parent := _parents[bone]
	var parent_g := Transform3D.IDENTITY
	if parent != -1:
		parent_g = skel.get_bone_global_pose(parent)
	var local := (parent_g.affine_inverse() * pose).orthonormalized()
	if not local.is_finite():
		return  # keep the bone where it was rather than poison the chain
	skel.set_bone_pose(bone, local)
