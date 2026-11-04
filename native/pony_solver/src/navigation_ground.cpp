// Native pony navigation, ground search: see navigation_ground.h. Each function names the
// walk_planner.gd / walk_grid.gd code it ports. Positions are single precision like Godot's
// Vector3 and are combined in the same order; scores and costs are doubles like GDScript floats.
#include "navigation_ground.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <unordered_map>

namespace ponynav {

const char *status_name(RouteStatus status) {
	switch (status) {
		case RouteStatus::PENDING:
			return "pending";
		case RouteStatus::COMPLETE:
			return "complete";
		case RouteStatus::PARTIAL:
			return "partial";
		case RouteStatus::WAITING_FOR_GEOMETRY:
			return "waiting_for_geometry";
		case RouteStatus::BUDGET_EXHAUSTED:
			return "budget_exhausted";
		case RouteStatus::UNREACHABLE:
			return "unreachable";
		case RouteStatus::CANCELLED:
			return "cancelled";
		case RouteStatus::STALE:
			return "stale";
		case RouteStatus::NO_FLOOR:
			return "no_floor";
		case RouteStatus::INVALID:
			return "invalid";
	}
	return "unknown";
}

namespace {

constexpr double RAD_TO_DEG = 180.0 / 3.1415926535897932384626433833;
constexpr double PI_VALUE = 3.1415926535897932384626433833;
// walk_planner.gd constants.
constexpr double START_REACH = 2.5;
constexpr double GOAL_REACH = 3.0;
constexpr int64_t MAX_CORRIDOR_SAMPLES = 512;
constexpr int64_t MAX_SMOOTH_CHECKS = 4096;
constexpr double CORRIDOR_STEP = CELL * 0.5;
constexpr double OUTPUT_STEP = 0.5;
const char *DISCONNECTED = "Destination is disconnected in sampled terrain";

// Godot Vector2::length() with single-precision real_t.
inline float length2f(float x, float z) {
	return std::sqrt(x * x + z * z);
}

inline Vec3f lerp3(const Vec3f &a, const Vec3f &b, float t) {
	return Vec3f(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t);
}

inline Vec3f scale3(const Vec3f &a, float s) {
	return Vec3f(a.x * s, a.y * s, a.z * s);
}

inline Vec3f add3(const Vec3f &a, const Vec3f &b) {
	return Vec3f(a.x + b.x, a.y + b.y, a.z + b.z);
}

inline Vec3f sub3(const Vec3f &a, const Vec3f &b) {
	return Vec3f(a.x - b.x, a.y - b.y, a.z - b.z);
}

// Godot Vector3::distance_squared_to(), single precision.
inline float distance_squared3(const Vec3f &from, const Vec3f &to) {
	const float x = to.x - from.x;
	const float y = to.y - from.y;
	const float z = to.z - from.z;
	const float x2 = x * x;
	const float y2 = y * y;
	const float z2 = z * z;
	return x2 + y2 + z2;
}

inline double lerp_double(double from, double to, double weight) {
	return from + (to - from) * weight;
}

inline int64_t ceil_int(double value) {
	return int64_t(std::ceil(value));
}

// Neighbour chunk code (dz + 1) * 3 + (dx + 1).
inline uint8_t neighbour_code(int32_t dx, int32_t dz) {
	return uint8_t((dz + 1) * 3 + (dx + 1));
}

// Deterministic tie key from global cell and slot: equal f and h always pop in one order,
// independent of which other chunks a snapshot holds.
inline uint64_t cell_tie(int32_t x, int32_t z, uint32_t slot) {
	const uint64_t bias = uint64_t(1) << 27;
	return ((uint64_t(int64_t(z) + int64_t(bias)) & 0xfffffffull) << 36) |
			((uint64_t(int64_t(x) + int64_t(bias)) & 0xfffffffull) << 8) | uint64_t(slot & 0xffu);
}

// walk_planner.gd _stable_fraction(): GDScript 64-bit integer arithmetic (wrapping).
double stable_fraction(float pos_x, float pos_y, int64_t salt) {
	const int64_t fx = int64_t(std::floor(double(pos_x) / CELL));
	const int64_t fy = int64_t(std::floor(double(pos_y) / CELL));
	uint64_t value = (uint64_t(fx) * 73856093ull) ^ (uint64_t(fy) * 19349663ull) ^ (uint64_t(salt) * 83492791ull);
	const int64_t signed_value = int64_t(value);
	const uint64_t shifted = uint64_t(signed_value >> 13);
	value = ((value ^ shifted) * 1274126177ull) & 0x7fffffffull;
	return double(int64_t(value) % 100000) / 100000.0;
}

} // namespace

RoomOffsets make_room_offsets(double radius) {
	RoomOffsets offsets;
	offsets.radius = radius;
	offsets.reach = int32_t(ceil_int(radius / CELL));
	for (int32_t z = -offsets.reach; z <= offsets.reach; ++z) {
		for (int32_t x = -offsets.reach; x <= offsets.reach; ++x) {
			if (x * x + z * z == 0) {
				continue;
			}
			const double length = double(length2f(float(x), float(z))) * CELL;
			if (length > radius) {
				continue;
			}
			offsets.dx.push_back(x);
			offsets.dz.push_back(z);
			offsets.length.push_back(length);
		}
	}
	return offsets;
}

double GroundAccess::direction_distance(int dir) {
	static const double ORTHOGONAL = double(length2f(1.0f, 0.0f)) * CELL;
	static const double DIAGONAL = double(length2f(1.0f, 1.0f)) * CELL;
	return (DIR_X[dir] != 0 && DIR_Z[dir] != 0) ? DIAGONAL : ORTHOGONAL;
}

GroundAccess::GroundAccess(std::shared_ptr<const Snapshot> p_snapshot, std::shared_ptr<ClearanceCache> p_cache,
		const GroundProfile &p_profile) :
		snap(std::move(p_snapshot)), cache(std::move(p_cache)), prof(p_profile.effective()) {
	// walk_planner.gd profile setter: WalkGrid.connected() terms computed once.
	step_limit = prof.step + .0001;
	grade_limit = prof.slope + .05;
	wade_floor_value = std::max(prof.wade, .01);
	body = make_room_offsets(prof.radius);
	layers.resize(snap->chunks.size());
}

int32_t GroundAccess::chunk_index(const ChunkKey &key) {
	const uint64_t packed = key.packed();
	if (cached_valid && packed == cached_key) {
		return cached_index;
	}
	cached_valid = true;
	cached_key = packed;
	cached_index = snap->find(key);
	return cached_index;
}

GroundAccess::Column GroundAccess::column(int32_t x, int32_t z) {
	Column result;
	const int32_t index = chunk_index(ChunkKey::of_cell(x, z));
	if (index < 0) {
		return result;
	}
	const GroundChunk &owner = *snap->chunks[size_t(index)];
	const int32_t local = local_column(x, z);
	result.chunk = index;
	result.first = owner.column_offsets[size_t(local)];
	result.count = owner.column_offsets[size_t(local) + 1] - result.first;
	return result;
}

void GroundAccess::cell(Handle handle, int32_t &x, int32_t &z) const {
	const GroundChunk &owner = *snap->chunks[handle_chunk(handle)];
	const uint32_t local = owner.spans[handle_span(handle)].column();
	x = owner.key.x * CHUNK_CELLS + int32_t(local % uint32_t(CHUNK_CELLS));
	z = owner.key.z * CHUNK_CELLS + int32_t(local / uint32_t(CHUNK_CELLS));
}

CellKey GroundAccess::key(Handle handle) const {
	CellKey result;
	if (handle == NO_HANDLE) {
		return result;
	}
	cell(handle, result.x, result.z);
	result.slot = int32_t(span(handle).slot());
	return result;
}

Handle GroundAccess::find(const CellKey &key) {
	if (!key.valid()) {
		return NO_HANDLE;
	}
	const Column found = column(key.x, key.z);
	if (found.chunk < 0) {
		return NO_HANDLE;
	}
	const GroundChunk &owner = chunk(uint32_t(found.chunk));
	for (uint32_t i = 0; i < found.count; ++i) {
		if (int32_t(owner.spans[found.first + i].slot()) == key.slot) {
			return make_handle(uint32_t(found.chunk), found.first + i);
		}
	}
	return NO_HANDLE;
}

Vec3f GroundAccess::point(Handle handle) const {
	int32_t x = 0;
	int32_t z = 0;
	cell(handle, x, z);
	return Vec3f(float((double(x) + .5) * CELL), span(handle).floor_y, float((double(z) + .5) * CELL));
}

bool GroundAccess::allowed(const FloorSpan &span) const {
	// WalkGrid.allowed(); comparisons written in GDScript's direction so NaN rejects alike.
	if (span.flags & (FLAG_NO_CLEARANCE | FLAG_PAINT_BLOCK)) {
		return false;
	}
	if (!(double(span.slope_deg) <= prof.slope)) {
		return false;
	}
	if (!(double(span.headroom) + .001 >= prof.clearance)) {
		return false;
	}
	if (!(double(span.water_depth) <= prof.wade + .001 || prof.swim)) {
		return false;
	}
	return true;
}

bool GroundAccess::link_from(const FloorSpan &a, const FloorSpan &b, double distance) const {
	if (!allowed(b)) {
		return false;
	}
	const double rise = std::fabs(double(a.floor_y) - double(b.floor_y));
	if (rise <= step_limit) {
		return true;
	}
	// Flat ledges cannot borrow the gradient allowance of a continuous ramp.
	const double grade = std::atan2(rise, distance) * RAD_TO_DEG;
	return grade <= grade_limit && std::max(double(a.slope_deg), double(b.slope_deg)) >= grade - 1.5;
}

bool GroundAccess::link(const FloorSpan &a, const FloorSpan &b, double distance) const {
	return allowed(a) && link_from(a, b, distance);
}

ProfileLayer &GroundAccess::layer(uint32_t index) {
	std::shared_ptr<ProfileLayer> &slot = layers[index];
	if (slot) {
		return *slot;
	}
	const GroundChunk &owner = chunk(index);
	std::array<uint64_t, 25> stamp{};
	size_t at = 0;
	for (int32_t dz = -2; dz <= 2; ++dz) {
		for (int32_t dx = -2; dx <= 2; ++dx) {
			ChunkKey near;
			near.x = owner.key.x + dx;
			near.z = owner.key.z + dz;
			stamp[at++] = snap->revision_of(near);
		}
	}
	if (cache) {
		slot = cache->acquire(owner.key, prof, stamp, owner.span_count());
	} else {
		slot = std::make_shared<ProfileLayer>(owner.span_count());
		slot->stamp = stamp;
	}
	return *slot;
}

bool GroundAccess::compute_room(Handle handle, const RoomOffsets &offsets) {
	// WalkGrid.has_room() / walk_planner.gd _has_room_r().
	++rooms_computed;
	const FloorSpan &center = span(handle);
	if (!allowed(center)) {
		return false;
	}
	int32_t x = 0;
	int32_t z = 0;
	cell(handle, x, z);
	for (size_t i = 0; i < offsets.dx.size(); ++i) {
		const Column other = column(x + offsets.dx[i], z + offsets.dz[i]);
		bool found = false;
		if (other.chunk >= 0) {
			const GroundChunk &owner = chunk(uint32_t(other.chunk));
			for (uint32_t k = 0; k < other.count; ++k) {
				if (link_from(center, owner.spans[other.first + k], offsets.length[i])) {
					found = true;
					break;
				}
			}
		}
		if (!found) {
			return false;
		}
	}
	return true;
}

bool GroundAccess::pure_room(Handle handle) {
	ProfileLayer &target = layer(handle_chunk(handle));
	std::atomic<uint8_t> &value = target.room[handle_span(handle)];
	const uint8_t known = value.load(std::memory_order_relaxed);
	if (known != 0) {
		return known == 2;
	}
	const bool result = compute_room(handle, body);
	value.store(result ? 2 : 1, std::memory_order_relaxed);
	return result;
}

bool GroundAccess::room_radius(Handle handle, double radius) {
	uint64_t a = 0;
	uint64_t b = 0;
	std::memcpy(&a, &radius, sizeof(a));
	std::memcpy(&b, &prof.radius, sizeof(b));
	if (a == b) {
		return pure_room(handle);
	}
	RadiusMemo *memo = nullptr;
	for (const std::unique_ptr<RadiusMemo> &candidate : radius_memos) {
		uint64_t c = 0;
		std::memcpy(&c, &candidate->offsets.radius, sizeof(c));
		if (c == a) {
			memo = candidate.get();
			break;
		}
	}
	if (memo == nullptr) {
		radius_memos.push_back(std::unique_ptr<RadiusMemo>(new RadiusMemo()));
		memo = radius_memos.back().get();
		memo->offsets = make_room_offsets(radius);
	}
	const auto found = memo->known.find(handle);
	if (found != memo->known.end()) {
		return found->second;
	}
	const bool result = compute_room(handle, memo->offsets);
	memo->known[handle] = result;
	return result;
}

void GroundAccess::ensure_components(uint32_t index) {
	ProfileLayer &target = layer(index);
	if (target.components_ready.load(std::memory_order_acquire)) {
		return;
	}
	std::lock_guard<std::mutex> lock(target.build_mutex);
	if (target.components_ready.load(std::memory_order_acquire)) {
		return;
	}
	build_components(index, target);
	target.components_ready.store(true, std::memory_order_release);
}

void GroundAccess::build_components(uint32_t index, ProfileLayer &target) {
	++components_built;
	const GroundChunk &owner = chunk(index);
	const uint32_t count = owner.span_count();
	auto room = [this](Handle handle) { return pure_room(handle); };
	std::vector<uint32_t> component(count, NO_COMPONENT);
	std::vector<uint32_t> stack;
	uint32_t components = 0;
	// Flood fill over the same edges the cell search uses, restricted to this chunk. Edges
	// between cells with body room are symmetric, so each fill is one connected component.
	for (uint32_t start = 0; start < count; ++start) {
		if (component[start] != NO_COMPONENT || !pure_room(make_handle(index, start))) {
			continue;
		}
		component[start] = components;
		stack.push_back(start);
		while (!stack.empty()) {
			const uint32_t current = stack.back();
			stack.pop_back();
			const FloorSpan &source = owner.spans[current];
			int32_t sx = 0;
			int32_t sz = 0;
			cell(make_handle(index, current), sx, sz);
			for (int dir = 0; dir < 8; ++dir) {
				const int32_t nx = sx + DIR_X[dir];
				const int32_t nz = sz + DIR_Z[dir];
				if (ChunkKey::of_cell(nx, nz) != owner.key) {
					continue;
				}
				const int32_t local = local_column(nx, nz);
				const uint32_t end = owner.column_offsets[size_t(local) + 1];
				for (uint32_t other = owner.column_offsets[size_t(local)]; other < end; ++other) {
					if (component[other] != NO_COMPONENT) {
						continue;
					}
					if (edge(source, sx, sz, dir, make_handle(index, other), owner.spans[other], room)) {
						component[other] = components;
						stack.push_back(other);
					}
				}
			}
		}
		++components;
	}
	// Frontier reach: a reached cell marks missing chunks it or its neighbours' body-room
	// probes touch (walk_planner.gd neighbors() and _room()). Over-approximate by margin.
	const int32_t margin = body.reach + 1;
	std::vector<uint8_t> touch_bits(components, 0);
	struct RawPortal {
		uint32_t component;
		uint8_t neighbour;
		uint32_t target;
	};
	std::vector<RawPortal> raw;
	for (uint32_t s = 0; s < count; ++s) {
		const uint32_t id = component[s];
		if (id == NO_COMPONENT) {
			continue;
		}
		const uint32_t local = owner.spans[s].column();
		const int32_t lx = int32_t(local % uint32_t(CHUNK_CELLS));
		const int32_t lz = int32_t(local / uint32_t(CHUNK_CELLS));
		const bool west = lx < margin;
		const bool east = lx > CHUNK_CELLS - 1 - margin;
		const bool north = lz < margin;
		const bool south = lz > CHUNK_CELLS - 1 - margin;
		uint8_t bits = 0;
		if (west) bits |= uint8_t(1u << neighbour_code(-1, 0));
		if (east) bits |= uint8_t(1u << neighbour_code(1, 0));
		if (north) bits |= uint8_t(1u << neighbour_code(0, -1));
		if (south) bits |= uint8_t(1u << neighbour_code(0, 1));
		touch_bits[id] |= bits; // corner chunks are derived from two edge bits when used
		// Portals: edges from a border cell into a neighbouring chunk.
		if (lx != 0 && lx != CHUNK_CELLS - 1 && lz != 0 && lz != CHUNK_CELLS - 1) {
			continue;
		}
		int32_t sx = 0;
		int32_t sz = 0;
		const Handle source_handle = make_handle(index, s);
		cell(source_handle, sx, sz);
		const FloorSpan &source = owner.spans[s];
		for (int dir = 0; dir < 8; ++dir) {
			const int32_t nx = sx + DIR_X[dir];
			const int32_t nz = sz + DIR_Z[dir];
			const ChunkKey near = ChunkKey::of_cell(nx, nz);
			if (near == owner.key) {
				continue;
			}
			const Column target_column = column(nx, nz);
			if (target_column.chunk < 0) {
				continue;
			}
			const GroundChunk &target_chunk = chunk(uint32_t(target_column.chunk));
			for (uint32_t k = 0; k < target_column.count; ++k) {
				const uint32_t target_span = target_column.first + k;
				if (edge(source, sx, sz, dir, make_handle(uint32_t(target_column.chunk), target_span),
							target_chunk.spans[target_span], room)) {
					raw.push_back({ id, neighbour_code(near.x - owner.key.x, near.z - owner.key.z), target_span });
				}
			}
		}
	}
	std::sort(raw.begin(), raw.end(), [](const RawPortal &a, const RawPortal &b) {
		if (a.component != b.component) return a.component < b.component;
		if (a.neighbour != b.neighbour) return a.neighbour < b.neighbour;
		return a.target < b.target;
	});
	raw.erase(std::unique(raw.begin(), raw.end(),
					  [](const RawPortal &a, const RawPortal &b) {
						  return a.component == b.component && a.neighbour == b.neighbour && a.target == b.target;
					  }),
			raw.end());
	target.component = std::move(component);
	target.component_count = components;
	target.touch = std::move(touch_bits);
	target.portal_offsets.assign(size_t(components) + 1, 0);
	target.portals.clear();
	target.portals.reserve(raw.size());
	size_t cursor = 0;
	for (uint32_t id = 0; id < components; ++id) {
		target.portal_offsets[id] = uint32_t(target.portals.size());
		while (cursor < raw.size() && raw[cursor].component == id) {
			Portal portal;
			portal.neighbour = raw[cursor].neighbour;
			portal.target_span = raw[cursor].target;
			target.portals.push_back(portal);
			++cursor;
		}
	}
	target.portal_offsets[components] = uint32_t(target.portals.size());
}

// ---------------------------------------------------------------------------------------------
// GroundSearch

namespace {

struct HeapEntry {
	double f;
	double g;
	double h;
	uint64_t tie;
	Handle node;
};

// Min-heap order: f, then h, then the cell tie key.
struct HeapAfter {
	bool operator()(const HeapEntry &a, const HeapEntry &b) const {
		if (a.f != b.f) return a.f > b.f;
		if (a.h != b.h) return a.h > b.h;
		return a.tie > b.tie;
	}
};

struct CoarseEntry {
	double f;
	double g;
	uint64_t node;
};

struct CoarseAfter {
	bool operator()(const CoarseEntry &a, const CoarseEntry &b) const {
		if (a.f != b.f) return a.f > b.f;
		return a.node > b.node;
	}
};

struct Certified {
	bool valid = false;
	std::vector<Vec3f> points;
	double cost = 0.0;
};

using Clock = std::chrono::steady_clock;

} // namespace

struct GroundSearch::Impl {
	enum class Phase { INIT, COARSE, DETAILED, SMOOTH, DONE };

