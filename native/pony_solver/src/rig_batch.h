// Close ponies' body skeleton modifiers in one native batch (perf overhaul 2026-11-21, lane
// rig_batch; captures/perf_2026-11-21/rig_batch.md).
//
// Each step, after every pose writer (world/characters/hybrid_mare/rig_batch.gd, physics priority
// 900000), PonyRigBatch::step():
//   1. main thread: for every bound NEAR pony, checks that she may use the batch (her rigs hold
//      only game-owned modifiers and listeners, every active modifier on her body rig is one of the
//      four ported below, no contact, kiss, cuddle, carry, conversation or camera within reach) and
//      gathers what those modifiers read: her body rig's plain bone poses (the pose the engine's
//      update starts from), the scripts' inputs and eased state;
//   2. worker threads (caller runs the first block): the four body modifiers in rig order, on plain
//      structs only, the same formulas as the scripts:
//        pony_clip_head.gd (face.cpp clip_head), pony_idle_body.gd, filly_proportions.gd and the
//        fidget part of affection_pose.gd (buck, stretch, yawn); a kiss, lean or rear keeps her on
//        the script path;
//   3. main thread: writes the idle body's eased state back into its script, and stamps every
//      ported script's `rig_batch_step` so the script's first line returns this step.
// The results are written inside the engine's own body update by PonyRigBatchApply, a native
// SkeletonModifier3D on her body rig, so the engine reverts them after the skin push exactly as it
// reverts the scripts' writes, and nothing outside the update ever sees a modified pose. The neck
// and hair links (hybrid_neck_link.gd, hybrid_hair_link.gd) run as native skeleton_updated handlers
// on the main thread for batched ponies: they are engine reads and writes of three or four bones,
// and running them inside the same signal keeps "they run exactly when the update emits" true.
//
// No worker touches a Skeleton3D, a node, a resource or the RenderingServer. Joint limits are read
// from the same PonySolverNative object the scripts call (pony._native, bound by
// pony_joint_limits.gd bind_native()); a pony whose limits were rebound and not yet copied
// (`_native_constrain` false) stays on the script path.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton_modifier3d.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class Node;
class Skeleton3D;
class PonySolverNative;

class PonyRigBatch : public RefCounted {
	GDCLASS(PonyRigBatch, RefCounted)

public:
	// One bone of the body rig the modifiers read or write, with its plain pose as the engine
	// stores it (position, rotation, scale) and the pose and global pose composed from it.
	struct Bone {
		int32_t index = -1;
		int32_t parent_slot = -1; // slot of the parent bone, -1 for a root bone
		Vector3 position;
		Quaternion rotation;
		Vector3 scale = Vector3(1, 1, 1);
		Transform3D pose;
		Transform3D global;
		bool global_ok = false;
		bool written = false;
	};

	// Everything one pony's batched pass reads, computes and writes. Workers touch only this.
	struct Row {
		bool bound = false;
		bool safe = false; // last audit passed
		bool dirty = true; // audit at the next step
		bool batched = false; // in this step's batch
		bool fixture_hold = false; // parity fixture: keep her on the scripts
		bool reload = true; // read the scripts' state again at the next gather
		int64_t out_frame = -1; // physics frame of the outputs below
		ObjectID pony, body, head, hair, clip, idle, filly, affection, terrain, simulator, neck_link, hair_link;
		ObjectID secondary, clip_solver, limits, limits_solver, apply;
		// Static data (refreshed by every audit).
		std::vector<int32_t> slot_of; // body bone index -> slot in `bones`, -1 if not gathered
		std::vector<Bone> bones; // parents before children
		std::vector<std::vector<int32_t>> below; // slot -> slots of its gathered descendants
		std::vector<int32_t> clip_bones;
		std::vector<Basis> clip_frames;
		int32_t hips = -1, hips_parent = -1;
		std::vector<int32_t> legs, leg_parents, spine;
		std::vector<Basis> spine_frames;
		int32_t filly_neck = -1, filly_head = -1;
		Basis filly_width;
		std::vector<int32_t> wings;
		int32_t flank[2] = { -1, -1 }, leg_lower[2] = { -1, -1 }, tarsal[2] = { -1, -1 }, neck1 = -1, head_bone = -1;
		// Per-step inputs.
		double delta = 0.0;
		int64_t frame = 0;
		bool clip_on = false, clip_rest = false;
		double clip_weight = 0.0;
		Vector3 clip_head, clip_gaze, clip_neck_gaze;
		bool idle_on = false, idle_skip = false, idle_wanted = false, idle_frame_ready = false, idle_can_apply = false;
		double idle_fade = 0.0, idle_roll = 0.0, idle_pitch = 0.0, idle_breath = 0.0, idle_applied_roll = 0.0;
		double sec_roll = 0.0, sec_breath = 0.0;
		Vector3 sec_offset;
		Basis idle_model_to_skeleton;
		bool filly_on = false;
		double neck_scale = 1.0, head_scale = 1.0, head_width = 1.0, wing_scale = 1.0;
		bool affection_on = false, stretch_left = true;
		double buck = 0.0, stretch = 0.0, yawn = 0.0;
		Vector3 affection_axis;
		double idle_fade_in = 0.0, idle_applied_in = 0.0; // to write back only what changed
		bool idle_frame_in = false, idle_eased = false;
		bool affection_mare_ok = false; // audit: the pose belongs to her
		// Links (static data from the audit; the hair link's skip state is held here while she stays
		// batched, read from its script the step she enters and written back the step she leaves).
		ObjectID link_source, link_target, link_hair, link_body, link_head;
		std::vector<int32_t> neck_source_bones, neck_target_bones;
		std::vector<Transform3D> neck_offsets;
		int32_t body_hips = -1, hair_pelvis = -1;
		std::vector<Vector2i> head_pairs;
		std::vector<Vector3> head_offsets;
		Transform3D head_rest_inverse, skull_frame;
		bool skip_unchanged = true;
		bool neck_on = false, hair_enabled = false; // per step
		Transform3D pelvis_offset; // per step
		double follow_head = 0.0; // per step
		Transform3D pelvis_written;
		bool pelvis_valid = false, pelvis_moved = true, head_valid = false, hair_state_held = false;
		std::vector<Transform3D> head_written;
		// Outputs (idle body state; the bone writes are the `written` bones).
		int64_t idle_last_pass = -1;
		bool idle_wrote_state = false;
		// Ported modifiers in rig child order: 0 clip head, 1 idle body, 2 filly, 3 affection.
		std::vector<int32_t> order;
		double breath_arch = 0.012;
		const PonySolverNative *clip_ptr = nullptr; // resolved on the main thread each step
		const PonySolverNative *limits_ptr = nullptr;
		size_t thread = 0; // which thread computed it (statistics)
		// Diagnostics: why she stayed on the script path last.
		String reason;
	};

private:
	std::vector<Row> rows;
	std::vector<int32_t> batch; // rows in this step's batch
	// Audit lists from rig_batch.gd: allowed modifier scripts per rig and listener keys.
	Array body_scripts, head_scripts, hair_scripts; // [clip, idle, filly, affection, terrain] for body
	PackedStringArray listener_keys;
	double breath_arch = 0.012;
	double serial_radius = 1.5;
	int32_t audit_steps = 15;
	int32_t tasks = -1; // -1 all pool threads; 0 the caller alone; n caller + at most n pool tasks
	bool links_native = true;
	// Statistics of the last step.
	int64_t last_gather_usec = 0, last_compute_usec = 0, last_post_usec = 0;
	int32_t last_batched = 0, last_workers = 0;
	int64_t total_batched = 0, total_steps = 0, link_calls = 0, apply_calls = 0;
	// Time inside the engine's updates (links, apply) since the last step(), and the last full one.
	int64_t gather_bones_ns = 0, last_gather_bones_ns = 0, last_slots = 0;
	int64_t update_link_ns = 0, update_apply_ns = 0, last_link_ns = 0, last_apply_ns = 0;

