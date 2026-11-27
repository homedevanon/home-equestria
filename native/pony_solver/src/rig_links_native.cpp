// Native state and per-update work of the neck and hair links; see rig_links_native.h.
#include "rig_links_native.h"

#include "engine_math.h"

#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/basis.hpp>

using namespace godot;

void LinkedSkeleton::set(Skeleton3D *p_skeleton) {
	pointer = p_skeleton;
	id = p_skeleton != nullptr ? ObjectID(p_skeleton->get_instance_id()) : ObjectID();
}

Skeleton3D *LinkedSkeleton::get() const {
	// The wrapper lives as long as its object; a freed object's id never comes back.
	if (!id.is_valid() || internal::gdextension_interface_object_get_instance_from_id(uint64_t(id)) == nullptr) {
		return nullptr;
	}
	return pointer;
}

// --- HybridNeckLinkNative ---------------------------------------------------------------------

// hybrid_neck_link.gd _on_source_updated, after the rig_batch guard:
//   if not enabled or not _linked or not is_instance_valid(source) or not is_instance_valid(target) \
//   		or not source.is_inside_tree() or not target.is_inside_tree(): return
//   var into_target := target.global_transform.affine_inverse()
//   for i in _source_bones.size():
//   	var source_pose := source.get_bone_global_pose(_source_bones[i])
//   	source_poses[_source_bones[i]] = source_pose
//   	var world := source.global_transform * source_pose * _offsets[i]
//   	target.set_bone_global_pose(_target_bones[i], into_target * world)
bool HybridNeckLinkNative::native_update(const Dictionary &p_source_poses) {
	if (!enabled || !linked) {
		return true;
	}
	Skeleton3D *from = source.get();
	Skeleton3D *to = target.get();
	if (from == nullptr || to == nullptr || !from->is_inside_tree() || !to->is_inside_tree()) {
		return true;
	}
	Dictionary source_poses = p_source_poses; // the caller's Dictionary, for this call only
	const Transform3D into_target = to->get_global_transform().affine_inverse();
	// The script reads source.global_transform in every pass; writing the head rig's bones does not
	// move the body rig, so the value is the same each time.
	const Transform3D source_global = from->get_global_transform();
	const size_t count = MIN(source_bones.size(), MIN(target_bones.size(), offsets.size()));
	for (size_t i = 0; i < count; i++) {
		const int32_t bone = source_bones[i];
		const Transform3D source_pose = from->get_bone_global_pose(bone);
		source_poses[int64_t(bone)] = source_pose;
		const Transform3D world = source_global * source_pose * offsets[i];
		to->set_bone_global_pose(target_bones[i], into_target * world);
	}
	return true;
}

void HybridNeckLinkNative::set_source_bones(const PackedInt32Array &p_bones) {
	source_bones.assign(p_bones.ptr(), p_bones.ptr() + p_bones.size());
}

PackedInt32Array HybridNeckLinkNative::get_source_bones() const {
	PackedInt32Array out;
	out.resize(int64_t(source_bones.size()));
	for (size_t i = 0; i < source_bones.size(); i++) {
		out.set(int64_t(i), source_bones[i]);
	}
	return out;
}

void HybridNeckLinkNative::set_target_bones(const PackedInt32Array &p_bones) {
	target_bones.assign(p_bones.ptr(), p_bones.ptr() + p_bones.size());
}

PackedInt32Array HybridNeckLinkNative::get_target_bones() const {
	PackedInt32Array out;
	out.resize(int64_t(target_bones.size()));
	for (size_t i = 0; i < target_bones.size(); i++) {
		out.set(int64_t(i), target_bones[i]);
	}
	return out;
}

void HybridNeckLinkNative::set_offsets(const TypedArray<Transform3D> &p_offsets) {
	offsets.clear();
	for (int64_t i = 0; i < p_offsets.size(); i++) {
		offsets.push_back(p_offsets[i]);
	}
}

TypedArray<Transform3D> HybridNeckLinkNative::get_offsets() const {
	TypedArray<Transform3D> out;
	for (const Transform3D &offset : offsets) {
		out.push_back(offset);
	}
	return out;
}

void HybridNeckLinkNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_update", "source_poses"), &HybridNeckLinkNative::native_update);
	ClassDB::bind_method(D_METHOD("set_source", "skeleton"), &HybridNeckLinkNative::set_source);
	ClassDB::bind_method(D_METHOD("get_source"), &HybridNeckLinkNative::get_source);
	ClassDB::bind_method(D_METHOD("set_target", "skeleton"), &HybridNeckLinkNative::set_target);
	ClassDB::bind_method(D_METHOD("get_target"), &HybridNeckLinkNative::get_target);
	ClassDB::bind_method(D_METHOD("set_source_bones", "bones"), &HybridNeckLinkNative::set_source_bones);
	ClassDB::bind_method(D_METHOD("get_source_bones"), &HybridNeckLinkNative::get_source_bones);
	ClassDB::bind_method(D_METHOD("set_target_bones", "bones"), &HybridNeckLinkNative::set_target_bones);
	ClassDB::bind_method(D_METHOD("get_target_bones"), &HybridNeckLinkNative::get_target_bones);
	ClassDB::bind_method(D_METHOD("set_offsets", "offsets"), &HybridNeckLinkNative::set_offsets);
	ClassDB::bind_method(D_METHOD("get_offsets"), &HybridNeckLinkNative::get_offsets);
	ClassDB::bind_method(D_METHOD("set_linked", "linked"), &HybridNeckLinkNative::set_linked);
	ClassDB::bind_method(D_METHOD("get_linked"), &HybridNeckLinkNative::get_linked);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &HybridNeckLinkNative::set_enabled);
	ClassDB::bind_method(D_METHOD("get_enabled"), &HybridNeckLinkNative::get_enabled);
	const uint32_t hidden = PROPERTY_USAGE_SCRIPT_VARIABLE; // not saved, not shown: runtime state like the script's
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "source", PROPERTY_HINT_NODE_TYPE, "Skeleton3D", hidden, "Skeleton3D"), "set_source", "get_source");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "target", PROPERTY_HINT_NODE_TYPE, "Skeleton3D", hidden, "Skeleton3D"), "set_target", "get_target");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "_source_bones", PROPERTY_HINT_NONE, "", hidden), "set_source_bones", "get_source_bones");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "_target_bones", PROPERTY_HINT_NONE, "", hidden), "set_target_bones", "get_target_bones");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "_offsets", PROPERTY_HINT_ARRAY_TYPE, "Transform3D", hidden), "set_offsets", "get_offsets");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_linked", PROPERTY_HINT_NONE, "", hidden), "set_linked", "get_linked");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled", PROPERTY_HINT_NONE, "", hidden), "set_enabled", "get_enabled");
}

// --- HybridHairLinkNative ---------------------------------------------------------------------

// hybrid_hair_link.gd _body_updated, after the rig_batch guard:
//   if not enabled or not is_instance_valid(hair) or not hair.is_inside_tree():
//   	_pelvis_valid = false; _head_valid = false
//   	return
//   var world := body.global_transform * body.get_bone_global_pose(body_hips) * pelvis_offset
//   var target := hair.global_transform.affine_inverse()*world
//   if not (SKIP_UNCHANGED and _pelvis_valid and target.is_equal_approx(_pelvis_written)):
//   	hair.set_bone_global_pose(hair_pelvis,target)
//   	_pelvis_written = target; _pelvis_valid = true; _pelvis_moved = true
bool HybridHairLinkNative::native_body_update(bool p_skip_unchanged) {
	Skeleton3D *to = hair.get();
	if (!enabled || to == nullptr || !to->is_inside_tree()) {
		pelvis_valid = false;
		head_valid = false;
		return true;
	}
	Skeleton3D *from = body.get();
	if (from == nullptr) {
		return true; // the script would stop on a null body here
	}
	const Transform3D world = from->get_global_transform() * from->get_bone_global_pose(int32_t(body_hips)) * pelvis_offset;
	const Transform3D aim = to->get_global_transform().affine_inverse() * world;
	if (!(p_skip_unchanged && pelvis_valid && aim.is_equal_approx(pelvis_written))) {
		to->set_bone_global_pose(int32_t(hair_pelvis), aim);
		pelvis_written = aim;
		pelvis_valid = true;
		pelvis_moved = true;
	}
	return true;
}

