extends Node
## Bridge between persistent bonds, completed dialogue, activities and physical actors.
const INTENT := preload("res://world/relationships/relationship_intent.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const LADDER := preload("res://world/relationships/bond_ladder.gd")
const ACTION_HELP := "Relationship actions: relationship_offer(kind,activity,location_id) proposes an eligible offer to Anon; activity is walk/meal/visit/orchard/fishing, or place for time together at a mapped place (then give its location_id, e.g. a park; omit location_id otherwise). For a named destination use go_to and the mapped location; each agreeing companion travels there independently and stops on arrival. Follow Anon only for a walk without a named destination; it ends when he stays beyond walking range. If he takes his balloon during a shared activity, you can board it with him. relationship_answer(offer_id,accept) answers ONLY an existing player offer. Use a boolean accept. agreed(kind) records a step you both said yes to: Anon asked for it in his own words and you accept, or he said yes to your offer. State your actual offer or answer in speech. These changes commit only when your spoken line finishes. Never answer your own offer or fabricate player acceptance. request_space() withdraws physical permission for three minutes; say that you want space. buck_player() kicks Anon back with your hind legs when your spoken line ends; only for real, lasting anger at unwelcome contact, never for boops or petting you secretly enjoy. cuddle() walks over and rests with Anon on the bed, couch, supported grass or deployed blanket he is lying on, only if you want to. Actual friendship chooses beside or shoulder company; an established romantic relationship permits a closer snuggle, subject to current boundaries. kiss_player() walks up and initiates a kiss; your relationship line says whether that is natural yet. Adults only. A short spoken line is optional; Anon can end it with the kiss button."
## Added to the relationship prompt only while the player is a young AnonPony (world/life/player_form.gd), so a
## human's prompt is unchanged.
const YOUNG_HELP := " Anon is a foal (a filly or colt), so there is no romance with Anon: no dates, dating, courtship, moving in, engagement, marriage, kisses or flank smacks, and never [kiss_player]."
## Player thread report 2026-10-29: with no kiss tag to use, a pony asked for a kiss invented a
## condition instead ("beat me in a race first, loser carries the pears") and repeated it for days.
## dev 2026-10-29: the stage must not forbid her kiss, only discourage it very strongly. So
## [kiss_player] stays offered and this line rides along while the bond does not welcome it yet.
const KISS_NOT_READY := "Your relationship is not at kissing yet, so [kiss_player] is very nearly off-limits. Use it only for a truly beautiful moment, or when Anon has genuinely, cleverly won you over; asking, pestering or a nice day is not enough. Otherwise say you are not ready, in your own way, and never invent a task, race or condition he must meet first."
const PLAYER_FORM := preload("res://world/life/player_form.gd")
var game: Node
var bonds: Node
var actors: Dictionary = {}
var _staged: Dictionary = {}
var _player_utterances: Dictionary = {}
var _utterance_serial := 0
var _leases: Dictionary = {}
var _timer := 0.0
var _offer_after := 60.0
var _house_signature: Dictionary = {}
var _kiss_requests: Dictionary = {}
var _after_kiss_intents: Dictionary = {}
## The activity of each pony's last generated outing offer (roll_outing).
var _last_outing: Dictionary = {}

func setup(host: Node) -> void:
	game = host; bonds = host.world_context.player_bonds
	add_to_group("player_relationships")
	host.world_context.event_recorded.connect(_event)
	bonds.boundary.connect(_boundary)
	# Princess Celestia's replies to Spike's letters (player thread report 2026-10-29).
	var replies := preload("res://world/ai/celestia_reply.gd").new()
	replies.name = "CelestiaReply"; add_child(replies); replies.setup(host)
	# Letters, Derpy's mail and appointments (docs/LETTERS_PLAN_2026_10_29.md).
	for row: Array in [["LetterPost", "res://world/letters/letter_post.gd"], ["LetterPaper", "res://world/letters/paper/letter_paper.gd"],
			["LetterCourier", "res://world/letters/courier/letter_courier.gd"], ["Appointments", "res://world/life/appointments/appointments.gd"]]:
		if not ResourceLoader.exists(str(row[1])): continue
		var node: Node = (load(str(row[1])) as GDScript).new()
		node.name = str(row[0]); add_child(node); node.call("setup", host)
	# Relationship levels (world/relationships/bond_ladder.gd): named in her prompt, shown in the
	# profile, and a level-up is celebrated where she stands.
	var impressions: Node = host.world_context.impressions
	impressions.ladder_provider = ladder
	if not impressions.changed.is_connected(_level_check): impressions.changed.connect(_level_check)
	if not bonds.changed.is_connected(_level_check): bonds.changed.connect(_level_check)

## Both level rows for one pony (bond_ladder.gd compute()).
func ladder(id: String) -> Dictionary:
	var context: Node = game.world_context if is_instance_valid(game) else null
	if context == null or not is_instance_valid(context.impressions): return {}
	var r: Dictionary = bonds.record_for(id)
	var gained: Dictionary = context.impressions.xp_for(id)
	var actor: Node = actors.get(id)
	var identity: Resource = actor.get("identity") if is_instance_valid(actor) else null
	return LADDER.compute({"met": bool(bonds.knowledge(id).get("met", false)), "stage": str(r.stage),
		"familiarity": float(r.familiarity), "trust": float(r.trust),
		"friend_xp": int(gained.friendship), "love_xp": int(gained.romance),
		"romance": bonds.adults.has(id) and bonds.eligible_for_romance(id),
		"stallion": identity != null and bool(identity.get("stallion")),
		"turned_down": bonds.offer_on_cooldown(id, "dating") and str(r.stage) in ["friend", "close_friend"],
		"together_s": float(r.get("together_s", 0.0)), "ready_s": bonds.READY_TOGETHER_S,
		"can_ask": bonds.eligible(id, "dating")})

## A level reached is announced once: she learns it as a world event, and if she is loaded, hearts
## and the new level's name rise over her head. The first look at a pony (and every drop, such as
## a break-up) is only remembered.
func _level_check(id: String) -> void:
	var context: Node = game.world_context if is_instance_valid(game) else null
	if context == null or context._read_only or not context.valid_id(id): return
	var levels := ladder(id)
	if levels.is_empty(): return
	if not context.state.get("bond_levels") is Dictionary: context.state["bond_levels"] = {}
	var known: Dictionary = context.state.bond_levels
	var now := {"friendship": int(levels.friendship.level), "love": int((levels.love as Dictionary).get("level", -1)) if not (levels.love as Dictionary).is_empty() else -1}
	var before: Variant = known.get(id)
	known[id] = now
	if not before is Dictionary or before == now: 
		if not before is Dictionary: context._changed()
		return
	context._changed()
	for row: String in ["love", "friendship"]:
		if int(now[row]) <= int((before as Dictionary).get(row, -1)): continue
		var name := str((levels[row] as Dictionary).name)
		var line := ("You and Anon reached a new %s level: %s." % [row, name])
		context.record("bond_level", line, [id, "player"], [id, "player"], "bond-level:%s:%s:%s" % [id, row, name])
		_celebrate(id, name)
		return

func _celebrate(id: String, name: String) -> void:
	var actor: Node3D = actors.get(id) as Node3D
	if not is_instance_valid(actor) or not actor.is_inside_tree(): return
	var boop: Node = actor.get("boop_node")
	if is_instance_valid(boop) and boop.has_method("celebrate"): boop.call("celebrate")
	var top: Vector3 = actor.call("listen_point") + Vector3.UP * 0.45 if actor.has_method("listen_point") else actor.global_position + Vector3.UP * 1.6
	var label := Label3D.new()
	var identity: Resource = actor.get("identity")
	label.text = "%s\n%s!" % [str(identity.get("display_name")) if identity != null else id.capitalize(), name]
	label.font_size = 56; label.pixel_size = 0.0014; label.outline_size = 12
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED; label.no_depth_test = true
	label.modulate = Color(1.0, 0.62, 0.82); label.outline_modulate = Color(0.32, 0.12, 0.3)
	game.add_child(label)
	label.global_position = top
	var tween := label.create_tween()
	tween.tween_property(label, "global_position", top + Vector3.UP * 0.5, 3.0)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 3.0).set_delay(1.5)
	tween.tween_callback(label.queue_free)
	if identity != null and not bool(identity.get("stallion")):
		var squee := AudioStreamPlayer3D.new()
		squee.stream = load("res://world/audio/pony/squee_%d.ogg" % (1 + randi() % 2))
		squee.volume_db = -6.0
		actor.add_child(squee); squee.play()
		squee.finished.connect(squee.queue_free)

