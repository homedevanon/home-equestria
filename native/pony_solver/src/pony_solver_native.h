// Native pony leg/pose solver (docs/NATIVE_SOLVER_2026_09_25.md).
// A line-by-line port of the hot GDScript in world/characters/locomotion/limb_solver.gd
// (forward kinematics, analytic leg solve, constrained refinement), the per-leg budget in
// pony_locomotion.gd _solve_leg() and pony_joint_limits.gd constrain()/apply(). Scalars are
// doubles like GDScript floats; vectors, bases and quaternions are Godot's single-precision
// types, and trigonometry goes through the engine's own builtin methods, so every operation
// matches the GDScript it replaces bit for bit, on every platform.
#pragma once

#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/triangle_mesh.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <unordered_map>
#include <vector>

namespace godot {

class Skeleton3D;

class PonySolverNative : public RefCounted {
	GDCLASS(PonySolverNative, RefCounted)

public:
	// face.cpp: a named expression shape, Dictionary(bone -> Transform3D) in iteration order.
	struct EyeShape {
		String name;
		std::vector<std::pair<int32_t, Transform3D>> bones;
	};

private:

	struct Joint {
		Basis parent;
		Basis rest;
		Vector3 axis;
		double lower = 0.0;
		double upper = 0.0;
		double swing = 0.0;
	};

	std::vector<int32_t> parents;
	std::unordered_map<int32_t, std::vector<int32_t>> chains; // leaf -> ancestors, root first
	std::unordered_map<int32_t, Joint> joints;
	std::vector<int32_t> joint_order; // pony_joint_limits.gd dictionary order
	std::vector<Transform3D> scratch_local;
	std::vector<Transform3D> scratch_global;

	// hoof_contacts.cpp: leg constants and the per-foot values carried between the phases.
	struct ContactLeg {
		int32_t leaf = 0;
		int32_t end = 0;
		double end_height = 0.0;
		Basis sole_basis;
	};
	struct ContactFoot {
		Vector3 local_sole;
		Vector3 source_sole;
		Vector3 stride_offset;
		Vector3 reference;
		Vector3 previous_landing;
		Vector3 previous_landing_normal;
		bool previous_landing_valid = false;
		bool airborne = false;
		double contact_weight = 1.0;
		double weight = 1.0;
		bool hit = false;
		Vector3 hit_position;
		Vector3 hit_normal;
		bool planted = false;
		bool resample = false;
		Vector3 desired_offset;
	};
	ContactLeg contact_legs[4];
	ContactFoot contact_feet[4];
	// contacts_begin_plant() -> contacts_resample_finish(): contacts_plant()'s re-sample points.
	PackedVector3Array contact_resample_points;
	PackedByteArray contact_resample;
	// Only hoof leaves, sole ends and their ancestors; invalidated by either binding.
	std::vector<int32_t> contact_fk_bones;
	std::vector<Transform3D> contact_local_fk;
	std::vector<Transform3D> contact_adapted_fk;
	Transform3D contact_frame;

	// tail.cpp: bound tail constants and the working state of one call.
	std::vector<Vector3> tail_tips;
	std::vector<Basis> tail_rest_bases;
	std::vector<double> tail_angle_limits;
	std::vector<Vector3> tail_angles;
	std::vector<Vector3> tail_velocity;
	std::vector<Transform3D> tail_base;
	std::vector<Transform3D> tail_frame;
	void tail_load(const PackedVector3Array &p_angles, const PackedVector3Array &p_velocity, const Array &p_base_pose);
	void tail_frames(const Transform3D &mount_frame);

	// Pose accessors: the same solve code runs on the GDScript pose arrays (inline calls) and on
	// C++ copies (the batched solve, which never touches a Godot container on a worker thread).
	struct ArrayPose {
		Array array;
		Transform3D get(int64_t i) const { return array[i]; }
		void set(int64_t i, const Transform3D &t) { array[i] = t; }
	};
	struct VectorPose {
		std::vector<Transform3D> *vector;
		const Transform3D &get(int64_t i) const { return (*vector)[i]; }
		void set(int64_t i, const Transform3D &t) { (*vector)[i] = t; }
	};

