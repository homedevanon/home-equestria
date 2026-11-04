extends RefCounted
## Local dice and a temporary navigation claim; language is requested only on arrival.
const OWNER := "social:player_greeting"
var rng := RandomNumberGenerator.new()
var clock := 0.0
var next_roll := 90.0
var cooldowns: Dictionary = {}
var id := ""
var nav: Node
var actor: Node3D
var region := ""
var player_start := Vector3.ZERO
var deadline := 0.0
var talking := false
var lingering := false
## dev 2026-09-25: "ponies that come up to anon just walk away after a few seconds without even
## so much as a 'hello?' ... 'anooon?'". After her greeting she waits; if the player has not
## answered after NUDGE_AFTER seconds she tries once more, then says a puzzled goodbye.
const NUDGE_AFTER := 7.0
const GIVE_UP_AFTER := 12.0
const NUDGE := "[Observed situation, not player speech] You walked up to Anon and said something a few seconds ago, but he has not answered or reacted at all. Check whether he is listening, in character: a short 'Hello?', his name, a wave, or a playful poke at him ignoring you. One short sentence; no action tags needed."
const GIVE_UP := "Anon has not answered you at all, even after you tried again. Say a short, slightly puzzled or teasing goodbye in character and head off."
## Knocking (player bug board #31, conversation_director.answer_knock): a pony who is home walks
## out to the player at her door and greets him, no dice and regardless of the approach settings.
const KNOCK := "[Observed situation, not player speech] Anon knocked on your front door and you came out to answer it. He is standing at your door now. Greet him in character and ask what brings him by. One or two short sentences; no action tags needed."
var knocked := false
## Sometimes she walks up with a favour to ask (world/mechanics/asks/asks.gd): only when she has no
## open favour and may ask one now, so her [ask] capability is really there when she arrives.
const FAVOUR_CHANCE := 0.25
const FAVOUR := "[Observed situation, not player speech] You noticed Anon nearby and walked over because you would like to ask him a small favour, something you really need today. You have now reached him. Greet him and ask it in your own words, in character, and add [ask: WANT, REWARD]. One or two short sentences."
var knock_goal := Vector3.INF
var nudged := false
var said_at := 0.0   # director clock when her last line finished
var previous: Dictionary = {}
var _tick := 0.0

func _init() -> void: rng.randomize()
func active() -> bool: return not id.is_empty()

func player_region(player: Node3D) -> String:
	return str(WorldLayout.nearest(player.global_position).get("id", ""))

func nearby(d: Node, pony: Node3D, radius: float, required_region: String) -> bool:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or not pony.is_visible_in_tree(): return false
	if not is_instance_valid(d.player_head) or not d.player_head.is_inside_tree(): return false
	if pony.has_method("action_interruption_reason") and pony.action_interruption_reason() != "": return false
	if pony.has_method("is_held") and pony.is_held(): return false
	var flight: Variant = pony.get("flight")
	if flight != null and flight.active(): return false
	var offset: Vector3 = pony.global_position - d.player_head.global_position
	if offset.length() > radius or absf(offset.y) > 3.0: return false
	var here := str(pony.get_meta("navigation_region", WorldLayout.nearest(pony.global_position).get("id", "")))
	return not required_region.is_empty() and here == required_region

## Ponies who walk over to needle him rather than to chat (thread 43671981: Diamond Tiara ran
## across town to insult him every day) come over unprompted at most once every SOUR_DAYS game
## days, at a walk. That covers the schoolyard snobs, any pony whose friendship with him is
## negative or whose last impression of him was annoyed or angry, and any character file with
## "player_approach_days" (its value wins; 0 turns the limit off).
const SNOBS := ["diamond_tiara", "silver_spoon"]
const SOUR_DAYS := 3
const SOUR_MOODS := ["annoyed", "angry"]

