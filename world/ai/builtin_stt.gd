extends Node
## Bundled CPU Whisper. No Python, server or account. The bundled model is base.en; a bigger model
## that understands speech better can be chosen in the speech settings (dev 2026-10-02: "add the
## ability to change whisper models to a better, more high quality model"). It is downloaded once
## from the official whisper.cpp model repository, checked against its published SHA-256, kept in
## user://voice/models/. A selected model must be ready before transcription starts.
const ASSETS := "res://world/ai/whisper/"
const VERSION := "1.8.3-base-en-1"
const MODEL_DIR := "user://voice/models"
const SOURCE := "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
## id -> file, size (bytes), SHA-256 (from the repository's file listing), label for the settings.
const MODELS := {
	"base": {"file": "", "size": 147964211, "sha256": "", "label": "Base (fast, built in)"},
	"small": {"file": "ggml-small.en.bin", "size": 487614201, "sha256": "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", "label": "Small (better, 490 MB download)"},
	"medium": {"file": "ggml-medium.en-q5_0.bin", "size": 539225533, "sha256": "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0", "label": "Medium (much better, 540 MB download)"},
	"turbo": {"file": "ggml-large-v3-turbo-q5_0.bin", "size": 574041195, "sha256": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", "label": "Large v3 Turbo (best, 575 MB download, slower)"},
}
var status := "Not started"
var model := "base"
var _download: HTTPRequest
var _verifier: Thread
var _download_model := ""
var _verifying_model := ""
var _running_model := ""
var _model_errors: Dictionary = {}
var _selected_ready := false
var _download_status_clock := 0.0
var available := false
var _installer: Thread
var _folder := ""
var _binary := ""
var _pid := -1
var _deadline := 0.0
var _callback: Callable
var _output := ""
var _input := ""
## The desktop program's output pipes (OS.execute_with_pipe) and what it wrote to stderr, so a
## program that cannot run says why instead of "could not read this recording".
var _pipe: Dictionary = {}
var _stderr_text := ""
## Android: no program may run from app storage, so Whisper runs in-process (native/whisper_stt,
## player board #13, dev 2026-10-26: on-device whisper for Quest). One loaded model at a time;
## loading happens on _loader so a 150 MB model never stalls a frame.
var _native: RefCounted
var _native_model := ""
var _loader: Thread
var _native_busy := false

## Tests set this to run the Android path on the desktop.
var force_in_process := false

func _in_process() -> bool:
	return force_in_process or OS.get_name() == "Android"

func _ready() -> void:
	add_to_group("builtin_speech_services")

## The chosen model id (MODELS); a missing download starts once the program is installed.
func set_model(id: String) -> void:
	model = id if MODELS.has(id) else "base"
	_model_errors.erase(model)
	if available: _fetch_model()
	_refresh_status()

func _model_file(id: String) -> String:
	if id == "base" or not MODELS.has(id): return _folder.path_join("base.en.bin")
	return ProjectSettings.globalize_path(MODEL_DIR).path_join(str(MODELS[id].file))

## A selected model never falls back to a different model during preparation.
func _model_ready(id: String) -> bool:
	if not available or _verifying_model == id: return false
	var path := _model_file(id)
	if not FileAccess.file_exists(path): return false
	if id == "base": return true
	var file := FileAccess.open(path, FileAccess.READ)
	return file != null and file.get_length() == int(MODELS[id].size)

func _busy() -> bool:
	return _pid > 0 or _native_busy

func _active_model() -> String:
	return _model_file(model) if _model_ready(model) else ""

## Selection, actual in-flight model and download ownership are separate state.
func model_state() -> Dictionary:
	return {"selected": model, "active": _running_model if _busy() else (model if _selected_ready else ""),
		"downloading": _download_model, "verifying": _verifying_model, "progress": download_progress(), "status": status}

func _refresh_status(refresh_readiness := true) -> void:
	if not available: return
	if refresh_readiness: _selected_ready = _model_ready(model)
	var selected := str(MODELS[model].label)
	var active := _running_model if _busy() else (model if _selected_ready else "")
	status = "Selected: %s · Active: %s" % [selected, active.capitalize() if not active.is_empty() else "none"]
	if _busy(): status += " · Transcribing"
	if _model_errors.has(model): status += " · " + str(_model_errors[model])
	elif not _selected_ready: status += " · Selected model is preparing"
	if not _download_model.is_empty():
		var progress := download_progress()
		status += " · Downloading %s%s" % [_download_model.capitalize(), " %d%%" % int(progress * 100.0) if progress >= 0.0 else ""]
	if not _verifying_model.is_empty(): status += " · Checking " + _verifying_model.capitalize()

func _fetch_model() -> void:
	if model == "base" or _download != null or _verifier != null or _model_errors.has(model) or _model_ready(model): return
	_start_download(model)

func _start_download(id: String) -> void:
	var path := _model_file(id)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MODEL_DIR))
	_download = HTTPRequest.new()
	_download_model = id
	_download.download_file = path + ".part"
	_download.use_threads = true
	add_child(_download)
	_download.request_completed.connect(_on_downloaded.bind(id))
	if _download.request(SOURCE + str(MODELS[id].file)) != OK:
		_download.queue_free(); _download = null; _download_model = ""
		_model_errors[id] = "Could not start downloading %s. Select it again to retry." % id.capitalize()
	_refresh_status()

