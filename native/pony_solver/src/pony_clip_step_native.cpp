// The clip tiers' walking step in C++ (lane `step`, port_step.md). See pony_clip_step_native.h.
//
// Every statement below is one of pony_locomotion.gd _clip_step() / _advance_clip(), in the script's
// order. Float types follow GDScript: script `float` locals and members are doubles; Vector3, Basis
// and Transform3D hold 32-bit floats, and a double meets a vector component only through the same
// conversion the Variant evaluator makes (real_t). @GlobalScope functions that reach the C runtime
// (sin, cos, tan, exp, atan2), the angle helpers, move_toward, smoothstep and fposmod go to the engine
// (UtilityFunctions), as GDScript does; clampf, lerpf, minf, maxf and absf are written out (engine_math.h).
#include "pony_clip_step_native.h"

#include "engine_math.h"

#include "pony_solver_native.h"

#include <godot_cpp/classes/animation_library.hpp>
#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/character_body3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>

namespace godot {

namespace {

// The members and methods step() reads and writes by name.
struct Names {
	StringName clip_age = "_clip_age";
	StringName clip_blocked = "_clip_blocked";
	StringName clip_wanted = "_clip_wanted";
	StringName command_speed = "_command_speed";
	StringName profile = "profile";
	StringName acceleration = "acceleration";
	StringName braking = "braking";
	StringName hip_height = "hip_height";
	StringName yaw_rate = "_yaw_rate";
	StringName nav_motion = "_nav_motion";
	StringName nav_frame = "_nav_frame";
	StringName nav_mode = "_nav_mode";
	StringName nav_yaw_rate = "_nav_yaw_rate";
	StringName nav_speed = "_nav_speed";
	StringName steer_turn_rate = "steer_turn_rate";
	StringName nav_executed_speed = "nav_executed_speed";
	StringName nav_executed_yaw_rate = "nav_executed_yaw_rate";
	StringName desired = "_desired";
	StringName sim_tier = "sim_tier";
	StringName sim_phase = "sim_phase";
	StringName far_logic_divisor = "far_logic_divisor";
	StringName far_tick_divisor = "far_tick_divisor";
	StringName backing = "backing";
	StringName clip_yaw = "_clip_yaw";
	StringName face_direction = "_face_direction";
	StringName held = "_held";
	StringName collision_cooldown = "_collision_cooldown";
	StringName face_turn_rate = "face_turn_rate";
	StringName clip_floor = "_clip_floor";
	StringName clip_floor_at = "_clip_floor_at";
	StringName clip_pitch_target = "_clip_pitch_target";
	StringName seated = "seated";
	StringName clip_blend = "_clip_blend";
	StringName posture_pivot_settled = "_posture_pivot_settled";
	StringName clip_pivot_settled = "_clip_pivot_settled";
	StringName clip_pitch = "_clip_pitch";
	StringName body_scale = "body_scale";
	StringName clip_from = "_clip_from";
	StringName pivot = "pivot";
	StringName ground_velocity = "_ground_velocity";
	StringName previous_horizontal_velocity = "_previous_horizontal_velocity";
	StringName actual_speed = "actual_speed";
	StringName state = "state";
	StringName blend = "_blend";
	StringName clip_refresh = "_clip_refresh";
	StringName clip_static = "_clip_static";
	StringName clip_blend_end = "_clip_blend_end";
	StringName clip_advance_delta = "_clip_advance_delta";
	StringName needs_full_rate = "needs_full_rate";
	StringName animation = "animation";
	StringName skeleton = "skeleton";
	StringName hoof_plants = "_hoof_plants";
	StringName audible = "audible";
	StringName step = "step";
	StringName crowd_hidden = "crowd_hidden"; // PonyCrowd.HIDDEN
	StringName coarse_motion = "coarse_motion";
	StringName posture = "posture";
	StringName active = "active";
	StringName clip_gait = "_clip_gait";
	StringName clip_pose_deferred = "_clip_pose_deferred";
	// _clip_logic()
	StringName nav_speed_scale = "nav_speed_scale";
	StringName nav_gait_speed = "_nav_gait_speed";
	StringName nav_refusal = "nav_refusal";
	StringName nav_wall_normal = "nav_wall_normal";
	StringName clip_ahead_from = "_clip_ahead_from";
	StringName clip_ahead_dir = "_clip_ahead_dir";
	StringName clip_ahead_certified = "_clip_ahead_certified";
	StringName clip_ahead_skips = "_clip_ahead_skips";
	StringName clip_ahead_reach = "_clip_ahead_reach";
	StringName step_height = "step_height";
	StringName max_slope_degrees = "max_slope_degrees";
	StringName crowd = "_crowd";
	StringName floor_y = "floor_y";
	StringName position = "position";
	StringName probe = "_probe";
	StringName native_probe = "_native_probe";
	StringName native = "_native";
	StringName floor_mask = "floor_mask";
	StringName clip_probe_logic = "_clip_probe_logic";
	StringName clip_floor_from_ray = "_clip_floor_from_ray";
	StringName clip_floor_keep = "_clip_floor_keep";
	StringName clip_floor_yaw = "_clip_floor_yaw";
	StringName clip_gait_hold = "_clip_gait_hold";
	StringName clip_enter_phase = "_clip_enter_phase";
	StringName handoff_library = "handoff";
	StringName handoff_clip = "crowd_handoff";
	StringName walk_speed = "walk_speed";
	StringName gait_hold_seconds = "gait_hold_seconds";
	StringName gait_blend_seconds = "gait_blend_seconds";
	StringName gallop_entry = "gallop_entry";
	StringName gallop_exit = "gallop_exit";
	StringName trot_entry = "trot_entry";
	StringName trot_exit = "trot_exit";
	StringName trot_speed = "trot_speed";
	StringName baked = "_baked";
	StringName speeds = "speeds";
	StringName logic = "logic";
	StringName secondary = "secondary";
	StringName update = "update";
	StringName nominal_speed = "nominal_speed";
	StringName sway_amount = "sway_amount";
	StringName phase = "phase";
	StringName head_angles = "head_angles";
	StringName gaze_angles = "gaze_angles";
	StringName neck_gaze = "_neck_gaze";
	StringName clip_head_from = "clip_head_from";
	StringName clip_head_to = "clip_head_to";
};

const Names &names() {
	static const Names n;
	return n;
}

inline Object *object_of(const Variant &value) {
	return value.get_type() == Variant::OBJECT ? static_cast<Object *>(value) : nullptr;
}

// pony_locomotion.gd _clip_floor_rise().
double floor_rise(Node3D *pony, Object *profile) {
	const Names &n = names();
	const double clip_floor = double(pony->get(n.clip_floor));
	if (!std::isfinite(clip_floor)) {
		return 0.0;
	}
	Vector3 forward = -pony->get_global_basis().get_column(2);
	forward.y = 0.0;
	const Vector3 floor_at = pony->get(n.clip_floor_at);
	const double expected = clip_floor + double((pony->get_global_position() - floor_at).dot(forward.normalized())) * UtilityFunctions::tan(double(pony->get(n.clip_pitch_target)));
	return pony::clamp_double(expected - pony->get_global_position().y, 0.0, double(profile->get(n.hip_height)));
}

} // namespace

void PonyClipStepNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "constants"), &PonyClipStepNative::configure);
	ClassDB::bind_method(D_METHOD("is_configured"), &PonyClipStepNative::is_configured);
	ClassDB::bind_method(D_METHOD("step", "pony", "delta"), &PonyClipStepNative::step);
	ClassDB::bind_method(D_METHOD("logic", "pony", "dt"), &PonyClipStepNative::logic);
}

