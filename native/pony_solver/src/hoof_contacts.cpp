// pony_locomotion.gd _update_contacts() for a free-standing pony (not held, no hoof held),
// line for line, split at its two terrain probes. The probes stay in GDScript (physics-server
// calls): contacts_begin() returns the four reference points, GDScript probes them;
// contacts_plant() returns the re-sample points of planted hooves (and the hoof_planted
// positions to emit), GDScript probes those; contacts_finish() completes the feet. Probe order
// changes (all references first, then all re-samples) but a ray query only reads the physics
// space, so every hit is the same. Foot state is read and written in the feet dictionaries.
#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

using namespace godot;
using namespace pony;

namespace {

struct Keys {
	const Variant age = StringName("age");
	const Variant dynamic_sole = StringName("dynamic_sole");
	const Variant turn_prediction = StringName("turn_prediction");
	const Variant landing = StringName("landing");
	const Variant landing_normal = StringName("landing_normal");
	const Variant landing_valid = StringName("landing_valid");
	const Variant landing_predicted = StringName("landing_predicted");
	const Variant limited = StringName("limited");
	const Variant normal = StringName("normal");
	const Variant lock = StringName("lock");
	const Variant lock_normal = StringName("lock_normal");
	const Variant planted = StringName("planted");
	const Variant valid = StringName("valid");
	const Variant weight = StringName("weight");
	const Variant offset = StringName("offset");
	const Variant target = StringName("target");
	const Variant basis = StringName("basis");
	const Variant position = StringName("position");
};

const Keys &keys() {
	static const Keys k;
	return k;
}

const Vector3 UP(0, 1, 0);

// predict_turn_transform()
Transform3D predict_turn_transform(const Transform3D &current, double speed, double yaw_rate, double seconds) {
	const double duration = clamp_double(seconds, 0.0, 0.45);
	const double yaw = clamp_double(yaw_rate * duration, -deg_to_rad(50.0), deg_to_rad(50.0));
	const Basis rotation = basis_axis_angle(UP, yaw);
	const Vector3 forward = -current.basis.get_column(2).normalized();
	const Vector3 midpoint_forward = basis_axis_angle(UP, yaw * 0.5).xform(forward);
	return Transform3D(rotation * current.basis,
			current.origin + midpoint_forward * (real_t)maxf(speed, 0.0) * (real_t)duration);
}

} // namespace

// Leg constants, once per gait profile: [leaf, end] per leg, end_height per leg, sole_basis per leg.
void PonySolverNative::bind_contact_legs(const PackedInt32Array &p_bones, const PackedFloat64Array &p_end_heights,
		const Array &p_sole_bases) {
	ERR_FAIL_COND(p_bones.size() != 8 || p_end_heights.size() != 4 || p_sole_bases.size() != 4);
	contact_fk_bones.clear();
	for (int i = 0; i < 4; i++) {
		contact_legs[i].leaf = p_bones[i * 2];
		contact_legs[i].end = p_bones[i * 2 + 1];
		contact_legs[i].end_height = p_end_heights[i];
		contact_legs[i].sole_basis = p_sole_bases[i];
	}
}

