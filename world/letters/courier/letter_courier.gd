extends Node
## Derpy's post (docs/LETTERS_PLAN_2026_10_29.md section 10). Anon holds a finished letter and holds
## use; PAPER calls collect(). The town's own Derpy comes herself when she is loaded, within 150 m
## and free; otherwise a courier Derpy appears out of sight behind and above him. She swoops to his
## hand, takes the letter, says a cheerful line and flies off toward the recipient's house
## (courier_swoop.gd). Delivery (LetterPost.delivered) is the town Derpy's landing at the door or
## 120 s, and for a courier 20 game minutes after the grab. That due time is kept in the world save
## (world_context.state.letter_courier.flights), so a reload still delivers.
##
## Replies and notes the post books with schedule_drop() go into Anon's mailbox at their due time
## (player_mailbox.gd shows and hands them over). While he has no home in the loaded world, Derpy
## swoops in the next time he is outdoors and hands the letter to him instead.
## Created by relationship_runtime.gd setup; polls like celestia_reply.gd.
const SWOOP := preload("res://world/letters/courier/courier_swoop.gd")
const MAILBOX := preload("res://world/letters/courier/player_mailbox.gd")
## M-AI-16: his letters on her doorstep and her kept copies at home (letter_props.gd).
const PROPS := preload("res://world/letters/courier/letter_props.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const STATE_KEY := "letter_courier"
const GROUP := "letter_courier"
const DERPY := "derpy_hooves"
const DERPY_SCENE := "res://world/characters/background/derpy_hooves.tscn"
const LETTER_TEXT := "res://world/letters/letter_text.gd"
const TOWN_REACH := 150.0
const SKY_RAY := 30.0
const COURIER_MINUTES := 20.0
const POLL := 1.0
## Real seconds before another hand-over swoop after one failed (briefcase full, hands busy).
const HAND_OVER_RETRY := 90.0
## Desktop hold point in the eyes' frame (harvest_pickup.gd HOLD): where a handed letter goes.
const DESKTOP_HAND := Vector3(0.19, -0.18, -0.42)
const LINES := ["Special delivery for %s? On it!", "A letter for %s! Leave it to me!",
	"Ooh, %s is gonna love this!", "Derpy Express! %s will have it in no time!", "Got it! Off to %s!"]
const GIVE_LINES := ["Mail for you!", "Special delivery! It's for you!", "You've got mail!"]
signal collected(letter_id: String)
var game: Node
var mailbox: Node
var letter_props: Node
## Test hook: Callable() -> Node3D, a fresh courier body (default: an instance of DERPY_SCENE).
var body_factory: Callable
var _sorties: Array = []
var _poll := 0.0
var _hand_over_wait := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group(GROUP)
	mailbox = MAILBOX.new()
	mailbox.name = "PlayerMailbox"
	add_child(mailbox)
	mailbox.call("setup", self)
	letter_props = PROPS.new()
	letter_props.name = "LetterProps"
	add_child(letter_props)
	letter_props.call("setup", self)
	var context := _context()
	if context != null and context.has_signal("reopened"):
		context.connect("reopened", func(_world: String) -> void: _reopened())
	_reopened()

func _reopened() -> void:
	_adopt_scheduled()
	if is_instance_valid(mailbox): mailbox.call("refresh")

## A courier on her way to Anon's hand. After the grab she flies on by herself.
func busy() -> bool:
	for sortie: Node in _sorties:
		if is_instance_valid(sortie) and not bool(sortie.get("grabbed")) and str(sortie.get("phase")) in ["approach", "hold"]: return true
	return false

## PAPER, once can_send passed: Derpy comes for the letter `item` in hand `side`. `on_taken` runs
## exactly once at the grab (PAPER removes the held item), then post.dispatched(letter_id).
func collect(letter_id: String, item: Node3D, side: String, on_taken: Callable) -> Dictionary:
	if busy(): return _no("Derpy is already on her way")
	if _state() == null: return _no("Derpy can't take letters right now")
	if letter_id.is_empty() or not is_instance_valid(item) or not item.is_inside_tree(): return _no("Hold the letter up")
	var camera := _camera()
	if camera == null: return _no("Derpy can't find you")
	if HOUSE.at(get_tree(), _player_point()) != null: return _no("Step outside to send it")
	if not open_sky(camera.global_position): return _no("Derpy needs open sky to reach you")
	var to := str(_post_row(letter_id).get("to", ""))
	var sortie: Node = SWOOP.new()
	sortie.name = "Swoop_" + letter_id
	sortie.set("kind", "send")
	sortie.set("letter_id", letter_id)
	sortie.set("courier", self)
	sortie.set("item", item)
	sortie.set("hand", func() -> Vector3: return item.global_position if is_instance_valid(item) and item.is_inside_tree() else Vector3.INF)
	sortie.set("view", _view)
	sortie.set("destination", _destination(to))
	sortie.set("line", (LINES[absi(hash(letter_id)) % LINES.size()] as String) % _name_for(letter_id, to))
	sortie.set_meta("side", side)
	sortie.set_meta("on_taken", on_taken)
	sortie.set_meta("to", to)
	if not _launch(sortie, _town_derpy(to)): return _no("Derpy can't fly right now")
	return {"ok": true, "reason": ""}

## BRAIN: her reply or note goes to Anon's mailbox at `due` (a game-day float).
func schedule_drop(letter_id: String, due: float) -> void:
	var state: Variant = _state()
	if state == null or letter_id.is_empty() or (state.mailbox as Array).has(letter_id): return
	state.drops[letter_id] = {"due": due}
	_changed()

## Ids in Anon's mailbox, oldest first (player_mailbox.gd).
func mailbox_ids() -> Array:
	var state := _peek()
	var ids: Variant = state.get("mailbox", [])
	return (ids as Array).duplicate() if ids is Array else []

func _process(delta: float) -> void:
	_poll -= delta
	_hand_over_wait = maxf(0.0, _hand_over_wait - delta)
	if _poll > 0.0: return
	_poll = POLL
	var clock := _clock()
	if clock != null: tick(int(clock.get("day")), float(clock.get("hours")))

## Delivers due flights, drops due replies in the mailbox (or hands one over), refreshes the prop.
func tick(day: int, hours: float) -> void:
	var state: Variant = _state()
	if state == null: return
	var now := float(day) + hours / 24.0
	for id: String in (state.flights as Dictionary).keys():
		var row: Variant = state.flights[id]
		if row is Dictionary and now >= float((row as Dictionary).get("due", 0.0)): _deliver(id)
	var home := player_home()
	for id: String in (state.drops as Dictionary).keys():
		var row: Variant = state.drops[id]
		if not row is Dictionary or now < float((row as Dictionary).get("due", 0.0)): continue
		# Derpy is already flying this one to his hand: it does not also go in the box.
		if _giving(id): continue
		if home != null:
			state.drops.erase(id)
			(state.mailbox as Array).append(id)
			_changed()
			var post := _post()
			if post != null: post.call("set_status", id, "in_mailbox")
		elif _hand_over_wait <= 0.0 and not busy():
			_hand_over(id)
			break
	if is_instance_valid(mailbox): mailbox.call("refresh")

## Anon's house in the loaded world (place_directory.gd's player_home rule), or null.
func player_home() -> Node3D:
	if not is_inside_tree(): return null
	for home: Node in get_tree().get_nodes_in_group("house_interiors"):
		if not home is Node3D or not home.is_inside_tree(): continue
		if str(home.get_meta("reserved_for", "")) == "player" or bool(home.get_meta("shared_player_home", false)): return home
	return null

## No roof, tree or cloud for SKY_RAY metres above `from` (static world, layer 1).
func open_sky(from: Vector3) -> bool:
	var world: World3D = get_viewport().find_world_3d() if is_inside_tree() and get_viewport() != null else null
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if space == null: return true
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.3, from + Vector3.UP * SKY_RAY, 1)
	var body: Variant = _briefcase().get("player_body") if _briefcase() != null else null
	if body is CollisionObject3D: query.exclude = [(body as CollisionObject3D).get_rid()]
	return space.intersect_ray(query).is_empty()

