extends SceneTree
## Headless check of the Fishing fixes pack (bundled_mods/fishing_patch, 2026-11-22) on Fishing 0.7.1:
## the pack's main.gd extension installs through the mod loader, its reactions subclass compiles, a
## pony's catch call-out and catch memory are skipped with Anon out of earshot, and a pony's catch
## never reaches the bucket or the game's landing (which spawned a fish item).
##   EQ_FISHING_PACK=<abs fishing.pck> EQ_FISHING_PATCH_PACK=<abs fishing_patch.pck> \
##   python3 tools/run_owned_godot.py --project home-equestria-public --expect FISHING_PATCH_CHECK \
##       --log LOG res://tools/modding/check_fishing_patch.gd
const LOADER := preload("res://world/modding/mod_loader.gd")

var errors := 0


func _initialize() -> void: run.call_deferred()


func expect(ok: bool, what: String) -> void:
	if ok: return
	errors += 1
	print("FISHING_PATCH_FAIL ", what)


## A stand-in rod: a pony holds it and its line has a fish on.
class FakeLine extends RefCounted:
	var fish := {"id": "perch", "name": "Perch", "length": .25, "size_t": .9, "rare": true}


class FakeRod extends Node3D:
	var holder := "pony"
	var line := FakeLine.new()
	var landed := 0
	func _landed(_at: Vector3) -> void: landed += 1


func run() -> void:
	for key: String in ["EQ_FISHING_PACK", "EQ_FISHING_PATCH_PACK"]:
		if not ProjectSettings.load_resource_pack(OS.get_environment(key)):
			push_error("Set " + key); quit(1); return
	var mod := {"id": "fishing_patch", "extends": ["res://mods/fishing_patch/ext/main.gd"], "errors": []}
	LOADER.apply_extensions([mod])
	expect((mod.errors as Array).is_empty(), "loader errors: %s" % str(mod.errors))
	var main_script: Script = load("res://mods/fishing/main.gd")
	expect(main_script != null and main_script.resource_path == "res://mods/fishing/main.gd", "fishing main.gd did not load")
	var main: Node = main_script.new() if main_script != null else null
	expect(main != null and main.has_method("_caught") and main.get_script().get("PATCH_REACTIONS") != null, "the patch's main.gd is not on the fishing mod")
	var reactions_script: Script = load("res://mods/fishing_patch/ext/reactions.gd")
	expect(reactions_script != null and reactions_script.can_instantiate(), "patch reactions.gd does not compile")
	if main == null or reactions_script == null:
		print("FISHING_PATCH_CHECK errors=", errors); quit(1); return
	# A host in the tree with a camera far from the rod: Anon is across town.
	root.add_child(main)
	await process_frame
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(500.0, 0.0, 0.0)
	cam.make_current()
	var reactions: RefCounted = main.get("reactions")
	expect(reactions != null and reactions.get_script() == reactions_script, "main._ready did not install the patch reactions")
	expect(reactions != null and not bool(reactions.call("_patch_near", Vector3.ZERO, 15.0)), "Anon 500 m away counted as near")
	cam.global_position = Vector3(5.0, 1.6, 0.0)
	expect(reactions != null and bool(reactions.call("_patch_near", Vector3.ZERO, 15.0)), "Anon 5 m away not counted as near")
	# A pony's catch: no bucket, no landing (no fish item).
	# In the game a rod sits on its dock under the fishing runtime (reactions.gd reads companions there).
	var runtime := Node3D.new()
	var dock := Node3D.new()
	runtime.add_child(dock)
	root.add_child(runtime)
	var rod := FakeRod.new()
	dock.add_child(rod)
	main.call("_caught", Vector3.ZERO, rod)
	expect(rod.landed == 0, "a pony's catch called the game's landing")
	var bucket: Variant = main.get("bucket")
	expect(bucket == null or not is_instance_valid(bucket) or (bucket.call("fish") as Array).is_empty(), "a pony's catch went into the bucket")
	rod.line.fish = {}
	main.call("_caught", Vector3.ZERO, rod)
	expect(rod.landed == 0, "a pony's empty catch called the game's landing")
	runtime.queue_free()
	main.queue_free()
	cam.queue_free()
	await process_frame
	print("FISHING_PATCH_CHECK errors=", errors)
	quit(1 if errors else 0)
