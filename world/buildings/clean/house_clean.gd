extends RefCounted
## Cleaned-up Ponyville house exteriors (dev 2026-11-13, "fix the textures and models we have").
## The generated house shells are flat boxes with the beams, windows and stones painted on in one
## smeared texture. A design that has res://world/buildings/clean/house_<x>_clean.scn (modelled in
## Blender from the old shell's own measurements, packed by tools/buildings/clean/
## build_clean_house.gd) draws that instead: real plaster walls, chamfered timber, arched window
## frames with glazing bars, a plank door and field stones, under the house's own thatch.
##
## Only the look changes. The old Exterior stays in the tree with its mesh, collision, occluder
## and every measurement taken from it (shell repairs, linings, furnisher walls); it is just not
## drawn (render layers 0, no shadow). Called by house_interior.gd once the house is set up and
## before its window pieces are merged, so the new glazing bars join the window batch.
const ROOT := "res://world/buildings/clean/house_%s_clean.scn"
## Off by default: dev turned this remodelled look down (2026-11-13) for repainted atlases on the
## old shells (world/buildings/repaint/house_repaint.gd). `--clean-houses=on` shows it again.
static var enabled: bool = "--clean-houses=on" in OS.get_cmdline_user_args() or "--clean-houses=on" in OS.get_cmdline_args()
## Window panes of a cleaned house: the show's purple, still see-through (dev 2026-11-13).
const GLASS := Color(0.62, 0.40, 0.85, 0.5)
static var _glass: BaseMaterial3D
## design -> {"Exterior": Mesh, "DoorLeaf": Mesh, "<Window>Sash": Mesh, ...}, or {} when none exists.
static var _looks: Dictionary = {}

static func look(design: String) -> Dictionary:
	if _looks.has(design): return _looks[design]
	var found := {}
	var path := ROOT % design.trim_prefix("house_")
	if ResourceLoader.exists(path):
		var scene: Node = (load(path) as PackedScene).instantiate()
		for child: Node in scene.get_children():
			if child is MeshInstance3D: found[str(child.name)] = (child as MeshInstance3D).mesh
		scene.free()
	_looks[design] = found
	return found

static func apply(house: Node3D) -> bool:
	if not enabled or bool(house.get_meta("clean_look", false)): return false
	var meshes := look(house.scene_file_path.get_file().get_basename())
	var exterior := house.get_node_or_null("Exterior") as MeshInstance3D
	if meshes.is_empty() or exterior == null or exterior.mesh == null or not meshes.has("Exterior"): return false
	var mesh: Mesh = meshes["Exterior"]
	var clean := MeshInstance3D.new()
	clean.name = "CleanExterior"
	clean.mesh = mesh
	clean.transform = exterior.transform
	# The thatch keeps the house's own material (two-sided, as the finished shell draws it).
	var thatch := exterior.get_active_material(0)
	for surface: int in mesh.get_surface_count():
		if mesh.surface_get_name(surface) == "roof": clean.set_surface_override_material(surface, thatch)
	clean.cast_shadow = exterior.cast_shadow
	clean.gi_mode = exterior.gi_mode
	clean.layers = exterior.layers
	clean.visibility_range_begin = exterior.visibility_range_begin
	clean.visibility_range_end = exterior.visibility_range_end
	clean.visibility_range_end_margin = exterior.visibility_range_end_margin
	clean.visibility_range_fade_mode = exterior.visibility_range_fade_mode
	# HouseInterior._ready runs while the house is still adding its children: attach deferred.
	if house.is_inside_tree(): Callable(_attach).call_deferred(house, clean)
	else: house.add_child(clean)
	# The old shell and its room-side copy stay for everything that reads them; they stop drawing.
	var old_mesh := exterior.mesh
	for old: MeshInstance3D in house.find_children("*", "MeshInstance3D", true, false):
		if old == exterior or (old.mesh == old_mesh and old != clean) or str(old.name) == "ExteriorRoomFace":
			old.layers = 0
			old.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Glazing bars: each game window keeps its node and collider and takes the new bars.
	for sash: MeshInstance3D in house.find_children("*Sash", "MeshInstance3D", false, false):
		if not meshes.has(str(sash.name)): continue
		sash.mesh = meshes[str(sash.name)]
		sash.material_override = null
	# Panes: one shared purple copy of the game's clear glass (same settings, so they still batch).
	for pane: MeshInstance3D in house.find_children("*Glass", "MeshInstance3D", false, false):
		var source := pane.get_active_material(0) as BaseMaterial3D
		if source == null: continue
		if _glass == null:
			_glass = source.duplicate() as BaseMaterial3D
			_glass.albedo_color = GLASS
		pane.set_surface_override_material(0, _glass)
	# The door leaf: new planks (both faces) in place of the flat picture and its mirrored back.
	var door := house.get_node_or_null("FrontDoor")
	if door != null and meshes.has("DoorLeaf"):
		var art := door.get_node_or_null("OriginalDoorArtwork") as MeshInstance3D
		if art != null:
			art.mesh = meshes["DoorLeaf"]
			art.material_override = null
			for name: String in ["LeafThickness", "InsideArtwork"]:
				var part := door.get_node_or_null(name) as MeshInstance3D
				if part != null: part.layers = 0
	house.set_meta("clean_look", true)
	return true

static func _attach(house: Node3D, clean: MeshInstance3D) -> void:
	if not is_instance_valid(house) or house.is_queued_for_deletion():
		clean.free()
		return
	house.add_child(clean)
