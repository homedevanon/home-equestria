extends RefCounted
## Group and ambient exchanges: choosing participants, requesting and validating a multi-pony reply, playing its beats, who heard what.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.

const GROUP := preload("res://world/ai/pony_group_conversation.gd")
const LLM := preload("res://world/ai/llm_client.gd")
const FACE_TAGS := preload("res://world/ai/pony_dialogue_tags.gd")
const VARIETY := preload("res://world/ai/dialogue_variety.gd")
const INTENT := preload("res://world/ai/pony_intent_consistency.gd")
const SENTENCES := preload("res://world/ai/speech_sentences.gd")
const AMBIENT_BUDGET := preload("res://world/ai/ambient_budget.gd")
const CHATTINESS := preload("res://world/ai/chattiness.gd")
const CHATTER := preload("res://world/ai/chatter_topics.gd")
const ADDRESSEE := preload("res://world/ai/addressee.gd")
const FILTERS := preload("res://world/ai/reply_filters.gd")
const CONTROLS := preload("res://world/ai/speech_controls.gd")
## Longest wait for bodies to turn before the first line; longer only while one walks up to the other.
const FACING_TIMEOUT := 4.0
const FACING_WALK_TIMEOUT := 10.0

## How long a group exchange may wait for a local model's reply (thread 43693039: Gemma 4 on a
## home server took about two minutes per group turn, past pony_group_conversation.gd's 150 s
## "Exchange became stale", so every reply was thrown away unseen). The request itself gives up at
## llm_client.gd LOCAL_TIMEOUT; this adds slack for the reply's last bytes.
const LOCAL_WAIT_SECONDS := LLM.LOCAL_TIMEOUT + 30.0
## A pony Anon talked with this recently is still in his conversation (_group_candidates).
const CHAT_PARTNER_SECONDS := 120.0

var host: Node
var _ambient_roll_wait := 1.0
var _heard_serial := 0
## Why the exchange stopped being valid (empty while valid), and why the last group reply was not
## played: printed to the log, read by tools/ai/test_group_reply_drops.gd.
var invalid_why := ""
var dropped_why := ""


func _init(owner_node: Node) -> void:
	host = owner_node


static func _distance_only_group_reason(reason: String) -> bool:
	return reason in ["Player left the conversation", "Participants can no longer hear each other", "Ambient company is comfortably out of earshot"]


func _group_turn_valid() -> bool:
	invalid_why = ""
	# A distant first member must not hide a removed/touched later member in the
	# group's early-return distance checks.
	for id: String in host.group.members:
		var node: Node3D = host.characters.get(id, {}).get("node")
		if not is_instance_valid(node) or not node.is_inside_tree() or not node.is_visible_in_tree():
			invalid_why = id + " left"; return false
		if host.group.ambient:
			if GROUP.interaction_stamp(node) != host.group.guard.get(id, []):
				invalid_why = id + " was touched or picked up"; return false
			if node.has_method("action_interruption_reason") and node.action_interruption_reason() != "":
				invalid_why = id + ": " + str(node.action_interruption_reason()); return false
	var reason: String = host.group.invalid_reason(host.characters, host.player_head, host.awareness, host._now())
	if reason.is_empty() or _distance_only_group_reason(reason): return true
	# A local model may still be writing the reply: the exchange waits for it (LOCAL_WAIT_SECONDS).
	if reason == "Exchange became stale" and host.state == "thinking" and _local_model() and host._now() - host.group.started_at <= LOCAL_WAIT_SECONDS: return true
	invalid_why = reason
	return false


func _local_model() -> bool:
	return is_instance_valid(host.llm) and host.llm.has_method("is_local") and bool(host.llm.is_local())


## Members of a chat Anon started stand still while its reply is on the way (a local model can take
## two minutes, thread 43693039): a pony on her own routine stops where she is, under the talk owner
## the exchange gives back (_clear_group). Held, story-claimed and command-led ponies keep what they
## are doing; ambient chats are held by their facing circle instead. A pony out with friends keeps
## her social owner: pony_social_groups.gd pauses an engaged member's outing itself, and taking the
## owner made her leave the group, breaking the outing up (dev 2026-09-23, director_company.gd).
func _hold_members() -> void:
	for id: String in host.group.members:
		var node: Variant = host.characters.get(id, {}).get("node")
		var nav: Node = node.get_node_or_null("Navigator") if is_instance_valid(node) else null
		if nav == null or not nav.has_method("stay") or host._encounter_claimed(id): continue
		if node.has_method("is_held") and node.is_held(): continue
		var owner := str(nav.command_owner)
		if not (owner.is_empty() or owner.begins_with("life:")): continue
		nav.stay()
		nav.command_owner = host.TALK_OWNER


