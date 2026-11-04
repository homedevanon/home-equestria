// Native pony navigation, actors, intents and search jobs (docs/NAVIGATION_PHASE_1_2026_10_02.md).
// Pure C++17, no Godot types.
//
// Ownership: the main thread owns worlds, actors and intents and calls every NavigationService
// method. Worker threads (two by default; dev 2026-10-20 multithreading: the GDScript backend sets
// its autodetected search concurrency, up to 64) only advance GroundSearch jobs in
// cooperative slices against immutable snapshots; they never see Godot objects. Finished jobs
// go through a short mutex-protected queue that the main thread drains in poll(), where stale
// actor, intent and chunk-revision results are rejected.
#pragma once

#include "navigation_ground.h"
#include "navigation_steering.h"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <thread>

namespace ponynav {

struct ActorHandle {
	uint32_t slot = 0;
	uint32_t generation = 0;
};

// What an intent owner asks for. `generation` must increase per actor; reissuing an identical
// request (same owner, destination and parameters) while it is still being searched is
// idempotent and keeps the earlier generation.
struct IntentParams {
	int64_t owner = 0;
	uint64_t generation = 0;
	Vec3f from;
	Vec3f goal;
	// 0 = ground stop at the destination (phase 1 supports ground terminals only).
	int32_t terminal_mode = 0;
	float pace = 1.0f;
	int32_t priority = 0;
	// Follow intents coalesce goal updates: one search in flight plus the newest goal.
	bool follow = false;
	float follow_replan_distance = 0.5f;
	SearchOptions search;

	bool same_request(const IntentParams &other) const;
};

struct NavResult {
	uint64_t job_id = 0;
	uint32_t world = 0;
	ActorHandle actor;
	uint64_t intent_generation = 0;
	int64_t owner = 0;
	Vec3f goal;
	// A newer follow goal arrived while this search ran; a new search for it has started.
	bool goal_superseded = false;
	SearchOutput output;
	double queue_us = 0.0;
	double latency_us = 0.0;
};

struct NavCounters {
	uint64_t jobs_submitted = 0;
	uint64_t jobs_finished = 0;
	uint64_t results_delivered = 0;
	uint64_t stale_world = 0;
	uint64_t stale_actor = 0;
	uint64_t stale_intent = 0;
	uint64_t stale_chunk = 0;
	uint64_t cancelled = 0;
	uint64_t idempotent = 0;
	uint64_t coalesced = 0;
	uint64_t rejected_generation = 0;
	uint64_t slices = 0;
};

// Bounded ring of recent job timings for diagnostics.
struct JobRecord {
	uint64_t job_id = 0;
	uint32_t world = 0;
	RouteStatus status = RouteStatus::PENDING;
	int64_t expanded = 0;
	double cpu_us = 0.0;
	double queue_us = 0.0;
	double latency_us = 0.0;
	int32_t slices = 0;
};

struct SearchJob {
	uint64_t id = 0;
	uint32_t world = 0;
	ActorHandle actor;
	uint64_t intent_generation = 0;
	int64_t owner = 0;
	Vec3f goal;
	int32_t priority = 0;
	std::chrono::steady_clock::time_point submitted;
	std::chrono::steady_clock::time_point ready_since;
	std::chrono::steady_clock::time_point first_slice;
	bool started = false;
	uint64_t last_slice = 0;
	std::atomic<bool> cancelled{ false };
	std::unique_ptr<GroundSearch> search;
	RouteStatus status = RouteStatus::PENDING;
};

class JobScheduler {
public:
	explicit JobScheduler(int workers);
	~JobScheduler();
	JobScheduler(const JobScheduler &) = delete;
	JobScheduler &operator=(const JobScheduler &) = delete;

	void submit(const std::shared_ptr<SearchJob> &job);
	std::vector<std::shared_ptr<SearchJob>> drain();
	// Stops and joins the worker threads; queued jobs stay queued (a later submit restarts).
	void set_workers(int workers);
	int workers() const;
	// Test hook: paused workers start no new slice.
	void set_paused(bool paused);
	void set_slice_budget(int64_t expansions, int64_t microseconds);
	size_t queued() const;
	int busy() const;
	uint64_t slices() const;
	// Cancels everything and joins only the threads this scheduler started.
	void shutdown();

private:
	void run();
	void start_locked();
	void stop_threads();