void PonyClipStepNative::configure(const Dictionary &c) {
	gaits = PackedStringArray(c.get("gaits", PackedStringArray()));
	library_prefix = String(c.get("library", "baked")) + "/";
	handoff_seconds = double(c.get("handoff_seconds", 0.35));
	hidden_rig_park = bool(c.get("hidden_rig_park", true));
	logic_divisor_near = int64_t(c.get("logic_divisor", 3));
	nav_step_turn = int64_t(c.get("nav_step_turn", 2));
	motion_standing = int64_t(c.get("motion_standing", 0));
	motion_moving = int64_t(c.get("motion_moving", 2));
	tier_hero = int64_t(c.get("tier_hero", 0));
	tier_near = int64_t(c.get("tier_near", 1));
	tier_far = int64_t(c.get("tier_far", 2));
	stand = String(c.get("stand", "stand"));
	handoff = String(c.get("handoff", "handoff/crowd_handoff"));
	clip_floor_keep = int64_t(c.get("clip_floor_keep", 12));
	clip_drop_check = double(c.get("clip_drop_check", 0.5));
	walk_rate_floor = double(c.get("walk_rate_floor", 0.5));
	const Vector2 rate = c.get("rate", Vector2(0.72, 1.35));
	rate_min = rate.x;
	rate_max = rate.y;
	slow_split = double(c.get("slow_split", 1.15));
	split_margin = double(c.get("split_margin", 0.05));
	fast_split_drop = double(c.get("fast_split_drop", 0.1));
	fast_margin = double(c.get("fast_margin", 0.07));
	refusal_none = int64_t(c.get("refusal_none", 0));
	refusal_support = int64_t(c.get("refusal_support", 1));
	configured = !gaits.is_empty() && c.has("rate");
}

