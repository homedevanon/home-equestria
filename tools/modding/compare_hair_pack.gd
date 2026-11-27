extends SceneTree
## Read-only comparison of a pack that replaces hair meshes (EQ_HAIR_PACK, absolute path) with the
## game's own files: for every res:// .scn/.res path in EQ_HAIR_LIST (one per line), the game's copy
## and the pack's: meshes, triangles, surfaces, bone binds, bounds, blend shapes, material colours and
## the tail anchors' metadata (source_mtime against the hair scene's file time, which a source run
## checks). Run only on a pack already scanned for embedded scripts. Prints HAIR_COMPARE_DONE.

func _initialize() -> void: run.call_deferred()

func describe(path: String) -> Dictionary:
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var out := {"tris": 0, "meshes": {}, "bones": [], "meta": {}, "nodes": []}
	if res == null: out["missing"] = true; return out
	var meshes: Array = []
	if res is PackedScene:
		var node: Node = (res as PackedScene).instantiate()
		for n: Node in [node] + node.find_children("*", "", true, false):
			(out.nodes as Array).append("%s:%s:%s" % [str(node.get_path_to(n)), n.get_class(), str(n.get_script() != null)])
			if n is Skeleton3D:
				for b in (n as Skeleton3D).get_bone_count(): (out.bones as Array).append((n as Skeleton3D).get_bone_name(b))
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				var binds: Array = []
				var skin: Skin = (n as MeshInstance3D).skin
				if skin != null:
					for b in skin.get_bind_count(): binds.append([str(skin.get_bind_name(b)), skin.get_bind_bone(b), skin.get_bind_pose(b)])
				meshes.append([str(n.name), (n as MeshInstance3D).mesh, hash(str(binds))])
		for key: String in res.get_meta_list(): out.meta[key] = str(res.get_meta(key)).left(60)
		node.free()
	elif res is Mesh:
		meshes.append(["mesh", res, 0])
		for key: String in res.get_meta_list():
			if not key.begins_with("pinned_0") and key != "contacts": out.meta[key] = str(res.get_meta(key)).left(80)
	for row: Array in meshes:
		var mesh: Mesh = row[1]
		var tris := 0
		var mats: Array = []
		var lods := 0
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var index: Variant = arrays[Mesh.ARRAY_INDEX]
			tris += ((index as PackedInt32Array).size() if index != null and not (index as PackedInt32Array).is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			var mat := mesh.surface_get_material(s)
			var colour := str((mat as BaseMaterial3D).albedo_color) + (" tex" if (mat as BaseMaterial3D).albedo_texture != null else "") if mat is BaseMaterial3D else str(mat)
			mats.append("%s|%s|%s" % [(mesh as ArrayMesh).surface_get_name(s) if mesh is ArrayMesh else "", mat.resource_name if mat != null else "", colour])
		out.tris += tris
		out.meshes[row[0]] = {"tris": tris, "mats": mats, "aabb": mesh.get_aabb(), "binds": row[2], "blend": mesh.get_blend_shape_count()}
	return out

func run() -> void:
	var paths := FileAccess.get_file_as_string(OS.get_environment("EQ_HAIR_LIST")).split("\n", false)
	var before := {}
	for p: String in paths: before[p] = describe(p)
	if not ProjectSettings.load_resource_pack(OS.get_environment("EQ_HAIR_PACK")):
		print("HAIR_COMPARE_FAIL mount"); quit(1); return
	var report := {}
	for p: String in paths:
		var old: Dictionary = before[p]
		var now := describe(p)
		var notes: Array = []
		if now.has("missing"): notes.append("pack copy does not load")
		if str(old.nodes) != str(now.nodes): notes.append("nodes differ: %s / %s" % [str(old.nodes).left(400), str(now.nodes).left(400)])
		if str(old.bones) != str(now.bones): notes.append("skeleton bones differ")
		for name: String in old.meshes:
			if not (now.meshes as Dictionary).has(name): notes.append("lost mesh " + name); continue
			var a: Dictionary = old.meshes[name]
			var b: Dictionary = now.meshes[name]
			if str(a.mats) != str(b.mats): notes.append("%s materials %s / %s" % [name, str(a.mats), str(b.mats)])
			if a.binds != b.binds: notes.append(name + " skin binds differ")
			if a.blend != b.blend: notes.append(name + " blend shapes differ")
			var grow: float = maxf(((a.aabb as AABB).position - (b.aabb as AABB).position).length(), ((a.aabb as AABB).end - (b.aabb as AABB).end).length())
			if grow > 0.02 * (a.aabb as AABB).size.length(): notes.append("%s bounds moved %.4f of %.4f" % [name, grow, (a.aabb as AABB).size.length()])
		report[p] = {"old": old.tris, "new": now.tris, "notes": notes, "old_meta": old.meta, "new_meta": now.meta}
	for p: String in report:
		var r: Dictionary = report[p]
		var fresh := ""
		var src := str(r.new_meta.get("source", ""))
		if not src.is_empty(): fresh = " source=%s mtime new=%s old=%s file=%d" % [src.get_file(), r.new_meta.get("source_mtime"), r.old_meta.get("source_mtime"), FileAccess.get_modified_time(src)]
		print("HAIR %s %d -> %d%s %s" % [p.trim_prefix("res://world/characters/"), r.old, r.new, fresh, "; ".join(PackedStringArray(r.notes))])
	var metas := {}
	for p: String in report:
		if p.ends_with(".res"): metas[str((report[p].old_meta as Dictionary).keys()) + " / " + str((report[p].new_meta as Dictionary).keys())] = p
	for k: String in metas: print("HAIRMETA ", k, " e.g. ", metas[k])
	print("HAIR_COMPARE_DONE")
	quit(0)
