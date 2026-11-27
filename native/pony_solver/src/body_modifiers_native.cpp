// Native bases of three close-pony body modifiers; see body_modifiers_native.h.
#include "body_modifiers_native.h"

#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>

using namespace godot;

namespace {

// GDScript's helpers on doubles (core/math/math_funcs.h, core/typedefs.h).
inline double gd_move_toward(double from, double to, double delta) {
	const double d = to - from;
	return std::abs(d) <= delta ? to : from + (d == 0 ? 0.0f : (d < 0 ? -1.0f : 1.0f)) * delta;
}
inline double gd_smoothstep01(double x) {
	const double s = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);
	return s * s * (3.0 - 2.0 * s);
}
inline double gd_maxf(double a, double b) {
	return a > b ? a : b;
}
inline bool gd_equal_approx(double a, double b) {
	if (a == b) {
		return true;
	}
	double tolerance = 0.00001 * std::abs(a);
	if (tolerance < 0.00001) {
		tolerance = 0.00001;
	}
	return std::abs(a - b) < tolerance;
}

double as_double(const Variant &v, double fallback = 0.0) {
	if (v.get_type() == Variant::FLOAT) {
		return double(v);
	}
	if (v.get_type() == Variant::INT) {
		return double(int64_t(v));
	}
	return fallback;
}
Object *as_object(const Variant &v) {
	return v.get_type() == Variant::OBJECT ? (Object *)v : nullptr;
}

struct Names {
	StringName hidden_parked = "_hidden_parked", secondary = "secondary", joint_limits = "joint_limits", pivot = "pivot";
	StringName native_constrain = "_native_constrain", native_solver = "_native";
	StringName offset = "offset", roll = "roll", breath = "breath", spine = "_spine", spine_frames = "_spine_frames";
	StringName neck = "_neck", parent_frames = "_parent_frames", logic_alpha = "logic_alpha";
	StringName clip_head_from = "clip_head_from", clip_head_to = "clip_head_to", clip_blend = "_clip_blend";
	StringName posture = "posture", active = "active", sleep_blend = "_sleep_blend";
};
const Names &names() {
	static Names n;
	return n;
}

constexpr int64_t MAX_LEGS = 8;

Node *node_of(ObjectID id) {
	return id.is_valid() ? Object::cast_to<Node>(ObjectDB::get_instance(uint64_t(id))) : nullptr;
}

} // namespace

// ---------------------------------------------------------------------------------------------
// pony_idle_body.gd

void PonyIdleBodyNative::set_pony(Node *p_pony) {
	pony = p_pony != nullptr ? ObjectID(p_pony->get_instance_id()) : ObjectID();
}
Node *PonyIdleBodyNative::get_pony() const {
	return node_of(pony);
}

