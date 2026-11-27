class_name HybridNeckLink
extends HybridNeckLinkNative
## Drive OpenPony neck/head bones from the native mare rig so the grafted head follows the body.
##
## The OpenPony head (own Skeleton3D, own face bones for mouth/blink) sits on the native body at a
## fixed rest offset (tools/fit_bell_hybrid_neck.py). After every native skeleton update the three
## OpenPony chain bones take the world motion of their native counterparts relative to rest, so both
## sides of the shared neck rim deform identically: the body's rim is weighted
## pony_head/pony_neck2/pony_spine3 and the head's rim HEAD/NECK/CHEST (children of mHead/mNeck/mChest).
##
## The native locomotion poses its bones inside a SkeletonModifier3D, and Skeleton3D restores the
## unmodified pose after skinning, so the modified poses are only readable from `skeleton_updated`.
## The OpenPony poses are written as plain bone poses there; its own modifiers (mouth) layer on top.
##
## Native state (perf overhaul 2026-11-21, lane links, captures/perf_2026-11-21/port_links.md):
## `source`, `target` (Skeleton3D), `_source_bones`, `_target_bones` (PackedInt32Array), `_offsets`
## (Array[Transform3D]), `_linked` and `enabled` (bool) are properties of HybridNeckLinkNative
## (native/pony_solver/src/rig_links_native.cpp) under these names. Its array getters hand out
## copies: assign a whole array, never append to the property in place. `native_update` is the
## handler's body below, the same engine calls in the same order.

const PAIRS := [["pony_spine3", "mChest"], ["pony_neck2", "mNeck"], ["pony_head", "mHead"]]
## Rollback switch: false runs the handler's body in GDScript (_script_source_updated).
const NATIVE_LINKS := true

## Last modified body frames used by the link, before Skeleton3D restores its plain poses.
## A script variable on purpose: the native update gets it for one call and never keeps it.
var source_poses: Dictionary = {}
## Physics frame whose pass the native body batch took over (rig_batch.gd); this script's pass
## returns at once in that frame. 0: never.
var rig_batch_step := 0


func link(body_skeleton: Skeleton3D, openpony_skeleton: Skeleton3D) -> bool:
	source = body_skeleton
	target = openpony_skeleton
	var source_bones := PackedInt32Array()
	var target_bones := PackedInt32Array()
	var offsets: Array[Transform3D] = []
	_source_bones = source_bones
	_target_bones = target_bones
	_offsets = offsets
	source_poses.clear()
	_linked = false
	if source == null or target == null:
		return false
	for pair in PAIRS:
		var s: int = source.find_bone(pair[0])
		var t: int = target.find_bone(pair[1])
		if s < 0 or t < 0:
			push_warning("HybridNeckLink: missing bone pair %s" % [pair])
			continue
		var source_rest: Transform3D = source.global_transform * source.get_bone_global_rest(s)
		var target_rest: Transform3D = target.global_transform * target.get_bone_global_rest(t)
		source_bones.append(s)
		target_bones.append(t)
		offsets.append(source_rest.affine_inverse() * target_rest)
	_source_bones = source_bones
	_target_bones = target_bones
	_offsets = offsets
	_linked = _source_bones.size() == PAIRS.size()
	if _linked and not source.skeleton_updated.is_connected(_on_source_updated):
		source.skeleton_updated.connect(_on_source_updated)
	# Her rigs may update on a worker thread while she is NEAR (rig_threads.gd).
	if _linked and get_parent() is Node3D: RIG_THREADS.register(get_parent() as Node3D)
	# Her body modifiers and these links may run in the native batch while she is NEAR (rig_batch.gd).
	if _linked and get_parent() is Node3D: RIG_BATCH.register(get_parent() as Node3D)
	return _linked

const RIG_THREADS := preload("res://world/characters/hybrid_mare/rig_threads.gd")
const RIG_BATCH := preload("res://world/characters/hybrid_mare/rig_batch.gd")


## `enabled` (native): off while the far render LOD shows a merged mesh on the body skeleton alone.
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")


func _on_source_updated() -> void:
	if rig_batch_step > 0 and rig_batch_step == Engine.get_physics_frames() and Engine.is_in_physics_frame(): return
	if not NATIVE_LINKS:
		_script_source_updated()
		return
	if not PROFILE.enabled:
		native_update(source_poses)
		return
	var started := Time.get_ticks_usec()
	native_update(source_poses)
	PROFILE.record("neck_link", started)


## The handler's body as it was before the native port (rollback path, NATIVE_LINKS false).
func _script_source_updated() -> void:
	if not enabled or not _linked or not is_instance_valid(source) or not is_instance_valid(target) \
			or not source.is_inside_tree() or not target.is_inside_tree():
		return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	var source_bones: PackedInt32Array = _source_bones
	var target_bones: PackedInt32Array = _target_bones
	var offsets: Array[Transform3D] = _offsets
	var into_target: Transform3D = target.global_transform.affine_inverse()
	for i in source_bones.size():
		var source_pose: Transform3D = source.get_bone_global_pose(source_bones[i])
		source_poses[source_bones[i]] = source_pose
		var world: Transform3D = source.global_transform * source_pose * offsets[i]
		target.set_bone_global_pose(target_bones[i], into_target * world)
	if PROFILE.enabled: PROFILE.record("neck_link", started)
