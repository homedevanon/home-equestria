// Native pony navigation, phase 2 follower service: corridors, the batch step and follower events
// (NavigationService members declared in navigation_jobs.h; docs/NAVIGATION_PHASE_2_2026_10_02.md).
//
// Tick order inside one step, per actor (the GDScript batch driver already gathered the actor's
// position, velocity and heading produced by the last physical move, and applied ownership):
//   1. advance progress from actual movement (bounded forward window; recovery only when lost);
//   2. arrival on the terminal region and floor, emitted once;
//   3. contact and refusal evidence from the last move (frontal wall, unsafe support);
//   4. steering: lookahead, preferred velocity for avoidance, feasible validated command;
//   5. progress classification and escalation (repair -> replan -> alternate -> failure).
// The caller applies each command once and returns the actual motion on the next step.
#include "navigation_jobs.h"

#include <algorithm>

namespace ponynav {

namespace {

using Clock = std::chrono::steady_clock;

double elapsed_us(Clock::time_point started) {
	return double(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started).count()) / 1000.0;
}

bool finite_limits(const SteeringLimits &l) {
	const double values[] = { l.accel, l.braking, l.yaw_rate_max, l.lateral_accel, l.step_turn_rate, l.walk_speed,
		l.lookahead_time, l.lookahead_min, l.lookahead_max, l.approach_distance, l.arrival_radius, l.floor_tolerance,
		l.projection_vertical, l.capsule_radius, l.body_radius, l.max_curvature, l.reversal_radius, l.escape_lateral };
	for (double value : values) {
		if (!std::isfinite(value) || value < 0.0) {
			return false;
		}
	}
	return l.accel > 0.0 && l.braking > 0.0 && l.yaw_rate_max > 0.0 && l.lateral_accel > 0.0 && l.max_curvature > 0.0 &&
			l.lookahead_min > 0.0 && l.lookahead_max >= l.lookahead_min;
}

void add_blocked(FollowState &follow, double x, double z, double radius) {
	for (const BlockedDisc &disc : follow.blocked) {
		if (std::hypot(disc.x - x, disc.z - z) < 0.3) {
			return;
		}
	}
	if (follow.blocked.size() >= 8) {
		follow.blocked.erase(follow.blocked.begin());
	}
	BlockedDisc disc;
	disc.x = x;
	disc.z = z;
	disc.radius = radius;
	follow.blocked.push_back(disc);
}

// The native stall watchdog is blind to ponies otherwise: held by ponies (one held or refused
// her within the last 3 s), the replan searches round the ones standing on her way ahead. The
// radius covers the follower's hard separation (body radii + 0.1, + 0.1 without an avoidance
// answer), a walk-grid cell (search discs test cell centres) and 0.1 m to spare
// (peer_passage.gd PEER_DISC_PAD is the same).
constexpr double PEER_DISC_PAD = 0.55;

void peer_discs(const FollowState &follow, const std::vector<Neighbour> &neighbours, const Vec3f &p,
		std::vector<BlockedDisc> &out) {
	out.clear();
	if (follow.neighbour_age > 3.0) {
		return;
	}
	for (const Neighbour &other : neighbours) {
		if (std::hypot(other.vx, other.vz) >= 0.25 || std::hypot(other.x - double(p.x), other.z - double(p.z)) > 4.5) {
			continue;
		}
		const CorridorProjection near =
				follow.corridor.project_window(other.x, double(p.y), other.z, follow.s, 0.5, 5.0, 3.0);
		if (!near.found || near.lateral > 1.5) {
			continue;
		}
		BlockedDisc disc;
		disc.x = other.x;
		disc.z = other.z;
		disc.radius = follow.limits.body_radius + other.radius + PEER_DISC_PAD;
		out.push_back(disc);
		if (out.size() >= 6) {
			break;
		}
	}
}

void write_command(std::vector<float> &commands, size_t row, bool valid, double speed, double yaw_rate, int32_t mode) {
	float *out = commands.data() + row * size_t(COMMAND_STRIDE);
	out[0] = valid ? 1.0f : 0.0f;
	out[1] = float(speed);
	out[2] = float(yaw_rate);
	out[3] = float(mode);
}

} // namespace

bool NavigationService::follow_configure(const ActorHandle &handle, const SteeringLimits &limits, const ProgressTuning *tuning) {
	Actor *actor = live_actor(handle);
	if (actor == nullptr || !finite_limits(limits)) {
		return false;
	}
	actor->follow.limits = limits;
	if (tuning != nullptr) {
		actor->follow.tuning = *tuning;
	}
	actor->follow.monitor.set_tuning(actor->follow.tuning);
	return true;
}

NavigationService::FollowGround *NavigationService::follow_ground(uint32_t world_id, const GroundProfile &profile,
		double required) {
	NavigationWorld *target = world(world_id);
	if (target == nullptr) {
		return nullptr;
	}
	std::shared_ptr<const Snapshot> snapshot = target->snapshot();
	FollowGround *found = nullptr;
	for (const std::unique_ptr<FollowGround> &entry : follow_grounds) {
		if (entry->world == world_id && entry->required == required && entry->profile.same(profile)) {
			found = entry.get();
			break;
		}
	}
	if (found == nullptr) {
		follow_grounds.push_back(std::unique_ptr<FollowGround>(new FollowGround()));
		found = follow_grounds.back().get();
		found->world = world_id;
		found->profile = profile;
		found->required = required;
	}
	if (found->snapshot != snapshot || !found->access) {
		// A new snapshot: the clearance cache's layers stay valid per chunk neighbourhood revision.
		found->validator.reset();
		found->cache = target->cache();
		found->access.reset(new GroundAccess(snapshot, found->cache, profile));
		found->validator.reset(new ArcValidator(*found->access, required));
		found->snapshot = snapshot;
	}
	found->used = follow_clock;
	// Entries nobody used for a while (a profile that left, a world without followers).
	if (follow_grounds.size() > 8) {
		follow_grounds.erase(std::remove_if(follow_grounds.begin(), follow_grounds.end(),
									 [this, found](const std::unique_ptr<FollowGround> &entry) {
										 return entry.get() != found && follow_clock - entry->used > 1200;
									 }),
				follow_grounds.end());
	}
	return found;
}

