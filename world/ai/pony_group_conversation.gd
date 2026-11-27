extends RefCounted
## A bounded exchange proposal. No generated beat is history until it is heard.
const ACTION_SCHEMA := preload("res://world/ai/pony_action_schema.gd")
const BOND := preload("res://world/relationships/bond_rules.gd")
const MAX_MEMBERS := 6
const MAX_BEATS := 4
const MAX_AMBIENT_BEATS := 12
const RANGE := 18.0
var members: Array[String] = []
var beats: Array = []
var cursor := 0
var started_at := 0.0
var guard: Dictionary = {}
var ambient := false
var ambient_radius := 45.0
var last_audible_at := 0.0

func active() -> bool: return not members.is_empty()
func clear() -> void:
	members.clear(); beats.clear(); guard.clear(); cursor = 0

func begin(ids: Array[String], characters: Dictionary, now: float, background := false) -> void:
	clear(); members = ids.duplicate(); started_at = now; last_audible_at = now; ambient = background
	for id in members:
		var node: Node3D = characters[id].node
		guard[id] = interaction_stamp(node)

static func interaction_stamp(node: Node3D) -> Array:
	return [node.get_instance_id(), node.is_held() if node.has_method("is_held") else false,
		node.boop_count() if node.has_method("boop_count") else 0,
		node.kiss_count() if node.has_method("kiss_count") else 0]

func invalid_reason(characters: Dictionary, player: Node3D, awareness: RefCounted, now: float) -> String:
	if not active(): return ""
	if now - started_at > 150.0: return "Exchange became stale"
	if not is_instance_valid(player) or not player.is_inside_tree(): return "Player unavailable"
	var nodes: Array[Node3D] = []
	var audible := false
	for id in members:
		if not characters.has(id) or not is_instance_valid(characters[id].node): return "A participant left"
		var node: Node3D = characters[id].node
		if not node.is_inside_tree() or not node.is_visible_in_tree(): return "A participant left"
		# Talking with Anon survives his touch: petting, boops, kisses and holding her are part of
		# the conversation, not an end to it (dev 2026-09-28). Ambient pony chats still break off.
		if ambient:
			if interaction_stamp(node) != guard[id]: return "A participant was touched or picked up"
			if node.has_method("action_interruption_reason") and node.action_interruption_reason() != "": return "Physical interaction interrupted the exchange"
		if ambient:
			if awareness.can_hear(player,node,ambient_radius): audible = true
		elif awareness.point(node).distance_to(awareness.point(player)) > RANGE + 2.0 or not awareness.can_hear(node, player, RANGE + 2.0): return "Player left the conversation"
		for other in nodes:
			if not awareness.can_hear(node, other, RANGE): return "Participants can no longer hear each other"
		nodes.append(node)
	if ambient:
		if audible: last_audible_at = now
		elif now-last_audible_at > 5.0: return "Ambient company is comfortably out of earshot"
	return ""

func decode(text: String, turn: int, contexts: Dictionary, bind_request := false) -> Dictionary:
	text = text.strip_edges()
	if text.length() > 16000: return {"error": "Exchange is too large"}
	if text.begins_with("```"):
		var lines := text.split("\n")
		if lines.size() < 3 or lines[-1] != "```": return {"error": "Incomplete exchange fence"}
		text = "\n".join(lines.slice(1, lines.size() - 1)).strip_edges()
	if not text.begins_with("{") and not "\"beats\"" in text:
		var lines := decode_lines(text, turn, contexts)
		if not lines.has("fallback"): return lines
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return {"fallback": true} if not text.begins_with("{") and not "\"beats\"" in text else {"error": "Invalid exchange JSON"}
	var value: Dictionary = parser.data
	if not value.has("beats"): return {"fallback": true}
	if not ACTION_SCHEMA._keys(value, ["schema_version", "turn_id", "beats"]): return {"error": "Unknown exchange fields"}
	if bind_request:value.turn_id=turn
	if not ACTION_SCHEMA._number(value.get("schema_version"), 1, 1) or not ACTION_SCHEMA._number(value.get("turn_id"), turn, turn): return {"error": "Wrong exchange version or turn"}
	var limit := MAX_AMBIENT_BEATS if ambient else MAX_BEATS
	if ambient and members.size() == 1: limit = 1
	if not value.beats is Array or value.beats.size() > limit: return {"error": "Too many conversation turns (limit %d)" % limit}
	var seen := {}
	var checked: Array = []
	for beat in value.beats:
		if not beat is Dictionary or not ACTION_SCHEMA._keys(beat, ["speaker_id", "listener_id", "speech", "actions", "impression"]): return {"error": "Invalid beat fields"}
		if beat.get("speaker_id") not in members or not contexts.has(beat.speaker_id): return {"error": "Speaker not authorized for this exchange"}
		var listeners: Array = members + (["none"] if ambient else ["player"])
		if beat.get("listener_id") not in listeners or beat.listener_id == beat.speaker_id: return {"error": "Invalid listener"}
		if not beat.get("speech") is String or beat.speech.length() > 600 or beat.speech.strip_edges().is_empty() or beat.speech == "[silence]": return {"error": "Each beat needs a spoken line of at most 600 characters; use no beats for silence"}
		if ambient and members.size() == 1 and beat.speech.length() > 200:
			return {"error": "A lone incidental remark must be brief (maximum 200 characters)"}
		var envelope := {"schema_version":1, "actor_id":beat.speaker_id, "turn_id":turn, "listener_id":"player", "speech":beat.speech, "actions":beat.get("actions", []), "impression":beat.get("impression",{})}
		var validated := ACTION_SCHEMA.decode(JSON.stringify(envelope), beat.speaker_id, turn, contexts[beat.speaker_id])
		if validated.has("error"): return validated
		for action: Dictionary in validated.actions:
			var key: String = beat.speaker_id + "/" + action.id
			if seen.has(key): return {"error": "Reused action ID in exchange"}
			seen[key] = true
		checked.append({"speaker_id":beat.speaker_id, "listener_id":beat.listener_id, "speech":validated.speech, "actions":validated.actions, "impression":{} if ambient else validated.get("impression",{})})
	if ambient and not checked.is_empty() and checked[0].speaker_id != members[0]: return {"error":"The selected initiator must speak first"}
	return {"beats": checked}

