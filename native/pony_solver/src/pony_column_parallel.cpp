// Perf trial grid_parallel (2026-11-24): PonyColumnSampler::sample() on all cores, with the Ponyville
// overhaul's per-column ground merge (_merge_terrain in the overhaul compat copy of
// world/navigation/walk_grid_service.gd) done inside the same call. Off unless the script calls
// set_parallel(true) / set_merge_terrain(true) (launch argument --try=grid_parallel).
//
// The per-column body below is a deliberate copy of the serial loop in pony_column_sampler.cpp, so
// the serial path stays byte for byte as it was; tools/navigation/test_grid_parallel.gd compares
// the two and must stay in the tree while both exist.
//
// Why workers may query the physics space here (Godot 4.5 + Jolt, read in
// modules/jolt_physics/spaces/jolt_physics_direct_space_state_3d.cpp): intersect_ray and
// intersect_shape refuse only while the space steps, call flush_pending_objects() (returns at once
// with nothing pending), build the query shape under its own mutex (try_build) and use Jolt's
// no-lock narrow phase. The main thread runs one ray and one shape query itself first (flushing
// pending bodies and building the shape), then stays blocked inside this call for the whole fan-out,
// and the call comes from the walk grid's _physics_process, not from inside the Jolt step. So no
// body is added, moved or freed while the workers query, unless some other thread does that: the
// game's own worker tasks do not (2026-11-24 grep), a third-party mod is not checked.
// Workers touch only: their own query objects, their own TerrainReads copy (regions looked up on
// the main thread first), the chunk arrays' raw memory (disjoint columns) and the sampler's
// collider -> navigation_ceiling table, read only. Node::get_meta() is thread-guarded in 4.5 (it
// returns null off the main thread, so a worker would take every roof shell for a floor): a worker
// that meets a collider the table does not know leaves that column, the main thread reads the tag
// after the wave and the column is sampled again (on the pool, or on the main thread at the end).
// The table lives as long as the sampler: the tag is set before a body enters the tree (as the
// chunk key registry, walk_grid_keys.gd, assumes too) and instance ids are never reused.
// Everything else (WalkChunk get/set, script calls, get_meta) is main thread.
#include "pony_column_sampler.h"

#include "terrain_reads.h"

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <limits>
#include <utility>
#include <vector>

using namespace godot;