void NavigationService::follow_event(const ActorHandle &handle, const FollowState &follow, int32_t kind,
		const std::string &reason, const Vec3f &at) {
	FollowEvent event;
	event.actor = handle;
	event.intent = follow.intent;
	event.route = follow.route;
	event.kind = kind;
	event.reason = reason;
	event.at = at;
	event.alternative = follow.alternative;
	if (!follow.corridor.empty()) {
		const Vec3f end = follow.corridor.end();
		event.distance = std::hypot(double(at.x) - double(end.x), double(at.z) - double(end.z));
	}
	if (kind == EVENT_REPLAN || kind == EVENT_ALTERNATE) {
		event.blocked = follow.blocked;
	}
	follow_events.push_back(event);
}

CorridorReply NavigationService::follow_set_corridor(const ActorHandle &handle, const CorridorRequest &request,
		const Vec3f &position, double heading, const Vec3f &velocity) {
	CorridorReply reply;
	Actor *actor = live_actor(handle);
	if (actor == nullptr) {
		reply.reason = "stale actor";
		return reply;
	}
	if (!position.finite() || !std::isfinite(heading) || !velocity.finite()) {
		reply.reason = "non-finite actor state";
		return reply;
	}
	if (request.points.size() < 2) {
		reply.reason = "a corridor needs at least two points";
		return reply;
	}
	for (const Vec3f &point : request.points) {
		if (!point.finite()) {
			reply.reason = "corridor points must be finite";
			return reply;
		}
	}
	FollowState &follow = actor->follow;
	const SteeringLimits &lim = follow.limits;
	std::vector<Vec3f> points = request.points;
	FollowGround *ground =
			follow_ground(actor->world, actor->profile, required_clearance(lim.capsule_radius, CELL * 0.5, 0.35 / (CELL * 0.5)));
	ArcValidator *validator = ground != nullptr && !request.authored ? ground->validator.get() : nullptr;

	// Arrival is judged against the requested destination: when the route ends on a nearby cell
	// centre, extend it to the destination itself if that last step certifies; otherwise the
	// arrival is reported as a goal-region alternative.
	if (request.terminal && request.has_goal && request.goal.finite()) {
		const Vec3f end = points.back();
		const double gap = std::hypot(double(request.goal.x) - double(end.x), double(request.goal.z) - double(end.z));
		if (gap <= 0.02) {
			reply.goal_appended = true;
		} else if (gap <= 1.0 && validator != nullptr) {
			const Handle from = validator->locate(end.x, end.y, end.z, 0.4);
			const Handle goal = validator->locate(request.goal.x, end.y, request.goal.z, 0.4);
			if (from != NO_HANDLE && goal != NO_HANDLE && validator->certifies(goal, false)) {
				const size_t count = size_t(std::ceil(gap / (CELL * 0.5)));
				std::vector<Pose2> samples(count);
				for (size_t i = 0; i < count; ++i) {
					const double t = double(i + 1) / double(count);
					samples[i].x = double(end.x) + (double(request.goal.x) - double(end.x)) * t;
					samples[i].z = double(end.z) + (double(request.goal.z) - double(end.z)) * t;
				}
				if (validator->walk(from, samples.data(), samples.size(), false)) {
					points.push_back(Vec3f(request.goal.x, validator->ground().span(goal).floor_y, request.goal.z));
					reply.goal_appended = true;
				}
			}
		}
		if (!reply.goal_appended) {
			reply.alternative = gap > lim.arrival_radius;
		}
	}
	// A cramped start: her own cell has no body room and the route begins on the nearest roomy
	// cell (the search snaps up to a metre). Begin the corridor where she stands when the step to
	// the route's start is walkable floor; the escape prefix below relaxes validation along it.
	if (validator != nullptr) {
		const Handle here = validator->locate(position.x, position.y, position.z, 0.4);
		Corridor original;
		const bool shaped = original.assign(points);
		const CorridorProjection near = shaped ? original.project_window(position.x, position.y, position.z, 0.0, 0.0,
														 std::min(original.length(), 2.5), lim.projection_vertical)
											   : CorridorProjection();
		if (here != NO_HANDLE && !validator->certifies(here, false) && near.found && near.lateral > 0.05 &&
				near.lateral <= 2.5) {
			// Join the route at her projection on it (not at a start cell diagonally behind her).
			const Vec3f joint = original.point_at(near.s);
			const size_t count = size_t(std::ceil(near.lateral / (CELL * 0.5)));
			std::vector<Pose2> samples(count);
			for (size_t i = 0; i < count; ++i) {
				const double t = double(i + 1) / double(count);
				samples[i].x = double(position.x) + (double(joint.x) - double(position.x)) * t;
				samples[i].z = double(position.z) + (double(joint.z) - double(position.z)) * t;
			}
			if (validator->walk(here, samples.data(), samples.size(), true)) {
				std::vector<Vec3f> joined{ Vec3f(position.x, validator->ground().span(here).floor_y, position.z), joint };
				const std::vector<Vec3f> &shape = original.points();
				for (size_t i = 0; i < shape.size(); ++i) {
					if (original.cumulative(i) > near.s + 1e-6) {
						joined.push_back(shape[i]);
					}
				}
				points = joined;
				reply.prepended = true;
			}
		}
	}
	Corridor corridor;
	if (!corridor.assign(points)) {
		reply.reason = "degenerate corridor";
		return reply;
	}
	// Cramped escape prefix: the route's first points may lie on floor without full body room
	// (the search seeded her nook); validation is relaxed there and she keeps to the centre line.
	double escape = 0.0;
	if (validator != nullptr) {
		const std::vector<Vec3f> &shape = corridor.points();
		size_t first_room = shape.size();
		for (size_t i = 0; i < shape.size(); ++i) {
			const Handle at = validator->locate(shape[i].x, shape[i].y, shape[i].z, 0.4);
			if (at != NO_HANDLE && validator->certifies(at, false)) {
				first_room = i;
				break;
			}
		}
		escape = first_room >= shape.size() ? corridor.length() : corridor.cumulative(first_room);
		escape = std::min(escape, 3.0);
	}
	// Join a forward section near the corridor's start (the route was searched from where she
	// was a moment ago), keeping her actual velocity. A join she cannot reach directly falls back
	// to the corridor's start.
	const double speed = std::hypot(double(velocity.x), double(velocity.z));
	const CorridorProjection join = corridor.project_window(position.x, position.y, position.z, 0.0, 0.0,
			std::min(corridor.length(), 3.0 + speed), lim.projection_vertical);
	double join_s = 0.0;
	if (join.found) {
		join_s = join.s;
		reply.join_lateral = join.lateral;
		if (join.lateral > 0.5 && validator != nullptr) {
			const Handle at = validator->locate(position.x, position.y, position.z, 0.4);
			const Vec3f target = corridor.point_at(join.s);
			const size_t count = size_t(std::ceil(join.lateral / (CELL * 0.5)));
			std::vector<Pose2> samples(count);
			for (size_t i = 0; i < count; ++i) {
				const double t = double(i + 1) / double(count);
				samples[i].x = double(position.x) + (double(target.x) - double(position.x)) * t;
				samples[i].z = double(position.z) + (double(target.z) - double(position.z)) * t;
			}
			if (!validator->walk(at, samples.data(), samples.size(), escape > 0.0)) {
				join_s = 0.0;
			}
		}
	}
	const bool new_intent = request.intent != follow.intent;
	if (new_intent) {
		follow.monitor.reset();
		follow.monitor.set_tuning(follow.tuning);
		follow.blocked.clear();
		follow.intent_progress = 0.0;
		follow.yield_time = 0.0;
		follow.frontal_contact = 0.0;
		follow.refused = 0.0;
		follow.pass_id = 0;
		follow.pass_side = 0;
		follow.pass_time = 0.0;
		follow.pass_distance = 0.0;
		follow.side_memory_id = 0;
		follow.side_memory = 0;
		follow.side_memory_age = 1e9;
		follow.turn_sign = 0;
		follow.turn_sign_age = 1e9;
		follow.neighbour_age = 1e9;
	} else {
		follow.monitor.corridor_replaced(request.route);
	}
	follow.corridor = std::move(corridor);
	follow.route = request.route;
	follow.intent = request.intent;
	follow.terminal = request.terminal;
	follow.authored = request.authored;
	follow.goal = request.goal;
	follow.alternative = reply.alternative;
	follow.goal_appended = reply.goal_appended;
	follow.s = join_s;
	follow.raw_s = join_s;
	follow.escape_until = escape;
	follow.active = true;
	follow.arrived = false;
	follow.failed = false;
	follow.lost = false;
	follow.reversing = false;
	follow.reversal_side = 0;
	follow.end_blocked = 0.0;
	follow.unlocated = 0.0;
	++follow_stats.corridors;
	if (reply.goal_appended) {
		++follow_stats.goal_appended;
	}
	if (reply.alternative) {
		++follow_stats.alternatives;
	}
	reply.accepted = true;
	reply.join_s = join_s;
	reply.escape_length = escape;
	reply.length = follow.corridor.length();
	reply.points = int32_t(follow.corridor.size());
	return reply;
}

