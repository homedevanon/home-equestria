extends Node
## The player's microphone: open-mic voice activity detection or push-to-talk, delivering
## one WAV per utterance.
##
## Godot side: an AudioStreamMicrophone plays into a muted "Mic" bus that carries an
## AudioEffectCapture; we pull the captured frames every process tick. VAD is an RMS gate
## with an adaptive noise floor and a hangover, plus a pre-roll so the first syllable is
## not clipped. The WAV is 16-bit mono at 16 kHz (STT_RATE), Whisper's own rate, made from the
## capture at the real engine mix rate (re-read whenever capture starts: a device change can change
## it), so no recognizer has to guess or resample. The microphone player is kept at normal speed
## while the time-stop look slows every other sound (talk_freeze.gd AudioServer.playback_speed_scale
## 0.7 stretched his own words and dropped pieces of them: the "[electronic music]" transcripts).
## Needs `audio/driver/enable_input=true` (project.godot).

signal state_changed(state: String)      # "off", "listening", "hearing", "muted"
signal interrupt_requested
signal utterance(wav: PackedByteArray, seconds: float)
signal feedback_utterance(wav: PackedByteArray, seconds: float)

const BUS := "Mic"
const BLOCK := 0.02   # seconds per analysis block
const RECORD_AUDIO := "android.permission.RECORD_AUDIO"
## Whisper's sample rate; recordings at higher mix rates are resampled to it (stt_wav).
const STT_RATE := 16000

@export var mode := "ptt"                # "vad", "ptt", "off"
@export var push_to_talk_action := "voice_talk"
@export var vr_button := "by_button"
@export var threshold := 0.012
@export var hangover := 0.75
@export var min_speech := 0.35
@export var max_speech := 18.0
@export var pre_roll := 0.3
## PipeWire source to attach the recording stream to ("" = leave the system default).
@export var mic_source := ""
@export var input_device := ""
@export var debug := false

var state := "off"
var level := 0.0             # last block RMS, for the HUD
var noise_floor := 0.004
var muted := false           # true while an utterance is being transcribed
var _capture: AudioEffectCapture
var _capture_bus := ""
var _player: AudioStreamPlayer
var _mix_rate := 48000.0
## The driver mix rate read at _ready (and again when capture starts); -1 for synthetic microphones
## (tests) that set their own _mix_rate.
var _driver_rate := -1.0
## AudioEffectCapture.get_discarded_frames() at the last utterance (it only counts up).
var _discarded_seen := 0
var _pre: Array[PackedFloat32Array] = []
var _pre_samples := 0
var _speech: PackedFloat32Array = PackedFloat32Array()
var _in_speech := false
var _silence := 0.0
var _speech_seconds := 0.0
var _voiced_blocks := 0
var _controllers: Array = []
var _ptt_held := false
var _ptt_capped := false # One bounded utterance per press; release rearms capture.
var feedback_mode := false
var _interrupt_held := false
var _available := false
var _permission_pending := false
var _applied_mode := ""
var _debug_timer := 0.0
var _debug_peak := 0.0
var _debug_frames := 0


