extends RefCounted
## Relationship overhaul 2026-11-21 (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md sections 2 and 10.1,
## contract docs/RELATIONSHIP_BUILD_2026_11_21.md 3.6): the one record a pony keeps about Anon,
## under player_bonds records[id][BOND.SAVE_KEY]. Pure functions over one record.
##
## It holds facts and her own words. Nothing in it is progress toward anything, and nothing in it
## is a time something becomes allowed: "day" and "t" fields only date a fact so her prompt and the
## page can say how long ago it was (BOND.age).
const BOND := preload("res://world/relationships/bond_rules.gd")
const LADDER := preload("res://world/relationships/bond_ladder.gd")

## A record for a pony who has never had one.
static func fresh(closeness: String, today: int, t: float) -> Dictionary:
	var met := closeness != "stranger"
	return {"v": BOND.SAVE_VERSION,
		"closeness": closeness, "closeness_day": today if met else -1, "closeness_why": "",
		"heart": "none", "heart_day": -1, "heart_why": "",
		"status_day": -1, "met_day": today if met else -1, "met_t": t if met else 0.0, "seen_day": -1,
		"occasions": 0, "meeting": false, "done": {}, "company_s": 0.0, "places": [],
		"sore": [], "answers": {}, "his_no": {}, "open_ask": {}, "last_ask": {}, "over": {},
		"undo": "", "undo_prev": {}, "kiss_word": "unsaid", "kiss_closed_by": "",
		"presses": {}, "last_touch": {}, "judging": {}, "lately": [], "weigh": [], "thought": {},
		"repair": "", "repair_kind": "", "repair_shown": false, "ask_flag": false, "ask_shown": false,
		"log": [], "acts": [], "act_from": "", "flings": [], "forgiven": [], "plan_day": -1, "plan_t": 0.0, "meet_kind": ""}

## Fills keys a record from an older build of this version lacks; never changes a present one.
static func complete(b: Dictionary) -> Dictionary:
	var base := fresh(str(b.get("closeness", "stranger")), -1, 0.0)
	for key: String in base:
		if not b.has(key): b[key] = base[key]
	return b

## The record of a 0.3.1 save (design 10.1). `seen`: {"met": bool, "friend_xp": int, "love_xp": int,
## "enemy": int, "grudge": float, "thought": String, "today": int (the day as the player reads it),
## "calendar": float (player_bonds.day()), "t": float}. Read once per record, never again.
static func convert(r: Dictionary, seen: Dictionary) -> Dictionary:
	var today := int(seen.get("today", 0))
	var t := float(seen.get("t", 0.0))
	var calendar := float(seen.get("calendar", 0.0))
	var stage := str(r.get("stage", "acquaintance"))
	# Her closeness: the friendship level the page showed (stage, familiarity, trust and friendship XP).
	var rows: Dictionary = LADDER.compute({"met": bool(seen.get("met", false)), "stage": stage,
		"familiarity": float(r.get("familiarity", 0.0)), "trust": float(r.get("trust", 0.0)),
		"friend_xp": int(seen.get("friend_xp", 0)), "love_xp": 0, "romance": false})
	var level := clampi(int((rows.friendship as Dictionary).get("level", 0)), 0, BOND.CLOSENESS.size() - 1)
	var b := fresh(str(BOND.CLOSENESS[level]), today, t)
	# When they met and when she reached this step are not known from a 0.3.1 save.
	b.closeness_day = -1
	b.met_day = -1
	b.met_t = 0.0
	# Her heart: the old Love bar's XP, and at least what a title saved under the old rules meant.
	var love := int(seen.get("love_xp", 0))
	for row: Array in BOND.CONVERT_HEART:
		if love >= int(row[0]):
			b.heart = str(row[1])
			break
	if BOND.CONVERT_TITLE_HEART.has(stage) and BOND.heart_rank(str(b.heart)) < BOND.heart_rank(str(BOND.CONVERT_TITLE_HEART[stage])):
		b.heart = str(BOND.CONVERT_TITLE_HEART[stage])
	if str(b.heart) != "none": b.heart_day = -1
	match stage:
		"dating": b.status_day = _day_of(float(r.get("dating_since", -1.0)), calendar, today)
		"engaged": b.status_day = _day_of(float(r.get("engaged_since", -1.0)), calendar, today)
		"married": b.status_day = _day_of(float(r.get("engaged_since", -1.0)), calendar, today)
	# An old hurt, and a betrayal, become sore points she has not forgiven.
	if int(seen.get("enemy", 0)) >= BOND.CONVERT_ENEMY_AT or float(seen.get("grudge", 0.0)) >= BOND.CONVERT_GRUDGE_AT:
		(b.sore as Array).append(sore_row("old", "", "", today, t, true))
	var betrayed: Variant = r.get("betrayed")
	if betrayed is Dictionary and not (betrayed as Dictionary).is_empty():
		(b.sore as Array).push_front(sore_row("betrayed", "", str((betrayed as Dictionary).get("with", "")), today, t, true))
	# A refused ask is remembered as a no, without its wait. He turned her down when her asks were spent.
	var cooldowns: Dictionary = r.get("cooldowns", {}) if r.get("cooldowns") is Dictionary else {}
	if cooldowns.has("dating_day"):
		var asks_left := int(r.get("asks_left", 2))
		if asks_left < 2:
			b.his_no = {"kind": "couple", "day": today, "t": t, "count": 2 - asks_left}
			b.last_ask = {"kind": "couple", "refused": true}
		else:
			b.answers = {"couple": {"answer": "no", "day": today, "t": t, "count": 1}}
	# The diary, seeded from what 0.3.1 counted.
	var experiences: Dictionary = r.get("experiences", {}) if r.get("experiences") is Dictionary else {}
	var done := {}
	for kind: String in ["walk", "meal", "fishing", "orchard", "visit", "place", "gift"]:
		if int(experiences.get(kind, 0)) > 0: done[kind] = int(experiences[kind])
	b.occasions = int(experiences.get("conversation", 0))
	var kept := 0
	var met_kept := 0
	var missed := 0
	for promise: Variant in r.get("promises", []):
		if not promise is Dictionary: continue
		match str((promise as Dictionary).get("status", "")):
			"kept":
				if str((promise as Dictionary).get("activity", "")) == "place": met_kept += 1
				else: kept += 1
			"missed": missed += 1
	var dates := int(r.get("dates", 0))
	if dates > 0: done["date"] = dates
	if kept - dates > 0: done["outing"] = kept - dates
	if met_kept > 0: done["meeting"] = met_kept
	if missed > 0: done["missed"] = missed
	if int(r.get("kisses", 0)) > 0: done["kisses"] = int(r.kisses)
	b.done = done
	b.company_s = float(r.get("together_s", 0.0))
	if r.get("plan") is Dictionary and not (r.plan as Dictionary).is_empty():
		b.plan_day = today
		b.plan_t = t
	var thought := str(seen.get("thought", ""))
	if not thought.is_empty() and thought != "We haven't shared enough yet for an impression.":
		b.thought = {"text": thought.left(BOND.WHY_MAX * 3), "day": today, "t": t}
	return b

