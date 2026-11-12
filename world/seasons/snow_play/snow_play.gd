extends Node
## Physical snow (W2-SEAS-F 2026-11-08; design captures/overhaul-2026-11-08/seasons/
## AUDIT_AND_DESIGN.md 6.2 'Physical snow'). Child "SnowPlay" of SeasonState, made by
## season_state.gd's optional FEATURES list; group "snow_play".
##
## - Snowballs (snowball.gd, snow_pickup.gd): scoop where the snow cover mirror
##   (world/seasons/snow_cover_query.gd) is deeper than SCOOP_COVER, throw, burst on a hit with a
##   puff and a real snow sample; a pony hit gets physical_reaction("snowball_hit"). At most
##   MAX_SNOWBALLS live; a resting one is gone 20 s after it stops.
## - Snowmen (snowman.gd): a snowball set down on snow rolls and grows (radius ~ sqrt(metres
##   rolled), cap 0.6 m) and stamps a rolled trail; pushed into a bigger ball it stacks; three
##   balls are a snowman, dressed by hand with a carrot, coal, sticks and a scarf (item rows in
##   world/seasons/data/snow_items.json). Saved in world_context.state.seasons.snowmen through
##   season_state (max MAX_SNOWMEN, the oldest unfinished, then the oldest, removed); they melt
##   away once the snow cover reaches 0.
## - Snow piles (snow_pile.gd) beside house doors under the eaves, burst by walking through them.
##
## Cost: nothing at all outside snow (no timers, no physics, out of every input/provider group);
## with snow a 1 Hz check, a 4 Hz proximity check only while snowmen or piles exist, physics only
## while a lone ball may be pushed by VR hands. Thrown balls are the only simulated bodies.
##
## API (group "snow_play", for ponies W2-SEAS-H and events W2-SEAS-I): active(), cover_at(pos),
## throw_snowball(from, velocity, thrower), build_snowman(at, facing, by), snowmen_near(at, r),
## snowman_count(); signals snowball_hit(target, at, thrower), snowman_built(snowman, by).
signal snowball_hit(target: Node, at: Vector3, thrower: Node)
signal snowman_built(snowman: Node, by: String)