func _launch(sortie: Node, town: Node3D) -> bool:
	add_child(sortie)
	_sorties.append(sortie)
	if town != null and bool(sortie.call("begin_town", town)): return true
	var body := _new_body()
	var camera := _camera()
	if body == null or camera == null:
		if body != null: body.free()
		_sorties.erase(sortie); sortie.free(); return false
	var spawn: Vector3 = SWOOP.spawn_point(camera.global_transform, func(p: Vector3) -> bool: return camera.is_position_in_frustum(p))
	if bool(sortie.call("begin_courier", body, spawn)): return true
	_sorties.erase(sortie); sortie.free()
	return false

func _new_body() -> Node3D:
	if body_factory.is_valid(): return body_factory.call() as Node3D
	var scene := load(DERPY_SCENE) as PackedScene
	return scene.instantiate() as Node3D if scene != null else null

## The town Derpy when she is loaded, within TOWN_REACH, free, outdoors and the recipient has a
## door to land at; else null (a courier comes).
func _town_derpy(to: String) -> Node3D:
	var population: Variant = game.get("population") if game != null else null
	if not population is Node or not "live" in population: return null
	var entry: Variant = (population.live as Dictionary).get(DERPY)
	var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
	if not actor is Node3D or not is_instance_valid(actor) or not (actor as Node3D).is_inside_tree(): return null
	var derpy := actor as Node3D
	var camera := _camera()
	if camera == null or derpy.global_position.distance_to(camera.global_position) > TOWN_REACH: return null
	if not _destination(to).is_finite() or not _free(derpy): return null
	return derpy

