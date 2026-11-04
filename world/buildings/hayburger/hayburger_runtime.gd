extends Node3D
## Real Ponyville restaurant: an open room, voluntary customer visits and paid counter work.
const FRONT := preload("res://world/buildings/hayburger/hayburger_front.gd")
const ROOM := preload("res://world/buildings/hayburger/hayburger_interior.gd")
const SHELL := preload("res://world/buildings/hayburger/hayburger_shell.gd")
const SHIFT := preload("res://world/minigames/hayburger/hayburger_shift.gd")
const CUSTOMERS := preload("res://world/minigames/hayburger/hayburger_customers.gd")
const BENCH := preload("res://world/minigames/hayburger/hayburger_workbench.gd")
const HANDS := preload("res://world/minigames/hayburger/hayburger_hands.gd")
const CURRENCY := preload("res://world/ui/currency.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const COVER := preload("res://world/ui/sleep_cover.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const LEGACY := preload("res://world/mechanics/legacy.gd")
const JOB_SHIFT := preload("res://world/mechanics/jobs/job_shift.gd")
const JOBS := preload("res://world/mechanics/jobs/jobs.gd")

## The room inside the source shell (building-local): +Z of the room faces the -Z entrance.
static func room_placement() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, PI).scaled(Vector3(1.0, 1.0, 0.87)), Vector3(0.217227, 0.04, 0.45))

var front: Node3D
var business_open := true
var _environment_timer := 0.0
var _room_lights: Array[Node] = []
var _room_bounds := AABB()

var game: Node
var building: Node3D
var room: Node3D
var customers: Node
var shift: RefCounted
var bench: Node3D
var hands: Node
var shell_report: Dictionary = {}
var _bell: AudioStreamPlayer3D
var _display_timer := 0.0
var _queue_dirty := false
var _working := false
var _configured := false
var _order_speech_key := ""
var _order_speech_customer := ""
var _order_speech_director: Node
var _order_context_actors: Dictionary = {}
## Paid counter shift (board #110): the clock-in time, game hours spent behind the counter and
## the summary shown on the counter note after clocking out. The wage is paid once, at the end.
const WAGE_PER_HOUR := 10
const WAGE_MAX_HOURS := 14.0
var shift_started: Dictionary = {}
var duty_hours := 0.0
var last_summary := ""
var last_summary_until_ms := 0
var _duty_clock := -1.0
## Confirmed shift (board #110): the screen fades and a group of mares is brought to the door as the
## shift's first customers. The shift then runs until the player clocks out or the restaurant closes:
## no second fade and no skipped hours (player bug board #29: the old three-hour skip after the
## group "kicked me out 10-20 seconds after starting"; they want to talk to the ponies they serve).
const GROUP_SIZE := 3
const GROUP_TIMEOUT := 300.0
## Booked customer id -> "waiting", "served" or "left".
var shift_group: Dictionary = {}
var _group_clock := 0.0
var _transition := false

