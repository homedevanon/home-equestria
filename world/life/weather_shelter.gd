extends Node
## Rain shelter (M-SEA-07, hazard H1; moved out of weather.gd 2026-11-08). Weather only publishes
## whether it is wet or cold (weather.gd conditions_changed / is_wet / is_cold / is_snowing); this
## life owner decides who goes indoors, the way night_rest.gd decides bedtime.
## - Heavy rain, hail or a blizzard: most residents with a home trot home (the same hashed 72% as
##   before; pegasi, who run the weather, carry on) and stay in until it clears.
## - A chat comes first (board #366, "Bedtime and rain shelter wait for chats"): while the director
##   holds her in place she is let go, and the walk home is tried again RETRY_SECONDS later. A
##   pony who is picked up is let go the same way. An unreachable home is retried once after the
##   same pause, then given up for this wet spell, with the reason logged.
## - Light snow sends nopony home: some free ponies go out to play in it instead (a day-plan step
##   seasonal/snow_play injected through day_runner.inject_now, where she stands).
## Decisions run when the weather flips and then on a 3 s timer only while it is wet or somepony
## is still sheltering; nothing runs on a dry day.
const OWNER := "weather:"
const CHECK_SECONDS := 3.0
## night_rest.gd RETRY_SECONDS: between tries she stands still instead of replanning.
const RETRY_SECONDS := 20.0
const MAX_TRIES := 2
## Share (percent) of residents with a home who go in when it pours.
const GO_HOME_SHARE := 72
## Share (percent) of free ponies who go out to play when light snow starts in the daytime.
const SNOW_PLAY_SHARE := 30
const SNOW_PLAY_HOURS := Vector2(8.0, 17.0)
const SNOW_PLAY_STEP := {"action": "snow_play", "handler": "seasonal/snow_play", "target": "",
	"phrase": "play in the snow", "reason": "because it's snowing", "minutes": 30.0, "hours": 1.0}

var game: Node
var weather: Node
var wet := false
var cold := false
var snowing := false
## Counts wet spells, so a different share of ponies goes in each time.
var spell := 0
## id -> {"phase": "going"|"home"|"paused"|"done", "tries": int, "retry_at": seconds}
var entries := {}
## id -> spell number she was last sent out to play in.
var _played := {}
var _snow_spell := 0
var _timer: Timer
## Clock override for tests (seconds); < 0 uses the engine clock.
var now_override := -1.0

func setup(host: Node, source: Node = null) -> void:
	game = host
	add_to_group("weather_shelter")
	weather = source if source != null else host.get_node_or_null("Weather")
	_timer = Timer.new(); _timer.name = "Check"; _timer.wait_time = CHECK_SECONDS; _timer.one_shot = false
	_timer.timeout.connect(decide)
	add_child(_timer)
	if weather != null and weather.has_signal("conditions_changed"):
		weather.conditions_changed.connect(_on_conditions)
		_on_conditions(bool(weather.call("is_wet")), bool(weather.call("is_cold")))

func _now() -> float:
	return now_override if now_override >= 0.0 else Time.get_ticks_msec() * .001

func _population() -> Node:
	var population: Variant = game.get("population") if game != null else null
	return population if population is Node and is_instance_valid(population) and "live" in population else null

func _on_conditions(is_wet: bool, is_cold: bool) -> void:
	if is_wet and not wet: spell += 1
	wet = is_wet; cold = is_cold
	var was_snowing := snowing
	snowing = weather != null and weather.has_method("is_snowing") and bool(weather.call("is_snowing"))
	if snowing and not was_snowing: _snow_spell += 1
	decide()
	if snowing and not wet and not was_snowing: send_out_to_play()

## One pass over the loaded residents. Called on a flip and every CHECK_SECONDS while active.
func decide() -> void:
	var population := _population()
	if population == null: return
	for id: String in population.live.keys():
		var actor: Node3D = population.live[id].get("actor")
		if not is_instance_valid(actor) or not actor.is_inside_tree(): continue
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav == null: continue
		var entry: Dictionary = entries.get(id, {})
		if wet:
			if entry.is_empty(): _maybe_go(id, actor, nav, population, {})
			else: _keep(id, actor, nav, population, entry)
		elif not entry.is_empty():
			_release(id, nav)
	if not wet:
		# Dry: everypony still listed (streamed out meanwhile) is forgotten.
		entries.clear()
	for id: String in entries.keys():
		if not population.live.has(id): entries.erase(id)
	if _timer != null and _timer.is_inside_tree():
		var active := wet or not entries.is_empty()
		if active and _timer.is_stopped(): _timer.start()
		elif not active and not _timer.is_stopped(): _timer.stop()