func register_actor(actor: Node3D) -> void:
	var identity: Resource = actor.get("identity")
	if identity == null: return
	var id := str(identity.id)
	actors[id] = actor
	bonds.register(id, not bool(identity.filly))
	actor.set_meta("relationship_runtime",self)
	actor.set_meta("relationship_id",id)
	if actor.has_signal("physical_reaction") and not actor.physical_reaction.is_connected(_contact.bind(id)):
		actor.physical_reaction.connect(_contact.bind(id))
	if actor.get_node_or_null("Affection") == null:
		var affection := preload("res://world/relationships/pony_affection.gd").new()
		affection.name = "Affection"; affection.mare = actor; actor.add_child(affection)

func action_context(id: String) -> Dictionary:
	var kinds: Array = bonds.available(id)
	if _home_for_offer(id).is_empty(): kinds.erase("move_in")
	return {"offers":kinds, "pending":bonds.pending(id)}

func prompt_for(id: String) -> String:
	# The relationship tag rules (formerly ACTION_HELP, 1.5 KB on every request and every group
	# participant) ride once in the dialogue prompt's fixed head (director_prompts.gd RELATIONSHIP_RULES).
	var result: String = bonds.prompt_for(id) + ("\n" + YOUNG_HELP.strip_edges() if _young_player() else "")
	return result + ("\n" + KISS_NOT_READY if _kiss_not_ready(id) else "")

