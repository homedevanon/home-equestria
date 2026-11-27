extends SceneTree
## Stills and triangle counts of whole ponies with and without a hair pack (EQ_HAIR_PACK absolute, ""
## = the game's own hair): each pony of EQ_HAIR_PONIES (scene paths, comma separated) is built as the
## game builds her, her own mane and tail meshes are counted, and she is drawn from the side and from
## behind into <EQ_HAIR_DIR>/<name>_<view>.png. A path ending in _hair.scn is drawn alone (Anon's hair).
## Prints HAIR_STILLS_DONE. Windowed (--render), hidden display.

func _initialize() -> void: run.call_deferred()

func count(node: Node) -> String:
	var rows: Array = []
	for n: Node in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not ("Devkit" in String(mi.name) or "NearHair" in String(mi.name) or "NearTail" in String(mi.name)) or mi.mesh == null: continue
		var tris := 0
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			tris += ((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arrays[Mesh.ARRAY_INDEX] != null else 0) / 3
		rows.append("%s=%d%s" % [mi.name, tris, "" if mi.is_visible_in_tree() else "(hidden)"])
	return " ".join(PackedStringArray(rows))

func run() -> void:
	var out := OS.get_environment("EQ_HAIR_DIR")
	DirAccess.make_dir_recursive_absolute(out)
	var probe := "res://world/characters/mane6/pinkie_pie_devkit_hair.glb"
	var probe2 := "res://world/characters/background/berry_punch_hair.scn"
	print("HAIRMTIME before glb=%d scn=%d" % [FileAccess.get_modified_time(probe), FileAccess.get_modified_time(probe2)])
	var pack := OS.get_environment("EQ_HAIR_PACK")
	if not pack.is_empty() and not ProjectSettings.load_resource_pack(pack): print("HAIR_STILLS_FAIL mount"); quit(1); return
	print("HAIRMTIME after glb=%d scn=%d editor=%s" % [FileAccess.get_modified_time(probe), FileAccess.get_modified_time(probe2), str(OS.has_feature("editor"))])
	var world := Node3D.new()
	root.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	world.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.66, 0.72)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.85)
	world.add_child(env)
	var floor := StaticBody3D.new()
	var box := CollisionShape3D.new()
	box.shape = BoxShape3D.new()
	(box.shape as BoxShape3D).size = Vector3(40, 0.2, 40)
	floor.add_child(box)
	floor.position.y = -0.1
	world.add_child(floor)
	var cam := Camera3D.new()
	cam.fov = 40
	cam.near = 0.02
	world.add_child(cam)
	cam.make_current()
	for path: String in OS.get_environment("EQ_HAIR_PONIES").split(",", false):
		if not ResourceLoader.exists(path): print("HAIRPONY missing ", path); continue
		var node: Node3D = (load(path) as PackedScene).instantiate()
		world.add_child(node)
		for i in 50: await process_frame
		var name := path.get_file().get_basename()
		print("HAIRPONY %s %s" % [name, count(node)])
		var alone := name.ends_with("_hair")
		var at := node.global_position + Vector3.UP * 0.55
		if alone:
			var box3 := AABB()
			for n: Node in node.find_children("*", "MeshInstance3D", true, false):
				var b: AABB = (n as MeshInstance3D).global_transform * (n as MeshInstance3D).get_aabb()
				box3 = b if box3.size == Vector3.ZERO else box3.merge(b)
			at = box3.get_center()
		# EQ_HAIR_FOCUS=tail: the tail fills the picture, from her side and from behind.
		if OS.get_environment("EQ_HAIR_FOCUS") == "tail":
			var tail_at := node.global_position + Vector3(0.0, 0.42, 0.42)
			for view: Array in [["tailside", Vector3(1.5, 0.12, 0.0)], ["tailback", Vector3(0.75, 0.3, 1.2)]]:
				cam.look_at_from_position(tail_at + view[1], tail_at, Vector3.UP)
				for i in 3: await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(out.path_join("%s_%s.png" % [name, view[0]]))
			node.queue_free()
			for i in 3: await process_frame
			continue
		for view: Array in [["side", Vector3(1.7, 0.15, 0.0)], ["back", Vector3(0.9, 0.35, 1.45)], ["front", Vector3(0.8, 0.2, -1.5)]]:
			cam.look_at_from_position(at + view[1], at, Vector3.UP)
			for i in 3: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(out.path_join("%s_%s.png" % [name, view[0]]))
		node.queue_free()
		for i in 3: await process_frame
	print("HAIR_STILLS_DONE")
	quit(0)
