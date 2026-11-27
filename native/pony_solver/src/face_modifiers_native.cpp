// Native pony step, lane `face`: see face_modifiers_native.h.
#include "face_modifiers_native.h"

#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <limits>

using namespace godot;

namespace {

// GDScript's maxf/minf/clampf are Godot's MAX/MIN/CLAMP templates (core/typedefs.h).
inline double gd_max(double a, double b) { return a > b ? a : b; }
inline double gd_min(double a, double b) { return a < b ? a : b; }
inline double gd_clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
// GDScript lerpf (Math::lerp, double).
inline double gd_lerp(double from, double to, double weight) { return from + (to - from) * weight; }

// Variant::hash_compare as Array == uses it (semantic comparison off for a FLOAT element, on
// inside vectors and transforms: is_same()).
inline bool same_real(real_t a, real_t b) { return a == b || (std::isnan(a) && std::isnan(b)); }
inline bool same_v2(const Vector2 &a, const Vector2 &b) { return same_real(a.x, b.x) && same_real(a.y, b.y); }
inline bool same_v3(const Vector3 &a, const Vector3 &b) {
	return same_real(a.x, b.x) && same_real(a.y, b.y) && same_real(a.z, b.z);
}
inline bool same_t3(const Transform3D &a, const Transform3D &b) {
	return same_v3(a.basis.rows[0], b.basis.rows[0]) && same_v3(a.basis.rows[1], b.basis.rows[1]) &&
			same_v3(a.basis.rows[2], b.basis.rows[2]) && same_v3(a.origin, b.origin);
}

// The script's identity: the native step only stands in for the script's own body.
ObjectID script_id(const Object *p_object) {
	const Variant script = p_object->get_script();
	const Object *object = script;
	return object != nullptr ? ObjectID(object->get_instance_id()) : ObjectID();
}

// openpony_eye_motion.gd FACE_POINTS and FACE_POINT_ODDS.
const Vector2 FACE_POINTS[4] = { Vector2(-1, 0), Vector2(1, 0), Vector2(0, 0), Vector2(0, -2.2) };
const double FACE_POINT_ODDS[4] = { .37, .37, .16, .10 };
const double FACE_HALF_EYES = .032;
const double FACE_POINT_GAIN = 1.5;
// GAZE_MOODS.neutral, the initial _mood and _mood_goal.
const double NEUTRAL_MOOD[8] = { 0.85, 1.0, 0.09, 0.15, 0.45, 1.0, 1.0, 0.3 };

double randf_range(RandomNumberGenerator *p_rng, double p_from, double p_to) {
	return (double)p_rng->randf_range((float)p_from, (float)p_to);
}

} // namespace

// ---------------------------------------------------------------------------------------------
// PonyEyeMotionNative: openpony_eye_motion.gd
// ---------------------------------------------------------------------------------------------

PonyEyeMotionNative::PonyEyeMotionNative() {
	rng.instantiate();
	for (int i = 0; i < 8; i++) {
		mood[i] = (float)NEUTRAL_MOOD[i];
		mood_goal[i] = (float)NEUTRAL_MOOD[i];
	}
}

Object *PonyEyeMotionNative::get_player() const {
	return player.is_valid() ? ObjectDB::get_instance(player) : nullptr;
}

void PonyEyeMotionNative::set_player(Object *p_value) {
	player = p_value != nullptr ? ObjectID(p_value->get_instance_id()) : ObjectID();
}

PackedFloat32Array PonyEyeMotionNative::get_mood() const {
	PackedFloat32Array out;
	out.resize(8);
	for (int i = 0; i < 8; i++) {
		out[i] = mood[i];
	}
	return out;
}

void PonyEyeMotionNative::set_mood(const PackedFloat32Array &p_value) {
	for (int i = 0; i < 8 && i < p_value.size(); i++) {
		mood[i] = p_value[i];
	}
}

PackedFloat32Array PonyEyeMotionNative::get_mood_goal() const {
	PackedFloat32Array out;
	out.resize(8);
	for (int i = 0; i < 8; i++) {
		out[i] = mood_goal[i];
	}
	return out;
}

void PonyEyeMotionNative::set_mood_goal(const PackedFloat32Array &p_value) {
	for (int i = 0; i < 8 && i < p_value.size(); i++) {
		mood_goal[i] = p_value[i];
	}
}