// _process_modification_with_delta() and _apply() with HIDDEN_SKIP on. Declines (nothing changed)
// when it would reach a joint limit that is not on the native solver (pony_joint_limits.gd
// constrain() would run its GDScript form).
bool PonyIdleBodyNative::native_step(double p_delta) {
	const Names &n = names();
	Node *p = get_pony();
	if (p != nullptr && p->get(n.hidden_parked) == Variant(true)) {
		return true;
	}
	const int64_t frame = int64_t(Engine::get_singleton()->get_physics_frames());
	const double new_fade = gd_move_toward(fade, wanted ? 1.0 : 0.0, p_delta / 0.6);
	if (new_fade <= 0.0 || hips < 0 || p == nullptr) {
		last_pass_frame = frame;
		fade = new_fade;
		return true;
	}
	Skeleton3D *skeleton = get_skeleton();
	Object *secondary = as_object(p->get(n.secondary));
	Object *limits = as_object(p->get(n.joint_limits));
	if (skeleton == nullptr || secondary == nullptr || limits == nullptr) {
		last_pass_frame = frame;
		fade = new_fade;
		return true;
	}
	const PonySolverNative *solver = nullptr;
	if (bool(limits->get(n.native_constrain))) {
		solver = Object::cast_to<PonySolverNative>(as_object(limits->get(n.native_solver)));
	}
	const int64_t leg_count = legs.size();
	if (solver == nullptr || leg_count > MAX_LEGS || leg_parents.size() < leg_count) {
		return false; // the script's own pass (its GDScript limits, or leg roots bind() never gives)
	}
	last_pass_frame = frame;
	fade = new_fade;
	if (!frame_ready) {
		Node3D *pivot = Object::cast_to<Node3D>(as_object(p->get(n.pivot)));
		if (pivot == nullptr || !pivot->is_inside_tree()) {
			return true;
		}
		// Model frame (the pivot: forward -Z, up +Y) to skeleton space, rotation only.
		model_to_skeleton = (pivot->get_global_basis().orthonormalized().inverse() * skeleton->get_global_basis().orthonormalized()).inverse();
		frame_ready = true;
	}
	const double ease = 1.0 - pony::engine_exp(-p_delta / 0.08);
	const Vector3 offset = secondary->get(n.offset);
	roll = pony::lerpf(roll, as_double(secondary->get(n.roll)), ease);
	pitch = pony::lerpf(pitch, double(offset.z) * 0.8, ease);
	breath = pony::lerpf(breath, as_double(secondary->get(n.breath)), ease);
	applied_roll = gd_maxf(applied_roll, std::abs(roll * fade));
	// The legs' orientation as the clip (and any earlier modifier) left it.
	Basis leg_globals[MAX_LEGS];
	for (int64_t i = 0; i < leg_count; i++) {
		leg_globals[i] = skeleton->get_bone_global_pose(int32_t(int64_t(legs[i]))).basis;
	}
	// Weight: roll and tip the whole body about the hips.
	const Basis turn = model_to_skeleton * pony::basis_from_euler(Vector3(pitch, 0.0, roll) * fade) * model_to_skeleton.inverse();
	const Basis parent = hips_parent >= 0 ? skeleton->get_bone_global_pose(int32_t(hips_parent)).basis.orthonormalized() : Basis();
	Transform3D hips_pose = skeleton->get_bone_pose(int32_t(hips));
	hips_pose.basis = parent.inverse() * turn * parent * hips_pose.basis;
	skeleton->set_bone_pose(int32_t(hips), hips_pose);
	// Breath along the back, as the solver tier's secondary applies it.
	if (std::abs(breath) > 0.0005) {
		const Array spine = secondary->get(n.spine);
		if (spine.size() == 2) {
			const Array frames = secondary->get(n.spine_frames);
			for (int64_t i = 0; i < 2; i++) {
				const int32_t bone = int32_t(int64_t(spine[i]));
				const Basis frame_basis = frames[i];
				const double arch = breath_arch * breath * fade * (i == 0 ? 1.0 : -1.0);
				Transform3D pose = skeleton->get_bone_pose(bone);
				pose.basis = solver->constrain_basis(bone, frame_basis.inverse() * pony::basis_axis_angle(Vector3(1, 0, 0), arch) * frame_basis * pose.basis);
				skeleton->set_bone_pose(bone, pose);
			}
		}
	}
	// The legs hang as before: each root turns back under its moved parent.
	for (int64_t i = 0; i < leg_count; i++) {
		const int32_t bone = int32_t(int64_t(legs[i]));
		const Basis moved = skeleton->get_bone_global_pose(int32_t(int64_t(leg_parents[i]))).basis;
		Transform3D pose = skeleton->get_bone_pose(bone);
		pose.basis = solver->constrain_basis(bone, moved.inverse() * leg_globals[i]);
		skeleton->set_bone_pose(bone, pose);
	}
	return true;
}

void PonyIdleBodyNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_step", "delta"), &PonyIdleBodyNative::native_step);
	ClassDB::bind_method(D_METHOD("set_pony", "value"), &PonyIdleBodyNative::set_pony);
	ClassDB::bind_method(D_METHOD("get_pony"), &PonyIdleBodyNative::get_pony);
	ClassDB::bind_method(D_METHOD("set_wanted", "value"), &PonyIdleBodyNative::set_wanted);
	ClassDB::bind_method(D_METHOD("get_wanted"), &PonyIdleBodyNative::get_wanted);
	ClassDB::bind_method(D_METHOD("set_fade", "value"), &PonyIdleBodyNative::set_fade);
	ClassDB::bind_method(D_METHOD("get_fade"), &PonyIdleBodyNative::get_fade);
	ClassDB::bind_method(D_METHOD("set_hips", "value"), &PonyIdleBodyNative::set_hips);
	ClassDB::bind_method(D_METHOD("get_hips"), &PonyIdleBodyNative::get_hips);
	ClassDB::bind_method(D_METHOD("set_hips_parent", "value"), &PonyIdleBodyNative::set_hips_parent);
	ClassDB::bind_method(D_METHOD("get_hips_parent"), &PonyIdleBodyNative::get_hips_parent);
	ClassDB::bind_method(D_METHOD("set_legs", "value"), &PonyIdleBodyNative::set_legs);
	ClassDB::bind_method(D_METHOD("get_legs"), &PonyIdleBodyNative::get_legs);
	ClassDB::bind_method(D_METHOD("set_leg_parents", "value"), &PonyIdleBodyNative::set_leg_parents);
	ClassDB::bind_method(D_METHOD("get_leg_parents"), &PonyIdleBodyNative::get_leg_parents);
	ClassDB::bind_method(D_METHOD("set_model_to_skeleton", "value"), &PonyIdleBodyNative::set_model_to_skeleton);
	ClassDB::bind_method(D_METHOD("get_model_to_skeleton"), &PonyIdleBodyNative::get_model_to_skeleton);
	ClassDB::bind_method(D_METHOD("set_frame_ready", "value"), &PonyIdleBodyNative::set_frame_ready);
	ClassDB::bind_method(D_METHOD("get_frame_ready"), &PonyIdleBodyNative::get_frame_ready);
	ClassDB::bind_method(D_METHOD("set_roll", "value"), &PonyIdleBodyNative::set_roll);
	ClassDB::bind_method(D_METHOD("get_roll"), &PonyIdleBodyNative::get_roll);
	ClassDB::bind_method(D_METHOD("set_pitch", "value"), &PonyIdleBodyNative::set_pitch);
	ClassDB::bind_method(D_METHOD("get_pitch"), &PonyIdleBodyNative::get_pitch);
	ClassDB::bind_method(D_METHOD("set_breath", "value"), &PonyIdleBodyNative::set_breath);
	ClassDB::bind_method(D_METHOD("get_breath"), &PonyIdleBodyNative::get_breath);
	ClassDB::bind_method(D_METHOD("set_applied_roll", "value"), &PonyIdleBodyNative::set_applied_roll);
	ClassDB::bind_method(D_METHOD("get_applied_roll"), &PonyIdleBodyNative::get_applied_roll);
	ClassDB::bind_method(D_METHOD("set_last_pass_frame", "value"), &PonyIdleBodyNative::set_last_pass_frame);
	ClassDB::bind_method(D_METHOD("get_last_pass_frame"), &PonyIdleBodyNative::get_last_pass_frame);
	ClassDB::bind_method(D_METHOD("set_breath_arch", "value"), &PonyIdleBodyNative::set_breath_arch);
	ClassDB::bind_method(D_METHOD("get_breath_arch"), &PonyIdleBodyNative::get_breath_arch);
	// The script's variables, same names; not stored or shown (they were plain script variables).
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "pony", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_NONE), "set_pony", "get_pony");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "wanted", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_wanted", "get_wanted");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fade", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_fade", "get_fade");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "_hips", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_hips", "get_hips");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "_hips_parent", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_hips_parent", "get_hips_parent");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "_legs", PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_NONE), "set_legs", "get_legs");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "_leg_parents", PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_NONE), "set_leg_parents", "get_leg_parents");
	ADD_PROPERTY(PropertyInfo(Variant::BASIS, "_model_to_skeleton", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_model_to_skeleton", "get_model_to_skeleton");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_frame_ready", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_frame_ready", "get_frame_ready");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "_roll", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_roll", "get_roll");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "_pitch", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_pitch", "get_pitch");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "_breath", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_breath", "get_breath");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "applied_roll", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_applied_roll", "get_applied_roll");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "_last_pass_frame", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_last_pass_frame", "get_last_pass_frame");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "_breath_arch", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_breath_arch", "get_breath_arch");
}

