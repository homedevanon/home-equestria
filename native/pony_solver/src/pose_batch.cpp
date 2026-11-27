// The whole pose solve of a free pony (not held, no hoof held, not on the GPU pose batch) as one
// job, so every pony of a physics tick can solve at once on the WorkerThreadPool. Line for line:
// pony_locomotion.gd _solve_pose(), _solve_leg() (pole memory included), _resolve_self_collision()
// with pony_self_collision.gd integrate(), and _finish_joint_constraints() (the joint limits;
// hoof_hold.solve() does nothing without a held hoof). solve_gather() and solve_scatter() read
// and write Godot containers on the main thread; solve_run() works on this pony's PoseJob only
// and calls nothing but math (engine builtins included), so jobs run on any thread in any order
// and give the serial result bit for bit.
#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstring>

using namespace godot;
using namespace pony;

namespace {

// Perf 2026-11-21 (lane native_calls): solve_batch() solves its first pony on the calling thread
// instead of sleeping while the pool solves all of them. Rollback: false.
constexpr bool CALLER_RUNS_FIRST_SOLVE = true;

const double MAX_PUSH = 0.08; // pony_self_collision.gd MAX_PUSH

struct Keys {
	const Variant dynamic_sole = StringName("dynamic_sole");
	const Variant target = StringName("target");
	const Variant basis = StringName("basis");
	const Variant weight = StringName("weight");
	const Variant planted = StringName("planted");
	const Variant limited = StringName("limited");
	const Variant correction_angle = StringName("correction_angle");
	const Variant self_push = StringName("self_push");
	const Variant self_penetration = StringName("self_penetration");
};

const Keys &keys() {
	static const Keys k;
	return k;
}

} // namespace

// Leg constants, once per gait profile. `bones`: root, proximal, middle, leaf per leg; `poles`:
// leg.pole; `max_flex`: leg.max_flex_degrees; `scalars`: epsilon (hip_height * 0.0001), budget
// (deg_to_rad(22)); `belly_from`/`belly_to`: pony_self_collision.gd BELLY_FROM/BELLY_TO.
void PonySolverNative::bind_pose_legs(const PackedInt32Array &p_bones, const PackedVector3Array &p_poles,
		const PackedFloat64Array &p_max_flex, const PackedFloat64Array &p_scalars, const Vector3 &p_belly_from,
		const Vector3 &p_belly_to) {
	solve_join();
	ERR_FAIL_COND(p_bones.size() != 16 || p_poles.size() != 4 || p_max_flex.size() != 4 || p_scalars.size() != 2);
	for (int i = 0; i < 4; i++) {
		for (int k = 0; k < 4; k++) {
			pose_legs[i].bones[k] = p_bones[i * 4 + k];
		}
		pose_legs[i].pole = p_poles[i];
		pose_legs[i].max_flex = p_max_flex[i];
	}
	pose_epsilon = p_scalars[0];
	pose_budget = p_scalars[1];
	pose_belly_from = p_belly_from;
	pose_belly_to = p_belly_to;
}

// Main thread: everything solve_run() reads. `shape`: hoof, segment and belly radius, hoof lift.
void PonySolverNative::solve_gather(const Array &p_source, const Array &p_feet, const Array &p_leg_poles,
		const Array &p_pushes, const Transform3D &p_frame, const Vector3 &p_forward, double p_delta,
		const PackedFloat64Array &p_shape) {
	solve_join();
	ERR_FAIL_COND(p_feet.size() != 4 || p_leg_poles.size() != 4 || p_pushes.size() != 4 || p_shape.size() != 4);
	const Keys &k = keys();
	PoseJob &j = job;
	const int64_t count = p_source.size();
	j.source.resize(count);
	for (int64_t i = 0; i < count; i++) {
		j.source[i] = p_source[i];
	}
	j.frame = p_frame;
	j.forward = p_forward;
	j.delta = p_delta;
	for (int i = 0; i < 4; i++) {
		const Dictionary foot = p_feet[i];
		j.sole[i] = foot[k.dynamic_sole];
		j.target[i] = foot[k.target];
		j.foot_basis[i] = foot[k.basis];
		j.weight[i] = foot[k.weight];
		j.planted[i] = foot[k.planted];
		j.leg_poles_in[i] = p_leg_poles[i];
		j.pushes_in[i] = p_pushes[i];
		j.shape[i] = p_shape[i];
	}
}

