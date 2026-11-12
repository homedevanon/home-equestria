class_name LipSync
extends RefCounted
## Timed mouth shapes for a speech clip: [{start, end, value}] with Rhubarb's
## letters A-H and X (see PonyMouth.VISEMES).
##
## First choice since 2026-11-10: the in-process recogniser (lip_sync_native.gd), which reads the
## samples in about a hundredth of the clip's length, on every platform the game ships on, Quest
## included. ai_config "lip_sync/engine" = "rhubarb" switches it off.
##
## Second: Rhubarb Lip Sync (Daniel Wolf, MIT) run as a subprocess on the wav; see
## rhubarb_path() for where it is looked for (bin/rhubarb/README.md for bundling). The phonetic recogniser takes ~0.2x realtime
## (0.6-0.9 s for a 3.5 s line) and is language-independent. It is the default for every line: the
## voice waits for the cues, and the English pocketSphinx recogniser (with the line's text) took about
## 9 s for a 3.4 s line, the lag before a pony answered (2026-10-31). ENGLISH_RECOGNISER = true
## brings it back.
## Fallback when the binary is missing: loudness windows mapped to X/B/C/D, so
## the mouth still flaps.
##
## Godot addons looked at (2026-09-07): "Baked Lipsync" (fbcosentino, asset
## 3629) bakes Rhubarb output in the editor, which does not fit lines that a
## TTS server renders at runtime; OVRLipSync via twovoip is Windows/Android.

const RHUBARB_CANDIDATES := [
	"~/tools/rhubarb/Rhubarb-Lip-Sync-1.14.0-Linux/rhubarb",
	"/usr/local/bin/rhubarb",
	"/usr/bin/rhubarb",
]
const NATIVE := preload("res://world/characters/lip_sync_native.gd")
const WINDOW := 0.04
const AMPLITUDE_LEVELS := {"X": 0.08, "B": 0.3, "C": 0.6}   # RMS / peak RMS below -> letter, else D

static var _threads: Array[Thread] = []


static var _configured_rhubarb: Variant = null
static var _configured_engine: Variant = null


## "auto" (the in-process recogniser first) or "rhubarb" (skip it), from ai_config "lip_sync/engine".
static func engine() -> String:
	if _configured_engine == null:
		_configured_engine = str(preload("res://world/ai/ai_config.gd").load_config().get_value("lip_sync/engine", "auto"))
	return str(_configured_engine)


## Rhubarb executable, first found of: $RHUBARB, ai_config "lip_sync/rhubarb_path",
## <game executable dir>/rhubarb/, <game executable dir>/runtime/rhubarb/,
## res://bin/rhubarb/<linux|windows>/ (source runs), then ~/tools and system paths.
## "" = none, and speech uses the loudness fallback.
static func rhubarb_path() -> String:
	var windows := OS.get_name() == "Windows"
	var exe_name := "rhubarb.exe" if windows else "rhubarb"
	var candidates: Array[String] = [OS.get_environment("RHUBARB")]
	if _configured_rhubarb == null:
		_configured_rhubarb = str(preload("res://world/ai/ai_config.gd").load_config().get_value("lip_sync/rhubarb_path", ""))
	candidates.append(str(_configured_rhubarb))
	var exe_dir := OS.get_executable_path().get_base_dir()
	candidates.append(exe_dir.path_join("rhubarb").path_join(exe_name))
	candidates.append(exe_dir.path_join("runtime/rhubarb").path_join(exe_name))
	candidates.append(ProjectSettings.globalize_path("res://bin/rhubarb/%s/%s" % ["windows" if windows else "linux", exe_name]))
	var home := OS.get_environment("USERPROFILE" if windows else "HOME")
	for candidate in RHUBARB_CANDIDATES:
		if home != "" or not candidate.begins_with("~"):
			candidates.append(candidate.replace("~", home))
	for path in candidates:
		if path != "" and path.is_absolute_path() and not path.contains("://") and FileAccess.file_exists(path):
			return path
	return ""


const ENGLISH_RECOGNISER := false

## Blocking. `wav_path` is res://, user:// or an absolute path.
static func analyse(wav_path: String, dialog := "") -> Array:
	var baked := chatter_cues(wav_path)
	if not baked.is_empty(): return baked
	if engine() != "rhubarb":
		var heard := NATIVE.analyse_clip(load_wav(wav_path))
		if not heard.is_empty(): return heard
	var exe := rhubarb_path()
	if exe == "":
		return amplitude_cues(load_wav(wav_path))
	var wav := ProjectSettings.globalize_path(wav_path)
	var stamp := "%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	var out_path := ProjectSettings.globalize_path("user://lipsync_%s.json" % stamp)
	var args := PackedStringArray(["-f", "json", "--extendedShapes", "GHX", "-q", "-o", out_path])
	var dialog_path := ""
	if ENGLISH_RECOGNISER and dialog.strip_edges() != "":
		dialog_path = ProjectSettings.globalize_path("user://lipsync_%s.txt" % stamp)
		var df := FileAccess.open(dialog_path, FileAccess.WRITE)
		df.store_string(dialog)
		df.close()
		args.append_array(["-r", "pocketSphinx", "-d", dialog_path])
	else:
		args.append_array(["-r", "phonetic"])
	args.append(wav)
	var output := []
	var code := OS.execute(exe, args, output, true)
	if dialog_path != "":
		DirAccess.remove_absolute(dialog_path)
	if code != 0 or not FileAccess.file_exists(out_path):
		push_warning("rhubarb failed (%d): %s" % [code, "".join(output).strip_edges().right(300)])
		return amplitude_cues(load_wav(wav_path))
	var text := FileAccess.get_file_as_string(out_path)
	DirAccess.remove_absolute(out_path)
	return parse_rhubarb(text)


