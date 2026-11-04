// Native pony navigation, steering: see navigation_steering.h.
#include "navigation_steering.h"

#include <algorithm>

namespace ponynav {

namespace {

constexpr double REVERSE_ENTER = 100.0 * PI_D / 180.0;
constexpr double REVERSE_EXIT = 60.0 * PI_D / 180.0;
constexpr double STEP_TURN_BEARING = 30.0 * PI_D / 180.0;
// A stopped pony with no valid arc realigns by a stepping turn above this bearing; a stepping
// turn once started completes down to STEP_TURN_DONE (no flip-flopping with tiny arcs).
constexpr double STEP_TURN_REALIGN = 8.0 * PI_D / 180.0;
constexpr double STEP_TURN_DONE = 12.0 * PI_D / 180.0;
// A stepping turn round a pony in the way aims this far past the tangent, away from her, and
// completes to within STEP_TARGET_DONE: walking off then always opens the gap.
constexpr double STEP_AWAY = 15.0 * PI_D / 180.0;
constexpr double STEP_TARGET_DONE = 4.0 * PI_D / 180.0;
// Time a candidate control is held before its stopping curve; the validated arc covers it.
constexpr double HOLD_SECONDS = 0.25;
// Avoidance answers older than this are missing, not proposals.
constexpr double AVOIDANCE_FRESH = 0.25;
// Neighbour prediction samples (seconds).
constexpr double NEIGHBOUR_HORIZON = 0.8;
constexpr double NEIGHBOUR_STEP = 0.1;
// A committed pass round a pony in the way (2026-10-31; tools/navigation/probe_heading_flips.gd).
// The old step round turned her to the tangent beside the pony and let the next tick decide
// afresh: for a pony dead ahead that tangent lies about 105 degrees off her way, past
// REVERSE_ENTER, so a reversal turned her straight back into it and the step round fired again,
// sometimes to the other side (left 225 / right 225 degrees, for ever). Now she walks round it on
// the chosen side, along the circle about it and a little outward, until it is a little behind her.
constexpr double PASS_SECONDS = 8.0;
constexpr double PASS_DISTANCE = 3.5;
// A pony walking away from her faster than this needs no going round.
constexpr double PASS_RECEDING = 0.3;
constexpr double PASS_OUTWARD = 12.0 * PI_D / 180.0;
// Outward turn while she is inside the hard separation (spawned or pushed close).
constexpr double PASS_TIGHT = 30.0 * PI_D / 180.0;
// Stopped and further off the pass heading than this: a stepping turn before any arc.
constexpr double PASS_ALIGN = 35.0 * PI_D / 180.0;
// The pass ends once the pony is this far behind her along the corridor's direction where she is
// (not along the lookahead target: that lies on the corridor through the pony, beside it). Ended
// just abeam, the pursuit arc back to the corridor ran into the pony and she stood beside it; past
// abeam the circle itself bends her back toward the route behind it.
constexpr double PASS_BEHIND = 0.4;

inline double clampd(double value, double low, double high) {
	return std::max(low, std::min(high, value));
}

inline double signd(double value) {
	return value < 0.0 ? -1.0 : 1.0;
}

struct Candidate {
	double v = 0.0;
	double k = 0.0;
	int32_t mode = MODE_TRAVEL;
	int32_t id = 0;
	double cost = 0.0;
	// Extra arc to validate (a reversal must have room for the whole turn).
	double turn_distance = 0.0;
};

struct Context {
	const Corridor &corridor;
	double s;
	const SteeringInput &in;
	const SteeringLimits &lim;
	ArcValidator *validator;
	Handle start;
	const std::vector<BlockedDisc> &blocked;
	const std::vector<Neighbour> &neighbours;
	std::vector<Pose2> buffer;
	double lookahead = 0.0;
	double target_speed = 0.0;
	double k_ref = 0.0;
	double v_ref = 0.0;
	bool pressure = false;
	double u_x = 0.0;
	double u_z = 0.0;
	double neighbour_margin = 0.0;
	int32_t validated = 0;
	int32_t last_refusal = REASON_NO_SAFE_ARC;
	int32_t refused_ground = 0;
	int32_t refused_neighbour = 0;
	int32_t refused_escape = 0;
	int32_t refused_wall = 0;
	int32_t refused_blocked = 0;