## A pony Anon has been talking with (chat_last, not since her goodbye).
func _in_chat(id: String) -> bool:
	var entry: Dictionary = host.characters.get(id, {})
	var last := float(entry.get("chat_last", -1e9))
	return host._now() - last <= CHAT_PARTNER_SECONDS and last > float(host._released.get(id, -1e9))


func _clear_group() -> void:
	host._after_speech_actions.clear()
	host._retry_intent()
	host._authored_active = ""
	if host._sit_key != "": host._sit_agreed[host._sit_key] = host._now(); host._sit_key = ""
	for id in host.group.members:
		host._set_attention(id, null)
		# Hand walking-up-to-talk back to the ordinary routine.
		var node: Variant = host.characters[id].node if host.characters.has(id) else null
		var nav: Node = node.get_node_or_null("Navigator") if is_instance_valid(node) else null
		if nav != null and nav.command_owner == host.TALK_OWNER: nav.command_owner = ""
	host.facing.release(host.characters)
	if host.group.active():
		var wait_seconds := float(host.config.get_value("group_conversations/ambient_cooldown_seconds",12.0)) if host.group.ambient else float(host.config.get_value("group_conversations/cooldown_seconds",30.0))
		host._ambient_wait = maxf(0.0,wait_seconds)
		if host.tts.has_method("cancel"): host.tts.cancel()
	host.group.clear()
	host._listener_id = "player"
	host._group_index = -1
	host._prefetch_index = -1
	host._prefetch_result = {}


func _group_candidates(first: String) -> Array[String]:
	var ids: Array[String] = []
	if not bool(host.config.get_value("group_conversations/enabled", true)) or first == "": return ids
	var candidates: Array = []
	for id in host.characters:
		var node: Variant = host.characters[id].node
		if not is_instance_valid(node) or not node.is_inside_tree() or not node.is_visible_in_tree(): continue
		if node.has_method("is_held") and node.is_held(): continue
		if node.has_method("action_interruption_reason") and node.action_interruption_reason() != "": continue
		var distance: float = host.awareness.point(node).distance_to(host.awareness.point(host.player_head))
		if distance <= GROUP.RANGE: candidates.append({"id": id, "distance": distance})
	candidates.sort_custom(func(a, b): return a.distance < b.distance)
	# Ray work stays bounded even in a hundred-pony crowd.
	var offered: Array = candidates.slice(0, 12)
	if not offered.any(func(item): return item.id == first): return ids
	var companions: Array = host.social.companions(first) if is_instance_valid(host.social) else []
	# Only ponies in this conversation answer together (player board #55): the pony he speaks to,
	# ponies he names or addresses ("you two" and "everypony" take everyone here), her companions
	# out with her, and ponies he has been talking with. A pony merely passing keeps her routine;
	# before, every pony in earshot joined, turned to him and was held, and long chats drew a crowd.
	if not bool(host._address.get("everyone", false)):
		var addressed: Array = host._address.get("addressed", [])
		offered = offered.filter(func(item: Dictionary) -> bool: return item.id == first or item.id in addressed or item.id in companions or _in_chat(item.id) or _mentioned(item.id))
	offered.sort_custom(func(a, b):
		var rank_a := 0 if a.id == first else (1 if _mentioned(a.id) else (2 if a.id in companions else 3))
		var rank_b := 0 if b.id == first else (1 if _mentioned(b.id) else (2 if b.id in companions else 3))
		return rank_a < rank_b if rank_a != rank_b else a.distance < b.distance)
	for candidate in offered:
		var node: Node3D = host.characters[candidate.id].node
		if not host.awareness.can_hear(node, host.player_head, GROUP.RANGE): continue
		var compatible := true
		for id in ids:
			if not host.awareness.can_hear(node, host.characters[id].node, GROUP.RANGE): compatible = false; break
		if compatible: ids.append(candidate.id)
		if ids.size() == GROUP.MAX_MEMBERS: break
	return ids if not ids.is_empty() and ids[0] == first else []


## Named in his line, by any name she answers to ("Derpy" for Derpy Hooves, "Dash", "Pinky").
func _mentioned(id: String) -> bool:
	var candidate := {"id": id, "names": ADDRESSEE.names_for(id, host.characters[id].profile)}
	return ADDRESSEE.name_scores(host._player_text, [candidate]).has(id)


func movement_dialogue_allowed(id: String) -> bool:
	# Only friends out walking together talk on the move. Any other pony chat holds everyone
	# where they stand (dev 2026-09-25: "ponies mid conversation WALK AWAY from each other":
	# this used to be true for every ambient group, so the living world never paused them).
	return host.group.active() and host.group.ambient and id in host.group.members and host._walking_together(host.group.members)


