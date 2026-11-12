extends RefCounted
## Mouth shapes read from the speech samples themselves, 10 ms at a time, with no helper program
## and no wait for the whole clip (dev 2026-11-10, from the /mlp/ thread: "a replacement to rhubarb
## ... with streaming ... that reduces latency by a LOT").
##
## The recogniser is Talking Avatar by InterviewFlowAI (MIT): a small causal network over 80-band
## log-mel frames that names one of 22 sound classes per 10 ms, looking 20 ms ahead. Its C++ port,
## the worker class TalkingAvatarAnalyzer (native/talking_avatar) and the class-to-letter table are
## from the breeze-tts-pny mod by nak (MIT). The model file is the upstream one, unchanged.
##
## Two uses:
##   analyse_clip(stream)  a finished clip, all cues at once (LipSync.analyse calls it first);
##   new() + begin/feed    a line that is still arriving (pcm_speech_player.gd), cues growing.
## Both give LipSync's cue shape [{start, end, value}] with the letters A-H and X.
## A clip this cannot read (stereo, not 16 bit, over a minute, library missing) returns no cues and
## LipSync goes on to its older ways.

const MODEL := "res://world/characters/lip_sync_model/viseme-model.bin"
const MODEL_SHA := "f1cdf2b76b9f2da8730b1d3e47d7e05a2b79c9b92d00dd00c595d64e471f419c"
const NATIVE_CLASS := &"TalkingAvatarAnalyzer"
## The analyser refuses more than this much audio in one line (the stream transport's limit too).
const MAX_SECONDS := 60.0
## Bytes per push_pcm call (the native side takes at most 48000).
const PUSH_BYTES := 9600
## A line still arriving is analysed at most this far ahead of what has been heard.
const AHEAD_SECONDS := 1.0

static var _lock := Mutex.new()
static var _checked := false
static var _model := PackedByteArray()

## A growing line: the cues so far. The last cue ends where the analysis has got to, so a mouth
## asked for a time past it rests (X) instead of holding a stale shape.
var cues: Array = []
var _analyzer: RefCounted
var _rate := 24000
var _sent := 0
var _eof := false


## True when the native library and its model are here. Safe from any thread.
static func available() -> bool:
	_lock.lock()
	if not _checked:
		_checked = true
		if ClassDB.class_exists(NATIVE_CLASS) and FileAccess.file_exists(MODEL):
			if FileAccess.get_sha256(MODEL) == MODEL_SHA:
				_model = FileAccess.get_file_as_bytes(MODEL)
			else:
				push_warning("lip sync: model file does not match its checksum; using the older lip sync")
	var ready := not _model.is_empty()
	_lock.unlock()
	return ready


## Loads the weights ahead of the first line (the native side keeps one parsed copy).
static func warm_up() -> void:
	if not available(): return
	var analyzer: RefCounted = ClassDB.instantiate(NATIVE_CLASS)
	if analyzer.begin(_model, 24000): analyzer.finish()


## All cues of a finished clip. Blocking (about a hundredth of the clip's length): call it from a
## worker thread. [] when this clip is not for this recogniser.
static func analyse_clip(stream: AudioStreamWAV) -> Array:
	if stream == null or stream.stereo or stream.format != AudioStreamWAV.FORMAT_16_BITS: return []
	var rate := stream.mix_rate
	var pcm := stream.data
	pcm.resize(pcm.size() - pcm.size() % 2)
	var seconds := pcm.size() / 2.0 / maxf(1.0, rate)
	if rate < 8000 or rate > 96000 or pcm.is_empty() or seconds > MAX_SECONDS or not available(): return []
	var analyzer: RefCounted = ClassDB.instantiate(NATIVE_CLASS)
	if not analyzer.begin(_model, rate): return []
	var events: Array = []
	var sent := 0
	var deadline := Time.get_ticks_msec() + 20000
	while true:
		var status: Dictionary = analyzer.status()
		if not str(status.error).is_empty() or Time.get_ticks_msec() > deadline:
			analyzer.cancel()
			return []
		events.append_array(analyzer.poll())
		if sent < pcm.size():
			# The native queue holds three seconds; keep it under two and let the worker catch up.
			if int(status.pending_frames) > rate * 2:
				OS.delay_usec(200)
				continue
			var end := mini(pcm.size(), sent + PUSH_BYTES)
			if not analyzer.push_pcm(pcm.slice(sent, end)): return []
			sent = end
			if sent == pcm.size(): analyzer.finish()
		elif bool(status.done):
			break
		else:
			OS.delay_usec(200)
	events.append_array(analyzer.poll())
	var result: Array = []
	for event: Dictionary in events:
		_add_event(result, event, seconds)
	if not result.is_empty(): result[-1]["end"] = maxf(float(result[-1]["start"]), seconds)
	return result


## One change of mouth shape, appended to a cue list. Equal neighbours join.
static func _add_event(list: Array, event: Dictionary, limit: float) -> void:
	var time := clampf(float(event.time), 0.0, limit)
	var value := str(event.value)
	if not list.is_empty():
		var last: Dictionary = list[-1]
		if time < float(last["start"]): return
		last["end"] = time
		if str(last["value"]) == value: return
		if float(last["end"]) <= float(last["start"]): list.pop_back()
	elif time > 0.0:
		list.append({"start": 0.0, "end": time, "value": "X"})
	list.append({"start": time, "end": time, "value": value})


## Starts a line that will arrive in pieces. False = no recogniser; the line plays with a still mouth.
func begin(rate := 24000) -> bool:
	cancel()
	cues = []
	_rate = rate
	_sent = 0
	_eof = false
	if not available(): return false
	_analyzer = ClassDB.instantiate(NATIVE_CLASS)
	if not _analyzer.begin(_model, rate):
		_analyzer = null
	return _analyzer != null


## Call every frame: `heard` is the playback time in seconds, `pcm` everything received so far
## (mono 16 bit), `done` true once the line has fully arrived. Extends `cues`.
func feed(heard: float, pcm: PackedByteArray, done: bool) -> void:
	if _analyzer == null: return
	var status: Dictionary = _analyzer.status()
	if not str(status.error).is_empty():
		push_warning("lip sync: " + str(status.error))
		cancel()
		return
	var limit := mini(pcm.size(), int((maxf(0.0, heard) + AHEAD_SECONDS) * _rate) * 2)
	limit -= limit % 2
	var pushes := 0
	while _sent < limit and pushes < 4 and int(status.pending_frames) < _rate:
		var end := mini(limit, _sent + int(_rate * 0.08) * 2)
		if not _analyzer.push_pcm(pcm.slice(_sent, end)):
			push_warning("lip sync: the analyser refused the audio")
			cancel()
			return
		_sent = end
		pushes += 1
	if done and _sent >= pcm.size() - pcm.size() % 2 and not _eof:
		_analyzer.finish()
		_eof = true
	var total := pcm.size() / 2.0 / _rate
	for event: Dictionary in _analyzer.poll():
		_add_event(cues, event, total)
	if not cues.is_empty():
		var analysed := total if bool(status.done) else float(status.processed_frames) / _rate
		cues[-1]["end"] = maxf(float(cues[-1]["end"]), minf(analysed, total))


func cancel() -> void:
	if _analyzer != null: _analyzer.cancel()
	_analyzer = null