	const std::vector<int32_t> &chain(int32_t leaf);
	template <typename Pose>
	void load_chain(const Pose &local, int32_t leaf);
	void chain_kinematics(const Transform3D &frame, int32_t leaf);
	void rotate_world(const Transform3D &frame, int32_t bone, const Quaternion &rotation);
	Basis constrain(int32_t index, const Basis &basis) const;
	template <typename Pose>
	void bound_rotation(const Pose &source, int32_t bone, double budget);
	void solve(const Transform3D &frame, int32_t root, int32_t middle, int32_t leaf, const Vector3 &sole,
			double max_flex_degrees, const Vector3 &target, const Basis &sole_basis, const Vector3 &pole, double epsilon);
	template <typename Pose>
	void refine_constrained(const Pose &source, const Transform3D &frame, int32_t root, int32_t proximal,
			int32_t middle, int32_t leaf, const Vector3 &sole, const Vector3 &target, const Basis &sole_basis, double budget);
	// solve_leg_stage() on any pose storage; `leg` is root, proximal, middle, leaf.
	template <typename Corrected, typename Source>
	void solve_leg_core(Corrected &corrected, const Source &source, const Transform3D &frame, const int32_t leg[4],
			const Vector3 &sole, double max_flex_degrees, const Vector3 &target, const Basis &sole_basis, const Vector3 &pole,
			double epsilon, double budget, int stage, double &r_correction, bool &r_limited);
	template <typename Pose>
	void apply_limits_core(Pose &pose, double *r_angles);

	// self_collision.cpp: pony_self_collision.gd measure() on plain values.
	struct MeasureResult {
		Vector3 wanted[4];
		float penetration[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
		double max_penetration = 0.0;
		std::vector<double> records; // depth, label, i, j per overlap, detection order
	};
	static void measure_core(const Transform3D p_middles[4], const Transform3D p_leaves[4], const Vector3 p_soles[4],
			const double p_weights[4], const Transform3D &p_frame, const Vector3 &p_forward, const double p_shape[4],
			const Vector3 &p_belly_from, const Vector3 &p_belly_to, MeasureResult &r_result);

	// pose_batch.cpp: the whole pose solve of a free pony (not held, no hoof held) as one job:
	// pony_locomotion.gd _solve_pose(), _solve_leg(), _resolve_self_collision() (with
	// pony_self_collision.gd integrate()) and _finish_joint_constraints(). solve_gather() and
	// solve_scatter() touch Godot containers on the main thread; solve_run() only this struct.
	struct PoseLeg {
		int32_t bones[4] = { 0, 0, 0, 0 }; // root, proximal, middle, leaf
		Vector3 pole;
		double max_flex = 180.0;
	};
	PoseLeg pose_legs[4];
	double pose_epsilon = 0.0;
	double pose_budget = 0.0;
	Vector3 pose_belly_from;
	Vector3 pose_belly_to;
	struct PoseJob {
		// Inputs, gathered on the main thread.
		std::vector<Transform3D> source;
		Transform3D frame;
		Vector3 forward;
		double delta = 0.0;
		Vector3 sole[4];
		Vector3 target[4];
		Basis foot_basis[4];
		double weight[4] = { 0.0, 0.0, 0.0, 0.0 };
		bool planted[4] = { false, false, false, false };
		Vector3 leg_poles_in[4];
		Vector3 pushes_in[4];
		double shape[4] = { 0.0, 0.0, 0.0, 0.0 };
		// Working copies and results.
		std::vector<Transform3D> corrected;
		std::vector<Transform3D> fk;
		std::vector<Transform3D> solved;
		Vector3 leg_poles[4];
		Vector3 pushes[4];
		bool limited[4] = { false, false, false, false };
		double correction[4] = { 0.0, 0.0, 0.0, 0.0 };
		Vector3 self_push[4];
		double self_penetration[4] = { 0.0, 0.0, 0.0, 0.0 };
		MeasureResult measure;
		std::vector<double> limit_angles;
	};
	PoseJob job;
	// dev 2026-10-20 multithreading: the WorkerThreadPool task running solve_run() on `job` since
	// solve_kick(), or -1. Ownership hand-off: between solve_kick() and solve_join() the task owns
	// `job`, `scratch_local`, `scratch_global` and `chains` (solve_run() writes them); the main
	// thread reads `parents`, `joints`, `joint_order` and `pose_legs` concurrently, which nothing
	// writes while a task is pending (every bind_* joins first). Every main-thread entry point that
	// touches the task's members calls solve_join() first; wait_for_task_completion() is the
	// happens-before edge that publishes the worker's writes. Only the main thread kicks or joins.
	int64_t solve_task = -1;
	static void run_kicked(void *p_solver);