func _ready() -> void:
	_driver_rate = AudioServer.get_mix_rate()
	_mix_rate = _driver_rate
	var idx := AudioServer.get_bus_index(BUS)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS)
	_capture = AudioEffectCapture.new()
	# Two seconds of room: a long game frame (a chat reply landing, a scene load) left the capture
	# full for longer than half a second and pieces of his words were dropped (split recordings).
	_capture.buffer_length = 2.0
	AudioServer.add_bus_effect(idx, _capture)
	_capture_bus = AudioServer.get_bus_name(idx)
	AudioServer.set_bus_mute(idx, true)
	_player = AudioStreamPlayer.new()
	_player.name = "MicPlayer"
	_player.stream = AudioStreamMicrophone.new()
	_player.bus = BUS
	add_child(_player)
	var enabled: bool = ProjectSettings.get_setting("audio/driver/enable_input", false)
	if not enabled:
		push_warning("SpeechInput: audio/driver/enable_input is off; no microphone")
	_available = enabled
	# Subscribe even when already granted: Android settings may revoke access later.
	# Defer the first request until the director has applied the saved microphone mode.
	if _requires_permission():
		_available = enabled and _has_record_permission()
		get_tree().on_request_permissions_result.connect(_on_permission)
		apply_settings.call_deferred()
	# In the headset the voice comes through WiVRn's PipeWire source, not the desk mic; on the
	# desktop that source exists too but carries nothing, so it is only chosen under XR.
	var xr := false
	var interface := XRServer.primary_interface
	if interface != null and interface.is_initialized():
		xr = true
	var inputs := AudioServer.get_input_device_list()
	if not input_device.is_empty() and input_device in inputs:AudioServer.input_device=input_device
	print("[speech] input devices: ", inputs, " (current: ", AudioServer.input_device, ", xr: ", xr, ")")
	if xr and input_device.is_empty() and OS.get_name()=="Linux":
		for device in inputs:
			if "wivrn" in String(device).to_lower():
				AudioServer.input_device = device
				print("[speech] mic -> ", device)
				break
		# `mic_source` unset means "whatever suits the rig": in the headset that is WiVRn's
		# source. Without this the stream stays on the system default (the soundboard's
		# virtual mic) and every utterance transcribes as silence.
		if mic_source == "":
			mic_source = "wivrn.source"
	_applied_mode = mode
	_sync_capture()
	_set_state("off" if mode == "off" or not _available else "listening")


## Re-applies mode and input device after the director changed them (provider page Save).
func apply_settings(request_permission: bool = true) -> void:
	if not is_inside_tree(): return
	_refresh_permission(request_permission)
	# Back to "System default" is left to the next launch: in the headset _ready picks WiVRn's source.
	if not input_device.is_empty() and input_device in AudioServer.get_input_device_list(): AudioServer.input_device = input_device
	if mode != _applied_mode or mode == "off" or not _available:
		_applied_mode = mode
		_ptt_held = false
		_ptt_capped = false
		_finish(false)
	_sync_capture()
	_set_state(_current_state())


func _requires_permission() -> bool:
	return OS.has_feature("android")


func _has_record_permission() -> bool:
	return OS.get_granted_permissions().has(RECORD_AUDIO)


func _request_record_permission() -> bool:
	return OS.request_permission(RECORD_AUDIO)


func _refresh_permission(request: bool) -> void:
	if not _requires_permission(): return
	var enabled := bool(ProjectSettings.get_setting("audio/driver/enable_input", false))
	_available = enabled and _has_record_permission()
	# Saving a microphone mode is an explicit retry after refusal. Focus changes only
	# refresh status; they must not repeatedly reopen the system prompt.
	if request and enabled and not _available and not _permission_pending and mode != "off":
		_permission_pending = true
		if _request_record_permission():
			_permission_pending = false
			_available = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_instance_valid(_player) and _requires_permission():
		apply_settings(false)


## PTT releases the actual input stream, rather than continuously recording and throwing
## its samples away. Open mic remains available only when the player selected VAD.
func _sync_capture() -> void:
	if not is_instance_valid(_player): return
	var held := _ptt_pressed()
	var wanted := _available and not muted and not (_ptt_capped and held) and (mode == "vad" or (mode == "ptt" and held))
	if wanted and not _player.playing:
		if _capture != null: _capture.clear_buffer()
		_refresh_mix_rate()
		_keep_normal_speed()
		_player.play()
		_route_mic()
	elif not wanted:
		if _player.playing: _player.stop()
		if _capture != null: _capture.clear_buffer()
		level = 0.0


## The capture runs at the driver's mix rate; a recording labelled with a stale rate plays
## stretched or squeezed to the recognizer.
func _refresh_mix_rate() -> void:
	if _driver_rate < 0.0: return
	var rate := AudioServer.get_mix_rate()
	if rate > 0.0 and rate != _driver_rate:
		print("[speech] mix rate changed: %d -> %d Hz" % [int(_driver_rate), int(rate)])
		_driver_rate = rate
		_mix_rate = rate