bool NavigationService::follow_clear(const ActorHandle &handle) {
	Actor *actor = live_actor(handle);
	if (actor == nullptr) {
		return false;
	}
	actor->follow.active = false;
	actor->follow.corridor.clear();
	actor->follow.prev_v = 0.0;
	actor->follow.prev_k = 0.0;
	actor->follow.reversing = false;
	actor->follow.pass_side = 0;
	actor->follow.pass_id = 0;
	return true;
}

std::vector<FollowEvent> NavigationService::take_follow_events() {
	std::vector<FollowEvent> result;
	result.swap(follow_events);
	return result;
}

const FollowState *NavigationService::follow_state(const ActorHandle &handle) const {
	const Actor *actor = live_actor(handle);
	return actor == nullptr ? nullptr : &actor->follow;
}

bool NavigationService::follow_step(const int64_t *keys, size_t key_count, const Vec3f *positions, size_t position_count,
		const Vec3f *velocities, size_t velocity_count, const float *headings, size_t heading_count, double delta,
		const float *inputs, size_t input_count, std::vector<float> &commands, std::vector<float> &state,
		std::vector<Vec3f> &preferred, std::string &error) {
	const Clock::time_point started = Clock::now();
	const size_t rows = position_count;
	commands.assign(rows * size_t(COMMAND_STRIDE), 0.0f);
	state.assign(rows * size_t(STATE_STRIDE), 0.0f);
	preferred.assign(rows, Vec3f());
	if (key_count != rows * 2 || velocity_count != rows || heading_count != rows ||
			(input_count != 0 && input_count != rows * size_t(INPUT_STRIDE))) {
		error = "step_batch: actor_keys needs 2 entries, velocities and headings 1, inputs 0 or INPUT_STRIDE per position";
		return false;
	}
	if (!std::isfinite(delta) || delta <= 0.0 || delta > 1.0) {
		error = "step_batch: delta must be finite, positive and at most 1 s";
		return false;
	}
	++follow_clock;
	++follow_stats.steps;
	std::vector<FollowRow> &table = follow_table;
	table.assign(rows, FollowRow());
	for (size_t i = 0; i < rows; ++i) {
		FollowRow &row = table[i];
		row.usable = positions[i].finite() && velocities[i].finite() && std::isfinite(headings[i]);
		if (row.usable) row.speed = std::hypot(double(velocities[i].x), double(velocities[i].z));
		const int64_t slot = keys[i * 2];
		const int64_t generation = keys[i * 2 + 1];
		if (slot < 0 && generation > 0) {
			row.identity = uint64_t(generation);
		}
		if (slot >= 0 && generation > 0 && slot <= 0xffffffffll && generation <= 0xffffffffll) {
			row.handle.slot = uint32_t(slot);
			row.handle.generation = uint32_t(generation);
			row.identity = (uint64_t(slot) << 32) | uint64_t(generation);
			Actor *actor = live_actor(row.handle);
			if (actor != nullptr && actor->follow.active) {
				row.actor = actor;
			}
		}
	}
	FollowBatch batch;
	batch.positions = positions;
	batch.velocities = velocities;
	batch.headings = headings;
	batch.inputs = inputs;
	batch.input_count = input_count;
	batch.rows = rows;
	batch.delta = delta;
	batch.table = &table;
	batch.commands = &commands;
	batch.state = &state;
	batch.preferred = &preferred;
	size_t followers = 0;
	for (size_t i = 0; i < rows; ++i) {
		if (table[i].actor == nullptr) {
			++follow_stats.observers;
		} else {
			++follow_stats.rows;
			++followers;
		}
	}
	bool parallel = parallel_follow && parallel_for != nullptr && followers >= parallel_min_rows;
	if (parallel) {
		// One actor in two rows steps twice, in row order: only the serial step keeps that order.
		std::vector<const Actor *> &seen = follow_seen;
		seen.clear();
		for (size_t i = 0; i < rows; ++i) {
			if (table[i].actor != nullptr) {
				seen.push_back(table[i].actor);
			}
		}
		std::sort(seen.begin(), seen.end());
		parallel = std::adjacent_find(seen.begin(), seen.end()) == seen.end();
	}
	if (parallel) {
		// Ground lookups (they may create or refresh follow_grounds) stay on this thread.
		for (size_t i = 0; i < rows; ++i) {
			FollowRow &row = table[i];
			if (row.actor == nullptr) {
				continue;
			}
			const SteeringLimits &lim = row.actor->follow.limits;
			row.ground = follow_ground(row.actor->world, row.actor->profile,
					required_clearance(lim.capsule_radius, CELL * 0.5, 0.35 / (CELL * 0.5)));
		}
		const size_t blocks = std::min(PARALLEL_MAX_BLOCKS, followers);
		if (follow_blocks.size() < blocks) {
			follow_blocks.resize(blocks);
		}
		// Idle blocks drop their ground copies (they would keep old snapshots alive).
		for (size_t b = blocks; b < follow_blocks.size(); ++b) {
			follow_blocks[b].grounds.clear();
		}
		// Contiguous row ranges, in row order, so the merged events keep the serial order.
		size_t next = 0;
		for (size_t b = 0; b < blocks; ++b) {
			FollowBlock &block = follow_blocks[b];
			block.rows.clear();
			block.sink.stats = FollowCounters();
			block.sink.events.clear();
			const size_t take = followers / blocks + (b < followers % blocks ? 1 : 0);
			while (block.rows.size() < take && next < rows) {
				if (table[next].actor != nullptr) {
					block.rows.push_back(next);
				}
				++next;
			}
		}
		FollowParallelJob job;
		job.service = this;
		job.batch = &batch;
		job.blocks = blocks;
		parallel_for(&NavigationService::follow_block_job, &job, uint32_t(blocks));
		for (size_t b = 0; b < blocks; ++b) {
			FollowSink &sink = follow_blocks[b].sink;
			merge_counters(follow_stats, sink.stats);
			for (FollowEvent &event : sink.events) {
				follow_events.push_back(std::move(event));
			}
			sink.events.clear();
		}
	} else {
		for (FollowBlock &block : follow_blocks) {
			block.grounds.clear();
		}
		FollowSink &sink = follow_serial_sink;
		sink.stats = FollowCounters();
		sink.events.clear();
		for (size_t i = 0; i < rows; ++i) {
			if (table[i].actor != nullptr) {
				follow_row(batch, i, sink, nullptr);
			}
		}
		merge_counters(follow_stats, sink.stats);
		for (FollowEvent &event : sink.events) {
			follow_events.push_back(std::move(event));
		}
		sink.events.clear();
	}
	follow_stats.step_us += elapsed_us(started);
	return true;
}