// ---------------------------------------------------------------------------------------------
// pony_clip_head.gd

void PonyClipHeadNative::set_pony(Node *p_pony) {
	pony = p_pony != nullptr ? ObjectID(p_pony->get_instance_id()) : ObjectID();
}
Node *PonyClipHeadNative::get_pony() const {
	return node_of(pony);
}

// _apply() on its native branch (native set): the inputs read and interpolated as the script does,
// then PonySolverNative::clip_head() called directly instead of through the script. Declines when
// `native` is not a PonySolverNative (the script's own loop then runs) or an input is missing.
bool PonyClipHeadNative::native_step() {
	const Names &n = names();
	PonySolverNative *solver = Object::cast_to<PonySolverNative>(native.ptr());
	Node *p = get_pony();
	if (solver == nullptr || p == nullptr) {
		return false;
	}
	Object *secondary = as_object(p->get(n.secondary));
	if (secondary == nullptr) {
		return false;
	}
	const Variant neck_value = secondary->get(n.neck);
	if (neck_value.get_type() != Variant::ARRAY) {
		return false;
	}
	const Array neck = neck_value;
	if (neck.is_empty()) {
		return true;
	}
	Skeleton3D *skeleton = get_skeleton();
	if (skeleton == nullptr) {
		return false;
	}
	const PackedVector3Array from = p->get(n.clip_head_from);
	const PackedVector3Array to = p->get(n.clip_head_to);
	if (from.size() < 3 || to.size() < 3) {
		return false;
	}
	const double t = as_double(p->call(n.logic_alpha));
	double weight = gd_smoothstep01(as_double(p->get(n.clip_blend)));
	Object *posture = as_object(p->get(n.posture));
	const bool rest = posture != nullptr && bool(posture->call(n.active));
	if (rest) {
		weight *= 1.0 - gd_smoothstep01(as_double(posture->get(n.sleep_blend)));
		if (weight <= 0.0) {
			return true;
		}
	}
	const Vector3 head = from[0].lerp(to[0], t) * weight;
	const Vector3 gaze = from[1].lerp(to[1], t) * weight;
	const Vector3 neck_gaze = from[2].lerp(to[2], t) * weight;
	if (!bound) {
		solver->bind_clip_head(PackedInt32Array(neck), secondary->get(n.parent_frames));
		bound = true;
	}
	solver->clip_head(skeleton, head, gaze, neck_gaze, rest);
	return true;
}

void PonyClipHeadNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_step"), &PonyClipHeadNative::native_step);
	ClassDB::bind_method(D_METHOD("set_pony", "value"), &PonyClipHeadNative::set_pony);
	ClassDB::bind_method(D_METHOD("get_pony"), &PonyClipHeadNative::get_pony);
	ClassDB::bind_method(D_METHOD("set_native", "value"), &PonyClipHeadNative::set_native);
	ClassDB::bind_method(D_METHOD("get_native"), &PonyClipHeadNative::get_native);
	ClassDB::bind_method(D_METHOD("set_bound", "value"), &PonyClipHeadNative::set_bound);
	ClassDB::bind_method(D_METHOD("get_bound"), &PonyClipHeadNative::get_bound);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "pony", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_NONE), "set_pony", "get_pony");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "native", PROPERTY_HINT_RESOURCE_TYPE, "RefCounted", PROPERTY_USAGE_NONE), "set_native", "get_native");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "_bound", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_bound", "get_bound");
}

// ---------------------------------------------------------------------------------------------
// filly_proportions.gd

