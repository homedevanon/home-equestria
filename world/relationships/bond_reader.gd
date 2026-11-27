extends Node
## The second look and the measured tag rate (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md section 9;
## contract docs/RELATIONSHIP_BUILD_2026_11_21.md section 3.4).
##
## It counts, for this session, how many of her replies that answer Anon carried a feeling tag. With
## the setting "ai/second_look" at "on" and that rate measured low, every delivered reply to him that
## carried no feeling tag gets one small request to the summary connection: a model reads the exchange
## and answers in tags. What it tags is applied as her own tags would be (the feeling through
## impressions.commit, a standing through bonds.stand, a step through bonds.step, source "reader").
## A request is skipped when the summary client is missing or busy, never queued; there is no budget
## by the minute or the hour. Three unreadable answers in a row turn it off for this session.
const BOND := preload("res://world/relationships/bond_rules.gd")
const BOND_TAGS := preload("res://world/relationships/bond_tags.gd")
const BOND_PROMPT := preload("res://world/relationships/bond_prompt.gd")
## Usage label and the size of its answer (design 9: at most 40 tokens out).
const PURPOSE := "bond_reader"
const OUTPUT_TOKENS := 40

var host: Node
## Stand-ins a test may set; otherwise found from the host and the director.
var client: Node = null
var impressions: Node = null
var bonds: Node = null
## "" reads the setting; a test sets "off" or "on".
var setting_override := ""
## Requests sent this session (for the AI page and tests).
var sent := 0
var _replies := 0
var _tagged := 0
var _unreadable := 0
var _stopped := false


func setup(owner_node: Node) -> void:
	host = owner_node
	add_to_group("bond_reader")


## One finished line of hers that he heard. Only replies that answer him are counted.
func note_reply(id: String, turn: int, his_line: String, her_line: String, tagged: bool, answers_him: bool) -> void:
	if not answers_him: return
	_replies += 1
	if tagged:
		_tagged += 1
		return
	if not BOND.DYNAMIC or _stopped or not _on() or not _low(): return
	var llm := _client()
	if llm == null or llm.get("busy") == true or not llm.has_method("complete_limited"): return
	var bond_node := _bonds()
	var standing: Dictionary = {}
	if bond_node != null and bond_node.has_method("standing"):
		var got: Variant = bond_node.call("standing", id)
		if got is Dictionary: standing = got
	var request: Dictionary = BOND_PROMPT.second_look(standing, his_line, her_line)
	var started: bool = bool(llm.call("complete_limited", str(request.system), [{"role": "user", "content": str(request.user)}],
		_on_answer.bind(id, turn), {"output_tokens": OUTPUT_TOKENS, "purpose": PURPOSE, "max_attempts": 1}))
	if started: sent += 1


## {"replies", "tagged", "rate", "low", "on"}, and "stopped" when three unreadable answers ended it.
func tag_rate() -> Dictionary:
	return {"replies": _replies, "tagged": _tagged, "rate": _rate(), "low": _low(), "on": _on(), "stopped": _stopped}


func _rate() -> float:
	return 1.0 if _replies == 0 else float(_tagged) / float(_replies)


## Under half after ten replies that answer him (bond_rules.gd READER): the page warns, and the second
## look may run.
func _low() -> bool:
	return _replies >= int(BOND.READER.min_replies) and _rate() < float(BOND.READER.rate)


func _on() -> bool:
	if not setting_override.is_empty(): return setting_override == "on"
	var loop := Engine.get_main_loop()
	if not loop is SceneTree: return false
	var settings: Node = (loop as SceneTree).root.get_node_or_null("Settings")
	if settings == null or not settings.has_method("get_value"): return false
	var value: Variant = settings.call("get_value", BOND.SECOND_LOOK_KEY)
	return value is String and str(value) == "on"


func _on_answer(text: String, error: String, id: String, turn: int) -> void:
	if not error.is_empty():
		print("[bond] second look for %s failed: %s" % [id, error.left(120)])
		return
	var read := BOND_TAGS.parse_reply(text)
	if read.is_empty():
		_unreadable += 1
		print("[bond] second look for %s was unreadable (%d in a row)" % [id, _unreadable])
		if _unreadable >= int(BOND.READER.fails):
			_stopped = true
			print("[bond] second look stopped for this session: three unreadable answers")
		return
	_unreadable = 0
	var facts := {"source": "reader", "turn": turn}
	var bond_node := _bonds()
	if bond_node != null:
		for entry: Variant in read.get("stand", []):
			if entry is Dictionary and bond_node.has_method("stand"):
				bond_node.call("stand", id, str(entry.ladder), str(entry.step), str(entry.get("why", "")), facts.duplicate())
		for entry: Variant in read.get("us", []):
			if entry is Dictionary and bond_node.has_method("step"):
				bond_node.call("step", id, str(entry.kind), str(entry.answer), {"source": "reader", "turn": turn, "he_spoke": true,
					"felt": str(read.get("felt", "")), "activity": str(entry.get("extra", "")), "place": "", "home": "", "meet": false})
	if read.has("felt"):
		var feeling := {}
		for key: String in ["felt", "felt_raw", "why", "forgive"]:
			if read.has(key): feeling[key] = read[key]
		var feelings := _impressions()
		if feelings != null and feelings.has_method("commit"):
			feelings.call("commit", id, feeling, "reader:%s:%d" % [id, turn])
	print("[bond] second look for %s: %s" % [id, text.strip_edges().left(160)])


func _client() -> Node:
	if client != null: return client
	var loop := Engine.get_main_loop()
	var director: Node = (loop as SceneTree).get_first_node_in_group("conversation_director") if loop is SceneTree else null
	if director == null: return null
	var summary: Variant = director.get("_summary_llm")
	return summary if summary is Node and is_instance_valid(summary) else null


func _context() -> Node:
	if host == null or not is_instance_valid(host): return null
	var context: Variant = host.get("world_context")
	return context if context is Node and is_instance_valid(context) else null


func _bonds() -> Node:
	if bonds != null: return bonds
	var context := _context()
	var found: Variant = context.get("player_bonds") if context != null else null
	return found if found is Node and is_instance_valid(found) else null


func _impressions() -> Node:
	if impressions != null: return impressions
	var context := _context()
	var found: Variant = context.get("impressions") if context != null else null
	return found if found is Node and is_instance_valid(found) else null
