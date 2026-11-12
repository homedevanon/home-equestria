extends SceneTree
## Review probe (W2-SCENARIO): reading a static var through a GDScript resource, and a missing one.
func _init() -> void:
	var saves := load("res://world/game_saves.gd") as GDScript
	saves.set("last_problem", "Needs the X mod")
	print("PROBE get=", saves.get("last_problem"), " missing=", str(saves.get("no_such_static")), " is_string=", saves.get("no_such_static") is String)
	print("PROBE_DONE")
	quit()
