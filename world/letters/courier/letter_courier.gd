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
## (player_mailbox.gd: his own box beside the path at his front door, which shows and hands them
## over). When one comes due while he is outdoors within WATCH_DISTANCE of that box, a courier Derpy
## flies it in, puts it through the open door and flies off (mailbox_swoop.gd); further away or
## indoors it goes in quietly, and if her flight fails it goes in quietly a second later, so mail is
## never lost. While he has no home in the loaded world, Derpy swoops in the next time he is
## outdoors and hands the letter to him instead.
##
## He may also post a finished letter in his own box (post_in_mailbox(), letter_tool.gd: click or E
## aimed at the box, or a VR grip let go at its letter spot): it waits in state outbox, can be taken
## back, and after OUTBOX_WAIT_MINUTES Derpy collects it: flying to the box while he watches
## (mailbox_swoop.gd "pickup"), otherwise quietly. Either way the letter goes on as one she took
## from his hand (_dispatched()).
## Created by relationship_runtime.gd setup; polls like celestia_reply.gd.
const SWOOP := preload("res://world/letters/courier/courier_swoop.gd")
const DROP_SWOOP := preload("res://world/letters/courier/mailbox_swoop.gd")
const MAILBOX := preload("res://world/letters/courier/player_mailbox.gd")
const DEV := preload("res://world/dev_tools.gd")
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
## Derpy flies due mail to his mailbox only while he is outdoors within this distance of it, and
## calls out one of DROP_LINES only while he is within DROP_LINE_NEAR.
const WATCH_DISTANCE := 120.0
const DROP_LINE_NEAR := 30.0
const DROP_LINES := ["Mail's here!", "Special delivery!", "You've got mail!", "Derpy Express!"]
## Flights to and from his mailbox (mailbox_swoop.gd kinds).
const MAILBOX_KINDS := ["drop", "pickup"]
## His box holds at most this many letters to send; Derpy collects one this many game minutes after
## it was posted.
const OUTBOX_LIMIT := 4
const OUTBOX_WAIT_MINUTES := 10.0
signal collected(letter_id: String)
var game: Node
var mailbox: MAILBOX
var letter_props: Node
## Test hook: Callable() -> Node3D, a fresh courier body (default: an instance of DERPY_SCENE).
var body_factory: Callable
## Test hook: 1 makes every watched drop a fumble, 0 none; -1 (the game) one in five, by letter id.
var fumble_override := -1
var _sorties: Array = []
var _poll := 0.0
var _hand_over_wait := 0.0
## Letter ids whose flight to the mailbox failed: they go in quietly (not saved; a reload delivers
## them quietly anyway).
var _unflown := {}
## The last poll's time, for _now() without a clock (tests).
var _last_now := 0.0

func setup(host: Node) -> void:
	game = host
	add_to_group(GROUP)
	mailbox = MAILBOX.new()
	mailbox.name = "PlayerMailbox"
	add_child(mailbox)
	mailbox.setup(self)
	letter_props = PROPS.new()
	letter_props.name = "LetterProps"
	add_child(letter_props)
	letter_props.call("setup", self)
	var context := _context()
	if context != null and context.has_signal("reopened"):
		context.connect("reopened", func(_world: String) -> void: _reopened())
	_reopened()

func _reopened() -> void:
	_unflown.clear()
	_adopt_scheduled()
	if is_instance_valid(mailbox):
		mailbox.refresh()
		mailbox.snap_pose()

## A courier on her way to Anon's hand. After the grab she flies on by herself. A flight to his
## mailbox does not count: another courier may come for his letter meanwhile.
func busy() -> bool:
	for sortie: Node in _sorties:
		if not is_instance_valid(sortie) or str(sortie.get("kind")) in MAILBOX_KINDS: continue
		if not bool(sortie.get("grabbed")) and str(sortie.get("phase")) in ["approach", "hold"]: return true
	return false

