extends Node
## Bridge between persistent bonds, completed dialogue, activities and physical actors.
const INTENT := preload("res://world/relationships/relationship_intent.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const LADDER := preload("res://world/relationships/bond_ladder.gd")
const ACTION_HELP := "Relationship actions take effect only after your spoken line ends, and you must state your actual offer or answer out loud. Use relationship_offer(kind,activity,location_id) to make Anon an eligible offer. Set activity to walk/meal/visit/orchard/fishing, or place for time at a mapped place like a park (give its location_id only for place; omit it otherwise). For a named destination, use go_to with that mapped location; each agreeing companion travels there on their own and stops on arrival. Only follow Anon on a walk with no named destination, which ends if he stays out of walking range. If he takes his balloon during a shared activity, you can board it with him. Use relationship_answer(offer_id,accept) with a boolean accept ONLY to answer an existing player offer. Never answer your own offer or fake his acceptance. Record a step you both agreed to with agreed(kind), whether Anon asked in his own words and you accepted, or he said yes to your offer. Call request_space() to withdraw physical permission for three minutes, and say you want space. Use buck_player() to kick Anon back with your hind legs after your line ends, only for real, lasting anger at unwelcome contact, never for boops or petting you secretly enjoy. If you want to, use cuddle() to walk over and rest with Anon on the bed, couch, supported grass or deployed blanket he is lying on. Actual friendship chooses beside or shoulder company, while an established romance allows a closer snuggle within current boundaries. For adults only, kiss_player() walks up and starts a kiss; your relationship line says if that is natural yet. A short spoken line is optional, and Anon can end it with the kiss button."
## Added to the relationship prompt only while the player is a young AnonPony (world/life/player_form.gd), so a
## human's prompt is unchanged.
const YOUNG_HELP := " Since Anon is a foal (a filly or colt), romance is off-limits: no dates, dating, courtship, moving in, engagement, marriage, kisses or flank smacks, and never [kiss_player]."
## Player thread report 2026-10-29: with no kiss tag to use, a pony asked for a kiss invented a
## condition instead ("beat me in a race first, loser carries the pears") and repeated it for days.
## dev 2026-10-29: the stage must not forbid her kiss, only discourage it very strongly. So
## [kiss_player] stays offered and this line rides along while the bond does not welcome it yet.
const KISS_NOT_READY := "You aren't at the kissing stage yet, so [kiss_player] is almost off-limits. Save it for a truly beautiful moment or when Anon genuinely and cleverly wins you over. Asking, pestering, or a nice day isn't enough. Otherwise, say in your own way that you aren't ready, and never invent a task, race, or condition he must meet first."
## dev 2026-11-15: "The llm SHOULD have agency". With romance_rules.FACTS the line no longer forbids;
## it says the kiss is hers to choose and that whatever she chooses happens (shorter, 37 tokens).
const KISS_YOUR_CHOICE := "You and Anon are not a couple. It is up to you whether you want to kiss him right now. If you do, use [kiss_player] or tell him he can kiss you. If you don't, turn him down in your own way, and don't make up any task or condition he has to meet first."
const RULES := preload("res://world/relationships/romance_rules.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
## Relationship overhaul 2026-11-21 (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md, contract
## docs/RELATIONSHIP_BUILD_2026_11_21.md section 4). With BOND.DYNAMIC on, this file passes her tags
## on and reports facts; it never judges her words and never reads his speech with a pattern.
const BOND := preload("res://world/relationships/bond_rules.gd")
## The second look (Words package); created by name, never preloaded (no cycle can form).
const BOND_READER_PATH := "res://world/relationships/bond_reader.gd"
## The face that shows romance on her (hybrid_mare/face_poses.gd: heart eyes and a blush).
const WARM_FACE := "affectionate"
## What a plan's activity may be (player_bonds.gd ACTIVITIES).
const PLAN_ACTIVITIES := ["walk", "fishing", "orchard", "meal", "visit", "place"]
var _reader: Node
## id -> Array of staged action rows for her line ({"turn", "action", "executor"}).
var _bond_staged: Dictionary = {}
## id -> the step the game asked her to voice ({"kind": "bond_ask", "step", "activity"}).
var _bond_invite: Dictionary = {}
## id -> the turn id of her latest contact turn (director_contacts.gd contact_turn).
var _contact_turns: Dictionary = {}
## id -> a contact turn that has had no finished line of hers yet.
var _contact_open: Dictionary = {}
## id -> her finished lines since he last spoke to her or touched her (he_spoke: she cannot
## answer for him). Absent: he has not, this session.
var _lines_since_him: Dictionary = {}
## id -> true: a touch she turned away, watched until he steps back out of reach.
var _touch_watch: Dictionary = {}
## id -> true: he spoke to her, touched her or did something with her since they last parted.
var _with_him: Dictionary = {}
## game.player_sleeping as last seen: he falling asleep is an event, read from the sleep system.
var _he_slept := false
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
## 2026-11-19: her spoken line to Anon this turn, sentence by sentence ({"turn", "text"}), read when
## it finishes (_read_reply); and the generated offer she was asked to voice ({"kind", "activity", "until"}).
var _reply_text: Dictionary = {}
var _generated_offer: Dictionary = {}

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
	# The second look and the measured tag rate (bond_reader.gd), only with the new relationships.
	if BOND.DYNAMIC and ResourceLoader.exists(BOND_READER_PATH):
		_reader = (load(BOND_READER_PATH) as GDScript).new()
		_reader.name = "BondReader"; add_child(_reader); _reader.call("setup", host)
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
	if BOND.DYNAMIC:
		# bond_ladder.gd compute() reads her own stated steps from "standing" (design 10.2).
		var row: Dictionary = bonds.record_for(id)
		var xp: Dictionary = context.impressions.xp_for(id)
		var pony: Node3D = _actor(id)
		var who: Resource = pony.get("identity") if pony != null else null
		return LADDER.compute({"standing": bonds.standing(id), "met": bool(bonds.knowledge(id).get("met", false)), "stage": str(row.get("stage", "acquaintance")),
			"familiarity": float(row.get("familiarity", 0.0)), "trust": float(row.get("trust", 0.0)),
			"friend_xp": int(xp.get("friendship", 0)), "love_xp": int(xp.get("romance", 0)),
			"romance": bonds.adults.has(id) and bonds.eligible_for_romance(id), "stallion": who != null and bool(who.get("stallion"))})
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
		# Anon may ask whenever she could say yes (player_bonds.agreeable); her answer is hers.
		"can_ask": bonds.agreeable(id, "dating") and not bonds.offer_on_cooldown(id, "dating") if RULES.FACTS else bonds.eligible(id, "dating")})

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
	var home := _home_for_offer(id)
	if home.is_empty(): kinds.erase("move_in")
	# What her [agreed: KIND] may accept (pony_action_schema.gd): her yes is not held to her offer list.
	var agreeable: Array = bonds.agreeable_kinds(id) if bonds.has_method("agreeable_kinds") else kinds.duplicate()
	if home.is_empty(): agreeable.erase("move_in")
	return {"offers":kinds, "pending":bonds.pending(id), "agreeable":agreeable}

