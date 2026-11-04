// PonyNavigationNative: Godot bindings for the native navigation service (see the header).
// Low-frequency results and diagnostics are Dictionaries; geometry crosses as packed arrays
// once per chunk revision.
#include "pony_navigation_native.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

double number(const Dictionary &values, const char *key, double fallback) {
	const Variant value = values.get(key, Variant());
	if (value.get_type() == Variant::FLOAT || value.get_type() == Variant::INT) {
		return double(value);
	}
	return fallback;
}

int64_t integer(const Dictionary &values, const char *key, int64_t fallback) {
	const Variant value = values.get(key, Variant());
	if (value.get_type() == Variant::INT) {
		return int64_t(value);
	}
	if (value.get_type() == Variant::FLOAT) {
		return int64_t(double(value));
	}
	return fallback;
}

bool flag(const Dictionary &values, const char *key, bool fallback) {
	const Variant value = values.get(key, Variant());
	if (value.get_type() == Variant::BOOL) {
		return bool(value);
	}
	if (value.get_type() == Variant::INT) {
		return int64_t(value) != 0;
	}
	return fallback;
}

ponynav::GroundProfile profile_from(const Dictionary &values) {
	ponynav::GroundProfile profile;
	profile.radius = number(values, "radius", profile.radius);
	profile.clearance = number(values, "clearance", number(values, "height", profile.clearance));
	profile.step = number(values, "step", profile.step);
	profile.slope = number(values, "slope", profile.slope);
	profile.wade = number(values, "wade", profile.wade);
	profile.swim = flag(values, "swim", profile.swim);
	profile.scale = number(values, "scale", profile.scale);
	profile.mask = uint32_t(integer(values, "mask", profile.mask));
	return profile;
}

ponynav::SearchOptions options_from(const Dictionary &values) {
	ponynav::SearchOptions options;
	options.any_floor = flag(values, "any_floor", options.any_floor);
	options.relaxed = flag(values, "relaxed", options.relaxed);
	options.use_corridor = flag(values, "use_corridor", options.use_corridor);
	options.allow_partial = flag(values, "allow_partial", options.allow_partial);
	options.smooth = flag(values, "smooth", options.smooth);
	options.expansion_limit = integer(values, "expansion_limit", integer(values, "limit", options.expansion_limit));
	options.goal_radius = number(values, "goal_radius", options.goal_radius);
	options.dijkstra = flag(values, "dijkstra", options.dijkstra);
	options.escape_reach = number(values, "escape_reach", options.escape_reach);
	const Variant blocked = values.get("blocked", Variant());
	if (blocked.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
		const PackedFloat32Array triples = blocked;
		for (int64_t i = 0; i + 2 < triples.size(); i += 3) {
			ponynav::SearchBlock block;
			block.x = triples[i];
			block.z = triples[i + 1];
			block.radius = triples[i + 2];
			if (std::isfinite(block.x) && std::isfinite(block.z) && std::isfinite(block.radius) && block.radius > 0.0) {
				options.blocked.push_back(block);
			}
		}
	}
	return options;
}

ponynav::Vec3f vec(const Vector3 &value) {
	return ponynav::Vec3f(value.x, value.y, value.z);
}

Vector3 vector(const ponynav::Vec3f &value) {
	return Vector3(value.x, value.y, value.z);
}

PackedVector3Array points(const std::vector<ponynav::Vec3f> &values) {
	PackedVector3Array result;
	result.resize(int64_t(values.size()));
	for (size_t i = 0; i < values.size(); ++i) {
		result.set(int64_t(i), vector(values[i]));
	}
	return result;
}

// walk_planner.gd uses Vector3i(0, -1, 0) for "no cell".
Vector3i cell_vector(const ponynav::CellKey &key) {
	return key.valid() ? Vector3i(key.x, key.slot, key.z) : Vector3i(0, -1, 0);
}

Dictionary output_dict(const ponynav::SearchOutput &output, bool with_cells) {
	Dictionary result;
	result["status"] = int64_t(output.status);
	result["status_name"] = String(ponynav::status_name(output.status));
	result["limited_by"] = int64_t(output.limited_by);
	result["reason"] = String(output.reason.c_str());
	result["path"] = points(output.path);
	result["partial_path"] = points(output.partial_path);
	result["raw_cost"] = output.raw_cost;
	result["raw_cell_count"] = int64_t(output.raw_cells.size());
	result["expanded"] = output.expanded;
	result["coarse_expanded"] = output.coarse_expanded;
	result["corridor"] = output.corridor_used;
	result["widened"] = output.corridor_widened;
	result["coarse_certified"] = output.coarse_certified;
	Array frontier;
	for (const ponynav::ChunkKey &key : output.frontier) {
		frontier.append(Vector2i(key.x, key.z));
	}
	result["frontier"] = frontier;
	result["dependencies"] = int64_t(output.dependencies.size());
	result["start"] = cell_vector(output.start);
	result["goal_cell"] = cell_vector(output.goal);
	result["start_cramped"] = output.start_cramped;
	result["goal_count"] = output.goal_count;
	result["smoothing_checks"] = int64_t(output.smoothing_checks);
	result["rooms_computed"] = int64_t(output.rooms_computed);
	result["components_built"] = int64_t(output.components_built);
	result["cpu_ms"] = output.cpu_us / 1000.0;
	result["slices"] = int64_t(output.slices);
	if (with_cells) {
		PackedInt32Array cells;
		cells.resize(int64_t(output.raw_cells.size()) * 3);
		for (size_t i = 0; i < output.raw_cells.size(); ++i) {
			cells.set(int64_t(i) * 3, output.raw_cells[i].x);
			cells.set(int64_t(i) * 3 + 1, output.raw_cells[i].slot);
			cells.set(int64_t(i) * 3 + 2, output.raw_cells[i].z);
		}
		result["raw_cells"] = cells;
	}
	return result;
}