	GroundAccess ground;
	Vec3f from;
	Vec3f to;
	SearchOptions options;
	SearchOutput out;
	Phase phase = Phase::INIT;

	Handle start = NO_HANDLE;
	Handle goal = NO_HANDLE;
	std::unordered_set<Handle> goals;
	int32_t goal_min_x = 0;
	int32_t goal_max_x = 0;
	int32_t goal_min_z = 0;
	int32_t goal_max_z = 0;
	std::unordered_set<Handle> seeds;
	double minimum_cost = .48;
	std::unordered_set<uint64_t> frontier;

	// Component/portal corridor.
	std::unordered_map<uint64_t, std::pair<double, uint64_t>> coarse_best;
	std::vector<CoarseEntry> coarse_heap;
	std::unordered_set<uint64_t> coarse_goals;
	ChunkKey coarse_goal_min;
	ChunkKey coarse_goal_max;
	std::vector<uint8_t> corridor;
	bool corridor_active = false;

	// Cell A*: per-chunk pages of stamped arrays, owned by this search.
	struct Page {
		std::unique_ptr<double[]> g;
		std::unique_ptr<Handle[]> parent;
		std::unique_ptr<uint32_t[]> stamp;
	};
	std::vector<std::unique_ptr<Page>> pages;
	uint32_t stamp = 0;
	std::vector<HeapEntry> heap;
	bool detailed_started = false;
	Handle reached = NO_HANDLE;
	Handle best_partial = NO_HANDLE;
	double best_partial_h = INF;
	double best_partial_g = INF;