void PonyEyeMotionNative::native_reset(bool p_rest_bound, bool p_base) {
	rest_bound = p_rest_bound;
	own_script = p_base ? script_id(this) : ObjectID();
	has_last = false;
	last_eyes = Dictionary();
	last_brows = Dictionary();
	last_ears = Dictionary();
	last_surface_update = Callable();
}

bool PonyEyeMotionNative::script_ok() const {
	return own_script.is_valid() && script_id(this) == own_script;
}

// _unprofiled_process_modification() with `native` set (PonySolverNative's eye_process and
// eye_rewrite do the bone work, as the script's own native path does).
bool PonyEyeMotionNative::native_step(bool p_reuse_unchanged) {
	PonySolverNative *native = Object::cast_to<PonySolverNative>(solver.ptr());
	if (native == nullptr || !script_ok()) {
		return false;
	}
	if (!is_inside_tree()) {
		return true;
	}
	Skeleton3D *sk = get_skeleton();
	if (sk == nullptr || !sk->is_inside_tree()) {
		return true;
	}
	if (!rest_bound) {
		return true;
	}
	if (rate_divisor > 1 && (((int64_t)Engine::get_singleton()->get_physics_frames() + rate_phase) % rate_divisor) != 0) {
		// Clip-tier mare: re-apply the last full run (Skeleton3D reverts modifier writes).
		native->eye_rewrite(sk);
		return true;
	}
	if (p_reuse_unchanged) {
		// _inputs(): empty while the head's AnimationPlayer plays (never reused).
		AnimationPlayer *animation = Object::cast_to<AnimationPlayer>(get_player());
		if (animation != nullptr && animation->is_playing()) {
			has_last = false;
		} else {
			Transform3D aim_frame;
			if (target_weight > 0.0 && head_bone >= 0) {
				aim_frame = sk->get_global_transform() * sk->get_bone_global_pose((int32_t)head_bone);
			}
			const Vector3 target = target_weight > 0.0 ? target_world : Vector3();
			// inputs == _last_inputs, element by element (the asymmetry array is a function of
			// cross_inward on this script).
			if (has_last && closure == last_closure && expression_closure == last_expression_closure &&
					target_weight == last_target_weight && convergence_degrees == last_convergence &&
					same_v2(gaze, last_gaze) && same_v2(offset, last_offset) && cross_inward == last_cross_inward &&
					same_v3(target, last_target) && same_t3(aim_frame, last_aim_frame) && expression_eyes == last_eyes &&
					expression_brows == last_brows && expression_ears == last_ears && surface_update == last_surface_update) {
				native->eye_rewrite(sk);
				return true;
			}
			// Stored with copies: the expression dictionaries are edited in place by their owners.
			has_last = true;
			last_closure = closure;
			last_expression_closure = expression_closure;
			last_target_weight = target_weight;
			last_convergence = convergence_degrees;
			last_gaze = gaze;
			last_offset = offset;
			last_cross_inward = cross_inward;
			last_target = target;
			last_aim_frame = aim_frame;
			last_eyes = expression_eyes.duplicate();
			last_brows = expression_brows.duplicate();
			last_ears = expression_ears.duplicate();
			last_surface_update = surface_update;
		}
	}
	PackedFloat64Array scalars;
	scalars.resize(7);
	scalars[0] = closure;
	scalars[1] = expression_closure;
	scalars[2] = target_weight;
	scalars[3] = convergence_degrees;
	// _native_asymmetry(): [1 when surface_angles() shifts the eyes, inward, vertical radians].
	scalars[4] = cross_inward > 0.0 ? 1.0 : 0.0;
	scalars[5] = cross_inward;
	scalars[6] = 0.0;
	native->eye_process(sk, scalars, gaze, offset, target_world, expression_eyes, expression_brows, expression_ears,
			surface_update);
	return true;
}

