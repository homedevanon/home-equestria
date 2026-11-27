extends RefCounted
## Chat holds, goodbyes and lulls: who is engaged in a conversation, when she says bye, when she speaks first.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.


var host: Node
var _patience: Dictionary = {}      # id -> chat length (s) after which she wants to move on
## Goodbyes the director decides itself: the player went quiet, or bedtime.
## Not when they are together at home (dev 2026-09-28: "we are together in our house. she
## shouldn't always literally leave"): there a lull just ends the chat and she stays.
var _farewell_wait := 0.0
## Mid-conversation lull: after 15–30 s with the floor open, a chance the pony
## speaks first (once per lull, only while the chat is live and she can hear the player).
var _lull_wait:=0.0
## Time the player has actually had to answer, shared by everyone using the voice channel.
var _floor_quiet_seconds := 0.0
## A lull prompt costs a whole dialogue request (~12k tokens). One per pony per chat, and at most
## one per LULL_GAP_SECONDS across all ponies: in a group each pony used to get her own lull
## 14-19 s after another's (tester capture 2026-10-22).
const LULL_GAP_SECONDS := 60.0
var _lull_next_at := -1e9
## The director's own goodbyes come one at a time: at 1 a.m. every mare in the square left in a
## chain, one after the other, each with "Well, I'm off to ..." (dev 2026-10-26).
const FAREWELL_GAP_SECONDS := 45.0
## Late at night a chat still runs at least this long before bedtime ends it.
const LATE_MIN_CHAT_SECONDS := 75.0
## Silence this long ends a chat (dev 2026-10-29: 50 s was far too short; 5 minutes).
const QUIET_SECONDS := 300.0
var _farewell_next_at := -1e9


func _init(owner_node: Node) -> void:
	host = owner_node


func participant_busy(id: String) -> bool:
	return host.state != "idle" and (id == host._current or (host.group.active() and id in host.group.members))


func engaged(id: String) -> bool:
	if not host.characters.has(id): return false
	# Speaking a transaction line must not evict its customer from the counter's
	# navigation lease. The shared voice channel still reports participant_busy.
	if not host._authored_active.is_empty() and id == host._current: return false
	if participant_busy(id) or (host.group.active() and id in host.group.members): return true
	var entry: Dictionary = host.characters[id]
	if not entry.has("chat_last") or host._now() - float(entry.chat_last) > host.CHAT_HOLD_SECONDS: return false
	# After her goodbye she is free until the player talks to her again.
	if float(entry.chat_last) <= float(host._released.get(id, -1e9)): return false
	var node: Variant = entry.node
	return is_instance_valid(node) and is_instance_valid(host.player_head) and node.is_inside_tree() \
		and host.awareness.can_hear(node, host.player_head, host._earshot(id))


## Engaged and not walking along with a talking group: stays where she is, no wandering, and
## her day plan waits (day_runner.gd; player reports 2026-10-28: ponies walked off mid-chat
## when a step's hour came). Once he walks off more than WALK_AWAY_METRES between turns she is
## free again, though she still hears him; while she is answering him she stays wherever he is.
const WALK_AWAY_METRES := 8.0
func holds_in_place(id: String) -> bool:
	if not engaged(id) or host.movement_dialogue_allowed(id): return false
	if participant_busy(id): return true
	var node: Variant = host.characters[id].node
	if not node is Node3D or not is_instance_valid(host.player_head): return false
	var apart: Vector3 = (node as Node3D).global_position - host.player_head.global_position
	apart.y = 0.0
	return apart.length() <= WALK_AWAY_METRES


## She has somewhere to be: a short goodbye in her own words, then she is free to leave.
## Group exchanges are short and bounded; she stays for the end of one instead.
func request_farewell(id: String, reason: String) -> bool:
	if not engaged(id) or host._farewell.has(id) or (host.group.active() and id in host.group.members): return false
	if host._encounter_claimed(id): return false
	if host.state != "idle" or host.speech.state == "hearing": return false
	host._farewell[id] = host._now() + 15.0
	host._farewell_reason = reason
	host._on_physical_reaction("farewell", id)
	if host.state == "idle": _release(id)   # nothing could be said: just go
	return true


## A goodbye reply that keeps her with him: a stay, following him, sitting or lying down nearby,
## or a cuddle. Anything else (a goodbye line alone, go_to, go_home, resume_routine) lets her go.
const STAYING := ["stay", "sit", "lie_down", "sit_on_seat", "cuddle"]
func stays(action: Dictionary) -> bool:
	var kind := str(action.get("type", ""))
	return kind in STAYING or (kind == "follow" and str(action.get("target_id", "")) == "player")


## She declined the goodbye: the chat goes on, and the director does not ask again for this chat
## (bedtime included) until she or he ends it.
func stay_on(id: String) -> void:
	host._farewell.erase(id)
	host._farewell_staying.erase(id)
	if not host.characters.has(id): return
	var entry: Dictionary = host.characters[id]
	entry["chat_last"] = host._now()
	entry["kept_on"] = entry.get("chat_since", entry.chat_last)


func _release(id: String) -> void:
	host._farewell.erase(id)
	host._farewell_staying.erase(id)
	_patience.erase(id)
	host._released[id] = host._now()
	if host.characters.has(id): host.characters[id].erase("chat_since")
	host._set_attention(id, null)