## AudioServer.playback_speed_scale (the time-stop look) applies to every player, the microphone's
## too: at 0.7 his words were captured 1.4 times as long and the input overflowed. The pitch scale
## undoes it for this one player.
func _keep_normal_speed() -> void:
	if not is_instance_valid(_player): return
	var wanted := 1.0 / clampf(AudioServer.playback_speed_scale, 0.05, 4.0)
	if not is_equal_approx(_player.pitch_scale, wanted): _player.pitch_scale = wanted


## Godot's PulseAudio/PipeWire input follows the system default source, and
## `AudioServer.input_device` does not always take. Move the stream with pactl instead.
func _route_mic() -> void:
	# Source runs on Linux only: the helper script is not packed into exports. Elsewhere the
	# AudioServer input device selection above is all there is.
	if mic_source == "" or OS.get_name() != "Linux" or not OS.has_feature("editor"):
		return
	var script := ProjectSettings.globalize_path("res://tools/ai/route_mic.sh")
	if script.is_absolute_path() and not script.begins_with("res://") and FileAccess.file_exists(script):
		OS.create_process("bash", [script, mic_source])


## XRController3D nodes whose `vr_button` acts as push-to-talk (either hand).
func set_controllers(controllers: Array) -> void:
	_controllers = controllers


func set_muted(value: bool) -> void:
	var changed := muted != value
	muted = value
	if changed or (muted and _in_speech):
		_finish(false)
		if _capture != null:_capture.clear_buffer()
	_sync_capture()
	_set_state(_current_state())


func _current_state() -> String:
	if mode == "off" or not _available: return "off"
	if muted: return "muted"
	return "hearing" if _in_speech else "listening"


func _set_state(value: String) -> void:
	if value == state: return
	state = value
	state_changed.emit(state)


func _ptt_pressed() -> bool:
	if InputMap.has_action(push_to_talk_action) and Input.is_action_pressed(push_to_talk_action) and not (get_viewport().gui_get_focus_owner() is LineEdit):
		return true
	for controller in _controllers:
		if controller != null and is_instance_valid(controller) and controller.has_method("is_button_pressed"):
			if controller.is_button_pressed(vr_button):
				return true
	return false


func _poll_interrupt() -> void:
	var held := _ptt_pressed()
	if held and not _interrupt_held and mode != "off" and _available: interrupt_requested.emit()
	_interrupt_held = held


## Feedback note instead of speech: both hands' talk buttons (B and Y) held together. A deliberate
## two-thumb chord, so talking while a hand grips a pony or a door never files feedback
## (playtester 2026-10-20; the old trigger + talk chord fired while carrying).
func _feedback_pressed() -> bool:
	var held := 0
	for controller in _controllers:
		if controller != null and is_instance_valid(controller) and controller.has_method("is_button_pressed") and controller.is_button_pressed(vr_button):
			held += 1
	return held >= 2


func _process(delta: float) -> void:
	_poll_interrupt()
	# Release must send the accumulated utterance even if the audio driver has no new
	# block. Do this before closing capture or returning for an empty capture buffer.
	var held := _ptt_pressed()
	if _ptt_capped and not held:
		_ptt_capped = false
		_ptt_held = false
	if _ptt_held and not held: _process_ptt(PackedFloat32Array(), delta)
	_sync_capture()
	if _capture == null or mode == "off" or not _available:
		return
	if muted or (_ptt_capped and held) or (mode == "ptt" and not held): return
	var available := _capture.get_frames_available()
	if available <= 0:
		return
	_keep_normal_speed()
	var frames := _capture.get_buffer(available)
	var mono := PackedFloat32Array()
	mono.resize(frames.size())
	for i in frames.size():
		mono[i] = (frames[i].x + frames[i].y) * 0.5
	if debug:
		_debug_frames += mono.size()
		_debug_peak = maxf(_debug_peak, _rms(mono))
		_debug_timer += delta
		if _debug_timer >= 2.0:
			print("[speech] mic %s: %d frames/2s, peak rms %.4f, floor %.4f, gate %.4f, state %s%s" % [
				AudioServer.input_device, _debug_frames, _debug_peak, noise_floor, maxf(threshold, noise_floor * 3.5),
				state, " (B held)" if _ptt_pressed() else ""])
			_debug_timer = 0.0
			_debug_peak = 0.0
			_debug_frames = 0
	if muted:
		return
	# Push-to-talk always works, on top of the open mic: holding the button captures
	# regardless of the gate, release sends.
	if mode == "ptt" or held or _ptt_held:
		if _in_speech and not _ptt_held and mode != "ptt" and not _feedback_pressed():
			# VAD was mid-utterance when the button came down: hand it over.
			_ptt_held = true
		_process_ptt(mono, delta)
	else:
		_process_vad(mono)


