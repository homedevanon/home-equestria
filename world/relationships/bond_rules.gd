extends RefCounted
## Relationship overhaul 2026-11-21 (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md, contract in
## docs/RELATIONSHIP_BUILD_2026_11_21.md): the words, steps and spellings of the relationship system,
## and the fixed values old readers and mods are given. Pure data and pure lookups.
##
## The dev's ruling: her model decides everything she feels and every step between the two of them;
## the game remembers facts and tells her. So nothing in this file is a threshold, a worth, a weight,
## a multiplier, a timer, a limit or a count to be reached, and nothing here may become one. The
## numbers below are of three kinds only: values looked up from her own stated step for old readers
## (FIXED_*), distances and press counts of her body's reflex (section 8), and sizes of text.

## The switch. true: her tags and the game's memory. false: the tree as it was on 2026-11-19.
## Off by default since 2026-11-26 (dev: 0.3.2 ships the old rules, the rework comes in a later
## patch). The launch argument --new-relationships turns it on; tests assign it.
## --old-relationships is still accepted and changes nothing.
static var DYNAMIC: bool = "--new-relationships" in OS.get_cmdline_user_args() or "--new-relationships" in OS.get_cmdline_args()
## Her feeling tag leads the reply (true) or ends it (--felt-last). The real-model check decides.
static var FELT_FIRST: bool = not ("--felt-last" in OS.get_cmdline_user_args() or "--felt-last" in OS.get_cmdline_args())

# --- Her word for the moment (design section 4.1, 4.4) ---
const WORDS := ["fine", "pleased", "touched", "flattered", "smitten", "pressured", "annoyed", "hurt", "angry", "forgiving"]
## reason: the word needs a few words why. mild: what it counts as without its reason. sore: the
## sore point it opens when it has its reason ("" = none).
const FELT := {
	"fine": {"reason": false, "mild": "", "sore": ""},
	"pleased": {"reason": false, "mild": "", "sore": ""},
	"touched": {"reason": true, "mild": "pleased", "sore": ""},
	"flattered": {"reason": false, "mild": "", "sore": ""},
	"smitten": {"reason": true, "mild": "flattered", "sore": ""},
	"pressured": {"reason": true, "mild": "cold", "sore": "came_on_strong"},
	"annoyed": {"reason": true, "mild": "cold", "sore": "annoyed"},
	"hurt": {"reason": true, "mild": "cold", "sore": "hurt"},
	"angry": {"reason": true, "mild": "cold", "sore": "furious"},
	"forgiving": {"reason": true, "mild": "pleased", "sore": ""},
}
## A cold word that came without its reason: it is cold for this reply (her last word on closeness)
## and leaves nothing lasting. Never written by her and never offered to her.
const COLD_MILD := "cold"
const COLD := ["pressured", "annoyed", "hurt", "angry", "cold"]
const WARM := ["pleased", "touched", "flattered", "smitten", "forgiving"]
## Counted as "pleased" for a filly, and for every pony while the player is a young AnonPony.
const ROMANTIC_WORDS := ["flattered", "smitten"]
## A word that is on no list: it counts for nothing and is only logged.
const OTHER := "other"
## Near words, by the listed word they mean. Never onto a word that opens a sore point.
const NEAR := {
	"happy": "pleased", "glad": "pleased", "nice": "pleased", "good": "pleased", "content": "pleased", "amused": "pleased",
	"delighted": "pleased", "warm": "pleased", "friendly": "pleased", "cheerful": "pleased",
	"calm": "fine", "okay": "fine", "ok": "fine", "neutral": "fine", "shy": "fine", "nervous": "fine", "wary": "fine",
	"unsure": "fine", "surprised": "fine", "confused": "fine", "relaxed": "fine", "curious": "fine", "startled": "fine",
	"moved": "touched", "grateful": "touched",
	"charmed": "flattered", "flustered": "flattered", "blushing": "flattered",
	"lovestruck": "smitten", "swept": "smitten", "swooning": "smitten",
	"forgive": "forgiving", "forgave": "forgiving", "forgiven": "forgiving",
}
## Tag names read as the feeling tag ([mood: ...] is not one: it stays her mood; [feel: PONY +1]
## with a number in it is her feeling about another pony and is left to the decoder).
const FELT_NAMES := ["felt", "feel", "feeling", "feels"]

