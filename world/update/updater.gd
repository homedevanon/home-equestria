extends Node
## In-game updater (dev 2026-10-28). A quiet check once every launch (dev 2026-10-30; it was at
## most every 6 hours; Settings > Updates turns it off) asks GitHub for the latest release of
## homedevanon/home-equestria and reads its signed update_manifest.json (update_verify.gd holds
## the rules: dev's offline RSA key signs, the game carries only the public key, so a taken-over
## repo cannot ship an update). One shared node under the tree's root (shared()) serves the title
## page, the pause menu and Settings > Updates: each shows which version this is and whether it is
## the newest (version_line()), plus an update button when a newer version is out;
## pressing it downloads this system's archive into user://update_staging/, checks the signed size
## and sha256, unpacks it there and hands over to a small script that waits for the game to close,
## moves the new files in (replaced ones go to user://update_staging/backup/, put back if any move
## fails) and starts the game again.
##
## Linux and Windows exports install in place. A game run from source or the editor, an AppImage,
## an install folder the player cannot write to, and Android/Quest only say a version is out and
## open the release page. No build key (world/update/release_public_key.pem missing) = no
## updater at all. Requests carry only a fixed User-Agent: no ids, no telemetry.

signal changed

const VERIFY := preload("res://world/update/update_verify.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const VERSION := preload("res://world/debug/version.gd")
const API := "https://api.github.com/repos/homedevanon/home-equestria/releases/latest"
const DOWNLOADS := "https://github.com/homedevanon/home-equestria/releases/download/"
const RELEASES := "https://github.com/homedevanon/home-equestria/releases"
## GitHub answers a release download with a redirect to its file host.
const FILE_HOSTS := ["objects.githubusercontent.com", "release-assets.githubusercontent.com"]
const MANIFEST := "update_manifest.json"
const USER_AGENT := "HomeEquestria-updater"
const STAGING := "user://update_staging"
const STATE := "user://update_state.cfg"

static var _told_no_key := false

## off (no key / unknown system), idle, checking, current, available, working, failed
var state := "idle"
var latest := ""
var status := ""                 # player-facing progress or problem
var platform := ""
var can_install := false
var quit_game := Callable()      # the pause menu's quit (it autosaves first)
var staging := STAGING           # tests use a temp folder
var _key: CryptoKey
var _page := RELEASES
var _manifest: Dictionary = {}
var _assets: Dictionary = {}     # release file name -> download address
var _http: HTTPRequest
var _own_roots := false          # this system's roots refused GitHub; the game's own are in use
var _check_failed := false       # the last check could not reach GitHub (the version line says so)
var _reply: Array = []
var _thread: Thread
var _stop := false
var _work := ""                  # what the worker thread does, for the progress line
var _done := 0
var _total := 0
var _views: Array[Dictionary] = []   # {button, label, line} per attach()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)   # only the progress line while installing
	_key = VERIFY.load_public_key()
	if _key == null:
		if not _told_no_key: print("[update] this build has no release key; updates are off")
		_told_no_key = true
		state = "off"; return
	platform = "linux" if OS.has_feature("linuxbsd") else "windows" if OS.has_feature("windows") else "android" if OS.has_feature("android") else ""
	if platform == "": state = "off"; return
	can_install = _why_not_install() == ""
	_http = HTTPRequest.new()
	_http.use_threads = true; _http.max_redirects = 0; _http.download_chunk_size = 1 << 20
	_http.request_completed.connect(func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void: _reply = [result, code, headers, body])
	add_child(_http)
	_after_install()
	var saved := ConfigFile.new()
	saved.load(STATE)
	var known := str(saved.get_value("check", "latest", ""))
	if VERIFY.newer(known, _version()):
		latest = known; state = "available"
		_page = str(saved.get_value("check", "page", RELEASES))
	elif known == _version() or str(saved.get_value("check", "current_for", "")) == _version():
		state = "current"
	_refresh()
	var wanted: Variant = Settings.get_value("updates/check")
	# Every launch: this node is made once per run (shared()). Headless test fixtures never call out.
	if wanted != false and DisplayServer.get_name() != "headless":
		check()


## The one updater of this run, made on first use under the tree's root (it outlives the title
## and the world, so its check and an install in progress carry over).
static func shared(from: Node) -> Node:
	var root := from.get_tree().root
	var found := root.get_node_or_null("Updater")
	if found == null:
		found = load("res://world/update/updater.gd").new(); found.name = "Updater"
		root.add_child.call_deferred(found)
	return found


## Which version this is and whether a newer one is out, for every menu that shows it.
func version_line() -> String:
	var mine := _version()
	if mine == "": return "Development copy (run from source)"
	if latest != "" and state in ["available", "working", "failed"]:
		return "You have an outdated version (%s). Newest: %s" % [mine, latest]
	if state == "current": return "You have the newest version (%s)" % mine
	if state == "checking": return "You have version %s. Checking for a newer one..." % mine
	if state == "idle" and _check_failed: return "You have version %s. Could not check for a newer one." % mine
	return "You have version %s" % mine


## The version line, an update button shown while a newer version is out, and a status line, at
## the end of box. quit replaces the game's quit while installing (the pause menu autosaves first).
func attach(box: Control, quit := Callable(), font_size := 18) -> void:
	if quit.is_valid(): quit_game = quit
	var line := STYLE.label("", "Muted", font_size - 3); line.name = "Version"
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(line)
	var button := Button.new(); button.name = "Update"; button.theme_type_variation = "Primary"
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT; button.icon = ICON.texture("sparkle", font_size + 4)
	button.custom_minimum_size.y = font_size * 2.4; button.add_theme_font_size_override("font_size", font_size)
	button.clip_text = true; button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.pressed.connect(press); box.add_child(button)
	var label := STYLE.label("", "Muted", font_size - 3); label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; box.add_child(label)
	_views.append({"button": button, "label": label, "line": line})
	_refresh()


func _refresh() -> void:
	_views = _views.filter(func(view: Dictionary) -> bool: return is_instance_valid(view.button))
	var outdated := latest != "" and state in ["available", "working", "failed"]
	var action := ("Update to %s now" if can_install else "Get %s from the release page") % latest
	for view: Dictionary in _views:
		view.line.text = version_line()
		view.button.visible = outdated
		view.button.disabled = state == "working"
		view.button.text = action
		view.label.text = status
		view.label.visible = status != "" and outdated
	changed.emit()


## The pause menu button: install here when this copy can, else open the release page.
func press() -> void:
	if state == "working": return
	if not can_install:
		OS.shell_open(_page if _page.begins_with(RELEASES + "/") else RELEASES)
		status = _why_not_install(); _refresh(); return
	install()


# ------------------------------------------------------------------ checking
## Asks GitHub for the latest release and keeps its manifest when the signature holds and the
## version is newer. Quiet: failures only log.
func check() -> bool:
	if state in ["off", "checking", "working"]: return false
	var before := state
	state = "checking"
	var saved := ConfigFile.new(); saved.load(STATE)
	saved.set_value("check", "last", Time.get_unix_time_from_system()); saved.save(STATE)
	var found := await _find_update()
	if found.has("error"):
		print("[update] check: %s" % found.error)
		state = "current" if "not newer" in str(found.error) else before if before == "available" else "idle"
		_check_failed = state == "idle"
		if state == "current": saved.set_value("check", "current_for", _version()); saved.save(STATE)
		_refresh(); return false
	_manifest = found
	_check_failed = false
	latest = str(found.version); state = "available"
	saved.set_value("check", "latest", latest); saved.set_value("check", "page", _page); saved.save(STATE)
	print("[update] version %s is available (signed manifest verified)" % latest)
	_refresh(); return true


func _find_update() -> Dictionary:
	var reply := await _fetch(API, "", 4 << 20, "application/vnd.github+json")
	if reply.has("error"): return reply
	var release: Variant = JSON.parse_string((reply.body as PackedByteArray).get_string_from_utf8())
	if not (release is Dictionary) or not ((release as Dictionary).get("assets") is Array): return {"error": "unexpected release reply"}
	var page := str((release as Dictionary).get("html_url", ""))
	if page.begins_with(RELEASES + "/"): _page = page
	_assets.clear()
	for asset: Variant in (release as Dictionary).assets:
		if not (asset is Dictionary): continue
		var url := str((asset as Dictionary).get("browser_download_url", ""))
		if _allowed(url, false): _assets[str((asset as Dictionary).get("name", ""))] = url
	if not _assets.has(MANIFEST) or not _assets.has(MANIFEST + ".sig"): return {"error": "the latest release has no signed manifest"}
	var manifest := await _fetch(str(_assets[MANIFEST]), "", 1 << 20, "application/octet-stream")
	if manifest.has("error"): return manifest
	var signature := await _fetch(str(_assets[MANIFEST + ".sig"]), "", 64 << 10, "application/octet-stream")
	if signature.has("error"): return signature
	return VERIFY.verified_manifest(manifest.body, (signature.body as PackedByteArray).get_string_from_ascii(), _key, _version())


## One GET. Redirects are followed here, one hop at a time, so each address is checked: GitHub's
## release download path first, then only its file hosts. to_file streams the body to disk.
func _fetch(url: String, to_file: String, limit: int, accept: String) -> Dictionary:
	for hop in 5:
		if not (url == API or _allowed(url, hop > 0)): return {"error": "refused address %s" % url.get_slice("?", 0)}
		_http.download_file = to_file; _http.body_size_limit = limit
		# A whole-request limit: none for multi-GB downloads, 30 s for the small replies.
		_http.timeout = 0.0 if to_file != "" else 30.0
		_reply = []
		if _http.request(url, PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: " + accept])) != OK: return {"error": "could not start a request"}
		while _reply.is_empty():
			if not await SHUTDOWN.frame(self): _http.cancel_request(); return {"error": "stopped"}
		# A PC whose root store lacks GitHub's roots (VERIFY.fallback_tls): the same address once
		# more with the game's own roots, kept for the rest of this run.
		if int(_reply[0]) == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR and not _own_roots:
			var roots := VERIFY.fallback_tls()
			if roots != null:
				_own_roots = true; _http.set_tls_options(roots)
				print("[update] %s refused this system's certificates; trying the game's own root certificates" % _host(url))
				continue
		var code := int(_reply[1])
		if code in [301, 302, 303, 307, 308]:
			url = ""
			for header: String in _reply[2]:
				if header.to_lower().begins_with("location:"): url = header.substr(9).strip_edges()
			continue
		if int(_reply[0]) != HTTPRequest.RESULT_SUCCESS or code != 200:
			return {"error": "HTTP %d from %s" % [code, _host(url)] if int(_reply[0]) == HTTPRequest.RESULT_SUCCESS else _network_problem(int(_reply[0]), _host(url))}
		return {"body": _reply[3]}
	return {"error": "too many redirects"}


static func _host(url: String) -> String:
	return url.substr(url.find("://") + 3).get_slice("/", 0) if "://" in url else url


## The reason in words with the host, so a player's log says what failed and where.
static func _network_problem(result: int, host: String) -> String:
	match result:
		HTTPRequest.RESULT_CANT_RESOLVE: return "could not look up %s: no internet, or DNS blocks it (network error 3)" % host
		HTTPRequest.RESULT_CANT_CONNECT: return "could not connect to %s: a firewall, VPN or proxy may block it (network error 2)" % host
		HTTPRequest.RESULT_CONNECTION_ERROR: return "the connection to %s broke (network error 4)" % host
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "secure connection to %s refused: check this PC's date and time; antivirus HTTPS scanning can also cause this (network error 5)" % host
		HTTPRequest.RESULT_TIMEOUT: return "%s did not answer in time (network error 13)" % host
	return "network error %d at %s" % [result, host]


static func _allowed(url: String, redirected: bool) -> bool:
	if url.begins_with(DOWNLOADS): return not ".." in url and not "@" in url.get_slice("/", 2)
	if not redirected or not url.begins_with("https://"): return false
	var host := url.substr(8).get_slice("/", 0)
	return host in FILE_HOSTS


# ------------------------------------------------------------------ installing
func install() -> void:
	if state == "working" or not can_install: return
	if _manifest.is_empty():
		status = "Checking the release..."; _refresh()
		if not await check(): status = "Could not reach the release (see the log)."; _refresh(); return
	state = "working"; _refresh(); set_process(true)
	var error := await _download_and_install()
	if error == "stopped": return
	set_process(false)
	state = "failed"; status = error; _refresh()
	print("[update] install stopped: %s" % error)


## Download, verify, unpack, then hand over to the install script. Returns why it stopped
## ("" never comes back: on success the game quits).
func _download_and_install() -> String:
	# A patch release (tools/build/release_patch.py) holds only the files changed since its base
	# full build: it installs on that base alone; any other copy needs the full download.
	var patch_base := str(_manifest.get("base", ""))
	if patch_base != "" and patch_base != VERSION.base_version():
		OS.shell_open(_page if _page.begins_with(RELEASES + "/") else RELEASES)
		return "Version %s is a small update for %s: download the full game from the release page." % [latest, patch_base]
	var parts := VERIFY.files_for(_manifest, platform)
	if parts.is_empty(): return "This release has no download for this system."
	var total := 0
	var halves := false
	for part: Dictionary in parts:
		total += int(part.size)
		halves = halves or (not _assets.has(str(part.name)) and _assets.has(str(part.name) + ".001"))
	# Download, a joined copy when it comes in parts, and the unpacked game (about 1.5x).
	var need := int(total * (3.6 if parts.size() > 1 or halves else 2.6)) + (512 << 20)
	var free := DirAccess.open("user://").get_space_left() if DirAccess.open("user://") != null else 0
	if free > 0 and free < need: return "Not enough disk space: about %.1f GB free needed." % (need / 1e9)
	DirAccess.make_dir_recursive_absolute(staging)
	var paths: Array[String] = []
	var base := 0
	for i in parts.size():
		var part: Dictionary = parts[i]
		var path := staging.path_join("part%d.bin" % i)
		paths.append(path)
		var name := str(part.name)
		var size := int(part.size); var sha := str(part.sha256)
		# A finished part from an interrupted try is checked again rather than fetched again.
		if _length(path) == size:
			var kept: Variant = await _in_thread("Checking the download", func() -> String: return VERIFY.file_matches(path, size, sha, _stopped))
			if _stop: return "stopped"
			if kept == "": base += size; continue
		# tools/release_all.py signs the whole archive but GitHub carries it as name.001, .002...
		# (2 GiB file limit): the halves are fetched, joined, and the whole is checked below.
		var pieces: Array[String] = [name]
		if not _assets.has(name):
			pieces.clear()
			while _assets.has("%s.%03d" % [name, pieces.size() + 1]): pieces.append("%s.%03d" % [name, pieces.size() + 1])
			if pieces.is_empty(): return "The release is missing %s." % name
		var segments: Array[String] = []
		var fetched := 0
		for j in pieces.size():
			var target := path if pieces.size() == 1 else "%s.%03d" % [path, j + 1]
			segments.append(target)
			_work = "download"; _done = base + fetched; _total = total
			# Never more than the signed size in all.
			var got := await _fetch(str(_assets[pieces[j]]), ProjectSettings.globalize_path(target), maxi(0, size - fetched), "application/octet-stream")
			_work = ""
			if got.has("error"): return "Download failed (%s). Press again to retry." % got.error
			fetched += maxi(0, _length(target))
		if segments.size() > 1:
			var joined_part: Variant = await _in_thread("Joining the download", _join.bind(segments, path))
			if _stop: return "stopped"
			if joined_part != true: return "Could not join the download (disk full?)."
			# The halves are emptied (kept as zero-byte files) once joined.
			for segment in segments: FileAccess.open(segment, FileAccess.WRITE)
		var checked: Variant = await _in_thread("Checking the download", func() -> String: return VERIFY.file_matches(path, size, sha, _stopped))
		if _stop: return "stopped"
		var mismatch := str(checked)
		if mismatch != "":
			# Moved aside, not deleted: the next try downloads a fresh copy over the part name.
			DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(path + ".bad"))
			print("[update] %s does not match the signed manifest (%s)" % [name, mismatch])
			return "The download does not match the signed release. Press again to retry."
		base += size
	var archive := paths[0]
	if paths.size() > 1:
		archive = staging.path_join("archive.bin")
		var joined: Variant = await _in_thread("Joining the download", _join.bind(paths, archive))
		if _stop: return "stopped"
		if joined != true: return "Could not join the download (disk full?)."
	var files := staging.path_join("files")
	var result: Variant = await _in_thread("Unpacking", func() -> Dictionary: return VERIFY.extract(archive, files, _progress, _stopped))
	if _stop or not (result is Dictionary): return "stopped"
	var unpacked: Dictionary = result
	if str(unpacked.get("error", "")) != "": return "Could not unpack the update (%s)." % unpacked.error
	return _hand_over(files, unpacked.files)


## The release archive holds one top folder (HomeEquestria-<version>-<platform>/): its files go
## straight into the install folder.
func _hand_over(files: String, written: Array) -> String:
	if written.is_empty(): return "The update is empty."
	var top := str(written[0]).get_slice("/", 0)
	var root := files
	var relative: Array[String] = []
	var shared := str(written[0]).contains("/")
	for path: Variant in written: shared = shared and str(path).begins_with(top + "/")
	if shared: root = files.path_join(top)
	for path: Variant in written: relative.append(str(path).substr(top.length() + 1) if shared else str(path))
	var install_dir := OS.get_executable_path().get_base_dir()
	var script := _write_script(ProjectSettings.globalize_path(root), relative, install_dir)
	if script.is_empty(): return "Could not write the install script."
	var pid := OS.create_process("/bin/sh", [script]) if platform == "linux" else OS.create_process("cmd.exe", ["/c", script])
	if pid <= 0: return "Could not start the installer."
	print("[update] installing %s: %d files; the game closes and starts again" % [latest, relative.size()])
	status = "Installing %s: the game restarts in a moment." % latest; _refresh()
	if quit_game.is_valid(): quit_game.call()
	else: get_tree().quit()
	return "stopped"


func _write_script(source: String, relative: Array[String], install_dir: String) -> String:
	var backup := ProjectSettings.globalize_path(staging.path_join("backup"))
	var result := ProjectSettings.globalize_path(staging.path_join("result.txt"))
	var log_path := ProjectSettings.globalize_path(staging.path_join("install.log"))
	var exe := OS.get_executable_path()
	var args: PackedStringArray = OS.get_cmdline_args()
	# The engine keeps --xr-mode for itself, so the restarted game came back with no mode and asked
	# Desktop or VR again (updater test 2026-10-28): pass on the mode this copy runs in.
	if not "--xr-mode" in args:
		var xr := XRServer.primary_interface
		args = PackedStringArray(["--xr-mode", "on" if xr != null and xr.is_initialized() else "off"]) + args
	if not OS.get_cmdline_user_args().is_empty(): args.append("--"); args.append_array(OS.get_cmdline_user_args())
	var pid := OS.get_process_id()
	var text := ""
	var path := ""
	if platform == "linux":
		path = staging.path_join("install.sh")
		var quoted: PackedStringArray = []
		for arg in args: quoted.append(_sh(arg))
		text = "#!/bin/sh\n# Home: Equestria update to %s (world/update/updater.gd): waits for the game to close,\n" % latest
		text += "# moves the new files in and the replaced ones to the backup folder, then starts the game.\n"
		text += "PID=%d\nSRC=%s\nDST=%s\nBAK=%s\nRESULT=%s\nexec >>%s 2>&1\n" % [pid, _sh(source), _sh(install_dir), _sh(backup), _sh(result), _sh(log_path)]
		text += "echo \"[update] installing %s\"\nn=0\nwhile kill -0 \"$PID\" 2>/dev/null; do\n" % latest
		text += "\tn=$((n + 1)); if [ \"$n\" -gt 300 ]; then echo \"[update] the game did not close\"; echo \"failed %s\" > \"$RESULT\"; exit 1; fi\n\tsleep 1\ndone\n" % latest
		text += "mkdir -p \"$BAK\" && : > \"$BAK/moved.list\" || exit 1\n"
		text += "start_game() { cd \"$DST\" && nohup %s %s >/dev/null 2>&1 & }\n" % [_sh(exe), " ".join(quoted)]
		text += "put() {\n\tif [ -e \"$DST/$1\" ]; then\n\t\tmkdir -p \"$(dirname \"$BAK/$1\")\" && mv -f \"$DST/$1\" \"$BAK/$1\" || return 1\n"
		text += "\t\tprintf '%s\\n' \"$1\" >> \"$BAK/moved.list\"\n\tfi\n\tmkdir -p \"$(dirname \"$DST/$1\")\" && mv -f \"$SRC/$1\" \"$DST/$1\"\n}\n"
		text += "fail() {\n\techo \"[update] could not install $1; putting the old files back\"\n"
		text += "\twhile IFS= read -r f; do mv -f \"$BAK/$f\" \"$DST/$f\"; done < \"$BAK/moved.list\"\n"
		text += "\techo \"failed %s\" > \"$RESULT\"; start_game; exit 1\n}\n" % latest
		for file in relative: text += "put %s || fail %s\n" % [_sh(file), _sh(file)]
		text += "echo \"ok %s\" > \"$RESULT\"\necho \"[update] installed %s\"\nstart_game\n" % [latest, latest]
	else:
		path = staging.path_join("install.bat")
		var quoted: PackedStringArray = []
		for arg in args:
			if "\"" in arg or "%" in arg: quoted.clear(); break   # odd arguments: start plain
			quoted.append("\"%s\"" % arg)
		var win := func(p: String) -> String: return p.replace("/", "\\").replace("%", "%%")
		var lines: PackedStringArray = ["@echo off", "chcp 65001 >nul",
			"rem Home: Equestria update to %s (world/update/updater.gd): waits for the game to close," % latest,
			"rem moves the new files in and the replaced ones to the backup folder, then starts the game.",
			"set \"SRC=%s\"" % win.call(source), "set \"DST=%s\"" % win.call(install_dir), "set \"BAK=%s\"" % win.call(backup),
			"set \"RESULT=%s\"" % win.call(result), "set \"LOG=%s\"" % win.call(log_path),
			">>\"%%LOG%%\" echo [update] installing %s" % latest, "set /a n=0", ":wait",
			"tasklist /FI \"PID eq %d\" /NH 2>nul | find \" %d \" >nul" % [pid, pid], "if errorlevel 1 goto closed",
			"set /a n+=1", "if %n% gtr 300 goto gone", "ping -n 2 127.0.0.1 >nul", "goto wait",
			":gone", ">>\"%LOG%\" echo [update] the game did not close", ">\"%%RESULT%%\" echo failed %s" % latest, "exit /b 1",
			":closed", "if not exist \"%BAK%\" mkdir \"%BAK%\"", "type nul >\"%BAK%\\moved.list\""]
		for file in relative: lines.append("call :put \"%s\" || goto fail" % file.replace("/", "\\"))
		lines.append_array([">\"%%RESULT%%\" echo ok %s" % latest, ">>\"%%LOG%%\" echo [update] installed %s" % latest, "goto start_game",
			":fail", ">>\"%LOG%\" echo [update] could not install; putting the old files back",
			"for /f \"usebackq delims=\" %%L in (\"%BAK%\\moved.list\") do move /y \"%BAK%\\%%L\" \"%DST%\\%%L\" >nul",
			">\"%%RESULT%%\" echo failed %s" % latest,
			":start_game", "start \"\" /D \"%%DST%%\" \"%s\" %s" % [win.call(exe), " ".join(quoted)], "exit /b 0",
			":put", "for %%F in (\"%BAK%\\%~1\") do if not exist \"%%~dpF\" mkdir \"%%~dpF\"",
			"if not exist \"%DST%\\%~1\" goto put_new", "move /y \"%DST%\\%~1\" \"%BAK%\\%~1\" >nul || exit /b 1",
			">>\"%BAK%\\moved.list\" echo %~1", ":put_new",
			"for %%F in (\"%DST%\\%~1\") do if not exist \"%%~dpF\" mkdir \"%%~dpF\"",
			"move /y \"%SRC%\\%~1\" \"%DST%\\%~1\" >nul || exit /b 1", "exit /b 0"])
		text = "\r\n".join(lines) + "\r\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return ""
	file.store_string(text); file.close()
	return ProjectSettings.globalize_path(path)


static func _sh(text: String) -> String:
	return "'" + text.replace("'", "'\\''") + "'"


## Why this copy cannot replace its own files ("" when it can).
func _why_not_install() -> String:
	if platform == "android": return "Install the new version from the release page."
	if OS.has_feature("editor") or not OS.has_feature("template"): return "This copy runs from source: update it there."
	if OS.get_environment("APPIMAGE") != "": return "The AppImage cannot update itself: download the new one."
	var install_dir := OS.get_executable_path().get_base_dir()
	if not FileAccess.file_exists(install_dir.path_join(OS.get_executable_path().get_file().get_basename() + ".pck")):
		return "This copy has no game pack beside it: download the new version."
	var probe := install_dir.path_join(".update-write-check")
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if file == null: return "The game folder is read-only: download the new version."
	file.close(); DirAccess.remove_absolute(probe)
	return ""


## Last run's install script left a result: log it, and empty the downloaded archive (kept as a
## file of zero bytes) once the new version runs.
func _after_install() -> void:
	var result_path := staging.path_join("result.txt")
	if not FileAccess.file_exists(result_path): return
	var result := FileAccess.get_file_as_string(result_path).strip_edges()
	if result.is_empty(): return
	print("[update] last install: %s (log: %s)" % [result, ProjectSettings.globalize_path(staging.path_join("install.log"))])
	if result == "ok " + _version():
		for name in DirAccess.get_files_at(staging):
			if name.begins_with("part") or name == "archive.bin": FileAccess.open(staging.path_join(name), FileAccess.WRITE)
	FileAccess.open(result_path, FileAccess.WRITE)


# ------------------------------------------------------------------ worker thread
## Long file work (hashing gigabytes, unpacking) runs off the main thread; the progress line
## follows it. Leaving the world stops it at the next chunk.
func _in_thread(what: String, work: Callable) -> Variant:
	_stop = false; _work = what; _done = 0; _total = 0
	_thread = Thread.new()
	_thread.start(work)
	while _thread != null and _thread.is_alive():
		if not await SHUTDOWN.frame(self): _stop = true; break
	if _thread == null: return null   # _exit_tree already joined it
	var value: Variant = _thread.wait_to_finish()
	_thread = null; _work = ""
	return value


func _stopped() -> bool:
	return _stop


func _progress(done: int, total: int) -> void:
	_done = done; _total = total


func _join(paths: Array[String], archive: String) -> bool:
	var out := FileAccess.open(archive, FileAccess.WRITE)
	if out == null: return false
	for path in paths:
		var source := FileAccess.open(path, FileAccess.READ)
		if source == null: return false
		while source.get_position() < source.get_length():
			out.store_buffer(source.get_buffer(VERIFY.CHUNK))
			if out.get_error() != OK or _stop: return false
	return true


func _process(_delta: float) -> void:
	if state != "working" or _work == "": return
	var text := status
	if _work == "download":
		var got := _done + maxi(0, _http.get_downloaded_bytes())
		text = "Downloading %s: %.1f of %.1f GB (%d%%)" % [latest, got / 1e9, _total / 1e9, roundi(100.0 * got / maxi(1, _total))]
	elif _total > 0: text = "%s: %d%%" % [_work, roundi(100.0 * _done / _total)]
	else: text = _work + "..."
	if text != status: status = text; _refresh()


func _exit_tree() -> void:
	_stop = true
	if _thread != null and _thread.is_started(): _thread.wait_to_finish()
	_thread = null


## The running version: a patch pack's own when one is mounted (world/debug/version.gd).
static func _version() -> String:
	var version := VERSION.text()
	return "" if version == "dev" else version


static func _length(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ) if FileAccess.file_exists(path) else null
	return file.get_length() if file != null else -1