func _process_ptt(mono: PackedFloat32Array, _delta: float) -> void:
	var held := _ptt_pressed()
	if _ptt_capped:
		if not held:
			_ptt_capped = false; _ptt_held = false
		_sync_capture()
		return
	if held and not _ptt_held:
		feedback_mode = _feedback_pressed()
		_speech = PackedFloat32Array()
		_enc_reset()
		_speech_seconds = 0.0
		_in_speech = true
		_set_state("hearing")
	elif held and not feedback_mode and _feedback_pressed():
		# Two thumbs rarely land on the same frame: the note starts when the chord closes.
		feedback_mode = true
		_speech = PackedFloat32Array()
		_enc_reset()
		_speech_seconds = 0.0
		state_changed.emit(state) # the HUD shows "Feedback" now
	if held:
		var sample_limit := maxi(1, int(max_speech * _mix_rate))
		var remaining := maxi(0, sample_limit - _speech.size())
		if mono.size() <= remaining: _speech.append_array(mono)
		elif remaining > 0: _speech.append_array(mono.slice(0, remaining))
		_speech_seconds = _speech.size() / _mix_rate
		_encode_ahead(_speech, false)
		level = _rms(mono)
		if _speech.size() >= sample_limit:
			# Latch before emit: synchronous transcription/mute callbacks cannot reopen
			# capture on the same still-held press. No second utterance until release.
			_ptt_capped = true; _ptt_held = true
			_finish(true)
			_sync_capture()
			return
	elif _ptt_held:
		_finish(true)
	_ptt_held = held


func _process_vad(mono: PackedFloat32Array) -> void:
	var block_size := int(_mix_rate * BLOCK)
	var offset := 0
	while offset < mono.size() and not muted:
		var block := mono.slice(offset, mini(offset + block_size, mono.size()))
		offset += block_size
		var rms := _rms(block)
		level = rms
		var gate := maxf(threshold, noise_floor * 3.5)
		var voiced := rms > gate
		if not _in_speech:
			# Adapt the floor only on quiet blocks so speech never raises it.
			if not voiced:
				noise_floor = lerpf(noise_floor, rms, 0.05)
			_push_pre(block)
			if voiced:
				_voiced_blocks += 1
				if _voiced_blocks >= 3:
					_in_speech = true
					_silence = 0.0
					_speech = PackedFloat32Array()
					_enc_reset()
					for chunk in _pre:
						_speech.append_array(chunk)
					_speech_seconds = _speech.size() / _mix_rate
					_set_state("hearing")
			else:
				_voiced_blocks = 0
			continue
		_speech.append_array(block)
		_speech_seconds += block.size() / _mix_rate
		_encode_ahead(_speech, false)
		if voiced:
			_silence = 0.0
		else:
			_silence += block.size() / _mix_rate
		if _silence >= hangover or _speech_seconds >= max_speech:
			_finish(true)


func _push_pre(block: PackedFloat32Array) -> void:
	_pre.append(block)
	_pre_samples += block.size()
	while _pre_samples > int(pre_roll * _mix_rate) and _pre.size() > 1:
		_pre_samples -= _pre[0].size()
		_pre.remove_at(0)