## Game days she must leave between unprompted approaches; 0 = only the ordinary cooldowns.
static func sour_days(d: Node, who: String) -> int:
	var entry: Dictionary = d.characters.get(who, {})
	var profile: Dictionary = entry.get("profile", {}) if entry.get("profile") is Dictionary else {}
	if profile.has("player_approach_days"): return maxi(0, int(profile.player_approach_days))
	if who in SNOBS: return SOUR_DAYS
	var context: Node = d.get("world_context")
	var impressions: Node = context.get("impressions") if is_instance_valid(context) else null
	if not is_instance_valid(impressions): return 0
	var core: Node = impressions.get("core")
	if is_instance_valid(core) and int(core.call("get_score", who, "friendship")) < 0: return SOUR_DAYS
	var note: Variant = (impressions.get("notes") as Dictionary).get(who, {}) if impressions.get("notes") is Dictionary else {}
	if note is Dictionary and str((note as Dictionary).get("mood", "")) in SOUR_MOODS: return SOUR_DAYS
	return 0

static func _game_day(d: Node) -> int:
	var clock: Node = d.get_node_or_null("/root/TimeOfDay") if d.is_inside_tree() else null
	return int(clock.day) if clock != null else 0

## The game day of her last unprompted approach (kept in the world, so a reload does not send her
## again), or a large negative number.
static func last_sour_day(d: Node, who: String) -> int:
	var context: Node = d.get("world_context")
	if not is_instance_valid(context) or not context.get("state") is Dictionary: return -1000000
	var record: Dictionary = (context.state as Dictionary).get("player_approaches", {})
	return int((record.get("last_day", {}) as Dictionary).get(who, -1000000))

static func _mark_sour_day(d: Node, who: String) -> void:
	var context: Node = d.get("world_context")
	if not is_instance_valid(context) or context.get("_read_only") == true or not context.get("state") is Dictionary: return
	var record: Dictionary = (context.state as Dictionary).get("player_approaches", {})
	var days: Dictionary = record.get("last_day", {})
	days[who] = _game_day(d)
	record["last_day"] = days
	context.state["player_approaches"] = record
	if context.has_method("_changed"): context.call("_changed")

## True while her SOUR_DAYS wait since her last unprompted approach is still running.
static func sour_blocked(d: Node, who: String) -> bool:
	var days := sour_days(d, who)
	return days > 0 and _game_day(d) - last_sour_day(d, who) < days

func eligible(d: Node, who: String, here: String, radius: float) -> bool:
	var pony: Node3D = d.characters[who].node
	if clock < float(cooldowns.get(who, 0.0)) or not nearby(d, pony, radius, here): return false
	if sour_blocked(d, who): return false
	if pony.has_method("is_speaking") and pony.is_speaking(): return false
	if preload("res://world/ai/pony_ambient_chatter.gd").hushed(pony): return false
	if d._now() - float(d.characters[who].get("chat_last", -1e9)) < 120.0: return false
	var company: Dictionary = pony.get_meta("social_group", {})
	if company.get("members", []).size() > 1 or str(company.get("id", "")).begins_with("rail:"): return false
	var navigator := pony.get_node_or_null("Navigator")
	return navigator != null and not is_instance_valid(navigator.get("_follow_target")) and (navigator.command_owner.is_empty() or navigator.command_owner.begins_with("life:"))