func _home_for_offer(id: String) -> String:
	if not is_instance_valid(game.population): return ""
	# Moving in means sharing her existing home; it does not evict other households.
	var house: Node3D = game.population.home_house(id)
	if house != null: return house.place_id()
	# Cloud homes use their stable authored building name.
	return "cloudominium_01" if id=="rainbow_dash" else ""

func stage(id: String, action: Dictionary, turn: int, executor: Node = null) -> void:
	var row: Dictionary = {"turn":turn,"action":action.duplicate(true),"executor":weakref(executor) if executor!=null else null}
	if action.get("type") == "kiss_player" and _after_kiss_intents.has(id):
		row.after_kiss_serial = int(_after_kiss_intents[id])
		row.eager = true
	if action.get("type") == "relationship_answer":
		var pending: Dictionary = bonds.pending(id)
		var utterance: Dictionary = _player_utterances.get(id, {})
		# Capture the player's actual request, not a mutable director speech/ambient turn.
		row.answer_source = utterance.duplicate(true)
		row.offer_id = str(pending.get("id", ""))
		row.answer_bound = pending.get("by") == "player" and action.get("offer_id") == row.offer_id and utterance.get("offer_id") == row.offer_id
	if action.get("type") == "agreed":
		# Bound to the player's line she is answering; a later or ambient turn cannot commit it.
		row.answer_source = (_player_utterances.get(id, {}) as Dictionary).duplicate(true)
	_staged[id] = row

func finish_spoken(id: String, turn: int) -> void:
	var row: Dictionary = _staged.get(id,{})
	if row.is_empty() or int(row.turn)!=turn: return
	_staged.erase(id)
	var a: Dictionary = row.action
	var committed := false
	if a.type=="relationship_offer":
		committed = not bonds.offer(id,a.kind,"pony",a.activity,_home_for_offer(id) if a.kind=="move_in" else "",str(a.get("location_id",""))).is_empty()
	elif a.type=="request_space":
		committed=bonds.request_space(id)
		var actor: Node3D = _actor(id)
		if is_instance_valid(actor) and actor.get_node_or_null("Affection")!=null:actor.get_node("Affection").end()
	elif a.type=="kiss_player":
		if row.has("after_kiss_serial") and (int(_after_kiss_intents.get(id, -1)) != int(row.after_kiss_serial) or not _after_kiss_valid(id, int(row.after_kiss_serial))):
			var kiss_executor: Node = row.executor.get_ref() if row.get("executor") != null else null
			if is_instance_valid(kiss_executor): kiss_executor._report(a, "failed", "After-kiss invitation expired or consent changed")
			return
		_queue_kiss(id, row)
		return
	elif a.type=="cuddle":
		committed=_join_rest(id)
	elif a.type=="buck_player":
		var actor: Node3D = _actor(id)
		var affection:Node=actor.get_node_or_null("Affection") if is_instance_valid(actor) else null
		committed=affection!=null and affection.buck(game.inventory.player_body)
	elif a.type == "relationship_answer":
		var source: Dictionary = _player_utterances.get(id, {})
		var captured: Dictionary = row.get("answer_source", {})
		committed = bool(row.get("answer_bound", false)) and not captured.is_empty() and source == captured and bonds.pending(id).get("id") == row.offer_id and bonds.answer(id,a.offer_id,"pony",a.accept)
	elif a.type == "agreed":
		var captured: Dictionary = row.get("answer_source", {})
		committed = not captured.is_empty() and _player_utterances.get(id, {}) == captured and bonds.agree(id, str(a.kind), _home_for_offer(id) if a.kind == "move_in" else "")
	var executor: Node=row.executor.get_ref() if row.get("executor")!=null else null
	if is_instance_valid(executor): executor._report(a,"completed" if committed else "failed","Spoken agreement committed" if committed else "Offer expired or eligibility changed")