	int64_t smoothing_checks = 0;

	Impl(std::shared_ptr<const Snapshot> snapshot, std::shared_ptr<ClearanceCache> cache, const GroundProfile &profile,
			const Vec3f &p_from, const Vec3f &p_to, const SearchOptions &p_options) :
			ground(std::move(snapshot), std::move(cache), profile), from(p_from), to(p_to), options(p_options) {}

	// ---- helpers --------------------------------------------------------------------------

	void finish(RouteStatus status, const std::string &reason) {
		out.status = status;
		out.reason = reason;
		phase = Phase::DONE;
	}

	// walk_planner.gd _room(): seeded cramped-start room, then the body-room verdict; a cell
	// without room near a missing chunk marks that chunk as frontier.
	bool search_room(Handle handle) {
		if (!seeds.empty() && seeds.count(handle) != 0) {
			return true;
		}
		if (!options.blocked.empty() && blocked_cell(handle)) {
			return false;
		}
		const bool result = ground.pure_room(handle);
		if (!result) {
			mark_room_frontier(handle);
		}
		return result;
	}

	bool blocked_cell(Handle handle) const {
		int32_t x = 0;
		int32_t z = 0;
		ground.cell(handle, x, z);
		const double cx = (double(x) + .5) * CELL;
		const double cz = (double(z) + .5) * CELL;
		for (const SearchBlock &block : options.blocked) {
			const double dx = cx - block.x;
			const double dz = cz - block.z;
			if (dx * dx + dz * dz <= block.radius * block.radius) {
				return true;
			}
		}
		return false;
	}

	// Phase 2 escape seeds: allowed cells connected to the start cell within escape_reach.
	void seed_escape(Handle from) {
		int32_t sx = 0;
		int32_t sz = 0;
		ground.cell(from, sx, sz);
		const double reach = options.escape_reach;
		std::vector<Handle> stack{ from };
		seeds.insert(from);
		auto allowed_room = [this](Handle handle) { return ground.allowed(ground.span(handle)); };
		while (!stack.empty()) {
			const Handle current = stack.back();
			stack.pop_back();
			const FloorSpan &source = ground.span(current);
			int32_t cx = 0;
			int32_t cz = 0;
			ground.cell(current, cx, cz);
			for (int dir = 0; dir < 8; ++dir) {
				const int32_t nx = cx + DIR_X[dir];
				const int32_t nz = cz + DIR_Z[dir];
				const double ox = double(nx - sx) * CELL;
				const double oz = double(nz - sz) * CELL;
				if (ox * ox + oz * oz > reach * reach) {
					continue;
				}
				const GroundAccess::Column column = ground.column(nx, nz);
				if (column.chunk < 0) {
					continue;
				}
				for (uint32_t i = 0; i < column.count; ++i) {
					const Handle next = make_handle(uint32_t(column.chunk), column.first + i);
					if (seeds.count(next) != 0) {
						continue;
					}
					const FloorSpan &dest = ground.span(next);
					if (!options.blocked.empty() && blocked_cell(next)) {
						continue;
					}
					if (ground.edge(source, cx, cz, dir, next, dest, allowed_room)) {
						seeds.insert(next);
						stack.push_back(next);
					}
				}
			}
		}
	}

