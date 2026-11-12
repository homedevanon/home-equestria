extends RefCounted
const CAPTURE := preload("res://world/ai/ai_capture.gd")
const VOCABULARY := preload("res://world/ai/speech_vocabulary.gd")
## Player speech input: microphone settings, speech-to-text requests and results, typed feedback notes, push-to-talk.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.


var host: Node


func _init(owner_node: Node) -> void:
	host = owner_node


## Speech input fields from the stt section. Speech-to-text provider "off" keeps the mic
## closed (typed chat still works).
func _configure_speech(stt: Dictionary) -> void:
	host.speech.mode = "off" if str(stt.get("provider", "local")) == "off" else String(stt.get("mode", "ptt"))
	host.speech.push_to_talk_action = String(stt.get("push_to_talk_action", "voice_talk"))
	host.speech.vr_button = String(stt.get("vr_push_to_talk_button", "by_button"))
	host.speech.threshold = float(stt.get("vad_threshold", 0.012))
	host.speech.hangover = float(stt.get("vad_hangover", 0.75))
	host.speech.min_speech = float(stt.get("vad_min_speech", 0.35))
	host.speech.max_speech = float(stt.get("vad_max_speech", 18.0))
	host.speech.debug = host.debug
	host.speech.input_device = String(stt.get("input_device", ""))
	var xr_now := XRServer.primary_interface != null and XRServer.primary_interface.is_initialized()
	var source: Variant = stt.get("mic_source")
	host.speech.mic_source = String(source) if source is String else ("wivrn.source" if xr_now and OS.get_name()=="Linux" else "")


func _on_utterance(wav: PackedByteArray, seconds: float, is_feedback := false) -> void:
	# Dictating a letter (the quill over the paper, world/letters/paper/letter_paper.gd): his words
	# go onto the paper. Nopony hears them and a pony who is talking is not cut off.
	if not is_feedback and dictating():
		# A pony was talking during it: the open mic may have caught her voice from the speakers,
		# and her words must not end up in his letter. He says it again after her line.
		if _dictation_overlap or host.state == "speaking":
			_dictation_overlap = false
			_capture("dictation_dropped", {"seconds": seconds, "reason": "pony speaking"})
			return
		_dictate(wav, seconds)
		return
	# A firm line (Trixie on stage) is not cut off: his words wait for its end.
	if host.floor_held() and not is_feedback:
		host._held_utterance = [wav, seconds, is_feedback]
		return
	if host.state != "idle": host.interrupt()
	host.state = "transcribing"
	host._transcribing_feedback = is_feedback
	host.speech.set_muted(true)
	host.hud.set_state("feedback" if is_feedback else "thinking", "" if is_feedback else "transcribing %.1f s..." % seconds)
	if host.debug:
		var dump := FileAccess.open("user://stt_last.wav", FileAccess.WRITE)
		if dump != null:
			dump.store_buffer(wav)
			dump.close()
	var stt: Dictionary = host.config.section("stt")
	_capture("request", {"provider": str(stt.get("provider", "local")), "model": str(stt.get("model", "")), "audio_bytes": wav.size(), "seconds": seconds})
	var err := OK
	# Names near Anon and the core cast, so the recognizer spells them (playtester: "Minuet").
	var vocabulary: String = VOCABULARY.prompt(host.characters, host.player_head, str(host.config.get_value("player_name", "")))
	if str(stt.get("provider", "local")) == "builtin":
		var generation: int = host._turn_id
		var heard := func(words: String, failure: String):
			if generation != host._turn_id or host.state != "transcribing": return
			if not failure.is_empty():
				_capture("error", {"error": failure})
				host._fail(failure)
				return
			_on_stt_completed(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), JSON.stringify({"text": words}).to_utf8_buffer())
		var error: String = host._builtin_stt.transcribe(wav, heard, vocabulary)
		if not error.is_empty():
			_capture("error", {"error": error})
			host._fail(error)
		return
	if str(stt.get("provider", "local")) == "openai":
		var request := transcription_request(stt, wav, vocabulary)
		err = host._stt.request_raw(request.url, request.headers, HTTPClient.METHOD_POST, request.body)
	else:
		# tools/ai/stt_server.py reads the names as Whisper's initial prompt; other servers ignore the header.
		err = host._stt.request_raw(String(stt.get("url", "")),
			PackedStringArray(["Content-Type: audio/wav", "X-Stt-Prompt: " + vocabulary.uri_encode()]), HTTPClient.METHOD_POST, wav)
	if err != OK:
		_capture("error", {"error": "request error %d" % err})
		host._fail("stt request error %d" % err)