## Only kiss_player permits a silent intention; other relationship actions require speech.
func finish_silent(id: String, turn: int) -> void:
	var row: Dictionary = _staged.get(id, {})
	if int(row.get("turn", -1)) == turn and row.get("action", {}).get("type") == "kiss_player": finish_spoken(id, turn)

func cancel_pending() -> void:
	for row: Dictionary in _staged.values():
		var executor:Node=row.executor.get_ref() if row.get("executor")!=null else null
		if is_instance_valid(executor):executor._report(row.action,"cancelled","Speech did not finish")
	_staged.clear()
	_after_kiss_intents.clear()

## Parse one concrete player utterance against its current offer; never use later ambient text.
func player_text(id: String, raw: String, short_answer_allowed: bool = true, utterance_id: int = -1) -> void:
	var actor: Node3D = _actor(id)
	var name_text: String = id.replace("_", " ")
	if actor != null and actor.get("identity") != null and "display_name" in actor.identity:
		name_text = str(actor.identity.display_name)
	var normalized_address: String = INTENT.whitespace(raw).to_lower()
	var addressed: bool = normalized_address.begins_with(name_text.to_lower() + ", ") or normalized_address.begins_with("hey " + name_text.to_lower() + ", ")
	var intent: Dictionary = INTENT.parse(raw, name_text, short_answer_allowed or addressed)
	_utterance_serial += 1
	var source: Dictionary = {"serial": _utterance_serial, "event": utterance_id, "raw": raw, "offer_id": ""}
	_player_utterances[id] = source
	if intent.is_empty(): return
	var offer: Dictionary = bonds.pending(id)
	if intent.type == "answer":
		if not offer.is_empty() and offer.by == "pony":
			source.offer_id = str(offer.id)
			bonds.answer(id, offer.id, "player", bool(intent.accept))
		return
	var kind: String = str(intent.kind)
	if kind == "break_up":
		bonds.break_up(id)
		return
	var made: String = bonds.offer(id, kind, "player", str(intent.activity), _home_for_offer(id) if kind == "move_in" else "")
	source.offer_id = made
	if made.is_empty() and kind == "dating" and bonds.offer_on_cooldown(id, "dating"): bonds.pestered(id)

func _event(event: Dictionary) -> void:
	if event.kind!="heard_speech" or event.subjects.size()<2: return
	var speaker := str(event.subjects[0]); var listener := str(event.subjects[1])
	if listener=="player" and actors.has(speaker) and is_instance_valid(game.director) and game.director._authored_active.is_empty() and not game.director._player_text.is_empty(): bonds.experience(speaker,"conversation",event.id)

func shared_activity(kind: String, at: Vector3, event_id: String, participants: Array = []) -> void:
	var picnic: Node = get_tree().get_first_node_in_group("picnic_runtime")
	if kind == "meal" and picnic != null and picnic.contains_player(at): return
	var camera: Camera3D = game._find_camera(game.player)
	if camera==null or camera.global_position.distance_to(at)>12.0: return
	for id: String in actors:
		var actor: Node3D = _actor(id)
		if actor==null or actor.global_position.distance_to(at)>8.0: continue
		if not participants.is_empty() and id not in participants: continue
		if actor.get("sleeping")==true: continue
		if not game.director or not game.director.awareness.can_hear(actor,camera,12.0): continue
		bonds.experience(id,kind,event_id)

func affection_allowed(actor: Node3D, kind: String) -> bool:
	var id := str(actor.get_meta("relationship_id",""))
	if kind!="kiss" and (actor.get("sleeping")==true or actor.is_speaking() or actor.get("_held")==true): return false
	return bonds.contact(id,kind)

