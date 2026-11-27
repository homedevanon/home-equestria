extends RefCounted
## Repainted Ponyville house shells (dev 2026-11-13). Dev retextures each house shell outside the
## game from cleaned-up pictures of the same house; the result keeps the shell's UVs, so it is one
## new atlas on the old layout: res://world/buildings/repaint/house_<x>_atlas.res (made by
## tools/buildings/repaint/build_house_repaint.gd). A design that has one draws it; a design
## without one is untouched.
##
## Only the picture changes. Mesh, collision, culling and every other material setting stay: each
## material that drew the old atlas gets one copy with the new atlas (shared by all houses of the
## design), attached the same way the old one was. Called by house_interior.gd after the finishes.
##   --house-repaint=off   keeps the old atlas (comparison, rollback)
##   --house-cartoon=on    trial: flat cartoon light on the shell (two tones, no shine)
const ROOT := "res://world/buildings/repaint/house_%s_atlas.res"
## Shell parts that read the atlas through their own copy of the picture (the door panel).
const PARTS := ["Exterior", "DoorSideWallBase", "OriginalDoorArtwork", "InsideArtwork"]
static var enabled: bool = not _switch("--house-repaint=off")
static var cartoon: bool = _switch("--house-cartoon=on")
## design -> Texture2D, or null when the design has no repaint.
static var _atlases: Dictionary = {}
## "<source material id>:<cartoon>" -> its repainted copy.
static var _copies: Dictionary = {}

static func _switch(word: String) -> bool:
	return word in OS.get_cmdline_user_args() or word in OS.get_cmdline_args()

static func atlas(design: String) -> Texture2D:
	if _atlases.has(design): return _atlases[design]
	var path := ROOT % design.trim_prefix("house_")
	var found: Texture2D = null
	if ResourceLoader.exists(path): found = load(path) as Texture2D
	_atlases[design] = found
	return found

static func apply(house: Node3D) -> bool:
	if not enabled or bool(house.get_meta("repainted", false)): return false
	var picture := atlas(house.scene_file_path.get_file().get_basename())
	var exterior := house.get_node_or_null("Exterior") as MeshInstance3D
	if picture == null or exterior == null or exterior.mesh == null: return false
	var shell_material := exterior.get_active_material(0) as BaseMaterial3D
	if shell_material == null or shell_material.albedo_texture == null: return false
	var old := shell_material.albedo_texture
	for part: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if part.mesh == null: continue
		var named := str(part.name) in PARTS
		for surface: int in part.mesh.get_surface_count():
			var material := part.get_active_material(surface) as BaseMaterial3D
			if material == null or material.albedo_texture == null: continue
			if material.albedo_texture != old and not (named and material.albedo_texture.get_size() == old.get_size()): continue
			var copy := _copy(material, picture)
			if part.material_override != null:
				part.material_override = copy
				break
			part.set_surface_override_material(surface, copy)
	house.set_meta("repainted", true)
	return true

static func _copy(material: BaseMaterial3D, picture: Texture2D) -> BaseMaterial3D:
	var key := "%d:%s" % [material.get_instance_id(), cartoon]
	if _copies.has(key): return _copies[key]
	var copy := material.duplicate() as BaseMaterial3D
	copy.albedo_texture = picture
	if cartoon:
		copy.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		copy.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_copies[key] = copy
	return copy
