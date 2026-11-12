extends RefCounted
## Assembles one standing easel (docs/PAINTING_STATION_2026_10_22.md sections 2-4): the open
## model, the canvas at its mount, the PaintPanel collider the desktop ray and E/click find, the
## Wake sensor, and the idle canvas face (a plain material, or the saved work in progress).
## Shared by the Balloon Hill station (station_install.gd) and owned easels (easel_fold.gd).
##
## Idle cost: four meshes (EaselBody casts the only shadow, all end at 60 m), one StaticBody3D
## and one Area3D whose script never processes. The painting runtime and core are not loaded.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const MODELS := "res://world/painting/models/"
const OPEN_MODEL := MODELS + "easel_open.glb"
const CANVAS_MODELS := {"P": MODELS + "canvas_portrait.glb", "L": MODELS + "canvas_landscape.glb"}
const WAKE_SCRIPT := "res://world/painting/easel_wake.gd"
const FACE_SIZE := {"P": Vector2(0.50, 0.811), "L": Vector2(0.811, 0.50)}
const VISIBLE_END := 60.0
const WAKE_RADIUS := 3.0
## The player body layer (player/*_player.tscn).
const PLAYER_LAYER := 2048
## Self-light on canvas faces (also canvas_face.gdshader and art_item.gd): the Balloon Hill
## canvas faces north and shaded walls get only blue sky light, so without it paint reads wrong.
const CANVAS_GLOW := 0.4
const STATION_LABEL := "a painter's easel on Balloon Hill"
const OWNED_LABEL := "a painter's easel"

## The easel node under `host` (named "Easel"), or null when the model is missing.
static func build(host: Node3D, key: String, owned: bool) -> Node3D:
	var scene := load(OPEN_MODEL) as PackedScene
	if scene == null:
		push_warning("[painting] easel model missing: " + OPEN_MODEL)
		return null
	var easel := Node3D.new(); easel.name = "Easel"
	easel.set_meta("painting_key", key); easel.set_meta("painting_owned", owned)
	var model: Node3D = scene.instantiate(); model.name = "EaselOpen"
	easel.add_child(model)
	for mesh: GeometryInstance3D in model.find_children("*", "GeometryInstance3D", true, false):
		mesh.visibility_range_end = VISIBLE_END
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if mesh.name == "EaselBody" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var orient := str(REGISTRY.wip(key).get("orient", "P"))
	mount_canvas(easel, orient)
	var panel := StaticBody3D.new(); panel.name = "PaintPanel"
	panel.collision_layer = 1; panel.collision_mask = 0
	easel.add_child(panel)
	_panel_shapes(easel, panel)
	var wake: Area3D = (load(WAKE_SCRIPT) as Script).new()
	wake.name = "Wake"
	wake.collision_layer = 0; wake.collision_mask = PLAYER_LAYER
	wake.monitorable = false; wake.monitoring = true
	var sphere := SphereShape3D.new(); sphere.radius = WAKE_RADIUS
	var holder := CollisionShape3D.new(); holder.shape = sphere
	wake.add_child(holder)
	wake.position = Vector3(0, 1.0, 0)
	wake.set("easel", easel); wake.set("key", key); wake.set("owned", owned)
	easel.add_child(wake)
	panel.set_meta("painting_easel", wake)
	host.add_child(easel)
	easel.add_to_group(REGISTRY.EASEL_GROUP)
	refresh_canvas(easel)
	return easel

## The canvas instance ("Canvas") at the portrait or landscape mount; replaces the old one.
static func mount_canvas(easel: Node3D, orient: String) -> Node3D:
	var old := easel.get_node_or_null("Canvas")
	if old != null:
		old.name = "CanvasOld"; easel.remove_child(old); old.queue_free()
	var scene := load(str(CANVAS_MODELS.get(orient, CANVAS_MODELS.P))) as PackedScene
	if scene == null: return null
	var canvas: Node3D = scene.instantiate(); canvas.name = "Canvas"
	var mount := marker(easel, "CanvasMountL" if orient == "L" else "CanvasMountP")
	canvas.transform = local_of(easel, mount) if mount != null else Transform3D.IDENTITY
	for mesh: GeometryInstance3D in canvas.find_children("*", "GeometryInstance3D", true, false):
		mesh.visibility_range_end = VISIBLE_END
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	easel.add_child(canvas)
	easel.set_meta("painting_orient", "L" if orient == "L" else "P")
	canvas.set_meta("ai_id", "painting_station" if not bool(easel.get_meta("painting_owned", false)) else "painting_easel")
	canvas.set_meta("ai_label", STATION_LABEL if not bool(easel.get_meta("painting_owned", false)) else OWNED_LABEL)
	canvas.add_to_group("ai_observable")
	return canvas