// advance(delta)
bool PonyEyeMotionNative::native_advance(double p_delta) {
	RandomNumberGenerator *r = rng.ptr();
	if (r == nullptr) {
		return false;
	}
	const double delta = p_delta;
	// Attention already owns target_weight for listening, looking and carrying.
	fixation = gd_lerp(fixation, gd_clamp(target_weight, 0.0, 1.0), 1.0 - UtilityFunctions::exp(-delta * 5.0));
	wait -= delta;
	if (saccades_enabled && wait <= 0.0) {
		from = scan_offset;
		const double angle = randf_range(r, -Math_PI, Math_PI);
		const double radius = std::sqrt(randf_range(r, .12, 1.0));
		to = Vector2((real_t)(UtilityFunctions::cos(angle) * .044), (real_t)(UtilityFunctions::sin(angle) * .027)) * (real_t)radius;
		if ((double)r->randf() < .18) {
			to = to * (real_t).18; // Small corrective return, not a regular reset.
		}
		duration = randf_range(r, .035, .065) + (double)from.distance_to(to) * .35;
		elapsed = 0.0;
		// Occasional paired shifts amid unequal longer fixations avoid a metronome.
		if ((double)r->randf() < .16) {
			wait = randf_range(r, .18, .38);
		} else {
			wait = randf_range(r, .8, 4.8);
		}
	}
	elapsed += delta;
	const double t = gd_clamp(elapsed / duration, 0.0, 1.0);
	const double eased = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
	scan_offset = saccades_enabled ? from.lerp(to, (real_t)eased) : Vector2();
	if (saccades_enabled && fixation > .02) {
		advance_focus(delta);
	} else if (focus_point != -1 || glance_left >= 0.0 || focus_offset != Vector2()) {
		focus_offset = Vector2();
		drift = Vector2();
		focus_point = -1;
		glance_left = -1.0;
		focus_wait = randf_range(r, .1, .4);
	}
	// On a target the face darts replace the idle exploration.
	const double fixed = UtilityFunctions::smoothstep(0.0, 1.0, fixation);
	offset = saccades_enabled ? scan_offset.lerp(focus_offset + drift, (real_t)fixed) : Vector2();
	if (!blink_enabled) {
		return true;
	}
	blink_wait -= delta;
	if (blink_wait <= 0.0 && blink_time < 0.0) {
		blink_time = 0.0;
		blink_close = randf_range(r, .105, .155);
		blink_hold = randf_range(r, .012, .045);
		blink_open = randf_range(r, .19, .29);
		if (paired_blink) {
			paired_blink = false;
			blink_wait = randf_range(r, 3.0, 7.5);
		} else {
			paired_blink = (double)r->randf() < .09;
			if (paired_blink) {
				blink_wait = blink_close + blink_hold + blink_open + randf_range(r, .10, .22);
			} else {
				blink_wait = randf_range(r, 3.0, 7.5);
			}
		}
	}
	closure = 0.0;
	if (blink_time >= 0.0) {
		blink_time += delta;
		const double opening = blink_close + blink_hold;
		const double finished = opening + blink_open;
		closure = blink_time < blink_close ? UtilityFunctions::smoothstep(0.0, blink_close, blink_time)
										   : 1.0 - UtilityFunctions::smoothstep(opening, finished, blink_time);
		if (blink_time >= finished) {
			blink_time = -1.0;
		}
	}
	closure *= gd_clamp(blink_strength, 0.0, 1.0);
	return true;
}

// _advance_focus(delta)
void PonyEyeMotionNative::advance_focus(double p_delta) {
	const double delta = p_delta;
	const double ease = 1.0 - UtilityFunctions::exp(-delta * 3.0);
	for (int i = 0; i < 8; i++) {
		mood[i] = (float)gd_lerp((double)mood[i], (double)mood_goal[i], ease);
	}
	focus_wait -= delta;
	if (glance_left >= 0.0) {
		glance_left -= delta;
		if (glance_left < 0.0) {
			focus_wait = 0.0; // straight back to her face
		}
	}
	if (focus_wait <= 0.0) {
		focus_start();
	}
	focus_elapsed += delta;
	const double t = gd_clamp(focus_elapsed / focus_duration, 0.0, 1.0);
	focus_offset = focus_from.lerp(focus_to, (real_t)(t * t * t * (t * (t * 6.0 - 15.0) + 10.0)));
	// Slow drift while fixating, corrected by the next dart. Close (full-rate) ponies only.
	if (rate_divisor == 1 && t >= 1.0 && glance_left < 0.0) {
		drift = drift.lerp(drift_goal, (real_t)(1.0 - UtilityFunctions::exp(-delta * 1.2)));
	}
}

