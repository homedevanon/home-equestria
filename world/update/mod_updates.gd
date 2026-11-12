extends Node
## Bundled-mod updates (dev 2026-11-08, M-MOD-09). The install carries the authors' own packs in
## mods/bundled/ with bundled_mods.json (id, version, sha256, update_url ...; staged by the private
## tools/bundled_mods/stage.py). Two ways a newer pack arrives, both written only under
## user://mods/bundled_updates/ (the install folder is never written) and recorded in its index.json:
##
## 1. The signed update manifest (world/update/updater.gd, update_verify.gd) may carry
##    "mods": {"<id>": {"version", "url", "sha256", "size", "min_game"}}. dev's offline key signs it,
##    so an entry newer than the installed version is downloaded on the updater's normal check.
## 2. A bundled mod whose author publishes an update address (update_url, https) can be asked for a
##    small JSON {version, url, sha256[, size]}. That is only an offer: Settings > Mods shows it as
##    "Update from the author" and the pack is fetched when the player presses it.
##
## Every download is https, size-capped, follows at most 5 redirects (https only), retries once with
## the game's own TLS roots like the updater, and must match its sha256 before it gets its final
## name. Nothing is ever run here: world/modding/mod_loader.gd mounts an update on the next start
## instead of the bundled file when its version is higher and its sha256 still matches the index.
##
##   index.json: {"format": 1, "mods": {"<id>": {"version", "file", "sha256", "source": "manifest"|"author"}}}
##
## API for Settings > Mods: shared(node), available() -> Array[Dictionary], check_authors() (await,
## on the player's press), install(id) -> bool (await), installed_version(id), status, signal changed.

signal changed

const VERIFY := preload("res://world/update/update_verify.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const BUNDLED := preload("res://world/modding/bundled_mods.gd")
const UPDATES := "user://mods/bundled_updates"
const BUNDLED_INDEX := "bundled_mods.json"
const USER_AGENT := "HomeEquestria-updater"
const AUTHOR_JSON_LIMIT := 64 * 1024

var updates_dir := UPDATES        # tests use a temp folder
var bundled_dir_override := ""    # tests: the folder holding bundled_mods.json
var game_version := ""            # tests: the running version ("" = world/debug/version.gd)
## Tests: func(url, to_file, limit, accept) -> [result, code, headers, body] in place of the network.
var transport := Callable()
var status := ""                  # the last thing that happened, for Settings > Mods
var busy := false
var _offers: Dictionary = {}      # id -> author offer {id, version, url, sha256, size, min_game}
var _http: HTTPRequest
var _reply: Array = []
var _own_roots := false
## The node shared() made: a second call before the deferred add_child ran (the updater's check and
## Settings > Mods in one frame) gets the same node instead of a second updater with its own offers.
static var _made: Node = null


## The one mod updater of this run, under the tree's root (made on first use).
## Settings > Mods may be built before its page enters the tree (game.gd _ready -> settings_menu
## setup): the main loop's tree is used then. null when there is no tree at all.
static func shared(from: Node) -> Node:
	if is_instance_valid(_made) and not _made.is_queued_for_deletion(): return _made
	var tree: SceneTree = from.get_tree() if from != null and from.is_inside_tree() else Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null: return null
	var root := tree.root
	var found := root.get_node_or_null("ModUpdates")
	if found == null:
		found = load("res://world/update/mod_updates.gd").new(); found.name = "ModUpdates"
		root.add_child.call_deferred(found)
	_made = found
	return found


## shared() adds this node on the next idle step; a press right after it waits for that, through
## world/shutdown_waits.gd so a quit in between ends the wait. False when it never got there.
func _wait_in_tree() -> bool:
	if is_inside_tree() or transport.is_valid(): return true
	var tree := Engine.get_main_loop() as SceneTree
	for _i in 10:
		if tree == null or not await SHUTDOWN.frame(tree.root): return false
		if is_inside_tree(): return true
	return false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ------------------------------------------------------------------ what is installed
## The install's bundled-mods folder, the one the loader reads (world/modding/bundled_mods.gd dir()).
static func bundled_dir() -> String:
	return BUNDLED.dir()


## {id: entry of bundled_mods.json} for the install's bundled mods; debug-only ones (D-36) only
## while they load (world/modding/mod_loader.gd debug_mods_allowed()).
func bundled() -> Dictionary:
	var dir := bundled_dir_override if bundled_dir_override != "" else bundled_dir()
	var out := {}
	if dir == "" or not FileAccess.file_exists(dir.path_join(BUNDLED_INDEX)): return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(BUNDLED_INDEX)))
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("mods") is Array): return out
	for entry: Variant in (parsed as Dictionary).mods:
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) != "": out[str((entry as Dictionary).id)] = entry
	if out.values().any(func(entry: Dictionary) -> bool: return entry.get("debug_only", false) == true) \
			and not bool((load("res://world/modding/mod_loader.gd") as GDScript).call("debug_mods_allowed")):
		for id: String in out.keys():
			if (out[id] as Dictionary).get("debug_only", false) == true: out.erase(id)
	return out