// limb_solver.gd forward_kinematics() on the job's copies.
void PonySolverNative::pose_fk(const std::vector<Transform3D> &local, const Transform3D &frame,
		std::vector<Transform3D> &r_globals) const {
	const size_t count = local.size();
	r_globals.resize(count);
	for (size_t i = 0; i < count; i++) {
		const int32_t parent = i < parents.size() ? parents[i] : -1;
		r_globals[i] = (parent < 0 ? frame : r_globals[parent]) * local[i];
	}
}

// pony_locomotion.gd _solve_leg(): the pole (remembered in the body frame) and the native solve.
void PonySolverNative::pose_solve_leg(int i, const Vector3 &target) {
	PoseJob &j = job;
	const PoseLeg &leg = pose_legs[i];
	const int32_t root = leg.bones[0], middle = leg.bones[2], leaf = leg.bones[3];
	const Vector3 line = (j.fk[leaf].origin - j.fk[root].origin).normalized();
	Vector3 pole = j.fk[middle].origin - j.fk[root].origin;
	pole -= line * pole.dot(line);
	if (pole.length_squared() < 0.0004) {
		pole = j.frame.basis.xform(j.leg_poles[i].length_squared() > 0.0 ? j.leg_poles[i] : leg.pole);
	} else {
		j.leg_poles[i] = j.frame.basis.inverse().xform(pole);
	}
	VectorPose corrected{ &j.corrected };
	const VectorPose source{ &j.source };
	double correction = 0.0;
	bool limited = false;
	solve_leg_core(corrected, source, j.frame, leg.bones, j.sole[i], leg.max_flex, target, j.foot_basis[i], pole,
			pose_epsilon, pose_budget, 3, correction, limited);
	if (limited) {
		j.limited[i] = true;
	}
	j.correction[i] = correction;
}

// pony_self_collision.gd measure() on the job's solved forward kinematics.
void PonySolverNative::pose_measure() {
	PoseJob &j = job;
	Transform3D middles[4];
	Transform3D leaves[4];
	for (int i = 0; i < 4; i++) {
		middles[i] = j.solved[pose_legs[i].bones[2]];
		leaves[i] = j.solved[pose_legs[i].bones[3]];
	}
	measure_core(middles, leaves, j.sole, j.weight, j.frame, j.forward, j.shape, pose_belly_from, pose_belly_to, j.measure);
}

// Any thread. Starts from the gathered inputs every time, so it can run again with the same result.
void PonySolverNative::solve_run() {
	PoseJob &j = job;
	// _solve_pose()
	j.corrected = j.source;
	pose_fk(j.source, j.frame, j.fk);
	for (int i = 0; i < 4; i++) {
		j.leg_poles[i] = j.leg_poles_in[i];
		j.pushes[i] = j.pushes_in[i];
		j.limited[i] = false;
		j.correction[i] = 0.0;
		j.self_push[i] = Vector3();
		j.self_penetration[i] = 0.0;
	}
	for (int i = 0; i < 4; i++) {
		pose_solve_leg(i, j.target[i]);
	}
	// _resolve_self_collision()
	pose_fk(j.corrected, j.frame, j.solved);
	pose_measure();
	// pony_self_collision.gd integrate()
	bool active = false;
	for (int i = 0; i < 4; i++) {
		Vector3 target = j.measure.wanted[i].limit_length(MAX_PUSH);
		if (j.weight[i] > 0.7 && j.planted[i]) {
			target.y = (real_t)minf(target.y, 0.0);
		}
		const double response = target.length_squared() > j.pushes[i].length_squared() ? 0.03 : 0.08;
		j.pushes[i] = j.pushes[i].lerp(target, (real_t)(1.0 - engine_exp(-j.delta / response)));
		if (j.pushes[i].length() < 0.0005) {
			j.pushes[i] = Vector3();
		} else {
			active = true;
		}
	}
	if (active) {
		for (int i = 0; i < 4; i++) {
			const Vector3 push = j.pushes[i];
			if (push == Vector3()) {
				continue;
			}
			for (int32_t bone : pose_legs[i].bones) {
				j.corrected[bone] = j.source[bone];
			}
			j.self_push[i] = push;
			pose_solve_leg(i, j.target[i] + push);
		}
		// Residual overlap after the leg did what its joints allow. Diagnostics only.
		pose_fk(j.corrected, j.frame, j.solved);
		pose_measure();
		for (int i = 0; i < 4; i++) {
			j.self_penetration[i] = j.measure.penetration[i];
		}
	}
	// _finish_joint_constraints(): pony_joint_limits.gd apply().
	j.limit_angles.resize(joint_order.size());
	VectorPose corrected{ &j.corrected };
	apply_limits_core(corrected, j.limit_angles.data());
}