// _focus_start()
void PonyEyeMotionNative::focus_start() {
	RandomNumberGenerator *r = rng.ptr();
	const double spacing = face_spacing();
	Vector2 target;
	if (glance_left < 0.0 && focus_point >= 0 && (double)r->randf() < (double)mood[2]) {
		// A brief look away; the return is the next dart, after the mood's dwell.
		const double angle = randf_range(r, -Math_PI, Math_PI);
		Vector2 direction((real_t)UtilityFunctions::cos(angle), (real_t)(UtilityFunctions::sin(angle) * .8));
		if ((double)r->randf() < (double)mood[7]) {
			direction = Vector2(direction.x, (real_t)(-std::abs((double)direction.y) - .35)).normalized();
		}
		const Vector2 scaled = direction * (real_t)(double)mood[3];
		target = scaled * (real_t)randf_range(r, .7, 1.25);
		glance_left = (double)mood[4] * randf_range(r, .6, 1.5);
		focus_point = -1;
		focus_wait = std::numeric_limits<double>::infinity();
		focus_glances += 1;
	} else {
		glance_left = -1.0;
		int64_t point = focus_point;
		for (int attempt = 0; attempt < 3; attempt++) {
			if (point != focus_point) {
				break;
			}
			double roll = (double)r->randf();
			point = 3;
			for (int i = 0; i < 4; i++) {
				roll -= FACE_POINT_ODDS[i];
				if (roll < 0.0) {
					point = i;
					break;
				}
			}
		}
		focus_point = point;
		const double size = spacing * (double)mood[1];
		const Vector2 base = FACE_POINTS[point] * (real_t)size;
		const double jitter_x = randf_range(r, -.18, .18);
		const double jitter_y = randf_range(r, -.18, .18);
		target = base + Vector2((real_t)jitter_x, (real_t)jitter_y) * (real_t)size;
		focus_wait = (double)mood[0] * randf_range(r, .45, 1.6);
	}
	const double drift_angle = randf_range(r, -Math_PI, Math_PI);
	Vector2 goal = Vector2((real_t)UtilityFunctions::cos(drift_angle), (real_t)UtilityFunctions::sin(drift_angle)) * (real_t)spacing;
	goal = goal * (real_t).3;
	goal = goal * (real_t)(double)mood[6];
	drift_goal = goal * (real_t)(double)r->randf();
	focus_from = focus_offset + drift;
	drift = Vector2();
	focus_to = target;
	const double start = randf_range(r, .03, .05);
	focus_duration = (start + (double)focus_from.distance_to(target) * .35) / gd_max((double)mood[5], .1);
	focus_elapsed = 0.0;
	focus_saccades += 1;
}

// _face_spacing()
double PonyEyeMotionNative::face_spacing() {
	double distance = 1.2;
	Skeleton3D *sk = is_inside_tree() ? get_skeleton() : nullptr;
	if (sk != nullptr && head_bone >= 0) {
		distance = (double)sk->get_global_transform().xform(sk->get_bone_global_pose((int32_t)head_bone).origin).distance_to(target_world);
	}
	return gd_clamp(FACE_POINT_GAIN * FACE_HALF_EYES / gd_max(distance, .1), .02, .06);
}

