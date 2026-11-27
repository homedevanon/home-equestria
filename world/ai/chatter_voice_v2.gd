extends RefCounted
## The old Ponese voice (version 2, 2026-10-14 to 2026-11-02), brought back unchanged for the
## ponies the player switches to it under Settings > Audio > Old voices (player card 66, 2026-11-20).
## chatter_voice.gd hands such a pony here; everyone else keeps the version 3 voice. This is the
## archived script (private archive/ponese-v2-2026-11-02/) with only the bank folder
## moved to world/audio/ponese/v2/. The removed Ponese style setting reads as "syllables".
##
## Ponese: the ponies' local gibberish speech (dev named it, 2026-10-14). Preparation on the
## main thread, composition on a worker. Banks are real pony voices from
## world/audio/ponese/v2/manifest.json (tools/ponese/build_ponese_banks.py in the private root):
## syllable grains for the default style, and the 26 letter names for the "letters" style
## ("treat" -> tee, arr, ee, ay, tee, very fast). Named ponies use their own voice; everyone
## else draws a stable voice (bank, pitch, intonation, pace, tone) from id, sex and age.
const MANIFEST := "res://world/audio/ponese/v2/manifest.json"
const STYLE_SETTING := "voice/ponese_style"
const STYLES := ["syllables", "letters"]
const MANE_SIX := ["applejack", "fluttershy", "pinkie_pie", "rainbow_dash", "rarity", "twilight_sparkle"]
## Base pitch per kind of pony; ponese sits a little above the speaking voice.
const KIND_PITCH := {"mare": 1.12, "filly": 1.14, "stallion": 1.02, "colt": 1.1}
## Rhubarb mouth shapes for grain vowels and letter names.
const VOWEL_MOUTH := {"IY": "B", "EH": "C", "AE": "C", "EY": "C", "AA": "D", "AH": "D", "AY": "D", "AR": "D",
	"OW": "E", "ER": "E", "UW": "F", "YU": "F"}
const LETTER_MOUTH := {"a": "C", "b": "B", "c": "B", "d": "B", "e": "B", "f": "C", "g": "B", "h": "C", "i": "D",
	"j": "C", "k": "C", "l": "C", "m": "C", "n": "C", "o": "E", "p": "B", "q": "F", "r": "D", "s": "C", "t": "B",
	"u": "F", "v": "B", "w": "F", "x": "C", "y": "D", "z": "B"}
## Digits speak the first letter of their name.
const DIGIT_LETTERS := {"0": "z", "1": "o", "2": "t", "3": "t", "4": "f", "5": "f", "6": "s", "7": "s", "8": "e", "9": "n"}
## Letter style plays each name a touch faster than recorded (the classic chirp).
const LETTER_SPEED := 1.12
## Syllable style 20% quicker without raising the pitch (dev 2026-10-15): each grain is cut to
## 1/SYLLABLE_SPEED of its length and the gaps between them shrink the same.
const SYLLABLE_SPEED := 1.2
const MAX_LETTERS := 360
static var _manifest: Dictionary = {}
var _cache: Dictionary = {}

static func manifest() -> Dictionary:
	if _manifest.is_empty() and FileAccess.file_exists(MANIFEST):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if data is Dictionary and int((data as Dictionary).get("version", 0)) == 2: _manifest = data
	return _manifest

## "animalese" was this voice's old name in configs and profiles.
static func normalize_mode(mode: String) -> String:
	return "ponese" if mode == "animalese" else mode

static func is_ponese_mode(mode: String) -> bool:
	return normalize_mode(mode) == "ponese"

