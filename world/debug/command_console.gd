extends CanvasLayer
## Desktop and VR keyboard developer commands. No process loop, provider calls or work while closed.
const CATALOGUE := preload("res://world/population/pony_population_config.gd")
const PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const OWNER := preload("res://player/desktop_action_owner.gd")
const DEV := preload("res://world/dev_tools.gd")
const HELP := "spawn <pony name> — bring that pony nearby\nbits [amount] — add that many bits (no amount: set balance to 999999)\nnoclip — fly through walls and ground (again: walk)\nfly — fly with collisions (again: walk)\nunstuck — stand on the ground where you are\nhome — back to the Ponyville spawn\ntime <hour> — set the clock (0–24, e.g. time 7.5)\nshow [tomorrow] — Trixie puts on a stage show at the schoolhouse now (or tomorrow at 17:00)\nhelp — show commands\nclear — clear output\nclose — close console"
var game: Node
var player_body: Node
var field: LineEdit
var output: RichTextLabel
var _mouse_before := Input.MOUSE_MODE_CAPTURED
var _lock_owned := false
var _busy := false
var _loading_path := ""
var _catalogue: Dictionary = {}
var spatial: Node3D
var panel: PanelContainer

func setup(host: Node) -> void:
	game = host; layer = 120
	player_body = game.player.get_node_or_null("Body") if game.xr_active else game.player
	panel = PanelContainer.new(); panel.position = Vector2(24, 24); panel.size = Vector2(700, 360)
	panel.theme = preload("res://world/ui/readable_text_theme.gd").make()
	var style := StyleBoxFlat.new(); style.bg_color = Color(.055, .065, .08, .94); style.set_corner_radius_all(8)
	for edge in [SIDE_LEFT, SIDE_RIGHT, SIDE_TOP, SIDE_BOTTOM]: style.set_content_margin(edge, 14)
	panel.add_theme_stylebox_override("panel", style); add_child(panel)
	var column := VBoxContainer.new(); panel.add_child(column)
	var title := Label.new(); title.text = "Debug console · ` or Esc to close"; column.add_child(title)
	title.add_theme_font_size_override("font_size",24 if game.xr_active else 18)
	output = RichTextLabel.new(); output.custom_minimum_size = Vector2(660, 260)
	output.scroll_following = true; output.bbcode_enabled = false; column.add_child(output)
	output.add_theme_font_size_override("normal_font_size",22 if game.xr_active else 16)
	field = LineEdit.new(); field.placeholder_text = "help / spawn rainbowdash / bits"; field.max_length = 160
	field.add_theme_font_size_override("font_size",24 if game.xr_active else 18)
	field.text_submitted.connect(_submit); column.add_child(field)
	if game.xr_active:
		spatial = preload("res://world/ui/spatial_menu_panel.gd").new()
		game._find_camera(game.player).add_child(spatial)
		spatial.position = Vector3(0, -.12, -1.15)
		panel.reparent(spatial.content); panel.position = Vector2(70, 230)
		panel.size = Vector2(760, 380)
		spatial.hide()
	visible = false; _write(HELP)
	# Settings > Debug runs commands here (world/ui/settings_page.gd _build_debug).
	var settings := get_node_or_null("/root/Settings")
	if settings != null: settings.set("debug_console", self)

func _input(event: InputEvent) -> void:
	if not event is InputEventKey: return
	if spatial != null and visible and event.physical_keycode not in [KEY_QUOTELEFT, KEY_ESCAPE]:
		spatial.send_key(event); get_viewport().set_input_as_handled(); return
	if not event.pressed or event.echo: return
	# Made in every build; it answers only while the developer tools are on (world/dev_tools.gd).
	if not visible and not DEV.enabled(): return
	if event.physical_keycode == KEY_QUOTELEFT:
		if visible: close()
		else:
			if not is_instance_valid(player_body): return
			if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return
			if player_body.controls_locked:
				if game.xr_active: return
				var activity := OWNER.current(game.inventory)
				if activity == null or not activity.has_method("owns_control_lock") or not activity.owns_control_lock(): return
			if not game.xr_active: OWNER.cancel_current(game.inventory)
			if player_body.controls_locked: return
			_mouse_before = Input.mouse_mode
			_lock_owned = true; player_body.controls_locked = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; visible = true
			if spatial != null: spatial.show(); spatial.refresh()
			field.grab_focus()
		get_viewport().set_input_as_handled()
	elif visible and event.physical_keycode == KEY_ESCAPE:
		close(); get_viewport().set_input_as_handled()