## Showing the player the way is a promise kept until they arrive or he walks off (the executor
## ends the lead then). A quiet walk, a long chat or the late hour must not end it in a goodbye:
## Twilight's tour after the intro, the longest chat of a new game, turned back halfway.
func _leading_player(id: String) -> bool:
	if not is_instance_valid(host.actions): return false
	var executor: Variant = host.actions.executors.get(id)
	if not is_instance_valid(executor): return false
	var movement: Dictionary = executor.movement
	# Following him is the same promise: Dash agreed "you lead the way", and the chat-length goodbye
	# fired seconds later and sent her back to her day, flying off (dev 2026-10-29).
	return str(movement.get("type", "")) in ["lead", "follow"] and str(movement.get("target_id", "")) == "player"


func _together_at_home(id: String) -> bool:
	if not host.characters.has(id) or not is_instance_valid(host.player_head): return false
	var node: Variant = host.characters[id].node
	if not is_instance_valid(node): return false
	var runtime: Node = host.get_tree().get_first_node_in_group("player_relationships")
	var partner: bool = runtime != null and is_instance_valid(runtime.bonds) and str(runtime.bonds.record_for(id).stage) in ["dating", "engaged", "married"]
	var house: Node3D = preload("res://world/buildings/house_interior.gd").at(host.get_tree(), host.player_head.global_position)
	var same_house: bool = house != null and house == preload("res://world/buildings/house_interior.gd").at(host.get_tree(), (node as Node3D).global_position)
	return partner or same_house


func _check_farewells(delta: float) -> void:
	_farewell_wait -= delta
	if _farewell_wait > 0.0: return
	_farewell_wait = 1.0
	for id in host._farewell.keys():
		if host._now() > float(host._farewell[id]): _release(id)
	if _floor_quiet_seconds <= 0.0 or host.state != "idle" or host._now() < _farewell_next_at: return
	var hours: float = host.get_node("/root/TimeOfDay").hours if host.has_node("/root/TimeOfDay") else 12.0
	for id in host.characters:
		if not engaged(id) or host._farewell.has(id) or host.quiet_moment(id) or host._encounter_claimed(id): continue
		if _leading_player(id): continue
		var entry: Dictionary = host.characters[id]
		var since_exchange: float = host._now() - maxf(float(entry.chat_last), float(entry.get("last_spoken_at", -1e9)))
		var quiet := minf(since_exchange, _floor_quiet_seconds)
		var length: float = host._now() - float(entry.get("chat_since", entry.chat_last))
		if not _patience.has(id): _patience[id] = host._reaction_rng.randf_range(240.0, 540.0)
		var reason := ""
		if _together_at_home(id):
			# A partner, or anypony in the same house as him: a lull ends the chat, she stays put.
			if quiet > QUIET_SECONDS: _release(id)
			continue
		# Late hours halve her patience instead of ending the chat on its first reply.
		var late := hours >= 22.0 or hours < 5.0
		# She chose to stay after an earlier goodbye prompt in this chat: no second one.
		if entry.has("kept_on") and entry.get("kept_on") == entry.get("chat_since", null): continue
		if quiet > QUIET_SECONDS: reason = "The player has gone quiet for a while."
		elif late and length > maxf(LATE_MIN_CHAT_SECONDS, float(_patience[id]) * .5): reason = "It is late; bedtime is coming."
		# No goodbye just for a chat running long (dev 2026-10-29): friends don't walk off mid-talk
		# for an errand, and long, deep conversations must stay possible. Silence or bedtime only.
		if reason != "" and request_farewell(id, reason):
			_farewell_next_at = host._now() + FAREWELL_GAP_SECONDS
			return


func _maybe_contribute(delta:float)->void:
	# The game and the Board Games director both call this before checking farewells.
	# Sample every physics tick, even when the next lull check isn't due yet.
	if host.state != "idle" or host.group.active() or host.speech.taking_turn() \
			or not host._held_utterance.is_empty() or not host._held_text.is_empty():
		_floor_quiet_seconds = 0.0
	else:
		_floor_quiet_seconds += delta
	_lull_wait-=delta
	if _lull_wait>0.0:return
	_lull_wait=0.5
	if _floor_quiet_seconds <= 0.0: return
	if host._now() < _lull_next_at: return
	# Filling a silence is the game's idea, not the player's: only with AI usage "full".
	if not preload("res://world/ai/ai_config.gd").background_allowed(host.get("config")): return
	for id in host.characters:
		if host._authored_holds(str(id)) or host.quiet_moment(str(id)): continue
		var entry:Dictionary=host.characters[id]
		if not entry.has("chat_last"):continue
		var since_exchange: float = host._now() - maxf(float(entry.chat_last), float(entry.get("last_spoken_at", -1e9)))
		if since_exchange > 45.0 or float(entry.get("lull_used", -1.0)) == float(entry.chat_last): continue
		if not entry.has("lull_after"):entry["lull_after"]=host._reaction_rng.randf_range(15.0,30.0)
		if minf(since_exchange, _floor_quiet_seconds) < float(entry.lull_after): continue
		entry["lull_used"]=entry.chat_last;entry.erase("lull_after")
		_lull_next_at = host._now() + LULL_GAP_SECONDS
		host._on_physical_reaction("quiet",id)
		return