func _contact(kind: String, id: String) -> void:
	if kind!="flank_smack": return
	var actor: Node3D = _actor(id)
	if bonds.contact(id,"flank_touch"):
		if is_instance_valid(actor): actor.expressions.kiss(); actor.set_dialogue_expression("amused")
		var partner: bool = str(bonds.record_for(id).stage) in ["dating","engaged","married"]
		game.world_context.record("affection", "You welcomed Anon's playful contact." if partner else "You welcomed Anon's playful contact. This does not mean you welcome unlimited repetition.",[id,"player"],[id,"player"])
	elif is_instance_valid(actor) and actor.get_node_or_null("Affection") != null and bonds.refused_again(id, "flank_touch"):
		# An unwelcome smack, repeated within half a minute of the last: a buck, as with kisses.
		# Bucking is a last resort (dev 2026-09-28); the first time gets only her AI reaction.
		actor.get_node("Affection").buck(game.inventory.player_body)

## Unwelcome contact: she lets go of any affectionate pose. Words, mood, space and bucking are
## her AI reaction's choice (conversation_director contact summaries), not scripted here.
func _boundary(id: String, _level: float, _kind: String) -> void:
	_after_kiss_intents.erase(id)
	_finish_kiss_request(id, false, "Kissing permission withdrawn")
	var actor: Node3D = _actor(id)
	if not is_instance_valid(actor): return
	var affection := actor.get_node_or_null("Affection")
	if affection!=null:
		affection.end(); affection.cancel_afterglow()

func _process(delta: float) -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.player):
		for id: String in _kiss_requests.keys(): _finish_kiss_request(id, false, "Player unavailable")
		return
	_tick_kiss_requests(delta)
	_timer -= delta; _offer_after -= delta
	if _timer>0.0: return
	_timer=1.0
	var camera: Camera3D = game._find_camera(game.player)
	# A young player is never asked out or courted (player_bonds.gd also refuses every romantic kind).
	var young := _young_player()
	for id: String in actors.keys():
		# A freed pony cannot be assigned to a typed variable; test the raw entry first.
		if not is_instance_valid(actors[id]): actors.erase(id); _leases.erase(id); continue
		var actor: Node3D=actors[id]
		bonds.expire_plan(id)
		_apply_household(id)
		# Time together counts toward her asking him out (player_bonds.gd courtship).
		# A spa visit is not time together (SPA_PLAN_2026_10_29.md section 3).
		if camera != null and actor.global_position.distance_to(camera.global_position) < 5.0 and not bool(actor.get("sleeping")) and not actor.has_meta("spa_client"): bonds.add_together(id, 1.0)
		_plan_step(id,actor,camera)
		if _offer_after <= 0.0 and camera != null and actor.global_position.distance_to(camera.global_position) < 4.0 and _free(actor) and bonds.pending(id).is_empty():
			var row: Dictionary = bonds.record_for(id)
			if not young and bonds.ready_to_ask(id) and randf() < .25:
				_offer_after = 180.0
				_request_generated(id, {"kind": "relationship_offer", "offer_kind": "dating", "activity": "walk"}, func() -> bool: return _offer_valid(id, "dating"))
			elif row.familiarity >= 20 and randf() < .12:
				_offer_after = 180.0
				var activity := roll_outing(str(_last_outing.get(id, "")))
				_last_outing[id] = activity
				var kind: String = "date" if not young and bonds.eligible(id, "date") and randf() < .4 else "outing"
				_request_generated(id, {"kind": "relationship_offer", "offer_kind": kind, "activity": activity}, func() -> bool: return _offer_valid(id, kind))

	if _offer_after<=0.0: _offer_after=30.0

## Generated outing offers (thread 43684951: ponies over-suggested fishing, a quarter of all rolls).
## Weighted toward variety: fishing 1 in 8 before the no-repeat rule (about 1 in 9 after it) and never
## twice in a row for one pony; `last` is that pony's previous roll.
const OUTING_WEIGHTS := {"walk": 3, "meal": 2, "visit": 2, "fishing": 1}
static func roll_outing(last: String) -> String:
	var total := 0
	for activity: String in OUTING_WEIGHTS:
		if not (activity == "fishing" and last == "fishing"): total += int(OUTING_WEIGHTS[activity])
	var roll := randi() % total
	for activity: String in OUTING_WEIGHTS:
		if activity == "fishing" and last == "fishing": continue
		roll -= int(OUTING_WEIGHTS[activity])
		if roll < 0: return activity
	return "walk"

