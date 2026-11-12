extends RefCounted
## Letters without AI (or after three failed calls): a short reply in her name picked by the
## letter's score, a note she writes on her own (stood up), and rule-based meeting detection
## ("show up tomorrow at town hall at 3:00"). Pure functions; letter_post.gd calls them.
const PLACES := preload("res://world/navigation/place_directory.gd")
const LETTER_TEXT := preload("res://world/letters/letter_text.gd")
const MEET_TIME := preload("res://world/life/appointments/meet_time.gd")
## Three per tier; {me} is her name, {you} the name he signed with.
const REPLIES := {
	"warm": [
		"Thank you so much for your letter! It really made my day, and I have read it twice already. It means a lot that you thought of me. Write again soon, and come and say hello when you are near.",
		"What a lovely surprise when Derpy brought your letter! I smiled the whole morning. You are a wonderful friend, and I am so glad you are here in Ponyville.",
		"Your letter was so sweet that I kept it on my desk. Thank you for writing to me. I can't wait to see you again!"],
	"neutral": [
		"Thank you for your letter. It was nice to hear from you. I hope things are going well for you in Ponyville.",
		"I got your letter this morning. Thanks for thinking of me! Let's talk more when we see each other.",
		"Derpy brought your letter, and it was good to hear from you. Take care, and say hello next time you pass by."],
	"cool": [
		"I got your letter. I am not quite sure what to make of it, to be honest. Maybe we can talk in person instead.",
		"Thank you for writing, I suppose. Next time, maybe put a little more thought into it.",
		"I read your letter. It was a bit hard to follow. If there is something you want to tell me, just come and say it."]}
const NOTES := {
	"annoyed": [
		"I waited for you like we agreed, and you never came. I hope you had a good reason. Next time, please tell me if you can't make it.",
		"I was there at the time we agreed and waited, but you didn't show up. That wasn't very nice. I'd like to hear why."],
	"sad": [
		"I was a little sad today and thought of you. I hope you are well.",
		"Things have been a bit grey lately. A letter from you would cheer me up."],
	"happy": [
		"I just wanted to write and say I am glad you are here. Have a wonderful day!",
		"I was thinking about you today and it made me smile. See you soon!"]}
const CLOSINGS := {"warm": "Love,", "neutral": "Your friend,", "cool": "From,"}
const MEET_VERBS := "\\b(meet|meeting|come|show up|see you)\\b"
## Words that name no particular place by themselves.
const GENERIC_PLACE := ["house", "home", "place", "there", "here", "front", "outside", "door"]

static func tier(score: int) -> String:
	return "warm" if score >= 70 else ("neutral" if score >= 40 else "cool")

## Her reply letter, "Dear <his name>," to her signature; `extra` is a sentence put before the
## closing (a confirmed meeting).
static func reply(her_name: String, his_name: String, score: int, seed: String, extra := "") -> String:
	var t := tier(score)
	var options: Array = REPLIES[t]
	var body: String = options[_roll(seed, options.size())]
	if not extra.is_empty(): body += " " + extra
	return "Dear %s,\n%s\n%s\n%s" % [his_name if not his_name.is_empty() else "Anon", body, CLOSINGS[t], her_name]

## A note she writes on her own, in `mood` (annoyed, sad, happy; anything else reads neutral).
static func note(her_name: String, mood: String, seed: String) -> String:
	var options: Array = NOTES.get(mood, REPLIES.neutral)
	var body: String = options[_roll(seed, options.size())]
	return "Dear Anon,\n%s\n%s\n%s" % [body, "Love," if mood == "happy" else "From,", her_name]

## {"place", "day", "time"} when the clean letter asks to meet with a day, a time and a place
## from `places` ([{id, label}]); {} otherwise. Day as written ("tomorrow", "in 2 days"), time "HH:MM".
static func detect_meet(text: String, places: Array) -> Dictionary:
	var lower := LETTER_TEXT.clean(text).to_lower().replace("’", "'")
	if _regex(MEET_VERBS).search(lower) == null: return {}
	var day := MEET_TIME.find_day(lower)
	var time := _time(lower, day)
	if day.is_empty() or time.is_empty(): return {}
	var place := find_place(lower, places)
	if place.is_empty(): return {}
	return {"place": place, "day": day, "time": time}