	// ground.cpp: the reused probe query and the body-support constants.
	ObjectID probe_owner;
	Ref<PhysicsRayQueryParameters3D> probe_query;
	std::vector<Vector3> body_neutral_soles;

	// face.cpp: bound eye motion data and the last full run's bone writes.
	std::vector<std::pair<int32_t, Transform3D>> eye_lid_open;
	std::vector<Transform3D> eye_lid_closed;
	std::vector<EyeShape> eye_shapes;
	std::vector<EyeShape> brow_shapes;
	std::vector<EyeShape> ear_shapes;
	std::vector<int32_t> eye_bones;
	int32_t eye_head_bone = -1;
	Vector3 eye_center_head;
	std::vector<Transform3D> eye_rest_globals;
	std::vector<int32_t> eye_parents;
	std::vector<std::pair<int32_t, Transform3D>> eye_written;
	// pony_clip_head.gd: neck and head bones and their parents' rest frames.
	std::vector<int32_t> clip_head_bones;
	std::vector<Basis> clip_head_parents;
	double eye_convergence = 5.0;
	bool eye_asymmetric = false;
	double eye_inward = 0.0;
	double eye_vertical = 0.0;
	// face.cpp: the terrain modifier's bone skip (held values and verified matches per bone).
	bool bone_skip_valid = false;
	std::vector<Vector3> skip_held_position;
	std::vector<Quaternion> skip_held_rotation;
	std::vector<Vector3> skip_held_scale;
	std::vector<Transform3D> skip_last;
	std::vector<Transform3D> skip_match;
	std::vector<Transform3D> skip_miss;
	std::vector<uint8_t> skip_flags;
	void eye_write(Skeleton3D *p_skeleton, int32_t p_bone, const Transform3D &p_pose);
	Vector2 eye_surface_angles(int p_side_index, const Vector2 &p_angles) const;
	Transform3D eye_pose(int p_side_index, const Vector2 &p_angles) const;
	void pose_fk(const std::vector<Transform3D> &local, const Transform3D &frame, std::vector<Transform3D> &r_globals) const;
	void pose_solve_leg(int i, const Vector3 &target);
	void pose_measure();
	static void run_job(void *p_solvers, uint32_t p_index);

protected:
	static void _bind_methods();

public:
	// posed_shoulder_surface.gd: stateless batches; lifecycle/cache thresholds stay in script.
	PackedVector3Array surface_skin(const PackedInt32Array &p_starts, const PackedInt32Array &p_slots,
			const PackedVector3Array &p_points, const PackedFloat32Array &p_weights, const Array &p_poses);
	Dictionary surface_envelope(const PackedVector3Array &p_vertices, const PackedVector3Array &p_normals,
			const Array &p_witnesses, bool p_rebuild);
	Dictionary surface_query(const Ref<TriangleMesh> &p_mesh, const PackedVector3Array &p_posed,
			const PackedInt32Array &p_overlaps, const Vector3 &p_cloth, const PackedInt32Array &p_triangles,
			const Dictionary &p_adjacent, const Transform3D &p_frame, const AABB &p_bounds,
			const PackedVector3Array &p_normals, const PackedFloat32Array &p_limits, double p_motion, bool p_pruning);
	void bind_rig(const PackedInt32Array &p_parents);
	void bind_limits(const PackedInt32Array &p_indices, const PackedFloat64Array &p_data);
	TypedArray<Transform3D> forward_kinematics(const Array &p_local, const Transform3D &p_frame);
	Array solve_leg(Array p_corrected, const Array &p_source, const Transform3D &p_frame, const PackedInt32Array &p_leg,
			const Vector3 &p_sole, double p_max_flex_degrees, const Vector3 &p_target, const Basis &p_sole_basis,
			const Vector3 &p_pole, double p_epsilon, double p_budget);
	PackedFloat64Array apply_limits(Array p_pose);
	// pony_joint_limits.gd constrain() for one bone (0.1.0 perf pass): reads only the bound limits,
	// so it never waits for a kicked solve.
	Basis constrain_basis(int32_t p_index, const Basis &p_basis) const;
	// pony_locomotion.gd _update_contacts() in three phases around its probes (hoof_contacts.cpp).
	void bind_contact_legs(const PackedInt32Array &p_bones, const PackedFloat64Array &p_end_heights, const Array &p_sole_bases);
	PackedVector3Array contacts_begin(const Array &p_source_pose, const Array &p_feet, const Transform3D &p_global,
			const Transform3D &p_pivot, const Transform3D &p_model_frame, double p_delta, const PackedFloat64Array &p_timing,
			const PackedFloat64Array &p_motion);
	Array contacts_plant(const Array &p_feet, const Array &p_hits, const PackedInt32Array &p_state, const PackedFloat64Array &p_scalars);
	void contacts_finish(const Array &p_feet, const Array &p_contacts, double p_delta, const PackedInt32Array &p_state,
			const Transform3D &p_global, const Transform3D &p_model_frame);
	// Perf 2026-11-21 (lane native_calls, contacts_fused.cpp): the same three phases with their
	// probes made here through probe() (the same rays, in the same order), so a HERO tick makes two
	// calls instead of three plus four to eight script _probe() calls and their dictionaries.
	// contacts_begin_plant() = contacts_begin(), probe() at the four references, contacts_plant();
	// it returns contacts_plant()'s array. contacts_resample_finish() = probe() at each re-sample
	// point contacts_plant() asked for, then contacts_finish(). `ray`: hip_height, mask,
	// max_slope_degrees (probe()'s arguments).
	Array contacts_begin_plant(const Array &p_source_pose, const Array &p_feet, const Transform3D &p_global,
			const Transform3D &p_pivot, const Transform3D &p_model_frame, double p_delta, const PackedFloat64Array &p_timing,
			const PackedFloat64Array &p_motion, const PackedInt32Array &p_state, const PackedFloat64Array &p_scalars,
			const PackedFloat64Array &p_ray);
	void contacts_resample_finish(const Array &p_feet, double p_delta, const PackedInt32Array &p_state,
			const Transform3D &p_global, const Transform3D &p_model_frame, const PackedFloat64Array &p_ray);
	// The hybrid tail springs (tail.cpp).
	void bind_tail(const PackedVector3Array &p_tips, const Array &p_rest_bases, const PackedFloat64Array &p_angle_limits);
	Array tail_update(const PackedVector3Array &p_angles, const PackedVector3Array &p_velocity, const Array &p_base_pose,
			const Transform3D &p_mount_frame, double p_delta, const Vector3 &p_world_acceleration, const Array &p_mount_state,
			const PackedFloat64Array &p_amounts);
	PackedVector3Array tail_tip_points(const PackedVector3Array &p_angles, const Array &p_base_pose, const Transform3D &p_mount);
	Array tail_project(const PackedVector3Array &p_angles, const PackedVector3Array &p_velocity, const Array &p_base_pose,
			const Transform3D &p_mount, const Array &p_planes, int32_t p_iterations, const PackedInt32Array &p_flags);
	// pony_self_collision.gd measure() (self_collision.cpp).
	Array measure_self_collision(const Array &p_fk, const PackedInt32Array &p_bones, const PackedVector3Array &p_soles,
			const PackedFloat64Array &p_weights, const Transform3D &p_frame, const Vector3 &p_forward,
			const PackedFloat64Array &p_shape, const Vector3 &p_belly_from, const Vector3 &p_belly_to);
	// Ground rays and body support (ground.cpp).
	void bind_probe(Object *p_pony, const RID &p_exclude);
	Dictionary probe(const Vector3 &p_point, double p_rise, double p_hip_height, int64_t p_mask, double p_max_slope_degrees);
	void bind_body(const PackedVector3Array &p_neutral_soles);
	Array update_body(const Transform3D &p_global, const Quaternion &p_body_tilt, const Transform3D &p_model_frame,
			const Vector3 &p_body_offset, const Vector3 &p_secondary_offset, const PackedFloat64Array &p_scalars);
	// Skeleton-modifier work and the boop spheres (face.cpp).
	void write_bone_poses(Object *p_skeleton, const Array &p_pose);
	int64_t write_bone_poses_skip(Object *p_skeleton, const Array &p_pose);
	void invalidate_bone_skip();
	void bind_eyes(const Dictionary &p_lid_open, const Dictionary &p_lid_closed, const Dictionary &p_eye_shapes,
			const Dictionary &p_brow_shapes, const Dictionary &p_ear_shapes, const PackedInt32Array &p_eye_bones,
			int32_t p_head_bone, const Vector3 &p_eye_center_head, const Array &p_rest_globals, const PackedInt32Array &p_parents);
	void eye_process(Object *p_skeleton, const PackedFloat64Array &p_scalars, const Vector2 &p_gaze, const Vector2 &p_offset,
			const Vector3 &p_target_world, const Dictionary &p_expression_eyes, const Dictionary &p_expression_brows,
			const Dictionary &p_expression_ears, const Callable &p_surface_update);
	void eye_rewrite(Object *p_skeleton);
	void boop_sync(Object *p_skeleton, const PackedInt32Array &p_bones, Object *p_snoot, Object *p_skull_shape,
			Object *p_muzzle_shape, const Array &p_decals);
	void bind_clip_head(const PackedInt32Array &p_bones, const Array &p_parent_frames);
	void clip_head(Object *p_skeleton, const Vector3 &p_head, const Vector3 &p_gaze, const Vector3 &p_neck_gaze, bool p_rest);
	// The batched pose solve (pose_batch.cpp).
	void bind_pose_legs(const PackedInt32Array &p_bones, const PackedVector3Array &p_poles, const PackedFloat64Array &p_max_flex,
			const PackedFloat64Array &p_scalars, const Vector3 &p_belly_from, const Vector3 &p_belly_to);
	void solve_gather(const Array &p_source, const Array &p_feet, const Array &p_leg_poles, const Array &p_pushes,
			const Transform3D &p_frame, const Vector3 &p_forward, double p_delta, const PackedFloat64Array &p_shape);
	void solve_run();
	Array solve_scatter(const Array &p_source, const Array &p_feet, Array p_leg_poles, Array p_pushes);
	void solve_batch(const Array &p_solvers, bool p_parallel);
	PackedFloat64Array solve_outputs() const;
	// dev 2026-10-20 multithreading: start solve_run() on the WorkerThreadPool right after
	// solve_gather(), so it overlaps the rest of the physics tick; solve_join() (or solve_batch(),
	// solve_scatter() and the other guarded entry points) waits for it.
	void solve_kick();
	void solve_join();
	bool solve_pending() const;
	~PonySolverNative();
	// Parity debugging: solve_leg stopped after `p_stage` (1 solve, 2 + budget, 3 + refinement).
	Array solve_leg_stage(Array p_corrected, const Array &p_source, const Transform3D &p_frame, const PackedInt32Array &p_leg,
			const Vector3 &p_sole, double p_max_flex_degrees, const Vector3 &p_target, const Basis &p_sole_basis,
			const Vector3 &p_pole, double p_epsilon, double p_budget, int p_stage);
};

} // namespace godot