func _ready() -> void:
	if building == null and get_parent() != null:
		building = get_parent().find_child("burger_joint_01", true, false) as Node3D
	if building == null: return
	shell_report = SHELL.prepare(building, street_holes())
	if not shell_report.get("ok", false):
		push_warning("Hayburger shell could not open: " + str(shell_report.get("error", "unknown shell")))
		return
	room = ROOM.new(); room.name = "RestaurantInterior"
	add_child(room)
	# Room +Z faces the existing restaurant's -Z entrance. Filled source collider is
	# replaced by the carved shell; the room owns its floor and furniture collision.
	room.global_transform = building.global_transform * room_placement()
	# Street windows stay drawn when the furnished room is culled at a distance.
	var windows: Node3D = room.get_node_or_null("StreetWindows") as Node3D
	if windows != null:
		var placed: Transform3D = windows.global_transform
		room.remove_child(windows); add_child(windows); windows.global_transform = placed
	# Customers assemble outside before entering; finishing a visit returns them outside.
	room.get_node("EntrySpawn").position = Vector3(0, -0.04, 7.2)
	# Walk fully outside, then clear the incoming lane before releasing the lease.
	# An arrival tolerance at EntrySpawn previously left customers in the doorway.
	for spec: Array in [["EntryClearance",Vector3(0,-.04,8.8)],["DeparturePoint",Vector3(3,-.04,8.8)]]:
		var marker := Marker3D.new(); marker.name = spec[0]; marker.position = spec[1]; room.add_child(marker)
	# A four-centimetre finished-floor lip still stops a pony's body capsule.
	# Join street to floor with the same visible, colliding wedge used by houses.
	var threshold: StaticBody3D = preload("res://world/buildings/stair_brush.gd").build({
		"center_x":0.0, "width":2.3, "back_z":4.9, "landing_z":5.3,
		"toe_z":6.6, "height":0.0, "toe_y":-0.05})
	threshold.name = "EntryThreshold"; room.add_child(threshold)
	# The wood FloorSlab ends at z 5.24 (hayburger_interior.gd), level with the landing: the stone
	# drawn over the planks z-fought in front of the door (thread report 2026-10-31). The visible
	# stone starts at the plank edge; collision keeps the whole landing under the doorway.
	var shown: StaticBody3D = preload("res://world/buildings/stair_brush.gd").build({
		"center_x":0.0, "width":2.3, "back_z":5.24, "landing_z":5.3,
		"toe_z":6.6, "height":0.0, "toe_y":-0.05})
	(threshold.get_node("StoneRamp") as MeshInstance3D).mesh = (shown.get_node("StoneRamp") as MeshInstance3D).mesh
	shown.free()
	_bell = AudioStreamPlayer3D.new(); _bell.name = "ServiceBell"
	_bell.stream = preload("res://world/inventory/assets/deposit.wav")
	_bell.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	_bell.volume_db = -18; _bell.max_distance = 10
	room.add_child(_bell); _bell.position = Vector3(0, 1, -1.4)
	front = FRONT.new(); front.name = "RestaurantDoors"
	front.building = building; front.report = shell_report
	building.add_child(front)
	_room_lights = room.find_children("*", "Light3D", true, false)
	_room_bounds = room.global_transform * AABB(Vector3(-6.5,0,-5.5),Vector3(13,4,11))
	_update_environment()


## Building-local (x, y) rectangles of the room's street windows, where the painted glass
## bands get clear holes (dev 2026-10-14).
static func street_holes() -> Array:
	var holes: Array = []
	var placement: Transform3D = room_placement()
	for x: float in ROOM.WINDOW_X:
		var a: Vector3 = placement * Vector3(x - ROOM.WINDOW_SIZE.x * .5, ROOM.WINDOW_SILL, ROOM.ROOM_SIZE.z * .5)
		var b: Vector3 = placement * Vector3(x + ROOM.WINDOW_SIZE.x * .5, ROOM.WINDOW_SILL + ROOM.WINDOW_SIZE.y, ROOM.ROOM_SIZE.z * .5)
		holes.append(Rect2(minf(a.x, b.x), minf(a.y, b.y), absf(b.x - a.x), absf(b.y - a.y)))
	return holes

func setup(host: Node) -> void:
	if _configured or room == null: return
	_configured = true; game = host
	shift = SHIFT.new(); shift.external_customers = true
	shift.reward_sink = _pay
	shift.changed.connect(func(): _queue_dirty = true)
	shift.served_order.connect(_served)
	customers = CUSTOMERS.new(); customers.name = "Customers"; add_child(customers)
	customers.customer_arrived.connect(_customer_arrived)
	customers.customer_departed.connect(_customer_departed)
	customers.setup(game, room)
	customers.set_open(business_open)
	bench = BENCH.new(); bench.name = "PhysicalKitchen"; room.add_child(bench); bench.setup(self)
	hands = HANDS.new(); hands.name = "KitchenHands"; add_child(hands); hands.setup(self,bench,game.inventory)
	# Cached walk-grid chunks may still contain the former filled building box.
	for service: Node in get_tree().get_nodes_in_group("pony_navigation"):
		refresh_navigation(service)
	_queue_dirty = true

func refresh_navigation(service: Node) -> void:
	if room == null or not is_instance_valid(service): return
	if not service.has_method("notify_geometry_changed"): return
	if service.get_meta("hayburger_geometry_applied", false): return
	var box: AABB = room.global_transform * AABB(Vector3(-6.5, -0.2, -5.5), Vector3(13, 4.2, 12.5))
	service.notify_geometry_changed(box)
	service.set_meta("hayburger_geometry_applied", true)