func prompt_for(id: String) -> String:
	if BOND.DYNAMIC:
		# Her YOU AND ANON block (player_bonds.gd prompt_for marks what it sent), and the young
		# player's line. No kiss line: the kiss is hers to choose and the block says where they stand.
		return str(bonds.prompt_for(id)) + ("\n" + YOUNG_HELP.strip_edges() if _young_player() else "")
	# The relationship tag rules (formerly ACTION_HELP, 1.5 KB on every request and every group
	# participant) ride once in the dialogue prompt's fixed head (director_prompts.gd RELATIONSHIP_RULES).
	var result: String = bonds.prompt_for(id) + ("\n" + YOUNG_HELP.strip_edges() if _young_player() else "")
	return result + ("\n" + (KISS_YOUR_CHOICE if RULES.FACTS else KISS_NOT_READY) if _kiss_not_ready(id) else "")

## Stable read API for mods (player_bonds.gd bond_state, version 1), reachable from a pony through
## her "relationship_runtime" meta as before.
func bond_state(id: String) -> Dictionary:
	return bonds.bond_state(id)

## For adult mods: report intimacy with her (player_bonds.gd note_intimacy). Returns bond_state.
func note_intimacy(id: String, kind := "intimacy") -> Dictionary:
	return bonds.note_intimacy(id, kind)

## A kiss began (pony_affection.gd begin): her own, or his that she returned. It counts.
func note_kiss(id: String, by_her: bool) -> void:
	if BOND.DYNAMIC: _with_him[id] = true
	bonds.kissed(id, by_her)

## He tried to kiss her and she turned away: she knows it next turn.
func note_refused_kiss(id: String) -> void:
	if BOND.DYNAMIC:
		# player_bonds.gd contact() already wrote it into her next prompt (last_touch); the press
		# count it started ends when he steps back out of reach (_between).
		_touch_watch[id] = true; _with_him[id] = true
		return
	bonds.moment(id, "he tried to kiss you and you turned your face away")

## She bucked him (pony_affection.gd buck): a memory, and her next turn knows it just happened
## (thread 2026-11-15: "she bucked me, but she didn't even address it, just continued flirting").
func note_buck(id: String) -> void:
	if BOND.DYNAMIC:
		var world: Variant = game.get("world_context") if is_instance_valid(game) else null
		if is_instance_valid(world): (world as Node).call("record", "affection", "You bucked Anon away with your hind legs.", [id, "player"], [id, "player"])
		bonds.fact(id, "bucked")
		return
	var context: Variant = game.get("world_context") if is_instance_valid(game) else null
	if is_instance_valid(context): (context as Node).call("record", "affection", "You bucked Anon away with your hind legs.", [id, "player"], [id, "player"])
	bonds.moment(id, "you bucked him away with your hind legs")

func _home_for_offer(id: String) -> String:
	if not is_instance_valid(game.population): return ""
	# Moving in means sharing her existing home; it does not evict other households.
	var house: Node3D = game.population.home_house(id)
	if house != null: return house.place_id()
	# Cloud homes use their stable authored building name.
	return "cloudominium_01" if id=="rainbow_dash" else ""

func stage(id: String, action: Dictionary, turn: int, executor: Node = null) -> void:
	if BOND.DYNAMIC:
		# Every staged action of her line waits for its end; the three old step actions become
		# steps there (_bond_action). Nothing is bound to his words here: she cannot answer for
		# him, and player_bonds.gd step() hears whether he spoke (facts.he_spoke).
		var staged: Dictionary = {"turn": turn, "action": action.duplicate(true), "executor": weakref(executor) if executor != null else null}
		if action.get("type") == "kiss_player" and _after_kiss_intents.has(id):
			staged.after_kiss_serial = int(_after_kiss_intents[id])
			staged.eager = true
		var list: Array = _bond_staged.get(id, [])
		list.append(staged)
		_bond_staged[id] = list
		return
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

## Her line to Anon finished (conversation_director.gd _on_speech_finished, once per speaker): her
## staged tags commit first, then her words fill what a forgotten tag left open (_read_reply).
func finish_spoken(id: String, turn: int) -> void:
	if BOND.DYNAMIC:
		_bond_finish(id, turn, false)
		return
	_finish_staged(id, turn)
	if RULES.FACTS: _read_reply(id, turn)

func _finish_staged(id: String, turn: int) -> void:
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
		committed=_join_rest(id) or _join_group_hug(id)
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

