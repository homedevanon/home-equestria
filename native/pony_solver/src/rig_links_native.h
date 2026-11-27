// Native state and per-update work of the neck and hair links (perf overhaul 2026-11-21, lane links;
// captures/perf_2026-11-21/port_links.md).
//
// world/characters/hybrid_mare/hybrid_neck_link.gd extends HybridNeckLinkNative and
// world/characters/hybrid_mare/hybrid_hair_link.gd extends HybridHairLinkNative. The scripts keep
// their names, their link()/bind() and their skeleton_updated handlers (_on_source_updated,
// _body_updated, _head_updated) as one-line shells; with NATIVE_LINKS on, a handler calls the
// native update below, which does exactly what the script body did, with the same engine calls in
// the same order and the same float types. The state the handlers read and write each update is held
// here as properties under the scripts' old names, so other scripts, rig_batch.cpp and mods reach it
// by name as before.
//
// The neck link's `source_poses` Dictionary stays a script variable: the shell passes it to
// native_update() for that call only, and nothing here keeps a reference to it.
#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class Skeleton3D;

// A Skeleton3D held like a typed GDScript variable: the object, and whether it still exists
// (is_instance_valid) checked by id without the binding lookup of ObjectDB::get_instance.
struct LinkedSkeleton {
	ObjectID id;
	Skeleton3D *pointer = nullptr;
	void set(Skeleton3D *p_skeleton);
	Skeleton3D *get() const;
};

class HybridNeckLinkNative : public Node {
	GDCLASS(HybridNeckLinkNative, Node)

	LinkedSkeleton source;
	LinkedSkeleton target;
	std::vector<int32_t> source_bones;
	std::vector<int32_t> target_bones;
	std::vector<Transform3D> offsets;
	bool linked = false;
	bool enabled = true;

protected:
	static void _bind_methods();

public:
	// hybrid_neck_link.gd _on_source_updated after its rig_batch guard. Always true (it handles
	// every state the script handles).
	bool native_update(const Dictionary &p_source_poses);

	void set_source(Skeleton3D *p_skeleton) { source.set(p_skeleton); }
	Skeleton3D *get_source() const { return source.get(); }
	void set_target(Skeleton3D *p_skeleton) { target.set(p_skeleton); }
	Skeleton3D *get_target() const { return target.get(); }
	void set_source_bones(const PackedInt32Array &p_bones);
	PackedInt32Array get_source_bones() const;
	void set_target_bones(const PackedInt32Array &p_bones);
	PackedInt32Array get_target_bones() const;
	void set_offsets(const TypedArray<Transform3D> &p_offsets);
	TypedArray<Transform3D> get_offsets() const;
	void set_linked(bool p_linked) { linked = p_linked; }
	bool get_linked() const { return linked; }
	void set_enabled(bool p_enabled) { enabled = p_enabled; }
	bool get_enabled() const { return enabled; }
};

class HybridHairLinkNative : public Node {
	GDCLASS(HybridHairLinkNative, Node)

	LinkedSkeleton body;
	LinkedSkeleton head;
	LinkedSkeleton hair;
	int64_t body_hips = -1;
	int64_t hair_pelvis = -1;
	Transform3D pelvis_offset;
	std::vector<Vector2i> head_pairs;
	std::vector<Vector3> head_offsets;
	bool enabled = true;
	Transform3D skull_frame;
	Transform3D head_rest_inverse;
	double follow_head = 0.0;
	Transform3D pelvis_written;
	std::vector<Transform3D> head_written{ Transform3D(), Transform3D(), Transform3D() };
	bool pelvis_valid = false;
	bool head_valid = false;
	bool pelvis_moved = true;

protected:
	static void _bind_methods();

public:
	// hybrid_hair_link.gd _body_updated and _head_updated after their rig_batch guards. Always true.
	bool native_body_update(bool p_skip_unchanged);
	bool native_head_update(bool p_skip_unchanged);

	void set_body(Skeleton3D *p_skeleton) { body.set(p_skeleton); }
	Skeleton3D *get_body() const { return body.get(); }
	void set_head(Skeleton3D *p_skeleton) { head.set(p_skeleton); }
	Skeleton3D *get_head() const { return head.get(); }
	void set_hair(Skeleton3D *p_skeleton) { hair.set(p_skeleton); }
	Skeleton3D *get_hair() const { return hair.get(); }
	void set_body_hips(int64_t p_bone) { body_hips = p_bone; }
	int64_t get_body_hips() const { return body_hips; }
	void set_hair_pelvis(int64_t p_bone) { hair_pelvis = p_bone; }
	int64_t get_hair_pelvis() const { return hair_pelvis; }
	void set_pelvis_offset(const Transform3D &p_offset) { pelvis_offset = p_offset; }
	Transform3D get_pelvis_offset() const { return pelvis_offset; }
	void set_head_pairs(const TypedArray<Vector2i> &p_pairs);
	TypedArray<Vector2i> get_head_pairs() const;
	void set_head_offsets(const TypedArray<Vector3> &p_offsets);
	TypedArray<Vector3> get_head_offsets() const;
	void set_enabled(bool p_enabled) { enabled = p_enabled; }
	bool get_enabled() const { return enabled; }
	void set_skull_frame(const Transform3D &p_frame) { skull_frame = p_frame; }
	Transform3D get_skull_frame() const { return skull_frame; }
	void set_head_rest_inverse(const Transform3D &p_frame) { head_rest_inverse = p_frame; }
	Transform3D get_head_rest_inverse() const { return head_rest_inverse; }
	void set_follow_head(double p_amount) { follow_head = p_amount; }
	double get_follow_head() const { return follow_head; }
	void set_pelvis_written(const Transform3D &p_pose) { pelvis_written = p_pose; }
	Transform3D get_pelvis_written() const { return pelvis_written; }
	void set_head_written(const TypedArray<Transform3D> &p_poses);
	TypedArray<Transform3D> get_head_written() const;
	void set_pelvis_valid(bool p_valid) { pelvis_valid = p_valid; }
	bool get_pelvis_valid() const { return pelvis_valid; }
	void set_head_valid(bool p_valid) { head_valid = p_valid; }
	bool get_head_valid() const { return head_valid; }
	void set_pelvis_moved(bool p_moved) { pelvis_moved = p_moved; }
	bool get_pelvis_moved() const { return pelvis_moved; }
};

} // namespace godot
