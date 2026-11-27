// PonyTailMotionNative (tail_motion_native.h): hybrid_tail_motion.gd's per-step body, and the parts
// of hybrid_tail_physics.gd / pony_tail.gd it calls (update(), apply_pose(), the floor-only contact
// pass), line for line. The spring step and the floor projection are copies of tail.cpp
// (PonySolverNative::tail_update / tail_project, which the springs' GDScript calls); keep the three
// in step. Engine math that reaches the C runtime goes through engine_math.h as there.
#include "tail_motion_native.h"

#include "engine_math.h"

#include <godot_cpp/classes/character_body3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cmath>

using namespace godot;

namespace {

// hybrid_tail_motion.gd
const double SETTLE_SECONDS = 0.5;
const double SETTLE_RECHECK = 1.0;
const double SETTLE_MOVE = 0.002;
const double SETTLE_TURN = 0.008;
const double QUIET_SPEED = 0.02;
const double QUIET_SPIN = 0.02;
const double QUIET_STEP = 0.0005;
const double ASIDE_SPEED = 1.2;

// pony_tail.gd / hybrid_tail_physics.gd (as tail.cpp)
const Vector3 GRAVITY(0.0, -9.8, 0.0);
const double MAX_STEP = 1.0 / 120.0;
const double MAX_DELTA = 0.25;
const double MAX_ANGULAR_SPEED = 2.8;
const double MAX_ANGULAR_ACCELERATION = 70.0;
const double MAX_ROOT_ACCELERATION = 18.0;
const double TAIL_RADIUS = .09;
const double MAX_CONTACT_ROTATION = .14;
const double SKIN_MARGIN = .009;
const double LEDGE_LIFT = .06;

const char *HYBRID_SPRINGS = "res://world/characters/hybrid_mare/hybrid_tail_physics.gd";
const char *BACKGROUND_SPRINGS = "res://world/characters/background/background_tail_physics.gd";

// pony_tail.gd _angle_basis() (tail.cpp angle_basis)
Basis angle_basis(const Vector3 &value) {
	const double angle = value.length();
	return angle > 0.000001 ? pony::basis_axis_angle(value / (real_t)angle, angle) : Basis();
}

// pony_tail.gd _rotation_vector() (tail.cpp rotation_vector)
Vector3 rotation_vector(const Quaternion &value) {
	const Vector3 axis(value.x, value.y, value.z);
	const double sine = axis.length();
	return sine > 0.000001 ? axis * (real_t)(2.0 * pony::engine_atan2(sine, value.w) / sine) : Vector3();
}

// @GlobalScope.move_toward (double), Godot core/math/math_funcs.h.
double move_toward(double from, double to, double delta) {
	const double difference = to - from;
	if (std::abs(difference) <= delta) {
		return to;
	}
	return from + (difference > 0.0 ? 1.0 : (difference < 0.0 ? -1.0 : 0.0)) * delta;
}

struct Contact {
	bool found = false;
	double depth = 0.0;
	int bone = 0;
	Vector3 offset;
	Vector3 normal;
};

} // namespace

struct PonyTailMotionNative::Names {
	StringName sim_tier = "sim_tier", sim_phase = "sim_phase", hero_divisor = "hero_divisor", tick = "_tick";
	StringName motion_paused = "motion_paused", touch_body = "touch_body", active = "active";
	StringName logic_divisor = "LOGIC_DIVISOR", profile = "profile", hip_height = "hip_height";
	StringName position = "position", normal = "normal", probe = "_probe";
	StringName bones = "bones", mount = "_mount", tips = "_tips", rest_bases = "_rest_bases", angle_limits = "angle_limits";
	StringName gravity_amount = "gravity_amount", inertia_amount = "inertia_amount", native_retry = "_native_retry";
	StringName native = "native", skeleton = "skeleton", angles = "angles", angular_velocity = "angular_velocity";
	StringName base_pose = "_base_pose", floor_planes = "_floor_planes", sleeping = "sleeping", quiet_frames = "_quiet_frames";
	StringName ground_wait = "_ground_wait", last_anchor = "_last_anchor", previous_mount = "_previous_mount";
	StringName after_angles = "_after_angles", contact_mount = "_contact_mount", previous_mount_basis = "_previous_mount_basis";
	StringName previous_mount_velocity = "_previous_mount_velocity", mount_history = "_mount_history";
	StringName max_penetration = "max_penetration", projected_contacts = "projected_contacts", contacts = "contacts";
	StringName solve_usec = "solve_usec", cheap_floor = "cheap_floor", contact_iterations = "contact_iterations";
	StringName floor_probe = "floor_probe", floor_is_plane = "floor_is_plane", contact_enabled = "_contact_enabled";
	StringName collision_enabled = "collision_enabled";
};

PonyTailMotionNative::Names &PonyTailMotionNative::names() {
	static Names n;
	return n;
}

PonyTailMotionNative::PonyTailMotionNative() {
	to = TypedArray<Transform3D>();
	from_rotation = TypedArray<Quaternion>();
	to_rotation = TypedArray<Quaternion>();
}

Node3D *PonyTailMotionNative::pony_node() const {
	return pony_id.is_valid() ? Object::cast_to<Node3D>(ObjectDB::get_instance(uint64_t(pony_id))) : nullptr;
}

Skeleton3D *PonyTailMotionNative::springs_skeleton() const {
	return s.skeleton.is_valid() ? Object::cast_to<Skeleton3D>(ObjectDB::get_instance(uint64_t(s.skeleton))) : nullptr;
}

