// The clip tiers' walking step in C++ (native pony step port 2026-11-21, lane `step`;
// captures/perf_2026-11-21/port_step.md, NATIVE_PONY_DESIGN.md).
//
// world/characters/locomotion/pony_locomotion.gd keeps its base (CharacterBody3D: a native base class
// would break every pony scene and the anonfilly mod's scene, which name CharacterBody3D) and holds one
// PonyClipStepNative per pony (Form 2 of the design). With NATIVE_CLIP_STEP on, the script's
// _clip_step() first calls step(self, delta): the same statements as the script's _clip_step() and
// _advance_clip() in the same order, with the same engine calls (rotation, global_position, pivot,
// AnimationPlayer advance/seek) and the same float types and operation order, so the result is
// bit-identical. The pony's members stay script variables; step() reads and writes the ones it needs
// by name (cached StringNames). It returns false before changing anything when the pony lacks a
// pivot, an AnimationPlayer or a gait profile; the script body then runs as before.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class PonyClipStepNative : public RefCounted {
	GDCLASS(PonyClipStepNative, RefCounted)

	// Constants of the script (configure()), so there is one source of truth for each.
	PackedStringArray gaits; // baked_gaits.gd GAITS
	String library_prefix = "baked/"; // String(BAKED_GAITS.LIBRARY) + "/"
	double handoff_seconds = 0.35; // CLIP_HANDOFF_SECONDS
	bool hidden_rig_park = true; // HIDDEN_RIG_PARK
	int64_t logic_divisor_near = 3; // LOGIC_DIVISOR
	int64_t nav_step_turn = 2; // NAV_MODE_STEP_TURN
	int64_t motion_standing = 0; // Motion.STANDING
	int64_t motion_moving = 2; // Motion.MOVING
	int64_t tier_hero = 0; // SimTier.HERO
	int64_t tier_near = 1; // SimTier.NEAR
	int64_t tier_far = 2; // SimTier.FAR
	// _clip_logic() constants.
	String stand = "stand"; // BAKED_GAITS.STAND
	String handoff = "handoff/crowd_handoff"; // HANDOFF
	int64_t clip_floor_keep = 12; // CLIP_FLOOR_KEEP
	double clip_drop_check = 0.5; // CLIP_DROP_CHECK
	double walk_rate_floor = 0.5; // CLIP_TIER.WALK_RATE_FLOOR
	double rate_min = 0.72; // CLIP_TIER.RATE.x (a 32-bit float widened, as GDScript reads it)
	double rate_max = 1.35; // CLIP_TIER.RATE.y
	double slow_split = 1.15; // CLIP_TIER.SLOW_SPLIT
	double split_margin = 0.05; // CLIP_TIER.SPLIT_MARGIN
	double fast_split_drop = 0.1; // CLIP_TIER.FAST_SPLIT_DROP
	double fast_margin = 0.07; // CLIP_TIER.FAST_MARGIN
	int64_t refusal_none = 0; // NAV_REFUSAL_NONE
	int64_t refusal_support = 1; // NAV_REFUSAL_SUPPORT
	bool configured = false;

	String choose_gait(Object *profile, const String &gait, double wanted, double speed) const;
	String trot_band(Object *profile, const String &gait, double speed) const;
	Dictionary probe(Object *pony, const Vector3 &point, double rise) const;

protected:
	static void _bind_methods();

public:
	// The script's constants, once per pony (pony_locomotion.gd _clip_step_native()).
	void configure(const Dictionary &constants);
	bool is_configured() const { return configured; }
	// pony_locomotion.gd _clip_step(delta) and _advance_clip(); false (nothing changed) to decline.
	bool step(Object *pony, double delta);
	// pony_locomotion.gd _clip_logic(dt); false (nothing changed) to decline.
	bool logic(Object *pony, double dt);
};

} // namespace godot