	mutable std::mutex mutex;
	std::condition_variable wake;
	std::vector<std::thread> threads;
	int wanted = 2;
	bool stopping = false;
	bool paused = false;
	bool closed = false;
	std::vector<std::shared_ptr<SearchJob>> ready;
	std::vector<std::shared_ptr<SearchJob>> done;
	int running = 0;
	uint64_t slice_clock = 0;
	int64_t slice_expansions = 4096;
	int64_t slice_us = 2000;
};

// ---- Phase 2: continuous ground follower (docs/NAVIGATION_PHASE_2_2026_10_02.md) ----------

// step_batch wire format, version 1. Rows are actors, in the caller's order:
//   actor_keys  int64 x 2 per row: slot, generation. A row whose slot is negative, or whose actor
//               has no active corridor, is an observer: it is a neighbour for the others and its
//               command row is invalid (valid = 0).
//   positions, velocities  one Vector3 per row (world space, last physical move).
//   headings    one float per row: Godot yaw (rotation.y).
//   inputs      empty, or INPUT_STRIDE floats per row (see BatchInput).
// Output: COMMAND_STRIDE floats per row: valid (0/1), forward_speed (m/s), yaw_rate (rad/s,
// positive turns left), command_mode (CommandMode). A deliberate stop of a navigation-owned actor
// is a valid zero command. STATE_STRIDE diagnostics per row and one preferred (avoidance)
// velocity per row are kept for the caller.
constexpr int32_t COMMAND_STRIDE = 4;
constexpr int32_t INPUT_STRIDE = 13;
constexpr int32_t STATE_STRIDE = 8;

// Input slots per row.
enum BatchInput : int32_t {
	INPUT_REQUESTED_SPEED = 0, // m/s the intent asks for (pace, command limits)
	INPUT_TERMINAL_SPEED = 1, // m/s allowed at the end of a continuing corridor (moving goal)
	INPUT_FLAGS = 2, // InputFlag bits
	INPUT_AVOID_VX = 3, // newest avoidance answer (world XZ velocity)
	INPUT_AVOID_VZ = 4,
	INPUT_AVOID_AGE = 5, // seconds since that answer arrived
	INPUT_WALL_NX = 6, // wall normal of the last physical move (XZ)
	INPUT_WALL_NZ = 7,
	INPUT_EXECUTED_SPEED = 8, // speed the motor executed last tick
	INPUT_EXECUTED_YAW = 9, // yaw rate the motor executed last tick
	INPUT_REFUSAL = 10, // MotorRefusal code of the last tick
	INPUT_STEP_SECONDS = 11, // this row's step (clip tiers step at 20 Hz); 0 = the batch delta
	INPUT_SPEED_SCALE = 12, // the motor's terrain speed factor (hills); 0 = unknown (1)
};

enum InputFlag : int32_t {
	INPUT_FLAG_AVOIDANCE = 1, // an avoidance answer exists for the current intent
	INPUT_FLAG_WALL = 2, // the last physical move touched a wall
	INPUT_FLAG_ROUTE_PENDING = 4, // a replacement route is being searched
};

enum MotorRefusal : int32_t {
	REFUSAL_NONE = 0,
	REFUSAL_SUPPORT = 1, // unsafe support ahead (the motor's emergency brake)
	REFUSAL_TOUCH = 2, // interaction/touch owns the body
	REFUSAL_TURN_SUPPORT = 3, // stepping turn refused: hooves would lose support
};

enum FollowEventKind : int32_t {
	EVENT_ARRIVED = 1,
	EVENT_REPAIR = 2,
	EVENT_REPLAN = 3,
	EVENT_ALTERNATE = 4,
	EVENT_FAILED = 5,
	EVENT_CORRIDOR_LOST = 6,
};

struct FollowEvent {
	ActorHandle actor;
	uint64_t intent = 0;
	uint64_t route = 0;
	int32_t kind = 0;
	std::string reason;
	Vec3f at;
	bool alternative = false;
	double distance = 0.0;
	std::vector<BlockedDisc> blocked;
	// Replan/alternate held up by ponies: discs round the ones standing on her way ahead. Search
	// discs for the next route only (never steering constraints: they would outlive the pony).
	std::vector<BlockedDisc> peers;
};

struct CorridorRequest {
	std::vector<Vec3f> points;
	uint64_t route = 0;
	uint64_t intent = 0;
	// The corridor ends at the destination: arrive there (else brake for its end and wait).
	bool terminal = true;
	bool has_goal = false;
	Vec3f goal;
	// Hand-authored house path or doorway portal, finer than the walk grid's erosion: the walk
	// grid neither certifies nor refuses it. Collision, support and neighbours stay live.
	bool authored = false;
};

struct CorridorReply {
	bool accepted = false;
	std::string reason;
	bool goal_appended = false;
	bool alternative = false;
	// Her own position was put in front of a cramped route start.
	bool prepended = false;
	double join_s = 0.0;
	double join_lateral = 0.0;
	double escape_length = 0.0;
	double length = 0.0;
	int32_t points = 0;
};

struct FollowState {
	bool active = false;
	bool authored = false; // CorridorRequest::authored
	SteeringLimits limits;
	ProgressTuning tuning;
	Corridor corridor;
	uint64_t route = 0;
	uint64_t intent = 0;
	bool terminal = true;
	bool alternative = false;
	bool goal_appended = false;
	bool arrived = false;
	bool failed = false;
	bool lost = false;
	Vec3f goal;
	double s = 0.0;
	double raw_s = 0.0;
	double escape_until = 0.0;
	double prev_v = 0.0;
	double prev_k = 0.0;
	int32_t prev_mode = MODE_STOP;
	double pref_vx = 0.0;
	double pref_vz = 0.0;
	int32_t reversal_side = 0;
	bool reversing = false;
	double turn_target = std::numeric_limits<double>::quiet_NaN();
	ProgressMonitor monitor;
	std::vector<BlockedDisc> blocked;
	double frontal_contact = 0.0;
	double refused = 0.0;
	double yield_time = 0.0;
	// Seconds held within reach of the destination with every arc refused.
	double end_blocked = 0.0;
	// Seconds the walk grid has had no floor where she stands.
	double unlocated = 0.0;
	double intent_progress = 0.0;
	// Committed pass round a pony (navigation_steering.h SteeringInput::pass_*), the side kept per
	// pony for a while, the last in-place turn's direction and age, and the seconds since a pony
	// last held or refused her.
	uint64_t pass_id = 0;
	int32_t pass_side = 0;
	double pass_time = 0.0;
	double pass_distance = 0.0;
	uint64_t side_memory_id = 0;
	int32_t side_memory = 0;
	double side_memory_age = 1e9;
	int32_t turn_sign = 0;
	double turn_sign_age = 1e9;
	double neighbour_age = 1e9;
	SteeringOutput last;
	CorridorProjection last_projection;
	uint64_t steps = 0;
	// Counters for diagnostics.
	uint64_t stepping_turn_steps = 0;
	uint64_t reversing_steps = 0;
	uint64_t brake_steps = 0;
	uint64_t hold_steps = 0;
};

struct FollowCounters {
	uint64_t steps = 0;
	uint64_t rows = 0;
	uint64_t observers = 0;
	uint64_t rejected_rows = 0;
	uint64_t corridors = 0;
	uint64_t goal_appended = 0;
	uint64_t alternatives = 0;
	uint64_t arrivals = 0;
	uint64_t repairs = 0;
	uint64_t replans = 0;
	uint64_t alternates = 0;
	uint64_t failures = 0;
	uint64_t lost = 0;
	uint64_t cells_checked = 0;
	uint64_t candidates_validated = 0;
	double step_us = 0.0;
};

class NavigationService {
public:
	explicit NavigationService(int workers = 2);
	~NavigationService();

