extends Node
## Plays a spoken line that is still arriving (world/ai/pcm_utterance.gd) through the speaker's own
## 3D voice player, and reads its mouth shapes as it goes. Playback starts once about 200 ms of
## sound is here; if the server falls behind, it pauses and takes up again where it stopped.
## Add as a child of the speaker, then begin(utterance, voice). The speaker reads `time` (what has
## been heard, in seconds) and `cues` (LipSync cue list, growing) every frame.
## Playback and the heard-time clock are from the breeze-tts-pny mod by nak (MIT), 2026-11-10.
signal started
signal finished
signal failed(message: String)

const LIP_SYNC := preload("res://world/characters/lip_sync_native.gd")
const RATE := 24000
const START_FRAMES := 4800 # 200 ms of audio, not 200 ms of waiting
const STALL_MS := 10000

var source: RefCounted
var voice: AudioStreamPlayer3D
var playback: AudioStreamGeneratorPlayback
var active := false
var began := false
var consumed_frames := 0
## Seconds of this line that have reached the listener's ears (the mixer's and the sound card's
## delay taken off), holding still through a pause for more sound.
var time := 0.0
## Mouth shapes so far; see lip_sync_native.gd.
var cues: Array = []
var debug := false

var _track: RefCounted
var _start_frames := START_FRAMES
var _capacity := 0
var _sent := 0
var _pushed := 0
var _last_skips := 0
var _underruns := 0
var _rebuffering := false
var _drain_ms := -1
var _last_data_ms := 0
var _seen := 0
var _origin_usec := 0
## The mixer's progress over time, (seconds since begin, seconds consumed): `time` is this line
## read `output latency` ago, so it stops when the mixer stops and ends on the last sample.
var _clock: Array[Vector2] = []


func _init() -> void:
	set_process(false)


func begin(utterance: RefCounted, player: AudioStreamPlayer3D) -> void:
	source = utterance; voice = player; active = true
	_start_frames = maxi(START_FRAMES, int(utterance.start_frames))
	_last_data_ms = Time.get_ticks_msec()
	_origin_usec = Time.get_ticks_usec()
	_track = LIP_SYNC.new()
	if _track.begin(RATE): cues = _track.cues
	else: _track = null
	set_process(true)


func cancel() -> void:
	if not active: return
	active = false; set_process(false)
	if _track != null: _track.cancel()
	if is_instance_valid(voice): voice.stop(); voice.stream_paused = false
	if source != null: source.cancel()
	_log("cancel")


func _exit_tree() -> void:
	cancel()


func _process(_delta: float) -> void:
	if not active: return
	if source.cancelled: _fail("PCM speech cancelled"); return
	if not source.error.is_empty(): _fail("PCM stream failed: " + source.error); return
	var frames: int = source.pcm.size() / 2
	if frames != _seen: _seen = frames; _last_data_ms = Time.get_ticks_msec()
	if not source.done and Time.get_ticks_msec() - _last_data_ms > STALL_MS:
		_fail("PCM stream stalled"); return
	if not began:
		if frames < _start_frames and not source.done: return
		if frames == 0: _fail("Empty PCM speech"); return
		var generator := AudioStreamGenerator.new()
		generator.mix_rate = RATE; generator.buffer_length = 0.5
		voice.stream = generator; voice.stream_paused = false; voice.play()
		playback = voice.get_stream_playback() as AudioStreamGeneratorPlayback
		if playback == null: _fail("PCM playback unavailable"); return
		_capacity = playback.get_frames_available()
		_fill(frames)
		_last_skips = playback.get_skips()
		began = true
		_log("start", {"request_to_play_ms": Time.get_ticks_msec() - source.request_ms,
			"output_latency_ms": AudioServer.get_output_latency() * 1000.0,
			"buffer_ms": frames * 1000.0 / RATE}, true)
		started.emit()
		return
	if not voice.playing and not _rebuffering: _fail("PCM playback stopped early"); return
	var skips := playback.get_skips()
	if skips > _last_skips and (not source.done or _sent < frames):
		_underruns += skips - _last_skips
		voice.stream_paused = true; _rebuffering = true
		_log("underrun", {"skips": skips - _last_skips}, true)
	_last_skips = skips
	if _rebuffering:
		if frames - _sent < _start_frames and not source.done: return
		_fill(frames); voice.stream_paused = false; _rebuffering = false
		_log("resume")
	_fill(frames)
	var queued := _capacity - playback.get_frames_available()
	consumed_frames = mini(_sent, maxi(consumed_frames, _pushed - queued))
	_tick_clock()
	if _track != null:
		_track.feed(time, source.pcm, source.done)
	if source.done and _sent == frames:
		# Keep the generator alive with silence while the last speech drains through the mixer
		# and the output queue. These frames never advance the speech timeline.
		var count := playback.get_frames_available()
		if count > 0:
			var silence := PackedVector2Array(); silence.resize(count)
			if playback.push_buffer(silence): _pushed += count
		if consumed_frames >= frames:
			if _drain_ms < 0: _drain_ms = Time.get_ticks_msec()
			if Time.get_ticks_msec() - _drain_ms >= AudioServer.get_output_latency() * 1000.0 + 40.0:
				active = false; set_process(false); voice.stop()
				if _track != null: _track.cancel()
				_log("finished", {"audio_ms": frames * 1000.0 / RATE}, true)
				source.release(); finished.emit()


func _fill(frames: int) -> void:
	var count := mini(playback.get_frames_available(), frames - _sent)
	if count <= 0: return
	var samples := PackedVector2Array(); samples.resize(count)
	var pcm: PackedByteArray = source.pcm
	for i in count:
		var value := float(pcm.decode_s16((_sent + i) * 2)) / 32768.0
		samples[i] = Vector2(value, value)
	if playback.push_buffer(samples): _sent += count; _pushed += count


func _tick_clock() -> void:
	var now := float(Time.get_ticks_usec() - _origin_usec) / 1000000.0
	var consumed := consumed_frames / float(RATE)
	if _clock.is_empty(): _clock.append(Vector2(now, 0.0))
	_clock.append(Vector2(now, consumed))
	var target := now - maxf(0.0, AudioServer.get_output_latency())
	while _clock.size() > 2 and _clock[1].x <= target: _clock.pop_front()
	while _clock.size() > 256: _clock.pop_front()
	var value := _clock[0].y
	if target < _clock[0].x: value = 0.0
	elif _clock.size() > 1:
		var width := _clock[1].x - _clock[0].x
		var weight := clampf((target - _clock[0].x) / width, 0.0, 1.0) if width > 0.0 else 1.0
		value = lerpf(_clock[0].y, _clock[1].y, weight)
	time = minf(consumed, maxf(time, value))


func _fail(message: String) -> void:
	_log("failed", {"message": message}, true)
	cancel()
	failed.emit(message)


func _log(event: String, extra: Dictionary = {}, always := false) -> void:
	if not always and not debug: return
	extra.merge({"event": event, "utterance": source.uri, "underruns": _underruns, "consumed_frames": consumed_frames})
	print("[pcm-playback] ", JSON.stringify(extra))