## Not held, asleep, talking, flying, sitting, on a balloon, indoors or kept by a story encounter.
func _free(derpy: Node3D) -> bool:
	if bool(derpy.get("_held")) or bool(derpy.get("sleeping")) or derpy.has_meta("balloon_passenger"): return false
	for part: String in ["flight", "thrown", "posture", "hoof_hold"]:
		var motion: Variant = derpy.get(part)
		if motion is Object and (motion as Object).has_method("active") and bool((motion as Object).call("active")): return false
	var support: Variant = derpy.get("moving_support")
	if support is Node and is_instance_valid(support): return false
	var director: Variant = game.get("director")
	if director is Object and is_instance_valid(director) and (director as Object).has_method("engaged") and bool((director as Object).call("engaged", DERPY)): return false
	var nav := derpy.get_node_or_null("Navigator")
	if nav != null and not str(nav.get("reserved_by")).is_empty(): return false
	return HOUSE.at(get_tree(), derpy.global_position) == null

## Where the letter goes: the recipient's front door, else her live position, else INF.
func _destination(to: String) -> Vector3:
	var population: Variant = game.get("population") if game != null and not to.is_empty() else null
	if not population is Node: return Vector3.INF
	if population.has_method("home_house"):
		var house: Variant = population.call("home_house", to)
		if house is Node3D and is_instance_valid(house) and (house as Node).has_method("outside"): return house.call("outside")
	if "live" in population:
		var entry: Variant = (population.live as Dictionary).get(to)
		var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
		if actor is Node3D and is_instance_valid(actor): return (actor as Node3D).global_position
	return Vector3.INF

func _name_for(letter_id: String, to: String) -> String:
	if ResourceLoader.exists(LETTER_TEXT):
		var text := str(_post_row(letter_id).get("text", ""))
		var named := str((load(LETTER_TEXT) as GDScript).call("greeting_name", text)) if not text.is_empty() else ""
		if not named.is_empty(): return named
	return to.replace("_", " ").capitalize() if not to.is_empty() else "your friend"

## swoop: the grab. PAPER's on_taken first (it frees the held item), then the post is told.
func _grabbed(sortie: Node) -> void:
	var id := str(sortie.get("letter_id"))
	var on_taken: Variant = sortie.get_meta("on_taken", null)
	if on_taken is Callable and (on_taken as Callable).is_valid(): (on_taken as Callable).call()
	sortie.set_meta("on_taken", null)
	var state: Variant = _state()
	var clock := _clock()
	if state != null:
		var now := float(clock.get("day")) + float(clock.get("hours")) / 24.0 if clock != null else 0.0
		state.flights[id] = {"to": str(sortie.get_meta("to", "")), "due": now + COURIER_MINUTES / 1440.0}
		_changed()
		var context := _context()
		if context != null and context.has_method("save_soon"): context.call("save_soon")
	var post := _post()
	if post != null: post.call("dispatched", id)
	if bool(sortie.get("town")): _remember_errand(id, str(sortie.get_meta("to", "")))
	collected.emit(id)

## swoop: the town Derpy landed at the door (or 120 s passed).
func _landed(sortie: Node) -> void:
	_deliver(str(sortie.get("letter_id")))