	void mark_room_frontier(Handle handle) {
		const int32_t r = ground.body_offsets().reach;
		const uint32_t local = ground.span(handle).column();
		const int32_t lx = int32_t(local % uint32_t(CHUNK_CELLS));
		const int32_t lz = int32_t(local / uint32_t(CHUNK_CELLS));
		if (lx - r >= 0 && lx + r < CHUNK_CELLS && lz - r >= 0 && lz + r < CHUNK_CELLS) {
			return;
		}
		int32_t x = 0;
		int32_t z = 0;
		ground.cell(handle, x, z);
		const int32_t offsets[4][2] = { { -r, 0 }, { r, 0 }, { 0, -r }, { 0, r } };
		for (const auto &offset : offsets) {
			const ChunkKey near = ChunkKey::of_cell(x + offset[0], z + offset[1]);
			if (ground.chunk_index(near) < 0) {
				frontier.insert(near.packed());
			}
		}
	}

	// walk_planner.gd cost(a, b).
	double edge_cost(double distance, const FloorSpan &dest) const {
		const double water = 1.0 + 4.0 * double(dest.water_depth) / ground.wade_floor();
		return distance * (1.0 + double(dest.slope_deg) / 45.0) * water * span_paint(dest);
	}

	double cost(Handle a, Handle b) {
		int32_t ax = 0, az = 0, bx = 0, bz = 0;
		ground.cell(a, ax, az);
		ground.cell(b, bx, bz);
		const double distance = double(length2f(float(ax - bx), float(az - bz))) * CELL;
		return edge_cost(distance, ground.span(b));
	}

	double heuristic(int32_t x, int32_t z) const {
		if (options.dijkstra) {
			return 0.0;
		}
		// Distance to the goal region's bounding box: a lower bound to every goal cell.
		const double dx = double(std::max({ goal_min_x - x, 0, x - goal_max_x }));
		const double dz = double(std::max({ goal_min_z - z, 0, z - goal_max_z }));
		return std::sqrt(dx * dx + dz * dz) * CELL * minimum_cost;
	}

	// walk_planner.gd _nearest(): nearest allowed cell with body room within `radius`.
	Handle nearest(const Vec3f &position, double radius) {
		const int32_t cx = cell_coord(double(position.x));
		const int32_t cz = cell_coord(double(position.z));
		Handle best = NO_HANDLE;
		double best_d = radius * radius;
		const int32_t r = int32_t(ceil_int(radius / CELL));
		for (int32_t z = -r; z <= r; ++z) {
			for (int32_t x = -r; x <= r; ++x) {
				const GroundAccess::Column column = ground.column(cx + x, cz + z);
				for (uint32_t i = 0; i < column.count; ++i) {
					const Handle handle = make_handle(uint32_t(column.chunk), column.first + i);
					if (!ground.allowed(ground.span(handle))) {
						continue;
					}
					const float d = distance_squared3(ground.point(handle), position);
					// A goal inside a blocked disc (a pony standing on it) is no goal: the search
					// then ends on the nearest free cell of the GOAL_REACH region instead.
					if (double(d) <= best_d && ground.pure_room(handle) &&
							(options.blocked.empty() || !blocked_cell(handle))) {
						best_d = double(d);
						best = handle;
					}
				}
			}
		}
		return best;
	}

	// walk_planner.gd _nearest_allowed(): ignores body room (cramped start).
	Handle nearest_allowed(const Vec3f &position, double radius) {
		const int32_t cx = cell_coord(double(position.x));
		const int32_t cz = cell_coord(double(position.z));
		Handle best = NO_HANDLE;
		double best_d = radius * radius;
		const int32_t r = int32_t(ceil_int(radius / CELL));
		for (int32_t z = -r; z <= r; ++z) {
			for (int32_t x = -r; x <= r; ++x) {
				const GroundAccess::Column column = ground.column(cx + x, cz + z);
				for (uint32_t i = 0; i < column.count; ++i) {
					const Handle handle = make_handle(uint32_t(column.chunk), column.first + i);
					if (!ground.allowed(ground.span(handle))) {
						continue;
					}
					const float d = distance_squared3(ground.point(handle), position);
					if (double(d) < best_d) {
						best_d = double(d);
						best = handle;
					}
				}
			}
		}
		return best;
	}

	void add_goal_region(double reach_radius) {
		// Every cell with room within `reach_radius` is a goal; the nearest becomes `goal`.
		const int32_t cx = cell_coord(double(to.x));
		const int32_t cz = cell_coord(double(to.z));
		const int32_t reach = int32_t(ceil_int(reach_radius / CELL));
		double nearest_d = INF;
		for (int32_t z = -reach; z <= reach; ++z) {
			for (int32_t x = -reach; x <= reach; ++x) {
				if (double(length2f(float(x), float(z))) * CELL > reach_radius) {
					continue;
				}
				const GroundAccess::Column column = ground.column(cx + x, cz + z);
				for (uint32_t i = 0; i < column.count; ++i) {
					const Handle candidate = make_handle(uint32_t(column.chunk), column.first + i);
					if (!search_room(candidate)) {
						continue;
					}
					goals.insert(candidate);
					const float d = distance_squared3(ground.point(candidate), to);
					if (double(d) < nearest_d) {
						nearest_d = double(d);
						goal = candidate;
					}
				}
			}
		}
	}

	// ---- INIT (walk_planner.gd plan()) ------------------------------------------------------

	void init() {
		if (!from.finite() || !to.finite()) {
			finish(RouteStatus::INVALID, "Route endpoints must be finite");
			return;
		}
		// Admissible lower bound from this snapshot's actual span costs (trails and fords
		// included): every edge costs at least its length * CELL * minimum_cost.
		minimum_cost = ground.snapshot().cost_floor;
		if (!std::isfinite(minimum_cost)) {
			minimum_cost = .48;
		}
		// Anchor to the floor she actually occupies before checking body room. A roomy
		// cell beside/below a narrow ramp is not a reachable replacement for its surface.
		start = nearest_allowed(from, 1.0);
		if (start == NO_HANDLE) start = nearest_allowed(from, START_REACH);
		if (start != NO_HANDLE && !search_room(start)) {
			if (start != NO_HANDLE && options.escape_reach > 0.0) {
				out.start_cramped = true;
				seed_escape(start);
			} else if (start != NO_HANDLE) {
				out.start_cramped = true;
				int32_t sx = 0;
				int32_t sz = 0;
				ground.cell(start, sx, sz);
				const int32_t r = int32_t(ceil_int(ground.profile().radius / CELL));
				for (int32_t z = -r; z <= r; ++z) {
					for (int32_t x = -r; x <= r; ++x) {
						const GroundAccess::Column column = ground.column(sx + x, sz + z);
						for (uint32_t i = 0; i < column.count; ++i) {
							const Handle handle = make_handle(uint32_t(column.chunk), column.first + i);
							if (ground.allowed(ground.span(handle))) {
								seeds.insert(handle);
							}
						}
					}
				}
			}
		}
		if (options.goal_radius > 0.0) {
			add_goal_region(options.goal_radius);
		} else {
			goal = nearest(to, 1.0);
			if (goal != NO_HANDLE) {
				goals.insert(goal);
			}
			// A destination with no room within a metre is not unreachable: every room cell
			// within GOAL_REACH is a goal and the search ends on a reachable one.
			if (goals.empty() || options.any_floor) {
				add_goal_region(GOAL_REACH);
			}
		}
		out.start = ground.key(start);
		out.goal = ground.key(goal);
		out.goal_count = int64_t(goals.size());
		if (start == NO_HANDLE || goals.empty()) {
			finish(RouteStatus::NO_FLOOR, "No safe floor at start or destination");
			return;
		}
		bool first = true;
		for (Handle candidate : goals) {
			int32_t x = 0;
			int32_t z = 0;
			ground.cell(candidate, x, z);
			if (first) {
				goal_min_x = goal_max_x = x;
				goal_min_z = goal_max_z = z;
				first = false;
			} else {
				goal_min_x = std::min(goal_min_x, x);
				goal_max_x = std::max(goal_max_x, x);
				goal_min_z = std::min(goal_min_z, z);
				goal_max_z = std::max(goal_max_z, z);
			}
		}
		phase = coarse_wanted() ? Phase::COARSE : Phase::DETAILED;
	}