	uint32_t create_world();
	bool destroy_world(uint32_t world);
	NavigationWorld *world(uint32_t world);

	ActorHandle register_actor(uint32_t world, const GroundProfile &profile, std::string &error);
	bool update_actor_profile(const ActorHandle &actor, const GroundProfile &profile);
	bool unregister_actor(const ActorHandle &actor);
	bool actor_live(const ActorHandle &actor) const;

	// Returns the generation the actor's live intent now has, or -1 when rejected.
	int64_t submit_intent(const ActorHandle &actor, const IntentParams &intent);
	bool update_intent_goal(const ActorHandle &actor, uint64_t generation, const Vec3f &goal, const Vec3f &from);
	bool cancel_intent(const ActorHandle &actor, uint64_t generation);

	std::vector<NavResult> poll();

	void set_workers(int workers) { scheduler.set_workers(workers); }
	int workers() const { return scheduler.workers(); }
	void set_paused(bool paused) { scheduler.set_paused(paused); }
	void set_slice_budget(int64_t expansions, int64_t microseconds) { scheduler.set_slice_budget(expansions, microseconds); }
	size_t pending_jobs() const;
	size_t actor_count() const;
	size_t world_count() const { return worlds.size(); }
	std::vector<uint32_t> world_ids() const;
	const NavCounters &counters() const { return stats; }
	std::vector<JobRecord> recent_jobs() const;
	size_t queued_jobs() const { return scheduler.queued(); }
	int busy_workers() const { return scheduler.busy(); }
	uint64_t slices() const { return scheduler.slices(); }
	void shutdown();