void PonyTailMotionNative::tailn_set_pony(Node3D *p_pony) {
	flush_springs();
	pony_id = p_pony != nullptr ? ObjectID(p_pony->get_instance_id()) : ObjectID();
}

Node3D *PonyTailMotionNative::tailn_get_pony() const {
	return pony_node();
}

void PonyTailMotionNative::tailn_set_springs(const Ref<RefCounted> &p_springs) {
	flush_springs();
	springs = p_springs;
}

// Any outside reader (and the script fallback) gets the springs object with the current state.
Ref<RefCounted> PonyTailMotionNative::tailn_get_springs() {
	flush_springs();
	return springs;
}

void PonyTailMotionNative::native_flush() {
	flush_springs();
}

void PonyTailMotionNative::_notification(int p_what) {
	if (p_what == NOTIFICATION_EXIT_TREE) {
		flush_springs();
	}
}

namespace {

Vector3 plane_vector(const Dictionary &dict, const StringName &key) {
	return dict.get(key, Variant());
}

} // namespace

// Reads the springs object in: its configuration and its state. False (nothing read) when it is
// not a springs script this code mirrors, or a part the step needs is missing.
bool PonyTailMotionNative::load_springs(Node3D *p_pony, Skeleton3D *p_skeleton) {
	const Names &n = names();
	Object *o = springs.ptr();
	Script *script = Object::cast_to<Script>((Object *)o->get_script());
	if (script == nullptr) {
		return false;
	}
	const String path = script->get_path();
	if (path != HYBRID_SPRINGS && path != BACKGROUND_SPRINGS) {
		return false;
	}
	if (Object::cast_to<CharacterBody3D>(p_pony) == nullptr) {
		return false;
	}
	const Variant divisor = p_pony->get(n.logic_divisor);
	if (divisor.get_type() != Variant::INT || (int64_t)divisor < 1) {
		return false;
	}
	const Variant native = o->get(n.native);
	if (native.get_type() != Variant::OBJECT || (Object *)native == nullptr) {
		return false; // the springs' GDScript maths: stays on the script
	}
	Skeleton3D *skeleton = Object::cast_to<Skeleton3D>((Object *)o->get(n.skeleton));
	if (skeleton == nullptr) {
		return false;
	}
	const Array bones_in = o->get(n.bones);
	const Array tips_in = o->get(n.tips);
	const Array rest_in = o->get(n.rest_bases);
	const Array limits_in = o->get(n.angle_limits);
	const Array angles_in = o->get(n.angles);
	const Array velocity_in = o->get(n.angular_velocity);
	const Array base_in = o->get(n.base_pose);
	const Array planes_in = o->get(n.floor_planes);
	const int64_t count = bones_in.size();
	if (count < 2 || tips_in.size() != count || rest_in.size() != count || limits_in.size() < count || angles_in.size() != count ||
			velocity_in.size() != count || base_in.size() != count || planes_in.size() != count) {
		return false;
	}
	const int32_t mount = (int64_t)o->get(n.mount);
	if (mount < 0 || mount >= skeleton->get_bone_count()) {
		return false;
	}
	const int32_t bone_count = p_skeleton->get_bone_count();
	for (int64_t i = 0; i < count; i++) {
		const int32_t bone = (int64_t)bones_in[i];
		if (bone < 0 || bone >= bone_count) {
			return false;
		}
	}
	for (int64_t i = 0; i < read_bones.size(); i++) {
		if (read_bones[i] < 0 || read_bones[i] >= bone_count) {
			return false;
		}
	}
	logic_divisor = (int64_t)divisor;
	s.skeleton = ObjectID(skeleton->get_instance_id());
	s.bones.resize(count);
	s.tips.resize(count);
	s.rest_bases.resize(count);
	s.angles.resize(count);
	s.velocity.resize(count);
	s.base.resize(count);
	s.planes.resize(count);
	for (int64_t i = 0; i < count; i++) {
		s.bones[i] = (int64_t)bones_in[i];
		s.tips[i] = tips_in[i];
		s.rest_bases[i] = rest_in[i];
		s.angles[i] = angles_in[i];
		s.velocity[i] = velocity_in[i];
		s.base[i] = base_in[i];
		const Dictionary plane = planes_in[i];
		Plane &out = s.planes[i];
		out.dict = plane;
		out.present = !plane.is_empty();
		out.position = out.present ? plane_vector(plane, n.position) : Vector3();
		out.normal = out.present ? plane_vector(plane, n.normal) : Vector3();
	}
	s.limits.resize(limits_in.size());
	for (int64_t i = 0; i < limits_in.size(); i++) {
		s.limits[i] = (double)limits_in[i];
	}
	s.mount = mount;
	s.mount_parents.clear();
	for (int32_t parent = skeleton->get_bone_parent(mount); parent >= 0; parent = skeleton->get_bone_parent(parent)) {
		s.mount_parents.push_back(parent);
		if (parent >= bone_count) {
			return false;
		}
	}
	s.gravity_amount = o->get(n.gravity_amount);
	s.inertia_amount = o->get(n.inertia_amount);
	s.retry = o->get(n.native_retry);
	s.sleeping = o->get(n.sleeping);
	s.quiet_frames = o->get(n.quiet_frames);
	s.ground_wait = o->get(n.ground_wait);
	s.last_anchor = o->get(n.last_anchor);
	s.previous_mount = o->get(n.previous_mount);
	const Array after_in = o->get(n.after_angles);
	s.after.resize(after_in.size());
	for (int64_t i = 0; i < after_in.size(); i++) {
		s.after[i] = after_in[i];
	}
	if (!s.after.empty() && (int64_t)s.after.size() != count) {
		return false;
	}
	s.contact_mount = o->get(n.contact_mount);
	s.previous_mount_basis = o->get(n.previous_mount_basis);
	s.previous_mount_velocity = o->get(n.previous_mount_velocity);
	s.mount_history = o->get(n.mount_history);
	s.max_penetration = o->get(n.max_penetration);
	s.projected_contacts = o->get(n.projected_contacts);
	s.contacts = o->get(n.contacts);
	s.solve_usec = o->get(n.solve_usec);
	s.cheap_floor = o->get(n.cheap_floor);
	s.contact_iterations = o->get(n.contact_iterations);
	s.floor_probe = o->get(n.floor_probe);
	s.floor_is_plane = o->get(n.floor_is_plane);
	s.contact_enabled = o->get(n.contact_enabled);
	if ((int64_t)pose.size() != bone_count) {
		pose.resize(bone_count);
		for (int32_t i = 0; i < bone_count; i++) {
			pose[i] = p_skeleton->get_bone_rest(i);
		}
	}
	owned = true;
	loads++;
	return true;
}