const SNOWBALL := preload("res://world/seasons/snow_play/snowball.gd")
const SNOWMAN := preload("res://world/seasons/snow_play/snowman.gd")
const PILE := preload("res://world/seasons/snow_play/snow_pile.gd")
const PICKUP := preload("res://world/seasons/snow_play/snow_pickup.gd")
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
const QUERY := preload("res://world/seasons/snow_cover_query.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const ITEMS_PATH := "res://world/seasons/data/snow_items.json"
const GROUP := "snow_play"
const SAVE_KEY := "snowmen"
const SCOOP_COVER := PICKUP.SCOOP_COVER
const MAX_SNOWBALLS := 8
const MAX_SNOWMEN := 12
## Real seconds a snowman takes to melt away once the snow is gone.
const MELT_SECONDS := 90.0
const SLOW_TICK := 1.0
const NEAR_TICK := 0.25
## Without snow: how often late autumn and winter look for the first snow.
const IDLE_POLL := 5.0
const PILE_RADIUS := 60.0
const PILE_REFRESH_MOVE := 20.0
const MAX_PILES := 16
const PILE_KICK_SPEED := 0.8
const PUSH_RANGE := 2.5
const DRESS_SECONDS := 0.5
const DRESS_REACH := 0.3
## A pony-built snowman (build_snowman): base, body, head.
const BUILT_RADII: Array[float] = [0.42, 0.3, 0.2]

var seasons: Node
var game: Node
var world: Node3D
var pickup: Node
## Tests: an inventory node stand-in, a fixed snow cover.
var inventory_override: Node
var cover_override := -1.0
var _active := false
var _snowballs: Array[RigidBody3D] = []
var _stacks: Array[Node3D] = []
var _piles: Dictionary = {}          # key -> pile
var _slow: Timer
var _near: Timer
var _pile_from := Vector3.INF
var _last_player := Vector3.INF
var _dress: Dictionary = {}          # side -> [stack, part, seconds]
var _push_last: Dictionary = {}      # side -> palm last tick
var _push_stacks: Array[Node3D] = []
var _items: Dictionary = {}
var _next_id := 0

func _init() -> void:
	add_to_group(GROUP)
	world = Node3D.new(); world.name = "SnowWorld"
	add_child(world)
	pickup = PICKUP.new(); pickup.name = "SnowPickup"
	add_child(pickup)
	pickup.call("setup", self)
	_slow = Timer.new(); _slow.name = "SnowTick"; _slow.wait_time = SLOW_TICK; _slow.one_shot = false
	_slow.timeout.connect(tick)
	add_child(_slow)
	_near = Timer.new(); _near.name = "SnowNear"; _near.wait_time = NEAR_TICK; _near.one_shot = false
	_near.timeout.connect(_tick_near)
	add_child(_near)
	set_physics_process(false)
	set_process(false)

## season_state hookup: signals, the saved snowmen, the first check.
func setup(state: Node) -> void:
	seasons = state
	var host: Variant = state.get("game") if state != null else null
	game = host as Node if host is Node and is_instance_valid(host) else null
	for pair: Array in [["season_changed", _on_season_signal], ["day_stepped", _on_day]]:
		if state != null and state.has_signal(pair[0]) and not state.is_connected(pair[0], pair[1]): state.connect(pair[0], pair[1])
	var context: Variant = state.get("context") if state != null else null
	if context is Node and is_instance_valid(context) and (context as Node).has_signal("reopened") and not (context as Node).is_connected("reopened", _on_reopened):
		(context as Node).connect("reopened", _on_reopened)
	restore()
	tick()

# ------------------------------------------------------------------ queries

func active() -> bool: return _active

func ui() -> Node:
	if is_instance_valid(inventory_override): return inventory_override
	var found: Variant = game.get("inventory") if is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

func snow_cover() -> float:
	if cover_override >= 0.0: return cover_override
	return float(seasons.call("snow_cover")) if is_instance_valid(seasons) and seasons.has_method("snow_cover") else 0.0

func effects_level() -> int:
	return int(seasons.call("effects_level")) if is_instance_valid(seasons) and seasons.has_method("effects_level") else 2

## Snow at a world point (the CPU mirror of the ground shader).
func cover_at(at: Vector3) -> float:
	if not is_inside_tree() or not at.is_finite(): return 0.0
	return QUERY.cover_at(get_tree(), at, Vector3.ZERO, snow_cover())

func stacks() -> Array[Node3D]:
	for i in range(_stacks.size() - 1, -1, -1):
		if not is_instance_valid(_stacks[i]) or _stacks[i].is_queued_for_deletion(): _stacks.remove_at(i)
	return _stacks

func snowballs() -> Array[RigidBody3D]:
	for i in range(_snowballs.size() - 1, -1, -1):
		if not is_instance_valid(_snowballs[i]) or str(_snowballs[i].get("state")) == "gone": _snowballs.remove_at(i)
	return _snowballs

func loose_snowballs() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for ball in snowballs():
		if str(ball.get("state")) == "resting": out.append(ball)
	return out

func snowman_count() -> int:
	return stacks().filter(func(s: Node3D) -> bool: return bool(s.call("complete"))).size()

func snowmen_near(at: Vector3, radius: float) -> Array:
	return stacks().filter(func(s: Node3D) -> bool: return bool(s.call("complete")) and s.global_position.distance_to(at) <= radius)

func piles() -> Array:
	return _piles.values().filter(func(p: Node) -> bool: return is_instance_valid(p))

# ------------------------------------------------------------------ activity and ticks

func _on_season_signal(_season: String) -> void: tick()

func _on_day(day: int) -> void:
	for pile: Node3D in piles():
		if int(pile.get("burst_day")) < day: pile.visible = true
	tick()

## The slow check: on or off, melting, piles, the timers' own schedule.
func tick() -> void:
	if not is_inside_tree(): return
	var cover := snow_cover()
	_set_active(cover > 0.001)
	if cover <= 0.001 and not stacks().is_empty():
		var gone := false
		for stack: Node3D in stacks().duplicate():
			if bool(stack.call("melt_by", SLOW_TICK / MELT_SECONDS)):
				_remove_stack(stack); gone = true
		if gone: mark_dirty()
	_refresh_piles(cover)
	var busy := _active or not stacks().is_empty() or not snowballs().is_empty()
	var season := str(seasons.call("season")) if is_instance_valid(seasons) and seasons.has_method("season") else ""
	var waiting := season == "winter" or (season == "autumn" and is_instance_valid(seasons) and float(seasons.call("progress")) > 0.7)
	if busy: _run(_slow, SLOW_TICK)
	elif waiting: _run(_slow, IDLE_POLL)
	else: _slow.stop()
	if _active and (not stacks().is_empty() or not piles().is_empty()): _run(_near, NEAR_TICK)
	else:
		_near.stop(); _push_stacks.clear(); set_physics_process(false); _dress.clear()

func _run(timer: Timer, wait: float) -> void:
	if not timer.is_inside_tree(): return
	if not is_equal_approx(timer.wait_time, wait): timer.wait_time = wait; timer.stop()
	if timer.is_stopped(): timer.start()

func _set_active(on: bool) -> void:
	if on == _active: return
	_active = on
	pickup.call("set_enabled", on)
	for stack: Node3D in stacks(): stack.call("set_station", on)
	if not on:
		for stack: Node3D in stacks(): stack.call("stop_rolling")
		for ball in snowballs():
			if str(ball.get("state")) == "resting": ball.call("despawn")

## 4 Hz while snowmen or piles exist: pile kicks, VR dressing, which balls VR hands may push.
func _tick_near() -> void:
	var inventory := ui()
	if inventory == null or not _active: return
	var body: Variant = inventory.get("player_body")
	var camera: Variant = inventory.get("camera")
	if not camera is Node3D or not is_instance_valid(camera): return
	var eye: Vector3 = (camera as Node3D).global_position
	var feet: Vector3 = (body as Node3D).global_position if body is Node3D and is_instance_valid(body) else eye
	var speed := feet.distance_to(_last_player) / NEAR_TICK if _last_player.is_finite() else 0.0
	_last_player = feet
	var desktop := bool(inventory.get("_desktop"))
	var palms: Array[Vector3] = []
	if not desktop:
		for side: String in ["left", "right"]:
			var p := HELD.point(inventory, side)
			if p.is_finite(): palms.append(p)
	var today := int(seasons.call("today")) if is_instance_valid(seasons) and seasons.has_method("today") else 0
	for pile: Node3D in piles():
		if not pile.visible: continue
		var r: float = pile.get("radius")
		var flat := Vector2(feet.x - pile.global_position.x, feet.z - pile.global_position.z).length()
		var kicked := flat < r + 0.2 and speed > PILE_KICK_SPEED and absf(feet.y - pile.global_position.y) < 1.2
		for p in palms:
			if Vector2(p.x - pile.global_position.x, p.z - pile.global_position.z).length() < r * 0.8 and p.y - pile.global_position.y < 0.4: kicked = true
		if kicked: pile.call("burst", today, effects_level())
	if desktop:
		_push_stacks.clear(); set_physics_process(false); return
	_push_stacks.clear()
	for stack: Node3D in stacks():
		if (stack.get("radii") as Array).size() == 1 and stack.global_position.distance_to(eye) < PUSH_RANGE: _push_stacks.append(stack)
	if _push_stacks.is_empty(): _push_last.clear()
	set_physics_process(not _push_stacks.is_empty())
	_tick_dress(inventory)

## VR: a part held to a snowman's face, body or neck for DRESS_SECONDS goes on.
func _tick_dress(inventory: Node) -> void:
	for side: String in ["left", "right"]:
		var part := part_for(HELD.id(inventory, side))
		if part.is_empty(): _dress.erase(side); continue
		var at := HELD.point(inventory, side)
		var found: Node3D = null
		for stack: Node3D in stacks():
			if bool(stack.call("wants", part)) and at.distance_to(stack.call("attach_point", part)) < DRESS_REACH: found = stack; break
		if found == null: _dress.erase(side); continue
		var row: Array = _dress.get(side, [null, "", 0.0])
		row = [found, part, float(row[2]) + NEAR_TICK if row[0] == found and row[1] == part else 0.0]
		_dress[side] = row
		if float(row[2]) >= DRESS_SECONDS:
			_dress.erase(side)
			dress_from_hand(found, inventory, side, part)

## VR pushing: the free hands' palms and velocities go to the lone balls in reach.
func _physics_process(delta: float) -> void:
	var inventory := ui()
	if inventory == null or _push_stacks.is_empty() or delta <= 0.0: set_physics_process(false); return
	var points: Array = []
	var velocities: Array = []
	for side: String in ["left", "right"]:
		if inventory.has_method("hand_busy") and bool(inventory.call("hand_busy", side)): _push_last.erase(side); continue
		var p := HELD.point(inventory, side)
		if not p.is_finite(): _push_last.erase(side); continue
		var last: Vector3 = _push_last.get(side, p)
		_push_last[side] = p
		points.append(p); velocities.append((p - last) / delta)
	if points.is_empty(): return
	for stack: Node3D in _push_stacks.duplicate():
		if is_instance_valid(stack) and str(stack.call("push_by_hands", points, velocities, delta)) == "stacked": _push_stacks.erase(stack)

# ------------------------------------------------------------------ snowballs

## A new snowball at `at`, held by nobody yet (the oldest loose one makes room at the cap).
func spawn_snowball(at: Vector3) -> RigidBody3D:
	var live := snowballs()
	while live.size() >= MAX_SNOWBALLS:
		var oldest: RigidBody3D = null
		for ball in live:
			if str(ball.get("state")) == "held": continue
			var resting := str(ball.get("state")) == "resting"
			var oldest_resting := oldest != null and str(oldest.get("state")) == "resting"
			if oldest == null or (resting and not oldest_resting) or (resting == oldest_resting and float(ball.get("made_at")) < float(oldest.get("made_at"))): oldest = ball
		if oldest == null: return null
		oldest.call("despawn")
		live = snowballs()
	var ball: RigidBody3D = SNOWBALL.new()
	ball.set("play", self)
	world.add_child(ball)
	ball.global_position = at if at.is_finite() else Vector3.ZERO
	_snowballs.append(ball)
	_run(_slow, SLOW_TICK)
	return ball

func _forget_snowball(ball: Node) -> void:
	_snowballs.erase(ball)

func _on_snowball_hit(ball: Node, body: Node, actor: Node, at: Vector3) -> void:
	stamp_trail(at, 0.15)
	snowball_hit.emit(actor if actor != null else body, at, ball.get("thrower") as Node)

## Ponies (W2-SEAS-H): a snowball thrown from `from`; `thrower` never hits itself.
func throw_snowball(from: Vector3, velocity: Vector3, thrower: Node = null) -> RigidBody3D:
	if not _active: return null
	var ball := spawn_snowball(from)
	if ball != null: ball.call("throw", velocity, thrower)
	return ball

# ------------------------------------------------------------------ snowmen

## A hand snowball set down at `at` on snow becomes a ball to roll; null (ball untouched) off snow.
func place_ball(ball: Node, at: Vector3) -> Node3D:
	if not _active or cover_at(at) <= SCOOP_COVER: return null
	if is_instance_valid(ball): ball.call("despawn")
	var stack := new_stack(at, [SNOWMAN.HAND_RADIUS])
	if stack != null: FX.sound(stack, "snow_play_scoop", at)
	return stack

## A stack of balls at `at` (ground point). The cap removes the oldest unfinished stack first.
func new_stack(at: Vector3, radii: Array, by := "player", facing := Vector3.ZERO) -> Node3D:
	while stacks().size() >= MAX_SNOWMEN:
		var victim: Node3D = null
		for stack: Node3D in stacks():
			if victim == null or (not bool(stack.call("complete")) and bool(victim.call("complete"))) \
				or (bool(stack.call("complete")) == bool(victim.call("complete")) and float(stack.get("made_at")) < float(victim.get("made_at"))):
				victim = stack
		_remove_stack(victim)
	var stack: Node3D = SNOWMAN.new()
	_next_id += 1
	stack.set("id", "sm%d_%d" % [Time.get_ticks_msec(), _next_id])
	stack.set("play", self)
	stack.set("by", by)
	var first: Array[float] = [float(radii[0]) if not radii.is_empty() else SNOWMAN.HAND_RADIUS]
	stack.set("radii", first)
	stack.set("rolled", SNOWMAN.rolled_for(first[0]))
	world.add_child(stack)
	stack.global_position = at
	_face(stack, facing)
	for i in range(1, mini(radii.size(), SNOWMAN.MAX_BALLS)): stack.call("add_ball", float(radii[i]))
	stack.call("rebuild")
	stack.call("set_station", _active)
	_stacks.append(stack)
	mark_dirty()
	tick()
	return stack

## Turns a stack's front (+Z) toward `facing`, else toward the player.
func _face(stack: Node3D, facing: Vector3) -> void:
	var toward := facing
	if toward == Vector3.ZERO:
		var inventory := ui()
		var camera: Variant = inventory.get("camera") if inventory != null else null
		if camera is Node3D and is_instance_valid(camera): toward = (camera as Node3D).global_position - stack.global_position
	toward.y = 0.0
	if toward.length() > 0.01: stack.global_rotation = Vector3(0, atan2(toward.x, toward.z), 0)

## Ponies and events: a finished snowman at `at` when there is snow there.
func build_snowman(at: Vector3, facing := Vector3.ZERO, by := "pony") -> Node3D:
	if not _active or cover_at(at) <= SCOOP_COVER: return null
	return new_stack(at, BUILT_RADII, by, facing)

func _stack_merged(from: Node3D, _into: Node3D) -> void:
	_remove_stack(from)
	mark_dirty()

func _on_snowman_complete(stack: Node3D) -> void:
	if stack.is_inside_tree():
		_face(stack, Vector3.ZERO)
		stack.call("rebuild")
		FX.sound(stack, "snow_play_burst", stack.global_position + Vector3.UP)
	snowman_built.emit(stack, str(stack.get("by")))
	mark_dirty()

func _remove_stack(stack: Node3D) -> void:
	if stack == null: return
	_stacks.erase(stack)
	_push_stacks.erase(stack)
	if is_instance_valid(stack):
		stack.call("set_station", false)
		stack.queue_free()

## The snowman part an item makes ("nose", "coal", "arm", "scarf") or "" (snow_items.json).
func part_for(item_id: String) -> String:
	if item_id.is_empty(): return ""
	var map: Dictionary = items().get("snowman_parts", {})
	if map.has(item_id): return str(map[item_id])
	for key: String in map:
		if key.ends_with("*") and item_id.begins_with(key.trim_suffix("*")): return str(map[key])
	return ""

func items() -> Dictionary:
	if _items.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ITEMS_PATH)) if FileAccess.file_exists(ITEMS_PATH) else null
		_items = parsed if parsed is Dictionary else {"snowman_parts": {}}
	return _items

