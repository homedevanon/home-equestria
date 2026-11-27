extends SceneTree
## Why FileAccess.get_modified_time("res://...") reads 0 in some runs: before and after the mods
## mount, for a res:// path and its disk path. Prints MTIME_DONE.
func _initialize() -> void:
	var p := "res://world/characters/mane6/pinkie_pie_devkit_hair.glb"
	print("MTIME initialize res=%d disk=%d unique=%s" % [FileAccess.get_modified_time(p), FileAccess.get_modified_time(ProjectSettings.globalize_path(p)), ProjectSettings.globalize_path("res://")])
	run.call_deferred()
func run() -> void:
	var p := "res://world/characters/mane6/pinkie_pie_devkit_hair.glb"
	print("MTIME deferred res=%d" % FileAccess.get_modified_time(p))
	var loader: Script = load("res://world/modding/mod_loader.gd")
	var mounted: Array = (loader.get("packs") as Array).filter(func(r: Dictionary) -> bool: return bool(r.get("mounted", false)))
	print("MTIME packs mounted=%d booted=%s" % [mounted.size(), str(loader.get("booted"))])
	for q: String in ["res://project.godot", "res://world/characters/background/berry_punch_hair.scn", "res://world/game.gd"]: print("MTIME %s %d" % [q, FileAccess.get_modified_time(q)])
	print("MTIME_DONE")
	quit(0)