## PAPER, once can_send passed: Derpy comes for the letter `item` in hand `side`. `on_taken` runs
## exactly once at the grab (PAPER removes the held item), then post.dispatched(letter_id).
func collect(letter_id: String, item: Node3D, side: String, on_taken: Callable) -> Dictionary:
	if busy(): return _no("Derpy is already on her way")
	if _state() == null: return _no("Derpy can't take letters right now")
	if letter_id.is_empty() or not is_instance_valid(item) or not item.is_inside_tree(): return _no("Hold the letter up")
	var camera := _camera()
	if camera == null: return _no("Derpy can't find you")
	if HOUSE.at(get_tree(), player_point()) != null: return _no("Step outside to send it")
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

## Ids of his own letters waiting in his mailbox for Derpy, oldest first (player_mailbox.gd).
func outbox_ids() -> Array:
	var rows: Variant = _peek().get("outbox", [])
	var ids: Array = []
	if rows is Array:
		for entry: Variant in rows:
			if entry is Dictionary: ids.append(str((entry as Dictionary).get("id", "")))
	return ids

## letter_tool.gd: Anon posts his finished letter `letter_id` in his own mailbox. `on_taken` runs
## exactly once on success (it removes the held item, as for collect()); the letter waits in the box
## (state outbox) until Derpy collects it, its post row a draft until then. {ok, reason} as collect().
func post_in_mailbox(letter_id: String, on_taken: Callable) -> Dictionary:
	var post := _post()
	if post == null or _state() == null: return _no("Derpy can't take letters right now")
	var check: Variant = post.call("can_send", letter_id)
	if not check is Dictionary or not bool((check as Dictionary).get("ok", false)):
		return _no(str((check as Dictionary).get("reason", "Not ready to send")) if check is Dictionary else "Not ready to send")
	if not is_instance_valid(mailbox) or not mailbox.placed(): return _no("You have no mailbox")
	var state: Variant = _state()
	if letter_id in outbox_ids(): return _no("It's in the mailbox already")
	if (state.outbox as Array).size() >= OUTBOX_LIMIT: return _no("The mailbox is full")
	if on_taken.is_valid(): on_taken.call()
	(state.outbox as Array).append({"id": letter_id, "at": _now()})
	_changed()
	_save_soon()
	mailbox.refresh()
	mailbox.play_cue("prop_mailbox_letter")
	return {"ok": true, "reason": ""}

## His letter `id` back out of the box into the briefcase and a free hand (`side`, "" any), the same
## draft as before; false (it stays in the box) when there is no room.
func take_back(id: String, side: String) -> bool:
	var state: Variant = _state()
	var inventory := briefcase()
	var store: Variant = inventory.get("inventory") if inventory != null else null
	if state == null or not store is Object or not id in outbox_ids(): return false
	if not fits(store as Object, ["letter:" + id]): return false
	if (store as Object).call("grant", "letter:" + id, 1) < 0: return false
	_remove_outbox(id)
	_changed()
	_save_soon()
	var paper := get_tree().get_first_node_in_group("letter_paper") if is_inside_tree() else null
	if paper != null and not side.is_empty() and not bool(inventory.call("hand_busy", side)):
		paper.call("put_in_hand", inventory, id, side)
	if is_instance_valid(mailbox): mailbox.refresh()
	return true

## Drops the outbox entry for `id`; true when there was one.
func _remove_outbox(id: String) -> bool:
	var state: Variant = _state()
	if state == null: return false
	var rows: Array = state.outbox
	for index in rows.size():
		var entry: Variant = rows[index]
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == id:
			rows.remove_at(index)
			return true
	return false

func _process(delta: float) -> void:
	_poll -= delta
	_hand_over_wait = maxf(0.0, _hand_over_wait - delta)
	if _poll > 0.0: return
	_poll = POLL
	var clock := _clock()
	if clock != null: tick(int(clock.get("day")), float(clock.get("hours")))

