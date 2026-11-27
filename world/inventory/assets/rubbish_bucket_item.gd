extends Node3D
## Anon's rubbish bucket ("rubbish-bucket", world/inventory/item_catalog.gd): the base game's way to
## get rid of things for good (thread 2026-11-13/16, posts 43708257 and 43710314; players used a
## third-party discard pack; docs/THREAD_FIX_SAVES_2026_11_19.md). Every world gets one, once, in
## the briefcase (grant_once, called by world/game_saves.gd). Set it down anywhere; at home it stands
## where it is placed, like furniture (world/housing/furnishing_rules.gd). An owned thing that is let
## go of or thrown so it lands in its mouth is thrown away through the briefcase's own transaction
## (inventory_store.gd consume), so the save never keeps a record of it.
## Safe for placed and checked-out things: only a loose body that is moving or has come to rest
## after a drop is taken, never one in a hand, frozen in place, placed at home, laid out, standing
## open or in a pot. What is refused (books, letters, the notebook, the photo journal, the bucket,
## tools the game hands out, wardrobe clothes) and the whole-stack rule live in
## world/inventory/rubbish_rules.gd, shared with the fixed bins (world/props/rubbish_bin.gd). The model is the existing fishing
## bucket (world/props/household/fishing-bucket.scn); no new geometry.
const MODEL := "res://world/props/household/fishing-bucket.scn"
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const RULES := preload("res://world/inventory/rubbish_rules.gd")
const ITEM_ID := "rubbish-bucket"
const ITEM_LAYER := 1 << 17
## The model's measured size (tools/saves/measure_bin_models.gd): 0.36 x 0.48 x 0.35 m.
const SIZE := Vector3(0.36, 0.48, 0.35)
## Rollback switch: false makes it an ordinary bucket (nothing is thrown away) and stops the grant.
const ENABLED := true
## world_context.state key: {"given": true} once this world's bucket was handed over.
const STATE_KEY := "rubbish_bucket"
const MESSAGE_SECONDS := 4.0
const KEEP := ["photo-journal", ITEM_ID]

var _inside: Array[RigidBody3D] = []

func _ready() -> void:
	var packed := load(MODEL) as PackedScene
	if packed != null: add_child(packed.instantiate())
	# Only as a briefcase item (a RigidBody3D owned by briefcase_inventory.gd), not in an icon render.
	if not ENABLED or not get_parent() is RigidBody3D: return
	var mouth := Area3D.new()
	mouth.name = "RubbishMouth"
	mouth.collision_layer = 0
	mouth.collision_mask = ITEM_LAYER
	mouth.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# From just under the rim to a hand's width above it: what lands in or on the bucket.
	box.size = Vector3(SIZE.x * 0.9, 0.3, SIZE.z * 0.9)
	shape.shape = box
	shape.position = Vector3(0, SIZE.y + 0.1, 0)
	mouth.add_child(shape)
	add_child(mouth)
	mouth.body_entered.connect(_entered)
	mouth.body_exited.connect(_exited)
	set_physics_process(false)

func configure_body(body: RigidBody3D, collision: CollisionShape3D) -> void:
	var shape := BoxShape3D.new(); shape.size = SIZE; collision.shape = shape
	collision.position = Vector3(0, SIZE.y * 0.5, 0)
	body.mass = 0.8

func _entered(body: Node3D) -> void:
	if body is RigidBody3D and body != get_parent() and body.has_meta("token") and not _inside.has(body):
		_inside.append(body)
		# Held over the mouth: the stack it came from goes in with it (world/inventory/rubbish_rules.gd).
		RULES.remember(body)
		set_physics_process(true)

func _exited(body: Node3D) -> void:
	_inside.erase(body)
	RULES.forget(body)
	if _inside.is_empty(): set_physics_process(false)

## Runs only while something is in the bucket's mouth (a dropped thing is taken on the next tick;
## one held over it waits until it is let go).
func _physics_process(_delta: float) -> void:
	for body: RigidBody3D in _inside.duplicate():
		_try(body)
	if _inside.is_empty(): set_physics_process(false)

