extends Node
const CAPTURE := preload("res://world/ai/ai_capture.gd")
## Renders a line to a WAV in user://tts/ and hands the path over:
## `synthesize(text, speaker_id, emotion, on_done)`, `on_done(path, error)`.
## Providers (ai_config "tts/provider"): "moss" = moss-tts POST /tts (reads inline
## [emotion] tags itself), "remote" = the same through tools/ai/tts_proxy.py, "gradio" =
## a MOSS-TTS-PNY Gradio host called directly, "openai" = any OpenAI-compatible
## /audio/speech endpoint, "none" = no server (every voice is local ponese).
## Failures fall back to ponese in `synthesize_profile`.
##
## Streamed speech (2026-11-10, from the breeze-tts-pny mod by nak, MIT): a "moss" server whose
## GET /health answers {"ready": true, "pcm_stream": "framed-v1"} also takes POST <url>/stream and
## sends the line while it renders it (pcm_voice_stream.gd). `synthesize_profile_live` then hands
## the caller a "pcm://utterance/N" name after about 200 ms of sound instead of a WAV path after
## the whole clip; the speaker plays it with pcm_speech_player.gd. A server that reports
## "characters" voices every pony by its profile id ("character_id" in the request), speaker id
## or not. Every other server and every other caller keeps the WAV path.

const EMOTION_IDS := {"neutral": 0, "happy": 1, "sad": 2, "angry": 3, "annoyed": 4,
	"fearful": 5, "surprised": 6, "calm": 7, "disgusted": 8, "whispering": 9, "shouting": 11}
const EMOTION_LABELS := {0: "Neutral", 1: "Happy", 2: "Sad", 3: "Angry", 4: "Annoyed", 5: "Fearful",
	6: "Surprised", 7: "Calm", 8: "Disgusted", 9: "Whispering", 11: "Shouting"}
## moss-tts speaker ids to the Gradio host's dropdown labels (same table as tools/ai/tts_proxy.py).
const SPEAKER_LABELS := {
	0: "T1 - Apple Bloom (0)", 1: "T1 - Applejack (1)", 11: "T1 - Fluttershy (11)", 35: "T1 - Heavy (35)",
	37: "T1 - Merasmus (37)", 17: "T1 - Pinkie (17)", 18: "T1 - Rainbow (18)", 19: "T1 - Rarity (19)",
	20: "T1 - Scootaloo (20)", 41: "T1 - Soldier (41)", 22: "T1 - Spike (22)", 24: "T1 - Starlight (24)",
	27: "T1 - Sweetie Belle (27)", 30: "T1 - Trixie (30)", 31: "T1 - Twilight (31)", 5: "T2 - Celestia (5)",
	7: "T2 - Chrysalis (7)", 33: "T2 - Demo (33)", 10: "T2 - Discord (10)", 34: "T2 - Engineer (34)",
	12: "T2 - Goldie Delicious (12)", 13: "T2 - Granny Smith (13)", 36: "T2 - Medic (36)", 38: "T2 - Pauling (38)",
	39: "T2 - Scout (39)", 40: "T2 - Sniper (40)", 42: "T2 - Spy (42)", 26: "T2 - Sunset Shimmer (26)",
	29: "T2 - Tirek (29)", 2: "T3 - Autumn Blaze (2)", 3: "T3 - Big Mac (3)", 4: "T3 - Cadance (4)",
	6: "T3 - Cheerilee (6)", 8: "T3 - Cozy Glow (8)", 9: "T3 - Diamond Tiara (9)", 14: "T3 - Luna (14)",
	15: "T3 - Maud (15)", 16: "T3 - Mrs. Cake (16)", 21: "T3 - Shining Armor (21)", 23: "T3 - Spitfire (23)",
	25: "T3 - Sunburst (25)", 28: "T3 - Thorax (28)", 32: "T3 - Zecora (32)",
}
const MAX_AUDIO_BYTES := 12 * 1024 * 1024
const DIR := "user://tts"
const CHATTER := preload("res://world/ai/chatter_voice.gd")
const CONTROLS := preload("res://world/ai/speech_controls.gd")
const PCM_STREAM := preload("res://world/ai/pcm_voice_stream.gd")
const UTTERANCE := preload("res://world/ai/pcm_utterance.gd")
const SENTENCES := preload("res://world/ai/speech_sentences.gd")
## The stream capability probe: attempts after start-up or a settings change, with 1/2/4/8/10 s
## between them; afterwards a spoken line asks again at most this often.
const PROBE_ATTEMPTS := 6
const REPROBE_MS := 30000
## Frames buffered before a streamed line starts. A server may ask for more in /health
## ("prebuffer_ms"): one that renders slower than real time, or sits behind a tunnel.
const START_FRAMES := 4800
const MAX_START_FRAMES := 24000 * 4

