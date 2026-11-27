// Native pony leg/pose solver: see pony_solver_native.h. Each function below names the
// GDScript it mirrors; keep them in step when the GDScript changes.
#include "pony_solver_native.h"
#include "engine_math.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

using namespace pony;

void PonySolverNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("surface_skin", "starts", "slots", "points", "weights", "poses"), &PonySolverNative::surface_skin);
	ClassDB::bind_method(D_METHOD("surface_envelope", "vertices", "normals", "witnesses", "rebuild"), &PonySolverNative::surface_envelope);
	ClassDB::bind_method(D_METHOD("surface_query", "mesh", "posed", "overlaps", "cloth", "triangles", "adjacent",
			"frame", "bounds", "normals", "limits", "motion", "pruning"), &PonySolverNative::surface_query);
	ClassDB::bind_method(D_METHOD("bind_rig", "parents"), &PonySolverNative::bind_rig);
	ClassDB::bind_method(D_METHOD("bind_limits", "indices", "data"), &PonySolverNative::bind_limits);
	ClassDB::bind_method(D_METHOD("forward_kinematics", "local", "frame"), &PonySolverNative::forward_kinematics);
	ClassDB::bind_method(D_METHOD("solve_leg", "corrected", "source", "frame", "leg", "sole", "max_flex_degrees",
								 "target", "sole_basis", "pole", "epsilon", "budget"),
			&PonySolverNative::solve_leg);
	ClassDB::bind_method(D_METHOD("apply_limits", "pose"), &PonySolverNative::apply_limits);
	ClassDB::bind_method(D_METHOD("constrain_basis", "index", "basis"), &PonySolverNative::constrain_basis);
	ClassDB::bind_method(D_METHOD("bind_contact_legs", "bones", "end_heights", "sole_bases"), &PonySolverNative::bind_contact_legs);
	ClassDB::bind_method(D_METHOD("contacts_begin", "source_pose", "feet", "global", "pivot", "model_frame", "delta", "timing", "motion"),
			&PonySolverNative::contacts_begin);
	ClassDB::bind_method(D_METHOD("contacts_plant", "feet", "hits", "state", "scalars"), &PonySolverNative::contacts_plant);
	ClassDB::bind_method(D_METHOD("contacts_finish", "feet", "contacts", "delta", "state", "global", "model_frame"),
			&PonySolverNative::contacts_finish);
	ClassDB::bind_method(D_METHOD("contacts_begin_plant", "source_pose", "feet", "global", "pivot", "model_frame", "delta",
								 "timing", "motion", "state", "scalars", "ray"),
			&PonySolverNative::contacts_begin_plant);
	ClassDB::bind_method(D_METHOD("contacts_resample_finish", "feet", "delta", "state", "global", "model_frame", "ray"),
			&PonySolverNative::contacts_resample_finish);
	ClassDB::bind_method(D_METHOD("bind_tail", "tips", "rest_bases", "angle_limits"), &PonySolverNative::bind_tail);
	ClassDB::bind_method(D_METHOD("tail_update", "angles", "velocity", "base_pose", "mount_frame", "delta", "world_acceleration",
								 "mount_state", "amounts"),
			&PonySolverNative::tail_update);
	ClassDB::bind_method(D_METHOD("tail_tip_points", "angles", "base_pose", "mount"), &PonySolverNative::tail_tip_points);
	ClassDB::bind_method(D_METHOD("tail_project", "angles", "velocity", "base_pose", "mount", "planes", "iterations", "flags"),
			&PonySolverNative::tail_project);
	ClassDB::bind_method(D_METHOD("measure_self_collision", "fk", "bones", "soles", "weights", "frame", "forward", "shape",
								 "belly_from", "belly_to"),
			&PonySolverNative::measure_self_collision);
	ClassDB::bind_method(D_METHOD("bind_probe", "pony", "exclude"), &PonySolverNative::bind_probe);
	ClassDB::bind_method(D_METHOD("probe", "point", "rise", "hip_height", "mask", "max_slope_degrees"), &PonySolverNative::probe);
	ClassDB::bind_method(D_METHOD("bind_body", "neutral_soles"), &PonySolverNative::bind_body);
	ClassDB::bind_method(D_METHOD("update_body", "global", "body_tilt", "model_frame", "body_offset", "secondary_offset", "scalars"),
			&PonySolverNative::update_body);
	ClassDB::bind_method(D_METHOD("write_bone_poses", "skeleton", "pose"), &PonySolverNative::write_bone_poses);
	ClassDB::bind_method(D_METHOD("write_bone_poses_skip", "skeleton", "pose"), &PonySolverNative::write_bone_poses_skip);
	ClassDB::bind_method(D_METHOD("invalidate_bone_skip"), &PonySolverNative::invalidate_bone_skip);
	ClassDB::bind_method(D_METHOD("bind_eyes", "lid_open", "lid_closed", "eye_shapes", "brow_shapes", "ear_shapes", "eye_bones",
								 "head_bone", "eye_center_head", "rest_globals", "parents"),
			&PonySolverNative::bind_eyes);
	ClassDB::bind_method(D_METHOD("eye_process", "skeleton", "scalars", "gaze", "offset", "target_world", "expression_eyes",
								 "expression_brows", "expression_ears", "surface_update"),
			&PonySolverNative::eye_process);
	ClassDB::bind_method(D_METHOD("eye_rewrite", "skeleton"), &PonySolverNative::eye_rewrite);
	ClassDB::bind_method(D_METHOD("boop_sync", "skeleton", "bones", "snoot", "skull_shape", "muzzle_shape", "decals"),
			&PonySolverNative::boop_sync);
	ClassDB::bind_method(D_METHOD("bind_clip_head", "bones", "parent_frames"), &PonySolverNative::bind_clip_head);
	ClassDB::bind_method(D_METHOD("clip_head", "skeleton", "head", "gaze", "neck_gaze", "rest"), &PonySolverNative::clip_head);
	ClassDB::bind_method(D_METHOD("bind_pose_legs", "bones", "poles", "max_flex", "scalars", "belly_from", "belly_to"),
			&PonySolverNative::bind_pose_legs);
	ClassDB::bind_method(D_METHOD("solve_gather", "source", "feet", "leg_poles", "pushes", "frame", "forward", "delta", "shape"),
			&PonySolverNative::solve_gather);
	ClassDB::bind_method(D_METHOD("solve_run"), &PonySolverNative::solve_run);
	ClassDB::bind_method(D_METHOD("solve_scatter", "source", "feet", "leg_poles", "pushes"), &PonySolverNative::solve_scatter);
	ClassDB::bind_method(D_METHOD("solve_batch", "solvers", "parallel"), &PonySolverNative::solve_batch);
	ClassDB::bind_method(D_METHOD("solve_outputs"), &PonySolverNative::solve_outputs);
	ClassDB::bind_method(D_METHOD("solve_kick"), &PonySolverNative::solve_kick);
	ClassDB::bind_method(D_METHOD("solve_join"), &PonySolverNative::solve_join);
	ClassDB::bind_method(D_METHOD("solve_pending"), &PonySolverNative::solve_pending);
	ClassDB::bind_method(D_METHOD("solve_leg_stage", "corrected", "source", "frame", "leg", "sole", "max_flex_degrees",
								 "target", "sole_basis", "pole", "epsilon", "budget", "stage"),
			&PonySolverNative::solve_leg_stage);
}