func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, id: String) -> void:
	_download.queue_free(); _download = null; _download_model = ""
	var part := _model_file(id) + ".part"
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		if FileAccess.file_exists(part): DirAccess.remove_absolute(part)
		_model_errors[id] = "Could not download %s (%s). Select it again to retry." % [id.capitalize(), "HTTP %d" % code if result == HTTPRequest.RESULT_SUCCESS else "network error"]
		_fetch_model(); _refresh_status(); return
	_verifying_model = id
	_verifier = Thread.new()
	if _verifier.start(_verify.bind(id)) != OK:
		_verifier = null
		_complete_verification(id, "Could not check the downloaded model. Select it again to retry.")
	_refresh_status()

## Off the main thread: hashing half a gigabyte takes a few seconds.
func _verify(id: String) -> String:
	var part := _model_file(id) + ".part"
	if FileAccess.get_sha256(part) != str(MODELS[id].sha256):
		DirAccess.remove_absolute(part)
		return "The downloaded %s model was damaged. Select it again to retry." % id.capitalize()
	if DirAccess.rename_absolute(part, _model_file(id)) != OK: return "Could not keep the downloaded %s model." % id.capitalize()
	return ""

func _complete_verification(id: String, failure: String) -> void:
	_verifying_model = ""
	if failure.is_empty(): _model_errors.erase(id)
	else: _model_errors[id] = failure
	# A selection made during the previous download is started once that work completes.
	_fetch_model(); _refresh_status()

func download_progress() -> float:
	if _download == null or _download_model.is_empty(): return -1.0
	var total := float(MODELS[_download_model].size)
	return clampf(float(_download.get_downloaded_bytes()) / total, 0.0, 1.0) if total > 0.0 else -1.0

func prepare() -> void:
	if available or _installer != null: return
	if not preload("res://world/ai/ai_config.gd").supports_builtin_stt(OS.get_name()):
		status = preload("res://world/ai/ai_config.gd").builtin_unavailable(OS.get_name()); return
	_folder = ProjectSettings.globalize_path("user://voice/" + VERSION)
	_binary = _folder.path_join("whisper-cli.exe" if OS.get_name() == "Windows" else "whisper-cli")
	if _in_process(): _binary = ""
	status = "Preparing built-in speech recognition…"
	_installer = Thread.new()
	var error: Error = _installer.start(_install.bind(OS.get_name() == "Windows", _in_process()))
	if error != OK:
		_installer = null; status = "Could not prepare speech recognition."