# --- Where she stands, by her own word (design sections 2, 4.1) ---
const CLOSENESS := ["stranger", "acquaintance", "friend", "good_friend", "best_friend", "blood_brothers", "kindred_soul"]
const HEART := ["none", "noticing", "crush", "in_love", "devoted"]
## The lowest closeness she can name. Stranger ends when they meet, which is a fact.
const CLOSENESS_FLOOR := "acquaintance"
## Tag names for a change of standing. A name that is also an old number tag ("friendship", "love",
## "romance") is a step tag only when its argument names a step; with a number it stays the old tag.
const FRIEND_NAMES := ["friend", "friends", "friendship", "closeness"]
const HEART_NAMES := ["heart", "love", "romance"]
## Spellings of a step in the argument (keys as key() makes them).
const CLOSENESS_STEPS := {
	"acquaintances": "acquaintance", "just_met": "acquaintance", "barely_know": "acquaintance",
	"friends": "friend", "a_friend": "friend", "just_friends": "friend",
	"good_friends": "good_friend", "close_friend": "good_friend", "close_friends": "good_friend", "a_good_friend": "good_friend",
	"best_friends": "best_friend", "bestie": "best_friend", "besties": "best_friend", "bff": "best_friend",
	"blood_brother": "blood_brothers", "blood_sisters": "blood_brothers", "like_family": "blood_brothers",
	"kindred": "kindred_soul", "kindred_spirit": "kindred_soul", "kindred_souls": "kindred_soul", "soul_friend": "kindred_soul",
}
const HEART_STEPS := {
	"nothing": "none", "no": "none", "no_feelings": "none", "just_friends": "none", "not_that_way": "none",
	"notice": "noticing", "noticing_him": "noticing", "noticing_her": "noticing", "interested": "noticing", "interest": "noticing",
	"a_crush": "crush", "crushing": "crush", "smitten": "crush",
	"love": "in_love", "inlove": "in_love", "loving": "in_love", "in_love_with_him": "in_love",
	"devotion": "devoted", "soulmate": "devoted", "soulmates": "devoted",
}

# --- Steps between them (design section 5) ---
const STEP_NAMES := ["us"]
const KINDS := ["kiss", "outing", "date", "couple", "move_in", "engaged", "married", "break_up", "hug"]
const ROMANTIC_KINDS := ["kiss", "date", "couple", "move_in", "engaged", "married"]
const ANSWER_WORDS := ["yes", "no", "ask", "refused"]
## Spellings of a KIND in the argument or the name of a tag she wrote (keys as key() makes them).
const KIND_NAMES := {
	"kisses": "kiss", "a_kiss": "kiss", "smooch": "kiss", "kiss_player": "kiss",
	"hugs": "hug", "a_hug": "hug", "embrace": "hug", "cuddle": "hug",
	"walk": "outing", "picnic": "outing", "hang_out": "outing", "hangout": "outing", "stroll": "outing", "trip": "outing",
	"meal": "outing", "visit": "outing", "fishing": "outing",
	"a_date": "date", "date_night": "date", "dinner_date": "date",
	"marefriend": "couple", "coltfriend": "couple", "girlfriend": "couple", "boyfriend": "couple", "dating": "couple",
	"together": "couple", "official": "couple", "relationship": "couple", "partner": "couple", "partners": "couple",
	"special_somepony": "couple", "going_steady": "couple", "a_couple": "couple",
	"moving_in": "move_in", "movein": "move_in", "live_together": "move_in", "living_together": "move_in", "share_a_home": "move_in",
	"engagement": "engaged", "proposal": "engaged", "propose": "engaged", "fiance": "engaged", "fiancee": "engaged",
	"marriage": "married", "marry": "married", "marry_me": "married", "wedding": "married", "wed": "married",
	"breakup": "break_up", "split": "break_up", "split_up": "break_up", "end_it": "break_up", "over": "break_up",
}
## Tag names that are also actions: claimed as a step only when the answer is a no.
const NEGATIVE_ONLY := ["kiss_player", "cuddle"]
const ANSWERS := {
	"yes": "yes", "y": "yes", "true": "yes", "accept": "yes", "accepted": "yes", "agree": "yes", "agreed": "yes",
	"ok": "yes", "okay": "yes", "sure": "yes",
	"no": "no", "n": "no", "false": "no", "nope": "no", "not_yet": "no", "not_now": "no", "later": "no",
	"decline": "no", "declined": "no",
	"ask": "ask", "asks": "ask", "asking": "ask", "asked": "ask", "offer": "ask",
	"refused": "refused", "refuse": "refused", "rejected": "refused", "took_back": "refused", "takes_back": "refused",
}
## The three old step tags, their kinds in new words, and the saved stage a title makes.
const OLD_TAGS := ["relationship_offer", "relationship_answer", "agreed"]
const OLD_KIND := {"dating": "couple", "engagement": "engaged", "marriage": "married", "date": "date", "outing": "outing",
	"move_in": "move_in", "kiss": "kiss", "hug": "hug", "break_up": "break_up"}