// Writes the mirrored state back into the springs object, in place in its own arrays.
void PonyTailMotionNative::flush_springs() {
	if (!owned) {
		return;
	}
	owned = false;
	Object *o = springs.ptr();
	if (o == nullptr) {
		return;
	}
	flushes++;
	const Names &n = names();
	const int64_t count = s.bones.size();
	Array angles_out = o->get(n.angles);
	Array velocity_out = o->get(n.angular_velocity);
	Array base_out = o->get(n.base_pose);
	Array planes_out = o->get(n.floor_planes);
	if (angles_out.size() != count) {
		angles_out.resize(count);
	}
	if (velocity_out.size() != count) {
		velocity_out.resize(count);
	}
	if (base_out.size() != count) {
		base_out.resize(count);
	}
	if (planes_out.size() != count) {
		planes_out.resize(count);
	}
	for (int64_t i = 0; i < count; i++) {
		angles_out.set(i, s.angles[i]);
		velocity_out.set(i, s.velocity[i]);
		base_out.set(i, s.base[i]);
		planes_out.set(i, s.planes[i].dict);
	}
	TypedArray<Vector3> after;
	for (const Vector3 &value : s.after) {
		after.push_back(value);
	}
	o->set(n.after_angles, after);
	o->set(n.sleeping, s.sleeping);
	o->set(n.quiet_frames, s.quiet_frames);
	o->set(n.ground_wait, s.ground_wait);
	o->set(n.last_anchor, s.last_anchor);
	o->set(n.previous_mount, s.previous_mount);
	o->set(n.contact_mount, s.contact_mount);
	o->set(n.previous_mount_basis, s.previous_mount_basis);
	o->set(n.previous_mount_velocity, s.previous_mount_velocity);
	o->set(n.mount_history, s.mount_history);
	o->set(n.max_penetration, s.max_penetration);
	o->set(n.projected_contacts, s.projected_contacts);
	o->set(n.contacts, s.contacts);
	o->set(n.solve_usec, s.solve_usec);
	o->set(n.cheap_floor, s.cheap_floor);
	o->set(n.contact_iterations, s.contact_iterations);
	o->set(n.floor_probe, s.floor_probe);
	o->set(n.floor_is_plane, s.floor_is_plane);
	o->set(n.contact_enabled, s.contact_enabled);
}

Dictionary PonyTailMotionNative::native_stats() const {
	Dictionary out;
	out["owned"] = owned;
	out["native_steps"] = native_steps;
	out["declined_steps"] = declined_steps;
	out["loads"] = loads;
	out["flushes"] = flushes;
	return out;
}

// hybrid_tail_motion.gd: `near` and `divisor` of _springs_tick / _skip_hair_pass.
void PonyTailMotionNative::tier(Node3D *p_pony, bool &r_near, int64_t &r_divisor) const {
	const Names &n = names();
	r_near = (int64_t)p_pony->get(n.sim_tier) == 1;
	if (r_near) {
		r_divisor = logic_divisor;
	} else {
		const int64_t hero = (int64_t)p_pony->get(n.hero_divisor);
		r_divisor = hero > 1 ? hero : 1;
	}
}

// `integrate` of _springs_tick: pony_locomotion.gd is_logic_tick() for NEAR (her tier is NEAR, so
// logic_divisor() is LOGIC_DIVISOR), her HERO beat otherwise.
bool PonyTailMotionNative::integrate_now(Node3D *p_pony, bool p_near, int64_t p_divisor) const {
	const Names &n = names();
	if (p_near) {
		const int64_t frames = (int64_t)Engine::get_singleton()->get_physics_frames();
		return ((frames + (int64_t)p_pony->get(n.sim_phase)) % logic_divisor) == 0;
	}
	return p_divisor <= 1 || (((int64_t)p_pony->get(n.tick) + (int64_t)p_pony->get(n.sim_phase)) % p_divisor) == 0;
}

// hybrid_tail_motion.gd _process_modification_with_delta() without the profile branch (the script
// shell keeps that). False, with nothing changed, when this pony's springs are not mirrored here.
bool PonyTailMotionNative::native_step(double p_delta) {
	Node3D *p = pony_node();
	if (springs.is_null() || p == nullptr || !p->is_inside_tree()) {
		declined_steps++;
		return false;
	}
	Skeleton3D *sk = get_skeleton();
	if (sk == nullptr) {
		declined_steps++;
		return false;
	}
	if (!owned && !load_springs(p, sk)) {
		declined_steps++;
		return false;
	}
	CharacterBody3D *body = Object::cast_to<CharacterBody3D>(p);
	native_steps++;
	const bool dirty = pose_dirty;
	pose_dirty = false;
	if (settled && settled_writes > 0 && !dirty && skip_hair_pass(sk, p, body, p_delta)) {
		return true;
	}
	springs_tick(sk, p, body, p_delta);
	apply_aside(sk, p, p_delta);
	return true;
}