func work_snapshot() -> Dictionary:
	if shift == null: return {}
	var data: Dictionary = shift.snapshot()
	if is_instance_valid(game) and is_instance_valid(game.inventory):
		data["wallet_bits"] = game.inventory.inventory.bits
	if customers != null: data["visitors"] = customers.visitor_report()
	return data

func work_action(action: String) -> bool:
	if shift == null or (not business_open and action != "quit"): return false
	if action == "start":
		if _working: return false
		shift.start_shift(Time.get_ticks_usec())
		_working = true; customers.set_working(true)
		var clock: Node = get_node_or_null("/root/TimeOfDay")
		shift_started = {"day": int(clock.day), "hours": float(clock.hours)} if clock != null else {}
		# Jobs core (world/mechanics/jobs/job_shift.gd): a wage that could not be saved stays owed
		# and is paid with this shift's; `-- --old-jobs` keeps the old reset.
		if LEGACY.old_jobs(): duty_hours = 0.0
		_duty_clock = _clock_hours(); last_summary = ""
		shift_group.clear()
		return true
	if action == "quit":
		stop_working(); return true
	return shift.act(action)

## The counter bell's confirmed start: the shift begins and its customer group is brought in.
func start_confirmed_shift() -> bool:
	if not work_action("start"): return false
	_open_group_shift.call_deferred()
	return true

func stop_working() -> void:
	if not _working: return
	_count_duty()
	_working = false
	_sync_order_context()
	_cancel_order_speech()
	customers.set_working(false)
	shift_group.clear()
	var result: Dictionary = shift.snapshot()
	if result.state == "playing": shift.act("quit")
	_pay_wage(result)
	_queue_dirty = true

## Game hours on the absolute clock (day * 24 + hours); -1 without a clock.
func _clock_hours() -> float:
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	return float(clock.day) * 24.0 + float(clock.hours) if clock != null else -1.0

## Adds the game time since the last count, if the worker stood behind the counter for it.
func _count_duty() -> void:
	var now: float = _clock_hours()
	if _working and now >= 0.0 and _duty_clock >= 0.0 and can_work():
		duty_hours = minf(WAGE_MAX_HOURS, duty_hours + clampf(now - _duty_clock, 0.0, 1.0))
	_duty_clock = now

## The shift's wage, paid once at clock-out: whole and part hours behind the counter.
func wage_for(hours: float) -> int:
	return int(floor(clampf(hours, 0.0, WAGE_MAX_HOURS) * float(WAGE_PER_HOUR)))

## The running jobs core when it serves this game's world (none in fixtures without the hub).
func _jobs() -> Node:
	var jobs: Node = JOBS.of(get_tree()) if is_inside_tree() else null
	return jobs if jobs != null and is_instance_valid(game) and jobs.get("context") == game.get("world_context") else null

func _pay_wage(result: Dictionary) -> void:
	if LEGACY.old_jobs():
		_pay_wage_old(result)
		return
	var wage: int = wage_for(duty_hours)
	var paid := wage == 0
	if wage > 0 and is_instance_valid(game) and is_instance_valid(game.get("inventory")):
		# The jobs core's shift wage: the Hayburger till pays, then the town; receipt
		# job:hayburger:<day>:<saved serial>; duty is kept (owed) when the payment fails.
		var jobs := _jobs()
		var pay: RefCounted = JOB_SHIFT.new()
		pay.job_id = "hayburger"; pay.duty_hours = duty_hours
		paid = bool(pay.end(game, ["business:hayburger", "town"], int(jobs.next_serial()) if jobs != null else -1,
			{"per_hour": WAGE_PER_HOUR, "max_hours": WAGE_MAX_HOURS}).get("paid", false))
	var served: int = int(result.get("served", 0))
	last_summary = "Shift over: %d hayburger%s served (%s in tips), %.1f h behind the counter.\nWage %s%s." % [
		served, "" if served == 1 else "s", CURRENCY.amount(served * SHIFT.REWARD_BITS), duty_hours, CURRENCY.amount(wage),
		" paid" if paid else " could not be paid; it is added to your next wage if you work another shift before leaving"]
	last_summary_until_ms = Time.get_ticks_msec() + 90000
	if paid: duty_hours = 0.0

