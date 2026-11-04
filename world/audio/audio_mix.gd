extends RefCounted
## Dedicated world buses preserve settings sliders and leave speech/UI untouched.
const ROUTES := {"WorldSFX": "SFX", "WorldAmbience": "Ambience", "Wind": "WorldAmbience"}
var _filters: Array[AudioEffectLowPassFilter] = []
var _reverbs: Array[AudioEffectReverb] = []
var _ambience_bus := -1
var _voice_bus := -1
var _indoor := 0.0
var _underwater := 0.0
var _duck_db := 0.0
var _peak_clock := 0.0
var _voice_hold := 0.0
var _written_db := 0.0
var _written_cutoff := 18000.0
var _written_wet := 0.0

static func ensure_buses() -> void:
	for bus: String in ROUTES:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.get_bus_count() - 1, bus)
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus), ROUTES[bus])
	ensure_ponese_bus()

## Ponese lines play through their own bus into Voice (so the Voice slider still sets them).
## dev 2026-11-03: in game ponese "sounds muffled and shitty". The native voice chain is dark on
## purpose (pony_ponese_voice.cpp soften(): -5 dB at 3 kHz, -8 dB shelf from 5 kHz, 9.5 kHz
## low-pass); this EQ takes the mud out and gives the presence and air back.
const PONESE_BUS := "Ponese"
const PONESE_EQ_DB := {"32 Hz": -8.0, "100 Hz": -2.5, "320 Hz": -3.0, "1000 Hz": 0.0, "3200 Hz": 3.5, "10000 Hz": 5.0}

static func ensure_ponese_bus() -> void:
	var voice := "Voice" if AudioServer.get_bus_index("Voice") >= 0 else "Master"
	var index := AudioServer.get_bus_index(PONESE_BUS)
	if index < 0:
		AudioServer.add_bus()
		index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(index, PONESE_BUS)
	AudioServer.set_bus_send(index, voice)
	for i in AudioServer.get_bus_effect_count(index):
		if AudioServer.get_bus_effect(index, i) is AudioEffectEQ6: return
	var eq := AudioEffectEQ6.new()
	for band in eq.get_band_count():
		eq.set_band_gain_db(band, float(PONESE_EQ_DB.values()[band]))
	AudioServer.add_bus_effect(index, eq)

func setup() -> void:
	ensure_buses()
	_ambience_bus = AudioServer.get_bus_index("WorldAmbience")
	_voice_bus = AudioServer.get_bus_index("Voice")
	for bus: String in ["WorldSFX", "WorldAmbience"]:
		var index: int = AudioServer.get_bus_index(bus)
		# Reuse our own effects after a scoped mixer is replaced.
		var filter: AudioEffectLowPassFilter
		var reverb: AudioEffectReverb
		for i in AudioServer.get_bus_effect_count(index):
			var effect: AudioEffect = AudioServer.get_bus_effect(index, i)
			if effect is AudioEffectLowPassFilter: filter = effect
			elif effect is AudioEffectReverb: reverb = effect
		if filter == null:
			filter = AudioEffectLowPassFilter.new(); filter.cutoff_hz = 18000.0
			filter.resonance = .1
			AudioServer.add_bus_effect(index, filter)
		if reverb == null:
			reverb = AudioEffectReverb.new(); reverb.wet = 0.0; reverb.dry = 1.0
			reverb.room_size = .35; reverb.damping = .65
			AudioServer.add_bus_effect(index, reverb)
		_filters.append(filter); _reverbs.append(reverb)
	reset()

func step(delta: float, indoor: float, underwater: float, foreground: bool) -> void:
	var blend: float = 1.0 - exp(-maxf(delta, 0.0) * 5.0)
	_indoor = lerpf(_indoor, indoor, blend)
	_underwater = lerpf(_underwater, underwater, blend)
	_peak_clock -= delta
	_voice_hold = maxf(_voice_hold - delta, 0.0)
	if _peak_clock <= 0.0:
		_peak_clock = .1
		if _voice_bus >= 0 and not AudioServer.is_bus_mute(_voice_bus):
			var peak: float = maxf(AudioServer.get_bus_peak_volume_left_db(_voice_bus, 0), AudioServer.get_bus_peak_volume_right_db(_voice_bus, 0))
			if peak > -48.0: _voice_hold = .35
	var target_db: float = -7.0 if foreground or _voice_hold > 0.0 else 0.0
	_duck_db = lerpf(_duck_db, target_db, 1.0 - exp(-delta * (12.0 if target_db < _duck_db else 2.5)))
	# Perf 0.1.0: settled values are not rewritten (a bus volume write takes the audio server's
	# lock every frame). Steps below these tolerances are inaudible; the target is still reached.
	if _ambience_bus >= 0 and absf(_duck_db - _written_db) >= .005:
		_written_db = _duck_db
		AudioServer.set_bus_volume_db(_ambience_bus, _duck_db)
	var cutoff: float = lerpf(lerpf(18000.0, 12500.0, _indoor), 850.0, _underwater)
	var wet: float = lerpf(_indoor * .085, .025, _underwater)
	if absf(cutoff - _written_cutoff) >= .5 or absf(wet - _written_wet) >= .00005:
		_written_cutoff = cutoff; _written_wet = wet
		for filter: AudioEffectLowPassFilter in _filters: filter.cutoff_hz = cutoff
		for reverb: AudioEffectReverb in _reverbs: reverb.wet = wet

func reset() -> void:
	_indoor = 0.0; _underwater = 0.0; _duck_db = 0.0; _voice_hold = 0.0
	_written_db = 0.0; _written_cutoff = 18000.0; _written_wet = 0.0
	if _ambience_bus >= 0: AudioServer.set_bus_volume_db(_ambience_bus, 0.0)
	for filter: AudioEffectLowPassFilter in _filters: filter.cutoff_hz = 18000.0
	for reverb: AudioEffectReverb in _reverbs: reverb.wet = 0.0