bool PonyClipStepNative::step(Object *object, double delta) {
	const Names &n = names();
	CharacterBody3D *pony = Object::cast_to<CharacterBody3D>(object);
	if (!configured || pony == nullptr) {
		return false;
	}
	Node3D *pivot = Object::cast_to<Node3D>(object_of(pony->get(n.pivot)));
	AnimationPlayer *animation = Object::cast_to<AnimationPlayer>(object_of(pony->get(n.animation)));
	Object *profile = object_of(pony->get(n.profile));
	if (pivot == nullptr || animation == nullptr || profile == nullptr) {
		return false; // declined before any change: the script body runs
	}

	// _clip_age += delta
	const double clip_age = double(pony->get(n.clip_age)) + delta;
	pony->set(n.clip_age, clip_age);
	// var target := 0.0 if _clip_blocked else _clip_wanted
	const double clip_wanted = double(pony->get(n.clip_wanted));
	const double target = bool(pony->get(n.clip_blocked)) ? 0.0 : clip_wanted;
	// _command_speed = move_toward(_command_speed, target, (accel if target > _command_speed else braking) * delta)
	double command_speed = double(pony->get(n.command_speed));
	const double rate_limit = double(profile->get(target > command_speed ? n.acceleration : n.braking));
	command_speed = UtilityFunctions::move_toward(command_speed, target, rate_limit * delta);
	pony->set(n.command_speed, command_speed);
	double horizontal_speed = command_speed;
	double yaw_rate = 0.0;
	pony->set(n.yaw_rate, yaw_rate);
	Vector3 travel_forward;

	// _nav_motion_live()
	bool nav_live = false;
	if (bool(pony->get(n.nav_motion))) {
		const int64_t tier = int64_t(pony->get(n.sim_tier));
		int64_t hold = 2;
		if (tier != tier_hero) {
			const int64_t logic = tier == tier_far ? std::max<int64_t>(1, int64_t(pony->get(n.far_logic_divisor))) : logic_divisor_near;
			hold = logic * std::max<int64_t>(int64_t(pony->get(n.far_tick_divisor)), 1) + 2;
		}
		if (int64_t(Engine::get_singleton()->get_physics_frames()) - int64_t(pony->get(n.nav_frame)) > hold) {
			pony->set(n.nav_motion, false);
			pony->set(n.desired, Vector3());
		} else {
			nav_live = true;
		}
	}
	if (nav_live) {
		// Navigation command: curvature at the executed speed (or a stepping turn), midpoint heading.
		const double yaw = pony->get_rotation().y;
		double rate = 0.0;
		const double nav_yaw_rate = double(pony->get(n.nav_yaw_rate));
		const double nav_speed = double(pony->get(n.nav_speed));
		if (int64_t(pony->get(n.nav_mode)) == nav_step_turn) {
			rate = nav_yaw_rate;
		} else if (nav_speed > 0.0001) {
			const double steer = double(pony->get(n.steer_turn_rate));
			rate = pony::clamp_double(nav_yaw_rate / nav_speed * horizontal_speed, -steer, steer);
		}
		yaw_rate = rate;
		pony->set(n.yaw_rate, yaw_rate);
		if (rate != 0.0) {
			Vector3 rotation = pony->get_rotation();
			rotation.y = yaw + rate * delta;
			pony->set_rotation(rotation);
		}
		travel_forward = Vector3(-UtilityFunctions::sin(yaw + rate * delta * 0.5), 0.0, -UtilityFunctions::cos(yaw + rate * delta * 0.5));
		pony->set(n.nav_executed_speed, horizontal_speed);
		pony->set(n.nav_executed_yaw_rate, rate);
	} else if (bool(pony->get(n.backing)) && clip_wanted > 0.01) {
		// Backing up keeps her heading; the clip plays in reverse (_clip_logic).
		travel_forward = pony->get_global_basis().get_column(2).normalized();
	} else if (clip_wanted > 0.01) {
		const double clip_yaw = double(pony->get(n.clip_yaw));
		const double yaw = pony->get_rotation().y;
		const double next_yaw = UtilityFunctions::rotate_toward(yaw, clip_yaw, 1.8 * delta);
		yaw_rate = UtilityFunctions::angle_difference(yaw, next_yaw) / delta;
		pony->set(n.yaw_rate, yaw_rate);
		if (next_yaw != yaw) {
			Vector3 rotation = pony->get_rotation();
			rotation.y = next_yaw;
			pony->set_rotation(rotation);
		}
		horizontal_speed *= pony::maxf(0.0, UtilityFunctions::cos(UtilityFunctions::angle_difference(pony->get_rotation().y, clip_yaw)));
	} else {
		const Vector3 face = pony->get(n.face_direction);
		if (face.length_squared() > 0.5 && !bool(pony->get(n.held)) && double(pony->get(n.collision_cooldown)) <= 0.0) {
			// A standing turn toward a face request.
			const double yaw = pony->get_rotation().y;
			const double want = UtilityFunctions::atan2(-face.x, -face.z);
			const double next_yaw = UtilityFunctions::rotate_toward(yaw, want, double(pony->get(n.face_turn_rate)) * 2.0 * delta);
			yaw_rate = UtilityFunctions::angle_difference(yaw, next_yaw) / delta;
			pony->set(n.yaw_rate, yaw_rate);
			if (next_yaw != yaw) {
				Vector3 rotation = pony->get_rotation();
				rotation.y = next_yaw;
				pony->set_rotation(rotation);
			}
		}
	}
	const Vector3 before = pony->get_global_position();
	const Vector3 forward = travel_forward != Vector3() ? travel_forward : -pony->get_global_basis().get_column(2).normalized();
	Vector3 next_position = before + forward * horizontal_speed * delta;
	const double clip_floor = double(pony->get(n.clip_floor));
	double clip_blend = double(pony->get(n.clip_blend));
	const double clip_pitch_target = double(pony->get(n.clip_pitch_target));
	if (std::isfinite(clip_floor) && !pony->has_meta(n.seated)) {
		// Between the rays, follow the measured slope from where they were cast.
		const Vector3 floor_at = pony->get(n.clip_floor_at);
		const double floor_y = clip_floor + double((next_position - floor_at).dot(forward)) * UtilityFunctions::tan(clip_pitch_target);
		if (std::abs(floor_y - next_position.y) <= double(profile->get(n.hip_height)) * 1.5) {
			next_position.y = pony::lerpf(next_position.y, floor_y, 1.0 - UtilityFunctions::exp(-delta / (clip_blend < 1.0 ? 0.3 : 0.12)));
		}
	}
	if (next_position != before) {
		pony->set_global_position(next_position);
	}
	pony->set(n.posture_pivot_settled, false);
	// Once the pitch has converged and the pivot holds it, nothing below would change.
	double clip_pitch = double(pony->get(n.clip_pitch));
	if (!(bool(pony->get(n.clip_pivot_settled)) && clip_blend >= 1.0 && clip_pitch == clip_pitch_target)) {
		pony->set(n.clip_pivot_settled, false);
		clip_pitch = pony::lerpf(clip_pitch, clip_pitch_target, 1.0 - UtilityFunctions::exp(-delta / 0.25));
		if (std::abs(clip_pitch - clip_pitch_target) < 1e-4) {
			clip_pitch = clip_pitch_target;
		}
		pony->set(n.clip_pitch, clip_pitch);
		const Transform3D clip_pivot(pony::basis_axis_angle(Vector3(1, 0, 0), clip_pitch).scaled(Vector3(1, 1, 1) * double(pony->get(n.body_scale))), Vector3());
		if (clip_blend < 1.0) {
			clip_blend = pony::minf(1.0, clip_blend + delta / handoff_seconds);
			pony->set(n.clip_blend, clip_blend);
			const Transform3D from = pony->get(n.clip_from);
			pivot->set_transform(pony::interpolate(from, clip_pivot, UtilityFunctions::smoothstep(0.0, 1.0, clip_blend)));
		} else {
			if (pivot->get_transform() != clip_pivot) {
				pivot->set_transform(clip_pivot);
			}
			pony->set(n.clip_pivot_settled, clip_pitch == clip_pitch_target);
		}
	}
	const Vector3 velocity = (pony->get_global_position() - before) / delta;
	pony->set_velocity(velocity);
	const Vector3 ground_velocity = pony->get_velocity();
	pony->set(n.ground_velocity, ground_velocity);
	pony->set(n.previous_horizontal_velocity, Vector3(ground_velocity.x, 0.0, ground_velocity.z));
	const double actual_speed = Vector2(ground_velocity.x, ground_velocity.z).length();
	pony->set(n.actual_speed, actual_speed);
	const bool moving = actual_speed > 0.05;
	pony->set(n.state, moving ? motion_moving : motion_standing);
	pony->set(n.blend, moving ? 1.0 : 0.0);
	// A settled stand is one pose, left in place by the last advance.
	const bool clip_refresh = bool(pony->get(n.clip_refresh));
	const double clip_blend_end = double(pony->get(n.clip_blend_end));
	if (clip_refresh || !bool(pony->get(n.clip_static)) || clip_age <= clip_blend_end) {
		const double advance_delta = double(pony->get(n.clip_advance_delta)) + delta;
		pony->set(n.clip_advance_delta, advance_delta);
		// A settled FAR gait poses her legs at 30 Hz, every other step of her phase group.
		const int64_t tier = int64_t(pony->get(n.sim_tier));
		if (tier == tier_far && !clip_refresh && clip_blend >= 1.0 && clip_age > clip_blend_end &&
				((int64_t(Engine::get_singleton()->get_physics_frames()) + int64_t(pony->get(n.sim_phase))) & 1) != 0 &&
				!bool(pony->call(n.needs_full_rate))) {
			return true;
		}
		pony->set(n.clip_refresh, false);
		// _advance_clip(_clip_advance_delta)
		bool deferred = false;
		const bool hidden = pony->has_meta(n.crowd_hidden);
		if (((tier == tier_far && (hidden || bool(pony->get(n.coarse_motion)))) || (hidden_rig_park && tier == tier_near && hidden)) &&
				!bool(pony->call(n.needs_full_rate))) {
			Object *posture = object_of(pony->get(n.posture));
			if ((posture == nullptr || !bool(posture->call(n.active))) && clip_blend >= 1.0 && clip_age > clip_blend_end) {
				const String gait = pony->get(n.clip_gait);
				if (gaits.has(gait) && animation->get_current_animation() == library_prefix + gait &&
						animation->get_current_animation_length() > 0.0) {
					// Only the settled, looping baked gait: keep its clock exact while hidden.
					const double at = animation->get_current_animation_position() + advance_delta * double(animation->get_playing_speed());
					animation->seek(UtilityFunctions::fposmod(at, animation->get_current_animation_length()), false);
					pony->set(n.clip_pose_deferred, true);
					deferred = true;
				}
			}
		}
		if (!deferred) {
			pony->set(n.clip_pose_deferred, false);
			animation->advance(advance_delta);
		}
		// _hoof_plants.step(self, animation, skeleton): its first line returns unless audible.
		Object *plants = object_of(pony->get(n.hoof_plants));
		if (plants != nullptr && bool(plants->get(n.audible))) {
			plants->call(n.step, pony, animation, pony->get(n.skeleton));
		}
		pony->set(n.clip_advance_delta, 0.0);
	} else {
		pony->set(n.clip_advance_delta, 0.0);
	}
	return true;
}