## Her finished line, read for what it plainly says, so a model that forgets a tag never stalls
## the relationship (THREAD_FIX_RELATIONSHIP 2026-11-19: "Ask each other out" stuck after both said
## yes; she asked for a kiss and then turned it away). Tags she sent were committed just before and
## win; each reading only fills a gap, and only while her reply is not cold (no negative feeling
## tag, not annoyed, angry or sad):
##  1. Anon's own ask in this turn is pending and she plainly says yes: accepted.
##  2. She asks him out in words with no offer open: her dating offer, for his yes.
##  3. The generated invitation she was asked to voice, voiced without its tag: that offer.
##  4. She invites a kiss in words: his kisses are welcome for a few minutes.
##  5. He was romantic this turn and she took it warmly without a romance tag: one love point.
##  6. Her face showed romance ([face:affectionate], heart eyes): a warm moment, his kiss is welcome.
##  1b. He asked her out in words the strict parser missed and she plainly says yes: they are a couple.
func _read_reply(id: String, turn: int) -> void:
	var spoken: Dictionary = _reply_text.get(id, {})
	_reply_text.erase(id)
	if spoken.is_empty() or int(spoken.get("turn", -1)) != turn: return
	var text := str(spoken.get("text", ""))
	var director: Node = game.get("director") if is_instance_valid(game) else null
	var feeling: Dictionary = director.get("_pending_impression") if is_instance_valid(director) and director.get("_pending_impression") is Dictionary else {}
	var cold: bool = int(feeling.get("friendship", 0)) < 0 or int(feeling.get("romance", 0)) < 0 or str(feeling.get("mood", "")) in ["annoyed", "angry", "sad"]
	if cold: return
	var face: String = str(director.get("_pending_face")) if is_instance_valid(director) and director.get("_pending_face") != null else ""
	if face in RULES.WARM_FACES and bonds.eligible_for_romance(id):
		bonds.note_warm(id)
		print("[bonds] %s: her face showed romance (%s)" % [id, face])
	var said: String = str(director.get("_player_text")) if is_instance_valid(director) and director.get("_player_text") != null else ""
	var source: Dictionary = _player_utterances.get(id, {})
	var his_turn: bool = int(source.get("event", -2)) == turn
	var offer: Dictionary = bonds.pending(id)
	if not offer.is_empty() and offer.by == "player" and his_turn and str(source.get("offer_id", "")) == str(offer.id) and RULES.says_yes(text):
		if bonds.answer(id, str(offer.id), "pony", true): print("[bonds] %s accepted %s in her own words (no tag)" % [id, str(offer.kind)])
	elif offer.is_empty() and his_turn and str(bonds.record_for(id).stage) in ["acquaintance", "friend", "close_friend"] and RULES.he_asks_out(said) and RULES.says_yes(text):
		if bonds.agree(id, "dating"): print("[bonds] %s said yes to being asked out in his own words (no tag)" % id)
	elif offer.is_empty() and not _young_player() and RULES.asks_out(text) and bonds.agreeable(id, "dating"):
		if not bonds.offer(id, "dating", "pony").is_empty(): print("[bonds] %s asked Anon out in her own words (no tag)" % id)
	elif offer.is_empty() and not (_generated_offer.get(id, {}) as Dictionary).is_empty():
		var asked: Dictionary = _generated_offer[id]
		if bonds.now() < float(asked.get("until", 0.0)) and RULES.invites(text):
			if not bonds.offer(id, str(asked.kind), "pony", str(asked.activity)).is_empty(): print("[bonds] %s voiced her %s offer without its tag" % [id, str(asked.kind)])
	_generated_offer.erase(id)
	if RULES.invites_kiss(text) and bonds.invite_kiss(id): print("[bonds] %s invited a kiss in her own words" % id)
	if his_turn and not feeling.has("romance") and RULES.romantic(said) and bonds.love_fact(id, "romantic_talk"):
		print("[bonds] %s: romantic talk she welcomed counts (no romance tag)" % id)

## Only kiss_player permits a silent intention; other relationship actions require speech.
func finish_silent(id: String, turn: int) -> void:
	if BOND.DYNAMIC:
		# A silent reply records nothing but her own [kiss_player], as today.
		_bond_finish(id, turn, true)
		return
	var row: Dictionary = _staged.get(id, {})
	if int(row.get("turn", -1)) == turn and row.get("action", {}).get("type") == "kiss_player": finish_spoken(id, turn)

func cancel_pending() -> void:
	if BOND.DYNAMIC:
		for list: Array in _bond_staged.values():
			for staged: Dictionary in list: _report_row(staged, "cancelled", "Speech did not finish")
		_bond_staged.clear()
		_after_kiss_intents.clear()
		# A touch she never got to answer does not stay counted: the next press is a first one.
		for id: String in _contact_open.keys(): bonds.touch_dropped(id)
		_contact_open.clear()
		return
	for row: Dictionary in _staged.values():
		var executor:Node=row.executor.get_ref() if row.get("executor")!=null else null
		if is_instance_valid(executor):executor._report(row.action,"cancelled","Speech did not finish")
	_staged.clear()
	_after_kiss_intents.clear()

## A contact turn has started for her with this turn id (director_contacts.gd); kinds are the touch
## kinds of the batch. Relationship overhaul 2026-11-21: her reply to it answers him.
func contact_turn(id: String, turn: int, _kinds: Array) -> void:
	if not BOND.DYNAMIC: return
	_contact_turns[id] = turn
	_contact_open[id] = turn
	_lines_since_him[id] = 0
	_with_him[id] = true

## His touch was dropped without a turn (director_contacts.gd): the press count ends.
func contact_dropped(id: String) -> void:
	if not BOND.DYNAMIC: return
	_contact_open.erase(id)
	bonds.touch_dropped(id)

