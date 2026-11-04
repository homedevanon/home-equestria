extends Node3D
## The photo camera (shop good "goods:camera", dev 2026-10-25): a vintage cine camera with an
## eyepiece on its back. Attached to the held item the first time it is used (on()).
## - VR: hold the eyepiece to one eye and that eye alone sees the lens view, vignetted, through a
##   black surround (the camera body); the other eye keeps the world. Trigger takes the photo.
## - Desktop: hold right click to look through it (the same vignetted view over the screen); click
##   takes the photo.
## A photo is a finished picture in the painting registry (kind "photo", painting_registry.gd) and
## goes straight into the photo journal (photo_journal.gd), which prints it once for a bit. The
## first photo brings the journal into the briefcase.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const FINDER_SHADER := preload("res://world/items/photo_finder.gdshader")
const OVERLAY_SHADER := preload("res://world/items/photo_overlay.gdshader")
const PHOTO_SIZE := Vector2i(1024, 768)
const FOV := 55.0
## Eyepiece this close to an eye (metres) puts that eye to the finder.
const EYE_REACH := 0.075
const IPD_HALF := 0.032
## Desktop: the lens sits this far ahead of the player's eye, past his hands and the camera body.
const DESKTOP_NEAR := 0.45
const SHOT_GAP := 1.2
const JOURNAL := "photo-journal"

var item: Node3D
var lens: Node3D
var eyepiece: Node3D
var _viewport: SubViewport
var _lens_camera: Camera3D
var _finder: MeshInstance3D
var _overlay: CanvasLayer
var _desktop_eye: Camera3D
var _vr_frame := -10
var _next_shot := 0.0

## The camera tool on this held item, made on first use.
static func on(held_item: Node3D) -> Node3D:
	var tool := held_item.get_node_or_null("PhotoCameraTool") as Node3D
	if tool != null: return tool
	tool = (load("res://world/items/photo_camera.gd") as GDScript).new()
	tool.name = "PhotoCameraTool"; tool.item = held_item
	held_item.add_child(tool)
	return tool

func _ready() -> void:
	lens = item.find_child("Lens", true, false) as Node3D
	eyepiece = item.find_child("Eyepiece", true, false) as Node3D
	_viewport = SubViewport.new()
	_viewport.size = PHOTO_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.msaa_3d = Viewport.MSAA_2X
	add_child(_viewport)
	_lens_camera = Camera3D.new()
	_lens_camera.fov = FOV; _lens_camera.near = 0.05; _lens_camera.far = 4000.0
	_viewport.add_child(_lens_camera)

func _exit_tree() -> void:
	_set_overlay(false)
	if is_instance_valid(_finder): _finder.queue_free()

## Desktop: right click held looks through the eyepiece.
func set_looking(on_: bool, eye: Camera3D) -> void:
	_desktop_eye = eye if on_ else null
	_set_overlay(on_)

func looking() -> bool:
	return _desktop_eye != null or (is_instance_valid(_finder) and _finder.visible)

## VR, every frame the camera is in a hand: which eye (if any) is at the eyepiece.
func vr_tick(head: Camera3D) -> void:
	_vr_frame = Engine.get_process_frames()
	if head == null or eyepiece == null: return
	var eye := -1
	var best := EYE_REACH
	for index in 2:
		var at: Vector3 = head.global_transform * Vector3(-IPD_HALF if index == 0 else IPD_HALF, 0, 0)
		var gap := at.distance_to(eyepiece.global_position)
		if gap < best: best = gap; eye = index
	if eye < 0:
		if is_instance_valid(_finder): _finder.hide()
		return
	if not is_instance_valid(_finder): _make_finder(head)
	if _finder.get_parent() != head: _finder.reparent(head, false)
	_finder.position = Vector3(-IPD_HALF if eye == 0 else IPD_HALF, 0, -0.12)
	(_finder.material_override as ShaderMaterial).set_shader_parameter("eye", eye)
	_finder.show()