ponynav::ChunkKey chunk_key(const Vector2i &coord) {
	ponynav::ChunkKey key;
	key.x = coord.x;
	key.z = coord.y;
	return key;
}

} // namespace

void PonyNavigationNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("create_world"), &PonyNavigationNative::create_world);
	ClassDB::bind_method(D_METHOD("destroy_world", "world"), &PonyNavigationNative::destroy_world);
	ClassDB::bind_method(D_METHOD("publish_walk_chunk", "world", "coord", "floor_y", "slope_deg", "water_depth", "headroom",
								 "flags", "paint_cost", "trail_weight"),
			&PonyNavigationNative::publish_walk_chunk);
	ClassDB::bind_method(D_METHOD("publish_span_chunk", "world", "coord", "column_offsets", "span_floats", "span_bytes"),
			&PonyNavigationNative::publish_span_chunk);
	ClassDB::bind_method(D_METHOD("remove_chunk", "world", "coord"), &PonyNavigationNative::remove_chunk);
	ClassDB::bind_method(D_METHOD("chunk_revision", "world", "coord"), &PonyNavigationNative::chunk_revision);
	ClassDB::bind_method(D_METHOD("chunk_count", "world"), &PonyNavigationNative::chunk_count);
	ClassDB::bind_method(D_METHOD("chunk_span_count", "world", "coord"), &PonyNavigationNative::chunk_span_count);
	ClassDB::bind_method(D_METHOD("register_actor", "world", "profile"), &PonyNavigationNative::register_actor);
	ClassDB::bind_method(D_METHOD("update_actor_profile", "slot", "generation", "profile"),
			&PonyNavigationNative::update_actor_profile);
	ClassDB::bind_method(D_METHOD("unregister_actor", "slot", "generation"), &PonyNavigationNative::unregister_actor);
	ClassDB::bind_method(D_METHOD("is_actor_live", "slot", "generation"), &PonyNavigationNative::is_actor_live);
	ClassDB::bind_method(D_METHOD("submit_intent", "slot", "generation", "intent"), &PonyNavigationNative::submit_intent);
	ClassDB::bind_method(D_METHOD("update_intent_goal", "slot", "generation", "intent_generation", "goal", "from"),
			&PonyNavigationNative::update_intent_goal);
	ClassDB::bind_method(D_METHOD("cancel_intent", "slot", "generation", "intent_generation"),
			&PonyNavigationNative::cancel_intent);
	ClassDB::bind_method(D_METHOD("poll_results"), &PonyNavigationNative::poll_results);
	ClassDB::bind_method(D_METHOD("search_now", "world", "profile", "from", "to", "options"),
			&PonyNavigationNative::search_now);
	ClassDB::bind_method(D_METHOD("wander_job", "world", "profile", "params"), &PonyNavigationNative::wander_job);
	ClassDB::bind_method(D_METHOD("query_cell", "world", "profile", "cell"), &PonyNavigationNative::query_cell);
	ClassDB::bind_method(D_METHOD("chunk_components", "world", "coord", "profile"), &PonyNavigationNative::chunk_components);
	ClassDB::bind_method(D_METHOD("set_worker_count", "count"), &PonyNavigationNative::set_worker_count);
	ClassDB::bind_method(D_METHOD("get_worker_count"), &PonyNavigationNative::get_worker_count);
	ClassDB::bind_method(D_METHOD("set_slice_budget", "expansions", "microseconds"), &PonyNavigationNative::set_slice_budget);
	ClassDB::bind_method(D_METHOD("set_paused", "paused"), &PonyNavigationNative::set_paused);
	ClassDB::bind_method(D_METHOD("pending_jobs"), &PonyNavigationNative::pending_jobs);
	ClassDB::bind_method(D_METHOD("queued_jobs"), &PonyNavigationNative::queued_jobs);
	ClassDB::bind_method(D_METHOD("busy_workers"), &PonyNavigationNative::busy_workers);
	ClassDB::bind_method(D_METHOD("get_diagnostics"), &PonyNavigationNative::get_diagnostics);
	ClassDB::bind_method(D_METHOD("shutdown"), &PonyNavigationNative::shutdown);
	ClassDB::bind_static_method("PonyNavigationNative", D_METHOD("status_name", "status"), &PonyNavigationNative::status_name);
	BIND_CONSTANT(STATUS_PENDING);
	BIND_CONSTANT(STATUS_COMPLETE);
	BIND_CONSTANT(STATUS_PARTIAL);
	BIND_CONSTANT(STATUS_WAITING_FOR_GEOMETRY);
	BIND_CONSTANT(STATUS_BUDGET_EXHAUSTED);
	BIND_CONSTANT(STATUS_UNREACHABLE);
	BIND_CONSTANT(STATUS_CANCELLED);
	BIND_CONSTANT(STATUS_STALE);
	BIND_CONSTANT(STATUS_NO_FLOOR);
	BIND_CONSTANT(STATUS_INVALID);

	ClassDB::bind_method(D_METHOD("follow_configure", "slot", "generation", "limits"), &PonyNavigationNative::follow_configure);
	ClassDB::bind_method(D_METHOD("follow_set_corridor", "slot", "generation", "points", "options", "position", "heading",
								 "velocity"),
			&PonyNavigationNative::follow_set_corridor);
	ClassDB::bind_method(D_METHOD("follow_clear", "slot", "generation"), &PonyNavigationNative::follow_clear);
	ClassDB::bind_method(D_METHOD("step_batch", "actor_keys", "positions", "velocities", "headings", "delta", "inputs"),
			&PonyNavigationNative::step_batch, DEFVAL(PackedFloat32Array()));
	ClassDB::bind_method(D_METHOD("batch_state"), &PonyNavigationNative::batch_state);
	ClassDB::bind_method(D_METHOD("batch_preferred_velocities"), &PonyNavigationNative::batch_preferred_velocities);
	ClassDB::bind_method(D_METHOD("take_follow_events"), &PonyNavigationNative::take_follow_events);
	ClassDB::bind_method(D_METHOD("follow_state", "slot", "generation"), &PonyNavigationNative::follow_state);
	ClassDB::bind_method(D_METHOD("follow_diagnostics"), &PonyNavigationNative::follow_diagnostics);
	ClassDB::bind_static_method("PonyNavigationNative", D_METHOD("reason_name", "reason"), &PonyNavigationNative::reason_name);
	ClassDB::bind_static_method("PonyNavigationNative", D_METHOD("pursuit", "position", "yaw", "target"),
			&PonyNavigationNative::pursuit);
	BIND_CONSTANT(COMMAND_STRIDE);
	BIND_CONSTANT(INPUT_STRIDE);
	BIND_CONSTANT(STATE_STRIDE);
	BIND_CONSTANT(MODE_STOP);
	BIND_CONSTANT(MODE_TRAVEL);
	BIND_CONSTANT(MODE_STEP_TURN);
	BIND_CONSTANT(MODE_BRAKE);
	BIND_CONSTANT(MODE_HOLD);
	BIND_CONSTANT(INPUT_REQUESTED_SPEED);
	BIND_CONSTANT(INPUT_TERMINAL_SPEED);
	BIND_CONSTANT(INPUT_FLAGS);
	BIND_CONSTANT(INPUT_AVOID_VX);
	BIND_CONSTANT(INPUT_AVOID_VZ);
	BIND_CONSTANT(INPUT_AVOID_AGE);
	BIND_CONSTANT(INPUT_WALL_NX);
	BIND_CONSTANT(INPUT_WALL_NZ);
	BIND_CONSTANT(INPUT_EXECUTED_SPEED);
	BIND_CONSTANT(INPUT_EXECUTED_YAW);
	BIND_CONSTANT(INPUT_REFUSAL);
	BIND_CONSTANT(INPUT_STEP_SECONDS);
	BIND_CONSTANT(INPUT_SPEED_SCALE);
	BIND_CONSTANT(INPUT_FLAG_AVOIDANCE);
	BIND_CONSTANT(INPUT_FLAG_WALL);
	BIND_CONSTANT(INPUT_FLAG_ROUTE_PENDING);
	BIND_CONSTANT(REFUSAL_NONE);
	BIND_CONSTANT(REFUSAL_SUPPORT);
	BIND_CONSTANT(REFUSAL_TOUCH);
	BIND_CONSTANT(REFUSAL_TURN_SUPPORT);
	BIND_CONSTANT(EVENT_ARRIVED);
	BIND_CONSTANT(EVENT_REPAIR);
	BIND_CONSTANT(EVENT_REPLAN);
	BIND_CONSTANT(EVENT_ALTERNATE);
	BIND_CONSTANT(EVENT_FAILED);
	BIND_CONSTANT(EVENT_CORRIDOR_LOST);
}