## mare, stallion, filly or colt: the profile's own fields first, then the roster kinds.
static func pony_kind(profile: Dictionary) -> String:
	var kind := str(profile.get("ponese_kind", ""))
	if kind in KIND_PITCH: return kind
	var stallion: bool = bool(profile.get("stallion", false)) or str(profile.get("sex", "")) == "stallion"
	var young: bool = bool(profile.get("filly", false)) or str(profile.get("age", "")) in ["filly", "foal", "young"]
	if profile.has("stallion") or profile.has("sex") or profile.has("filly") or profile.has("age"):
		return ("colt" if stallion else "filly") if young else ("stallion" if stallion else "mare")
	var known: Variant = manifest().get("kinds", {}).get(str(profile.get("id", "")), "mare")
	return str(known) if str(known) in KIND_PITCH else "mare"

## Stable per-pony voice: bank, base pitch, intonation range, pace and tone.
static func identity_voice(profile: Dictionary) -> Dictionary:
	var id := str(profile.get("id", "background"))
	var seed_value := stable_hash(id)
	var data := manifest()
	var banks: Dictionary = data.get("banks", {})
	var kind := pony_kind(profile)
	var bank := str(profile.get("ponese_bank", profile.get("chatter_bank", "")))
	var own := banks.has(bank)
	if not own:
		bank = str(data.get("assign", {}).get(id, ""))
		own = banks.has(bank)
	if not own:
		var pools: Dictionary = data.get("pools", {})
		var pool: Array = pools.get(kind, [])
		if pool.is_empty(): pool = pools.get("stallion" if kind == "colt" else "mare", [])
		bank = str(pool[seed_value % pool.size()]) if not pool.is_empty() else ""
	var bank_kind := str(banks.get(bank, {}).get("kind", kind))
	var pitch: float = KIND_PITCH[kind]
	# A filly on a grown-up bank speaks higher; a mare on a filly bank a touch lower.
	if kind in ["filly", "colt"] and bank_kind in ["mare", "stallion"]: pitch *= 1.08
	elif kind in ["mare", "stallion"] and bank_kind in ["filly", "colt"]: pitch *= .94
	# Own show voices stay close to themselves; pool voices spread wider so neighbours differ.
	var spread := .025 if own else .075
	pitch *= 1.0 + spread * (_unit(seed_value, 1) * 2.0 - 1.0)
	pitch *= clampf(float(profile.get("ponese_pitch", 1.0)), .7, 1.4)
	var pace := lerpf(.92, 1.12, _unit(seed_value, 2)) * clampf(float(profile.get("chatter_pace", 1.0)), .7, 1.35)
	if kind in ["filly", "colt"]: pace *= 1.06
	elif kind == "stallion": pace *= .96
	var tone := 0.0 if own else lerpf(-.5, .5, _unit(seed_value, 3))
	var intonation := lerpf(.03, .1, _unit(seed_value, 4)) + (.02 if kind in ["filly", "colt"] else 0.0)
	return {"bank": bank, "kind": kind, "own": own, "pitch": clampf(pitch, .7, 1.5), "range": intonation,
		"pace": clampf(pace, .7, 1.4), "tone": tone, "seed": seed_value}

static func _unit(seed_value: int, salt: int) -> float:
	return float(stable_hash("%d/%d" % [seed_value, salt]) % 10007) / 10006.0

static func stable_hash(value: String) -> int:
	var h := 5381
	for byte in value.to_utf8_buffer(): h = (h * 33 + byte) & 0x7fffffff
	return h

static func use_chatter(profile: Dictionary, mode := "auto") -> bool:
	var choice := normalize_mode(str(profile.get("voice_mode", mode)))
	if choice == "ponese": return true
	if choice == "tts": return false
	return int(profile.get("tts_speaker_id", -1)) < 0 or str(profile.get("voice_status", "")).begins_with("temporary shared")

## The player's chosen style (Settings > Audio > Ponese style); a profile may pin its own.
static func current_style(profile: Dictionary = {}) -> String:
	var pinned := str(profile.get("ponese_style", ""))
	if pinned in STYLES: return pinned
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null else null
	if settings != null and settings.has_method("get_value"):
		var value := str(settings.get_value(STYLE_SETTING))
		if value in STYLES: return value
	return STYLES[0]