void PonySolverNative::bind_rig(const PackedInt32Array &p_parents) {
	solve_join();
	parents.assign(p_parents.ptr(), p_parents.ptr() + p_parents.size());
	chains.clear();
	contact_fk_bones.clear();
	scratch_local.assign(parents.size(), Transform3D());
	scratch_global.assign(parents.size(), Transform3D());
}

// Per joint, 24 doubles: parent basis rows (9), rest basis rows (9), axis (3), lower, upper, swing.
void PonySolverNative::bind_limits(const PackedInt32Array &p_indices, const PackedFloat64Array &p_data) {
	solve_join();
	joints.clear();
	joint_order.clear();
	ERR_FAIL_COND(p_data.size() != p_indices.size() * 24);
	const double *d = p_data.ptr();
	for (int64_t i = 0; i < p_indices.size(); i++) {
		const double *j = d + i * 24;
		Joint joint;
		joint.parent = Basis(j[0], j[1], j[2], j[3], j[4], j[5], j[6], j[7], j[8]);
		joint.rest = Basis(j[9], j[10], j[11], j[12], j[13], j[14], j[15], j[16], j[17]);
		joint.axis = Vector3(j[18], j[19], j[20]);
		joint.lower = j[21];
		joint.upper = j[22];
		joint.swing = j[23];
		joints[p_indices[i]] = joint;
		joint_order.push_back(p_indices[i]);
	}
}

