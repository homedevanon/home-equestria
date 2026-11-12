class_name PonyCrowd
extends Node
## Simulation tiers for many ponies at once (dev, 2026-09-08: "100 concurrent rendered ponies").
##
## Every `interval` seconds the crowd ranks every simulated pony (group `sim_ponies`) by its
## distance to the current camera, in-frustum ponies first, and hands out tiers:
## - HERO: the full procedural solver (every tick inside `close_distance`, every other tick
##   out to `hero_distance`); held, touched, thrown or flying ponies are HERO at any distance,
##   talking ones within TALK_HERO_DISTANCE. Sitting, lying, sleeping, following and indoor
##   ponies are ranked by distance like any other.
## - NEAR and FAR also sit, lie and sleep: pony_posture.gd's state machine with baked posture clips.
## - NEAR (to `near_distance`): the solver-baked gait clips (baked_gaits.gd,
##   docs/CLIP_TIER_2026_09_25.md) on the model's own AnimationPlayer, root motion from the
##   navigator, floor height and slope from three rays; no contacts, leg solves or collision.
##   Full render, a live head over the clip, eyes and tail stay live. Their logic runs at 20 Hz,
##   a third of the ponies per step (phases 0..2).
## - FAR: the same clips on the merged far mesh; eyes, tail, attention and expressions parked.
## Without a camera (headless tests) every pony stays HERO, so nothing else changes.
## One crowd per SceneTree, created lazily by the first pony (`for_pony`).

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const GROUP := &"pony_crowd"
const MEMBERS := &"sim_ponies"
enum Tier { HERO, NEAR, FAR }

@export var interval := 0.25
## Physics ticks between whole steps of a FAR mare (quality.gd crowd_far_tick_divisor).
var far_tick_divisor := 1
@export var hero_budget := 1000  # dev 2026-09-17: every mare near the player is HERO or NEAR, never FAR; distance decides
@export var near_budget := 1000
## dev 2026-09-25: the solver is baked into the clip tiers' gaits and the clip tier has a live
## head, so only ponies within "spitting distance" (or pinned) run the full solver.
@export var hero_distance := 4.0
## Inside this range a HERO mare solves every tick; beyond it every other tick (30 Hz).
@export var close_distance := 3.0
@export var near_distance := 45.0
## FAR ponies run their logic every far_divisor-th physics step (quality.gd crowd_far_divisor:
## 3 = 20 Hz, Low 4 = 15 Hz, Very Low 6 = 10 Hz); their clip and root still move every step.
var far_divisor := 3
var _cli_tiers := false
## Past this a HERO mare solves every third tick (only a --hero-distance A/B reaches it).
const MID_DISTANCE := 12.0
## A speaking or listening pony farther than this runs the clip tier (live head and mouth);
## closer she stays on the solver.
const TALK_HERO_DISTANCE := 8.0
## A HERO pony keeps HERO until she is this much past hero_distance (the solver's hand-off
## into a clip is cheap but not free, and ponies walk along the line).
const HERO_MARGIN := 1.0
## dev 2026-09-25: ponies behind walls should not cost the full solve. A pony the renderer
## culls (outside the view, or behind a house occluder) runs the NEAR clip tier even inside
## hero range, except this close, where she can bump into you or you turn round onto her.
## The renderer's own cull decides, through a VisibleOnScreenNotifier3D on each pony; it
## goes through the same occlusion test as meshes. Coming back into view re-ranks at once.
@export var hidden_hero_distance := 4.0
## Tier changes are not free (a demotion bakes the current pose into a hand-off clip), and
## walking and turning made ponies flicker across the view edge, behind houses and across the
## range lines several times a second (dev 2026-09-25: 90 fps standing, 20 walking). So a pony
## counts as unseen only after UNSEEN_HOLD seconds out of sight, and keeps her tier until she is
## TIER_MARGIN metres past its range line. Promotion is still immediate.
const UNSEEN_HOLD := 2.0
const TIER_MARGIN := 4.0
const UNSEEN_SINCE := &"crowd_unseen_since"
## Sitting, lying and sleeping ponies are ranked like any other (dev 2026-09-25, F4 at 2:42 am:
## 45 of 46 ponies pinned on the solver, all asleep). Past hero range they play the baked posture
## clips on the 20 Hz clip-tier logic, where a settled hold does not even advance the mixer;
## within it a settled rest solves every other tick. `statistics.resting` counts clip-tier ponies
## in a posture. Never a stop (dev: "never fully disable a pony"): their navigator and schedule
## run as usual, so rests end on time.
## `--crowd-tiers off` keeps every pony HERO (A/B against the old behaviour).
var enabled := true
var statistics := {"hero": 0, "near": 0, "far": 0, "pinned": 0, "hidden": 0, "unseen_rest": 0, "resting": 0, "camera": false}
var _timer := 0.0
var _service: Node
var _visual_members: Array[Node] = []
## Each member's model pivot (null without one), refreshed with _visual_members in rank().
var _visual_pivots: Array[Node3D] = []
## Each member's view-test radius (0.1.0 perf pass: read per frame, its scale re-measured per ranking).
var _visual_radii := PackedFloat32Array()
const HIDDEN := &"crowd_hidden"