	Context(const Corridor &p_corridor, double p_s, const SteeringInput &p_in, const SteeringLimits &p_lim,
			ArcValidator *p_validator, Handle p_start, const std::vector<BlockedDisc> &p_blocked,
			const std::vector<Neighbour> &p_neighbours) :
			corridor(p_corridor), s(p_s), in(p_in), lim(p_lim), validator(p_validator), start(p_start), blocked(p_blocked),
			neighbours(p_neighbours) {}
};

// Distance travelled after t seconds of the hold-then-brake profile.
double profile_distance(double v, double braking, double t) {
	if (t <= HOLD_SECONDS) {
		return v * t;
	}
	const double after = t - HOLD_SECONDS;
	const double stop_time = braking > 0.0 ? v / braking : 0.0;
	const double braking_time = std::min(after, stop_time);
	return v * HOLD_SECONDS + v * braking_time - 0.5 * braking * braking_time * braking_time;
}

// Smallest predicted separation from one neighbour over the horizon, and the current one.
void neighbour_separation(const Context &c, const Candidate &candidate, const Neighbour &other, double &now,
		double &smallest) {
	const Pose2 &pose = c.in.pose;
	now = std::hypot(pose.x - other.x, pose.z - other.z);
	smallest = now;
	for (double t = NEIGHBOUR_STEP; t <= NEIGHBOUR_HORIZON + 1e-9; t += NEIGHBOUR_STEP) {
		const Pose2 at = arc_pose(pose, candidate.k, profile_distance(candidate.v, c.lim.braking, t));
		const double ox = other.x + other.vx * t;
		const double oz = other.z + other.vz * t;
		smallest = std::min(smallest, std::hypot(at.x - ox, at.z - oz));
	}
}

// A blocked disc refuses a sample inside it. Contact discs are recorded just beyond the
// contact point, which leaves the pony's own position inside the newest one: then every
// arc failed at its first sample, even one leading straight away, and she stood pinned
// against a wardrobe or armchair forever (houses D and G). From a start already inside a
// disc, only samples that come closer to it than the start are refused.
bool disc_refuses(const BlockedDisc &disc, const Pose2 &start, const Pose2 &at, double capsule_radius) {
	const double limit = disc.radius + capsule_radius;
	const double here = std::hypot(at.x - disc.x, at.z - disc.z);
	if (here >= limit) {
		return false;
	}
	const double from = std::hypot(start.x - disc.x, start.z - disc.z);
	return from >= limit || here < from - 0.01;
}

double hard_separation(const Context &c, const Neighbour &other) {
	return c.lim.body_radius + other.radius + 0.1 + c.neighbour_margin;
}

// Collision constraints first: ground (body room along the swept arc), the intent's blocked
// discs, the cramped escape corridor, wall contact and neighbours (unless `with_neighbours` is off:
// an emergency brake that no neighbour constraint allows must still keep to safe ground).
bool validate(Context &c, const Candidate &candidate, bool with_neighbours = true) {
	++c.validated;
	const Pose2 &pose = c.in.pose;
	const double v = std::max(0.0, candidate.v);
	if (candidate.mode == MODE_STEP_TURN) {
		// Turning on the spot sweeps nothing: the collision capsule is vertical and round.
		return true;
	}
	if (v < 0.01 && candidate.turn_distance <= 0.0) {
		// Stopping where she stands is always allowed.
		return true;
	}
	double distance = v * HOLD_SECONDS + v * v / (2.0 * c.lim.braking) + candidate.turn_distance + 0.05;
	distance = std::max(distance, 0.15);
	const double spacing = sample_spacing(candidate.k);
	const size_t count = size_t(std::ceil(distance / spacing));
	c.buffer.resize(count);
	for (size_t i = 0; i < count; ++i) {
		c.buffer[i] = arc_pose(pose, candidate.k, distance * double(i + 1) / double(count));
	}
	for (const Pose2 &at : c.buffer) {
		for (const BlockedDisc &disc : c.blocked) {
			if (disc_refuses(disc, pose, at, c.lim.capsule_radius)) {
				c.last_refusal = REASON_WALL_CONTACT;
				++c.refused_blocked;
				return false;
			}
		}
	}
	const bool relaxed = c.s < c.in.escape_until;
	if (relaxed) {
		for (const Pose2 &at : c.buffer) {
			const CorridorProjection near = c.corridor.project_window(at.x, c.in.y, at.z, c.s, 0.5, distance + 0.5, 3.0);
			if (!near.found || near.lateral > c.lim.escape_lateral) {
				c.last_refusal = REASON_NO_SAFE_ARC;
				++c.refused_escape;
				return false;
			}
		}
	}
	if (c.in.wall && v > 0.05) {
		const Pose2 soon = arc_pose(pose, candidate.k, std::min(distance, std::max(0.05, v * 0.2)));
		double hx = 0.0, hz = 0.0;
		forward_of(soon.yaw, hx, hz);
		if (hx * c.in.wall_nx + hz * c.in.wall_nz < -0.2) {
			c.last_refusal = REASON_WALL_CONTACT;
			++c.refused_wall;
			return false;
		}
	}
	if (c.validator != nullptr && !c.validator->walk(c.start, c.buffer.data(), c.buffer.size(), relaxed)) {
		c.last_refusal = REASON_NO_SAFE_ARC;
		++c.refused_ground;
		return false;
	}
	if (!with_neighbours) {
		return true;
	}
	for (const Neighbour &other : c.neighbours) {
		double now = 0.0, smallest = 0.0;
		neighbour_separation(c, candidate, other, now, smallest);
		// Never closer than the hard separation; once inside it (spawned overlapping), never closer
		// than now. Moving away is always allowed.
		if (smallest < hard_separation(c, other) && smallest < now - 1e-6) {
			c.last_refusal = REASON_NEIGHBOUR;
			++c.refused_neighbour;
			return false;
		}
	}
	return true;
}

double score(Context &c, const Candidate &candidate) {
	const Pose2 &pose = c.in.pose;
	const double v = std::max(0.0, candidate.v);
	const double horizon = clampd(c.lookahead / std::max(c.target_speed, 0.3), 0.4, 1.2);
	const Pose2 end = arc_pose(pose, candidate.k, v * horizon);
	const CorridorProjection near =
			c.corridor.project_window(end.x, c.in.y, end.z, c.s, 1.0, v * horizon + c.lookahead + 1.0, 3.0);
	const double gain = near.found ? near.s - c.s : 0.0;
	const double expected = std::max(0.3, c.target_speed * horizon);
	const double lateral = near.found ? near.lateral : 3.0;
	double tx = 0.0, tz = -1.0;
	c.corridor.tangent_at(near.found ? near.s : c.s, tx, tz);
	const double heading_error = std::fabs(wrap_angle(end.yaw - yaw_of(tx, tz)));
	// Under avoidance pressure the preferred velocity leads and the corridor may be left for a while.
	const double lateral_scale = c.pressure ? 1.0 : 0.5;
	const double lateral_weight = c.pressure ? 0.3 : 0.8;
	const double reference_weight = c.pressure ? 0.1 : 0.6;
	double cost = clampd((expected - gain) / expected, -0.5, 2.0);
	cost += lateral_weight * std::min(4.0, (lateral / lateral_scale) * (lateral / lateral_scale));
	cost += 0.3 * heading_error / PI_D;
	cost += reference_weight * std::fabs(candidate.k - c.k_ref) / (std::fabs(c.k_ref) + 0.5);
	cost += 0.4 * std::fabs(v - c.v_ref) / std::max(c.v_ref, 0.5);
	cost += 0.2 * (std::fabs(v - c.in.prev_v) / std::max(c.in.prev_v, 0.5) +
						  std::fabs(candidate.k - c.in.prev_k) / (std::fabs(c.in.prev_k) + 0.5));
	if (c.pressure) {
		const Pose2 soon = arc_pose(pose, candidate.k, v * 0.3);
		double hx = 0.0, hz = 0.0;
		forward_of(soon.yaw, hx, hz);
		const double u = std::hypot(c.u_x, c.u_z);
		cost += 2.5 * std::hypot(hx * v - c.u_x, hz * v - c.u_z) / std::max(u, 0.5);
	}
	double fx = 0.0, fz = 0.0;
	forward_of(pose.yaw, fx, fz);
	double end_lx = 0.0, end_lz = 0.0;
	left_of(end.yaw, end_lx, end_lz);
	for (const Neighbour &other : c.neighbours) {
		double now = 0.0, smallest = 0.0;
		neighbour_separation(c, candidate, other, now, smallest);
		const double soft = 2.0 * hard_separation(c, other) + 0.3;
		if (smallest < soft) {
			cost += 0.8 * (soft - smallest) / soft;
		}
		// Keep right of an oncoming pony, whatever the avoidance proposal says: RVO has no
		// handedness, and two ponies picking mirrored sides stood nose to nose (2 m lanes).
		const double ahead = (other.x - pose.x) * fx + (other.z - pose.z) * fz;
		const double closing = -(other.vx * fx + other.vz * fz);
		if (ahead > 0.0 && closing > 0.2 && now < soft + 1.5) {
			const double ox = other.x + other.vx * horizon - end.x;
			const double oz = other.z + other.vz * horizon - end.z;
			const double side = ox * end_lx + oz * end_lz;
			if (side < 0.0 && std::fabs(side) < soft) {
				cost += 0.5;
			}
		}
	}
	return cost;
}

bool cheaper(const Candidate &a, const Candidate &b) {
	if (a.cost != b.cost) {
		return a.cost < b.cost;
	}
	return a.id < b.id;
}

// A straight walk of `distance` from where she stands at heading `yaw`, validated like any arc
// (ground, blocked discs, escape corridor and neighbours).
bool straight_valid(Context &c, double yaw, double distance) {
	Pose2 start = c.in.pose;
	start.yaw = yaw;
	const double spacing = sample_spacing(0.0);
	const size_t count = size_t(std::ceil(distance / spacing));
	c.buffer.resize(count);
	for (size_t i = 0; i < count; ++i) {
		c.buffer[i] = arc_pose(start, 0.0, distance * double(i + 1) / double(count));
	}
	++c.validated;
	for (const Pose2 &at : c.buffer) {
		for (const BlockedDisc &disc : c.blocked) {
			if (disc_refuses(disc, start, at, c.lim.capsule_radius)) {
				return false;
			}
		}
	}
	const bool relaxed = c.s < c.in.escape_until;
	if (relaxed) {
		for (const Pose2 &at : c.buffer) {
			const CorridorProjection near = c.corridor.project_window(at.x, c.in.y, at.z, c.s, 0.5, distance + 0.5, 3.0);
			if (!near.found || near.lateral > c.lim.escape_lateral) {
				return false;
			}
		}
	}
	if (c.validator != nullptr && !c.validator->walk(c.start, c.buffer.data(), c.buffer.size(), relaxed)) {
		return false;
	}
	for (const Neighbour &other : c.neighbours) {
		const double now = std::hypot(start.x - other.x, start.z - other.z);
		for (double t = NEIGHBOUR_STEP; t <= 1.0; t += NEIGHBOUR_STEP) {
			const Pose2 at = arc_pose(start, 0.0, std::min(distance, 0.3 * t));
			const double d = std::hypot(at.x - (other.x + other.vx * t), at.z - (other.z + other.vz * t));
			if (d < hard_separation(c, other) && d < now - 1e-6) {
				return false;
			}
		}
	}
	return true;
}

// An emergency brake (nothing validated): the braked speed along the first curvature whose
// stopping arc keeps to certified ground, neighbours aside; straight when none does.
Candidate emergency_brake(Context &c, double v_lo, double k_ref, int32_t side_hint) {
	Candidate brake;
	brake.v = v_lo;
	brake.mode = MODE_BRAKE;
	const double dk = std::max(0.3, 0.5 * std::fabs(k_ref));
	const double curvatures[7] = { k_ref, k_ref - 0.5 * dk, k_ref + 0.5 * dk, k_ref - dk, k_ref + dk,
		double(side_hint) * c.lim.max_curvature * 0.5, 0.0 };
	for (double k : curvatures) {
		brake.k = clampd(k, -c.lim.max_curvature, c.lim.max_curvature);
		const double cap = curve_speed_limit(brake.k, c.lim.yaw_rate_max, c.lim.lateral_accel);
		if (cap + 1e-9 < v_lo) {
			continue;
		}
		if (validate(c, brake, false)) {
			return brake;
		}
	}
	brake.k = c.in.wall ? 0.0 : k_ref;
	return brake;
}

void finish_travel(SteeringOutput &out, const Candidate &chosen, const SteeringLimits &lim) {
	out.v = std::max(0.0, chosen.v);
	out.k = clampd(chosen.k, -lim.max_curvature, lim.max_curvature);
	out.w = clampd(out.k * out.v, -lim.yaw_rate_max, lim.yaw_rate_max);
	out.mode = chosen.mode;
	out.chosen = chosen.id;
}

const Neighbour *find_neighbour(const std::vector<Neighbour> &neighbours, uint64_t id) {
	for (const Neighbour &other : neighbours) {
		if (other.id == id) {
			return &other;
		}
	}
	return nullptr;
}

// Heading round `other` on `side` (+1: the tangent (-rz, rx) of the unit line r from it to her,
// -1: the opposite tangent), turned `outward` (plus `extra`) away from it so the gap only opens.
double pass_heading(const Context &c, const Neighbour &other, int32_t side, double extra) {
	const Pose2 &pose = c.in.pose;
	const double dx = pose.x - other.x;
	const double dz = pose.z - other.z;
	const double d = std::max(std::hypot(dx, dz), 1e-6);
	const double rx = dx / d;
	const double rz = dz / d;
	const double tx = side > 0 ? -rz : rz;
	const double tz = side > 0 ? rx : -rx;
	const double outward = (d < hard_separation(c, other) + 0.05 ? PASS_TIGHT : PASS_OUTWARD) + extra;
	return yaw_of(tx * std::cos(outward) + rx * std::sin(outward), tz * std::cos(outward) + rz * std::sin(outward));
}

// Room to get past the pony on `side`: certified ground on the straight line from her to the
// spot at hard separation beside it (square to her line to it). A pony standing in a gap or a
// narrow lane leaves none: going round her only meets the wall, so the older step round, the
// peer passage asks and reroutes deal with her instead (2026-10-31).
bool beside_open(Context &c, const Neighbour &other, int32_t side) {
	if (c.validator == nullptr) {
		return true;
	}
	const Pose2 &pose = c.in.pose;
	const double dx = pose.x - other.x;
	const double dz = pose.z - other.z;
	const double d = std::max(std::hypot(dx, dz), 1e-6);
	const double tx = side > 0 ? -dz / d : dz / d;
	const double tz = side > 0 ? dx / d : -dx / d;
	const double reach = hard_separation(c, other);
	const double px = other.x + tx * reach;
	const double pz = other.z + tz * reach;
	const double length = std::hypot(px - pose.x, pz - pose.z);
	const size_t count = std::max<size_t>(1, size_t(std::ceil(length / sample_spacing(0.0))));
	c.buffer.resize(count);
	for (size_t i = 0; i < count; ++i) {
		const double f = double(i + 1) / double(count);
		c.buffer[i].x = pose.x + (px - pose.x) * f;
		c.buffer[i].z = pose.z + (pz - pose.z) * f;
		c.buffer[i].yaw = pose.yaw;
	}
	++c.validated;
	return c.validator->walk(c.start, c.buffer.data(), c.buffer.size(), c.s < c.in.escape_until);
}

// The side whose pass heading lies nearer her way; her right on a near tie (keep right).
int32_t pass_side_for(const Context &c, const Neighbour &other, double way) {
	const double plus = wrap_angle(pass_heading(c, other, 1, 0.0) - way);
	const double minus = wrap_angle(pass_heading(c, other, -1, 0.0) - way);
	if (std::fabs(std::fabs(plus) - std::fabs(minus)) < 0.1) {
		return plus < minus ? 1 : -1;
	}
	return std::fabs(plus) < std::fabs(minus) ? 1 : -1;
}

// One tick of the committed pass round neighbour `id` on `side`. False when it is over (the pony
// is behind her or gone) or cannot go on along this side (recorded in out.failed_pass_*):
// the ordinary decision runs then. Every arc is validated like any other (ground, discs,
// neighbours).
bool pass_step(Context &c, SteeringOutput &out, uint64_t id, int32_t side, double target_speed, double v_lo,
		double v_hi) {
	const SteeringInput &in = c.in;
	const SteeringLimits &lim = c.lim;
	const Neighbour *other = find_neighbour(c.neighbours, id);
	if (other == nullptr || side == 0) {
		return false;
	}
	const Pose2 &pose = in.pose;
	double wx = 0.0, wz = -1.0;
	c.corridor.tangent_at(c.s, wx, wz);
	if ((other->x - pose.x) * wx + (other->z - pose.z) * wz <= -PASS_BEHIND) {
		return false;
	}
	const double gap = std::max(std::hypot(other->x - pose.x, other->z - pose.z), 1e-6);
	if ((other->vx * (other->x - pose.x) + other->vz * (other->z - pose.z)) / gap > PASS_RECEDING) {
		return false;
	}
	const double heading = pass_heading(c, *other, side, 0.0);
	const double error = wrap_angle(heading - pose.yaw);
	out.pass_id = id;
	out.pass_side = side;
	if (in.speed < 0.08 && std::fabs(error) > PASS_ALIGN) {
		out.v = 0.0;
		out.k = 0.0;
		out.w = signd(error) * lim.step_turn_rate;
		out.mode = MODE_STEP_TURN;
		out.reason = REASON_NEIGHBOUR;
		return true;
	}
	// Round a pony at an easy pace: never faster than her trip, never slower than a walk.
	const double pass_speed = clampd(target_speed, lim.walk_speed, std::max(lim.walk_speed, 1.0));
	const double reach = std::max(c.lookahead, 0.8);
	const int32_t shut_before = c.refused_ground + c.refused_blocked + c.refused_escape + c.refused_wall;
	// Headings from the corridor's own direction round to the pass heading and beyond it: the
	// first that validates keeps her as close to her way as the separation allows (hugging the
	// circle about the pony, which also fits a lane), never closer to it than she is.
	const double route = yaw_of(wx, wz);
	const double toward_route = wrap_angle(route - heading);
	double headings[7];
	int32_t count = 0;
	for (double f : { 1.0, 0.75, 0.5, 0.25, 0.0 }) {
		headings[count++] = heading + toward_route * f;
	}
	headings[count++] = pass_heading(c, *other, side, 0.3);
	headings[count++] = pass_heading(c, *other, side, 0.6);
	// Pace first, then the heading nearest her way: hugging tighter at a crawl is never preferred
	// to going round at the pass pace (that crawl read as a stall).
	double ks[7];
	for (int32_t e = 0; e < count; ++e) {
		double hx = 0.0, hz = 0.0;
		forward_of(headings[e], hx, hz);
		double f = 0.0, l = 0.0;
		ks[e] = clampd(pursuit_curvature(pose, pose.x + hx * reach, pose.z + hz * reach, f, l), -lim.max_curvature,
				lim.max_curvature);
	}
	// Each arc is validated at the pace it is meant to reach (never below v_lo), then commanded
	// at the acceleration window's speed: a shorter piece of the same validated arc. Validated at
	// the window's crawl from a stop, the most inward heading always passed and she crept along
	// the separation's edge without ever speeding up.
	const double first_k = ks[4];
	const double speeds[2] = { pass_speed, 0.5 * pass_speed };
	for (double wanted : speeds) {
		for (int32_t e = 0; e < count; ++e) {
			const double cap = curve_speed_limit(ks[e], lim.yaw_rate_max, lim.lateral_accel);
			Candidate candidate;
			candidate.v = std::max(std::min(wanted, cap), v_lo);
			candidate.k = ks[e];
			candidate.id = 2000 + e;
			if (candidate.v < 0.01) {
				continue;
			}
			if (validate(c, candidate)) {
				candidate.v = clampd(candidate.v, v_lo, v_hi);
				finish_travel(out, candidate, lim);
				out.reason = REASON_NONE;
				return true;
			}
		}
	}
	if (in.speed < 0.08) {
		if (std::fabs(error) > STEP_TARGET_DONE) {
			// Not yet turned far enough for an arc that opens the gap.
			out.v = 0.0;
			out.k = 0.0;
			out.w = signd(error) * lim.step_turn_rate;
			out.mode = MODE_STEP_TURN;
			out.reason = REASON_NEIGHBOUR;
			return true;
		}
		if (c.refused_ground + c.refused_blocked + c.refused_escape + c.refused_wall == shut_before) {
			// Only ponies refused it (the other one is still turning or stepping round her too):
			// wait a moment on this side; the pass's time limit bounds the wait.
			out.v = 0.0;
			out.k = 0.0;
			out.w = 0.0;
			out.mode = MODE_HOLD;
			out.reason = REASON_NEIGHBOUR;
			return true;
		}
		// Facing along the pass and the ground (a wall, a disc, the escape corridor) refuses it:
		// this side is shut. The caller tries the other side.
		out.pass_id = 0;
		out.pass_side = 0;
		out.failed_pass_id = id;
		out.failed_pass_side = side;
		return false;
	}
	// Moving: brake along the pass, still committed to it.
	const Candidate brake = emergency_brake(c, v_lo, first_k, first_k >= 0.0 ? 1 : -1);
	finish_travel(out, brake, lim);
	out.reason = REASON_NEIGHBOUR;
	return true;
}

} // namespace

const char *reason_name(int32_t reason) {
	switch (reason) {
		case REASON_NONE:
			return "";
		case REASON_STEPPING_TURN:
			return "stepping_turn";
		case REASON_YIELDING:
			return "yielding";
		case REASON_NO_SAFE_ARC:
			return "no_safe_arc";
		case REASON_CORRIDOR_END:
			return "corridor_end";
		case REASON_WALL_CONTACT:
			return "wall_contact";
		case REASON_SUPPORT_REFUSED:
			return "support_refused";
		case REASON_ARRIVED:
			return "arrived";
		case REASON_INVALID_INPUT:
			return "invalid_input";
		case REASON_REVERSING:
			return "reversing";
		case REASON_REPAIR:
			return "repair";
		case REASON_NEIGHBOUR:
			return "neighbour";
		case REASON_FAILED:
			return "failed";
		case REASON_AVOIDANCE_MISSING:
			return "avoidance_missing";
		case REASON_CORRIDOR_LOST:
			return "corridor_lost";
		case REASON_WAITING_ROUTE:
			return "waiting_route";
		default:
			return "unknown";
	}
}

bool reason_explains_stop(int32_t reason) {
	return reason != REASON_NONE && reason != REASON_REVERSING && reason != REASON_AVOIDANCE_MISSING;
}

Pose2 arc_pose(const Pose2 &start, double curvature, double distance) {
	Pose2 result;
	if (std::fabs(curvature) < 1e-9) {
		result.x = start.x - std::sin(start.yaw) * distance;
		result.z = start.z - std::cos(start.yaw) * distance;
		result.yaw = start.yaw;
		return result;
	}
	const double yaw = start.yaw + curvature * distance;
	result.x = start.x + (std::cos(yaw) - std::cos(start.yaw)) / curvature;
	result.z = start.z - (std::sin(yaw) - std::sin(start.yaw)) / curvature;
	result.yaw = wrap_angle(yaw);
	return result;
}

Pose2 advance_midpoint(const Pose2 &start, double speed, double yaw_rate, double dt) {
	const double middle = start.yaw + yaw_rate * dt * 0.5;
	Pose2 result;
	result.x = start.x - std::sin(middle) * speed * dt;
	result.z = start.z - std::cos(middle) * speed * dt;
	result.yaw = wrap_angle(start.yaw + yaw_rate * dt);
	return result;
}

double pursuit_curvature(const Pose2 &pose, double tx, double tz, double &forward, double &left) {
	double fx = 0.0, fz = 0.0, lx = 0.0, lz = 0.0;
	forward_of(pose.yaw, fx, fz);
	left_of(pose.yaw, lx, lz);
	const double dx = tx - pose.x;
	const double dz = tz - pose.z;
	forward = dx * fx + dz * fz;
	left = dx * lx + dz * lz;
	const double squared = forward * forward + left * left;
	if (squared < 1e-12) {
		return 0.0;
	}
	return 2.0 * left / squared;
}

double curve_speed_limit(double curvature, double yaw_rate_max, double lateral_accel) {
	const double k = std::fabs(curvature);
	if (k < 1e-6) {
		return INF;
	}
	return std::min(yaw_rate_max / k, std::sqrt(lateral_accel / k));
}

double stopping_speed(double distance, double end_speed, double braking) {
	return std::sqrt(std::max(0.0, end_speed * end_speed + 2.0 * braking * std::max(0.0, distance)));
}

double required_clearance(double capsule_radius, double spacing, double max_curvature) {
	double chord = 0.0;
	if (max_curvature > 1e-6) {
		const double radius = 1.0 / max_curvature;
		const double angle = std::min(spacing * max_curvature, PI_D);
		chord = radius * (1.0 - std::cos(angle * 0.5));
	}
	return capsule_radius + spacing * 0.5 + chord + CELL * std::sqrt(2.0) * 0.5;
}

double sample_spacing(double curvature) {
	double spacing = CELL * 0.5;
	if (std::fabs(curvature) > 1e-6) {
		spacing = std::min(spacing, 0.35 / std::fabs(curvature));
	}
	return spacing;
}

// ---------------------------------------------------------------------------------------------
// ArcValidator

ArcValidator::ArcValidator(GroundAccess &p_ground, double required_radius) :
		g(p_ground), radius(std::max(required_radius, p_ground.profile().radius)),
		pure(radius <= p_ground.profile().radius + 1e-9) {
}

Handle ArcValidator::locate(double x, double y, double z, double tolerance) {
	// Her own column first; a body standing a little off the sampled floor (a bump, a column the
	// stream republished at the heightmap) is found in her column up to 0.75 m, then in the eight
	// neighbouring columns within `tolerance`, nearest first. Validation still links every step.
	const int32_t cx = cell_coord(x);
	const int32_t cz = cell_coord(z);
	Handle best = NO_HANDLE;
	double best_score = INF;
	for (int32_t pass = 0; pass < 3 && best == NO_HANDLE; ++pass) {
		for (int32_t dz = -1; dz <= 1; ++dz) {
			for (int32_t dx = -1; dx <= 1; ++dx) {
				const bool own = dx == 0 && dz == 0;
				if ((pass < 2) != own) {
					continue;
				}
				const double reach = pass == 1 ? std::max(tolerance, 0.75) : tolerance;
				const GroundAccess::Column column = g.column(cx + dx, cz + dz);
				if (column.chunk < 0) {
					continue;
				}
				const GroundChunk &owner = g.chunk(uint32_t(column.chunk));
				for (uint32_t i = 0; i < column.count; ++i) {
					const double dy = std::fabs(double(owner.spans[column.first + i].floor_y) - y);
					const double score = dy + (own ? 0.0 : 0.25);
					if (dy <= reach && score < best_score) {
						best_score = score;
						best = make_handle(uint32_t(column.chunk), column.first + i);
					}
				}
			}
		}
	}
	return best;
}

bool ArcValidator::certifies(Handle handle, bool relaxed) {
	if (relaxed) {
		return g.allowed(g.span(handle));
	}
	return pure ? g.pure_room(handle) : g.room_radius(handle, radius);
}

bool ArcValidator::enter(Handle from, int32_t fx, int32_t fz, int32_t tx, int32_t tz, bool relaxed, Handle &out) {
	++cells_checked;
	const FloorSpan &source = g.span(from);
	const GroundAccess::Column column = g.column(tx, tz);
	if (column.chunk < 0) {
		return false;
	}
	const int32_t dx = tx - fx;
	const int32_t dz = tz - fz;
	const bool diagonal = dx != 0 && dz != 0;
	const double distance = diagonal ? CELL * std::sqrt(2.0) : CELL;
	const GroundChunk &owner = g.chunk(uint32_t(column.chunk));
	Handle best = NO_HANDLE;
	double best_dy = INF;
	for (uint32_t i = 0; i < column.count; ++i) {
		const Handle handle = make_handle(uint32_t(column.chunk), column.first + i);
		const FloorSpan &span = owner.spans[column.first + i];
		if (!g.link_from(source, span, distance)) {
			continue;
		}
		const double dy = std::fabs(double(span.floor_y) - double(source.floor_y));
		if (dy >= best_dy || !certifies(handle, relaxed)) {
			continue;
		}
		best_dy = dy;
		best = handle;
	}
	if (best == NO_HANDLE) {
		return false;
	}
	if (diagonal) {
		// A diagonal step may not squeeze between two touching blocked cells.
		const FloorSpan &dest = g.span(best);
		const int32_t sides[2][2] = { { fx + dx, fz }, { fx, fz + dz } };
		for (const auto &side : sides) {
			const GroundAccess::Column middle_column = g.column(side[0], side[1]);
			bool via = false;
			if (middle_column.chunk >= 0) {
				const GroundChunk &middle_owner = g.chunk(uint32_t(middle_column.chunk));
				for (uint32_t i = 0; i < middle_column.count; ++i) {
					const FloorSpan &middle = middle_owner.spans[middle_column.first + i];
					if (g.link_from(source, middle, CELL) && g.link(middle, dest, CELL)) {
						via = true;
						break;
					}
				}
			}
			if (!via) {
				return false;
			}
		}
	}
	out = best;
	return true;
}

bool ArcValidator::walk(Handle from, const Pose2 *samples, size_t count, bool relaxed) {
	if (from == NO_HANDLE) {
		return false;
	}
	int32_t cx = 0;
	int32_t cz = 0;
	g.cell(from, cx, cz);
	Handle current = from;
	for (size_t i = 0; i < count; ++i) {
		const int32_t tx = cell_coord(samples[i].x);
		const int32_t tz = cell_coord(samples[i].z);
		int32_t guard = 0;
		while ((cx != tx || cz != tz) && guard++ < 64) {
			const int32_t sx = tx > cx ? 1 : (tx < cx ? -1 : 0);
			const int32_t sz = tz > cz ? 1 : (tz < cz ? -1 : 0);
			Handle next = NO_HANDLE;
			if (!enter(current, cx, cz, cx + sx, cz + sz, relaxed, next)) {
				return false;
			}
			current = next;
			cx += sx;
			cz += sz;
		}
		if (cx != tx || cz != tz) {
			return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------------------------
// Steering

double preview_speed_limit(const Corridor &corridor, double s, double speed_hint, const SteeringLimits &lim) {
	if (corridor.empty()) {
		return INF;
	}
	const double braking = lim.braking * 0.8;
	const double hint = std::max(speed_hint, lim.walk_speed);
	const double horizon = hint * hint / (2.0 * braking) + lim.lookahead_max + 0.5;
	double best = INF;
	for (double x = 0.0; x <= horizon + 1e-9; x += 0.25) {
		const double centre = s + x;
		if (centre - lim.lookahead_min * 0.5 > corridor.length()) {
			break;
		}
		// The pursuit rounds the corridor over about one lookahead: the curvature it will steer here
		// is that of the circle through the corridor points one lookahead behind, here and one
		// lookahead ahead (Menger curvature; a right angle gives about 1.41 / lookahead). Cell-scale
		// zigzags of a route barely bend that circle, as they barely bend the pursuit. The lookahead
		// is the one the follower will use at the speed this curve allows (refined twice).
		double guess = hint;
		double cap = INF;
		for (int iteration = 0; iteration < 3; ++iteration) {
			const double window = clampd(guess * lim.lookahead_time, lim.lookahead_min, lim.lookahead_max);
			const Vec3f a = corridor.point_at(centre - window);
			const Vec3f b = corridor.point_at(centre);
			const Vec3f c = corridor.point_at(centre + window);
			const double abx = double(b.x) - double(a.x), abz = double(b.z) - double(a.z);
			const double bcx = double(c.x) - double(b.x), bcz = double(c.z) - double(b.z);
			const double acx = double(c.x) - double(a.x), acz = double(c.z) - double(a.z);
			const double sides = std::hypot(abx, abz) * std::hypot(bcx, bcz) * std::hypot(acx, acz);
			const double kappa = sides > 1e-9 ? 2.0 * std::fabs(abx * bcz - abz * bcx) / sides : 0.0;
			cap = curve_speed_limit(kappa, lim.yaw_rate_max, lim.lateral_accel);
			if (!std::isfinite(cap) || std::fabs(cap - guess) < 0.02) {
				break;
			}
			guess = std::min(cap, hint);
		}
		if (std::isfinite(cap)) {
			best = std::min(best, stopping_speed(x, cap, braking));
		}
	}
	return best;
}

namespace {
SteeringOutput steer_decision(Context &c, const Corridor &corridor, double s, const SteeringInput &in,
		const SteeringLimits &lim, const std::vector<Neighbour> &neighbours);
} // namespace

SteeringOutput steer(const Corridor &corridor, double s, const SteeringInput &in, const SteeringLimits &lim,
		ArcValidator *validator, Handle start, const std::vector<BlockedDisc> &blocked,
		const std::vector<Neighbour> &neighbours) {
	Context c(corridor, s, in, lim, validator, start, blocked, neighbours);
	SteeringOutput out = steer_decision(c, corridor, s, in, lim, neighbours);
	out.refused_ground = c.refused_ground;
	out.refused_neighbour = c.refused_neighbour;
	out.refused_escape = c.refused_escape;
	out.refused_wall = c.refused_wall;
	out.refused_blocked = c.refused_blocked;
	out.start_located = validator == nullptr || start != NO_HANDLE;
	out.neighbours = int32_t(neighbours.size());
	return out;
}

namespace {
SteeringOutput steer_decision(Context &c, const Corridor &corridor, double s, const SteeringInput &in,
		const SteeringLimits &lim, const std::vector<Neighbour> &neighbours) {
	SteeringOutput out;
	c.neighbour_margin = in.neighbour_margin;
	const Pose2 &pose = in.pose;
	const double length = corridor.length();
	const double lookahead = clampd(in.speed * lim.lookahead_time, lim.lookahead_min, lim.lookahead_max);
	c.lookahead = lookahead;
	out.lookahead = lookahead;
	out.remaining = std::max(0.0, length - s);
	const Vec3f end = corridor.end();
	const double end_distance = std::hypot(double(end.x) - pose.x, double(end.z) - pose.z);

	// Lookahead target: the corridor point `lookahead` ahead of her progress. Near the end of a
	// destination corridor the end itself; past the end of a continuing one, its extension.
	double tx = 0.0, tz = 0.0;
	if (s + lookahead <= length) {
		const Vec3f target = corridor.point_at(s + lookahead);
		tx = target.x;
		tz = target.z;
	} else if (in.terminal) {
		tx = end.x;
		tz = end.z;
		if (end_distance < 0.05) {
			double ex = 0.0, ez = 0.0;
			corridor.tangent_at(length, ex, ez);
			tx = double(end.x) + ex * lookahead;
			tz = double(end.z) + ez * lookahead;
		}
	} else {
		double ex = 0.0, ez = 0.0;
		corridor.tangent_at(length, ex, ez);
		const double over = s + lookahead - length;
		tx = double(end.x) + ex * over;
		tz = double(end.z) + ez * over;
	}
	double forward = 0.0, left = 0.0;
	const double raw_curvature = pursuit_curvature(pose, tx, tz, forward, left);
	out.bearing = std::atan2(left, forward);

	// Speed limits: request, curves previewed ahead (brake early), the remaining arc.
	const double scale = std::isfinite(in.speed_scale) && in.speed_scale > 0.0 ? clampd(in.speed_scale, 0.2, 1.0) : 1.0;
	const double requested = std::max(0.0, std::isfinite(in.requested_speed) ? in.requested_speed : 0.0) * scale;
	const double curve = preview_speed_limit(corridor, s, std::max(in.speed, requested), lim);
	double arrive = INF;
	if (in.terminal) {
		const double left_to_go = std::max(out.remaining, end_distance);
		arrive = stopping_speed(left_to_go - 0.02, 0.0, lim.braking * 0.85);
		if (left_to_go < lim.approach_distance) {
			arrive = std::min(arrive, lim.walk_speed);
		}
	} else {
		arrive = stopping_speed(out.remaining - 0.05, std::max(0.0, in.terminal_speed), lim.braking * 0.85);
	}
	const double target_speed = std::min(requested, std::min(curve, arrive));
	c.target_speed = target_speed;
	out.target_speed = target_speed;
	out.permitted = target_speed;
	// Preferred velocity for avoidance: toward the lookahead target at the target speed.
	{
		const double dx = tx - pose.x;
		const double dz = tz - pose.z;
		const double length_xz = std::hypot(dx, dz);
		if (length_xz > 1e-6 && target_speed > 0.01) {
			out.preferred_vx = dx / length_xz * target_speed;
			out.preferred_vz = dz / length_xz * target_speed;
		}
	}

	const double dt_control = std::max(in.dt, 1.0 / 60.0);
	const double v_lo = std::max(0.0, in.speed - lim.braking * dt_control);
	const double v_hi = std::max(0.0, in.speed) + lim.accel * dt_control;

	// A zero answer is congestion only with somepony near enough to cause it; alone, it is a
	// broken or unsynchronised avoidance answer: treated as no answer, it never holds her.
	bool somepony_near = false;
	for (const Neighbour &n : neighbours) {
		if (std::hypot(n.x - pose.x, n.z - pose.z) < 3.0) {
			somepony_near = true;
			break;
		}
	}
	// Avoidance: a fresh answer is a proposal; none (or stale) means conservative following.
	const bool fresh = in.has_avoidance && in.avoid_age <= AVOIDANCE_FRESH && std::isfinite(in.avoid_vx) &&
			std::isfinite(in.avoid_vz) && (somepony_near || std::hypot(in.avoid_vx, in.avoid_vz) >= 0.05);
	out.avoidance_missing = !fresh;
	if (!fresh) {
		c.neighbour_margin += 0.1;
	}
	// A committed pass round a pony goes on before anything else may turn her back into it.
	if (in.pass_side != 0 && c.validator != nullptr && in.pass_time <= PASS_SECONDS &&
			in.pass_distance <= PASS_DISTANCE) {
		if (pass_step(c, out, in.pass_id, in.pass_side, target_speed, v_lo, v_hi)) {
			out.candidates_validated = c.validated;
			return out;
		}
	}
	const double previous_preferred = std::hypot(in.prev_pref_vx, in.prev_pref_vz);
	const double answer = fresh ? std::hypot(in.avoid_vx, in.avoid_vz) : 0.0;
	out.zero_answer = fresh && answer < 0.05 && previous_preferred > 0.2 && target_speed > 0.2;
	if (out.zero_answer && !in.ignore_yield) {
		// Congestion: avoidance asks her to wait. Brake along the planned curve, with a reason.
		out.yielding = true;
		Candidate brake;
		brake.v = v_lo;
		brake.k = clampd(raw_curvature, -lim.max_curvature, lim.max_curvature);
		brake.mode = MODE_HOLD;
		finish_travel(out, brake, lim);
		out.reason = REASON_YIELDING;
		return out;
	}
	if (fresh && !in.ignore_yield &&
			std::hypot(in.avoid_vx - in.prev_pref_vx, in.avoid_vz - in.prev_pref_vz) > 0.2 + 0.15 * previous_preferred) {
		c.pressure = true;
		c.u_x = in.avoid_vx;
		c.u_z = in.avoid_vz;
	}

	const double bearing = std::fabs(out.bearing);
	const bool reversing = (in.reversing ? bearing > REVERSE_EXIT : bearing > REVERSE_ENTER) &&
			std::hypot(tx - pose.x, tz - pose.z) > 0.05;
	// A turn of more than 90 degrees keeps the way a turn went a moment ago (no left/right flips
	// across the point straight behind her).
	const int32_t held_turn = bearing > 0.5 * PI_D ? in.turn_hold : 0;
	// Inside a cramped escape prefix there is no body room: an arc shorter than her body sweeps it
	// like a pivot, so she realigns with a deliberate supported stepping turn, then walks the
	// centre line.
	// A stepping turn round a pony in the way completes toward its own heading first.
	if (in.prev_mode == MODE_STEP_TURN && std::isfinite(in.turn_target) && in.speed < 0.08) {
		const double error = wrap_angle(in.turn_target - pose.yaw);
		if (std::fabs(error) > STEP_TARGET_DONE) {
			out.v = 0.0;
			out.k = 0.0;
			out.w = signd(error) * lim.step_turn_rate;
			out.mode = MODE_STEP_TURN;
			out.reason = in.prev_reason == REASON_REPAIR ? REASON_REPAIR : REASON_NEIGHBOUR;
			out.turn_target = in.turn_target;
			return out;
		}
	}
	const bool cramped = s < in.escape_until;
	const bool continuing = in.prev_mode == MODE_STEP_TURN && !std::isfinite(in.turn_target) && in.speed < 0.08 &&
			bearing > STEP_TURN_DONE;
	// A support brake can stop an otherwise valid arc before its forward motion can turn
	// her toward the corridor (notably authored interiors without the ground validator).
	// Realign only when stopped and facing across the route; the motor independently
	// checks hoof support for this existing step turn, including every continuation tick.
	const bool support_alignment = in.support_refused && in.speed < 0.08 && bearing > STEP_TURN_BEARING;
	if (continuing || support_alignment || (cramped && in.speed <= lim.walk_speed + 0.1 && (reversing || (bearing > STEP_TURN_BEARING && in.speed < 0.08)))) {
		const int32_t side = in.reversing && in.reversal_side != 0 ? in.reversal_side
				: held_turn != 0									? held_turn
																	: (left >= 0.0 ? 1 : -1);
		out.v = 0.0;
		out.k = 0.0;
		out.w = double(side) * lim.step_turn_rate;
		out.mode = MODE_STEP_TURN;
		out.reason = REASON_STEPPING_TURN;
		out.reversing = bearing > REVERSE_EXIT;
		out.reversal_side = side;
		return out;
	}
	if (reversing) {
		// The target is behind her: turn round on a validated arc toward its side, braking to a
		// turning speed; with no safe arc and at a walk, a deliberate supported stepping turn.
		int32_t side = in.reversing && in.reversal_side != 0 ? in.reversal_side
				: held_turn != 0							  ? held_turn
															  : (left >= 0.0 ? 1 : -1);
		const double turning_speed = std::min(clampd(lim.reversal_radius * lim.yaw_rate_max, lim.walk_speed,
														lim.lateral_accel / lim.yaw_rate_max),
				target_speed);
		const double turn_angle = std::max(0.0, bearing - STEP_TURN_BEARING);
		int32_t id = 0;
		for (int32_t attempt = 0; attempt < 2; ++attempt) {
			const int32_t this_side = attempt == 0 ? side : -side;
			const double speeds[2] = { clampd(turning_speed, v_lo, v_hi), v_lo };
			for (double v : speeds) {
				if (v < 1e-3) {
					continue;
				}
				Candidate candidate;
				candidate.v = v;
				candidate.k = double(this_side) *
						std::min(lim.max_curvature, std::min(lim.yaw_rate_max / v, lim.lateral_accel / (v * v)));
				candidate.id = id++;
				// Validate the arc through the turn and the stop after it.
				const double turn = attempt == 0 ? turn_angle : (TAU_D - bearing - STEP_TURN_BEARING);
				candidate.turn_distance = std::max(0.0, turn) / std::fabs(candidate.k);
				if (validate(c, candidate)) {
					finish_travel(out, candidate, lim);
					out.reason = REASON_REVERSING;
					out.reversing = true;
					out.reversal_side = this_side;
					out.candidates_validated = c.validated;
					return out;
				}
			}
		}
		out.reversing = true;
		out.reversal_side = side;
		out.candidates_validated = c.validated;
		if (in.speed <= lim.walk_speed + 0.1) {
			out.v = 0.0;
			out.k = 0.0;
			out.w = double(side) * lim.step_turn_rate;
			out.mode = MODE_STEP_TURN;
			out.reason = REASON_STEPPING_TURN;
			return out;
		}
		const double k_turn = double(side) * std::min(lim.max_curvature,
												  std::min(lim.yaw_rate_max / std::max(v_lo, 1e-3),
														  lim.lateral_accel / std::max(v_lo * v_lo, 1e-6)));
		const Candidate brake = emergency_brake(c, v_lo, k_turn, side);
		finish_travel(out, brake, lim);
		out.reason = REASON_NO_SAFE_ARC;
		out.candidates_validated = c.validated;
		return out;
	}

	// Reference: regulated pure pursuit.
	double k_ref = clampd(raw_curvature, -lim.max_curvature, lim.max_curvature);
	out.reference_curvature = k_ref;
	const double cap_ref = curve_speed_limit(k_ref, lim.yaw_rate_max, lim.lateral_accel);
	double v_ref = clampd(std::min(target_speed, cap_ref), v_lo, v_hi);
	if (v_ref > cap_ref + 1e-9) {
		// The braking window cannot reach the curve's speed this tick: the tightest curvature
		// this speed allows (a wider arc, still validated).
		k_ref = signd(k_ref) * std::min(std::fabs(k_ref),
									   std::min(lim.yaw_rate_max / std::max(v_ref, 1e-6),
											   lim.lateral_accel / std::max(v_ref * v_ref, 1e-9)));
	}
	c.k_ref = k_ref;
	c.v_ref = v_ref;
	Candidate reference;
	reference.v = v_ref;
	reference.k = k_ref;
	reference.id = 0;

	// On open sampled ground, start the walking detour before RVO's answer
	// changes enough to count as pressure. Authored doorway paths and cramped
	// escape prefixes keep their existing constrained steering.
	const bool open_ground = c.validator != nullptr && c.s >= in.escape_until;
	if (!c.pressure && !neighbours.empty() && (!fresh || in.ignore_yield || open_ground) && v_ref > 0.05) {
		// No usable avoidance answer: our own conservative proposal. When the reference arc would
		// pass too close to a neighbour ahead, prefer the same velocity turned to her right, more
		// the closer it gets. Both parties of a head-on meeting turn right and pass.
		double worst = 0.0;
		double fx = 0.0, fz = 0.0;
		forward_of(pose.yaw, fx, fz);
		for (const Neighbour &other : neighbours) {
			const double ahead = (other.x - pose.x) * fx + (other.z - pose.z) * fz;
			if (ahead <= 0.0) {
				continue;
			}
			double now = 0.0, smallest = 0.0;
			neighbour_separation(c, reference, other, now, smallest);
			const double soft = 2.0 * hard_separation(c, other) + 0.3;
			worst = std::max(worst, clampd((soft - smallest) / soft, 0.0, 1.0));
		}
		if (worst > 0.0) {
			const double turn = -50.0 * PI_D / 180.0 * worst;
			double ux = 0.0, uz = 0.0;
			const double heading = std::atan2(-(tx - pose.x), -(tz - pose.z));
			forward_of(heading + turn, ux, uz);
			c.pressure = true;
			c.u_x = ux * v_ref;
			c.u_z = uz * v_ref;
			out.side_step = true;
		}
	}
	bool crowded = false;
	if (!c.pressure) {
		for (const Neighbour &other : neighbours) {
			double now = 0.0, smallest = 0.0;
			neighbour_separation(c, reference, other, now, smallest);
			if (smallest < 2.0 * hard_separation(c, other) + 0.3) {
				crowded = true;
				break;
			}
		}
	}
	const bool contested = c.pressure || crowded || in.wall || in.repair;
	if (!contested && validate(c, reference)) {
		finish_travel(out, reference, lim);
		out.reason = (!fresh && v_ref > 0.01) ? REASON_AVOIDANCE_MISSING : REASON_NONE;
		out.candidates_validated = c.validated;
		return out;
	}

	// Bounded candidate set: three speeds x five curvatures, the previous control, the
	// avoidance proposal and a brake; scored first, then validated cheapest first.
	std::vector<Candidate> candidates;
	candidates.reserve(20);
	const double dk = std::max(0.3, 0.5 * std::fabs(k_ref));
	const double curvatures[5] = { k_ref, k_ref - 0.5 * dk, k_ref + 0.5 * dk, k_ref - dk, k_ref + dk };
	const double speeds[3] = { v_ref, 0.5 * (v_ref + v_lo), v_lo };
	int32_t id = 0;
	for (double k_raw : curvatures) {
		const double k = clampd(k_raw, -lim.max_curvature, lim.max_curvature);
		const double cap = curve_speed_limit(k, lim.yaw_rate_max, lim.lateral_accel);
		for (double v_raw : speeds) {
			const double v = std::min(v_raw, cap);
			// A stop is the brake candidate's job, never a "valid" travel choice without a reason.
			if ((v + 1e-9 < v_lo && v_lo > 0.0) || v < 0.01) {
				++id;
				continue;
			}
			Candidate candidate;
			candidate.v = v;
			candidate.k = k;
			candidate.id = id++;
			candidates.push_back(candidate);
		}
	}
	{
		Candidate previous;
		previous.v = clampd(in.prev_v, v_lo, v_hi);
		previous.k = clampd(in.prev_k, -lim.max_curvature, lim.max_curvature);
		previous.v = std::min(previous.v, curve_speed_limit(previous.k, lim.yaw_rate_max, lim.lateral_accel));
		previous.id = id++;
		if ((previous.v + 1e-9 >= v_lo || v_lo <= 0.0) && previous.v >= 0.01) {
			candidates.push_back(previous);
		}
	}
	if (c.pressure) {
		const double u = std::hypot(c.u_x, c.u_z);
		if (u > 0.01) {
			double fu = 0.0, lu = 0.0;
			const double k_u = clampd(pursuit_curvature(pose, pose.x + c.u_x / u * lookahead, pose.z + c.u_z / u * lookahead, fu, lu),
					-lim.max_curvature, lim.max_curvature);
			const double cap_u = curve_speed_limit(k_u, lim.yaw_rate_max, lim.lateral_accel);
			const double v_u = clampd(std::min(u, cap_u), v_lo, v_hi);
			Candidate proposal;
			proposal.v = v_u;
			proposal.k = k_u;
			proposal.id = id++;
			if (proposal.v >= 0.01) {
				candidates.push_back(proposal);
			}
			Candidate slower = proposal;
			slower.v = 0.5 * (v_u + v_lo);
			slower.id = id++;
			if (slower.v >= 0.01) {
				candidates.push_back(slower);
			}
		}
	}
	Candidate brake;
	brake.v = v_lo;
	brake.k = k_ref;
	brake.mode = MODE_BRAKE;
	brake.id = id++;
	candidates.push_back(brake);
	for (Candidate &candidate : candidates) {
		candidate.cost = score(c, candidate);
	}
	out.candidates_scored = int32_t(candidates.size());
	std::stable_sort(candidates.begin(), candidates.end(), cheaper);
	// Already walking off along a local repair heading (below) at a creep.
	const bool repairing = in.prev_reason == REASON_REPAIR && in.speed < 0.3;
	for (const Candidate &candidate : candidates) {
		if (candidate.mode == MODE_BRAKE && ((candidate.v < 0.01 && in.speed < 0.08) || (repairing && c.refused_ground > 0))) {
			// (Creeping off along a local repair heading: the brake would stop her each other tick.)
			// Already stopped: holding still is the fallback below (a stepping turn toward the
			// corridor or a recorded hold), never chosen ahead of a travel candidate that validates.
			continue;
		}
		if (validate(c, candidate)) {
			finish_travel(out, candidate, lim);
			out.reason = candidate.mode == MODE_BRAKE ? c.last_refusal
					: in.repair							? REASON_REPAIR
					: (!fresh && candidate.v > 0.01)	? REASON_AVOIDANCE_MISSING
														: REASON_NONE;
			if (candidate.mode == MODE_BRAKE && out.reason == REASON_NONE) {
				out.reason = REASON_NO_SAFE_ARC;
			}
			out.candidates_validated = c.validated;
			return out;
		}
	}
	out.candidates_validated = c.validated;
	// Blocked by other ponies only (the ground would let her go): go round the nearest one on the
	// side nearer her way (her right on a near tie), which never brings them closer. Both ponies of
	// a nose-to-nose meeting do the same and part. Without the ground validator (authored indoor
	// corridors) the older one-tick step round to its tangent and walk past remains.
	if (in.speed < 0.08 && c.refused_neighbour > 0 && c.refused_ground == 0 && c.refused_escape == 0 &&
			!neighbours.empty()) {
		const Neighbour *nearest = nullptr;
		double distance = INF;
		for (const Neighbour &other : neighbours) {
			const double d = std::hypot(pose.x - other.x, pose.z - other.z);
			if (d < distance) {
				distance = d;
				nearest = &other;
			}
		}
		if (nearest != nullptr && distance > 1e-6 && in.goal_occupied) {
			// A pony standing on her destination: wait beside it (the batch reports arrival at the
			// nearest reachable spot), never circle it.
			out.v = 0.0;
			out.k = 0.0;
			out.w = 0.0;
			out.mode = MODE_HOLD;
			out.reason = REASON_NEIGHBOUR;
			return out;
		}
		// Open floor along a side's pass heading (0.6 m): in a lane too narrow to go round (2 m) the
		// pass would only meet the wall, so the older step round below squeezes past instead.
		int32_t side = 0;
		if (nearest != nullptr && distance > 1e-6 && c.validator != nullptr) {
			const double way = pose.yaw + out.bearing;
			// A walker gets the same side every time (she chooses hers the same way); a standing
			// pony the side remembered for her, flipped once found shut.
			side = !nearest->walker && in.side_memory_id == nearest->id && in.side_memory != 0
					? in.side_memory
					: pass_side_for(c, *nearest, way);
			if (!nearest->walker && out.failed_pass_id == nearest->id && out.failed_pass_side == side) {
				side = -side;
			}
			if (!straight_valid(c, pass_heading(c, *nearest, side, 0.0), 0.6) || !beside_open(c, *nearest, side)) {
				// A walker keeps right as well: going round her on the other side mirrors her.
				side = !nearest->walker && straight_valid(c, pass_heading(c, *nearest, -side, 0.0), 0.6)
								&& beside_open(c, *nearest, -side)
						? -side
						: 0;
			}
		}
		if (side != 0) {
			// Open sampled ground: commit to a pass round it, on the side remembered for this pony,
			// else the side nearer her way (her right on a near tie); a side found shut tries the
			// other one.
			for (int32_t attempt = 0; attempt < 2; ++attempt) {
				if (pass_step(c, out, nearest->id, side, target_speed, v_lo, v_hi)) {
					out.candidates_validated = c.validated;
					return out;
				}
				if (out.failed_pass_id != nearest->id || out.failed_pass_side != side || nearest->walker) {
					break; // already past it (nothing to go round), or a walker who keeps right too
				}
				side = -side;
			}
			out.pass_id = 0;
			out.pass_side = 0;
			// Past it (or both sides shut) and every arc refused: walk on straight, which never
			// brings them closer.
			Candidate past;
			past.v = std::max(v_hi, 0.05);
			past.k = 0.0;
			past.id = 1000;
			if (validate(c, past)) {
				finish_travel(out, past, lim);
				out.reason = REASON_NEIGHBOUR;
				out.candidates_validated = c.validated;
				return out;
			}
		}
		if (nearest != nullptr && distance > 1e-6 && side == 0) {
			const double rx = (pose.x - nearest->x) / distance;
			const double rz = (pose.z - nearest->z) / distance;
			// The two tangents of the line between them, each turned STEP_AWAY further from her.
			const double away = yaw_of(rx, rz);
			const double first = wrap_angle(yaw_of(-rz, rx) + STEP_AWAY * (wrap_angle(away - yaw_of(-rz, rx)) >= 0.0 ? 1.0 : -1.0));
			const double second = wrap_angle(yaw_of(rz, -rx) + STEP_AWAY * (wrap_angle(away - yaw_of(rz, -rx)) >= 0.0 ? 1.0 : -1.0));
			const double way = pose.yaw + out.bearing;
			const double e1 = std::fabs(wrap_angle(first - way));
			const double e2 = std::fabs(wrap_angle(second - way));
			const double target = std::fabs(e1 - e2) < 0.1
					? (wrap_angle(first - pose.yaw) < wrap_angle(second - pose.yaw) ? first : second)
					: (e1 < e2 ? first : second);
			const double error = wrap_angle(target - pose.yaw);
			if (std::fabs(error) > STEP_TARGET_DONE) {
				out.v = 0.0;
				out.k = 0.0;
				out.w = signd(error) * lim.step_turn_rate;
				out.mode = MODE_STEP_TURN;
				out.reason = REASON_NEIGHBOUR;
				out.turn_target = target;
				return out;
			}
			Candidate past;
			past.v = std::max(v_hi, 0.05);
			past.k = 0.0;
			past.id = 1000;
			if (validate(c, past)) {
				finish_travel(out, past, lim);
				out.reason = REASON_NEIGHBOUR;
				out.candidates_validated = c.validated;
				return out;
			}
		}
	}
	// Stopped where the ground refuses every short arc toward her way (the edge of the room beside
	// a wall): local repair. The nearest heading within 90 degrees of her way whose first 0.3 m keeps
	// to certified ground: step round to it, then walk off along it. Her way here is the corridor
	// close by, not the lookahead target: beside the mouth of a gap or doorway the lookahead cuts
	// its corner through ground the validator refuses, and headings picked round it swing left and
	// right as she shuffles (2026-10-31, a walker who had stepped aside froze at a 1.4 m gap).
	if ((in.speed < 0.08 || repairing) && c.refused_ground > 0 && c.refused_neighbour == 0) {
		double way = pose.yaw + out.bearing;
		if (!c.corridor.empty()) {
			const Vec3f near = c.corridor.point_at(std::min(c.s + 0.4, c.corridor.length()));
			const double nx = double(near.x) - pose.x;
			const double nz = double(near.z) - pose.z;
			if (nx * nx + nz * nz > 0.15 * 0.15 && std::fabs(wrap_angle(yaw_of(nx, nz) - way)) < 0.5 * PI_D) {
				way = yaw_of(nx, nz);
			}
		}
		for (int step = 0; step <= 18; ++step) {
			const double offset = double((step + 1) / 2) * (10.0 * PI_D / 180.0) * (step % 2 == 1 ? 1.0 : -1.0);
			const double heading = wrap_angle(way + offset);
			if (!straight_valid(c, heading, 0.3)) {
				continue;
			}
			const double error = wrap_angle(heading - pose.yaw);
			if (std::fabs(error) > STEP_TARGET_DONE) {
				out.v = 0.0;
				out.k = 0.0;
				out.w = signd(error) * lim.step_turn_rate;
				out.mode = MODE_STEP_TURN;
				out.reason = REASON_REPAIR;
				out.turn_target = heading;
				out.candidates_validated = c.validated;
				return out;
			}
			out.v = std::max(std::min(v_hi, 0.25), 0.05);
			out.k = 0.0;
			out.w = 0.0;
			out.mode = MODE_TRAVEL;
			out.reason = REASON_REPAIR;
			out.candidates_validated = c.validated;
			return out;
		}
	}
	// Nothing validates, not even the brake arc: stop now; turn in place toward the corridor when
	// she is already stopped and not facing along it (local repair before any escalation), unless
	// that way is a pony who refused her: then she holds, with the reason recorded.
	if (in.speed < 0.08 && bearing > STEP_TURN_REALIGN && c.refused_neighbour == 0) {
		out.v = 0.0;
		out.k = 0.0;
		out.w = signd(out.bearing) * lim.step_turn_rate;
		out.mode = MODE_STEP_TURN;
		out.reason = REASON_STEPPING_TURN;
		return out;
	}
	const int32_t refusal = c.last_refusal;
	const Candidate fallback = emergency_brake(c, v_lo, k_ref, out.bearing >= 0.0 ? 1 : -1);
	out.v = v_lo;
	out.k = fallback.k;
	out.w = clampd(out.k * out.v, -lim.yaw_rate_max, lim.yaw_rate_max);
	out.mode = v_lo > 0.0 ? MODE_BRAKE : MODE_HOLD;
	out.reason = refusal;
	out.candidates_validated = c.validated;
	return out;
}

} // namespace

} // namespace ponynav