## Eligibility is checked both when exposing the action and again on arrival.
func can_kiss_player(id: String) -> bool:
	var actor := _actor(id)
	return actor != null and actor.identity != null and not actor.identity.filly and not actor.sleeping and not _young_player() and not bonds.kiss_barred(id)

## She may kiss him (can_kiss_player) but the bond does not welcome it yet (KISS_NOT_READY).
func _kiss_not_ready(id: String) -> bool:
	return can_kiss_player(id) and not bonds.welcomes(id, "kiss")

## A filly or colt player (world/life/player_form.gd); human Anon and grown AnonPony are not.
func _young_player() -> bool:
	return is_inside_tree() and PLAYER_FORM.is_young(PLAYER_FORM.active(get_tree()))

## One quiet minute after his kiss, the requested little invitation precedes an eager return.
func invite_after_kiss(id: String, serial: int) -> bool:
	if not _after_kiss_valid(id,serial): return false
	var director: Node=game.get("director")
	if director==null:return false
	_after_kiss_intents[id] = serial
	var valid := func() -> bool: return int(_after_kiss_intents.get(id, -1)) == serial and _after_kiss_valid(id,serial)
	var finished := func() -> void:
		# Finishing generated speech is not consent. Only an explicit generated
		# kiss_player action, committed by the ordinary action pipeline, can kiss.
		if int(_after_kiss_intents.get(id, -1)) == serial: _after_kiss_intents.erase(id)
	var requested := _request_generated(id, {"kind": "after_kiss", "serial": serial}, valid, finished)
	if not requested and int(_after_kiss_intents.get(id, -1)) == serial: _after_kiss_intents.erase(id)
	return requested

func _offer_valid(id: String, kind: String) -> bool:
	var actor: Node3D = _actor(id)
	if actor == null or not is_instance_valid(game) or not is_instance_valid(game.player): return false
	var camera: Camera3D = game._find_camera(game.player)
	return camera != null and actor.global_position.distance_to(camera.global_position) < 4.0 and actor.get("sleeping") != true and actor.get("_held") != true and bonds.pending(id).is_empty() and bonds.eligible(id, kind) and (kind != "dating" or bonds.ready_to_ask(id))

## Generated requests create no offer, action or fallback line when generation fails.
func _request_generated(id: String, intent: Dictionary, valid: Callable, finished: Callable = Callable()) -> bool:
	var director: Node = game.get("director") if is_instance_valid(game) else null
	if not is_instance_valid(director) or not director.has_method("request_relationship_intent") or not valid.is_valid() or valid.call() != true: return false
	return director.call("request_relationship_intent", id, intent, valid, finished) == true

func _after_kiss_valid(id: String, serial: int) -> bool:
	if not can_kiss_player(id) or not is_instance_valid(game):return false
	var kisser: Node=game.get("kisser")
	if kisser==null or not is_instance_valid(kisser.camera):return false
	var actor := _actor(id)
	var affection := actor.get_node_or_null("Affection")
	return affection!=null and affection.kind.is_empty() and affection._return_serial==serial and actor.global_position.distance_to(kisser.camera.global_position)<3.0

func _queue_kiss(id: String, row: Dictionary) -> void:
	_finish_kiss_request(id, false, "Replaced by another kiss intention")
	var actor := _actor(id)
	var kisser: Node = game.get("kisser") if is_instance_valid(game) else null
	var nav := actor.get_node_or_null("Navigator") if actor != null else null
	var executor: Node = row.executor.get_ref() if row.get("executor") != null else null
	if not can_kiss_player(id) or kisser == null or (nav == null and not actor.is_held()):
		if is_instance_valid(executor): executor._report(row.action, "failed", "Kiss unavailable or not welcomed")
		return
	if is_instance_valid(executor) and not executor.movement.is_empty(): executor._end_move("cancelled", "Chose to kiss Anon")
	var request := row.duplicate()
	request.left = 20.0; request.refresh = 0.0; request.goal = Vector3.INF
	request.owner = nav.command_owner if nav != null else ""
	request.wander = nav.wander_enabled if nav != null else false
	request.token = "kiss:" + id
	if nav != null:
		nav.stay(); nav.command_owner = request.token; nav.wander_enabled = false
	_kiss_requests[id] = request
	if is_instance_valid(executor): executor._report(row.action, "running", "Approaching Anon to kiss him")

func cancel_kiss_action(id: String, action_id: String = "") -> bool:
	var row: Dictionary = _kiss_requests.get(id, {})
	if row.is_empty() or (not action_id.is_empty() and row.action.id != action_id): return false
	_finish_kiss_request(id, false, "Kiss intention cancelled")
	return true

