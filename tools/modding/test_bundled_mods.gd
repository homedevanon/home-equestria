extends SceneTree
## Bundled mods and the loader's held/superseded/patch rules (world/modding/bundled_mods.gd,
## mod_loader.gd; dev 2026-11-08, M-MOD-03/05/07/08). Tiny packs are built here with PCKPacker in
## user:// (the fixture texts are in tools/modding/fixtures/loader/): default-on and default-off
## bundled mods, the player's switch kept by mod id across a renamed update, a player's copy
## superseded by a higher bundled version and the other way round, a patch pack mounting right
## after its parent and switching with it, a covered old pack not held, an uncovered old world/game.gd
## replacer held with a reason, mod.json "depends", unknown mod.json keys, a downloaded update with a
## wrong sha256 ignored and a good one mounted, a pack without the build tool's marker still
## recognised, and the compile check of an allowed old pack's script copies. Expected engine
## errors: the deliberately broken script copy prints one parse error.
##   XDG_DATA_HOME=<scratch>/mod-bundled-test python3 tools/run_owned_godot.py --project home-equestria-public \
##       --wait-for-slot 1800 --expect BUNDLED_MODS_DONE --log LOG res://tools/modding/test_bundled_mods.gd
const LOADER := preload("res://world/modding/mod_loader.gd")
const BUNDLED := preload("res://world/modding/bundled_mods.gd")
const FIXTURES := "res://tools/modding/fixtures/loader/"
const DOORWAY := "res://world/buildings/open_doorway.gd"
const CROSSHAIR := "res://world/ui/desktop_crosshair.gd"
const HOME := "res://world/buildings/zecora/zecora_home.gd"
const IDENTITY := "res://world/characters/zecora/zecora_identity.gd"
var failures := 0
var checks := 0
var temp := ""
var sources := 0