	bool coarse_wanted() {
		// walk_planner.gd skips its chunk corridor inside one chunk and in tiny snapshots.
		if (!options.use_corridor || ground.snapshot().chunks.size() < 16 || !options.blocked.empty()) {
			return false;
		}
		if (handle_chunk(start) == handle_chunk(goal)) {
			return false;
		}
		// Seeded (cramped) cells are not in the pure-room component graph.
		if (!seeds.empty() && !ground.pure_room(start)) {
			return false;
		}
		ground.ensure_components(handle_chunk(start));
		if (ground.layer(handle_chunk(start)).component[handle_span(start)] == NO_COMPONENT) {
			return false;
		}
		bool first = true;
		for (Handle candidate : goals) {
			const uint32_t index = handle_chunk(candidate);
			ground.ensure_components(index);
			const uint32_t id = ground.layer(index).component[handle_span(candidate)];
			if (id == NO_COMPONENT) {
				return false;
			}
			coarse_goals.insert((uint64_t(index) << 32) | id);
			const ChunkKey key = ground.chunk(index).key;
			if (first) {
				coarse_goal_min = coarse_goal_max = key;
				first = false;
			} else {
				coarse_goal_min.x = std::min(coarse_goal_min.x, key.x);
				coarse_goal_min.z = std::min(coarse_goal_min.z, key.z);
				coarse_goal_max.x = std::max(coarse_goal_max.x, key.x);
				coarse_goal_max.z = std::max(coarse_goal_max.z, key.z);
			}
		}
		const uint32_t start_chunk = handle_chunk(start);
		const uint64_t node =
				(uint64_t(start_chunk) << 32) | ground.layer(start_chunk).component[handle_span(start)];
		coarse_best[node] = std::make_pair(0.0, ~uint64_t(0));
		coarse_heap.push_back({ coarse_heuristic(start_chunk), 0.0, node });
		return true;
	}

	double coarse_heuristic(uint32_t index) const {
		const ChunkKey key = ground.chunk(index).key;
		const double dx = double(std::max({ coarse_goal_min.x - key.x, 0, key.x - coarse_goal_max.x }));
		const double dz = double(std::max({ coarse_goal_min.z - key.z, 0, key.z - coarse_goal_max.z }));
		return std::sqrt(dx * dx + dz * dz);
	}

	// ---- COARSE: component/portal A* --------------------------------------------------------

	// Returns true when the slice should end.
	bool coarse_step(const Clock::time_point &deadline, bool timed, const std::atomic<bool> *cancel) {
		while (!coarse_heap.empty()) {
			if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) {
				finish(RouteStatus::CANCELLED, "Cancelled");
				return true;
			}
			std::pop_heap(coarse_heap.begin(), coarse_heap.end(), CoarseAfter());
			const CoarseEntry entry = coarse_heap.back();
			coarse_heap.pop_back();
			const auto best = coarse_best.find(entry.node);
			if (best == coarse_best.end() || entry.g > best->second.first) {
				continue;
			}
			++out.coarse_expanded;
			if (coarse_goals.count(entry.node) != 0) {
				build_corridor(entry.node);
				phase = Phase::DETAILED;
				return false;
			}
			const uint32_t index = uint32_t(entry.node >> 32);
			const uint32_t id = uint32_t(entry.node & 0xffffffffu);
			ground.ensure_components(index);
			ProfileLayer &here = ground.layer(index);
			const ChunkKey key = ground.chunk(index).key;
			for (uint32_t p = here.portal_offsets[id]; p < here.portal_offsets[id + 1]; ++p) {
				const Portal &portal = here.portals[p];
				const int32_t dx = int32_t(portal.neighbour % 3) - 1;
				const int32_t dz = int32_t(portal.neighbour / 3) - 1;
				ChunkKey near;
				near.x = key.x + dx;
				near.z = key.z + dz;
				const int32_t target = ground.chunk_index(near);
				if (target < 0) {
					continue;
				}
				ground.ensure_components(uint32_t(target));
				const ProfileLayer &there = ground.layer(uint32_t(target));
				if (portal.target_span >= there.component.size()) {
					continue;
				}
				const uint32_t target_id = there.component[portal.target_span];
				if (target_id == NO_COMPONENT) {
					continue;
				}
				const uint64_t next = (uint64_t(uint32_t(target)) << 32) | target_id;
				const double score = entry.g + ((dx != 0 && dz != 0) ? std::sqrt(2.0) : 1.0);
				const auto known = coarse_best.find(next);
				if (known != coarse_best.end() && score >= known->second.first) {
					continue;
				}
				coarse_best[next] = std::make_pair(score, entry.node);
				coarse_heap.push_back({ score + coarse_heuristic(uint32_t(target)), score, next });
				std::push_heap(coarse_heap.begin(), coarse_heap.end(), CoarseAfter());
			}
			if (timed && Clock::now() >= deadline) {
				return true;
			}
		}
		// Every component reachable from the start is known and none holds a goal: the
		// outcome is certified without a cell search. Missing chunks touching a reached
		// component keep it open (WaitingForGeometry); otherwise it is unreachable.
		for (const auto &visited : coarse_best) {
			const uint32_t index = uint32_t(visited.first >> 32);
			const uint32_t id = uint32_t(visited.first & 0xffffffffu);
			const ProfileLayer &here = ground.layer(index);
			uint8_t bits = here.touch[id];
			const ChunkKey key = ground.chunk(index).key;
			// Corner chunks are reachable when two edges meet.
			const bool west = bits & (1u << neighbour_code(-1, 0));
			const bool east = bits & (1u << neighbour_code(1, 0));
			const bool north = bits & (1u << neighbour_code(0, -1));
			const bool south = bits & (1u << neighbour_code(0, 1));
			const int32_t sides[8][3] = {
				{ -1, 0, west }, { 1, 0, east }, { 0, -1, north }, { 0, 1, south },
				{ -1, -1, west && north }, { 1, -1, east && north }, { -1, 1, west && south }, { 1, 1, east && south },
			};
			for (const auto &side : sides) {
				if (!side[2]) {
					continue;
				}
				ChunkKey near;
				near.x = key.x + side[0];
				near.z = key.z + side[1];
				if (ground.chunk_index(near) < 0) {
					frontier.insert(near.packed());
				}
			}
		}
		out.coarse_certified = true;
		finish(frontier.empty() ? RouteStatus::UNREACHABLE : RouteStatus::WAITING_FOR_GEOMETRY, DISCONNECTED);
		return true;
	}

	void build_corridor(uint64_t node) {
		// walk_planner.gd _chunk_corridor(): the chunks of the coarse route plus one ring.
		corridor.assign(ground.snapshot().chunks.size(), 0);
		uint64_t at = node;
		while (at != ~uint64_t(0)) {
			const ChunkKey key = ground.chunk(uint32_t(at >> 32)).key;
			for (int32_t dz = -1; dz <= 1; ++dz) {
				for (int32_t dx = -1; dx <= 1; ++dx) {
					ChunkKey near;
					near.x = key.x + dx;
					near.z = key.z + dz;
					const int32_t index = ground.chunk_index(near);
					if (index >= 0) {
						corridor[size_t(index)] = 1;
					}
				}
			}
			at = coarse_best[at].second;
		}
		corridor_active = true;
		out.corridor_used = true;
	}

	// ---- DETAILED: resumable cell A* --------------------------------------------------------

	Page &page(uint32_t index) {
		std::unique_ptr<Page> &slot = pages[index];
		if (!slot) {
			const uint32_t count = ground.chunk(index).span_count();
			slot.reset(new Page());
			slot->g.reset(new double[count == 0 ? 1 : count]);
			slot->parent.reset(new Handle[count == 0 ? 1 : count]);
			slot->stamp.reset(new uint32_t[count == 0 ? 1 : count]());
		}
		return *slot;
	}

	double best_g(Handle handle) {
		const std::unique_ptr<Page> &slot = pages[handle_chunk(handle)];
		if (!slot || slot->stamp[handle_span(handle)] != stamp) {
			return INF;
		}
		return slot->g[handle_span(handle)];
	}

	void set_best(Handle handle, double g, Handle parent) {
		Page &target = page(handle_chunk(handle));
		const uint32_t span = handle_span(handle);
		target.stamp[span] = stamp;
		target.g[span] = g;
		target.parent[span] = parent;
	}

	Handle parent_of(Handle handle) {
		return pages[handle_chunk(handle)]->parent[handle_span(handle)];
	}

	void start_detailed() {
		if (pages.empty()) {
			pages.resize(ground.snapshot().chunks.size());
		}
		++stamp; // new search pass: every stamped entry of the last pass is stale at once
		heap.clear();
		set_best(start, 0.0, NO_HANDLE);
		int32_t x = 0;
		int32_t z = 0;
		ground.cell(start, x, z);
		heap.push_back({ 0.0, 0.0, heuristic(x, z), cell_tie(x, z, ground.span(start).slot()), start });
		best_partial = NO_HANDLE;
		best_partial_h = INF;
		best_partial_g = INF;
		detailed_started = true;
	}