func _begin_group(ids: Array[String], ambient := false) -> void:
	if ambient:
		ids = ids.filter(func(id: String) -> bool: return not host._authored_holds(id))
		if ids.is_empty(): return
	host.group.begin(ids, host.characters, host._now(), ambient)
	host.group.ambient_radius = 45.0
	if ambient and host.group.invalid_reason(host.characters,host.player_head,host.awareness,host._now()) != "":
		host._finish_silence(); return
	host.state = "thinking"
	host._current = ids[0]
	host._recorded = false
	host._pending_impression={}
	host._pending_text = ""
	host._show_indicator("thinking")
	host.speech.set_muted(false)
	if not host.group.active(): return
	var request: String = "Respond to the player's latest words: " + host._player_text
	# Whom he is speaking to (addressee.gd): the model otherwise guessed from the shared transcript,
	# which can miss the line he is answering (Strawberry Sunrise answered Dash's "Wanna race?").
	if not host._address_hint.is_empty(): request += "\n" + host._address_hint
	if ambient: request = ambient_request(ids)
	if ambient and host._group_request != "": request = host._group_request
	if ambient and ids.size() > 1:
		host._befriend(ids)
		_turn_to_each_other(ids)
	host._group_request = ""
	# A group the player addressed takes the connection; ponies chatting among themselves
	# simply skip this moment when it is taken (no error on screen).
	if not host.group.ambient:
		if not await host._take_llm():
			print("[ai] group request dropped: a newer turn started while the local model finished an earlier one")
			return
		# The exchange's clock starts when its request is sent, not while it queued behind another.
		host.group.started_at = host._now()
		_hold_members()
	if not _complete_group(host._group_prompt(), [{"role":"user", "content":request}], host._on_group_reply.bind(host._turn_id)):
		if host.group.ambient: host._finish_silence()
		else: host._fail("llm busy")


## The one request that writes a whole pony-to-pony conversation (dev 2026-10-14: "one ai call generates
## an entire convo all at once with all ponies involved"). A lone pony gets one brief remark at most.
func ambient_request(ids: Array[String]) -> String:
	var request := ""
	if ids.size() < 2:
		request = "An ordinary spontaneous remark from %s, to herself, about something she actually perceives or knows; silence is fine. Nobody will answer: do not address anypony by name and do not ask a question. Not addressed to Anon." % ids[0]
	else:
		var others := ", ".join(ids.slice(1))
		request = "Write the whole conversation now, all at once: an ordinary spontaneous chat that %s starts with %s, standing right here facing each other. Script every line in speaking order. Each participant speaks at least once, and whoever is spoken to answers on the very next line, politely and in character; nobody is left hanging. Usually 2 to 6 short lines, each one bringing something new, ending naturally (a goodbye, a plan or an easy pause). Mark each line [to: listener_id]. Continue only from completed shared speech. Anon being nearby is not a cue to greet or address him." % [ids[0], others]
	request += " " + CHATTER.seed_line() + " Ponies standing right here are present: talk with them, never about them or their house as if they were elsewhere."
	if ids.size() > 1 and host._walking_together(ids): request += " They are out together as friends, walking side by side while they talk: they can mention where they're heading, the walk, stopping somewhere, or suggest what to do next together."
	return request


## Before a word is said (dev 2026-10-14: Twilight greeted Lemon Hearts while they faced opposite ways):
## they stop, turn their bodies to each other (a group to its circle) and look at each other; the
## starter walks up first when she is a few steps away. Friends walking together keep walking.
func _turn_to_each_other(ids: Array[String]) -> void:
	if host._walking_together(ids): return
	host.facing.begin(ids, host.characters)
	_gaze_for(ids[0], ids[1])
	if ids.size() == 2: host._close_in(ids[0], ids[1])


## The speaker looks at her listener; everyone else looks at the speaker.
func _gaze_for(speaker: String, listener: String) -> void:
	if not host.characters.has(speaker): return
	if host.characters.has(listener): host._set_attention(speaker, host.characters[listener].node)
	for id in host.group.members:
		if id != speaker: host._set_attention(id, host.characters[speaker].node)


## Every line of a multi-pony script gets a pony listener, so speaker and listener look at each other:
## its [to:] when given, else whoever spoke last (an answer), else whoever speaks next.
static func address_lines(beats: Array, members: Array) -> void:
	if members.size() < 2: return
	for i in beats.size():
		var beat: Dictionary = beats[i]
		var speaker := str(beat.get("speaker_id", ""))
		var named := str(beat.get("listener_id", "none"))
		if named in members and named != speaker: continue
		var pick := ""
		for j in range(i - 1, -1, -1):
			if str(beats[j].speaker_id) != speaker: pick = str(beats[j].speaker_id); break
		if pick == "":
			for j in range(i + 1, beats.size()):
				if str(beats[j].speaker_id) != speaker: pick = str(beats[j].speaker_id); break
		if pick == "":
			for id in members:
				if str(id) != speaker: pick = str(id); break
		beat.listener_id = pick


