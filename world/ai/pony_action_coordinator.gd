extends Node
## Registration, advertised capabilities and revalidation at the moment of dispatch.
const EXECUTOR := preload("res://world/ai/pony_action_executor.gd")
const SCHEMA := preload("res://world/ai/pony_action_schema.gd")
const AWARENESS := preload("res://world/ai/pony_awareness.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const BITS := preload("res://world/ai/bit_payments.gd")
const MECHANICS := preload("res://world/mechanics/mechanics.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
## Model-requested trips whose failure she tells Anon about (dev 2026-10-15: Dash's balloon walk
## failed silently while she kept saying "come on").
const TOLD_MOVES := ["go_to", "lead", "follow", "go_home", "go_to_bed", "approach"]
const FAILURE_NOTICE_S := 60.0
## Showing Anon the way (thread 43717688 / 43723287, 2026-11-16..18: "she tells me to follow her" and
## then nothing was said again): she says so when they get there, and calls him on when she has been
## waiting for him a while. Each is one generated line (one model request). Rollback: LEAD_TALK = false.
const LEAD_TALK := true
## Waiting this long for him before she calls out; at most one call per lead per CALL_GAP_S.
const LEAD_WAIT_CALL_S := 10.0
const LEAD_CALL_GAP_S := 45.0
const LEAD_CALLS_MAX := 2
## A lead or walk to a whole region she already stands in goes nowhere (Zecora asked about something in
## the Everfree had only "Everfree Forest" to name: its centre, 220 m off, then a stop in the trees).
## It fails at once with a reason she tells Anon, instead. Rollback: REGION_HERE_FAILS = false.
const REGION_HERE_FAILS := true
const CALL_RANGE := 24.0
const CALL_TIMEOUT := 90.0
## Who may give Anon a house of his own ([give_house]): the town's mayor and the princess. The
## grant is the arrival story's own home ownership (arrival_story.gd grant_home), so it is saved,
## his bed, "Your home" on the map and "Anon's house" for ponies (playtester 2026-10-20: Mayor
## Mare walked him to an empty house and said it was his, but nothing made it so).
const HOUSE_GRANTERS := ["mayor_mare", "celestia"]
var executors: Dictionary = {}
var awareness := AWARENESS.new()
var _call_serial := 0
var _calls: Dictionary = {}
var _ai_moves: Dictionary = {} # "pony/action id" -> the place id ("" when none) of movement the model asked for
var _lead_calls: Dictionary = {} # "pony/action id" -> [msec of her last "this way" call while waiting, calls made]
var _told_at: Dictionary = {} # pony -> msec of her last failure notice; a retried failing trip is no request loop

func register_actor(id: String, actor: Node3D) -> void:
	if executors.has(id) and is_instance_valid(executors[id]): executors[id].free()
	var executor := EXECUTOR.new()
	add_child(executor)
	executor.bind(actor)
	executor.coordinator = self; executor.character_id = id
	executor.outcome.connect(_on_actor_outcome.bind(id))
	executors[id] = executor

func context(id: String, targets: Dictionary) -> Dictionary:
	if not executors.has(id) or not is_instance_valid(executors[id]): return {"capabilities": [], "targets": {}, "locations": []}
	var executor: Node = executors[id]
	var places: Array = executor.navigator.command_places() if is_instance_valid(executor.navigator) and executor.navigator.has_method("command_places") else []
	var capabilities: Array = executor.capabilities()
	var runtime: Node = get_tree().get_first_node_in_group("encounters") if is_inside_tree() else null
	if runtime != null and runtime.claimed(id):
		capabilities = capabilities.filter(func(type: String) -> bool: return not runtime.blocks_action(id, type))
	var story := _arrival_story()
	if story != null and story.can_teleport_to_ponyville(id, executor.actor): capabilities.append("teleport_to_ponyville")
	# Asking again moves his home (arrival_story.gd can_offer_home; thread fix 2026-11-19).
	if story != null and id in HOUSE_GRANTERS and (story.can_offer_home() if story.has_method("can_offer_home") else story.has_method("can_grant_home") and story.can_grant_home()): capabilities.append("give_house")
	# She moves home into the house she and Anon both stand in or at (pony_population.gd move_target).
	if _move_target(id) != null: capabilities.append("move_house")
	# Her own purse ([pay_player], bit_payments.gd): offered only while she holds bits.
	var game := _game()
	var purse: int = BITS.balance(game.get("world_context"), id) if game != null and is_instance_valid(game.get("world_context")) else 0
	if purse > 0: capabilities.append("pay_player")
	var result := {"capabilities": capabilities, "targets": targets, "locations": places, "place_labels": _place_labels(), "purse": purse}
	# Shared mechanics (world/mechanics/mechanics.gd): [give] and later verbs, only while possible.
	var mech: Node = MECHANICS.of(get_tree()) if is_inside_tree() else null
	if mech != null: mech.ai_context(id, executor.actor, result)
	# Her own model trip in progress: the place her "walk with me" means (pony_action_schema.gd _follow_to_lead).
	result.heading_to = executor.ai_destination()
	var callable_ponies: Array[String] = []
	for other: String in targets:
		if other == id or not executors.has(other) or not is_instance_valid(executors[other]): continue
		var peer: Node3D = executors[other].actor
		if not is_instance_valid(peer) or not peer.is_inside_tree() or not is_instance_valid(executor.actor): continue
		if AWARENESS.point(peer).distance_to(AWARENESS.point(executor.actor)) > CALL_RANGE: continue
		callable_ponies.append(other)
	if not callable_ponies.is_empty(): capabilities.append_array(["call_pony", "send_pony"])
	result.callable_ponies = callable_ponies
	var relationships: Node = get_tree().get_first_node_in_group("player_relationships")
	if relationships != null: result["relationship"] = relationships.action_context(id)
	return result

func commit(id: String, actions: Array, targets: Dictionary, turn: int) -> String:
	var available := context(id, targets)
	# A story encounter holds her (world/ai/encounters/encounter_runtime.gd): the model cannot
	# send her away, cancel the story's command or hand her back to her routine. Story
	# controllers command her through the executor directly and are not filtered here.
	var runtime: Node = get_tree().get_first_node_in_group("encounters") if is_inside_tree() else null
	var allowed: Array = []
	for action: Dictionary in actions:
		if runtime != null and runtime.blocks_action(id, str(action.type)):
			if executors.has(id) and is_instance_valid(executors[id]):
				executors[id]._report(action, "failed", "Not now: you are in the middle of " + str(runtime.title_for(id)))
			continue
		if str(action.get("type", "")) == "teleport_to_ponyville":
			var story := _arrival_story()
			# Her own story line may already have started this same journey during the speech.
			if story != null and story.teleport_pending(): continue
		var error := SCHEMA.validate(action, available)
		if error != "" and str(action.get("type", "")) == "teleport_to_ponyville" and _arrival_story() != null and executors.has(id):
			error += " (" + _arrival_story().teleport_block_reason(id, executors[id].actor) + ")"
		if error != "": return error
		allowed.append(action)
	# [lead: player, HOUSE] [give_house] in one reply gives the house she is taking him to.
	for action: Dictionary in allowed:
		if str(action.get("type", "")) != "give_house": continue
		for other: Dictionary in allowed:
			if str(other.get("type", "")) in ["lead", "go_to"] and str(other.get("location_id", "")).begins_with(PLACES.HOUSE_KIND + ":"):
				action.house_id = str(other.location_id)
	if not allowed.is_empty():
		for action: Dictionary in allowed:
			if str(action.get("type", "")) not in TOLD_MOVES: continue
			# Always logged: a model trip and where it was meant to go, so a failed walk can be traced.
			print("[ai] %s moves: %s %s" % [id, action.type, str(action.get("location_id", action.get("target_id", "")))])
			_ai_moves[id + "/" + str(action.get("id", ""))] = str(action.get("location_id", ""))
			if _ai_moves.size() > 64: _ai_moves.erase(_ai_moves.keys()[0])
		var refused: Array = []
		for action: Dictionary in allowed:
			var inside := _region_here(id, action)
			if not inside.is_empty(): refused.append([action, inside])
		for row: Array in refused:
			allowed.erase(row[0])
			executors[id]._report(row[0], "failed", "You're already in %s, with no single spot to show there. Name a listed place, or say you don't know where it is" % row[1])
		if not allowed.is_empty(): executors[id].submit(allowed, targets, turn, true)
	return ""

## The region's name when a model go_to/lead names a whole region she already stands in, else "".
func _region_here(id: String, action: Dictionary) -> String:
	if not REGION_HERE_FAILS or str(action.get("type", "")) not in ["go_to", "lead"]: return ""
	var place := str(action.get("location_id", ""))
	if not place.begins_with("region:") or not executors.has(id) or not is_instance_valid(executors[id].actor): return ""
	var region := WorldLayout.region(place.trim_prefix("region:"))
	# A region with a homestead in town (Sweet Apple Acres) means that homestead, and one with an
	# authored spawn (Ponyville's plaza) means that spot: both are real places to walk to.
	if region.is_empty() or PLACES.REGION_HOMESTEADS.has(str(region.id)) or region.has("spawn"): return ""
	return str(region.get("name", region.id)) if WorldLayout.distance_to(region, executors[id].actor.global_position) <= 0.0 else ""

## Labels for free-form place names in model tags (place_directory.gd match_name).
func _place_labels() -> Dictionary:
	var labels := {}
	if not is_inside_tree(): return labels
	for place: Dictionary in PLACES.entries(get_tree()):
		labels[place.id] = str(place.label) + (" " + str(place.alt) if place.has("alt") else "")
	return labels

## The game root (pony populations' host), or null.
func _game() -> Node:
	var population := get_tree().get_first_node_in_group("pony_populations") if is_inside_tree() else null
	if population == null or not ("host" in population) or not is_instance_valid(population.host): return null
	return population.host

func dispatch_pay(id: String, action: Dictionary) -> void:
	var executor: Node = executors.get(id)
	if not is_instance_valid(executor): return
	var game := _game()
	var amount := int(action.get("amount", 0))
	var why: String = BITS.pay_player(game, executor.actor, id, amount) if game != null else "Bits cannot change hooves right now."
	if not why.is_empty(): executor._report(action, "failed", why); return
	executor._report(action, "completed", "Anon received %d bits from your purse; you have %d left" % [amount, BITS.balance(game.world_context, id)])

## A mechanic verb ([give] and the later ones): the hub runs it and reports her outcome.
func dispatch_mechanic(id: String, action: Dictionary) -> void:
	var executor: Node = executors.get(id)
	if not is_instance_valid(executor): return
	var mech: Node = MECHANICS.of(get_tree()) if is_inside_tree() else null
	var result: Dictionary = mech.dispatch(id, executor.actor, action) if mech != null else {"status": "failed", "reason": "Not possible right now"}
	executor._report(action, str(result.get("status", "failed")), str(result.get("reason", "")))

func _arrival_story() -> Node:
	return get_tree().get_first_node_in_group("arrival_story") if is_inside_tree() else null

func dispatch_house(id: String, action: Dictionary) -> void:
	var executor: Node = executors.get(id)
	if not is_instance_valid(executor): return
	var story := _arrival_story()
	if story != null and id in HOUSE_GRANTERS and story.has_method("request_home"):
		# Game facts decide the house (arrival_story.gd request_home; thread fix 2026-11-19).
		var result: Dictionary = story.request_home(id, str(action.get("house_id", "")))
		match str(result.get("status", "")):
			"given":
				var given: Node3D = result.house
				executor._report(action, "completed", "%s is Anon's home for good now. It's saved and on his map" % given.label())
			"permit":
				var hint := ""
				if not str(result.get("offer", "")).is_empty(): hint = "; it becomes his when he reaches %s" % result.offer
				elif not str(result.get("nearest", "")).is_empty(): hint = "; nearest empty one: %s" % result.nearest
				else: hint = "; no Ponyville house stands empty right now"
				executor._report(action, "accepted", "It isn't his yet. He can pick any empty house, and it's his once you two stand at it or he claims it at the EMPTY HOUSE sign on its door" + hint)
			_: executor._report(action, "failed", str(result.get("reason", "No house was given")))
		return
	var house: Node3D = story.grant_home(id, str(action.get("house_id", ""))) if story != null and id in HOUSE_GRANTERS and story.has_method("grant_home") else null
	if house == null:
		executor._report(action, "failed", "No house was given because Anon already has a home or no free Ponyville house is loaded nearby")
		return
	executor._report(action, "completed", "%s is now Anon's permanent home. It's saved, marked on his map, and ponies can visit" % house.label())

## The house she would move her household into with [move_house] now, or null: she and Anon both
## stand in or at it (pony_population.gd move_target decides which houses may be moved into).
func _move_target(id: String) -> Node3D:
	var game := _game()
	var executor: Node = executors.get(id)
	if game == null or not is_instance_valid(executor) or not is_instance_valid(executor.actor) or not executor.actor.is_inside_tree(): return null
	var population: Variant = game.get("population")
	var player: Variant = game.get("player")
	if not population is Node or not is_instance_valid(population) or not (population as Node).has_method("move_target") or not player is Node3D or not is_instance_valid(player): return null
	var camera: Node3D = game.call("_find_camera", player) if game.has_method("_find_camera") else player as Node3D
	if camera == null: return null
	var feet := Vector3(camera.global_position.x, executor.actor.global_position.y, camera.global_position.z)
	return (population as Node).call("move_target", id, executor.actor.global_position, feet) as Node3D

## [move_house]: her household moves into the house she and Anon stand in, recorded as his choice.
func dispatch_move_house(id: String, action: Dictionary) -> void:
	var executor: Node = executors.get(id)
	if not is_instance_valid(executor): return
	var house := _move_target(id)
	var game := _game()
	if house == null or game == null:
		executor._report(action, "failed", "You can only move into an empty house (or your own home), and you and Anon both need to be standing inside it")
		return
	var why := str(game.population.call("move_household", id, house))
	if not why.is_empty(): executor._report(action, "failed", why); return
	executor._report(action, "completed", "You live at %s with your household now" % house.label())

func dispatch_arrival(id: String, action: Dictionary) -> void:
	var executor: Node = executors.get(id)
	if not is_instance_valid(executor): return
	var story := _arrival_story()
	if story == null or not story.request_teleport_to_ponyville(id, executor.actor, int(story.game.world_context.epoch)):
		executor._report(action, "failed", "Forest rescue transport is unavailable here")
		return
	executor._report(action, "accepted", "Arrival story owns transport; arrival is not yet confirmed")

## Voice-range requests, not authority over remote residents or protected story routes.
func _can_call(issuer: String, recipient: String) -> bool:
	if not executors.has(issuer) or not executors.has(recipient): return false
	if not is_instance_valid(executors[issuer]) or not is_instance_valid(executors[recipient]): return false
	var a: Node3D = executors[issuer].actor
	var b: Node3D = executors[recipient].actor
	if not is_instance_valid(a) or not is_instance_valid(b) or a == b: return false
	return a.is_inside_tree() and b.is_inside_tree() and awareness.can_hear(b, a, CALL_RANGE)

func dispatch_pony(id: String, action: Dictionary, targets: Dictionary, turn: int) -> void:
	var recipient := str(action.get("pony_id", ""))
	var issuer: Node = executors.get(id)
	if not is_instance_valid(issuer): return
	if not _can_call(id, recipient): issuer._report(action, "failed", "Pony cannot hear your request here"); return
	var receiver: Node = executors[recipient]
	var destination: Node3D = issuer.actor if action.type == "call_pony" else targets.get(str(action.get("target_id", "")))
	if not is_instance_valid(destination) or not destination.is_inside_tree(): issuer._report(action, "failed", "Destination pony disappeared"); return
	if destination != issuer.actor and not awareness.can_hear(issuer.actor, destination, CALL_RANGE): issuer._report(action, "failed", "Destination is not locally present"); return
	if destination == receiver.actor: issuer._report(action, "failed", "A pony cannot be sent to herself"); return
	var gap: float = receiver.actor.global_position.distance_to(destination.global_position)
	if gap <= 1.8:
		issuer._report(action, "completed", "Pony is already beside the requested target; existing ownership retained"); return
	var runtime: Node = get_tree().get_first_node_in_group("encounters")
	if runtime != null and runtime.claimed(recipient):
		var shared: bool = runtime.has_method("shares_active") and runtime.shares_active(id, recipient)
		var safe_rest: bool = receiver.movement.get("type", "") == "stay" and gap <= 5.0
		var owns_story_route: bool = (not receiver.movement.is_empty() and not safe_rest) or (receiver.movement.is_empty() and is_instance_valid(receiver.navigator) and not str(receiver.navigator.command_owner).is_empty())
		if not shared or owns_story_route or gap > 5.0:
			issuer._report(action, "failed", "Pony is needed by an unfinished encounter; its route is retained"); return
	if "approach" not in receiver.capabilities(): issuer._report(action, "failed", "Pony cannot approach right now"); return
	_call_serial += 1
	var move := {"id": "call%d-%s-approach" % [_call_serial, id], "type": "approach", "target_id": "destination", "distance_m": 1.6, "duration_s": CALL_TIMEOUT}
	var destination_targets := {"destination": destination}
	receiver.submit([move], destination_targets, maxi(turn, int(receiver._latest_turn)))
	if str(receiver.movement.get("id", "")) != str(move.id): issuer._report(action, "failed", "Movement request was refused"); return
	_calls[recipient + "/" + str(move.id)] = {"issuer": weakref(issuer), "action": action}
	issuer._report(action, "accepted", "Asked %s to approach %s; arrival is not yet confirmed" % [recipient, id if action.type == "call_pony" else str(action.target_id)])

func _on_actor_outcome(event: Dictionary, recipient: String) -> void:
	var key := recipient + "/" + str(event.get("id", ""))
	if _ai_moves.has(key) and str(event.get("status", "")) in ["completed", "failed", "cancelled"]:
		var place := str(_ai_moves[key])
		_ai_moves.erase(key); _lead_calls.erase(key)
		print("[ai] %s %s %s: %s" % [recipient, event.get("type", ""), event.status, event.get("reason", "")])
		var lost := str(event.status) == "cancelled" and "walking range" in str(event.get("reason", ""))
		if str(event.status) == "failed" or lost: _tell_player(recipient, event, lost)
		elif LEAD_TALK and str(event.status) == "completed" and str(event.get("type", "")) == "lead": _tell_arrival(recipient, event, place)
	elif LEAD_TALK and _ai_moves.has(key) and str(event.get("type", "")) == "lead" and str(event.get("reason", "")).begins_with("Waiting for follower"):
		_call_on_later(recipient, event, key)
	if not _calls.has(key): return
	var row: Dictionary = _calls[key]
	var issuer: Node = (row.issuer as WeakRef).get_ref()
	if is_instance_valid(issuer): issuer._report(row.action, str(event.status), "Requested pony: " + str(event.reason))
	if str(event.status) in ["completed", "failed", "cancelled"]: _calls.erase(key)

## She says so herself instead of standing there (one generated line, only while Anon can hear
## her; stale after FAILURE_NOTICE_S). The outcome also stays in her prompt's action outcomes.
func _tell_player(id: String, event: Dictionary, lost: bool) -> void:
	var director: Node = get_tree().get_first_node_in_group("conversation_director") if is_inside_tree() else null
	var executor: Node = executors.get(id)
	if director == null or not director.has_method("queue_generated_intent") or not is_instance_valid(executor): return
	if Time.get_ticks_msec() - int(_told_at.get(id, -1000000)) < FAILURE_NOTICE_S * 1500.0: return
	_told_at[id] = Time.get_ticks_msec()
	var actor: Node3D = executor.actor
	var why := str(event.get("reason", ""))
	var purpose := "Anon wandered off while you were showing him the way. Call out to him briefly. If he comes back and asks, you can lead him again." if lost and str(event.get("type", "")) == "lead" \
		else "Anon got too far ahead while you were following him, and you lost him. Call out to him briefly. Use [follow: player] if you still want to tag along." if lost \
		else "You tried to %s, but couldn't: %s. Briefly tell Anon you can't get there that way, and don't pretend you arrived. You can suggest going somewhere else, or ask him to lead with [follow: player]." % [str(event.get("type", "")).replace("_", " "), why]
	var started := Time.get_ticks_msec()
	director.queue_generated_intent(id, purpose, "move-failed:%s:%s" % [id, str(event.get("id", ""))],
		func() -> bool: return is_instance_valid(actor) and actor.is_inside_tree() and Time.get_ticks_msec() - started < FAILURE_NOTICE_S * 1000.0, Callable(), true)

## There, with Anon: she says so (one generated line while he can hear her, stale after FAILURE_NOTICE_S).
func _tell_arrival(id: String, event: Dictionary, place: String) -> void:
	var director: Node = get_tree().get_first_node_in_group("conversation_director") if is_inside_tree() else null
	var executor: Node = executors.get(id)
	if director == null or not director.has_method("queue_generated_intent") or not is_instance_valid(executor): return
	var actor: Node3D = executor.actor
	var found: Dictionary = PLACES.find(get_tree(), place) if not place.is_empty() and is_inside_tree() else {}
	var label := str(found.get("label", "the place")) if not found.is_empty() else "the place"
	var short := "as close as" in str(event.get("reason", ""))
	var purpose := ("The path goes no closer to %s. In a few words, tell Anon this is as near as you can lead him and where it is from here." if short \
		else "You just led Anon to %s. Let him know in a few words that you're both here now.") % label
	var started := Time.get_ticks_msec()
	director.queue_generated_intent(id, purpose, "lead-arrived:%s:%s" % [id, str(event.get("id", ""))],
		func() -> bool: return is_instance_valid(actor) and actor.is_inside_tree() and Time.get_ticks_msec() - started < FAILURE_NOTICE_S * 1000.0, Callable(), true)

## At most LEAD_CALLS_MAX calls per lead, LEAD_CALL_GAP_S apart (an idle player costs no endless requests).
func _may_call(key: String) -> bool:
	var row: Array = _lead_calls.get(key, [-1000000, 0])
	return int(row[1]) < LEAD_CALLS_MAX and Time.get_ticks_msec() - int(row[0]) >= LEAD_CALL_GAP_S * 1000.0

## Waiting for Anon who lags behind: after LEAD_WAIT_CALL_S still waiting, she calls him on (one timer per
## wait, no per-frame work; at most one call per LEAD_CALL_GAP_S for this lead).
func _call_on_later(id: String, event: Dictionary, key: String) -> void:
	if not is_inside_tree() or not _may_call(key): return
	if not await SHUTDOWN.seconds(self, LEAD_WAIT_CALL_S): return
	var executor: Node = executors.get(id)
	if not is_instance_valid(executor) or not _ai_moves.has(key) or str(executor.movement.get("id", "")) != str(event.get("id", "")): return
	if not bool(executor.get("_waiting_for_follower")): return
	if not _may_call(key): return
	var director: Node = get_tree().get_first_node_in_group("conversation_director")
	if director == null or not director.has_method("queue_generated_intent"): return
	_lead_calls[key] = [Time.get_ticks_msec(), int((_lead_calls.get(key, [0, 0]) as Array)[1]) + 1]
	var found: Dictionary = PLACES.find(get_tree(), str(_ai_moves[key]))
	var actor: Node3D = executor.actor
	var started := Time.get_ticks_msec()
	director.queue_generated_intent(id, "While leading Anon to %s, you stopped to wait because he's lagging behind. Call him over in a few words." % str(found.get("label", "the place")),
		"lead-wait:%s:%d" % [key, started],
		func() -> bool: return is_instance_valid(actor) and actor.is_inside_tree() and is_instance_valid(executor) and bool(executor.get("_waiting_for_follower")) and Time.get_ticks_msec() - started < 15000, Callable(), true)

func outcomes(id: String) -> String:
	return executors[id].context_lines() if executors.has(id) and is_instance_valid(executors[id]) else ""

func invalidate_world() -> void:
	_calls.clear()
	for executor: Node in executors.values():
		if not is_instance_valid(executor): continue
		executor._end_move("cancelled", "World changed", true)
		executor._end_gaze("cancelled", "World changed")
		executor._seen.clear(); executor._latest_turn = -1; executor.recent.clear()

func forget(id: String) -> void:
	for key: String in _calls.keys():
		if not key.begins_with(id + "/"): continue
		var row: Dictionary = _calls[key]
		var issuer: Node = (row.issuer as WeakRef).get_ref()
		if is_instance_valid(issuer): issuer._report(row.action, "failed", "Requested pony left the loaded scene")
		_calls.erase(key)
	if executors.has(id) and is_instance_valid(executors[id]): executors[id].free()
	executors.erase(id)