const STAGE_FOR := {"couple": "dating", "engaged": "engaged", "married": "married"}
const STATUS := ["none", "couple", "engaged", "married"]
const STATUS_FOR_STAGE := {"dating": "couple", "engaged": "engaged", "married": "married"}
## What her heart would be for a title to match it. Used only to choose wording (the "heart is not in
## it" note, the page line "She has not said she has feelings for you") and for bond_state().committed.
## It refuses nothing: her yes stands at any heart.
const TITLE_MEANS := {"couple": "crush", "engaged": "in_love", "married": "devoted"}

# --- Sore points (design section 6). No weight: each is open until she forgives it. ---
## fact: the game opens it from something it saw, without her word. label: the page's words.
## grave: the order used only to pick the fixed hostility value old readers get (FIXED_HOSTILITY).
const SORE := {
	"came_on_strong": {"fact": false, "grave": 1, "label": "Came on too strong"},
	"annoyed": {"fact": false, "grave": 1, "label": "Annoyed her"},
	"hint": {"fact": true, "grave": 1, "label": "Would not take a hint"},
	"ignored_no": {"fact": true, "grave": 2, "label": "Ignored her no"},
	"hurt": {"fact": false, "grave": 2, "label": "Hurt her"},
	"furious": {"fact": false, "grave": 3, "label": "Made her furious"},
	"stood_up": {"fact": true, "grave": 2, "label": "Stood her up"},
	"rushed": {"fact": true, "grave": 2, "label": "It got physical before it got serious"},
	"ended_coldly": {"fact": true, "grave": 2, "label": "Ended it coldly"},
	"betrayed": {"fact": true, "grave": 3, "label": "Betrayed her"},
	"old": {"fact": true, "grave": 2, "label": "Something he did before still stings"},
}
## The sore points whose talk reaches the town while they are unforgiven (design section 7.2).
const TOWN_HEARS := ["hurt", "furious", "betrayed"]
## "Anon goes from mare to mare" is said while his last this-many flings were with different mares.
## A description of a fact, true or not at any moment; it is never a count to be reached by her.
const FLING_TALK := 3