// pony_locomotion.gd _probe(point, rise): the bound native probe when the pony uses it (the same
// call the script makes), else the script's own ray.
Dictionary PonyClipStepNative::probe(Object *pony, const Vector3 &point, double rise) const {
	const Names &n = names();
	if (bool(pony->get(n.native_probe))) {
		PonySolverNative *solver = Object::cast_to<PonySolverNative>(object_of(pony->get(n.native)));
		if (solver != nullptr) {
			Object *profile = object_of(pony->get(n.profile));
			return solver->probe(point, rise, double(profile->get(n.hip_height)), int64_t(pony->get(n.floor_mask)),
					double(profile->get(n.max_slope_degrees)));
		}
	}
	return pony->call(n.probe, point, rise);
}

// pony_clip_tier.gd trot_band().
String PonyClipStepNative::trot_band(Object *profile, const String &gait, double speed) const {
	const Names &n = names();
	const double body = double(profile->get(n.body_scale));
	const double slow = slow_split * body;
	const double fast = double(Vector2(profile->get(n.trot_speed)).x) - fast_split_drop * body;
	const double slow_margin = split_margin * body;
	const double fast_margin_scaled = fast_margin * body;
	if (gait == "trot_slow") {
		if (speed < slow + slow_margin) {
			return gait;
		}
	} else if (gait == "trot") {
		if (speed >= slow - slow_margin && speed < fast + fast_margin_scaled) {
			return gait;
		}
	} else if (gait == "trot_fast") {
		if (speed >= fast - fast_margin_scaled) {
			return gait;
		}
	}
	if (speed < slow) {
		return "trot_slow";
	}
	return speed < fast ? "trot" : "trot_fast";
}