## A day of the old calendar (player_bonds.day() units) as the day the player reads.
static func _day_of(old_day: float, calendar: float, today: int) -> int:
	if old_day < 0.0: return -1
	return today - maxi(0, int(floorf(calendar)) - int(floorf(old_day)))

static func sore_row(kind: String, text: String, who: String, day: int, t: float, fact: bool) -> Dictionary:
	return {"kind": kind, "text": text.left(BOND.WHY_MAX), "who": who, "day": day, "t": t, "fact": fact, "again": false}

## The sore point of a kind, or {} when none of that kind is open.
static func sore_of(b: Dictionary, kind: String) -> Dictionary:
	for row: Variant in b.get("sore", []):
		if row is Dictionary and str((row as Dictionary).get("kind", "")) == kind: return row
	return {}

## SORE[kind].grave of the gravest open sore point, 0 with none.
static func gravest(b: Dictionary) -> int:
	var most := 0
	for row: Variant in b.get("sore", []):
		if row is Dictionary: most = maxi(most, int((BOND.SORE.get(str((row as Dictionary).get("kind", "")), {}) as Dictionary).get("grave", 0)))
	return most

## A count of the diary.
static func count(b: Dictionary, kind: String) -> int:
	return int((b.get("done", {}) as Dictionary).get(kind, 0))

static func add(b: Dictionary, kind: String, amount := 1) -> void:
	var done: Dictionary = b.done
	done[kind] = int(done.get(kind, 0)) + amount

## Nothing done together yet beyond talking on one occasion.
static func empty_diary(b: Dictionary) -> bool:
	if int(b.get("occasions", 0)) > 1: return false
	for kind: String in b.get("done", {}):
		if kind in ["face_warm", "bucked", "letters", "kiss_turned"]: continue
		if int(b.done[kind]) > 0: return false
	return true

## A light check of a saved record (player_bonds.valid_save).
static func valid(b: Variant) -> bool:
	if not b is Dictionary: return false
	var d: Dictionary = b
	if not (d.get("v") is int or d.get("v") is float): return false
	if d.has("closeness") and str(d.closeness) not in BOND.CLOSENESS: return false
	if d.has("heart") and str(d.heart) not in BOND.HEART: return false
	for key: String in ["sore", "lately", "weigh", "log", "places", "acts", "flings"]:
		if d.has(key) and not d[key] is Array: return false
	for key: String in ["done", "answers", "his_no", "open_ask", "over", "presses", "last_touch", "thought"]:
		if d.has(key) and not d[key] is Dictionary: return false
	return true
