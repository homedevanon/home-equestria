extends RefCounted
## Ponese: the ponies' local gibberish speech (dev named it, 2026-10-14; v3 rebuilt 2026-11-02,
## docs/PONESE_V3_2026_11_02.md). Each pony says real syllables of her own show voice: banks in
## world/audio/ponese/v3 (private root tools/ponese/build_ponese_v3.py) hold every speaker's
## syllables as vocoder frames, and the native PonyPoneseVoice picks, makes and joins them with
## her own melody, real word endings and a soft voice chain. Named ponies use their own voice;
## everyone else draws a stable pool voice of their kind, raised a little in pitch and/or vocal
## tract (never lowered) so neighbours differ. Preparation on the main thread, composition on a
## worker.
const MANIFEST := "res://world/audio/ponese/v3/manifest.json"
const NATIVE_CLASS := "PonyPoneseVoice"
## One style since v3; the old "letters" setting reads as this.
const STYLES := ["syllables"]
const KINDS := ["mare", "filly", "stallion", "colt"]
## Native voices kept loaded (each holds its bank and its made syllables).
const MAX_LOADED := 16
static var _manifest: Dictionary = {}
var _voices: Dictionary = {}
var _order: Array[String] = []

static func manifest() -> Dictionary:
	if _manifest.is_empty() and FileAccess.file_exists(MANIFEST):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if data is Dictionary and int((data as Dictionary).get("version", 0)) == 3: _manifest = data
	return _manifest

## "animalese" was this voice's old name in configs and profiles.
static func normalize_mode(mode: String) -> String:
	return "ponese" if mode == "animalese" else mode

static func is_ponese_mode(mode: String) -> bool:
	return normalize_mode(mode) == "ponese"

## mare, stallion, filly or colt: the profile's own fields first, then the known kinds.
static func pony_kind(profile: Dictionary) -> String:
	var kind := str(profile.get("ponese_kind", ""))
	if kind in KINDS: return kind
	var stallion: bool = bool(profile.get("stallion", false)) or str(profile.get("sex", "")) == "stallion"
	var young: bool = bool(profile.get("filly", false)) or str(profile.get("age", "")) in ["filly", "foal", "young"]
	if profile.has("stallion") or profile.has("sex") or profile.has("filly") or profile.has("age"):
		return ("colt" if stallion else "filly") if young else ("stallion" if stallion else "mare")
	var known: Variant = manifest().get("kinds", {}).get(str(profile.get("id", "")), "mare")
	return str(known) if str(known) in KINDS else "mare"

## Stable per-pony voice: bank, pitch and formant (vocal tract) scale, pace.
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
	var pitch := 1.0
	var formant := 1.0
	var pace := 1.0
	if not own:
		# Pool voices: up to 8 % higher and up to 5 % smaller, never deeper than the speaker.
		pitch = 1.0 + .08 * _unit(seed_value, 1)
		formant = lerpf(.99, 1.05, _unit(seed_value, 3))
		pace = lerpf(.94, 1.08, _unit(seed_value, 2))
	# A filly or colt on a grown-up voice speaks higher and smaller.
	if kind in ["filly", "colt"] and bank_kind in ["mare", "stallion"]:
		pitch *= 1.1
		formant *= 1.06
		pace *= 1.04
	pitch *= clampf(float(profile.get("ponese_pitch", 1.0)), 1.0, 1.4)
	pace *= clampf(float(profile.get("chatter_pace", 1.0)), .7, 1.35)
	return {"bank": bank, "kind": kind, "own": own, "pitch": snappedf(clampf(pitch, 1.0, 1.5), .001),
		"formant": snappedf(clampf(formant, .95, 1.15), .001), "pace": clampf(pace, .7, 1.4), "seed": seed_value}

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

static func current_style(_profile: Dictionary = {}) -> String:
	return STYLES[0]

func prepare(profile: Dictionary) -> Dictionary:
	var data := manifest()
	if data.is_empty(): return {"error":"missing ponese manifest"}
	if not ClassDB.class_exists(NATIVE_CLASS): return {"error":"ponese voice library missing"}
	var voice := identity_voice(profile)
	var bank: Dictionary = data.get("banks", {}).get(voice.bank, {})
	if bank.is_empty(): return {"error":"missing ponese bank " + str(voice.bank)}
	var key := "%s|%.3f|%.3f" % [voice.bank, voice.pitch, voice.formant]
	if not _voices.has(key):
		var bytes := FileAccess.get_file_as_bytes(str(bank.data))
		if bytes.size() != int(bank.bytes): return {"error":"invalid ponese bank " + str(voice.bank)}
		var native: RefCounted = ClassDB.instantiate(NATIVE_CLASS)
		if not native.call("load_bank", bytes, int(data.get("fft", 1024))): return {"error":"unreadable ponese bank " + str(voice.bank)}
		native.call("set_shape", float(voice.pitch), float(voice.formant))
		_voices[key] = native
		_order.append(key)
		# A line being composed keeps its voice alive through the dictionary it was given.
		while _order.size() > MAX_LOADED: _voices.erase(_order.pop_front())
	else:
		_order.erase(key)
		_order.append(key)
	voice["native"] = _voices[key]
	voice["style"] = STYLES[0]
	voice["syllables"] = syllable_share()
	return voice

## Settings > Audio > Ponese syllables as a share (0.25-1): how many of a word's syllables she
## says. Read here on the main thread; compose() runs on a worker.
static func syllable_share() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null else null
	if settings == null: return 1.0
	var percent: Variant = settings.call("get_value", "voice/ponese_syllables")
	return clampf(float(percent) / 100.0, .25, 1.0) if percent is int or percent is float else 1.0

## Composes on a worker thread: text in, 24 kHz PCM, mouth cues and word cues out.
static func compose(text: String, voice: Dictionary, emotion := "neutral", variation := 0) -> Dictionary:
	if voice.has("error"): return voice
	var clean := text.strip_edges()
	if clean.begins_with("[") and clean.find("]") < 24:
		var end := clean.find("]")
		if end >= 0:
			emotion = clean.substr(1, end - 1)
			clean = clean.substr(end + 1).strip_edges()
	if clean.length() > 1200: return {"error":"ponese line exceeds 1200 characters"}
	var native: RefCounted = voice.get("native")
	if native == null: return {"error":"ponese voice not prepared"}
	emotion = emotion.to_lower()
	var gain := .65 if emotion == "whispering" else (1.1 if emotion in ["angry", "shouting"] else 1.0)
	var pace := float(voice.get("pace", 1.0)) * (1.06 if emotion in ["happy", "surprised", "excited"] else (.94 if emotion in ["calm", "sad", "whispering"] else 1.0))
	# Fewer syllables (Settings > Audio > Ponese syllables) say the same words in fewer sounds.
	var syllables := clampf(float(voice.get("syllables", 1.0)), .25, 1.0)
	# Long lines still include every word; the native voice stops at 45 seconds.
	pace *= maxf(1.0, clean.length() * syllables / 450.0)
	var result: Dictionary = native.call("compose", clean, {"emotion": emotion, "variation": variation, "pace": pace, "gain": gain, "syllables": syllables})
	if result.has("error"): return result
	result["bank"] = voice.bank
	result["style"] = STYLES[0]
	return result
