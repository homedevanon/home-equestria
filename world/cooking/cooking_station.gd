extends Node3D
## A pan on an existing cooker. Only active heat processes; ingredients retain inventory loans.
const VIEW := preload("res://world/player_view.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const INDEX := preload("res://world/cooking/cooking_index.gd")
const STATE := preload("res://world/cooking/cooking_state.gd")
const RECIPES := preload("res://world/cooking/cooking_recipes.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
var station_id := ""
var inventory_ui: Node
var pan: StaticBody3D
var knob: StaticBody3D
var heat_visual: MeshInstance3D
var knob_visual: Node3D
var status: MeshInstance3D
var _timer_tile := -1
var elapsed := 0.0
var heat := false
var _since_save := 0.0
var _saving := false
var _failed := false
var _saved_mark: Dictionary = {}
var _ingredients: Array[String] = []
var _recipe: Dictionary = {}
var _heat_sound := 0
var _heat_event := ""
var _audio_tick := 0.0

func _ready() -> void:
	add_to_group("home_cookers")
	set_notify_transform(true)
	INDEX.add(self)
	set_process(false)

func bind(ui: Node) -> void:
	if inventory_ui == ui: return
	if is_instance_valid(inventory_ui) and inventory_ui.inventory.changed.is_connected(refresh): inventory_ui.inventory.changed.disconnect(refresh)
	inventory_ui = ui
	inventory_ui.inventory.changed.connect(refresh)
	refresh()

func refresh() -> void:
	if _saving or not is_instance_valid(inventory_ui): return
	_ingredients = STATE.ids(inventory_ui.inventory, station_id)
	_recipe = RECIPES.complete(_ingredients)
	var saved: Dictionary = STATE.mark(inventory_ui.inventory, station_id)
	if saved != _saved_mark:
		_saved_mark = saved.duplicate()
		heat = bool(saved.get("heat", false))
		elapsed = float(saved.get("elapsed", 0.0))
		_since_save = 0.0
		_failed = false
	for token: String in STATE.tokens(inventory_ui.inventory, station_id):
		var item: Variant = inventory_ui.loose.get(token)
		if is_instance_valid(item):
			presentation(item, true)
			item.freeze = true
			item.global_transform = inventory_ui.STORE.decode_pose(inventory_ui.inventory.loans[token].world_transform)
	_update_visuals()
	_sync_heat_audio()
	set_process(heat)

func accepted_ids() -> Array[String]:
	return _ingredients.duplicate()

func can_accept(ui: Node, item: RigidBody3D) -> bool:
	if not is_instance_valid(item) or not item.has_meta("token"): return false
	bind(ui)
	var loan: Dictionary = ui.inventory.loans.get(str(item.get_meta("token")), {})
	if loan.is_empty() or loan.has("cooking") or loan.has("bites"): return false
	var proposed: Array[String] = _ingredients.duplicate()
	proposed.append(str(loan.id))
	return not RECIPES.candidates(proposed).is_empty()

func deposit_pose(ui: Node, item: RigidBody3D) -> Transform3D:
	var count: int = STATE.tokens(ui.inventory, station_id).size()
	var spots: Array[Vector3] = [Vector3(-.085,0,-.085), Vector3(.085,0,-.085), Vector3(-.085,0,.085), Vector3(.085,0,.085)]
	var pose := pan.global_transform.orthonormalized()
	pose.origin += pose.basis * (spots[mini(count, 3)] + Vector3.UP * (.025 + FOOD.rest_height(str(item.get_meta("item_id", "")), pose.basis)))
	return pose

func deposit(ui: Node, side: String) -> bool:
	var item: RigidBody3D = ui.held.get(side)
	if not can_accept(ui, item): return false
	bind(ui)
	var pose := deposit_pose(ui, item)
	if not STATE.deposit(ui.inventory, str(item.get_meta("token")), station_id, pose):
		ui._error(); return false
	ui._unglow(item)
	ui.held.erase(side); ui._track.erase(side); ui._eat_time.erase(side); ui._claim(side, false)
	for key: String in ["world_pick", "hold_offset", "hold_from", "hold_blend", "ray_hold", "toggle_armed"]:
		if item.has_meta(key): item.remove_meta(key)
	presentation(item, true)
	item.global_transform = pose
	item.freeze = true; item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	ui._refresh_holding(); ui._haptic(side)
	SFX.play_event(self, "prop_pan_place", {"intensity": .65}, pose.origin)
	refresh()
	return true

func can_heat(ui: Node) -> bool:
	bind(ui)
	return not _recipe.is_empty()

func toggle(ui: Node) -> bool:
	bind(ui)
	if not can_heat(ui): return false
	var desired := not heat
	if not STATE.save_heat(ui.inventory, station_id, desired, elapsed):
		ui._error(); return false
	# An explicit retry may write the same durable mark after a failed output spawn.
	heat = desired; _failed = false; _since_save = 0.0
	_saved_mark = STATE.mark(ui.inventory, station_id)
	set_process(heat); _update_visuals(); _sync_heat_audio()
	SFX.play_at(self, "prop_cook_toggle", knob.global_position if is_instance_valid(knob) else global_position)
	return true

func _process(delta: float) -> void:
	_audio_tick -= delta
	if _audio_tick <= 0.0: _sync_heat_audio()
	if not heat or not is_instance_valid(inventory_ui):
		_stop_heat_audio(); set_process(false); return
	var recipe: Dictionary = _recipe
	if recipe.is_empty(): refresh(); return
	elapsed = minf(float(recipe.seconds), elapsed + maxf(delta, 0.0))
	_since_save += delta
	if _since_save >= 5.0 or elapsed >= float(recipe.seconds):
		_saving = true
		var saved := STATE.save_heat(inventory_ui.inventory, station_id, true, elapsed)
		_saving = false
		if not saved:
			# Last durable contents and progress survive. Retry requires a deliberate knob turn.
			heat = false; _failed = true; set_process(false); _stop_heat_audio(); _update_visuals(); return
		_saved_mark = STATE.mark(inventory_ui.inventory, station_id)
		_since_save = 0.0
	if elapsed >= float(recipe.seconds): _finish(recipe)
	_update_visuals()

func _finish(recipe: Dictionary) -> void:
	var active: Array[String] = STATE.tokens(inventory_ui.inventory, station_id)
	if active.is_empty(): return
	var token: String = active[0]
	var scene: PackedScene = CATALOG.scene(str(recipe.output))
	if scene == null: _stop_failed(); return
	var visual := scene.instantiate() as Node3D
	if visual == null or (visual.has_method("prepare") and not visual.prepare()):
		if visual != null: visual.free()
		_stop_failed(); return
	# Preparing the retained body can fail without consuming a single ingredient.
	var output: RigidBody3D = inventory_ui._make_item(token, str(recipe.output), visual)
	var pose := pan.global_transform.orthonormalized()
	pose.origin += pose.basis.y * (.027 + FOOD.rest_height(str(recipe.output), pose.basis))
	output.global_transform = pose; output.hide()
	_saving = true
	var committed := STATE.finish(inventory_ui.inventory, station_id, token, pose)
	_saving = false
	if not committed:
		output.queue_free(); _stop_failed(); return
	for old_token: String in active:
		var old: Variant = inventory_ui.loose.get(old_token)
		inventory_ui.loose.erase(old_token)
		if is_instance_valid(old): old.queue_free()
	inventory_ui.loose[token] = output
	output.freeze = true; output.show()
	heat = false; elapsed = 0.0; _ingredients.clear(); _recipe = {}; _saved_mark.clear(); set_process(false)
	inventory_ui._refresh_holding()
	_stop_heat_audio()
	SFX.play_at(self, "prop_cook_finish", pan.global_position)
	# Stations adapter (world/mechanics/stations/stations.gd, row home_cooker): the "made" fact only.
	STATIONS.note(self, "home_cooker", "player", [str(recipe.output)])

func _stop_failed() -> void:
	heat = false; _failed = true; set_process(false)
	_stop_heat_audio()

func _update_visuals() -> void:
	if is_instance_valid(heat_visual): heat_visual.visible = heat
	if is_instance_valid(knob_visual): knob_visual.rotation.z = -.8 if heat else .8
	if not is_instance_valid(status): return
	var tile := 0
	if _failed: tile = 1
	elif heat: tile = 6 + clampi(ceili(float(_recipe.get("seconds", 0.0)) - elapsed), 0, 25)
	elif not _ingredients.is_empty(): tile = 1 + _ingredients.size()
	if tile != _timer_tile:
		_timer_tile = tile
		(status.material_override as StandardMaterial3D).uv1_offset = Vector3(float(tile % 4) * .25, float(tile / 4) * .125, 0)

func _sync_heat_audio() -> void:
	_audio_tick = .5
	if not heat or _recipe.is_empty() or not is_instance_valid(inventory_ui):
		_stop_heat_audio(); return
	var camera: Camera3D = VIEW.camera(self)
	var at := pan.global_position if is_instance_valid(pan) else global_position
	if camera != null and camera.global_position.distance_squared_to(at) > 100.0:
		_stop_heat_audio(); return
	var event := "prop_simmer_loop" if str(_recipe.get("id", "")) == "vegetable_noodles" else "prop_sizzle_loop"
	if _heat_event != event:
		_stop_heat_audio(); _heat_event = event
	if _heat_sound == 0: _heat_sound = SFX.start_loop(self, event, {"intensity": .65})
	if _heat_sound != 0 and not SFX.update_loop(self, _heat_sound, {"intensity": .65}, at):
		_heat_sound = 0

func _stop_heat_audio() -> void:
	if _heat_sound != 0: SFX.stop_loop(self, _heat_sound, .18)
	_heat_sound = 0; _heat_event = ""

static func presentation(item: Node, in_pan: bool) -> void:
	var raw := item.find_child("RawPortion", true, false) as Node3D
	var prepared := item.find_child("CookingPortion", true, false) as Node3D
	if raw != null and prepared != null:
		raw.visible = not in_pan
		prepared.visible = in_pan

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and is_inside_tree(): INDEX.add(self)

func _exit_tree() -> void:
	SFX.release_source(self)
	INDEX.remove(self)