## The idle face: the saved work in progress as a plain texture, or the bare canvas colour.
static func refresh_canvas(easel: Node) -> void:
	if not easel is Node3D or not easel.has_meta("painting_key"): return
	var key := str(easel.get_meta("painting_key"))
	var row := REGISTRY.wip(key)
	var orient := str(row.get("orient", easel.get_meta("painting_orient", "P")))
	if orient != str(easel.get_meta("painting_orient", "P")): mount_canvas(easel, orient)
	var face := canvas_face(easel)
	if face == null: return
	var texture: Texture2D = null
	var file := REGISTRY.path(str(row.get("file", ""))) if not row.is_empty() else ""
	if not file.is_empty() and FileAccess.file_exists(file):
		var image := Image.load_from_file(file)
		var size: Vector2 = FACE_SIZE.get(orient, FACE_SIZE.P)
		if image != null and not image.is_empty() and (image.get_width() > image.get_height()) == (size.x > size.y):
			image.generate_mipmaps()
			texture = ImageTexture.create_from_image(image)
	face.material_override = idle_material(texture)
	var canvas := easel.get_node_or_null("Canvas")
	if canvas != null:
		# An emptied owned easel waits for a bought canvas (painting_registry.is_bare, M-ACT-03).
		var bare := REGISTRY.is_bare(key)
		if canvas is Node3D: (canvas as Node3D).visible = not bare
		if bare:
			canvas.set_meta("ai_label", "an empty painter's easel")
			return
		var owned := bool(easel.get_meta("painting_owned", false))
		var colours := str(row.get("label", ""))
		if texture != null and not colours.is_empty():
			canvas.set_meta("ai_label", "an easel with a painting in progress (%s)" % colours)
		else:
			canvas.set_meta("ai_label", OWNED_LABEL if owned else STATION_LABEL)

static func idle_material(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.roughness = 0.9
	material.emission_enabled = true
	material.emission_energy_multiplier = CANVAS_GLOW
	if texture != null:
		material.albedo_texture = texture
		material.emission = Color.WHITE
		material.emission_texture = texture
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	else:
		material.albedo_color = REGISTRY.CANVAS_COLOR
		material.emission = REGISTRY.CANVAS_COLOR
	return material

static func canvas_face(easel: Node) -> MeshInstance3D:
	var canvas := easel.get_node_or_null("Canvas")
	return canvas.find_child("CanvasFace", true, false) as MeshInstance3D if canvas != null else null

static func marker(easel: Node, marker_name: String) -> Node3D:
	var model := easel.get_node_or_null("EaselOpen")
	return model.find_child(marker_name, true, false) as Node3D if model != null else null

## A node's transform relative to the easel, without needing the tree.
static func local_of(easel: Node, node: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var at: Node = node
	while at != null and at != easel:
		if at is Node3D: result = (at as Node3D).transform * result
		at = at.get_parent()
	return result

## The mast-and-legs box in easel space (station frame collision, an open owned easel's shape).
static func frame_box(easel: Node) -> AABB:
	var body := marker(easel, "EaselBody") as MeshInstance3D
	if body == null or body.mesh == null: return AABB(Vector3(-0.4, 0, -0.62), Vector3(0.8, 1.9, 0.7))
	return local_of(easel, body) * body.get_aabb()

## PaintPanel: the canvas (both orientations), the tray with wells and jar, and the tool hooks.
static func _panel_shapes(easel: Node3D, panel: StaticBody3D) -> void:
	var mount := marker(easel, "CanvasMountP")
	if mount != null:
		var at := local_of(easel, mount)
		at.origin += at.basis * Vector3(0, -0.005, -0.02)
		_box(panel, "Canvas", Vector3(0.85, 0.86, 0.05), at)
	var tray := marker(easel, "PaletteFrame")
	if tray != null:
		_box(panel, "Tray", Vector3(0.86, 0.09, 0.19), local_of(easel, tray) * Transform3D(Basis.IDENTITY, Vector3(0, 0.02, 0)))
	var low := Vector3.INF
	var high := -Vector3.INF
	for tool: String in ["Brush", "Pencil", "Scraper"]:
		var hook := marker(easel, "Hook_" + tool)
		if hook == null: continue
		var at := local_of(easel, hook).origin
		low = low.min(at + Vector3(-0.03, -0.19, -0.03)); high = high.max(at + Vector3(0.03, 0.09, 0.03))
	if low.is_finite() and high.is_finite():
		_box(panel, "Hooks", high - low, Transform3D(Basis.IDENTITY, (low + high) * 0.5))

static func _box(body: StaticBody3D, part: String, size: Vector3, at: Transform3D) -> void:
	var shape := BoxShape3D.new(); shape.size = size
	var holder := CollisionShape3D.new(); holder.name = part; holder.shape = shape; holder.transform = at
	body.add_child(holder)