func tick(d: Node, delta: float) -> void:
	clock += delta; _tick -= delta
	if _tick > 0: return
	_tick = .5
	if knocked and active():
		advance(d); return
	if not bool(d.config.get_value("player_approaches/enabled", true)) or not preload("res://world/ai/ai_config.gd").background_allowed(d.config):
		end(d); return
	if active():
		advance(d); return
	if clock < next_roll: return
	if d.state != "idle" or d.group.active() or d.speech.state == "hearing" or not d.ambient_budget.available(): return
	if not is_instance_valid(d.player_head) or not d.player_head.is_inside_tree(): return
	# Give an existing player conversation room, even between its spoken turns.
	for entry in d.characters.values():
		if d._now() - float(entry.get("chat_last", -1e9)) < 45.0: return
	next_roll = clock + 30.0 # Never replay missed rolls after a hitch.
	if rng.randf() >= clampf(float(d.config.get_value("player_approaches/chance", .2)), 0, 1): return
	var here := player_region(d.player_head)
	var radius := clampf(float(d.config.get_value("player_approaches/radius_m", 24.0)), 3, 40)
	var candidates: Array[String] = []
	for who: String in d.characters:
		if eligible(d, who, here, radius): candidates.append(who)
	# One pony wins the opportunity, independent of population density.
	if candidates.is_empty(): return
	var who: String = candidates[rng.randi_range(0, candidates.size()-1)]
	var pony: Node3D = d.characters[who].node
	var navigator: Node = pony.get_node("Navigator")
	if not navigator.command_target_visible(d.player_head): return
	var toward: Vector3 = pony.global_position - d.player_head.global_position; toward.y = 0
	if toward.length() < .1: return
	var goal: Vector3 = navigator.command_support(d.player_head.global_position + toward.normalized()*2.0)
	if not goal.is_finite() or absf(goal.y - pony.global_position.y) > 3.0: return
	id = who; actor = pony; nav = navigator; region = here; player_start = d.player_head.global_position
	previous = {"owner":nav.command_owner,"wander":nav.wander_enabled,"limit":nav.command_speed_limit,"pace":nav.command_pace_target}
	cooldowns[id] = clock + maxf(60, float(d.config.get_value("player_approaches/pony_cooldown_seconds", 900)))
	next_roll = clock + maxf(30, float(d.config.get_value("player_approaches/cooldown_seconds", 120)))
	deadline = clock + 35.0; talking = false
	nav.command_owner = OWNER; nav.wander_enabled = false
	nav.command_speed_limit = INF; nav.command_pace_target = -1.0
	if pony.has_method("request_posture"): pony.request_posture("stand")
	var sour := sour_days(d, who) > 0
	if sour: _mark_sour_day(d, who)
	if not nav.command_destination(goal, "walk" if sour else "trot"): cancel()

## Navigator owners a knock may take her from: wandering, the living world, outings, chat stops,
## lounging on her couch. A story, an errand, bedtime or anything else the player or a system started keeps her.
const KNOCK_FREE_OWNERS := ["life:", "social:", "chat:", "leisure:couch:"]

static func can_answer_knock(pony: Node3D) -> bool:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or pony.get("sleeping") == true: return false
	if pony.has_method("is_held") and pony.is_held(): return false
	var navigator: Node = pony.get_node_or_null("Navigator")
	if navigator == null: return false
	var owner := str(navigator.command_owner)
	if owner.is_empty(): return true
	for prefix: String in KNOCK_FREE_OWNERS:
		if owner.begins_with(prefix): return true
	return false

## The free pony inside `home` nearest its door, or null when nopony is home to answer.
static func knock_answerer(door: Node3D, home: Node3D, candidates: Array) -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for pony: Variant in candidates:
		if not (pony is Node3D) or not can_answer_knock(pony) or not home.contains((pony as Node3D).global_position, true): continue
		var distance := (pony as Node3D).global_position.distance_to(door.global_position)
		if distance < best_distance: best = pony; best_distance = distance
	return best

## Where she stands: just outside her door, up to a step toward the player but never closer than
## about 1.4 m to him.
static func knock_spot(home: Node3D, navigator: Node, player: Vector3) -> Vector3:
	var outside: Vector3 = home.outside()
	var toward := player - outside
	toward.y = 0.0
	# A player on the doorstep: she steps out beside him instead of into him.
	if toward.length() < 1.4:
		var side := toward.cross(Vector3.UP).normalized() if toward.length() > 0.05 else Vector3.RIGHT
		return navigator.command_support(outside + side * sqrt(1.96 - toward.length_squared()))
	return navigator.command_support(outside + toward.limit_length(clampf(toward.length() - 1.4, 0.0, 1.0)))

## She walks out of her house to the player standing at its door.
func answer_knock(d: Node, who: String, home: Node3D) -> bool:
	var pony: Node3D = d.characters[who].node
	var navigator: Node = pony.get_node("Navigator")
	if active(): cancel()
	var goal: Vector3 = knock_spot(home, navigator, d.player_head.global_position)
	if not goal.is_finite(): return false
	id = who; actor = pony; nav = navigator; region = player_region(d.player_head); player_start = d.player_head.global_position
	previous = {"owner":nav.command_owner,"wander":nav.wander_enabled,"limit":nav.command_speed_limit,"pace":nav.command_pace_target}
	deadline = clock + 75.0; talking = false; knocked = true; knock_goal = goal
	nav.command_owner = OWNER; nav.wander_enabled = false
	nav.command_speed_limit = INF; nav.command_pace_target = -1.0
	if pony.has_method("request_posture"): pony.request_posture("stand")
	if not nav.command_destination(goal, "walk"): cancel(); return false
	print("[knock] %s comes to the door" % who)
	return true

