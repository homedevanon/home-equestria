extends RefCounted
const CONTROLS := preload("res://world/ai/speech_controls.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const MEET_TIME := preload("res://world/life/appointments/meet_time.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const ASK_RULES := preload("res://world/mechanics/asks/ask_rules.gd")
## Data only. Never turn model text into method names, code, paths or coordinates.
const AGREED_KINDS := ["dating", "date", "outing", "move_in", "engagement", "marriage"]
const TYPES := ["look_at", "approach", "call_pony", "send_pony", "follow", "go_to", "step", "lead", "stay", "cancel", "resume_routine", "sit", "stand", "lie_down", "fly_to", "hover", "land", "loop_de_loop", "barrel_roll", "circle_over", "sonic_rainboom", "sit_on_seat", "go_home", "go_to_bed", "air_show", "relationship_offer", "relationship_answer", "agreed", "request_space", "buck_player", "cuddle", "kiss_player", "wake_up", "teleport_to_ponyville", "send_letter", "give_house", "magic_show", "take_off", "put_on", "meet", "meet_cancel", "pay_player", "give", "offer_job", "use", "ask", "invite", "sell", "buy"]
## Actions that need spoken words in the same reply (docs/MECHANICS_ARCHITECTURE_2026_11_01.md 4.6).
const SPEECH_REQUIRED := ["relationship_offer", "relationship_answer", "agreed", "request_space", "buck_player", "cuddle",
	"teleport_to_ponyville", "give_house", "meet", "meet_cancel", "pay_player", "give", "ask", "offer_job", "invite", "sell", "buy"]
## One intention per channel per reply; everything not listed is "movement".
const CHANNELS := {"look_at": "gaze", "give_house": "grant", "magic_show": "grant", "pay_player": "money",
	"take_off": "wardrobe", "put_on": "wardrobe", "meet": "plan", "meet_cancel": "plan",
	"give": "trade", "sell": "trade", "buy": "trade", "ask": "plan", "offer_job": "plan", "invite": "plan"}
const SPEECH_LIMIT := 2880
const STEP_DIRECTIONS := ["forward", "back", "left", "right", "away", "aside"]
const STEP_SPELLINGS := {"forwards": "forward", "ahead": "forward", "backward": "back", "backwards": "back", "backward_s": "back",
	"back_up": "back", "behind": "back", "sideways": "aside", "out_of_the_way": "aside", "out_of_way": "aside", "to_the_side": "aside",
	"side": "aside", "away_from_player": "away", "away_from_you": "away"}
const FIELDS := {
	"teleport_to_ponyville": [], "give_house": [], "magic_show": [], "take_off": ["kind"], "put_on": ["kind"],
	"meet": ["location_id", "day", "time"], "meet_cancel": [], "pay_player": ["amount"], "give": ["item"], "use": ["station_id"], "offer_job": ["job_id"], "ask": ["want", "reward"], "invite": ["event_id"], "sell": ["item", "price"], "buy": ["item", "price"],
	"call_pony": ["pony_id"], "send_pony": ["pony_id", "target_id"],
	"request_space": [], "buck_player": [], "cuddle": [], "kiss_player": [], "wake_up": [], "send_letter": [], "relationship_offer": ["kind", "activity", "location_id"], "relationship_answer": ["offer_id", "accept"], "agreed": ["kind"],
	"look_at": ["target_id", "duration_s"], "approach": ["target_id", "distance_m"],
	"follow": ["target_id", "formation", "distance_m"], "go_to": ["location_id", "pace"],
	"step": ["direction", "distance_m"],
	"lead": ["target_id", "location_id", "wait_distance_m"],
	"stay": ["duration_s", "until_cancel"], "cancel": ["action_id"], "resume_routine": [], "sit": [], "stand": [], "lie_down": [], "fly_to": ["location_id"], "hover": ["duration_s"], "land": [], "loop_de_loop": [], "barrel_roll": [], "circle_over": ["target_id"], "sonic_rainboom": [], "sit_on_seat": [], "go_home": [], "go_to_bed": ["bed"], "air_show": ["moves", "target_id"]}
## Air show figures (pony_flight.gd SHOW_MOVES) and the tag spellings that name one. A reply with
## [air_show: loop, dive, ...] or with several trick tags ([loop_de_loop] [dive] [barrel_roll])
## becomes one air_show action: one takeoff, the figures in order, one landing.
const SHOW_MOVES := ["loop", "barrel_roll", "aileron_roll", "spiral_climb", "dive", "figure_eight", "immelmann", "split_s", "hammerhead", "flyby", "circle"]
const SHOW_TAGS := {"loop": "loop", "loop_de_loop": "loop", "loopdeloop": "loop", "barrel_roll": "barrel_roll", "barrelroll": "barrel_roll",
	"aileron_roll": "aileron_roll", "roll": "aileron_roll", "spiral_climb": "spiral_climb", "spiral": "spiral_climb", "corkscrew": "spiral_climb",
	"dive": "dive", "swoop": "dive", "figure_eight": "figure_eight", "figure_8": "figure_eight", "figure8": "figure_eight",
	"immelmann": "immelmann", "immelman": "immelmann", "split_s": "split_s", "splits": "split_s", "hammerhead": "hammerhead",
	"stall_turn": "hammerhead", "flyby": "flyby", "fly_by": "flyby", "fly_past": "flyby", "circle": "circle", "circle_over": "circle"}
const SHOW_LIMIT := 8

## Tag replies (dev 2026-10-02: "harden the ai action calling system into tags so even a dumb ai
## model can understand its options and output the correct structure like ponyponyparadise"):
## the reply is the spoken line; square-bracket tags in it are never spoken:
##   [face:happy] Oh, hello there! [look_at: player]
## Action tags are [type] or [type: arg, arg] with arguments in SIGNATURES order; missing ones take
## their default, numbers are clamped into range, spellings are forgiven (ALIASES), and a tag that
## still cannot be used is dropped (listed in "dropped") while the line is spoken. Feelings:
## [mood: happy] [friendship: +1] [romance: 0] [thought: ...]. [silence] says nothing.
## JSON replies (the old envelope) are still accepted.
## Per type: [field, default]; a default of null means required.
const SIGNATURES := {
	"call_pony": [["pony_id", null]], "send_pony": [["pony_id", null], ["target_id", null]],
	"look_at": [["target_id", null], ["duration_s", 3.0]], "approach": [["target_id", null], ["distance_m", 1.2]],
	"follow": [["target_id", null], ["formation", "right"], ["distance_m", 1.5]], "go_to": [["location_id", null], ["pace", "walk"]],
	"step": [["direction", "aside"], ["distance_m", 1.5]],
	"lead": [["target_id", null], ["location_id", null], ["wait_distance_m", 6.0]], "cancel": [["action_id", "current"]],
	"fly_to": [["location_id", null]], "hover": [["duration_s", 10.0]], "circle_over": [["target_id", "player"]],
	"relationship_offer": [["kind", null], ["activity", "walk"], ["location_id", ""]], "relationship_answer": [["offer_id", null], ["accept", null]], "agreed": [["kind", null]],
	"take_off": [["kind", null]], "put_on": [["kind", null]],
	"meet": [["location_id", null], ["day", "today"], ["time", null]], "pay_player": [["amount", null]], "give": [["item", null]], "use": [["station_id", null]], "offer_job": [["job_id", null]],
	"ask": [["want", null], ["reward", "thanks"]], "invite": [["event_id", null]], "sell": [["item", null], ["price", null]], "buy": [["item", null], ["price", null]],
	"go_to_bed": [["bed", "own"]]}
## [go_to_bed: here] spellings: the bed in the house where Anon is; anything else is her own bed.
const BED_HERE := ["here", "this", "this_bed", "that", "that_bed", "there", "player", "anon", "his", "his_bed", "your", "yours", "your_bed", "anons_bed", "anon's_bed"]
const PLAYER_NAMES := ["me", "you", "anon", "him", "the player", "anonymous"]
## The configured player name (AI Settings player_name, lower case), reread when the user config
## file changes; see is_player_name().
static var _own_name := ""
static var _own_name_stamp := -1
const RANGES := {"duration_s": [0.2, 600.0], "distance_m": [1.0, 6.0], "wait_distance_m": [3.0, 15.0]}
const ALIASES := {"lookat": "look_at", "look": "look_at", "goto": "go_to", "walk_to": "go_to", "go": "go_to", "flyto": "fly_to",
	"summon": "call_pony", "call": "call_pony", "send": "send_pony", "go_to_pony": "approach",
	"wait": "stay", "hold": "stay", "hold_position": "stay", "stay_here": "stay", "wait_here": "stay",
	"fly": "fly_to", "loop": "loop_de_loop", "loopdeloop": "loop_de_loop", "loop_the_loop": "loop_de_loop", "barrelroll": "barrel_roll",
	"roll": "barrel_roll", "circle": "circle_over", "circle_around": "circle_over", "fly_around": "circle_over", "rainboom": "sonic_rainboom",
	"sonicrainboom": "sonic_rainboom", "lay_down": "lie_down", "lie": "lie_down", "laydown": "lie_down", "liedown": "lie_down",
	"sitdown": "sit", "sit_down": "sit", "standup": "stand", "stand_up": "stand", "wake": "wake_up", "wakeup": "wake_up",
	"home": "go_home", "gohome": "go_home", "bed": "go_to_bed", "gotobed": "go_to_bed", "go_bed": "go_to_bed", "to_bed": "go_to_bed",
	"bedtime": "go_to_bed", "get_in_bed": "go_to_bed", "lie_in_bed": "go_to_bed", "lay_in_bed": "go_to_bed", "sleep_in_bed": "go_to_bed", "go_to_sleep": "go_to_bed", "resume": "resume_routine", "stop": "cancel", "seat": "sit_on_seat", "bench": "sit_on_seat",
	"kiss": "kiss_player", "buck": "buck_player", "hug": "cuddle", "space": "request_space",
	"letter": "send_letter", "send_a_letter": "send_letter", "write_letter": "send_letter", "letter_to_celestia": "send_letter", "send_letter_to_celestia": "send_letter", "fire_letter": "send_letter",
	"give_home": "give_house", "grant_house": "give_house", "grant_home": "give_house", "assign_house": "give_house", "house_grant": "give_house",
	"airshow": "air_show", "show": "air_show", "stunts": "air_show", "stunt_show": "air_show", "aerobatics": "air_show", "flying_show": "air_show",
	"perform_show": "magic_show", "stage_show": "magic_show", "start_show": "magic_show", "magicshow": "magic_show", "trixie_show": "magic_show",
	"put_on_show": "magic_show", "put_on_a_show": "magic_show", "great_and_powerful_show": "magic_show", "perform": "magic_show",
	"remove": "take_off", "takeoff": "take_off", "undress": "take_off", "unequip": "take_off", "remove_clothing": "take_off",
	"wear": "put_on", "puton": "put_on", "dress": "put_on", "equip": "put_on",
	"move": "step", "step_aside": "step", "move_aside": "step", "make_way": "step", "scoot": "step", "shift": "step",
	"meet_up": "meet", "meet_anon": "meet", "appointment": "meet", "make_appointment": "meet", "schedule_meeting": "meet",
	"cancel_meet": "meet_cancel", "cancel_meeting": "meet_cancel", "call_off_meeting": "meet_cancel",
	"pay": "pay_player", "pay_anon": "pay_player", "pay_him": "pay_player", "give_bits": "pay_player", "give_money": "pay_player",
	"tip": "pay_player", "tip_player": "pay_player", "give_player_bits": "pay_player", "bits": "pay_player",
	"gift": "give", "give_item": "give", "hand": "give", "hand_over": "give", "give_player": "give",
	"work": "use", "use_station": "use", "work_station": "use", "operate": "use",
	"hire": "offer_job", "job": "offer_job", "offer_work": "offer_job", "hire_player": "offer_job", "employ": "offer_job",
	"favor": "ask", "favour": "ask", "ask_favor": "ask", "ask_favour": "ask", "quest": "ask",
	"invite_player": "invite", "invite_to": "invite", "invite_event": "invite",
	"offer_price": "sell", "sell_to_player": "sell", "price": "sell", "haggle": "sell",
	"buy_from_player": "buy", "purchase": "buy", "offer_to_buy": "buy"}
## One line per command for the prompt: the exact tag and what it does.
const TAG_HELP := {
	"teleport_to_ponyville": "[teleport_to_ponyville] Twilight takes you both out of the Everfree to Ponyville for shelter at Golden Oak; only available during the active forest rescue; finish explaining first, then regroup beside the newcomer before casting if separated",
	"call_pony": "[call_pony: PONY_ID] ask a nearby pony who can hear you to come to you; no remote summons",
	"send_pony": "[send_pony: PONY_ID, TARGET] ask a nearby pony who can hear you to go to a nearby pony or player; a request is not arrival",
	"look_at": "[look_at: TARGET] look at someone for a moment (optional seconds: [look_at: player, 5])",
	"approach": "[approach: TARGET] walk up close to someone and stop there",
	"follow": "[follow: TARGET] go along with someone (optional side and metres: [follow: player, left, 2])",
	"go_to": "[go_to: LOCATION] walk to a place (optional pace: [go_to: LOCATION, trot])",
	"step": "[step: DIRECTION] take a few steps where you are: forward, back, left, right, away (from the player) or aside (out of someone's way, e.g. when you block a doorway or path); optional metres 1–6: [step: back, 2]",
	"lead": "[lead: TARGET, LOCATION] take someone to a place, waiting for them",
	"stay": "[stay: SECONDS] hold position for 0.5–600 seconds; [stay] waits 30 seconds",
	"cancel": "[cancel] stop what you are doing",
	"resume_routine": "[resume_routine] go back to your day",
	"sit": "[sit] sit down", "stand": "[stand] stand up", "lie_down": "[lie_down] lie down",
	"fly_to": "[fly_to: LOCATION] fly to a place", "hover": "[hover: SECONDS] hover in the air here",
	"land": "[land] land", "loop_de_loop": "[loop_de_loop] a quick flight with a loop-de-loop, for fun or showing off",
	"barrel_roll": "[barrel_roll] a quick flight with a barrel roll, for fun or showing off",
	"circle_over": "[circle_over: TARGET] fly a lap over someone and land beside them",
	"sonic_rainboom": "[sonic_rainboom] climb high, burst past the speed of sound with a rainbow ring, and come back",
	"air_show": "[air_show: MOVE, MOVE, ...] one flight that chains up to 8 figures for whoever watches, then lands: loop, barrel_roll, aileron_roll, spiral_climb, dive, figure_eight, immelmann, split_s, hammerhead, flyby, circle (e.g. [air_show: loop, dive, figure_eight, flyby])",
	"sit_on_seat": "[sit_on_seat] walk to the nearest free bench or seat and sit on it",
	"wake_up": "[wake_up] wake up, or get up out of a bed or off a couch",
	"go_home": "[go_home] go home to rest a while (say goodbye first)",
	"go_to_bed": "[go_to_bed] walk to your own bed, climb in and lie there (asleep at night) until you get up; [go_to_bed: here] the bed in the house where Anon is",
	"relationship_offer": "[relationship_offer: KIND, ACTIVITY] ask Anon for a relationship step (ACTIVITY walk/meal/visit/orchard/fishing, or place plus a LOCATION)",
	"relationship_answer": "[relationship_answer: OFFER_ID, yes] or no: answer Anon's invitation",
	"agreed": "[agreed: KIND] you both said yes to a step: Anon asked you for it in his own words and you accept, or he said yes to your offer (KIND dating/date/outing/move_in/engagement/marriage)",
	"request_space": "[request_space] ask Anon to give you some space", "buck_player": "[buck_player] buck Anon away (only real, lasting anger at unwelcome contact)",
	"cuddle": "[cuddle] cuddle up to Anon", "kiss_player": "[kiss_player] kiss Anon",
	"send_letter": "[send_letter] write a quick note on a scroll and send it to Princess Celestia with your green fire",
	"give_house": "[give_house] officially make a free Ponyville house Anon's own home, for good (the empty one he is in or beside, else the nearest free one); only when you give it, never just to talk about houses; works alongside one other action",
	"magic_show": "[magic_show] start your Great and Powerful stage show at the schoolhouse stage: fireworks call the town, the curtain rises in about three minutes; only when Anon paid for one or you truly want an audience; works alongside one other action",
	"take_off": "[take_off: ITEM] take off something you are wearing (e.g. socks, scarf, hat, glasses), when asked or when you want to; you keep it and can [put_on] it again; works alongside one other action",
	"put_on": "[put_on: ITEM] put back on something you took off earlier; works alongside one other action",
	"meet": "[meet: LOCATION, DAY, HH:MM] agree to meet Anon at a place on a day (today, tomorrow or a number of days ahead) and time, e.g. [meet: landmark:town_hall, tomorrow, 15:00]; you will go there a bit early and wait; replaces your earlier meeting with him",
	"meet_cancel": "[meet_cancel] call off your agreed meeting with Anon",
	"pay_player": "[pay_player: BITS] hand Anon that many bits from your own purse (pay him for work or goods, pay back a loan, tip him, treat him, gift him); only bits you hold, say it out loud; works alongside one other action",
	"offer_job": "[offer_job: JOB] offer Anon paid work for today (from your list); tell him where it is, he goes himself; works alongside one other action",
	"use": "[use: STATION] go and work a station near you (from your list), e.g. [use: cider_press]",
	"ask": "[ask: WANT, REWARD] ask Anon a favour: WANT is items and a count (2 apples), fetch PONY, go to LOCATION or help at JOB; REWARD is bits you hold (10 bits), an item you have, or thanks; one open favour at a time; works alongside one other action",
	"invite": "[invite: EVENT] invite Anon to a town event today (from your list); it goes in his notebook; works alongside one other action",
	"give": "[give: ITEM] hand Anon something you really have (from your list); it goes into his hand; say it out loud; works alongside one other action",
	"sell": "[sell: ITEM, BITS] your price for Anon on something from your stall here (from your list) for two minutes; he takes it from the stall himself; say it out loud",
	"buy": "[buy: ITEM, BITS] offer Anon bits from your purse for something he is holding (from your list); you pay when he hands it to you; say it out loud"}

## The reply channel of an action type: one intention per channel per reply.
static func channel(type: String) -> String:
	return str(CHANNELS.get(type, "movement"))

## Turns a model's tag name into a TYPES entry ("" when it is not an action).
static func action_type(raw: String) -> String:
	var name := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	if name in TYPES: return name
	return str(ALIASES.get(name, ALIASES.get(name.replace("_", ""), "")))

## A tag reply: speech without its action and feeling tags (face/gesture tags stay for
## pony_dialogue_tags.gd), validated actions, the impression and the dropped tags with reasons.
static func decode_tags(text: String, actor: String, turn: int, context: Dictionary) -> Dictionary:
	if text.length() > 8192: return {"error": "Response exceeds 8192 characters"}
	var tags := RegEx.new()
	tags.compile("\\[\\s*([A-Za-z][A-Za-z _-]{1,40}?)\\s*(?:[:=]\\s*([^\\]\\r\\n]*?))?\\s*\\]")
	var actions: Array = []
	var dropped: Array = []
	var impression := {}
	var silent := false # [silence] alone: nothing is spoken
	var speech := CONTROLS.sanitize(text, true)
	var channels: Array = []
	for span: Dictionary in CONTROLS.spans(text):
		if not span.complete: dropped.append("Malformed control tag (ignored)"); continue
		var found := tags.search(str(span.tag))
		if found == null: dropped.append("Unrecognized control tag (ignored)"); continue
		var raw := found.get_string(1)
		var name := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
		var value := found.get_string(2).strip_edges()
		var type := action_type(raw)
		# Trixie cannot fly: her plain [show] means her stage show, not an air show (dev 2026-10-28).
		if name == "show" and "magic_show" in context.get("capabilities", []): type = "magic_show"
		# Air show: a figure tag joins the reply's show (or starts one); two trick tags chain.
		var figure: String = SHOW_TAGS.get(name, "") if type in ["", "loop_de_loop", "barrel_roll", "air_show"] else ""
		if type == "air_show" or figure != "":
			var show_at := -1
			for i in actions.size():
				if actions[i].type in ["air_show", "loop_de_loop", "barrel_roll"]: show_at = i
			var moves: Array = []
			var audience := "player"
			if type == "air_show":
				for part in value.split(",", false):
					var item := part.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
					if SHOW_TAGS.has(item): moves.append(SHOW_TAGS[item])
					elif item == "player" or is_player_name(item): audience = "player"
					elif context.get("targets", {}).has(item): audience = item
				if moves.is_empty(): moves = ["loop", "barrel_roll", "dive"]
			else: moves = [figure]
			if show_at >= 0:
				var joined: Dictionary = actions[show_at]
				if joined.type != "air_show":
					joined.moves = [SHOW_TAGS[joined.type]]; joined.type = "air_show"; joined.target_id = "player"
					joined.id = "t%d-%d-air_show" % [turn, show_at]
				for move in moves: if joined.moves.size() < SHOW_LIMIT: joined.moves.append(move)
				continue
			if type in ["loop_de_loop", "barrel_roll"]: pass   # alone, the classic trick
			else:
				var show := {"id": "t%d-%d-air_show" % [turn, actions.size()], "type": "air_show", "moves": moves.slice(0, SHOW_LIMIT), "target_id": audience}
				var show_error := validate(show, context)
				if show_error == "" and "movement" in channels: show_error = "Only one movement per reply"
				if show_error != "": dropped.append("%s (%s)" % [found.get_string(0), show_error]); continue
				channels.append("movement"); actions.append(show)
				continue
		# Face, gesture and voice-emotion tags stay in the line for pony_dialogue_tags.gd and TTS.
		if type.is_empty() and name not in ["silence", "friendship", "romance", "mood", "thought"]:
			if not CONTROLS.presentation_tag(str(span.tag)): dropped.append("Unrecognized control tag (ignored)")
			continue
		if name == "silence": silent = true; continue
		if name in ["friendship", "romance"]:
			if value.trim_prefix("+").is_valid_float(): impression[name] = int(round(float(value.trim_prefix("+"))))
			continue
		if name == "mood": impression.mood = value.to_lower(); continue
		if name == "thought": impression.thought = value; continue
		if type == "teleport_to_ponyville" and not value.is_empty():
			dropped.append("teleport_to_ponyville takes no arguments"); continue
		var action := _tag_action(type, value, turn, actions.size())
		# A house grant or Trixie's stage show moves nopony now: either may come with her walk or follow.
		# An agreed meeting (appointments.gd) moves nopony now: it may come with a walk and a look.
		var lane := channel(type)
		var error := validate(action, context)
		if error == "" and lane in channels: error = "Only one %s per reply" % ("look_at" if lane == "gaze" else "movement")
		if error == "" and actions.size() >= 2: error = "At most two actions per reply"
		if error != "":
			dropped.append("%s (%s)" % [found.get_string(0), error]); continue
		channels.append(lane)
		actions.append(action)
	speech = speech.replace("  ", " ").strip_edges()
	_follow_to_lead(actions, speech, actor, turn, context)
	if speech.length() > SPEECH_LIMIT: return {"error": "Speech exceeds 2880 characters; use complete sentences within the limit"}
	for action: Dictionary in actions:
		if action.type in SPEECH_REQUIRED and CONTROLS.sanitize(speech).is_empty():
			return {"error": "This action requires spoken words before it can finish"}
	return {"speech": speech, "actions": actions, "impression": preload("res://world/ai/impressions/pony_impressions.gd").sanitize(impression),
		"dropped": dropped, "tags": true, "control_only": not silent and actions.is_empty() and CONTROLS.sanitize(speech).is_empty() and not text.strip_edges().is_empty()}

## A word naming the player in a tag: PLAYER_NAMES or his configured name, in any case, with spaces
## or underscores (M-AI-05: a renamed player was not recognised in [follow: Name]).
static func is_player_name(word: String) -> bool:
	var key := word.strip_edges().to_lower()
	if key in PLAYER_NAMES: return true
	var config_path: String = load("res://world/ai/ai_config.gd").USER_PATH
	var stamp := FileAccess.get_modified_time(config_path) if FileAccess.file_exists(config_path) else 0
	if stamp != _own_name_stamp:
		_own_name_stamp = stamp
		var config: RefCounted = load("res://world/ai/ai_config.gd").load_config()
		_own_name = str(config.get_value("player_name", "Anon")).strip_edges().to_lower().replace("_", " ")
	return not _own_name.is_empty() and key.replace("_", " ") == _own_name

static func _tag_action(type: String, value: String, turn: int, index: int) -> Dictionary:
	var action := {"id": "t%d-%d-%s" % [turn, index, type], "type": type}
	var args: Array = []
	for part in value.split(",", false):
		var item := part.strip_edges()
		if not item.is_empty(): args.append(item)
	if type == "stay":
		var seconds := str(args[0]).trim_suffix("s").strip_edges() if not args.is_empty() else ""
		if seconds.is_valid_float(): action.duration_s = clampf(float(seconds), 0.5, 600.0)
		else: action.duration_s = 30.0
		return action
	# Forgiving shapes: [follow] and [lead: PLACE] mean the player; "me"/"anon" name him too.
	var lone_place: bool = type == "lead" and args.size() == 1 and str(args[0]).to_lower() != "player" and not is_player_name(str(args[0]))
	if type in ["follow", "lead"] and (args.is_empty() or lone_place): args.push_front("player")
	if type in ["follow", "lead", "approach", "look_at", "circle_over"] and not args.is_empty() and is_player_name(str(args[0])): args[0] = "player"
	# [meet: town hall, tomorrow at 3pm]: day and time written as one argument.
	if type == "meet" and args.size() == 2 and not MEET_TIME.find_time(str(args[1])).is_empty():
		var said := str(args[1])
		var day_word := MEET_TIME.find_day(said)
		args = [args[0], day_word if not day_word.is_empty() else "today", MEET_TIME.find_time(said)]
	var fields: Array = SIGNATURES.get(type, [])
	for i in fields.size():
		var field: String = fields[i][0]
		var fallback: Variant = fields[i][1]
		var given := str(args[i]) if i < args.size() else ""
		if given.is_empty():
			if fallback == null or (fallback is String and fallback.is_empty()): continue
			action[field] = fallback
			continue
		if RANGES.has(field) or field.ends_with("_s") or field.ends_with("_m"):
			var number := given.trim_suffix("m").trim_suffix("s").strip_edges()
			var bounds: Array = RANGES.get(field, [0.0, 600.0])
			action[field] = clampf(float(number), bounds[0], bounds[1]) if number.is_valid_float() else fallback
		elif field == "accept":
			action[field] = given.to_lower() in ["yes", "true", "accept", "y", "ok", "sure"]
		else:
			action[field] = given.to_lower().replace(" ", "_") if field.ends_with("_id") or field in ["formation", "pace", "kind", "activity", "direction"] else given
	if type == "hover": action.duration_s = clampf(float(action.get("duration_s", 10.0)), 1.0, 60.0)
	if type == "look_at": action.duration_s = clampf(float(action.get("duration_s", 3.0)), 0.2, 30.0)
	if type == "follow" and action.get("formation") not in ["behind", "left", "right", "loose"]: action.formation = "right"
	if type == "step": action.direction = STEP_SPELLINGS.get(str(action.get("direction", "aside")), str(action.get("direction", "aside")))
	if type == "go_to" and action.get("pace") not in ["walk", "trot"]: action.pace = "walk"
	if type == "go_to_bed": action.bed = "here" if str(action.get("bed", "own")).to_lower().replace(" ", "_") in BED_HERE else "own"
	# [sell: cider keg, 35 bits] / [buy: tea set, 30]: the number is the price.
	if type in ["sell", "buy"] and action.has("price"):
		var price_digits := RegEx.create_from_string("\\d+").search(str(action.price))
		if price_digits != null: action.price = int(price_digits.get_string())
		else: action.erase("price")
	# [pay_player: 20 bits] / [pay_player: 20]: the number is the amount.
	if type == "pay_player" and action.has("amount"):
		var digits := RegEx.create_from_string("\\d+").search(str(action.amount))
		if digits != null: action.amount = int(digits.get_string())
		else: action.erase("amount")
	return action

## "Walk with me" to a place she is going (thread report 2026-10-31: Rarity said she was going to
## the library to see Twilight and asked Anon along; on his "Sure" the model sent [follow: player]
## and she trailed him instead of heading there). Her [follow: player] becomes
## [lead: player, PLACE] only when she invited him in her own words and the place is certain: a
## listed location she named ("going to the library", "walk with me to X", "let's go to X"), her
## own model go_to/lead in progress (context heading_to) or her pending place outing; in the same
## line or her next reply after that invitation. An open-ended "walk with me" keeps [follow].
const INVITE_PATTERN := "\\b(walk|come|trot|stroll)( along)? with me\\b|\\bcome (along|too)\\b|\\bjoin me\\b|\\btag along\\b|\\bkeep me company\\b|\\baccompany me\\b|\\byou can come\\b|\\b(want|wanna|care|like) to (come|join)\\b|\\bwhy don't you come\\b|\\bcoming with me\\b"
const PLACE_PATTERNS := ["\\b(?:walk|come|go|trot|head)\\s+(?:along\\s+|over\\s+)?with me\\s+(?:over\\s+|down\\s+|up\\s+)?to\\s+([^,.!?;:\\n]+)",
	"\\blet'?s\\s+(?:go|walk|head|trot|stroll)\\s+(?:over\\s+|down\\s+|up\\s+|on\\s+)?to\\s+([^,.!?;:\\n]+)",
	"(?<!not )(?<!n't )\\b(?:going|heading|headed|off|on my way|walking|trotting|popping|making my way|bound)\\s+(?:over\\s+|down\\s+|up\\s+|back\\s+|out\\s+|across\\s+)?to\\s+([^,.!?;:\\n]+)"]
## Where a spoken place name ends ("the library to see Twilight").
const PLACE_CUTS := [" to ", " for ", " and ", " with ", " because ", " so ", " if ", " now ", " today ", " right ", " later ", " soon ", " darling ", " dear "]
## "going to see/buy/be ..." is a plan, not a place.
const NOT_PLACES := ["see", "visit", "get", "buy", "have", "be", "do", "make", "try", "ask", "tell", "meet", "help", "find", "pick", "bake",
	"grab", "check", "talk", "say", "show", "need", "go", "walk", "sleep", "eat", "read", "play", "take", "bring", "fetch", "look", "start",
	"finish", "work", "practice", "pay", "borrow", "return", "drop", "deliver", "sell", "give", "set", "fix", "stop", "rest", "sit", "fly"]
## actor -> {"place", "turn", "next"}: her last invitation to a certain place, kept for her next reply.
static var _invited: Dictionary = {}

static func _follow_to_lead(actions: Array, speech: String, actor: String, turn: int, context: Dictionary) -> void:
	var line := speech.to_lower().replace("’", "'")
	var spoken := _spoken_place(line, context)
	var invite: bool = bool(spoken.invite)
	var invites := RegEx.new()
	invites.compile(INVITE_PATTERN)
	if invites.search(line) != null: invite = true
	var place: String = str(spoken.place) if invite else ""
	var pending: Dictionary = context.get("relationship", {}).get("pending", {})
	var outing := str(pending.get("place", "")) if pending.get("by") == "pony" and pending.get("activity") == "place" else ""
	if place.is_empty() and invite:
		for action: Dictionary in actions:
			if action.type in ["go_to", "lead"] and not str(action.get("location_id", "")).is_empty(): place = str(action.location_id)
		if place.is_empty(): place = str(context.get("heading_to", ""))
	# Her own pending place outing is a structured invitation already.
	if place.is_empty(): place = outing
	var record: Dictionary = _invited.get(actor, {})
	# The same turn decoded again (a repair) replaces it; a later turn reads it once, then it lapses.
	if not record.is_empty() and (int(record.turn) >= turn or (int(record.next) >= 0 and int(record.next) != turn)): record = {}
	if not record.is_empty(): record.next = turn
	if not place.is_empty(): _invited[actor] = {"place": place, "turn": turn, "next": -1}
	elif record.is_empty(): _invited.erase(actor)
	var destination: String = place if not place.is_empty() else str(record.get("place", ""))
	if destination.is_empty() or "lead" not in context.get("capabilities", []): return
	for i in actions.size():
		var follow: Dictionary = actions[i]
		if follow.type != "follow" or follow.get("target_id") != "player": continue
		var lead := _tag_action("lead", "player, " + destination, turn, i)
		if validate(lead, context) != "": return
		print("[ai] %s: [follow: player] after her invitation to %s became [lead: player, %s]" % [actor, destination, str(lead.location_id)])
		actions[i] = lead
		return

## A listed place she says she is going to or invites Anon to: {"place", "invite"}.
static func _spoken_place(line: String, context: Dictionary) -> Dictionary:
	var locations: Array = context.get("locations", [])
	if locations.is_empty(): return {"place": "", "invite": false}
	for index in PLACE_PATTERNS.size():
		var pattern := RegEx.new()
		pattern.compile(str(PLACE_PATTERNS[index]))
		for found: RegExMatch in pattern.search_all(line):
			var clause := found.get_string(1).strip_edges() + " "
			for cut: String in PLACE_CUTS:
				var at := clause.find(cut)
				if at > 0: clause = clause.left(at)
			var words := PLACES.name_words(clause)
			if words.is_empty() or words.size() > 5 or words[0] in NOT_PLACES: continue
			var matched := PLACES.match_name(clause.strip_edges(), locations, context.get("place_labels", {}))
			if not matched.is_empty(): return {"place": matched, "invite": index < 2}
	return {"place": "", "invite": false}

## The FORMAT RULES block for one speaker: only her commands, targets and places.
static func tag_rules(capabilities: Array, targets: Array, places: String, include_bindings := true) -> String:
	var lines: Array = ["REPLY FORMAT (plain text, never JSON):",
		"Write only what you say out loud. Put tags in square brackets anywhere in the line; tags are never spoken.",
		"Example: [face:happy] Oh, hello there! [look_at: player]"]
	var commands: Array = []
	for type: String in TYPES:
		if type in capabilities and TAG_HELP.has(type): commands.append("- " + str(TAG_HELP[type]))
	if not commands.is_empty():
		lines.append("THINGS YOU CAN DO NOW (at most one, plus one [look_at: ...]):")
		lines.append_array(commands)
		if include_bindings:
			lines.append("TARGETS (who TARGET can be): " + (", ".join(targets) if not targets.is_empty() else "(none)"))
			lines.append("LOCATIONS (what LOCATION can be, nearest first; use the id before the =):")
			lines.append(places)
	lines.append("FEELINGS (optional, never spoken): after your complete spoken words you may add [mood: happy] [friendship: +1] [romance: 0] [thought: a short private thought]. Omit unchanged feelings. Never begin your answer with private metadata. Use [silence] to say nothing.")
	return "\n".join(lines)

static func decode(text: String, actor: String, turn: int, context: Dictionary, bind_request := false) -> Dictionary:
	text = text.strip_edges()
	if text.length() > 8192: return {"error": "Response exceeds 8192 characters"}
	if text.begins_with("```"):
		# Providers sometimes omit the closing Markdown fence even when the JSON is
		# complete. Strip only the wrapper; JSON.parse still rejects truncated data.
		text = text.substr(3).strip_edges()
		if text.to_lower().begins_with("json"): text = text.substr(4).strip_edges()
		if text.ends_with("```"): text = text.left(-3).strip_edges()
		if not text.begins_with("{"): return {"error": "Expected JSON inside response fence"}
	if not text.begins_with("{"):
		# Malformed JSON is never spoken; everything else is a tag reply.
		if "\"actions\"" in text or "\"schema_version\"" in text or "\"speech\"" in text:
			return {"error": "Malformed structured response"}
		return decode_tags(text, actor, turn, context)
	var parser := JSON.new()
	if parser.parse(text) != OK: return {"error": "Invalid response JSON"}
	var value: Variant = parser.data
	if not value is Dictionary: return {"error": "Invalid response JSON"}
	if not _keys(value, ["schema_version", "actor_id", "turn_id", "listener_id", "speech", "actions", "impression"]): return {"error": "Unknown response fields"}
	# Called only after the director checks the actual request generation.
	if bind_request:
		value.turn_id=turn;value.actor_id=actor;value.listener_id="player"
	if not _number(value.get("schema_version"), 1, 1) or value.get("actor_id") != actor or not _number(value.get("turn_id"), turn, turn):
		return {"error": "Wrong version, actor or conversation turn"}
	if value.get("listener_id") != "player": return {"error": "Group speech is not available yet"}
	if not value.get("speech") is String or value.speech.length() > SPEECH_LIMIT: return {"error": "Invalid speech field (maximum 2880 characters)"}
	var raw_speech: String = value.speech
	value.speech = CONTROLS.sanitize(raw_speech, true)
	if not value.get("actions") is Array or value.actions.size() > 2: return {"error": "At most two actions per reply"}
	var ids: Array = []
	var channels: Array = []
	for action in value.actions:
		var error := validate(action, context)
		if error != "": return {"error": error}
		if action.id in ids: return {"error": "Duplicate action IDs in reply"}
		if action.type in SPEECH_REQUIRED and CONTROLS.sanitize(value.speech).is_empty():return {"error":"This action requires spoken words before it can finish"}
		ids.append(action.id)
		var lane := channel(str(action.type))
		if lane in channels: return {"error": "One intention per channel per reply"}
		channels.append(lane)
	return {"speech": value.speech, "actions": value.actions.duplicate(true), "impression":preload("res://world/ai/impressions/pony_impressions.gd").sanitize(value.get("impression")),
		"control_only": value.actions.is_empty() and not raw_speech.strip_edges().is_empty() and raw_speech.strip_edges() != "[silence]" and CONTROLS.sanitize(value.speech).is_empty()}

static func validate(action: Variant, context: Dictionary) -> String:
	if not action is Dictionary or not action.get("type") is String or action.type not in TYPES: return "Unsupported action"
	if not _id(action.get("id")): return "Invalid action ID"
	if action.type not in context.get("capabilities", []): return "Capability unavailable: " + action.type
	var allowed: Array = ["id", "type"] + FIELDS[action.type]
	if not _keys(action, allowed): return "Unknown action fields"
	# Linky is the existing Shoeshine identity. Canonicalize the name before
	# ordinary target/hearing validation; an alias never grants availability.
	for field: String in ["target_id", "pony_id"]:
		if field not in FIELDS[action.type] or not action.get(field) is String: continue
		var name_id: String = str(action[field]).strip_edges().to_lower().replace(" ", "_")
		if name_id in ["linky", "linky_(shoeshine)"]: action[field] = "shoeshine"
	if "target_id" in FIELDS[action.type]:
		if not _id(action.get("target_id")) or not context.get("targets", {}).has(action.target_id): return "Unknown target"
	if action.type in ["call_pony", "send_pony"]:
		if not _id(action.get("pony_id")) or action.pony_id not in context.get("callable_ponies", []): return "Pony is not nearby or cannot hear you"
		if action.type == "send_pony" and action.pony_id == action.target_id: return "A pony cannot be sent to herself"
	if "location_id" in FIELDS[action.type] and (action.type != "relationship_offer" or action.has("location_id")):
		if not action.get("location_id") is String: return "Unknown mapped location"
		if action.location_id not in context.get("locations", []):
			# A free-form name ("Sugarcube Corner", "the balloon") becomes the listed id it means.
			var matched := PLACES.match_name(str(action.location_id), context.get("locations", []), context.get("place_labels", {}))
			if matched.is_empty(): return "Unknown mapped location"
			action.location_id = matched
	match action.type:
		"relationship_offer":
			if action.get("kind") not in context.get("relationship",{}).get("offers",[]): return "Relationship milestone not eligible"
			if action.get("activity") not in ["walk","fishing","orchard","meal","visit","place"]: return "Unknown shared activity"
			if (action.get("activity") == "place") != action.has("location_id"): return "A place outing needs its location_id, and only a place outing takes one"
			if not context.get("relationship",{}).get("pending",{}).is_empty(): return "Answer or finish the existing invitation first"
		"relationship_answer":
			var pending: Dictionary=context.get("relationship",{}).get("pending",{})
			if pending.is_empty() or pending.get("by")!="player" or pending.get("id")!=action.get("offer_id"): return "No matching player invitation"
			if not action.get("accept") is bool: return "Invitation answer must be boolean"
		"agreed":
			# AI-directed agreement (dev 2026-10-31): her reply decides, in any wording; the game still
			# checks the step is allowed (player_bonds.gd agree).
			var relationship: Dictionary = context.get("relationship", {})
			var open: Dictionary = relationship.get("pending", {})
			if action.get("kind") not in AGREED_KINDS: return "Unknown relationship step"
			if not open.is_empty() and open.get("kind") != action.get("kind"): return "Answer or finish the existing invitation first"
			if open.is_empty() and action.get("kind") not in relationship.get("offers", []): return "Relationship milestone not eligible"
		"meet":
			var clock := _clock(context)
			var when := MEET_TIME.parse(str(action.get("day", "today")), str(action.get("time", "")), int(clock.day), float(clock.hours))
			if not bool(when.ok): return str(when.error)
			# Normalized, so a second validation (and the appointment store) reads the same meeting.
			action.day = str(when.day_text); action.time = str(when.time_text)
		"pay_player":
			if not (action.get("amount") is int or action.get("amount") is float) or int(action.amount) < 1: return "Name how many bits to give"
			if int(action.amount) > int(context.get("purse", 0)): return "You only have %d bits" % int(context.get("purse", 0))
			action.amount = int(action.amount)
		"give":
			# Only what she really has (mechanics.gd ai_context "givables"); normalised to its id.
			if not action.get("item") is String or str(action.item).strip_edges().is_empty() or str(action.item).length() > 80: return "Name the thing to give"
			var given := ITEM_CATALOG.match_name(str(action.item), context.get("givables", []))
			if given.is_empty(): return "You do not have that to give"
			action.item = given
		"use":
			# Only a station she can work now (mechanics.gd ai_context "stations", stations.gd workable).
			if not _id(action.get("station_id")) or action.station_id not in context.get("stations", []): return "No station you can work here"
		"offer_job":
			# Only work she hires for that is open now (mechanics.gd ai_context "jobs", jobs.gd offerable).
			if action.get("job_id") is String: action.job_id = str(action.job_id).trim_prefix("the_")
			# A spelled-out name ("apple bucking", "day spa", "Cider-Stand") becomes its id (jobs.json names).
			if action.get("job_id") is String and str(action.job_id) not in context.get("jobs", []):
				var spelled_job := _event_key(str(action.job_id))
				var job_names: Dictionary = context.get("job_names", {}) if context.get("job_names") is Dictionary else {}
				for job: Variant in context.get("jobs", []):
					if spelled_job == _event_key(str(job)) or spelled_job == _event_key(str(job_names.get(job, ""))): action.job_id = str(job); break
			if not _id(action.get("job_id")) or action.job_id not in context.get("jobs", []): return "You have no such work to offer now"
		"ask":
			# A favour in the shared grammar (world/mechanics/asks/ask_rules.gd), normalised in place so
			# the second validation (commit) reads the canonical form.
			if not action.get("want") is String or not action.get("reward", "thanks") is String: return "Say what the favour is"
			var asked := ASK_RULES.parse(str(action.want), str(action.get("reward", "thanks")), context)
			if not bool(asked.ok): return str(asked.error)
			action.want = str(asked.want); action.reward = str(asked.reward)
		"invite":
			# Only an event she may invite Anon to today (mechanics.gd ai_context "events"); a spelled-out
			# name ("Trixie's stage show", "the Cider Season") becomes its id (town_calendar.gd rows).
			if action.get("event_id") is String and str(action.event_id) not in context.get("events", []):
				var spelled := _event_key(str(action.event_id))
				var names: Dictionary = context.get("event_names", {}) if context.get("event_names") is Dictionary else {}
				for event: Variant in context.get("events", []):
					if spelled == _event_key(str(event)) or spelled == _event_key(str(names.get(event, ""))): action.event_id = str(event); break
			if not _id(action.get("event_id")) or action.event_id not in context.get("events", []): return "No such event today"
		"sell", "buy":
			# [sell]: only what is on her stall here (mechanics.gd ai_context "sell_items", market.gd), at
			# 1..2x its card price. [buy]: only what Anon holds beside her ("anon_holding"), within her
			# purse and at most twice its value (at least 10). Item normalised to its id.
			if not action.get("item") is String or str(action.item).strip_edges().is_empty() or str(action.item).length() > 80: return "Name the thing"
			if not (action.get("price") is int or action.get("price") is float) or int(action.price) < 1: return "Name a price in bits"
			var listed: Array = context.get("sell_items" if action.type == "sell" else "anon_holding", [])
			var named := ITEM_CATALOG.match_name(str(action.item), listed)
			if named.is_empty(): return "That is not on your stall here" if action.type == "sell" else "Anon is not holding that"
			action.item = named
			action.price = int(action.price)
			if action.type == "sell":
				var card: int = int((context.get("sell_prices", {}) as Dictionary).get(named, 0)) if context.get("sell_prices") is Dictionary else 0
				if action.price > maxi(1, card * 2): return "At most %d bits for that" % maxi(1, card * 2)
			else:
				var purse: int = int(context.get("buy_purse", context.get("purse", 0)))
				if action.price > purse: return "You only have %d bits" % purse
				var worth: int = int((context.get("holding_values", {}) as Dictionary).get(named, 0)) if context.get("holding_values") is Dictionary else 0
				if action.price > maxi(10, worth * 2): return "At most %d bits for that" % maxi(10, worth * 2)
		"take_off", "put_on":
			if not action.get("kind") is String or str(action.kind).is_empty() or str(action.kind).length() > 40: return "Name the item of clothing"
		"hover":
			if not _number(action.get("duration_s"), 1, 60): return "Hover duration must be 1–60 seconds"
		"air_show":
			var moves: Variant = action.get("moves")
			if not moves is Array or moves.is_empty() or moves.size() > SHOW_LIMIT: return "An air show needs 1–8 figures"
			for move in moves: if str(move) not in SHOW_MOVES: return "Unknown air show figure: " + str(move)
		"look_at":
			if not _number(action.get("duration_s"), .2, 30): return "Look duration must be 0.2–30 seconds"
		"approach", "follow":
			if not _number(action.get("distance_m"), 1.0, 6.0): return "Distance must be 1–6 metres"
			if action.type == "follow" and action.get("formation") not in ["behind", "left", "right", "loose"]: return "Unknown formation"
		"go_to":
			if action.get("pace") not in ["walk", "trot"]: return "Pace must be walk or trot"
		"go_to_bed":
			if action.get("bed", "own") not in ["own", "here"]: return "Bed must be own or here"
		"step":
			if action.get("direction") not in STEP_DIRECTIONS: return "Direction must be forward, back, left, right, away or aside"
			if not _number(action.get("distance_m"), 1.0, 6.0): return "Distance must be 1–6 metres"
		"lead":
			if not _number(action.get("wait_distance_m"), 3, 15): return "Lead waiting distance must be 3–15 metres"
		"stay":
			if action.has("until_cancel") or not _number(action.get("duration_s"), .5, 600): return "Stay duration must be 0.5–600 seconds"
		"cancel":
			if not _id(action.get("action_id")): return "Invalid cancellation target"
	return ""

## The game clock for meeting times: context "clock" ({"day", "hours"}, tests and letters) or TimeOfDay.
static func _clock(context: Dictionary) -> Dictionary:
	var given: Variant = context.get("clock")
	if given is Dictionary: return {"day": int((given as Dictionary).get("day", 0)), "hours": float((given as Dictionary).get("hours", 12.0))}
	var loop := Engine.get_main_loop() as SceneTree
	var clock: Node = loop.root.get_node_or_null("TimeOfDay") if loop != null else null
	return {"day": int(clock.get("day")), "hours": float(clock.get("hours"))} if clock != null else {"day": 0, "hours": 12.0}

static func _keys(value: Dictionary, allowed: Array) -> bool:
	for key in value:
		if key not in allowed: return false
	return true

static func _number(value: Variant, low: float, high: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= low and value <= high

## An event id or name reduced to letters and digits, without a leading "the" ([invite]).
static func _event_key(text: String) -> String:
	var key := ""
	for c: String in text.to_lower().trim_prefix("the ").trim_prefix("the_"):
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"): key += c
	return key

static func _id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 96: return false
	for c in value:
		if c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-": return false
	return true