## Delivers due flights, drops due replies in the mailbox (Derpy flies them in while he watches, or
## they go in quietly; with no home she hands one over), refreshes the mailbox.
func tick(day: int, hours: float) -> void:
	var state: Variant = _state()
	if state == null:
		# A read-only world still shows its mailbox.
		if is_instance_valid(mailbox): mailbox.refresh()
		return
	var now := float(day) + hours / 24.0
	_last_now = now
	for id: String in (state.flights as Dictionary).keys():
		var row: Variant = state.flights[id]
		if row is Dictionary and now >= float((row as Dictionary).get("due", 0.0)): _deliver(id)
	var home := player_home()
	var due: Array[String] = []
	for id: String in (state.drops as Dictionary).keys():
		var row: Variant = state.drops[id]
		if not row is Dictionary or now < float((row as Dictionary).get("due", 0.0)): continue
		# Derpy is already flying this one to his hand or his mailbox: it does not also go in the box.
		if not _flying(id): due.append(id)
	if home != null and not due.is_empty():
		for id: String in _fly_to_mailbox(due): due.erase(id)
	for id: String in due:
		if home != null:
			_into_mailbox(id)
		elif _hand_over_wait <= 0.0 and not busy():
			_hand_over(id)
			break
	_collect_outbox(now)
	if is_instance_valid(mailbox): mailbox.refresh()

## His posted letters at least OUTBOX_WAIT_MINUTES old: Derpy flies to the box for them while he
## watches (after any flight already under way, so a due drop goes first), else she collects them
## quietly; so do letters whose pickup flight failed or could not start.
func _collect_outbox(now: float) -> void:
	var state: Variant = _state()
	if state == null or (state.outbox as Array).is_empty(): return
	var due: Array[String] = []
	for entry: Variant in (state.outbox as Array).duplicate():
		if not entry is Dictionary: continue
		var id := str((entry as Dictionary).get("id", ""))
		if now >= float((entry as Dictionary).get("at", 0.0)) + OUTBOX_WAIT_MINUTES / 1440.0 and not _flying(id): due.append(id)
	if due.is_empty(): return
	var flyable: Array[String] = []
	for id: String in due:
		if not _unflown.has(id): flyable.append(id)
	if not flyable.is_empty() and _watching_mailbox():
		if _mailbox_flight() != null:
			for id: String in flyable: due.erase(id)
		elif _fly_pickup(flyable):
			for id: String in flyable: due.erase(id)
	for id: String in due: _dispatched(id, str(_post_row(id).get("to", "")), false)

## mailbox_swoop.gd, at the slot: she has his posted letters in her mouth now; the letter is shown
## gliding out of the box to `to_mouth`.
func picked_from_mailbox(sortie: Node, to_mouth: Transform3D) -> void:
	var outgoing := outbox_ids()
	for id: String in sortie.get("letter_ids"):
		if id in outgoing: _dispatched(id, str(_post_row(id).get("to", "")), false)
	if is_instance_valid(mailbox): mailbox.slide_out(to_mouth)

## A due drop goes into the mailbox state (the box shows it on its next refresh).
func _into_mailbox(id: String) -> void:
	var state: Variant = _state()
	if state == null: return
	state.drops.erase(id)
	_unflown.erase(id)
	if not (state.mailbox as Array).has(id): (state.mailbox as Array).append(id)
	_changed()
	var post := _post()
	if post != null: post.call("set_status", id, "in_mailbox")

## Derpy flies the due drops `ids` to his mailbox while he can see it: the ids she took (none when
## he is too far, indoors, a flight is already on its way, or she could not take off).
func _fly_to_mailbox(ids: Array[String]) -> Array[String]:
	var carried: Array[String] = []
	for id: String in ids:
		if not _unflown.has(id): carried.append(id)
	if carried.is_empty() or _mailbox_flight() != null or not _watching_mailbox(): return []
	var near := player_point().distance_to(mailbox.stand_point()) < DROP_LINE_NEAR
	var line: String = DROP_LINES[absi(hash(carried[0])) % DROP_LINES.size()] if near else ""
	var fumble := fumble_override == 1 or (fumble_override < 0 and absi(hash(carried[0] + "fumble")) % 5 == 0)
	return carried if _mailbox_sortie("drop", carried, line, Vector3.INF, fumble) != null else []

