extends SceneTree
## Lists what the mod loader sees this launch (bundled dir from -- --bundled-dir). Prints LIST_MODS_DONE.


func _initialize() -> void:
	var loader: GDScript = load("res://world/modding/mod_loader.gd")
	print("bundled dir: ", load("res://world/modding/bundled_mods.gd").dir())
	if not loader.booted: loader.boot()
	for row: Dictionary in loader.packs:
		print("PACK ", row.file, " enabled=", row.enabled, " mounted=", row.get("mounted", false), " held=", row.get("held", false), " reason=", row.get("reason", ""), " error=", row.get("error", ""))
	print("LIST_MODS_DONE")
	quit()