func prepare(profile: Dictionary) -> Dictionary:
	var data := manifest()
	if data.is_empty(): return {"error":"missing ponese manifest"}
	var voice := identity_voice(profile)
	var bank: Dictionary = data.get("banks", {}).get(voice.bank, {})
	if bank.is_empty(): return {"error":"missing ponese bank " + str(voice.bank)}
	if not _cache.has(voice.bank):
		var bytes := FileAccess.get_file_as_bytes(str(bank.pcm))
		if bytes.size() != int(bank.bytes): return {"error":"invalid ponese PCM " + str(voice.bank)}
		var by_vowel: Dictionary = {}
		var grains: Array = bank.grains
		for index in grains.size():
			var vowel := str(grains[index].get("vowel", ""))
			if not by_vowel.has(vowel): by_vowel[vowel] = []
			by_vowel[vowel].append(index)
		_cache[voice.bank] = {"data": bytes, "by_vowel": by_vowel}
	var cached: Dictionary = _cache[voice.bank]
	voice["data"] = cached.data
	voice["by_vowel"] = cached.by_vowel
	voice["grains"] = bank.grains
	voice["letters"] = bank.get("letters", {})
	voice["rate"] = int(data.get("rate", 16000))
	voice["style"] = current_style(profile)
	return voice

## Composes on a worker thread: pure data in, PCM and mouth cues out.
static func compose(text: String, voice: Dictionary, emotion := "neutral", variation := 0) -> Dictionary:
	var started := Time.get_ticks_usec()
	if voice.has("error"): return voice
	var clean := text.strip_edges()
	if clean.begins_with("[") and clean.find("]") < 24:
		var end := clean.find("]")
		if end >= 0:
			emotion = clean.substr(1, end - 1)
			clean = clean.substr(end + 1).strip_edges()
	if clean.length() > 1200: return {"error":"ponese line exceeds 1200 characters"}
	var token_regex := RegEx.new()
	token_regex.compile("[\\p{L}\\p{N}'’]+|[.,!?;:\\n]")
	var tokens := token_regex.search_all(clean)
	if tokens.is_empty(): return {"error":"empty ponese line"}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(voice.seed) + stable_hash(clean) + variation * 7919
	var line := {"pcm": PackedByteArray(), "cues": [], "word_cues": [], "rate": int(voice.get("rate", 16000)),
		"raw": voice.data, "gain": .65 if emotion == "whispering" else (1.1 if emotion in ["angry", "shouting"] else 1.0),
		"tone": clampf(float(voice.get("tone", 0.0)) - (.4 if emotion == "whispering" else 0.0), -.8, .7), "lp": 0.0}
	var pace: float = voice.pace
	var pitch: float = voice.pitch
	if emotion in ["happy", "surprised"]:
		pace *= 1.08
		pitch *= 1.04
	if emotion in ["calm", "sad", "whispering"]: pace *= .92
	if emotion == "sad": pitch *= .96
	var letters_style := str(voice.get("style", "syllables")) == "letters" and not (voice.get("letters", {}) as Dictionary).is_empty()
	var letter_cap := 99
	if letters_style:
		var total := 0
		var words := 0
		for token in tokens:
			if token.get_string() not in [".", ",", "!", "?", ";", ":", "\n"]:
				total += token.get_string().length(); words += 1
		if total > MAX_LETTERS: letter_cap = maxi(2, int(MAX_LETTERS / maxi(1, words)))
	else:
		# Long lines still include every word; cap work/buffer at 45 seconds.
		pace *= maxf(1.0, clean.length() / 450.0)
	var spread: float = voice.get("range", .06)
	_silence(line, .035)
	var spoken := 0
	for token_index in tokens.size():
		var word := tokens[token_index].get_string()
		if word in [".", ",", "!", "?", ";", ":", "\n"]:
			if not line.word_cues.is_empty(): line.word_cues[-1].end_char = tokens[token_index].get_end()
			_silence(line, (.24 if word in [".", "!", "?"] else .12) / pace)
			continue
		spoken += 1
		line.word_cues.append({"start": float(line.pcm.size() / 2) / line.rate, "end_char": tokens[token_index].get_end()})
		var next := tokens[token_index + 1].get_string() if token_index + 1 < tokens.size() else ""
		# Gentle fall across the sentence, a lift on exclamations, a rise into questions.
		var progress := float(token_index) / maxf(1.0, tokens.size() - 1.0)
		var word_pitch := pitch * (1.0 + spread * rng.randf_range(-1.0, 1.0)) * (1.0 - .05 * progress)
		if next == "!": word_pitch *= 1.0 + spread
		var contour := {"question": next == "?", "final": next in [".", "!", ""], "spread": spread}
		if letters_style: _say_letters(line, word, voice, word_pitch, pace, contour, rng, letter_cap)
		else: _say_syllables(line, word, voice, word_pitch, pace, contour, rng)
		_silence(line, rng.randf_range(.045, .08) / pace)
		if line.pcm.size() > line.rate * 2 * 45: return {"error":"ponese duration budget exceeded"}
	if spoken == 0: return {"error":"no spoken words"}
	_silence(line, .08)
	return {"pcm": line.pcm, "cues": line.cues, "word_cues": line.word_cues, "rate": line.rate, "bank": voice.bank,
		"style": "letters" if letters_style else "syllables", "words": spoken, "build_usec": Time.get_ticks_usec() - started}

