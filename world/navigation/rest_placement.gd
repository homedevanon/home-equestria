extends RefCounted
## Decision-time check, never a per-frame scene scan. Traversable entrances are
## useful route segments, but not autonomous destinations or resting places.
const FAR_HOUSE := 80.0
const FAR_DOOR := 20.0

static func passage(tree: SceneTree, at: Vector3, radius: float) -> bool:
	if not at.is_finite(): return true
	for home: Node3D in tree.get_nodes_in_group("house_interiors"):
		# Most houses are far away: both tests below only pass within a door's width of the
		# entrance, and no entrance lies this far from its house.
		if at.distance_squared_to(home.global_position) > FAR_HOUSE * FAR_HOUSE: continue
		var outside: Vector3 = home.outside()
		var doorway: Vector3 = home.to_global(Vector3(home.doorway.x, home.floor_y, home.doorway.z))
		var inside: Vector3 = home.inside()
		# Some civic interiors use their room centre as inside(). Reserve the
		# entrance, not a line all the way through the middle of the building.
		inside = doorway.move_toward(inside, 1.5)
		var width := maxf(.6, float(home.door_width) * home.global_basis.x.length() * .5) + radius
		if _on_segment(at, outside, doorway, width) or _on_segment(at, doorway, inside, width): return true
	# Standalone shop doors do not necessarily have a residential interior.
	for door: Node3D in tree.get_nodes_in_group("house_doors"):
		if at.distance_squared_to(door.global_position) > FAR_DOOR * FAR_DOOR: continue
		var box: AABB = door.navigation_box
		if not box.has_volume(): continue
		# navigation_box is authored in the closed leaf frame; an open leaf's
		# rotation must not rotate the protected doorway away from the entrance.
		var frame := door.get_parent_node_3d().global_transform * Transform3D(Basis.from_scale(door.scale), door.position)
		var local := frame.affine_inverse() * at
		var x_margin := radius / frame.basis.x.length()
		var z_margin := radius / frame.basis.z.length()
		if local.x < box.position.x - x_margin or local.x > box.end.x + x_margin: continue
		if local.z < box.position.z - z_margin or local.z > box.end.z + z_margin: continue
		if local.y >= box.position.y - .45 / frame.basis.y.length() and local.y <= box.end.y: return true
	return false

static func _on_segment(at: Vector3, start: Vector3, end: Vector3, width: float) -> bool:
	var line := Vector2(end.x - start.x, end.z - start.z)
	var offset := Vector2(at.x - start.x, at.z - start.z)
	var fraction := clampf(offset.dot(line) / line.length_squared(), 0.0, 1.0) if line.length_squared() > .0001 else 0.0
	return (offset - line * fraction).length_squared() <= width * width and absf(at.y - lerpf(start.y, end.y, fraction)) < .45