## Parse one concrete player utterance against its current offer; never use later ambient text.
func player_text(id: String, raw: String, short_answer_allowed: bool = true, utterance_id: int = -1) -> void:
	if BOND.DYNAMIC:
		# Only noted: that he spoke to her and on which turn. Nothing reads his words.
		_utterance_serial += 1
		_player_utterances[id] = {"serial": _utterance_serial, "event": utterance_id, "raw": raw, "offer_id": ""}
		_lines_since_him[id] = 0
		_with_him[id] = true
		return
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
	# Her line to Anon, sentence by sentence, for _read_reply when it finishes.
	if RULES.FACTS and listener == "player" and actors.has(speaker) and is_instance_valid(game) and is_instance_valid(game.get("director")):
		var turn := int(game.director.get("_turn_id"))
		var spoken: Dictionary = _reply_text.get(speaker, {})
		_reply_text[speaker] = {"turn": turn, "text": (str(spoken.text) + " " if int(spoken.get("turn", -1)) == turn else "") + str(event.text)}
	if listener=="player" and actors.has(speaker) and is_instance_valid(game.director) and game.director._authored_active.is_empty() and not game.director._player_text.is_empty(): bonds.experience(speaker,"conversation",event.id)

func shared_activity(kind: String, at: Vector3, event_id: String, participants: Array = []) -> void:
	if BOND.DYNAMIC:
		# The same door as before (player_bonds.gd experience enters it in the diary and moves
		# nothing); a pony he did something with is "with him" until they part.
		var feast: Node = get_tree().get_first_node_in_group("picnic_runtime")
		if kind == "meal" and feast != null and feast.contains_player(at): return
		var eye: Camera3D = game._find_camera(game.player)
		if eye == null or eye.global_position.distance_to(at) > 12.0: return
		for pony: String in actors:
			var body: Node3D = _actor(pony)
			if body == null or body.global_position.distance_to(at) > 8.0: continue
			if not participants.is_empty() and pony not in participants: continue
			if body.get("sleeping") == true: continue
			if not game.director or not game.director.awareness.can_hear(body, eye, 12.0): continue
			_with_him[pony] = true
			bonds.experience(pony, kind, event_id)
		return
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
	if BOND.DYNAMIC:
		# Her body's ready answer (player_bonds.gd contact: stance "yes"); a touch she turned
		# away is watched until he steps back out of reach (_between).
		_with_him[id] = true
		var welcomed: bool = bonds.contact(id, kind)
		if not welcomed: _touch_watch[id] = true
		return welcomed
	return bonds.contact(id,kind)

func _contact(kind: String, id: String) -> void:
	if BOND.DYNAMIC:
		_bond_contact(kind, id)
		return
	# A welcomed hug or held hoof is closeness that counts toward love (romance_rules.gd LOVE.affection).
	if RULES.FACTS and kind in ["hug", "hoofhold"] and bonds.welcomes(id, "hug"): bonds.love_fact(id, "affection")
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
	if BOND.DYNAMIC:
		_bond_tick(delta)
		return
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
				if _request_generated(id, {"kind": "relationship_offer", "offer_kind": "dating", "activity": "walk"}, func() -> bool: return _offer_valid(id, "dating")):
					_generated_offer[id] = {"kind": "dating", "activity": "walk", "until": bonds.now() + 90.0}
			elif row.familiarity >= 20 and randf() < .12:
				_offer_after = 180.0
				var activity := roll_outing(str(_last_outing.get(id, "")))
				_last_outing[id] = activity
				var kind: String = "date" if not young and bonds.eligible(id, "date") and randf() < .4 else "outing"
				if _request_generated(id, {"kind": "relationship_offer", "offer_kind": kind, "activity": activity}, func() -> bool: return _offer_valid(id, kind)):
					_generated_offer[id] = {"kind": kind, "activity": activity, "until": bonds.now() + 90.0}

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
	if BOND.DYNAMIC:
		# Her own [kiss_player] is never overruled (design section 6); only age stands in code.
		return actor != null and actor.identity != null and not actor.identity.filly and not actor.sleeping and not _young_player()
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

## cuddle() while Anon stands hugging a pony: she walks in and joins that hug (group_hug.gd join).
func _join_group_hug(id: String) -> bool:
	var actor: Node3D = _actor(id)
	var kisser: Variant = game.get("kisser") if is_instance_valid(game) else null
	return actor != null and kisser is Node and (kisser as Node).has_method("join_group_hug") and bool((kisser as Node).call("join_group_hug", actor))

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
	var seen: Variant=bonds.peek(id).get("plan")
	var plan: Dictionary=(seen as Dictionary).duplicate(true) if seen is Dictionary else {}
	var nav:=actor.get_node_or_null("Navigator")
	if nav==null or camera==null: return
	var lease: Dictionary=_leases.get(id,{})
	if plan.is_empty():
		if not lease.is_empty() and not str(lease.token).is_empty() and nav.command_owner==lease.token:
			nav.stay();nav.command_owner="";nav.wander_enabled=lease.wander
		_leases.erase(id);return
	var free := _free(actor)
	if not RULES.FACTS and not free:
		if not actor.has_meta("fishing_companion") and not lease.is_empty() and nav.command_owner!=lease.token: _leases.erase(id)
		return
	# Counting is apart from steering (THREAD_FIX_RELATIONSHIP 2026-11-19): when she agrees she
	# usually walks there with her own [go_to] or [follow] (the prompt tells her to), and after it
	# "rest_after_command" or her day plan holds her navigator. The game then does not steer her, but
	# what they do together still counts; before, it counted nothing and every such date was missed.
	if not free:
		if not lease.is_empty() and not str(lease.token).is_empty() and nav.command_owner != lease.token: lease.token = ""
		if lease.is_empty():
			lease = {"token":"", "wander":nav.wander_enabled, "seconds":0.0, "distance":0.0, "last":camera.global_position}
			_leases[id] = lease
	elif lease.is_empty() or str(lease.token).is_empty():
		if lease.is_empty():
			lease = {"token":"", "wander":nav.wander_enabled, "seconds":0.0, "distance":0.0, "last":camera.global_position}
			_leases[id] = lease
		lease.token = "bond:"+str(plan.id); lease.wander = nav.wander_enabled; nav.command_owner = lease.token
		if plan.activity == "place":
			var destination: Vector3 = nav.command_location(str(plan.get("place", "")))
			if destination.is_finite(): nav.go_to(destination)
		else: nav.follow(camera)
	var steering: bool = not str(lease.token).is_empty() and nav.command_owner == lease.token
	if RULES.FACTS and _together_step(id, actor, camera, plan, lease): return
	if plan.activity == "place":
		# The shared plan has a destination, not a moving player target. Wait there
		# after arrival, then count actual time together; never restart following.
		var spot: Vector3 = nav.command_location(str(plan.get("place", "")))
		if spot.is_finite() and actor.global_position.distance_to(spot)<20.0 and camera.global_position.distance_to(spot)<20.0:
			lease.at_place=float(lease.get("at_place",0.0))+1.0
			if float(lease.at_place)>=90.0: bonds.experience(id,"place",plan.id)
		return
	# He walking off ends a walk the game is leading; on her own trip the plan's deadline decides.
	var lost: bool = (steering or not RULES.FACTS) and (actor.global_position.distance_to(camera.global_position) > 30.0 or not nav.command_target_floor(camera.global_position).is_finite())
	lease.lost_seconds = float(lease.get("lost_seconds", 0.0)) + 1.0 if lost else 0.0
	if float(lease.lost_seconds) >= 8.0:
		bonds.cancel_plan(id)
		if nav.command_owner == lease.token:
			nav.stay(); nav.command_owner = ""; nav.wander_enabled = lease.wander
		_leases.erase(id); return
	if steering and not is_instance_valid(nav.get("_follow_target")): nav.follow(camera)
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