namespace {

// walk_grid.gd and walk_grid_service.gd constants (as pony_column_sampler.cpp).
constexpr int64_t CHUNK_CELLS = 64;
constexpr int64_t SPANS = 2;
constexpr double CELL = 0.25;
constexpr int64_t PAINT_SCALE = 50;
constexpr uint8_t SOLID = 1;
constexpr uint8_t WATER = 2;
constexpr uint32_t WATER_MASK = 1u << 15;
constexpr double PI_VALUE = 3.1415926535897932384626433833;

// Fan-out shape: blocks of BLOCK_COLUMNS consecutive columns, at most MAX_BLOCKS per wave (the
// caller runs block 0), and no fan-out below MIN_PARALLEL_COLUMNS.
constexpr int64_t BLOCK_COLUMNS = 16;
constexpr int64_t MAX_BLOCKS = 12;
constexpr int64_t MIN_PARALLEL_COLUMNS = 32;
// Pool passes over a wave's columns that met an unknown collider, before the rest go to the main thread.
constexpr int REPAIR_ROUNDS = 2;
// The collider table is cleared at the start of a call once it holds this many entries.
constexpr size_t CEILING_TABLE_LIMIT = 65536;

// sample_column() results.
constexpr uint8_t COLUMN_DONE = 0;
constexpr uint8_t COLUMN_UNKNOWN_COLLIDER = 1; // a worker met a collider the table does not know
constexpr uint8_t COLUMN_NEEDS_SCRIPT = 2; // a terrain read needs the script (main thread)

// How a block reads the ceiling tag: as the serial loop (memo per call, get_meta), as a worker
// (the table only), or as the main thread during a fan-out (the table, filled on a miss).
enum class Mode { SERIAL, WORKER, MAIN };

int64_t slope_degrees(double normal_y) {
	const double clamped = normal_y < -1.0 ? -1.0 : (normal_y > 1.0 ? 1.0 : normal_y);
	return int64_t(std::ceil(std::acos(clamped) * (180.0 / PI_VALUE) - .001));
}

double max_zero(double value) {
	return 0.0 < value ? value : 0.0;
}

struct Keys {
	const Variant position = StringName("position");
	const Variant normal = StringName("normal");
	const Variant rid = StringName("rid");
	const Variant collider_id = StringName("collider_id");
	const StringName height_at = StringName("height_at");
	const StringName normal_at = StringName("normal_at");
	const StringName floor_y = StringName("floor_y");
	const StringName slope_deg = StringName("slope_deg");
	const StringName water_depth = StringName("water_depth");
	const StringName headroom = StringName("headroom");
	const StringName flags = StringName("flags");
	const StringName paint_cost = StringName("paint_cost");
	const StringName trail_weight = StringName("trail_weight");
	const StringName coord = StringName("coord");
	const StringName ceiling_meta = StringName("navigation_ceiling");
};

const Keys &keys() {
	static const Keys k;
	return k;
}

// The ray state and the volume transform one column leaves behind (sample() leaves the service's
// query objects as the serial loop leaves them; with the merge on, as the serial loop followed by
// the script's _merge_terrain over the same columns leaves them: the last merged column's merge).
struct Tail {
	Vector3 from;
	Vector3 to;
	uint32_t mask = 0;
	bool inside = false;
	bool volume = false; // this column moved the volume
	bool merged = false; // the merge got past its early returns (it moved the ray and the volume)
	Vector3 volume_origin;
};

// One call's inputs and outputs, shared read-only by every block (the arrays by disjoint columns).
struct Shared {
	PhysicsDirectSpaceState3D *space = nullptr;
	Object *terrain = nullptr;
	bool fast = true;
	bool merge = false;
	Vector2i coord;
	double top = 0.0;
	double bottom = 0.0;
	TypedArray<RID> base_excludes;
	std::vector<AABB> blockers;
	int64_t first = 0;
	float *floor_y = nullptr;
	uint8_t *slope_deg = nullptr;
	float *water_depth = nullptr;
	float *headroom = nullptr;
	uint8_t *flags = nullptr;
	uint8_t *paint_cost = nullptr;
	uint8_t *trail_weight = nullptr;
	int64_t trail_size = 0;
	std::vector<Tail> tails; // per column of the call
	std::vector<uint8_t> needs_main; // per column: COLUMN_* of its last try
	std::unordered_map<uint64_t, bool> *ceiling_table = nullptr; // read only while workers run
};

// One block's own query objects, terrain reader and ceiling memo.
struct Block {
	Ref<PhysicsRayQueryParameters3D> ray;
	Ref<PhysicsShapeQueryParameters3D> volume;
	pony::TerrainReads reads;
	bool reads_bound = false;
	bool reads_ok = false;
	std::vector<std::pair<uint64_t, bool>> ceilings; // Mode::SERIAL memo
	std::vector<uint64_t> unknown; // Mode::WORKER: colliders the table did not know
	Mode mode = Mode::SERIAL;
};

bool blocked(const Shared &s, const Vector3 &point) {
	for (const AABB &box : s.blockers) {
		if (box.grow(real_t(.18)).has_point(point)) {
			return true;
		}
	}
	return false;
}

bool read_ceiling_tag(uint64_t p_id) {
	Object *collider = ObjectDB::get_instance(p_id);
	return collider != nullptr && bool(collider->get_meta(keys().ceiling_meta, false));
}

// 1: a navigation_ceiling collider, 0: not, -1: unknown to a worker (the column waits).
int is_ceiling(const Shared &s, Block &b, const Dictionary &p_hit) {
	const Keys &k = keys();
	if (!s.fast) {
		Object *collider = p_hit["collider"];
		return collider != nullptr && bool(collider->get_meta(k.ceiling_meta, false)) ? 1 : 0;
	}
	const uint64_t id = uint64_t(int64_t(p_hit[k.collider_id]));
	if (b.mode == Mode::SERIAL) {
		for (const std::pair<uint64_t, bool> &seen : b.ceilings) {
			if (seen.first == id) {
				return seen.second ? 1 : 0;
			}
		}
		const bool ceiling = read_ceiling_tag(id);
		b.ceilings.emplace_back(id, ceiling);
		return ceiling ? 1 : 0;
	}
	const auto found = s.ceiling_table->find(id);
	if (found != s.ceiling_table->end()) {
		return found->second ? 1 : 0;
	}
	if (b.mode == Mode::WORKER) {
		b.unknown.push_back(id);
		return -1;
	}
	const bool ceiling = read_ceiling_tag(id);
	s.ceiling_table->emplace(id, ceiling);
	return ceiling ? 1 : 0;
}

// Terrain height through the block's reader, else the script (main thread only). False: this
// column needs the main thread.
bool terrain_height(const Shared &s, Block &b, const Vector3 &p_at, bool p_allow_script, double &r_height) {
	if (s.fast) {
		if (!b.reads_bound) {
			if (!p_allow_script) {
				return false;
			}
			b.reads_ok = b.reads.bind(s.terrain);
			b.reads_bound = true;
		}
		if (b.reads_ok) {
			r_height = b.reads.height_at(p_at);
			b.reads_ok = b.reads.usable();
			if (b.reads_ok) {
				return true;
			}
		}
	}
	if (!p_allow_script) {
		return false;
	}
	r_height = double(s.terrain->call(s.fast ? keys().height_at : StringName("height_at"), p_at));
	return true;
}

bool terrain_normal(const Shared &s, Block &b, const Vector3 &p_at, bool p_allow_script, Vector3 &r_normal) {
	if (s.fast && b.reads_ok) {
		r_normal = b.reads.normal_at(p_at);
		b.reads_ok = b.reads.usable();
		if (b.reads_ok) {
			return true;
		}
	}
	if (!p_allow_script) {
		return false;
	}
	r_normal = s.terrain->call(s.fast ? keys().normal_at : StringName("normal_at"), p_at);
	return true;
}

// The overhaul's _merge_terrain(chunk, column) after the column's own floors, ported line by line
// (compat copy of walk_grid_service.gd, 2026-11-24). `water_y` is the column's own water ray, the
// same ray the script casts again (same ends, mask, flags and exclude list).
bool merge_column(Shared &s, Block &b, int64_t column, double x, double z, double water_y, Tail &tail,
		bool p_allow_script) {
	if (s.terrain == nullptr) {
		return true;
	}
	const int64_t first = column * SPANS;
	int64_t found = 0;
	while (found < SPANS && std::isfinite(double(s.floor_y[first + found])) && (s.flags[first + found] & SOLID)) {
		++found;
	}
	if (found == 0) {
		return true; // (the sampler's own heightmap fallback has it)
	}
	double ground = 0.0;
	if (!terrain_height(s, b, Vector3(real_t(x), 0.0f, real_t(z)), p_allow_script, ground)) {
		return false;
	}
	if (!std::isfinite(ground)) {
		return true; // a terrain hole (under a building) or no region
	}
	int64_t index = 0;
	while (index < found && double(s.floor_y[first + index]) > ground + .025) {
		++index;
	}
	if (index == SPANS) {
		return true;
	}
	const int64_t slot = first + index;
	if (index < found && double(s.floor_y[slot]) >= ground - .025) {
		return true; // the ground itself, or a floor on it
	}
	// (the script reads the normal after the shift and the water ray; neither changes it)
	Vector3 normal;
	if (!terrain_normal(s, b, Vector3(real_t(x), real_t(ground), real_t(z)), p_allow_script, normal)) {
		return false; // nothing of the merge written yet: the main thread redoes the whole column
	}
	tail.merged = true;
	if (index < found) {
		if (index + 1 < SPANS) {
			s.floor_y[slot + 1] = s.floor_y[slot];
			s.slope_deg[slot + 1] = s.slope_deg[slot];
			s.water_depth[slot + 1] = s.water_depth[slot];
			s.flags[slot + 1] = s.flags[slot];
			// minf(a, b) is MIN(a, b): (a < b ? a : b)
			const double headroom = double(s.headroom[slot]);
			const double gap = ground - double(s.floor_y[slot]);
			s.headroom[slot + 1] = float(headroom < gap ? headroom : gap);
		}
	}
	s.floor_y[slot] = float(ground);
	s.slope_deg[slot] = uint8_t(slope_degrees(double(normal.y)));
	s.water_depth[slot] = float(max_zero(water_y - ground));
	s.flags[slot] = uint8_t(SOLID | (double(s.water_depth[slot]) > .001 ? WATER : 0));
	// its clearance against the same scenery and blockers as any other floor
	const Keys &k = keys();
	const double reach = ground + 3.0;
	b.ray->set_from(Vector3(real_t(x), real_t(ground + .03), real_t(z)));
	b.ray->set_to(Vector3(real_t(x), real_t(reach < s.top ? s.top : reach), real_t(z)));
	b.ray->set_hit_from_inside(true);
	const Dictionary ceiling = s.space->intersect_ray(b.ray);
	s.headroom[slot] = ceiling.is_empty() ? std::numeric_limits<float>::infinity()
										  : float(double(Vector3(ceiling[k.position]).y) - ground);
	const Vector3 volume_at(real_t(x), real_t(ground + .237), real_t(z));
	b.volume->set_transform(Transform3D(Basis(), volume_at));
	tail.volume = true;
	tail.volume_origin = volume_at;
	if (!s.space->intersect_shape(b.volume, 1).is_empty()) {
		s.headroom[slot] = 0.0f;
	}
	if (blocked(s, Vector3(real_t(x), real_t(ground + .3), real_t(z)))) {
		s.headroom[slot] = 0.0f;
	}
	return true;
}

// One column, a copy of the serial loop body in pony_column_sampler.cpp (lines 219-347 on
// 2026-11-24) writing into raw array memory, then the merge when it is on. `local` counts from the
// call's first column. Not COLUMN_DONE (workers only): the column is redone whole later.
uint8_t sample_column(Shared &s, Block &b, int64_t local) {
	const bool p_allow_script = b.mode != Mode::WORKER;
	const Keys &k = keys();
	const int64_t column = s.first + local;
	Tail &tail = s.tails[size_t(local)];
	tail.volume = false;
	tail.merged = false;
	const Vector3 up(0, 1, 0);
	const Variant &key_position = s.fast ? k.position : Variant(String("position"));
	const Variant &key_normal = s.fast ? k.normal : Variant(String("normal"));
	const Variant &key_rid = s.fast ? k.rid : Variant(String("rid"));
	const Ref<PhysicsRayQueryParameters3D> &ray = b.ray;
	const Ref<PhysicsShapeQueryParameters3D> &volume = b.volume;
	PhysicsDirectSpaceState3D *space = s.space;
	// chunk.clear_column(column)
	for (int64_t span = 0; span < SPANS; ++span) {
		const int64_t slot = column * SPANS + span;
		s.floor_y[slot] = std::numeric_limits<float>::quiet_NaN();
		s.slope_deg[slot] = 0;
		s.water_depth[slot] = 0.0f;
		s.headroom[slot] = std::numeric_limits<float>::infinity();
		s.flags[slot] = 0;
		if (s.trail_size > slot) {
			s.trail_weight[slot] = 0;
		}
	}
	s.paint_cost[column] = uint8_t(PAINT_SCALE);
	const int64_t cell_x = int64_t(s.coord.x) * CHUNK_CELLS + column % CHUNK_CELLS;
	const int64_t cell_z = int64_t(s.coord.y) * CHUNK_CELLS + column / CHUNK_CELLS;
	const double x = (double(cell_x) + .5) * CELL;
	const double z = (double(cell_z) + .5) * CELL;
	const double top = s.top;
	const double bottom = s.bottom;
	ray->set_from(Vector3(real_t(x), real_t(top), real_t(z)));
	ray->set_to(Vector3(real_t(x), real_t(bottom), real_t(z)));
	ray->set_collision_mask(WATER_MASK);
	ray->set_hit_from_inside(false);
	const Dictionary water = space->intersect_ray(ray);
	const double water_y = water.is_empty() ? -std::numeric_limits<double>::infinity() : double(Vector3(water[key_position]).y);
	ray->set_collision_mask(1);
	double height = top;
	int64_t found = 0;
	TypedArray<RID> floor_excludes = s.base_excludes.duplicate();
	bool excluding = false;
	for (int attempt = 0; attempt < 6; ++attempt) {
		ray->set_from(Vector3(real_t(x), real_t(height), real_t(z)));
		ray->set_to(Vector3(real_t(x), real_t(bottom), real_t(z)));
		ray->set_hit_from_inside(false);
		if (excluding) {
			ray->set_exclude(floor_excludes);
		}
		const Dictionary hit = space->intersect_ray(ray);
		if (excluding) {
			ray->set_exclude(s.base_excludes);
		}
		if (hit.is_empty()) {
			break;
		}
		const Vector3 position = hit[key_position];
		height = double(position.y) - .025;
		const int ceiling_tag = is_ceiling(s, b, hit);
		if (ceiling_tag < 0) {
			return COLUMN_UNKNOWN_COLLIDER;
		}
		if (ceiling_tag > 0) {
			floor_excludes.append(RID(hit[key_rid]));
			excluding = true;
			continue;
		}
		const Vector3 normal = hit[key_normal];
		if (double(normal.y) <= .01) {
			continue;
		}
		const int64_t slot = column * SPANS + found;
		s.floor_y[slot] = position.y;
		s.slope_deg[slot] = uint8_t(slope_degrees(double(normal.y)));
		s.water_depth[slot] = float(max_zero(water_y - double(position.y)));
		s.flags[slot] = uint8_t(SOLID | (double(s.water_depth[slot]) > .001 ? WATER : 0));
		ray->set_from(position + up * real_t(.03));
		ray->set_to(Vector3(real_t(x), real_t(top), real_t(z)));
		ray->set_hit_from_inside(true);
		const Dictionary ceiling = space->intersect_ray(ray);
		s.headroom[slot] = ceiling.is_empty() ? std::numeric_limits<float>::infinity()
											  : float(double(Vector3(ceiling[key_position]).y) - double(position.y));
		const Vector3 volume_at = position + up * real_t(.237);
		volume->set_transform(Transform3D(Basis(), volume_at));
		tail.volume = true;
		tail.volume_origin = volume_at;
		if (!space->intersect_shape(volume, 1).is_empty()) {
			s.headroom[slot] = 0.0f;
		}
		if (blocked(s, position + up * real_t(.3))) {
			s.headroom[slot] = 0.0f;
		}
		++found;
		if (found >= SPANS) {
			break;
		}
	}
	if (found == 0 && s.terrain != nullptr) {
		// No physics floor here: the world heightmap is the ground.
		double ground = 0.0;
		if (!terrain_height(s, b, Vector3(real_t(x), 0.0f, real_t(z)), p_allow_script, ground)) {
			return COLUMN_NEEDS_SCRIPT;
		}
		if (std::isfinite(ground)) {
			Vector3 normal;
			if (!terrain_normal(s, b, Vector3(real_t(x), real_t(ground), real_t(z)), p_allow_script, normal)) {
				return COLUMN_NEEDS_SCRIPT;
			}
			const int64_t slot = column * SPANS;
			s.floor_y[slot] = float(ground);
			s.slope_deg[slot] = uint8_t(slope_degrees(double(normal.y)));
			s.water_depth[slot] = float(max_zero(water_y - ground));
			s.flags[slot] = uint8_t(SOLID | (double(s.water_depth[slot]) > .001 ? WATER : 0));
			const double reach = ground + 3.0;
			ray->set_from(Vector3(real_t(x), real_t(ground + .03), real_t(z)));
			ray->set_to(Vector3(real_t(x), real_t(reach < top ? top : reach), real_t(z)));
			ray->set_hit_from_inside(true);
			const Dictionary ceiling = space->intersect_ray(ray);
			s.headroom[slot] = ceiling.is_empty() ? std::numeric_limits<float>::infinity()
												  : float(double(Vector3(ceiling[key_position]).y) - ground);
			const Vector3 volume_at(real_t(x), real_t(ground + .237), real_t(z));
			volume->set_transform(Transform3D(Basis(), volume_at));
			tail.volume = true;
			tail.volume_origin = volume_at;
			if (!space->intersect_shape(volume, 1).is_empty()) {
				s.headroom[slot] = 0.0f;
			}
			if (blocked(s, Vector3(real_t(x), real_t(ground + .3), real_t(z)))) {
				s.headroom[slot] = 0.0f;
			}
		}
	}
	if (s.merge && !merge_column(s, b, column, x, z, water_y, tail, p_allow_script)) {
		return COLUMN_NEEDS_SCRIPT;
	}
	return COLUMN_DONE;
}

void capture_ray(const Block &b, Tail &tail) {
	tail.from = b.ray->get_from();
	tail.to = b.ray->get_to();
	tail.mask = b.ray->get_collision_mask();
	tail.inside = b.ray->is_hit_from_inside_enabled();
}

// The last of the first `done` columns whose merge moved the ray and volume, or -1.
int64_t last_merged(const Shared &s, int64_t done) {
	if (!s.merge) {
		return -1;
	}
	for (int64_t local = done - 1; local >= 0; --local) {
		if (s.tails[size_t(local)].merged) {
			return local;
		}
	}
	return -1;
}

// One pass of the pool over `locals` (call-local columns): block i takes locals[i * per_block, ...).
struct Wave {
	Shared *shared = nullptr;
	Block *blocks = nullptr;
	const int64_t *locals = nullptr;
	int64_t count = 0;
	int64_t per_block = BLOCK_COLUMNS;
};

void run_block(Wave &wave, uint32_t index) {
	Shared &s = *wave.shared;
	Block &b = wave.blocks[index];
	const int64_t from = int64_t(index) * wave.per_block;
	const int64_t to = std::min<int64_t>(wave.count, from + wave.per_block);
	for (int64_t i = from; i < to; ++i) {
		const int64_t local = wave.locals[i];
		const uint8_t result = sample_column(s, b, local);
		s.needs_main[size_t(local)] = result;
		if (result == COLUMN_DONE) {
			capture_ray(b, s.tails[size_t(local)]);
		}
	}
}

// The pool runs blocks 1..used-1; the calling thread runs block 0 (navigation_parallel.cpp).
void run_shifted(void *p_user, uint32_t p_index) {
	run_block(*static_cast<Wave *>(p_user), p_index + 1);
}

void dispatch(WorkerThreadPool *p_pool, Shared &s, std::vector<Block> &blocks, const std::vector<int64_t> &locals,
		int64_t per_block) {
	if (locals.empty()) {
		return;
	}
	Wave wave{ &s, blocks.data(), locals.data(), int64_t(locals.size()), per_block };
	const int64_t used = std::min<int64_t>(int64_t(blocks.size()), (wave.count + per_block - 1) / per_block);
	if (used > 1) {
		const WorkerThreadPool::GroupID group = p_pool->add_native_group_task(&run_shifted, &wave, int(used - 1), -1, true,
				String("Walk grid columns"));
		run_block(wave, 0);
		p_pool->wait_for_group_task_completion(group);
	} else {
		run_block(wave, 0);
	}
}

int64_t pool_blocks(int64_t p_wanted) {
	if (p_wanted > 0) {
		return std::min<int64_t>(p_wanted, MAX_BLOCKS);
	}
	int64_t threads = -1;
	ProjectSettings *settings = ProjectSettings::get_singleton();
	if (settings != nullptr) {
		threads = int64_t(settings->get_setting("threading/worker_pool/max_threads", -1));
	}
	if (threads <= 0) {
		threads = OS::get_singleton()->get_processor_count();
	}
	return std::max<int64_t>(1, std::min<int64_t>(threads + 1, MAX_BLOCKS));
}

} // namespace