func _unprofiled_process(_delta: float) -> void:
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null:
		for pony in _visual_members:
			if is_instance_valid(pony) and pony.has_meta(HIDDEN):
				pony.refresh_hidden_clip()
				pony.pivot.show();pony.remove_meta(HIDDEN)
				if pony.has_method(&"set_crowd_hidden"): pony.set_crowd_hidden(false)
		return
	var xr := preload("res://world/player_view.gd").viewport(self).use_xr
	# Typed on both paths: "[] if xr else ..." is an untyped Array, and assigning it errored every
	# frame in VR (69k errors per session, stalling the game; 2026-10-15).
	var planes: Array[Plane] = []
	if not xr: planes = camera.get_frustum()
	for index in _visual_members.size():
		var pony: Node = _visual_members[index]
		if not is_instance_valid(pony) or not pony.is_inside_tree(): continue
		var center: Vector3 = pony.global_position + Vector3.UP * .7
		var radius: float = _visual_radii[index]
		var draw := true
		if xr:
			# Camera3D's desktop frustum may be narrower than the stereo eye views.
			# Cull only fully behind the headset; the renderer culls side geometry.
			draw = (center-camera.global_position).dot(-camera.global_basis.z) >= -radius
		else:
			for plane: Plane in planes:
				if plane.distance_to(center) > radius: draw=false; break
		var visual: Node3D = _visual_pivots[index]
		if not is_instance_valid(visual): continue
		if not draw and visual.visible:
			pony.set_meta(HIDDEN, true); visual.hide()
			# Her rigs stop their passes while nothing of her draws (pony_locomotion.gd HIDDEN_RIG_PARK).
			if pony.has_method(&"set_crowd_hidden"): pony.set_crowd_hidden(true)
		elif draw and pony.has_meta(HIDDEN):
			pony.refresh_hidden_clip()
			pony.remove_meta(HIDDEN)
			# Rigs back on their passes, with one this frame: she is drawn already posed.
			if pony.has_method(&"set_crowd_hidden"): pony.set_crowd_hidden(false)
			visual.show()


static func for_pony(pony: Node) -> Node:
	var tree := pony.get_tree()
	if tree == null:
		return null
	var existing: Node = tree.root.get_meta(GROUP) if tree.root.has_meta(GROUP) else null
	if is_instance_valid(existing):
		return existing
	var crowd := load("res://world/characters/crowd/pony_crowd.gd").new() as Node
	crowd.name = "PonyCrowd"
	tree.root.set_meta(GROUP, crowd)
	tree.root.call_deferred("add_child", crowd)
	return crowd


func _ready() -> void:
	add_to_group(GROUP)
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--crowd-tiers")
	if at >= 0 and at + 1 < args.size() and args[at + 1] == "off":
		enabled = false
	# Quality presets (XR_OVERRIDES) shrink the solver tiers in the headset; command
	# line switches win for A/B runs.
	_apply_quality(0)
	var quality := get_node_or_null("/root/Quality")
	if quality != null: quality.preset_changed.connect(_apply_quality)
	for flag in ["--hero-budget", "--near-budget", "--hero-distance", "--near-distance"]:
		if args.find(flag) >= 0: _cli_tiers = true
	at = args.find("--hero-budget")
	if at >= 0 and at + 1 < args.size(): hero_budget = int(args[at + 1])
	at = args.find("--near-budget")
	if at >= 0 and at + 1 < args.size(): near_budget = int(args[at + 1])
	at = args.find("--hero-distance")  # A/B: metres of full solve
	if at >= 0 and at + 1 < args.size(): hero_distance = float(args[at + 1])
	at = args.find("--near-distance")
	if at >= 0 and at + 1 < args.size(): near_distance = float(args[at + 1])
	# Headless there is no renderer to cull, so notifiers never report on-screen: keep the
	# cull-based demotion off there (benches and fixtures expect HERO ponies).
	# `--crowd-cull off` does the same in a rendered game for A/B runs.
	at = args.find("--crowd-cull")
	if DisplayServer.get_name() == "headless" or (at >= 0 and at + 1 < args.size() and args[at + 1] == "off"):
		hidden_hero_distance = INF
	at = args.find("--crowd-interval")  # A/B: seconds between re-rankings
	if at >= 0 and at + 1 < args.size(): interval = float(args[at + 1])
	# Runs after the ponies moved this tick, so next tick sees a settled ranking.
	process_physics_priority = 900