## The pre-port wage (`-- --old-jobs`): the town pays and the duty resets even when it failed.
func _pay_wage_old(result: Dictionary) -> void:
	var wage: int = wage_for(duty_hours)
	var paid := wage == 0
	if wage > 0 and is_instance_valid(game) and is_instance_valid(game.get("inventory")):
		# One pay path (world/mechanics/ledger.gd); the town pays until the jobs core (WP5).
		paid = LEDGER.transfer(game, "town", "player", wage, "wage").is_empty()
	var served: int = int(result.get("served", 0))
	last_summary = "Shift over: %d hayburger%s served (%s in tips), %.1f h behind the counter.\nWage %s%s." % [
		served, "" if served == 1 else "s", CURRENCY.amount(served * SHIFT.REWARD_BITS), duty_hours, CURRENCY.amount(wage),
		" paid" if paid else " could not be saved; ask again next shift"]
	last_summary_until_ms = Time.get_ticks_msec() + 90000
	duty_hours = 0.0

func _pay(amount: int) -> bool:
	if not business_open or not _working or amount != SHIFT.REWARD_BITS or not is_instance_valid(game): return false
	var orders: Array = shift.snapshot().orders
	if orders.is_empty() or not customers.can_serve(orders[0].id): return false
	var jobs := _jobs()
	if LEGACY.old_jobs() or jobs == null:
		return LEDGER.transfer(game, "town", "player", SHIFT.REWARD_BITS, "tip").is_empty()
	# The jobs core's unit pay: the customer tips from her purse, else the town; "worked" fact.
	return jobs.pay_unit("hayburger", "player", "", str(orders[0].get("customer_id", "")), SHIFT.REWARD_BITS, {"item": "food:hayburger"}).is_empty()

func _served(order: Dictionary, _reward: int) -> void:
	_sync_order_context()
	if is_instance_valid(game) and is_instance_valid(game.get("relationship_runtime")):
		game.relationship_runtime.shared_activity("meal",room.global_position,"meal_"+str(get_instance_id())+"_"+str(order.id),[str(order.customer_id)])
	_cancel_order_speech()
	customers.on_order_served(order, 20)
	# Facts stream (world/mechanics/facts.gd): counters only; the meal memory is shared_activity's.
	# With the jobs core, pay_unit already added it with the tip.
	if LEGACY.old_jobs() or _jobs() == null:
		FACTS.note(self, "worked", {"actor": "player", "target": str(order.customer_id), "item": "food:hayburger", "ref": "hayburger"})
	_bell.play()
	var id := str(order.customer_id)
	if shift_group.has(id): shift_group[id] = "served"

func _customer_arrived(id: String, display_name: String) -> void:
	if _working and shift.add_customer(id, display_name):
		customers.sync_orders(shift.snapshot().orders)

func _customer_departed(id: String) -> void:
	if id == _order_speech_customer: _cancel_order_speech()
	if shift != null: shift.remove_customer(id)
	_sync_order_context()

func _sync_order_context() -> void:
	var live: Dictionary = {}
	var director: Node = game.get("director") as Node if is_instance_valid(game) else null
	if _working and shift != null and is_instance_valid(director):
		for order: Dictionary in shift.snapshot().orders:
			var id := str(order.customer_id)
			if not director.characters.has(id): continue
			var actor: Node = director.characters[id].node
			if not is_instance_valid(actor): continue
			actor.set_meta("hayburger_order_context", "Your active Hayburger ticket: " + order_speech_intent(order) + " Ingredients: " + ", ".join(order.recipe) + ". You are waiting for this order; it has not been served. If asked to repeat it, use this exact order, not a guess from conversation history.")
			live[id] = actor
	for id: String in _order_context_actors:
		var actor: Node = _order_context_actors[id]
		if id not in live and is_instance_valid(actor): actor.remove_meta("hayburger_order_context")
	_order_context_actors = live

