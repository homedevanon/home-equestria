extends Node
## Plans routes; the locomotion controller remains the sole writer of physics
## movement, gait, hoof contacts, and interruption/holding responses.

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
## Bounded diagnostic ring (navigation_trace.gd); `trace` stays null unless a lab enables tracing.
const NAV_TRACE := preload("res://world/characters/navigation/navigation_trace.gd")
var trace: NAV_TRACE
## Split by responsibility (2026-10-13); this file stays the navigator and keeps every name.
const OWNERSHIP := preload("res://world/characters/navigation/navigator_ownership.gd")
const COMMANDS := preload("res://world/characters/navigation/navigator_commands.gd")
const WANDER := preload("res://world/characters/navigation/navigator_wander.gd")
const ROUTES := preload("res://world/characters/navigation/navigator_routes.gd")
const NATIVE_ADAPTER := preload("res://world/characters/navigation/navigator_native_adapter.gd")
const LEGACY := preload("res://world/characters/navigation/navigator_legacy_steering.gd")
## Native following is the default (native_navigation_backend.gd). For a pony whose
## locomotion accepts navigation motion, routes become native corridors:
## native_follow_driver.gd steps every following pony in one batch and the locomotion applies one
## (speed, yaw rate) command per tick. This navigator stays the caller adapter (intent, routes,
## journey legs, house travel, arrival events). Legacy steering remains the explicit
## --native-navigation off comparison and unsupported-native fallback.
const NATIVE_BACKEND := preload("res://world/navigation/native_navigation_backend.gd")
const FOLLOW_DRIVER := preload("res://world/characters/navigation/native_follow_driver.gd")
## Reason codes of the native follower (navigation_steering.h FollowReason), and the ones that
## explain a slow-down or a stop for the trace.
const NATIVE_REASONS := ["", "stepping_turn", "yielding", "no_safe_arc", "corridor_end", "wall_contact",
	"support_refused", "arrived", "invalid_input", "reversing", "repair", "neighbour", "failed",
	"avoidance_missing", "corridor_lost", "waiting_route"]
const NATIVE_INFORMATIONAL := [0, 9, 13]
const NATIVE_INPUT_STRIDE := 13
## Cramped starts may leave their nook along capsule-sized floor this far (native search option).
const NATIVE_ESCAPE_REACH := 2.5
static var _follow_driver: Node
var native_follow := false
## Set with an arrival when the requested destination itself could not be reached and the
## follower stopped on the nearest reachable spot instead (a distinct outcome, never silent).
var arrival_alternative := false
var _native_handle := PackedInt64Array()
var _native_service: WalkGridService
var _native_active := false
var _native_intent := 0
var _native_route := 0
## `path` changes (routes, direct legs) bump the serial; the follower is sent each new one.
var _path_serial := 0
## A pending short corridor stays useful until consumed, redirected, or its ground changes.
var _direct_serial := -1
var _direct_goal := Vector3.INF
var _direct_snapshot: Dictionary = {}
var _direct_profile := 0
var _direct_trails := false
var _native_serial := -1
var _native_terminal := false
## House travel's hand-authored indoor/doorway corridor (house_travel.gd walk): the walk grid
## neither certifies nor refuses it, and the speed stays at the indoor cap.
var _native_authored := false
var _native_sent_authored := false
var _native_speed_cap := INF
var _contact_approach := Vector3.INF
var _native_inputs := PackedFloat32Array()
var _native_row_frame := -1
var _native_mode := 0
var _native_reason := 0
var _native_progress := 0.0
## The recorded reason of the follower's current slow-down or stop ("" while simply following).
var _native_wait := ""
## Blocked discs (x, z, radius triples) from obstruction evidence, for the next route search.
var _native_blocked := PackedFloat32Array()
## Discs round ponies standing in her way (peer_passage.gd reroutes, native stall replans), kept
## apart from the obstruction evidence above: only fresh ones (PEER_DISC_SECONDS) reach a search,
## and a search they leave without a route is redone without them (navigator_routes.gd).
var _peer_discs := PackedFloat32Array()
var _peer_discs_msec := -1
var _planned_with_peers := false
const PEER_DISC_SECONDS := 10.0
## Avoidance answers tagged by the frame they arrived in and the intent they were asked for.
var _avoid_frame := -1
var _avoid_submit_intent := -1
var _avoid_answer_intent := -2
var _avoid_last_position := Vector3.INF
signal arrived
signal route_failed(reason: String)
signal route_changed