PonyNavigationNative::PonyNavigationNative() :
		service(new ponynav::NavigationService(2)) {
}

PonyNavigationNative::~PonyNavigationNative() {
	if (service) {
		service->shutdown();
	}
}

int64_t PonyNavigationNative::create_world() {
	return int64_t(service->create_world());
}

bool PonyNavigationNative::destroy_world(int64_t p_world) {
	return service->destroy_world(uint32_t(p_world));
}

int64_t PonyNavigationNative::publish_walk_chunk(int64_t p_world, const Vector2i &p_coord,
		const PackedFloat32Array &p_floor_y, const PackedByteArray &p_slope_deg, const PackedFloat32Array &p_water_depth,
		const PackedFloat32Array &p_headroom, const PackedByteArray &p_flags, const PackedByteArray &p_paint_cost,
		const PackedByteArray &p_trail_weight) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	if (target == nullptr) {
		UtilityFunctions::push_error("PonyNavigationNative.publish_walk_chunk: unknown world ", p_world);
		return 0;
	}
	std::string error;
	std::shared_ptr<ponynav::GroundChunk> chunk = ponynav::build_chunk_from_legacy(chunk_key(p_coord), p_floor_y.ptr(),
			size_t(p_floor_y.size()), p_slope_deg.ptr(), size_t(p_slope_deg.size()), p_water_depth.ptr(),
			size_t(p_water_depth.size()), p_headroom.ptr(), size_t(p_headroom.size()), p_flags.ptr(), size_t(p_flags.size()),
			p_paint_cost.ptr(), size_t(p_paint_cost.size()), p_trail_weight.size() > 0 ? p_trail_weight.ptr() : nullptr,
			size_t(p_trail_weight.size()), error);
	if (!chunk) {
		UtilityFunctions::push_error("PonyNavigationNative.publish_walk_chunk ", p_coord, ": ", String(error.c_str()));
		return 0;
	}
	return int64_t(target->publish(chunk));
}

