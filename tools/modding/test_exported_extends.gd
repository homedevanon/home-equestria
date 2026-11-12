extends SceneTree
## Mod script extensions over exported game scripts (M-MOD-01, M-MOD-07). An exported game keeps
## its scripts as binary tokens, x.gdc behind x.gd.remap; extending a copied N.gdc failed to compile
## and the old plain take-over broke every later preload of the script. This mounts a stand-in
## "exported game" pack (tools/modding/fixtures/loader/exported/: the *.gdc.bin files are the same
## Godot's export of the *.gd.txt sources, see make_exported_fixtures.py; without them the scripts
## go in as source behind a .remap, and the run says so), then mod packs that extend those scripts,
## and checks: the extension compiles, two mods chain in load order, a game script that preloads the
## extended path still parses and sees the subclass, a game script with a global class_name kept
## only as tokens can be extended, and an extension that cannot compile leaves the game script as it
## was, undoes that mod's other extensions and gives the mod the error "could not extend <path> in
## this build". Expected engine errors: the deliberately broken extension prints its parse error.
##   XDG_DATA_HOME=<scratch>/mod-exported-test python3 tools/run_owned_godot.py --project home-equestria-public \
##       --wait-for-slot 1800 --expect EXPORTED_EXTENDS_DONE --log LOG res://tools/modding/test_exported_extends.gd
const LOADER := preload("res://world/modding/mod_loader.gd")
const DIR := "res://tools/modding/fixtures/loader/exported/"
const BASE := DIR + "game_base.gd"
const USER := DIR + "game_user.gd"
const RIVER_USER := DIR + "river_user.gd"
const RIVER := "res://world/water/river_support.gd"
var failures := 0
var checks := 0
var temp := ""
var sources := 0

func _initialize() -> void: run.call_deferred()
func check(ok: bool, text: String) -> void:
	checks += 1
	print("[exported] ", "PASS " if ok else "FAIL ", text)
	if not ok: failures += 1

## A pack of {res:// path: text or PackedByteArray}.
func pack(path: String, files: Dictionary) -> void:
	var packer := PCKPacker.new()
	packer.pck_start(path)
	for target: String in files:
		var source := temp.path_join("src_%d" % sources); sources += 1
		var file := FileAccess.open(source, FileAccess.WRITE)
		if files[target] is PackedByteArray: file.store_buffer(files[target])
		else: file.store_string(str(files[target]))
		file.close()
		packer.add_file(target, source)
	packer.flush()

func has_constant(script: Script, name: String) -> bool:
	while script != null:
		if script.get_script_constant_map().has(name): return true
		script = script.get_base_script()
	return false