func close() -> void:
	if not visible: return
	if is_instance_valid(field) and field.is_inside_tree(): field.release_focus()
	visible = false
	if spatial != null: spatial.hide()
	if _lock_owned and is_instance_valid(player_body): player_body.controls_locked = false
	_lock_owned = false; Input.mouse_mode = _mouse_before

func _exit_tree() -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings != null and settings.get("debug_console") == self: settings.set("debug_console", null)
	if visible: close()
	if is_instance_valid(spatial): spatial.queue_free()
	# Release the threaded request even if the world closes during a summon.
	if not _loading_path.is_empty():
		var status := ResourceLoader.load_threaded_get_status(_loading_path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS or status == ResourceLoader.THREAD_LOAD_LOADED:
			ResourceLoader.load_threaded_get(_loading_path)
		_loading_path = ""

func _write(text: String) -> void:
	# Bound retained UI text even during long debug sessions.
	if output.text.length() > 12000: output.text = output.text.right(8000)
	output.append_text(text + "\n")
	if spatial != null: spatial.refresh()

static func name_key(value: String) -> String:
	return value.to_lower().replace(" ", "").replace("_", "").replace("-", "").strip_edges()

func resolve_pony(value: String) -> String:
	if _catalogue.is_empty(): _catalogue = CATALOGUE.catalogue()
	var key := name_key(value)
	for id: String in _catalogue:
		if key == name_key(id) or key == name_key(CATALOGUE.pony_name(id)): return id
	return ""

func _submit(line: String) -> void:
	field.clear()
	if _busy: _write("A spawn is still loading."); return
	var text := line.strip_edges()
	if text.is_empty(): return
	_write("> " + text)
	var reply := await execute(text)
	if not is_inside_tree(): return
	_write(reply)
	if visible: field.grab_focus()

func execute(text: String) -> String:
	var command := text.get_slice(" ", 0).to_lower()
	var argument := text.substr(command.length()).strip_edges()
	match command:
		"help": return HELP
		"clear": output.clear(); return ""
		"close", "exit": close(); return ""
		"bits":
			if not argument.is_empty() and not argument.is_valid_int(): return "Usage: bits [amount]"
			if not is_instance_valid(game.inventory): return "Inventory is not ready."
			var wallet: RefCounted = game.inventory.inventory
			if wallet == null: return "Inventory is not ready."
			if not argument.is_empty():
				var amount := argument.to_int()
				var added: bool = amount == 0 or (wallet.credit_bits(amount) if amount > 0 else wallet.debit_bits(-amount))
				return ("Balance: %d" % int(wallet.bits)) if added else "Could not update balance: " + str(wallet.last_error)
			var difference: int = 999999 - int(wallet.bits)
			var ok: bool = difference == 0 or (wallet.credit_bits(difference) if difference > 0 else wallet.debit_bits(-difference))
			return "Balance: 999999" if ok else "Could not update balance: " + str(wallet.last_error)
		"noclip", "fly":
			return _fly(command == "noclip")
		"unstuck":
			var at := _body_position()
			if not at.is_finite(): return "No player body."
			var ground := WorldTerrain.instance.height_at(at) if WorldTerrain.instance != null else NAN
			if not is_finite(ground): return _place(game.spawn.global_position, "Back at the spawn (no ground found here).")
			return _place(Vector3(at.x, ground + 0.5, at.z), "On the ground.")
		"home":
			return _place(game.spawn.global_position, "Back at the Ponyville spawn.")
		"time":
			if not argument.is_valid_float(): return "Usage: time <hour>, e.g. time 7.5"
			var hour := float(argument)
			if hour < 0.0 or hour > 24.0: return "Hours run from 0 to 24."
			var clock := get_node_or_null("/root/TimeOfDay")
			if clock == null: return "The clock is not running."
			clock.set("hours", fmod(hour, 24.0))
			return "Time: " + str(clock.call("time_string"))
		"show":
			var runtime: Node = game.get_node_or_null("TrixieShow")
			if runtime == null: return "The show runtime is not loaded."
			if argument.to_lower() == "tomorrow": return runtime.force_next_day()
			if runtime.active(): return "A show is already on."
			return "Trixie is on her way to the schoolhouse stage." if runtime.start(true) else "Trixie cannot perform right now."
		"spawn":
			var id := resolve_pony(argument)
			if id.is_empty(): return "Unknown pony. Try spawn rainbowdash, spawn cherryberry, spawn celestia or spawn luna."
			_busy = true
			var result := await _spawn(id)
			_busy = false
			return result
	return "Unknown command. Type help."

## Debug flight on the desktop rig (player/desktop_player.gd \\ and Shift+\\); VR flies without noclip.
func _fly(through: bool) -> String:
	if not is_instance_valid(player_body) or not "flying" in player_body: return "No player body."
	if "noclip" in player_body:
		var on: bool = not (player_body.flying and player_body.noclip == through)
		player_body.flying = on; player_body.noclip = on and through
	else:
		if through: return "Noclip is desktop only; try fly."
		player_body.flying = not player_body.flying
	if not player_body.flying and "velocity" in player_body: player_body.velocity = Vector3.ZERO
	if not player_body.flying: return "Walking."
	return "Noclip on: Space up, Ctrl down, Shift faster." if through else "Flying: Space up, Ctrl down, Shift faster."


func _body_position() -> Vector3:
	return (player_body as Node3D).global_position if is_instance_valid(player_body) and player_body is Node3D else Vector3(NAN, NAN, NAN)


func _place(at: Vector3, reply: String) -> String:
	if not is_instance_valid(player_body) or not player_body is Node3D: return "No player body."
	if player_body.has_method("teleport"): player_body.teleport(at)
	else:
		if player_body.get("seat") != null and is_instance_valid(player_body.get("seat")) and player_body.has_method("stand_up"): player_body.stand_up()
		(player_body as Node3D).global_position = at
		if "velocity" in player_body: player_body.velocity = Vector3.ZERO
	return reply


func _spawn(id: String) -> String:
	var population: Node = game.population
	if not is_instance_valid(population): return "Population is not ready."
	if population._spawning == id or population.visiting.has(id): return "That pony is already spawning or on a visit."
	var camera: Camera3D = game._find_camera(game.player)
	if camera == null: return "Player camera is not ready."
	var forward := -camera.global_basis.z; forward.y = 0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	var wanted := camera.global_position + forward.normalized() * 3.0
	wanted.y = game.player.global_position.y + .2
	var existing: Node3D
	for actor: Node3D in game.mares:
		if is_instance_valid(actor) and actor.identity != null and actor.identity.id == id: existing = actor; break
	var region: String = str(WorldLayout.nearest(wanted).get("id", "ponyville"))
	var navigation: Node = game._resident_service(region, wanted)
	if navigation == null: return "No loaded navigation near you."
	if not navigation.ready_for_paths: return "Ground navigation is still loading; try again shortly."
	if is_instance_valid(existing):
		var nav: Node = existing.get_node_or_null("Navigator")
		if nav != null and not str(nav.reserved_by).is_empty(): return "That pony is currently needed by an active encounter."
		var home: Node3D = preload("res://world/buildings/house_interior.gd").at(get_tree(), wanted)
		var point := PLACEMENT.support(existing.get_world_3d().direct_space_state, wanted, existing.profile, home, [existing.get_rid()])
		if not point.is_finite(): return "No safe clear floor in front of you. Try facing an open spot."
		if nav != null: nav.stay(); nav._native_clear(); nav._service = navigation
		existing.reset_motion(Transform3D(existing.global_basis, point))
		existing.set_meta("navigation_region", region)
		_register_resident(id, existing, region)
		return "Brought " + CATALOGUE.pony_name(id) + " nearby."
	var path: String = _catalogue[id]
	if ResourceLoader.load_threaded_request(path, "PackedScene") != OK: return "Could not load that pony."
	_loading_path = path
	population.visiting[id] = true
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if not await SHUTDOWN.seconds(self, .05):
				if is_instance_valid(population): population.visiting.erase(id)
				return "Spawn cancelled."
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_LOADED:
		_loading_path = ""
		population.visiting.erase(id)
		return "Could not load that pony."
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	_loading_path = ""
	var actor: Node3D
	if packed != null:
		actor = await game._spawn_resident(id, str(population.config.assignments.get(id, region)), wanted, packed, region, self)
	if not is_instance_valid(population): return "Spawn cancelled."
	population.visiting.erase(id)
	if not is_instance_valid(actor): return "Could not find safe nearby ground for that pony."
	_register_resident(id, actor, region)
	return "Spawned " + CATALOGUE.pony_name(id) + "."

func _register_resident(id: String, actor: Node3D, region: String) -> void:
	# Home assignment stays intact; current physical location belongs to the visit.
	game.population.live[id] = {"actor":actor, "region":str(game.population.config.assignments.get(id, region))}
	if not is_instance_valid(game.life): return
	game.life.detach(id)
	game.life._sync_roster()
	if game.life.core.state.residents.has(id): game.life.core.state.residents[id].region = region
	game.life.attach(id, actor, true)
