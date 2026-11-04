extends Node
## Curated paid stock at existing Ponyville shops. Main owns the save checkpoint.
## restore_state(saved) BEFORE setup(game); no disk writes or automatic restocking.
signal stock_changed(state: Dictionary)
const DISPLAY: Script = preload("res://world/food/food_display.gd")
const TOWN: String = "Zones/PonyvilleTown/"
## Exact anchors from town.tscn, rnl_scenery build group names and Hayburger runtime.
## Market stock uses authored inclined counters; restaurant stock uses existing worktops.
## "indoor" stock stops drawing with its shut room (Sugarcube's interior range; Hayburger has none).
const PLACEMENTS: Array[Dictionary] = [
	{"id":"ponyville:sugarcube:bakery", "anchor":"sugarcube_corner/BakeryRoom", "preset":"bakery", "columns":6, "at":Vector3(-1.40, 1.95, -0.85), "table":false, "indoor":true},
	{"id":"ponyville:sugarcube:pastries", "anchor":"sugarcube_corner/BakeryRoom", "preset":"pastries", "columns":5, "at":Vector3(1.49, 1.95, -0.85), "table":false, "indoor":true},
	{"id":"ponyville:sugarcube:drinks", "anchor":"sugarcube_corner/BakeryRoom", "preset":"drinks", "columns":3, "at":Vector3(2.98, 1.95, -0.85), "table":false, "indoor":true},
	{"id":"ponyville:sugarcube:cake", "anchor":"sugarcube_corner/BakeryRoom", "preset":"celebration", "columns":1, "at":Vector3(-3.95, 1.71, -1.10), "table":false, "indoor":true},
	{"id":"ponyville:hayburger:meals", "anchor":"Hayburger/RestaurantInterior", "preset":"restaurant", "columns":7, "at":Vector3(-1.15, 1.0575, -1.20), "table":false},
	{"id":"ponyville:market:produce", "anchor":"RNLScenery/Town/Market/kiosk_01_02", "preset":"produce", "columns":8, "at":Vector3(0, 1.217184, 0), "turn":PI, "tilt":0.23756, "margin":Vector2(0.04, 0.18), "table":false},
	{"id":"ponyville:market:bakery", "anchor":"RNLScenery/Town/Market/kiosk_02_02", "preset":"bakery", "columns":5, "at":Vector3(-0.55, 0.930637, -2.308675), "turn":PI, "tilt":PI / 15.0, "table":false},
	{"id":"ponyville:market:celebration", "anchor":"RNLScenery/Town/Market/kiosk_02_02", "preset":"celebration", "columns":1, "at":Vector3(1.04, 0.930637, -2.308675), "turn":PI, "tilt":PI / 15.0, "table":false},
	{"id":"ponyville:market:pantry", "anchor":"RNLScenery/Town/Market/cloudsdale_hotdogstand_02", "preset":"pantry", "columns":6, "at":Vector3(0, 1.011437, -1.684633), "turn":PI, "tilt":0.39051587, "table":false},
	{"id":"ponyville:market:cooking", "anchor":"RNLScenery/Town/Market/tent_friagram_lightbrown_01", "preset":"cooking", "category":"Cooking", "columns":3, "at":Vector3(0.65, 0.95, 6.35), "margin":Vector2(0.08, 0.16), "table":false},
	{"id":"ponyville:market:pony-feed", "anchor":"RNLScenery/Town/Market/tent_friagram_lightbrown_01", "preset":"pony-feed", "category":"Pony feed", "columns":2, "at":Vector3(-0.8, 0.95, 5.8), "margin":Vector2(0.08, 0.16), "table":false},
	{"id":"ponyville:fair:drinks", "anchor":"RNLScenery/East/Fair/kiosk_02_01", "preset":"drinks", "columns":3, "at":Vector3(0, 0.930637, -2.308675), "turn":PI, "tilt":PI / 15.0, "table":false},
	{"id":"ponyville:fair:regional", "anchor":"RNLScenery/East/Fair/kiosk_01_01", "preset":"regional", "columns":3, "at":Vector3(0, 1.217184, 0), "turn":PI, "tilt":0.23756, "table":false},
]
var _game: Node
var _stock: Dictionary = {}
var _displays: Dictionary = {}
var _populated: bool = false
var _retry: float = 0.0
## Explicit startup diagnostic only; no recurring timer/counter work in normal play.
var _trace_startup := "--stock-startup-profile" in OS.get_cmdline_user_args()
var _traced_refresh := false

func _exit_tree() -> void:
	for display: Node3D in active_displays():
		if not display.is_queued_for_deletion():
			display.queue_free()

func setup(game: Node) -> void:
	if is_instance_valid(_game):
		return
	_game = game
	# Let loaded scenery install its authored counter collision first.
	_retry = 0.1
	set_physics_process(true)

## After save restore and loaded counter installation, while the loading cover
## still owns input. Populate synchronously so material warmup sees real stock.
## Missing streamed anchors retain the normal retry; this never restocks a sale.
func prepare_loaded() -> void:
	if not is_instance_valid(_game) or not _game.is_inside_tree(): return
	refresh()
	_retry = 1.0

func _physics_process(delta: float) -> void:
	if not is_instance_valid(_game):
		return
	_retry -= delta
	if _retry > 0.0:
		return
	_retry = 1.0
	refresh()