// hybrid_hair_link.gd _head_updated, after the rig_batch guard (the script text is in that file).
bool HybridHairLinkNative::native_head_update(bool p_skip_unchanged) {
	Skeleton3D *to = hair.get();
	if (!enabled || to == nullptr || !to->is_inside_tree()) {
		pelvis_valid = false;
		head_valid = false;
		return true;
	}
	Skeleton3D *from = head.get();
	const size_t count = head_pairs.size();
	if (from == nullptr || count > head_offsets.size() || (count > 0 && count < 3 && follow_head > 0.0)) {
		return true; // the script would stop on a null head or an index out of range here
	}
	static const double FOLLOW_SHARE[2] = { 0.6, 1.0 }; // the script's FOLLOW_SHARE: mChest, mNeck
	std::vector<Transform3D> targets;
	targets.reserve(count);
	bool changed = !p_skip_unchanged || !head_valid || pelvis_moved || count != head_written.size();
	const Transform3D into_hair = to->get_global_transform().affine_inverse();
	// The script reads head.global_transform in every pass; these passes only read bones.
	const Transform3D head_global = from->get_global_transform();
	for (size_t i = 0; i < count; i++) {
		const Vector2i pair = head_pairs[i];
		Transform3D posed = from->get_bone_global_pose(pair.x);
		if (i < 2 && follow_head > 0.0) {
			const Transform3D skull = from->get_bone_global_pose(head_pairs[2].x) * head_rest_inverse;
			posed = pony::interpolate(posed, skull * from->get_bone_global_rest(pair.x), follow_head * FOLLOW_SHARE[i]);
		}
		if (i == 2) {
			const Transform3D motion = posed * head_rest_inverse;
			posed = motion * skull_frame * motion.affine_inverse() * posed;
		}
		const Transform3D world = head_global * posed * Transform3D(Basis(), head_offsets[i]);
		const Transform3D aim = into_hair * world;
		targets.push_back(aim);
		if (!changed && !aim.is_equal_approx(head_written[i])) {
			changed = true;
		}
	}
	if (changed) {
		// Parent first (mChest, mNeck, mHead): each local pose reads its freshly written parent.
		for (size_t i = 0; i < count; i++) {
			to->set_bone_global_pose(head_pairs[i].y, targets[i]);
		}
		head_written.swap(targets);
		head_valid = true;
		pelvis_moved = false;
	}
	return true;
}

void HybridHairLinkNative::set_head_pairs(const TypedArray<Vector2i> &p_pairs) {
	head_pairs.clear();
	for (int64_t i = 0; i < p_pairs.size(); i++) {
		head_pairs.push_back(p_pairs[i]);
	}
}

TypedArray<Vector2i> HybridHairLinkNative::get_head_pairs() const {
	TypedArray<Vector2i> out;
	for (const Vector2i &pair : head_pairs) {
		out.push_back(pair);
	}
	return out;
}

void HybridHairLinkNative::set_head_offsets(const TypedArray<Vector3> &p_offsets) {
	head_offsets.clear();
	for (int64_t i = 0; i < p_offsets.size(); i++) {
		head_offsets.push_back(p_offsets[i]);
	}
}

TypedArray<Vector3> HybridHairLinkNative::get_head_offsets() const {
	TypedArray<Vector3> out;
	for (const Vector3 &offset : head_offsets) {
		out.push_back(offset);
	}
	return out;
}

void HybridHairLinkNative::set_head_written(const TypedArray<Transform3D> &p_poses) {
	head_written.clear();
	for (int64_t i = 0; i < p_poses.size(); i++) {
		head_written.push_back(p_poses[i]);
	}
}

TypedArray<Transform3D> HybridHairLinkNative::get_head_written() const {
	TypedArray<Transform3D> out;
	for (const Transform3D &pose : head_written) {
		out.push_back(pose);
	}
	return out;
}

void HybridHairLinkNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_body_update", "skip_unchanged"), &HybridHairLinkNative::native_body_update);
	ClassDB::bind_method(D_METHOD("native_head_update", "skip_unchanged"), &HybridHairLinkNative::native_head_update);
	ClassDB::bind_method(D_METHOD("set_body", "skeleton"), &HybridHairLinkNative::set_body);
	ClassDB::bind_method(D_METHOD("get_body"), &HybridHairLinkNative::get_body);
	ClassDB::bind_method(D_METHOD("set_head", "skeleton"), &HybridHairLinkNative::set_head);
	ClassDB::bind_method(D_METHOD("get_head"), &HybridHairLinkNative::get_head);
	ClassDB::bind_method(D_METHOD("set_hair", "skeleton"), &HybridHairLinkNative::set_hair);
	ClassDB::bind_method(D_METHOD("get_hair"), &HybridHairLinkNative::get_hair);
	ClassDB::bind_method(D_METHOD("set_body_hips", "bone"), &HybridHairLinkNative::set_body_hips);
	ClassDB::bind_method(D_METHOD("get_body_hips"), &HybridHairLinkNative::get_body_hips);
	ClassDB::bind_method(D_METHOD("set_hair_pelvis", "bone"), &HybridHairLinkNative::set_hair_pelvis);
	ClassDB::bind_method(D_METHOD("get_hair_pelvis"), &HybridHairLinkNative::get_hair_pelvis);
	ClassDB::bind_method(D_METHOD("set_pelvis_offset", "offset"), &HybridHairLinkNative::set_pelvis_offset);
	ClassDB::bind_method(D_METHOD("get_pelvis_offset"), &HybridHairLinkNative::get_pelvis_offset);
	ClassDB::bind_method(D_METHOD("set_head_pairs", "pairs"), &HybridHairLinkNative::set_head_pairs);
	ClassDB::bind_method(D_METHOD("get_head_pairs"), &HybridHairLinkNative::get_head_pairs);
	ClassDB::bind_method(D_METHOD("set_head_offsets", "offsets"), &HybridHairLinkNative::set_head_offsets);
	ClassDB::bind_method(D_METHOD("get_head_offsets"), &HybridHairLinkNative::get_head_offsets);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &HybridHairLinkNative::set_enabled);
	ClassDB::bind_method(D_METHOD("get_enabled"), &HybridHairLinkNative::get_enabled);
	ClassDB::bind_method(D_METHOD("set_skull_frame", "frame"), &HybridHairLinkNative::set_skull_frame);
	ClassDB::bind_method(D_METHOD("get_skull_frame"), &HybridHairLinkNative::get_skull_frame);
	ClassDB::bind_method(D_METHOD("set_head_rest_inverse", "frame"), &HybridHairLinkNative::set_head_rest_inverse);
	ClassDB::bind_method(D_METHOD("get_head_rest_inverse"), &HybridHairLinkNative::get_head_rest_inverse);
	ClassDB::bind_method(D_METHOD("set_follow_head", "amount"), &HybridHairLinkNative::set_follow_head);
	ClassDB::bind_method(D_METHOD("get_follow_head"), &HybridHairLinkNative::get_follow_head);
	ClassDB::bind_method(D_METHOD("set_pelvis_written", "pose"), &HybridHairLinkNative::set_pelvis_written);
	ClassDB::bind_method(D_METHOD("get_pelvis_written"), &HybridHairLinkNative::get_pelvis_written);
	ClassDB::bind_method(D_METHOD("set_head_written", "poses"), &HybridHairLinkNative::set_head_written);
	ClassDB::bind_method(D_METHOD("get_head_written"), &HybridHairLinkNative::get_head_written);
	ClassDB::bind_method(D_METHOD("set_pelvis_valid", "valid"), &HybridHairLinkNative::set_pelvis_valid);
	ClassDB::bind_method(D_METHOD("get_pelvis_valid"), &HybridHairLinkNative::get_pelvis_valid);
	ClassDB::bind_method(D_METHOD("set_head_valid", "valid"), &HybridHairLinkNative::set_head_valid);
	ClassDB::bind_method(D_METHOD("get_head_valid"), &HybridHairLinkNative::get_head_valid);
	ClassDB::bind_method(D_METHOD("set_pelvis_moved", "moved"), &HybridHairLinkNative::set_pelvis_moved);
	ClassDB::bind_method(D_METHOD("get_pelvis_moved"), &HybridHairLinkNative::get_pelvis_moved);
	const uint32_t hidden = PROPERTY_USAGE_SCRIPT_VARIABLE; // not saved, not shown: runtime state like the script's
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "body", PROPERTY_HINT_NODE_TYPE, "Skeleton3D", hidden, "Skeleton3D"), "set_body", "get_body");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "head", PROPERTY_HINT_NODE_TYPE, "Skeleton3D", hidden, "Skeleton3D"), "set_head", "get_head");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "hair", PROPERTY_HINT_NODE_TYPE, "Skeleton3D", hidden, "Skeleton3D"), "set_hair", "get_hair");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "body_hips", PROPERTY_HINT_NONE, "", hidden), "set_body_hips", "get_body_hips");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "hair_pelvis", PROPERTY_HINT_NONE, "", hidden), "set_hair_pelvis", "get_hair_pelvis");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "pelvis_offset", PROPERTY_HINT_NONE, "", hidden), "set_pelvis_offset", "get_pelvis_offset");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "head_pairs", PROPERTY_HINT_ARRAY_TYPE, "Vector2i", hidden), "set_head_pairs", "get_head_pairs");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "head_offsets", PROPERTY_HINT_ARRAY_TYPE, "Vector3", hidden), "set_head_offsets", "get_head_offsets");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled", PROPERTY_HINT_NONE, "", hidden), "set_enabled", "get_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "skull_frame", PROPERTY_HINT_NONE, "", hidden), "set_skull_frame", "get_skull_frame");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "_head_rest_inverse", PROPERTY_HINT_NONE, "", hidden), "set_head_rest_inverse", "get_head_rest_inverse");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "follow_head", PROPERTY_HINT_NONE, "", hidden), "set_follow_head", "get_follow_head");
	ADD_PROPERTY(PropertyInfo(Variant::TRANSFORM3D, "_pelvis_written", PROPERTY_HINT_NONE, "", hidden), "set_pelvis_written", "get_pelvis_written");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "_head_written", PROPERTY_HINT_ARRAY_TYPE, "Transform3D", hidden), "set_head_written", "get_head_written");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_pelvis_valid", PROPERTY_HINT_NONE, "", hidden), "set_pelvis_valid", "get_pelvis_valid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_head_valid", PROPERTY_HINT_NONE, "", hidden), "set_head_valid", "get_head_valid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_pelvis_moved", PROPERTY_HINT_NONE, "", hidden), "set_pelvis_moved", "get_pelvis_moved");
}