## Emitted when a streamed line has fully arrived (or failed): the client is free again.
signal live_render_finished

@export var provider := "none"
@export var url := "http://127.0.0.1:8000/tts"
@export var timeout := 60.0
@export var style_strength := 1.0
## Gradio host: called directly by "gradio", passed to the proxy by "remote".
@export var remote_url := ""
@export var gradio_api := "synthesize"
## OpenAI-compatible speech endpoint.
@export var base_url := ""
@export var api_key := ""
@export var model := ""
@export var voice := "alloy"
@export var debug := false

var busy := false
var _request: HTTPRequest
var _on_done: Callable
var _counter := 0
var voice_mode := "ponese"
var chatter_fallback := true
var output_dir := DIR
var _chatter := CHATTER.new()
var _jobs: Array = []
var _generation := 0
var _failure_generation := 0
var _chatter_counter := 0
## Gradio is three requests (call, event stream, file); this names the pending one.
var _stage := ""
var _gradio_call := ""
var _tag_regex := RegEx.create_from_string("\\[[A-Za-z _-]{1,20}\\]")
var _pcm_stream: Node
var _health: HTTPRequest
var _probe_serial := 0
var _probe_attempts := 0
var _probe_ms := -REPROBE_MS
## The url the stream probe succeeded for; "" = no streaming.
var _stream_url := ""
## The streaming server picks voices by character id (it reported "characters").
var _stream_characters := false
var _start_frames := START_FRAMES
var _want_live := false
var _live: RefCounted
var _live_announced := false
var _stream_character := ""


func _ready() -> void:
	_request = HTTPRequest.new()
	_request.name = "TtsRequest"
	_request.timeout = timeout
	_request.body_size_limit = MAX_AUDIO_BYTES
	# Interruptions must not join a worker blocked waiting for audio bytes.
	_request.use_threads = false
	add_child(_request)
	_request.request_completed.connect(_on_completed)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	set_process(false)
	_pcm_stream = PCM_STREAM.new()
	_pcm_stream.name = "PcmStream"
	_pcm_stream.debug = debug
	add_child(_pcm_stream)
	_pcm_stream.response_completed.connect(_on_pcm_completed)
	_pcm_stream.pcm_chunk.connect(_on_pcm_chunk)
	_probe.call_deferred()


func configure(section: Dictionary) -> void:
	voice_mode = CHATTER.normalize_mode(str(section.get("voice_mode", voice_mode)))
	chatter_fallback = bool(section.get("chatter_fallback", true))
	provider = str(section.get("provider", "none"))
	url = String(section.get("url", url))
	remote_url = String(section.get("remote_url", "")).rstrip("/")
	gradio_api = String(section.get("gradio_api", gradio_api))
	base_url = String(section.get("base_url", base_url)).rstrip("/")
	api_key = String(section.get("api_key", ""))
	model = String(section.get("model", model))
	voice = String(section.get("voice", voice))
	if provider == "remote":
		url = String(section.get("proxy_url", "http://127.0.0.1:8791/tts"))
	timeout = float(section.get("timeout", timeout))
	style_strength = float(section.get("style_strength", style_strength))
	if _request != null:
		_request.timeout = timeout
	_set_stream("")
	_probe_attempts = 0
	_probe.call_deferred()