// hybrid_tail_motion.gd _skip_hair_pass()
bool PonyTailMotionNative::skip_hair_pass(Skeleton3D *p_sk, Node3D *p_pony, CharacterBody3D *p_body, double p_delta) {
	const Names &n = names();
	if (std::abs(aside) >= .0001 || std::abs(aside_goal) >= .0001) {
		return false;
	}
	const int32_t children = p_sk->get_child_count();
	if (children != solo_children) {
		solo_children = children;
		solo = true;
		for (int32_t i = 0; i < children; i++) {
			Node *child = p_sk->get_child(i);
			if (child != this && Object::cast_to<SkeletonModifier3D>(child) != nullptr) {
				solo = false;
				break;
			}
		}
	}
	if (!solo) {
		return false;
	}
	const Variant touch_value = p_pony->get(n.touch_body);
	Object *touch = touch_value.get_type() == Variant::OBJECT ? (Object *)touch_value : nullptr;
	if (touch != nullptr && (bool)touch->get(n.active)) {
		return false;
	}
	bool near = false;
	int64_t divisor = 1;
	tier(p_pony, near, divisor);
	skipped_delta += p_delta;
	const bool integrate = integrate_now(p_pony, near, divisor);
	if (!integrate) {
		return true;
	}
	if (settle_holds(p_sk, p_body)) {
		skipped_delta = 0.0;
		return true;
	}
	skipped_delta -= p_delta; // _springs_tick adds it again
	wake_now = true; // and wakes without testing (and counting the recheck) twice
	return false;
}

// hybrid_tail_motion.gd _springs_tick()
bool PonyTailMotionNative::springs_tick(Skeleton3D *p_sk, Node3D *p_pony, CharacterBody3D *p_body, double p_delta) {
	const Names &n = names();
	bool near = false;
	int64_t divisor = 1;
	tier(p_pony, near, divisor);
	skipped_delta += p_delta;
	const bool integrate = integrate_now(p_pony, near, divisor);
	if (settled) {
		if (integrate) {
			const bool wake = wake_now;
			wake_now = false;
			if (!wake && settle_holds(p_sk, p_body)) {
				skipped_delta = 0.0;
				write_settled(p_sk);
				return false;
			}
			settled = false;
			quiet = recheck <= 0.0 ? SETTLE_SECONDS : 0.0;
		} else {
			write_settled(p_sk);
			return false;
		}
	}
	if (!integrate && history) {
		steps += 1;
		write_between(p_sk, double(steps + 1) / double(divisor));
		return false;
	}
	s.cheap_floor = true; // dev 2026-09-17: jigglebones + floor for every tier, no skin scan
	s.contact_iterations = 4;
	for (int64_t i = 0; i < read_bones.size(); i++) {
		const int32_t bone = read_bones[i];
		pose[bone] = p_sk->get_bone_pose(bone);
	}
	double stepped = 0.0;
	const bool paused = p_pony->get(n.motion_paused);
	if (!paused && integrate) {
		const double step = skipped_delta;
		skipped_delta = 0.0;
		stepped = step;
		const Vector3 velocity = p_body->get_velocity();
		const Vector3 acceleration = history ? (velocity - previous_velocity) / (real_t)pony::maxf(step, .001) : Vector3();
		previous_velocity = velocity;
		history = true;
		springs_update(step, acceleration);
	}
	const bool plane = near && plane_floor.is_valid();
	s.floor_probe = plane ? plane_floor : ray_floor;
	s.floor_is_plane = plane;
	s.contact_enabled = !paused && (integrate || !near);
	springs_apply();
	const int64_t count = s.bones.size();
	const bool fresh = to.size() != count;
	if (fresh) {
		to.resize(count);
		to_rotation.resize(count);
	}
	// The previous target becomes the start; reuse the two buffers instead of copying.
	const Array previous = from_rotation;
	from_rotation = to_rotation;
	to_rotation = previous;
	if (to_rotation.size() != count) {
		to_rotation.resize(count);
	}
	for (int64_t k = 0; k < count; k++) {
		const Transform3D target = pose[s.bones[k]];
		to[k] = target;
		to_rotation[k] = target.basis.get_rotation_quaternion();
	}
	if (fresh) {
		from_rotation = to_rotation.duplicate();
	}
	steps = 0;
	write_between(p_sk, 1.0 / double(divisor));
	if (stepped > 0.0) {
		watch_settle(p_sk, p_body, stepped);
	}
	return true;
}

