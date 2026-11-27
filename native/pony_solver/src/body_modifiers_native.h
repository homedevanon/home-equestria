// Native bases of three close-pony body modifiers (native pony step port 2026-11-21, lane body;
// captures/perf_2026-11-21/NATIVE_PONY_DESIGN.md and port_body.md).
//
// Each class is the native base of its script (Form 1): the script keeps its path, its callback
// and its old body as the fallback, and its hot state lives here as properties with the names the
// script variables had, so `get`/`set` by name (rig_batch.cpp, tests, hybrid_mare.gd) keep working.
//   PonyIdleBodyNative          world/life/idle/pony_idle_body.gd
//   PonyClipHeadNative          world/characters/locomotion/pony_clip_head.gd
//   PonyFillyProportionsNative  world/characters/hybrid_mare/filly_proportions.gd
// native_step() does one modifier pass with the scripts' formulas, the same engine calls in the
// same order, and returns true; it returns false before changing anything when it cannot do the
// pass exactly (the script's own pass then runs). The rig_batch_step guard stays in the scripts.
#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton_modifier3d.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>

namespace godot {

class PonyIdleBodyNative : public SkeletonModifier3D {
	GDCLASS(PonyIdleBodyNative, SkeletonModifier3D)

	ObjectID pony;
	bool wanted = false;
	double fade = 0.0;
	int64_t hips = -1;
	int64_t hips_parent = -1;
	Array legs;
	Array leg_parents;
	Basis model_to_skeleton;
	bool frame_ready = false;
	double roll = 0.0;
	double pitch = 0.0;
	double breath = 0.0;
	double applied_roll = 0.0;
	int64_t last_pass_frame = -1;
	double breath_arch = 0.012; // pony_secondary_motion.gd BREATH_ARCH, set by the script

protected:
	static void _bind_methods();

public:
	bool native_step(double p_delta);

	void set_pony(Node *p_pony);
	Node *get_pony() const;
	void set_wanted(bool p_value) { wanted = p_value; }
	bool get_wanted() const { return wanted; }
	void set_fade(double p_value) { fade = p_value; }
	double get_fade() const { return fade; }
	void set_hips(int64_t p_value) { hips = p_value; }
	int64_t get_hips() const { return hips; }
	void set_hips_parent(int64_t p_value) { hips_parent = p_value; }
	int64_t get_hips_parent() const { return hips_parent; }
	void set_legs(const Array &p_value) { legs = p_value; }
	Array get_legs() const { return legs; }
	void set_leg_parents(const Array &p_value) { leg_parents = p_value; }
	Array get_leg_parents() const { return leg_parents; }
	void set_model_to_skeleton(const Basis &p_value) { model_to_skeleton = p_value; }
	Basis get_model_to_skeleton() const { return model_to_skeleton; }
	void set_frame_ready(bool p_value) { frame_ready = p_value; }
	bool get_frame_ready() const { return frame_ready; }
	void set_roll(double p_value) { roll = p_value; }
	double get_roll() const { return roll; }
	void set_pitch(double p_value) { pitch = p_value; }
	double get_pitch() const { return pitch; }
	void set_breath(double p_value) { breath = p_value; }
	double get_breath() const { return breath; }
	void set_applied_roll(double p_value) { applied_roll = p_value; }
	double get_applied_roll() const { return applied_roll; }
	void set_last_pass_frame(int64_t p_value) { last_pass_frame = p_value; }
	int64_t get_last_pass_frame() const { return last_pass_frame; }
	void set_breath_arch(double p_value) { breath_arch = p_value; }
	double get_breath_arch() const { return breath_arch; }
};

class PonyClipHeadNative : public SkeletonModifier3D {
	GDCLASS(PonyClipHeadNative, SkeletonModifier3D)

	ObjectID pony;
	Ref<RefCounted> native;
	bool bound = false;

protected:
	static void _bind_methods();

public:
	bool native_step();

	void set_pony(Node *p_pony);
	Node *get_pony() const;
	void set_native(const Ref<RefCounted> &p_value) { native = p_value; }
	Ref<RefCounted> get_native() const { return native; }
	void set_bound(bool p_value) { bound = p_value; }
	bool get_bound() const { return bound; }
};

class PonyFillyProportionsNative : public SkeletonModifier3D {
	GDCLASS(PonyFillyProportionsNative, SkeletonModifier3D)

	double neck_scale = 0.9;
	double head_scale = 1.0;
	double head_width = 1.0;
	double wing_scale = 1.0;
	int64_t neck = -1;
	int64_t head = -1;
	Basis local_width_basis;
	PackedInt32Array wings;

protected:
	static void _bind_methods();

public:
	bool native_step();

	void set_neck_scale(double p_value) { neck_scale = p_value; }
	double get_neck_scale() const { return neck_scale; }
	void set_head_scale(double p_value) { head_scale = p_value; }
	double get_head_scale() const { return head_scale; }
	void set_head_width(double p_value) { head_width = p_value; }
	double get_head_width() const { return head_width; }
	void set_wing_scale(double p_value) { wing_scale = p_value; }
	double get_wing_scale() const { return wing_scale; }
	void set_neck(int64_t p_value) { neck = p_value; }
	int64_t get_neck() const { return neck; }
	void set_head(int64_t p_value) { head = p_value; }
	int64_t get_head() const { return head; }
	void set_local_width_basis(const Basis &p_value) { local_width_basis = p_value; }
	Basis get_local_width_basis() const { return local_width_basis; }
	void set_wings(const PackedInt32Array &p_value) { wings = p_value; }
	PackedInt32Array get_wings() const { return wings; }
};

} // namespace godot