func _bag() -> Node:
	var bucket := get_parent()
	var bag: Node = bucket.get_parent() if bucket != null else null
	if bag == null or not "inventory" in bag or not "loose" in bag or not "held" in bag: return null
	return bag

func _try(body: RigidBody3D) -> void:
	if not is_instance_valid(body):
		_inside.erase(body); return
	var bag := _bag()
	if bag == null: return
	var held: Array = (bag.get("held") as Dictionary).values()
	# The bucket in a hand is not a bin yet; a thing in a hand is not let go yet.
	if get_parent() in held or body in held: return
	var loose: Dictionary = bag.get("loose")
	var store: Object = bag.get("inventory")
	var token := str(body.get_meta("token", ""))
	if store == null or loose.get(token) != body or not (store.get("loans") as Dictionary).has(token):
		_inside.erase(body); return
	# Resting where it was restored or placed: not thrown in.
	if body.freeze: return
	var loan: Dictionary = (store.get("loans") as Dictionary)[token]
	for key: String in ["furnishing_home", "picnic_deployed", "easel_open", "cooking"]:
		if loan.has(key):
			_inside.erase(body); return
	# The shared rules refuse what is kept, else throw it (and the rest of its stack) away, with the
	# sound and the hotbar line (world/inventory/rubbish_rules.gd).
	_inside.erase(body)
	RULES.throw_away(bag, body, global_position, self)

## "" when `id` may be thrown away, else the hotbar line that says why not (world/inventory/rubbish_rules.gd).
static func refusal_text(id: String) -> String:
	return RULES.refusal(id)

static func _shown_name(id: String) -> String:
	var shown := str(CATALOG.definition(id).get("name", ""))
	return shown if not shown.is_empty() else id

static func _say(bag: Node, text: String) -> void:
	var bar: Variant = bag.get("hotbar")
	if not bar is Node or not is_instance_valid(bar) or not (bar as Node).has_method("set_message"): return
	(bar as Node).call("set_message", text, false, MESSAGE_SECONDS)

## True when this world already had its bucket (or got it now); false to try again later (no world
## yet, loading, title, a full briefcase).
static func grant_once(game: Node) -> bool:
	if not ENABLED: return true
	if not is_instance_valid(game): return false
	var context: Variant = game.get("world_context")
	var bag: Variant = game.get("inventory")
	if not context is Node or not is_instance_valid(context) or not bag is Node or not is_instance_valid(bag): return false
	if bool((context as Node).get("_read_only")) or str((context as Node).get("world_id")).is_empty(): return false
	if bool((bag as Node).get("hud_hidden")) or game.has_node("LoadingCover") or game.get("title_active") == true: return false
	var state: Variant = (context as Node).get("state")
	if not state is Dictionary: return false
	var flags: Dictionary = (state as Dictionary).get(STATE_KEY) as Dictionary if (state as Dictionary).get(STATE_KEY) is Dictionary else {}
	if bool(flags.get("given", false)): return true
	var store: Variant = (bag as Node).get("inventory")
	if not store is Object or not bool((store as Object).get("writable")): return false
	if not owns(store):
		if int((store as Object).call("grant", ITEM_ID, 1)) < 0: return false
		_say(bag, "A rubbish bucket is in your briefcase: set it down, then drop or throw things into it to throw them away.")
		print("[inventory] the rubbish bucket is in the briefcase")
	flags["given"] = true
	state[STATE_KEY] = flags
	if (context as Node).has_method("_changed"): (context as Node).call("_changed")
	return true

static func owns(store: Object) -> bool:
	for slot: Variant in store.get("slots"):
		if slot is Dictionary and str((slot as Dictionary).get("id", "")) == ITEM_ID: return true
	for loan: Variant in (store.get("loans") as Dictionary).values():
		if loan is Dictionary and str((loan as Dictionary).get("id", "")) == ITEM_ID: return true
	return false