func _initialize() -> void: run.call_deferred()
func check(ok: bool, text: String) -> void:
	checks += 1
	print("[bundled] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

## A pack of {res:// path: text} written with PCKPacker; its sha256.
func pack(path: String, files: Dictionary) -> String:
	var packer := PCKPacker.new()
	packer.pck_start(path)
	for target: String in files:
		var source := temp.path_join("src_%d" % sources); sources += 1
		var file := FileAccess.open(source, FileAccess.WRITE); file.store_string(str(files[target])); file.close()
		packer.add_file(target, source)
	packer.flush()
	return FileAccess.get_sha256(path)

func manifest(id: String, version: String, extra: Dictionary = {}) -> String:
	var doc := {"id": id, "name": id.capitalize(), "version": version, "author": "Tester"}
	doc.merge(extra, true)
	return JSON.stringify(doc)

func fixture(name: String) -> String:
	return FileAccess.get_file_as_string(FIXTURES + name)

func entry(id: String, version: String, file: String, sha: String, default_on: bool, order: int, extra: Dictionary = {}) -> Dictionary:
	var out := {"id": id, "title": id.capitalize(), "author": "Tester", "version": version, "file": file, "sha256": sha,
		"default_on": default_on, "source_url": "https://example.invalid/" + id, "order": order}
	out.merge(extra, true)
	return out

func write_json(path: String, data: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE); file.store_string(JSON.stringify(data, "\t")); file.close()

func row_of(file: String) -> Dictionary:
	for row: Dictionary in LOADER.pack_rows():
		if row.file == file: return row
	return {}

func mod_of(id: String) -> Dictionary:
	for mod: Dictionary in LOADER.mods:
		if mod.id == id: return mod
	return {}

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("mod-bundled-test"):
		printerr("BUNDLED_MODS_REFUSED requires an isolated XDG_DATA_HOME"); quit(1); return
	temp = ProjectSettings.globalize_path("user://bundled_test")
	var b1 := temp.path_join("install1/mods/bundled"); var b2 := temp.path_join("install2/mods/bundled")
	var user := temp.path_join("user_mods"); var updates := temp.path_join("bundled_updates")
	var empty := temp.path_join("none")
	for dir: String in [b1, b2, user, updates, empty]: DirAccess.make_dir_recursive_absolute(dir)
	LOADER.updates_dir = updates
	var now := LOADER.game_version()
	check(BUNDLED.dir() == "", "a source run without --bundled-dir has no bundled folder")

	# ---- install 1: the bundled folder
	var mods: Array = []
	mods.append(entry("bon", "1.0.0", "bon.pck", pack(b1.path_join("bon.pck"), {"res://mods/bon/mod.json": manifest("bon", "1.0.0"), "res://mods/bon/who.txt": "bon 1"}), true, 10))
	mods.append(entry("boff", "1.0.0", "boff.pck", pack(b1.path_join("boff.pck"), {"res://mods/boff/mod.json": manifest("boff", "1.0.0")}), false, 20))
	mods.append(entry("sup_b", "1.2.0", "sup_b.pck", pack(b1.path_join("sup_b.pck"), {"res://mods/sup_b/mod.json": manifest("sup_b", "1.2.0"), "res://mods/sup_b/who.txt": "bundled"}), true, 30))
	mods.append(entry("sup_u", "1.0.0", "sup_u.pck", pack(b1.path_join("sup_u.pck"), {"res://mods/sup_u/mod.json": manifest("sup_u", "1.0.0"), "res://mods/sup_u/who.txt": "bundled"}), true, 40))
	# An old pack replacing a game script, and devanon's patch pack made for exactly its version
	# that replaces the same file again (listed first in the manifest: it still mounts after it).
	mods.append(entry("parent_patch", "1.0.0", "parent_patch.pck", pack(b1.path_join("parent_patch.pck"), {
		"res://mods/parent_patch/mod.json": manifest("parent_patch", "1.0.0", {"game_version": now}),
		DOORWAY: fixture("doorway_patched.gd.txt")}), true, 5, {"patches": {"parent": "1.2.0"}}))
	mods.append(entry("parent", "1.2.0", "parent.pck", pack(b1.path_join("parent.pck"), {
		"res://mods/parent/mod.json": manifest("parent", "1.2.0", {"game_version": "0.0.1"}),
		DOORWAY: fixture("doorway_parent.gd.txt")}), true, 50))
	# An old pack replacing world/game.gd with no patch: held.
	mods.append(entry("lonely", "1.0.0", "lonely.pck", pack(b1.path_join("lonely.pck"), {
		"res://mods/lonely/mod.json": manifest("lonely", "1.0.0", {"game_version": "0.0.1"}),
		"res://world/game.gd": "extends Node\nconst OLD_GAME := true\n"}), true, 60))
	mods.append(entry("wrong_patch", "1.0.0", "wrong_patch.pck", pack(b1.path_join("wrong_patch.pck"), {
		"res://mods/wrong_patch/mod.json": manifest("wrong_patch", "1.0.0"), "res://mods/wrong_patch/who.txt": "wrong"}), true, 70, {"patches": {"sup_b": "9.9.9"}}))
	mods.append(entry("upd", "1.0.0", "upd.pck", pack(b1.path_join("upd.pck"), {"res://mods/upd/mod.json": manifest("upd", "1.0.0"), "res://mods/upd/who.txt": "bundled"}), true, 80))
	mods.append(entry("upd_ok", "1.0.0", "upd_ok.pck", pack(b1.path_join("upd_ok.pck"), {"res://mods/upd_ok/mod.json": manifest("upd_ok", "1.0.0"), "res://mods/upd_ok/who.txt": "bundled"}), true, 90))
	write_json(b1.path_join("bundled_mods.json"), {"format": 1, "mods": mods})
	# Downloaded updates: one whose file no longer matches the index, one that does.
	pack(updates.path_join("upd-1.1.0.pck"), {"res://mods/upd/mod.json": manifest("upd", "1.1.0"), "res://mods/upd/who.txt": "update"})
	var good := pack(updates.path_join("upd_ok-1.1.0.pck"), {"res://mods/upd_ok/mod.json": manifest("upd_ok", "1.1.0"), "res://mods/upd_ok/who.txt": "update"})
	write_json(updates.path_join("index.json"), {"format": 1, "mods": {
		"upd": {"version": "1.1.0", "file": "upd-1.1.0.pck", "sha256": "0".repeat(64), "source": "manifest"},
		"upd_ok": {"version": "1.1.0", "file": "upd_ok-1.1.0.pck", "sha256": good, "source": "manifest"}}})
	# ---- the player's own mods folder
	pack(user.path_join("a_sup_b.pck"), {"res://mods/sup_b/mod.json": manifest("sup_b", "1.0.0"), "res://mods/sup_b/who.txt": "user"})
	pack(user.path_join("a_sup_u.pck"), {"res://mods/sup_u/mod.json": manifest("sup_u", "2.0.0"), "res://mods/sup_u/who.txt": "user"})
	pack(user.path_join("dep_missing.pck"), {"res://mods/needs_x/mod.json": manifest("needs_x", "1.0.0", {"depends": {"not_here": ">=1.0.0"}})})
	pack(user.path_join("dep_old.pck"), {"res://mods/needs_bon/mod.json": manifest("needs_bon", "1.0.0", {"depends": {"bon": ">=2.0.0"}})})
	pack(user.path_join("dep_ok.pck"), {"res://mods/uses_bon/mod.json": manifest("uses_bon", "1.0.0", {"depends": {"bon": ">=1.0"}})})
	pack(user.path_join("keys.pck"), {"res://mods/odd_keys/mod.json": manifest("odd_keys", "1.0.0", {"future_key": {"start": "somewhere"}, "whatever": 5, "update_url": "http://not-https.invalid/x.json"})})
	# A pack with no build marker for a mod whose folder also exists in this source tree (M-MOD-07).
	pack(user.path_join("plain_dinnerbone.pck"), {"res://mods/dinnerbone/mod.json": FileAccess.get_file_as_string("res://mods/dinnerbone/mod.json")})

	# A source run pays about a second once, for its first mounted pack (res:// becomes pack-backed);
	# an exported game already runs from packs. Paid here first so the boot is timed as players see it.
	var prime := temp.path_join("prime.pck")
	pack(prime, {"res://tools/modding/fixtures/loader/prime_marker.txt": "prime"})
	ProjectSettings.load_resource_pack(prime, true)
	var started := Time.get_ticks_usec()
	LOADER.boot([user], [empty], PackedStringArray(), b1)
	var boot_ms := (Time.get_ticks_usec() - started) / 1000.0
	print("[bundled] boot with %d packs took %.1f ms" % [LOADER.packs.size(), boot_ms])
	var files: Array = LOADER.packs.map(func(row: Dictionary) -> String: return row.file)
	check(files.slice(0, 2) == ["bundled/bon.pck", "bundled/boff.pck"] and files.find("bundled/upd_ok.pck") < files.find("a_sup_b.pck"), "bundled packs mount first, in manifest order (%s)" % str(files))
	var bon := row_of("bundled/bon.pck"); var boff := row_of("bundled/boff.pck")
	check(bon.enabled and bon.switched_on and bon.bundled and bon.switchable and FileAccess.get_file_as_string("res://mods/bon/who.txt") == "bon 1", "a default-on bundled mod loads (%s)" % str(bon))
	check(not boff.enabled and not boff.switched_on and not FileAccess.file_exists("res://mods/boff/mod.json"), "a default-off bundled mod stays off and unmounted")
	var page: Control = load("res://world/ui/settings_page.gd").new()
	check(str(page.call("_mod_notes", boff)).contains("Off until you switch it on"), "and the Mods screen says so")
	# Supersede both ways.
	var sup_b_user := row_of("a_sup_b.pck"); var sup_u := row_of("bundled/sup_u.pck")
	check(not sup_b_user.enabled and str(sup_b_user.superseded_by) == "Sup B 1.2.0" and not sup_b_user.switchable and FileAccess.get_file_as_string("res://mods/sup_b/who.txt") == "bundled", "a player's lower copy is superseded by the bundled one (%s)" % str(sup_b_user.reason))
	check(not sup_u.enabled and str(sup_u.superseded_by).contains("2.0.0") and FileAccess.get_file_as_string("res://mods/sup_u/who.txt") == "user" and row_of("a_sup_u.pck").enabled, "a player's higher copy supersedes the bundled one (%s)" % str(sup_u.reason))
	# Patch pack after its parent, covering it.
	var parent := row_of("bundled/parent.pck"); var patch := row_of("bundled/parent_patch.pck")
	check(files.find("bundled/parent_patch.pck") == files.find("bundled/parent.pck") + 1, "the patch pack mounts right after the pack it patches (%s)" % str(files))
	check(parent.enabled and not parent.held and patch.enabled and patch.patch_of == "bundled/parent.pck" and not patch.switchable, "an old pack fully covered by its patch is not held; the patch has no switch of its own")
	check(FileAccess.get_file_as_string(DOORWAY).contains("PATCHED"), "and the patch's copy of the game file wins")
	check(str(page.call("_mod_notes", parent)).contains("Includes devanon's patch Parent Patch 1.0.0"), "the Mods screen lists the patch under its parent (%s)" % str(page.call("_mod_notes", parent)))
	var wrong := row_of("bundled/wrong_patch.pck")
	check(not wrong.enabled and str(wrong.reason).contains("9.9.9") and not FileAccess.file_exists("res://mods/wrong_patch/who.txt"), "a patch made for another version of its mod stays off with a reason (%s)" % str(wrong.reason))
	# Uncovered old game.gd replacer.
	var lonely := row_of("bundled/lonely.pck")
	check(lonely.held and not lonely.enabled and str(lonely.reason).contains("Made for game 0.0.1") and not FileAccess.get_file_as_string("res://world/game.gd").contains("OLD_GAME"), "an uncovered old world/game.gd replacer stays held with a reason (%s)" % str(lonely.reason))
	check(str(lonely.warning).contains("world/game.gd"), "and its row warns that it replaces world/game.gd")
	# Dependencies and unknown keys.
	check(str(mod_of("needs_x").errors).contains("needs not_here") and not row_of("dep_missing.pck").reason.is_empty(), "a missing dependency is a mod error with a reason (%s)" % str(mod_of("needs_x").errors))
	check(str(mod_of("needs_bon").errors).contains("1.0.0 is installed"), "an older dependency is a mod error (%s)" % str(mod_of("needs_bon").errors))
	check(mod_of("uses_bon").errors.is_empty() and LOADER.active().has(mod_of("uses_bon")), "a met dependency runs")
	var odd := mod_of("odd_keys")
	check(odd.errors.is_empty() and LOADER.active().has(odd) and str(odd.update_url).is_empty(), "unknown mod.json keys are harmless; an http update_url is dropped (%s)" % str(odd.errors))
	# Updates.
	var upd := row_of("bundled/upd.pck"); var upd_ok := row_of("bundled/upd_ok.pck")
	check(upd.version == "1.0.0" and str(upd.update).is_empty() and FileAccess.get_file_as_string("res://mods/upd/who.txt") == "bundled", "an update whose sha256 does not match the index is ignored (%s)" % str(upd))
	check(upd_ok.version == "1.1.0" and upd_ok.update == "manifest" and FileAccess.get_file_as_string("res://mods/upd_ok/who.txt") == "update", "a matching newer update mounts instead of the bundled file (%s)" % str(upd_ok))
	check(row_of("plain_dinnerbone.pck").ids == ["dinnerbone"], "a pack without the build marker is recognised by its mod.json (%s)" % str(row_of("plain_dinnerbone.pck").ids))

	# ---- the player's switches, kept by id across an update that renames the file
	LOADER.set_enabled("bundled/bon.pck", false)
	LOADER.set_enabled("bundled/boff.pck", true)
	LOADER.set_enabled("bundled/parent.pck", false)
	check(not BUNDLED.is_on("bon", true) and BUNDLED.is_on("boff", false), "switches are saved by mod id")
	check(LOADER.disabled_files().is_empty(), "and never land in the player's file list")
	var mods2: Array = []
	mods2.append(entry("bon", "1.1.0", "bon-1.1.0.pck", pack(b2.path_join("bon-1.1.0.pck"), {"res://mods/bon/mod.json": manifest("bon", "1.1.0")}), true, 10))
	mods2.append(entry("boff", "1.0.0", "boff.pck", pack(b2.path_join("boff.pck"), {"res://mods/boff/mod.json": manifest("boff", "1.0.0")}), false, 20))
	for name: String in ["parent.pck", "parent_patch.pck"]: DirAccess.copy_absolute(b1.path_join(name), b2.path_join(name))
	for item: Dictionary in mods:
		if item.id in ["parent", "parent_patch"]: mods2.append(item)
	write_json(b2.path_join("bundled_mods.json"), {"format": 1, "mods": mods2})
	LOADER.boot([empty], [empty], PackedStringArray(), b2)
	check(not row_of("bundled/bon-1.1.0.pck").enabled and row_of("bundled/boff.pck").enabled and FileAccess.file_exists("res://mods/boff/mod.json"), "after an update renames the file the switches still hold; the opted-in mod loads")
	var parent2 := row_of("bundled/parent.pck"); var patch2 := row_of("bundled/parent_patch.pck")
	check(not parent2.enabled and not patch2.enabled and str(patch2.reason).contains("Off while") and not bool(patch2.switched_on), "switching the parent off switches its patch off (%s)" % str(patch2.reason))

	# ---- source-run staging layout (Nov 8 bug): packs in <folder>/<file>, folder name != mod id
	var staged := temp.path_join("staged")
	DirAccess.make_dir_recursive_absolute(staged.path_join("pony_dances"))
	pack(staged.path_join("pony_dances").path_join("sub_mod.pck"), {"res://mods/sub_mod/mod.json": manifest("sub_mod", "1.0.0")})
	write_json(staged.path_join("bundled_mods.json"), {"format": 1, "mods": [entry("sub_mod", "1.0.0", "sub_mod.pck",
		FileAccess.get_sha256(staged.path_join("pony_dances").path_join("sub_mod.pck")), true, 10)]})
	LOADER.boot([empty], [empty], PackedStringArray(), staged)
	var sub := row_of("bundled/sub_mod.pck")
	check(sub.enabled and sub.mounted and str(sub.get("error", "")) == "" and FileAccess.file_exists("res://mods/sub_mod/mod.json"), "a pack staged in a subfolder named unlike its id is found and mounted (%s)" % str(sub.get("error", "")))

	# ---- D-36: a debug-only bundled mod and its patch are neither mounted nor listed without the
	# developer tools; a caution line and the declared authors reach the Mods screen.
	var dbg := temp.path_join("debug_only")
	DirAccess.make_dir_recursive_absolute(dbg)
	var dbg_rows: Array = [
		entry("tele", "1.0.0", "tele.pck", pack(dbg.path_join("tele.pck"), {"res://mods/tele/mod.json": manifest("tele", "1.0.0"), "res://mods/tele/who.txt": "tele"}), true, 10, {"debug_only": true}),
		entry("tele_patch", "1.0.0", "tele_patch.pck", pack(dbg.path_join("tele_patch.pck"), {"res://mods/tele_patch/mod.json": manifest("tele_patch", "1.0.0")}), true, 11, {"patches": {"tele": "1.0.0"}}),
		entry("filly", "1.0.0", "filly.pck", pack(dbg.path_join("filly.pck"), {"res://mods/filly/mod.json": manifest("filly", "1.0.0", {"author": "Home: Equestria"})}), false, 20, {"caution": "Strong language."})]
	write_json(dbg.path_join("bundled_mods.json"), {"format": 1, "mods": dbg_rows})
	LOADER.debug_override = false
	LOADER.boot([empty], [empty], PackedStringArray(), dbg)
	var listed: Array = LOADER.pack_rows().map(func(row: Dictionary) -> String: return row.file)
	check("bundled/tele.pck" not in listed and "bundled/tele_patch.pck" not in listed and not FileAccess.file_exists("res://mods/tele/who.txt"), "without the developer tools a debug-only mod and its patch are not mounted or listed (%s)" % str(listed))
	var filly := row_of("bundled/filly.pck")
	var filly_notes := str(page.call("_mod_notes", filly))
	check(filly.caution == "Strong language." and filly_notes.contains("Strong language.") and filly_notes.contains("Third-party mod"), "a caution line and a declared author naming the game reach the Mods screen while the pack is off (%s)" % filly_notes)
	LOADER.debug_override = true
	LOADER.boot([empty], [empty], PackedStringArray(), dbg)
	check(row_of("bundled/tele.pck").enabled and row_of("bundled/tele_patch.pck").enabled and FileAccess.get_file_as_string("res://mods/tele/who.txt") == "tele", "with the developer tools on it mounts with its patch")
	LOADER.debug_override = null

	# ---- allowed old packs: compile check of their script copies
	var allowed := temp.path_join("allowed")
	DirAccess.make_dir_recursive_absolute(allowed)
	pack(allowed.path_join("cc_bad.pck"), {"res://mods/cc_bad/mod.json": manifest("cc_bad", "1.0.0", {"game_version": "0.0.1"}), CROSSHAIR: fixture("crosshair_broken.gd.txt")})
	pack(allowed.path_join("cc_good.pck"), {"res://mods/cc_good/mod.json": manifest("cc_good", "1.0.0", {"game_version": "0.0.1"}),
		HOME: fixture("home_copy.gd.txt"), IDENTITY: "extends RefCounted\nconst FROM_PACK := true\n"})
	var config := ConfigFile.new(); config.load(LOADER.SETTINGS)
	config.set_value("mods", "allowed_old", {"cc_bad.pck": now, "cc_good.pck": now}); config.save(LOADER.SETTINGS)
	LOADER.boot([allowed], [empty], PackedStringArray(), "")
	var bad := row_of("cc_bad.pck"); var fine := row_of("cc_good.pck")
	check(bad.held and not bad.enabled and str(bad.reason).contains("its copy of world/ui/desktop_crosshair.gd does not work with this game version") and not FileAccess.get_file_as_string(CROSSHAIR).contains("missing_function"), "an allowed old pack whose script copy does not compile is held with the reason (%s)" % str(bad.reason))
	var home := load(HOME) as Script; var identity := load(IDENTITY) as Script
	check(fine.enabled and fine.mounted and not fine.held and home != null and home.get_script_constant_map().get("GOOD") == true and identity != null and identity.get_script_constant_map().get("FROM_PACK") == true, "one whose copies compile mounts, and its copies win even where the check loaded the game's script")
	page.free()
	check(boot_ms < 200.0, "boot with %d packs took %.1f ms (budget 200 ms)" % [files.size(), boot_ms])
	print("BUNDLED_MODS_DONE ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures)
	await process_frame
	quit(0 if failures == 0 else 1)