// Everything before the first probe. `timing` per foot: stride amount (stride_offset * blend),
// airborne (0/1), turn prediction (0/1), touchdown seconds (min(0.45, ...), used with the
// prediction), contact weight (leg_contact_weight, or 1 when blend <= 0).
// `motion`: actual_speed, yaw_rate.
PackedVector3Array PonySolverNative::contacts_begin(const Array &p_source_pose, const Array &p_feet,
		const Transform3D &p_global, const Transform3D &p_pivot, const Transform3D &p_model_frame, double p_delta,
		const PackedFloat64Array &p_timing, const PackedFloat64Array &p_motion) {
	PackedVector3Array references;
	ERR_FAIL_COND_V(p_feet.size() != 4 || p_timing.size() != 20 || p_motion.size() != 2, references);
	const Keys &k = keys();
	const double actual_speed = p_motion[0];
	const double yaw_rate = p_motion[1];
	// local_fk and adapted_fk: the same products as limb_solver.gd forward_kinematics().
	// Contacts consume only eight endpoints. Cache their ancestor union instead of
	// transforming unrelated face, wing and accessory bones twice every solve.
	const int64_t count = p_source_pose.size();
	ERR_FAIL_COND_V(count != (int64_t)parents.size(), references);
	if (contact_fk_bones.empty()) {
		std::vector<uint8_t> needed(count, 0);
		for (const ContactLeg &leg : contact_legs) {
			for (int32_t tip : { leg.leaf, leg.end }) {
				for (int32_t bone = tip; bone >= 0; bone = parents[bone]) {
					ERR_FAIL_COND_V(bone >= count, references);
					if (needed[bone]) {
						break;
					}
					// The original full FK also requires parents before children.
					ERR_FAIL_COND_V(parents[bone] >= bone, references);
					needed[bone] = 1;
				}
			}
		}
		for (int32_t i = 0; i < count; i++) {
			if (needed[i]) {
				contact_fk_bones.push_back(i);
			}
		}
	}
	contact_local_fk.resize(count);
	contact_adapted_fk.resize(count);
	const Transform3D frame = p_global * p_pivot * p_model_frame;
	for (int32_t i : contact_fk_bones) {
		const Transform3D local = p_source_pose[i];
		const int32_t parent = parents[i];
		contact_local_fk[i] = (parent < 0 ? Transform3D() : contact_local_fk[parent]) * local;
		contact_adapted_fk[i] = (parent < 0 ? frame : contact_adapted_fk[parent]) * local;
	}
	contact_frame = frame;
	const Vector3 stride_axis = p_global.basis.get_column(2).normalized();
	for (int i = 0; i < 4; i++) {
		ContactLeg &leg = contact_legs[i];
		ContactFoot &c = contact_feet[i];
		Dictionary foot = p_feet[i];
		foot[k.age] = (double)foot[k.age] + p_delta;
		c.local_sole = contact_local_fk[leg.end].origin - UP * (real_t)leg.end_height;
		foot[k.dynamic_sole] = contact_local_fk[leg.leaf].affine_inverse().xform(c.local_sole);
		c.source_sole = frame.xform(c.local_sole);
		const double stride_amount = p_timing[i * 5];
		c.airborne = p_timing[i * 5 + 1] != 0.0;
		const bool predict = p_timing[i * 5 + 2] != 0.0;
		const double touchdown = p_timing[i * 5 + 3];
		c.contact_weight = p_timing[i * 5 + 4];
		c.stride_offset = stride_axis * (real_t)stride_amount;
		const Vector3 flat(c.local_sole.x, 0.0, c.local_sole.z);
		c.reference = frame.xform(flat) + c.stride_offset;
		const Vector3 current_reference = c.reference;
		foot[k.turn_prediction] = Vector3();
		if (predict) {
			const Transform3D predicted_root = predict_turn_transform(p_global, actual_speed, yaw_rate, touchdown);
			const Transform3D predicted_frame = predicted_root * p_pivot * p_model_frame;
			c.reference = predicted_frame.xform(flat) + predicted_root.basis.get_column(2).normalized() * (real_t)stride_amount;
			foot[k.turn_prediction] = c.reference - current_reference;
		}
		c.previous_landing = foot[k.landing];
		c.previous_landing_normal = foot[k.landing_normal];
		c.previous_landing_valid = (bool)foot[k.landing_valid] && (bool)foot[k.landing_predicted];
		references.push_back(c.reference);
	}
	return references;
}

// From the first probe to the second. `hits` are the four probe dictionaries ({} for none).
// `state`: state, STANDING, STOPPING. `scalars`: blend, spawn_settle, body_scale, hip_height,
// seconds_since_switch, gait_blend_seconds. Returns [re-sample points, which feet re-sample
// (PackedByteArray), hoof_planted positions, the hoof index of each of those positions
// (PackedInt32Array)]. The indices (2026-11-08) let the caller hand each plant to its own hoof:
// a gait switch can unplant that same foot later in this pass, and matching a position to the
// nearest planted lock then gave the plant (and its sound) to another hoof.
Array PonySolverNative::contacts_plant(const Array &p_feet, const Array &p_hits, const PackedInt32Array &p_state,
		const PackedFloat64Array &p_scalars) {
	Array result;
	ERR_FAIL_COND_V(p_feet.size() != 4 || p_hits.size() != 4 || p_state.size() != 3 || p_scalars.size() != 6, result);
	const Keys &k = keys();
	const int32_t state = p_state[0];
	const int32_t standing = p_state[1];
	const int32_t stopping = p_state[2];
	const double blend = p_scalars[0];
	const double spawn_settle = p_scalars[1];
	const double body_scale = p_scalars[2];
	const double hip_height = p_scalars[3];
	const double seconds_since_switch = p_scalars[4];
	const double gait_blend_seconds = p_scalars[5];
	const Vector3 frame_up = contact_frame.basis.get_column(1).normalized();
	PackedVector3Array points;
	PackedByteArray probe;
	PackedVector3Array planted_at;
	PackedInt32Array planted_hoof;
	for (int i = 0; i < 4; i++) {
		ContactFoot &c = contact_feet[i];
		Dictionary foot = p_feet[i];
		const Dictionary hit = p_hits[i];
		c.hit = !hit.is_empty();
		if (c.hit) {
			c.hit_position = hit[k.position];
			c.hit_normal = hit[k.normal];
		}
		const double weight = blend > 0.0 ? lerpf(1.0, c.contact_weight, blend) : 1.0;
		c.weight = weight;
		Vector3 desired_offset;
		foot[k.limited] = false;
		foot[k.landing_valid] = c.hit;
		foot[k.landing_predicted] = false;
		if (c.hit) {
			foot[k.landing] = c.hit_position;
			foot[k.landing_normal] = c.hit_normal;
			foot[k.landing_predicted] = c.airborne;
			foot[k.normal] = c.hit_normal;
			desired_offset = c.hit_position - c.reference;
			const double limit = hip_height * 0.14 * body_scale;
			foot[k.limited] = desired_offset.length() > limit;
			desired_offset = desired_offset.limit_length(limit);
			desired_offset -= frame_up * (real_t)maxf(c.local_sole.y, 0.0) * (real_t)weight;
		}
		desired_offset += c.stride_offset;
		const bool loaded = state == standing || (blend > 0.999 && state != stopping && weight > 0.7);
		bool planted;
		if (loaded && c.hit) {
			if (state == standing && spawn_settle > 0.0) {
				foot[k.lock] = c.hit_position;
				foot[k.lock_normal] = c.hit_normal;
			}
			if (!(bool)foot[k.planted]) {
				foot[k.lock] = c.previous_landing_valid ? c.previous_landing : c.hit_position;
				foot[k.lock_normal] = c.previous_landing_valid ? c.previous_landing_normal : c.hit_normal;
				foot[k.age] = 0.0;
				if (state != standing) {
					planted_at.push_back(c.hit_position);
					planted_hoof.push_back(i);
				}
			}
			planted = true;
			foot[k.valid] = true;
			foot[k.landing_predicted] = false;
		} else {
			planted = false;
			foot[k.valid] = c.hit;
		}
		foot[k.planted] = planted;
		foot[k.weight] = weight;
		c.resample = false;
		if (planted && state != standing) {
			const Vector3 lock = foot[k.lock];
			Vector3 horizontal_lock = lock - (c.source_sole + desired_offset);
			horizontal_lock.y = 0.0;
			if (horizontal_lock.length() > 0.3 * body_scale && seconds_since_switch < gait_blend_seconds * 2.0) {
				planted = false;
				foot[k.planted] = false;
				foot[k.valid] = c.hit;
				horizontal_lock = Vector3();
			}
			desired_offset += horizontal_lock.limit_length(0.12 * body_scale);
			c.resample = true;
		}
		c.planted = planted;
		c.desired_offset = desired_offset;
		points.push_back(c.source_sole + desired_offset);
		probe.push_back(c.resample ? 1 : 0);
	}
	result.push_back(points);
	result.push_back(probe);
	result.push_back(planted_at);
	result.push_back(planted_hoof);
	return result;
}