NavigationService::ParallelFor NavigationService::parallel_for = nullptr;
bool NavigationService::parallel_follow = true;
size_t NavigationService::parallel_min_rows = 4;

void NavigationService::follow_block_job(void *data, uint32_t index) {
	FollowParallelJob *job = static_cast<FollowParallelJob *>(data);
	if (index >= job->blocks) {
		return;
	}
	NavigationService *service = job->service;
	FollowBlock &block = service->follow_blocks[index];
	for (size_t i : block.rows) {
		service->follow_row(*job->batch, i, block.sink, &block);
	}
}

ArcValidator *NavigationService::block_validator(FollowBlock &block, const FollowGround &ground) {
	if (ground.access == nullptr || ground.snapshot == nullptr || ground.cache == nullptr) {
		return nullptr;
	}
	FollowBlockGround *found = nullptr;
	for (const std::unique_ptr<FollowBlockGround> &entry : block.grounds) {
		if (entry->world == ground.world && entry->required == ground.required && entry->profile.same(ground.profile)) {
			found = entry.get();
			break;
		}
	}
	if (found == nullptr) {
		// Bounded like follow_grounds: a block keeps at most a few profiles.
		if (block.grounds.size() >= 16) {
			block.grounds.clear();
		}
		block.grounds.push_back(std::unique_ptr<FollowBlockGround>(new FollowBlockGround()));
		found = block.grounds.back().get();
		found->world = ground.world;
		found->profile = ground.profile;
		found->required = ground.required;
	}
	if (found->snapshot != ground.snapshot || !found->access) {
		found->validator.reset();
		found->access.reset(new GroundAccess(ground.snapshot, ground.cache, ground.profile));
		found->validator.reset(new ArcValidator(*found->access, ground.required));
		found->snapshot = ground.snapshot;
	}
	return found->validator.get();
}