func mod_of(id: String) -> Dictionary:
	for mod: Dictionary in LOADER.mods:
		if mod.id == id: return mod
	return {}

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("mod-exported-test"):
		printerr("EXPORTED_EXTENDS_REFUSED requires an isolated XDG_DATA_HOME"); quit(1); return
	temp = ProjectSettings.globalize_path("user://exported_test")
	var mods_dir := temp.path_join("mods"); var empty := temp.path_join("none")
	for dir: String in [mods_dir, empty]: DirAccess.make_dir_recursive_absolute(dir)
	# The autoloads may have loaded river_support.gd already; the stand-in tokens then do not reach it
	# (the source copy is extended instead), which the run reports.
	var river_cached := ResourceLoader.has_cached(RIVER)
	print("[exported] river_support.gd loaded before the test: ", river_cached)
	# The stand-in exported game: each script as tokens behind a .remap, as the export writes it.
	var tokens := FileAccess.file_exists(DIR + "game_base.gdc.bin")
	var game := {}
	for item: Array in [[BASE, "game_base"], [USER, "game_user"], [RIVER_USER, "river_user"], [RIVER, "river_support"]]:
		var path: String = item[0]
		if tokens:
			var bytes := FileAccess.get_file_as_bytes(DIR + str(item[1]) + ".gdc.bin")
			game[path.get_basename() + ".gdc"] = bytes
			game[path + ".remap"] = "[remap]\n\npath=\"%s\"\n" % (path.get_basename() + ".gdc")
		else:
			var shadow := path.get_basename() + "_exported.gd"
			game[shadow] = FileAccess.get_file_as_string(DIR + str(item[1]) + ".gd.txt")
			game[path + ".remap"] = "[remap]\n\npath=\"%s\"\n" % shadow
	print("[exported] CASE ", "binary tokens (.gdc from the Godot 4.5 export template run)" if tokens else "source text behind a .remap (no .gdc fixtures)")
	var game_pack := temp.path_join("game_exported.pck")
	pack(game_pack, game)
	check(ProjectSettings.load_resource_pack(game_pack, true), "the stand-in exported game mounts")
	var plain := load(DIR + "game_base.gd") as Script
	# Not kept: a cached game script would make the loader's copy needless and hide the bug.
	check(plain != null and plain.get_script_constant_map().get("KIND") == "game" and (plain.source_code.is_empty() == tokens), "its script loads through the remap%s" % (" as binary tokens" if tokens else ""))
	plain = null
	# Mods: two extend game_base.gd (they chain), one extends river_support.gd (a global class_name),
	# and a third mod whose second extension cannot compile.
	pack(mods_dir.path_join("a_ext.pck"), {
		"res://mods/ext_first/mod.json": JSON.stringify({"id": "ext_first", "name": "First", "version": "1.0.0", "extends": ["res://mods/ext_first/base.gd", "res://mods/ext_first/river.gd"]}),
		"res://mods/ext_first/base.gd": "extends \"%s\"\nconst MODDED := true\nfunc describe() -> String:\n\treturn \"first+\" + super()\n" % BASE,
		"res://mods/ext_first/river.gd": "extends \"%s\"\nconst MODDED := true\n" % RIVER})
	pack(mods_dir.path_join("b_ext.pck"), {
		"res://mods/ext_second/mod.json": JSON.stringify({"id": "ext_second", "name": "Second", "version": "1.0.0", "extends": ["res://mods/ext_second/base.gd"]}),
		"res://mods/ext_second/base.gd": "extends '%s'\nconst SECOND := true\nfunc describe() -> String:\n\treturn \"second+\" + super()\n" % BASE})
	pack(mods_dir.path_join("c_ext.pck"), {
		"res://mods/ext_bad/mod.json": JSON.stringify({"id": "ext_bad", "name": "Bad", "version": "1.0.0", "extends": ["res://mods/ext_bad/fine.gd", "res://mods/ext_bad/broken.gd"]}),
		"res://mods/ext_bad/fine.gd": "extends \"%s\"\nconst BAD_MOD := true\n" % RIVER_USER,
		"res://mods/ext_bad/broken.gd": "extends \"%s\"\nstatic func describe() -> String:\n\treturn not_a_thing_in_this_game\n" % USER})
	LOADER.boot([mods_dir], [empty], PackedStringArray(), "")
	check(mod_of("ext_first").errors.is_empty() and mod_of("ext_second").errors.is_empty(), "both extensions compile over the exported script (%s / %s)" % [str(mod_of("ext_first").errors), str(mod_of("ext_second").errors)])
	var base := load(BASE) as Script
	var constants := {}
	var walk := base
	while walk != null:
		constants.merge(walk.get_script_constant_map())
		walk = walk.get_base_script()
	check(constants.get("MODDED") == true and constants.get("SECOND") == true and constants.get("KIND") == "game", "the game path loads the chained extensions over the game's script")
	var made: Object = base.new() if base != null and base.can_instantiate() else null
	check(made != null and str(made.call("describe")) == "second+first+game", "they chain in load order and reach the game's code through super (%s)" % (str(made.call("describe")) if made != null else "null"))
	made = null
	var copies := LOADER.BASES
	if tokens:
		var remaps := Array(DirAccess.get_files_at(copies)).filter(func(name: String) -> bool: return name.ends_with(".gd.remap"))
		check(not remaps.is_empty() and Array(DirAccess.get_files_at(copies)).any(func(name: String) -> bool: return name.ends_with(".gdc")), "the game's tokens were copied as N.gdc behind N.gd.remap (%s)" % str(remaps))
	# Player board #40 and game_saves.gd: game scripts that preload the extended path still parse.
	var user := load(USER) as Script
	check(user != null and user.can_instantiate() and str(user.call("describe")) == "second+first+game" and user.call("modded") == true, "an exported game script that preloads the extended script parses and gets the mod's subclass")
	var later := GDScript.new()
	later.source_code = "extends RefCounted\nconst X := preload(\"%s\")\nfunc modded() -> bool:\n\tvar s: Script = X\n\treturn s.get_script_constant_map().get(\"SECOND\", false)\n" % BASE
	var compiled := later.reload()
	check(compiled == OK and later.new().modded(), "a script compiled later that preloads it parses too (%s)" % error_string(compiled))
	# A game script with a global class_name, kept as tokens.
	var river := load(RIVER) as Script
	var river_base: Script = river.get_base_script() if river != null else null
	check(river != null and river.get_script_constant_map().get("MODDED") == true and river_base != null and river_base.get_global_name() != &"RiverSupport" and (river_cached or not tokens or river_base.resource_path.begins_with("user://")), "a class_name game script is extended; its copy no longer claims the global name (%s)" % (str(river_base.get_global_name()) if river_base != null else "none"))
	var river_user := load(RIVER_USER) as Script
	check(river_user != null and str(river_user.call("describe")) == "supported" and river_user.call("modded") == true and not river_user.get_script_constant_map().has("BAD_MOD"),
		"a game script using the class by name and by preload still works, and the failed mod's other extension was undone")
	var bad := mod_of("ext_bad")
	check(str(bad.errors).contains("could not extend %s in this build" % USER) and not LOADER.active().has(bad), "an extension that cannot compile gives its mod the error (%s)" % str(bad.errors))
	check(not has_constant(user, "SECOND") and str(user.call("describe")) == "second+first+game", "and the game script it targeted stays the game's own")
	print("EXPORTED_EXTENDS_DONE ", "PASS" if failures == 0 else "FAIL", " checks=", checks, " failures=", failures, " case=", "gdc" if tokens else "remap-text")
	await process_frame
	quit(0 if failures == 0 else 1)