	struct Names;
	static Names &names();

	bool audit(Row &row);
	bool gather(Row &row, int32_t index, const Vector3 &camera, double delta, int64_t frame, bool was);
	void flush(Row &row);
	void invalidate_hair(Row &row);
	void post(Row &row);
	static void compute_row(Row &row);
	static void compute_job(void *data, uint32_t index);
	bool row_live(int32_t id) const;

	void _child_changed(Node *p_node, int32_t p_row);
	void _body_updated(int32_t row);
	void _head_updated(int32_t row);

protected:
	static void _bind_methods();

public:
	// rig_batch.gd setup: the allowed scripts ([clip, idle, filly, affection, terrain] on the body,
	// any order on head and hair), listener keys ("script path::method" or "Class::method"), the
	// secondary's BREATH_ARCH and the camera radius of the contact rule.
	void configure(const Array &p_body_scripts, const Array &p_head_scripts, const Array &p_hair_scripts,
			const PackedStringArray &p_listener_keys, double p_breath_arch, double p_serial_radius, int32_t p_audit_steps);
	// A hybrid mare (her body, head and hair rigs exist): returns her row, or -1.
	int32_t bind_pony(Object *p_pony, Object *p_body, Object *p_head, Object *p_hair, Object *p_neck_link, Object *p_hair_link,
			Object *p_apply);
	void unbind(int32_t p_row);
	void mark_dirty(int32_t p_row);
	// One physics step: gather, compute on the pool, write state back. Returns ponies batched.
	int32_t step(const Vector3 &p_camera, double p_delta);
	// Every row leaves the batch this step (the scripts run); fixtures and the switch.
	void release_all();
	// Fixtures: keep a pony on the scripts while held (entering and leaving the batch).
	void hold(int32_t p_row, bool p_hold);
	// Fixtures: -1 every pool thread, 0 the calling thread alone, n the caller plus n pool tasks.
	void set_tasks(int32_t p_tasks);
	bool is_batched(int32_t p_row) const;
	String why(int32_t p_row) const;
	Dictionary stats() const;
	// PonyRigBatchApply: this step's writes for the row's body rig.
	void apply_row(int32_t p_row, Skeleton3D *p_skeleton);
};

// Writes a batched pony's body modifier results inside the engine's update of her body rig.
// Always active; it writes only in a step that batched her (pony_locomotion.gd _watched_modifiers
// skips this class, so a FAR rig still parks).
class PonyRigBatchApply : public SkeletonModifier3D {
	GDCLASS(PonyRigBatchApply, SkeletonModifier3D)

	ObjectID batch;
	int32_t row = -1;

protected:
	static void _bind_methods();

public:
	void setup(Object *p_batch, int32_t p_row);
	void _process_modification_with_delta(double p_delta) override;
};

} // namespace godot
