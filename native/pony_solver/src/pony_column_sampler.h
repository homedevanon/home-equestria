// PonyColumnSampler: walk_grid_service.gd _sample_column() as one native call per tick
// (dev 2026-10-20 multithreading).
//
// Why this stays on the main thread: Godot 4.5 only lets the main thread use a physics space's
// direct state. PhysicsServer3DWrapMT::space_get_direct_state() refuses other threads, and
// JoltPhysicsServer3D refuses a space that is stepping. Jolt's queries use the no-lock narrow
// phase and body interfaces (jolt_space_3d.cpp), so a ray on a worker would race any body the
// main thread adds, moves or frees. The columns cannot be rebuilt from terrain data either,
// because they must match the colliders exactly (houses, props, roofs). What changes is that a
// whole budget slice of columns runs in C++ instead of the GDScript interpreter. The rays, their
// order, every parameter and every float conversion are the same as the GDScript sampler.
#pragma once

#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/physics_shape_query_parameters3d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <unordered_map>
#include <vector>

namespace godot {

class PonyColumnSampler : public RefCounted {
	GDCLASS(PonyColumnSampler, RefCounted)

protected:
	static void _bind_methods();

public:
	// Samples columns first_column, first_column + 1, ... of `chunk` (a WalkChunk) like
	// _sample_column(), stopping after `max_columns` or once Time.get_ticks_usec() reaches
	// `deadline_usec` (checked before every column after the first, as the GDScript loop does).
	// `ray` and `volume` are the service's own query objects (left as the GDScript sampler leaves
	// them). `blockers` holds AABBs; `terrain` is WorldTerrain.instance or null.
	// Returns how many columns were sampled. Main thread only.
	int64_t sample(Object *p_space, const Ref<PhysicsRayQueryParameters3D> &p_ray,
			const Ref<PhysicsShapeQueryParameters3D> &p_volume, Object *p_chunk, int64_t p_first_column,
			int64_t p_max_columns, int64_t p_deadline_usec, const AABB &p_bounds, const Array &p_blockers,
			Object *p_terrain);

	// Perf 2026-11-21 (lane native_calls), for parity fixtures only: false runs sample() the old
	// way (terrain through the script's height_at/normal_at, per-call names and keys, the collider
	// object per hit); true (the default, NATIVE_FAST_PATHS) uses terrain_reads.h and cached keys.
	static void set_fast_paths(bool p_enabled);
	static bool get_fast_paths();
	// For the parity fixture: per point [height_at, normal_at x, y, z] from terrain_reads.h, or an
	// empty array when `terrain` cannot be read natively.
	static PackedFloat64Array terrain_reads(Object *p_terrain, const PackedVector3Array &p_points);
	// A/B fixtures only (lane native_calls): navigation_parallel.cpp's CALLER_RUNS_FIRST_BLOCK at run time.
	static void set_follow_caller_block(bool p_enabled);

	// Perf trial grid_parallel (2026-11-24, pony_column_parallel.cpp), both off by default. When
	// either is on, sample() hands the call to sample_blocks(): the same columns, on the worker pool
	// in waves of up to 12 blocks of 16 columns when `parallel` is on (deadline checked between
	// waves, so it returns whole waves), and with the Ponyville overhaul's _merge_terrain done per
	// column natively when `merge_terrain` is on.
	void set_parallel(bool p_enabled);
	bool get_parallel() const;
	void set_merge_terrain(bool p_enabled);
	bool get_merge_terrain() const;
	// Fixtures only: blocks per wave (0 = worker threads + 1, at most 12).
	void set_parallel_blocks(int64_t p_blocks);
	// The last sample_blocks() call: path, blocks, waves, wave_columns, main_columns, columns, merge.
	Dictionary get_last_parallel() const;

private:
	bool parallel = false;
	bool merge_terrain = false;
	int64_t parallel_blocks = 0;
	Dictionary last_parallel;
	std::vector<Ref<PhysicsRayQueryParameters3D>> block_rays;
	std::vector<Ref<PhysicsShapeQueryParameters3D>> block_volumes;
	std::unordered_map<uint64_t, bool> ceiling_table; // collider id -> navigation_ceiling, main thread writes
	int64_t sample_blocks(Object *p_space, const Ref<PhysicsRayQueryParameters3D> &p_ray,
			const Ref<PhysicsShapeQueryParameters3D> &p_volume, Object *p_chunk, int64_t p_first_column,
			int64_t p_max_columns, int64_t p_deadline_usec, const AABB &p_bounds, const Array &p_blockers,
			Object *p_terrain);
};

} // namespace godot
