extends Node
## Durable story encounters (docs/plans/AI_CONTEXT_AND_INTERRUPTION_RESILIENCE_2026_10_02.md
## section 2). A story controller begins an encounter with its participants, what each of them
## knows, the commitment, and the beats that must be delivered; this module keeps that purpose
## alive through interruptions:
## - frame_for(speaker) is pinned into every AI request for a participant (director system
##   prompt), contact and question turns included, regenerated from saved state each time;
## - a participant is claimed while the encounter is active: routine farewells and visit timers
##   cannot take her away; during the forest intro (until the teleport) neither can model-chosen
##   leave/cancel/routine actions (blocks_action); later scenes let the model move her;
## - a beat is delivered only when its speech finished naturally (director turn_delivered), not
##   when it was accepted or started; an interrupted beat is resumed by asking the AI for fresh dialogue about the unfinished purpose;
##   no canned speech, timed completion or replay of finished beats;
## - state persists in the world context ("encounters"), by stable ids, never Nodes.
## Temporary events (a boop) are recorded as the latest event; they never replace the encounter.
signal beat_delivered(encounter_id: String, beat_id: String)
signal completed(encounter_id: String)

const STATE_KEY := "encounters"
## Before an interrupted beat is resumed: the director idle and the player in earshot this long.
const SETTLE_SECONDS := 1.5
## A latest event older than this is no longer mentioned.
const EVENT_SECONDS := 25.0

var game: Node
var _settle := 0.0
## encounter id -> {"turn": director turn awaited for the current beat, "line": authored key}
var _pending: Dictionary = {}
## "encounter|participant" -> WeakRef(navigator) currently reserved (crucial-moment presence).
var _reserved: Dictionary = {}
var _presence_wait := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group("encounters")
	var context: Node = game.get("world_context")
	if context != null and context.has_signal("reopened"): context.reopened.connect(_on_reopened)

## Another world or checkpoint: nothing pending or reserved from before survives.
func _on_reopened(_world: String) -> void:
	_pending.clear(); _settle = 0.0
	for slot: String in _reserved.keys():
		var nav: Node = (_reserved[slot] as WeakRef).get_ref()
		if is_instance_valid(nav): nav.release_reservation(slot.get_slice("|", 0))
	_reserved.clear()

func _store() -> Dictionary:
	var context: Node = game.get("world_context") if is_instance_valid(game) else null
	if context == null: return {}
	if not (context.state.get(STATE_KEY) is Dictionary): context.state[STATE_KEY] = {}
	return context.state[STATE_KEY]

func _changed() -> void:
	var context: Node = game.get("world_context") if is_instance_valid(game) else null
	if context != null and context.has_method("_changed"): context._changed()

## `definition`: {"title", "place", "participants": [ids], "knows": {id: [facts]},
## "commitment": {id: text}, "allowed": text, "release_after": {id: beat id},
## "movers": {id: [owner prefixes allowed to move her during the encounter]}, "hold": true
## (model actions may not move her; otherwise only the forest intro holds),
## "beats": [{"id", "label", "speaker", "intent", "await_turn_s"}]}. A beat without
## intent is driven by its story controller. Legacy text fields identify required speech
## but their canned prose is never submitted or spoken. Failed generation stays pending.
## Idempotent: an encounter already begun (or finished) is left as it is.
func begin(id: String, definition: Dictionary) -> bool:
	var store := _store()
	if store.has(id): return false
	var row := definition.duplicate(true)
	row["status"] = "active"
	row["beat"] = 0
	row["delivered"] = []
	row["attempts"] = 0
	row["event"] = {}
	row["revision"] = 1
	row["beat_started"] = Time.get_unix_time_from_system()
	row["turn_tried"] = false
	store[id] = row
	_changed()
	print("[encounter] begin ", id)
	return true

func active(id: String) -> bool:
	var row: Dictionary = _store().get(id, {})
	return str(row.get("status", "")) == "active"

func get_row(id: String) -> Dictionary:
	return (_store().get(id, {}) as Dictionary).duplicate(true)

func delivered(id: String, beat_id: String) -> bool:
	var row: Dictionary = _store().get(id, {})
	return beat_id in (row.get("delivered", []) as Array)

func complete(id: String) -> void:
	var store := _store()
	if not store.has(id) or str(store[id].get("status", "")) != "active": return
	store[id].status = "completed"
	_cancel_pending(id)
	_changed()
	_sync_presence()   # her normal life resumes now, not half a second later
	completed.emit(id)
	print("[encounter] completed ", id)

