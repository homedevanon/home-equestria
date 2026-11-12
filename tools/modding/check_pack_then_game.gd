extends SceneTree
## Mounts one mod pack, loads its entry script the way the Mods autoload does (before the world
## scripts), then loads world/game.gd. A mod that preloads game scripts enters the game's script
## cycles from another side; this shows whether the game still compiles after it.
##   run_owned_godot.py --project home-equestria-public --expect PACK_THEN_GAME --log LOG --arg=--pack=/abs/mod.pck --arg=--entry=res://mods/<id>/main.gd res://tools/modding/check_pack_then_game.gd
func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var pack := ""; var entry := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--pack="): pack = argument.trim_prefix("--pack=")
		if argument.begins_with("--entry="): entry = argument.trim_prefix("--entry=")
	var mounted := pack.is_empty() or ProjectSettings.load_resource_pack(pack, false)
	var first: Variant = ResourceLoader.load(entry) if not entry.is_empty() else null
	var entry_ok := first != null and (first as Script).can_instantiate()
	var game: Variant = ResourceLoader.load("res://world/game.gd")
	var game_ok := game != null and (game as Script).can_instantiate()
	print("PACK_THEN_GAME mounted=", mounted, " entry=", entry_ok, " game=", game_ok)
	quit(0)