	// Phase 2 follower. All main thread.
	bool follow_configure(const ActorHandle &actor, const SteeringLimits &limits, const ProgressTuning *tuning);
	CorridorReply follow_set_corridor(const ActorHandle &actor, const CorridorRequest &request, const Vec3f &position,
			double heading, const Vec3f &velocity);
	bool follow_clear(const ActorHandle &actor);
	// One batch step (see the wire format above). `commands`, `state` and `preferred` are
	// resized to the row count. Returns false (and leaves every output invalid) when the array
	// lengths do not match.
	bool follow_step(const int64_t *keys, size_t key_count, const Vec3f *positions, size_t position_count,
			const Vec3f *velocities, size_t velocity_count, const float *headings, size_t heading_count, double delta,
			const float *inputs, size_t input_count, std::vector<float> &commands, std::vector<float> &state,
			std::vector<Vec3f> &preferred, std::string &error);
	std::vector<FollowEvent> take_follow_events();
	const FollowState *follow_state(const ActorHandle &actor) const;

	// 0.1.0 perf: follow_step() steps its follower rows in contiguous blocks on this parallel-for
	// when one is installed (navigation_parallel.cpp installs Godot's WorkerThreadPool in the game
	// build; the standalone tests have none and stay serial). Every block has its own ground
	// access and validator copies (pure memo caches over the same immutable snapshot) and collects
	// its counters and events, merged in row order afterwards: the same commands, states, events
	// and counters as the serial step. Rollback: parallel_follow = false.
	using ParallelFor = void (*)(void (*job)(void *, uint32_t), void *data, uint32_t count);
	static ParallelFor parallel_for;
	static bool parallel_follow;
	// Fewer follower rows than this step serially (the pool's wake-up costs more than it saves).
	static size_t parallel_min_rows;
	static constexpr size_t PARALLEL_MAX_BLOCKS = 8;
	const FollowCounters &follow_counters() const { return follow_stats; }
	size_t follow_ground_entries() const { return follow_grounds.size(); }

private:
	struct IntentState {
		bool live = false;
		bool cancelled = false;
		IntentParams params;
		uint64_t job = 0; // job in flight, 0 = none
		bool has_pending_goal = false;
		Vec3f pending_goal;
		Vec3f pending_from;
		Vec3f searched_goal;
	};
	struct Actor {
		uint32_t generation = 0;
		bool live = false;
		uint32_t world = 0;
		GroundProfile profile;
		uint64_t last_intent_generation = 0;
		IntentState intent;
		FollowState follow;
	};