## Default style: one grain per spelled syllable, matched to its vowel; the same word keeps
## much the same sounds, so repeated words read as words.
static func _say_syllables(line: Dictionary, word: String, voice: Dictionary, word_pitch: float, pace: float, contour: Dictionary, rng: RandomNumberGenerator) -> void:
	var vowels := spelled_vowels(word)
	var grains: Array = voice.grains
	var by_vowel: Dictionary = voice.get("by_vowel", {})
	var key := stable_hash(word.to_lower())
	for s in vowels.size():
		var choices: Array = by_vowel.get(vowels[s], [])
		var selected: int
		if choices.size() >= 2: selected = int(choices[(key + s * 7 + rng.randi_range(0, 2)) % choices.size()])
		else: selected = (key + s * 7 + rng.randi_range(0, 3)) % grains.size()
		var grain: Dictionary = grains[selected]
		var p := word_pitch * (1.0 + float(contour.spread) * .3 * rng.randf_range(-1.0, 1.0))
		if contour.question: p *= lerpf(1.0, 1.14, (s + 1.0) / vowels.size())
		elif contour.final and s == vowels.size() - 1: p *= .95
		var mouth := str(VOWEL_MOUTH.get(str(grain.get("vowel", "")), ["C", "E", "F", "D"][selected % 4]))
		_render(line, int(grain.offset), maxi(2, int(float(grain.frames) / SYLLABLE_SPEED)), p * pace, mouth)
		_silence(line, rng.randf_range(.012, .022) / pace / SYLLABLE_SPEED)

## Letter style: every letter of the word as its spoken name, back to back.
static func _say_letters(line: Dictionary, word: String, voice: Dictionary, word_pitch: float, pace: float, contour: Dictionary, rng: RandomNumberGenerator, cap: int) -> void:
	var letters: Dictionary = voice.letters
	var names: Array[String] = []
	for ch in word.to_lower():
		var letter: String = DIGIT_LETTERS.get(ch, ch)
		if letters.has(letter): names.append(letter)
		if names.size() >= cap: break
	if names.is_empty():
		_say_syllables(line, word, voice, word_pitch, pace, contour, rng)
		return
	for i in names.size():
		var clip: Dictionary = letters[names[i]]
		var p := word_pitch * (1.0 + float(contour.spread) * .5 * rng.randf_range(-1.0, 1.0))
		if contour.question: p *= lerpf(1.0, 1.16, (i + 1.0) / names.size())
		elif contour.final and i == names.size() - 1: p *= .95
		_render(line, int(clip.offset), int(clip.frames), p * pace * LETTER_SPEED, str(LETTER_MOUTH.get(names[i], "C")))
		_silence(line, rng.randf_range(.0, .008) / pace)