	// Returns true when the slice should end.
	bool detailed_step(int64_t &slice_expansions, const Clock::time_point &deadline, bool timed,
			const std::atomic<bool> *cancel) {
		if (!detailed_started) {
			start_detailed();
		}
		auto room = [this](Handle handle) { return search_room(handle); };
		const int64_t limit = options.expansion_limit;
		while (!heap.empty() && out.expanded < limit) {
			if (out.expanded % 128 == 0 && cancel != nullptr && cancel->load(std::memory_order_relaxed)) {
				finish(RouteStatus::CANCELLED, "Cancelled");
				return true;
			}
			if (slice_expansions <= 0) {
				return true;
			}
			if (timed && (out.expanded & 63) == 0 && Clock::now() >= deadline) {
				return true;
			}
			std::pop_heap(heap.begin(), heap.end(), HeapAfter());
			const HeapEntry entry = heap.back();
			heap.pop_back();
			if (entry.g > best_g(entry.node)) {
				continue; // superseded heap entry
			}
			++out.expanded;
			--slice_expansions;
			const Handle key = entry.node;
			if (goals.count(key) != 0) {
				reached = key;
				phase = Phase::SMOOTH;
				return false;
			}
			if (entry.h < best_partial_h || (entry.h == best_partial_h && entry.g < best_partial_g)) {
				best_partial = key;
				best_partial_h = entry.h;
				best_partial_g = entry.g;
			}
			// walk_planner.gd neighbors(): same candidates, order and frontier marks.
			const FloorSpan &source = ground.span(key);
			const bool source_ok = ground.allowed(source);
			int32_t sx = 0;
			int32_t sz = 0;
			ground.cell(key, sx, sz);
			for (int dir = 0; dir < 8; ++dir) {
				const int32_t nx = sx + DIR_X[dir];
				const int32_t nz = sz + DIR_Z[dir];
				const ChunkKey near = ChunkKey::of_cell(nx, nz);
				const int32_t index = ground.chunk_index(near);
				if (index < 0) {
					frontier.insert(near.packed());
					continue;
				}
				if (corridor_active && !corridor[size_t(index)]) {
					continue;
				}
				if (!source_ok) {
					continue;
				}
				const GroundAccess::Column column = ground.column(nx, nz);
				const GroundChunk &owner = ground.chunk(uint32_t(index));
				const double distance = GroundAccess::direction_distance(dir);
				for (uint32_t i = 0; i < column.count; ++i) {
					const uint32_t span_index = column.first + i;
					const Handle next = make_handle(uint32_t(index), span_index);
					const FloorSpan &dest = owner.spans[span_index];
					if (!ground.edge(source, sx, sz, dir, next, dest, room)) {
						continue;
					}
					const double score = entry.g + edge_cost(distance, dest);
					if (score >= best_g(next)) {
						continue;
					}
					set_best(next, score, key);
					const double h = heuristic(nx, nz);
					heap.push_back({ score + h, score, h, cell_tie(nx, nz, dest.slot()), next });
					std::push_heap(heap.begin(), heap.end(), HeapAfter());
				}
			}
		}
		if (out.expanded >= limit) {
			end_without_route(RouteStatus::BUDGET_EXHAUSTED, "Search budget reached");
			return true;
		}
		if (corridor_active) {
			// The coarse corridor was too narrow for the cell graph: widen to the whole
			// snapshot within the same expansion budget.
			corridor_active = false;
			out.corridor_widened = true;
			detailed_started = false;
			return false;
		}
		end_without_route(frontier.empty() ? RouteStatus::UNREACHABLE : RouteStatus::WAITING_FOR_GEOMETRY,
				DISCONNECTED);
		return true;
	}

	void end_without_route(RouteStatus status, const std::string &reason) {
		if (options.allow_partial && best_partial != NO_HANDLE && best_partial != start) {
			std::vector<Handle> raw = reconstruct(best_partial);
			smoothing_checks = 0;
			out.partial_path = options.smooth ? smooth(raw, false) : raw_points(raw);
			out.limited_by = status;
			finish(RouteStatus::PARTIAL, reason);
			return;
		}
		finish(status, reason);
	}

	std::vector<Handle> reconstruct(Handle end) {
		std::vector<Handle> raw;
		Handle at = end;
		while (at != NO_HANDLE) {
			raw.push_back(at);
			at = parent_of(at);
		}
		std::reverse(raw.begin(), raw.end());
		return raw;
	}

	std::vector<Vec3f> raw_points(const std::vector<Handle> &raw) const {
		std::vector<Vec3f> points;
		points.reserve(raw.size());
		for (Handle handle : raw) {
			points.push_back(ground.point(handle));
		}
		return points;
	}

	// ---- SMOOTH (walk_planner.gd _smooth and its certification) -----------------------------

	void complete() {
		std::vector<Handle> raw = reconstruct(reached);
		out.raw_cost = best_g(reached);
		out.raw_cells.reserve(raw.size());
		std::unordered_set<uint32_t> path_chunks;
		for (Handle handle : raw) {
			out.raw_cells.push_back(ground.key(handle));
			path_chunks.insert(handle_chunk(handle));
		}
		smoothing_checks = 0;
		size_t prefix = 0;
		if (options.escape_reach > 0.0 && !seeds.empty()) {
			// Phase 2 escape: the seeded prefix (no body room) stays as raw cells; the rest is
			// smoothed and certified as usual.
			while (prefix + 1 < raw.size() && !ground.pure_room(raw[prefix])) {
				++prefix;
			}
		}
		if (prefix > 0 && options.smooth) {
			std::vector<Vec3f> points = raw_points(std::vector<Handle>(raw.begin(), raw.begin() + long(prefix)));
			const std::vector<Vec3f> rest = smooth(std::vector<Handle>(raw.begin() + long(prefix), raw.end()), options.relaxed);
			points.insert(points.end(), rest.begin(), rest.end());
			out.path = points;
		} else {
			out.path = options.smooth ? smooth(raw, options.relaxed) : raw_points(raw);
		}
		out.smoothing_checks = int32_t(smoothing_checks);
		// The route depends on its cells' chunks and their neighbours (body room and side
		// crossings look one chunk across a border).
		std::vector<uint32_t> ordered(path_chunks.begin(), path_chunks.end());
		std::sort(ordered.begin(), ordered.end());
		std::unordered_set<uint64_t> seen;
		for (uint32_t index : ordered) {
			const ChunkKey key = ground.chunk(index).key;
			for (int32_t dz = -1; dz <= 1; ++dz) {
				for (int32_t dx = -1; dx <= 1; ++dx) {
					ChunkKey near;
					near.x = key.x + dx;
					near.z = key.z + dz;
					const int32_t at = ground.chunk_index(near);
					if (at >= 0 && seen.insert(near.packed()).second) {
						out.dependencies.push_back(std::make_pair(near, ground.chunk(uint32_t(at)).revision));
					}
				}
			}
		}
		finish(RouteStatus::COMPLETE, "");
	}

	Handle corridor_floor(int32_t cx, int32_t cz, float expected_y, Handle previous, double radius) {
		Handle best = NO_HANDLE;
		double score = INF;
		const GroundAccess::Column column = ground.column(cx, cz);
		for (uint32_t i = 0; i < column.count; ++i) {
			const Handle key = make_handle(uint32_t(column.chunk), column.first + i);
			if (!ground.room_radius(key, radius)) {
				continue;
			}
			if (!options.blocked.empty() && blocked_cell(key)) {
				continue;
			}
			if (previous != NO_HANDLE && key != previous && !corridor_connected(previous, key, radius)) {
				continue;
			}
			const double candidate = std::fabs(double(ground.span(key).floor_y) - double(expected_y));
			if (candidate < score) {
				score = candidate;
				best = key;
			}
		}
		return best;
	}