func cancel(id: String, reason: String) -> void:
	var store := _store()
	if not store.has(id): return
	store[id].status = "cancelled"; store[id].reason = reason
	_cancel_pending(id)
	_changed()
	_sync_presence()

## The active encounters this speaker takes part in.
func _for(speaker: String) -> Array:
	var result: Array = []
	var store := _store()
	for key: String in store:
		var row: Dictionary = store[key]
		if str(row.get("status", "")) == "active" and speaker in (row.get("participants", []) as Array):
			result.append(key)
	return result

## A participant of an active encounter whose own part is not finished yet.
func claimed(speaker: String) -> bool:
	for key: String in _for(speaker):
		if _claims(key, speaker): return true
	return false

func shares_active(a: String, b: String) -> bool:
	for key: String in _for(a):
		if b in (_store()[key].get("participants", []) as Array): return true
	return false

func _claims(key: String, speaker: String) -> bool:
	var row: Dictionary = _store().get(key, {})
	if str(row.get("status", "")) != "active" or speaker not in (row.get("participants", []) as Array): return false
	var after := str((row.get("release_after", {}) as Dictionary).get(speaker, ""))
	return after.is_empty() or after not in (row.get("delivered", []) as Array)

## Crucial-moment presence: every claimed participant's navigator is reserved (only the
## encounter's own movers may move her; her old route stops); released as soon as the claim ends.
func _sync_presence() -> void:
	var wanted := {}
	var store := _store()
	for key: String in store:
		var row: Dictionary = store[key]
		for pid: String in row.get("participants", []):
			if not _claims(key, pid): continue
			var nav := _navigator(pid)
			if nav == null: continue
			wanted[key + "|" + pid] = true
			var movers: Array = ((row.get("movers", {}) as Dictionary).get(pid, []) as Array).duplicate()
			# "ai:" lets the model's own tag commands move her (navigator_ownership.gd).
			if not _holds(key): movers.append("ai:")
			if str(nav.get("reserved_by")) != key or nav.get("_reserved_owners") != movers:
				nav.reserve(key, movers)
				_reserved[key + "|" + pid] = weakref(nav)
	for slot: String in _reserved.keys():
		if wanted.has(slot): continue
		var nav: Node = (_reserved[slot] as WeakRef).get_ref()
		if is_instance_valid(nav): nav.release_reservation(slot.get_slice("|", 0))
		_reserved.erase(slot)

func _navigator(pid: String) -> Node:
	var actor: Node = null
	var director: Node = game.get("director") if is_instance_valid(game) else null
	if director != null and director.characters.has(pid) and is_instance_valid(director.characters[pid].node): actor = director.characters[pid].node
	var population: Variant = game.get("population") if is_instance_valid(game) else null
	if actor == null and population is Node and is_instance_valid(population):
		var live: Variant = (population as Node).get("live")
		if live is Dictionary and (live as Dictionary).get(pid) is Dictionary and is_instance_valid((live as Dictionary)[pid].get("actor")): actor = (live as Dictionary)[pid].actor
	if actor == null: return null
	var nav := actor.get_node_or_null("Navigator")
	return nav if nav != null and nav.has_method("reserve") else null

## Model-chosen actions that would take a claimed participant away from the encounter.
const LEAVING := ["resume_routine", "go_home", "go_to_bed", "go_to", "fly_to", "lead", "follow", "cancel",
	"loop_de_loop", "barrel_roll", "circle_over", "sonic_rainboom", "air_show", "sit_on_seat", "stay", "approach",
	"stand", "sit", "lie_down", "wake_up", "hover", "land", "cuddle", "buck_player", "board_game"]
## Only the forest intro (until the teleport to Ponyville) and "hold" encounters hold them; in
## every other scene the model may move a participant (dev 2026-10-15) and the story re-leads her.
func blocks_action(speaker: String, type: String) -> bool:
	if type not in LEAVING: return false
	for key: String in _for(speaker):
		if _claims(key, speaker) and _holds(key): return true
	return false

const INTRO := "arrival_rescue"
## Also any encounter begun with "hold": true (Trixie's stage show: Anon's words must not walk her
## off the stage mid-show, dev 2026-10-28).
func _holds(key: String) -> bool:
	if bool((_store().get(key, {}) as Dictionary).get("hold", false)): return true
	if key != INTRO: return false
	var story: Node = get_tree().get_first_node_in_group("arrival_story") if is_inside_tree() else null
	return story == null or not story.has_method("holds_actions") or bool(story.holds_actions())