## The scripted lines start once the bodies have turned (or a short timeout); the first voice is
## synthesized meanwhile.
func _start_script() -> void:
	if not host.group.ambient or not host.facing.active() or host.group.beats.is_empty() or host.facing.settled(host.characters):
		host._next_group_beat(); return
	var first: Dictionary = host.group.beats[0]
	host._current = str(first.speaker_id)
	_gaze_for(host._current, str(first.listener_id))
	host.state = "facing"
	host._facing_wait = FACING_TIMEOUT
	host._prefetch_next()


func _tick_facing_wait(delta: float) -> void:
	host._facing_wait -= delta
	var walking := false
	for id in host.group.members:
		var node: Variant = host.characters.get(id, {}).get("node")
		var nav: Node = node.get_node_or_null("Navigator") if is_instance_valid(node) else null
		if nav != null and nav.command_owner == host.TALK_OWNER and nav.get("_has_target") == true: walking = true
	var limit := FACING_WALK_TIMEOUT - FACING_TIMEOUT if walking else 0.0
	if host.facing.settled(host.characters) or host._facing_wait <= -limit: host._next_group_beat()


func _complete_group(prompt: String, messages: Array, done: Callable) -> bool:
	var label: String = host._take_purpose("group_ambient" if host.group.ambient else "group")
	host._trace_request("group_ambient" if host.group.ambient else "group", ",".join(host.group.members), prompt, messages)
	if not host.group.ambient:
		host._label_next(label)
		return host.llm.complete(prompt,messages,done)
	if not host._ambient_audible(host.group.members,45.0): return false
	var input_bytes := prompt.to_utf8_buffer().size() + JSON.stringify(messages).to_utf8_buffer().size() + 1024
	if not host.ambient_budget.reserve(input_bytes): return false
	host._label_next(label)
	if host.llm.has_method("complete_limited"):
		return host.llm.complete_limited(prompt,messages,done,{"input_bytes":AMBIENT_BUDGET.MAX_INPUT_BYTES,"output_tokens":AMBIENT_BUDGET.MAX_OUTPUT_TOKENS,"reasoning_room":AMBIENT_BUDGET.REASONING_TOKENS})
	return host.llm.complete(prompt,messages,done)


## The complete lines of a script the provider cut off at its output limit. The last line is
## dropped as possibly unfinished (replies arrive edge-stripped, so a clean cut after a newline
## cannot be told apart), as are code fences. Empty unless two participants still speak (one
## line for a lone pony), so a salvaged chat never leaves only its opener hanging.
static func complete_lines(text: String, members: Array) -> String:
	var lines: PackedStringArray = []
	for raw: String in text.strip_edges().split("\n", false):
		if not raw.strip_edges().begins_with("```"): lines.append(raw)
	if lines.is_empty(): return ""
	lines.remove_at(lines.size() - 1)
	var speakers := {}
	for raw: String in lines:
		var line := raw.strip_edges().trim_prefix("-").strip_edges()
		var colon := line.find(":")
		if colon <= 0: continue
		var speaker := line.left(colon).strip_edges().to_lower().replace(" ", "_").trim_prefix("**").trim_suffix("**")
		if speaker in members: speakers[speaker] = true
	if speakers.is_empty() or speakers.size() < mini(2, members.size()): return ""
	return "\n".join(lines)


func _ambient_audible(ids: Array, distance: float) -> bool:
	if not is_instance_valid(host.player_head): return false
	for id in ids:
		if host.characters.has(id) and is_instance_valid(host.characters[id].node) and host.awareness.can_hear(host.player_head,host.characters[id].node,distance): return true
	return false