// After the second probe. `contacts` holds the re-sample dictionaries ({} where none was taken
// or nothing was hit). `state`: state, STANDING.
void PonySolverNative::contacts_finish(const Array &p_feet, const Array &p_contacts, double p_delta,
		const PackedInt32Array &p_state, const Transform3D &p_global, const Transform3D &p_model_frame) {
	ERR_FAIL_COND(p_feet.size() != 4 || p_contacts.size() != 4 || p_state.size() != 2);
	const Keys &k = keys();
	const int32_t state = p_state[0];
	const int32_t standing = p_state[1];
	const Vector3 frame_up = contact_frame.basis.get_column(1).normalized();
	const double frame_up_y = contact_frame.basis.get_column(1).y;
	for (int i = 0; i < 4; i++) {
		ContactLeg &leg = contact_legs[i];
		ContactFoot &c = contact_feet[i];
		Dictionary foot = p_feet[i];
		if (c.resample) {
			const Dictionary contact = p_contacts[i];
			if (!contact.is_empty()) {
				const Vector3 position = contact[k.position];
				c.desired_offset.y = (real_t)((double)position.y - (double)c.source_sole.y);
				c.desired_offset.y = (real_t)((double)c.desired_offset.y + maxf(c.local_sole.y, 0.0) * (1.0 - c.weight) * frame_up_y);
				foot[k.normal] = contact[k.normal];
				foot[k.landing] = position;
				c.hit = true;
				c.hit_position = position;
				c.hit_normal = contact[k.normal];
			}
		}
		const double contact_response = c.planted ? 0.02 : 0.045;
		const Vector3 previous = foot[k.offset];
		Vector3 offset = previous.lerp(c.desired_offset, (real_t)(1.0 - engine_exp(-p_delta / contact_response)));
		foot[k.offset] = offset;
		foot[k.target] = c.source_sole + offset;
		Basis basis = contact_adapted_fk[leg.leaf].basis.orthonormalized();
		const bool standing_contact = c.planted && state == standing;
		if (standing_contact) {
			const Vector3 lock = foot[k.lock];
			foot[k.target] = lock;
			foot[k.offset] = lock - c.source_sole;
			const Vector3 lock_normal = foot[k.lock_normal];
			foot[k.normal] = lock_normal;
			basis = Basis(shortest_arc(UP, lock_normal)) * p_global.basis.orthonormalized() *
					p_model_frame.basis.orthonormalized() * leg.sole_basis;
		}
		if (c.hit && !standing_contact) {
			const double angle = minf(vector_angle(frame_up, c.hit_normal), deg_to_rad(12.0)) * c.weight;
			const Vector3 axis = frame_up.cross(c.hit_normal);
			if (axis.length_squared() > 1e-10) {
				basis = basis_axis_angle(axis.normalized(), angle) * basis;
			}
		}
		foot[k.basis] = basis;
	}
}