// hybrid_tail_motion.gd _watch_settle()
void PonyTailMotionNative::watch_settle(Skeleton3D *p_sk, CharacterBody3D *p_body, double p_step) {
	const Transform3D mount = s.mount >= 0 ? p_sk->get_global_transform() * p_sk->get_bone_global_pose(s.mount) : Transform3D();
	const size_t count = s.angles.size();
	double turn = SETTLE_TURN * .1 * (double)mount.basis.get_column(0).length();
	turn *= turn;
	bool quiet_now = (size_t)last_angles.size() == count && (double)p_body->get_velocity().length_squared() < QUIET_SPEED * QUIET_SPEED &&
			(double)mount.origin.distance_squared_to(last_mount.origin) < SETTLE_MOVE * SETTLE_MOVE * .01 &&
			(double)mount.basis.get_column(0).distance_squared_to(last_mount.basis.get_column(0)) < turn &&
			(double)mount.basis.get_column(2).distance_squared_to(last_mount.basis.get_column(2)) < turn;
	if (quiet_now) {
		for (size_t k = 0; k < count; k++) {
			if ((double)s.velocity[k].length_squared() > QUIET_SPIN * QUIET_SPIN ||
					(double)s.angles[k].distance_squared_to(last_angles[k]) > QUIET_STEP * QUIET_STEP) {
				quiet_now = false;
				break;
			}
		}
	}
	last_mount = mount;
	PackedVector3Array angles_now;
	angles_now.resize(count);
	for (size_t k = 0; k < count; k++) {
		angles_now.set(k, s.angles[k]);
	}
	last_angles = angles_now;
	quiet = quiet_now ? quiet + p_step : 0.0;
	if (quiet < SETTLE_SECONDS || to.size() != (int64_t)s.bones.size()) {
		return;
	}
	// Settle on the pose just written in full (t = 1 of the next in-between writes is _to).
	settled = true;
	settled_writes = 0;
	recheck = SETTLE_RECHECK;
	settle_mount = mount;
	settle_reach = mount.basis.get_column(0).length();
	for (Vector3 &spin : s.velocity) {
		spin = Vector3();
	}
}

// hybrid_tail_motion.gd _settle_holds()
bool PonyTailMotionNative::settle_holds(Skeleton3D *p_sk, CharacterBody3D *p_body) {
	recheck -= skipped_delta;
	if (recheck <= 0.0 || s.mount < 0) {
		return false;
	}
	const Vector3 velocity = p_body->get_velocity();
	if ((double)velocity.length_squared() > QUIET_SPEED * QUIET_SPEED) {
		return false;
	}
	for (const Vector3 &spin : s.velocity) {
		if (spin != Vector3()) {
			return false; // a swish (pony_idle_twitches) or kick
		}
	}
	const Transform3D mount = p_sk->get_global_transform() * p_sk->get_bone_global_pose(s.mount);
	if ((double)mount.origin.distance_squared_to(settle_mount.origin) > SETTLE_MOVE * SETTLE_MOVE) {
		return false;
	}
	// Basis columns scaled like the rig: a column moves `reach * angle` when the rump turns.
	double limit = SETTLE_TURN * settle_reach;
	limit *= limit;
	if ((double)mount.basis.get_column(0).distance_squared_to(settle_mount.basis.get_column(0)) > limit ||
			(double)mount.basis.get_column(1).distance_squared_to(settle_mount.basis.get_column(1)) > limit ||
			(double)mount.basis.get_column(2).distance_squared_to(settle_mount.basis.get_column(2)) > limit) {
		return false;
	}
	s.previous_mount_basis = mount.basis.orthonormalized();
	s.previous_mount_velocity = Vector3();
	previous_velocity = velocity;
	return true;
}

void PonyTailMotionNative::write_settled(Skeleton3D *p_sk) {
	settled_writes += 1;
	steps = 0;
	write_between(p_sk, 1.0);
}

// hybrid_tail_motion.gd _apply_aside()
void PonyTailMotionNative::apply_aside(Skeleton3D *p_sk, Node3D *p_pony, double p_delta) {
	const double limit = !s.limits.empty() ? s.limits[0] * .9 : .5;
	aside = move_toward(aside, pony::clamp_double(aside_goal, -limit, limit), p_delta * ASIDE_SPEED);
	if (std::abs(aside) < .0001 || s.bones.empty()) {
		return;
	}
	const int32_t bone = s.bones[0];
	const int32_t parent = p_sk->get_bone_parent(bone);
	const Quaternion parent_rotation = parent >= 0 ? p_sk->get_bone_global_pose(parent).basis.get_rotation_quaternion() : Quaternion();
	const Vector3 axis = (p_sk->get_global_basis().orthonormalized().inverse().xform(p_pony->get_global_basis().get_column(1).normalized())).normalized();
	const Quaternion global = parent_rotation * p_sk->get_bone_pose_rotation(bone);
	p_sk->set_bone_pose_rotation(bone, parent_rotation.inverse() * pony::axis_angle(axis, aside) * global);
}

// hybrid_tail_motion.gd _write_between()
void PonyTailMotionNative::write_between(Skeleton3D *p_sk, double p_t) {
	const int64_t count = s.bones.size();
	if (p_t >= 1.0) {
		for (int64_t k = 0; k < count; k++) {
			p_sk->set_bone_pose(s.bones[k], to[k]);
		}
		return;
	}
	for (int64_t k = 0; k < count; k++) {
		const Transform3D target = to[k];
		p_sk->set_bone_pose_position(s.bones[k], target.origin);
		p_sk->set_bone_pose_rotation(s.bones[k], pony::slerp(from_rotation[k], to_rotation[k], p_t));
	}
}

// hybrid_tail_physics.gd reset() with pony_tail.gd reset().
void PonyTailMotionNative::springs_reset() {
	for (Vector3 &value : s.angles) {
		value = Vector3();
	}
	for (Vector3 &value : s.velocity) {
		value = Vector3();
	}
	for (Plane &plane : s.planes) {
		plane = Plane();
	}
	s.previous_mount_velocity = Vector3();
	s.mount_history = false;
	s.max_penetration = 0.0;
	s.contacts = 0;
	s.sleeping = false;
	s.quiet_frames = 0;
	s.after.clear();
	s.ground_wait = 0.0;
}