## Asks the "moss" server whether it can send speech while rendering it.
func _probe() -> void:
	_probe_serial += 1
	if is_instance_valid(_health):
		_health.cancel_request(); _health.queue_free(); _health = null
	if not is_inside_tree() or provider != "moss" or not (url.begins_with("http://") or url.begins_with("https://")) or not url.rstrip("/").ends_with("/tts"): return
	_probe_attempts += 1
	_probe_ms = Time.get_ticks_msec()
	_health = HTTPRequest.new(); _health.timeout = 5.0; _health.body_size_limit = 65536
	add_child(_health)
	_health.request_completed.connect(_on_health.bind(url, _probe_serial))
	var error := _health.request(url.rstrip("/").trim_suffix("/tts") + "/health")
	if error != OK: _retry_probe(_probe_serial, error, 0)


func _on_health(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, requested_url: String, serial: int) -> void:
	if serial != _probe_serial or requested_url != url: return
	if result != HTTPRequest.RESULT_SUCCESS or code in [408, 429, 500, 502, 503, 504]:
		_retry_probe(serial, result, code)
		return
	# Any other answer (MOSS has no /health, or one without the stream field): WAV as before.
	if code != 200: return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary or data.get("pcm_stream") != "framed-v1": return
	if not data.get("ready", false):
		_retry_probe(serial, result, code)
		return
	var hint: Variant = data.get("prebuffer_ms", 0)
	_start_frames = clampi(int(hint) * 24, START_FRAMES, MAX_START_FRAMES) if hint is float or hint is int else START_FRAMES
	var characters: Variant = data.get("characters", 0)
	_stream_characters = (characters is float or characters is int) and int(characters) > 0
	_set_stream(url)
	print("[voice] voice server sends speech while rendering it; lines start after %d ms of sound%s" % [
		_start_frames / 24, " (voices by character)" if _stream_characters else ""])


func _retry_probe(serial: int, result: int, code: int) -> void:
	if debug: print("[voice] stream probe attempt %d: result %d, HTTP %d" % [_probe_attempts, result, code])
	if _probe_attempts >= PROBE_ATTEMPTS or not is_inside_tree(): return
	var delay := minf(pow(2.0, _probe_attempts - 1), 10.0)
	await get_tree().create_timer(delay).timeout
	if not is_inside_tree() or serial != _probe_serial or not _stream_url.is_empty(): return
	_probe()


## A server that came up after every probe attempt (a Colab link pasted while the notebook was
## still loading) is found again on a later line.
func _reprobe_if_given_up() -> void:
	if _stream_url.is_empty() and _probe_attempts >= PROBE_ATTEMPTS and Time.get_ticks_msec() - _probe_ms >= REPROBE_MS:
		_probe_attempts = 0
		_probe()


func _set_stream(value: String) -> void:
	_stream_url = value
	if value.is_empty():
		_stream_characters = false
		_start_frames = START_FRAMES
	# With a stream the first sound no longer waits for the clip's end, so one request may carry
	# several short sentences (speech_sentences.gd).
	SENTENCES.note_stream_client(get_instance_id(), can_stream())


## True when lines can be heard while the server is still rendering them.
func can_stream() -> bool:
	return provider == "moss" and not _stream_url.is_empty() and url == _stream_url


## True when a voice server is set up at all; otherwise every pony speaks ponese.
func has_server() -> bool:
	match provider:
		"openai": return base_url != "" and model != ""
		"gradio": return remote_url != ""
		"moss", "remote": return url != ""
	return false


func build_body(text: String, speaker_id: int, emotion: String) -> Dictionary:
	text = voice_text(text)
	var body := {"text": text, "speaker_id": speaker_id, "format": "wav", "trim_silence": true}
	if not text.begins_with("[") and EMOTION_IDS.has(emotion):
		body["style_emotion_id"] = EMOTION_IDS[emotion]
	if style_strength != 1.0:
		body["style_strength"] = style_strength
	if provider == "remote" and remote_url != "":
		body["remote"] = remote_url
	if can_stream() and _stream_characters and not _stream_character.is_empty():
		body["character_id"] = _stream_character
	return body


