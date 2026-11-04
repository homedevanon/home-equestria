extends Node
## The briefcase's picture of any item that has no baked icon (dev 2026-11-03: "every item that goes
## into your inventory gets a screenshot of it and displays it as the icon in your briefcase. right
## now its brown circles"). The first time ItemCatalog.icon meets such an item, this builds the item
## in a small private world, photographs it from the same three-quarter view and studio light as
## tools/inventory/bake_item_icons.gd, keeps the PNG in user://item_icons/<game version>/ and tells
## the views. Mod items get pictures this way with no art of their own.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const SELF := "res://world/inventory/item_icon_camera.gd"
const FOLDER := "user://item_icons"
const GROUP := "item_icon_views"
const SIZE := 192
const YAW_DEGREES := 35.0
const PITCH_DEGREES := 28.0
const FOV := 26.0
const SETTLE_FRAMES := 3

static var _shots: Dictionary = {}
static var _looked: Dictionary = {}
static var _asked: Dictionary = {}
static var _camera: Node = null

var _queue: Array[Dictionary] = []
var _view: SubViewport
var _lens: Camera3D
var _busy := false

static func _file(id: String) -> String:
	var version := str(ProjectSettings.get_setting("application/config/version", "0"))
	return "%s/%s/%s.png" % [FOLDER, version.validate_filename(), id.validate_filename()]

## The picture already taken for this item, or null.
static func shot(id: String) -> Texture2D:
	if _shots.has(id): return _shots[id]
	if _looked.has(id): return null
	_looked[id] = true
	var path := _file(id)
	if not FileAccess.file_exists(path): return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty(): return null
	_shots[id] = ImageTexture.create_from_image(image)
	return _shots[id]

## A headless run has no renderer to photograph with.
static func wanted(id: String) -> bool:
	return not _asked.has(id) and not _shots.has(id) and DisplayServer.get_name() != "headless"

## Queues one photograph; `scene` is the item as ItemCatalog builds it.
static func request(id: String, scene: PackedScene) -> void:
	_asked[id] = true
	if scene == null: return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return
	if not is_instance_valid(_camera):
		_camera = (load(SELF) as Script).new()
		_camera.name = "ItemIconCamera"
		tree.root.add_child.call_deferred(_camera)
	_camera.call("enqueue", id, scene)

func enqueue(id: String, scene: PackedScene) -> void:
	_queue.append({"id": id, "scene": scene})
	if not _busy: _work.call_deferred()

func _work() -> void:
	if _busy: return
	_busy = true
	if _view == null: _build_studio()
	while not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		if not await _photograph(str(job.id), job.scene as PackedScene):
			break
	_busy = false
	if is_instance_valid(_view): _view.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _build_studio() -> void:
	_view = SubViewport.new()
	_view.size = Vector2i(SIZE, SIZE)
	_view.transparent_bg = true
	_view.own_world_3d = true
	_view.msaa_3d = Viewport.MSAA_4X
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_view)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1, 1, 1)
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_view.add_child(world_environment)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 40, 0)
	key.light_energy = 1.25
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -140, 0)
	fill.light_energy = 0.45
	_view.add_child(key)
	_view.add_child(fill)
	_lens = Camera3D.new()
	_lens.fov = FOV
	_lens.current = true
	_view.add_child(_lens)

## False only when the game is quitting.
func _photograph(id: String, scene: PackedScene) -> bool:
	var item := _item(id, scene)
	_view.add_child(item)
	if not await SHUTDOWN.frame(self):
		item.free()
		return false
	var box: Variant = _bounds(item)
	if box is AABB:
		_aim(box as AABB)
		_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		for i in SETTLE_FRAMES:
			if not await SHUTDOWN.frame(self):
				item.free()
				return false
		var image := _view.get_texture().get_image()
		_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if image != null and not image.is_empty() and image.get_used_rect().size != Vector2i.ZERO:
			_keep(id, image)
	item.queue_free()
	return true

## The item as the briefcase's _make_item builds it, frozen and with its scripts asleep.
func _item(id: String, scene: PackedScene) -> RigidBody3D:
	var visual := scene.instantiate() as Node3D
	var item := RigidBody3D.new()
	item.name = "IconItem"
	item.set_meta("item_id", id)
	item.freeze = true
	item.collision_layer = 0
	item.collision_mask = 0
	item.process_mode = Node.PROCESS_MODE_DISABLED
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(.11, .032, .15)
	shape.shape = box
	item.add_child(shape)
	item.add_child(visual)
	if visual.has_method("configure_body"): visual.configure_body(item, shape)
	return item

func _bounds(item: Node3D) -> Variant:
	var box: Variant = null
	for node: Node in item.find_children("*", "VisualInstance3D", true, false):
		var visual := node as VisualInstance3D
		if not visual.is_visible_in_tree() or visual is GPUParticles3D or visual is Light3D: continue
		var part: AABB = visual.global_transform * visual.get_aabb()
		box = part if box == null else (box as AABB).merge(part)
	return box

func _aim(box: AABB) -> void:
	var radius := maxf(box.size.length() * 0.5, 0.01)
	var pitch := deg_to_rad(-PITCH_DEGREES)
	var yaw := deg_to_rad(YAW_DEGREES)
	var direction := (Basis.from_euler(Vector3(pitch, yaw, 0.0)) * Vector3.BACK).normalized()
	var distance := radius / sin(deg_to_rad(FOV * 0.5)) * 1.18
	_lens.global_position = box.get_center() + direction * distance
	_lens.look_at(box.get_center(), Vector3.UP)
	_lens.near = maxf(distance - radius * 2.0, 0.005)
	_lens.far = distance + radius * 2.0

func _keep(id: String, image: Image) -> void:
	var path := _file(id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	_shots[id] = ImageTexture.create_from_image(image)
	get_tree().call_group(GROUP, "icon_ready", id)
