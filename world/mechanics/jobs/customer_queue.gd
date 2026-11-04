extends RefCounted
## The shared customer lease (P4 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 7.3): every
## job that borrows a living resident (a Hayburger customer, a spa client, Applejack collecting
## apples, a cider stand customer) takes her navigator the same way and gives it back the same way.
## claim() saves the four navigation fields (plus any extra ones the venue names), takes the command
## owner and sets the lease metas; release() restores exactly what was saved, removes only the metas
## this lease still owns, makes the living world reissue her goal and starts her cooldown.
## Venue-specific routing, seating and eligibility stay with the venue; eligible() is the generic
## union of the Hayburger checks for jobs without their own (the cider stand).
const OWNERSHIP := preload("res://world/characters/navigation/navigator_ownership.gd")
## Model reply tags that only move her a step or change her pose (pony_action_executor.gd). Said
## by a customer while Anon chats with her, they took her navigator and the venue read that as her
## leaving: the order was cancelled and the ticket gone (board #307, thread 2026-11-01). Trips away
## ([follow], [lead], [go_to], [go_home]) still end a visit, as a player takeover does.
const IN_PLACE_TAGS: Array[String] = ["approach", "stay", "step", "sit", "stand", "lie_down", "sit_on_seat"]

var owner_prefix := ""      # e.g. "leisure:hayburger:%d:" % iid; the full owner is prefix + pony id
var max_customers := 3
var cooldown_s := 45.0
var radius := 180.0
var exclude: PackedStringArray = []
## id -> {"owner", "actor", "nav", "previous": {owner, wander, speed, pace, <extra fields>}, "metas", "nav_metas", "gate", "clear", "since"}
var claimed: Dictionary = {}
## id -> clock value until which she is not asked again. A venue may share its own dictionary.
var cooldowns: Dictionary = {}
## Seconds on the queue's own clock (tick()); a venue with its own clock assigns it.
var clock := 0.0
var population: Node
var life: Node
## Optional: Callable(actor) -> bool, true while she is talking with Anon (game._population_busy).
var busy_check: Callable

func setup(population_node: Node, life_node: Node, spec: Dictionary) -> void:
	population = population_node
	life = life_node
	max_customers = int(spec.get("max", max_customers)) if spec.get("max") is int or spec.get("max") is float else max_customers
	if spec.get("cooldown_s") is int or spec.get("cooldown_s") is float: cooldown_s = float(spec.cooldown_s)
	if spec.get("radius") is int or spec.get("radius") is float: radius = float(spec.radius)
	if spec.get("owner_prefix") is String: owner_prefix = str(spec.owner_prefix)
	var listed: Variant = spec.get("exclude")
	if listed is Array:
		for id: Variant in listed: exclude.append(str(id))

func tick(delta: float) -> void:
	clock += maxf(delta, 0.0)

func owner_for(id: String) -> String:
	return owner_prefix + id

func owns(id: String) -> bool:
	var lease: Variant = claimed.get(id)
	if not lease is Dictionary: return false
	var nav: Variant = (lease as Dictionary).get("nav")
	return is_instance_valid(nav) and str((nav as Node).get("command_owner")) == str((lease as Dictionary).owner)