## Quality tiers: every pony stays present in every tier (dev 2026-09-29: "all ponies should be
## there, they should just LOD more aggressively"); the tiers only move the NEAR/FAR line in
## (45 m, Low 30, Very Low 20) and slow the FAR logic. HERO stays 4 m everywhere.
func _apply_quality(_preset: int) -> void:
	if _cli_tiers: return
	var quality := get_node_or_null("/root/Quality")
	if quality == null: return
	hero_budget = int(quality.get_value("crowd_hero_budget", hero_budget))
	near_budget = int(quality.get_value("crowd_near_budget", near_budget))
	hero_distance = float(quality.get_value("crowd_hero_distance", hero_distance))
	near_distance = float(quality.get_value("crowd_near_distance", near_distance))
	far_divisor = maxi(1, int(quality.get_value("crowd_far_divisor", far_divisor)))
	far_tick_divisor = maxi(1, int(quality.get_value("crowd_far_tick_divisor", 1)))
	_timer = 0.0


func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = interval
	rank()


## Assign tiers now (tests call this directly).
func rank() -> void:
	var members := get_tree().get_nodes_in_group(MEMBERS)
	_visual_members.assign(members)
	_visual_pivots.clear()
	_visual_radii.resize(members.size())
	for i in members.size():
		var pony: Node = members[i]
		_visual_pivots.append(pony.pivot if "pivot" in pony else null)
		# The per-frame view test's bounding radius, from her scale at this ranking (0.25 s).
		_visual_radii[i] = 2.5 * maxf(1.0, pony.global_basis.get_scale().length() / sqrt(3.0)) if pony is Node3D else 2.5
	var camera: Camera3D = preload("res://world/player_view.gd").camera(self)
	var counts := {"hero": 0, "near": 0, "far": 0, "pinned": 0, "hidden": 0, "unseen_rest": 0, "resting": 0, "camera": camera != null}
	if camera == null or not enabled:
		for pony in members:
			pony.hero_divisor = 1
			pony.set_detail_divisor(1)
			pony.set_sim_tier(Tier.HERO, 0)
		counts.hero = members.size()
		statistics = counts
		return
	var eye := camera.global_position
	var ranked: Array = []
	# (score, index into ranked): sorted natively, not through a script comparator (W2 perf pass:
	# the lambda was ~250 script calls per ranking with 45 ponies).
	var order: Array[Vector2] = []
	for pony in members:
		if not pony.is_inside_tree():
			continue
		var distance := eye.distance_to(pony.global_position)
		# is_pinned() is body_pinned() plus talking/listening; past TALK_HERO_DISTANCE only the
		# body pins count, so the conversation checks are skipped there.
		var pinned: bool = pony.body_pinned() if distance > TALK_HERO_DISTANCE else pony.is_pinned()
		if not pinned and not pony.has_clip_tier() and not (pony.has_method("own_far_tier") and pony.own_far_tier()):
			pinned = true  # a body layout without baked gaits has only the solver
		if pinned:
			# Held, touched, thrown, flying, riding a moving support (or up close in a
			# conversation): the solver, every tick when close or touched, else every other.
			var divisor := 1 if distance <= close_distance or pony.needs_full_rate() else 2
			pony.hero_divisor = divisor
			pony.set_detail_divisor(1)
			pony.set_sim_tier(Tier.HERO, counts.pinned % divisor)
			counts.pinned += 1
			counts.hero += 1
			continue
		var seen := _seen_held(pony, distance)
		# Unseen ponies rank as if farther away: they can be cheaper unseen.
		var score := distance * (1.0 if seen else 1.6)
		order.append(Vector2(score, ranked.size()))
		ranked.append([score, distance, pony, seen])
	order.sort()
	var near_index := 0
	for key in order:
		var entry: Array = ranked[int(key.y)]
		var pony: Node = entry[2]
		var hero_limit := hero_distance + (HERO_MARGIN if pony.sim_tier == Tier.HERO else 0.0)
		var near_limit := near_distance + (TIER_MARGIN if pony.sim_tier != Tier.FAR else 0.0)
		if not entry[3] and entry[1] <= hero_limit: counts.hidden += 1
		if counts.hero < hero_budget and entry[1] <= hero_limit and entry[3]:
			var close: bool = entry[1] <= close_distance
			var divisor := 1 if close else (2 if entry[1] <= MID_DISTANCE else 3)
			if pony.resting_hold() and not pony.needs_full_rate():
				divisor = 2  # a settled sit or lie beside you: every other tick
			pony.hero_divisor = divisor
			# Spike is a member with no NEAR_DIVISOR: reading it here would abort the whole ranking.
			var near_divisor: int = pony.NEAR_DIVISOR if "NEAR_DIVISOR" in pony else 1
			pony.set_detail_divisor(1 if entry[1] <= MID_DISTANCE else near_divisor, counts.hero % near_divisor)
			pony.set_sim_tier(Tier.HERO, 0 if close else counts.hero % divisor)
			counts.hero += 1
		elif counts.near < near_budget and entry[1] <= near_limit:
			if pony.posture != null and pony.posture.active(): counts.resting += 1
			pony.set_detail_divisor(1)
			pony.set_sim_tier(Tier.NEAR, near_index % 3)
			near_index += 1
			counts.near += 1
		else:
			if pony.posture != null and pony.posture.active(): counts.resting += 1
			pony.set_detail_divisor(1)
			if "far_logic_divisor" in pony: pony.far_logic_divisor = far_divisor
			if "far_tick_divisor" in pony: pony.far_tick_divisor = far_tick_divisor
			# Spread both whole-body and logic beats: reducing this offset modulo just
			# the logic divisor biases the body phases when the two divisors differ.
			pony.set_sim_tier(Tier.FAR, counts.far)
			counts.far += 1
	statistics = counts