func _cancel_order_speech() -> void:
	if not _order_speech_key.is_empty() and is_instance_valid(_order_speech_director):
		_order_speech_director.cancel_authored_line(_order_speech_key)
	_order_speech_key = ""; _order_speech_customer = ""; _order_speech_director = null

## Rechecked by the director before synthesis/playback and while the line is live.
func _order_speech_valid(order_id: String, customer_id: String) -> bool:
	if not is_inside_tree() or not _working or shift == null or not is_instance_valid(customers): return false
	var snapshot: Dictionary = shift.snapshot()
	var orders: Array = snapshot.orders
	return snapshot.state == "playing" and not orders.is_empty() and str(orders[0].id) == order_id \
		and str(orders[0].customer_id) == customer_id and customers.can_serve(order_id)

func _sync_order_speech() -> void:
	_sync_order_context()
	var orders: Array = shift.snapshot().orders if shift != null else []
	if not _working or orders.is_empty(): _cancel_order_speech(); return
	var order: Dictionary = orders[0]
	var id := str(order.customer_id); var order_id := str(order.id)
	var key := "hayburger:%d:%s" % [get_instance_id(), order_id]
	if not _order_speech_key.is_empty() and key != _order_speech_key: _cancel_order_speech()
	if not _order_speech_valid(order_id, id):
		_cancel_order_speech(); return
	var director: Node = game.get("director") as Node if is_instance_valid(game) else null
	if not is_instance_valid(director) or not director.has_method("queue_generated_intent"): return
	var text := order_speech_intent(order)
	if director.queue_generated_intent(id, text, key, _order_speech_valid.bind(order_id, id)):
		_order_speech_key = key; _order_speech_customer = id; _order_speech_director = director

static func order_speech_intent(order: Dictionary) -> String:
	return "You are ordering the actual customer ticket at Hayburger. Request it naturally in your own words. Ticket name: %s. Required ingredients: %s. Do not change the order, invent extras, or give construction instructions. This is your request to the server, not a quotation to recite." % [str(order.recipe_name),", ".join(order.recipe)]

func can_work() -> bool:
	if not business_open or not _configured or not is_instance_valid(game) or not is_instance_valid(game.inventory): return false
	var camera: Camera3D = game.inventory.camera
	if camera == null: return false
	var local: Vector3 = room.to_local(camera.global_position)
	if absf(local.x) > 5.85 or local.z < -4.85 or local.z > -1.8 or local.y < 0.25 or local.y > 3.3: return false
	return true

func menus_available() -> bool:
	if not is_instance_valid(game): return false
	for item in [game.save_menu, game.settings_menu, game.pause_menu]:
		if is_instance_valid(item) and item.opened: return false
	return not game.inventory.player_body.controls_locked

func exclusive_inputs() -> Array[Node]:
	var result: Array[Node] = []
	for item in [game.save_menu, game.settings_menu, game.pause_menu, game.get_node_or_null("ChatBox")]:
		if is_instance_valid(item): result.append(item)
	if is_instance_valid(game.inventory.camera):
		for child in game.inventory.camera.get_children():
			if child.get_script() == preload("res://player/interactor.gd"): result.append(child)
	return result

func _process(delta: float) -> void:
	_environment_timer -= delta
	if _environment_timer <= 0.0:
		_environment_timer = 0.25
		_update_environment()
	if not _configured: return
	if _working:
		shift.advance(delta)
		if not shift_group.is_empty() and not _transition: _check_group(delta)
	_display_timer -= delta
	if _display_timer > 0.0: return
	_display_timer = 0.1
	if _queue_dirty:
		_queue_dirty = false
		customers.sync_orders(shift.snapshot().orders)
	_sync_order_speech()
	if room.visible: bench.refresh()

## Fade to black and back; null without a player view (fixtures), then the steps are instant.
func _cover() -> Node:
	if not is_instance_valid(game) or not game.has_method("_find_camera") or game.get("player") == null: return null
	var cover: Node = COVER.new(); cover.name = "ShiftCover"; game.add_child(cover); cover.setup(game)
	return cover

func _lock_player(locked: bool) -> void:
	if not is_instance_valid(game) or not is_instance_valid(game.get("inventory")): return
	var body: Node = game.inventory.get("player_body")
	if is_instance_valid(body) and "controls_locked" in body: body.controls_locked = locked