void NavigationService::sink_event(FollowSink &sink, const ActorHandle &handle, const FollowState &follow, int32_t kind,
		const std::string &reason, const Vec3f &at) {
	FollowEvent event;
	event.actor = handle;
	event.intent = follow.intent;
	event.route = follow.route;
	event.kind = kind;
	event.reason = reason;
	event.at = at;
	event.alternative = follow.alternative;
	if (!follow.corridor.empty()) {
		const Vec3f end = follow.corridor.end();
		event.distance = std::hypot(double(at.x) - double(end.x), double(at.z) - double(end.z));
	}
	if (kind == EVENT_REPLAN || kind == EVENT_ALTERNATE) {
		event.blocked = follow.blocked;
	}
	sink.events.push_back(event);
}

void NavigationService::merge_counters(FollowCounters &into, const FollowCounters &from) {
	into.steps += from.steps;
	into.rows += from.rows;
	into.observers += from.observers;
	into.rejected_rows += from.rejected_rows;
	into.corridors += from.corridors;
	into.goal_appended += from.goal_appended;
	into.alternatives += from.alternatives;
	into.arrivals += from.arrivals;
	into.repairs += from.repairs;
	into.replans += from.replans;
	into.alternates += from.alternates;
	into.failures += from.failures;
	into.lost += from.lost;
	into.cells_checked += from.cells_checked;
	into.candidates_validated += from.candidates_validated;
	into.step_us += from.step_us;
}