void PonyColumnSampler::set_parallel(bool p_enabled) {
	parallel = p_enabled;
}

bool PonyColumnSampler::get_parallel() const {
	return parallel;
}

void PonyColumnSampler::set_merge_terrain(bool p_enabled) {
	merge_terrain = p_enabled;
}

bool PonyColumnSampler::get_merge_terrain() const {
	return merge_terrain;
}

void PonyColumnSampler::set_parallel_blocks(int64_t p_blocks) {
	parallel_blocks = p_blocks;
}

Dictionary PonyColumnSampler::get_last_parallel() const {
	return last_parallel;
}

int64_t PonyColumnSampler::sample_blocks(Object *p_space, const Ref<PhysicsRayQueryParameters3D> &p_ray,
		const Ref<PhysicsShapeQueryParameters3D> &p_volume, Object *p_chunk, int64_t p_first_column,
		int64_t p_max_columns, int64_t p_deadline_usec, const AABB &p_bounds, const Array &p_blockers,
		Object *p_terrain) {
	PhysicsDirectSpaceState3D *space = Object::cast_to<PhysicsDirectSpaceState3D>(p_space);
	ERR_FAIL_NULL_V(space, 0);
	ERR_FAIL_COND_V(p_ray.is_null() || p_volume.is_null(), 0);
	ERR_FAIL_NULL_V(p_chunk, 0);
	const int64_t columns = CHUNK_CELLS * CHUNK_CELLS;
	if (p_first_column < 0 || p_first_column >= columns || p_max_columns <= 0) {
		return 0;
	}
	const Keys &k = keys();
	PackedFloat32Array floor_y = p_chunk->get(k.floor_y);
	PackedByteArray slope_deg = p_chunk->get(k.slope_deg);
	PackedFloat32Array water_depth = p_chunk->get(k.water_depth);
	PackedFloat32Array headroom = p_chunk->get(k.headroom);
	PackedByteArray flags = p_chunk->get(k.flags);
	PackedByteArray paint_cost = p_chunk->get(k.paint_cost);
	PackedByteArray trail_weight = p_chunk->get(k.trail_weight);
	const int64_t slots = columns * SPANS;
	ERR_FAIL_COND_V_MSG(floor_y.size() != slots || slope_deg.size() != slots || water_depth.size() != slots ||
					headroom.size() != slots || flags.size() != slots || paint_cost.size() != columns,
			0, "PonyColumnSampler needs an allocated WalkChunk");
	const int64_t count = std::min<int64_t>(p_max_columns, columns - p_first_column);

	Shared s;
	s.space = space;
	s.terrain = p_terrain;
	s.fast = get_fast_paths();
	s.merge = merge_terrain;
	s.coord = p_chunk->get(k.coord);
	s.top = double(p_bounds.get_end().y) + 5.0;
	s.bottom = double(p_bounds.position.y) - 5.0;
	s.base_excludes = p_ray->get_exclude();
	for (int64_t i = 0; i < p_blockers.size(); ++i) {
		if (p_blockers[i].get_type() == Variant::AABB) {
			s.blockers.push_back(AABB(p_blockers[i]));
		}
	}
	s.first = p_first_column;
	// ptrw() makes these arrays this call's own (copy on write) here, on the main thread.
	s.floor_y = floor_y.ptrw();
	s.slope_deg = slope_deg.ptrw();
	s.water_depth = water_depth.ptrw();
	s.headroom = headroom.ptrw();
	s.flags = flags.ptrw();
	s.paint_cost = paint_cost.ptrw();
	s.trail_size = trail_weight.size();
	s.trail_weight = s.trail_size > 0 ? trail_weight.ptrw() : nullptr;
	s.tails.resize(size_t(count));
	s.needs_main.assign(size_t(count), COLUMN_DONE);
	if (ceiling_table.size() >= CEILING_TABLE_LIMIT) {
		ceiling_table.clear();
	}
	s.ceiling_table = &ceiling_table;

	OS *os = OS::get_singleton();
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	Time *time = Time::get_singleton();
	int64_t done = 0;
	int64_t block_count = 0;
	int64_t waves = 0;
	int64_t main_columns = 0;
	int64_t repaired = 0;
	String path = "serial";

	// Parallel preconditions: main thread, the native terrain reader binds, a pool, enough columns.
	pony::TerrainReads reads;
	bool fan_out = parallel && s.fast && count >= MIN_PARALLEL_COLUMNS && pool != nullptr &&
			os->get_thread_caller_id() == os->get_main_thread_id() && p_terrain != nullptr && reads.bind(p_terrain);
	if (fan_out) {
		// Look up every terrain region this chunk's reads can touch here, on the main thread, so the
		// workers' copies only read (heights reach one vertex past the point; 8 m steps over the
		// chunk grown by 4 m meet every region larger than 8 m that the grown box touches).
		const double chunk_m = double(CHUNK_CELLS) * CELL;
		const double x0 = double(s.coord.x) * chunk_m - 4.0;
		const double z0 = double(s.coord.y) * chunk_m - 4.0;
		for (int iz = 0; iz <= 3; ++iz) {
			for (int ix = 0; ix <= 3; ++ix) {
				reads.height_at(Vector3(real_t(x0 + ix * 8.0), 0.0f, real_t(z0 + iz * 8.0)));
			}
		}
		fan_out = reads.usable();
	}
	if (fan_out) {
		path = "parallel";
		block_count = pool_blocks(parallel_blocks);
		// Per-block query objects, kept between calls and set from the caller's each call.
		while (int64_t(block_rays.size()) < block_count) {
			Ref<PhysicsRayQueryParameters3D> ray;
			ray.instantiate();
			block_rays.push_back(ray);
			Ref<PhysicsShapeQueryParameters3D> volume;
			volume.instantiate();
			block_volumes.push_back(volume);
		}
		std::vector<Block> blocks(static_cast<size_t>(block_count));
		for (int64_t i = 0; i < block_count; ++i) {
			Block &b = blocks[size_t(i)];
			b.ray = block_rays[size_t(i)];
			b.ray->set_collision_mask(p_ray->get_collision_mask());
			b.ray->set_collide_with_areas(p_ray->is_collide_with_areas_enabled());
			b.ray->set_collide_with_bodies(p_ray->is_collide_with_bodies_enabled());
			b.ray->set_hit_back_faces(p_ray->is_hit_back_faces_enabled());
			b.ray->set_hit_from_inside(p_ray->is_hit_from_inside_enabled());
			b.ray->set_exclude(s.base_excludes);
			b.volume = block_volumes[size_t(i)];
			b.volume->set_shape_rid(p_volume->get_shape_rid());
			b.volume->set_margin(p_volume->get_margin());
			b.volume->set_collision_mask(p_volume->get_collision_mask());
			b.volume->set_collide_with_areas(p_volume->is_collide_with_areas_enabled());
			b.volume->set_collide_with_bodies(p_volume->is_collide_with_bodies_enabled());
			b.volume->set_exclude(p_volume->get_exclude());
			b.volume->set_motion(p_volume->get_motion());
			b.volume->set_transform(p_volume->get_transform());
			b.reads = reads;
			b.reads_bound = true;
			b.reads_ok = true;
			b.mode = Mode::WORKER;
		}
		// One ray and one shape query here first: Jolt flushes pending bodies and builds the query
		// shape on the main thread, so the workers' calls find nothing to do there.
		{
			const int64_t column = p_first_column;
			const double x = (double(int64_t(s.coord.x) * CHUNK_CELLS + column % CHUNK_CELLS) + .5) * CELL;
			const double z = (double(int64_t(s.coord.y) * CHUNK_CELLS + column / CHUNK_CELLS) + .5) * CELL;
			Block &b = blocks[0];
			b.ray->set_from(Vector3(real_t(x), real_t(s.top), real_t(z)));
			b.ray->set_to(Vector3(real_t(x), real_t(s.bottom), real_t(z)));
			space->intersect_ray(b.ray);
			b.volume->set_transform(Transform3D(Basis(), Vector3(real_t(x), real_t(s.top), real_t(z))));
			space->intersect_shape(b.volume, 1);
		}
		const int64_t wave_columns = block_count * BLOCK_COLUMNS;
		std::vector<int64_t> locals;
		std::vector<int64_t> retry;
		while (done < count) {
			if (done > 0 && int64_t(time->get_ticks_usec()) >= p_deadline_usec) {
				break;
			}
			const int64_t wave_end = std::min<int64_t>(count, done + wave_columns);
			locals.clear();
			for (int64_t local = done; local < wave_end; ++local) {
				locals.push_back(local);
			}
			dispatch(pool, s, blocks, locals, BLOCK_COLUMNS);
			// Columns that met a collider the table did not know: read the tags here, sample again.
			for (int round = 0; round < REPAIR_ROUNDS; ++round) {
				retry.clear();
				for (const int64_t local : locals) {
					if (s.needs_main[size_t(local)] == COLUMN_UNKNOWN_COLLIDER) {
						retry.push_back(local);
					}
				}
				if (retry.empty()) {
					break;
				}
				for (Block &b : blocks) {
					for (const uint64_t id : b.unknown) {
						if (ceiling_table.find(id) == ceiling_table.end()) {
							ceiling_table.emplace(id, read_ceiling_tag(id));
						}
					}
					b.unknown.clear();
				}
				++repaired;
				locals.swap(retry);
				dispatch(pool, s, blocks, locals, (int64_t(locals.size()) + block_count - 1) / block_count);
			}
			done = wave_end;
			++waves;
		}
		// What is left (a terrain read that needs the script, a collider still unknown): here, whole.
		Block &main_block = blocks[0];
		main_block.mode = Mode::MAIN;
		for (int64_t local = 0; local < done; ++local) {
			if (s.needs_main[size_t(local)] != COLUMN_DONE) {
				sample_column(s, main_block, local);
				capture_ray(main_block, s.tails[size_t(local)]);
				++main_columns;
			}
		}
		for (Block &b : blocks) {
			b.unknown.clear();
		}
		// The service's query objects as the serial loop (and the script merge after it) leaves them.
		if (done > 0) {
			const int64_t merged = last_merged(s, done);
			const Tail &last = s.tails[size_t(merged >= 0 ? merged : done - 1)];
			p_ray->set_from(last.from);
			p_ray->set_to(last.to);
			p_ray->set_collision_mask(last.mask);
			p_ray->set_hit_from_inside(last.inside);
			for (int64_t local = merged >= 0 ? merged : done - 1; local >= 0; --local) {
				if (s.tails[size_t(local)].volume) {
					p_volume->set_transform(Transform3D(Basis(), s.tails[size_t(local)].volume_origin));
					break;
				}
			}
		}
	} else {
		// The same column function, serially, on the caller's own query objects (the serial loop's
		// per-column deadline check).
		Block b;
		b.ray = p_ray;
		b.volume = p_volume;
		b.mode = Mode::SERIAL;
		for (; done < count; ++done) {
			if (done > 0 && int64_t(time->get_ticks_usec()) >= p_deadline_usec) {
				break;
			}
			sample_column(s, b, done);
			if (s.merge) {
				capture_ray(b, s.tails[size_t(done)]);
			}
		}
		block_count = 1;
		// With the merge on, the script merge after the serial loop would leave the last merged
		// column's merge ray and volume, not the last column's.
		const int64_t merged = s.merge && done > 0 ? last_merged(s, done) : -1;
		if (merged >= 0) {
			const Tail &last = s.tails[size_t(merged)];
			p_ray->set_from(last.from);
			p_ray->set_to(last.to);
			p_ray->set_collision_mask(last.mask);
			p_ray->set_hit_from_inside(last.inside);
			p_volume->set_transform(Transform3D(Basis(), last.volume_origin));
		}
	}
	p_chunk->set(k.floor_y, floor_y);
	p_chunk->set(k.slope_deg, slope_deg);
	p_chunk->set(k.water_depth, water_depth);
	p_chunk->set(k.headroom, headroom);
	p_chunk->set(k.flags, flags);
	p_chunk->set(k.paint_cost, paint_cost);
	p_chunk->set(k.trail_weight, trail_weight);
	Dictionary stats;
	stats["path"] = path;
	stats["blocks"] = block_count;
	stats["waves"] = waves;
	stats["wave_columns"] = block_count * BLOCK_COLUMNS;
	stats["main_columns"] = main_columns;
	stats["repair_waves"] = repaired;
	stats["ceiling_table"] = int64_t(ceiling_table.size());
	stats["columns"] = done;
	stats["merge"] = s.merge;
	last_parallel = stats;
	return done;
}