// limb_solver.gd forward_kinematics()
TypedArray<Transform3D> PonySolverNative::forward_kinematics(const Array &p_local, const Transform3D &p_frame) {
	const int64_t count = p_local.size();
	TypedArray<Transform3D> result;
	result.resize(count);
	std::vector<Transform3D> globals(count);
	for (int64_t i = 0; i < count; i++) {
		const int32_t parent = i < (int64_t)parents.size() ? parents[i] : -1;
		const Transform3D local = p_local[i];
		globals[i] = (parent < 0 ? p_frame : globals[parent]) * local;
		result[i] = globals[i];
	}
	return result;
}

const std::vector<int32_t> &PonySolverNative::chain(int32_t leaf) {
	auto found = chains.find(leaf);
	if (found != chains.end()) {
		return found->second;
	}
	std::vector<int32_t> ancestors;
	for (int32_t ancestor = leaf; ancestor >= 0; ancestor = parents[ancestor]) {
		ancestors.push_back(ancestor);
	}
	std::reverse(ancestors.begin(), ancestors.end());
	return chains.emplace(leaf, std::move(ancestors)).first->second;
}

template <typename Pose>
void PonySolverNative::load_chain(const Pose &local, int32_t leaf) {
	for (int32_t bone : chain(leaf)) {
		scratch_local[bone] = local.get(bone);
	}
}

// limb_solver.gd _chain_kinematics(): only the leaf's ancestors, same multiplication order.
void PonySolverNative::chain_kinematics(const Transform3D &frame, int32_t leaf) {
	for (int32_t bone : chain(leaf)) {
		scratch_global[bone] = (parents[bone] < 0 ? frame : scratch_global[parents[bone]]) * scratch_local[bone];
	}
}

// limb_solver.gd rotate_world()
void PonySolverNative::rotate_world(const Transform3D &frame, int32_t bone, const Quaternion &rotation) {
	const Basis &parent_basis = parents[bone] < 0 ? frame.basis : scratch_global[parents[bone]].basis;
	const Quaternion desired = rotation.normalized() * rotation_of(scratch_global[bone].basis);
	const Quaternion relative = rotation_of(parent_basis).inverse() * desired;
	scratch_local[bone].basis = Basis(relative.normalized()).scaled_local(scratch_local[bone].basis.get_scale());
}