## index.json's mods, {id: {version, file, sha256, source}}.
func index() -> Dictionary:
	var path := updates_dir.path_join("index.json")
	if not FileAccess.file_exists(path): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("mods") is Dictionary): return {}
	return (parsed as Dictionary).mods


## The version that mounts for this id: a downloaded update whose file still matches its sha256,
## else the bundled pack's.
func installed_version(id: String) -> String:
	var shipped := str(bundled().get(id, {}).get("version", ""))
	var update: Variant = index().get(id)
	if update is Dictionary:
		var entry: Dictionary = update
		var path := updates_dir.path_join(str(entry.get("file", "")))
		if VERIFY.newer(str(entry.get("version", "")), shipped) and FileAccess.file_exists(path) \
				and VERIFY.sha256_file(path) == str(entry.get("sha256", "")).to_lower():
			return str(entry.version)
	return shipped


## Author updates the player can install now: [{id, title, installed, version, source, size}].
func available() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var shipped := bundled()
	for id: String in _offers:
		var offer: Dictionary = _offers[id]
		if not VERIFY.newer(str(offer.version), installed_version(id)): continue
		out.append({"id": id, "title": str(shipped.get(id, {}).get("title", id)), "installed": installed_version(id),
			"version": str(offer.version), "source": "author", "size": int(offer.size)})
	return out


func _running() -> String:
	if game_version != "": return game_version
	var text: String = preload("res://world/debug/version.gd").text()
	return "" if text == "dev" else text


# ------------------------------------------------------------------ signed manifest
## The updater's check handed over the newest release's manifest: every "mods" entry for a
## bundled mod, newer than what is installed and made for this game version, is downloaded.
## Returns how many were installed.
func from_signed_manifest(manifest_bytes: PackedByteArray, sig_text: String, key: CryptoKey) -> int:
	var document := VERIFY.signed_document(manifest_bytes, sig_text, key)
	if document.has("error"):
		print("[mod updates] manifest refused: %s" % document.error); return 0
	if not (document.get("mods") is Dictionary): return 0
	if busy: return 0
	busy = true
	var count := 0
	var shipped := bundled()
	for id: Variant in document.mods:
		var offer := VERIFY.mod_offer(str(id), document.mods[id])
		if offer.has("error"): print("[mod updates] signed entry refused: %s" % offer.error); continue
		if not shipped.has(offer.id): continue   # only bundled mods have a version to update
		if not VERIFY.newer(str(offer.version), installed_version(offer.id)): continue
		if offer.min_game != "" and VERIFY.newer(str(offer.min_game), _running()):
			print("[mod updates] %s %s needs the game %s or newer" % [offer.id, offer.version, offer.min_game]); continue
		var error := await _download(offer, "manifest")
		if error == "": count += 1
		else: print("[mod updates] %s %s: %s" % [offer.id, offer.version, error])
	busy = false
	if count > 0: status = "%d bundled mod update%s downloaded; they load the next time the game starts." % [count, "" if count == 1 else "s"]
	changed.emit()
	return count


# ------------------------------------------------------------------ author channel
## Asks every bundled mod's update_url (the player pressed "Check for mod updates"). Offers only;
## nothing is downloaded. Returns how many offers there are.
func check_authors() -> int:
	if busy: return available().size()
	busy = true
	if not await _wait_in_tree(): busy = false; return 0
	var shipped := bundled()
	for id: String in shipped:
		var address := str(shipped[id].get("update_url", ""))
		if address == "": continue
		var offer := await author_offer(id, address)
		if offer.has("error"): print("[mod updates] %s: %s" % [id, offer.error]); continue
		_offers[id] = offer
	busy = false
	var count := available().size()
	status = "No mod updates from the authors." if count == 0 else "%d mod update%s from the authors." % [count, "" if count == 1 else "s"]
	changed.emit()
	return count


## One author's small update JSON {version, url, sha256[, size]} read from an https address, or
## {"error"}.
func author_offer(id: String, address: String) -> Dictionary:
	if not address.begins_with("https://"): return {"error": "update address is not https"}
	var reply := await _fetch(address, "", AUTHOR_JSON_LIMIT)
	if reply.has("error"): return reply
	var parsed: Variant = JSON.parse_string((reply.body as PackedByteArray).get_string_from_utf8())
	if not (parsed is Dictionary): return {"error": "the update address did not answer with JSON"}
	var offer := VERIFY.mod_offer(id, parsed)
	if offer.has("error"): return offer
	if not VERIFY.newer(str(offer.version), installed_version(id)): return {"error": "no newer version (%s)" % offer.version}
	return offer


