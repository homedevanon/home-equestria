extends SceneTree
## Player board #57: mod.json "depends" (world/modding/mod_loader.gd). Tiny packs are built here with
## PCKPacker in user://mod_depends_test and booted through the real loader with no bundled mods.
## Checks: a pack that needs a mod from a pack whose file name sorts later now loads after it, and
## its mod starts after that mod; packs without "depends" keep their file-name order; a missing,
## switched-off or too old dependency stops the mod with a plain reason on the Mods screen; two mods
## that need each other are both stopped with the loop named, and boot finishes.
##   python3 tools/run_owned_godot.py --project home-equestria-public --expect MOD_DEPENDS_PASS \
##       --log LOG res://tools/modding/test_mod_depends.gd
const LOADER := preload("res://world/modding/mod_loader.gd")
var failures := 0
var checks := 0
var temp := ""
var sources := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, text: String) -> void:
	checks += 1
	print("[mod-depends] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

func pack(path: String, id: String, version: String, depends: Variant = null) -> void:
	var doc := {"id": id, "name": id.capitalize(), "version": version, "author": "Tester"}
	if depends != null: doc["depends"] = depends
	var source := temp.path_join("src_%d.json" % sources); sources += 1
	var file := FileAccess.open(source, FileAccess.WRITE); file.store_string(JSON.stringify(doc)); file.close()
	var packer := PCKPacker.new()
	packer.pck_start(path)
	packer.add_file("res://mods/%s/mod.json" % id, source)
	packer.flush()

func files() -> Array:
	return LOADER.pack_rows().map(func(row: Dictionary) -> String: return str(row.file))

func row_of(file: String) -> Dictionary:
	for row: Dictionary in LOADER.pack_rows():
		if row.file == file: return row
	return {}

func mod_of(id: String) -> Dictionary:
	for mod: Dictionary in LOADER.mods:
		if mod.id == id: return mod
	return {}

func run() -> void:
	temp = ProjectSettings.globalize_path("user://mod_depends_test")
	var dir := temp.path_join("mods"); var empty := temp.path_join("empty")
	for folder: String in [dir, empty]: DirAccess.make_dir_recursive_absolute(folder)
	# File names sort a_ before z_: the dependant comes first by name.
	pack(dir.path_join("a_cakes.pck"), "dep_cakes", "1.0.0", {"dep_bakery": ">=1.0.0"})
	pack(dir.path_join("b_plain.pck"), "dep_plain_b", "1.0.0")
	pack(dir.path_join("c_plain.pck"), "dep_plain_c", "1.0.0")
	pack(dir.path_join("z_bakery.pck"), "dep_bakery", "1.2.0")
	pack(dir.path_join("d_missing.pck"), "dep_needs_missing", "1.0.0", {"dep_not_here": ">=1.0.0"})
	pack(dir.path_join("e_old.pck"), "dep_needs_new", "1.0.0", {"dep_bakery": ">=2.0.0"})
	pack(dir.path_join("f_off.pck"), "dep_switched_off", "1.0.0")
	pack(dir.path_join("g_needs_off.pck"), "dep_needs_off", "1.0.0", {"dep_switched_off": "*"})
	pack(dir.path_join("h_loop_a.pck"), "dep_loop_a", "1.0.0", {"dep_loop_b": "*"})
	pack(dir.path_join("i_loop_b.pck"), "dep_loop_b", "1.0.0", {"dep_loop_a": "*"})
	var started := Time.get_ticks_msec()
	LOADER.boot([dir], [empty], PackedStringArray(["f_off.pck"]), "")
	check(Time.get_ticks_msec() - started < 20000, "boot finishes with a loop of needs (%d ms)" % (Time.get_ticks_msec() - started))
	var order := files()
	print("[mod-depends] pack order: ", order)
	check(order.find("z_bakery.pck") < order.find("a_cakes.pck"), "the needed pack mounts before the pack that needs it")
	check(order.find("b_plain.pck") < order.find("c_plain.pck") and order.find("c_plain.pck") < order.find("d_missing.pck"), "packs without needs keep their file-name order")
	var active: Array = LOADER.active().map(func(mod: Dictionary) -> String: return str(mod.id))
	check("dep_cakes" in active and active.find("dep_bakery") < active.find("dep_cakes"), "the needing mod runs and starts after the mod it needs (%s)" % str(active))
	var missing := row_of("d_missing.pck")
	check("dep_needs_missing" not in active and str(missing.reason).contains("needs dep_not_here 1.0.0 or newer (not installed)"), "a missing dependency stops the mod with a plain reason: %s" % missing.reason)
	var old := row_of("e_old.pck")
	check("dep_needs_new" not in active and str(old.reason).contains("needs Dep Bakery 2.0.0 or newer (1.2.0 is installed)"), "a too old dependency stops the mod with a plain reason: %s" % old.reason)
	var off := row_of("g_needs_off.pck")
	check("dep_needs_off" not in active and str(off.reason).contains("needs Dep Switched Off (it is switched off or not loaded)"), "a switched-off dependency stops the mod with a plain reason: %s" % off.reason)
	var loop_a := row_of("h_loop_a.pck"); var loop_b := row_of("i_loop_b.pck")
	check("dep_loop_a" not in active and "dep_loop_b" not in active, "mods that need each other do not run")
	check(str(loop_a.reason).contains("loop: Dep Loop A needs Dep Loop B needs Dep Loop A") and str(loop_b.reason).contains("loop"), "the loop is named on the Mods screen: %s" % loop_a.reason)
	check(order.find("h_loop_a.pck") < order.find("i_loop_b.pck"), "packs in a loop keep their order")
	# A list with no needs comes back unchanged.
	var plain: Array = [{"file": "x.pck", "declared": {"x": {"depends": {}}}, "bundled": false, "patch_of": "", "superseded_by": ""},
		{"file": "y.pck", "declared": {"y": {}}, "bundled": false, "patch_of": "", "superseded_by": ""}]
	check(LOADER._depends_first(plain) == plain, "a load order without any needs is unchanged")
	print("MOD_DEPENDS_%s checks=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", checks, failures])
	quit(0 if failures == 0 else 1)
