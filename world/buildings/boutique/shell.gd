extends RefCounted
## Opens only this instance's measured original door. Source mesh and prefab stay intact.
const LAYOUT := preload("res://world/buildings/boutique/layout.gd")
const DOOR := preload("res://world/buildings/hinged_door.gd")
const LEAF := AABB(Vector3(-1.061,.04,-5.20),Vector3(1.768,3.69,.40))
## The source's modelled brass knob and its backplate (three small pieces, 224 triangles) sit 0.24 m
## from the hinge (x .698): the door swings on that side, so the knob read as on the wrong side
## (board #308). The leaf already carries real pulls at its latch edge (door.handle, built by
## hinged_door.gd), so the old knob is dropped from the moving leaf, like Trixie's wagon knob.
const KNOB := AABB(Vector3(.36,1.02,-5.14),Vector3(.21,.70,.28))
static func prepare(existing: Node3D) -> Dictionary:
	var source: ArrayMesh = existing.get_node("Mesh1").mesh
	var shell := ArrayMesh.new(); var leaf := ArrayMesh.new()
	var moved := 0
	var backing := 0
	var knob := 0
	for s in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array(); var moving := PackedInt32Array()
		for i in range(0,indices.size(),3):
			var face := PackedInt32Array([indices[i],indices[i+1],indices[i+2]])
			if LEAF.has_point(vertices[indices[i]]) and LEAF.has_point(vertices[indices[i+1]]) and LEAF.has_point(vertices[indices[i+2]]):
				# Two broad scenery wall triangles sit behind the detailed door/window.
				# They are not part of a usable leaf: viewed from inside they blank its art.
				if s==0 and vertices[face[0]].z> -4.87 and vertices[face[1]].z> -4.87 and vertices[face[2]].z> -4.87:
					backing += 1; continue
				if KNOB.has_point(vertices[face[0]]) and KNOB.has_point(vertices[face[1]]) and KNOB.has_point(vertices[face[2]]):
					knob += 1; continue
				moving.append_array(face); moved += 1
			else: kept.append_array(face)
		for pair: Array in [[shell,kept],[leaf,moving]]:
			if (pair[1] as PackedInt32Array).is_empty(): continue
			var out: Array = arrays.duplicate();out[Mesh.ARRAY_INDEX]=pair[1]
			var target: ArrayMesh = pair[0]
			# Drop unused source vertices: the shared physical pull builder measures this AABB.
			var compact:=SurfaceTool.new();compact.create_from_arrays(out);compact.deindex();compact.index()
			var material:Material=source.surface_get_material(s)
			# Scenery artwork was authored for outside viewing. The usable moving leaf
			# must also remain opaque when the player closes it from inside the room.
			if (s==1 or target==leaf) and material is BaseMaterial3D:
				material=material.duplicate();material.cull_mode=BaseMaterial3D.CULL_DISABLED
			compact.set_material(material);compact.commit(target)
	assert(moved > 38, "Boutique source door changed; remeasure the leaf and its window")
	assert(backing==2, "Remeasure the boutique scenery door backing")
	if knob != 224: push_warning("[boutique] hinge-side knob cut %d triangles (expected 224): remeasure KNOB" % knob)
	existing.get_node("Mesh1").mesh = shell
	for body: Node in existing.find_children("*","CollisionObject3D",true,false):
		body.collision_layer=0;body.collision_mask=0
	var frame := Node3D.new();frame.name="BoutiqueRoomFrame"
	var world_frame := Transform3D(existing.global_basis.orthonormalized()*Basis(Vector3.UP,PI),existing.to_global(LAYOUT.ORIGIN))
	frame.transform = existing.global_transform.affine_inverse()*world_frame;existing.add_child(frame)
	# Original decoration is outside the new measured lining. Its triangle shell still
	# blocks exterior walking; old filled boxes must never return inside the usable room.
	var body := StaticBody3D.new();body.name="HollowExterior";existing.add_child(body)
	var col := CollisionShape3D.new();var shape := shell.create_trimesh_shape();shape.backface_collision=true;col.shape=shape;body.add_child(col)
	var door: AnimatableBody3D = DOOR.new();door.name="BoutiqueDoor"
	door.position=frame.to_local(existing.to_global(Vector3(.698,.053,-4.96)))
	door.swing_direction=1.0
	frame.add_child(door)
	var mesh := ArrayMesh.new()
	for s in leaf.get_surface_count():
		var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES);st.set_material(leaf.surface_get_material(s))
		st.append_from(leaf,s,door.global_transform.affine_inverse()*existing.global_transform);st.commit(mesh)
	var art:=MeshInstance3D.new();art.name="OriginalDoorArtwork";art.mesh=mesh;door.add_child(art)
	var collision:=CollisionShape3D.new();collision.name="LeafCollision";var leaf_shape:=BoxShape3D.new();leaf_shape.size=Vector3(1.75,3.62,.18)
	collision.shape=leaf_shape;collision.position=Vector3(.875,1.81,0);door.add_child(collision)
	door.handle=Vector3(1.48,1.05,0);door.navigation_box=AABB(Vector3(-.15,-.1,-1.9),Vector3(2.05,3.9,3.8))
	print("[boutique] opened original door triangles=",moved)
	var layout := LAYOUT.room()
	layout.window_glass = preload("res://world/buildings/boutique/window_reveals.gd").measure(source,frame.global_transform.affine_inverse()*existing.global_transform)
	return {"frame":frame,"door":door,"layout":layout}