// Main thread: writes the feet fields, the pole memory and the self-collision pushes in place and
// returns [corrected pose, penetration (PackedFloat32Array), max_penetration, overlap records
// (PackedFloat64Array), joint-limit angles (PackedFloat64Array, pony_joint_limits.gd order)].
// The corrected pose is a copy of `source` (the gathered source pose, as _solve_pose()'s
// source_pose.duplicate()) with only the bones the solve changed written over it.
Array PonySolverNative::solve_scatter(const Array &p_source, const Array &p_feet, Array p_leg_poles, Array p_pushes) {
	solve_join();
	Array result;
	ERR_FAIL_COND_V(p_feet.size() != 4 || p_leg_poles.size() != 4 || p_pushes.size() != 4, result);
	const Keys &k = keys();
	const PoseJob &j = job;
	for (int i = 0; i < 4; i++) {
		Dictionary foot = p_feet[i];
		foot[k.self_push] = j.self_push[i];
		foot[k.self_penetration] = j.self_penetration[i];
		if (j.limited[i]) {
			foot[k.limited] = true;
		}
		foot[k.correction_angle] = j.correction[i];
		p_leg_poles[i] = j.leg_poles[i];
		p_pushes[i] = j.pushes[i];
	}
	ERR_FAIL_COND_V(p_source.size() != (int64_t)j.corrected.size(), result);
	Array corrected = p_source.duplicate();
	for (size_t i = 0; i < j.corrected.size(); i++) {
		// Bitwise, so a changed sign of zero is still written.
		if (std::memcmp(&j.corrected[i], &j.source[i], sizeof(Transform3D)) != 0) {
			corrected[i] = j.corrected[i];
		}
	}
	PackedFloat32Array penetration;
	for (int i = 0; i < 4; i++) {
		penetration.push_back(j.measure.penetration[i]);
	}
	PackedFloat64Array records;
	records.resize(j.measure.records.size());
	for (size_t i = 0; i < j.measure.records.size(); i++) {
		records.set(i, j.measure.records[i]);
	}
	PackedFloat64Array angles;
	angles.resize(j.limit_angles.size());
	for (size_t i = 0; i < j.limit_angles.size(); i++) {
		angles.set(i, j.limit_angles[i]);
	}
	result.push_back(corrected);
	result.push_back(penetration);
	result.push_back(j.measure.max_penetration);
	result.push_back(records);
	result.push_back(angles);
	return result;
}

void PonySolverNative::run_job(void *p_solvers, uint32_t p_index) {
	static_cast<PonySolverNative **>(p_solvers)[p_index]->solve_run();
}

// dev 2026-10-20 multithreading: one pony's solve as its own pool task (solve_kick()).
void PonySolverNative::run_kicked(void *p_solver) {
	static_cast<PonySolverNative *>(p_solver)->solve_run();
}