## Seen now, or unseen for less than UNSEEN_HOLD seconds, or within hidden_hero_distance.
func _seen_held(pony: Node, distance: float) -> bool:
	if distance <= hidden_hero_distance or _seen(pony):
		if pony.has_meta(UNSEEN_SINCE): pony.remove_meta(UNSEEN_SINCE)
		return true
	var now := Time.get_ticks_msec() / 1000.0
	if not pony.has_meta(UNSEEN_SINCE):
		pony.set_meta(UNSEEN_SINCE, now)
		return true
	return now - float(pony.get_meta(UNSEEN_SINCE)) < UNSEEN_HOLD


## Whether the renderer drew this pony's body box last frame (in view and not behind an
## occluder). The notifier is added on first use; until the renderer has culled it once she
## counts as seen.
func _seen(pony: Node) -> bool:
	var notifier := pony.get_node_or_null(^"CrowdVisibility") as VisibleOnScreenNotifier3D
	if notifier != null:
		return notifier.is_on_screen()
	notifier = VisibleOnScreenNotifier3D.new()
	notifier.name = "CrowdVisibility"
	var s: Variant = pony.get("body_scale")
	var k: float = float(s) if s != null else 1.0
	notifier.aabb = AABB(Vector3(-0.6, 0.0, -0.9) * k, Vector3(1.2, 1.7, 1.8) * k)
	pony.add_child(notifier)
	notifier.screen_entered.connect(_on_pony_seen)
	return true


## A pony stepped out from behind a wall: re-rank on the next physics tick so she is
## back on the full solve before the clip pose can be noticed.
func _on_pony_seen() -> void:
	_timer = 0.0


## Floor height under `position` from the walk grid (no physics ray): the span nearest
## `near_y`, NAN when the column is unknown.
func floor_y(position: Vector3, near_y: float) -> float:
	if not is_instance_valid(_service):
		_service = get_tree().get_first_node_in_group("pony_navigation") if is_inside_tree() else null
		if _service == null or not (_service is WalkGridService):
			_service = null
			return WorldTerrain.instance.height_at(position) if is_instance_valid(WorldTerrain.instance) else NAN
	var data: Dictionary = _service.grid.snapshot()
	var column := WalkGrid.column(position)
	var best := NAN
	var best_gap := 1.5
	for span in WalkGrid.SPANS:
		var sample := WalkGrid.sample(data, Vector3i(column.x, span, column.y))
		if sample.is_empty():
			continue
		var gap := absf(float(sample.height) - near_y)
		if gap < best_gap:
			best_gap = gap
			best = float(sample.height)
	if not is_finite(best) and is_instance_valid(WorldTerrain.instance):
		best = WorldTerrain.instance.height_at(position)
	return best


func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process(_delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("crowd_process", started)