func _process(_delta: float) -> void:
	if _desktop_eye != null and (not is_instance_valid(_desktop_eye) or not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		set_looking(false, null)
	if is_instance_valid(_finder) and _finder.visible and Engine.get_process_frames() - _vr_frame > 2: _finder.hide()
	var live := looking()
	if live: _aim()
	if _viewport.render_target_update_mode != SubViewport.UPDATE_ONCE:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if live else SubViewport.UPDATE_DISABLED

func _aim() -> void:
	if _desktop_eye != null and is_instance_valid(_desktop_eye):
		var pose := _desktop_eye.global_transform
		pose.origin -= pose.basis.z * DESKTOP_NEAR
		_lens_camera.global_transform = pose
	elif lens != null:
		_lens_camera.global_transform = Transform3D(lens.global_basis.orthonormalized(), lens.global_position)

func _make_finder(head: Camera3D) -> void:
	_finder = MeshInstance3D.new()
	_finder.name = "PhotoFinder"
	var quad := QuadMesh.new(); quad.size = Vector2(0.5, 0.5)
	_finder.mesh = quad
	var material := ShaderMaterial.new(); material.shader = FINDER_SHADER
	material.set_shader_parameter("view", _viewport.get_texture())
	material.render_priority = 120
	_finder.material_override = material
	_finder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_finder.extra_cull_margin = 1.0
	head.add_child(_finder)

func _set_overlay(on_: bool) -> void:
	if not on_:
		if is_instance_valid(_overlay): _overlay.queue_free()
		_overlay = null
		return
	if is_instance_valid(_overlay): return
	_overlay = CanvasLayer.new(); _overlay.layer = 60
	var view := TextureRect.new()
	view.texture = _viewport.get_texture()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new(); material.shader = OVERLAY_SHADER
	view.material = material
	_overlay.add_child(view)
	# The overlay is a child of this tool, so it goes when the camera leaves the hand.
	add_child(_overlay)

## Takes the photo: one render from the lens, written into the journal once the frame is drawn.
## False while the last shot settles.
func snap(inventory: Node, desktop_eye: Camera3D) -> bool:
	var now := Time.get_ticks_msec() * 0.001
	if now < _next_shot or not is_instance_valid(inventory): return false
	_next_shot = now + SHOT_GAP
	if desktop_eye != null and _desktop_eye == null:
		_desktop_eye = desktop_eye; _aim(); _desktop_eye = null
	else:
		_aim()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	SFX.play_at(item, "prop_select", item.global_position)   # no shutter sound yet
	RenderingServer.request_frame_drawn_callback(_developed.bind(weakref(inventory)))
	return true

func _developed(inventory_ref: WeakRef) -> void:
	if not is_inside_tree(): return
	var inventory: Node = inventory_ref.get_ref()
	if not is_instance_valid(inventory): return
	var image := _viewport.get_texture().get_image()
	if image == null or image.is_empty(): return
	image.convert(Image.FORMAT_RGBA8)
	var id := "%x-%04x" % [int(Time.get_unix_time_from_system()), randi() & 0xffff]
	if not REGISTRY.write_png(image, "art_%s.png" % id):
		_say(inventory, "Could not save the photo."); return
	REGISTRY.add_art(id, "L", "", REGISTRY.KIND_PHOTO)
	_keep_journal(inventory)
	SFX.play_at(item, "page", item.global_position)
	print("[photo] took photo ", id)

## The journal arrives with the first photo; a later one replaces it if it was thrown away.
func _keep_journal(inventory: Node) -> void:
	var store: Variant = inventory.get("inventory")
	if not store is Object: return
	for row: Variant in (store as Object).get("slots"):
		if row is Dictionary and str((row as Dictionary).get("id", "")) == JOURNAL: return
	for loan: Variant in ((store as Object).get("loans") as Dictionary).values():
		if str((loan as Dictionary).get("id", "")) == JOURNAL: return
	if int((store as Object).call("grant", JOURNAL, 1)) < 0: _say(inventory, "No room for your photo journal: the photo is saved.")

func _say(inventory: Node, text: String) -> void:
	var store: Variant = inventory.get("inventory")
	if store is Object: (store as Object).set("last_error", text)
	if inventory.has_method("_error"): inventory.call("_error")