func advance(d: Node) -> void:
	# Answering a knock she starts indoors, maybe in another navigation region than the porch.
	var near: bool = knocked and is_instance_valid(actor) and actor.is_inside_tree() and is_instance_valid(d.player_head) \
		and actor.global_position.distance_to(d.player_head.global_position) < 40.0
	if not d.characters.has(id) or not is_instance_valid(d.player_head) or not (near or nearby(d, actor, 28.0, region)):
		end(d); return
	if (not knocked and player_region(d.player_head) != region) or d.player_head.global_position.distance_to(player_start) > (8.0 if knocked else 5.0):
		end(d); return
	if lingering:
		# The player answered (or is answering): hand her to the conversation; engaged() keeps her.
		var answered: bool = float(d.characters[id].get("chat_last", -1e9)) > said_at + 0.5 \
			or d.speech.state == "hearing" or (d.state != "idle" and d._current == id and not d._proactive_turn)
		if answered: cancel(); return
		if d.state != "idle": return
		var quiet: float = d._now() - said_at
		if not nudged and quiet >= NUDGE_AFTER:
			nudged = true; lingering = false; talking = true
			if not d.begin_player_greeting(id, NUDGE): cancel()
			return
		if nudged and quiet >= GIVE_UP_AFTER:
			var who := id
			cancel()
			d.request_farewell(who, GIVE_UP)
			return
		if clock >= deadline: cancel()
		return
	if talking:
		if not d._proactive_turn or d.state == "idle": cancel()
		return
	if not is_instance_valid(nav) or nav.command_owner != OWNER or clock > deadline or d.state != "idle" or d.speech.state == "hearing":
		cancel(); return
	# Answering a knock she may first get up from lying down, which interrupts the walk: resume it.
	if knocked and nav.state in [nav.State.INTERRUPTED, nav.State.IDLE] and actor.global_position.distance_to(knock_goal) > 1.0:
		if nav.state == nav.State.IDLE and nav.get("_has_target") != true: nav.command_destination(knock_goal, "walk")
		return
	# State alone is not arrival: wait for actual proximity and unobstructed hearing.
	if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED, nav.State.INTERRUPTED]: cancel(); return
	var offset: Vector3 = actor.global_position - d.player_head.global_position
	if Vector2(offset.x, offset.z).length() > 2.8: return
	if not d.awareness.can_hear(actor, d.player_head, 4.0): cancel(); return
	nav.stay(); talking = true
	if not d.begin_player_greeting(id, KNOCK if knocked else _favour(d)): cancel()

## The favour greeting, or "" for the ordinary one (a quarter of the time when she may ask).
func _favour(d: Node) -> String:
	if rng.randf() >= FAVOUR_CHANCE or not d.is_inside_tree() or d._encounter_claimed(id): return ""
	var asks: Node = d.get_tree().get_first_node_in_group("mechanics_asks")
	return FAVOUR if asks != null and str(asks.call("can_ask", id)).is_empty() else ""

func finished(d: Node = null) -> void:
	if not active(): return
	talking = false; lingering = true; deadline = clock + 30.0
	said_at = d._now() if d != null else 0.0

func end(d: Node) -> void:
	if talking and d._proactive_turn and not d.speech_committed(): d.interrupt()
	cancel()

func cancel() -> void:
	if is_instance_valid(nav) and nav.command_owner == OWNER:
		nav.stay(); nav.command_owner = previous.owner; nav.wander_enabled = previous.wander
		nav.command_speed_limit = previous.limit; nav.command_pace_target = previous.pace
	id = ""; actor = null; nav = null; talking = false; lingering = false; nudged = false; knocked = false; previous.clear()