## In-process (Android) installs only the model: the program is the native library.
func _install(windows: bool, in_process := false) -> String:
	if DirAccess.make_dir_recursive_absolute(_folder) != OK: return "Cannot create speech recognition cache."
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(ASSETS + "manifest.json"))
	if not manifest is Dictionary: return "Speech recognition files are missing from this build."
	var packed := "windows.zip" if windows else "linux.zip"
	var marker := _folder.path_join("installed")
	var signature: String = ("native" if in_process else str(manifest[packed].sha256)) + str(manifest["base.en.bin"].sha256)
	if FileAccess.file_exists(marker) and FileAccess.get_file_as_string(marker) == signature and (in_process or FileAccess.file_exists(_binary)) and FileAccess.file_exists(_folder.path_join("base.en.bin")):
		return "" if in_process else _probe_program()
	if in_process: return _install_model(manifest, marker, signature)
	if FileAccess.get_sha256(ASSETS + packed) != str(manifest[packed].sha256): return "Speech recognition program is incomplete."
	var zip := ZIPReader.new()
	if zip.open(ASSETS + packed) != OK: return "Cannot open speech recognition program."
	for name: String in zip.get_files():
		if name != name.get_file() or name in [".", ".."]: zip.close(); return "Invalid speech recognition archive."
		var file := FileAccess.open(_folder.path_join(name), FileAccess.WRITE)
		if file == null: zip.close(); return "Cannot install speech recognition program."
		file.store_buffer(zip.read_file(name)); var error: Error = file.get_error(); file.close()
		if error != OK: zip.close(); return "Not enough space for speech recognition."
	zip.close()
	if not windows and FileAccess.set_unix_permissions(_binary, 493) != OK: return "Cannot make speech recognition executable."
	var installed := _install_model(manifest, marker, signature)
	return installed if not installed.is_empty() else _probe_program()

func _install_model(manifest: Dictionary, marker: String, signature: String) -> String:
	var source := FileAccess.open(ASSETS + "base.en.bin", FileAccess.READ)
	var model := FileAccess.open(_folder.path_join("base.en.bin"), FileAccess.WRITE)
	if source == null or model == null: return "Cannot install speech recognition model."
	while source.get_position() < source.get_length():
		model.store_buffer(source.get_buffer(1048576))
		if model.get_error() != OK: return "Not enough space for speech recognition model."
	model.close(); source.close()
	if FileAccess.get_sha256(_folder.path_join("base.en.bin")) != str(manifest["base.en.bin"].sha256): return "Speech recognition model is incomplete."
	var done := FileAccess.open(marker, FileAccess.WRITE)
	if done == null: return "Cannot finish speech recognition installation."
	done.store_string(signature); done.close()
	return ""

## The desktop program must start on this system (installer thread, once per launch): until 0.3.0
## the bundled Linux whisper-cli needed glibc 2.38, so on Linux Mint 21 (glibc 2.35) every recording
## ended as "could not read this recording" (thread 43664642). The settings say what is missing.
## Since 0.3.1 the Linux program is linked statically and needs no system library at all.
func _probe_program() -> String:
	var output: Array = []
	var code := OS.execute(_binary, PackedStringArray(["--help"]), output, true)
	return "" if code == 0 else program_failure(code, "\n".join(output))


## A player-readable reason for a desktop program that stopped without a transcript.
static func program_failure(code: int, stderr: String) -> String:
	var where := " Choose a speech server in Settings → Dialogue & microphone instead."
	if "GLIBC_" in stderr:
		var wanted := RegEx.create_from_string("GLIBC_([0-9.]+)").search(stderr)
		return "Built-in speech recognition needs a newer Linux (glibc %s or later, such as Linux Mint 22 or Ubuntu 24.04)." % (wanted.get_string(1) if wanted != null else "2.38") + where
	if "error while loading shared libraries" in stderr or code == 127:
		return "Built-in speech recognition is missing a system library (%s)." % _last_line(stderr) + where
	if code == 132 or "Illegal instruction" in stderr:
		return "Built-in speech recognition needs a processor with AVX2." + where
	if code != 0:
		var detail := _last_line(stderr)
		return "Built-in speech recognition stopped (exit %d%s); an older processor without AVX2 cannot run it." % [code, (": " + detail) if not detail.is_empty() else ""] + where
	return "Speech recognition could not read this recording."