## Bounded authored-path lookup also handles a streamed-out shop returning later.
func refresh() -> void:
	if not is_instance_valid(_game) or not _game.is_inside_tree():
		return
	var started: int = Time.get_ticks_usec() if _trace_startup else 0
	var built := 0
	for spec: Dictionary in PLACEMENTS:
		var id: String = spec.id
		var current: Variant = _displays.get(id)
		if is_instance_valid(current):
			continue
		var anchor: Node3D = _game.get_node_or_null(TOWN + str(spec.anchor)) as Node3D
		if anchor == null or not anchor.is_inside_tree():
			continue
		var display_started: int = Time.get_ticks_usec() if _trace_startup else 0
		var display: Node3D = DISPLAY.new()
		display.name = "FoodShop_" + str(spec.preset)
		display.display_id = id
		display.preset = spec.preset
		display.category_label = str(spec.get("category", ""))
		display.columns = spec.columns
		display.for_sale = true
		display.build_surface = spec.table
		display.indoor = bool(spec.get("indoor", false))
		display.spacing_margin = spec.get("margin", Vector2(0.10, 0.18))
		var at: Vector3 = spec.at
		var surface: Transform3D = anchor.global_transform.orthonormalized()
		surface.origin = anchor.to_global(at)
		surface.basis *= Basis(Vector3.UP, float(spec.get("turn", 0.0))) * Basis(Vector3.RIGHT, float(spec.get("tilt", 0.0)))
		if _stock.has(id):
			display.restore_stock(_stock[id])
		display.top_level = true
		display.transform = surface
		display.stock_changed.connect(_remember)
		anchor.add_child(display)
		_displays[id] = display
		_populated = true
		display.populate()
		_stock[id] = display.snapshot()
		built += 1
		if _trace_startup:
			print("STOCK_STARTUP_DISPLAY ", JSON.stringify({"owner":"food","id":id,"ms":float(Time.get_ticks_usec()-display_started)/1000.0,"items":display.available_count(),"physics_frame":Engine.get_physics_frames()}))
	if _trace_startup and (not _traced_refresh or built > 0):
		_traced_refresh = true
		print("STOCK_STARTUP_PASS ",JSON.stringify({"owner":"food","ms":float(Time.get_ticks_usec()-started)/1000.0,"new_displays":built,"physics_frame":Engine.get_physics_frames(),"loading_cover":_game.has_node("LoadingCover")}))

func _remember(state: Dictionary) -> void:
	_stock[str(state.display_id)] = state.duplicate(true)
	stock_changed.emit(snapshot())

func snapshot() -> Dictionary:
	return {"version":1, "displays":_stock.duplicate(true)}

## Pure worker-safe validation: reads only literal constants and the supplied value.
## Never instantiates DISPLAY, reads assets, or touches catalogue/static lazy caches.
## Partial display maps are valid (shops may not have streamed in before saving).
static func valid_snapshot(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var state: Dictionary = value
	if state.is_empty():
		return true
	var version: Variant = state.get("version")
	if state.size() != 2 or not (version is int or version is float) or version != 1 or not state.get("displays") is Dictionary:
		return false
	var displays: Dictionary = state.displays
	var presets: Dictionary = {}
	for spec: Dictionary in PLACEMENTS:
		presets[spec.id] = spec.preset
	for id: Variant in displays:
		if not id is String or not presets.has(id):
			return false
		var raw: Variant = displays[id]
		if not raw is Dictionary:
			return false
		var stock: Dictionary = raw
		if stock.size() != 2 or not stock.get("display_id") is String or stock.display_id != id or not stock.get("taken") is Array:
			return false
		var taken: Array = stock.taken
		# Saves from before the 2026-10-15 menu change list the old stock (dropped on restore).
		var keys: Array[String] = _keys(DISPLAY.PRESETS[presets[id]])
		var legacy: Array[String] = _keys(DISPLAY.LEGACY_PRESETS.get(presets[id], []))
		if taken.size() > maxi(keys.size(), legacy.size()):
			return false
		keys.append_array(legacy)
		var seen: Dictionary = {}
		for key: Variant in taken:
			if not key is String or not keys.has(key) or seen.has(key):
				return false
			seen[key] = true
	return true

static func _keys(slugs: Array) -> Array[String]:
	var keys: Array[String] = []
	for index: int in slugs.size():
		keys.append("%d:food:%s" % [index, slugs[index]])
	return keys

## Atomic validation; rejects late restores instead of recreating purchased portions.
## An absent food section in an older save means initial paid stock.
func restore_state(value: Variant) -> bool:
	if _populated or not valid_snapshot(value):
		return false
	var state: Dictionary = value
	var displays: Dictionary = state.get("displays", {})
	_stock = displays.duplicate(true)
	# Keep only portions of the current menus; old-menu keys (before 2026-10-15) mean nothing now.
	var presets: Dictionary = {}
	for spec: Dictionary in PLACEMENTS:
		presets[spec.id] = spec.preset
	for id: String in _stock:
		var current: Array[String] = _keys(DISPLAY.PRESETS[presets[id]])
		var kept: Array = []
		for key: Variant in _stock[id].taken:
			if current.has(key): kept.append(key)
		_stock[id].taken = kept
	return true

## Daily refill, called by world/shop/shop_world.gd at 06:00.
func restock() -> void:
	for display: Node3D in active_displays():
		display.restock()
	for id: String in _stock:
		_stock[id].taken = []
	stock_changed.emit(snapshot())

## The pony economy's refill (world/mechanics/market/market.gd plan_restock, via shop_world.gd):
## only the slots each keeper paid for, {display_id: [keys]}.
func restock_keys(plan: Dictionary) -> void:
	for display: Node3D in active_displays():
		display.restock_keys(plan.get(str(display.display_id), []))
	for id: String in _stock:
		var refill: Array = plan.get(id, [])
		_stock[id].taken = (_stock[id].taken as Array).filter(func(key: Variant) -> bool: return not key in refill)
	stock_changed.emit(snapshot())

func active_displays() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for value: Variant in _displays.values():
		if is_instance_valid(value):
			result.append(value)
	return result