#define BIND_FIELD(m_class, m_type, m_name, m_member, m_usage) \
	ClassDB::bind_method(D_METHOD("face_get_" m_name), &m_class::get_##m_member); \
	ClassDB::bind_method(D_METHOD("face_set_" m_name, "value"), &m_class::set_##m_member); \
	ADD_PROPERTY(PropertyInfo(m_type, m_name, PROPERTY_HINT_NONE, "", m_usage), "face_set_" m_name, "face_get_" m_name);

#define BIND_OBJECT(m_class, m_name, m_member, m_class_name) \
	ClassDB::bind_method(D_METHOD("face_get_" m_name), &m_class::get_##m_member); \
	ClassDB::bind_method(D_METHOD("face_set_" m_name, "value"), &m_class::set_##m_member); \
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, m_name, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE, m_class_name), "face_set_" m_name, "face_get_" m_name);

void PonyEyeMotionNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_reset", "rest_bound", "base"), &PonyEyeMotionNative::native_reset);
	ClassDB::bind_method(D_METHOD("native_step", "reuse_unchanged"), &PonyEyeMotionNative::native_step);
	ClassDB::bind_method(D_METHOD("native_advance", "delta"), &PonyEyeMotionNative::native_advance);
	const uint32_t none = PROPERTY_USAGE_NONE;
	BIND_OBJECT(PonyEyeMotionNative, "native", solver, "RefCounted")
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "convergence_degrees", convergence_degrees, PROPERTY_USAGE_DEFAULT)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "closure", closure, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "expression_closure", expression_closure, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::DICTIONARY, "expression_brows", expression_brows, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::DICTIONARY, "expression_eyes", expression_eyes, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::DICTIONARY, "expression_ears", expression_ears, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "gaze", gaze, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::CALLABLE, "surface_update", surface_update, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR3, "target_world", target_world, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "target_weight", target_weight, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::BOOL, "saccades_enabled", saccades_enabled, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::INT, "rate_divisor", rate_divisor, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::INT, "rate_phase", rate_phase, none)
	BIND_OBJECT(PonyEyeMotionNative, "_player", player, "AnimationPlayer")
	BIND_FIELD(PonyEyeMotionNative, Variant::BOOL, "blink_enabled", blink_enabled, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "blink_strength", blink_strength, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::INT, "_head_bone", head_bone, none)
	BIND_OBJECT(PonyEyeMotionNative, "_rng", rng, "RandomNumberGenerator")
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_wait", wait, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_from", from, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_to", to, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_offset", offset, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_scan_offset", scan_offset, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_fixation", fixation, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_elapsed", elapsed, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_duration", duration, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_blink_wait", blink_wait, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_blink_time", blink_time, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_blink_close", blink_close, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_blink_hold", blink_hold, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_blink_open", blink_open, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::BOOL, "_paired_blink", paired_blink, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::PACKED_FLOAT32_ARRAY, "_mood", mood, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::PACKED_FLOAT32_ARRAY, "_mood_goal", mood_goal, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_focus_from", focus_from, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_focus_to", focus_to, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_focus_offset", focus_offset, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_focus_elapsed", focus_elapsed, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_focus_duration", focus_duration, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_focus_wait", focus_wait, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::INT, "_focus_point", focus_point, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "_glance_left", glance_left, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_drift", drift, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::VECTOR2, "_drift_goal", drift_goal, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::INT, "focus_saccades", focus_saccades, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::INT, "focus_glances", focus_glances, none)
	BIND_FIELD(PonyEyeMotionNative, Variant::FLOAT, "cross_inward", cross_inward, none)
}

// ---------------------------------------------------------------------------------------------
// PonyMouthNative: pony_mouth.gd
// ---------------------------------------------------------------------------------------------

int32_t PonyMouthNative::name_id(const String &p_name) {
	const int64_t length = p_name.length();
	const char32_t *chars = p_name.ptr();
	for (size_t i = 0; i < names.size(); i++) {
		if ((int64_t)names[i].size() == length && (length == 0 || names[i].compare(0, length, chars, length) == 0)) {
			return (int32_t)i;
		}
	}
	names.emplace_back(chars, chars + length);
	shapes.emplace_back();
	return (int32_t)names.size() - 1;
}

int PonyMouthNative::find(const std::vector<std::pair<int32_t, double>> &p_list, int32_t p_id) {
	for (size_t i = 0; i < p_list.size(); i++) {
		if (p_list[i].first == p_id) {
			return (int)i;
		}
	}
	return -1;
}

double PonyMouthNative::value_of(const std::vector<std::pair<int32_t, double>> &p_list, int32_t p_id) {
	const int i = find(p_list, p_id);
	return i >= 0 ? p_list[i].second : 0.0;
}

Dictionary PonyMouthNative::to_dictionary(const std::vector<std::pair<int32_t, double>> &p_list) const {
	Dictionary out;
	for (const std::pair<int32_t, double> &entry : p_list) {
		const std::u32string &name = names[entry.first];
		out[String(name.c_str())] = entry.second;
	}
	return out;
}