func _finish(emit: bool) -> void:
	_in_speech = false
	_voiced_blocks = 0
	_pre.clear()
	_pre_samples = 0
	var seconds := _speech_seconds - (_silence if mode == "vad" else 0.0)
	var samples := _speech
	var feedback := feedback_mode
	feedback_mode = false
	_speech = PackedFloat32Array()
	_speech_seconds = 0.0
	_silence = 0.0
	_set_state(_current_state())
	if emit and seconds >= min_speech:
		if debug:
			print("[speech] utterance %.2f s (%d samples)" % [seconds, samples.size()])
		# Frames the capture had to throw away while it was full: the recording has holes.
		var discarded := _capture.get_discarded_frames() if _capture != null else 0
		if discarded > _discarded_seen:
			print("[speech] the microphone dropped %d frames of this recording (the game was busy)" % (discarded - _discarded_seen))
		# One line per recording for bug reports (thread 2026-11-10: "glitchy and pitched down" clips):
		# a wrong pitch shows as a sound speed other than 1, or as two rates that differ.
		print("[speech] recording %.2f s: capture %d Hz, input device %d Hz, sound speed %.2f, mic speed %.2f, dropped %d" % [
			seconds, int(_mix_rate), int(AudioServer.get_input_mix_rate()), AudioServer.playback_speed_scale,
			_player.pitch_scale if is_instance_valid(_player) else 1.0, discarded - _discarded_seen])
		_discarded_seen = discarded
		var wav := _finish_wav(samples)
		if feedback:
			feedback_utterance.emit(wav, seconds)
		else:
			utterance.emit(wav, seconds)
	else:
		_enc_reset()
		if debug and emit:
			print("[speech] dropped %.2f s blip" % seconds)


## The recording is converted for the recogniser while it is captured, a few hundred samples a
## frame, so the frame that ends an utterance has almost nothing left to convert (the whole
## conversion in that one frame held the game for 40 to 160 ms each time the player stopped
## talking). The bytes are the same as stt_wav() makes; tools/ai/test_stt_wav_incremental.gd.
var _enc_pcm := PackedByteArray()
var _enc_count := 0
var _enc_rate := 0
var _enc_round := PackedFloat32Array([0.0])

func _enc_reset() -> void:
	_enc_pcm = PackedByteArray()
	_enc_count = 0
	_enc_rate = int(_mix_rate)

## Converts what `samples` has gained since the last call. Not final: only output samples whose
## source samples are all captured; final: the rest, the last one clamped as resample() does.
func _encode_ahead(samples: PackedFloat32Array, final: bool) -> void:
	var size := samples.size()
	var direct := _enc_rate <= STT_RATE
	var step := 1.0 if direct else float(_enc_rate) / float(STT_RATE)
	var want := size
	if not direct: want = int(floor(size / step)) if final else maxi(0, int(floor((size - 1) / step)))
	if want <= _enc_count: return
	_enc_pcm.resize(want * 2)
	var last := size - 1
	var wide := step >= 2.0
	for i in range(_enc_count, want):
		var value := 0.0
		if direct:
			value = samples[i]
		else:
			var at := i * step
			var a := int(at)
			var b := mini(a + 1, last)
			value = samples[a] + (samples[b] - samples[a]) * (at - a)
			if wide: value = (samples[maxi(a - 1, 0)] + value + samples[b]) / 3.0
			# resample() stores single-precision values before encode_wav() reads them.
			_enc_round[0] = value
			value = _enc_round[0]
		_enc_pcm.encode_s16(i * 2, int(clampf(value, -1.0, 1.0) * 32767.0))
	_enc_count = want

## The finished recording as stt_wav() would make it, from what was converted on the way.
func _finish_wav(samples: PackedFloat32Array) -> PackedByteArray:
	var rate := int(_mix_rate)
	if _enc_rate != rate or _enc_count * 2 != _enc_pcm.size() or (rate > 0 and samples.is_empty()):
		# The device rate changed during the recording (or nothing was converted): the plain way.
		_enc_reset()
		return stt_wav(samples, rate)
	_encode_ahead(samples, true)
	var pcm := _enc_pcm
	_enc_reset()
	return wav_from_pcm(pcm, mini(rate, STT_RATE))