# --- Things the game saw (design section 2 D): diary kinds and the events that are not deeds ---
## Kinds counted in the diary and told under "So far". No kind has a worth.
const DIARY := ["talk", "company", "walk", "meal", "fishing", "orchard", "visit", "place", "gift", "favour", "outing", "meeting", "date"]
## Kinds that are a promise kept.
const PROMISES := ["outing", "meeting", "date"]
## Kinds for player_bonds.fact(): her own touch (detail "kiss" or "cuddle"), her affectionate face,
## her buck, the two of them parting (detail "he_slept" when he went to sleep away from her), and a
## welcomed hug or held hoof.
const EVENTS := ["her_touch", "face_warm", "bucked", "parted", "hug"]
## What puts the weighing line on her next reply to him (design section 3.4).
const WEIGH := ["deed", "promise_kept", "promise_missed", "gift", "kiss", "hug", "intimacy", "sore_opened", "sore_forgiven", "met_again"]
## An adult mod's acts: this many event-id stems are remembered for each pony, so no act is entered twice.
const ACT_STEMS := 8

# --- Her body's reflex (design section 8). Counts of presses and distances; never a judgement. ---
## Presses of the kiss button before she could answer: the second is a hint, the third the buck.
const PRESS_HINT := 2
const PRESS_BUCK := 3
## He has stepped back out of reach beyond this many metres: the count of presses ends.
const REACH_M := 3.0
## They have parted beyond this many metres: the meeting ends.
const PART_M := 30.0
## She is beside him within this many metres: when he falls asleep beside her, an open plan stays open.
const BESIDE_M := 8.0
## Company near her is told in "So far" as a phrase. These bounds only choose the phrase.
const COMPANY_WORDS := [[600.0, "a little while"], [5400.0, "about an hour"], [18000.0, "several hours"]]
const COMPANY_MOST := "many hours"

# --- Fixed values for mods and old saves (design section 10.2). An echo of her word. ---
## Friendship XP and love XP as old readers see them: the threshold of the level she says she is at.
const FIXED_FRIEND_XP := {"stranger": 0, "acquaintance": 0, "friend": 0, "good_friend": 60, "best_friend": 180, "blood_brothers": 450, "kindred_soul": 1000}
const FIXED_LOVE_XP := {"none": 0, "noticing": 10, "crush": 30, "in_love": 150, "devoted": 400}
const FIXED_LOVE_XP_MARRIED_DEVOTED := 900
## [familiarity, trust] per closeness step. Trust reads 0 while a sore point is open.
const FIXED_KNOWN := {"stranger": [0.0, 0.0], "acquaintance": [5.0, 0.0], "friend": [20.0, 10.0], "good_friend": [40.0, 30.0],
	"best_friend": [60.0, 55.0], "blood_brothers": [80.0, 80.0], "kindred_soul": [100.0, 100.0]}
## devotion() per heart step: [not a committed couple, a committed couple]. Lowest while a sore point is open.
const FIXED_DEVOTION := {"none": [0.0, 0.4], "noticing": [0.1, 0.4], "crush": [0.2, 0.55], "in_love": [0.3, 0.8], "devoted": [0.35, 1.0]}
const FIXED_DEVOTION_SORE := 0.0
## hostility, grudge and profile().enemy by the gravest open sore point (SORE[kind].grave); 0 with none.
const FIXED_HOSTILITY := {1: 15.0, 2: 40.0, 3: 75.0}

# --- Converting a 0.3.1 save (design section 10.1). Read once per record, never again. ---
const CONVERT_HEART := [[400, "devoted"], [150, "in_love"], [30, "crush"], [10, "noticing"]]
const CONVERT_TITLE_HEART := {"dating": "crush", "engaged": "in_love", "married": "devoted"}
const CONVERT_ENEMY_AT := 25
const CONVERT_GRUDGE_AT := 15.0
const SAVE_KEY := "bond"
const SAVE_VERSION := 3

# --- Her prompt and the page ---
## "Lately": how many items. An item leaves only when a newer one pushes it out.
const LATELY := 3
const WHY_MAX := 80
const LOG_KEPT := 12
## Counts in "So far" are written as words up to this; from the next on, "many times".
const COUNT_WORDS := 9
## standing().repair values (design section 4.4): no feeling tag last turn; a strong word without its
## reason; a step with no answer; a yes beside a cold word.
const REPAIRS := ["felt", "why", "us_answer", "us_cold"]
## Per-pony heart notes (design section 3.2a).
const HEART_NOTES := "res://world/relationships/heart_notes.json"
const PACE_KEY := "relationship/pace"