## Any agreed plan is also kept by RULES.PLAN_TOGETHER_S of time near each other, whatever activity
## was planned (thread 2026-11-19: "not a single one shows a status other than missed"); while they
## are together an open plan never runs out. True when the plan was kept now.
func _together_step(id: String, actor: Node3D, camera: Camera3D, plan: Dictionary, lease: Dictionary) -> bool:
	if actor.get("sleeping") == true or actor.global_position.distance_to(camera.global_position) >= RULES.PLAN_NEAR_M: return false
	if BOND.DYNAMIC:
		# No deadline to push back: a plan ends kept, called off, or missed when he sleeps on it.
		lease.together = float(lease.get("together", 0.0)) + 1.0
		return float(lease.together) >= RULES.PLAN_TOGETHER_S and bonds.experience(id, str(plan.activity), str(plan.id))
	lease.together = float(lease.get("together", 0.0)) + 1.0
	if float(plan.get("deadline", 0.0)) - bonds.now() < 120.0: bonds.extend_plan(id, 300.0)
	return float(lease.together) >= RULES.PLAN_TOGETHER_S and bonds.experience(id, str(plan.activity), str(plan.id))

func _apply_household(id: String) -> void:
	var home_id := str(bonds.peek(id).get("shared_home_id", ""))
	if not is_instance_valid(game.population):return
	var previous:Dictionary=_house_signature.get(id,{})
	var old_house:Node3D=previous.house.get_ref() if previous.get("house")!=null else null
	if is_instance_valid(old_house) and previous.id!=home_id:
		# Only the partner who holds the house clears it; a second partner leaving changes nothing.
		if str(old_house.get_meta("player_partner",""))==id:
			old_house.remove_meta("shared_player_home")
			old_house.remove_meta("player_partner")
			old_house.set_sleepers(game.population.residents_of(previous.id))
			var old_bed:=old_house.get_node_or_null("PlayerRest")
			if old_bed!=null:
				# Out of the tree at once: its name is free for the next shared bed, and it lets its bed go.
				old_house.remove_child(old_bed);old_bed.queue_free()
		_house_signature.erase(id)
	if home_id.is_empty():return
	for house:Node3D in get_tree().get_nodes_in_group("house_interiors"):
		if house.place_id()!=home_id:continue
		var holder:=str(house.get_meta("player_partner",""))
		if previous.get("instance",0)==house.get_instance_id() and holder==id:return
		# Two partners can share one house (Vinyl and Octavia, or a Mirror Pool copy of the mare he
		# lives with). The first keeps the shared bed for as long as she lives here: each used to
		# take the house back from the other every second, adding one more shared bed node each
		# time (the Mirror Pool author's report, 2026-11-12).
		if holder!="" and holder!=id and actors.has(holder) and is_instance_valid(actors[holder]) and str(bonds.peek(holder).get("shared_home_id", ""))==home_id:
			_house_signature[id]={"id":home_id,"house":weakref(house),"instance":house.get_instance_id()}
			return
		var residents:Array=game.population.residents_of(home_id)
		if "player" not in residents:residents.append("player")
		house.set_meta("shared_player_home",true)
		house.set_meta("player_partner",id)
		house.set_sleepers(residents)
		# A shared bed left by an earlier holder (she moved out or is gone) goes first: two under one
		# house left the old one running, and the new one, renamed by the engine, was never found
		# again by its name (audit 2026-11-20).
		var stale:=house.get_node_or_null("PlayerRest")
		if stale!=null:
			house.remove_child(stale);stale.queue_free()
		var rest:=preload("res://world/relationships/shared_bed.gd").new()
		rest.name="PlayerRest";rest.house=house;rest.partner_id=id;rest.runtime=self
		house.add_child(rest)
		_house_signature[id]={"id":home_id,"house":weakref(house),"instance":house.get_instance_id()}
		return

# --- Relationship overhaul 2026-11-21: one finished line, call by call (contract section 4) ------

func _director() -> Node:
	var director: Variant = game.get("director") if is_instance_valid(game) else null
	return director as Node if is_instance_valid(director) else null

func _report_row(row: Dictionary, status: String, why: String) -> void:
	var executor: Node = row.executor.get_ref() if row.get("executor") != null else null
	if is_instance_valid(executor): executor._report(row.action, status, why)

