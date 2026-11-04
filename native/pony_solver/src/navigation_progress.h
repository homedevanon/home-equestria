// Native pony navigation, progress and stall classification (docs/NAVIGATION_PHASE_2_2026_10_02.md).
// Pure C++17, no Godot types.
//
// Each follower keeps a fixed ring of 10 Hz samples over ten seconds (time, route, corridor
// progress, intent progress, position, yaw, command and actual speed, permitted speed, contact
// normal, class and reason). The class is decided before any timer advances:
//   FOLLOWING      expects corridor progress in proportion to the permitted speed;
//   TURNING        a reversal arc or a supported stepping turn (bounded by its own timer);
//   YIELDING       congestion: avoidance asked her to wait (bounded by its own timer);
//   WAITING_ROUTE  at the end of the available corridor while the next one is searched
//                  (planning wait, never physical stuck time).
// Held, asleep and paused actors are not stepped at all, so nothing advances for them.
//
// A stall is genuine blocked progress while following, circling (a full heading sweep with no
// gain toward the goal), oscillation (corridor projection reversing back and forth) or heading
// oscillation (big turns left, right, left with next to no route progress). Recovery
// escalates deterministically: local repair, obstacle update + replan, alternate route, then one
// terminal failure. Each level has its own deadline; a total stalled-time budget caps the whole
// intent so different failures cannot repeat forever. A replacement route does not erase the
// intent's history; only a new intent resets it.
#pragma once

#include <cstdint>

namespace ponynav {

enum class FollowClass : uint8_t {
	FOLLOWING = 0,
	TURNING = 1,
	YIELDING = 2,
	WAITING_ROUTE = 3,
};

enum class Escalation : uint8_t {
	NONE = 0,
	LOCAL_REPAIR = 1,
	REPLAN = 2,
	ALTERNATE = 3,
	FAILED = 4,
};

const char *escalation_name(Escalation level);

struct ProgressSample {
	double t = 0.0;
	uint64_t route = 0;
	// Corridor arc length (monotonic within one route) and the raw, unclamped projection.
	double progress = 0.0;
	double raw_progress = 0.0;
	// Corridor progress summed over every route of this intent.
	double intent_progress = 0.0;
	double x = 0.0;
	double z = 0.0;
	double yaw = 0.0;
	double goal_distance = 0.0;
	double command = 0.0;
	double actual = 0.0;
	double permitted = 0.0;
	double contact_nx = 0.0;
	double contact_nz = 0.0;
	// Accumulated since the previous sample.
	double gained = 0.0;
	double expected = 0.0;
	double following = 0.0;
	FollowClass klass = FollowClass::FOLLOWING;
	int32_t reason = 0;
};

struct ProgressTuning {
	double sample_hz = 10.0;
	// Seconds of history a stall is judged over, and the share of it that must be FOLLOWING.
	double stall_window = 3.5;
	double following_share = 0.9;
	// Metres of permitted motion in the window before progress can be judged at all.
	double expected_floor = 0.6;
	// Stalled when the gain is below this share of the permitted distance.
	double stall_fraction = 0.25;
	// Gain in the window that clears an escalation.
	double resume_gain = 1.0;
	// Continuous TURNING / YIELDING beyond these counts as FOLLOWING (spinning, endless yield).
	double turning_limit = 4.0;
	double yielding_limit = 2.5;
	// Per-attempt deadlines of each escalation level.
	double repair_seconds = 2.5;
	double replan_seconds = 6.0;
	double alternate_seconds = 8.0;
	// Total stalled seconds one intent may spend before it fails.
	double total_stall_limit = 30.0;
	double circling_window = 8.0;
	double circling_progress = 0.5;
	double oscillation_window = 5.0;
	double oscillation_amplitude = 0.15;
	int oscillation_reversals = 3;
	// Heading oscillation: this many alternating turns of at least `heading_lobe` radians inside
	// `heading_window` seconds, with less than `heading_progress` metres of intent progress.
	double heading_window = 8.0;
	double heading_lobe = 60.0 * 3.14159265358979323846 / 180.0;
	int heading_lobes = 3;
	double heading_progress = 0.4;
};

class ProgressMonitor {
public:
	// Ten seconds at 10 Hz: the circling and heading windows (8 s) fit inside it.
	static constexpr int CAPACITY = 100;

	void set_tuning(const ProgressTuning &value) { tuning = value; }
	const ProgressTuning &get_tuning() const { return tuning; }
	// A new intent: forget everything.
	void reset();
	// A replacement route for the same intent: keeps history and escalation; ends a replan wait.
	void corridor_replaced(uint64_t route);
	// Advances by dt. `now.gained` is this tick's intent progress and `now.permitted` the speed
	// the follower would travel at if unobstructed. Returns the escalation level entered on this
	// tick (NONE when the level did not rise).
	Escalation update(double dt, FollowClass klass, const ProgressSample &now);
	// Physical evidence (repeated frontal obstruction, refused support): jump to at least `level`
	// now. Returns the level entered, or NONE when already there.
	Escalation force(Escalation level, const char *cause);
	// Seconds added to the total stall budget (the batch grants 0.1 s per metre covered, so a long
	// legitimate walk is not mislabeled a failure).
	void set_budget_bonus(double seconds) { budget_bonus_ = seconds > 0.0 ? seconds : 0.0; }

	Escalation level() const { return level_; }
	bool awaiting_route() const { return awaiting_route_; }
	bool stalled() const { return stalled_; }
	const char *cause() const { return cause_; }
	double total_stalled() const { return total_stalled_; }
	double following_time() const { return following_time_; }
	double turning_run() const { return turning_run_; }
	double yielding_run() const { return yielding_run_; }
	double planning_wait() const { return planning_wait_; }
	double level_time() const { return level_time_; }
	int repairs() const { return repairs_; }
	int replans() const { return replans_; }
	int alternates() const { return alternates_; }
	double clock() const { return clock_; }
	// The class actually counted this tick (TURNING/YIELDING past their limits count as following).
	FollowClass effective_class() const { return effective_; }
	int sample_count() const { return count_; }
	// Oldest first.
	const ProgressSample &sample(int index) const;

	// Analysers over the ring (also used by the tests on synthetic traces).
	bool circling() const;
	bool oscillating() const;
	bool heading_oscillating() const;

private:
	void push(const ProgressSample &sample);
	void evaluate();

	ProgressTuning tuning;
	ProgressSample ring_[CAPACITY];
	int count_ = 0;
	int next_ = 0;
	double clock_ = 0.0;
	double since_sample_ = 0.0;
	double acc_gained_ = 0.0;
	double acc_expected_ = 0.0;
	double acc_following_ = 0.0;
	double following_time_ = 0.0;
	double turning_run_ = 0.0;
	double yielding_run_ = 0.0;
	double planning_wait_ = 0.0;
	double total_stalled_ = 0.0;
	bool stalled_ = false;
	const char *cause_ = "";
	Escalation level_ = Escalation::NONE;
	double level_time_ = 0.0;
	bool awaiting_route_ = false;
	int repairs_ = 0;
	int replans_ = 0;
	int alternates_ = 0;
	FollowClass effective_ = FollowClass::FOLLOWING;
	double window_gain_ = 0.0;
	double budget_bonus_ = 0.0;
};

} // namespace ponynav