## False (and the cover freed, the player released) once the world is going away.
func _still_here(cover: Node) -> bool:
	if not SHUTDOWN.active and is_inside_tree() and not is_queued_for_deletion(): return true
	if is_instance_valid(cover): cover.queue_free()
	_transition = false
	return false

func _open_group_shift() -> void:
	if not _working or _transition: return
	_transition = true
	var cover := _cover()
	if cover != null:
		_lock_player(true)
		await cover.close_eyes()
		if not _still_here(cover): return
	var booked: Array[String] = []
	if _working and customers.has_method("book_group"): booked = customers.book_group(GROUP_SIZE)
	for id: String in booked: shift_group[id] = "waiting"
	_group_clock = 0.0
	if cover != null:
		if not await SHUTDOWN.seconds(self, 0.5) or not _still_here(cover): return
		await cover.open_eyes()
		if not _still_here(cover): return
		cover.finish()
		_lock_player(false)
	_transition = false

## Every booked customer was served or has gone (or the group took far too long): the counter stays
## open for walk-ins, and the group leaves on foot after their meal like any customer.
func _check_group(delta: float) -> void:
	_group_clock += delta
	var visitors: Variant = customers.get("_visitors")
	var waiting := false
	for id: String in shift_group:
		if shift_group[id] != "waiting": continue
		if visitors is Dictionary and (visitors as Dictionary).has(id): waiting = true
		else: shift_group[id] = "left"
	if waiting and _group_clock <= GROUP_TIMEOUT: return
	if not shift_group.values().has("served"):
		print("[hayburger] booked group left unserved (", customers.get("_last_reason"), "); shift continues")
	shift_group.clear()

func _exit_tree() -> void:
	_working = false
	_sync_order_context()
	_cancel_order_speech()
	if is_instance_valid(customers): customers.release_all()

## Business hours and rendering do not suspend customers, cooking or collision.
func _update_environment() -> void:
	if room == null: return
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var hours: float = float(clock.hours) if clock != null else 12.0
	var open_now: bool = hours >= 8.0 and hours < 22.0
	if _working: _count_duty()
	# Door sign: SKIBIDI from sunrise, TOILET from sunset (dev 2026-10-14).
	if clock != null and front.has_method("set_daytime"): front.set_daytime(float(clock.sun_elevation()) >= 0.0)
	if front.business_open != open_now or business_open != open_now:
		business_open = open_now
		front.set_open(open_now)
		if customers != null and customers.has_method("set_open"): customers.set_open(open_now)
		if not open_now: stop_working()
		if bench != null: bench.refresh()
	for light: Node3D in _room_lights:
		if light.visible != business_open: light.visible = business_open
	var bulb: StandardMaterial3D = room._materials.get("bulb")
	if bulb != null and bulb.emission_enabled != business_open: bulb.emission_enabled = business_open
	var camera: Camera3D = preload("res://world/player_view.gd").camera(self)
	if is_instance_valid(game) and is_instance_valid(game.get("inventory")):
		var eye: Camera3D = game.inventory.camera
		if eye != null: camera = eye
	if camera != null:
		var at: Vector3 = camera.global_position
		var closest: Vector3 = at.clamp(_room_bounds.position, _room_bounds.end)
		var distance: float = at.distance_to(closest)
		# Five metres of hysteresis prevents flicker at the cutoff. Keep carried
		# kitchen food visible until it is released, even outside the restaurant.
		var carrying: bool = bench != null and not bench.held.is_empty()
		room.visible = carrying or distance < (40.0 if room.visible else 35.0)
	# Customer simulation continues while furnishings are culled. Nearby ponies
	# can pass either way by day, and only outwards after closing.
	if is_instance_valid(game) and game.get("mares") is Array:
		for actor: Node in game.mares:
			if actor is Node3D: front.offer_passage(actor)
	if customers != null and customers.get("_visitors") is Dictionary:
		for visit: Dictionary in customers._visitors.values():
			if is_instance_valid(visit.actor):
				if not business_open and front.is_inside(visit.actor.global_position): front.keep_exit_open()
				front.offer_passage(visit.actor)
