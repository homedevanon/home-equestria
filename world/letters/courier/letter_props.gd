extends Node
## Anon's letters as things at her house (M-AI-16, NEXT_STEPS Letters Oct 29: "courier delivery
## shows nothing at her door; her own copy of the letter in her house"). Existing props only: the
## Ponyville kit letter (activity/letter.scn).
## - On her doorstep: a delivered letter (letter_post.gd delivered() sets the row's "doorstep") waits
##   in the kit mailbox nearest her door, or flat by the door, until she is home (her body within
##   TAKE_M of it or inside her house) or DOORSTEP_DAYS pass.
## - At home: she keeps his newest HOME_COPIES letters, lying on a table in her house (bedside,
##   coffee or cafe table, dresser), else on the floor beside her bed or mid-room.
## Refreshed every POLL seconds by a Timer (no per-frame work); props exist only while her house is loaded.
## Nothing here asks the AI or moves a pony.
const KIT_SPOTS := preload("res://world/props/ponyville_kit/kit_spots.gd")
const FITS := preload("res://world/props/ponyville_kit/kit_fits.gd")
const STORE := preload("res://world/letters/letter_store.gd")
const LETTER := "res://world/props/ponyville_kit/activity/letter.scn"
const POLL := 2.0
const TAKE_M := 2.5
const DOORSTEP_DAYS := 1.0
const HOME_COPIES := 2
const MAILBOX_REACH := 12.0
## Flat by her door, to the other side of the step from Anon's own (player_mailbox.gd DOOR_OFFSET).
const DOOR_OFFSET := Vector3(-0.6, 0.02, 0.0)
const TABLES := ["bedside-table", "coffee-table", "round-cafe-table", "dresser", "vanity"]
var courier: Node
## "door:<id>" / "home:<id>" -> Node3D
var _props: Dictionary = {}
var _scene: PackedScene

func setup(owner_courier: Node) -> void:
	courier = owner_courier
	var timer := Timer.new()
	timer.name = "Poll"
	timer.wait_time = POLL
	timer.autostart = true
	timer.timeout.connect(refresh)
	add_child(timer)

## Shows, moves or removes every letter prop; public for tests.
func refresh() -> void:
	var context: Node = courier.call("_context") if courier != null else null
	var rows: Dictionary = STORE.rows(context) if context != null and not bool(context.get("_read_only")) else _peek(context)
	var want := {}
	var homes := {}   # pony -> [rows newest first]
	var now := _now()
	for id: String in rows:
		var r: Dictionary = rows[id]
		if str(r.get("kind", "")) != "letter" or str(r.get("from", "")) != "player" or str(r.get("status", "")) not in ["delivered", "read"]: continue
		var pony := str(r.get("to", ""))
		if pony.is_empty(): continue
		var house := _house(pony)
		if bool(r.get("doorstep", false)):
			if _taken_in(pony, house, now - float(r.get("delivered_at", now))):
				if context != null: STORE.update(context, id, {"doorstep": false})
			elif house != null:
				var at: Variant = doorstep_transform(house)
				if at is Transform3D: want["door:" + id] = at
				continue
			else: continue
		if house == null: continue
		var list: Array = homes.get(pony, [])
		list.append(r)
		homes[pony] = list
	for pony: String in homes:
		var list: Array = homes[pony]
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("delivered_at", 0.0)) > float(b.get("delivered_at", 0.0)))
		var house := _house(pony)
		for i in mini(HOME_COPIES, list.size()):
			var at: Variant = home_transform(house, i)
			if at is Transform3D: want["home:" + str(list[i].id)] = at
	for key: String in _props.keys():
		if not want.has(key) or not is_instance_valid(_props[key]):
			if is_instance_valid(_props[key]): (_props[key] as Node).queue_free()
			_props.erase(key)
	for key: String in want:
		var spot: Transform3D = want[key]
		if _props.has(key):
			var prop: Node3D = _props[key]
			if not prop.transform.is_equal_approx(spot): prop.transform = spot
			continue
		var made := _make(key, spot)
		if made != null: _props[key] = made

## Props now, for tests: key -> Node3D.
func props() -> Dictionary:
	return _props

## Her letter is in: she is at the door or inside, or it has waited long enough.
func _taken_in(pony: String, house: Node3D, waited_days: float) -> bool:
	if waited_days > DOORSTEP_DAYS: return true
	var actor := _actor(pony)
	if actor == null or house == null: return false
	if house.has_method("contains") and bool(house.call("contains", actor.global_position)): return true
	var door: Vector3 = house.call("outside") if house.has_method("outside") else house.global_position
	return Vector2(actor.global_position.x - door.x, actor.global_position.z - door.z).length() < TAKE_M