## Derpy collects his posted letters `ids` from the box while he watches (no other mailbox flight
## under way); false when she could not take off.
func _fly_pickup(ids: Array[String]) -> bool:
	var to := str(_post_row(ids[0]).get("to", ""))
	var near := player_point().distance_to(mailbox.stand_point()) < DROP_LINE_NEAR
	var line: String = (LINES[absi(hash(ids[0])) % LINES.size()] as String) % _name_for(ids[0], to) if near else ""
	return _mailbox_sortie("pickup", ids, line, _destination(to), false) != null

## A courier flight (mailbox_swoop.gd) of `kind` for `ids` to his mailbox, started out of his view
## and watched by the box's door; null when she could not take off. `away` is where she flies off
## to afterwards (INF: back where she came from).
func _mailbox_sortie(kind: String, ids: Array[String], line: String, away: Vector3, fumble: bool) -> Node:
	var camera := _camera()
	var body := _new_body()
	if camera == null or body == null:
		if body != null: body.free()
		return null
	var sortie: DROP_SWOOP = DROP_SWOOP.new()
	sortie.name = ("MailDrop_" if kind == "drop" else "MailPickup_") + ids[0]
	sortie.kind = kind
	sortie.letter_id = ids[0]
	sortie.letter_ids = ids
	sortie.courier = self
	sortie.view = _view
	var slot := mailbox.slot_point()
	sortie.slot = slot
	sortie.door_out = mailbox.door_out()
	sortie.ground_y = mailbox.stand_point().y
	sortie.fumble = fumble
	sortie.hand = func() -> Vector3: return slot
	sortie.line = line
	add_child(sortie)
	_sorties.append(sortie)
	if not sortie.begin_mailbox(body, DROP_SWOOP.spawn_beyond(mailbox.stand_point(), mailbox.door_out(), camera)):
		_sorties.erase(sortie)
		sortie.free()
		return null
	if away.is_finite(): sortie.destination = away
	mailbox.expect(sortie)
	return sortie

## He is outdoors within WATCH_DISTANCE of his own mailbox, which stands, and there is a camera to
## keep Derpy's arrival out of view.
func _watching_mailbox() -> bool:
	if not is_instance_valid(mailbox) or not mailbox.placed() or _camera() == null: return false
	var player := player_point()
	if not player.is_finite() or player.distance_to(mailbox.stand_point()) > WATCH_DISTANCE: return false
	return HOUSE.at(get_tree(), player) == null

## The flight to his mailbox under way, or null.
func _mailbox_flight() -> Node:
	for sortie: Node in _sorties:
		if is_instance_valid(sortie) and str(sortie.get("kind")) in MAILBOX_KINDS and not bool(sortie.get("_ended")): return sortie
	return null

## mailbox_swoop.gd: her letters are through the door. Into the mailbox as the quiet delivery puts
## them, the letter shown sliding in from `from` (her mouth).
func dropped_in_mailbox(sortie: Node, from: Transform3D) -> void:
	var state: Variant = _state()
	if state == null: return
	for id: String in sortie.get("letter_ids"):
		if (state.drops as Dictionary).has(id): _into_mailbox(id)
	if is_instance_valid(mailbox): mailbox.slide_in(from)

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
	var body: Variant = briefcase().get("player_body") if briefcase() != null else null
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
	_dispatched(id, str(sortie.get_meta("to", "")), bool(sortie.get("town")))

## The letter `id` to `to` is Derpy's now: at her grab from his hand, at her grab from his mailbox, or
## collected quietly from it. The flight row (due COURIER_MINUTES on), post.dispatched, collected, a
## save soon and, for the town Derpy, her errand. The only place a collected letter leaves the
## outbox, so a posted letter is never lost or sent twice.
func _dispatched(id: String, to: String, town: bool) -> void:
	var state: Variant = _state()
	if state != null:
		_remove_outbox(id)
		_unflown.erase(id)
		state.flights[id] = {"to": to, "due": _now() + COURIER_MINUTES / 1440.0}
		_changed()
		_save_soon()
	var post := _post()
	if post != null: post.call("dispatched", id)
	if town: _remember_errand(id, to)
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

## swoop: a flight ended. Letters a mailbox flight did not deliver or collect go quietly next poll.
func _sortie_done(sortie: Node) -> void:
	_sorties.erase(sortie)
	if str(sortie.get("kind")) in MAILBOX_KINDS and not bool(sortie.get("grabbed")):
		for id: String in sortie.get("letter_ids"): _unflown[id] = true