func _tick_kiss_requests(delta: float) -> void:
	for id: String in _kiss_requests.keys():
		var row: Dictionary = _kiss_requests[id]
		row.left -= delta; row.refresh -= delta
		var actor := _actor(id)
		var kisser: Node = game.get("kisser")
		if not can_kiss_player(id) or kisser == null or not is_instance_valid(kisser.camera) or row.left <= 0.0:
			_finish_kiss_request(id, false, "Kiss approach expired or eligibility changed"); continue
		var nav := actor.get_node_or_null("Navigator")
		if nav != null and nav.command_owner != row.token:
			_finish_kiss_request(id, false, "Approach interrupted"); continue
		if actor.is_speaking(): continue
		var to: Vector3 = kisser.camera.global_position - actor.global_position
		to.y = 0.0
		if to.length() <= .95 or actor.is_held():
			# Release the approach lease before Affection claims the same navigator.
			_release_kiss_nav(actor, row)
			var begun: bool = kisser.begin_from_pony(actor)
			if begun and row.get("eager",false) and not actor.is_held() and actor.grounded() and (actor.posture==null or not actor.posture.active()) and not actor.get_meta("cuddle_active",false):
				actor.lunge(to.normalized()*minf(.8,to.length()),.22)
			_finish_kiss_request(id, begun, "Kiss begun" if begun else "Kiss unavailable on arrival")
		elif row.refresh <= 0.0:
			row.refresh = .5
			var goal := actor.global_position + to.normalized() * (to.length() - .8)
			if not Vector3(row.goal).is_finite() or goal.distance_to(row.goal) > .25:
				row.goal = goal
				nav.go_to(goal, 1 if row.get("eager",false) else 0)

func _release_kiss_nav(actor: Node3D, row: Dictionary) -> void:
	var nav := actor.get_node_or_null("Navigator") if actor != null else null
	if nav != null and nav.command_owner == row.token:
		nav.stay(); nav.command_owner = row.owner; nav.wander_enabled = row.wander

func _finish_kiss_request(id: String, success: bool, reason: String) -> void:
	if not _kiss_requests.has(id): return
	var row: Dictionary = _kiss_requests[id]
	_kiss_requests.erase(id)
	_release_kiss_nav(_actor(id), row)
	var executor: Node = row.executor.get_ref() if row.get("executor") != null else null
	if is_instance_valid(executor): executor._report(row.action, "completed" if success else "failed", reason)

## cuddle(): she joins Anon on the bed or couch he is lying on (couch.gd / shared_bed.gd accept).
func _join_rest(id: String) -> bool:
	var actor: Node3D = _actor(id)
	var body: Node = game.inventory.player_body if is_instance_valid(game.inventory) else null
	if actor == null or not is_instance_valid(body) or not body.get_meta("couch_sleeping", false): return false
	var seat: Node3D = body.get("seat") as Node3D
	var rest: Node = seat.get_meta("couch") if is_instance_valid(seat) and seat.has_meta("couch") else null
	return is_instance_valid(rest) and rest.has_method("accept") and rest.accept(actor)

## Compatibility for the earlier immediate action; approach requests use _queue_kiss.
func _kiss_him(id: String) -> bool:
	var actor := _actor(id)
	var kisser: Node = game.get("kisser") if is_instance_valid(game) else null
	return can_kiss_player(id) and kisser != null and kisser.begin_from_pony(actor)

## The registered pony, or null once freed (a freed instance cannot be assigned to a typed var).
func _actor(id: String) -> Node3D:
	var entry: Variant = actors.get(id)
	return entry as Node3D if is_instance_valid(entry) else null

func _free(actor: Node3D) -> bool:
	if not is_instance_valid(actor): return false
	if actor.get("sleeping")==true or actor.get("_held")==true or actor.is_speaking(): return false
	if actor.has_method("action_interruption_reason") and not actor.action_interruption_reason().is_empty(): return false
	var nav:=actor.get_node_or_null("Navigator")
	return nav!=null and (nav.command_owner.is_empty() or nav.command_owner.begins_with("life:") or nav.command_owner.begins_with("bond:"))