## OpenAI-compatible Whisper API: multipart/form-data POST to {base_url}/audio/transcriptions
## with the utterance as `file` and the `model`; the JSON reply carries `text`. A non-empty
## `prompt` goes as the API's `prompt` field: names the recognizer should spell.
static func transcription_request(stt: Dictionary, wav: PackedByteArray, prompt := "") -> Dictionary:
	var boundary := "----HomeEquestria%d" % Time.get_ticks_usec()
	var body := PackedByteArray()
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n%s\r\n" % [boundary, str(stt.get("model", "whisper-1"))]).to_utf8_buffer())
	if not prompt.is_empty():
		body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n%s\r\n" % [boundary, prompt]).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n" % boundary).to_utf8_buffer())
	body.append_array(("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"utterance.wav\"\r\nContent-Type: audio/wav\r\n\r\n" % boundary).to_utf8_buffer())
	body.append_array(wav)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	var headers := PackedStringArray(["Content-Type: multipart/form-data; boundary=" + boundary])
	var key := str(stt.get("api_key", ""))
	if key != "": headers.append("Authorization: Bearer " + key)
	return {"url": str(stt.get("base_url", "")).rstrip("/") + "/audio/transcriptions", "headers": headers, "body": body}


func _on_stt_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_capture("response", {"result": result, "http_status": code, "body": body.get_string_from_utf8()})
	if host.state != "transcribing":
		return
	host.state = "idle"
	var is_feedback: bool = host._transcribing_feedback
	host._transcribing_feedback = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var hint := "check Settings → Dialogue & microphone" if str(host.config.get_value("stt/provider", "local")) == "openai" else "start tools/ai/stt_server.sh"
		host._fail("speech-to-text failed (%d/%d%s); %s" % [result, code, (": " + body.get_string_from_utf8().left(120)) if code >= 400 else "", hint])
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var heard := String(parsed.get("text", "")) if parsed is Dictionary else ""
	if host.debug: print("[ai] heard: ", heard)
	var text := spoken_words(heard)
	if text.strip_edges() == "":
		host.speech.set_muted(false)
		# Whisper's sound labels ("[electronic music]", "(silence)") are not his words; nopony
		# hears them (thread 43656594: push-to-talk kept arriving as "[electronic music]").
		if not heard.strip_edges().is_empty():
			print("[ai] heard no words, only ", heard.strip_edges().left(60))
			_capture("non_speech", {"text": heard.strip_edges().left(120)})
		host.hud.set_state(host.speech.state, "" if heard.strip_edges().is_empty() else "heard no words, only %s; check the microphone" % heard.strip_edges().left(40))
		return
	if is_feedback:
		handle_feedback(text)
	else:
		# "Minuet" -> "Minuette" before routing, so the right pony is addressed and nobody corrects his spelling.
		var respelled: String = VOCABULARY.correct(text)
		if respelled != text: print("[ai] respelled heard names: %s -> %s" % [text.left(80), respelled.left(80)])
		host.handle_text(respelled)


## The transcript without Whisper's non-speech labels: bracketed or parenthesised sound descriptions
## ("[Music]", "[electronic music]", "[BLANK_AUDIO]", "(silence)", "(upbeat music)"), *stage
## directions* and music notes. "" when nothing with letters or digits is left.
static func spoken_words(text: String) -> String:
	var words := RegEx.create_from_string("\\[[^\\]\\n]*\\]|\\([^)\\n]*\\)|\\*[^*\\n]*\\*|[♪♫♬]").sub(text, " ", true)
	words = RegEx.create_from_string("\\s+").sub(words, " ", true).strip_edges()
	return words if RegEx.create_from_string("[\\p{L}\\p{N}]").search(words) != null else ""


func handle_feedback(text: String) -> void:
	host.feedback_input.submit(text)

