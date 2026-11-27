extends Node
## Applejack's wagon wheel: a small farm event at Sweet Apple Acres. The apple wagon in the farmyard
## (scenery "appleacres_wagon_01", world/props/ponyville/rnl_scenery.json) stands at WAGON_AT and is
## drawn as the apple cart (world/props/apple_cart/). Now and then from spring to autumn a wheel
## breaks: the cart is swapped for the broken one with its apples spilled beside it (played out in
## front of Anon when he is near, cart_show.gd), Applejack writes Anon a letter asking for a hoof
## (a favour, world/mechanics/asks/asks.gd, reward "thanks", so the game never pays by itself) and a
## spare wheel leans on the back wall inside the barn (spare_wheel.gd). Anon picks it up, holds it up
## to the wagon (wagon_fit.gd) and it is fixed (the cart rights itself as he watches). Applejack is then told and offers to pay him from her
## own purse; her AI only pays ([pay_player]) if he accepts, so he can simply say no. While the wagon
## is broken she waits beside it (applejack_waits.gd). If Anon never comes, the favour runs out after
## FAVOUR_HOURS and the wagon is mended without him (Big Mac sees to it) once he is away.
## The wheel is the catalogue item "food:cart-wheel" (world/food/definitions.json), tagged "tool" in
## world/inventory/item_tags.json so it cannot be gifted or sold. The favour's notebook words come from
## the row "wagon_wheel" in world/mechanics/data/events.json (the town calendar skips rows without a
## season or driver).
## Created by the hub (mechanics.gd setup). Checks once a second and does nothing until the farmyard
## wagon has loaded, so fixtures and labs without the town never break anything. Saved in
## world_context.state.wagon_wheel; a world without that block has a whole wagon.
const WAITS := preload("res://world/mechanics/wagon_wheel/applejack_waits.gd")
const SPARE := preload("res://world/mechanics/wagon_wheel/spare_wheel.gd")
const CART_SHOW := preload("res://world/mechanics/wagon_wheel/cart_show.gd")
const FIT := preload("res://world/mechanics/wagon_wheel/wagon_fit.gd")
const HAND_OVER := preload("res://world/mechanics/hand_over.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const LETTER_POST := preload("res://world/letters/letter_post.gd")
const DEV := preload("res://world/dev_tools.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const SNOW := preload("res://world/seasons/snow_materials.gd")

const STATE_KEY := "wagon_wheel"   # {"rolled_day", "due_day", "last_break", "broken", "ask_id", "held", "paused"}
const CHECK := 1.0
const APPLE_CART := "res://world/props/apple_cart/apple_cart.scn"
const BROKEN_CART := "res://world/props/apple_cart/broken_apple_cart.scn"
const WHEEL_ID := "food:cart-wheel"
const APPLEJACK := "applejack"
## The favour's want: an "event:" want that only this mechanic completes (nothing in the game sends
## an "attended" fact for it).
const FAVOUR := "event:wagon_wheel"
const FAVOUR_WHY := "a wheel broke on her apple wagon and she needs help putting on the spare"
## How long the favour stays in the notebook (game hours).
const FAVOUR_HOURS := 48.0
## What she offers when it is done, at most (less if her purse is lighter).
const OFFER_BITS := 15

## The wagon that breaks, by its scenery id, found under the town's RNLScenery node.
const WAGON := "appleacres_wagon_01"
const SCENERY := "RNLScenery"
## When it can break: these seasons, on a day that rolls under BREAK_CHANCE, at least COOLDOWN_DAYS
## after the last time, from BREAK_HOUR in the morning.
const SEASONS := ["spring", "summer", "autumn"]
const BREAK_CHANCE := 0.12
const COOLDOWN_DAYS := 6
const BREAK_HOUR := 7.0

## The wagon is moved here from its scenery spot (keeping its own facing and collision). y is only a
## hint: the wagon is set on the terrain's own height there.
const WAGON_AT := Vector3(90.0, -4.5, -440.0)
## The wagon's middle in its own frame (its collision box centre): where the wheel is fitted.
const WAGON_MIDDLE := Vector3(-0.73, 0.65, 0.0)

## The spare wheel leans on the back wall inside the Sweet Apple Acres barn ("appleacres_barned_01"),
## facing the doors. y is a hint: the barn floor is at about -7.38.
const SPARE_AT := Vector3(3.95, -7.38, -443.74)
const SPARE_YAW := 1.362       # the barn's own yaw: wheel face parallel to the back wall
const SPARE_LEAN := -0.15      # top leaning back onto the wall

## The cart only changes (broken <-> mended) while Anon is this far away, so it never pops in front
## of him; his own fix is the exception.
const SWAP_DISTANCE := 25.0
## A break starting while Anon is outdoors this near the wagon plays out in front of him
## (cart_show.gd) instead of waiting for him to leave.
const BREAK_WATCH := 60.0
const SHOW_DISTANCE := 160.0
const FADE_MARGIN := 4.0

## Applejack's letter when the wheel breaks, what the post's note is about, and what she remembers.
const LETTER_TEXT := "Dear Anon,\nA wheel done busted on my apple wagon right here in the Sweet Apple Acres farmyard. Could you lend a hoof?\nMuch obliged,\nApplejack"
const LETTER_GIST := "help fitting a new wheel on her apple wagon"
const LETTER_MEMORY := "You sent Anon a note asking for help putting the spare wheel on your apple wagon."

var hub: Node   # mechanics.gd
## Tests: {"day": int, "hours": float} instead of TimeOfDay, a season name instead of the town
## calendar's, and a fixed roll (0..1) instead of randf().
var clock_override: Dictionary = {}
var season_override := ""
var roll_override: Variant = null
var waits: WAITS
var picture: CART_SHOW
## Tests: how often each sound cue (and "dust") was started, counted at the call.
var cue_counts: Dictionary = {}
var _timer: Timer
var _wagon: Node3D          # the scenery wagon (kept for its collision; its own meshes hidden)
var _originals: Array = []  # the wagon's own meshes, hidden while the cart models draw it
var _cart: Node3D
var _broken_cart: Node3D
var _fit: FIT               # at the wagon's middle
var _spare: SPARE           # in the barn
var _showing_broken := false
var _snapped := false
var _resync := false        # after another world or checkpoint: show the saved state at once
var _watched_context: Node

func _ready() -> void:
	name = "WagonWheel"
	waits = WAITS.new(self)
	picture = CART_SHOW.new(self)
	_timer = Timer.new(); _timer.name = "WagonWheelCheck"; _timer.wait_time = CHECK; _timer.autostart = true
	_timer.timeout.connect(tick)
	add_child(_timer)

# --- Game lookups ---------------------------------------------------------------------------------

func game() -> Node:
	var found: Variant = hub.get("game") if is_instance_valid(hub) else null
	return found as Node if is_instance_valid(found) else null

func context() -> Node:
	var host := game()
	var found: Variant = host.get("world_context") if host != null else null
	return found as Node if is_instance_valid(found) else null

## The briefcase inventory (world/inventory/briefcase_inventory.gd), or null.
func ui() -> Node:
	var host := game()
	var found: Variant = host.get("inventory") if host != null else null
	return found as Node if is_instance_valid(found) else null

func _asks() -> Node:
	var found: Variant = hub.get("asks") if is_instance_valid(hub) else null
	return found as Node if is_instance_valid(found) else null

# --- Saved state ----------------------------------------------------------------------------------

## The saved block ({} without a world context). Worlds from before 0.3.2 kept it in
## state.mods.wagon_wheel (same fields); it is moved here the first time it is read.
func state() -> Dictionary:
	var world := context()
	if world == null or not world.get("state") is Dictionary: return {}
	var all: Dictionary = world.state
	if not all.get(STATE_KEY) is Dictionary:
		var mods: Variant = all.get("mods")
		var old: Variant = (mods as Dictionary).get(STATE_KEY) if mods is Dictionary else null
		all[STATE_KEY] = (old as Dictionary).duplicate(true) if old is Dictionary else {}
		if old is Dictionary:
			(mods as Dictionary).erase(STATE_KEY)
			save()
	return all[STATE_KEY]

## Marks the world save dirty (written with the next autosave).
func save() -> void:
	var world := context()
	if world != null: world._changed()

func broken() -> bool:
	return state().get("broken", false) == true

static func _int(value: Variant, fallback: int) -> int:
	return int(value) if (value is int or value is float) and is_finite(float(value)) else fallback

func _clock() -> Dictionary:
	if not clock_override.is_empty():
		return {"day": _int(clock_override.get("day"), 0), "hours": float(clock_override.get("hours", 0.0))}
	return FACTS.clock()

func _season() -> String:
	if not season_override.is_empty(): return season_override
	var calendar: Variant = hub.get("calendar") if is_instance_valid(hub) else null
	if is_instance_valid(calendar) and (calendar as Node).has_method("season_name"): return str((calendar as Node).season_name())
	return ""

func _roll() -> float:
	return float(roll_override) if roll_override is float or roll_override is int else randf()

# --- The once-a-second check ----------------------------------------------------------------------

## Finds the wagon (the town may load later), rolls the day, keeps the favour, the carts, the spare
## and Applejack in step.
func tick() -> void:
	if not is_inside_tree() or context() == null: return
	_watch_context()
	if not is_instance_valid(_wagon) or not _wagon.is_inside_tree():
		_forget_wagon()
		if not _find_wagon(): return
	_snap_wagon()
	_hide_originals()
	_roll_day()
	_start_if_due()
	_check_favour()
	_update_cart(_resync)
	_resync = false
	_update_spare()
	waits.keep()
	_watch_hands()

func _watch_context() -> void:
	var world := context()
	if world == _watched_context or not world.has_signal("reopened"): return
	_watched_context = world
	world.reopened.connect(_on_reopened)

## Another world or a checkpoint: the carts show the loaded state at once, Applejack's thank-you
## window from before is over.
func _on_reopened(_world: String) -> void:
	_resync = true
	picture.finish()
	waits.reset()

# --- The wagon ------------------------------------------------------------------------------------

func _find_wagon() -> bool:
	for town: Node in get_tree().get_nodes_in_group("town_roots"):
		var scenery: Node = town.get_node_or_null(SCENERY)
		var found: Node = scenery.find_child(WAGON, true, false) if scenery != null else null
		if found is Node3D:
			_take_wagon(found as Node3D)
			return true
	return false

## Moves the scenery wagon to WAGON_AT, hides its own meshes and puts both carts and the fitting
## point under it, so they move with it.
func _take_wagon(wagon: Node3D) -> void:
	_wagon = wagon
	_originals.clear()
	for mesh: Node in wagon.find_children("*", "GeometryInstance3D", true, false): _originals.append(mesh)
	_wagon.global_position = WAGON_AT
	_snapped = false
	_cart = _place_model(APPLE_CART, "AppleCart")
	_broken_cart = _place_model(BROKEN_CART, "BrokenAppleCart")
	_fit = FIT.new()
	_fit.wheel = self
	_wagon.add_child(_fit)
	_fit.position = WAGON_MIDDLE
	for cart: Variant in [_cart, _broken_cart]:
		if is_instance_valid(cart): SNOW.adopt(cart)   # snow and rain wetness, in season
	picture.bind(_wagon, _cart, _broken_cart)
	_showing_broken = broken()
	_update_cart(true)
	_snap_wagon()
	print("[wagon_wheel] found ", _wagon.get_path())

## The wagon left the tree or was freed: what was put under it goes (a wagon that comes back gets
## fresh carts), any moment playing stops.
func _forget_wagon() -> void:
	picture.clear()
	for node: Variant in [_cart, _broken_cart, _fit]:
		if not is_instance_valid(node): continue
		if is_instance_valid(_wagon) and (node as Node).get_parent() == _wagon: _wagon.remove_child(node)
		(node as Node).queue_free()
	_wagon = null
	_originals.clear()
	_cart = null; _broken_cart = null; _fit = null
	if is_instance_valid(_spare): _spare.queue_free()
	_spare = null
	_showing_broken = false

## Sets the wagon on the terrain at WAGON_AT, using the terrain's own height (no ray: it cannot hit
## the wagon itself, and it works before that part of the world has its collision). The terrain may
## not answer while the world is still loading; then this is tried again every second.
func _snap_wagon() -> void:
	if _snapped or not is_instance_valid(_wagon): return
	var height: float = WorldTerrain.instance.height_at(WAGON_AT) if is_instance_valid(WorldTerrain.instance) else NAN
	if not is_finite(height): return
	_wagon.global_position = Vector3(WAGON_AT.x, height, WAGON_AT.z)
	_snapped = true

func _place_model(path: String, node_name: String) -> Node3D:
	var scene := load(path) as PackedScene
	if scene == null:
		push_warning("[wagon_wheel] missing model " + path)
		return null
	var node: Node3D = scene.instantiate()
	node.name = node_name
	far_fade(node, SHOW_DISTANCE)
	_wagon.add_child(node)
	return node

## The wagon's own meshes stay hidden (re-checked every second, in case a zone filter shows them).
func _hide_originals() -> void:
	for mesh: Variant in _originals:
		if is_instance_valid(mesh) and (mesh as Node3D).visible: (mesh as Node3D).visible = false

## Shows the cart that matches the state (the broken one with its spilled apples). A change waits
## until Anon is away, unless `now`; a break or mend playing out is left to finish.
func _update_cart(now: bool) -> void:
	var want := broken()
	if not picture.busy():
		if want != _showing_broken and (now or _player_away()): _showing_broken = want
		picture.rest(_showing_broken, str(state().get("ask_id", "")))
	if is_instance_valid(_fit): _fit.visible = _showing_broken and want

## Anon is outdoors within BREAK_WATCH of the wagon in the tree: he would see a break.
func _watching() -> bool:
	if not is_instance_valid(_wagon) or not _wagon.is_inside_tree(): return false
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if camera == null or camera.global_position.distance_to(middle()) > BREAK_WATCH: return false
	return not _indoors(camera.global_position - Vector3.UP * 1.2)

## Inside a house (world/buildings/house_interior.gd contains, group "house_interiors"), asked only
## at a break; looked up through the group so this script does not load the interiors.
func _indoors(point: Vector3) -> bool:
	for home: Node in get_tree().get_nodes_in_group("house_interiors"):
		if home.has_method("contains") and bool(home.contains(point)): return true
	return false

## The wagon just broke: played out in front of Anon when he is near, else the broken cart shows
## once he is away (or at once, `at_once`, for the developer break).
func _show_break(at_once: bool) -> void:
	if _watching():
		_showing_broken = true
		picture.play_break(str(state().get("ask_id", "")))
		if is_instance_valid(_fit): _fit.visible = true
		waits.say_break()
	elif at_once:
		_update_cart(true)

## Plays a sound cue at `at` (and counts it for tests); `sound` false only counts.
func cue(name: String, at: Vector3, sound := true) -> void:
	cue_counts[name] = int(cue_counts.get(name, 0)) + 1
	if sound and is_instance_valid(_wagon) and _wagon.is_inside_tree(): SOUNDS.play_at(_wagon, name, at)

func middle() -> Vector3:
	return _wagon.global_transform * WAGON_MIDDLE if is_instance_valid(_wagon) else Vector3.INF

func broken_cart() -> Node3D:
	return _broken_cart if is_instance_valid(_broken_cart) else null

## The wheel can go on now: the wagon is broken and Anon sees the broken cart.
func can_fit() -> bool:
	return broken() and _showing_broken and is_instance_valid(_wagon)

func _player_away() -> bool:
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	return camera == null or not is_instance_valid(_wagon) or camera.global_position.distance_to(_wagon.global_position) > SWAP_DISTANCE

# --- The day's roll and the favour ----------------------------------------------------------------

## Once a day, from BREAK_HOUR: does the wheel break today?
func _roll_day() -> void:
	var saved := state()
	var clock := _clock()
	var today := _int(clock.get("day"), 0)
	if _int(saved.get("rolled_day"), -1) == today or float(clock.get("hours", 0.0)) < BREAK_HOUR: return
	saved["rolled_day"] = today
	var since := today - _int(saved.get("last_break"), -1000)
	if not broken() and _season() in SEASONS and since >= COOLDOWN_DAYS and _roll() < BREAK_CHANCE:
		saved["due_day"] = today
		print("[wagon_wheel] a wheel breaks today (day %d)" % today)
	save()

## Breaks the wagon once Applejack's favour is in the notebook. She may already have another favour
## open; then it waits, but only for today.
func _start_if_due() -> void:
	var saved := state()
	if not saved.has("due_day"): return
	if _int(saved.get("due_day"), -1) != _int(_clock().get("day"), 0):
		saved.erase("due_day")
		save()
		return
	if broken(): return
	var asks := _asks()
	if asks == null: return
	var made := _ask_applejack(asks)
	if made.get("ok", false) != true: return
	_break(str(made.get("id", "")))
	_show_break(false)

## Applejack's favour (source "letter": the game then sends no note of its own) and her letter
## asking for help. Returns asks.create's {ok, id, error}.
func _ask_applejack(asks: Node) -> Dictionary:
	var made: Dictionary = asks.create(APPLEJACK, FAVOUR, "thanks", FAVOUR_WHY, "letter", FAVOUR_HOURS)
	if made.get("ok", false) == true: _send_letter()
	return made

## Her note goes into the post due now: Derpy brings it to Anon (world/letters/letter_post.gd).
func _send_letter() -> void:
	var post := LETTER_POST.find(get_tree())
	if post == null:
		push_warning("[wagon_wheel] no letter post; Applejack's letter was not sent")
		return
	var id := str(post.pony_sends(APPLEJACK, LETTER_TEXT, LETTER_GIST, LETTER_MEMORY))
	if not id.is_empty(): print("[wagon_wheel] Applejack sent Anon a letter (%s)" % id)

func _break(ask_id: String) -> void:
	var saved := state()
	saved.erase("due_day")
	saved["broken"] = true
	saved["ask_id"] = ask_id
	saved["last_break"] = _int(_clock().get("day"), 0)
	save()
	print("[wagon_wheel] the wagon is broken; favour ", ask_id)

## The favour gone from the notebook without Anon fixing it (expired, cancelled): the wagon is
## mended without him.
func _check_favour() -> void:
	if not broken(): return
	var asks := _asks()
	if asks == null: return
	var id := str(state().get("ask_id", ""))
	for row: Dictionary in asks.open_rows():
		if str(row.get("id", "")) == id: return
	_mend()
	print("[wagon_wheel] the favour closed without Anon; the wagon is mended")

func _mend() -> void:
	var saved := state()
	saved["broken"] = false
	saved.erase("ask_id")
	save()

static func is_wheel(id: String) -> bool:
	return not id.is_empty() and ITEM_CATALOG.canonical(id) == WHEEL_ID

## Anon fitted the wheel he holds in `side`: it leaves his hand and briefcase, the favour is done
## (for her thanks, no automatic payment), the cart is whole at once, and Applejack hears it and
## offers to pay him. False (nothing changed) when he holds no wheel or the wagon is not broken.
func fit(side: String) -> bool:
	var inventory := ui()
	if not can_fit() or inventory == null or not is_wheel(HELD.id(inventory, side)): return false
	if not HELD.use_up(inventory, side): return false
	var asks := _asks()
	var id := str(state().get("ask_id", ""))
	_mend()
	_showing_broken = false
	if is_instance_valid(_fit): _fit.visible = false
	picture.play_mend()
	waits.thank()
	waits.say_fit(id)
	if asks != null and not id.is_empty():
		asks.close_done(id, "Anon fitted the new wheel.")
		var world := context()
		var impressions: Variant = world.get("impressions") if world != null else null
		if is_instance_valid(impressions): impressions.commit(APPLEJACK, {"friendship": 2}, "ask:" + id)
		var facts: Variant = hub.get("facts")
		if is_instance_valid(facts):
			facts.add("ask_done", {"actor": "player", "target": APPLEJACK, "ref": id},
				"Anon fitted a new wheel on Applejack's apple wagon.", [APPLEJACK, "player"])
	_offer_pay()
	print("[wagon_wheel] Anon fitted the wheel")
	return true

func _offer_pay() -> void:
	var host := game()
	var director: Variant = host.get("director") if host != null else null
	if not is_instance_valid(director) or not (director as Node).has_method("told_paid"): return
	var world := context()
	var purse := LEDGER.purse(world, APPLEJACK) if world != null else OFFER_BITS
	var offer := mini(OFFER_BITS, purse)
	var note := "Anon just put the spare wheel on your apple wagon, like you asked him to."
	if offer > 0:
		note += (" Thank him and offer to pay him %d bits for his trouble. Only hand them over with [pay_player: %d]" +
			" if he accepts; if he turns the money down, respect that and do not pay him.") % [offer, offer]
	else:
		note += " Thank him warmly. Your purse is empty, so you can't pay him today."
	(director as Node).told_paid(APPLEJACK, note)

## Where Applejack waits: beside the wagon, on the side facing the barn (where Anon comes from with
## the wheel), on the ground; null without a wagon.
func wait_spot() -> Variant:
	if not is_instance_valid(_wagon): return null
	var near := _wagon.global_transform * Vector3(WAGON_MIDDLE.x, 0.0, WAITS.WAIT_SIDE)
	var far := _wagon.global_transform * Vector3(WAGON_MIDDLE.x, 0.0, -WAITS.WAIT_SIDE)
	var at := near if near.distance_to(SPARE_AT) < far.distance_to(SPARE_AT) else far
	var ground: Variant = _ground(at.x, at.z, _wagon.global_position.y)
	if ground != null: at.y = float(ground)
	return at

# --- The spare wheel ------------------------------------------------------------------------------

## The spare is in the barn while the wagon is broken and Anon has no cart wheel of his own (in a
## hand, in the briefcase or dropped somewhere). Lose it, and it is back in the barn.
func _update_spare() -> void:
	if not broken():
		if is_instance_valid(_spare): _spare.queue_free()
		_spare = null
		return
	if not is_instance_valid(_spare): _place_spare()
	if is_instance_valid(_spare):
		_spare.inventory = ui()
		_spare.visible = not _owns_wheel()

func _place_spare() -> void:
	var ground: Variant = _ground(SPARE_AT.x, SPARE_AT.z, SPARE_AT.y)
	# The barn floor, not the terrain under it: wait until the barn has loaded.
	if ground == null or absf(float(ground) - SPARE_AT.y) > 0.5: return
	_spare = SPARE.new()
	_spare.wheel = self
	add_child(_spare)
	_spare.global_transform = Transform3D(Basis(Vector3.UP, SPARE_YAW) * Basis(Vector3.RIGHT, SPARE_LEAN),
		Vector3(SPARE_AT.x, float(ground), SPARE_AT.z))

## Anon has a cart wheel somewhere: in the briefcase, a hand, or dropped in the world.
func _owns_wheel() -> bool:
	var inventory := ui()
	var store: Variant = inventory.get("inventory") if inventory != null else null
	if store == null: return false
	for slot: Variant in store.get("slots"):
		if slot is Dictionary and is_wheel(str((slot as Dictionary).get("id", ""))): return true
	for loan: Variant in (store.get("loans") as Dictionary).values():
		if loan is Dictionary and is_wheel(str((loan as Dictionary).get("id", ""))): return true
	return false

## Anon takes the spare (spare_wheel.gd): into the briefcase and, when free, the hand `side`.
func take_spare(side: String) -> bool:
	var inventory := ui()
	if not is_instance_valid(_spare) or not _spare.is_visible_in_tree() or inventory == null: return false
	if HAND_OVER.give_to_anon(inventory, WHEEL_ID, side).is_empty(): return false
	_spare.visible = false
	return true

## In VR the wheel is fitted by holding it up to the wagon (wagon_fit.gd checks its hands); that
## check runs only while the broken cart shows and a hand holds a wheel.
func _watch_hands() -> void:
	var inventory := ui()
	if not is_instance_valid(_fit) or not _fit.visible or inventory == null or bool(inventory.get("_desktop")): return
	for side: String in ["left", "right"]:
		if is_wheel(HELD.id(inventory, side)):
			_fit.set_physics_process(true)
			return

# --- Helpers --------------------------------------------------------------------------------------

## The ground under `at` (x, z): what a ray finds near the wagon's height, else the terrain, else
## the wagon's own height.
func ground_height(at: Vector3) -> float:
	var near_y: float = _wagon.global_position.y if is_instance_valid(_wagon) else at.y
	var hit: Variant = _ground(at.x, at.z, near_y)
	if hit != null: return float(hit)
	var height: float = WorldTerrain.instance.height_at(at) if is_instance_valid(WorldTerrain.instance) else NAN
	return height if is_finite(height) else near_y

func _ground(x: float, z: float, near_y: float) -> Variant:
	var world := get_viewport().get_world_3d() if get_viewport() != null else null
	if world == null: return null
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, near_y + 2.5, z), Vector3(x, near_y - 30.0, z), 1)
	var hit := world.direct_space_state.intersect_ray(query)
	return null if hit.is_empty() else (hit.position as Vector3).y