static func _rms(block: PackedFloat32Array) -> float:
	if block.is_empty(): return 0.0
	var sum := 0.0
	for v in block:
		sum += v * v
	return sqrt(sum / block.size())


## The recording as Whisper wants it: mono 16-bit at STT_RATE (lower rates stay as they are).
static func stt_wav(samples: PackedFloat32Array, rate: int) -> PackedByteArray:
	if rate <= STT_RATE: return encode_wav(samples, rate)
	return encode_wav(resample(samples, rate, STT_RATE), STT_RATE)


## Rate conversion for speech: each output sample averages the source samples around its position
## (a small box filter, so hiss above the new Nyquist does not fold into the voice), linear between
## them. One pass over the output when the utterance ends; nothing runs per frame.
static func resample(samples: PackedFloat32Array, rate: int, target: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if samples.is_empty() or rate <= 0 or target <= 0: return out
	var step := float(rate) / float(target)
	var count := int(floor(samples.size() / step))
	out.resize(count)
	var last := samples.size() - 1
	var wide := step >= 2.0
	for i in count:
		var at := i * step
		var a := int(at)
		var b := mini(a + 1, last)
		var value := samples[a] + (samples[b] - samples[a]) * (at - a)
		if wide: value = (samples[maxi(a - 1, 0)] + value + samples[b]) / 3.0
		out[i] = value
	return out


## 16-bit PCM mono WAV.
static func encode_wav(samples: PackedFloat32Array, rate: int) -> PackedByteArray:
	var pcm := PackedByteArray()
	pcm.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		pcm.encode_s16(i * 2, v)
	return wav_from_pcm(pcm, rate)


## A mono 16-bit WAV file around `pcm`.
static func wav_from_pcm(pcm: PackedByteArray, rate: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array("RIFF".to_ascii_buffer())
	out.resize(8)
	out.encode_u32(4, 36 + pcm.size())
	out.append_array("WAVEfmt ".to_ascii_buffer())
	var fmt := PackedByteArray()
	fmt.resize(20)
	fmt.encode_u32(0, 16)
	fmt.encode_u16(4, 1)
	fmt.encode_u16(6, 1)
	fmt.encode_u32(8, rate)
	fmt.encode_u32(12, rate * 2)
	fmt.encode_u16(16, 2)
	fmt.encode_u16(18, 16)
	out.append_array(fmt)
	out.append_array("data".to_ascii_buffer())
	var size := PackedByteArray()
	size.resize(4)
	size.encode_u32(0, pcm.size())
	out.append_array(size)
	out.append_array(pcm)
	return out

func _on_permission(permission: String, granted: bool) -> void:
	if permission != RECORD_AUDIO: return
	_permission_pending = false
	print("[speech] microphone permission ", "granted" if granted else "refused")
	_available = granted and bool(ProjectSettings.get_setting("audio/driver/enable_input", false))
	# Never turn a refusal callback into another permission prompt.
	apply_settings(false)

func _exit_tree() -> void:
	# Audio buses outlive scene nodes. Remove only this microphone's capture effect,
	# retaining the shared bus and effects owned by another scene or audio component.
	if is_instance_valid(_player): _player.stop()
	if _capture != null:
		_capture.clear_buffer()
		var preferred := AudioServer.get_bus_index(_capture_bus)
		if preferred >= 0: _remove_owned_capture(preferred)
		# A user or mixer may rename/reorder the bus after setup; effect identity is
		# authoritative, and the scan also handles a moved owned effect.
		for bus in AudioServer.bus_count:
			if bus != preferred: _remove_owned_capture(bus)
	_capture = null; _capture_bus = ""
	_ptt_held = false; _ptt_capped = false
	_finish(false)

func _remove_owned_capture(bus: int) -> void:
	for effect in range(AudioServer.get_bus_effect_count(bus) - 1, -1, -1):
		if AudioServer.get_bus_effect(bus, effect) == _capture:
			AudioServer.remove_bus_effect(bus, effect)