## The held part leaves the hand and the briefcase (one saved transaction) and goes on.
func dress_from_hand(stack: Node3D, inventory: Node, side: String, part: String) -> bool:
	var item_id := HELD.id(inventory, side)
	if part_for(item_id) != part or not bool(stack.call("wants", part)): return false
	if not HELD.use_up(inventory, side): return false
	return bool(stack.call("dress", part, item_id))

# ------------------------------------------------------------------ snow piles

func _refresh_piles(cover: float) -> void:
	if not _active or cover < SCOOP_COVER:
		for key: String in _piles.keys(): _drop_pile(key)
		_pile_from = Vector3.INF
		return
	var inventory := ui()
	var camera: Variant = inventory.get("camera") if inventory != null else null
	if not camera is Node3D or not is_instance_valid(camera) or not is_instance_valid(WorldTerrain.instance): return
	var eye: Vector3 = (camera as Node3D).global_position
	if _pile_from.is_finite() and eye.distance_to(_pile_from) < PILE_REFRESH_MOVE: return
	_pile_from = eye
	var wanted: Dictionary = {}
	var doors: Array = []
	for door: Node in get_tree().get_nodes_in_group("house_doors"):
		if door is Node3D and (door as Node3D).global_position.distance_to(eye) < PILE_RADIUS: doors.append(door)
	doors.sort_custom(func(a: Node3D, b: Node3D) -> bool: return a.global_position.distance_squared_to(eye) < b.global_position.distance_squared_to(eye))
	for door: Node3D in doors:
		if wanted.size() >= MAX_PILES: break
		var spot := eave_spot(door)
		if spot.is_finite(): wanted["%d_%d" % [roundi(spot.x * 2.0), roundi(spot.z * 2.0)]] = spot
	for key: String in _piles.keys():
		if not wanted.has(key): _drop_pile(key)
	for key: String in wanted:
		if not _piles.has(key): add_pile(wanted[key], key)

