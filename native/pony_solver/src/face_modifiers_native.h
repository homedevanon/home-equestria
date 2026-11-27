// Native pony step, lane `face` (captures/perf_2026-11-21/NATIVE_PONY_DESIGN.md, Form 1).
//
// PonyEyeMotionNative is the base class of world/characters/openpony/openpony_eye_motion.gd and
// PonyMouthNative the base class of world/characters/openpony/pony_mouth.gd. Each holds the
// script's hot state as properties with the script's own names, and runs the script's per-step
// body (`native_step`) and its logic-tick clock (`native_advance`, `native_advance_weights`) line
// for line: the same types (double scalars, single-precision vectors), the same order of
// operations and the engine's own functions for everything transcendental, so the result is bit
// for bit the script's. The scripts keep their bodies as the fallback (switch NATIVE_STEP).
#pragma once

#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton_modifier3d.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <string>
#include <utility>
#include <vector>

namespace godot {

class Skeleton3D;

// A plain field bound as a property: get_<member>() / set_<member>().
#define FACE_FIELD(m_type, m_member, m_default) \
	m_type m_member = m_default; \
	m_type get_##m_member() const { return m_member; } \
	void set_##m_member(m_type p_value) { m_member = p_value; }

class PonyEyeMotionNative : public SkeletonModifier3D {
	GDCLASS(PonyEyeMotionNative, SkeletonModifier3D)

public:
	// Script names in comments where they differ.
	Ref<RefCounted> solver; // native (PonySolverNative or null)
	FACE_FIELD(double, convergence_degrees, 5.0)
	FACE_FIELD(double, closure, 0.0)
	FACE_FIELD(double, expression_closure, 0.0)
	FACE_FIELD(Dictionary, expression_brows, Dictionary())
	FACE_FIELD(Dictionary, expression_eyes, Dictionary())
	FACE_FIELD(Dictionary, expression_ears, Dictionary())
	FACE_FIELD(Vector2, gaze, Vector2())
	FACE_FIELD(Callable, surface_update, Callable())
	FACE_FIELD(Vector3, target_world, Vector3())
	FACE_FIELD(double, target_weight, 0.0)
	FACE_FIELD(bool, saccades_enabled, true)
	FACE_FIELD(int64_t, rate_divisor, 1)
	FACE_FIELD(int64_t, rate_phase, 0)
	ObjectID player; // _player
	FACE_FIELD(bool, blink_enabled, true)
	FACE_FIELD(double, blink_strength, 1.0)
	FACE_FIELD(int64_t, head_bone, -1) // _head_bone
	Ref<RandomNumberGenerator> rng; // _rng
	FACE_FIELD(double, wait, 2.0) // _wait
	FACE_FIELD(Vector2, from, Vector2()) // _from
	FACE_FIELD(Vector2, to, Vector2()) // _to
	FACE_FIELD(Vector2, offset, Vector2()) // _offset
	FACE_FIELD(Vector2, scan_offset, Vector2()) // _scan_offset
	FACE_FIELD(double, fixation, 0.0) // _fixation
	FACE_FIELD(double, elapsed, 1.0) // _elapsed
	FACE_FIELD(double, duration, 0.08) // _duration
	FACE_FIELD(double, blink_wait, 3.0) // _blink_wait
	FACE_FIELD(double, blink_time, -1.0) // _blink_time
	FACE_FIELD(double, blink_close, 0.13) // _blink_close
	FACE_FIELD(double, blink_hold, 0.025) // _blink_hold
	FACE_FIELD(double, blink_open, 0.23) // _blink_open
	FACE_FIELD(bool, paired_blink, false) // _paired_blink
	float mood[8]; // _mood (PackedFloat32Array)
	float mood_goal[8]; // _mood_goal
	FACE_FIELD(Vector2, focus_from, Vector2()) // _focus_from
	FACE_FIELD(Vector2, focus_to, Vector2()) // _focus_to
	FACE_FIELD(Vector2, focus_offset, Vector2()) // _focus_offset
	FACE_FIELD(double, focus_elapsed, 1.0) // _focus_elapsed
	FACE_FIELD(double, focus_duration, 0.05) // _focus_duration
	FACE_FIELD(double, focus_wait, 0.3) // _focus_wait
	FACE_FIELD(int64_t, focus_point, -1) // _focus_point
	FACE_FIELD(double, glance_left, -1.0) // _glance_left
	FACE_FIELD(Vector2, drift, Vector2()) // _drift
	FACE_FIELD(Vector2, drift_goal, Vector2()) // _drift_goal
	FACE_FIELD(int64_t, focus_saccades, 0)
	FACE_FIELD(int64_t, focus_glances, 0)
	FACE_FIELD(double, cross_inward, 0.0)

private:
	// Set by native_reset() from bind(): `not _rest_globals.is_empty()`, and the script this
	// node had (only openpony_eye_motion.gd itself runs the native step).
	bool rest_bound = false;
	ObjectID own_script;
	// The script's _last_inputs, typed. has_last false = [] (never reused).
	bool has_last = false;
	double last_closure = 0.0;
	double last_expression_closure = 0.0;
	double last_target_weight = 0.0;
	double last_convergence = 0.0;
	Vector2 last_gaze;
	Vector2 last_offset;
	double last_cross_inward = 0.0;
	Vector3 last_target;
	Transform3D last_aim_frame;
	Dictionary last_eyes;
	Dictionary last_brows;
	Dictionary last_ears;
	Callable last_surface_update;

	bool script_ok() const;
	void advance_focus(double p_delta);
	void focus_start();
	double face_spacing();

protected:
	static void _bind_methods();

public:
	PonyEyeMotionNative();