void PonyMouthNative::from_dictionary(const Dictionary &p_value, std::vector<std::pair<int32_t, double>> &r_list) {
	r_list.clear();
	const Array keys = p_value.keys();
	for (int64_t i = 0; i < keys.size(); i++) {
		r_list.emplace_back(name_id(String(keys[i])), (double)p_value[keys[i]]);
	}
}

PackedInt32Array PonyMouthNative::get_mix_bones() const {
	PackedInt32Array out;
	out.resize((int64_t)mix_bones.size());
	for (size_t i = 0; i < mix_bones.size(); i++) {
		out[(int64_t)i] = mix_bones[i];
	}
	return out;
}

void PonyMouthNative::set_mix_bones(const PackedInt32Array &p_value) {
	mix_bones.assign(p_value.ptr(), p_value.ptr() + p_value.size());
}

Array PonyMouthNative::get_mix_rotations() const {
	Array out;
	for (const Quaternion &q : mix_rotations) {
		out.push_back(q);
	}
	return out;
}

void PonyMouthNative::set_mix_rotations(const Array &p_value) {
	mix_rotations.clear();
	for (int64_t i = 0; i < p_value.size(); i++) {
		mix_rotations.push_back(p_value[i]);
	}
}

PackedVector3Array PonyMouthNative::get_mix_offsets() const {
	PackedVector3Array out;
	out.resize((int64_t)mix_offsets.size());
	for (size_t i = 0; i < mix_offsets.size(); i++) {
		out[(int64_t)i] = mix_offsets[i];
	}
	return out;
}

void PonyMouthNative::set_mix_offsets(const PackedVector3Array &p_value) {
	mix_offsets.assign(p_value.ptr(), p_value.ptr() + p_value.size());
}

bool PonyMouthNative::script_ok() const {
	return own_script.is_valid() && script_id(this) == own_script;
}

void PonyMouthNative::native_bind(const Dictionary &p_shapes, const PackedInt32Array &p_bones,
		const PackedFloat64Array &p_constants, const Array &p_speech_open, const Dictionary &p_lip_tone, bool p_base) {
	own_script = p_base ? script_id(this) : ObjectID();
	ERR_FAIL_COND(p_constants.size() != 5);
	open_rate = p_constants[0];
	close_rate = p_constants[1];
	settle = p_constants[2];
	speech_open_at = p_constants[3];
	lip_tone_step = p_constants[4];
	for (Shape &shape : shapes) {
		shape = Shape();
	}
	const Array shape_names = p_shapes.keys();
	for (int64_t s = 0; s < shape_names.size(); s++) {
		const int32_t id = name_id(String(shape_names[s]));
		Shape &shape = shapes[id];
		shape.present = true;
		const Dictionary deltas = p_shapes[shape_names[s]];
		const Array shape_bones = deltas.keys();
		for (int64_t b = 0; b < shape_bones.size(); b++) {
			const int32_t bone = (int32_t)(int64_t)shape_bones[b];
			const Dictionary d = deltas[shape_bones[b]];
			if (bone < 0) {
				continue;
			}
			if ((int32_t)shape.slot.size() <= bone) {
				shape.slot.resize(bone + 1, -1);
			}
			shape.slot[bone] = (int32_t)shape.q.size();
			shape.q.push_back(d["q"]);
			shape.p.push_back(d["p"]);
		}
	}
	bones.assign(p_bones.ptr(), p_bones.ptr() + p_bones.size());
	speech_open.clear();
	for (int64_t i = 0; i < p_speech_open.size(); i++) {
		speech_open.push_back(name_id(String(p_speech_open[i])));
	}
	lip_tone_shares.clear();
	const Array tone_names = p_lip_tone.keys();
	for (int64_t i = 0; i < tone_names.size(); i++) {
		lip_tone_shares.emplace_back(name_id(String(tone_names[i])), (double)p_lip_tone[tone_names[i]]);
	}
}