// Main thread, right after solve_gather(): the solve starts on a worker now instead of when the
// batch flushes (priority 800), so it overlaps the remaining ponies' ticks and every other node
// before the flush. The flush then only waits for what is left. The result is solve_run() on the
// gathered inputs either way, so it is identical to the batched and the serial solve.
void PonySolverNative::solve_kick() {
	solve_join();
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (pool == nullptr) {
		solve_run();
		return;
	}
	solve_task = pool->add_native_task(&PonySolverNative::run_kicked, this, true, String("Pony pose solve"));
}

// Main thread: waits for a kicked solve (if any). Afterwards `job` holds its result.
void PonySolverNative::solve_join() {
	if (solve_task < 0) {
		return;
	}
	const int64_t task = solve_task;
	solve_task = -1;
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (pool != nullptr) { // gone only at engine shutdown, after its threads finished
		pool->wait_for_task_completion(task);
	}
}

bool PonySolverNative::solve_pending() const {
	return solve_task >= 0;
}

// A pony freed while her kicked solve still runs: the task holds `this`, so wait for it (every
// pool task must be waited for anyway).
PonySolverNative::~PonySolverNative() {
	solve_join();
}

// Runs solve_run() of every solver in `solvers` (this one need not be among them): at once on
// the WorkerThreadPool when `parallel`, else one after another on this thread. A solver whose
// solve was kicked (solve_kick()) is only waited for: its job already ran on the same inputs.
void PonySolverNative::solve_batch(const Array &p_solvers, bool p_parallel) {
	std::vector<PonySolverNative *> solvers;
	solvers.reserve(p_solvers.size());
	for (int64_t i = 0; i < p_solvers.size(); i++) {
		PonySolverNative *solver = Object::cast_to<PonySolverNative>(p_solvers[i]);
		if (solver == nullptr) {
			continue;
		}
		if (solver->solve_pending()) {
			solver->solve_join();
			continue;
		}
		solvers.push_back(solver);
	}
	if (!p_parallel || solvers.size() < 2) {
		for (PonySolverNative *solver : solvers) {
			solver->solve_run();
		}
		return;
	}
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (CALLER_RUNS_FIRST_SOLVE) {
		// The calling thread solves the first pony while the pool solves the rest (it would
		// otherwise sleep in the wait). Independent solves: the same results bit for bit.
		const WorkerThreadPool::GroupID group = pool->add_native_group_task(&PonySolverNative::run_job,
				solvers.data() + 1, (int)solvers.size() - 1, -1, true, String("Pony pose solve"));
		solvers[0]->solve_run();
		pool->wait_for_group_task_completion(group);
		return;
	}
	const WorkerThreadPool::GroupID group = pool->add_native_group_task(&PonySolverNative::run_job, solvers.data(),
			(int)solvers.size(), -1, true, String("Pony pose solve"));
	pool->wait_for_group_task_completion(group);
}

// Parity: every result of the last solve_run(), flattened, to compare two runs exactly.
PackedFloat64Array PonySolverNative::solve_outputs() const {
	const_cast<PonySolverNative *>(this)->solve_join();
	PackedFloat64Array out;
	const PoseJob &j = job;
	auto vector = [&](const Vector3 &v) {
		out.push_back(v.x);
		out.push_back(v.y);
		out.push_back(v.z);
	};
	for (const Transform3D &t : j.corrected) {
		for (int c = 0; c < 3; c++) {
			vector(t.basis.get_column(c));
		}
		vector(t.origin);
	}
	for (int i = 0; i < 4; i++) {
		vector(j.leg_poles[i]);
		vector(j.pushes[i]);
		vector(j.self_push[i]);
		out.push_back(j.limited[i] ? 1.0 : 0.0);
		out.push_back(j.correction[i]);
		out.push_back(j.self_penetration[i]);
		out.push_back(j.measure.penetration[i]);
	}
	out.push_back(j.measure.max_penetration);
	for (double value : j.measure.records) {
		out.push_back(value);
	}
	for (double value : j.limit_angles) {
		out.push_back(value);
	}
	return out;
}