func _plan_step(id: String, actor: Node3D, camera: Camera3D) -> void:
	var plan: Dictionary=bonds.record_for(id).plan
	var nav:=actor.get_node_or_null("Navigator")
	if nav==null or camera==null: return
	var lease: Dictionary=_leases.get(id,{})
	if plan.is_empty():
		if not lease.is_empty() and nav.command_owner==lease.token:
			nav.stay();nav.command_owner="";nav.wander_enabled=lease.wander
		_leases.erase(id);return
	if not _free(actor):
		if not actor.has_meta("fishing_companion") and not lease.is_empty() and nav.command_owner!=lease.token: _leases.erase(id)
		return
	if lease.is_empty():
		lease={"token":"bond:"+str(plan.id),"wander":nav.wander_enabled,"seconds":0.0,"distance":0.0,"last":camera.global_position}
		_leases[id]=lease;nav.command_owner=lease.token
		if plan.activity == "place":
			var destination: Vector3 = nav.command_location(str(plan.get("place", "")))
			if destination.is_finite(): nav.go_to(destination)
		else: nav.follow(camera)
	if plan.activity == "place":
		# The shared plan has a destination, not a moving player target. Wait there
		# after arrival, then count actual time together; never restart following.
		var spot: Vector3 = nav.command_location(str(plan.get("place", "")))
		if spot.is_finite() and actor.global_position.distance_to(spot)<20.0 and camera.global_position.distance_to(spot)<20.0:
			lease.at_place=float(lease.get("at_place",0.0))+1.0
			if float(lease.at_place)>=90.0: bonds.experience(id,"place",plan.id)
		return
	var lost: bool = actor.global_position.distance_to(camera.global_position) > 30.0 or not nav.command_target_floor(camera.global_position).is_finite()
	lease.lost_seconds = float(lease.get("lost_seconds", 0.0)) + 1.0 if lost else 0.0
	if float(lease.lost_seconds) >= 8.0:
		bonds.cancel_plan(id)
		if nav.command_owner == lease.token:
			nav.stay(); nav.command_owner = ""; nav.wander_enabled = lease.wander
		_leases.erase(id); return
	if nav.command_owner==lease.token and not is_instance_valid(nav.get("_follow_target")): nav.follow(camera)
	if actor.global_position.distance_to(camera.global_position)>5.0: lease.last=camera.global_position;return
	var travel: float=lease.last.distance_to(camera.global_position)
	lease.last=camera.global_position
	# Teleports and standing AFK cannot complete a walk.
	if travel>.05 and travel<6.0: lease.distance+=travel;lease.seconds+=1.0
	if plan.activity=="walk" and lease.seconds>=60.0 and lease.distance>=60.0:
		bonds.experience(id,"walk",plan.id)
	elif plan.activity=="visit":
		var home:=HOUSE.at(get_tree(),actor.global_position)
		if home!=null and HOUSE.at(get_tree(),camera.global_position)==home:
			lease.seconds+=1.0
			if lease.seconds>=120.0:bonds.experience(id,"visit",plan.id)

func _apply_household(id: String) -> void:
	var home_id := str(bonds.record_for(id).shared_home_id)
	if not is_instance_valid(game.population):return
	var previous:Dictionary=_house_signature.get(id,{})
	var old_house:Node3D=previous.house.get_ref() if previous.get("house")!=null else null
	if is_instance_valid(old_house) and previous.id!=home_id:
		old_house.remove_meta("shared_player_home")
		old_house.remove_meta("player_partner")
		old_house.set_sleepers(game.population.residents_of(previous.id))
		var old_bed:=old_house.get_node_or_null("PlayerRest")
		if old_bed!=null:old_bed.queue_free()
		_house_signature.erase(id)
	if home_id.is_empty():return
	for house:Node3D in get_tree().get_nodes_in_group("house_interiors"):
		if house.place_id()!=home_id:continue
		if previous.get("instance",0)==house.get_instance_id() and house.get_meta("player_partner","")==id:return
		var residents:Array=game.population.residents_of(home_id)
		if "player" not in residents:residents.append("player")
		house.set_meta("shared_player_home",true)
		house.set_meta("player_partner",id)
		house.set_sleepers(residents)
		var rest:=preload("res://world/relationships/shared_bed.gd").new()
		rest.name="PlayerRest";rest.house=house;rest.partner_id=id;rest.runtime=self
		house.add_child(rest)
		_house_signature[id]={"id":home_id,"house":weakref(house),"instance":house.get_instance_id()}
		return

func _exit_tree() -> void:
	for id: String in _kiss_requests.keys(): _finish_kiss_request(id, false, "Relationship runtime closed")