	Actor *live_actor(const ActorHandle &actor);
	const Actor *live_actor(const ActorHandle &actor) const;
	std::shared_ptr<SearchJob> start_job(uint32_t slot, Actor &actor, const Vec3f &from, const Vec3f &goal);
	void cancel_job(uint64_t job);
	void record(const SearchJob &job, double queue_us, double latency_us);

	JobScheduler scheduler;
	std::unordered_map<uint32_t, std::unique_ptr<NavigationWorld>> worlds;
	uint32_t next_world = 1;
	std::vector<Actor> actors;
	std::vector<uint32_t> free_slots;
	std::unordered_map<uint64_t, std::shared_ptr<SearchJob>> in_flight;
	uint64_t next_job = 1;
	NavCounters stats;
	std::deque<JobRecord> history;
	static constexpr size_t HISTORY = 64;

	// Follower ground access per (world, profile), rebuilt when the world's snapshot changes.
	struct FollowGround {
		uint32_t world = 0;
		GroundProfile profile;
		double required = 0.0;
		std::shared_ptr<const Snapshot> snapshot;
		std::shared_ptr<ClearanceCache> cache;
		std::unique_ptr<GroundAccess> access;
		std::unique_ptr<ArcValidator> validator;
		uint64_t used = 0;
	};
	FollowGround *follow_ground(uint32_t world, const GroundProfile &profile, double required);

	// One follow_step() call's inputs and per-row table, shared read-only by the row steps.
	struct FollowRow {
		bool usable = false;
		double speed = 0.0;
		Actor *actor = nullptr;
		ActorHandle handle;
		// Who this row is across ticks (a neighbour's id): (slot << 32) | generation for a handle,
		// an observer row's second key when it gives one, else 0.
		uint64_t identity = 0;
		FollowGround *ground = nullptr; // pre-resolved for a parallel step
	};
	struct FollowBatch {
		const Vec3f *positions = nullptr;
		const Vec3f *velocities = nullptr;
		const float *headings = nullptr;
		const float *inputs = nullptr;
		size_t input_count = 0;
		size_t rows = 0;
		double delta = 0.0;
		const std::vector<FollowRow> *table = nullptr;
		std::vector<float> *commands = nullptr;
		std::vector<float> *state = nullptr;
		std::vector<Vec3f> *preferred = nullptr;
	};
	// What a row step reports (merged into follow_stats/follow_events in row order).
	struct FollowSink {
		FollowCounters stats;
		std::vector<FollowEvent> events;
		std::vector<Neighbour> neighbours;
	};
	// A block's own copy of one follow ground (same world, profile, clearance and snapshot).
	struct FollowBlockGround {
		uint32_t world = 0;
		GroundProfile profile;
		double required = 0.0;
		std::shared_ptr<const Snapshot> snapshot;
		std::unique_ptr<GroundAccess> access;
		std::unique_ptr<ArcValidator> validator;
	};
	struct FollowBlock {
		std::vector<size_t> rows;
		FollowSink sink;
		std::vector<std::unique_ptr<FollowBlockGround>> grounds;
	};
	struct FollowParallelJob {
		NavigationService *service = nullptr;
		const FollowBatch *batch = nullptr;
		size_t blocks = 0;
	};
	static void follow_block_job(void *data, uint32_t index);
	ArcValidator *block_validator(FollowBlock &block, const FollowGround &ground);
	void follow_row(const FollowBatch &batch, size_t i, FollowSink &sink, FollowBlock *block);
	static void sink_event(FollowSink &sink, const ActorHandle &actor, const FollowState &follow, int32_t kind,
			const std::string &reason, const Vec3f &at);
	static void merge_counters(FollowCounters &into, const FollowCounters &from);
	std::vector<FollowBlock> follow_blocks;
	FollowSink follow_serial_sink;
	std::vector<FollowRow> follow_table;
	std::vector<const Actor *> follow_seen;
	void follow_event(const ActorHandle &actor, const FollowState &follow, int32_t kind, const std::string &reason,
			const Vec3f &at);
	std::vector<std::unique_ptr<FollowGround>> follow_grounds;
	std::vector<FollowEvent> follow_events;
	FollowCounters follow_stats;
	uint64_t follow_clock = 0;
};

} // namespace ponynav
