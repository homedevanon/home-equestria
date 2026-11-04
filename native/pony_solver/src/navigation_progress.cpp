// Native pony navigation, progress and stall classification: see navigation_progress.h.
#include "navigation_progress.h"

#include <algorithm>
#include <cmath>

namespace ponynav {

namespace {

constexpr double PI_VALUE = 3.14159265358979323846;

double wrap(double angle) {
	angle = std::fmod(angle + PI_VALUE, 2.0 * PI_VALUE);
	if (angle < 0.0) {
		angle += 2.0 * PI_VALUE;
	}
	return angle - PI_VALUE;
}

} // namespace

const char *escalation_name(Escalation level) {
	switch (level) {
		case Escalation::NONE:
			return "none";
		case Escalation::LOCAL_REPAIR:
			return "local_repair";
		case Escalation::REPLAN:
			return "replan";
		case Escalation::ALTERNATE:
			return "alternate";
		case Escalation::FAILED:
			return "failed";
	}
	return "unknown";
}

void ProgressMonitor::reset() {
	const ProgressTuning keep = tuning;
	*this = ProgressMonitor();
	tuning = keep;
}

void ProgressMonitor::corridor_replaced(uint64_t) {
	if (awaiting_route_) {
		awaiting_route_ = false;
		level_time_ = 0.0;
	}
}

const ProgressSample &ProgressMonitor::sample(int index) const {
	if (count_ < CAPACITY) {
		return ring_[index];
	}
	return ring_[(next_ + index) % CAPACITY];
}

void ProgressMonitor::push(const ProgressSample &value) {
	ring_[next_] = value;
	next_ = (next_ + 1) % CAPACITY;
	if (count_ < CAPACITY) {
		++count_;
	}
}

Escalation ProgressMonitor::update(double dt, FollowClass klass, const ProgressSample &now) {
	if (!(dt > 0.0) || !std::isfinite(dt)) {
		return Escalation::NONE;
	}
	clock_ += dt;
	FollowClass effective = klass;
	if (klass == FollowClass::TURNING) {
		turning_run_ += dt;
		if (turning_run_ > tuning.turning_limit) {
			effective = FollowClass::FOLLOWING;
		}
	} else {
		turning_run_ = 0.0;
	}
	if (klass == FollowClass::YIELDING) {
		yielding_run_ += dt;
		if (yielding_run_ > tuning.yielding_limit) {
			effective = FollowClass::FOLLOWING;
		}
	} else {
		yielding_run_ = 0.0;
	}
	if (klass == FollowClass::WAITING_ROUTE) {
		planning_wait_ += dt;
	}
	effective_ = effective;
	if (effective == FollowClass::FOLLOWING) {
		following_time_ += dt;
		acc_following_ += dt;
		acc_expected_ += std::max(0.0, std::isfinite(now.permitted) ? now.permitted : 0.0) * dt;
	}
	acc_gained_ += std::max(0.0, std::isfinite(now.gained) ? now.gained : 0.0);
	since_sample_ += dt;
	if (since_sample_ >= 1.0 / tuning.sample_hz) {
		ProgressSample value = now;
		value.t = clock_;
		value.gained = acc_gained_;
		value.expected = acc_expected_;
		value.following = acc_following_;
		value.klass = effective;
		push(value);
		evaluate();
		if (stalled_) {
			total_stalled_ += since_sample_;
		}
		since_sample_ = 0.0;
		acc_gained_ = 0.0;
		acc_expected_ = 0.0;
		acc_following_ = 0.0;
	}
	if (level_ == Escalation::FAILED) {
		return Escalation::NONE;
	}
	if (!awaiting_route_ && level_ != Escalation::NONE) {
		level_time_ += dt;
	}
	if (total_stalled_ > tuning.total_stall_limit + budget_bonus_) {
		level_ = Escalation::FAILED;
		cause_ = "stalled too long in total";
		return Escalation::FAILED;
	}
	if (level_ == Escalation::NONE) {
		if (stalled_) {
			level_ = Escalation::LOCAL_REPAIR;
			level_time_ = 0.0;
			++repairs_;
			return Escalation::LOCAL_REPAIR;
		}
		return Escalation::NONE;
	}
	if (!stalled_ && window_gain_ >= tuning.resume_gain) {
		// Progress resumed: back to plain following. Counters and the total budget remain.
		level_ = Escalation::NONE;
		level_time_ = 0.0;
		awaiting_route_ = false;
		return Escalation::NONE;
	}
	if (awaiting_route_) {
		return Escalation::NONE;
	}
	const double deadline = level_ == Escalation::LOCAL_REPAIR ? tuning.repair_seconds
			: level_ == Escalation::REPLAN						  ? tuning.replan_seconds
																  : tuning.alternate_seconds;
	if (level_time_ >= deadline && stalled_) {
		level_ = Escalation(uint8_t(level_) + 1);
		level_time_ = 0.0;
		awaiting_route_ = level_ == Escalation::REPLAN || level_ == Escalation::ALTERNATE;
		if (level_ == Escalation::REPLAN) {
			++replans_;
		} else if (level_ == Escalation::ALTERNATE) {
			++alternates_;
		}
		return level_;
	}
	return Escalation::NONE;
}

Escalation ProgressMonitor::force(Escalation level, const char *cause) {
	if (uint8_t(level_) >= uint8_t(level)) {
		return Escalation::NONE;
	}
	level_ = level;
	level_time_ = 0.0;
	cause_ = cause;
	awaiting_route_ = level == Escalation::REPLAN || level == Escalation::ALTERNATE;
	if (level == Escalation::LOCAL_REPAIR) {
		++repairs_;
	} else if (level == Escalation::REPLAN) {
		++replans_;
	} else if (level == Escalation::ALTERNATE) {
		++alternates_;
	}
	return level_;
}

void ProgressMonitor::evaluate() {
	double gained = 0.0;
	double expected = 0.0;
	double following = 0.0;
	const double newest = sample(count_ - 1).t;
	for (int i = count_ - 1; i >= 0; --i) {
		const ProgressSample &value = sample(i);
		if (newest - value.t >= tuning.stall_window) {
			break;
		}
		gained += value.gained;
		expected += value.expected;
		following += value.following;
	}
	window_gain_ = gained;
	stalled_ = false;
	if (following >= tuning.following_share * tuning.stall_window && expected >= tuning.expected_floor &&
			gained < tuning.stall_fraction * expected) {
		stalled_ = true;
		cause_ = "no progress while following";
	} else if (circling()) {
		stalled_ = true;
		cause_ = "circling";
	} else if (oscillating()) {
		stalled_ = true;
		cause_ = "oscillation";
	} else if (heading_oscillating()) {
		stalled_ = true;
		cause_ = "heading oscillation";
	}
}

bool ProgressMonitor::circling() const {
	if (count_ < 2) {
		return false;
	}
	const double newest = sample(count_ - 1).t;
	double turned = 0.0;
	double first_distance = -1.0;
	double best_distance = 0.0;
	for (int i = 0; i < count_; ++i) {
		const ProgressSample &value = sample(i);
		if (newest - value.t > tuning.circling_window) {
			continue;
		}
		if (first_distance < 0.0) {
			first_distance = value.goal_distance;
			best_distance = value.goal_distance;
		} else {
			turned += std::fabs(wrap(value.yaw - sample(i - 1).yaw));
			best_distance = std::min(best_distance, value.goal_distance);
		}
	}
	return turned >= 2.0 * PI_VALUE && first_distance - best_distance < tuning.circling_progress;
}

bool ProgressMonitor::heading_oscillating() const {
	if (count_ < 3) {
		return false;
	}
	// Stepping and reversing turns count as TURNING for up to turning_limit, and a turn left then
	// back right inside that limit reset it every half cycle: no other test saw a walker swinging
	// 220 degrees each way in front of a pony (tools/navigation/probe_heading_flips.gd).
	// A lobe ends once the heading has come back more than 10 degrees from its extreme (gait
	// wobble inside a turn does not split it); alternating lobes of heading_lobe or more count.
	constexpr double BACK = 10.0 * PI_VALUE / 180.0;
	const double newest = sample(count_ - 1).t;
	double gained = 0.0;
	double lobe = 0.0;
	double against = 0.0;
	int lobes = 0;
	int last_sign = 0;
	bool started = false;
	for (int i = 0; i < count_; ++i) {
		const ProgressSample &value = sample(i);
		if (newest - value.t > tuning.heading_window) {
			continue;
		}
		if (!started) {
			started = true;
			continue;
		}
		gained += value.gained;
		const double turn = wrap(value.yaw - sample(i - 1).yaw);
		if (lobe == 0.0 || (turn > 0.0) == (lobe > 0.0)) {
			lobe += turn + against;
			against = 0.0;
			continue;
		}
		against += turn;
		if (std::fabs(against) > BACK) {
			if (std::fabs(lobe) >= tuning.heading_lobe) {
				const int sign = lobe > 0.0 ? 1 : -1;
				lobes = sign != last_sign ? lobes + 1 : lobes;
				last_sign = sign;
			}
			lobe = against;
			against = 0.0;
		}
	}
	if (std::fabs(lobe) >= tuning.heading_lobe) {
		const int sign = lobe > 0.0 ? 1 : -1;
		lobes = sign != last_sign ? lobes + 1 : lobes;
	}
	return lobes >= tuning.heading_lobes && gained < tuning.heading_progress;
}

bool ProgressMonitor::oscillating() const {
	if (count_ < 3) {
		return false;
	}
	const double newest = sample(count_ - 1).t;
	int flips = 0;
	int trend = 0;
	double extreme = 0.0;
	uint64_t route = 0;
	bool started = false;
	for (int i = 0; i < count_; ++i) {
		const ProgressSample &value = sample(i);
		if (newest - value.t > tuning.oscillation_window) {
			continue;
		}
		if (!started || value.route != route) {
			started = true;
			route = value.route;
			extreme = value.raw_progress;
			trend = 0;
			flips = 0;
			continue;
		}
		const double progress = value.raw_progress;
		if (trend >= 0 && progress > extreme) {
			extreme = progress;
			trend = 1;
		} else if (trend <= 0 && progress < extreme) {
			extreme = progress;
			trend = -1;
		} else if (std::fabs(progress - extreme) > tuning.oscillation_amplitude) {
			trend = trend != 0 ? -trend : (progress > extreme ? 1 : -1);
			extreme = progress;
			++flips;
		}
	}
	return flips >= tuning.oscillation_reversals;
}

} // namespace ponynav