int64_t PonyNavigationNative::publish_span_chunk(int64_t p_world, const Vector2i &p_coord,
		const PackedInt32Array &p_column_offsets, const PackedFloat32Array &p_span_floats,
		const PackedByteArray &p_span_bytes) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	if (target == nullptr) {
		UtilityFunctions::push_error("PonyNavigationNative.publish_span_chunk: unknown world ", p_world);
		return 0;
	}
	const int64_t span_count = p_span_floats.size() / 3;
	if (p_span_floats.size() != span_count * 3 || p_span_bytes.size() != span_count * 4) {
		UtilityFunctions::push_error("PonyNavigationNative.publish_span_chunk: 3 floats and 4 bytes per span");
		return 0;
	}
	std::vector<uint32_t> offsets;
	offsets.reserve(size_t(p_column_offsets.size()));
	for (int64_t i = 0; i < p_column_offsets.size(); ++i) {
		const int32_t value = p_column_offsets[i];
		if (value < 0) {
			UtilityFunctions::push_error("PonyNavigationNative.publish_span_chunk: negative column offset");
			return 0;
		}
		offsets.push_back(uint32_t(value));
	}
	std::vector<ponynav::SpanInput> spans(static_cast<size_t>(span_count));
	for (int64_t i = 0; i < span_count; ++i) {
		ponynav::SpanInput &span = spans[size_t(i)];
		span.floor_y = p_span_floats[i * 3];
		span.headroom = p_span_floats[i * 3 + 1];
		span.water_depth = p_span_floats[i * 3 + 2];
		span.flags = p_span_bytes[i * 4];
		span.slope_deg = p_span_bytes[i * 4 + 1];
		span.paint_byte = p_span_bytes[i * 4 + 2];
		span.trail_byte = p_span_bytes[i * 4 + 3];
	}
	std::string error;
	std::shared_ptr<ponynav::GroundChunk> chunk = ponynav::build_chunk_from_columns(chunk_key(p_coord), offsets, spans, error);
	if (!chunk) {
		UtilityFunctions::push_error("PonyNavigationNative.publish_span_chunk ", p_coord, ": ", String(error.c_str()));
		return 0;
	}
	return int64_t(target->publish(chunk));
}

bool PonyNavigationNative::remove_chunk(int64_t p_world, const Vector2i &p_coord) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	return target != nullptr && target->remove(chunk_key(p_coord));
}

int64_t PonyNavigationNative::chunk_revision(int64_t p_world, const Vector2i &p_coord) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	return target == nullptr ? 0 : int64_t(target->revision_of(chunk_key(p_coord)));
}

int64_t PonyNavigationNative::chunk_count(int64_t p_world) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	return target == nullptr ? 0 : int64_t(target->chunk_count());
}

int64_t PonyNavigationNative::chunk_span_count(int64_t p_world, const Vector2i &p_coord) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	if (target == nullptr) {
		return -1;
	}
	std::shared_ptr<const ponynav::GroundChunk> chunk = target->chunk(chunk_key(p_coord));
	return chunk ? int64_t(chunk->span_count()) : -1;
}

PackedInt64Array PonyNavigationNative::register_actor(int64_t p_world, const Dictionary &p_profile) {
	std::string error;
	const ponynav::ActorHandle handle = service->register_actor(uint32_t(p_world), profile_from(p_profile), error);
	PackedInt64Array result;
	if (handle.generation == 0) {
		UtilityFunctions::push_error("PonyNavigationNative.register_actor: ", String(error.c_str()));
		return result;
	}
	result.append(int64_t(handle.slot));
	result.append(int64_t(handle.generation));
	return result;
}

static ponynav::ActorHandle actor_handle(int64_t p_slot, int64_t p_generation) {
	ponynav::ActorHandle handle;
	if (p_slot < 0 || p_generation <= 0 || p_slot > 0xffffffffll || p_generation > 0xffffffffll) {
		return handle;
	}
	handle.slot = uint32_t(p_slot);
	handle.generation = uint32_t(p_generation);
	return handle;
}

bool PonyNavigationNative::update_actor_profile(int64_t p_slot, int64_t p_generation, const Dictionary &p_profile) {
	return service->update_actor_profile(actor_handle(p_slot, p_generation), profile_from(p_profile));
}

bool PonyNavigationNative::unregister_actor(int64_t p_slot, int64_t p_generation) {
	return service->unregister_actor(actor_handle(p_slot, p_generation));
}

bool PonyNavigationNative::is_actor_live(int64_t p_slot, int64_t p_generation) {
	return service->actor_live(actor_handle(p_slot, p_generation));
}

int64_t PonyNavigationNative::submit_intent(int64_t p_slot, int64_t p_generation, const Dictionary &p_intent) {
	const Variant from = p_intent.get("from", Variant());
	const Variant goal = p_intent.get("goal", Variant());
	const int64_t generation = integer(p_intent, "generation", 0);
	if (from.get_type() != Variant::VECTOR3 || goal.get_type() != Variant::VECTOR3 || generation <= 0) {
		UtilityFunctions::push_error("PonyNavigationNative.submit_intent: needs Vector3 from, Vector3 goal and generation > 0");
		return -1;
	}
	ponynav::IntentParams params;
	params.owner = integer(p_intent, "owner", 0);
	params.generation = uint64_t(generation);
	params.from = vec(Vector3(from));
	params.goal = vec(Vector3(goal));
	params.terminal_mode = int32_t(integer(p_intent, "terminal_mode", 0));
	params.pace = float(number(p_intent, "pace", 1.0));
	params.priority = int32_t(integer(p_intent, "priority", 0));
	params.follow = flag(p_intent, "follow", false);
	params.follow_replan_distance = float(number(p_intent, "follow_replan_distance", 0.5));
	params.search = options_from(p_intent);
	return service->submit_intent(actor_handle(p_slot, p_generation), params);
}

bool PonyNavigationNative::update_intent_goal(int64_t p_slot, int64_t p_generation, int64_t p_intent_generation,
		const Vector3 &p_goal, const Vector3 &p_from) {
	if (p_intent_generation <= 0) {
		return false;
	}
	return service->update_intent_goal(actor_handle(p_slot, p_generation), uint64_t(p_intent_generation), vec(p_goal),
			vec(p_from));
}