// pony_tail.gd _frames() (tail.cpp tail_frames)
void PonyTailMotionNative::springs_frames(const Transform3D &p_mount) {
	const size_t count = s.tips.size();
	s.frame.resize(count);
	Transform3D parent = p_mount;
	for (size_t i = 0; i < count; i++) {
		Transform3D local = s.base[i];
		const Basis &rest = s.rest_bases[i];
		local.basis = rest * angle_basis(s.angles[i]) * rest.inverse() * local.basis;
		parent = parent * local;
		s.frame[i] = parent;
	}
}

// hybrid_tail_physics.gd update() and _update_native() (tail.cpp tail_update).
void PonyTailMotionNative::springs_update(double p_delta, const Vector3 &p_world_acceleration) {
	Skeleton3D *skeleton = springs_skeleton();
	s.ground_wait -= pony::minf(p_delta, .25);
	if (s.sleeping) {
		const Transform3D mount = skeleton->get_global_transform() * skeleton->get_bone_global_pose(s.mount);
		if (!mount.is_equal_approx(s.previous_mount) || (double)p_world_acceleration.length_squared() > .0025) {
			s.sleeping = false;
			s.quiet_frames = 0;
		} else {
			return;
		}
	}
	if (s.bones.empty() || p_delta <= 0.0 || !std::isfinite(p_delta)) {
		return;
	}
	const Transform3D mount_frame = skeleton->get_global_transform() * skeleton->get_bone_global_pose(s.mount);
	const size_t count = s.tips.size();
	const double elapsed = pony::minf(p_delta, MAX_DELTA);
	const Basis mount_basis = mount_frame.basis.orthonormalized();
	Vector3 mount_acceleration;
	Vector3 previous_mount_velocity = s.previous_mount_velocity;
	if (s.mount_history && p_delta <= MAX_DELTA) {
		Quaternion change = (mount_basis * s.previous_mount_basis.inverse()).get_rotation_quaternion().normalized();
		if (change.w < 0.0) {
			change = -change;
		}
		Vector3 mount_velocity = rotation_vector(change) / (real_t)p_delta;
		mount_velocity = mount_velocity.limit_length(6.0);
		mount_acceleration = ((mount_velocity - previous_mount_velocity) / (real_t)p_delta).limit_length(25.0);
		previous_mount_velocity = mount_velocity;
	} else {
		previous_mount_velocity = Vector3();
	}
	const Vector3 acceleration = p_world_acceleration.is_finite() ? p_world_acceleration.limit_length(MAX_ROOT_ACCELERATION) : Vector3();
	const int64_t step_count = std::max<int64_t>(1, (int64_t)std::ceil(elapsed / MAX_STEP));
	const double dt = elapsed / step_count;
	const Vector3 zero_force;
	for (int64_t step = 0; step < step_count; step++) {
		springs_frames(mount_frame);
		for (size_t i = 0; i < count; i++) {
			const double progress = (double)i / (double)(count - 1);
			const Basis frame = s.frame[i].basis.orthonormalized();
			const Basis inverse_frame = frame.inverse();
			const Vector3 direction = s.tips[i].normalized();
			const Vector3 local_force = inverse_frame.xform(GRAVITY * (real_t)s.gravity_amount - acceleration * (real_t)s.inertia_amount);
			Vector3 force = direction.cross(local_force) * (real_t)pony::lerpf(0.35, 0.8, progress);
			force -= inverse_frame.xform(mount_acceleration) * (real_t)pony::lerpf(0.18, 0.35, progress);
			force += zero_force;
			force -= direction * force.dot(direction);
			const double stiffness = pony::lerpf(42.0, 23.0, progress);
			const double damping = pony::lerpf(10.0, 7.0, progress);
			const Vector3 angular_acceleration = (force - s.angles[i] * (real_t)stiffness - s.velocity[i] * (real_t)damping).limit_length(MAX_ANGULAR_ACCELERATION);
			s.velocity[i] = (s.velocity[i] + angular_acceleration * (real_t)dt).limit_length(MAX_ANGULAR_SPEED);
			s.angles[i] += s.velocity[i] * (real_t)dt;
			const double limit = s.limits[std::min(i, s.limits.size() - 1)];
			if (s.angles[i].length() > limit) {
				s.angles[i] = s.angles[i].limit_length(limit);
				const Vector3 outward = s.angles[i].normalized();
				s.velocity[i] -= outward * (real_t)pony::maxf(0.0, s.velocity[i].dot(outward));
			}
		}
	}
	s.previous_mount_basis = mount_basis;
	s.previous_mount_velocity = previous_mount_velocity;
	s.mount_history = true;
}

// hybrid_tail_physics.gd apply_pose() on the motion's pose buffer.
void PonyTailMotionNative::springs_apply() {
	if (s.bones.empty()) {
		return;
	}
	Skeleton3D *skeleton = springs_skeleton();
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	const size_t count = s.bones.size();
	for (size_t i = 0; i < count; i++) {
		// Always start from the standing tail's authored local offsets and shape.
		s.base[i] = skeleton->get_bone_rest(s.bones[i]);
	}
	// pony_tail.gd _pose_global(_mount, pose)
	Transform3D global = pose[s.mount];
	for (const int32_t parent : s.mount_parents) {
		global = pose[parent] * global;
	}
	const Transform3D mount = skeleton->get_global_transform() * global;
	s.contact_mount = mount;
	const Vector3 anchor = mount.xform(s.base[0].origin);
	if (s.last_anchor.is_finite() && (double)anchor.distance_to(s.last_anchor) > 1.0) {
		springs_reset();
		s.ground_wait = 0.0;
	}
	s.last_anchor = anchor;
	springs_contacts(mount, anchor);
	if (!s.after.empty() && s.contact_enabled && mount.is_equal_approx(s.previous_mount)) {
		double movement = 0.0;
		for (size_t i = 0; i < s.angles.size(); i++) {
			movement = pony::maxf(movement, s.angles[i].distance_to(s.after[i]));
		}
		// Contact settling below 0.06 degrees per tick can sleep instead of perpetually
		// recomputing a visually stationary hair mesh against the same floor.
		s.quiet_frames = movement < .001 ? s.quiet_frames + 1 : 0;
		if (s.quiet_frames >= 30) {
			s.sleeping = true;
			for (Vector3 &spin : s.velocity) {
				spin = Vector3();
			}
		}
	} else {
		s.quiet_frames = 0;
	}
	s.previous_mount = mount;
	s.after = s.angles;
	s.solve_usec = (int64_t)(Time::get_singleton()->get_ticks_usec() - started);
}