func _deliver(id: String) -> bool:
	var state: Variant = _state()
	var post := _post()
	if state == null or post == null or not (state.flights as Dictionary).has(id): return false
	state.flights.erase(id)
	_changed()
	post.call("delivered", id)
	return true

func _sortie_done(sortie: Node) -> void:
	_sorties.erase(sortie)

## Derpy remembers the errand (her own memory; the recipient's comes from the post).
func _remember_errand(id: String, to: String) -> void:
	var context := _context()
	if context == null or not context.has_method("record") or to.is_empty(): return
	context.call("record", "courier_errand", "You flew Anon's letter to %s for him." % to.replace("_", " ").capitalize(),
		[DERPY], [DERPY, "player"], "courier:" + id)

## The reverse swoop: no home mailbox, so Derpy brings a due reply to his free hand.
func _hand_over(id: String) -> bool:
	var camera := _camera()
	var inventory := _briefcase()
	if camera == null or inventory == null: return false
	if HOUSE.at(get_tree(), _player_point()) != null or not open_sky(camera.global_position): return false
	var side := _free_side()
	if side.is_empty(): return false
	var sortie: Node = SWOOP.new()
	sortie.name = "Give_" + id
	sortie.set("kind", "give")
	sortie.set("letter_id", id)
	sortie.set("courier", self)
	sortie.set("hand", func() -> Vector3: return _hand_point(side))
	sortie.set("view", _view)
	sortie.set("line", GIVE_LINES[absi(hash(id)) % GIVE_LINES.size()])
	sortie.set_meta("side", side)
	if not _launch(sortie, null):
		_hand_over_wait = HAND_OVER_RETRY
		return false
	sortie.call("_carry_letter")
	return true

## swoop: at his hand with a reply. False keeps it for a later try.
func _handed(sortie: Node) -> bool:
	var ok := take_letter(str(sortie.get("letter_id")), str(sortie.get_meta("side", "")))
	if not ok: _hand_over_wait = HAND_OVER_RETRY
	return ok

## The take (mailbox or hand-over): into the briefcase, into a free hand, the gift, status taken.
## It leaves both the mailbox and the drops, so it can never be taken twice.
func take_letter(id: String, side: String) -> bool:
	var state: Variant = _state()
	var inventory := _briefcase()
	var store: Variant = inventory.get("inventory") if inventory != null else null
	if state == null or not store is Object: return false
	var row := _post_row(id)
	var gift := str(row.get("gift", ""))
	# The letter and her gift go in together, or both wait (a full briefcase).
	if not fits(store as Object, ["letter:" + id] + ([gift] if not gift.is_empty() and CATALOG.has(gift) else [])): return false
	if (store as Object).call("grant", "letter:" + id, 1) < 0: return false
	(state.mailbox as Array).erase(id)
	state.drops.erase(id)
	_changed()
	if not gift.is_empty() and CATALOG.has(gift): (store as Object).call("grant", gift, 1)
	var post := _post()
	if post != null: post.call("set_status", id, "taken")
	var paper := get_tree().get_first_node_in_group("letter_paper") if is_inside_tree() else null
	if paper != null and not side.is_empty() and not bool(inventory.call("hand_busy", side)):
		paper.call("put_in_hand", inventory, id, side)
	if is_instance_valid(mailbox): mailbox.call("refresh")
	return true

## Room for one of each of `ids` in the briefcase store (inventory_store.gd grant's rule: a stack
## of the same thing with room, else an empty slot).
static func fits(store: Object, ids: Array) -> bool:
	var listed: Variant = store.get("slots")
	if not listed is Array: return true   # a store without slots (a test double): grant decides
	var slots: Array = listed
	var empty := 0
	for slot: Variant in slots:
		if slot is Dictionary and (slot as Dictionary).is_empty(): empty += 1
	for id: String in ids:
		var canonical := CATALOG.canonical(id)
		var stacks := false
		for slot: Variant in slots:
			var s: Dictionary = slot if slot is Dictionary else {}
			if not s.is_empty() and not s.has("bites") and CATALOG.canonical(str(s.get("id", ""))) == canonical and int(s.get("count", 0)) + 1 <= CATALOG.stack(canonical):
				stacks = true; break
		if not stacks: empty -= 1
	return empty >= 0

