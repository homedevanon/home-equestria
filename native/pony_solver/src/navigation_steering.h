// Native pony navigation, steering (docs/NAVIGATION_PHASE_2_2026_10_02.md).
// Pure C++17, no Godot types.
//
// Godot convention throughout: forward is local -Z, yaw 0 faces world -Z, and a positive yaw
// rate turns the forward vector toward world -X (left). A pose's forward is
// (-sin(yaw), -cos(yaw)) and its left is (-cos(yaw), sin(yaw)).
//
// The follower is a regulated pure pursuit: a rolling lookahead on the corridor gives the
// reference curvature k = 2 * left / (forward^2 + left^2); speed is limited by the curve
// (v * |k| <= yaw_rate_max and v^2 * |k| <= lateral_accel), by braking for the remaining arc
// and for curvature previewed ahead, and by the acceleration window. The reference control is
// executed when its arc validates and nothing presses on it. Otherwise a bounded candidate set
// (three speeds x five curvatures, the previous control, the avoidance proposal and a brake) is
// scored on corridor progress, corridor error, deviation from the preferred (avoidance)
// velocity and control change, after the collision constraints (ground, wall contact,
// neighbours) have removed invalid candidates; ties keep the stable candidate order.
// Every arc is integrated with translation and yaw together and checked as a swept body: the
// arc is sampled at most every half cell, and the certified clearance covers the capsule radius,
// half the sample spacing, the chord deviation of the arc between samples and the cell's
// half-diagonal (see ArcValidator). A target behind her uses a turning arc when one validates;
// a true reversal with no safe arc uses a deliberate supported stepping turn.
#pragma once

#include "navigation_follow.h"
#include "navigation_progress.h"