enum State { IDLE, WAITING, MOVING, INTERRUPTED, ARRIVED, UNREACHABLE, BLOCKED }
enum Gait { TROT, WALK }
## Requested speeds are metres per second drawn from the pony's gait profile bands
## (walk_speed / trot_speed). The locomotion controller picks walk, trot or gallop
## from the request with its own entry/exit hysteresis; a gallop is never requested
## by name, it follows from a speed above the trot band (catching up).
const HOUSE := preload("res://world/buildings/house_interior.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const RIVER := preload("res://world/navigation/river_crossings.gd")
## Destinations farther than this are walked in legs, each planned when the last is nearly done.
## Pegasi fly any trip longer than this instead of walking it.
const LONG_WALK_M := 35.0
const JOURNEY_LEG := 110.0
## Explicit ground actions must not fight their executor's landing behavior.
var _flight_shortcuts := true
var house_travel:=preload("res://world/characters/navigation/house_travel.gd").new()
const DAILY := preload("res://world/ai/pony_daily_activity.gd")
const REST_PLACEMENT := preload("res://world/navigation/rest_placement.gd")
@export var wander_enabled := true
## Gait for explicit go_to(); autonomous walking uses a daylight-dependent band.
@export var gait := Gait.TROT
## Current cruise speed in metres per second, eased toward pace_target.
var pace := 0.4
var pace_target := 0.4
## Unhurried arrivals: the last stretch of a fixed destination is walked.
@export var approach_distance := 0.65
## Gain from formation error (m) to extra following speed (m/s) for a moving goal.
@export var follow_gain := 1.0
var _pace_timer := 0.0
var _route_gait := Gait.TROT
@export var wander_radius := 35.0
## Wandering alternates with real rests, not a new destination every few seconds.
@export var rest_seconds := Vector2(6.0, 16.0)
@export var wander_seconds := Vector2(12.0, 28.0)
@export_range(0.0, 1.0) var sit_chance := 0.75
## Wander never strays further than this from where she started.
@export var leash_radius := 180.0
## Share of wander routes taken at a trot instead of a walk.
@export var wander_trot_share := 0.75
## Lateral wobble of the followed corridor, metres, driven by noise.
@export var path_wobble := 0.0
@export_range(0.0, 1.0) var approach_player_chance := 0.15
## Someone worth a glance now and then (the player). Rare by design.
@export var attention_target: Node3D
@export var glance_interval := Vector2(12.0, 30.0)
@export var glance_chance := 0.4
## Head-frame sign conventions for the directed look; flip if she looks the
## wrong way (unverified on this rig, dev to judge in the headset).
@export var look_pitch_sign := 1.0
@export var look_yaw_sign := 1.0
## Print state and reason every few seconds (game log diagnostics).
@export var debug_log := false
@export var arrival_distance := 0.25:
	set(value):
		if is_equal_approx(arrival_distance, value): return
		arrival_distance = value
		if is_instance_valid(agent): agent.target_desired_distance = value
		if _native_handle.size() == 2 and _native_service == _service:
			_configure_native_limits()
@export var target_snap_distance := 1.0
@export var stuck_timeout := 3.0

var state := State.IDLE
var reason := ""
var target := Vector3.ZERO
var path := PackedVector3Array()
var agent: NavigationAgent3D
var pony: CharacterBody3D
var _has_target := false
var _needs_path := false
var _home := Vector3.ZERO
var _initialized := false
var _idle_time := 1.0
var _map_revision := 0
var _safe_velocity := Vector3.ZERO
var _desired_velocity := Vector3.ZERO
var _stuck_time := 0.0
var _progress_position := Vector3.ZERO
var _retries := 0
var _was_interrupted := false
## Crucial-moment presence (docs/plans/AI_CONTEXT_AND_INTERRUPTION_RESILIENCE_2026_10_02.md): a story
## encounter reserves her (reserve()); then only owners starting with one of its prefixes (and the
## AI's own small moves: approach, stay) may take this navigator. Any other takeover (day plan,
## night rest, living world, social outing, company visit, wandering) is refused and recorded,
## and their go_to/follow/command_destination right after the refused takeover do nothing.
var reserved_by := ""
var _reserved_owners: Array = []
var _reserved_wander := true
var _owner_denied_at := Vector2i(-1, -1)
## Recent refused takeovers, newest last (for traces and fixtures).
var denied_owners: Array = []
var command_owner := "":
	set(value):
		if not reserved_by.is_empty() and value != "" and not OWNERSHIP.admit_owner(self, value): return
		command_owner = value
var command_speed_limit := INF
var command_pace_target := -1.0
## Measured horizontal speed of a followed target (m/s); a moving goal is never
## braked below it, so formation error settles instead of sawtoothing.
var command_target_speed := 0.0
var command_target_velocity := Vector3.ZERO
var _tracking_speed := -1.0
var _moving_goal := false
## Following over ground the grid has not sampled yet: the controller's own probes own
## safety and the speed is held to the walk band until the cells are certified.
var _unknown_pursuit := false
## The destination as last requested; `target` becomes the certified route's end.
var _live_goal := Vector3.INF
var _follow_speed := 0.0
var _follow_last := Vector3.INF
var _follow_limit_owned := false
var _follow_target: Node3D
var _follow_timer := 0.0
var _follow_fail_ticks := 0
var _follow_goal := Vector3.INF
var _indoor_follow_cache: Dictionary = {}
var indoor_yield := preload("res://world/characters/navigation/indoor_peer_yield.gd").new()
## Outdoor pony-to-pony passage: ask loiterers to step aside, give way, reroute (peer_passage.gd).
var peer_passage := preload("res://world/characters/navigation/peer_passage.gd").new()
var _waypoint := 0
## True while the current route came from the wander picker, not a caller.
var _wandering := false
var _silent_avoidance := 0.0
var _off_mesh_time := 0.0
var _noise := FastNoiseLite.new()
var _noise_time := 0.0
var _glance_timer := 8.0
var _debug_timer := 0.0
var _wander_time := 0.0
var _rest_sit_pending := false
var _rest_posture := "sit"
var _company_cooldown := 0.0
var _pace_band := Vector2(.3, .5)
var _service: WalkGridService
var _request := -1
var _wander_request := -1
var _spot := ""
var _spot_goal := false
var _recent_wanders: Array[Vector3] = []
var _wander_intent := ""
var _approach_cooldown := 0.0
var _approaching_player := false
var _conversation_target: Node3D
var _conversation_hold := true
## Company at rest turns toward the point between its members (living_world_runtime);
## INF when unused. Beats the conversation partner so a seated circle stays a circle.
var face_point := Vector3.INF
var _lookahead_cache := Vector3.INF
var _lookahead_timer := 0.0
var _lookahead_waypoint := -1
var _escape_goal := Vector3.INF
var _escape_timer := 0.0
## Final destination of a long trip; `target` is then the current leg's end.
var _journey_goal := Vector3.INF
var _journey_attempt := 0
var _journey_flights := 0
## Bridge approach points still to pass on a trip that crosses the town river (river_crossings.gd).
var _journey_via: Array = []
## Resolved command locations: id -> [point, msec]; open ground beside a landmark is found
## once the walk grid has sampled it, then reused rather than searched every tick.
var _location_cache: Dictionary = {}


func _ready() -> void:
	pony = get_parent() as CharacterBody3D
	assert(pony != null and pony.has_method("set_desired_velocity"))
	_noise.seed = randi()
	_noise.frequency = 1.0
	add_to_group("pony_navigators")
	# The follow drivers' peer lists change only when a navigator joins or leaves the tree.
	get_tree().call_group("native_follow_drivers", "_invalidate_peers")
	tree_exiting.connect(func() -> void: get_tree().call_group("native_follow_drivers", "_invalidate_peers"))
	tree_entered.connect(func() -> void: get_tree().call_group("native_follow_drivers", "_invalidate_peers"))
	_noise.fractal_octaves = 2
	_idle_time = randf_range(1.0, 3.0) # Start life promptly; stagger first requests across frames.
	process_physics_priority = -10
	pony.navigation_steering = true
	agent = NavigationAgent3D.new()
	agent.name = "PathAgent"
	agent.radius = pony.profile.radius
	agent.height = pony.profile.clearance
	agent.path_desired_distance = 0.25
	agent.target_desired_distance = arrival_distance
	agent.path_max_distance = 0.9
	agent.max_speed = pony.profile.max_travel_speed
	_pace_band = pony.profile.trot_speed
	pace = _pace_band.x
	pace_target = pace
	agent.neighbor_distance = 3.0
	agent.time_horizon_agents = 1.0
	agent.time_horizon_obstacles = 0.7
	agent.avoidance_enabled = true
	# In the world scene this Navigator enters before the pony's _ready.
	# Its parent is still adding children then; defer sibling insertion so the
	# avoidance agent actually enters the tree instead of leaking unattached.
	pony.add_child.call_deferred(agent)
	agent.velocity_computed.connect(_on_safe_velocity)
	native_follow = NATIVE_BACKEND.follow_enabled() and pony.has_method("accept_navigation_motion")
	if native_follow:
		_native_inputs.resize(NATIVE_INPUT_STRIDE)
		_ensure_follow_driver()


func _owner_permitted(owner: String) -> bool:
	return OWNERSHIP.owner_permitted(self, owner)

## A story encounter reserves her: a route already under way for another owner stops now (an
## old route would otherwise carry her off), wandering stops, and only `owners` may command her.
func reserve(encounter: String, owners: Array) -> void:
	OWNERSHIP.reserve(self, encounter, owners)

func release_reservation(encounter: String) -> void:
	OWNERSHIP.release_reservation(self, encounter)

## Movement refused while reserved: no permitted owner holds her, or a takeover was just refused.
func _movement_refused(kind: String) -> bool:
	return OWNERSHIP.movement_refused(self, kind)

func go_to(destination: Vector3, route_gait: int = -1, flight_shortcuts := true) -> void:
	if _movement_refused("go_to"): return
	_flight_shortcuts = flight_shortcuts
	house_travel.clear(pony)
	_cancel_queries()
	_escape_goal = Vector3.INF; _escape_timer = 0.0
	_spot_goal = false
	_request = -1
	_wander_request = -1
	_rest_sit_pending = false
	if pony != null: _stand_for_travel()
	_follow_target = null
	_wandering = false
	_approaching_player = false
	if not destination.is_finite():
		_fail("Destination is not finite")
		return
	# Named commercial destinations resolve to a shared center. Reserve a guest spot
	# before routing, just as scheduled visits do, rather than parking every caller there.
	var visit_home: Node3D = HOUSE.at(get_tree(), destination) if pony != null else null
	if visit_home != null and visit_home.has_method("request_visit") and destination.distance_to(visit_home.center()) < .1:
		if not visit_home.request_visit(pony):
			_fail("Bakery is busy; choose another stop"); return
		destination = visit_home.visit_point(pony)
	if trace != null: trace.intent_generation += 1
	_native_intent += 1
	arrival_alternative = false
	_native_blocked = PackedFloat32Array()
	_peer_discs = PackedFloat32Array()
	_route_gait = gait if route_gait < 0 else route_gait
	_pick_pace()
	_moving_goal = false
	_unknown_pursuit = false
	command_target_speed = 0.0
	command_target_velocity = Vector3.ZERO
	if _follow_limit_owned:
		_follow_limit_owned = false
		command_speed_limit = INF
	target = destination
	_live_goal = destination
	_has_target = true
	_needs_path = true
	_retries = 0
	_stuck_time = 0.0
	state = State.WAITING
	reason = "Planning route"
	_reset_lookahead()
	_journey_goal = Vector3.INF
	_journey_attempt = 0
	_journey_flights = 0
	# Over the town river, walk by a bridge: legs and short searches both miss it otherwise.
	_journey_via = RIVER.route(pony.global_position, destination) if pony != null else []
	if pony != null and (not _journey_via.is_empty() or _flat_distance(pony.global_position, destination) > JOURNEY_LEG * 1.2):
		_journey_goal = destination
		_next_leg()
	elif _flight_shortcuts and pony != null and _flat_distance(pony.global_position, destination) > LONG_WALK_M and pony.has_method("request_flight") \
			and pony.identity != null and pony.identity.has_wings() and pony.request_flight(_flight_landing(destination)):
		# A pegasus does not trudge across town: long walks become a flight. Into a house she
		# lands at its door and walks the rest; the route is planned once she is down.
		_cancel_queries(); path.clear(); _needs_path = true
		state = State.MOVING; reason = "Flying there"


func _flight_landing(destination: Vector3) -> Vector3:
	return ROUTES.flight_landing(self, destination)

func stay() -> void:
	indoor_yield.clear()
	peer_passage.clear()
	_native_intent += 1
	house_travel.clear(pony)
	_journey_goal = Vector3.INF
	_journey_via = []
	_cancel_queries()
	_escape_goal = Vector3.INF; _escape_timer = 0.0
	_request = -1
	_wander_request = -1
	_spot = ""
	_follow_target = null
	if _follow_limit_owned:
		_follow_limit_owned = false
		command_speed_limit = INF
	wander_enabled = false
	_has_target = false
	_wandering = false
	_rest_sit_pending = false
	path.clear()
	state = State.IDLE
	reason = "Staying here"
	_reset_lookahead()
	_halt()


func follow(who: Node3D) -> void:
	if _movement_refused("follow"): return
	house_travel.clear(pony)
	_native_intent += 1
	_journey_goal = Vector3.INF
	_journey_via = []
	_follow_target = who
	_follow_goal = Vector3.INF
	_follow_last = Vector3.INF
	_follow_speed = 0.0
	wander_enabled = false
	_follow_timer = 0.0
	_retries = 0
	_stuck_time = 0.0
	_approaching_player = false


func set_conversation_target(who: Node3D, hold_position := true) -> void:
	_conversation_target = who
	_conversation_hold = hold_position
	if is_instance_valid(who) and command_owner.is_empty():
		_cancel_queries(); _has_target = false; _wandering = false; path.clear()
		state = State.IDLE; reason = "Facing conversation partner"
	if _holds_for_conversation(): _halt()


func _holds_for_conversation() -> bool:
	return is_instance_valid(_conversation_target) and (command_owner.is_empty() or not _has_target \
		or (_conversation_hold and command_owner.begins_with("life:")))


## Physics time skipped since the last run while the pony is in a clip tier.
var _clip_skipped := 0.0
## The pony keeps a clip-tier logic beat (pony_locomotion.is_logic_tick); looked up once per pony.
var _logic_beat := false
var _beat_pony: Object

## Clip-tier ponies run their logic at 20 Hz (pony_locomotion.is_logic_tick, dev 2026-09-25:
## "the same tickspeed as minecraft"): the route and steering update on her logic beat with
## the time that passed, and the velocity request holds in between. HERO ponies run every tick.
func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("navigators", started)

func _physics_step(delta: float) -> void:
	if pony != _beat_pony:
		_beat_pony = pony
		_logic_beat = pony.has_method(&"is_logic_tick")
	if _logic_beat and not pony.is_logic_tick():
		_clip_skipped += delta
		return
	var step := delta + _clip_skipped
	_clip_skipped = 0.0
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_navigator_tick(step)
	if started > 0: CPU_PROFILE.record("nav_logic_tick", started)
	if trace != null or NAV_TRACE.enabled:
		if trace == null: trace = NAV_TRACE.new(); trace.label = str(pony.name)
		trace.advance(self, step)


## Records `label` from `since` and returns the next checkpoint (only called under CPU_PROFILE.enabled).
static func _cpu_lap(label: String, since: int) -> int:
	CPU_PROFILE.record(label, since)
	return Time.get_ticks_usec()

func _navigator_tick(delta: float) -> void:
	var prof := CPU_PROFILE.enabled
	var lap := Time.get_ticks_usec() if prof else 0
	if pony.get(&"sleeping") == true:
		_halt()
		return
	if pony.get(&"thrown") != null and pony.thrown.active(): return
	if pony.get(&"flight") != null and pony.flight.active(): return
	_approach_cooldown = maxf(0.0, _approach_cooldown - delta)
	_company_cooldown = maxf(0.0, _company_cooldown - delta)
	if not _initialized:
		_home = pony.global_position
		_progress_position = _home
		_initialized = true
		if REST_PLACEMENT.passage(get_tree(), _home, pony.profile.radius): _idle_time = 0.0
	var interrupted: bool = pony.motion_paused or pony._held or (pony.get(&"hoof_hold")!=null and pony.hoof_hold.active()) or not pony._interaction.is_empty()
	if interrupted:
		_was_interrupted = true
		state = State.INTERRUPTED
		reason = "Held, petted, or paused"
		_halt()
		_reset_lookahead()
		return
	if indoor_yield.tick(self): return
	if peer_passage.tick(self, delta): return
	if face_point.is_finite() and not _has_target:
		_halt()
		var toward := face_point - pony.global_position; toward.y = 0.0
		if toward.length() > 0.1 and pony.has_method(&"face_direction"):
			pony.face_direction(toward.normalized())
		state = State.IDLE; reason = "Facing the group"
		return
	if _holds_for_conversation():
		_halt()
		var facing := _conversation_target.global_position - pony.global_position; facing.y = 0.0
		if facing.length() > 0.1 and pony.has_method(&"face_direction"):
			pony.face_direction(facing.normalized())
		state = State.IDLE; reason = "Facing conversation partner"
		return
	if _contact_approach.is_finite():
		if _flat_distance(pony.global_position, _contact_approach) <= arrival_distance:
			stay(); state = State.ARRIVED; reason = "Arrived at physical contact approach"
			arrived.emit()
		else:
			# The same short physical corridor used at doorways: the motor's
			# collision and support checks remain authoritative inside grid erosion.
			house_travel.walk(self, _contact_approach)
		return
	if prof: lap = _cpu_lap("nav_pre_guards", lap)
	# Neither _plan() nor the wander picker reads the map any more (walk grid routes); the agent
	# creates the world's map itself. 0.1.0 perf: no World3D lookup every logic tick.
	var map := RID()
	if not is_instance_valid(_service):
		for node in get_tree().get_nodes_in_group("pony_navigation"):
			if node is WalkGridService and (not is_instance_valid(_service) or node.bounds.get_center().distance_to(pony.global_position) < _service.bounds.get_center().distance_to(pony.global_position)):
				_service = node
		if is_instance_valid(_service):
			_service.ensure_near(pony.global_position, 2.0)
	if not is_instance_valid(_service) or not _service.ready_for_paths:
		state = State.WAITING
		reason = "Waiting for navigation"
		_needs_path = _has_target
		_halt()
		return
	if _moving_goal and _has_target:
		_service.ensure_near(pony.global_position, 4.0)
	var iteration := _service.revision
	if iteration != _map_revision:
		_cancel_queries()
		_map_revision = iteration
		_needs_path = _has_target
		_request = -1
		_wander_request = -1
		_reset_lookahead()
	if _was_interrupted:
		_was_interrupted = false
		_escape_goal = Vector3.INF; _escape_timer = 0.0
		_needs_path = _has_target
		_stuck_time = 0.0
		# A casual wander goal is disposable. Putting her down should not send
		# her straight back to a destination chosen before she was picked up.
		if wander_enabled and reserved_by.is_empty() and (_wandering or not _has_target):
			_begin_rest(randf_range(15.0, 30.0))
	if prof: lap = _cpu_lap("nav_service", lap)
	_update_glance(delta)
	if prof: lap = _cpu_lap("nav_glance", lap)
	if debug_log:
		_debug_timer -= delta
		if _debug_timer <= 0.0:
			_debug_timer = 5.0
			print("[navigator] %s: %s (on_floor=%s target=%s pace=%.2f speed=%.2f off_mesh=%.1fs silent_avoid=%.1fs at %s)" % [
				State.keys()[state], reason, pony.grounded(), _has_target, pace,
				Vector2(pony.velocity.x, pony.velocity.z).length(), _off_mesh_time, _silent_avoidance,
				pony.global_position.snapped(Vector3.ONE * 0.1)])
	if not pony.grounded():
		_halt()
		return
	if is_instance_valid(_follow_target):
		_follow_timer -= delta
		# Being close on the far side does not finish the owned door crossing.
		# Let HouseTravel clear its endpoint and passage before ordinary follow rests.
		if not house_travel.active() and pony.global_position.distance_to(_follow_target.global_position) < 1.8 and house_travel.here(pony)==house_travel.house_at(get_tree(),_follow_target.global_position):
			_has_target = false
			path.clear()
			_follow_goal = Vector3.INF
			state = State.IDLE
			reason = "Close to follow target"
			_halt()
			return
		if _follow_timer <= 0.0:
			_follow_timer = 0.75
			var destination := _follow_target.global_position
			if _follow_last.is_finite():
				var moved := destination - _follow_last; moved.y = 0.0
				_follow_speed = lerpf(_follow_speed, moved.length() / 0.75, 0.5)
			_follow_last = destination
			# Her speed follows the target's measured pace plus the gap, never a
			# fixed band: a walking Anon gets a matching trot, a lead gets a gallop.
			var gap := _flat_distance(pony.global_position, destination)
			command_target_speed = _follow_speed
			command_target_velocity = (destination - pony.global_position).normalized() * _follow_speed
			command_target_velocity.y = 0.0
			command_speed_limit = clampf(_follow_speed + maxf(0.0, gap - 1.8) * follow_gain, pony.profile.walk_speed.x, pony.profile.max_travel_speed)
			_follow_limit_owned = true
			_moving_goal = true
			# A refused or blocked follow is retried every few seconds even when the leader
			# stands still: the grid keeps sampling around them, and a refusal must never
			# mean "walk somewhere else and try again" (dev 2026-09-18).
			var failed := state in [State.BLOCKED, State.UNREACHABLE]
			_follow_fail_ticks = _follow_fail_ticks + 1 if failed else 0
			if not _follow_goal.is_finite() or destination.distance_to(_follow_goal) > 0.75 or _follow_fail_ticks >= 4:
				if failed: _retries = 0; _follow_fail_ticks = 0
				_follow_goal = destination
				target = destination
				_live_goal = destination
				_has_target = true
				_needs_path = true
				# Refreshing a moving target must not erase the stuck timer.
				# Only real movement below counts as progress toward recovery.
	if prof: lap = _cpu_lap("nav_follow", lap)
	if not _has_target:
		_halt()
		if wander_enabled and reserved_by.is_empty():
			_idle_time -= delta
			if _rest_sit_pending and pony.actual_speed < 0.02:
				_rest_sit_pending = false
				if pony.has_method(&"request_posture"):
					if not pony.request_posture(_rest_posture):
						_rest_sit_pending = pony.posture_status().refusal == "Wait until stopped"
					else:
						reason = "Sunning herself" if _rest_posture=="lie_down" and DAILY.sunny(pony) else "Resting"
				elif pony.has_method(&"request_sit"):
					pony.request_sit()
			if _idle_time <= 0.0:
				if not _stand_for_travel(): return
				_pick_wander_point(map)
		if prof: _cpu_lap("nav_idle", lap)
		return
	if not _stand_for_travel():
		_halt()
		return
	if house_travel.update(self):return
	# The native corridor starts where she stands, cramped or not: one writer, no legacy escape step.
	if not native_follow and _recover_cramped_start(delta): return
	if _approaching_player and not _needs_path:
		_wander_time -= delta
		if _wander_time <= 0.0:
			_begin_rest()
			return
	# Nobody holds one exact speed. Drift inside the gait's band: a new
	# target every few seconds, eased so the footfalls never see a step.
	_pace_timer -= delta
	_dawdle_seconds -= delta
	if _pace_timer <= 0.0:
		_pick_pace(false)
	# Noise on top of the band target: nobody holds a speed, and the drift
	# is continuous rather than a new step every few seconds.
	_noise_time += delta
	var band := _pace_band
	var drift := _noise.get_noise_1d(_noise_time * 0.35) * (band.y - band.x) * 0.5
	var target_pace := pace_target + drift if command_pace_target < 0.0 else command_pace_target
	var requested := clampf(target_pace, band.x, band.y) if command_pace_target < 0.0 else clampf(target_pace, .15, pony.profile.max_travel_speed)
	pace = move_toward(pace, requested, delta * (2.0 if command_pace_target >= 0.0 else 0.6))
	if prof: lap = _cpu_lap("nav_travel_pace", lap)
	if _needs_path:
		if not _plan(map):
			return
		# The native follower brakes for the end of the corridor it has and records that wait.
		if not native_follow and (_flat_distance(pony.global_position,path[-1])<=arrival_distance or (path.size()>1 and passed_waypoint(pony.global_position,path[-2],path[-1]))):
			# Reached the previous route while its extension is pending. Do not
			# orbit its final sample or claim arrival at the newer destination.
			# A moving goal on certified open ground is pursued directly meanwhile,
			# so a fast leader is not lost to every replan.
			if not (_pending_leg() or (_moving_goal and command_target_velocity.length() > .3)):
				_halt();state=State.WAITING;reason="Waiting for route extension";return
	# A moving goal outruns the planner: when the certified route ends far from the
	# live slot, pursue the slot directly over certified ground (short legs, each
	# checked by the service) and let the next route replace it when it lands.
	if prof: lap = _cpu_lap("nav_plan", lap)
	if _moving_goal and _live_goal.is_finite() and not path.is_empty() and _flat_distance(path[-1], _live_goal) > 1.5:
		if _direct_leg():
			_needs_path = true
	if prof: lap = _cpu_lap("nav_direct_leg", lap)
	if native_follow:
		# Long trips still plan their next leg here; arrival, steering and stall recovery are the
		# native follower's (events come back through _on_native_event).
		if _journey_goal.is_finite() and _request < 0 and not _needs_path and _flat_distance(pony.global_position, target) < 25.0:
			if not _journey_via.is_empty() or _flat_distance(pony.global_position, _journey_goal) > JOURNEY_LEG * 1.2 or _flat_distance(target, _journey_goal) > 1.0:
				_journey_attempt = 0
				_next_leg()
		_native_authored = false
		_native_speed_cap = INF
		_native_tick(delta)
		peer_passage.watch(self, delta)
		if prof: _cpu_lap("nav_native_tick", lap)
		return
	# GDScript steering: --native-navigation off, or a pony the native follower could not register.
	LEGACY.steer(self, delta)
	if prof: _cpu_lap("nav_legacy_steer", lap)


## Callers waiting for travel must let terrain sampling/path search finish rather
## than cancelling its request with another identical movement command.
func route_pending() -> bool:
	return _has_target and _request >= 0


func _plan(map: RID) -> bool:
	if _request < 0:
		if house_travel.active():target=house_travel.goal
		var extra := {}
		_planned_with_peers = false
		if native_follow:
			extra["escape_reach"] = NATIVE_ESCAPE_REACH
			var blocked := _native_blocked
			if not _peer_discs.is_empty() and Time.get_ticks_msec() - _peer_discs_msec <= int(PEER_DISC_SECONDS * 1000.0):
				blocked = _native_blocked + _peer_discs
				_planned_with_peers = true
			if not blocked.is_empty(): extra["blocked"] = blocked
		_request = _service.request_path(pony.global_position,target,pony.profile,_path_ready,_spot_goal,_wandering or autonomous_command(),extra)
	# Moving-target refreshes retain the previously certified route while the new
	# query builds. The normal per-step clearance guard still validates each step.
	if not path.is_empty() and _waypoint < path.size(): return true
	# A moving goal with no route yet is pursued over certified ground meanwhile.
	if _pending_leg():
		return true
	state = State.WAITING
	reason = "Sampling terrain / planning route"
	_halt()
	return false


func _recover_cramped_start(delta: float) -> bool:
	return LEGACY.recover_cramped_start(self, delta)

## Replace the route with one short leg toward the live goal: certified when the grid
## knows the ground, otherwise unknown-but-not-refused ground at walking speed.
func _pending_leg() -> bool:
	if not _live_goal.is_finite(): return false
	if _moving_goal: return _direct_leg()
	# Ordinary outings can start across already certified nearby ground while
	# the worker searches the complete route. Unknown ground still means wait.
	return autonomous_command() and _direct_leg(false)

## Reuse the six-value profile record without caching mutable profile values.
## Resource properties may change without a changed signal; refresh all values each time.
var _direct_profile_values := {"slope": 0.0, "step": 0.0, "wade": 0.0, "swim": false, "radius": 0.0, "clearance": 0.0}

func _direct_profile_hash() -> int:
	var profile: Resource = pony.profile
	_direct_profile_values.slope = float(profile.max_slope_degrees)
	_direct_profile_values.step = float(profile.step_height)
	_direct_profile_values.wade = float(profile.wade_depth)
	_direct_profile_values.swim = bool(profile.swim)
	_direct_profile_values.radius = float(profile.radius)
	_direct_profile_values.clearance = float(profile.clearance)
	return _direct_profile_values.hash()

## 0.1.0 perf: the last refused certified-only direct leg (see _direct_leg). Rollback:
## DIRECT_REFUSAL_CACHE = false.
const DIRECT_REFUSAL_CACHE := true
var _direct_refused_at := Vector3.INF
var _direct_refused_goal := Vector3.INF
var _direct_refused_profile := 0
var _direct_refused_trails := false
var _direct_refused_snapshot: Dictionary = {}

func _direct_leg(allow_unknown := true) -> bool:
	var destination:Vector3=house_travel.goal if house_travel.active() else _live_goal
	var toward := destination - pony.global_position; toward.y = 0.0
	if toward.length() <= arrival_distance: return false
	var snapshot := _service.grid.snapshot()
	var profile_hash := _direct_profile_hash()
	var trails := autonomous_command()
	if _direct_serial == _path_serial and path.size() == 2 \
			and _flat_distance(pony.global_position, path[-1]) > 1.2 \
			and destination == _direct_goal and profile_hash == _direct_profile \
			and trails == _direct_trails \
			and (allow_unknown or not _unknown_pursuit) \
			and pony.global_position.distance_to(Geometry3D.get_closest_point_to_segment(pony.global_position, path[0], path[1])) < .2 \
			and is_same(snapshot, _direct_snapshot):
		return true
	# A certified-only leg refused from this very spot, toward this goal, on this same published
	# ground is refused again (the check reads nothing else): an outing waiting for its route
	# re-ran it on every logic beat while standing still.
	if not allow_unknown and DIRECT_REFUSAL_CACHE and pony.global_position == _direct_refused_at \
			and destination == _direct_refused_goal and profile_hash == _direct_refused_profile \
			and trails == _direct_refused_trails and is_same(snapshot, _direct_refused_snapshot):
		return false
	var direct := pony.global_position + toward.limit_length(2.4)
	direct.y = lerpf(pony.global_position.y, destination.y, minf(2.4 / toward.length(), 1.0))
	if _service.steering_segment_clear(pony.global_position, direct, pony.profile, trails):
		_unknown_pursuit = false
	elif allow_unknown and _service.segment_unknown_or_clear(pony.global_position, direct, pony.profile, trails):
		_unknown_pursuit = true
	else:
		if not allow_unknown:
			_direct_refused_at = pony.global_position
			_direct_refused_goal = destination
			_direct_refused_profile = profile_hash
			_direct_refused_trails = trails
			_direct_refused_snapshot = snapshot
		return false
	path = PackedVector3Array([pony.global_position, direct]); _waypoint = 1; _reset_lookahead()
	_path_serial += 1
	_direct_serial = _path_serial
	_direct_goal = destination
	_direct_snapshot = snapshot
	_direct_profile = profile_hash
	_direct_trails = trails
	return true


func _path_ready(result: Dictionary, request_id: int, completed_revision: int) -> void:
	ROUTES.path_ready(self, result, request_id, completed_revision)


func _navigation_available() -> bool:
	for service in get_tree().get_nodes_in_group("pony_navigation"):
		if not service.ready_for_paths:
			return false
	return true


func _pick_wander_point(map: RID) -> void:
	WANDER.pick_wander_point(self, map)

func _wander_ready(result: Dictionary, request_id: int, completed_revision: int) -> void:
	WANDER.wander_ready(self, result, request_id, completed_revision)

func go_to_spot(id: String) -> void:
	COMMANDS.go_to_spot(self, id)

const AUTONOMOUS_OWNERS := ["social:", "life:", "sleep:", "leisure:", "day:"]

func autonomous_command() -> bool:
	for prefix: String in AUTONOMOUS_OWNERS:
		if command_owner.begins_with(prefix): return true
	return false


## AI commands own intent only; route sampling, contact and acceleration stay here.
func command_destination(destination: Vector3, requested_pace: String, refresh := false) -> bool:
	return COMMANDS.command_destination(self, destination, requested_pace, refresh)

func command_target_visible(who: Node3D) -> bool:
	return COMMANDS.command_target_visible(self, who)

func command_target_floor(at: Vector3) -> Vector3:
	return COMMANDS.command_target_floor(self, at)

## Final sub-half-metre step after a supported activity route has arrived.
func command_contact_approach(destination: Vector3) -> bool:
	return COMMANDS.command_contact_approach(self, destination)

func command_support(at: Vector3) -> Vector3:
	return COMMANDS.command_support(self, at)


## A travelling group narrows to single file when side slots leave the road.
func command_formation_support(at: Vector3, leader: Vector3) -> Vector3:
	return COMMANDS.command_formation_support(self, at, leader)

func command_follow_goal(goal:Vector3,leader:Vector3) -> Vector3:
	return COMMANDS.command_follow_goal(self, goal, leader)

func _indoor_follow_support(home:Node3D, at:Vector3, floor_y:float) -> Vector3:
	return COMMANDS.indoor_follow_support(self, home, at, floor_y)

func command_places() -> Array:
	return COMMANDS.command_places(self)

## Lines for the prompt: nearest named places with labels and distances, then regions.
func command_place_lines(local_limit := 30) -> Array:
	return COMMANDS.command_place_lines(self, local_limit)

func command_location(id: String) -> Vector3:
	return COMMANDS.command_location(self, id)

## The next leg of a long trip: a point up to JOURNEY_LEG along the way, turned aside
## on retries when the straight line meets water, cliffs or buildings.
func _next_leg() -> void:
	ROUTES.next_leg(self)


func awareness_places() -> Array:
	return COMMANDS.awareness_places(self)


func map_layers() -> MapLayers:
	return _service.layers if is_instance_valid(_service) else null

func _cancel_queries() -> void:
	_contact_approach = Vector3.INF
	_direct_snapshot = {}
	_direct_refused_snapshot = {}
	_direct_serial = -1
	if is_instance_valid(_service):
		_service.cancel_request(_request)
		_service.cancel_request(_wander_request)
	_request = -1
	_wander_request = -1
	_approaching_player = false


func _begin_rest(duration: float = -1.0) -> void:
	WANDER.begin_rest(self, duration)


func _may_approach_player() -> bool:
	return WANDER.may_approach_player(self)


## Curved physical motion can pass a dense path sample without entering its small
## acceptance circle. Do not turn back toward a passed sample; certify the next leg.
static func passed_waypoint(position: Vector3, previous: Vector3, waypoint: Vector3) -> bool:
	var segment := Vector2(waypoint.x - previous.x, waypoint.z - previous.z)
	var offset := Vector2(position.x - waypoint.x, position.z - waypoint.z)
	if segment.length_squared() < .0001 or absf(position.y - waypoint.y) > .65: return false
	return offset.dot(segment) >= 0 and offset.length() <= 2.5 and absf(offset.cross(segment.normalized())) <= .6


func _lookahead_point(position: Vector3, distance: float) -> Vector3:
	return LEGACY.lookahead_point(self, position, distance)


func _cached_lookahead(delta: float) -> Vector3:
	return LEGACY.cached_lookahead(self, delta)


func _reset_lookahead() -> void:
	_tracking_speed = -1.0
	_lookahead_cache = Vector3.INF
	_lookahead_timer = randf() * 0.1
	_lookahead_waypoint = -1


## Now and then, if the player is near, she looks at them for a moment.
func _update_glance(delta: float) -> void:
	_glance_timer -= delta
	if _glance_timer > 0.0:
		return
	WANDER.glance(self)


## Everyday outdoor strolling pace (m/s at a 2.2 m/s trot floor, scaled per body): the baked
## 1.6 m/s trot clip, what dev calls the walk.
const STROLL_TROT := Vector2(1.2, 1.8)
## A dawdle: now and then a pony alone slows to the solver's slow trot (the baked trot_slow clip)
## for a stretch, then picks her usual pace up again (dev 2026-10-31: "they shouldn't usually walk
## that slowly ... but they should do it sometimes"). Company dawdles more (pony_social_groups.gd).
const DAWDLE_TROT := Vector2(0.72, 1.05)
const DAWDLE_SECONDS := Vector2(8.0, 22.0)
## Chance per pace pick (every 3-7 s) of starting a dawdle, from a lazy hour to a busy one.
const DAWDLE_CHANCE := Vector2(0.09, 0.03)
var _dawdle_seconds := 0.0
func _pick_pace(restart: bool = true) -> void:
	_pace_band = pony.profile.walk_speed if _route_gait == Gait.WALK else pony.profile.trot_speed
	if _route_gait == Gait.WALK and (_wandering or autonomous_command()):
		# Everyday strolling outdoors is the trot clip, not the 0.3 m/s four-beat walk (dev
		# 2026-10-14). The walk stays for indoors and for slowing to a stop; speed alone picks
		# walk, slow trot, trot, fast trot and gallop.
		var indoors: bool = house_travel.here(pony) != null
		var body: float = pony.profile.trot_speed.x / 2.2
		var activity: float = daytime_activity()
		if not indoors and _dawdle_seconds <= 0.0 and randf() < lerpf(DAWDLE_CHANCE.x, DAWDLE_CHANCE.y, activity):
			_dawdle_seconds = randf_range(DAWDLE_SECONDS.x, DAWDLE_SECONDS.y)
		# Each pony keeps her own natural pace, a few percent brisker or easier than the next.
		var temper := 1.0 + (float(absi(hash(String(pony.name))) % 1000) / 1000.0 - 0.5) * 0.12
		_pace_band = pony.profile.walk_speed if indoors else (DAWDLE_TROT * body * temper if _dawdle_seconds > 0.0 \
			else DAILY.walk_band(STROLL_TROT * body * temper, activity))
	var band := _pace_band
	pace_target = randf_range(band.x, band.y)
	_pace_timer = randf_range(3.0, 7.0)
	if restart:
		# A fresh route starts inside its band rather than easing from the
		# previous gait across the walk/trot threshold mid-stride.
		pace = clampf(pace, band.x, band.y)


func _on_safe_velocity(value: Vector3) -> void:
	_safe_velocity = Vector3(value.x, 0.0, value.z).limit_length(pony.profile.max_travel_speed)
	# Tagged: the frame it arrived in and the intent whose preferred velocity it answers.
	_avoid_frame = Engine.get_physics_frames()
	_avoid_answer_intent = _avoid_submit_intent


func _halt() -> void:
	_desired_velocity = Vector3.ZERO
	_safe_velocity = Vector3.ZERO
	# Each write submits the agent's velocity to the avoidance server again; an idle pony
	# halts every logic tick, and its preferred velocity is already the zero it last sent.
	if agent.velocity != Vector3.ZERO: agent.velocity = Vector3.ZERO
	pony.stop()
	if _native_active: _native_clear()


func _fail(message: String, failure_state: State = State.UNREACHABLE) -> void:
	_contact_approach = Vector3.INF
	house_travel.abandon(pony)
	_has_target = false
	_approaching_player = false
	path.clear()
	state = failure_state
	reason = message
	_idle_time = 4.0
	if agent != null:
		_halt()
	if trace != null: trace.failed(self, message)
	route_failed.emit(message)


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _exit_tree() -> void:
	house_travel.clear(pony)
	_cancel_queries()
	if _native_active: _native_clear()


## --- Native follower adapter (phase 2) ---------------------------------------------------------

## The tree's single batch driver, added beside the world root on first use.
func _ensure_follow_driver() -> void:
	# A driver still waiting for its deferred add is not in any tree yet: keep it.
	if is_instance_valid(_follow_driver) and (not _follow_driver.is_inside_tree() or _follow_driver.get_tree() == get_tree()): return
	var tree := get_tree()
	if tree == null: return
	_follow_driver = FOLLOW_DRIVER.new()
	_follow_driver.name = "NativeFollowDriver"
	tree.root.add_child.call_deferred(_follow_driver)


## One navigator tick on the native follower: keep the corridor current, assemble this tick's
## inputs and queue the row; native_follow_driver.gd steps every queued row once, in one batch,
## before locomotion moves anypony, and hands each command back through _native_apply().
func _native_tick(delta: float) -> void:
	if path.size() < 2:
		_halt()
		state = State.WAITING
		reason = "Sampling terrain / planning route"
		return
	if not _native_ready():
		return
	var terminal := _native_terminal_route()
	if _native_serial != _path_serial or terminal != _native_terminal or _native_authored != _native_sent_authored or not _native_active:
		_native_send_corridor(terminal)
		if not _native_active:
			return
	var cruising: float = pace
	if is_finite(command_speed_limit): cruising = minf(command_speed_limit, pony.profile.max_travel_speed)
	cruising = minf(cruising, _native_speed_cap)
	var target_moving := _moving_goal and command_target_speed > 0.3
	var frame := Engine.get_physics_frames()
	var flags := 0
	if _avoid_frame >= 0 and _avoid_answer_intent == _native_intent: flags |= 1
	var wall_value: Variant = pony.get(&"nav_wall_normal")
	var wall: Vector3 = wall_value if wall_value is Vector3 else Vector3.ZERO
	if wall.length_squared() > 1e-6: flags |= 2
	if _request >= 0: flags |= 4
	_native_inputs[0] = cruising
	_native_inputs[1] = command_target_speed if target_moving else 0.0
	_native_inputs[2] = flags
	_native_inputs[3] = _safe_velocity.x
	_native_inputs[4] = _safe_velocity.z
	_native_inputs[5] = float(frame - _avoid_frame) / maxf(1.0, float(Engine.physics_ticks_per_second)) if _avoid_frame >= 0 else 1000.0
	_native_inputs[6] = wall.x
	_native_inputs[7] = wall.z
	_native_inputs[8] = float(pony.nav_executed_speed)
	_native_inputs[9] = float(pony.nav_executed_yaw_rate)
	_native_inputs[10] = float(pony.nav_refusal)
	_native_inputs[11] = delta
	# The motor's hill factor: the follower scales its target once (the motor no longer scales the
	# command, which compounded with the follower's acceleration window into a crawl uphill).
	var speed_scale: Variant = pony.get(&"nav_speed_scale")
	_native_inputs[12] = float(speed_scale) if speed_scale != null else 1.0
	_native_row_frame = frame
	_ensure_follow_driver()
	_follow_driver.submit(self)


## The native actor for this pony in its service's native world (shared with its route searches).
func _native_ready() -> bool:
	if _native_handle.size() == 2 and _native_service == _service: return true
	return NATIVE_ADAPTER.register(self)


func _configure_native_limits() -> void:
	NATIVE_ADAPTER.configure_limits(self)


## Corridors end at the destination (arrive there) unless they are a journey leg, a direct leg
## toward a far moving slot, a house approach, or a goal still on the move.
func _native_terminal_route() -> bool:
	if indoor_yield.goal.is_finite() or peer_passage.active(): return false
	if house_travel.active() or not _live_goal.is_finite() or path.is_empty(): return false
	if _moving_goal and command_target_speed > 0.3: return false
	if _journey_goal.is_finite() and _flat_distance(_live_goal, _journey_goal) > 1.0: return false
	return _flat_distance(path[-1], _live_goal) <= 1.0


func _native_send_corridor(terminal: bool) -> void:
	NATIVE_ADAPTER.send_corridor(self, terminal)


## Diagnostics for traces and labs (a Dictionary per call: not for every tick of normal play).
func native_follow_state() -> Dictionary:
	return NATIVE_ADAPTER.follow_state(self)


## Cheap accepted-corridor evidence for a companion taking a detour. Route identity is
## part of the sample: replanning must not count a new corridor's offset as movement.
func command_follow_progress() -> Vector2:
	return Vector2(_native_route, _native_progress) if _native_active else Vector2(-1, 0)


func _native_clear() -> void:
	NATIVE_ADAPTER.clear(self)


## Called by the batch driver with this tick's command row, diagnostics and preferred velocity.
func _native_apply(commands: PackedFloat32Array, states: PackedFloat32Array, preferred: Vector3, row: int) -> void:
	var at := row * 4
	if commands[at] == 0.0:
		# The follower no longer owns her (corridor gone natively): stop, plan afresh.
		_native_active = false
		pony.stop()
		_needs_path = _has_target
		return
	# The gait follows the follower's target speed (as the legacy navigator's requested pace did),
	# not the momentary command it accelerates through.
	pony.accept_navigation_motion(commands[at + 1], commands[at + 2], int(commands[at + 3]), preferred.length())
	var si := row * 8
	_native_mode = int(commands[at + 3])
	_native_progress = states[si]
	_native_reason = int(states[si + 5])
	_native_wait = "" if _native_reason in NATIVE_INFORMATIONAL or _native_reason < 0 or _native_reason >= NATIVE_REASONS.size() else str(NATIVE_REASONS[_native_reason])
	match _native_reason:
		1: state = State.MOVING; reason = "Turning round (stepping)"
		2: state = State.MOVING; reason = "Yielding to other ponies"
		3: state = State.MOVING; reason = "No safe arc; braking"
		4, 15: state = State.WAITING; reason = "Waiting for route extension"
		_: state = State.MOVING; reason = "Following route"
	# RVO retains its velocity between ticks. Forced velocity is a teleport reset,
	# not per-frame motor feedback (Godot 4.5 NavAgent3D's contract).
	_desired_velocity = preferred
	if not _avoid_last_position.is_finite() or pony.global_position.distance_squared_to(_avoid_last_position) > 9.0:
		var ground: Variant = pony.get(&"_ground_velocity")
		var actual: Vector3 = ground if ground is Vector3 else pony.velocity
		agent.set_velocity_forced(Vector3(actual.x, 0.0, actual.z))
	_avoid_last_position = pony.global_position
	agent.velocity = preferred
	_avoid_submit_intent = _native_intent
	# For the trace and the waypoint readers: the route point she has passed, never going back.
	var position := pony.global_position
	var best := _waypoint
	var nearest := INF
	for i in range(maxi(_waypoint, 1), mini(_waypoint + 4, path.size())):
		var closest := Geometry3D.get_closest_point_to_segment(position, path[i - 1], path[i])
		var gap := _flat_distance(position, closest)
		if gap < nearest - 0.001: nearest = gap; best = i
	_waypoint = maxi(_waypoint, best)
	var lookahead: float = states[si + 2]
	_lookahead_cache = position + (preferred.normalized() if preferred.length_squared() > 1e-6 else -pony.global_basis.z) * lookahead
	_stuck_time = 0.0


## Low-frequency follower events for this pony's current intent.
func _on_native_event(event: Dictionary) -> void:
	NATIVE_ADAPTER.on_event(self, event)


func daytime_activity() -> float:
	var clock := get_node_or_null("/root/TimeOfDay")
	return DAILY.daylight(float(clock.hours)) if clock != null else 1.0

func outgoing_radius() -> float:
	return wander_radius * lerpf(1.0, 1.5, daytime_activity())

func outgoing_leash() -> float:
	return leash_radius * lerpf(1.0, 1.8, daytime_activity())

func _ordinary_rest() -> float:
	return WANDER.ordinary_rest(self)

func _stand_for_travel() -> bool:
	# On a bench: stand up there and let Seating hop her down before walking off.
	if pony.get_meta(&"seated", false):
		if pony.has_method(&"request_posture") and pony.posture_status().requested != "stand": pony.request_posture("stand")
		return false
	if pony.has_method(&"posture_status"):
		var status: Dictionary = pony.posture_status()
		if status.kind != "stand" or not status.settled:
			pony.request_posture("stand")
			return false
	elif pony.has_method(&"is_sitting") and pony.is_sitting():
		pony.stand_up()
		return false
	return true

func _try_company_visit() -> bool:
	return WANDER.try_company_visit(self)