func _talking(id: String) -> bool:
	var director: Variant = game.get("director") if game != null else null
	return is_instance_valid(director) and director is Node and (director as Node).has_method("holds_in_place") \
		and bool((director as Node).call("holds_in_place", id))

static func _held(actor: Node3D) -> bool:
	return bool(actor.get("_held")) or (actor.get("hoof_hold") != null and actor.hoof_hold.active())

## Routine owners give way to the rain; player and AI commands, day steps and bedtime do not.
static func _free_owner(owner: String) -> bool:
	return owner.is_empty() or owner.begins_with("life:") or owner.begins_with("social:")

func _maybe_go(id: String, actor: Node3D, nav: Node, population: Node, entry: Dictionary) -> void:
	# Most go home; a few (and pegasi, who run the weather) carry on.
	if entry.is_empty() and absi(hash(id + ":" + str(spell))) % 100 >= GO_HOME_SHARE: return
	if actor.get("identity") != null and actor.identity.has_method("has_wings") and actor.identity.has_wings(): return
	if not _free_owner(str(nav.command_owner)): return
	if _held(actor) or actor.get("sleeping") or _talking(id): return
	var house: Node3D = population.home_house(id) if population.has_method("home_house") else null
	if house == null: return
	if house.contains(actor.global_position):
		if not entry.is_empty(): entry.phase = "done"   # got in by herself while paused
		return
	nav.stay(); nav.command_owner = OWNER + id
	nav.go_to(house.inside(), nav.Gait.TROT)
	nav.command_owner = OWNER + id
	entry.phase = "going"
	entry.tries = int(entry.get("tries", 0))
	entries[id] = entry

func _keep(id: String, actor: Node3D, nav: Node, population: Node, entry: Dictionary) -> void:
	var owned := str(nav.command_owner) == OWNER + id
	match str(entry.phase):
		"going", "home":
			if not owned:
				# Bedtime, the player or an AI command took her: theirs now, for this spell.
				entry.phase = "done"
				return
			if entry.phase == "going" and (_talking(id) or _held(actor)):
				_pause(id, nav, entry, "chat" if _talking(id) else "held")
				return
			if entry.phase == "going" and nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				entry.tries = int(entry.tries) + 1
				if int(entry.tries) >= MAX_TRIES:
					nav.stay(); nav.command_owner = ""
					entry.phase = "done"
					print("[shelter] %s: home unreachable twice, staying out this spell" % id)
				else: _pause(id, nav, entry, "home unreachable")
				return
			var house: Node3D = population.home_house(id) if population.has_method("home_house") else null
			if entry.phase == "going" and house != null and house.contains(actor.global_position): entry.phase = "home"
		"paused":
			if _now() < float(entry.retry_at): return
			_maybe_go(id, actor, nav, population, entry)
			if str(entry.phase) == "paused": entry.retry_at = _now() + RETRY_SECONDS

func _pause(id: String, nav: Node, entry: Dictionary, reason: String) -> void:
	nav.stay(); nav.command_owner = ""
	entry.phase = "paused"
	entry.retry_at = _now() + RETRY_SECONDS
	print("[shelter] %s: walk home paused (%s), retry in %.0f s" % [id, reason, RETRY_SECONDS])

func _release(id: String, nav: Node) -> void:
	if str(nav.command_owner).begins_with(OWNER):
		nav.stay(); nav.command_owner = ""
	entries.erase(id)

## Light snow in the daytime: some free ponies with no plan step running go out and play where they
## are. Once per snow spell each; never in the wet, at night, or without the day runner.
func send_out_to_play() -> int:
	var population := _population()
	var tree := get_tree() if is_inside_tree() else null
	var runner: Node = tree.get_first_node_in_group("day_runner") if tree != null else null
	if population == null or runner == null or not runner.has_method("inject_now"): return 0
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var hours: float = float(clock.get("hours")) if clock != null else 12.0
	if hours < SNOW_PLAY_HOURS.x or hours > SNOW_PLAY_HOURS.y: return 0
	var sent := 0
	var cards: Variant = runner.get("cards")
	for id: String in population.live.keys():
		if int(_played.get(id, -1)) == _snow_spell: continue
		if absi(hash(id + ":snow:" + str(_snow_spell))) % 100 >= SNOW_PLAY_SHARE: continue
		if cards is Dictionary and (cards as Dictionary).get(id, {}).get("action") != null: continue
		var actor: Node3D = population.live[id].get("actor")
		if not is_instance_valid(actor) or _talking(id): continue
		if runner.has_method("can_inject") and not bool(runner.call("can_inject", id, true)): continue
		if bool(runner.call("inject_now", id, SNOW_PLAY_STEP.duplicate(true))):
			_played[id] = _snow_spell
			sent += 1
	if sent > 0: print("[shelter] light snow: %d ponies went out to play" % sent)
	return sent