## The player pressed "Update from the author" for this mod.
func install(id: String) -> bool:
	if busy or not _offers.has(id): return false
	var offer: Dictionary = _offers[id]
	if not VERIFY.newer(str(offer.version), installed_version(id)): return false
	busy = true; status = "Downloading %s %s..." % [id, offer.version]; changed.emit()
	if not await _wait_in_tree(): busy = false; status = ""; changed.emit(); return false
	var error := await _download(offer, "author")
	busy = false
	status = "%s %s loads the next time the game starts." % [id, offer.version] if error == "" else "Could not update %s: %s" % [id, error]
	if error == "": _offers.erase(id)
	changed.emit()
	return error == ""


# ------------------------------------------------------------------ download
## Download to <id>-<version>.pck.part, check size and sha256, then rename and record it. ""
## on success; on any failure nothing new is left in the folder.
func _download(offer: Dictionary, source: String) -> String:
	DirAccess.make_dir_recursive_absolute(updates_dir)
	var name := "%s-%s.pck" % [offer.id, offer.version]
	var final := updates_dir.path_join(name)
	var part := final + ".part"
	var limit := int(offer.size) if int(offer.size) > 0 else VERIFY.MAX_MOD_BYTES
	var reply := await _fetch(str(offer.url), ProjectSettings.globalize_path(part), limit)
	if reply.has("error"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part)); return str(reply.error)
	var size := -1
	if FileAccess.file_exists(part):
		var file := FileAccess.open(part, FileAccess.READ)
		if file != null: size = file.get_length(); file.close()
	var mismatch := VERIFY.file_matches(part, size if int(offer.size) <= 0 else int(offer.size), str(offer.sha256))
	if size <= 0 or mismatch != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part))
		return "the download does not match its sha256 (%s)" % (mismatch if mismatch != "" else "empty")
	if FileAccess.file_exists(final): DirAccess.remove_absolute(ProjectSettings.globalize_path(final))
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(part), ProjectSettings.globalize_path(final)) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part)); return "could not save the pack"
	var mods := index()
	var replaced := str(mods.get(offer.id, {}).get("file", "")) if mods.get(offer.id) is Dictionary else ""
	mods[offer.id] = {"version": offer.version, "file": name, "sha256": offer.sha256, "source": source}
	if not _write_index(mods): return "could not write index.json"
	# The previous update of this mod is no longer listed: its file goes (it may still be mounted
	# this run on Windows, where the removal then simply fails and the file is ignored).
	if replaced != "" and replaced != name: DirAccess.remove_absolute(ProjectSettings.globalize_path(updates_dir.path_join(replaced)))
	print("[mod updates] %s %s saved from the %s (%d bytes, sha256 checked)" % [offer.id, offer.version, source, size])
	return ""


func _write_index(mods: Dictionary) -> bool:
	var path := updates_dir.path_join("index.json")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify({"format": 1, "mods": mods}, "\t") + "\n"); file.close()
	if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path)) == OK


## One GET with redirects followed here (https only, at most 5 hops). to_file streams to disk.
func _fetch(url: String, to_file: String, limit: int) -> Dictionary:
	for hop in 6:
		if hop == 5: return {"error": "too many redirects"}
		if not url.begins_with("https://") or "@" in url.substr(8).get_slice("/", 0): return {"error": "refused address %s" % url.get_slice("?", 0)}
		var reply: Array = await _request(url, to_file, limit)
		if reply.is_empty(): return {"error": "stopped"}
		if int(reply[0]) == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR and not _own_roots and _http != null and not transport.is_valid():
			var roots := VERIFY.fallback_tls()
			if roots != null: _own_roots = true; _http.set_tls_options(roots); continue
		var code := int(reply[1])
		if int(reply[0]) in [HTTPRequest.RESULT_SUCCESS, HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED] and code in [301, 302, 303, 307, 308]:
			url = ""
			for header: Variant in reply[2]:
				if str(header).to_lower().begins_with("location:"): url = str(header).substr(9).strip_edges()
			continue
		if int(reply[0]) != HTTPRequest.RESULT_SUCCESS or code != 200:
			return {"error": "HTTP %d" % code if int(reply[0]) == HTTPRequest.RESULT_SUCCESS else "network error %d" % int(reply[0])}
		return {"body": reply[3]}
	return {"error": "too many redirects"}


func _request(url: String, to_file: String, limit: int) -> Array:
	if transport.is_valid(): return transport.call(url, to_file, limit, "application/octet-stream")
	if _http == null:
		if not is_inside_tree(): return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
		_http = HTTPRequest.new(); _http.use_threads = true; _http.max_redirects = 0
		_http.request_completed.connect(func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void: _reply = [result, code, headers, body])
		add_child(_http)
	_http.download_file = to_file; _http.body_size_limit = limit
	_http.timeout = 120.0 if to_file != "" else 30.0
	_reply = []
	if _http.request(url, PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: application/octet-stream"])) != OK:
		return [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
	while _reply.is_empty():
		if not await SHUTDOWN.frame(self): _http.cancel_request(); return []
	return _reply