// _retarget(blend)
void PonyMouthNative::native_retarget(const Dictionary &p_viseme_targets, const Dictionary &p_expression,
		double p_expression_scale, double p_blend) {
	targets.clear();
	const Array viseme_keys = p_viseme_targets.keys();
	for (int64_t i = 0; i < viseme_keys.size(); i++) {
		targets.emplace_back(name_id(String(viseme_keys[i])), (double)p_viseme_targets[viseme_keys[i]]);
	}
	const Array expression_keys = p_expression.keys();
	for (int64_t i = 0; i < expression_keys.size(); i++) {
		const int32_t id = name_id(String(expression_keys[i]));
		const int at = find(targets, id);
		const double value = gd_min((at >= 0 ? targets[at].second : 0.0) + (double)p_expression[expression_keys[i]] * p_expression_scale, 1.0);
		if (at >= 0) {
			targets[at].second = value;
		} else {
			targets.emplace_back(id, value);
		}
	}
	if (p_blend == 0.0) {
		mix_valid = false;
		weights.clear();
		for (const std::pair<int32_t, double> &entry : targets) {
			if (!(entry.second <= 0.0)) {
				weights.push_back(entry);
			}
		}
		update_lip_open();
	}
}

// _update_lip_open()
void PonyMouthNative::update_lip_open() {
	if (lip_tone_changed.is_valid()) {
		double tone = 0.0;
		for (const std::pair<int32_t, double> &share : lip_tone_shares) {
			tone += value_of(weights, share.first) * share.second;
		}
		tone = UtilityFunctions::snappedf(gd_min(tone, 1.0), lip_tone_step);
		if (tone != lip_tone) {
			lip_tone = tone;
			lip_tone_changed.call(tone);
		}
	}
	if (!lip_open_changed.is_valid()) {
		return;
	}
	bool open = false;
	for (int32_t shape : speech_open) {
		if (value_of(weights, shape) > speech_open_at) {
			open = true;
			break;
		}
	}
	if (open != lip_open) {
		lip_open = open;
		lip_open_changed.call(open);
	}
}

// advance_weights(delta)
bool PonyMouthNative::native_advance_weights(double p_delta) {
	const double delta = p_delta;
	const double rise = blend_time <= 0.0 ? 1.0 : 1.0 - UtilityFunctions::exp(-delta * open_rate / blend_time);
	const double fall = blend_time <= 0.0 ? 1.0 : 1.0 - UtilityFunctions::exp(-delta * close_rate / blend_time);
	bool changed = false;
	for (const std::pair<int32_t, double> &entry : targets) {
		const int at = find(weights, entry.first);
		const double before = at >= 0 ? weights[at].second : 0.0;
		const double target = entry.second;
		double w = before + (target - before) * (target > before ? rise : fall);
		if (std::abs(target - w) < settle) {
			w = target;
		}
		if (w != before || at < 0) {
			changed = true;
		}
		if (at >= 0) {
			weights[at].second = w;
		} else {
			weights.emplace_back(entry.first, w);
		}
	}
	for (size_t i = 0; i < weights.size();) {
		if (find(targets, weights[i].first) < 0) {
			const double w = weights[i].second * (1.0 - fall);
			changed = true;
			if (w < settle) {
				weights.erase(weights.begin() + (ptrdiff_t)i);
				continue;
			}
			weights[i].second = w;
		}
		i++;
	}
	return changed;
}

// _build_mix()
void PonyMouthNative::build_mix(double p_influence) {
	mix_bones.clear();
	mix_rotations.clear();
	mix_offsets.clear();
	mix_influence = p_influence;
	mix_valid = true;
	for (int32_t idx : bones) {
		Quaternion q;
		Vector3 p;
		bool touched = false;
		for (const std::pair<int32_t, double> &entry : weights) {
			const double w = entry.second * p_influence;
			if (w <= 0.0001) {
				continue;
			}
			// A weight for a shape build() never made is a script error there; here it adds nothing.
			const Shape &shape = shapes[entry.first];
			if (!shape.present || idx < 0 || idx >= (int32_t)shape.slot.size() || shape.slot[idx] < 0) {
				continue;
			}
			const int32_t slot = shape.slot[idx];
			q = q * pony::slerp(Quaternion(), shape.q[slot], gd_min(w, 1.0));
			p += shape.p[slot] * (real_t)w;
			touched = true;
		}
		if (touched) {
			mix_bones.push_back(idx);
			mix_rotations.push_back(q);
			mix_offsets.push_back(p);
		}
	}
}