// One follower row of follow_step() (steps 1-5 of the file comment). Reads only this row's actor
// (and the other rows' positions, velocities and limits); writes only this row's outputs.
void NavigationService::follow_row(const FollowBatch &batch, size_t i, FollowSink &sink, FollowBlock *block) {
	const std::vector<FollowRow> &table = *batch.table;
	const Vec3f *positions = batch.positions;
	const Vec3f *velocities = batch.velocities;
	const float *headings = batch.headings;
	const float *inputs = batch.inputs;
	const size_t input_count = batch.input_count;
	const size_t rows = batch.rows;
	const double delta = batch.delta;
	std::vector<float> &commands = *batch.commands;
	std::vector<float> &state = *batch.state;
	std::vector<Vec3f> &preferred = *batch.preferred;
	const FollowRow &row = table[i];
	FollowState &follow = row.actor->follow;
	const SteeringLimits &lim = follow.limits;
	const float *in = input_count != 0 ? inputs + i * size_t(INPUT_STRIDE) : nullptr;
	bool inputs_ok = row.usable;
	if (in != nullptr) {
		for (int32_t k = 0; k < INPUT_STRIDE; ++k) {
			inputs_ok = inputs_ok && std::isfinite(in[k]);
		}
	}
	float *state_row = state.data() + i * size_t(STATE_STRIDE);
	if (!inputs_ok) {
		// NaN/INF never reaches the steering: a navigation-owned actor gets a valid stop.
		++sink.stats.rejected_rows;
		write_command(commands, i, true, 0.0, 0.0, MODE_STOP);
		state_row[5] = float(REASON_INVALID_INPUT);
		follow.last.reason = REASON_INVALID_INPUT;
		return;
	}
	const double dt = (in != nullptr && in[INPUT_STEP_SECONDS] > 0.0f && in[INPUT_STEP_SECONDS] <= 1.0f)
			? double(in[INPUT_STEP_SECONDS])
			: delta;
	const Vec3f &p = positions[i];
	const Vec3f &velocity = velocities[i];
	const double yaw = headings[i];
	double fx = 0.0, fz = 0.0;
	forward_of(yaw, fx, fz);
	const double speed = std::max(0.0, double(velocity.x) * fx + double(velocity.z) * fz);
	++follow.steps;

	// 1. Progress from actual movement.
	const double ahead = std::max(2.0, speed + 1.5);
	CorridorProjection projection = follow.corridor.project_window(p.x, p.y, p.z, follow.s, 0.75, ahead,
			lim.projection_vertical);
	bool recovered = false;
	const bool repairing = follow.monitor.level() == Escalation::LOCAL_REPAIR;
	if (!projection.found || projection.lateral > 2.5 || (repairing && projection.lateral > 0.75)) {
		// Explicit recovery: every segment, nearest wins (may move progress back).
		const CorridorProjection all = follow.corridor.project_all(p.x, p.y, p.z, lim.projection_vertical);
		if (all.found && (!projection.found || all.lateral + 0.25 < projection.lateral)) {
			projection = all;
			recovered = true;
		}
	}
	if (!projection.found || projection.lateral > 4.0) {
		if (!follow.lost) {
			follow.lost = true;
			++sink.stats.lost;
			sink_event(sink, row.handle, follow, EVENT_CORRIDOR_LOST, "Off the route corridor", p);
		}
		const double braked = std::max(0.0, speed - lim.braking * dt);
		write_command(commands, i, true, braked, 0.0, braked > 0.0 ? MODE_BRAKE : MODE_STOP);
		state_row[0] = float(follow.s);
		state_row[5] = float(REASON_CORRIDOR_LOST);
		follow.last.reason = REASON_CORRIDOR_LOST;
		follow.prev_v = braked;
		follow.prev_k = 0.0;
		return;
	}
	follow.lost = false;
	double gained = 0.0;
	if (projection.s > follow.s) {
		gained = projection.s - follow.s;
		follow.s = projection.s;
	} else if (recovered) {
		follow.s = projection.s;
	}
	follow.raw_s = projection.s;
	follow.intent_progress += gained;
	follow.last_projection = projection;

	// 2. Arrival: the terminal region on the right floor, emitted once. Emitted 2 mm inside the
	// acceptance radius, so single-precision rounding in the caller never reports an arrival
	// outside it.
	const Vec3f end = follow.corridor.end();
	const double end_distance = std::hypot(double(p.x) - double(end.x), double(p.z) - double(end.z));
	if (follow.terminal && !follow.arrived && !follow.failed && end_distance <= std::max(0.0, lim.arrival_radius - 0.002) &&
			std::fabs(double(p.y) - double(end.y)) <= lim.floor_tolerance &&
			follow.corridor.length() - follow.s <= lim.arrival_radius + 0.5) {
		follow.arrived = true;
		++sink.stats.arrivals;
		sink_event(sink, row.handle, follow, EVENT_ARRIVED,
				follow.alternative ? "Arrived at the nearest reachable spot" : "Arrived", p);
	}
	if (follow.arrived || follow.failed) {
		write_command(commands, i, true, 0.0, 0.0, MODE_STOP);
		state_row[0] = float(follow.s);
		state_row[1] = float(projection.segment);
		state_row[5] = float(follow.arrived ? REASON_ARRIVED : REASON_FAILED);
		follow.last.reason = follow.arrived ? REASON_ARRIVED : REASON_FAILED;
		follow.prev_v = 0.0;
		follow.prev_k = 0.0;
		return;
	}

	// 3. Evidence from the last physical move.
	const int32_t flags = in != nullptr ? int32_t(in[INPUT_FLAGS]) : 0;
	double nx = in != nullptr ? double(in[INPUT_WALL_NX]) : 0.0;
	double nz = in != nullptr ? double(in[INPUT_WALL_NZ]) : 0.0;
	const double normal = std::hypot(nx, nz);
	const bool wall = (flags & INPUT_FLAG_WALL) != 0 && normal > 1e-6;
	if (wall) {
		nx /= normal;
		nz /= normal;
	}
	const double executed = in != nullptr ? double(in[INPUT_EXECUTED_SPEED]) : speed;
	const bool frontal = wall && fx * nx + fz * nz < -0.7 && (follow.prev_v > 0.05 || executed > 0.05);
	if (frontal) {
		// Something the walk grid does not know stopped her nose-on: mark it at once (a small
		// disc inside it, behind the contact) so no later arc tries to walk through it again.
		add_blocked(follow, double(p.x) - nx * (lim.capsule_radius + 0.3), double(p.z) - nz * (lim.capsule_radius + 0.3), 0.35);
	}
	// Held by that obstruction: still pushing, or stopped because every arc meets the mark.
	const bool held_by_obstruction = frontal ||
			(speed < 0.05 && (follow.last.refused_blocked > 0 || follow.last.refused_wall > 0) && !follow.blocked.empty());
	follow.frontal_contact = held_by_obstruction ? follow.frontal_contact + dt
												 : std::max(0.0, follow.frontal_contact - 0.5 * dt);
	Escalation forced = Escalation::NONE;
	if (follow.frontal_contact > 0.6) {
		// Repeated frontal obstruction: repair the route around the marked area.
		follow.frontal_contact = 0.0;
		forced = follow.monitor.force(Escalation::REPLAN, "repeated frontal obstruction");
	}
	const int32_t refusal = in != nullptr ? int32_t(in[INPUT_REFUSAL]) : REFUSAL_NONE;
	follow.refused = refusal == REFUSAL_SUPPORT ? follow.refused + dt : std::max(0.0, follow.refused - dt);
	if (follow.refused > 1.5) {
		follow.refused = 0.0;
		add_blocked(follow, double(p.x) + fx * (lim.capsule_radius + 0.5), double(p.z) + fz * (lim.capsule_radius + 0.5), 0.35);
		if (forced == Escalation::NONE) {
			forced = follow.monitor.force(Escalation::REPLAN, "unsafe support ahead");
		}
	}
	if (forced == Escalation::REPLAN) {
		++sink.stats.replans;
		sink_event(sink, row.handle, follow, EVENT_REPLAN, std::string("Replanning: ") + follow.monitor.cause(), p);
	}

	// 4. Steering.
	SteeringInput steering;
	steering.pose.x = p.x;
	steering.pose.z = p.z;
	steering.pose.yaw = yaw;
	steering.y = p.y;
	steering.speed = speed;
	steering.dt = dt;
	steering.requested_speed = in != nullptr ? std::max(0.0, double(in[INPUT_REQUESTED_SPEED])) : lim.walk_speed;
	steering.terminal_speed = in != nullptr ? std::max(0.0, double(in[INPUT_TERMINAL_SPEED])) : 0.0;
	steering.speed_scale = in != nullptr ? double(in[INPUT_SPEED_SCALE]) : 1.0;
	steering.terminal = follow.terminal;
	steering.has_avoidance = (flags & INPUT_FLAG_AVOIDANCE) != 0;
	steering.avoid_vx = in != nullptr ? double(in[INPUT_AVOID_VX]) : 0.0;
	steering.avoid_vz = in != nullptr ? double(in[INPUT_AVOID_VZ]) : 0.0;
	steering.avoid_age = in != nullptr ? double(in[INPUT_AVOID_AGE]) : 1e9;
	steering.wall = wall;
	steering.wall_nx = nx;
	steering.wall_nz = nz;
	steering.prev_v = follow.prev_v;
	steering.prev_k = follow.prev_k;
	steering.prev_mode = follow.prev_mode;
	steering.prev_pref_vx = follow.pref_vx;
	steering.prev_pref_vz = follow.pref_vz;
	steering.reversal_side = follow.reversal_side;
	steering.reversing = follow.reversing;
	steering.turn_target = follow.turn_target;
	steering.prev_reason = follow.last.reason;
	steering.escape_until = follow.escape_until;
	steering.repair = follow.monitor.level() == Escalation::LOCAL_REPAIR;
	steering.support_refused = refusal == REFUSAL_SUPPORT;
	steering.ignore_yield = follow.yield_time > follow.tuning.yielding_limit;
	ArcValidator *validator = nullptr;
	if (block == nullptr) {
		FollowGround *ground = follow_ground(row.actor->world, row.actor->profile,
				required_clearance(lim.capsule_radius, CELL * 0.5, 0.35 / (CELL * 0.5)));
		validator = ground != nullptr && !follow.authored ? ground->validator.get() : nullptr;
	} else if (row.ground != nullptr && !follow.authored) {
		validator = block_validator(*block, *row.ground);
	}
	const uint64_t cells_before = validator != nullptr ? validator->cells_checked : 0;
	const Handle start = validator != nullptr ? validator->locate(p.x, p.y, p.z, 0.4) : NO_HANDLE;
	// The walk grid lost her floor while she follows (a streamed column republished at another
	// height): no arc can start, and no local repair can help. Replan from where she is now.
	follow.unlocated = (validator != nullptr && start == NO_HANDLE) ? follow.unlocated + dt : 0.0;
	if (follow.unlocated > 0.5 && forced == Escalation::NONE) {
		follow.unlocated = 0.0;
		if (follow.monitor.force(Escalation::REPLAN, "the walk grid lost her floor") == Escalation::REPLAN) {
			++sink.stats.replans;
			sink_event(sink, row.handle, follow, EVENT_REPLAN, "Replanning: the walk grid lost her floor", p);
		}
	}
	std::vector<Neighbour> &neighbours = sink.neighbours;
	neighbours.clear();
	for (size_t j = 0; j < rows; ++j) {
		if (j == i || !table[j].usable) {
			continue;
		}
		const Vec3f &other = positions[j];
		// See oncoming traffic before the pair uses up its braking distance.
		const double other_speed = table[j].speed;
		const double braking = std::max(0.1, lim.braking);
		const double reach = std::max(3.5, (speed + other_speed) * 0.8 +
				(speed * speed + other_speed * other_speed) / (2.0 * braking));
		if (std::fabs(double(other.x) - double(p.x)) > reach || std::fabs(double(other.z) - double(p.z)) > reach ||
				std::fabs(double(other.y) - double(p.y)) > 1.5) {
			continue;
		}
		Neighbour neighbour;
		neighbour.x = other.x;
		neighbour.z = other.z;
		neighbour.vx = velocities[j].x;
		neighbour.vz = velocities[j].z;
		neighbour.radius = table[j].actor != nullptr ? table[j].actor->follow.limits.body_radius : lim.body_radius;
		neighbour.walker = table[j].actor != nullptr;
		// Stable across ticks (a committed pass and its remembered side name the pony): her
		// identity (native_follow_driver.gd gives observer rows one too), else her row.
		neighbour.id = table[j].identity != 0 ? table[j].identity : (uint64_t(1) << 63) | uint64_t(j);
		neighbours.push_back(neighbour);
	}
	// A pony that is not moving stands on her destination, and she is about as close as the
	// neighbour separation lets her come: she waits there, and arrives at the nearest reachable spot.
	// "On" it means the separation round that pony covers the whole arrival circle: no spot within
	// the arrival radius of the destination is a body's width from her. A pony merely beside the
	// destination leaves it reachable, so the walker goes on and arrives for real (2026-10-31: with
	// the test at separation PLUS the arrival radius, leaving Hayburger customers stopped 1.7 m
	// short of a departure spot beside an earlier customer and parked in the walkway for 90 s).
	bool goal_occupied = false;
	if (follow.terminal) {
		for (const Neighbour &other : neighbours) {
			const double reach = lim.body_radius + other.radius + 0.2;
			if (std::hypot(other.vx, other.vz) < 0.25 &&
					std::hypot(other.x - double(end.x), other.z - double(end.z)) < reach - lim.arrival_radius &&
					end_distance <= reach + 0.6) {
				goal_occupied = true;
				break;
			}
		}
	}
	steering.goal_occupied = goal_occupied;
	steering.pass_id = follow.pass_id;
	steering.pass_side = follow.pass_side;
	steering.pass_time = follow.pass_time;
	steering.pass_distance = follow.pass_distance;
	if (follow.side_memory_age < 6.0) {
		steering.side_memory_id = follow.side_memory_id;
		steering.side_memory = follow.side_memory;
	}
	steering.turn_hold = follow.turn_sign_age < 1.5 ? follow.turn_sign : 0;
	SteeringOutput out = steer(follow.corridor, follow.s, steering, lim, validator, start, follow.blocked, neighbours);
	if (validator != nullptr) {
		sink.stats.cells_checked += validator->cells_checked - cells_before;
	}
	sink.stats.candidates_validated += uint64_t(std::max(0, out.candidates_validated));
	// The yield timer runs while avoidance keeps answering zero, whether she still obeys it.
	follow.yield_time = out.zero_answer ? follow.yield_time + dt : 0.0;
	// Pass bookkeeping: its time and distance, the side kept for that pony (a side found shut
	// flips it), and the last in-place turn's direction.
	if (out.failed_pass_side != 0) {
		follow.side_memory_id = out.failed_pass_id;
		follow.side_memory = -out.failed_pass_side;
		follow.side_memory_age = 0.0;
	}
	if (out.pass_side != 0) {
		if (out.pass_side == follow.pass_side && out.pass_id == follow.pass_id) {
			follow.pass_time += dt;
			follow.pass_distance += speed * dt;
		} else {
			follow.pass_time = 0.0;
			follow.pass_distance = 0.0;
		}
		follow.side_memory_id = out.pass_id;
		follow.side_memory = out.pass_side;
		follow.side_memory_age = 0.0;
	} else {
		follow.pass_time = 0.0;
		follow.pass_distance = 0.0;
		if (out.failed_pass_side == 0) {
			follow.side_memory_age += dt;
		}
	}
	follow.pass_id = out.pass_id;
	follow.pass_side = out.pass_side;
	if (out.mode == MODE_STEP_TURN || out.reason == REASON_REVERSING) {
		follow.turn_sign = out.w >= 0.0 ? 1 : -1;
		follow.turn_sign_age = 0.0;
	} else {
		follow.turn_sign_age += dt;
	}
	follow.neighbour_age = (out.reason == REASON_NEIGHBOUR || out.refused_neighbour > 0 || out.yielding ||
								   out.pass_side != 0)
			? 0.0
			: follow.neighbour_age + dt;
	// Held within twice the arrival radius of a destination she cannot step any closer to
	// (every arc refused by the ground, a wall or ponies standing at it): after half a second
	// that is arrival at the nearest reachable spot, reported as a goal-region alternative,
	// never a failure and never a plain arrival.
	// A pony standing on the destination itself holds her a body's width short of it: the same.
	const bool held_short = follow.terminal && (end_distance <= 2.0 * lim.arrival_radius || goal_occupied) &&
			std::fabs(double(p.y) - double(end.y)) <= lim.floor_tolerance && speed < 0.05 && out.v < 0.05 &&
			(goal_occupied || out.reason == REASON_NO_SAFE_ARC || out.reason == REASON_WALL_CONTACT ||
					out.reason == REASON_REPAIR || out.reason == REASON_NEIGHBOUR);
	follow.end_blocked = held_short ? follow.end_blocked + dt : 0.0;
	if (follow.end_blocked > 0.5 && !follow.arrived) {
		follow.arrived = true;
		follow.alternative = true;
		++sink.stats.arrivals;
		++sink.stats.alternatives;
		sink_event(sink, row.handle, follow, EVENT_ARRIVED, "Arrived at the nearest reachable spot", p);
		out.v = 0.0;
		out.w = 0.0;
		out.k = 0.0;
		out.mode = MODE_STOP;
		out.reason = REASON_ARRIVED;
	}
	const double remaining = std::max(0.0, follow.corridor.length() - follow.s);
	if (!follow.terminal && remaining < 0.3 && out.v < 0.1 && out.reason == REASON_NONE) {
		out.reason = (flags & INPUT_FLAG_ROUTE_PENDING) != 0 ? REASON_WAITING_ROUTE : REASON_CORRIDOR_END;
	}

	// 5. Progress classification and escalation.
	FollowClass klass = FollowClass::FOLLOWING;
	if (out.mode == MODE_STEP_TURN || out.reason == REASON_REVERSING) {
		klass = FollowClass::TURNING;
	} else if (out.yielding) {
		klass = FollowClass::YIELDING;
	} else if (out.reason == REASON_WAITING_ROUTE) {
		klass = FollowClass::WAITING_ROUTE;
	}
	ProgressSample sample;
	sample.route = follow.route;
	sample.progress = follow.s;
	sample.raw_progress = projection.s;
	sample.intent_progress = follow.intent_progress;
	sample.x = p.x;
	sample.z = p.z;
	sample.yaw = yaw;
	sample.goal_distance = end_distance;
	sample.command = out.v;
	sample.actual = speed;
	sample.permitted = out.permitted;
	sample.contact_nx = wall ? nx : 0.0;
	sample.contact_nz = wall ? nz : 0.0;
	sample.gained = gained;
	sample.reason = out.reason;
	follow.monitor.set_budget_bonus(0.1 * follow.intent_progress);
	const Escalation entered = follow.monitor.update(dt, klass, sample);
	switch (entered) {
		case Escalation::LOCAL_REPAIR:
			++sink.stats.repairs;
			sink_event(sink, row.handle, follow, EVENT_REPAIR, std::string("Local repair: ") + follow.monitor.cause(), p);
			break;
		case Escalation::REPLAN:
			++sink.stats.replans;
			sink_event(sink, row.handle, follow, EVENT_REPLAN,
					std::string("No route progress after a local repair (") + follow.monitor.cause() + ")", p);
			peer_discs(follow, neighbours, p, sink.events.back().peers);
			break;
		case Escalation::ALTERNATE:
			++sink.stats.alternates;
			sink_event(sink, row.handle, follow, EVENT_ALTERNATE,
					std::string("Still blocked after a replan (") + follow.monitor.cause() + ")", p);
			peer_discs(follow, neighbours, p, sink.events.back().peers);
			break;
		case Escalation::FAILED:
			++sink.stats.failures;
			follow.failed = true;
			sink_event(sink, row.handle, follow, EVENT_FAILED,
					follow.monitor.total_stalled() > follow.tuning.total_stall_limit
							? "Blocked: stalled too long on this trip"
							: "Blocked: no progress after a local repair, a replan and an alternate route",
					p);
			out.v = 0.0;
			out.w = 0.0;
			out.k = 0.0;
			out.mode = MODE_STOP;
			out.reason = REASON_FAILED;
			break;
		default:
			break;
	}

	// Output and the record kept for the next tick.
	write_command(commands, i, true, out.v, out.w, out.mode);
	state_row[0] = float(follow.s);
	state_row[1] = float(projection.segment);
	state_row[2] = float(out.lookahead);
	state_row[3] = float(remaining);
	state_row[4] = float(out.reference_curvature);
	state_row[5] = float(out.reason);
	state_row[6] = float(out.preferred_vx);
	state_row[7] = float(out.preferred_vz);
	preferred[i] = Vec3f(float(out.preferred_vx), 0.0f, float(out.preferred_vz));
	follow.prev_v = out.v;
	follow.prev_k = out.k;
	follow.prev_mode = out.mode;
	follow.pref_vx = out.preferred_vx;
	follow.pref_vz = out.preferred_vz;
	follow.reversal_side = out.reversal_side;
	follow.reversing = out.reversing;
	follow.turn_target = out.turn_target;
	follow.last = out;
	if (out.mode == MODE_STEP_TURN) {
		++follow.stepping_turn_steps;
	} else if (out.reason == REASON_REVERSING) {
		++follow.reversing_steps;
	} else if (out.mode == MODE_BRAKE) {
		++follow.brake_steps;
	} else if (out.mode == MODE_HOLD) {
		++follow.hold_steps;
	}
}

} // namespace ponynav