// hybrid_tail_physics.gd: the wake test of the floor probes.
void PonyTailMotionNative::springs_wake_test(size_t p_index, const Plane &p_plane) {
	const Plane &old = s.planes[p_index];
	if (s.sleeping && (p_plane.present != old.present ||
							  (p_plane.present && (std::abs((double)(p_plane.position - old.position).dot(p_plane.normal)) > .001 ||
														  (double)p_plane.normal.distance_to(old.normal) > .001)))) {
		s.sleeping = false;
		s.quiet_frames = 0;
	}
	s.planes[p_index] = p_plane;
}

// hybrid_tail_physics.gd _floor_at()
PonyTailMotionNative::Plane PonyTailMotionNative::springs_floor_at(const Vector3 &p_tip, double p_anchor_y) {
	const Names &n = names();
	Plane out;
	out.dict = s.floor_probe.call(Vector3(p_tip.x, pony::maxf(p_anchor_y, p_tip.y), p_tip.z));
	out.present = !out.dict.is_empty();
	if (out.present) {
		out.position = plane_vector(out.dict, n.position);
		out.normal = plane_vector(out.dict, n.normal);
	}
	if (!out.present || (double)out.position.y <= (double)p_tip.y + LEDGE_LIFT || s.floor_probe.get_method() != n.probe) {
		return out;
	}
	Object *body = s.floor_probe.get_object();
	const Variant profile = body != nullptr ? body->get(n.profile) : Variant();
	if (profile.get_type() == Variant::NIL) {
		return out;
	}
	// _probe(point, rise) casts from point + up * (hip * 0.9 + rise): start 3 cm over the tip.
	const double hip = ((Object *)profile)->get(n.hip_height);
	Plane below;
	below.dict = s.floor_probe.call(p_tip, .03 - hip * .9);
	below.present = !below.dict.is_empty();
	if (below.present) {
		below.position = plane_vector(below.dict, n.position);
		below.normal = plane_vector(below.dict, n.normal);
	}
	return below.present && (double)below.position.y <= (double)p_tip.y + .03 ? below : out;
}

// hybrid_tail_physics.gd _contacts_native() with tail.cpp tail_tip_points() and tail_project().
void PonyTailMotionNative::springs_contacts(const Transform3D &p_mount, const Vector3 &p_anchor) {
	const Names &n = names();
	const size_t count = s.tips.size();
	if (s.ground_wait <= 0.0 && s.floor_probe.is_valid()) {
		s.ground_wait = s.sleeping ? .1 : .05;
		if (s.floor_is_plane) {
			// _share_floor_plane(): one plane for every joint.
			Plane plane;
			plane.dict = s.floor_probe.call(p_anchor);
			plane.present = !plane.dict.is_empty();
			if (plane.present) {
				plane.position = plane_vector(plane.dict, n.position);
				plane.normal = plane_vector(plane.dict, n.normal);
			}
			for (size_t i = 0; i < count; i++) {
				springs_wake_test(i, plane);
			}
		} else {
			springs_frames(p_mount);
			std::vector<Vector3> tips(count);
			for (size_t i = 0; i < count; i++) {
				tips[i] = s.frame[i].xform(s.tips[i]);
			}
			for (size_t i = 0; i < count; i++) {
				springs_wake_test(i, springs_floor_at(tips[i], p_anchor.y));
			}
		}
	}
	Object *o = springs.ptr();
	const bool project_now = (bool)o->get(n.collision_enabled) && s.contact_enabled && !s.sleeping;
	// tail.cpp tail_project()
	auto deepest = [&]() {
		Contact best;
		for (size_t i = 0; i < count; i++) {
			const Plane &plane = s.planes[i];
			if (!plane.present) {
				continue;
			}
			for (const double t : { .5, 1. }) {
				const Vector3 offset = s.tips[i] * (real_t)t;
				const double depth = (double)plane.normal.dot(plane.position - s.frame[i].xform(offset)) + TAIL_RADIUS;
				if (depth > (best.found ? best.depth : 0.0)) {
					best.found = true;
					best.depth = depth;
					best.bone = (int)i;
					best.offset = offset;
					best.normal = plane.normal;
				}
			}
		}
		return best;
	};
	s.gradients.resize(count);
	auto project = [&](const Contact &contact) {
		double denominator = 0.0;
		for (size_t joint = 0; joint < count; joint++) {
			Vector3 lever;
			if (contact.bone >= (int)joint) {
				lever += (s.frame[contact.bone].xform(contact.offset) - s.frame[joint].origin) * (real_t)1.0;
			}
			Vector3 gradient = lever.cross(contact.normal);
			const Vector3 axis = s.frame[joint].basis.xform(s.tips[joint]).normalized();
			gradient -= axis * gradient.dot(axis);
			s.gradients[joint] = gradient;
			denominator += gradient.length_squared();
		}
		if (denominator < .0000001) {
			return;
		}
		for (size_t joint = 0; joint < count; joint++) {
			const Vector3 rotation = (s.gradients[joint] * (real_t)(contact.depth * .85 / denominator)).limit_length(MAX_CONTACT_ROTATION);
			if (rotation.length_squared() < .00000001) {
				continue;
			}
			const Basis &parent = joint == 0 ? p_mount.basis : s.frame[joint - 1].basis;
			const Basis desired = parent.inverse() * angle_basis(rotation) * s.frame[joint].basis;
			Quaternion relative = (s.rest_bases[joint].inverse() * desired).orthonormalized().get_rotation_quaternion();
			if (relative.w < 0.0) {
				relative = -relative;
			}
			Vector3 vector = rotation_vector(relative);
			const Vector3 direction = s.tips[joint].normalized();
			vector -= direction * vector.dot(direction);
			const Vector3 before = s.angles[joint];
			s.angles[joint] = vector.limit_length(s.limits[joint]);
			const Vector3 correction = s.angles[joint] - before;
			if (correction.length_squared() > .0000001) {
				const Vector3 normal = correction.normalized();
				s.velocity[joint] -= normal * (real_t)pony::minf(0.0, s.velocity[joint].dot(normal));
			}
		}
	};
	int64_t projected = 0;
	double remaining = -1.0;
	springs_frames(p_mount);
	if (project_now) {
		for (int64_t iteration = 0; iteration < s.contact_iterations; iteration++) {
			const Contact contact = deepest();
			if (!contact.found || contact.depth < .0005) {
				break;
			}
			project(contact);
			if (s.retry) {
				// background_tail_physics.gd _project(): one more pass while overlap remains.
				springs_frames(p_mount);
				const Contact again = deepest();
				if (again.found && again.depth > .002) {
					project(again);
				}
			}
			springs_frames(p_mount);
			projected++;
		}
		const Contact left = deepest();
		if (left.found) {
			remaining = left.depth;
		}
	}
	s.projected_contacts = projected;
	s.max_penetration = project_now ? (remaining < 0.0 ? 0.0 : pony::maxf(0.0, remaining - SKIN_MARGIN)) : 0.0;
	for (size_t i = 0; i < count; i++) {
		Transform3D local = s.base[i];
		local.basis = s.rest_bases[i] * angle_basis(s.angles[i]) * s.rest_bases[i].inverse() * local.basis;
		pose[s.bones[i]] = local;
	}
}