## Her line finished and he heard it (or, silent, a reply with no words). In this order:
## (a) answers_him, he_spoke and her feeling dictionary; (b) bonds.replied; (c) her own touch and
## face; (d) each [friend/heart: STEP, why] to bonds.stand; (e) each [us: KIND, ANSWER] to
## bonds.step; (f) the staged actions, the three old step actions becoming steps; (g) the reader.
## The feeling itself follows through impressions.commit, called by the director after this.
func _bond_finish(id: String, turn: int, silent: bool) -> void:
	var rows: Array = _bond_staged.get(id, [])
	_bond_staged.erase(id)
	var mine: Array = []
	for row: Dictionary in rows:
		if int(row.turn) == turn: mine.append(row)
		else: _report_row(row, "failed", "A later line replaced it")
	if silent:
		for row: Dictionary in mine:
			if str(row.action.get("type", "")) != "kiss_player":
				_report_row(row, "failed", "Relationship actions need a spoken line")
				continue
			bonds.fact(id, "her_touch", "kiss")
			_bond_action(id, row, {})
		return
	var director := _director()
	var listener: String = str(director.get("_listener_id")) if director != null and director.get("_listener_id") != null else "player"
	var feeling: Dictionary = {}
	if director != null and director.get("_pending_impression") is Dictionary: feeling = director.get("_pending_impression")
	var face: String = str(director.get("_pending_face")) if director != null and director.get("_pending_face") != null else ""
	if listener != "player":
		# A line to another pony: only her own physical actions run.
		for row: Dictionary in mine:
			var kind := str(row.action.get("type", ""))
			if kind in ["kiss_player", "cuddle"]: bonds.fact(id, "her_touch", "kiss" if kind == "kiss_player" else "cuddle")
			if kind in ["kiss_player", "cuddle", "request_space", "buck_player"]: _bond_action(id, row, {})
			else: _report_row(row, "failed", "Not said to Anon")
		return
	# (a) He spoke to her this turn, or this is her reply to a contact turn: it answers him. He
	# "spoke" also when at most two of her lines have finished since his word or touch (she cannot
	# answer for him; player_bonds.gd turns a yes with no word of his into her asking).
	var source: Dictionary = _player_utterances.get(id, {})
	var answers_him: bool = int(source.get("event", -2)) == turn or int(_contact_turns.get(id, -2)) == turn
	var since: int = int(_lines_since_him.get(id, -1))
	var he_spoke: bool = answers_him or (since >= 0 and since <= 2)
	if answers_him: _lines_since_him[id] = 1
	elif since >= 0: _lines_since_him[id] = since + 1
	_contact_open.erase(id)
	_with_him[id] = true
	var voiced := _voiced_invite(id)
	var tagged: bool = not str(feeling.get("felt", "")).is_empty() or not str(feeling.get("felt_raw", "")).is_empty()
	# (b)
	bonds.replied(id, {"turn": turn, "he_spoke": he_spoke, "answers_him": answers_him, "tagged": tagged})
	# (c) Her own touch is her newest word before any welcome is read.
	for row: Dictionary in mine:
		var kind := str(row.action.get("type", ""))
		if kind == "kiss_player": bonds.fact(id, "her_touch", "kiss")
		elif kind == "cuddle": bonds.fact(id, "her_touch", "cuddle")
	if face == WARM_FACE: bonds.fact(id, "face_warm")
	# (d)
	var stands: Variant = feeling.get("stand", [])
	if stands is Array:
		for entry: Variant in stands:
			if not entry is Dictionary: continue
			var said: Dictionary = entry
			bonds.stand(id, str(said.get("ladder", "")), str(said.get("step", "")), str(said.get("why", "")), {"source": "tag", "turn": turn})
	# (e)
	var felt := str(feeling.get("felt", ""))
	var steps: Variant = feeling.get("us", [])
	if steps is Array:
		for entry: Variant in steps:
			if not entry is Dictionary: continue
			var said: Dictionary = entry
			var kind := _bond_kind(str(said.get("kind", "")))
			if kind.is_empty(): kind = str(said.get("kind", ""))
			var terms := _plan_terms(id, turn, str(said.get("extra", "")))
			bonds.step(id, kind, str(said.get("answer", "")), {"source": "tag", "turn": turn, "he_spoke": he_spoke, "felt": felt,
				"activity": str(terms.activity), "place": str(terms.place), "home": _home_for_offer(id) if kind == "move_in" else "", "meet": _meet_set(id, turn)})
	# (f)
	var base := {"source": "tag", "turn": turn, "he_spoke": he_spoke, "felt": felt, "activity": "walk", "place": "", "home": "", "meet": _meet_set(id, turn)}
	for row: Dictionary in mine:
		var terms := _plan_terms(id, turn, "")
		var facts := base.duplicate()
		facts.activity = str(terms.activity); facts.place = str(terms.place)
		_bond_action(id, row, facts)
	# (g)
	if _reader != null and is_instance_valid(_reader):
		var spoken: Dictionary = _reply_text.get(id, {})
		var her_line: String = str(spoken.get("text", "")) if int(spoken.get("turn", -1)) == turn else ""
		_reader.call("note_reply", id, turn, str(source.get("raw", "")) if int(source.get("event", -2)) == turn else "", her_line, tagged, answers_him)
	_reply_text.erase(id)
	# The invitation is used by the line that voiced it, and by no later line.
	if not voiced.is_empty(): _bond_invite.erase(id)