## M-AI-18: the letter asks her to come to him now ("please come", "come see me", "come over",
## "come find me", "I need you here"), with no day or time named (that is a meeting).
const COME_ASK := "\\b(please come|come (see|find|visit|over|here|quick|right away|now|to me|and see)|can you come|could you come|would you come|i need you here|come as soon)\\b"
static func asks_to_come(text: String) -> bool:
	var lower := LETTER_TEXT.clean(text).to_lower().replace("’", "'")
	if _regex(COME_ASK).search(lower) == null: return false
	return MEET_TIME.find_day(lower).is_empty() or _time(lower).is_empty()

## The listed place a free-form letter names after at/to/by/near ("at town hall at 3"), or "".
## "your house" is her home and "my house" Anon's.
static func find_place(lower: String, places: Array) -> String:
	var ids: Array = []
	var labels := {}
	var her_home := ""
	var his_home := ""
	for p: Dictionary in places:
		ids.append(str(p.id)); labels[str(p.id)] = str(p.get("label", ""))
		if bool(p.get("her_home", false)): her_home = str(p.id)
		if bool(p.get("player_home", false)): his_home = str(p.id)
	if not her_home.is_empty() and _regex("\\byour (house|home|place)\\b").search(lower) != null: return her_home
	if not his_home.is_empty() and _regex("\\bmy (house|home|place)\\b").search(lower) != null: return his_home
	for found: RegExMatch in _regex("\\b(?:at|to|by|near|outside|in front of)\\s+((?:the\\s+)?[a-z'][a-z' -]{1,48})").search_all(lower):
		var words: Array = Array(found.get_string(1).split(" ", false))
		# Stop at the next preposition or time word ("town hall at 3").
		for i in words.size():
			if str(words[i]) in ["at", "on", "to", "tomorrow", "today", "tonight", "and", "around", "about", "noon", "in", "by"]:
				words = words.slice(0, i); break
		while not words.is_empty():
			var phrase := " ".join(words)
			var meaningful := PLACES.name_words(phrase)
			var named := false
			for word: String in meaningful:
				if word not in GENERIC_PLACE: named = true
			if named:
				var id := PLACES.match_name(phrase, ids, labels)
				if not id.is_empty(): return id
			words.pop_back()
	return ""

## "15:00" for the first clock time in the letter (meet_time.gd forms), or "". "tonight at 8" and
## "tomorrow evening at 8" are 20:00.
static func _time(lower: String, day := "") -> String:
	var raw := MEET_TIME.find_time(lower)
	var hour := MEET_TIME.hour_of(raw) if not raw.is_empty() else -1.0
	if hour < 0.0: return ""
	var evening := _regex("\\b(?:this|today|tomorrow)\\s+(?:evening|night)\\b").search(lower)
	hour = MEET_TIME.evening(hour, "%s %s %s" % [raw, day, evening.get_string() if evening != null else ""])
	return MEET_TIME.clock_text(hour)

## "3", "3:30" or "noon" for a confirmation sentence.
static func spoken_time(hour: float) -> String:
	var h := int(floorf(hour))
	var m := roundi((hour - h) * 60.0)
	if h == 12 and m == 0: return "noon"
	var twelve := h % 12
	if twelve == 0: twelve = 12
	return str(twelve) if m == 0 else "%d:%02d" % [twelve, m]

## Day words for the confirmation: "today", "tomorrow" or "on day N".
static func spoken_day(day: int, today: int) -> String:
	if day == today: return "today"
	if day == today + 1: return "tomorrow"
	return "on day %d" % day

static func _roll(seed: String, count: int) -> int:
	return absi(hash(seed)) % maxi(1, count)

static func _regex(pattern: String) -> RegEx:
	var r := RegEx.new()
	r.compile(pattern)
	return r