// _process_modification(): the same engine calls in the same order.
bool PonyFillyProportionsNative::native_step() {
	Skeleton3D *sk = get_skeleton();
	if (sk == nullptr || neck < 0 || head < 0) {
		return true;
	}
	// Scale propagates down the chain: the head's own factor divides out the neck's.
	if (!gd_equal_approx(neck_scale, 1.0)) {
		sk->set_bone_pose_scale(int32_t(neck), sk->get_bone_pose_scale(int32_t(neck)) * neck_scale);
	}
	const double head_factor = head_scale / neck_scale;
	if (!gd_equal_approx(head_factor, 1.0)) {
		sk->set_bone_pose_scale(int32_t(head), sk->get_bone_pose_scale(int32_t(head)) * head_factor);
	}
	if (!gd_equal_approx(head_width, 1.0)) {
		// Conjugate model-rest X into the head frame; keep all existing posed scale.
		Transform3D posed_head = sk->get_bone_global_pose(int32_t(head));
		posed_head.basis = posed_head.basis * local_width_basis;
		sk->set_bone_global_pose(int32_t(head), posed_head);
	}
	if (!gd_equal_approx(wing_scale, 1.0)) {
		for (int64_t i = 0; i < wings.size(); i++) {
			const int32_t wing = wings[i];
			sk->set_bone_pose_scale(wing, sk->get_bone_pose_scale(wing) * wing_scale);
		}
	}
	return true;
}

void PonyFillyProportionsNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_step"), &PonyFillyProportionsNative::native_step);
	ClassDB::bind_method(D_METHOD("set_neck_scale", "value"), &PonyFillyProportionsNative::set_neck_scale);
	ClassDB::bind_method(D_METHOD("get_neck_scale"), &PonyFillyProportionsNative::get_neck_scale);
	ClassDB::bind_method(D_METHOD("set_head_scale", "value"), &PonyFillyProportionsNative::set_head_scale);
	ClassDB::bind_method(D_METHOD("get_head_scale"), &PonyFillyProportionsNative::get_head_scale);
	ClassDB::bind_method(D_METHOD("set_head_width", "value"), &PonyFillyProportionsNative::set_head_width);
	ClassDB::bind_method(D_METHOD("get_head_width"), &PonyFillyProportionsNative::get_head_width);
	ClassDB::bind_method(D_METHOD("set_wing_scale", "value"), &PonyFillyProportionsNative::set_wing_scale);
	ClassDB::bind_method(D_METHOD("get_wing_scale"), &PonyFillyProportionsNative::get_wing_scale);
	ClassDB::bind_method(D_METHOD("set_neck", "value"), &PonyFillyProportionsNative::set_neck);
	ClassDB::bind_method(D_METHOD("get_neck"), &PonyFillyProportionsNative::get_neck);
	ClassDB::bind_method(D_METHOD("set_head", "value"), &PonyFillyProportionsNative::set_head);
	ClassDB::bind_method(D_METHOD("get_head"), &PonyFillyProportionsNative::get_head);
	ClassDB::bind_method(D_METHOD("set_local_width_basis", "value"), &PonyFillyProportionsNative::set_local_width_basis);
	ClassDB::bind_method(D_METHOD("get_local_width_basis"), &PonyFillyProportionsNative::get_local_width_basis);
	ClassDB::bind_method(D_METHOD("set_wings", "value"), &PonyFillyProportionsNative::set_wings);
	ClassDB::bind_method(D_METHOD("get_wings"), &PonyFillyProportionsNative::get_wings);
	// The script's four exported values stay exported; the bones it found in _ready() are not stored.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "neck_scale"), "set_neck_scale", "get_neck_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "head_scale"), "set_head_scale", "get_head_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "head_width"), "set_head_width", "get_head_width");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "wing_scale"), "set_wing_scale", "get_wing_scale");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "_neck", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_neck", "get_neck");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "_head", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_head", "get_head");
	ADD_PROPERTY(PropertyInfo(Variant::BASIS, "_local_width_basis", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_local_width_basis", "get_local_width_basis");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT32_ARRAY, "_wings", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_wings", "get_wings");
}