func title_for(speaker: String) -> String:
	var keys := _for(speaker)
	return str(_store()[keys[0]].get("title", keys[0])) if not keys.is_empty() else ""

## A temporary event (boop, petting, a question, being carried) on a participant.
func event(speaker: String, kind: String, summary := "") -> void:
	for key: String in _for(speaker):
		var row: Dictionary = _store()[key]
		row.event = {"speaker": speaker, "kind": kind, "summary": summary, "at": Time.get_unix_time_from_system()}
		row.revision = int(row.get("revision", 0)) + 1

## The pinned frame for a participant's request: why they are here, what they know, what is
## done and what is left, the latest event, and what they may do. Empty outside encounters.
func frame_for(speaker: String) -> String:
	var keys := _for(speaker)
	if keys.is_empty(): return ""
	var row: Dictionary = _store()[keys[0]]
	var lines: PackedStringArray = []
	lines.append("CURRENT ENCOUNTER: %s%s." % [str(row.get("title", keys[0])), (", " + str(row.place)) if str(row.get("place", "")) != "" else ""])
	var knows: Array = (row.get("knows", {}) as Dictionary).get(speaker, [])
	if not knows.is_empty(): lines.append("YOU KNOW: " + " ".join(knows))
	var commitment := str((row.get("commitment", {}) as Dictionary).get(speaker, ""))
	if commitment != "": lines.append("YOUR PURPOSE HERE: " + commitment)
	var beats: Array = row.get("beats", [])
	var done: Array = row.get("delivered", [])
	var progress: PackedStringArray = []
	for beat: Dictionary in beats:
		progress.append("%s: %s" % [str(beat.get("label", beat.id)), "done" if str(beat.id) in done else "not yet"])
	if not progress.is_empty(): lines.append("PROGRESS: " + "; ".join(progress) + ".")
	var current: Dictionary = beats[int(row.beat)] if int(row.beat) < beats.size() else {}
	var ev: Dictionary = row.get("event", {})
	var fresh: bool = not ev.is_empty() and Time.get_unix_time_from_system() - float(ev.get("at", 0.0)) < EVENT_SECONDS
	if fresh: lines.append("LATEST EVENT: " + (str(ev.summary) if str(ev.get("summary", "")) != "" else str(ev.kind)) + ".")
	if not current.is_empty() and str(current.get("speaker","")) == speaker:
		lines.append("RESPONSE: React naturally to the current question or interruption while preserving the unfinished purpose: " + _intent(row,current))
	elif not current.is_empty():
		lines.append("RESPONSE: Stay with the encounter; react briefly to anything that just happened.")
	if claimed(speaker) and _holds(keys[0]):
		lines.append("PRESENCE: " + str(row.get("allowed", "Stay with the encounter; its controller owns your movement and posture until this is finished.")))
		lines.append("MODEL ACTIONS: [look_at: TARGET] may direct your gaze. Do not issue stay, approach, posture, flight or cancel tags; the encounter controller owns those actions. Being touched or answering a question does not cancel your purpose.")
	elif claimed(speaker):
		lines.append("PRESENCE: You may follow, lead or go places with Anon when it fits; keep your purpose here in mind and come back to it.")
	return "\n".join(lines)

## Director: a turn finished speaking to the end (not interrupted).
func on_turn_delivered(speaker: String, turn: int) -> void:
	for key: String in _pending.keys():
		var waiting: Dictionary = _pending[key]
		if int(waiting.get("turn", -1)) == turn and str(waiting.get("speaker", "")) == speaker and _beat_valid(key,int(waiting.get("beat",-1)),int(waiting.get("epoch",-1))):
			_deliver(key)

## A story controller started the current beat as an AI turn (a greeting): delivered when that
## turn finishes naturally, else resumed with the authored line.
func expect_turn(id: String, speaker: String, turn: int) -> void:
	if not active(id) or turn < 0: return
	_pending[id] = {"turn":turn,"speaker":speaker,"since":Time.get_unix_time_from_system(),"beat":int(_store()[id].beat),"epoch":_epoch()}
	var row: Dictionary = _store()[id]
	row.turn_tried = true

## A story-driven beat (no line of its own) is done: the next beat begins.
func mark_delivered(id: String, beat_id: String) -> void:
	if not active(id): return
	var row: Dictionary = _store()[id]
	var beats: Array = row.get("beats", [])
	if int(row.beat) < beats.size() and str(beats[int(row.beat)].id) == beat_id: _deliver(id)