func synthesize(text: String, speaker_id: int, emotion: String, on_done: Callable, voice_name := "") -> bool:
	if busy:
		return false
	text = voice_text(text)
	if spoken_text(text).is_empty():
		_defer_failure(on_done, "no generated speech to synthesize")
		return true
	if provider in ["gradio", "remote"] and spoken_text(text).length() > 600:
		_defer_failure(on_done, "voice line exceeds 600 characters; split on sentence or word boundaries")
		return true
	if not has_server():
		_defer_failure(on_done, "no voice server configured")
		return true
	busy = true
	_on_done = on_done
	if debug:
		print("[tts] %s speaker %d: %s" % [provider, speaker_id, text])
	var err := OK
	match provider:
		"openai":
			_stage = "wav"
			var body := {"model": model, "input": spoken_text(text), "voice": voice_name if voice_name != "" else voice,
				"response_format": "wav"}
			if model.begins_with("gpt-4o") and EMOTION_IDS.has(_line_emotion(text, emotion)) and _line_emotion(text, emotion) != "neutral":
				body["instructions"] = "Speak in a %s tone." % _line_emotion(text, emotion)
			var headers := PackedStringArray(["Content-Type: application/json"])
			if api_key != "": headers.append("Authorization: Bearer " + api_key)
			err = _dispatch_request(base_url + "/audio/speech", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
		"gradio":
			_stage = "gradio_call"
			_gradio_call = "%s/gradio_api/call/%s" % [remote_url, gradio_api]
			var emotion_id := int(EMOTION_IDS.get(_line_emotion(text, emotion), 0))
			var payload := gradio_body(text, speaker_id, emotion_id)
			err = _dispatch_request(_gradio_call, PackedStringArray(["Content-Type: application/json"]),
				HTTPClient.METHOD_POST, JSON.stringify(payload))
		_:
			_stage = "wav"
			err = _dispatch_request(url, PackedStringArray(["Content-Type: application/json"]),
				HTTPClient.METHOD_POST, JSON.stringify(build_body(text, speaker_id, emotion)))
	if err != OK:
		_defer_failure(on_done, "request error %d" % err)
	return true


## Accepted local errors own the same cancellation boundary as provider audio.
## Defer delivery until synthesis has returned its acceptance to the caller.
func _defer_failure(on_done: Callable, error: String) -> void:
	busy = true
	_on_done = on_done
	_failure_generation += 1
	_deliver_failure.call_deferred(_failure_generation, error)


func _deliver_failure(generation: int, error: String) -> void:
	if generation != _failure_generation or not busy: return
	_finish("", error)

## The director splits long speech on sentence/word boundaries. Never silently clip a word
## here: other callers and unusual long words must either reach the provider whole or fail.
func gradio_body(text: String, speaker_id: int, emotion_id: int) -> Dictionary:
	return {"data": [spoken_text(text), "", "en", SPEAKER_LABELS.get(speaker_id, SPEAKER_LABELS[31]),
		EMOTION_LABELS.get(emotion_id, "Neutral"), 0.5, 0.8, 0.92, 0, 1.05]}


## The line without [emotion]/[face] tags, for servers that would read them aloud.
func spoken_text(text: String) -> String:
	return CONTROLS.sanitize(text)

## MOSS accepts one leading emotion; every other control is stripped at this last boundary.
func voice_text(text: String) -> String:
	var emotion := _line_emotion(text, "")
	var spoken := spoken_text(text)
	if spoken.is_empty(): return ""
	return ("[%s] " % emotion if EMOTION_IDS.has(emotion) else "") + spoken


## A leading [emotion] tag wins over the requested emotion.
func _line_emotion(text: String, emotion: String) -> String:
	var stripped := text.strip_edges()
	if stripped.begins_with("["):
		var tag := stripped.substr(1, stripped.find("]") - 1).strip_edges().to_lower()
		if EMOTION_IDS.has(tag): return tag
	return emotion


func cancel() -> void:
	if busy: _capture("cancel", {})
	_generation += 1
	_failure_generation += 1
	if _live != null:
		_live.cancel_transport = Callable()
		_live.cancel(); _live = null
	if is_instance_valid(_pcm_stream): _pcm_stream.cancel()
	if _request != null: _request.cancel_request()
	busy = false
	_stage = ""
	_on_done = Callable()


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not busy: return
	_capture("response", {"result": result, "http_status": code, "bytes": body.size(),
		"body": "" if _stage == "wav" and code >= 200 and code < 300 else body.get_string_from_utf8()})
	if not _on_done.is_valid():
		_finish("", "")
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish("", "http result %d" % result)
		return
	if code < 200 or code >= 300:
		_finish("", "http %d: %s" % [code, body.get_string_from_utf8().left(200)])
		return
	match _stage:
		"gradio_call":
			var event: Variant = JSON.parse_string(body.get_string_from_utf8())
			var event_id := str(event.get("event_id", "")) if event is Dictionary else ""
			if event_id == "":
				_finish("", "voice host gave no event id")
				return
			_stage = "gradio_events"
			_request_next(_gradio_call + "/" + event_id)
		"gradio_events":
			var audio_url := _gradio_audio_url(body.get_string_from_utf8())
			if audio_url.begins_with("error:"):
				_finish("", audio_url)
				return
			_stage = "wav"
			_request_next(audio_url)
		_:
			_save_wav(body)


func _request_next(next_url: String) -> void:
	var err := _dispatch_request(next_url)
	if err != OK: _finish("", "request error %d" % err)


func _dispatch_request(next_url: String, headers := PackedStringArray(), method := HTTPClient.METHOD_GET, body := "") -> Error:
	_capture("request", {"method": method, "body": body})
	if can_stream() and next_url == url and is_instance_valid(_pcm_stream):
		if _want_live:
			_live = UTTERANCE.new(); _live.cancel_transport = cancel; _live_announced = false
			_live.start_frames = _start_frames
		return _pcm_stream.start(url.rstrip("/") + "/stream", body, timeout)
	return _request.request(next_url, headers, method, body)


## As synthesize_profile, for a caller whose speaker can play a line that is still arriving
## (pcm_speech_player.gd): with a streaming server `on_done` gets a "pcm://utterance/N" name once
## the line's first 200 ms are here. Without one this is synthesize_profile.
func synthesize_profile_live(text: String, profile: Dictionary, emotion: String, on_done: Callable) -> bool:
	if busy: return false
	_want_live = can_stream()
	var accepted := synthesize_profile(text, profile, emotion, on_done)
	_want_live = false
	return accepted


func _on_pcm_chunk(data: PackedByteArray) -> void:
	if _live == null or not busy: return
	_live.pcm.append_array(data)
	# Hand the line over once its start buffer is here: the director gives playback 12 seconds to
	# start after the handoff, but stays in rendering for 90.
	if _live.pcm.size() >= maxi(9600, int(_live.start_frames) * 2): _announce_live()


func _announce_live() -> void:
	if _live == null or _live_announced or not _on_done.is_valid(): return
	_live_announced = true
	var utterance: RefCounted = _live
	var done := _on_done; _on_done = Callable()
	var uri: String = utterance.publish()
	_capture("complete", {"audio_file": uri, "error": ""})
	done.call(uri, "")
	if not utterance.claimed: utterance.cancel()


func _on_pcm_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if _live == null:
		_on_completed(result, code, headers, body); return
	var utterance: RefCounted = _live
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and not utterance.pcm.is_empty():
		utterance.done = true
		_announce_live()
	elif _live_announced:
		# The speaker already has the line: it stops there (pcm_speech_player.gd reports it).
		utterance.error = "transport result %d, HTTP %d" % [result, code]
	else:
		utterance.release(); _live = null
		_on_completed(result, code, headers, body); return
	utterance.release()
	_live = null; _on_done = Callable(); busy = false; _stage = ""
	live_render_finished.emit.call_deferred()


## Gradio's server-sent events: the "complete" event's data is the output list; its first
## entry is the audio file. Only a file on the configured host is followed.
func _gradio_audio_url(stream: String) -> String:
	var current := ""
	for raw in stream.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("event:"):
			current = line.substr(6).strip_edges()
		elif line.begins_with("data:") and current in ["complete", "error"]:
			if current == "error": return "error: voice host error " + line.substr(5).strip_edges().left(200)
			var outputs: Variant = JSON.parse_string(line.substr(5).strip_edges())
			var audio: Variant = outputs[0] if outputs is Array and not outputs.is_empty() else null
			if not audio is Dictionary: return "error: voice host returned no audio"
			var file_url := str(audio.url) if audio.get("url") is String else ""
			if file_url == "": file_url = "%s/gradio_api/file=%s" % [remote_url, str(audio.get("path", "")).uri_encode().replace("%2F", "/")]
			if not file_url.begins_with(remote_url): return "error: voice host audio url off-host, refused"
			return file_url
	return "error: voice host stream ended without audio"


func _save_wav(body: PackedByteArray) -> void:
	if body.size() < 44 or body.slice(0, 4).get_string_from_ascii() != "RIFF" or body.slice(8, 12).get_string_from_ascii() != "WAVE":
		_finish("", "not a wav (%d bytes)" % body.size())
		return
	body = fix_wav_sizes(body)
	_counter += 1
	var path := "%s/line_%03d.wav" % [output_dir, _counter % 40]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_finish("", "cannot write " + path)
		return
	file.store_buffer(body)
	file.close()
	_finish(path, "")


func _finish(path: String, error: String) -> void:
	_capture("complete", {"audio_file": path.get_file(), "error": error})
	var done := _on_done
	_on_done = Callable()
	busy = false
	_stage = ""
	if done.is_valid(): done.call(path, error)


## Streaming servers (OpenAI among them) write 0xFFFFFFFF as the RIFF/data sizes; set
## them from the actual byte count so Godot's loader and Rhubarb read the whole clip.
static func fix_wav_sizes(body: PackedByteArray) -> PackedByteArray:
	var offset := 12
	while offset + 8 <= body.size():
		var id := body.slice(offset, offset + 4).get_string_from_ascii()
		var chunk := body.decode_u32(offset + 4)
		if id == "data":
			var actual := body.size() - offset - 8
			if chunk != actual:
				body.encode_u32(offset + 4, actual)
				body.encode_u32(4, body.size() - 8)
			break
		offset += 8 + chunk + (chunk & 1)
	return body


## Identity-aware routing, retaining the legacy synthesize API for callers without profiles.
func synthesize_profile(text: String, profile: Dictionary, emotion: String, on_done: Callable) -> bool:
	if busy: return false
	_reprobe_if_given_up()
	text = voice_text(text)
	if spoken_text(text).is_empty():
		_defer_failure(on_done, "no generated speech to synthesize")
		return true
	var settings: Node = get_tree().root.get_node_or_null("Settings") if is_inside_tree() else null
	var mode := voice_mode
	if settings != null and settings.has_method("tts_enabled") and not settings.tts_enabled(): mode = "ponese"
	if not has_server() or CHATTER.is_ponese_mode(mode): return _start_chatter(text, profile, emotion, on_done)
	# An OpenAI voice name makes any pony voiced, speaker id or not.
	var openai_voiced := provider == "openai" and profile.has("openai_voice") and not CHATTER.is_ponese_mode(str(profile.get("voice_mode", mode)))
	# A streaming server with its own voice list voices a pony by profile id, speaker id or not;
	# a pony set to Ponese in her own profile stays Ponese.
	var routed := can_stream() and _stream_characters and not str(profile.get("id", "")).is_empty() \
		and not CHATTER.is_ponese_mode(str(profile.get("voice_mode", mode)))
	if CHATTER.use_chatter(profile, mode) and not openai_voiced and not routed:
		return _start_chatter(text, profile, emotion, on_done)
	var generation := _generation
	var finished := func(path: String, error: String) -> void:
		if generation != _generation or not on_done.is_valid(): return
		if error != "" and chatter_fallback:
			if debug: print("[voice] TTS unavailable (", error.left(80), "); local chatter for ", profile.get("id", "background"))
			if _start_chatter(text, profile, emotion, on_done): return
		on_done.call(path, error)
	_stream_character = str(profile.get("id", "")) if routed else ""
	var accepted := synthesize(text, int(profile.get("tts_speaker_id", 31)), emotion, finished, str(profile.get("openai_voice", "")))
	_stream_character = ""
	return accepted or busy

func synthesize_ponese(text: String, profile: Dictionary, emotion: String, on_done: Callable) -> bool:
	return _start_chatter(text, profile, emotion, on_done)

func _start_chatter(text: String, profile: Dictionary, emotion: String, on_done: Callable) -> bool:
	if busy or _jobs.size() >= 2: return false
	_capture("local_voice", {"text": text, "speaker": str(profile.get("id", "")), "emotion": emotion})
	emotion = _line_emotion(text, emotion)
	text = spoken_text(text)
	# "..." or a lone symbol: nothing for the voice to say (the native voice answered "empty ponese
	# line", log 2026-11-04..07); the director treats this answer as silence.
	if not CONTROLS.has_ponese_words(text):
		_defer_failure(on_done, "no generated speech to synthesize")
		return true
	busy = true
	_on_done = on_done
	var bank := _chatter.prepare(profile)
	if bank.has("error"):
		_chatter_error.call_deferred(_generation, str(bank.error))
		return true
	_chatter_counter += 1
	var thread := Thread.new()
	var result: Array = []
	var variation := _chatter_counter
	var error := thread.start(func() -> void: result.append(CHATTER.compose(text, bank, emotion, variation)))
	if error != OK:
		_chatter_error.call_deferred(_generation, "chatter worker unavailable")
		return true
	_jobs.append({"thread":thread, "result":result, "generation":_generation})
	set_process(true)
	return true


func _process(_delta: float) -> void:
	for index in range(_jobs.size()-1, -1, -1):
		var job: Dictionary = _jobs[index]
		if job.thread.is_alive(): continue
		job.thread.wait_to_finish()
		_jobs.remove_at(index)
		if job.generation != _generation: continue
		var done := _on_done
		_on_done = Callable(); busy = false
		if not done.is_valid(): continue
		var result: Dictionary = job.result[0]
		if result.has("error"):
			done.call("", result.error); continue
		_counter += 1
		var path := "%s/chatter_%d_%03d.wav" % [output_dir, get_instance_id(), _counter % 40]
		var stream := AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate = int(result.rate)
		stream.data = result.pcm
		var saved := stream.save_to_wav(ProjectSettings.globalize_path(path))
		if saved != OK:
			done.call("", "cannot save chatter WAV"); continue
		var cue_file := FileAccess.open(path + ".mouth.json", FileAccess.WRITE)
		if cue_file == null:
			done.call("", "cannot save chatter mouth cues"); continue
		cue_file.store_string(JSON.stringify({"chatter_version":1, "wav_sha256":FileAccess.get_sha256(path), "mouthCues":result.cues, "wordCues":result.get("word_cues",[])}))
		cue_file.close()
		if debug: print("[voice] ",result.bank," local composition ",result.build_usec," us, ",stream.get_length()," s")
		done.call(path, "")
	set_process(not _jobs.is_empty())


func _exit_tree() -> void:
	SENTENCES.note_stream_client(get_instance_id(), false)
	_probe_serial += 1
	if is_instance_valid(_health): _health.cancel_request()
	cancel()
	for job in _jobs: job.thread.wait_to_finish()
	_jobs.clear()


func _chatter_error(generation: int, message: String) -> void:
	if generation != _generation or not busy: return
	_finish("", message)


func _capture(event: String, details: Dictionary) -> void:
	if CAPTURE.folder().is_empty(): return
	details["client"] = get_instance_id()
	details["stage"] = _stage
	details["provider"] = provider
	CAPTURE.record("tts", event, details, api_key)