func _on_group_reply(text: String, error: String, turn: int) -> void:
	if turn != host._turn_id or host.state != "thinking" or not host.group.active():
		# Never silent (thread 43693039: a local model's complete group lines never reached the game).
		dropped_why = "a newer turn started" if turn != host._turn_id else ("the exchange ended" if not host.group.active() else "state is " + str(host.state))
		print("[ai] group reply dropped (%s): %s" % [dropped_why, text.strip_edges().left(80)])
		return
	if error == LLM.OUTPUT_LIMIT_ERROR:
		# A script cut off at the output limit keeps its complete lines (tester 2026-10-20: ambient
		# chats showed "group llm: model output limit reached"). Ponies chatting among themselves do
		# not pay a second full-price request for them; a group the player addressed is first asked
		# once more with recovery room. Nothing usable: silence for ambient, an error code otherwise.
		var salvaged := complete_lines(text, host.group.members)
		if (salvaged.is_empty() or not host.group.ambient) and host._repair_response(text, "The exchange was cut off by the model output limit. Return fewer COMPLETE short lines, finishing every sentence and tag; omit optional feelings/thoughts.", true): return
		if salvaged.is_empty():
			if host.group.ambient: host._finish_silence(); return
			var addressed: String = host.group.members[0]
			_clear_group()
			host._current = addressed
			host._llm_error("group llm", error); return
		print("[ai] group reply cut off at the output limit; kept its complete lines")
		text = salvaged
		error = ""
	if error != "":
		if str(host.llm.get("last_outcome")) in ["refusal", "transient"]:
			# Ponies chatting among themselves just skip it; a group the player addressed shows the code.
			if host.group.ambient: host._finish_silence(); return
			var first: String = host.group.members[0]
			_clear_group()
			host._current = first
		host._llm_error("group llm", error); return
	if not host._listener_available() or not host._group_turn_valid():
		dropped_why = invalid_why if not invalid_why.is_empty() else "the listener is gone"
		print("[ai] group reply dropped (%s)" % dropped_why)
		host.interrupt(); return
	dropped_why = ""
	# Played from now on: a reply that took its time (a local model) gets the whole exchange window
	# for its lines, so its second line is not cut as stale (_next_group_beat).
	host.group.started_at = host._now()
	var contexts := {}
	for id in host.group.members:
		host.awareness.sample(id, host.characters[id].node, host.characters, host.player_head, host._now(), host._earshot(id), true)
		contexts[id] = host.actions.context(id, host._action_targets(id))
	text = host.take_story_notes(text, true)
	var decoded: Dictionary = host.group.decode(text, turn, contexts, true)
	if host.group.ambient and text.strip_edges() == "[silence]": decoded = {"beats":[]}
	if decoded.has("fallback"):
		if host._repair_response(text, "Write each beat as its own line: speaker_id: spoken words [tags].", true): return
		if host.group.ambient:
			# Legacy plain text remains an opener, not a distant reply to the player.
			var plain := text
			decoded = {"beats":[]} if text.strip_edges() == "[silence]" or host._strip_tag(plain).is_empty() else {"beats":[{"speaker_id":host.group.members[0],"listener_id":"none","speech":plain,"actions":[]}]}
		else:
			_clear_group()
			host._set_attention(host._current, host.player_head)
			host.speech.set_muted(false)
			host._on_reply(text, error, turn)
			return
	if decoded.has("error"):
		if host._repair_response(text, str(decoded.error), true): return
		host._fail("invalid group exchange: " + decoded.error); return
	# Provider refusal boilerplate (reply_filters.gd) is never voiced; a line of nothing else goes.
	# No spoken line left: a refusal, handled like one that survived llm_client.gd's retries.
	var refused := false
	for beat: Dictionary in decoded.beats:
		if bool(beat.get("silent_travel", false)): continue
		var own_words := FILTERS.without_refusals(str(beat.speech))
		if own_words == str(beat.speech): continue
		refused = true
		beat.speech = own_words
		if not FILTERS.has_speech(own_words): beat.refused = true
	if refused:
		print("[ai] group reply: dropped refusal boilerplate")
		decoded.beats = decoded.beats.filter(func(item: Dictionary) -> bool: return not bool(item.get("refused", false)))
		if decoded.beats.filter(func(item: Dictionary) -> bool: return not bool(item.get("silent_travel", false))).is_empty():
			if host.group.ambient: host._finish_silence(); return
			var addressed: String = host.group.members[0]
			_clear_group()
			host._current = addressed
			host._llm_error("group llm", LLM.REFUSAL_ERROR); return
	var previous := {}
	for id in host.group.members: previous[id] = host.characters[id].spoken.duplicate()
	var said := {}
	for beat in decoded.beats:
		if bool(beat.get("silent_travel", false)): continue
		var missing := INTENT.missing(host._player_text, beat.speech, beat.actions) if not host.group.ambient else ""
		if not missing.is_empty():
			if host._repair_response(text, missing, true): return
			host._fail("Accepted trip lacks travel action"); return
		var tagged := FACE_TAGS.parse(beat.speech)
		beat.face = tagged.face
		beat.face_map = FACE_TAGS.sentence_faces(SENTENCES.split(beat.speech))
		beat.gesture = tagged.gesture
		beat.speech = host.clean_reply(tagged.speech)
		if host._strip_tag(beat.speech).is_empty():
			if host._repair_response(text, "One line contains only control tags, with no spoken dialogue. Remove that line or write a brief spoken answer to the actual question.", true): return
			host._fail("empty group speech"); return
		# A sentence this pony said moments ago (or earlier in this exchange) is left out locally.
		var earlier: Array = FILTERS.recent(host._said_recently, str(beat.speaker_id), host._now()) + said.get(beat.speaker_id, [])
		beat.speech = FILTERS.without_repeats(str(beat.speech), earlier)
		said[beat.speaker_id] = said.get(beat.speaker_id, []) + FILTERS.sentences(host._strip_tag(beat.speech))
		var repetition := VARIETY.reason(host._strip_tag(beat.speech), previous[beat.speaker_id], host._player_text)
		# A repeated pet name is dropped from the line, not re-requested at full prompt price.
		for _attempt in VARIETY.PET_NAMES.size():
			var fixed := VARIETY.local_fix(beat.speech, repetition)
			if fixed.is_empty() or host._strip_tag(fixed).strip_edges().is_empty(): break
			beat.speech = fixed
			repetition = VARIETY.reason(host._strip_tag(beat.speech), previous[beat.speaker_id], host._player_text)
		if repetition != "" and host.group.ambient:
			# A whole background conversation is not re-requested (full prompt price) for one
			# repeated line: that line is simply left out.
			beat.drop = true; continue
		if repetition != "" and not host._rewrite_used:
			host._rewrite_used = true
			host._next_purpose = "group_variety_revision"
			if _complete_group(host._group_prompt() + "\nRevise once to remove repetition: " + repetition + "\nDraft: " + text, [{"role":"user", "content":host._player_text if not host.group.ambient and not host._player_text.is_empty() else "An optional quiet exchange."}], host._on_group_reply.bind(turn)): return
			host._fail("group rewrite unavailable"); return
		previous[beat.speaker_id].append(host._strip_tag(beat.speech))
	if host.group.ambient:
		decoded.beats = decoded.beats.filter(func(item: Dictionary) -> bool: return not bool(item.get("drop", false)))
		address_lines(decoded.beats, host.group.members)
		var speakers := {}
		for beat: Dictionary in decoded.beats: speakers[beat.speaker_id] = true
		if host.group.members.size() > 1 and speakers.size() == 1 and host._repair_response(text, "Only one pony speaks. Write the whole conversation: the pony she addresses answers on the very next line, and each participant speaks at least once.", true): return
	host.group.beats = voiced_beats(SENTENCES.expand(decoded.beats))
	_start_script()


