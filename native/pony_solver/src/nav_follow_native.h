// Native hand-off of the batched route follower (native pony step, round two, lane follow, 2026-11-21;
// captures/perf_2026-11-21/port_follow.md).
//
// world/characters/navigation/native_follow_driver.gd extends PonyNavFollowDriverNative. With the
// script's NATIVE_FOLLOW_STATE on, its _physics_process is one call to native_batch(), which does
// what the script body did, in the same order, with no per-pony GDScript loop: it collects the rows
// the navigators queued this frame, syncs their walk-grid services, builds the follower and observer
// rows (the observer snapshot is kept here), runs PonyNavigationNative::step_batch directly, and
// hands each follower her command. The hand-off is pony_navigator.gd _native_apply done natively
// when that navigator's own NATIVE_FOLLOW_STATE is on and her script is exactly pony_navigator.gd
// (a subclass may override _native_apply, so it keeps the script call); events still go to the
// script (_on_native_event), and the pony still receives accept_navigation_motion() as before.
//
// The navigator's members stay script variables (they are read all over the navigation code);
// this class reads and writes them by cached name. Every such crossing is listed in the lane notes.
#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class Node3D;


class PonyNavFollowDriverNative : public Node {
	GDCLASS(PonyNavFollowDriverNative, Node)

	// Counters the labs read by name (formerly script variables of the same names).
	int64_t batches = 0;
	int64_t rows_stepped = 0;
	int64_t observers_added = 0;
	int64_t invalid_buffers = 0;
	int64_t last_batch_us = 0;
	int64_t peer_refreshes = 0;
	// Split of the last native batch, for the CPU profile labels the script recorded.
	int64_t last_gather_us = 0;
	int64_t last_step_us = 0;
	int64_t last_apply_us = 0;

	Ref<Script> backend; // native_navigation_backend.gd (its static instance())

	// Rows queued this frame (submit order), as the script's _rows.
	std::vector<ObjectID> rows;
	// Observer snapshot (the script's _peer_navs/_peer_ponies/_peer_keys/_peer_slots/_peer_stamp).
	bool peers_dirty = true;
	std::vector<ObjectID> peer_navs;
	std::vector<ObjectID> peer_ponies;
	std::vector<int64_t> peer_keys;
	std::vector<int64_t> peer_stamp;
	std::unordered_map<uint64_t, int64_t> peer_slots;

	// Buffers handed to step_batch (kept for native_last_buffers()).
	PackedInt64Array keys;
	PackedVector3Array positions;
	PackedVector3Array velocities;
	PackedFloat32Array headings;
	PackedFloat32Array inputs;

	// Navigator scripts seen: may their _native_apply run natively (exactly pony_navigator.gd with
	// NATIVE_FOLLOW_STATE on), and the constants that body uses, read from the script once.
	struct ApplyScript {
		bool native = false;
		int64_t state_moving = 0;
		int64_t state_waiting = 0;
		double leg_start_speed = 0.05;
		int64_t mode_travel = 1;
		int64_t mode_step_turn = 2;
		std::vector<String> reasons;
		std::vector<int64_t> informational;
	};
	std::unordered_map<uint64_t, ApplyScript> apply_scripts;
	const ApplyScript &apply_script_of(Object *p_navigator);
	void apply_row(Object *p_navigator, Node3D *p_pony, const ApplyScript &p_script, const PackedFloat32Array &p_commands,
			const PackedFloat32Array &p_states, const Vector3 &p_preferred, int64_t p_row);
	void refresh_peers();

protected:
	static void _bind_methods();

public:
	void native_configure(const Ref<Script> &p_backend);
	void native_submit(Object *p_navigator);
	void native_invalidate_peers();
	// native_follow_driver.gd _physics_process body (OBSERVER_CACHE path). Returns 0 when nothing
	// was queued or the backend is missing, 1 when a batch ran.
	int64_t native_batch(double p_delta);
	// nearby_navigators() over the native snapshot.
	TypedArray<Node> native_nearby_navigators(const Vector3 &p_at, double p_radius);
	// [keys, positions, velocities, headings, inputs] of the last batch (labs and the parity fixture).
	Array native_last_buffers() const;

	void set_batches(int64_t p_value) { batches = p_value; }
	int64_t get_batches() const { return batches; }
	void set_rows_stepped(int64_t p_value) { rows_stepped = p_value; }
	int64_t get_rows_stepped() const { return rows_stepped; }
	void set_observers_added(int64_t p_value) { observers_added = p_value; }
	int64_t get_observers_added() const { return observers_added; }
	void set_invalid_buffers(int64_t p_value) { invalid_buffers = p_value; }
	int64_t get_invalid_buffers() const { return invalid_buffers; }
	void set_last_batch_us(int64_t p_value) { last_batch_us = p_value; }
	int64_t get_last_batch_us() const { return last_batch_us; }
	void set_peer_refreshes(int64_t p_value) { peer_refreshes = p_value; }
	int64_t get_peer_refreshes() const { return peer_refreshes; }
	int64_t get_last_gather_us() const { return last_gather_us; }
	int64_t get_last_step_us() const { return last_step_us; }
	int64_t get_last_apply_us() const { return last_apply_us; }
};

} // namespace godot