#define TAILN_PROPERTY(m_type, m_name, m_suffix, m_hint, m_hint_string, m_class)                                                     \
	ClassDB::bind_method(D_METHOD("tailn_set_" #m_suffix, "value"), &PonyTailMotionNative::tailn_set_##m_suffix);                     \
	ClassDB::bind_method(D_METHOD("tailn_get_" #m_suffix), &PonyTailMotionNative::tailn_get_##m_suffix);                              \
	ADD_PROPERTY(PropertyInfo(m_type, m_name, m_hint, m_hint_string, PROPERTY_USAGE_NONE, m_class), "tailn_set_" #m_suffix, "tailn_get_" #m_suffix);

void PonyTailMotionNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_step", "delta"), &PonyTailMotionNative::native_step);
	ClassDB::bind_method(D_METHOD("native_flush"), &PonyTailMotionNative::native_flush);
	ClassDB::bind_method(D_METHOD("native_owns"), &PonyTailMotionNative::native_owns);
	ClassDB::bind_method(D_METHOD("native_stats"), &PonyTailMotionNative::native_stats);
	TAILN_PROPERTY(Variant::OBJECT, "pony", pony, PROPERTY_HINT_NODE_TYPE, "Node3D", "Node3D")
	TAILN_PROPERTY(Variant::OBJECT, "springs", springs, PROPERTY_HINT_NONE, "", "RefCounted")
	TAILN_PROPERTY(Variant::VECTOR3, "_previous_velocity", previous_velocity, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::BOOL, "_history", history, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::FLOAT, "_skipped_delta", skipped_delta, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::INT, "_steps", steps, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::FLOAT, "aside_goal", aside_goal, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::FLOAT, "_aside", aside, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::BOOL, "_settled", settled, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::FLOAT, "_quiet", quiet, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::FLOAT, "_recheck", recheck, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::TRANSFORM3D, "_settle_mount", settle_mount, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::FLOAT, "_settle_reach", settle_reach, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::TRANSFORM3D, "_last_mount", last_mount, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::PACKED_VECTOR3_ARRAY, "_last_angles", last_angles, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::INT, "_settled_writes", settled_writes, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::BOOL, "_wake_now", wake_now, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::BOOL, "_pose_dirty", pose_dirty, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::BOOL, "_solo", solo, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::INT, "_solo_children", solo_children, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::PACKED_INT32_ARRAY, "_read_bones", read_bones, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::ARRAY, "_to", to, PROPERTY_HINT_ARRAY_TYPE, "Transform3D", "")
	TAILN_PROPERTY(Variant::ARRAY, "_from_rotation", from_rotation, PROPERTY_HINT_ARRAY_TYPE, "Quaternion", "")
	TAILN_PROPERTY(Variant::ARRAY, "_to_rotation", to_rotation, PROPERTY_HINT_ARRAY_TYPE, "Quaternion", "")
	TAILN_PROPERTY(Variant::CALLABLE, "_ray_floor", ray_floor, PROPERTY_HINT_NONE, "", "")
	TAILN_PROPERTY(Variant::CALLABLE, "_plane_floor", plane_floor, PROPERTY_HINT_NONE, "", "")
}

#undef TAILN_PROPERTY
