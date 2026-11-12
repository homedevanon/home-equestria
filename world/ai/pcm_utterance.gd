extends RefCounted
## One spoken line that is still being rendered by the voice server: its samples so far, and
## whether it is complete, failed or cancelled. The voice client (tts_client.gd) fills it, the
## speaking character (pcm_speech_player.gd) plays it; either side may cancel.
## Handed over by name ("pcm://utterance/7") through the same path argument a WAV file takes, so
## say(path, text) keeps one signature. From the breeze-tts-pny mod by nak (MIT), 2026-11-10.
const SCHEME := "pcm://"

static var pending: Dictionary = {}
static var serial := 0

## Mono 16-bit little-endian samples at RATE, appended as they arrive.
const RATE := 24000
var pcm := PackedByteArray()
var done := false
var error := ""
var cancelled := false
var claimed := false
var request_ms := Time.get_ticks_msec()
## Frames buffered before playback starts, or resumes after it ran dry.
var start_frames := 4800
var uri := ""
var cancel_transport := Callable()


static func is_uri(path: String) -> bool:
	return path.begins_with(SCHEME)


func publish() -> String:
	serial += 1
	uri = "%sutterance/%d" % [SCHEME, serial]
	pending[uri] = self
	return uri


## The speaker claims the line; a second take of the same name gets null.
static func take(path: String) -> RefCounted:
	var value: RefCounted = pending.get(path)
	pending.erase(path)
	if value != null: value.claimed = true
	return value


func cancel() -> void:
	if cancelled: return
	cancelled = true
	pending.erase(uri)
	if cancel_transport.is_valid(): cancel_transport.call()


func release() -> void:
	pending.erase(uri)
	cancel_transport = Callable()
