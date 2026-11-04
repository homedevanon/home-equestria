extends Node
## Registration, advertised capabilities and revalidation at the moment of dispatch.
const EXECUTOR := preload("res://world/ai/pony_action_executor.gd")
const SCHEMA := preload("res://world/ai/pony_action_schema.gd")
const AWARENESS := preload("res://world/ai/pony_awareness.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const BITS := preload("res://world/ai/bit_payments.gd")
const MECHANICS := preload("res://world/mechanics/mechanics.gd")
## Model-requested trips whose failure she tells Anon about (dev 2026-10-15: Dash's balloon walk
## failed silently while she kept saying "come on").
const TOLD_MOVES := ["go_to", "lead", "follow", "go_home", "go_to_bed", "approach"]
const FAILURE_NOTICE_S := 60.0
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
var _ai_moves: Dictionary = {} # "pony/action id" -> true for movement the model asked for
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
	if story != null and id in HOUSE_GRANTERS and story.has_method("can_grant_home") and story.can_grant_home(): capabilities.append("give_house")
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
			_ai_moves[id + "/" + str(action.get("id", ""))] = true
			if _ai_moves.size() > 64: _ai_moves.erase(_ai_moves.keys()[0])
		executors[id].submit(allowed, targets, turn, true)
	return ""

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
	var house: Node3D = story.grant_home(id, str(action.get("house_id", ""))) if story != null and id in HOUSE_GRANTERS and story.has_method("grant_home") else null
	if house == null:
		executor._report(action, "failed", "No house was given: Anon already has a home, or no free Ponyville house is loaded nearby")
		return
	executor._report(action, "completed", "%s is now Anon's own home for good: saved, marked on his map, and ponies can go there" % house.label())

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
		_ai_moves.erase(key)
		print("[ai] %s %s %s: %s" % [recipient, event.get("type", ""), event.status, event.get("reason", "")])
		var lost := str(event.status) == "cancelled" and "walking range" in str(event.get("reason", ""))
		if str(event.status) == "failed" or lost: _tell_player(recipient, event, lost)
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
	var purpose := "You were showing Anon the way, but he stopped following and wandered off. Call out to him in a few words; you can show him again if he comes back and asks." if lost and str(event.get("type", "")) == "lead" \
		else "You were following Anon, but he went too far ahead and you lost him. Call out to him in a few words; if you still want to go along, use [follow: player]." if lost \
		else "You tried to %s but could not: %s. Tell Anon in a few words that you could not get there this way; never claim you arrived. You may ask him to lead the way ([follow: player]) or suggest somewhere else." % [str(event.get("type", "")).replace("_", " "), why]
	var started := Time.get_ticks_msec()
	director.queue_generated_intent(id, purpose, "move-failed:%s:%s" % [id, str(event.get("id", ""))],
		func() -> bool: return is_instance_valid(actor) and actor.is_inside_tree() and Time.get_ticks_msec() - started < FAILURE_NOTICE_S * 1000.0, Callable(), true)

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