bool PonyNavigationNative::cancel_intent(int64_t p_slot, int64_t p_generation, int64_t p_intent_generation) {
	if (p_intent_generation <= 0) {
		return false;
	}
	return service->cancel_intent(actor_handle(p_slot, p_generation), uint64_t(p_intent_generation));
}

Array PonyNavigationNative::poll_results() {
	Array results;
	for (const ponynav::NavResult &entry : service->poll()) {
		Dictionary result = output_dict(entry.output, false);
		result["job_id"] = int64_t(entry.job_id);
		result["world"] = int64_t(entry.world);
		result["slot"] = int64_t(entry.actor.slot);
		result["generation"] = int64_t(entry.actor.generation);
		result["intent_generation"] = int64_t(entry.intent_generation);
		result["owner"] = entry.owner;
		result["goal"] = vector(entry.goal);
		result["goal_superseded"] = entry.goal_superseded;
		result["queue_ms"] = entry.queue_us / 1000.0;
		result["latency_ms"] = entry.latency_us / 1000.0;
		results.append(result);
	}
	return results;
}

Ref<PonyWanderJob> PonyNavigationNative::wander_job(int64_t p_world, const Dictionary &p_profile,
		const Dictionary &p_params) {
	// dev 2026-10-20 multithreading: the snapshot is taken here, on the calling (main) thread.
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	ERR_FAIL_NULL_V_MSG(target, Ref<PonyWanderJob>(), "Unknown navigation world");
	const ponynav::GroundProfile profile = profile_from(p_profile);
	std::string error;
	ERR_FAIL_COND_V_MSG(!profile.valid(error), Ref<PonyWanderJob>(), String(error.c_str()));
	Ref<PonyWanderJob> job;
	job.instantiate();
	job->configure(target->snapshot(), target->cache(), profile, p_params);
	return job;
}

Dictionary PonyNavigationNative::search_now(int64_t p_world, const Dictionary &p_profile, const Vector3 &p_from,
		const Vector3 &p_to, const Dictionary &p_options) {
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	if (target == nullptr) {
		Dictionary failed;
		failed["status"] = int64_t(STATUS_INVALID);
		failed["status_name"] = "invalid";
		failed["reason"] = "Unknown navigation world";
		return failed;
	}
	const ponynav::GroundProfile profile = profile_from(p_profile);
	std::string error;
	if (!profile.valid(error)) {
		Dictionary failed;
		failed["status"] = int64_t(STATUS_INVALID);
		failed["status_name"] = "invalid";
		failed["reason"] = String(error.c_str());
		return failed;
	}
	std::shared_ptr<ponynav::ClearanceCache> cache = flag(p_options, "use_cache", true) ? target->cache() : nullptr;
	ponynav::GroundSearch search(target->snapshot(), cache, profile, vec(p_from), vec(p_to), options_from(p_options));
	search.run_to_completion();
	return output_dict(search.output(), true);
}

Dictionary PonyNavigationNative::query_cell(int64_t p_world, const Dictionary &p_profile, const Vector3i &p_cell) {
	Dictionary result;
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	result["present"] = false;
	if (target == nullptr) {
		return result;
	}
	ponynav::GroundAccess ground(target->snapshot(), target->cache(), profile_from(p_profile));
	ponynav::CellKey key;
	key.x = p_cell.x;
	key.slot = p_cell.y;
	key.z = p_cell.z;
	const ponynav::CellReport report = ponynav::report_cell(ground, key, flag(p_profile, "with_component", false));
	result["present"] = report.present;
	if (!report.present) {
		return result;
	}
	result["height"] = double(report.span.floor_y);
	result["slope"] = int64_t(report.span.slope_deg);
	result["water"] = double(report.span.water_depth);
	result["clearance"] = double(report.span.headroom);
	result["flags"] = int64_t(report.span.flags);
	result["paint"] = report.paint;
	result["trail"] = report.trail;
	result["allowed"] = report.allowed;
	result["room"] = report.room;
	result["surface_id"] = int64_t(report.span.surface_id);
	result["component"] = report.component == ponynav::NO_COMPONENT ? int64_t(-1) : int64_t(report.component);
	return result;
}

Dictionary PonyNavigationNative::chunk_components(int64_t p_world, const Vector2i &p_coord, const Dictionary &p_profile) {
	Dictionary result;
	ponynav::NavigationWorld *target = service->world(uint32_t(p_world));
	result["count"] = int64_t(-1);
	if (target == nullptr) {
		return result;
	}
	ponynav::GroundAccess ground(target->snapshot(), target->cache(), profile_from(p_profile));
	const int32_t index = ground.chunk_index(chunk_key(p_coord));
	if (index < 0) {
		return result;
	}
	ground.ensure_components(uint32_t(index));
	const ponynav::ProfileLayer &layer = ground.layer(uint32_t(index));
	PackedInt32Array components;
	components.resize(int64_t(layer.component.size()));
	for (size_t i = 0; i < layer.component.size(); ++i) {
		components.set(int64_t(i), layer.component[i] == ponynav::NO_COMPONENT ? -1 : int32_t(layer.component[i]));
	}
	result["count"] = int64_t(layer.component_count);
	result["components"] = components;
	result["portals"] = int64_t(layer.portals.size());
	result["span_count"] = int64_t(layer.span_count);
	return result;
}

void PonyNavigationNative::set_worker_count(int64_t p_count) {
	service->set_workers(int(p_count));
}

int64_t PonyNavigationNative::get_worker_count() {
	return service->workers();
}

