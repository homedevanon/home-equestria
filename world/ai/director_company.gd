extends RefCounted
## Living-world company hooks: walking up to talk, befriending after a chat, friends walking together, sitting down together.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.

const TALK_DISTANCE := 1.6

var host: Node


func _init(owner_node: Node) -> void:
	host = owner_node


## A pony speaking to another pony more than a couple of metres away walks up to her.
## Only from ordinary routines: never over a player or AI command, never while held,
## seated or lying (standing up from a bench just to say one line looks wrong).
func _close_in(speaker_id: String, listener_id: String) -> void:
	var a: Node3D = host.characters[speaker_id].node; var b: Node3D = host.characters[listener_id].node
	if not is_instance_valid(a) or not is_instance_valid(b) or a == b: return
	# Friends walking together already keep their places beside each other; stopping one
	# to walk up to the other broke the outing up (dev 2026-09-23).
	if _walking_together([speaker_id, listener_id]): return
	if host._encounter_claimed(speaker_id): return
	var gap := Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z)
	if gap.length() < 2.6: return
	var nav := a.get_node_or_null("Navigator")
	if nav == null: return
	var owner: String = nav.command_owner
	if not (owner.is_empty() or owner.begins_with("life:") or owner.begins_with("social:")): return
	if (a.has_method("is_held") and a.is_held()) or a.has_meta("seated"): return
	if a.has_method("posture_status") and a.posture_status().get("kind", "stand") != "stand": return
	var goal := b.global_position + Vector3(gap.x, 0.0, gap.y).normalized() * TALK_DISTANCE
	nav.go_to(goal, nav.Gait.WALK)
	nav.command_owner = host.TALK_OWNER


## Friend behaviour (dev 2026-09-23). Ponies who just chatted become company: the living
## world plans their next outing together, so a chat in a doorway turns into a walk.
func _befriend(members: Array) -> void:
	var game: Node = host.get_parent()
	var life: Node = game.get("life") if game != null else null
	if life == null or not ("core" in life) or life.core == null: return
	# Already out together: the outing itself will keep them together.
	var ticket := ""
	for id in members:
		var node: Variant = host.characters[id].node if host.characters.has(id) else null
		var company: Dictionary = node.get_meta("social_group", {}) if is_instance_valid(node) else {}
		if ticket == "": ticket = str(company.get("id", "-"))
		elif str(company.get("id", "+")) != ticket: ticket = "mixed"
	if ticket != "-" and ticket != "mixed" and ticket != "": return
	life.core.note_company(members, 300.0, true)


## A company of ponies (living world outing members) is chatting among themselves now.
func _walking_together(ids: Array) -> bool:
	var ticket := ""
	for id in ids:
		var node: Variant = host.characters[id].node if host.characters.has(id) else null
		if not is_instance_valid(node) or not node.has_meta("social_group"): return false
		var company: Dictionary = node.get_meta("social_group")
		if ticket == "": ticket = str(company.get("id", ""))
		elif str(company.get("id", "")) != ticket: return false
	return ticket != ""


func company_chatting(members: Array) -> bool:
	if not host.group.active() or not host.group.ambient: return false
	for id in members:
		if id in host.group.members: return true
	return false


func propose_company_sit(members: Array, place: String) -> bool:
	var key := ",".join(PackedStringArray(members))
	var ids: Array[String] = []
	for id in members:
		if host.characters.has(id) and host.ambient_chatter.eligible(host.characters[id].node, host.player_head, 45.0): ids.append(str(id))
	if ids.size() < 2 or host.state != "idle" or host.group.active() or not is_instance_valid(host.player_head) or not host.ambient_budget.available():
		host._sit_agreed[key] = host._now(); return false
	host._sit_key = key
	host._current = ids[0]; host._turn_id += 1; host._player_text = ""; host._rewrite_used = false
	# No scripted "let's sit down" / "agreed" exchange (dev 2026-10-22: every pair said the same
	# lines); they settle in silently and talk about something real between them.
	host._group_request = "You just arrived together at %s and are settling in. Skip any talk about sitting down, being tired, or just agreeing. %s brings up something real between these ponies, like a shared interest, something she heard or wants to ask, or what is on her mind. The others reply in character. Write 3-6 short turns that each move the talk on." % [place, ids[0]]
	host._begin_group(ids, true)
	if not host.group.active(): host._sit_agreed[key] = host._now(); host._sit_key = ""
	return host.group.active()


func company_sit_agreed(key: String) -> bool:
	return host._now() - float(host._sit_agreed.get(key, -1e9)) < 120.0
