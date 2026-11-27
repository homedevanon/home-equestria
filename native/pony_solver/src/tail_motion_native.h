// PonyTailMotionNative: the native base of hybrid_tail_motion.gd (lane tail of the native pony
// step, captures/perf_2026-11-21/NATIVE_PONY_DESIGN.md and port_tail.md).
//
// The motion script's hot state lives here as properties with the script's own names, and
// native_step() runs the script's whole per-step body (_process_modification_with_delta and what it
// calls) when the springs object is one the native code knows. The springs (hybrid_tail_physics.gd,
// a GDScript RefCounted extending pony_tail.gd) keep their GDScript object for binding, for the
// script fallback and for every outside caller; while native_step runs, their state is mirrored
// here and the GDScript object is stale. Reading the `springs` property writes the mirror back
// first and hands ownership back to the script object (the next native step reads it in again),
// so kick(), reset_history(), a replaced springs object and anything else that reaches the springs
// through `tail_motion.springs` sees and changes the current state.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton_modifier3d.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class CharacterBody3D;
class Node3D;
class Skeleton3D;

class PonyTailMotionNative : public SkeletonModifier3D {
	GDCLASS(PonyTailMotionNative, SkeletonModifier3D)

public:
	struct Plane {
		Dictionary dict; // what the probe returned ({} for none), handed back on a flush
		bool present = false;
		Vector3 position;
		Vector3 normal;
	};

	// Mirror of the springs object (hybrid_tail_physics.gd and pony_tail.gd members).
	struct Springs {
		ObjectID skeleton;
		std::vector<int32_t> bones;
		int32_t mount = -1;
		std::vector<int32_t> mount_parents; // parents of `mount`, nearest first (pony_tail.gd _pose_global)
		std::vector<Vector3> tips;
		std::vector<Basis> rest_bases;
		std::vector<double> limits;
		double gravity_amount = 0.0;
		double inertia_amount = 0.0;
		bool retry = false; // background_tail_physics.gd's extra projection
		// State.
		std::vector<Vector3> angles;
		std::vector<Vector3> velocity;
		std::vector<Transform3D> base;
		std::vector<Plane> planes;
		bool sleeping = false;
		int64_t quiet_frames = 0;
		double ground_wait = 0.0;
		Vector3 last_anchor;
		Transform3D previous_mount;
		std::vector<Vector3> after; // _after_angles (empty after a reset)
		Transform3D contact_mount;
		Basis previous_mount_basis;
		Vector3 previous_mount_velocity;
		bool mount_history = false;
		double max_penetration = 0.0;
		int64_t projected_contacts = 0;
		int64_t contacts = 0;
		int64_t solve_usec = 0;
		// Written by the motion every pass.
		bool cheap_floor = false;
		int64_t contact_iterations = 12;
		Callable floor_probe;
		bool floor_is_plane = false;
		bool contact_enabled = true;
		// Scratch.
		std::vector<Transform3D> frame;
		std::vector<Vector3> gradients;
	};

private:
	// hybrid_tail_motion.gd members, same names as properties.
	ObjectID pony_id;
	Ref<RefCounted> springs;
	Vector3 previous_velocity;
	bool history = false;
	double skipped_delta = 0.0;
	int64_t steps = 0;
	double aside_goal = 0.0;
	double aside = 0.0;
	bool settled = false;
	double quiet = 0.0;
	double recheck = 0.0;
	Transform3D settle_mount;
	double settle_reach = 0.0;
	Transform3D last_mount;
	PackedVector3Array last_angles;
	int64_t settled_writes = 0;
	bool wake_now = false;
	bool pose_dirty = true;
	bool solo = false;
	int64_t solo_children = -1;
	PackedInt32Array read_bones;
	Array to; // Array[Transform3D], shared with the script (it changes them in place)
	Array from_rotation; // Array[Quaternion]
	Array to_rotation; // Array[Quaternion]
	Callable ray_floor;
	Callable plane_floor;

	// Native only.
	bool owned = false; // the springs' state is in `s`, their GDScript object is stale
	Springs s;
	std::vector<Transform3D> pose; // the script's _pose buffer: rest, the mount ancestry, the tail
	int64_t logic_divisor = 3; // pony.LOGIC_DIVISOR
	int64_t native_steps = 0, declined_steps = 0, loads = 0, flushes = 0;

	struct Names;
	static Names &names();

	Node3D *pony_node() const;
	bool load_springs(Node3D *p_pony, Skeleton3D *p_skeleton);
	void flush_springs();
	void tier(Node3D *p_pony, bool &r_near, int64_t &r_divisor) const;
	bool integrate_now(Node3D *p_pony, bool p_near, int64_t p_divisor) const;