// pony_joint_limits.gd constrain()
Basis PonySolverNative::constrain(int32_t index, const Basis &basis) const {
	auto found = joints.find(index);
	if (found == joints.end()) {
		return basis;
	}
	const Joint &joint = found->second;
	const Quaternion rotation = (joint.parent * basis.orthonormalized() * joint.rest.inverse() * joint.parent.inverse()).get_rotation_quaternion();
	double angle = 0.0;
	Quaternion swing;
	split(rotation, joint.axis, angle, swing);
	if (angle >= joint.lower && angle <= joint.upper && angle_of(swing) <= joint.swing) {
		return basis;
	}
	const double bend = clamp_double(angle, joint.lower, joint.upper);
	const double swing_angle = angle_of(swing);
	if (swing_angle > joint.swing) {
		swing = slerp(Quaternion(), swing, joint.swing / swing_angle);
	}
	const Basis clamped = Basis(swing * axis_angle(joint.axis, bend));
	return (joint.parent.inverse() * clamped * joint.parent * joint.rest).scaled_local(basis.get_scale());
}

// limb_solver.gd _bound_rotation()
template <typename Pose>
void PonySolverNative::bound_rotation(const Pose &source, int32_t bone, double budget) {
	scratch_local[bone].basis = constrain(bone, scratch_local[bone].basis);
	const Transform3D from = source.get(bone);
	const Quaternion before = rotation_of(from.basis);
	const Quaternion after = rotation_of(scratch_local[bone].basis);
	const double angle = angle_between(before, after);
	if (angle > budget) {
		scratch_local[bone] = interpolate(from, scratch_local[bone], budget / angle);
	}
	scratch_local[bone].basis = constrain(bone, scratch_local[bone].basis);
}

// limb_solver.gd solve() (its return value is unused by pony_locomotion.gd).
void PonySolverNative::solve(const Transform3D &frame, int32_t root, int32_t middle, int32_t leaf, const Vector3 &sole,
		double max_flex_degrees, const Vector3 &target, const Basis &sole_basis, const Vector3 &pole, double epsilon) {
	chain_kinematics(frame, leaf);
	const Vector3 r = scratch_global[root].origin;
	const Vector3 m = scratch_global[middle].origin;
	const Vector3 e = scratch_global[leaf].origin;
	const double a = r.distance_to(m);
	const double b = m.distance_to(e);
	const Vector3 scale = scratch_global[leaf].basis.get_scale();
	const Vector3 leaf_target = target - sole_basis.xform(sole * scale);
	Vector3 direction = leaf_target - r;
	const double distance = direction.length();
	if (a < epsilon || b < epsilon || distance < epsilon) {
		return;
	}
	direction /= (real_t)distance;
	const double flex = Math::deg_to_rad(max_flex_degrees);
	const double minimum_reach = std::sqrt(std::max(0.0, a * a + b * b + 2.0 * a * b * engine_cos(flex)));
	const double reach = clamp_double(distance, std::max(minimum_reach, std::abs(a - b) + epsilon), a + b - epsilon);
	Vector3 bend = pole - direction * pole.dot(direction);
	if (bend.length_squared() < 1e-10) {
		bend = direction.cross(Vector3(1, 0, 0));
		if (bend.length_squared() < 1e-10) {
			bend = direction.cross(Vector3(0, 1, 0));
		}
	}
	bend = bend.normalized();
	const double along = (a * a - b * b + reach * reach) / (2.0 * reach);
	const double height = std::sqrt(std::max(0.0, a * a - along * along));
	const Vector3 wanted_middle = r + direction * (real_t)along + bend * (real_t)height;
	rotate_world(frame, root, alignment(m - r, wanted_middle - r));
	chain_kinematics(frame, leaf);
	rotate_world(frame, middle,
			alignment(scratch_global[leaf].origin - scratch_global[middle].origin,
					r + direction * (real_t)reach - scratch_global[middle].origin));
	chain_kinematics(frame, leaf);
	const Quaternion desired_rotation = rotation_of(sole_basis);
	const Quaternion old_rotation = rotation_of(scratch_global[leaf].basis);
	rotate_world(frame, leaf, desired_rotation * old_rotation.inverse());
	chain_kinematics(frame, leaf);
}