	bool corridor_connected(Handle a, Handle b, double radius) {
		int32_t ax = 0, az = 0, bx = 0, bz = 0;
		ground.cell(a, ax, az);
		ground.cell(b, bx, bz);
		const int32_t dx = bx - ax;
		const int32_t dz = bz - az;
		if (std::abs(dx) > 1 || std::abs(dz) > 1) {
			return false;
		}
		const FloorSpan &source = ground.span(a);
		const FloorSpan &dest = ground.span(b);
		if (!ground.link(source, dest, double(length2f(float(dx), float(dz))) * CELL)) {
			return false;
		}
		if (dx == 0 || dz == 0) {
			return true;
		}
		// A diagonal sample may not squeeze between two touching blocked cells.
		const int32_t sides[2][2] = { { dx, 0 }, { 0, dz } };
		for (const auto &side : sides) {
			bool via = false;
			const GroundAccess::Column column = ground.column(ax + side[0], az + side[1]);
			for (uint32_t i = 0; i < column.count; ++i) {
				const Handle key = make_handle(uint32_t(column.chunk), column.first + i);
				if (!ground.room_radius(key, radius)) {
					continue;
				}
				const FloorSpan &middle = ground.span(key);
				if (ground.link(source, middle, CELL) && ground.link(middle, dest, CELL)) {
					via = true;
					break;
				}
			}
			if (!via) {
				return false;
			}
		}
		return true;
	}

	Certified certify_segment(const Vec3f &a, const Vec3f &b, double cost_limit, double extra_clearance) {
		Certified result;
		if (!a.finite() || !b.finite()) {
			return result;
		}
		const double distance = double(length2f(b.x - a.x, b.z - a.z));
		const int64_t steps = std::max<int64_t>(1, ceil_int(distance / CORRIDOR_STEP));
		if (steps > MAX_CORRIDOR_SAMPLES || smoothing_checks + steps + 1 > MAX_SMOOTH_CHECKS) {
			return result;
		}
		smoothing_checks += steps + 1;
		// WalkGrid.has_room is already the profile-radius erosion of sampled occupancy; curves
		// are sampled twice per cell, so every touched eroded cell keeps the curve inside it.
		const double radius = ground.profile().radius + std::max(0.0, extra_clearance);
		Handle previous = NO_HANDLE;
		double total = 0.0;
		result.points.reserve(size_t(steps) + 1);
		for (int64_t step = 0; step <= steps; ++step) {
			const double t = double(step) / double(steps);
			const Vec3f position = lerp3(a, b, float(t));
			const Handle key = corridor_floor(cell_coord(double(position.x)), cell_coord(double(position.z)), position.y,
					previous, radius);
			if (key == NO_HANDLE) {
				return Certified();
			}
			const FloorSpan &sample = ground.span(key);
			if (previous != NO_HANDLE && key != previous && !corridor_connected(previous, key, radius)) {
				return Certified();
			}
			result.points.push_back(Vec3f(position.x, sample.floor_y, position.z));
			if (step > 0) {
				const double stride = distance / double(steps);
				const double water = 1.0 + 4.0 * double(sample.water_depth) / ground.wade_floor();
				total += stride * (1.0 + double(sample.slope_deg) / 45.0) * water * span_paint(sample);
				if (total > cost_limit) {
					return Certified();
				}
			}
			previous = key;
		}
		result.valid = true;
		result.cost = total;
		return result;
	}

	Certified certify_polyline(const std::vector<Vec3f> &shape, double cost_limit = INF, double extra_clearance = 0.0) {
		if (shape.empty()) {
			return Certified();
		}
		if (shape.size() == 1) {
			return certify_segment(shape[0], shape[0], cost_limit, extra_clearance);
		}
		Certified result;
		double total = 0.0;
		for (size_t i = 1; i < shape.size(); ++i) {
			const Certified segment = certify_segment(shape[i - 1], shape[i], cost_limit - total, extra_clearance);
			if (!segment.valid) {
				return Certified();
			}
			total += segment.cost;
			for (const Vec3f &point : segment.points) {
				if (result.points.empty() || double(distance_squared3(point, result.points.back())) > .000001) {
					result.points.push_back(point);
				}
			}
		}
		result.valid = true;
		result.cost = total;
		return result;
	}

	std::vector<Vec3f> smooth(const std::vector<Handle> &raw, bool relaxed) {
		std::vector<Vec3f> fallback = raw_points(raw);
		if (raw.size() < 2) {
			return fallback;
		}
		std::vector<Vec3f> anchors{ fallback[0] };
		size_t i = 0;
		while (i < raw.size() - 1) {
			size_t best = i + 1;
			double reference = 0.0;
			// Bound shortcut work; retain height samples across crests and floor changes.
			const size_t end = std::min(i + 33, raw.size());
			for (size_t j = i + 1; j < end; ++j) {
				reference += cost(raw[j - 1], raw[j]);
				if (certify_segment(fallback[i], fallback[j], reference * 1.03, 0.0).valid) {
					best = j;
				}
			}
			i = best;
			anchors.push_back(fallback[i]);
		}
		Certified certified = certify_polyline(anchors);
		if (!certified.valid) {
			return fallback;
		}
		std::vector<Vec3f> shape = rounded_shape(anchors);
		if (relaxed) {
			shape = relaxed_shape(shape);
		}
		certified = certify_polyline(shape, certified.cost * (relaxed ? 1.06 : 1.03));
		if (!certified.valid) {
			certified = certify_polyline(anchors);
			if (!certified.valid) {
				return fallback;
			}
		}
		return decimate(certified.points);
	}

	std::vector<Vec3f> rounded_shape(const std::vector<Vec3f> &anchors) {
		if (anchors.size() < 3) {
			return anchors;
		}
		std::vector<Vec3f> result{ anchors[0] };
		for (size_t i = 1; i + 1 < anchors.size(); ++i) {
			const Vec3f &a = anchors[i - 1];
			const Vec3f &b = anchors[i];
			const Vec3f &c = anchors[i + 1];
			float in_x = b.x - a.x;
			float in_z = b.z - a.z;
			float out_x = c.x - b.x;
			float out_z = c.z - b.z;
			const float in_length = length2f(in_x, in_z);
			const float out_length = length2f(out_x, out_z);
			if (double(in_length) < .01 || double(out_length) < .01) {
				result.push_back(b);
				continue;
			}
			// Godot Vector2::normalized().
			in_x /= in_length;
			in_z /= in_length;
			out_x /= out_length;
			out_z /= out_length;
			const float alignment = in_x * out_x + in_z * out_z;
			if (double(alignment) > .995 || double(alignment) < -.8) {
				result.push_back(b);
				continue;
			}
			double distance = std::min(1.5, std::min(double(in_length), double(out_length)) * .22);
			std::vector<Vec3f> rounded;
			for (int attempt = 0; attempt < 3; ++attempt) {
				const float d = float(distance);
				Vec3f enter = sub3(b, Vec3f(in_x * d, 0.0f * d, in_z * d));
				Vec3f leave = add3(b, Vec3f(out_x * d, 0.0f * d, out_z * d));
				enter.y = float(lerp_double(double(a.y), double(b.y), 1.0 - distance / std::max(.001, double(in_length))));
				leave.y = float(lerp_double(double(b.y), double(c.y), distance / std::max(.001, double(out_length))));
				std::vector<Vec3f> candidate{ enter };
				const int64_t curve_steps = std::max<int64_t>(3, ceil_int(distance * 2.0 / OUTPUT_STEP));
				for (int64_t step = 1; step < curve_steps; ++step) {
					const double t = double(step) / double(curve_steps);
					const float u = float(1.0 - t);
					const float w = float(t);
					const Vec3f first = scale3(scale3(enter, u), u);
					const Vec3f second = scale3(scale3(scale3(b, 2.0f), u), w);
					const Vec3f third = scale3(scale3(leave, w), w);
					candidate.push_back(add3(add3(first, second), third));
				}
				candidate.push_back(leave);
				const Certified reference = certify_polyline(std::vector<Vec3f>{ enter, b, leave });
				const Certified check = certify_polyline(candidate, (reference.valid ? reference.cost : INF) * 1.03);
				if (reference.valid && check.valid) {
					rounded = candidate;
					break;
				}
				distance *= .5;
			}
			if (rounded.empty()) {
				result.push_back(b);
			} else {
				result.insert(result.end(), rounded.begin(), rounded.end());
			}
		}
		result.push_back(anchors.back());
		return result;
	}

	static double shape_length(const std::vector<Vec3f> &shape) {
		double total = 0.0;
		for (size_t i = 1; i < shape.size(); ++i) {
			total += double(length2f(shape[i].x - shape[i - 1].x, shape[i].z - shape[i - 1].z));
		}
		return total;
	}