// pony_clip_tier.gd choose_gait().
String PonyClipStepNative::choose_gait(Object *profile, const String &gait, double wanted, double speed) const {
	const Names &n = names();
	const double gallop_entry = double(profile->get(n.gallop_entry));
	const bool gallop_ready = wanted >= gallop_entry && speed >= gallop_entry - 0.8;
	if (gait == "gallop") {
		const double gallop_exit = double(profile->get(n.gallop_exit));
		if (wanted < gallop_exit || speed < gallop_exit - 0.8) {
			return trot_band(profile, "", speed);
		}
	} else if (gait == "walk") {
		if (gallop_ready) {
			return "gallop";
		}
		if (wanted >= double(profile->get(n.trot_entry))) {
			return trot_band(profile, "", speed);
		}
	} else {
		if (gallop_ready) {
			return "gallop";
		}
		if (wanted > 0.0 && wanted < double(profile->get(n.trot_exit)) && speed < double(profile->get(n.trot_entry))) {
			return "walk";
		}
		return trot_band(profile, gait, speed);
	}
	return gait;
}

bool PonyClipStepNative::logic(Object *object, double dt) {
	const Names &n = names();
	Node3D *pony = Object::cast_to<Node3D>(object);
	if (!configured || pony == nullptr) {
		return false;
	}
	AnimationPlayer *animation = Object::cast_to<AnimationPlayer>(object_of(pony->get(n.animation)));
	Object *profile = object_of(pony->get(n.profile));
	Object *plants = object_of(pony->get(n.hoof_plants));
	if (animation == nullptr || profile == nullptr || plants == nullptr) {
		return false; // declined before any change: the script body runs
	}
	const int64_t tier = int64_t(pony->get(n.sim_tier));
	Object *secondary = nullptr;
	if (tier == tier_near) {
		secondary = object_of(pony->get(n.secondary));
		if (secondary == nullptr) {
			return false;
		}
	}

	pony->set(n.collision_cooldown, 0.0);
	// var nav_motion := _nav_motion_live()
	bool nav_motion = false;
	if (bool(pony->get(n.nav_motion))) {
		int64_t hold = 2;
		if (tier != tier_hero) {
			const int64_t logic = tier == tier_far ? std::max<int64_t>(1, int64_t(pony->get(n.far_logic_divisor))) : logic_divisor_near;
			hold = logic * std::max<int64_t>(int64_t(pony->get(n.far_tick_divisor)), 1) + 2;
		}
		if (int64_t(Engine::get_singleton()->get_physics_frames()) - int64_t(pony->get(n.nav_frame)) > hold) {
			pony->set(n.nav_motion, false);
			pony->set(n.desired, Vector3());
		} else {
			nav_motion = true;
		}
	}
	const bool stepping = nav_motion && int64_t(pony->get(n.nav_mode)) == nav_step_turn;
	if (nav_motion) {
		pony->set(n.nav_speed_scale, 1.0);
	}
	const Vector3 desired = pony->get(n.desired);
	const double clip_wanted = desired.length();
	pony->set(n.clip_wanted, clip_wanted);
	const bool backing = bool(pony->get(n.backing));
	if (clip_wanted > 0.01 && !nav_motion && !backing) {
		pony->set(n.clip_yaw, UtilityFunctions::atan2(-desired.x, -desired.z));
	}
	// No collision body here: certify support beyond the next logic step.
	bool clip_blocked = false;
	pony->set(n.clip_blocked, false);
	const double hip_height = double(profile->get(n.hip_height));
	const double travel = pony::maxf(double(pony->get(n.command_speed)), clip_wanted) * dt;
	if (clip_wanted > 0.01 && travel > 0.0) {
		const Vector3 here = pony->get_global_position();
		const Vector3 ahead = (backing ? 1.0 : -1.0) * pony->get_global_basis().get_column(2).normalized();
		const Vector3 ahead_from = pony->get(n.clip_ahead_from);
		const Vector3 ahead_dir = pony->get(n.clip_ahead_dir);
		const Vector3 moved = here - ahead_from;
		const double along = moved.dot(ahead_dir);
		if (bool(pony->get(n.clip_ahead_certified)) && int64_t(pony->get(n.clip_ahead_skips)) < 1 && double(ahead.dot(ahead_dir)) > 0.9986 &&
				along >= 0.0 && along + travel + hip_height <= double(pony->get(n.clip_ahead_reach)) &&
				double((moved - ahead_dir * along).length_squared()) < 0.0025) {
			pony->set(n.clip_ahead_skips, int64_t(pony->get(n.clip_ahead_skips)) + 1);
		} else {
			const double reach = 2.0 * travel + hip_height;
			const Vector3 point = here + ahead * reach;
			const Dictionary hit = probe(pony, point, floor_rise(pony, profile));
			double floor_y = NAN;
			if (!hit.is_empty()) {
				floor_y = Vector3(hit[n.position]).y;
			} else {
				Object *crowd = object_of(pony->get(n.crowd));
				if (crowd != nullptr) {
					floor_y = double(crowd->call(n.floor_y, point, here.y));
				}
			}
			pony->set(n.clip_ahead_certified, true);
			pony->set(n.clip_ahead_skips, 0);
			pony->set(n.clip_ahead_from, here);
			pony->set(n.clip_ahead_dir, ahead);
			pony->set(n.clip_ahead_reach, reach);
			if (!std::isfinite(floor_y) || std::abs(floor_y - here.y) > pony::maxf(double(profile->get(n.step_height)),
																					   reach * UtilityFunctions::tan(pony::deg_to_rad(double(profile->get(n.max_slope_degrees)))))) {
				clip_blocked = true;
				pony->set(n.clip_blocked, true);
				pony->set(n.clip_ahead_certified, false);
				pony->set(n.command_speed, 0.0);
			}
		}
	} else {
		pony->set(n.clip_ahead_certified, false);
	}
	if (nav_motion) {
		pony->set(n.nav_refusal, clip_blocked ? refusal_support : refusal_none);
		pony->set(n.nav_wall_normal, Vector3());
	}
	// A pony that has not moved or turned since the last rays found real collision under her keeps
	// that floor; the rays still run about every 2 s.
	const int64_t probe_logic = int64_t(pony->get(n.clip_probe_logic)) - 1;
	pony->set(n.clip_probe_logic, probe_logic);
	const double clip_blend = double(pony->get(n.clip_blend));
	const double clip_floor = double(pony->get(n.clip_floor));
	const int64_t floor_keep = int64_t(pony->get(n.clip_floor_keep));
	if (probe_logic <= 0 && clip_blend >= 1.0 && bool(pony->get(n.clip_floor_from_ray)) && std::isfinite(clip_floor) && floor_keep < clip_floor_keep &&
			double(pony->get_rotation().y) == double(pony->get(n.clip_floor_yaw)) &&
			double(pony->get_global_position().distance_squared_to(Vector3(pony->get(n.clip_floor_at)))) < 0.0025) {
		pony->set(n.clip_probe_logic, 3);
		pony->set(n.clip_floor_keep, floor_keep + 1);
	} else if (probe_logic <= 0 || clip_blend < 1.0) {
		pony->set(n.clip_probe_logic, 3);
		pony->set(n.clip_floor_keep, 0);
		pony->set(n.clip_floor_yaw, double(pony->get_rotation().y));
		const Vector3 half = -pony->get_global_basis().get_column(2).normalized() * 0.45;
		const double rise = floor_rise(pony, profile);
		Dictionary centre = probe(pony, pony->get_global_position(), rise);
		Object *crowd = object_of(pony->get(n.crowd));
		if (!centre.is_empty() && double(Vector3(centre[n.position]).y) < double(pony->get_global_position().y) - clip_drop_check && crowd != nullptr) {
			// A big drop where the walk grid knows a floor level with her: take the grid's floor.
			const double known = double(crowd->call(n.floor_y, pony->get_global_position(), double(pony->get_global_position().y)));
			if (std::isfinite(known) && known > double(Vector3(centre[n.position]).y) + clip_drop_check) {
				centre = Dictionary();
			}
		}
		pony->set(n.clip_floor_from_ray, !centre.is_empty());
		if (!centre.is_empty()) {
			pony->set(n.clip_floor, double(Vector3(centre[n.position]).y));
			const Dictionary front = probe(pony, pony->get_global_position() + half, rise);
			const Dictionary back = probe(pony, pony->get_global_position() - half, rise);
			if (!front.is_empty() && !back.is_empty()) {
				pony->set(n.clip_pitch_target, pony::clamp_double(UtilityFunctions::atan2(double(Vector3(front[n.position]).y) - double(Vector3(back[n.position]).y), 0.9), -0.4, 0.4));
			}
		} else {
			const double floor_value = crowd != nullptr ? double(crowd->call(n.floor_y, pony->get_global_position(), double(pony->get_global_position().y))) : NAN;
			pony->set(n.clip_floor, floor_value);
			if (std::isfinite(floor_value) && crowd != nullptr) {
				const double front_y = double(crowd->call(n.floor_y, pony->get_global_position() + half, floor_value));
				const double back_y = double(crowd->call(n.floor_y, pony->get_global_position() - half, floor_value));
				if (std::isfinite(front_y) && std::isfinite(back_y)) {
					pony->set(n.clip_pitch_target, pony::clamp_double(UtilityFunctions::atan2(front_y - back_y, 0.9), -0.4, 0.4));
				}
			}
		}
		pony->set(n.clip_floor_at, pony->get_global_position());
	}
	// Gait: the solver's bands and hysteresis.
	const double gait_hold = pony::maxf(0.0, double(pony->get(n.clip_gait_hold)) - dt);
	pony->set(n.clip_gait_hold, gait_hold);
	const double clip_age = double(pony->get(n.clip_age));
	const double clip_blend_end = double(pony->get(n.clip_blend_end));
	if (clip_age > pony::maxf(handoff_seconds + 0.15, clip_blend_end + 0.1) && animation->get_current_animation() != handoff &&
			animation->has_animation_library(n.handoff_library) && animation->get_animation_library(n.handoff_library)->has_animation(n.handoff_clip)) {
		animation->get_animation_library(n.handoff_library)->remove_animation(n.handoff_clip);
	}
	const double actual_speed = double(pony->get(n.actual_speed));
	const bool moving = actual_speed > 0.05 || double(pony->get(n.command_speed)) > 0.05 || stepping;
	String clip_gait = pony->get(n.clip_gait);
	if (moving && gait_hold <= 0.0) {
		double gait_wanted = clip_wanted;
		if (stepping) {
			gait_wanted = Vector2(profile->get(n.walk_speed)).x;
		} else if (nav_motion && clip_wanted > 0.0) {
			gait_wanted = pony::maxf(clip_wanted, double(pony->get(n.nav_gait_speed)));
		}
		const String chosen = choose_gait(profile, clip_gait, gait_wanted, actual_speed);
		if (chosen != clip_gait) {
			clip_gait = chosen;
			pony->set(n.clip_gait, clip_gait);
			pony->set(n.clip_gait_hold, double(profile->get(n.gait_hold_seconds)));
		}
	}
	const String clip = library_prefix + (moving ? clip_gait : stand);
	if (animation->get_current_animation() != clip) {
		const String current = animation->get_current_animation();
		const bool from_handoff = current == handoff;
		double at = from_handoff ? double(pony->get(n.clip_enter_phase)) : 0.0;
		// _clip_gait_playing()
		if (current.begins_with(library_prefix) && !current.ends_with("/" + stand) && animation->get_current_animation_length() > 0.0) {
			at = animation->get_current_animation_position() / animation->get_current_animation_length();
		}
		const double blend = from_handoff ? handoff_seconds : double(profile->get(n.gait_blend_seconds));
		animation->play(clip, blend);
		pony->set(n.clip_blend_end, clip_age + blend / walk_rate_floor);
		if (moving) {
			animation->seek(UtilityFunctions::fposmod(at, 1.0) * animation->get_current_animation_length(), false);
		}
	}
	pony->set(n.clip_static, !moving);
	// BAKED_GAITS.speed(_baked, _clip_gait) * profile.body_scale
	double baked_speed = 1.0;
	Object *library = object_of(pony->get(n.baked));
	if (library != nullptr) {
		baked_speed = double(Dictionary(library->get_meta(n.speeds, Dictionary())).get(clip_gait, 1.0));
	} else {
		return false; // unreachable in the game (no clip tier without baked clips); the script would error
	}
	const double clip_speed = baked_speed * double(profile->get(n.body_scale));
	double speed_scale = 1.0;
	if (moving && clip_speed > 0.0) {
		speed_scale = pony::clamp_double(actual_speed / clip_speed, clip_gait == "walk" ? walk_rate_floor : rate_min, rate_max);
	}
	animation->set_speed_scale(speed_scale);
	if (stepping && actual_speed < 0.05) {
		animation->set_speed_scale(0.5);
	}
	if (backing && moving) {
		animation->set_speed_scale(-std::abs(animation->get_speed_scale()));
	}
	plants->call(n.logic, pony, tier == tier_near);
	if (tier == tier_near) {
		// The live head: the secondary's breath, give and gaze at this logic tick.
		const String current = animation->get_current_animation();
		double stride = double(pony->get(n.phase));
		if (current.begins_with(library_prefix) && !current.ends_with("/" + stand) && animation->get_current_animation_length() > 0.0) {
			stride = animation->get_current_animation_position() / animation->get_current_animation_length();
		}
		secondary->call(n.update, dt, stride, pony::clamp_double(actual_speed / double(profile->get(n.nominal_speed)), 0.0, 1.0), 1.0,
				double(profile->get(n.sway_amount)), hip_height, Vector3(), 1.0);
		pony->set(n.clip_head_from, pony->get(n.clip_head_to));
		PackedVector3Array head;
		head.push_back(secondary->get(n.head_angles));
		head.push_back(secondary->get(n.gaze_angles));
		head.push_back(secondary->get(n.neck_gaze));
		pony->set(n.clip_head_to, head);
	}
	return true;
}

} // namespace godot