void PonyNavigationNative::set_slice_budget(int64_t p_expansions, int64_t p_microseconds) {
	service->set_slice_budget(p_expansions, p_microseconds);
}

void PonyNavigationNative::set_paused(bool p_paused) {
	service->set_paused(p_paused);
}

int64_t PonyNavigationNative::pending_jobs() {
	return int64_t(service->pending_jobs());
}

int64_t PonyNavigationNative::queued_jobs() {
	return int64_t(service->queued_jobs());
}

int64_t PonyNavigationNative::busy_workers() {
	return int64_t(service->busy_workers());
}

Dictionary PonyNavigationNative::get_diagnostics() {
	const ponynav::NavCounters &counters = service->counters();
	Dictionary result;
	result["workers"] = int64_t(service->workers());
	result["worlds"] = int64_t(service->world_count());
	result["actors"] = int64_t(service->actor_count());
	result["pending_jobs"] = int64_t(service->pending_jobs());
	result["queued_jobs"] = int64_t(service->queued_jobs());
	result["busy_workers"] = int64_t(service->busy_workers());
	result["slices"] = int64_t(service->slices());
	result["jobs_submitted"] = int64_t(counters.jobs_submitted);
	result["jobs_finished"] = int64_t(counters.jobs_finished);
	result["results_delivered"] = int64_t(counters.results_delivered);
	result["stale_world"] = int64_t(counters.stale_world);
	result["stale_actor"] = int64_t(counters.stale_actor);
	result["stale_intent"] = int64_t(counters.stale_intent);
	result["stale_chunk"] = int64_t(counters.stale_chunk);
	result["cancelled"] = int64_t(counters.cancelled);
	result["idempotent"] = int64_t(counters.idempotent);
	result["coalesced"] = int64_t(counters.coalesced);
	result["rejected"] = int64_t(counters.rejected_generation);
	Array worlds;
	for (uint32_t id : service->world_ids()) {
		ponynav::NavigationWorld *target = service->world(id);
		Dictionary entry;
		entry["world"] = int64_t(id);
		entry["chunks"] = int64_t(target->chunk_count());
		entry["chunk_bytes"] = int64_t(target->memory_bytes());
		entry["cache_layers"] = int64_t(target->cache()->layer_count());
		entry["cache_bytes"] = int64_t(target->cache()->memory_bytes());
		entry["cache_hits"] = int64_t(target->cache()->hits());
		entry["cache_misses"] = int64_t(target->cache()->misses());
		worlds.append(entry);
	}
	result["world_memory"] = worlds;
	Array recent;
	for (const ponynav::JobRecord &record : service->recent_jobs()) {
		Dictionary entry;
		entry["job_id"] = int64_t(record.job_id);
		entry["world"] = int64_t(record.world);
		entry["status"] = String(ponynav::status_name(record.status));
		entry["expanded"] = record.expanded;
		entry["cpu_ms"] = record.cpu_us / 1000.0;
		entry["queue_ms"] = record.queue_us / 1000.0;
		entry["latency_ms"] = record.latency_us / 1000.0;
		entry["slices"] = int64_t(record.slices);
		recent.append(entry);
	}
	result["recent"] = recent;
	return result;
}

void PonyNavigationNative::shutdown() {
	service->shutdown();
}

String PonyNavigationNative::status_name(int64_t p_status) {
	return String(ponynav::status_name(ponynav::RouteStatus(int32_t(p_status))));
}

// ---- Phase 2 follower --------------------------------------------------------------------------

static_assert(int(PonyNavigationNative::COMMAND_STRIDE) == int(ponynav::COMMAND_STRIDE), "command stride");
static_assert(int(PonyNavigationNative::INPUT_STRIDE) == int(ponynav::INPUT_STRIDE), "input stride");
static_assert(int(PonyNavigationNative::STATE_STRIDE) == int(ponynav::STATE_STRIDE), "state stride");
static_assert(int(PonyNavigationNative::MODE_STEP_TURN) == int(ponynav::MODE_STEP_TURN), "mode");
static_assert(int(PonyNavigationNative::INPUT_STEP_SECONDS) == int(ponynav::INPUT_STEP_SECONDS), "input slot");
static_assert(int(PonyNavigationNative::INPUT_SPEED_SCALE) == int(ponynav::INPUT_SPEED_SCALE), "input slot");
static_assert(int(PonyNavigationNative::INPUT_FLAG_ROUTE_PENDING) == int(ponynav::INPUT_FLAG_ROUTE_PENDING), "flag");
static_assert(int(PonyNavigationNative::REFUSAL_TURN_SUPPORT) == int(ponynav::REFUSAL_TURN_SUPPORT), "refusal");
static_assert(int(PonyNavigationNative::EVENT_CORRIDOR_LOST) == int(ponynav::EVENT_CORRIDOR_LOST), "event");