	std::vector<Vec3f> relaxed_shape(const std::vector<Vec3f> &shape) {
		if (shape.size() < 2) {
			return shape;
		}
		const double total = shape_length(shape);
		const float direct_x = shape.back().x - shape[0].x;
		const float direct_z = shape.back().z - shape[0].z;
		if (total < 6.0 || double(length2f(direct_x, direct_z)) / total < .9) {
			return shape;
		}
		const double amplitude = std::min(1.0, total * .06);
		// Prove the whole base corridor has room for the lateral displacement first.
		if (!certify_polyline(shape, INF, amplitude + .1).valid) {
			return shape;
		}
		float normal_x = -direct_z;
		float normal_z = direct_x;
		const float normal_length = std::sqrt(normal_x * normal_x + normal_z * normal_z);
		if (normal_length != 0.0f) {
			normal_x /= normal_length;
			normal_z /= normal_length;
		}
		const float seed_x = shape[0].x + shape.back().z;
		const float seed_z = shape[0].z - shape.back().x;
		if (stable_fraction(seed_x, seed_z, 313) < .5) {
			normal_x = -normal_x;
			normal_z = -normal_z;
		}
		std::vector<Vec3f> result{ shape[0] };
		double walked = 0.0;
		for (size_t i = 1; i < shape.size(); ++i) {
			const double segment = double(length2f(shape[i].x - shape[i - 1].x, shape[i].z - shape[i - 1].z));
			const int64_t steps = std::max<int64_t>(1, ceil_int(segment / 2.0));
			for (int64_t step = 1; step <= steps; ++step) {
				const double local = double(step) / double(steps);
				Vec3f point = lerp3(shape[i - 1], shape[i], float(local));
				const double progress = (walked + segment * local) / total;
				const float amount = float(amplitude);
				const float wave = float(std::sin(PI_VALUE * progress));
				const float offset_x = (normal_x * amount) * wave;
				const float offset_z = (normal_z * amount) * wave;
				point.x += offset_x;
				point.z += offset_z;
				result.push_back(point);
			}
			walked += segment;
		}
		const Certified base = certify_polyline(shape);
		const Certified bent = certify_polyline(result, (base.valid ? base.cost : INF) * 1.06);
		return (base.valid && bent.valid) ? result : shape;
	}

	double sampled_stride_cost(const Vec3f &point, double stride) {
		const GroundAccess::Column column = ground.column(cell_coord(double(point.x)), cell_coord(double(point.z)));
		const FloorSpan *selected = nullptr;
		double error = INF;
		for (uint32_t i = 0; i < column.count; ++i) {
			const FloorSpan &sample = ground.chunk(uint32_t(column.chunk)).spans[column.first + i];
			const double candidate = std::fabs(double(sample.floor_y) - double(point.y));
			if (candidate < error) {
				error = candidate;
				selected = &sample;
			}
		}
		if (selected == nullptr) {
			return INF;
		}
		const double water = 1.0 + 4.0 * double(selected->water_depth) / ground.wade_floor();
		return stride * (1.0 + double(selected->slope_deg) / 45.0) * water * span_paint(*selected);
	}

	static bool height_follows(const std::vector<Vec3f> &points, size_t a, size_t b) {
		if (b <= a + 1) {
			return true;
		}
		for (size_t i = a + 1; i < b; ++i) {
			const double t = double(i - a) / double(b - a);
			if (std::fabs(double(points[i].y) - lerp_double(double(points[a].y), double(points[b].y), t)) > .035) {
				return false;
			}
		}
		return true;
	}

	std::vector<Vec3f> decimate(const std::vector<Vec3f> &points) {
		if (points.size() <= 2) {
			return points;
		}
		std::vector<Vec3f> result{ points[0] };
		size_t i = 0;
		while (i < points.size() - 1) {
			size_t best = i + 1;
			double reference = 0.0;
			for (size_t j = i + 1; j < points.size(); ++j) {
				const double stride = double(length2f(points[j].x - points[j - 1].x, points[j].z - points[j - 1].z));
				if (stride > OUTPUT_STEP * 1.5 && j > i + 1) {
					break;
				}
				reference += sampled_stride_cost(points[j], stride);
				const Certified check = certify_segment(points[i], points[j], reference * 1.03, 0.0);
				if (check.valid && height_follows(points, i, j)) {
					best = j;
				}
				if (double(length2f(points[j].x - points[i].x, points[j].z - points[i].z)) >= OUTPUT_STEP) {
					break;
				}
			}
			i = best;
			result.push_back(points[i]);
		}
		return result;
	}

	void collect_outputs() {
		out.frontier.clear();
		out.frontier.reserve(frontier.size());
		for (uint64_t packed : frontier) {
			out.frontier.push_back(ChunkKey::from_packed(packed));
		}
		std::sort(out.frontier.begin(), out.frontier.end());
		if (out.status != RouteStatus::COMPLETE && out.dependencies.empty()) {
			// An incomplete verdict depends on every chunk the search read.
			for (uint32_t index = 0; index < ground.snapshot().chunks.size(); ++index) {
				if (ground.layer_touched(index) || (index < pages.size() && pages[index])) {
					const GroundChunk &owner = ground.chunk(index);
					out.dependencies.push_back(std::make_pair(owner.key, owner.revision));
				}
			}
		}
		out.rooms_computed = ground.rooms_computed;
		out.components_built = ground.components_built;
	}
};

GroundSearch::GroundSearch(std::shared_ptr<const Snapshot> snapshot, std::shared_ptr<ClearanceCache> cache,
		const GroundProfile &profile, const Vec3f &from, const Vec3f &to, const SearchOptions &options) :
		impl(new Impl(std::move(snapshot), std::move(cache), profile, from, to, options)) {
}

GroundSearch::~GroundSearch() = default;

RouteStatus GroundSearch::advance(int64_t expansion_budget, int64_t time_budget_us, const std::atomic<bool> *cancel) {
	Impl &s = *impl;
	if (s.phase == Impl::Phase::DONE) {
		return s.out.status;
	}
	const Clock::time_point began = Clock::now();
	const bool timed = time_budget_us > 0;
	const Clock::time_point deadline = began + std::chrono::microseconds(timed ? time_budget_us : 0);
	int64_t slice_expansions = expansion_budget > 0 ? expansion_budget : std::numeric_limits<int64_t>::max();
	++s.out.slices;
	bool yield = false;
	while (!yield && s.phase != Impl::Phase::DONE) {
		if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) {
			s.finish(RouteStatus::CANCELLED, "Cancelled");
			break;
		}
		switch (s.phase) {
			case Impl::Phase::INIT:
				s.init();
				break;
			case Impl::Phase::COARSE:
				yield = s.coarse_step(deadline, timed, cancel);
				break;
			case Impl::Phase::DETAILED:
				yield = s.detailed_step(slice_expansions, deadline, timed, cancel);
				break;
			case Impl::Phase::SMOOTH:
				s.complete();
				break;
			case Impl::Phase::DONE:
				break;
		}
	}
	s.out.cpu_us += double(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - began).count()) / 1000.0;
	if (s.phase == Impl::Phase::DONE) {
		s.collect_outputs();
		return s.out.status;
	}
	return RouteStatus::PENDING;
}

RouteStatus GroundSearch::run_to_completion(const std::atomic<bool> *cancel) {
	RouteStatus status = RouteStatus::PENDING;
	while (status == RouteStatus::PENDING) {
		status = advance(0, 0, cancel);
	}
	return status;
}

bool GroundSearch::finished() const {
	return impl->phase == Impl::Phase::DONE;
}

void GroundSearch::cancel() {
	if (impl->phase != Impl::Phase::DONE) {
		impl->finish(RouteStatus::CANCELLED, "Cancelled");
		impl->collect_outputs();
	}
}

const SearchOutput &GroundSearch::output() const {
	return impl->out;
}

GroundAccess &GroundSearch::access() {
	return impl->ground;
}

CellReport report_cell(GroundAccess &ground, const CellKey &key, bool with_component) {
	CellReport report;
	const Handle handle = ground.find(key);
	if (handle == NO_HANDLE) {
		return report;
	}
	report.present = true;
	report.span = ground.span(handle);
	report.paint = span_paint(report.span);
	report.trail = span_trail(report.span);
	report.allowed = ground.allowed(report.span);
	report.room = ground.pure_room(handle);
	if (with_component) {
		ground.ensure_components(handle_chunk(handle));
		report.component = ground.layer(handle_chunk(handle)).component[handle_span(handle)];
	}
	return report;
}

} // namespace ponynav