func _next_group_beat() -> void:
	if not host.group.active(): return
	if not host._listener_available() or not host._group_turn_valid(): host.interrupt(); return
	if host.group.cursor >= host.group.beats.size(): host._finish_silence(); return
	var reason: String = host.group.invalid_reason(host.characters, host.player_head, host.awareness, host._now())
	var next: Dictionary = host.group.beats[host.group.cursor]
	var actor: Node3D = host.characters.get(str(next.speaker_id), {}).get("node")
	if not is_instance_valid(actor) or not actor.is_inside_tree(): host.interrupt(); return
	if str(next.listener_id) not in ["player", "none"]:
		var listener_node: Node3D = host.characters.get(str(next.listener_id), {}).get("node")
		if not is_instance_valid(listener_node) or not listener_node.is_inside_tree(): host.interrupt(); return
	if not reason.is_empty() and host.group.cursor > 0 and not (bool(next.get("continuation", false)) and str(next.speaker_id) == host._current):
		host._finish_silence(); return
	if bool(next.get("silent_travel", false)):
		# Same locality, encounter and capability checks as spoken movement. The preceding
		# trip line has finished; no fabricated speech, TTS request or conversation history.
		var travel_error: String = host.actions.commit(str(next.speaker_id), next.actions, host._action_targets(str(next.speaker_id)), host._turn_id)
		if not travel_error.is_empty(): push_warning("Companion travel: " + travel_error)
		host.group.cursor += 1
		host._next_group_beat.call_deferred()
		return
	host._set_attention(host._current, null)
	if host._listener_id != "player": host._set_attention(host._listener_id, null)
	host._group_index = host.group.cursor
	var beat: Dictionary = host.group.beats[host.group.cursor]
	host.group.cursor += 1
	host._current = beat.speaker_id
	host._listener_id = beat.listener_id
	host._pending_face = str(beat.get("face", ""))
	host._pending_gesture = str(beat.get("gesture", ""))
	host._pending_impression=beat.get("impression",{})
	host._pending_text = host.clean_reply(beat.speech)
	if host._strip_tag(host._pending_text).is_empty(): host._finish_silence(); return
	if not CONTROLS.has_words(host._strip_tag(host._pending_text)):
		# "..." alone: nothing to voice (the ponese voice refused it: "empty ponese line").
		host._next_group_beat.call_deferred(); return
	host._pending_actions = beat.actions.duplicate(true)
	host._voice_id += 1
	host._recorded = false
	host._history_record = {}
	var listener: Node3D = host.player_head if host._listener_id == "player" else (host.characters[host._listener_id].node if host.characters.has(host._listener_id) else null)
	host._set_attention(host._current, listener)
	if host.group.ambient and is_instance_valid(host.social): host.social.pause_for_dialogue(host._current)
	# Everyone else in the exchange turns to whoever is talking, and a pony talking to
	# another pony a few steps away walks up to her first (dev 2026-09-23).
	for id in host.group.members:
		if id != host._current and host.characters.has(host._current): host._set_attention(id, host.characters[host._current].node)
	if host.characters.has(host._listener_id) and not host.group.ambient: host._close_in(host._current, host._listener_id)
	host.state = "rendering"
	host._ponese_attempted = false
	host._render_wait = 0.0
	host.speech.set_muted(false)
	host._show_indicator("thinking")
	if not host.group.ambient or _player_hears_current(): host.hud.set_state("thinking", "")
	if host._prefetch_index == host._group_index:
		if not host._prefetch_result.is_empty(): host._on_tts(host._prefetch_result.path, host._prefetch_result.error, host._turn_id, host._voice_id)
		return
	var profile: Dictionary = host.characters[host._current].profile
	if not host._synthesize_voice(host._pending_text, profile, str(profile.get("tts_default_emotion", "neutral")), host._on_tts.bind(host._turn_id, host._voice_id)): host._voice_error("tts busy")


