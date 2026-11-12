extends RefCounted
## Extra resource packs shipped next to the executable (region packs, raw data pack).
## Call load_extra_packs() once, as early as possible (before anything reads res:// data from a
## pack): e.g. first line of the first autoload's _init. Source runs have no packs and skip.
## Packs load in name order; later packs replace files of earlier ones.

## Small preflight, not an integrity scan: these imported/model and terrain assets
## live in the Quest data pack, never in the code-only APK.
const ANDROID_REQUIRED_DATA := [
	"res://world/characters/hybrid_mare/stallion_body.glb",
	"res://world/terrain/data_half/terrain3d_00_02.res",
]
const MISSING_DATA := "Install the game's data (the OBB files, SideQuest does it with the APK), then reopen the game."
## The other way round: files the code-only APK itself must hold, because the title loads them
## before any data exists (GitHub #16: the menu fonts sat under world/books/, which ships in the
## data pack, so the title script failed to load and the headset showed a black void). The preset
## generator (tools/build/make_export_presets.py) keeps these and everything the title scene and
## the autoloads preload in the APK, and refuses to write presets that leave one out.
const ANDROID_REQUIRED_APK := [
	"res://world/ui/title_screen.tscn",
	"res://world/ui/fonts/CelestiaMediumRedux.ttf",
	"res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf",
	"res://world/books/fonts/AtkinsonHyperlegible-Bold.ttf",
	"res://world/books/fonts/AtkinsonHyperlegible-Italic.ttf",
]

## The first ANDROID_REQUIRED_APK file `exists` cannot find, or "" (tools/ui/test_title_without_data.gd).
static func apk_problem(exists: Callable) -> String:
	for path: String in ANDROID_REQUIRED_APK:
		if not bool(exists.call(path)): return path
	return ""

static func installation_problem(android_export: bool, exists: Callable) -> String:
	if not android_export: return ""
	for path: String in ANDROID_REQUIRED_DATA:
		if not bool(exists.call(path)): return MISSING_DATA
	return ""

## Shared app-file locations for resource packs and explicit key-file imports.
## user:// is internal on Quest; USB file transfer reaches the external aliases.
static func android_directories(user_data: String, external_roots: PackedStringArray = []) -> Array[String]:
	var dirs: Array[String] = [user_data]
	# Data downloaded on first launch for this exact app version (world/ui/quest_data_download.gd).
	var downloaded := user_data.path_join("quest-data").path_join(str(ProjectSettings.get_setting("application/config/version", "")))
	if downloaded not in dirs: dirs.append(downloaded)
	var package := user_data.get_base_dir().get_file()
	var roots: PackedStringArray = external_roots
	if roots.is_empty(): roots = PackedStringArray(["/storage/emulated/0", "/sdcard"])
	for root: String in roots:
		var external := root.path_join("Android/data").path_join(package).path_join("files")
		if external not in dirs: dirs.append(external)
	# OBB expansion files (dev 2026-10-23: "just dont make people do extra work"): SideQuest
	# installs main.<code>.<package>.obb (data) and patch.<code>.<package>.obb (raw) here with the
	# APK, and the app may read its own obb folder without a permission.
	for root: String in roots:
		var obb := root.path_join("Android/obb").path_join(package)
		if obb not in dirs: dirs.append(obb)
	return dirs

## Patch packs (tools/build/release_patch.py): HomeEquestria-update-<base version>.pck holds the
## files changed since that full build. It sorts after -data and -raw, so it mounts last and wins.
## One left behind by a later full install is made for another base and stays unmounted.
const PATCH_PREFIX := "HomeEquestria-update-"

static func patch_fits(name: String) -> bool:
	if not name.begins_with(PATCH_PREFIX): return true
	return name.trim_prefix(PATCH_PREFIX).get_basename() == str(ProjectSettings.get_setting("application/config/version", ""))

## The game's own packs beside the executable: HomeEquestria.pck, -data, -raw (or a renamed exe's).
## Any other pack there is a mod (world/modding/mod_loader.gd).
static func is_game_pack(name: String) -> bool:
	var exe := OS.get_executable_path().get_file().get_basename()
	return name.begins_with("HomeEquestria") or (not exe.is_empty() and name.begins_with(exe))

static func load_extra_packs() -> PackedStringArray:
	var loaded := PackedStringArray()
	if not OS.has_feature("template"): return loaded
	var exe := OS.get_executable_path()
	var main_pack := exe.get_basename() + ".pck"
	var dirs: Array[String] = [exe.get_base_dir()]
	if OS.has_feature("android"):
		dirs = android_directories(OS.get_user_data_dir())
	# Other packs beside a desktop executable are mods: world/modding/mod_loader.gd mounts them
	# after these, honouring Settings → Mods.
	return _load_from_directories(dirs, main_pack, ProjectSettings.load_resource_pack, not OS.has_feature("android"))

static func _load_from_directories(dirs: Array[String], main_pack: String,
		mount: Callable = ProjectSettings.load_resource_pack, game_only := false) -> PackedStringArray:
	var loaded := PackedStringArray()
	var seen := {}
	for dir in dirs:
		if not DirAccess.dir_exists_absolute(dir): continue
		var names := DirAccess.get_files_at(dir)
		names.sort()
		for name in names:
			if name.get_extension().to_lower() not in ["pck", "obb"] or seen.has(name): continue
			if game_only and not is_game_pack(name): continue
			if not patch_fits(name): print("[packs] skipped %s: made for another version" % name); continue
			var path := dir.path_join(name)
			if path == main_pack: continue
			if bool(mount.call(path, true)):
				seen[name] = true
				loaded.append(name)
			else: push_warning("[packs] could not load %s" % path)
	if not loaded.is_empty(): print("[packs] loaded ", ", ".join(loaded))
	return loaded