## One staged action at the end of her line. kiss_player, cuddle, request_space and buck_player
## run as today; relationship_offer, relationship_answer and agreed are steps with source "tag".
func _bond_action(id: String, row: Dictionary, facts: Dictionary) -> void:
	var a: Dictionary = row.action
	var type := str(a.get("type", ""))
	var committed := false
	match type:
		"kiss_player":
			if row.has("after_kiss_serial") and (int(_after_kiss_intents.get(id, -1)) != int(row.after_kiss_serial) or not _after_kiss_valid(id, int(row.after_kiss_serial))):
				_report_row(row, "failed", "After-kiss invitation expired or consent changed")
				return
			_queue_kiss(id, row)
			return
		"cuddle":
			committed = _join_rest(id) or _join_group_hug(id)
		"request_space":
			committed = bonds.request_space(id)
			var actor: Node3D = _actor(id)
			if is_instance_valid(actor) and actor.get_node_or_null("Affection") != null: actor.get_node("Affection").end()
		"buck_player":
			var actor: Node3D = _actor(id)
			var affection: Node = actor.get_node_or_null("Affection") if is_instance_valid(actor) else null
			var body: Variant = game.inventory.player_body if is_instance_valid(game) and is_instance_valid(game.get("inventory")) else null
			committed = affection != null and affection.buck(body)
		"agreed":
			committed = _bond_step(id, _bond_kind(str(a.get("kind", ""))), "yes", facts)
		"relationship_offer":
			var kind := _bond_kind(str(a.get("kind", "")))
			var terms := facts.duplicate()
			var activity := str(a.get("activity", ""))
			if activity in PLAN_ACTIVITIES: terms.activity = activity
			if not str(a.get("location_id", "")).is_empty(): terms.place = str(a.location_id)
			if kind == "move_in": terms.home = _home_for_offer(id)
			committed = _bond_step(id, kind, "ask", terms)
		"relationship_answer":
			var kind := _bond_kind(str(a.get("kind", "")))
			if kind.is_empty(): kind = str((bonds.standing(id).get("open_ask", {}) as Dictionary).get("kind", ""))
			if kind.is_empty(): kind = _bond_kind(str(bonds.pending(id).get("kind", "")))
			var terms := facts.duplicate()
			if kind == "move_in": terms.home = _home_for_offer(id)
			committed = _bond_step(id, kind, "yes" if a.get("accept") == true else "no", terms)
	_report_row(row, "completed" if committed else "failed", "Spoken step recorded" if committed else "Not possible now")

func _bond_step(id: String, kind: String, answer: String, facts: Dictionary) -> bool:
	if kind.is_empty(): return false
	var result: Variant = bonds.step(id, kind, answer, facts)
	return result is Dictionary and bool((result as Dictionary).get("ok", false))

## A step KIND from its new or old spelling ("dating" -> "couple", "engagement" -> "engaged").
static func _bond_kind(raw: String) -> String:
	var kind := BOND.kind(raw)
	return kind if not kind.is_empty() else str(BOND.OLD_KIND.get(BOND.key(raw), ""))

## The plan's activity and place: from the invitation the game asked her to voice, the tag's third
## argument, or the movement she chose in the same reply ([go_to]/[lead] to a place, [follow]); else
## a walk. Any plan is kept by time together, so a wrong guess costs nothing.
func _plan_terms(id: String, turn: int, extra: String) -> Dictionary:
	var invite := _voiced_invite(id)
	if str(invite.get("activity", "")) in PLAN_ACTIVITIES: return {"activity": str(invite.activity), "place": ""}
	if BOND.key(extra) in PLAN_ACTIVITIES: return {"activity": BOND.key(extra), "place": ""}
	var move := _reply_move(id, turn)
	var kind := str(move.get("type", ""))
	if kind in ["go_to", "lead"] and not str(move.get("location_id", "")).is_empty(): return {"activity": "place", "place": str(move.location_id)}
	return {"activity": "walk", "place": ""}

## The invitation she is voicing on this line: the director is delivering a generated purpose line.
func _voiced_invite(id: String) -> Dictionary:
	var invite: Dictionary = _bond_invite.get(id, {})
	var director := _director()
	if invite.is_empty() or director == null: return {}
	var active: String = str(director.get("_authored_active")) if director.get("_authored_active") != null else ""
	return invite if not active.is_empty() else {}

## The movement she chose in this reply: action ids are "t<turn>-<index>-<type>" (pony_action_schema.gd).
func _reply_move(id: String, turn: int) -> Dictionary:
	var director := _director()
	var coordinator: Variant = director.get("actions") if director != null else null
	if not is_instance_valid(coordinator) or not (coordinator as Object).get("executors") is Dictionary: return {}
	var executor: Variant = ((coordinator as Object).get("executors") as Dictionary).get(id)
	if not is_instance_valid(executor): return {}
	var move: Variant = (executor as Object).get("movement")
	if not move is Dictionary or not str((move as Dictionary).get("id", "")).begins_with("t%d-" % turn): return {}
	return move

## Her reply set an appointment ([meet: PLACE, DAY, TIME]): the appointment is the plan.
func _meet_set(id: String, turn: int) -> bool:
	var book: Node = get_node_or_null("Appointments")
	if book == null and is_inside_tree(): book = get_tree().get_first_node_in_group("appointments")
	if book == null or not book.has_method("open_for"): return false
	var row: Variant = book.call("open_for", id)
	return row is Dictionary and str((row as Dictionary).get("source", "")) == "speech:%d" % turn

## A touch the boop node reports: a welcomed hug or held hoof is the fact "hug"; a flank smack asks
## her ready answer (player_bonds.gd contact, never the bare stage), and the buck asks refused_again.
func _bond_contact(kind: String, id: String) -> void:
	_with_him[id] = true
	if kind in ["hug", "hoofhold"]:
		if bonds.stance(id, "hug") == "yes": bonds.fact(id, "hug")
		return
	if kind != "flank_smack": return
	var actor: Node3D = _actor(id)
	if bonds.contact(id, "flank_touch"):
		if is_instance_valid(actor): actor.expressions.kiss(); actor.set_dialogue_expression("amused")
		var partner: bool = bool(bonds.bond_state(id).get("couple", false))
		game.world_context.record("affection", "You welcomed Anon's playful contact." if partner else "You welcomed Anon's playful contact. This does not mean you welcome unlimited repetition.", [id, "player"], [id, "player"])
		return
	_touch_watch[id] = true
	if is_instance_valid(actor) and actor.get_node_or_null("Affection") != null and bonds.refused_again(id, "flank_touch"):
		actor.get_node("Affection").buck(game.inventory.player_body)

