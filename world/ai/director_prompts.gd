extends RefCounted
## Prompt building: situation block, system prompt, durable context, action/place lists, group prompt and the opt-in request trace.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.

const ANON_DAY := preload("res://world/ai/anon_day.gd")
const VARIETY := preload("res://world/ai/dialogue_variety.gd")
const FACE_TAGS := preload("res://world/ai/pony_dialogue_tags.gd")
const ACTION_SCHEMA := preload("res://world/ai/pony_action_schema.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const ARRIVAL_CONTEXT := preload("res://world/ai/arrival_context.gd")
const MEMORY := preload("res://world/ai/memory/story_memory.gd")
const TOWN_TALK := preload("res://world/ai/memory/town_talk.gd")
const IMPRESSIONS := preload("res://world/ai/impressions/pony_impressions.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const HEARD_TRANSCRIPT_BYTES := 8192
## Cache layout markers, stripped by llm_client.build_request (docs/AI_TOKENS_AND_CACHING_2026_10_25.md).
const LLM := preload("res://world/ai/llm_client.gd")

var host: Node
## The fit loop uses the original size so sharing never silently expands memory slices.
var _group_saved_bytes := 0


func _init(owner_node: Node) -> void:
	host = owner_node


## Everything the model needs about right now, as a short block after the persona.
func situation_block(id: String) -> String:
	var entry: Dictionary = host.characters[id]
	var node: Variant = entry.node
	var lines: PackedStringArray = []
	lines.append("Situation:")
	if not is_instance_valid(node) or not node.is_inside_tree(): return "Situation: character unavailable."
	var observation: Dictionary = host.awareness.sample(id, node, host.characters, host.player_head, host._now(), host._earshot(id), true)
	lines.append_array(host.awareness.describe(observation, str(host.config.get_value("player_name", "Anon")), host._now()))
	lines.append(preload("res://world/characters/accessories/pony_wardrobe.gd").situation_line(node))
	if is_instance_valid(host.world_context): lines.append(preload("res://world/ai/bit_payments.gd").situation_line(host.world_context, id))
	# The player-body line rides in the fixed head (solo_head), not in every live block.
	# First meeting or not, and whether she knows his name (player_bonds.gd knowledge_line).
	if is_instance_valid(host.world_context) and is_instance_valid(host.world_context.player_bonds) and host.world_context.player_bonds.has_method("knowledge_line"):
		lines.append(host.world_context.player_bonds.knowledge_line(id))
	var tod: Node = host.get_node_or_null("/root/TimeOfDay")
	if tod != null and "hours" in tod:
		var h := float(tod.hours)
		var word := "night"
		if h >= 5.0 and h < 8.0: word = "dawn"
		elif h >= 8.0 and h < 12.0: word = "morning"
		elif h >= 12.0 and h < 17.0: word = "afternoon"
		elif h >= 17.0 and h < 20.0: word = "evening"
		lines.append("- Time: %s (%02d:%02d)." % [word, int(h), int(fmod(h, 1.0) * 60.0)])
	# What Anon has done today, as far as she knows (world/ai/anon_day.gd, thread report 2026-11-01).
	var anon_day := ANON_DAY.line(host.get_tree(), id) if host.is_inside_tree() else ""
	if not anon_day.is_empty(): lines.append(anon_day)
	# Ponies Anon names who are not here: where they really are beats any rumour (town_talk.gd,
	# thread report 2026-11-03: a made-up cider stand stayed "fact" for hours).
	var story := _story()
	if story != null and host.is_inside_tree():
		var where: String = TOWN_TALK.where_now(host.get_tree(), str(host.get("_player_text")), _present(id), story.name_of)
		if not where.is_empty(): lines.append(where)
	var schedule: Node = node.get_node_or_null("Schedule")
	if schedule != null and schedule.has_method("situation_line"):
		var line: String = schedule.situation_line()
		if line != "":
			lines.append(line)
	var outcomes: String = host.actions.outcomes(id)
	if node.has_meta("life_intent"):
		lines.append("- Your current activity intention: " + str(node.get_meta("life_intent")))
	if node.has_meta("day_plan"):
		lines.append("- Your plans for today (loosely; you get sidetracked): " + str(node.get_meta("day_plan")))
	if node.has_meta("social_group"):
		lines.append("- " + _company_line(node.get_meta("social_group")))
	if outcomes != "": lines.append("Your action outcomes (not dialogue):\n" + outcomes)
	if node.has_meta("hayburger_order_context"): lines.append(str(node.get_meta("hayburger_order_context")))
	if node.has_meta("show_watching"): lines.append(str(node.get_meta("show_watching")))
	# Pinned letters and agreed meetings (docs/LETTERS_PLAN_2026_10_29.md); "" costs nothing.
	for provider: Node in host.get_tree().get_nodes_in_group("pony_prompt_notes"):
		if provider.has_method("prompt_note"):
			var note: String = str(provider.call("prompt_note", id))
			if not note.is_empty(): lines.append(note)
	if node.has_meta("relationship_runtime"):
		lines.append(node.get_meta("relationship_runtime").prompt_for(id))
	if entry.has("chat_since") and host._now() - float(entry.get("chat_last", -1e9)) < 120.0 and host._now() - float(entry.chat_since) > 150.0 \
			and node.has_method("posture_status") and str(node.posture_status().get("kind", "stand")) == "stand":
		lines.append("- You two have been talking for a while now. If it suits you and the moment, settle in: sit down or lie down ([sit] / [lie_down]) and keep chatting; no need to announce it.")
	return "\n".join(lines)


## Walking company in a few words instead of its raw JSON record.
func _company_line(group: Variant) -> String:
	if not group is Dictionary: return "Out with company (not proof of arrival or private knowledge)."
	var names: Array = (group.get("members", []) as Array).map(func(m): return _name(str(m)))
	return "Out with %s: %s, %s (an intention, not proof of arrival or private knowledge)." % [", ".join(names), str(group.get("intention", "")), str(group.get("state", ""))]


## AnonPony: what Anon is and which pronouns fit. It covers princess visits, the Luna dream,
## chatter and persona files that still say he/him. Empty for human Anon, whose prompt is unchanged.
func _anon_pony_line() -> String:
	if not host.is_inside_tree(): return ""
	var form: Dictionary = PLAYER_FORM.active(host.get_tree())
	if not PLAYER_FORM.is_pony(form): return "- Player body: a human with hands and feet; he is not a pony. You are a pony with hooves; horn magic and wings depend on your actual race. This does not establish that you know his name or past."
	var words: Dictionary = PLAYER_FORM.pronouns(form)
	return "- Player body: %s, a pony with hooves, not human hands. Refer to the player as %s/%s; where other instructions say he/him/his about Anon, use %s/%s/%s. This does not establish that you know the player's name or past." % [
		PLAYER_FORM.describe(form), words.subject, words.object, words.subject, words.object, words.possessive]


## The active story encounter's pinned frame for this speaker, or "" (encounter_runtime.gd).
func _encounter_frame(id: String) -> String:
	var runtime: Node = host.get_tree().get_first_node_in_group("encounters") if host.is_inside_tree() else null
	return runtime.frame_for(id) if runtime != null else ""


func _encounter_claimed(id: String) -> bool:
	var runtime: Node = host.get_tree().get_first_node_in_group("encounters") if host.is_inside_tree() else null
	return runtime != null and runtime.claimed(id)


## Witnessed speech as plain lines ("Lyra to Bon Bon: ..."), newest kept within the byte budget.
func heard_lines(events: Array) -> String:
	var lines: PackedStringArray = []
	var used := 0
	for i in range(events.size() - 1, -1, -1):
		var e: Dictionary = events[i]
		var speaker := _name(str(e.get("speaker_id", "")))
		var listener := str(e.get("listener_id", ""))
		var to := "" if listener in ["", "none"] else " to " + _name(listener)
		var line := "%s%s: \"%s\"" % [speaker, to, str(e.get("text", ""))]
		if used + line.length() > HEARD_TRANSCRIPT_BYTES / 2: break
		lines.insert(0, line); used += line.length() + 1
	return "(nothing yet)" if lines.is_empty() else "\n".join(lines)


func _name(id: String) -> String:
	if id == "player": return "Anon"
	if host.characters.has(id): return str(host.characters[id].profile.get("name", id))
	return id.replace("_", " ").capitalize()


## The speaker and the ponies she sees now (her last awareness sample).
func _present(id: String) -> Array:
	var observed: Dictionary = host.awareness._observations.get(id, {}) if host.get("awareness") != null else {}
	var present: Array = [id]
	for peer: Variant in observed.get("visible", []) + observed.get("present", []):
		if peer is Dictionary and str((peer as Dictionary).get("id", "")) not in present: present.append(str((peer as Dictionary).get("id", "")))
	return present


func _story() -> RefCounted:
	if not is_instance_valid(host.world_context): return null
	var story: RefCounted = host.world_context.get("story")
	return story if story != null and story.is_open() else null


## Bound witnessed transcript separately: it lives in the system prompt, outside
## the client's message-history limit. Retain whole recent events and saved originals.
static func heard_transcript(events: Array) -> String:
	var start := events.size()
	var bytes := 2 # JSON array brackets.
	while start > 0:
		var event_bytes := JSON.stringify(events[start - 1]).to_utf8_buffer().size()
		var separator := 1 if start < events.size() else 0
		if bytes + event_bytes + separator > HEARD_TRANSCRIPT_BYTES: break
		start -= 1
		bytes += event_bytes + separator
	var transcript := JSON.stringify(events.slice(start))
	if start > 0:
		transcript += "\nSome witnessed speech omitted for space. Use durable memories; do not invent missing conversation."
	return transcript


## Solo request layout (dev 2026-10-22 token diet; tester capture: 29 KB system prompts, of which
## 15 KB fixed rules sat behind the changing Situation): the fixed head first (shared rules, reply
## format, every tag rule, player body), then what changes rarely (player directions, her persona),
## then the live part (situation, memories, heard speech, what she can do now and where she can go).
func system_prompt(id: String) -> String:
	var entry: Dictionary = host.characters[id]
	var situation: String = host.situation_block(id)
	var frame := _encounter_frame(id)
	if frame != "": situation = frame + "\n\n" + situation
	var intent: String = host._generated_intent_frame(id)
	if intent != "": situation = intent + "\n\n" + situation
	if is_instance_valid(host.world_context) and is_instance_valid(host.world_context.impressions):
		var impressions: Node = host.world_context.impressions
		situation += "\n" + (impressions.standing_line(id) if impressions.has_method("standing_line") else impressions.prompt_for(id))
	# Stable for this pony (head, player directions, persona), then the live part, which the client
	# sends after the conversation history so the stable part and the history can be cached.
	var prompt: String = solo_head() + LLM.HEAD_END + host.feedback.prompt([id]) + "\n\n" + persona_text(str(entry.prompt)) + LLM.LIVE_START + situation
	var durable := _durable_context(id)
	if durable != "": prompt += "\n\n" + durable
	var story := _story()
	if story == null:
		prompt += "\n\nCompleted speech you personally heard (speaker-labelled, not private thoughts): " + heard_transcript(entry.heard.slice(maxi(0, entry.heard.size() - 8)))
	var actions: String = host._action_prompt(id)
	if actions != "": prompt += "\n\n" + actions
	if story != null and host.get("_brain_due") == true:
		prompt += "\n\n" + MEMORY.BRAIN_INSTRUCTION
		# Real off-screen ponies for ELSEWHERE (town_talk.gd, thread report 2026-11-03); "" costs nothing.
		var town: String = story.town_note(host.get_tree(), _present(id)) if host.is_inside_tree() else ""
		if not town.is_empty(): prompt += "\n" + town
	# A pet topic she keeps coming back to across days (player thread report 2026-10-29); only
	# costs tokens on the turns it fires.
	var fixation: String = VARIETY.fixation_note(entry.spoken, host._player_text)
	if fixation != "": prompt += "\n\n" + fixation
	return prompt


## Persona files repeat two shared sentences that system.md already states for every pony ("Hospitality is
## not friendship", "Claim ... only when observations support them"); 129 background personas end with
## the second. Those sentences are dropped where the persona is sent (PROMPT diet 2026-10-22); the rest of
## each line and the files stay as written.
const PERSONA_BOILERPLATE := ["Your familiarity with the player comes only from the supplied relationship and first-meeting facts.",
	"React to what is actually happening around you; do not invent private thoughts or offscreen events."]
static func persona_text(text: String) -> String:
	var kept: PackedStringArray = []
	for line: String in text.strip_edges().split("\n"):
		for rule: String in PERSONA_BOILERPLATE: line = line.replace(rule, "")
		if line.strip_edges().is_empty() and not kept.is_empty() and kept[-1].strip_edges().is_empty(): continue
		kept.append(line.strip_edges() if line.begins_with(" ") else line)
	return "\n".join(kept).strip_edges()


## Every solo request's fixed head: byte-identical across ponies and calls while system.md and the
## player's body stay the same, so it is the shared prefix a provider cache can reuse. Each rule is
## stated once here (the reply protocol, format rules, tag rules and relationship help used to
## repeat each other in three places).
func solo_head() -> String:
	return "%s%s\n\n%s\n%s\n%s\n\n%s\n%s\n\n%s" % [host._system_base.strip_edges(), LLM.HEAD_END, SOLO_FORMAT, FACE_TAGS.PROMPT, IMPRESSIONS.PROMPT, SOLO_ACTIONS, RELATIONSHIP_RULES, _anon_pony_line().trim_prefix("- ")]


const SOLO_FORMAT := "REPLY FORMAT: only what you say out loud, plain text, never JSON. Square-bracket tags may go anywhere in the line and are never spoken. Example: [face:happy] Oh, hello there! [look_at: player]"
## The tags nearly every pony has. They are explained once in the fixed head; the live part names the
## ones she cannot use right now and explains her extra ones (flight, letters, kisses, story actions).
const SOLO_CORE := ["look_at", "approach", "follow", "go_to", "lead", "step", "stay", "cancel", "resume_routine", "go_home", "go_to_bed",
	"sit", "stand", "lie_down", "sit_on_seat", "wake_up", "call_pony", "send_pony",
	"relationship_offer", "relationship_answer", "agreed", "request_space", "buck_player", "cuddle"]
const SOLO_ACTIONS := """ACTION TAGS: at most one movement or posture tag plus one [look_at] per reply, only tags available now, with the TARGETS, PONY_IDs and LOCATIONS (or a mapped place's exact name) listed at the end, exactly as written. Never coordinates, code or JSON.
- [look_at: TARGET] look a moment ([look_at: player, 5] for seconds)
- [approach: TARGET] walk up close and stop, e.g. to come closer to whoever you talk with
- [follow: TARGET] go along with someone ([follow: player, left, 2] for side and metres); [follow: player] is an open-ended walk with no destination, never your own trip. It stands you up itself (never add [stand]) and ends on [cancel], a new movement, or when they stay far out of reach. When Anon asks you to come with him to a named place ("walk with me to X", "follow me to X", "let's go to X"), use [lead: player, LOCATION] so you both head there, never [follow]
- [go_to: LOCATION] walk to any named destination, including an accepted earlier invitation ([go_to: LOCATION, trot] for pace); far places are fine (you travel in stages); ends on arrival
- [lead: TARGET, LOCATION] take someone to a place, waiting for them; when Anon agrees to come along where you are going, [lead: player, LOCATION]
- [step: DIRECTION] a few steps: forward, back, left, right, away (from the player) or aside (out of someone's way, e.g. a doorway); [step: back, 2] for 1-6 metres
- [stay: SECONDS] hold position 0.5-600 seconds ([stay] = 30); never instead of a story route
- [cancel] stop; [resume_routine] back to your day; [go_home] go home to rest a while (say goodbye first)
- [sit], [stand], [lie_down]; [sit_on_seat] sit on the nearest free bench or seat; [wake_up] wake, or get out of a bed or off a couch
- [go_to_bed] walk to your own bed, climb in and lie there (asleep at night) until [wake_up]; [go_to_bed: here] the bed in the house where Anon is; if he lies in a bed, [cuddle] joins him
- [call_pony: PONY_ID] ask a nearby pony who can hear you to come; [send_pony: PONY_ID, TARGET] ask her to go to a nearby pony or the player. No remote summons; a request is not arrival
- [relationship_offer: KIND, ACTIVITY] propose an eligible offer to Anon; ACTIVITY walk/fishing/orchard/meal/visit, or place plus a LOCATION ([relationship_offer: KIND, place, LOCATION])
- [relationship_answer: OFFER_ID, yes] or no: answer ONLY an existing invitation from Anon
- [agreed: KIND] Anon just asked you for a step in his own words (be my marefriend, go out with me, marry me, move in...) and you say yes, or he just said yes to your own offer; KIND dating/date/outing/move_in/engagement/marriage, only from your eligible offers. Without it nothing changes
- [request_space] withdraw physical permission for three minutes; say you want space
- [buck_player] kick Anon back with your hind legs as your line ends: only real, lasting anger at unwelcome contact, never boops or petting you secretly enjoy
- [cuddle] walk over and rest with Anon where he lies (bed, couch, supported grass, blanket), only if you want to
Requests are not compulsions: accept, clarify or decline. Saying yes does not move you: accepting something that needs moving or a posture puts its tag in this same reply; if no tag here can do it, say you can't right now instead of promising it. Holding and touching pause movement. Never say you arrived or did something before it happens."""
## Formerly relationship_runtime.gd ACTION_HELP plus player_bonds.gd's fixed sentences, sent with every
## request and again for every group participant; now once per request.
const RELATIONSHIP_RULES := "Relationship tags need spoken words stating your offer or answer and commit only when the line finishes; never answer your own offer or invent Anon's acceptance. On an outing to a named place each agreeing companion uses [go_to] and stops on arrival; follow Anon only on a walk with no named destination (it ends when he stays beyond walking range). During a shared activity you can board his balloon with him. A cuddle is beside or shoulder company in friendship, a closer snuggle only in an established romance, within current boundaries. Friendship and romance are separate: even full attraction never makes you partners; only an explicit proposal the other accepts does. Declining is allowed; affection and marriage never grant blanket permission. Never claim a milestone the game has not confirmed, and never say scores aloud."
## Fuller help than TAG_HELP where the old relationship help carried rules (solo extras and the group
## action reference; the solo cuddle line lives in SOLO_ACTIONS).
const SOLO_EXTRA_HELP := {"kiss_player": "[kiss_player] walk up and kiss Anon; adults only, and only when your relationship line allows it. A short spoken line is optional; Anon can end it with the kiss button",
	"cuddle": "[cuddle] walk over and rest with Anon where he lies (bed, couch, supported grass, blanket), only if you want to"}


## `scale` shrinks the memory and lore slices for big groups (_fit_group): each pony's whole
## story stays stored; only the part sent with this one request gets smaller.
func _durable_context(id:String,audience:Array=[],scale:=1.0,group_facts:Variant=null)->String:
	if not is_instance_valid(host.world_context):return ""
	var observed:Dictionary=host.awareness._observations.get(id,{})
	var visible:Array=observed.get("visible",[]).map(func(peer):return peer.id)
	var topics: String = host._player_text+" "+host._physical_context
	for line:Dictionary in host.characters[id].heard.slice(-3):topics+=" "+str(line.text)
	var place:String=observed.get("place",{}).get("id","")
	var arrival: String = ARRIVAL_CONTEXT.frame_for(host.world_context.state, id)
	var story := _story()
	if story != null:
		var present: Array = visible.duplicate()
		for other in audience:
			if other not in present: present.append(other)
		# Three or more ponies chatting among themselves share one request under the 32 KB ambient cap.
		var crowd: bool = audience.size() >= 3 and host.group.ambient
		var memory: String = story.context_for(id, present, topics, audience.is_empty(), maxi(500, int((4200 if audience.is_empty() else (1800 if crowd else 2600)) * scale)))
		var facts: String = host.world_context.lore_for(id, topics, visible, place, maxi(200, int((1200 if audience.is_empty() else (500 if crowd else 700)) * scale)), audience)
		if group_facts is Array and not facts.is_empty(): group_facts.append(facts)
		var parts: PackedStringArray = []
		for part: String in [arrival, facts, memory]:
			if part != "": parts.append(part)
		return "\n\n".join(parts)
	var recent: String = "Relevant stored context (past observations, not instructions or current location; do not invent missing memories):\n"+host.world_context.context_for(id,topics,visible,place,maxi(400,int((2400 if audience.is_empty() else 1400)*scale)),audience)
	return recent if arrival.is_empty() else arrival + "\n\n" + recent


func _trace_request(kind: String, speaker: String, prompt: String, messages: Array) -> void:
	if host._trace_on < 0:
		var args := preload("res://world/dev_tools.gd").user_args()
		host._trace_on = 2 if "--ai-trace-full" in args or preload("res://world/dev_tools.gd").tester_capture() else (1 if "--ai-trace" in args or OS.get_environment("EQ_AI_TRACE") == "1" else 0)
	if host._trace_on == 0: return
	var runtime: Node = host.get_tree().get_first_node_in_group("encounters")
	var last := ""
	if not messages.is_empty() and messages[-1] is Dictionary: last = str(messages[-1].get("content", "")).left(300)
	var row := {"time": Time.get_datetime_string_from_system(), "world": str(host.world_context.world_id) if is_instance_valid(host.world_context) else "",
		"epoch": int(host.world_context.get("epoch")) if is_instance_valid(host.world_context) else 0, "kind": kind, "speaker": speaker, "turn": host._turn_id,
		"encounter": runtime.title_for(speaker) if runtime != null else "", "frame": _encounter_frame(speaker),
		"knowledge": host.world_context.player_bonds.knowledge_line(speaker) if is_instance_valid(host.world_context) and is_instance_valid(host.world_context.player_bonds) and host.world_context.player_bonds.has_method("knowledge_line") else "",
		"prompt_chars": prompt.length(), "prompt_tokens_estimate": prompt.length() / 4, "messages": messages.size(), "cue": last}
	if host._trace_on == 2: row["prompt"] = prompt
	DirAccess.make_dir_recursive_absolute("user://ai_trace")
	var path := "user://ai_trace/trace.jsonl"
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null: return
	file.seek_end(); file.store_line(JSON.stringify(row)); file.close()


func _action_targets(id: String) -> Dictionary:
	var targets := {}
	if is_instance_valid(host.player_head) and host.player_head.is_inside_tree(): targets.player = host.player_head
	var observed: Dictionary = host.awareness._observations.get(id, {})
	for peer in observed.get("visible", []) + observed.get("present", []):
		if host.characters.has(peer.id):
			var node: Variant = host.characters[peer.id].node
			if is_instance_valid(node): targets[peer.id] = node
	var object_ids: Array = observed.get("objects", []).map(func(item): return item.get("id", ""))
	for node in host.get_tree().get_nodes_in_group("ai_observable"):
		var object_id := str(node.get_meta("ai_id", ""))
		if object_id != "" and object_id in object_ids and not targets.has(object_id): targets[object_id] = node
	return targets


## The live action part of a solo request: what she cannot do now, her extra tags, and the ids she may
## name. The tag rules themselves are in the fixed head (SOLO_ACTIONS).
func _action_prompt(id: String) -> String:
	var context: Dictionary = host.actions.context(id, host._action_targets(id))
	var capabilities: Array = context.get("capabilities", [])
	if capabilities.is_empty(): return "ACTIONS NOW: none; speak only."
	var lines: PackedStringArray = ["ACTIONS NOW"]
	var missing: Array = SOLO_CORE.filter(func(type: String) -> bool: return type not in capabilities)
	if not missing.is_empty(): lines.append("Not available now: " + ", ".join(missing))
	var extra: PackedStringArray = []
	for type: String in ACTION_SCHEMA.TYPES:
		if type in capabilities and type not in SOLO_CORE and ACTION_SCHEMA.TAG_HELP.has(type):
			extra.append("- " + str(SOLO_EXTRA_HELP.get(type, ACTION_SCHEMA.TAG_HELP[type])))
	if not extra.is_empty(): lines.append("Your extra tags now:\n" + "\n".join(extra))
	var callable: Array = context.get("callable_ponies", [])
	if not callable.is_empty(): lines.append("PONY_IDs you can call or send (observed nearby; hearing is checked when the request executes): " + ", ".join(callable))
	var targets: Dictionary = context.get("targets", {})
	lines.append("TARGETS: " + (", ".join(targets.keys()) if not targets.is_empty() else "(none)"))
	lines.append(_location_block(id, context))
	return "\n".join(lines)


func _place_lines(id: String, local_limit := 30) -> String:
	var node: Variant = host.characters[id].node if host.characters.has(id) else null
	var nav: Node = node.get_node_or_null("Navigator") if is_instance_valid(node) else null
	if nav == null or not nav.has_method("command_place_lines"): return "(none)"
	var lines: Array = nav.command_place_lines(local_limit)
	return "(none)" if lines.is_empty() else "\n".join(lines)


## A place this close is where she already stands (place_directory.gd prompt_lines distance).
const HERE_METRES := 6

## Where she can go, compact (dev 2026-10-22: 75 "id = label (kind, ~N m)" lines were 4.5 KB of every
## request, 44 of them distant regions with metre counts). Nearest places first; a place whose own label
## resolves to it alone (place_directory.gd match_name gives an exact label +10) is listed by name,
## other places as "name = id"; regions by name on one line. Distances are dropped: the order says it.
func _location_block(id: String, context: Dictionary, local_limit := LOCAL_PLACES, region_limit := REGION_PLACES) -> String:
	var raw: String = host._place_lines(id, local_limit)
	if raw == "(none)": return "LOCATIONS: (none)"
	var labels: Dictionary = context.get("place_labels", {})
	var local: PackedStringArray = []
	var regions: PackedStringArray = []
	var listed := {}
	for line: String in raw.split("\n", false):
		var at := line.find(" = ")
		if at < 0:
			local.append(line); continue
		var place_id := line.left(at)
		var label := line.substr(at + 3)
		var kind := ""
		var here := false
		var open := label.rfind(" (")
		if open > 0 and label.ends_with(")"):
			var inside := label.substr(open + 2, label.length() - open - 3)
			kind = inside.get_slice(",", 0)
			# Standing at it already (Derpy reached the market aisle, then "led" Anon there and stood
			# still saying "follow me", dev 2026-10-26): she must know, not offer to walk there.
			var metres := inside.get_slice("~", 1).to_int() if "~" in inside else 999
			here = metres <= HERE_METRES and not kind.begins_with("region")
			label = label.left(open)
		if label == "painted spot":
			local.append(place_id); continue
		var key := "".join(PLACES.name_words(label))
		if listed.has(key): continue # the same name twice (a landmark and its building): one entry
		listed[key] = true
		var by_name: bool = not key.is_empty() and key == "".join(PLACES.name_words(str(labels.get(place_id, label))))
		if kind.begins_with("region"):
			if regions.size() < region_limit: regions.append(label if by_name else "%s = %s" % [label, place_id])
		elif local.size() < local_limit:
			local.append((label if by_name else "%s = %s" % [label, place_id]) + (" (YOU ARE HERE: do not go_to or lead to it)" if here else ""))
	var text := "LOCATIONS (nearest first): " + "; ".join(local)
	if not regions.is_empty(): text += "\nREGIONS (nearest first): " + "; ".join(regions)
	return text + "\nAny other mapped place also works by its exact name. A named business and a resident's house are distinct destinations: guide to the named business itself, not the resident's separate home."


const LOCAL_PLACES := 20
const REGION_PLACES := 24


## Tags an ambient pony-to-pony chat offers (dev 2026-10-14 batch conversations): looking, stepping
## closer, settling in. Player-directed tags (kisses, offers, cuddles, calling ponies) are left out of
## that prompt; travel only for friends out walking together. Other valid tags are still accepted.
const AMBIENT_ACTIONS := ["look_at", "approach", "step", "sit", "stand", "lie_down", "sit_on_seat"]
const AMBIENT_WALK_ACTIONS := ["go_to", "follow"]


## Byte targets for one group request (dev 2026-10-15: a crowd of six around Lyra went over the
## old 64 KiB cap and every conversation there failed). Shared rules stay whole; each
## participant's memory, lore, observations and place list shrink until the request fits.
## The ambient target leaves room for its 32 KiB request cap (ambient_budget.gd).
const GROUP_PROMPT_BYTES := 40000
const AMBIENT_PROMPT_BYTES := 26000


func _group_prompt() -> String:
	if host.group.ambient: return _fit_group(_ambient_prompt, AMBIENT_PROMPT_BYTES)
	return _fit_group(_player_group_prompt, GROUP_PROMPT_BYTES)


## Builds with per-participant slices at `scale` (full size for up to three ponies), shrinking
## until the prompt fits `budget` bytes or the slices reach their floors.
func _fit_group(build: Callable, budget: int) -> String:
	var scale := clampf(3.0 / maxf(1.0, float(host.group.members.size())), 0.25, 1.0)
	var prompt: String = build.call(scale)
	while prompt.to_utf8_buffer().size() + _group_saved_bytes > budget and scale > 0.13:
		scale *= 0.6
		prompt = build.call(scale)
	return prompt


## Whole lines from the start of `text`, at most `limit` characters.
static func _clip_lines(text: String, limit: int) -> String:
	if text.length() <= limit: return text
	var cut := text.left(limit)
	var at := cut.rfind("\n")
	return (cut.left(at) if at > limit / 2 else cut) + "\n(more observations omitted for space)"


## Lore selection has already enforced each entry's viewers. Share only byte-identical
## selected blocks, naming their original participants rather than broadening knowledge.
static func _share_group_facts(parts: Array[String], memories: Array[Dictionary]) -> int:
	var blocks := {}
	for memory: Dictionary in memories:
		for facts: String in memory.get("facts", []):
			if not blocks.has(facts): blocks[facts] = []
			blocks[facts].append(memory)
	var packed: Array[String] = parts.duplicate()
	var shared: PackedStringArray = []
	for facts: String in blocks:
		var copies: Array = blocks[facts]
		if copies.size() < 2: continue
		var witnesses: PackedStringArray = []
		for copy: Dictionary in copies: witnesses.append(str(copy.id))
		var reference := "World facts F%d" % (shared.size() + 1)
		var block := "%s (only %s):\n%s" % [reference, ", ".join(witnesses), facts]
		var before: int = copies.size() * JSON.stringify(facts).to_utf8_buffer().size()
		var after: int = JSON.stringify(block).to_utf8_buffer().size() + copies.size() * JSON.stringify(reference).to_utf8_buffer().size()
		if after >= before: continue
		for copy: Dictionary in copies:
			var index := int(copy.index)
			var at := packed[index].find(facts)
			if at < 0: return 0
			packed[index] = packed[index].left(at) + reference + packed[index].substr(at + facts.length())
		shared.append(block)
	if shared.is_empty(): return 0
	packed.append("SHARED WORLD FACTS\nEach numbered block applies only to its listed participants; personal memories remain separate.\n" + "\n\n".join(shared))
	if JSON.stringify("\n\n".join(packed)).to_utf8_buffer().size() < JSON.stringify("\n\n".join(parts)).to_utf8_buffer().size():
		var saved := "\n\n".join(parts).to_utf8_buffer().size() - "\n\n".join(packed).to_utf8_buffer().size()
		parts.assign(packed)
		return saved
	return 0


func _player_group_prompt(scale := 1.0) -> String:
	# Fixed rules first (shared rules, expression and feeling tags), the output protocol stays last.
	# The shared rules and tag rules are the cacheable head (LLM.HEAD_END after each); the rest changes per call.
	var parts: Array[String] = [host._system_base + LLM.HEAD_END, FACE_TAGS.PROMPT + "\n" + IMPRESSIONS.PROMPT + " Each line may carry its own feeling tags. Only its speaker supplies that private reaction." + LLM.HEAD_END, host.feedback.prompt(host.group.members)]
	var memories: Array[Dictionary] = []
	var shared_capabilities: Array = []
	parts.append("Player body facts (shared observation, not shared personal knowledge):\n" + _anon_pony_line())
	for id in host.group.members:
		var facts: Array = []
		memories.append({"id": id, "index": parts.size(), "facts": facts})
		parts.append(_durable_context(id,host.group.members,scale,facts))
		if is_instance_valid(host.world_context) and is_instance_valid(host.world_context.player_bonds) and host.world_context.player_bonds.has_method("knowledge_line"):
			parts.append("Participant %s's player knowledge: %s" % [id, host.world_context.player_bonds.knowledge_line(id)])
		var node: Node3D = host.characters[id].node
		var observation: Dictionary = host.awareness.sample(id, node, host.characters, host.player_head, host._now(), host._earshot(id), true).duplicate(true)
		observation["your_current_clothing"] = preload("res://world/characters/accessories/pony_wardrobe.gd").situation_line(node)
		# Private touches are not group knowledge.
		if _story() == null:
			observation.events = []
			observation.objects = []
		observation.erase("boops")
		observation.erase("kisses")
		if node.has_meta("hayburger_order_context"): observation["your_active_order"] = str(node.get_meta("hayburger_order_context"))
		if node.has_meta("relationship_runtime"): observation["your_relationship"] = node.get_meta("relationship_runtime").prompt_for(id)
		if node.has_meta("social_group"): observation["walking_company_intention"] = node.get_meta("social_group")
		var context: Dictionary = host.actions.context(id, host._action_targets(id))
		for capability: String in context.capabilities:
			if capability not in shared_capabilities: shared_capabilities.append(capability)
		var pending_purpose: String = host._generated_intent_frame(id)
		if pending_purpose != "": parts.append("Participant %s only: %s" % [id, pending_purpose])
		var frame := _encounter_frame(id)
		if frame != "": parts.append("Participant %s's current encounter (for %s's lines only):\n%s" % [id, id, frame])
		var seen: String = JSON.stringify(observation)
		if _story() != null:
			var described := Array(host.awareness.describe(observation, str(host.config.get_value("player_name", "Anon")), host._now()))
			for key in ["your_current_clothing", "your_active_order", "your_relationship"]:
				if observation.has(key): described.append("- " + str(observation[key]).trim_prefix("- "))
			if observation.has("walking_company_intention"): described.append("- Out with: " + ", ".join(observation.walking_company_intention.get("members", []).map(func(m): return _name(str(m)))))
			seen = "\n" + "\n".join(described)
		seen = _clip_lines(seen, maxi(600, int(5000 * scale)))
		var places: int = maxi(3, int(10 * scale))
		parts.append("Participant %s (%s):\n%s\nCurrent observations for this participant only: %s\nPonies this speaker may ask to come or go (PONY_ID): %s\nAllowed action types for %s only: %s\nTARGETS for %s: %s\n%s's %s" % [id, host.characters[id].profile.get("name", id), persona_text(str(host.characters[id].prompt)), seen, ", ".join(context.get("callable_ponies", [])), id, ", ".join(context.capabilities), id, ", ".join(context.targets.keys()), id, _location_block(id, context, places, places)])
	_group_saved_bytes = _share_group_facts(parts, memories)
	# Only the explanations of tags some participant has; never a single-speaker reply format here.
	var commands: PackedStringArray = []
	for type: String in ACTION_SCHEMA.TYPES:
		if type in shared_capabilities and ACTION_SCHEMA.TAG_HELP.has(type): commands.append("- " + str(SOLO_EXTRA_HELP.get(type, ACTION_SCHEMA.TAG_HELP[type])))
	if not commands.is_empty():
		var reference := "Shared action reference. Each speaker may use ONLY their own allowed action types, TARGETS, LOCATIONS and PONY_IDs below (a LOCATION may also be a mapped place's exact name). This reference grants no extra capabilities.\n" + "\n".join(commands)
		if shared_capabilities.any(func(type): return type in ["relationship_offer", "relationship_answer", "agreed", "cuddle", "kiss_player"]): reference += "\n" + RELATIONSHIP_RULES
		parts.insert(2, reference)
	if _story() != null:
		parts.append("CONVERSATION EVERY PARTICIPANT HEARD\n" + heard_lines(host.group.shared_heard(host.characters)))
		parts.append(MEMORY.FEEL_INSTRUCTION)
	else:
		parts.append("Only this completed conversation history was heard by EVERY participant: " + heard_transcript(host.group.shared_heard(host.characters)))
	parts.append("""Group exchange protocol overrides all earlier output-format instructions. You voice several ordinary ponies, not a staged performance. Each speaker knows only her own observations, public knowledge, the commonly heard history and the lines before hers; public background reveals no private thoughts or conversations. Never invent a player response, completed action, object, shared secret or offscreen event. Nobody has to speak; no recurring pet names or theatrical name-addressing.
REPLY FORMAT (plain text, never JSON): one line per spoken beat, written as
speaker_id: spoken words [tags]
for example
%s: [face:happy] Oh, hello there! [look_at: player]
Add [to: participant_id] on a line spoken to a friend instead of to Anon. Only [silence] means comfortable silence.
Pick the first speaker by whom the player addresses by name, the topic and each pony's observations, never merely the first listed or closest. If one pony is addressed, usually only she answers; others may chime in naturally, no roll call. Usually one to four brief lines (at most four, at most 600 characters each); one line is fine. Speaker IDs only from the participants above; a speaker may address a friend, then the player, on separate lines. Speech only, no narration.
A line's tags belong to its speaker and must be among her own tags above; ordinary speech needs none. At most one movement tag plus one [look_at] per line. For a named outing every participant who agreed to join, proposer and invited companions alike, gets [go_to: LOCATION]; never leave someone behind because another pony answered the player. After the spoken acceptance, an agreeing invited companion may have an action-only line, companion_id: [go_to: SAME_LOCATION], which does not count toward the four. Never move uninvolved or declining ponies. [follow: player] only for an open-ended walk without a named destination; when Anon asks a pony to come with him to a named place ("walk with me to X", "follow me to X"), [lead: player, LOCATION], never [follow]; when Anon agrees to come along where she is going, [lead: player, LOCATION]; it stands her up itself (never add [stand]). To come closer to whoever she talks with, [approach: TARGET]; [follow] only to go along with someone. Never coordinates, code or JSON. A movement request is not proof of arrival.
""" % [host.group.members[0]])
	return "\n\n".join(parts)


## One request writes a whole ambient conversation: personas, observations and memory per pony, a short
## tag list, and the script format. No player-reply rules, impressions or full action reference: those
## cost every conversation their bytes and ambient lines never address Anon.
func _ambient_prompt(scale := 1.0) -> String:
	var members: Array[String] = host.group.members
	var walking: bool = members.size() > 1 and host._walking_together(members)
	var offered: Array = AMBIENT_ACTIONS + (AMBIENT_WALK_ACTIONS if walking else [])
	var parts: Array[String] = [host._system_base + LLM.HEAD_END, FACE_TAGS.PROMPT + LLM.HEAD_END, host.feedback.prompt(host.group.members)]
	var memories: Array[Dictionary] = []
	parts.append("Player body facts (shared observation, not shared personal knowledge):\n" + _anon_pony_line())
	var shared: Array = []
	for id in members:
		var facts: Array = []
		memories.append({"id": id, "index": parts.size(), "facts": facts})
		parts.append(_durable_context(id, members, scale, facts))
		if is_instance_valid(host.world_context) and is_instance_valid(host.world_context.player_bonds) and host.world_context.player_bonds.has_method("knowledge_line"):
			parts.append("Participant %s's player knowledge: %s" % [id, host.world_context.player_bonds.knowledge_line(id)])
		var node: Node3D = host.characters[id].node
		var observation: Dictionary = host.awareness.sample(id, node, host.characters, host.player_head, host._now(), host._earshot(id), true).duplicate(true)
		observation["your_current_clothing"] = preload("res://world/characters/accessories/pony_wardrobe.gd").situation_line(node)
		if _story() == null:
			observation.events = []
			observation.objects = []
		observation.erase("boops")
		observation.erase("kisses")
		if node.has_meta("social_group"): observation["walking_company_intention"] = node.get_meta("social_group")
		var context: Dictionary = host.actions.context(id, host._action_targets(id))
		var own: Array = []
		for capability: String in context.capabilities:
			if capability in offered:
				own.append(capability)
				if capability not in shared: shared.append(capability)
		var pending_purpose: String = host._generated_intent_frame(id)
		if pending_purpose != "": parts.append("Participant %s only: %s" % [id, pending_purpose])
		var frame := _encounter_frame(id)
		if frame != "": parts.append("Participant %s's current encounter (for %s's lines only):\n%s" % [id, id, frame])
		var seen: String = JSON.stringify(observation)
		if _story() != null:
			var described := Array(host.awareness.describe(observation, str(host.config.get_value("player_name", "Anon")), host._now()))
			described.append("- " + str(observation.your_current_clothing).trim_prefix("- "))
			if observation.has("walking_company_intention"): described.append("- Out with: " + ", ".join(observation.walking_company_intention.get("members", []).map(func(m): return _name(str(m)))))
			seen = "\n" + "\n".join(described)
		seen = _clip_lines(seen, maxi(500, int(4000 * scale)))
		var block := "Participant %s (%s):\n%s\nCurrent observations for this participant only: %s\nTags %s may use: %s\nTARGETS for %s: %s" % [id, host.characters[id].profile.get("name", id), persona_text(str(host.characters[id].prompt)), seen, id, ", ".join(own) if not own.is_empty() else "(none)", id, ", ".join(context.targets.keys())]
		if walking and "go_to" in own: block += "\n%s's %s" % [id, _location_block(id, context, maxi(2, int(5 * scale)), maxi(2, int(5 * scale)))]
		parts.append(block)
	_group_saved_bytes = _share_group_facts(parts, memories)
	var commands: Array = []
	for type: String in shared:
		if ACTION_SCHEMA.TAG_HELP.has(type): commands.append("- " + str(ACTION_SCHEMA.TAG_HELP[type]))
	if not commands.is_empty():
		parts.insert(2, "Optional action tags (each speaker only her own, at most one plus one [look_at: ...] per line; ordinary speech needs none):\n" + "\n".join(commands))
	if _story() != null:
		parts.append("CONVERSATION EVERY PARTICIPANT HEARD\n" + heard_lines(host.group.shared_heard(host.characters)))
		parts.append(MEMORY.FEEL_INSTRUCTION)
	else:
		parts.append("Only this completed conversation history was heard by EVERY participant: " + heard_transcript(host.group.shared_heard(host.characters)))
	var first: String = members[0]
	if members.size() < 2:
		parts.append("""Ambient remark protocol overrides all earlier output-format instructions. %s is on her own; nobody will answer. Return at most ONE incidental remark of at most 200 characters, written as
%s: spoken words [tags]
or only [silence]. Never address anypony by name, never ask a question, never address Anon (player). Speech only, no narration.""" % [first, first])
		return "\n\n".join(parts)
	var second: String = members[1]
	parts.append("""Ambient conversation protocol overrides all earlier output-format instructions. These ponies are chatting among themselves, standing together and facing each other; Anon is only somewhere nearby. First decide privately why they are talking now (their relationship and feelings above, something one wants from or wants to tell another) and let that drive the talk; each pony speaks as herself, at her own age and standing (a filly with a grown-up mare is not a chat between equals). Each speaker knows only her own observations, public knowledge, the shared heard history and the lines before hers. Never invent a player response, completed action, shared secret or offscreen event. No recurring pet names or theatrical name-addressing.
REPLY FORMAT (plain text, never JSON): the WHOLE conversation at once, one line per spoken turn, in speaking order:
speaker_id: spoken words [to: listener_id] [tags]
for example
%s: [face:happy] (her opening words) [to: %s]
%s: (her answer, straight back to her) [to: %s]
The first line is spoken by %s. Whoever is spoken to answers on the very next line; nobody is left hanging and every participant speaks at least once. Take turns politely like ordinary ponies having a real chat: short lines of one or two sentences (at most 200 characters), no monologues, no speeches, no roll call. About 4 to 10 lines, at most ten; end naturally with a goodbye, a plan or an easy pause, not a punchline or an open question. Tags on a line belong to its speaker and must be among her own tags above. Never address Anon (player) in this conversation. Speech only, no narration. Only if nobody has anything to say, reply with just [silence].""" % [first, second, second, first, first])
	return "\n\n".join(parts)