## Sentence beats (speech_sentences.gd expand) that have words to say. A wordless piece ("..." before
## "Hello.", a lone "~") hands its tags and first-piece role to the next piece of the same line, or its
## feelings to the piece before; a line with no words at all keeps only its tags, as a silent step.
static func voiced_beats(beats: Array) -> Array:
	var out: Array = []
	for i in beats.size():
		var beat: Dictionary = beats[i]
		if bool(beat.get("silent_travel", false)) or CONTROLS.has_words(CONTROLS.sanitize(str(beat.get("speech", "")))):
			out.append(beat); continue
		var next: Dictionary = beats[i + 1] if i + 1 < beats.size() else {}
		if not next.is_empty() and str(next.get("speaker_id", "")) == str(beat.get("speaker_id", "")) and bool(next.get("continuation", false)):
			next.continuation = bool(beat.get("continuation", false))
			if not bool(beat.get("continuation", false)): next.actions = beat.get("actions", [])
			continue
		if bool(beat.get("continuation", false)) and not out.is_empty() and str(out[-1].get("speaker_id", "")) == str(beat.get("speaker_id", "")):
			if beat.has("impression"): out[-1].impression = beat.impression
			continue
		if not (beat.get("actions", []) as Array).is_empty():
			var step := beat.duplicate(true)
			step.silent_travel = true
			out.append(step)
	return out


func _prefetch_next() -> void:
	if not host._listener_available() or not host._group_turn_valid(): return
	# A streamed line is still being rendered while it plays; the next one is asked for when the
	# voice client is free again (tts_client.gd live_render_finished).
	if host.tts.has_method("can_stream") and host.tts.can_stream() and host.tts.busy:
		if not host.tts.live_render_finished.is_connected(_on_live_render_finished):
			host.tts.live_render_finished.connect(_on_live_render_finished)
		return
	var index: int = host.group.cursor
	if index >= host.group.beats.size(): return
	var beat: Dictionary = host.group.beats[index]
	if bool(beat.get("silent_travel", false)): return
	var actor: Node3D = host.characters.get(str(beat.speaker_id), {}).get("node")
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return
	var profile: Dictionary = host.characters[beat.speaker_id].profile
	host._prefetch_index = index
	host._prefetch_result = {}
	if not host._synthesize_voice(beat.speech, profile, str(profile.get("tts_default_emotion", "neutral")), host._on_prefetch.bind(host._turn_id, index)):
		host._prefetch_result = {"path":"", "error":"prefetch unavailable"}


func _on_live_render_finished() -> void:
	if host.state == "speaking" and host.group.active() and host._prefetch_index != host.group.cursor:
		_prefetch_next()


func _on_prefetch(path: String, error: String, turn: int, index: int) -> void:
	if turn != host._turn_id or not host.group.active() or index != host._prefetch_index: return
	host._prefetch_result = {"path":path, "error":error}
	if host.state == "rendering" and host._group_index == index: host._on_tts(path, error, turn, host._voice_id)


func _audience(source: Node3D) -> Array[String]:
	var result: Array[String] = []
	if not is_instance_valid(source): return result
	var candidates: Array = []
	for id in host.characters:
		var node: Variant = host.characters[id].node
		if is_instance_valid(node) and node.is_inside_tree():
			var distance: float = host.awareness.point(node).distance_to(host.awareness.point(source))
			if distance <= host._earshot(id): candidates.append({"id":id, "distance":distance})
	candidates.sort_custom(func(a, b): return a.distance < b.distance)
	# Chosen participants must be checked even in a densely packed crowd.
	if host.group.active(): candidates.sort_custom(func(a,b):
		var first: bool = a.id in host.group.members; var second: bool = b.id in host.group.members
		return first if first != second else a.distance < b.distance)
	for item in candidates.slice(0, 12):
		if host.awareness.can_hear(host.characters[item.id].node, source, host._earshot(item.id)): result.append(item.id)
	return result


