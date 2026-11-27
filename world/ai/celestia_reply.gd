extends Node
## Princess Celestia answers letters (player thread report 2026-10-29: Twilight talked about her
## unanswered letter to Celestia for ten in-game days, a goal that could never complete). A letter
## Spike sends with his green fire (spike.gd send_letter calls letter_sent through the group) books
## one reply per sender for the next morning, kept in the world save
## (world_context.state.celestia_replies) so a reload keeps it. When it is due Spike, if he is in
## the world and free, belches the reply scroll back up in green flame (spike.gd receive_letter);
## the sender and Twilight, whose letters Spike carries, remember it as a world event. With no
## Spike in the world the event alone arrives; if he stays asleep or busy it arrives without him
## at noon. Created by relationship_runtime.gd setup.
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const STATE_KEY := "celestia_replies"
const GROUP := "celestia_reply"
const MORNING_HOUR := 7.0
## A letter sent before this hour went "last night": the reply comes that same morning.
const NIGHT_ENDS := 4.0
const LATEST_HOUR := 12.0
const SPIKE := "spike"
const TWILIGHT := "twilight_sparkle"
const POLL := 2.0
const TEXT := "Princess Celestia's reply to the letter %s sent arrived%s. She thanks you for writing and is glad Anon is safe and welcome in Ponyville. She will look into how %s got here herself, so there is no need to write to her about it again for now."
var game: Node
var _poll := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group(GROUP)

## Called through the group the moment a letter goes up in green fire.
func letter_sent(sender: String) -> void:
	var clock := _clock()
	if clock != null: schedule(sender, int(clock.day), float(clock.hours))

## Books the reply for the next morning; false while one is already on its way to this sender.
func schedule(sender: String, day: int, hours: float) -> bool:
	var pending: Variant = _pending()
	if pending == null or sender.is_empty() or pending.has(sender): return false
	pending[sender] = {"due": float(day + (0 if hours < NIGHT_ENDS else 1)) + MORNING_HOUR / 24.0}
	game.world_context._changed()
	return true

func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0: return
	_poll = POLL
	var clock := _clock()
	if clock != null: tick(int(clock.day), float(clock.hours))

## Delivers every reply that is due at this time of the day count.
func tick(day: int, hours: float) -> void:
	var pending: Variant = _pending()
	if pending == null or (pending as Dictionary).is_empty(): return
	var now := float(day) + hours / 24.0
	for sender: String in (pending as Dictionary).keys():
		var row: Variant = pending[sender]
		var due: float = float((row as Dictionary).get("due", 0.0)) if row is Dictionary else 0.0
		if now < due: continue
		var spike := _spike()
		var belched := false
		if spike != null:
			belched = bool(spike.call("receive_letter"))
			# Asleep, held or busy: the scroll waits for him until noon, then arrives anyway.
			if not belched and now < due + (LATEST_HOUR - MORNING_HOUR) / 24.0: continue
		_deliver(sender, int(floorf(due)), belched)
		pending.erase(sender)
		game.world_context._changed()

func _deliver(sender: String, due_day: int, belched: bool) -> void:
	var w: Dictionary = PLAYER_FORM.pronouns(PLAYER_FORM.active(get_tree()) if is_inside_tree() else {})
	var text := TEXT % [sender.replace("_", " ").capitalize(), " in a puff of Spike's green fire" if belched else "", str(w.subject)]
	var witnesses: Array = [sender]
	if TWILIGHT not in witnesses: witnesses.append(TWILIGHT)
	if belched and SPIKE not in witnesses: witnesses.append(SPIKE)
	game.world_context.record("letter_reply", text, witnesses, [sender], "celestia_reply:%s:%d" % [sender, due_day])

func _pending() -> Variant:
	if game == null or not is_instance_valid(game.get("world_context")): return null
	var context: Node = game.world_context
	if context.get("_read_only") == true: return null
	if not context.state.get(STATE_KEY) is Dictionary: context.state[STATE_KEY] = {}
	return context.state[STATE_KEY]

func _spike() -> Node:
	var mares: Variant = game.get("mares")
	if not mares is Array: return null
	for actor: Variant in mares:
		if not is_instance_valid(actor) or not (actor as Node).is_inside_tree() or not (actor as Node).has_method("receive_letter"): continue
		var identity: Variant = (actor as Node).get("identity")
		if identity is Resource and str((identity as Resource).get("id")) == SPIKE: return actor
	return null

func _clock() -> Node:
	return get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