## "" when she may be asked now, else why not. The union of hayburger_customers._eligibility_reason:
## a free life:/social: lease or a wandering unowned navigator (never day:/leisure:/show:/visit:),
## not flying, held, asleep, following, talking, in a group outing or a group activity, life not
## paused, not excluded, not cooled down, within `radius` of `at` when given.
func eligible(id: String, actor: Node3D, at := Vector3.INF) -> String:
	if claimed.has(id): return "already visiting"
	if id in exclude: return "excluded"
	if float(cooldowns.get(id, -INF)) > clock: return "cooldown"
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return "gone"
	if actor.get("sleeping") == true or actor.get("motion_paused") == true: return "interaction, sleep or unsupported"
	if bool(actor.get_meta("active_follow", false)) or bool(actor.get_meta("seating", false)): return "interaction, sleep or unsupported"
	if actor.has_method("is_held") and bool(actor.call("is_held")): return "interaction, sleep or unsupported"
	if actor.has_method("action_interruption_reason") and not str(actor.call("action_interruption_reason")).is_empty(): return "interaction, sleep or unsupported"
	if busy_check.is_valid() and bool(busy_check.call(actor)): return "interaction, sleep or unsupported"
	if is_instance_valid(actor.get("conversation_target")): return "interaction, sleep or unsupported"
	if not actor.global_position.is_finite(): return "unsupported body"
	if at.is_finite() and actor.global_position.distance_to(at) > radius: return "outside visit radius"
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or is_instance_valid(nav.get("_follow_target")) or is_instance_valid(nav.get("_conversation_target")): return "interaction, sleep or unsupported"
	var owner := str(nav.get("command_owner"))
	if not (owner.is_empty() or owner == "life:" + id or owner == "social:" + id): return "owned by " + owner.get_slice(":", 0)
	var flight: Variant = actor.get("flight")
	if is_instance_valid(flight) and (flight as Object).has_method("active") and bool((flight as Object).call("active")): return "flying"
	if actor.has_meta("social_group"):
		var group: Variant = actor.get_meta("social_group")
		if group is Dictionary and ((group as Dictionary).get("members", []) as Array).size() > 1: return "group outing"
	if owner.is_empty() and (not bool(nav.get("wander_enabled")) or (nav.get("_has_target") == true and nav.get("_wandering") != true)): return "unowned player command"
	if is_instance_valid(life) and life.get("core") != null:
		var core_state: Variant = (life.get("core") as Object).get("state")
		if core_state is Dictionary:
			var residents: Variant = (core_state as Dictionary).get("residents")
			var resident: Dictionary = (residents as Dictionary).get(id, {}) if residents is Dictionary else {}
			if bool(resident.get("paused", false)): return "living world paused"
			var activities: Variant = (core_state as Dictionary).get("activities")
			var activity: Variant = (activities as Dictionary).get(str(resident.get("activity", ""))) if activities is Dictionary else null
			if activity is Dictionary and ((activity as Dictionary).get("members", []) as Array).size() > 1: return "group activity"
	if not nav.has_method("command_destination"): return "navigation unavailable"
	return ""