## Derpy remembers the errand (her own memory; the recipient's comes from the post).
func _remember_errand(id: String, to: String) -> void:
	var context := _context()
	if context == null or not context.has_method("record") or to.is_empty(): return
	context.call("record", "courier_errand", "You flew Anon's letter to %s for him." % to.replace("_", " ").capitalize(),
		[DERPY], [DERPY, "player"], "courier:" + id)

## The reverse swoop: no home mailbox, so Derpy brings a due reply to his free hand.
func _hand_over(id: String) -> bool:
	var camera := _camera()
	var inventory := briefcase()
	if camera == null or inventory == null: return false
	if HOUSE.at(get_tree(), player_point()) != null or not open_sky(camera.global_position): return false
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
	var inventory := briefcase()
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
	if is_instance_valid(mailbox): mailbox.refresh()
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

## A hand-over swoop or a flight to his mailbox is carrying this letter.
func _flying(id: String) -> bool:
	for sortie: Node in _sorties:
		if not is_instance_valid(sortie) or bool(sortie.get("_ended")): continue
		var kind := str(sortie.get("kind"))
		if kind == "give" and str(sortie.get("letter_id")) == id: return true
		if kind in MAILBOX_KINDS and not bool(sortie.get("grabbed")) and id in (sortie.get("letter_ids") as Array): return true
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
	var inventory := briefcase()
	if inventory == null: return ""
	if bool(inventory.get("_desktop")): return "" if bool(inventory.call("hand_busy", "desktop")) else "desktop"
	for side: String in ["right", "left"]:
		var sample: Dictionary = inventory.call("hand_sample", side)
		if bool(sample.get("active", false)) and not bool(inventory.call("hand_busy", side)): return side
	return ""

func _hand_point(side: String) -> Vector3:
	var inventory := briefcase()
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
	var inventory := briefcase()
	var camera: Variant = inventory.get("camera") if inventory != null else null
	if camera is Camera3D and is_instance_valid(camera) and (camera as Node).is_inside_tree(): return camera
	return get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null

## Where Anon is: just above his feet (the player body), else his eyes; ZERO when neither exists
## (player_mailbox.gd opens its door by it).
func player_point() -> Vector3:
	var inventory := briefcase()
	var body: Variant = inventory.get("player_body") if inventory != null else null
	if body is Node3D and is_instance_valid(body): return (body as Node3D).global_position + Vector3.UP * 0.3
	var camera := _camera()
	return camera.global_position if camera != null else Vector3.ZERO

## The game's briefcase (briefcase_inventory.gd: hands, camera, player body, store), or null
## (player_mailbox.gd reads its hands and camera).
func briefcase() -> Node:
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
	for key: String in ["mailbox", "outbox"]:
		if not (state as Dictionary).get(key) is Array: state[key] = []
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

## Now in game days (day + hours / 24); without a clock, the last poll's time.
func _now() -> float:
	var clock := _clock()
	return float(clock.get("day")) + float(clock.get("hours")) / 24.0 if clock != null else _last_now

## The world save within about a second (world_context.gd save_soon).
func _save_soon() -> void:
	var context := _context()
	if context != null and context.has_method("save_soon"): context.call("save_soon")

# --- Developer test letter --------------------------------------------------------------------------

## A note from Derpy, due now: she flies it to his mailbox if he is outdoors near it, else it goes in
## quietly (or to his hand with no home). Ctrl+Shift+L with the developer tools on (world/dev_tools.gd).
## What happened, for the log.
func test_letter() -> String:
	var post := _post()
	if post == null: return "No letter post in this world."
	var id: String = post.pony_sends(DERPY, "Dear Anon,\nJust testing your mailbox! Do you like it?\nDerpy", "testing his mailbox", "")
	return "Test letter " + id + " is on its way." if not id.is_empty() else "The letter could not be written."

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_L or not key.ctrl_pressed or not key.shift_pressed: return
	if not DEV.enabled(): return
	print("[letters] ", test_letter())
	get_viewport().set_input_as_handled()