func _deliver(id: String) -> void:
	var store := _store()
	if not store.has(id): return
	var row: Dictionary = store[id]
	var beats: Array = row.get("beats", [])
	if int(row.beat) >= beats.size(): return
	var beat: Dictionary = beats[int(row.beat)]
	if str(beat.id) not in (row.delivered as Array): (row.delivered as Array).append(str(beat.id))
	row.beat = int(row.beat) + 1
	row.attempts = 0
	row.turn_tried = false
	row.beat_started = Time.get_unix_time_from_system()
	row.revision = int(row.get("revision", 0)) + 1
	_pending.erase(id)
	_changed()
	print("[encounter] %s delivered %s" % [id, beat.id])
	_sync_presence()
	beat_delivered.emit(id, str(beat.id))

func _epoch() -> int:
	var context: Node = game.get("world_context") if is_instance_valid(game) else null
	return int(context.get("epoch")) if context != null else -1

func _beat_valid(id: String, index: int, epoch: int) -> bool:
	return active(id) and _epoch() == epoch and int(_store()[id].beat) == index

func _intent(row: Dictionary, beat: Dictionary) -> String:
	if str(beat.get("intent","")) != "": return str(beat.intent)
	# Saved pre-migration scripts remain semantic obligations, never dialogue drafts.
	if str(beat.get("text","")) == "": return ""
	return "Explain the unfinished encounter beat: %s. Your responsibility: %s. Generate your own words from the established encounter facts; never assume this explanation was already heard." % [str(beat.get("label",beat.id)),str((row.get("commitment",{}) as Dictionary).get(str(beat.get("speaker","")),row.get("title","")))]

func _cancel_pending(id: String) -> void:
	var waiting: Dictionary = _pending.get(id,{})
	var director: Node = game.get("director") if is_instance_valid(game) else null
	if director != null and str(waiting.get("line","")) != "": director.cancel_authored_line(str(waiting.line))
	_pending.erase(id)

func _generated_done(id: String, index: int, epoch: int) -> void:
	if _beat_valid(id,index,epoch): _deliver(id)

## Failed, silent or interrupted generation leaves the same required beat pending.
func _process(delta: float) -> void:
	var director: Node = game.get("director") if is_instance_valid(game) else null
	var store := _store()
	_presence_wait -= delta
	if _presence_wait <= 0.0:
		_presence_wait = 0.5
		_sync_presence()
	if store.is_empty(): return
	var idle: bool = director == null or (str(director.get("state")) == "idle" and not director.group.active())
	_settle = _settle + delta if idle else 0.0
	for key: String in store:
		var row: Dictionary = store[key]
		if str(row.get("status","")) != "active": continue
		var beats: Array = row.get("beats",[])
		var index := int(row.beat)
		if index >= beats.size(): continue
		var beat: Dictionary = beats[index]
		var waiting: Dictionary = _pending.get(key,{})
		if not waiting.is_empty():
			if director != null and str(waiting.get("line","")) != "":
				var lines: Dictionary = director.get("_authored_lines")
				if lines.has(str(waiting.line)): continue
			elif director != null and int(director.get("_turn_id")) == int(waiting.get("turn",-1)) and not idle: continue
			_pending.erase(key)
		if _settle < SETTLE_SECONDS: continue
		var intent := _intent(row,beat)
		if intent.is_empty() or director == null: continue
		var waited := Time.get_unix_time_from_system() - float(row.get("beat_started",0.0))
		if float(beat.get("await_turn_s",0.0)) > 0.0 and not bool(row.get("turn_tried",false)) and waited < float(beat.await_turn_s): continue
		var epoch := _epoch()
		var line_key := "encounter:%s:%s:%d" % [key,beat.id,epoch]
		if director.has_method("queue_generated_intent") and director.queue_generated_intent(str(beat.speaker),intent,line_key,_beat_valid.bind(key,index,epoch),_generated_done.bind(key,index,epoch)):
			row.attempts = int(row.get("attempts",0)) + 1
			_pending[key] = {"line":line_key,"speaker":str(beat.speaker),"beat":index,"epoch":epoch}
		_settle = 0.0
		return

## The speaker is registered with the director and close enough to the player to be heard.
func _available(director: Node, speaker: String) -> bool:
	if director == null or not director.characters.has(speaker): return false
	var node: Variant = director.characters[speaker].node
	var head: Variant = director.get("player_head")
	return is_instance_valid(node) and is_instance_valid(head) and (node as Node3D).global_position.distance_to((head as Node3D).global_position) < 12.0