# --- Between turns: three events, each sent once when a distance or the sleep system says so -----

func _bond_tick(delta: float) -> void:
	_sleep_edge()
	_timer -= delta; _offer_after -= delta
	if _timer > 0.0: return
	_timer = 1.0
	_bond_pass()

## He has gone to sleep (game.player_sleeping turned true: a night in bed, a nap, passing out).
## Read from the sleep system, never from the clock. A pony beside him has not been stood up.
func _sleep_edge() -> void:
	var asleep := bool(game.get("player_sleeping")) if is_instance_valid(game) else false
	if asleep and not _he_slept:
		var camera: Camera3D = game._find_camera(game.player) if is_instance_valid(game.player) else null
		for id: String in actors.keys():
			var actor := _actor(id)
			if actor == null or not actor.is_inside_tree(): continue
			var beside: bool = camera != null and actor.global_position.distance_to(camera.global_position) <= BOND.BESIDE_M
			if beside: bonds.fact(id, "parted")
			else: bonds.fact(id, "parted", "he_slept")
		_with_him.clear()
		_touch_watch.clear()
	_he_slept = asleep

## The once-a-second pass over the ponies (time together, plans, households, her initiative).
func _bond_pass() -> void:
	var camera: Camera3D = game._find_camera(game.player)
	var young := _young_player()
	for id: String in actors.keys():
		# A freed pony cannot be assigned to a typed variable; test the raw entry first.
		if not is_instance_valid(actors[id]): actors.erase(id); _leases.erase(id); continue
		var actor: Node3D = actors[id]
		_apply_household(id)
		# A spa visit is not time together (SPA_PLAN_2026_10_29.md section 3).
		if camera != null and actor.global_position.distance_to(camera.global_position) < 5.0 and not bool(actor.get("sleeping")) and not actor.has_meta("spa_client"): bonds.add_together(id, 1.0)
		_plan_step(id, actor, camera)
		_between(id, actor, camera)
		if _offer_after <= 0.0 and camera != null and actor.global_position.distance_to(camera.global_position) < 4.0 and _free(actor):
			_bond_initiative(id, young)
	if _offer_after <= 0.0: _offer_after = 30.0

## He stepped back out of reach of a touch she turned away and has not answered: the press count
## ends. He went beyond parting distance of a pony he was with, or she fell asleep: they parted.
func _between(id: String, actor: Node3D, camera: Camera3D) -> void:
	if camera == null or not actor.is_inside_tree(): return
	var away := actor.global_position.distance_to(camera.global_position)
	if _touch_watch.has(id) and away > BOND.REACH_M:
		_touch_watch.erase(id)
		if not (bonds.standing(id).get("last_touch", {}) as Dictionary).is_empty(): bonds.touch_dropped(id)
	if _with_him.has(id) and (away > BOND.PART_M or actor.get("sleeping") == true):
		_with_him.erase(id)
		bonds.fact(id, "parted")

## Her initiative (design 5.3): a turn to ask him to be a couple when she has said so herself
## (standing.wants_to_ask), and today's occasional outing roll between friends, under today's
## budget for lines the game asks for (_offer_after, the rolls). Nothing while a sore point is
## open, while she is wary, or with a question or a plan already open.
func _bond_initiative(id: String, young: bool) -> void:
	var standing: Dictionary = bonds.standing(id)
	if not _may_start(standing): return
	if not young and bool(standing.get("romance", false)) and str(standing.get("wants_to_ask", "")) == "couple" and randf() < .25:
		_offer_after = 180.0
		_ask_her(id, {"kind": "bond_ask", "step": "couple", "activity": ""})
	elif BOND.closeness_rank(str(standing.get("closeness", ""))) >= BOND.closeness_rank("friend") and randf() < .12:
		_offer_after = 180.0
		var activity := roll_outing(str(_last_outing.get(id, "")))
		_last_outing[id] = activity
		var step: String = "date" if not young and bool(standing.get("romance", false)) and bonds.eligible(id, "date") and randf() < .4 else "outing"
		_ask_her(id, {"kind": "bond_ask", "step": step, "activity": activity})

func _ask_her(id: String, intent: Dictionary) -> void:
	var step := str(intent.step)
	var finished := func() -> void:
		if _bond_invite.get(id, {}) == intent: _bond_invite.erase(id)
	if _request_generated(id, intent, func() -> bool: return _bond_ask_valid(id, step), finished): _bond_invite[id] = intent

static func _may_start(standing: Dictionary) -> bool:
	if standing.is_empty() or bool(standing.get("wary", false)): return false
	var sore: Variant = standing.get("sore", [])
	if sore is Array and not (sore as Array).is_empty(): return false
	var asked: Variant = standing.get("open_ask", {})
	var plan: Variant = standing.get("plan", {})
	return not (asked is Dictionary and not (asked as Dictionary).is_empty()) and not (plan is Dictionary and not (plan as Dictionary).is_empty())

func _bond_ask_valid(id: String, step: String) -> bool:
	var actor: Node3D = _actor(id)
	if actor == null or not is_instance_valid(game) or not is_instance_valid(game.player): return false
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null or actor.global_position.distance_to(camera.global_position) >= 4.0 or actor.get("sleeping") == true or actor.get("_held") == true: return false
	var standing: Dictionary = bonds.standing(id)
	return _may_start(standing) and (step != "couple" or str(standing.get("wants_to_ask", "")) == "couple")

func _exit_tree() -> void:
	for id: String in _kiss_requests.keys(): _finish_kiss_request(id, false, "Relationship runtime closed")