## Vowel class of each spelled syllable, read from the letters ("tree" -> IY, "go" -> OW).
static func spelled_vowels(word: String) -> Array[String]:
	var lower := word.to_lower()
	var groups := RegEx.create_from_string("[aeiouy]+r?").search_all(lower)
	var out: Array[String] = []
	for index in groups.size():
		var group := groups[index].get_string()
		var start := groups[index].get_start()
		var end := groups[index].get_end()
		# A silent final "e" is not its own syllable; a leading "y" is a consonant.
		if group == "e" and start == lower.length() - 1 and index > 0: continue
		if start == 0 and group.length() > 1 and group.begins_with("y"): group = group.substr(1)
		# Open syllables and vowel-consonant-e ("make", "home") say the letter's long name.
		var long := end >= lower.length() or (lower.ends_with("e") and end == lower.length() - 2 and index < groups.size() - 1)
		out.append(_group_vowel(group, long))
	if out.is_empty(): out.append("AH")
	return out.slice(0, 7)

static func _group_vowel(group: String, at_end: bool) -> String:
	var body := group.trim_suffix("r")
	if group.ends_with("r") and body in ["a"]: return "AR"
	if group.ends_with("r") and body in ["e", "i", "u", "ea", "ou"]: return "ER"
	match body:
		"ee", "ea", "ie", "ei", "ey": return "IY"
		"ai", "ay": return "EY"
		"oo", "ew", "ue", "ui": return "UW"
		"oa", "oe", "ow": return "OW"
		"ou": return "UW" if at_end else "AA"
		"oi", "oy", "igh": return "AY"
		"y": return "IY" if at_end else "AY"
		"a": return "EY" if at_end else "AE"
		"e": return "IY" if at_end else "EH"
		"i": return "AY" if at_end else "EH"
		"o": return "OW" if at_end else "AA"
		"u": return "UW" if at_end else "AH"
	return "AH"

## Resample one clip into the line at `rate` (pitch and speed together), with the voice's tone.
static func _render(line: Dictionary, offset: int, count: int, rate: float, mouth: String) -> void:
	var raw: PackedByteArray = line.raw
	# Take the buffer out of the dictionary so growing it never copies the whole line.
	var pcm: PackedByteArray = line.pcm
	line.pcm = PackedByteArray()
	var length := maxi(2, int(count / maxf(rate, .1)))
	var start := pcm.size() / 2
	pcm.resize(pcm.size() + length * 2)
	var gain: float = line.gain
	var tone: float = line.tone
	var lp: float = line.lp
	for j in length:
		var at := j * float(count - 1) / maxi(1, length - 1)
		var a := int(at)
		var sample := lerpf(raw.decode_s16((offset + a) * 2), raw.decode_s16((offset + mini(a + 1, count - 1)) * 2), at - a)
		# One-pole split: tone < 0 darkens toward the low band, tone > 0 lifts the highs.
		lp += .42 * (sample - lp)
		sample = lp + (1.0 + tone) * (sample - lp)
		pcm.encode_s16((start + j) * 2, int(clampf(sample * gain, -30000, 30000)))
	line.lp = lp
	line.pcm = pcm
	line.cues.append({"start": float(start) / line.rate, "end": float(start + length) / line.rate, "value": mouth})

static func _silence(line: Dictionary, seconds: float) -> void:
	var pcm: PackedByteArray = line.pcm
	line.pcm = PackedByteArray()
	var start := pcm.size() / 2
	var count := maxi(1, int(seconds * line.rate))
	# PackedByteArray resize initializes newly allocated bytes to zero.
	pcm.resize(pcm.size() + count * 2)
	line.pcm = pcm
	line.cues.append({"start": float(start) / line.rate, "end": float(start + count) / line.rate, "value": "X"})
