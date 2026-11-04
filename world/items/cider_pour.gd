extends Node
## Fills an empty cider mug at a cider keg (world/items/cider_keg.gd): bring the mug to the keg's
## top, either one in hand. Checks four times a second, only over the player's own loose items
## (held and set-down things), so it costs nothing when no mug and keg are out.
const STORE := preload("res://world/inventory/inventory_store.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const KEG := preload("res://world/items/cider_keg.gd")
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
## A mug this close to the keg's tap fills (hands); a desktop mug floats ahead of the view.
const POUR_REACH := 0.28
const POUR_REACH_DESKTOP := 0.9
const CHECK_SECONDS := 0.25
var game: Node
var _wait := 0.0

func setup(host: Node) -> void:
	game = host
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0: return
	_wait = CHECK_SECONDS
	var inventory: Node = game.get("inventory") if is_instance_valid(game) else null
	if not is_instance_valid(inventory) or not "loose" in inventory: return
	var mugs: Array[RigidBody3D] = []
	var kegs: Array[RigidBody3D] = []
	for value: Variant in inventory.loose.values():
		if not is_instance_valid(value) or not value is RigidBody3D: continue
		var id := str((value as Node).get_meta("item_id", ""))
		if id == KEG.MUG_EMPTY: mugs.append(value)
		elif KEG.is_keg(id) and KEG.servings(id) > 0: kegs.append(value)
	if mugs.is_empty() or kegs.is_empty(): return
	var held: Array = inventory.held.values()
	for mug: RigidBody3D in mugs:
		for keg: RigidBody3D in kegs:
			# Two things left side by side never pour by themselves: one is in a hand.
			if not (held.has(mug) or held.has(keg)): continue
			var reach := POUR_REACH_DESKTOP if inventory.held.get("desktop") in [mug, keg] else POUR_REACH
			if mug.global_position.distance_to(_tap(keg)) > reach: continue
			if pour(inventory, mug, keg): return

## Where the cider comes out: the top of the keg.
static func _tap(keg: Node3D) -> Vector3:
	return keg.global_transform * Vector3(0.0, 0.22, 0.0)

## One saved transaction: the keg loses a mug's worth and the empty mug is full again.
static func pour(inventory: Node, mug: RigidBody3D, keg: RigidBody3D) -> bool:
	var store: RefCounted = inventory.inventory
	var mug_token := str(mug.get_meta("token", ""))
	var keg_token := str(keg.get_meta("token", ""))
	if not store.loans.has(mug_token) or not store.loans.has(keg_token): return false
	var keg_id := str(store.loans[keg_token].id)
	if str(store.loans[mug_token].id) != KEG.MUG_EMPTY or not KEG.is_keg(keg_id) or KEG.servings(keg_id) <= 0: return false
	var next: Array = store.slots.duplicate(true)
	var checked: Dictionary = store.loans.duplicate(true)
	for token: String in [mug_token, keg_token]:
		if checked[token].get("equipped", false):
			STORE._remove_unit(next, int(checked[token].slot))
			checked[token].erase("equipped")
	checked[mug_token].id = KEG.MUG_FULL
	checked[mug_token].erase("bites")
	checked[keg_token].id = KEG.id_for(KEG.servings(keg_id) - 1)
	if not store._commit(next, checked): return false
	mug.set_meta("item_id", KEG.MUG_FULL)
	var visual: Node3D = mug.get_meta("food_visual", null)
	if visual != null:
		visual.food_id = KEG.MUG_FULL
		visual.show_full()
		FOOD.configure(mug, visual, mug.get_child(0) as CollisionShape3D)
	keg.set_meta("item_id", checked[keg_token].id)
	inventory._refresh_holding()
	for side: String in inventory.held:
		if inventory.held[side] in [mug, keg]: inventory._haptic(side)
	SFX.play_event(mug, "prop_sip", {"pitch": 0.82, "intensity": 0.9})
	print("[cider] poured a mug; %d left in the keg" % KEG.servings(str(checked[keg_token].id)))
	# Stations adapter (world/mechanics/stations/stations.gd, row keg_pour): the "made" fact only.
	STATIONS.note(inventory, "keg_pour", "player", [KEG.MUG_FULL])
	return true