namespace ponynav {

// Command modes on the wire (fourth float of every command row).
enum CommandMode : int32_t {
	// Deliberate stop: brake to zero and hold the heading. A valid zero command.
	MODE_STOP = 0,
	// Forward speed and yaw rate along a validated arc.
	MODE_TRAVEL = 1,
	// Supported stepping turn on the spot: speed 0, yaw rate; the motor steps the legs.
	MODE_STEP_TURN = 2,
	// Safety or obstruction brake: the speed is the braked speed, the curvature is kept.
	MODE_BRAKE = 3,
	// Yield or wait with a recorded reason (the motor treats it like STOP).
	MODE_HOLD = 4,
};

// Recorded reasons, per actor and tick.
enum FollowReason : int32_t {
	REASON_NONE = 0,
	REASON_STEPPING_TURN = 1,
	REASON_YIELDING = 2,
	REASON_NO_SAFE_ARC = 3,
	REASON_CORRIDOR_END = 4,
	REASON_WALL_CONTACT = 5,
	REASON_SUPPORT_REFUSED = 6,
	REASON_ARRIVED = 7,
	REASON_INVALID_INPUT = 8,
	// Moving reversal arc (informational: she is moving).
	REASON_REVERSING = 9,
	REASON_REPAIR = 10,
	REASON_NEIGHBOUR = 11,
	REASON_FAILED = 12,
	// Informational: no fresh avoidance answer; conservative neighbour-checked following.
	REASON_AVOIDANCE_MISSING = 13,
	REASON_CORRIDOR_LOST = 14,
	REASON_WAITING_ROUTE = 15,
};

const char *reason_name(int32_t reason);
// True for reasons that justify a stop or a slow-down in the trace (not the informational ones).
bool reason_explains_stop(int32_t reason);

struct SteeringLimits {
	// Profile limits (PonyGaitProfile acceleration/braking; locomotion steer_turn_rate).
	double accel = 2.5;
	double braking = 3.5;
	double yaw_rate_max = 1.8;
	// Measured lateral acceleration limit (tools/navigation/measure_turn_limits.gd: planted drift
	// stays inside the 30 mm reach budget at 2 m/s^2 for every tested trot speed).
	double lateral_accel = 2.0;
	// Supported stepping turn rate (rad/s) and the walk band's top speed.
	double step_turn_rate = 1.2;
	double walk_speed = 0.36;
	// Rolling lookahead: clamp(speed * time, min, max). The legacy navigator used 0.7-2.4 m.
	double lookahead_time = 0.9;
	double lookahead_min = 0.6;
	double lookahead_max = 2.4;
	// Fixed destinations end at a walk inside this distance.
	double approach_distance = 0.65;
	double arrival_radius = 0.25;
	// Same floor: arrival height tolerance and corridor projection tolerance.
	double floor_tolerance = 0.6;
	double projection_vertical = 0.65;
	// Physical collision capsule radius (vertical capsule, so yaw does not sweep it).
	double capsule_radius = 0.19;
	// Profile radius (walk-grid body room), metres; used for neighbour separation.
	double body_radius = 0.45;
	// Tightest curvature the follower ever commands (1/m).
	double max_curvature = 8.0;
	// Reversal arc radius aimed for when turning round (m).
	double reversal_radius = 0.35;
	// Lateral deviation allowed while inside a cramped escape prefix.
	double escape_lateral = 0.2;
};

struct Pose2 {
	double x = 0.0;
	double z = 0.0;
	double yaw = 0.0;
};

inline void forward_of(double yaw, double &fx, double &fz) {
	fx = -std::sin(yaw);
	fz = -std::cos(yaw);
}

inline void left_of(double yaw, double &lx, double &lz) {
	lx = -std::cos(yaw);
	lz = std::sin(yaw);
}

// Pose after `distance` metres along a constant-curvature arc (exact).
Pose2 arc_pose(const Pose2 &start, double curvature, double distance);
// One midpoint-yaw step: heading at dt/2 carries the translation; the motor does the same.
Pose2 advance_midpoint(const Pose2 &start, double speed, double yaw_rate, double dt);
// Pure pursuit toward (tx, tz) in the pose's yaw-only frame. Returns the curvature; `forward`
// and `left` are the target's coordinates in that frame.
double pursuit_curvature(const Pose2 &pose, double tx, double tz, double &forward, double &left);
// min(yaw_rate_max / |k|, sqrt(lateral_accel / |k|)); infinite for a straight line.
double curve_speed_limit(double curvature, double yaw_rate_max, double lateral_accel);
// Highest speed that still brakes to `end_speed` within `distance` at `braking`.
double stopping_speed(double distance, double end_speed, double braking);

struct BlockedDisc {
	double x = 0.0;
	double z = 0.0;
	double radius = 0.0;
};

struct Neighbour {
	double x = 0.0;
	double z = 0.0;
	double vx = 0.0;
	double vz = 0.0;
	double radius = 0.45;
	uint64_t id = 0;
	// She follows a route of her own (she keeps right too: no going round her on the other side).
	bool walker = false;
};

// Validates arcs against one world snapshot for one movement profile, on the main thread.
// A visited cell must be linked to the previous one (step/slope/headroom/water, diagonal side
// crossings like WalkGridService.steering_segment_clear) and must certify the body: its walk-grid
// body room at `required_radius` (the profile radius when that is enough) covers the capsule,
// half the sample spacing, the arc's chord deviation and the cell's half-diagonal. Inside a
// cramped escape prefix (`relaxed`) only the floor itself must be allowed.
class ArcValidator {
public:
	ArcValidator(GroundAccess &ground, double required_radius);
	// Span the actor stands on: allowed floor in her column within `tolerance` of y, nearest.
	Handle locate(double x, double y, double z, double tolerance);
	// Walk the sample poses from `from`. The starting cell itself is where she already is, so it
	// is never refused; every following cell must certify.
	bool walk(Handle from, const Pose2 *samples, size_t count, bool relaxed);
	bool certifies(Handle handle, bool relaxed);
	uint64_t cells_checked = 0;
	GroundAccess &ground() { return g; }

private:
	bool enter(Handle from, int32_t fx, int32_t fz, int32_t tx, int32_t tz, bool relaxed, Handle &out);
	GroundAccess &g;
	double radius;
	bool pure;
};

// The clearance radius that certifies a capsule of `capsule_radius` between arc samples spaced
// `spacing` apart at curvature up to `max_curvature`, on 0.25 m cells.
double required_clearance(double capsule_radius, double spacing, double max_curvature);
// Spacing of arc samples: half a cell, and at most 0.35 rad of turn between samples.
double sample_spacing(double curvature);

struct SteeringInput {
	Pose2 pose;
	double y = 0.0;
	// Current forward speed (actual motion projected on the heading).
	double speed = 0.0;
	double dt = 1.0 / 60.0;
	double requested_speed = 0.0;
	// The motor's terrain speed factor (1 on the flat): the target is scaled by it once here, and
	// the motor does not scale the command again (no compounding with the acceleration window).
	double speed_scale = 1.0;
	double terminal_speed = 0.0;
	bool terminal = true;
	bool has_avoidance = false;
	double avoid_vx = 0.0;
	double avoid_vz = 0.0;
	double avoid_age = 0.0;
	bool wall = false;
	double wall_nx = 0.0;
	double wall_nz = 0.0;
	double prev_v = 0.0;
	double prev_k = 0.0;
	int32_t prev_mode = MODE_STOP;
	// Previous preferred velocity submitted to avoidance.
	double prev_pref_vx = 0.0;
	double prev_pref_vz = 0.0;
	int32_t reversal_side = 0;
	bool reversing = false;
	// Arc length of the corridor's cramped escape prefix (relaxed validation before it).
	double escape_until = 0.0;
	bool repair = false;
	// The physical motor refused forward support; it still validates any stepping turn.
	bool support_refused = false;
	// Heading a stepping turn started last tick is turning toward (NaN when none): a stepping turn
	// round a pony in the way completes before she walks past it.
	double turn_target = std::numeric_limits<double>::quiet_NaN();
	int32_t prev_reason = REASON_NONE;
	// Yielding has lasted past its limit: treat avoidance as missing and rely on neighbours.
	bool ignore_yield = false;
	double neighbour_margin = 0.0;
	// Committed pass round a pony in the way (2026-10-31): she walks round that pony on one side
	// until it is abeam, with no reversal or pursuit arc pulling her back into it. `pass_side` 0
	// means none; +1/-1 picks the tangent (see pass_heading in navigation_steering.cpp).
	uint64_t pass_id = 0;
	int32_t pass_side = 0;
	// Seconds and metres spent in the current pass (bounded).
	double pass_time = 0.0;
	double pass_distance = 0.0;
	// The side last committed round this neighbour (kept a few seconds): a re-trigger keeps it.
	uint64_t side_memory_id = 0;
	int32_t side_memory = 0;
	// A step turn or turning arc went this way (+1 left, -1 right) less than the hold time ago:
	// a new turn of more than 90 degrees keeps that direction (no left/right/left reversals).
	int32_t turn_hold = 0;
	// A pony that is not moving stands on her destination: she waits beside it, never walks round it.
	bool goal_occupied = false;
};

struct SteeringOutput {
	double v = 0.0;
	double w = 0.0;
	double k = 0.0;
	int32_t mode = MODE_STOP;
	int32_t reason = REASON_NONE;
	double lookahead = 0.0;
	double reference_curvature = 0.0;
	double remaining = 0.0;
	double permitted = 0.0;
	double target_speed = 0.0;
	double bearing = 0.0;
	double preferred_vx = 0.0;
	double preferred_vz = 0.0;
	int32_t reversal_side = 0;
	bool reversing = false;
	double turn_target = std::numeric_limits<double>::quiet_NaN();
	bool yielding = false;
	// A fresh avoidance answer asked for (almost) zero velocity this tick, obeyed or not.
	bool zero_answer = false;
	// Our own keep-right proposal stood in for a missing avoidance answer.
	bool side_step = false;
	bool avoidance_missing = false;
	int32_t candidates_scored = 0;
	int32_t candidates_validated = 0;
	int32_t chosen = -1;
	// Refusals of this decision by constraint (diagnostics).
	int32_t refused_ground = 0;
	int32_t refused_neighbour = 0;
	int32_t refused_escape = 0;
	int32_t refused_wall = 0;
	int32_t refused_blocked = 0;
	bool start_located = true;
	int32_t neighbours = 0;
	// The committed pass for the next tick (0 side: none), and the pass found shut this tick
	// (0 side: none; the caller remembers the other side for that neighbour).
	uint64_t pass_id = 0;
	int32_t pass_side = 0;
	uint64_t failed_pass_id = 0;
	int32_t failed_pass_side = 0;
};

// One follower decision. `validator` may be null (no ground: every arc validates), `start` is
// the actor's span from validator->locate(). `blocked` discs and `neighbours` are constraints.
SteeringOutput steer(const Corridor &corridor, double s, const SteeringInput &input, const SteeringLimits &limits,
		ArcValidator *validator, Handle start, const std::vector<BlockedDisc> &blocked,
		const std::vector<Neighbour> &neighbours);

// Curvature preview: the highest speed now that can still brake to every curve's limit ahead.
double preview_speed_limit(const Corridor &corridor, double s, double speed_hint, const SteeringLimits &limits);

} // namespace ponynav