static func _last_line(text: String) -> String:
	var lines := text.strip_edges().split("\n", false)
	return lines[lines.size() - 1].strip_edges().left(120) if not lines.is_empty() else ""


## `prompt`: Whisper's initial prompt, pony and place names to spell (speech_vocabulary.gd).
func transcribe(wav: PackedByteArray, callback: Callable, prompt := "") -> String:
	if not available: prepare(); return status
	if _busy(): return "Speech recognition is already listening to the previous recording."
	_fetch_model(); _refresh_status()
	var chosen := _active_model()
	if chosen.is_empty(): return status
	# Unique owned files also isolate simultaneous game instances.
	_output = _folder.path_join("utterance-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_input = _output + ".wav"
	_callback = callback
	# The in-process recogniser takes the bytes; only the helper program reads the file.
	if _in_process(): return _transcribe_in_process(chosen, wav, prompt)
	var file := FileAccess.open(_input, FileAccess.WRITE)
	if file == null: _callback = Callable(); return "Cannot save the microphone recording."
	file.store_buffer(wav); file.close()
	# Bigger models need more of the CPU to answer quickly; leave two cores for the game.
	var threads := clampi(OS.get_processor_count() - 2, 3, 8)
	var arguments := PackedStringArray(["-m", chosen, "-f", _input, "-of", _output, "-otxt", "-l", "en", "-t", str(threads), "-np", "-nt", "-ng", "-bs", "1", "-bo", "1"])
	if not prompt.is_empty(): arguments.append_array(PackedStringArray(["--prompt", prompt]))
	_pipe = OS.execute_with_pipe(_binary, arguments, false)
	_stderr_text = ""
	_pid = int(_pipe.get("pid", -1))
	if _pid <= 0:
		_pipe = {}
		_cleanup(); _callback = Callable(); return "Could not start built-in speech recognition."
	_deadline = Time.get_ticks_msec() * .001 + 60.0
	_running_model = model
	_refresh_status()
	return ""

func _transcribe_in_process(chosen: String, wav: PackedByteArray, prompt: String) -> String:
	_cleanup()
	if _loader != null: _callback = Callable(); return "Speech recognition is still loading its model."
	if _native == null: _native = ClassDB.instantiate("WhisperSTT")
	if _native_model != chosen:
		# Load off the main thread, then start this recording.
		_native_model = ""
		_loader = Thread.new()
		if _loader.start(_load_native.bind(chosen)) != OK:
			_loader = null; _callback = Callable(); return "Could not load the speech recognition model."
		_pending_wav = wav; _pending_prompt = prompt; _native_busy = true
		_running_model = model; _refresh_status()
		return ""
	return _start_native(wav, prompt)

var _pending_wav := PackedByteArray()
var _pending_prompt := ""

func _load_native(path: String) -> String:
	return path if _native.call("load_model", path) == OK else ""

## The game leaves two of the headset's cores to rendering and physics.
func _start_native(wav: PackedByteArray, prompt: String) -> String:
	var error: int = _native.call("start", wav, prompt, clampi(OS.get_processor_count() - 2, 2, 4))
	if error != OK:
		_native_busy = false; _callback = Callable(); _running_model = ""; _refresh_status()
		return "Speech recognition could not read this recording." if error == ERR_INVALID_DATA else "Could not start built-in speech recognition."
	_native_busy = true
	_deadline = Time.get_ticks_msec() * .001 + 60.0
	_running_model = model
	_refresh_status()
	return ""

func _native_step() -> void:
	if _loader != null:
		if _loader.is_alive(): return
		_native_model = str(_loader.wait_to_finish()); _loader = null
		var wav := _pending_wav; _pending_wav = PackedByteArray()
		if _native_model.is_empty():
			_native_busy = false; _running_model = ""
			_model_errors[model] = "Could not load the speech recognition model."
			var failed := _callback; _callback = Callable(); _refresh_status()
			if failed.is_valid(): failed.call("", "Could not load the speech recognition model.")
			return
		var error := _start_native(wav, _pending_prompt)
		if not error.is_empty():
			var failed := _callback; _callback = Callable()
			if failed.is_valid(): failed.call("", error)
		return
	if not _native_busy or _native == null: return
	var timed_out := Time.get_ticks_msec() * .001 > _deadline
	if bool(_native.call("is_running")) and not timed_out: return
	if timed_out: _native.call("cancel")
	var words := str(_native.call("take_text"))
	var error := "Speech recognition timed out." if timed_out else str(_native.call("error"))
	_native_busy = false; _running_model = ""
	var done := _callback; _callback = Callable(); _refresh_status()
	if done.is_valid(): done.call(words if error.is_empty() else "", error)

func _process(delta: float) -> void:
	if _installer != null and not _installer.is_alive():
		var error: String = _installer.wait_to_finish()
		_installer = null; available = error.is_empty()
		status = "Built-in speech recognition ready" if available else error
		if available: _fetch_model(); _refresh_status()
	if _verifier != null and not _verifier.is_alive():
		var id := _verifying_model
		var failure: String = _verifier.wait_to_finish()
		_verifier = null
		_complete_verification(id, failure)
	if _download != null:
		_download_status_clock -= delta
		if _download_status_clock <= 0.0:
			_download_status_clock = 0.35
			_refresh_status(false)
	if _in_process(): _native_step(); return
	if _pid <= 0: return
	_drain_pipes()
	if OS.is_process_running(_pid) and Time.get_ticks_msec() * .001 <= _deadline: return
	var error := ""
	if OS.is_process_running(_pid): OS.kill(_pid); error = "Speech recognition timed out."
	elif not FileAccess.file_exists(_output + ".txt"):
		_drain_pipes()
		error = program_failure(OS.get_process_exit_code(_pid), _stderr_text)
		push_warning("[speech] whisper-cli: " + _stderr_text.strip_edges().right(300))
	_close_pipes()
	var words := FileAccess.get_file_as_string(_output + ".txt").strip_edges() if error.is_empty() else ""
	_pid = -1
	var done := _callback; _callback = Callable()
	_cleanup(); _running_model = ""; _refresh_status()
	if done.is_valid(): done.call(words, error)

## Reads what the program wrote so far (non-blocking pipes, only while it runs): a full pipe would
## stall it, and stderr holds the reason it failed. The last 4 KB of stderr are kept.
func _drain_pipes() -> void:
	for key: String in ["stdio", "stderr"]:
		var pipe: Variant = _pipe.get(key)
		if not pipe is FileAccess: continue
		var chunk := (pipe as FileAccess).get_buffer(65536)
		if key == "stderr" and not chunk.is_empty(): _stderr_text = (_stderr_text + chunk.get_string_from_utf8()).right(4096)


func _close_pipes() -> void:
	for key: String in ["stdio", "stderr"]:
		var pipe: Variant = _pipe.get(key)
		if pipe is FileAccess: (pipe as FileAccess).close()
	_pipe = {}


func _cleanup() -> void:
	for path: String in [_input, _output + ".txt"]:
		if not path.is_empty() and FileAccess.file_exists(path): DirAccess.remove_absolute(path)

func cancel() -> void:
	_callback = Callable()
	if _native != null and _native_busy and _loader == null: _native.call("cancel"); _native_busy = false
	if _pid > 0 and OS.is_process_running(_pid): OS.kill(_pid)
	_close_pipes()
	_pid = -1
	_running_model = ""
	_cleanup(); _refresh_status()

func _exit_tree() -> void:
	cancel()
	if _loader != null: _loader.wait_to_finish(); _loader = null
	if _installer != null: _installer.wait_to_finish(); _installer = null
	if _verifier != null: _verifier.wait_to_finish(); _verifier = null
	if _download != null:
		_download.cancel_request()
		var part := _download.download_file
		_download = null
		if FileAccess.file_exists(part): DirAccess.remove_absolute(part)