static func far_fade(node: Node, distance: float) -> void:
	if node is GeometryInstance3D:
		var mesh := node as GeometryInstance3D
		mesh.visibility_range_end = distance
		mesh.visibility_range_end_margin = FADE_MARGIN
		mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for child: Node in node.get_children():
		far_fade(child, distance)

# --- Developer tools ------------------------------------------------------------------------------

## Ctrl+Shift+W breaks the wheel now, whatever the season, roll or cooldown. Only while the game's
## developer tools are on (world/dev_tools.gd: editor runs, tester builds, or Settings > Updates
## pressed five times).
func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	var key := event as InputEventKey
	if key.physical_keycode != KEY_W or not key.ctrl_pressed or not key.shift_pressed or not DEV.enabled(): return
	print("[wagon_wheel] ", debug_break())
	get_viewport().set_input_as_handled()

## Breaks the wheel now and says what happened. The broken cart shows at once, even with Anon looking.
func debug_break() -> String:
	if not is_instance_valid(_wagon): return "The wagon is not loaded yet."
	if broken(): return "The wheel is already broken."
	var asks := _asks()
	if asks == null: return "Favours are not ready yet."
	var made := _ask_applejack(asks)
	if made.get("ok", false) != true: return "Applejack could not ask: " + str(made.get("error", "?"))
	_break(str(made.get("id", "")))
	_show_break(true)
	_update_spare()
	return "The wheel broke; Applejack sent Anon a letter."