func _record_heard(speaker_id: String, listener_id: String, text: String, audience: Array[String]) -> void:
	_heard_serial += 1
	var event := {"id":_heard_serial, "speaker_id":speaker_id, "listener_id":listener_id, "text":text}
	for id in audience:
		if not host.characters.has(id): continue
		var heard: Array = host.characters[id].heard
		heard.append(event)
		while heard.size() > 16: heard.pop_front()
	if is_instance_valid(host.world_context):
		var place:String=host.awareness._observations.get(speaker_id,{}).get("place",{}).get("id","")
		var saved_id:String=host.world_context.record("heard_speech",text,audience,[speaker_id,listener_id],"",place)
		if saved_id!="":event.id=saved_id # Same identity before/after resident unload or restart.
		if saved_id!="" and speaker_id in audience and listener_id in audience and speaker_id!=listener_id:
			host.world_context.shared_event("conversation",[speaker_id,listener_id],saved_id+"-company","You exchanged a completed spoken line with "+listener_id+" and "+speaker_id+".")


func _tick_ambient(delta: float) -> void:
	if host.player_approaches.active(): return
	host._ambient_wait = maxf(0.0,host._ambient_wait-delta)
	if host._ambient_wait > 0.0 or host.state != "idle" or host.speech.state == "hearing":
		_ambient_roll_wait = 1.0; return
	_ambient_roll_wait -= delta
	if _ambient_roll_wait > 0.0: return
	_ambient_roll_wait = 1.0 # No accumulated dice or request burst after a stalled frame.
	if not bool(host.config.get_value("group_conversations/ambient",true)) or not preload("res://world/ai/ai_config.gd").background_allowed(host.config) or not is_instance_valid(host.player_head) or not host.player_head.is_inside_tree(): return
	if not host.ambient_budget.available(): return
	if not host._ambient_continuation.is_empty():
		var company: Array = host._ambient_continuation.duplicate(); host._ambient_continuation.clear()
		if host._now()-host._ambient_continued_at < 150.0 and host._ambient_audible(company,45.0) and company.all(func(id): return not host._authored_holds(str(id)) and host.characters.has(id) and host.ambient_chatter.eligible(host.characters[id].node,host.player_head,45.0)):
			host._current = company[0]; host._turn_id += 1; host._player_text = ""; host._rewrite_used = false
			_begin_group(company,true); return
	var chance := clampf(float(host.config.get_value("group_conversations/ambient_chance_per_pony_second",.012)),0.0,1.0)
	# Time of day and the player's chattiness setting (world/ai/chattiness.gd).
	var clock: Node = host.get_node_or_null("/root/TimeOfDay")
	chance *= CHATTINESS.factor(float(clock.hours) if clock != null else 12.0, float(host.config.get_value("chattiness", 1.0)))
	if chance <= 0.0: return
	var reply_chance := clampf(float(host.config.get_value("group_conversations/ambient_reply_chance",.8)),0.0,1.0) if bool(host.config.get_value("group_conversations/enabled",true)) else 0.0
	var eligible_characters: Dictionary = host.characters.duplicate()
	for id: String in eligible_characters.keys():
		if host._authored_holds(id) or host.quiet_moment(id): eligible_characters.erase(id)
	var ids: Array[String] = host.ambient_chatter.choose(eligible_characters,host.player_head,host.awareness,host._now(),_ambient_radius(),chance,reply_chance,maxf(0,float(host.config.get_value("group_conversations/ambient_pony_cooldown_seconds",75.0))))
	if ids.is_empty(): return
	if not host._ambient_audible(ids,30.0): return
	host._current = ids[0]
	host._turn_id += 1
	host._player_text = ""
	host._rewrite_used = false
	_begin_group(ids, true)


func _ambient_radius() -> float:
	var radius := clampf(float(host.config.get_value("group_conversations/ambient_radius_m",30.0)),1.0,30.0)
	if host.player_head is Camera3D: radius = minf(radius,host.player_head.far)
	return radius


func _player_hears_current() -> bool:
	if not host.characters.has(host._current) or not is_instance_valid(host.player_head): return false
	# Pony voices are not occluded: when the 30 m voice reaches you, so do its subtitle and
	# the mic mute. The line-of-sight test hid the text of ponies chatting behind a house
	# while their voices were plainly audible (dev, 2026-09-22).
	var node: Variant = host.characters[host._current].node
	return is_instance_valid(node) and node.is_inside_tree() and host.awareness.point(host.player_head).distance_to(host.awareness.point(node)) <= 30.0
