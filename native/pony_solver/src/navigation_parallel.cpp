// 0.1.0 performance pass: installs Godot's WorkerThreadPool as the follower's parallel-for
// (NavigationService::parallel_for, navigation_jobs.h). Only the GDExtension build compiles this
// file; the standalone navigation tests leave parallel_for empty and step serially.
#include "navigation_jobs.h"

#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/variant/string.hpp>

extern bool pony_follow_caller_block;

namespace {

// Perf 2026-11-21 (lane native_calls): the calling thread runs block 0 itself while the pool runs
// blocks 1..count-1, instead of sleeping in wait_for_group_task_completion (the main thread is not
// a pool thread, so Godot 4.5 does not let it help). Blocks are independent and merged in row
// order afterwards, so the results are the same bit for bit. Rollback: false.
constexpr bool CALLER_RUNS_FIRST_BLOCK = true;

struct ShiftedJob {
	void (*job)(void *, uint32_t);
	void *data;
};

void run_shifted(void *p_user, uint32_t p_index) {
	const ShiftedJob *shifted = static_cast<const ShiftedJob *>(p_user);
	shifted->job(shifted->data, p_index + 1);
}

void run_on_pool(void (*job)(void *, uint32_t), void *data, uint32_t count) {
	godot::WorkerThreadPool *pool = godot::WorkerThreadPool::get_singleton();
	if (pool == nullptr || count < 2) {
		for (uint32_t i = 0; i < count; ++i) {
			job(data, i);
		}
		return;
	}
	if (pony_follow_caller_block) {
		// `shifted` lives on this stack until the group is waited for below.
		ShiftedJob shifted{ job, data };
		const godot::WorkerThreadPool::GroupID group = pool->add_native_group_task(
				&run_shifted, &shifted, int(count - 1), -1, true, godot::String("Pony follow step"));
		job(data, 0);
		pool->wait_for_group_task_completion(group);
		return;
	}
	// High priority, like the pose solve: the physics tick waits for it.
	const godot::WorkerThreadPool::GroupID group =
			pool->add_native_group_task(job, data, int(count), -1, true, godot::String("Pony follow step"));
	pool->wait_for_group_task_completion(group);
}

struct InstallParallelFollow {
	InstallParallelFollow() {
		ponynav::NavigationService::parallel_for = &run_on_pool;
	}
};

InstallParallelFollow install_parallel_follow;

} // namespace

// Read by run_on_pool(); PonyColumnSampler.set_follow_caller_block() flips it for A/B fixtures.
bool pony_follow_caller_block = CALLER_RUNS_FIRST_BLOCK;
