extends MultiMeshInstance3D
## Far-house window glow (dev 2026-10-13): past the lining range (mare_home_lining.gd, 60 m) a
## house shows no interior. Its windows show a soft 2D cartoon card instead (window_glow.gdshader):
## a warm/sky-tinted pane by day; at night lit only while its household has a lamp on
## (world/life/house_lamps.gd set_house_lit, dev 2026-10-17), dark otherwise or with nopony home.
## One MultiMesh for all the standard houses that share a parent (the town: one draw). Each house
## registers when its lining is installed (mare_home_lining.gd); the cards are built from the baked
## panes (window_panes.json, tools/interiors/bake_window_glow.gd) and each house's own transform.
## Cards sit just inside the glass, so frames and sashes stay in front. No process callback.
const PANES := "res://world/buildings/window_glow/window_panes.json"
const SHADER := preload("res://world/buildings/window_glow/window_glow.gdshader")
const SELF := "res://world/buildings/window_glow/window_glow.gd"
## Card behind the glass's inner face, in metres, and how much it overlaps the frame.
const INSET := 0.012
const GROW := 1.06
## Panes whose glow card shows outside the glass (M-WLD-03, board #220, W2-PROPS-ART): "design/pane"
## -> (height scale, drop as a share of the pane's half height). house_a's left window glass is
## taller than its frame opening: the trimmed card took 395 outside-glass sight lines to 5 at 85 m.
const CARD_TRIM := {"house_a/LeftWindow01Glass": Vector2(0.7, 0.2)}
static var _panes: Dictionary = {}
static var _material: ShaderMaterial
## Look 2026-11-10: lit houses inside the lining range get the lamp's glow added over the real
## room (window_glow_near.gdshader explains why). A second instance of the same cards, so the
## lit state above reaches it with no bookkeeping. Rollback: LOOK_NEAR_GLOW = false.
const LOOK_NEAR_GLOW := true
const NEAR_SHADER := preload("res://world/buildings/window_glow/window_glow_near.gdshader")
static var _near_material: ShaderMaterial
var _near: MultiMeshInstance3D
## Houses waiting for the next (deferred) build, per parent instance id.
static var _pending: Dictionary = {}

## A standard house joins its town's glow. Called from the house's own setup (its parent is still
## adding children then), so the build waits for the end of the frame.
static func add_house(house: Node3D) -> void:
	var town := house.get_parent() as Node3D
	if town == null or not _load_panes().has(house.scene_file_path.get_file().get_basename()): return
	var id := town.get_instance_id()
	if not _pending.has(id):
		_pending[id] = []
		Callable(_flush).call_deferred(id)
	(_pending[id] as Array).append(house)

static func _flush(id: int) -> void:
	var houses: Array = _pending.get(id, [])
	_pending.erase(id)
	var town := instance_from_id(id) as Node3D
	if town == null or not town.is_inside_tree() or town.is_queued_for_deletion(): return
	var glow := town.get_node_or_null("WindowGlow") as MultiMeshInstance3D
	if glow == null:
		glow = (load(SELF) as Script).new() as MultiMeshInstance3D
		glow.name = "WindowGlow"
		town.add_child(glow)
	glow.call("add", houses)

var _houses: Array = []
var _ranges: Dictionary = {}    # place id -> Vector2i(first card, card count)
## Each card's custom data as written: switching writes from here, never reads the GPU copy back.
var _customs: PackedColorArray = []
static var _lit_places: Dictionary = {}   # place id -> true while its household has a lamp on

## Household lamps switched (house_lamps.gd): that house's window cards light or go dark.
static func set_house_lit(place: String, on: bool) -> void:
	if on: _lit_places[place] = true
	else: _lit_places.erase(place)
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return
	for glow: Node in tree.get_nodes_in_group("window_glow"):
		glow.call("_show_lit", place, on)