bool PonyNavigationNative::follow_configure(int64_t p_slot, int64_t p_generation, const Dictionary &p_limits) {
	ponynav::SteeringLimits limits;
	limits.accel = number(p_limits, "accel", limits.accel);
	limits.braking = number(p_limits, "braking", limits.braking);
	limits.yaw_rate_max = number(p_limits, "yaw_rate_max", limits.yaw_rate_max);
	limits.lateral_accel = number(p_limits, "lateral_accel", limits.lateral_accel);
	limits.step_turn_rate = number(p_limits, "step_turn_rate", limits.step_turn_rate);
	limits.walk_speed = number(p_limits, "walk_speed", limits.walk_speed);
	limits.lookahead_time = number(p_limits, "lookahead_time", limits.lookahead_time);
	limits.lookahead_min = number(p_limits, "lookahead_min", limits.lookahead_min);
	limits.lookahead_max = number(p_limits, "lookahead_max", limits.lookahead_max);
	limits.approach_distance = number(p_limits, "approach_distance", limits.approach_distance);
	limits.arrival_radius = number(p_limits, "arrival_radius", limits.arrival_radius);
	limits.floor_tolerance = number(p_limits, "floor_tolerance", limits.floor_tolerance);
	limits.projection_vertical = number(p_limits, "projection_vertical", limits.projection_vertical);
	limits.capsule_radius = number(p_limits, "capsule_radius", limits.capsule_radius);
	limits.body_radius = number(p_limits, "body_radius", limits.body_radius);
	limits.max_curvature = number(p_limits, "max_curvature", limits.max_curvature);
	limits.reversal_radius = number(p_limits, "reversal_radius", limits.reversal_radius);
	limits.escape_lateral = number(p_limits, "escape_lateral", limits.escape_lateral);
	return service->follow_configure(actor_handle(p_slot, p_generation), limits, nullptr);
}

Dictionary PonyNavigationNative::follow_set_corridor(int64_t p_slot, int64_t p_generation, const PackedVector3Array &p_points,
		const Dictionary &p_options, const Vector3 &p_position, double p_heading, const Vector3 &p_velocity) {
	ponynav::CorridorRequest request;
	request.points.reserve(size_t(p_points.size()));
	for (int64_t i = 0; i < p_points.size(); ++i) {
		request.points.push_back(vec(p_points[i]));
	}
	request.route = uint64_t(std::max<int64_t>(0, integer(p_options, "route", 0)));
	request.intent = uint64_t(std::max<int64_t>(0, integer(p_options, "intent", 0)));
	request.terminal = flag(p_options, "terminal", true);
	request.authored = flag(p_options, "authored", false);
	const Variant goal = p_options.get("goal", Variant());
	if (goal.get_type() == Variant::VECTOR3) {
		request.has_goal = true;
		request.goal = vec(Vector3(goal));
	}
	const ponynav::CorridorReply reply =
			service->follow_set_corridor(actor_handle(p_slot, p_generation), request, vec(p_position), p_heading, vec(p_velocity));
	Dictionary result;
	result["accepted"] = reply.accepted;
	result["reason"] = String(reply.reason.c_str());
	result["goal_appended"] = reply.goal_appended;
	result["alternative"] = reply.alternative;
	result["prepended"] = reply.prepended;
	result["join_s"] = reply.join_s;
	result["join_lateral"] = reply.join_lateral;
	result["escape_length"] = reply.escape_length;
	result["length"] = reply.length;
	result["points"] = int64_t(reply.points);
	return result;
}

bool PonyNavigationNative::follow_clear(int64_t p_slot, int64_t p_generation) {
	return service->follow_clear(actor_handle(p_slot, p_generation));
}

PackedFloat32Array PonyNavigationNative::step_batch(const PackedInt64Array &p_actor_keys, const PackedVector3Array &p_positions,
		const PackedVector3Array &p_velocities, const PackedFloat32Array &p_headings, double p_delta,
		const PackedFloat32Array &p_inputs) {
	const int64_t rows = p_positions.size();
	batch_positions.resize(size_t(rows));
	for (int64_t i = 0; i < rows; ++i) {
		batch_positions[size_t(i)] = vec(p_positions[i]);
	}
	const int64_t velocity_rows = p_velocities.size();
	batch_velocities.resize(size_t(velocity_rows));
	for (int64_t i = 0; i < velocity_rows; ++i) {
		batch_velocities[size_t(i)] = vec(p_velocities[i]);
	}
	std::string error;
	const bool ok = service->follow_step(p_actor_keys.ptr(), size_t(p_actor_keys.size()), batch_positions.data(),
			batch_positions.size(), batch_velocities.data(), batch_velocities.size(), p_headings.ptr(),
			size_t(p_headings.size()), p_delta, p_inputs.size() > 0 ? p_inputs.ptr() : nullptr, size_t(p_inputs.size()),
			batch_commands, batch_state_rows, batch_preferred_rows, error);
	PackedFloat32Array result;
	if (!ok) {
		UtilityFunctions::push_error("PonyNavigationNative.", String(error.c_str()));
		return result;
	}
	result.resize(int64_t(batch_commands.size()));
	if (!batch_commands.empty()) {
		std::memcpy(result.ptrw(), batch_commands.data(), batch_commands.size() * sizeof(float));
	}
	return result;
}

PackedFloat32Array PonyNavigationNative::batch_state() {
	PackedFloat32Array result;
	result.resize(int64_t(batch_state_rows.size()));
	if (!batch_state_rows.empty()) {
		std::memcpy(result.ptrw(), batch_state_rows.data(), batch_state_rows.size() * sizeof(float));
	}
	return result;
}

PackedVector3Array PonyNavigationNative::batch_preferred_velocities() {
	PackedVector3Array result;
	result.resize(int64_t(batch_preferred_rows.size()));
	for (size_t i = 0; i < batch_preferred_rows.size(); ++i) {
		result.set(int64_t(i), vector(batch_preferred_rows[i]));
	}
	return result;
}

