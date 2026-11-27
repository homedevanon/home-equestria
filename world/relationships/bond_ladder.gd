extends RefCounted
## Relationship levels (dev 2026-10-29: "love 0/100 looks like it doesn't loop back around"). Two
## ladders per pony, each a row of named levels; the bar fills toward the NEXT level and empties
## after each level-up, so it reads as levelling, never as a 0-100 score that ends.
##   Friendship: Stranger, Acquaintance, Friend, Good Friend, Best Friend, Blood Brothers, Kindred Soul.
##   Love (adults, from Friend on): Crush, New Couple, Marefriend/Coltfriend, Head Over Hooves, Soulmates.
## The first three friendship levels are the bond stage (player_bonds.gd: met, familiarity and trust
## from time together). Beyond Friend they are friendship XP: every warm reply's friendship gain
## adds up with no ceiling (pony_impressions.gd), each level needing more than the last. Love levels
## are love XP plus the real commitments: New Couple is dating, Head Over Hooves can be engagement,
## Soulmates is marriage. A full bar waiting on one of those says so instead of a number.

const FRIEND_NAMES := ["Stranger", "Acquaintance", "Friend", "Good Friend", "Best Friend", "Blood Brothers", "Kindred Soul"]
## Cumulative friendship XP for Good Friend, Best Friend, Blood Brothers and Kindred Soul. A warm
## reply is about +4 (pony_impressions.gd GAIN), a five-minute sitting at most +40.
const FRIEND_XP := [60, 180, 450, 1000]
const LOVE_XP := {"crush": 30, "partner": 150, "hooves": 400, "soulmates": 900}
## Acquaintance to Friend mirrors player_bonds.gd experience(): familiarity 20 and trust 10.
const FRIEND_FAMILIARITY := 20.0
const FRIEND_TRUST := 10.0

## Old saves had capped 0..100 scores with tiers at 25/55/85. Seeds keep each pony on the level its
## old tier meant: 25 (old "Friend") = Good Friend, 55 = Best Friend, 85 = Blood Brothers.
static func seed_friendship(score: int) -> int:
	var s := float(clampi(score, 0, 100))
	if s < 25.0: return roundi(s * 2.4)
	if s < 55.0: return roundi(60.0 + (s - 25.0) * 4.0)
	if s < 85.0: return roundi(180.0 + (s - 55.0) * 9.0)
	return roundi(450.0 + (s - 85.0) * 20.0)

static func seed_romance(score: int) -> int:
	var s := float(clampi(score, 0, 100))
	if s < 25.0: return roundi(s * 1.2)
	if s < 55.0: return roundi(30.0 + (s - 25.0) * 4.0)
	if s < 85.0: return roundi(150.0 + (s - 55.0) * 25.0 / 3.0)
	return roundi(400.0 + (s - 85.0) * 20.0)

## The exact inverses of the seeds (relationship overhaul 2026-11-21, design 10.2): the old 0..100
## score old readers are given for a fixed XP. unseed_friendship(60) is 25, unseed_romance(30) is 25.
static func unseed_friendship(xp: int) -> int:
	var x := float(maxi(xp, 0))
	if x < 60.0: return clampi(roundi(x / 2.4), 0, 100)
	if x < 180.0: return clampi(roundi(25.0 + (x - 60.0) / 4.0), 0, 100)
	if x < 450.0: return clampi(roundi(55.0 + (x - 180.0) / 9.0), 0, 100)
	return clampi(roundi(85.0 + (x - 450.0) / 20.0), 0, 100)

static func unseed_romance(xp: int) -> int:
	var x := float(maxi(xp, 0))
	if x < 30.0: return clampi(roundi(x / 1.2), 0, 100)
	if x < 150.0: return clampi(roundi(25.0 + (x - 30.0) / 4.0), 0, 100)
	if x < 400.0: return clampi(roundi(55.0 + (x - 150.0) * 3.0 / 25.0), 0, 100)
	return clampi(roundi(85.0 + (x - 400.0) / 20.0), 0, 100)

## facts: {"met", "stage", "familiarity", "trust", "friend_xp", "love_xp", "romance" (may romance at
## all), "stallion", "turned_down" (a dating ask refused recently), "together_s", "ready_s"}.
## Returns {"friendship": row, "love": row or {}} where a row is
## {"names", "level" (0-based), "name", "next", "have", "need", "fill" (0..1), "max", "waiting"}.
## With the key "standing" (player_bonds.standing(), relationship overhaul 2026-11-21) the levels
## are her own stated steps (design 10.2): the same shape, names and integers, and no bar to fill.
static func compute(facts: Dictionary) -> Dictionary:
	if facts.has("standing") and facts.standing is Dictionary:
		return _from_standing(facts.standing, bool(facts.get("stallion", false)))
	return {"friendship": _friend_row(facts), "love": _love_row(facts)}

## Love: no level -1, Crush 0 (a crush or more, not a couple), New Couple 1 (a couple, a crush),
## Marefriend 2 (a couple, in love), Head Over Hooves 3 (a couple, devoted), Soulmates 4 (married and
## devoted). A couple whose heart is below a crush has no love level.
static func _from_standing(s: Dictionary, stallion: bool) -> Dictionary:
	var at := maxi(0, CLOSENESS_ORDER.find(str(s.get("closeness", "stranger"))))
	var friend := _row(FRIEND_NAMES, at, 0, 1)
	friend.fill = 0.0
	if not bool(s.get("romance", false)): return {"friendship": friend, "love": {}}
	var names := ["Crush", "New Couple", "Coltfriend" if stallion else "Marefriend", "Head Over Hooves", "Soulmates"]
	var heart := HEART_ORDER.find(str(s.get("heart", "none")))
	var status := str(s.get("status", "none"))
	var level := -1
	if heart >= 2:
		if status == "none": level = 0
		else:
			level = heart - 1
			if status == "married" and heart == 4: level = 4
	if level < 0:
		return {"friendship": friend, "love": {"names": names, "level": -1, "name": "No crush yet", "next": "Crush", "have": 0, "need": 0, "fill": 0.0, "max": false, "waiting": ""}}
	var love := _row(names, level, 0, 1)
	love.fill = 0.0
	return {"friendship": friend, "love": love}