func _on_speech_state(value: String) -> void:
	if value == "hearing": _dictation_overlap = host.state == "speaking"
	if value == "hearing" and (host.state != "idle" or host.group.active()) and not host.floor_held() and not dictating(): host.interrupt()
	if host.state == "idle":
		host.hud.set_state("feedback" if value == "hearing" and host.speech.feedback_mode else value, host.hud.detail if value == "listening" else "")


## Button down takes the floor immediately, before any microphone samples arrive.
func _on_talk_pressed() -> void:
	if not host.floor_held() and not dictating(): host.interrupt()


## Letter dictation (docs/LETTERS_PLAN_2026_10_29.md section 7): while a `letter_dictation` node
## (letter_paper.gd) says the quill is over the paper, each utterance is transcribed on its own
## channel, one at a time in the order spoken, and its words go to take_words. It never touches
## the conversation state, the conversation's speech-to-text request or handle_text, so no pony
## hears it and a reply in flight carries on. The mic stays open for the next sentence.
var _dictation_queue: Array[PackedByteArray] = []
var _dictation_busy := false
## A pony's line was playing when the current utterance began (dropped if it is dictation).
var _dictation_overlap := false
var _dictation_http: HTTPRequest

func _dictation_node() -> Node:
	if not is_instance_valid(host) or not host.is_inside_tree(): return null
	return host.get_tree().get_first_node_in_group("letter_dictation")

func dictating() -> bool:
	var node := _dictation_node()
	return node != null and node.has_method("is_dictating") and bool(node.call("is_dictating"))

func _dictate(wav: PackedByteArray, seconds: float) -> void:
	_capture("dictation", {"audio_bytes": wav.size(), "seconds": seconds})
	_dictation_queue.append(wav)
	_next_dictation()

func _next_dictation() -> void:
	if _dictation_busy or _dictation_queue.is_empty(): return
	var stt: Dictionary = host.config.section("stt")
	var provider := str(stt.get("provider", "local"))
	if provider == "off":
		_dictation_queue.clear(); return
	var wav: PackedByteArray = _dictation_queue.pop_front()
	_dictation_busy = true
	var vocabulary: String = VOCABULARY.prompt(host.characters, host.player_head, str(host.config.get_value("player_name", "")))
	if provider == "builtin":
		var error: String = host._builtin_stt.transcribe(wav, func(words: String, failure: String): _dictation_done(words, failure), vocabulary)
		if not error.is_empty(): _dictation_done("", error)
		return
	if not is_instance_valid(_dictation_http):
		_dictation_http = HTTPRequest.new()
		_dictation_http.name = "DictationSTT"
		_dictation_http.timeout = 60.0
		host.add_child(_dictation_http)
		_dictation_http.request_completed.connect(_on_dictation_completed)
	var err := OK
	if provider == "openai":
		var request := transcription_request(stt, wav, vocabulary)
		err = _dictation_http.request_raw(request.url, request.headers, HTTPClient.METHOD_POST, request.body)
	else:
		err = _dictation_http.request_raw(String(stt.get("url", "")),
			PackedStringArray(["Content-Type: audio/wav", "X-Stt-Prompt: " + vocabulary.uri_encode()]), HTTPClient.METHOD_POST, wav)
	if err != OK: _dictation_done("", "request error %d" % err)

func _on_dictation_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_dictation_done("", "speech-to-text failed (%d/%d)" % [result, code]); return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	_dictation_done(String(parsed.get("text", "")) if parsed is Dictionary else "", "")

func _dictation_done(text: String, failure: String) -> void:
	_dictation_busy = false
	if not failure.is_empty():
		_capture("dictation_error", {"error": failure})
		push_warning("[letters] dictation: " + failure)
	elif not spoken_words(text).is_empty():
		# The same respelling as conversation: "Minuet" -> "Minuette". Sound labels never reach paper.
		var respelled: String = VOCABULARY.correct(spoken_words(text))
		if host.debug: print("[letters] dictated: ", respelled.left(120))
		var node := _dictation_node()
		if node != null and node.has_method("take_words"): node.call("take_words", respelled)
	_next_dictation()


func _capture(event: String, details: Dictionary) -> void:
	details["turn"] = host._turn_id
	CAPTURE.record("stt", event, details, str(host.config.get_value("stt/api_key", "")))