// limb_solver.gd refine_constrained()
template <typename Pose>
void PonySolverNative::refine_constrained(const Pose &source, const Transform3D &frame, int32_t root, int32_t proximal,
		int32_t middle, int32_t leaf, const Vector3 &sole, const Vector3 &target, const Basis &sole_basis, double budget) {
	const int32_t mutable_bones[4] = { root, proximal, middle, leaf };
	for (int32_t bone : mutable_bones) {
		scratch_local[bone].basis = constrain(bone, scratch_local[bone].basis);
	}
	chain_kinematics(frame, leaf);
	double best_error = scratch_global[leaf].xform(sole).distance_to(target);
	if (best_error < 0.006) {
		return;
	}
	Transform3D best[4] = { scratch_local[root], scratch_local[proximal], scratch_local[middle], scratch_local[leaf] };
	const int32_t order[3] = { middle, proximal, root };
	for (int iteration = 0; iteration < 6; iteration++) {
		for (int32_t bone : order) {
			chain_kinematics(frame, leaf);
			const Vector3 pivot = scratch_global[bone].origin;
			const Vector3 sole_world = scratch_global[leaf].xform(sole);
			const Quaternion rotation = slerp(Quaternion(), alignment(sole_world - pivot, target - pivot), 0.65);
			rotate_world(frame, bone, rotation);
			bound_rotation(source, bone, budget);
		}
		chain_kinematics(frame, leaf);
		const Quaternion before = rotation_of(scratch_global[leaf].basis);
		const Quaternion desired = rotation_of(sole_basis);
		rotate_world(frame, leaf, desired * before.inverse());
		bound_rotation(source, leaf, budget);
		chain_kinematics(frame, leaf);
		const double error = scratch_global[leaf].xform(sole).distance_to(target);
		if (error < best_error) {
			best_error = error;
			best[0] = scratch_local[root];
			best[1] = scratch_local[proximal];
			best[2] = scratch_local[middle];
			best[3] = scratch_local[leaf];
		}
		if (best_error < 0.002) {
			break;
		}
	}
	for (int j = 0; j < 4; j++) {
		scratch_local[mutable_bones[j]] = best[j];
	}
}

// pony_locomotion.gd _solve_leg() after the pole: solve, the 22-degree budget, the constrained
// refinement and the correction angle. Writes the four leg bones of `corrected` in place and
// returns [correction_angle, limited].
Array PonySolverNative::solve_leg(Array p_corrected, const Array &p_source, const Transform3D &p_frame,
		const PackedInt32Array &p_leg, const Vector3 &p_sole, double p_max_flex_degrees, const Vector3 &p_target,
		const Basis &p_sole_basis, const Vector3 &p_pole, double p_epsilon, double p_budget) {
	return solve_leg_stage(p_corrected, p_source, p_frame, p_leg, p_sole, p_max_flex_degrees, p_target, p_sole_basis,
			p_pole, p_epsilon, p_budget, 3);
}

Array PonySolverNative::solve_leg_stage(Array p_corrected, const Array &p_source, const Transform3D &p_frame,
		const PackedInt32Array &p_leg, const Vector3 &p_sole, double p_max_flex_degrees, const Vector3 &p_target,
		const Basis &p_sole_basis, const Vector3 &p_pole, double p_epsilon, double p_budget, int p_stage) {
	solve_join(); // dev 2026-10-20 multithreading: shares scratch_* and chains with a kicked solve
	Array result;
	ERR_FAIL_COND_V(p_leg.size() != 4, result);
	const int32_t leg[4] = { p_leg[0], p_leg[1], p_leg[2], p_leg[3] };
	ArrayPose corrected{ p_corrected };
	const ArrayPose source{ p_source };
	double correction = 0.0;
	bool limited = false;
	solve_leg_core(corrected, source, p_frame, leg, p_sole, p_max_flex_degrees, p_target, p_sole_basis, p_pole, p_epsilon,
			p_budget, p_stage, correction, limited);
	if (p_stage == 3) {
		result.push_back(correction);
		result.push_back(limited);
	}
	return result;
}