## Tag exchange (pony_action_schema.gd tag replies): one beat per line, "speaker_id: spoken line"
## with that speaker's tags inside, and [to: listener_id] when she talks to another participant.
## Lines from a speaker who is not taking part are dropped; no speaker lines at all is a fallback
## (plain speech for the addressed pony). [silence] alone is no beats.
const TO := "(?i)\\[\\s*to\\s*[:=]\\s*([a-z0-9_ -]+?)\\s*\\]"
func decode_lines(text: String, turn: int, contexts: Dictionary) -> Dictionary:
	if text.strip_edges() == "[silence]": return {"beats": []}
	var to := RegEx.new(); to.compile(TO)
	var limit := MAX_AMBIENT_BEATS if ambient else MAX_BEATS
	if ambient and members.size() == 1: limit = 1
	var checked: Array = []
	var any_speaker := false
	var control_only := false
	var spoken_count := 0
	var travel_destinations: Array[String] = []
	var quiet_members: Array[String] = []
	for raw_line in text.split("\n", false):
		var line := raw_line.strip_edges().trim_prefix("-").strip_edges()
		if BOND.DYNAMIC: line = tags_after_name(line)
		var colon := line.find(":")
		if colon <= 0: continue
		var speaker := line.left(colon).strip_edges().to_lower().replace(" ", "_").trim_prefix("**").trim_suffix("**")
		if speaker not in members or not contexts.has(speaker): continue
		any_speaker = true
		var body := line.substr(colon + 1).strip_edges()
		var listener := "none" if ambient else "player"
		var found := to.search(body)
		if found != null:
			var named := found.get_string(1).strip_edges().to_lower().replace(" ", "_")
			if named in members and named != speaker: listener = named
			body = body.replace(found.get_string(0), "").strip_edges()
		var decoded := ACTION_SCHEMA.decode_tags(body, speaker, turn, contexts[speaker])
		if decoded.has("error"): return decoded
		control_only = control_only or bool(decoded.get("control_only", false))
		var spoken: String = decoded.speech
		if spoken.strip_edges().is_empty():
			# An invited companion can join an already spoken trip without a roll call.
			# Only validated go_to actions sharing that trip are allowed silently.
			if not ambient and decoded.actions.size() == 1 and decoded.actions[0].type == "go_to" and str(decoded.actions[0].location_id) in travel_destinations and speaker not in quiet_members:
				checked.append({"speaker_id":speaker, "listener_id":listener, "speech":"", "actions":decoded.actions, "silent_travel":true})
				quiet_members.append(speaker)
			continue
		if spoken_count >= limit: continue
		if ambient and members.size() == 1 and spoken.length() > 200: return {"error": "A lone incidental remark must be brief (maximum 200 characters)"}
		if spoken.length() > 600: return {"error": "Each spoken beat must fit within 600 characters; preserve whole sentences"}
		checked.append({"speaker_id": speaker, "listener_id": listener, "speech": spoken, "actions": decoded.actions,
			"impression": {} if ambient else decoded.get("impression", {})})
		spoken_count += 1
		for action: Dictionary in decoded.actions:
			if action.type == "go_to": travel_destinations.append(str(action.location_id))
	if not any_speaker: return {"fallback": true}
	if checked.is_empty() and control_only: return {"error": "Exchange contains only control syntax and no spoken answer"}
	if ambient and not checked.is_empty() and checked[0].speaker_id != members[0]: return {"error": "The selected initiator must speak first"}
	return {"beats": checked}

## "[felt: pleased] applejack: Howdy." becomes "applejack: [felt: pleased] Howdy." (relationship
## overhaul 2026-11-21, design 4.1): the first colon of a line that begins with a tag is the tag's own,
## so the line would be lost whole. Tag syntax only: the line's words are not read. A line whose
## leading tags are not followed by a participant's name is returned unchanged.
func tags_after_name(line: String) -> String:
	if not line.begins_with("["): return line
	var lead := ""
	var rest := line
	while rest.begins_with("["):
		var close := rest.find("]")
		if close < 0: return line
		lead += rest.left(close + 1) + " "
		rest = rest.substr(close + 1).strip_edges()
	var colon := rest.find(":")
	if colon <= 0: return line
	var speaker := rest.left(colon).strip_edges().to_lower().replace(" ", "_").trim_prefix("**").trim_suffix("**")
	if speaker not in members: return line
	return rest.left(colon + 1) + " " + lead + rest.substr(colon + 1).strip_edges()

func shared_heard(characters: Dictionary) -> Array:
	if members.is_empty(): return []
	var result: Array = []
	for event in characters[members[0]].get("heard", []):
		var shared := true
		for id in members.slice(1):
			if not characters[id].get("heard", []).any(func(item): return item.id == event.id): shared = false; break
		if shared: result.append(event)
	return result.slice(maxi(0, result.size() - 6))