## In the kit mailbox nearest her door (activity/fit.json letter_rest), else flat by the door.
func doorstep_transform(house: Node3D) -> Variant:
	var door: Vector3 = house.call("outside") if house.has_method("outside") else house.global_position
	if not door.is_finite(): return null
	KIT_SPOTS._index()
	var best := ""
	var gap := MAILBOX_REACH * MAILBOX_REACH
	for id: String in KIT_SPOTS._by_kind.get("mailbox", []):
		var row: Dictionary = KIT_SPOTS._by_id[id]
		var distance := Vector2(float(row.x) - door.x, float(row.z) - door.z).length_squared()
		if distance < gap: gap = distance; best = id
	var fit := FITS.get_kind("mailbox")
	if not best.is_empty() and not fit.is_empty():
		var spot: Dictionary = KIT_SPOTS.by_id(best)
		var rest: Transform3D = (spot.transform as Transform3D) * FITS.transform(fit.get("letter_rest"))
		if rest.is_finite(): return rest
	var facing := house.global_basis.orthonormalized() if house.global_basis.is_finite() else Basis.IDENTITY
	return Transform3D(facing, door + facing * DOOR_OFFSET)

## Copy `index` (0 newest) on a table top in her house, else beside her bed, else mid-room.
func home_transform(house: Node3D, index: int) -> Variant:
	var facing := house.global_basis.orthonormalized() if house.global_basis.is_finite() else Basis.IDENTITY
	var side := facing.x * (0.09 * float(index))
	for child: Node in house.get_children():
		if not child is Node3D or not child.has_meta("furniture") or str(child.get_meta("furniture")) not in TABLES: continue
		var box := _box(child as Node3D)
		if box.size == Vector3.ZERO or not box.position.is_finite(): continue
		var top := box.get_center()
		top.y = box.end.y + 0.005
		return Transform3D(facing.rotated(Vector3.UP, 0.3 * float(index)), top + side)
	var floor_at := Vector3.INF
	if house.has_method("bed_side"): floor_at = house.call("bed_side")
	if not floor_at.is_finite() and house.has_method("center"): floor_at = house.call("center")
	if not floor_at.is_finite(): return null
	return Transform3D(facing, floor_at + Vector3.UP * 0.01 + side)

static func _box(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mesh: Node in node.find_children("*", "MeshInstance3D", true, false):
		var instance := mesh as MeshInstance3D
		if instance.mesh == null: continue
		var box: AABB = instance.global_transform * instance.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out

func _make(key: String, spot: Transform3D) -> Node3D:
	if _scene == null: _scene = load(LETTER) as PackedScene
	if _scene == null: return null
	var prop := _scene.instantiate() as Node3D
	if prop == null: return null
	prop.name = "Letter_" + key.replace(":", "_")
	prop.transform = spot
	prop.set_meta("letter_id", key.get_slice(":", 1))
	add_child(prop)
	return prop

func _house(pony: String) -> Node3D:
	var game: Node = courier.get("game") if courier != null else null
	var population: Variant = game.get("population") if game != null else null
	if not population is Node or not (population as Node).has_method("home_house"): return null
	var house: Variant = population.call("home_house", pony)
	return house if house is Node3D and is_instance_valid(house) and (house as Node3D).is_inside_tree() else null

func _actor(pony: String) -> Node3D:
	var game: Node = courier.get("game") if courier != null else null
	var population: Variant = game.get("population") if game != null else null
	if not population is Node or not "live" in population: return null
	var entry: Variant = (population.live as Dictionary).get(pony)
	var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
	return actor if actor is Node3D and is_instance_valid(actor) and (actor as Node3D).is_inside_tree() else null

func _now() -> float:
	var clock: Node = get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	if courier != null and courier.has_method("_clock") and courier.call("_clock") != null: clock = courier.call("_clock")
	return float(clock.get("day")) + float(clock.get("hours")) / 24.0 if clock != null else 0.0

## A read-only world still shows its letters (no rows are created).
static func _peek(context: Node) -> Dictionary:
	var state: Variant = context.get("state") if context != null else null
	var store: Variant = (state as Dictionary).get(STORE.STATE_KEY) if state is Dictionary else null
	var rows: Variant = (store as Dictionary).get("rows") if store is Dictionary else null
	return rows if rows is Dictionary else {}