const CLOSENESS_ORDER := ["stranger", "acquaintance", "friend", "good_friend", "best_friend", "blood_brothers", "kindred_soul"]
const HEART_ORDER := ["none", "noticing", "crush", "in_love", "devoted"]

static func _row(names: Array, level: int, have: int, need: int, waiting := "") -> Dictionary:
	var top := level >= names.size() - 1
	var fill := 1.0 if top or need <= 0 else clampf(float(have) / float(need), 0.0, 1.0)
	return {"names": names, "level": level, "name": str(names[level]), "next": "" if top else str(names[level + 1]),
		"have": have, "need": need, "fill": fill, "max": top, "waiting": waiting}

static func _friend_row(f: Dictionary) -> Dictionary:
	var stage := str(f.get("stage", "acquaintance"))
	var xp := int(f.get("friend_xp", 0))
	if not bool(f.get("met", false)):
		return _row(FRIEND_NAMES, 0, 0, 1, "Say hello to meet")
	if stage == "acquaintance":
		# Points toward Friend: familiarity and trust, each counted up to what Friend needs.
		var have := roundi(minf(float(f.get("familiarity", 0.0)), FRIEND_FAMILIARITY) + minf(float(f.get("trust", 0.0)), FRIEND_TRUST) * 2.0)
		return _row(FRIEND_NAMES, 1, have, roundi(FRIEND_FAMILIARITY + FRIEND_TRUST * 2.0), "Spend time together")
	var level := 2
	for threshold: int in FRIEND_XP:
		if xp >= threshold: level += 1
	if level >= FRIEND_NAMES.size() - 1: return _row(FRIEND_NAMES, FRIEND_NAMES.size() - 1, xp, xp)
	var floor_xp: int = 0 if level == 2 else int(FRIEND_XP[level - 3])
	return _row(FRIEND_NAMES, level, xp - floor_xp, int(FRIEND_XP[level - 2]) - floor_xp)

static func _love_row(f: Dictionary) -> Dictionary:
	if not bool(f.get("romance", false)): return {}
	var names := ["Crush", "New Couple", "Coltfriend" if bool(f.get("stallion", false)) else "Marefriend", "Head Over Hooves", "Soulmates"]
	var stage := str(f.get("stage", "acquaintance"))
	var xp := int(f.get("love_xp", 0))
	match stage:
		"married":
			return _row(names, 4, xp, xp)
		"engaged":
			return _row(names, 3, 1, 1, "Marry to become Soulmates")
		"dating":
			if xp >= int(LOVE_XP.hooves):
				return _row(names, 3, xp - int(LOVE_XP.hooves), int(LOVE_XP.soulmates) - int(LOVE_XP.hooves),
					"Marry to become Soulmates" if xp >= int(LOVE_XP.soulmates) else "")
			if xp >= int(LOVE_XP.partner):
				return _row(names, 2, xp - int(LOVE_XP.partner), int(LOVE_XP.hooves) - int(LOVE_XP.partner))
			return _row(names, 1, maxi(0, xp - int(LOVE_XP.crush)), int(LOVE_XP.partner) - int(LOVE_XP.crush))
	# Not dating: no level until a crush. A dating ask turned down sends the row back to "no crush
	# yet" for now (dev: "Crush, rejected back to platonic"); love XP is kept for later.
	if stage not in ["friend", "close_friend"] or bool(f.get("turned_down", false)) or xp < int(LOVE_XP.crush):
		var waiting := "Become friends first" if stage not in ["friend", "close_friend"] else ("Turned down for now" if bool(f.get("turned_down", false)) else "")
		return {"names": names, "level": -1, "name": "No crush yet", "next": "Crush", "have": mini(xp, int(LOVE_XP.crush)),
			"need": int(LOVE_XP.crush), "fill": clampf(float(xp) / float(LOVE_XP.crush), 0.0, 1.0), "max": false, "waiting": waiting}
	# A crush: the bar is time together until one of you is ready to ask (player_bonds READY_TOGETHER_S).
	var ready_s := maxf(1.0, float(f.get("ready_s", 3600.0)))
	var together := minf(float(f.get("together_s", 0.0)), ready_s)
	# Asking is in any words; her AI decides (dev 2026-10-31). Say what still blocks it, if anything.
	var waiting := "Ask each other out" if together >= ready_s else "You can ask now, in your own words"
	if not bool(f.get("can_ask", true)): waiting = "Trust %d/20 to ask" % mini(19, int(f.get("trust", 0.0)))
	var row := _row(names, 0, roundi(together / 60.0), roundi(ready_s / 60.0), waiting)
	row.unit = "min together"
	return row

## One line for her prompt: the level names she and Anon have reached.
static func prompt_line(levels: Dictionary) -> String:
	var friend: Dictionary = levels.get("friendship", {})
	var love: Dictionary = levels.get("love", {})
	var parts := PackedStringArray()
	if not friend.is_empty(): parts.append("friendship level " + str(friend.name))
	if not love.is_empty() and int(love.level) >= 0: parts.append("love level " + str(love.name))
	return "" if parts.is_empty() else "With Anon: " + ", ".join(parts) + "."