## Up to `limit` eligible live residents, nearest to `at` first (empty while the queue is full).
func candidates(at: Vector3, limit: int) -> Array[String]:
	var found: Array[String] = []
	if not is_instance_valid(population) or claimed.size() >= max_customers: return found
	var live: Variant = population.get("live")
	if not live is Dictionary: return found
	var rows: Array = []
	for id: Variant in (live as Dictionary).keys():
		var resident: Variant = (live as Dictionary)[id]
		var actor: Node3D = (resident as Dictionary).get("actor") as Node3D if resident is Dictionary else null
		if not eligible(str(id), actor, at).is_empty(): continue
		rows.append([actor.global_position.distance_squared_to(at) if at.is_finite() else 0.0, str(id)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for row: Array in rows.slice(0, maxi(limit, 0)): found.append(str(row[1]))
	return found

## Takes her navigator for one visit: saves owner/wander_enabled/command_speed_limit/
## command_pace_target (plus opts.fields, e.g. ["face_point", "arrival_distance"]), stays, takes the
## owner (refused when the navigator does not accept it), sets speed INF and pace -1 and the metas
## (actor metas from `metas`, navigator metas from opts.nav_metas). opts (all optional):
##   owner: String     the full owner (default owner_prefix + id)
##   wander: bool      also set wander_enabled (the spa turns it off; the Hayburger leaves it)
##   fields: Array     extra navigator fields to save and restore
##   gate: String      actor meta whose value is the owner: on release the actor metas go only
##                     while it still names this lease (the spa's "spa_visit")
##   clear: Array      more actor metas removed with the gate (the spa's "spa_company")
func claim(id: String, actor: Node3D, metas: Dictionary, opts := {}) -> bool:
	if not is_instance_valid(actor): return false
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return false
	var owner := str(opts.get("owner", owner_for(id)))
	var previous := {"owner": nav.get("command_owner"), "wander": nav.get("wander_enabled"),
		"speed": nav.get("command_speed_limit"), "pace": nav.get("command_pace_target")}
	var fields: Variant = opts.get("fields", [])
	if fields is Array:
		for field: Variant in fields: previous[str(field)] = nav.get(str(field))
	nav.call("stay")
	nav.set("command_owner", owner)
	if str(nav.get("command_owner")) != owner: return false
	if opts.get("wander") is bool: nav.set("wander_enabled", bool(opts.wander))
	nav.set("command_speed_limit", INF)
	nav.set("command_pace_target", -1.0)
	var nav_metas: Dictionary = opts.get("nav_metas", {}) if opts.get("nav_metas") is Dictionary else {}
	for key: String in nav_metas: nav.set_meta(key, nav_metas[key])
	for key: String in metas: actor.set_meta(key, metas[key])
	claimed[id] = {"owner": owner, "actor": actor, "nav": nav, "previous": previous, "metas": metas.duplicate(),
		"nav_metas": nav_metas.duplicate(), "gate": str(opts.get("gate", "")), "clear": opts.get("clear", []) if opts.get("clear") is Array else [],
		"since": clock}
	return true

## A visit's navigator taken by one of her own in-place reply tags (IN_PLACE_TAGS, or the executor's
## "rest_after_command" left after one) is taken back for `owner`: she stops where she is and the
## venue re-issues its leg. The executor then sees another owner and tells the model the tag was
## cancelled. True when it took the navigator back. Static: the venues' `-- --old-jobs` copies use it too.
static func reclaim_from_model(nav: Node, owner: String) -> bool:
	if not is_instance_valid(nav) or owner.is_empty(): return false
	var current := str(nav.get("command_owner"))
	if current == owner: return false
	var tag := current.get_slice("-", 2) if OWNERSHIP.AI_TAG_ID.search(current) != null else ""
	if current != "rest_after_command" and tag not in IN_PLACE_TAGS: return false
	nav.call("stay")
	nav.set("command_owner", owner)
	if str(nav.get("command_owner")) != owner: return false
	nav.set("command_speed_limit", INF)
	nav.set("command_pace_target", -1.0)
	return true

## The saved navigation fields of a lease ({} when not claimed).
func previous(id: String) -> Dictionary:
	var lease: Variant = claimed.get(id)
	return ((lease as Dictionary).previous as Dictionary).duplicate() if lease is Dictionary else {}

## Ends the lease: while it still owns the navigator (or `owned` says so), stays and restores the
## saved fields and makes the living world reissue her goal (life.actors[id].goal = Vector3.INF);
## removes the metas this lease set that still hold its values; starts the cooldown
## (`cooldown` seconds, default cooldown_s; negative = none). Returns whether it restored.
func release(id: String, _reason: String, cooldown := INF, owned: Variant = null) -> bool:
	var lease: Variant = claimed.get(id)
	if not lease is Dictionary: return false
	claimed.erase(id)
	var row: Dictionary = lease
	var nav: Node = row.nav as Node if is_instance_valid(row.get("nav")) else null
	var actor: Node3D = row.actor as Node3D if is_instance_valid(row.get("actor")) else null
	var restored := false
	var mine: bool = bool(owned) if owned is bool else (nav != null and actor != null and str(nav.get("command_owner")) == str(row.owner))
	if mine and nav != null:
		nav.call("stay")
		var saved: Dictionary = row.previous
		nav.set("command_owner", saved.owner)
		nav.set("wander_enabled", saved.wander)
		nav.set("command_speed_limit", saved.speed)
		nav.set("command_pace_target", saved.pace)
		for field: String in saved:
			if field in ["owner", "wander", "speed", "pace"]: continue
			nav.set(field, saved[field])
		_reissue_goal(id)
		restored = true
	if actor != null:
		var gate: String = row.gate
		if gate.is_empty():
			for key: String in row.metas:
				if actor.has_meta(key) and actor.get_meta(key) == row.metas[key]: actor.remove_meta(key)
		elif actor.has_meta(gate) and actor.get_meta(gate) == row.owner:
			for key: String in row.metas:
				if actor.has_meta(key): actor.remove_meta(key)
			for key: Variant in row.clear:
				if actor.has_meta(str(key)): actor.remove_meta(str(key))
	if nav != null:
		for key: String in row.nav_metas:
			if nav.has_meta(key) and nav.get_meta(key) == row.nav_metas[key]: nav.remove_meta(key)
	var wait: float = cooldown_s if cooldown == INF else cooldown
	if wait >= 0.0: cooldowns[id] = clock + wait
	return restored

func release_all(reason: String) -> void:
	for id: String in claimed.keys(): release(id, reason)

## The living world caches each pony's goal; clearing it makes it reissue her paused outing's route.
func _reissue_goal(id: String) -> void:
	if not is_instance_valid(life): return
	var actors: Variant = life.get("actors")
	if actors is Dictionary and (actors as Dictionary).has(id):
		var entry: Variant = (actors as Dictionary)[id]
		if entry is Object: (entry as Object).set("goal", Vector3.INF)
		elif entry is Dictionary: (entry as Dictionary)["goal"] = Vector3.INF
