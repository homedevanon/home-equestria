extends HybridHairLinkNative
## The devkit mane uses mHead/mChest, its tail mTail1..6. Copy the linked
## OpenPony head and native pelvis *inside* skeleton_updated, before skinning.
##
## Native state (perf overhaul 2026-11-21, lane links, captures/perf_2026-11-21/port_links.md):
## `body`, `head`, `hair` (Skeleton3D), `body_hips`, `hair_pelvis`, `pelvis_offset`, `head_pairs`
## (Array[Vector2i]), `head_offsets` (Array[Vector3]), `enabled` (off while the far render LOD shows
## a merged mesh on the body skeleton alone), `skull_frame`, `_head_rest_inverse`, `follow_head` and
## the skip state below are properties of HybridHairLinkNative
## (native/pony_solver/src/rig_links_native.cpp) under these names. Its array getters hand out
## copies: assign a whole array, never append to the property in place. `native_body_update` and
## `native_head_update` are the handlers' bodies below, the same engine calls in the same order.
##
## `follow_head` 0..1, set by pony_carry.gd while she is bridal carried: her head tips far back
## against her neck there, and the back of the mane (on mChest/mNeck) would fold into her throat.
## Those bones then ride along with the skull instead, chest less than neck.
const FOLLOW_SHARE := [0.6, 1.0] # mChest, mNeck.
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")
## Unchanged links are not rewritten (0.1.0 perf pass): a pose write makes the hair rig re-skin, and
## a still body and head handed it the same four bones every tick. A bone is written again once its
## target leaves Transform3D.is_equal_approx of the last written one (a hundredth of a millimetre),
## so the hair never trails by more than that. The mane chain is written whole when any of it, or
## the pelvis below it, changed. Rollback: SKIP_UNCHANGED = false.
## Skip state (native): `_pelvis_written`, `_head_written` (three identity frames at first),
## `_pelvis_valid`, `_head_valid`, and `_pelvis_moved` (true at first: the pelvis moved since the mane
## chain was last written, so its locals must be rewritten).
const SKIP_UNCHANGED := true
## Rollback switch: false runs the handlers' bodies in GDScript (_script_body_updated,
## _script_head_updated).
const NATIVE_LINKS := true
## Physics frame whose pass the native body batch took over (rig_batch.gd); this script's pass
## returns at once in that frame. 0: never.
var rig_batch_step := 0

func bind(body_sk: Skeleton3D, head_sk: Skeleton3D, hair_sk: Skeleton3D,
		tail_offset_world := Vector3.ZERO, mane_offset_world := Vector3.ZERO) -> void:
	body = body_sk
	head = head_sk
	hair = hair_sk
	_head_rest_inverse = head.get_bone_global_rest(head.find_bone("mHead")).affine_inverse()
	body_hips = body.find_bone("pony_hips")
	hair_pelvis = hair.find_bone("mPelvis")
	var body_rest: Transform3D = body.global_transform * body.get_bone_global_rest(body_hips)
	var hair_rest: Transform3D = hair.global_transform * hair.get_bone_global_rest(hair_pelvis)
	hair_rest.origin += tail_offset_world
	pelvis_offset = body_rest.affine_inverse() * hair_rest
	var pairs: Array[Vector2i] = head_pairs
	var offsets: Array[Vector3] = head_offsets
	for name in ["mChest","mNeck","mHead"]:
		var pair := Vector2i(head.find_bone(name),hair.find_bone(name))
		pairs.append(pair)
		# The mane offset is fixed in each bone's own frame, so it nods with the head.
		var rest: Transform3D = head.global_transform * head.get_bone_global_rest(pair.x)
		offsets.append(rest.basis.inverse() * mane_offset_world)
	head_pairs = pairs
	head_offsets = offsets
	body.skeleton_updated.connect(_body_updated)
	head.skeleton_updated.connect(_head_updated)

func _body_updated() -> void:
	if rig_batch_step > 0 and rig_batch_step == Engine.get_physics_frames() and Engine.is_in_physics_frame(): return
	if not NATIVE_LINKS:
		_script_body_updated()
		return
	if not PROFILE.enabled:
		native_body_update(SKIP_UNCHANGED)
		return
	var started := Time.get_ticks_usec()
	native_body_update(SKIP_UNCHANGED)
	PROFILE.record("hair_link", started)

func _head_updated() -> void:
	if rig_batch_step > 0 and rig_batch_step == Engine.get_physics_frames() and Engine.is_in_physics_frame(): return
	if not NATIVE_LINKS:
		_script_head_updated()
		return
	if not PROFILE.enabled:
		native_head_update(SKIP_UNCHANGED)
		return
	var started := Time.get_ticks_usec()
	native_head_update(SKIP_UNCHANGED)
	PROFILE.record("hair_link", started)

## The handlers' bodies as they were before the native port (rollback path, NATIVE_LINKS false).
func _script_body_updated() -> void:
	if not enabled or not is_instance_valid(hair) or not hair.is_inside_tree():
		_pelvis_valid = false; _head_valid = false
		return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	var world: Transform3D = body.global_transform * body.get_bone_global_pose(body_hips) * pelvis_offset
	var target: Transform3D = hair.global_transform.affine_inverse()*world
	if not (SKIP_UNCHANGED and _pelvis_valid and target.is_equal_approx(_pelvis_written)):
		hair.set_bone_global_pose(hair_pelvis,target)
		_pelvis_written = target
		_pelvis_valid = true
		_pelvis_moved = true
	if PROFILE.enabled: PROFILE.record("hair_link", started)

func _script_head_updated() -> void:
	if not enabled or not is_instance_valid(hair) or not hair.is_inside_tree():
		_pelvis_valid = false; _head_valid = false
		return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	var pairs: Array[Vector2i] = head_pairs
	var offsets: Array[Vector3] = head_offsets
	var written: Array[Transform3D] = _head_written
	var targets: Array[Transform3D] = []
	var changed := not SKIP_UNCHANGED or not _head_valid or _pelvis_moved \
		or pairs.size() != written.size()
	var into_hair: Transform3D = hair.global_transform.affine_inverse()
	for i in pairs.size():
		var pair := pairs[i]
		var posed: Transform3D = head.get_bone_global_pose(pair.x)
		if i < 2 and follow_head > 0.0:
			var skull: Transform3D = head.get_bone_global_pose(pairs[2].x) * _head_rest_inverse
			posed = posed.interpolate_with(skull * head.get_bone_global_rest(pair.x), follow_head * FOLLOW_SHARE[i])
		if i == 2:
			var motion: Transform3D = posed * _head_rest_inverse
			posed = motion * skull_frame * motion.affine_inverse() * posed
		var world: Transform3D = head.global_transform * posed * Transform3D(Basis.IDENTITY, offsets[i])
		var target := into_hair*world
		targets.append(target)
		if not changed and not target.is_equal_approx(written[i]): changed = true
	if changed:
		# Parent first (mChest, mNeck, mHead): each local pose reads its freshly written parent.
		for i in pairs.size(): hair.set_bone_global_pose(pairs[i].y, targets[i])
		_head_written = targets
		_head_valid = true
		_pelvis_moved = false
	if PROFILE.enabled: PROFILE.record("hair_link", started)