func _drop_pile(key: String) -> void:
	var pile: Variant = _piles.get(key)
	_piles.erase(key)
	if pile is Node and is_instance_valid(pile): (pile as Node).queue_free()

## Beside an outside door, under the eave: a ground point with snow next to the door frame, or INF.
func eave_spot(door: Node3D) -> Vector3:
	var terrain := WorldTerrain.instance
	if not is_instance_valid(terrain): return Vector3.INF
	var origin := door.global_position
	if not terrain.has_ground(origin) or absf(terrain.height_at(origin) - origin.y) > 1.2: return Vector3.INF
	# hinged_door.gd: the node is the leaf, hinged at the outside-left jamb, +Z out of the house,
	# and swings by its own rotation.y; the closed frame keeps an open door's piles outside.
	var parent := door.get_parent_node_3d()
	var closed := (parent.global_basis if parent != null else Basis.IDENTITY) * Basis.from_euler(Vector3(door.rotation.x, 0.0, door.rotation.z))
	var across := closed.x.normalized(); across.y = 0.0
	var out := closed.z.normalized(); out.y = 0.0
	if across.length() < 0.1 or out.length() < 0.1: return Vector3.INF
	var space := door.get_world_3d().direct_space_state
	# Past the latch side, else beside the hinge; always in front of the wall.
	for side in [1.35, -0.35]:
		var at: Vector3 = origin + across.normalized() * float(side) + out.normalized() * 0.75
		var ground := terrain.height_at(at)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(at.x, ground + 2.4, at.z), Vector3(at.x, ground - 0.5, at.z), 1))
		if not hit.is_empty() and absf((hit.position as Vector3).y - ground) > 0.3: continue
		var spot := Vector3(at.x, ground, at.z)
		if cover_at(spot) > SCOOP_COVER: return spot
	return Vector3.INF

