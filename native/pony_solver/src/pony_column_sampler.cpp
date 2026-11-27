// PonyColumnSampler: see pony_column_sampler.h (dev 2026-10-20 multithreading).
// A literal port of walk_grid_service.gd _sample_column(). GDScript floats are doubles and
// Vector3/AABB are single precision; each conversion below is the one the script makes.
#include "pony_column_sampler.h"

#include "terrain_reads.h"

#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <cmath>
#include <limits>
#include <utility>
#include <vector>

using namespace godot;

namespace {

// walk_grid.gd and walk_grid_service.gd constants.
constexpr int64_t CHUNK_CELLS = 64;
constexpr int64_t SPANS = 2;
constexpr double CELL = 0.25;
constexpr int64_t PAINT_SCALE = 50;
constexpr uint8_t SOLID = 1;
constexpr uint8_t WATER = 2;
constexpr uint32_t WATER_MASK = 1u << 15;
constexpr double PI_VALUE = 3.1415926535897932384626433833;

// ceili(rad_to_deg(acos(clampf(normal_y, -1, 1))) - .001)
int64_t slope_degrees(double normal_y) {
	const double clamped = normal_y < -1.0 ? -1.0 : (normal_y > 1.0 ? 1.0 : normal_y);
	return int64_t(std::ceil(std::acos(clamped) * (180.0 / PI_VALUE) - .001));
}

// maxf(0.0, value): MAX(a, b) is (a < b ? b : a).
double max_zero(double value) {
	return 0.0 < value ? value : 0.0;
}

// Perf 2026-11-21 (lane native_calls): terrain heights and normals read from Terrain3D's images
// (terrain_reads.h) instead of the script's height_at/normal_at, dictionary keys and names built
// once, and each collider's "navigation_ceiling" meta read once per call (by collider_id) instead
// of the collider object on every hit. Same rays, order and outputs. Rollback: false.
constexpr bool NATIVE_FAST_PATHS = true;
bool fast_paths = NATIVE_FAST_PATHS;

struct Keys {
	const Variant position = StringName("position");
	const Variant normal = StringName("normal");
	const Variant rid = StringName("rid");
	const Variant collider = StringName("collider");
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

struct ChunkArrays {
	PackedFloat32Array floor_y;
	PackedByteArray slope_deg;
	PackedFloat32Array water_depth;
	PackedFloat32Array headroom;
	PackedByteArray flags;
	PackedByteArray paint_cost;
	PackedByteArray trail_weight;
};

} // namespace

void PonyColumnSampler::_bind_methods() {
	ClassDB::bind_method(D_METHOD("sample", "space", "ray", "volume", "chunk", "first_column", "max_columns",
								 "deadline_usec", "bounds", "blockers", "terrain"),
			&PonyColumnSampler::sample);
	ClassDB::bind_static_method("PonyColumnSampler", D_METHOD("set_fast_paths", "enabled"), &PonyColumnSampler::set_fast_paths);
	ClassDB::bind_static_method("PonyColumnSampler", D_METHOD("get_fast_paths"), &PonyColumnSampler::get_fast_paths);
	ClassDB::bind_static_method("PonyColumnSampler", D_METHOD("terrain_reads", "terrain", "points"),
			&PonyColumnSampler::terrain_reads);
	ClassDB::bind_static_method("PonyColumnSampler", D_METHOD("set_follow_caller_block", "enabled"),
			&PonyColumnSampler::set_follow_caller_block);
	// Perf trial grid_parallel (pony_column_parallel.cpp).
	ClassDB::bind_method(D_METHOD("set_parallel", "enabled"), &PonyColumnSampler::set_parallel);
	ClassDB::bind_method(D_METHOD("get_parallel"), &PonyColumnSampler::get_parallel);
	ClassDB::bind_method(D_METHOD("set_merge_terrain", "enabled"), &PonyColumnSampler::set_merge_terrain);
	ClassDB::bind_method(D_METHOD("get_merge_terrain"), &PonyColumnSampler::get_merge_terrain);
	ClassDB::bind_method(D_METHOD("set_parallel_blocks", "blocks"), &PonyColumnSampler::set_parallel_blocks);
	ClassDB::bind_method(D_METHOD("get_last_parallel"), &PonyColumnSampler::get_last_parallel);
}

extern bool pony_follow_caller_block; // navigation_parallel.cpp

void PonyColumnSampler::set_follow_caller_block(bool p_enabled) {
	pony_follow_caller_block = p_enabled;
}

void PonyColumnSampler::set_fast_paths(bool p_enabled) {
	fast_paths = p_enabled;
}

bool PonyColumnSampler::get_fast_paths() {
	return fast_paths;
}

PackedFloat64Array PonyColumnSampler::terrain_reads(Object *p_terrain, const PackedVector3Array &p_points) {
	PackedFloat64Array out;
	pony::TerrainReads reads;
	if (!reads.bind(p_terrain)) {
		return out;
	}
	out.resize(p_points.size() * 4);
	double *w = out.ptrw();
	for (int64_t i = 0; i < p_points.size(); ++i) {
		const double h = reads.height_at(Vector3(p_points[i].x, 0.0f, p_points[i].z));
		const Vector3 n = reads.normal_at(Vector3(p_points[i].x, real_t(std::isfinite(h) ? h : 0.0), p_points[i].z));
		if (!reads.usable()) {
			return PackedFloat64Array();
		}
		w[i * 4] = h;
		w[i * 4 + 1] = n.x;
		w[i * 4 + 2] = n.y;
		w[i * 4 + 3] = n.z;
	}
	return out;
}

int64_t PonyColumnSampler::sample(Object *p_space, const Ref<PhysicsRayQueryParameters3D> &p_ray,
		const Ref<PhysicsShapeQueryParameters3D> &p_volume, Object *p_chunk, int64_t p_first_column,
		int64_t p_max_columns, int64_t p_deadline_usec, const AABB &p_bounds, const Array &p_blockers,
		Object *p_terrain) {
	PhysicsDirectSpaceState3D *space = Object::cast_to<PhysicsDirectSpaceState3D>(p_space);
	ERR_FAIL_NULL_V(space, 0);
	ERR_FAIL_COND_V(p_ray.is_null() || p_volume.is_null(), 0);
	ERR_FAIL_NULL_V(p_chunk, 0);
	if (parallel || merge_terrain) { // perf trial grid_parallel (pony_column_parallel.cpp)
		return sample_blocks(p_space, p_ray, p_volume, p_chunk, p_first_column, p_max_columns, p_deadline_usec, p_bounds,
				p_blockers, p_terrain);
	}
	const int64_t columns = CHUNK_CELLS * CHUNK_CELLS;
	if (p_first_column < 0 || p_first_column >= columns || p_max_columns <= 0) {
		return 0;
	}
	const Keys &k = keys();
	const bool fast = fast_paths;
	ChunkArrays a;
	a.floor_y = p_chunk->get(k.floor_y);
	a.slope_deg = p_chunk->get(k.slope_deg);
	a.water_depth = p_chunk->get(k.water_depth);
	a.headroom = p_chunk->get(k.headroom);
	a.flags = p_chunk->get(k.flags);
	a.paint_cost = p_chunk->get(k.paint_cost);
	a.trail_weight = p_chunk->get(k.trail_weight);
	const int64_t slots = columns * SPANS;
	ERR_FAIL_COND_V_MSG(a.floor_y.size() != slots || a.slope_deg.size() != slots || a.water_depth.size() != slots ||
					a.headroom.size() != slots || a.flags.size() != slots || a.paint_cost.size() != columns,
			0, "PonyColumnSampler needs an allocated WalkChunk");
	const Vector2i coord = p_chunk->get(k.coord);
	std::vector<AABB> blockers;
	for (int64_t i = 0; i < p_blockers.size(); ++i) {
		if (p_blockers[i].get_type() == Variant::AABB) {
			blockers.push_back(AABB(p_blockers[i]));
		}
	}
	const double top = double(p_bounds.get_end().y) + 5.0;
	const double bottom = double(p_bounds.position.y) - 5.0;
	const TypedArray<RID> base_excludes = p_ray->get_exclude();
	const Vector3 up(0, 1, 0);
	Time *time = Time::get_singleton();
	const StringName ceiling_meta("navigation_ceiling");
	// Fast path: each collider's ceiling meta once per call (nothing sets it during a call).
	std::vector<std::pair<uint64_t, bool>> ceilings;
	auto is_ceiling = [&](const Dictionary &p_hit) -> bool {
		if (!fast) {
			Object *collider = p_hit["collider"];
			return collider != nullptr && bool(collider->get_meta(ceiling_meta, false));
		}
		const uint64_t id = uint64_t(int64_t(p_hit[k.collider_id]));
		for (const std::pair<uint64_t, bool> &seen : ceilings) {
			if (seen.first == id) {
				return seen.second;
			}
		}
		Object *collider = ObjectDB::get_instance(id);
		const bool ceiling = collider != nullptr && bool(collider->get_meta(k.ceiling_meta, false));
		ceilings.emplace_back(id, ceiling);
		return ceiling;
	};
	// Fast path: the terrain read natively, bound on the first column that needs it.
	pony::TerrainReads reads;
	bool reads_bound = false;
	bool reads_ok = false;
	const Variant &key_position = fast ? k.position : Variant(String("position"));
	const Variant &key_normal = fast ? k.normal : Variant(String("normal"));
	const Variant &key_rid = fast ? k.rid : Variant(String("rid"));
	auto blocked = [&blockers](const Vector3 &point) {
		for (const AABB &box : blockers) {
			if (box.grow(real_t(.18)).has_point(point)) {
				return true;
			}
		}
		return false;
	};

	int64_t done = 0;
	for (; done < p_max_columns && p_first_column + done < columns; ++done) {
		if (done > 0 && int64_t(time->get_ticks_usec()) >= p_deadline_usec) {
			break;
		}
		const int64_t column = p_first_column + done;
		// chunk.clear_column(column)
		for (int64_t span = 0; span < SPANS; ++span) {
			const int64_t slot = column * SPANS + span;
			a.floor_y.set(slot, std::numeric_limits<float>::quiet_NaN());
			a.slope_deg.set(slot, 0);
			a.water_depth.set(slot, 0.0f);
			a.headroom.set(slot, std::numeric_limits<float>::infinity());
			a.flags.set(slot, 0);
			if (a.trail_weight.size() > slot) {
				a.trail_weight.set(slot, 0);
			}
		}
		a.paint_cost.set(column, uint8_t(PAINT_SCALE));
		const int64_t cell_x = int64_t(coord.x) * CHUNK_CELLS + column % CHUNK_CELLS;
		const int64_t cell_z = int64_t(coord.y) * CHUNK_CELLS + column / CHUNK_CELLS;
		const double x = (double(cell_x) + .5) * CELL;
		const double z = (double(cell_z) + .5) * CELL;
		p_ray->set_from(Vector3(real_t(x), real_t(top), real_t(z)));
		p_ray->set_to(Vector3(real_t(x), real_t(bottom), real_t(z)));
		p_ray->set_collision_mask(WATER_MASK);
		p_ray->set_hit_from_inside(false);
		const Dictionary water = space->intersect_ray(p_ray);
		const double water_y = water.is_empty() ? -std::numeric_limits<double>::infinity() : double(Vector3(water[key_position]).y);
		p_ray->set_collision_mask(1);
		double height = top;
		int64_t found = 0;
		TypedArray<RID> floor_excludes = base_excludes.duplicate();
		bool excluding = false;
		for (int attempt = 0; attempt < 6; ++attempt) {
			p_ray->set_from(Vector3(real_t(x), real_t(height), real_t(z)));
			p_ray->set_to(Vector3(real_t(x), real_t(bottom), real_t(z)));
			p_ray->set_hit_from_inside(false);
			// _ray.exclude = floor_excludes ... _ray.exclude = base_excludes (only differs after a ceiling).
			if (excluding) {
				p_ray->set_exclude(floor_excludes);
			}
			const Dictionary hit = space->intersect_ray(p_ray);
			if (excluding) {
				p_ray->set_exclude(base_excludes);
			}
			if (hit.is_empty()) {
				break;
			}
			const Vector3 position = hit[key_position];
			height = double(position.y) - .025;
			// Non-walkable roof/ceiling shells still block motion and headroom rays.
			if (is_ceiling(hit)) {
				floor_excludes.append(RID(hit[key_rid]));
				excluding = true;
				continue;
			}
			const Vector3 normal = hit[key_normal];
			if (double(normal.y) <= .01) {
				continue;
			}
			const int64_t slot = column * SPANS + found;
			a.floor_y.set(slot, position.y);
			a.slope_deg.set(slot, uint8_t(slope_degrees(double(normal.y))));
			a.water_depth.set(slot, float(max_zero(water_y - double(position.y))));
			a.flags.set(slot, uint8_t(SOLID | (double(a.water_depth[slot]) > .001 ? WATER : 0)));
			p_ray->set_from(position + up * real_t(.03));
			p_ray->set_to(Vector3(real_t(x), real_t(top), real_t(z)));
			p_ray->set_hit_from_inside(true);
			const Dictionary ceiling = space->intersect_ray(p_ray);
			a.headroom.set(slot, ceiling.is_empty() ? std::numeric_limits<float>::infinity()
													 : float(double(Vector3(ceiling[key_position]).y) - double(position.y)));
			// Catch thin vertical walls between column centres.
			p_volume->set_transform(Transform3D(Basis(), position + up * real_t(.237)));
			if (!space->intersect_shape(p_volume, 1).is_empty()) {
				a.headroom.set(slot, 0.0f);
			}
			if (blocked(position + up * real_t(.3))) {
				a.headroom.set(slot, 0.0f);
			}
			++found;
			if (found >= SPANS) {
				break;
			}
		}
		if (found == 0 && p_terrain != nullptr) {
			// No physics floor here: the world heightmap is the ground.
			const Vector3 ground_at{ real_t(x), 0.0f, real_t(z) };
			double ground = 0.0;
			bool read = false;
			if (fast) {
				if (!reads_bound) {
					reads_ok = reads.bind(p_terrain);
					reads_bound = true;
				}
				if (reads_ok) {
					ground = reads.height_at(ground_at);
					read = reads_ok = reads.usable();
				}
			}
			if (!read) {
				ground = double(p_terrain->call(fast ? k.height_at : StringName("height_at"), ground_at));
			}
			if (std::isfinite(ground)) {
				const Vector3 normal_at{ real_t(x), real_t(ground), real_t(z) };
				Vector3 normal;
				read = false;
				if (fast && reads_ok) {
					normal = reads.normal_at(normal_at);
					read = reads_ok = reads.usable();
				}
				if (!read) {
					normal = p_terrain->call(fast ? k.normal_at : StringName("normal_at"), normal_at);
				}
				const int64_t slot = column * SPANS;
				a.floor_y.set(slot, float(ground));
				a.slope_deg.set(slot, uint8_t(slope_degrees(double(normal.y))));
				a.water_depth.set(slot, float(max_zero(water_y - ground)));
				a.flags.set(slot, uint8_t(SOLID | (double(a.water_depth[slot]) > .001 ? WATER : 0)));
				const double reach = ground + 3.0;
				p_ray->set_from(Vector3(real_t(x), real_t(ground + .03), real_t(z)));
				p_ray->set_to(Vector3(real_t(x), real_t(reach < top ? top : reach), real_t(z)));
				p_ray->set_hit_from_inside(true);
				const Dictionary ceiling = space->intersect_ray(p_ray);
				a.headroom.set(slot, ceiling.is_empty() ? std::numeric_limits<float>::infinity()
														 : float(double(Vector3(ceiling[key_position]).y) - ground));
				p_volume->set_transform(Transform3D(Basis(), Vector3(real_t(x), real_t(ground + .237), real_t(z))));
				if (!space->intersect_shape(p_volume, 1).is_empty()) {
					a.headroom.set(slot, 0.0f);
				}
				if (blocked(Vector3(real_t(x), real_t(ground + .3), real_t(z)))) {
					a.headroom.set(slot, 0.0f);
				}
			}
		}
	}
	p_chunk->set(k.floor_y, a.floor_y);
	p_chunk->set(k.slope_deg, a.slope_deg);
	p_chunk->set(k.water_depth, a.water_depth);
	p_chunk->set(k.headroom, a.headroom);
	p_chunk->set(k.flags, a.flags);
	p_chunk->set(k.paint_cost, a.paint_cost);
	p_chunk->set(k.trail_weight, a.trail_weight);
	return done;
}