template <typename Corrected, typename Source>
void PonySolverNative::solve_leg_core(Corrected &corrected, const Source &source, const Transform3D &frame, const int32_t leg[4],
		const Vector3 &sole, double max_flex_degrees, const Vector3 &target, const Basis &sole_basis, const Vector3 &pole,
		double epsilon, double budget, int stage, double &r_correction, bool &r_limited) {
	const int32_t root = leg[0], proximal = leg[1], middle = leg[2], leaf = leg[3];
	load_chain(corrected, leaf);
	solve(frame, root, middle, leaf, sole, max_flex_degrees, target, sole_basis, pole, epsilon);
	const int32_t three[3] = { root, middle, leaf };
	if (stage == 1) {
		for (int32_t bone : three) {
			corrected.set(bone, scratch_local[bone]);
		}
		return;
	}
	double maximum = 0.0;
	for (int32_t bone : three) {
		const Transform3D from = source.get(bone);
		maximum = std::max(maximum, angle_between(rotation_of(from.basis), rotation_of(scratch_local[bone].basis)));
	}
	bool limited = false;
	if (maximum > budget) {
		const double blend = budget / maximum;
		for (int32_t bone : three) {
			const Transform3D from = source.get(bone);
			scratch_local[bone] = interpolate(from, scratch_local[bone], blend);
		}
		limited = true;
	}
	double correction = std::min(maximum, budget);
	if (stage == 2) {
		for (int32_t bone : three) {
			corrected.set(bone, scratch_local[bone]);
		}
		return;
	}
	refine_constrained(source, frame, root, proximal, middle, leaf, sole, target, sole_basis, budget);
	const int32_t four[4] = { root, proximal, middle, leaf };
	for (int32_t bone : four) {
		const Transform3D from = source.get(bone);
		correction = std::max(correction, angle_between(rotation_of(from.basis), rotation_of(scratch_local[bone].basis)));
		corrected.set(bone, scratch_local[bone]);
	}
	r_correction = correction;
	r_limited = limited;
}

// pony_joint_limits.gd apply(): constrains every bound joint of `pose` in place and returns
// the angle each one moved, in bind_limits() order.
// pony_joint_limits.gd constrain(): `joints` is written only by bind_limits(), which joins any
// kicked solve first, and the solve task only reads it, so no join is needed here.
Basis PonySolverNative::constrain_basis(int32_t p_index, const Basis &p_basis) const {
	return constrain(p_index, p_basis);
}

PackedFloat64Array PonySolverNative::apply_limits(Array p_pose) {
	solve_join();
	PackedFloat64Array angles;
	angles.resize(joint_order.size());
	ArrayPose pose{ p_pose };
	apply_limits_core(pose, angles.ptrw());
	return angles;
}

template <typename Pose>
void PonySolverNative::apply_limits_core(Pose &pose, double *r_angles) {
	for (size_t i = 0; i < joint_order.size(); i++) {
		const int32_t index = joint_order[i];
		Transform3D transform = pose.get(index);
		const Quaternion before = rotation_of(transform.basis);
		transform.basis = constrain(index, transform.basis);
		pose.set(index, transform);
		r_angles[i] = angle_between(before, rotation_of(transform.basis));
	}
}

// The batched pose solve (pose_batch.cpp) runs the same code on C++ copies of the pose.
template void PonySolverNative::solve_leg_core<PonySolverNative::VectorPose, PonySolverNative::VectorPose>(VectorPose &,
		const VectorPose &, const Transform3D &, const int32_t[4], const Vector3 &, double, const Vector3 &, const Basis &,
		const Vector3 &, double, double, int, double &, bool &);
template void PonySolverNative::apply_limits_core<PonySolverNative::VectorPose>(VectorPose &, double *);