	Ref<RefCounted> get_solver() const { return solver; }
	void set_solver(const Ref<RefCounted> &p_value) { solver = p_value; }
	Object *get_player() const;
	void set_player(Object *p_value);
	Ref<RandomNumberGenerator> get_rng() const { return rng; }
	void set_rng(const Ref<RandomNumberGenerator> &p_value) { rng = p_value; }
	PackedFloat32Array get_mood() const;
	void set_mood(const PackedFloat32Array &p_value);
	PackedFloat32Array get_mood_goal() const;
	void set_mood_goal(const PackedFloat32Array &p_value);

	// bind(): forget the last inputs; `rest_bound` = not _rest_globals.is_empty(); `base` = the
	// node runs openpony_eye_motion.gd itself (not a subclass).
	void native_reset(bool p_rest_bound, bool p_base);
	// _unprofiled_process_modification(); false (nothing changed) when the script must run it.
	bool native_step(bool p_reuse_unchanged);
	// advance(delta).
	bool native_advance(double p_delta);
};

class PonyMouthNative : public SkeletonModifier3D {
	GDCLASS(PonyMouthNative, SkeletonModifier3D)

public:
	FACE_FIELD(int64_t, rate_divisor, 1)
	FACE_FIELD(int64_t, rate_phase, 0)
	FACE_FIELD(double, blend_time, 0.06)
	FACE_FIELD(bool, mix_valid, false) // _mix_valid
	FACE_FIELD(double, mix_influence, 1.0) // _mix_influence
	FACE_FIELD(Callable, lip_open_changed, Callable())
	FACE_FIELD(Callable, lip_tone_changed, Callable())
	FACE_FIELD(bool, lip_open, false) // _lip_open
	FACE_FIELD(double, lip_tone, 0.0) // _lip_tone

private:
	struct Shape {
		bool present = false;
		std::vector<int32_t> slot; // bone -> index into q/p, -1 when the shape leaves it
		std::vector<Quaternion> q;
		std::vector<Vector3> p;
	};
	// Shape names seen so far (interned ids); `shapes` is indexed by the same id.
	std::vector<std::u32string> names;
	std::vector<Shape> shapes;
	std::vector<int32_t> bones; // _bones
	// _targets and _weights in Dictionary order: (name id, weight).
	std::vector<std::pair<int32_t, double>> targets;
	std::vector<std::pair<int32_t, double>> weights;
	// The mix cache (_mix_bones, _mix_rotations, _mix_offsets).
	std::vector<int32_t> mix_bones;
	std::vector<Quaternion> mix_rotations;
	std::vector<Vector3> mix_offsets;
	// The native step's last full-run writes (the script keeps its own _written_* for its body).
	std::vector<int32_t> written_bones;
	std::vector<Quaternion> written_rotations;
	std::vector<Vector3> written_positions;
	// The script's constants, handed over by native_bind().
	double open_rate = 3.4;
	double close_rate = 1.8;
	double settle = 0.004;
	double speech_open_at = 0.05;
	double lip_tone_step = 0.05;
	std::vector<int32_t> speech_open;
	std::vector<std::pair<int32_t, double>> lip_tone_shares;
	ObjectID own_script;

	int32_t name_id(const String &p_name);
	static int find(const std::vector<std::pair<int32_t, double>> &p_list, int32_t p_id);
	static double value_of(const std::vector<std::pair<int32_t, double>> &p_list, int32_t p_id);
	Dictionary to_dictionary(const std::vector<std::pair<int32_t, double>> &p_list) const;
	void from_dictionary(const Dictionary &p_value, std::vector<std::pair<int32_t, double>> &r_list);
	bool script_ok() const;
	void update_lip_open();
	void build_mix(double p_influence);

protected:
	static void _bind_methods();

public:
	Dictionary get_targets() const { return to_dictionary(targets); }
	void set_targets(const Dictionary &p_value) { from_dictionary(p_value, targets); }
	Dictionary get_weights() const { return to_dictionary(weights); }
	void set_weights(const Dictionary &p_value) { from_dictionary(p_value, weights); }
	PackedInt32Array get_mix_bones() const;
	void set_mix_bones(const PackedInt32Array &p_value);
	Array get_mix_rotations() const;
	void set_mix_rotations(const Array &p_value);
	PackedVector3Array get_mix_offsets() const;
	void set_mix_offsets(const PackedVector3Array &p_value);

	// build(): the sampled shapes and their bones, and the script constants
	// [OPEN_RATE, CLOSE_RATE, SETTLE, SPEECH_OPEN_AT, LIP_TONE_STEP], SPEECH_OPEN, LIP_TONE.
	// `base` = the node runs pony_mouth.gd itself (not a subclass).
	void native_bind(const Dictionary &p_shapes, const PackedInt32Array &p_bones, const PackedFloat64Array &p_constants,
			const Array &p_speech_open, const Dictionary &p_lip_tone, bool p_base);
	// _retarget(blend) after the expression scale: _targets from the viseme targets and the
	// expression layer; with blend 0, _weights jump there and the lip callbacks run.
	void native_retarget(const Dictionary &p_viseme_targets, const Dictionary &p_expression, double p_expression_scale,
			double p_blend);
	// advance_weights(delta).
	bool native_advance_weights(double p_delta);
	// _update_lip_open().
	void native_update_lip_open() { update_lip_open(); }
	// _unprofiled_process_modification(); false (nothing changed) when the script must run it.
	bool native_step(bool p_mix_cache);
};

#undef FACE_FIELD

} // namespace godot