# --- Second look (design section 9) and settings ---
const SECOND_LOOK_KEY := "ai/second_look"
const SECOND_LOOK_VALUES := ["off", "on"]
## min_replies and rate decide when the page warns and when a tag-less reply gets its second look.
## fails: unreadable answers that turn it off for the session. max_chars: the size of its request.
## There is no budget by the minute or the hour on it.
const READER := {"min_replies": 10, "rate": 0.5, "fails": 3, "max_chars": 1800}
## Catalogue entries that are replaced while DYNAMIC is on (the Prompts tab says so).
const RETIRED_PROMPTS := ["pony_impressions.prompt", "director_prompts.relationship_rules"]

## A tag name or argument as a table key.
static func key(raw: String) -> String:
	return raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")

## The listed word a tag argument names: itself, a near word's, or OTHER.
static func word(raw: String) -> String:
	var name := key(raw)
	if name in WORDS: return name
	return str(NEAR.get(name, OTHER))

## The KIND a tag name or argument names, "" when none.
static func kind(raw: String) -> String:
	var name := key(raw)
	if name in KINDS: return name
	return str(KIND_NAMES.get(name, ""))

## "yes", "no", "ask", "refused", or "" when the argument is none of them.
static func answer(raw: String) -> String:
	return str(ANSWERS.get(key(raw), ""))

## The closeness step an argument names, "" when none. "stranger" is never returned.
static func closeness_step(raw: String) -> String:
	var name := key(raw)
	if name in CLOSENESS: return name if name != "stranger" else ""
	return str(CLOSENESS_STEPS.get(name, ""))

## The heart step an argument names, "" when none.
static func heart_step(raw: String) -> String:
	var name := key(raw)
	if name in HEART: return name
	return str(HEART_STEPS.get(name, ""))

static func closeness_rank(step: String) -> int:
	return maxi(0, CLOSENESS.find(step))

static func heart_rank(step: String) -> int:
	return maxi(0, HEART.find(step))

## Wording only: is her heart at what this title would mean? A kind with no entry is always true.
static func title_matches(step_kind: String, heart: String) -> bool:
	if not TITLE_MEANS.has(step_kind): return true
	return heart_rank(heart) >= heart_rank(str(TITLE_MEANS[step_kind]))

## The step above this one on its ladder, "" at the top.
static func next_closeness(step: String) -> String:
	var at := CLOSENESS.find(step)
	return str(CLOSENESS[at + 1]) if at >= 0 and at + 1 < CLOSENESS.size() else ""

static func next_heart(step: String) -> String:
	var at := HEART.find(step)
	return str(HEART[at + 1]) if at >= 0 and at + 1 < HEART.size() else ""

## A count as her prompt says it: "once", "twice", "three times" ... "many times".
static func times(count: int) -> String:
	if count <= 0: return "never"
	if count > COUNT_WORDS: return "many times"
	return ["once", "twice", "three times", "four times", "five times", "six times", "seven times", "eight times", "nine times"][count - 1]

## Time in her company as a phrase.
static func company(seconds: float) -> String:
	for row: Array in COMPANY_WORDS:
		if seconds < float(row[0]): return str(row[1])
	return COMPANY_MOST

## "a moment ago", "a few minutes ago", "earlier today", "yesterday", "3 days ago": the same
## words in her prompt and on the page. Wording only: no rule reads an age.
static func age(played_seconds_ago: float, calendar_days_ago: int) -> String:
	if calendar_days_ago >= 2: return "%d days ago" % calendar_days_ago
	if calendar_days_ago == 1: return "yesterday"
	if played_seconds_ago < 90.0: return "a moment ago"
	if played_seconds_ago < 900.0: return "a few minutes ago"
	return "earlier today"