## Runs analyse() on a thread; `on_done` is called on the main thread with the cues.
static func analyse_async(wav_path: String, dialog: String, on_done: Callable) -> void:
	var thread := Thread.new()
	_threads.append(thread)
	var finish := func(cues: Array) -> void:
		if thread.is_started(): thread.wait_to_finish()
		_threads.erase(thread)
		# The speaker may be gone by now (Twilight despawns at the opening's teleport).
		if on_done.is_valid(): on_done.call(cues)
	thread.start(func() -> void:
		var cues := analyse(wav_path, dialog)
		if OS.is_stdout_verbose() or "debugmouth" in preload("res://world/dev_tools.gd").user_args():
			print("lipsync: thread done, %d cues" % cues.size())
		finish.call_deferred(cues))


## Leaving the world: join analysis threads still running, so none outlives the scene.
static func join_all() -> void:
	for thread: Thread in _threads:
		if thread.is_started(): thread.wait_to_finish()
	_threads.clear()


static func parse_rhubarb(text: String) -> Array:
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		push_warning("rhubarb json: " + json.get_error_message())
		return []
	var cues: Array = []
	for cue in (json.data as Dictionary).get("mouthCues", []):
		cues.append({"start": float(cue["start"]), "end": float(cue["end"]), "value": String(cue["value"])})
	return cues


static func viseme_at(cues: Array, t: float) -> String:
	for cue in cues:
		if t >= cue["start"] and t < cue["end"]:
			return cue["value"]
	return "X"


static func duration(cues: Array) -> float:
	return 0.0 if cues.is_empty() else float(cues[-1]["end"])


static func load_wav(wav_path: String) -> AudioStreamWAV:
	if wav_path.begins_with("res://") and ResourceLoader.exists(wav_path):
		return load(wav_path) as AudioStreamWAV
	var path := ProjectSettings.globalize_path(wav_path)
	if not FileAccess.file_exists(path):
		push_warning("wav missing: " + path)
		return null
	return AudioStreamWAV.load_from_file(path)


## Loudness fallback: RMS per WINDOW, normalised by the loudest window.
static func amplitude_cues(stream: AudioStreamWAV) -> Array:
	if stream == null or stream.format != AudioStreamWAV.FORMAT_16_BITS:
		return []
	var data := stream.data
	var channels := 2 if stream.stereo else 1
	var frames_per_window := int(stream.mix_rate * WINDOW)
	var total := data.size() / (2 * channels)
	var levels: Array[float] = []
	var peak := 0.0
	var f := 0
	while f < total:
		var sum := 0.0
		var n := mini(frames_per_window, total - f)
		for i in n:
			var s := float(data.decode_s16((f + i) * 2 * channels)) / 32768.0
			sum += s * s
		var rms := sqrt(sum / maxf(1.0, n))
		levels.append(rms)
		peak = maxf(peak, rms)
		f += n
	var cues: Array = []
	for i in levels.size():
		var level := levels[i] / peak if peak > 0.0 else 0.0
		var letter := "D"
		for k in AMPLITUDE_LEVELS:
			if level < AMPLITUDE_LEVELS[k]:
				letter = k
				break
		var start := i * WINDOW
		if not cues.is_empty() and cues[-1]["value"] == letter:
			cues[-1]["end"] = start + WINDOW
		else:
			cues.append({"start": start, "end": start + WINDOW, "value": letter})
	return cues


## Locally composed speech already knows its exact timing; never transcribe its gibberish.
static func chatter_cues(wav_path: String) -> Array:
	var sidecar := wav_path + ".mouth.json"
	if not FileAccess.file_exists(sidecar): return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar))
	if not data is Dictionary or data.get("chatter_version") != 1: return []
	if data.get("wav_sha256", "") != FileAccess.get_sha256(wav_path): return []
	var stream := load_wav(wav_path)
	if stream == null: return []
	var last := 0.0
	var cues: Array = []
	for cue in data.get("mouthCues", []):
		if not cue is Dictionary or not cue.has_all(["start", "end", "value"]): return []
		if not cue.start is float and not cue.start is int: return []
		if not cue.end is float and not cue.end is int: return []
		if not is_finite(cue.start) or not is_finite(cue.end): return []
		if float(cue.start) < last - .0001 or float(cue.end) <= float(cue.start) or float(cue.end) > stream.get_length() + .001: return []
		if not cue.value in ["A","B","C","D","E","F","G","H","X"]: return []
		cues.append(cue); last = float(cue.end)
	return cues