Array PonyNavigationNative::take_follow_events() {
	Array events;
	for (const ponynav::FollowEvent &entry : service->take_follow_events()) {
		Dictionary event;
		event["slot"] = int64_t(entry.actor.slot);
		event["generation"] = int64_t(entry.actor.generation);
		event["intent"] = int64_t(entry.intent);
		event["route"] = int64_t(entry.route);
		event["kind"] = int64_t(entry.kind);
		event["reason"] = String(entry.reason.c_str());
		event["at"] = vector(entry.at);
		event["alternative"] = entry.alternative;
		event["distance"] = entry.distance;
		PackedFloat32Array blocked;
		for (const ponynav::BlockedDisc &disc : entry.blocked) {
			blocked.append(float(disc.x));
			blocked.append(float(disc.z));
			blocked.append(float(disc.radius));
		}
		event["blocked"] = blocked;
		PackedFloat32Array peers;
		for (const ponynav::BlockedDisc &disc : entry.peers) {
			peers.append(float(disc.x));
			peers.append(float(disc.z));
			peers.append(float(disc.radius));
		}
		event["peer_blocked"] = peers;
		events.append(event);
	}
	return events;
}

Dictionary PonyNavigationNative::follow_state(int64_t p_slot, int64_t p_generation) {
	Dictionary result;
	const ponynav::FollowState *state = service->follow_state(actor_handle(p_slot, p_generation));
	result["live"] = state != nullptr;
	if (state == nullptr) {
		return result;
	}
	result["active"] = state->active;
	result["route"] = int64_t(state->route);
	result["intent"] = int64_t(state->intent);
	result["terminal"] = state->terminal;
	result["arrived"] = state->arrived;
	result["failed"] = state->failed;
	result["alternative"] = state->alternative;
	result["goal_appended"] = state->goal_appended;
	result["progress"] = state->s;
	result["raw_progress"] = state->raw_s;
	result["length"] = state->corridor.length();
	result["points"] = int64_t(state->corridor.size());
	result["escape_until"] = state->escape_until;
	result["lateral"] = state->last_projection.found ? state->last_projection.lateral : -1.0;
	result["segment"] = int64_t(state->last_projection.segment);
	result["speed"] = state->last.v;
	result["yaw_rate"] = state->last.w;
	result["curvature"] = state->last.k;
	result["reference_curvature"] = state->last.reference_curvature;
	result["mode"] = int64_t(state->last.mode);
	result["reason"] = String(ponynav::reason_name(state->last.reason));
	result["lookahead"] = state->last.lookahead;
	result["remaining"] = state->last.remaining;
	result["permitted"] = state->last.permitted;
	result["bearing"] = state->last.bearing;
	result["reversing"] = state->reversing;
	// Committed pass round a pony (navigation_steering.cpp pass_step).
	result["pass_side"] = int64_t(state->pass_side);
	result["pass_time"] = state->pass_time;
	result["pass_distance"] = state->pass_distance;
	result["escalation"] = String(ponynav::escalation_name(state->monitor.level()));
	result["stall_cause"] = String(state->monitor.cause());
	result["stalled"] = state->monitor.stalled();
	result["total_stalled"] = state->monitor.total_stalled();
	result["planning_wait"] = state->monitor.planning_wait();
	result["repairs"] = int64_t(state->monitor.repairs());
	result["replans"] = int64_t(state->monitor.replans());
	result["alternates"] = int64_t(state->monitor.alternates());
	result["intent_progress"] = state->intent_progress;
	result["blocked"] = int64_t(state->blocked.size());
	result["steps"] = int64_t(state->steps);
	result["stepping_turn_steps"] = int64_t(state->stepping_turn_steps);
	result["reversing_steps"] = int64_t(state->reversing_steps);
	result["brake_steps"] = int64_t(state->brake_steps);
	result["hold_steps"] = int64_t(state->hold_steps);
	result["candidates_validated"] = int64_t(state->last.candidates_validated);
	result["refused_ground"] = int64_t(state->last.refused_ground);
	result["refused_neighbour"] = int64_t(state->last.refused_neighbour);
	result["refused_escape"] = int64_t(state->last.refused_escape);
	result["refused_wall"] = int64_t(state->last.refused_wall);
	result["refused_blocked"] = int64_t(state->last.refused_blocked);
	result["start_located"] = state->last.start_located;
	result["neighbours"] = int64_t(state->last.neighbours);
	return result;
}

Dictionary PonyNavigationNative::follow_diagnostics() {
	const ponynav::FollowCounters &counters = service->follow_counters();
	Dictionary result;
	result["steps"] = int64_t(counters.steps);
	result["rows"] = int64_t(counters.rows);
	result["observers"] = int64_t(counters.observers);
	result["rejected_rows"] = int64_t(counters.rejected_rows);
	result["corridors"] = int64_t(counters.corridors);
	result["goal_appended"] = int64_t(counters.goal_appended);
	result["alternatives"] = int64_t(counters.alternatives);
	result["arrivals"] = int64_t(counters.arrivals);
	result["repairs"] = int64_t(counters.repairs);
	result["replans"] = int64_t(counters.replans);
	result["alternates"] = int64_t(counters.alternates);
	result["failures"] = int64_t(counters.failures);
	result["lost"] = int64_t(counters.lost);
	result["cells_checked"] = int64_t(counters.cells_checked);
	result["candidates_validated"] = int64_t(counters.candidates_validated);
	result["step_ms"] = counters.step_us / 1000.0;
	result["ground_entries"] = int64_t(service->follow_ground_entries());
	return result;
}

String PonyNavigationNative::reason_name(int64_t p_reason) {
	return String(ponynav::reason_name(int32_t(p_reason)));
}

Vector3 PonyNavigationNative::pursuit(const Vector3 &p_position, double p_yaw, const Vector3 &p_target) {
	ponynav::Pose2 pose;
	pose.x = p_position.x;
	pose.z = p_position.z;
	pose.yaw = p_yaw;
	double forward = 0.0;
	double left = 0.0;
	const double curvature = ponynav::pursuit_curvature(pose, p_target.x, p_target.z, forward, left);
	return Vector3(float(curvature), float(forward), float(left));
}