## A hand-over swoop for this letter is under way.
func _giving(id: String) -> bool:
	for sortie: Node in _sorties:
		if is_instance_valid(sortie) and str(sortie.get("kind")) == "give" and str(sortie.get("letter_id")) == id and not bool(sortie.get("_ended")): return true
	return false

## Rows the post booked while no courier ran: scheduled replies become drops, in_mailbox rows join
## the mailbox (BRAIN's state.letters, read only).
func _adopt_scheduled() -> void:
	var state: Variant = _state()
	var context := _context()
	if state == null: return
	var letters: Variant = context.state.get("letters")
	var rows: Variant = (letters as Dictionary).get("rows") if letters is Dictionary else null
	if not rows is Dictionary: return
	for id: String in (rows as Dictionary).keys():
		var row: Variant = rows[id]
		if not row is Dictionary or str(row.get("to", "")) != "player" or str(row.get("from", "")) == "player": continue
		var status := str(row.get("status", ""))
		if state.flights.has(id) or state.drops.has(id) or (state.mailbox as Array).has(id): continue
		if status == "scheduled":
			state.drops[id] = {"due": float(row.get("due_at", 0.0))}
			_changed()
		elif status == "in_mailbox":
			(state.mailbox as Array).append(id)
			_changed()

func _free_side() -> String:
	var inventory := _briefcase()
	if inventory == null: return ""
	if bool(inventory.get("_desktop")): return "" if bool(inventory.call("hand_busy", "desktop")) else "desktop"
	for side: String in ["right", "left"]:
		var sample: Dictionary = inventory.call("hand_sample", side)
		if bool(sample.get("active", false)) and not bool(inventory.call("hand_busy", side)): return side
	return ""

func _hand_point(side: String) -> Vector3:
	var inventory := _briefcase()
	if inventory == null: return Vector3.INF
	if side == "desktop":
		var camera := _camera()
		return camera.global_transform * DESKTOP_HAND if camera != null else Vector3.INF
	var sample: Dictionary = inventory.call("hand_sample", side)
	if not bool(sample.get("active", false)): return Vector3.INF
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	return sample.get("grip_position", pose.origin)

func _view() -> Transform3D:
	var camera := _camera()
	return camera.global_transform if camera != null else Transform3D.IDENTITY

func _camera() -> Camera3D:
	var inventory := _briefcase()
	var camera: Variant = inventory.get("camera") if inventory != null else null
	if camera is Camera3D and is_instance_valid(camera) and (camera as Node).is_inside_tree(): return camera
	return get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null

## His feet (the player body), else his eyes.
func _player_point() -> Vector3:
	var inventory := _briefcase()
	var body: Variant = inventory.get("player_body") if inventory != null else null
	if body is Node3D and is_instance_valid(body): return (body as Node3D).global_position + Vector3.UP * 0.3
	var camera := _camera()
	return camera.global_position if camera != null else Vector3.ZERO

func _briefcase() -> Node:
	var inventory: Variant = game.get("inventory") if game != null else null
	return inventory if inventory is Node and is_instance_valid(inventory) else null

func _post() -> Node:
	return get_tree().get_first_node_in_group("letter_post") if is_inside_tree() else null

func _post_row(id: String) -> Dictionary:
	var post := _post()
	var row: Variant = post.call("row", id) if post != null else {}
	return row if row is Dictionary else {}

func _no(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}

func _context() -> Node:
	var context: Variant = game.get("world_context") if game != null else null
	return context if context is Node and is_instance_valid(context) else null

## Writable courier state (created on first use), or null while read only.
func _state() -> Variant:
	var context := _context()
	if context == null or context.get("_read_only") == true: return null
	var state: Variant = context.state.get(STATE_KEY)
	if not state is Dictionary:
		state = {}
		context.state[STATE_KEY] = state
	for key: String in ["flights", "drops"]:
		if not (state as Dictionary).get(key) is Dictionary: state[key] = {}
	if not (state as Dictionary).get("mailbox") is Array: state.mailbox = []
	return state

## Read without creating anything (a read-only world still shows its mailbox).
func _peek() -> Dictionary:
	var context := _context()
	var state: Variant = context.state.get(STATE_KEY) if context != null else null
	return state if state is Dictionary else {}

func _changed() -> void:
	var context := _context()
	if context != null and context.has_method("_changed"): context.call("_changed")

func _clock() -> Node:
	return get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