	bool skip_hair_pass(Skeleton3D *p_sk, Node3D *p_pony, CharacterBody3D *p_body, double p_delta);
	bool springs_tick(Skeleton3D *p_sk, Node3D *p_pony, CharacterBody3D *p_body, double p_delta);
	void watch_settle(Skeleton3D *p_sk, CharacterBody3D *p_body, double p_step);
	bool settle_holds(Skeleton3D *p_sk, CharacterBody3D *p_body);
	void write_settled(Skeleton3D *p_sk);
	void apply_aside(Skeleton3D *p_sk, Node3D *p_pony, double p_delta);
	void write_between(Skeleton3D *p_sk, double p_t);

	Skeleton3D *springs_skeleton() const;
	void springs_reset();
	void springs_frames(const Transform3D &p_mount);
	void springs_update(double p_delta, const Vector3 &p_world_acceleration);
	void springs_apply();
	void springs_contacts(const Transform3D &p_mount, const Vector3 &p_anchor);
	Plane springs_floor_at(const Vector3 &p_tip, double p_anchor_y);
	void springs_wake_test(size_t p_index, const Plane &p_plane);

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	bool native_step(double p_delta);
	void native_flush();
	bool native_owns() const { return owned; }
	Dictionary native_stats() const;

	// Property accessors (named tailn_* so no script function of the subclass can hide them).
	void tailn_set_pony(Node3D *p_pony);
	Node3D *tailn_get_pony() const;
	void tailn_set_springs(const Ref<RefCounted> &p_springs);
	Ref<RefCounted> tailn_get_springs();
	void tailn_set_previous_velocity(const Vector3 &v) { previous_velocity = v; }
	Vector3 tailn_get_previous_velocity() const { return previous_velocity; }
	void tailn_set_history(bool v) { history = v; }
	bool tailn_get_history() const { return history; }
	void tailn_set_skipped_delta(double v) { skipped_delta = v; }
	double tailn_get_skipped_delta() const { return skipped_delta; }
	void tailn_set_steps(int64_t v) { steps = v; }
	int64_t tailn_get_steps() const { return steps; }
	void tailn_set_aside_goal(double v) { aside_goal = v; }
	double tailn_get_aside_goal() const { return aside_goal; }
	void tailn_set_aside(double v) { aside = v; }
	double tailn_get_aside() const { return aside; }
	void tailn_set_settled(bool v) { settled = v; }
	bool tailn_get_settled() const { return settled; }
	void tailn_set_quiet(double v) { quiet = v; }
	double tailn_get_quiet() const { return quiet; }
	void tailn_set_recheck(double v) { recheck = v; }
	double tailn_get_recheck() const { return recheck; }
	void tailn_set_settle_mount(const Transform3D &v) { settle_mount = v; }
	Transform3D tailn_get_settle_mount() const { return settle_mount; }
	void tailn_set_settle_reach(double v) { settle_reach = v; }
	double tailn_get_settle_reach() const { return settle_reach; }
	void tailn_set_last_mount(const Transform3D &v) { last_mount = v; }
	Transform3D tailn_get_last_mount() const { return last_mount; }
	void tailn_set_last_angles(const PackedVector3Array &v) { last_angles = v; }
	PackedVector3Array tailn_get_last_angles() const { return last_angles; }
	void tailn_set_settled_writes(int64_t v) { settled_writes = v; }
	int64_t tailn_get_settled_writes() const { return settled_writes; }
	void tailn_set_wake_now(bool v) { wake_now = v; }
	bool tailn_get_wake_now() const { return wake_now; }
	void tailn_set_pose_dirty(bool v) { pose_dirty = v; }
	bool tailn_get_pose_dirty() const { return pose_dirty; }
	void tailn_set_solo(bool v) { solo = v; }
	bool tailn_get_solo() const { return solo; }
	void tailn_set_solo_children(int64_t v) { solo_children = v; }
	int64_t tailn_get_solo_children() const { return solo_children; }
	void tailn_set_read_bones(const PackedInt32Array &v) { read_bones = v; }
	PackedInt32Array tailn_get_read_bones() const { return read_bones; }
	void tailn_set_to(const Array &v) { to = v; }
	Array tailn_get_to() const { return to; }
	void tailn_set_from_rotation(const Array &v) { from_rotation = v; }
	Array tailn_get_from_rotation() const { return from_rotation; }
	void tailn_set_to_rotation(const Array &v) { to_rotation = v; }
	Array tailn_get_to_rotation() const { return to_rotation; }
	void tailn_set_ray_floor(const Callable &v) { ray_floor = v; }
	Callable tailn_get_ray_floor() const { return ray_floor; }
	void tailn_set_plane_floor(const Callable &v) { plane_floor = v; }
	Callable tailn_get_plane_floor() const { return plane_floor; }

	PonyTailMotionNative();
};

} // namespace godot