func add_pile(at: Vector3, key := "") -> Node3D:
	if key.is_empty(): key = "%d_%d" % [roundi(at.x * 2.0), roundi(at.z * 2.0)]
	if _piles.has(key): return _piles[key]
	var pile: Node3D = PILE.new()
	pile.set("key", key)
	world.add_child(pile)
	pile.global_position = at
	pile.rotation.y = float(absi(hash(key)) % 628) * 0.01
	_piles[key] = pile
	return pile

# ------------------------------------------------------------------ trail

## Presses the snow trail (WP-B world/seasons/snow_trail.gd, group "snow_trail",
## stamp(xz, strength)) where a ball rolled or burst: one print, a ring of five for a wide ball.
func stamp_trail(at: Vector3, radius: float) -> void:
	if not is_inside_tree() or not at.is_finite(): return
	var trail: Node = get_tree().get_first_node_in_group("snow_trail")
	if trail == null or not trail.has_method("stamp"): return
	var centre := Vector2(at.x, at.z)
	trail.call("stamp", centre, 1.0)
	if radius <= 0.15: return
	for offset: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		trail.call("stamp", centre + offset * radius * 0.6, 0.85)

# ------------------------------------------------------------------ save

func mark_dirty() -> void:
	_save()

func _save() -> void:
	if not is_instance_valid(seasons) or not seasons.has_method("block"): return
	var saved: Dictionary = seasons.call("block")
	if saved.is_empty(): return
	var rows: Array = []
	for stack: Node3D in stacks():
		if stack.is_queued_for_deletion(): continue
		rows.append(stack.call("record"))
	saved[SAVE_KEY] = rows
	seasons.call("mark_changed")

## The saved snowmen (newest MAX_SNOWMEN kept), replacing any in the world.
func restore() -> void:
	for stack: Node3D in stacks().duplicate(): _remove_stack(stack)
	_stacks.clear()
	if not is_instance_valid(seasons) or not seasons.has_method("block"): return
	var saved: Dictionary = seasons.call("block")
	var rows: Variant = saved.get(SAVE_KEY)
	if not rows is Array: return
	var list: Array = (rows as Array).filter(func(r: Variant) -> bool: return r is Dictionary)
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("made", 0.0)) > float(b.get("made", 0.0)))
	for row: Dictionary in list.slice(0, MAX_SNOWMEN):
		var stack: Node3D = SNOWMAN.new()
		stack.set("play", self)
		if not bool(stack.call("apply_record", row)): stack.free(); continue
		world.add_child(stack)
		stack.call("rebuild")
		stack.call("set_station", _active)
		_stacks.append(stack)

func _on_reopened(_world_id: String) -> void:
	_after_reopen.call_deferred()

func _after_reopen() -> void:
	restore()
	tick()