// _unprofiled_process_modification()
bool PonyMouthNative::native_step(bool p_mix_cache) {
	if (!script_ok()) {
		return false;
	}
	Skeleton3D *skel = get_skeleton();
	if (skel == nullptr || bones.empty()) {
		return true;
	}
	if (rate_divisor > 1 && (((int64_t)Engine::get_singleton()->get_physics_frames() + rate_phase) % rate_divisor) != 0) {
		// Clip-tier mare: re-apply the last full run (Skeleton3D reverts modifier writes).
		for (size_t k = 0; k < written_bones.size(); k++) {
			skel->set_bone_pose_rotation(written_bones[k], written_rotations[k]);
			skel->set_bone_pose_position(written_bones[k], written_positions[k]);
		}
		return true;
	}
	const bool changed = native_advance_weights(get_process_delta_time() * (double)rate_divisor);
	if (changed) {
		update_lip_open();
	}
	if (weights.empty()) {
		written_bones.clear();
		written_rotations.clear();
		written_positions.clear();
		mix_valid = false;
		return true;
	}
	const double influence = (double)get_influence();
	if (changed || !mix_valid || influence != mix_influence || !p_mix_cache) {
		build_mix(influence);
	}
	const size_t count = mix_bones.size();
	written_bones = mix_bones;
	written_rotations.resize(count);
	written_positions.resize(count);
	for (size_t k = 0; k < count; k++) {
		const int32_t idx = mix_bones[k];
		const Quaternion q = (skel->get_bone_pose_rotation(idx) * mix_rotations[k]).normalized();
		const Vector3 p = skel->get_bone_pose_position(idx) + mix_offsets[k];
		skel->set_bone_pose_rotation(idx, q);
		skel->set_bone_pose_position(idx, p);
		written_rotations[k] = q;
		written_positions[k] = p;
	}
	return true;
}

void PonyMouthNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_bind", "shapes", "bones", "constants", "speech_open", "lip_tone", "base"),
			&PonyMouthNative::native_bind);
	ClassDB::bind_method(D_METHOD("native_retarget", "viseme_targets", "expression", "expression_scale", "blend"),
			&PonyMouthNative::native_retarget);
	ClassDB::bind_method(D_METHOD("native_advance_weights", "delta"), &PonyMouthNative::native_advance_weights);
	ClassDB::bind_method(D_METHOD("native_update_lip_open"), &PonyMouthNative::native_update_lip_open);
	ClassDB::bind_method(D_METHOD("native_step", "mix_cache"), &PonyMouthNative::native_step);
	const uint32_t none = PROPERTY_USAGE_NONE;
	BIND_FIELD(PonyMouthNative, Variant::INT, "rate_divisor", rate_divisor, none)
	BIND_FIELD(PonyMouthNative, Variant::INT, "rate_phase", rate_phase, none)
	BIND_FIELD(PonyMouthNative, Variant::FLOAT, "blend_time", blend_time, PROPERTY_USAGE_DEFAULT)
	BIND_FIELD(PonyMouthNative, Variant::BOOL, "_mix_valid", mix_valid, none)
	BIND_FIELD(PonyMouthNative, Variant::FLOAT, "_mix_influence", mix_influence, none)
	BIND_FIELD(PonyMouthNative, Variant::CALLABLE, "lip_open_changed", lip_open_changed, none)
	BIND_FIELD(PonyMouthNative, Variant::CALLABLE, "lip_tone_changed", lip_tone_changed, none)
	BIND_FIELD(PonyMouthNative, Variant::BOOL, "_lip_open", lip_open, none)
	BIND_FIELD(PonyMouthNative, Variant::FLOAT, "_lip_tone", lip_tone, none)
	BIND_FIELD(PonyMouthNative, Variant::DICTIONARY, "_targets", targets, none)
	BIND_FIELD(PonyMouthNative, Variant::DICTIONARY, "_weights", weights, none)
	BIND_FIELD(PonyMouthNative, Variant::PACKED_INT32_ARRAY, "_mix_bones", mix_bones, none)
	BIND_FIELD(PonyMouthNative, Variant::ARRAY, "_mix_rotations", mix_rotations, none)
	BIND_FIELD(PonyMouthNative, Variant::PACKED_VECTOR3_ARRAY, "_mix_offsets", mix_offsets, none)
}
