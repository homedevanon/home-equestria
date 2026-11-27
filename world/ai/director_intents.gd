extends RefCounted
## Generated story/transaction purposes: the AI-only intent queue, its guards, retries and delivery.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.

const GROUP := preload("res://world/ai/pony_group_conversation.gd")
const BOND := preload("res://world/relationships/bond_rules.gd")
const BOND_PROMPT := preload("res://world/relationships/bond_prompt.gd")

var host: Node


func _init(owner_node: Node) -> void:
	host = owner_node


## AI-only semantic intent queue. Acceptance is not delivery; failures remain pending.
## `once`: a notice, not a story beat. Once the player heard any sentence of it, an interruption
## ends it instead of re-requesting it (three "could not get there" lines in 50 s, 2026-10-22).
## `firm`: once it is spoken the player cannot cut it off; his words wait for the end of the line
## (conversation_director.floor_held; Trixie's stage patter, dev 2026-10-28).
func queue_generated_intent(id: String, intent: String, key: String, valid: Callable, finished := Callable(), once := false, firm := false) -> bool:
	if key.is_empty() or intent.strip_edges().is_empty() or not valid.is_valid(): return false
	if host._authored_lines.has(key): return str(host._authored_lines[key].id) == id and str(host._authored_lines[key].intent) == intent.strip_edges()
	if not bool(valid.call()): return false
	host._authored_lines[key] = {"id":id,"intent":intent.strip_edges(),"valid":valid,"finished":finished,"started":false,"attempts":0,"retry_at":0.0,"delivered":false,"epoch":host._intent_epoch,"heard":[],"once":once,"firm":firm}
	return true


## Compatibility for old callers: their text is context for generation, never spoken directly.
func queue_authored_line(id: String, text: String, key: String, valid: Callable, finished := Callable()) -> bool:
	return queue_generated_intent(id, "Put this situation into your own words. Treat it as background and never repeat it word for word: " + text, key, valid, finished)


func request_relationship_intent(id: String, intent: Dictionary, valid: Callable, finished := Callable()) -> bool:
	var kind := str(intent.get("kind",""))
	var purpose := ""
	if kind == "after_kiss": purpose = "You just shared a sweet kiss. If you want another, ask for one in your own words and include [kiss_player]. Leave the tag out if you pass or just talk."
	elif kind == "relationship_offer": purpose = "Consider making a genuine relationship offer right now. Requested kind: %s. Activity, if relevant: %s. Tag the offer you make with the relationship_offer action tag, and don't claim an offer or relationship already exists." % [intent.get("offer_kind",""),intent.get("activity","")]
	# Relationship overhaul 2026-11-21 (design 5.3): the turn the game gives her to speak up.
	elif kind == "bond_ask" and BOND.DYNAMIC: purpose = BOND_PROMPT.intent_text(intent)
	else: return false
	if purpose.is_empty(): return false
	return queue_generated_intent(id,purpose,"relationship-intent:%s:%s" % [id,JSON.stringify(intent)],valid,finished)


func cancel_authored_line(key: String) -> void:
	host._authored_lines.erase(key)
	if host._authored_active == key and not key.is_empty(): host.interrupt()


func _authored_valid(row: Dictionary) -> bool:
	var guard: Callable = row.valid
	return int(row.get("epoch",-1)) == host._intent_epoch and guard.is_valid() and bool(guard.call())


func _authored_holds(id: String) -> bool:
	for row: Dictionary in host._authored_lines.values():
		if str(row.id) == id and not bool(row.get("delivered",false)): return true
	return false


func _retry_intent() -> void:
	if not host._authored_lines.has(host._authored_active): return
	var row: Dictionary = host._authored_lines[host._authored_active]
	if bool(row.get("delivered",false)): return
	if bool(row.get("once", false)) and not (row.get("heard", []) as Array).is_empty():
		row.delivered = true
		return
	row.started = false
	row.attempts = int(row.get("attempts",0)) + 1
	row.retry_at = host._now() + minf(30.0,pow(2.0,minf(float(row.attempts),5.0)))


func _tick_authored() -> void:
	for key: String in host._authored_lines.keys():
		if not _authored_valid(host._authored_lines[key]): cancel_authored_line(key)
	if host.state != "idle" or host.group.active() or host.speech.state == "hearing" or host.llm.busy or host.player_approaches.active(): return
	for key: String in host._authored_lines:
		var row: Dictionary = host._authored_lines[key]
		if row.started or bool(row.get("delivered",false)) or host._now() < float(row.retry_at) or not host.characters.has(str(row.id)): continue
		var id := str(row.id)
		var actor: Node3D = host.characters[id].node
		if not is_instance_valid(actor) or not is_instance_valid(host.player_head) or not actor.is_inside_tree() or not actor.is_visible_in_tree(): continue
		if actor.has_method("is_speaking") and actor.is_speaking(): continue
		if not host.awareness.can_hear(actor,host.player_head,GROUP.RANGE): continue
		row.started = true
		host._authored_active = key
		host._current = id; host._listener_id = "player"; host._turn_id += 1
		host._proactive_turn = false; host._player_text = ""; host._physical_context = ""; host._rewrite_used = false
		host._pending_actions = []; host._pending_impression = {}; host._pending_text = ""
		host._pending_face = ""; host._pending_gesture = ""; host._recorded = false; host._history_record = {}
		host._prefetch_index = -1; host._prefetch_result = {}; host._group_index = -1
		host.state = "thinking"
		var messages: Array = host.characters[id].history.duplicate(true)
		messages.append({"role":"user","content":"[Current game purpose, not player speech or a quotation] " + str(row.intent) + " Write fresh in-character dialogue for the unfinished part only, picking up from the witnessed lines in the system context. Do not start over or read the context like a script. If you cannot speak, this purpose stays pending."})
		host._next_purpose = "story_purpose"
		if not host._complete_solo(host.system_prompt(id),messages,host._on_reply.bind(host._turn_id)): host._finish_silence()
		return


## Current generated purpose is mandatory for initial, repair and novelty requests.
func _generated_intent_frame(id: String) -> String:
	var frames: Array[String] = []
	for key: String in host._authored_lines:
		var row: Dictionary = host._authored_lines[key]
		if str(row.id) != id or bool(row.get("delivered", false)) or not _authored_valid(row): continue
		var frame := "PENDING GENERATION PURPOSE (game facts and intention, never quoted dialogue): " + str(row.intent)
		frame += " Answer the player's interruption naturally, then get back to what you were here to do. Skip the intro and any facts they already heard. Just answering a question does not count as finishing your purpose."
		var heard: Array = row.get("heard", [])
		if not heard.is_empty(): frame += " Sentences from this purpose that actually finished in the listener's presence (do not recite again): " + JSON.stringify(heard)
		frames.append(frame)
	return "\n".join(frames)


func _finish_intent(done: Callable, valid: Callable, epoch: int) -> void:
	if epoch == host._intent_epoch and valid.is_valid() and bool(valid.call()) and done.is_valid(): done.call()