func _show_lit(place: String, on: bool) -> void:
	if multimesh == null or not _ranges.has(place): return
	var span: Vector2i = _ranges[place]
	for i: int in range(span.x, mini(span.x + span.y, _customs.size())):
		var c := _customs[i]
		c.a = fmod(c.a, 1.0) + (1.0 if on else 0.0)
		_customs[i] = c
		multimesh.set_instance_custom_data(i, c)

static func _place_of(house: Node3D) -> String:
	for child: Node in house.get_children():
		if child.is_in_group("house_interiors"): return str(child.call("place_id"))
	return ""

func _ready() -> void:
	add_to_group("window_glow")
	# World-space instances: the town root's own transform must not apply twice.
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	material_override = _material
	if LOOK_NEAR_GLOW:
		if _near_material == null:
			_near_material = ShaderMaterial.new()
			_near_material.shader = NEAR_SHADER
		_near = MultiMeshInstance3D.new(); _near.name = "NearGlow"
		_near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_near.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_near.material_override = _near_material
		add_child(_near)

static func _load_panes() -> Dictionary:
	if _panes.is_empty() and FileAccess.file_exists(PANES):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PANES))
		if parsed is Dictionary: _panes = (parsed as Dictionary).get("designs", {})
	return _panes

static func _vec(value: Variant) -> Vector3:
	var a: Array = value
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

## Adds houses and rebuilds every card (a town has a few hundred; built once at load).
func add(houses: Array) -> void:
	for house: Variant in houses:
		if is_instance_valid(house) and house is Node3D and not _houses.has(house): _houses.append(house)
	var designs := _load_panes()
	var transforms: Array[Transform3D] = []
	var customs: PackedColorArray = []
	var kept: Array[Node3D] = []
	_ranges.clear()
	for entry: Variant in _houses:
		if not is_instance_valid(entry) or not (entry as Node3D).is_inside_tree(): continue
		var house := entry as Node3D
		kept.append(house)
		var design := house.scene_file_path.get_file().get_basename()
		var data: Dictionary = designs[design]
		var to_world := house.global_transform
		var centre := to_world * _vec(data.centre)
		# Seeded by the house, like its furniture: the same house keeps its night habits.
		var seed := float(posmod(hash(str(house.name)), 997)) / 997.0
		var metres := maxf(to_world.basis.get_scale().x, 0.001)
		var place := _place_of(house)
		# Custom alpha: the seed, plus 1 while the household has a lamp on.
		var lit_flag := 1.0 if _lit_places.has(place) else 0.0
		if place != "": _ranges[place] = Vector2i(transforms.size(), (data.panes as Array).size())
		for pane: Dictionary in data.panes:
			var normal := _vec(pane.n)
			var half_width := _vec(pane.u).length() * GROW
			var trim: Vector2 = CARD_TRIM.get(design + "/" + str(pane.get("name", "")), Vector2(1.0, 0.0))
			var half_height := _vec(pane.v).length() * GROW * trim.x
			# QuadMesh faces +Z: X = up x normal keeps the basis right-handed (front faces out).
			var across := Vector3.UP.cross(normal).normalized()
			var basis := Basis(across * half_width * 2.0, Vector3.UP * half_height * 2.0, normal * 0.01)
			var origin := _vec(pane.c) - normal * (float(pane.thick) * 0.5 + INSET / metres) - Vector3.UP * _vec(pane.v).length() * trim.y
			transforms.append(to_world * Transform3D(basis, origin))
			customs.append(Color(centre.x, centre.y, centre.z, seed + lit_flag))
	_houses = kept
	var cards := MultiMesh.new()
	cards.transform_format = MultiMesh.TRANSFORM_3D
	cards.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	cards.mesh = quad
	cards.instance_count = transforms.size()
	for i: int in transforms.size():
		cards.set_instance_transform(i, transforms[i])
		cards.set_instance_custom_data(i, customs[i])
	_customs = customs
	multimesh = cards
	if _near != null: _near.multimesh = cards
