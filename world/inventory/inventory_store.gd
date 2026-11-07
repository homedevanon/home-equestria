extends RefCounted
## Stored stacks include equipped units. Equipped loans are references, not extra items.
## Loose/legacy loans own one unit outside the stack. Commit saves before changing visuals.
signal changed
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FURNISHING := preload("res://world/housing/furnishing_rules.gd")
const COOKING_STATE := preload("res://world/cooking/cooking_state.gd")
const SAVE_FILE := preload("res://world/save_file.gd")
const RETIRED := preload("res://world/items/retired_items.gd")
const SLOT_COUNT := 27
const MAX_BITS := 2_000_000_000
## Completed bites a partly eaten portion keeps (the third bite finishes it).
const MAX_BITES := 2
var slots: Array = []
var loans: Dictionary = {}
var bits: int = 0
var save_path := ""
var last_error := ""
var writable := true
var _serial := 0

func _init() -> void:
	slots.resize(SLOT_COUNT)
	slots.fill({})

func open(path: String = save_path, starter: bool = false) -> bool:
	save_path = path
	var empty_slots: Array = []
	empty_slots.resize(SLOT_COUNT)
	empty_slots.fill({})
	var decoded := {"version": 1, "slots": empty_slots, "checked_out": {}, "bits": 0}
	if path.is_empty() or (not FileAccess.file_exists(path) and not FileAccess.file_exists(path + ".previous")):
		if starter:
			empty_slots[0] = {"id": "apple", "count": 5}
			empty_slots[1] = {"id": "carrot", "count": 3}
			empty_slots[2] = {"id": "notebook", "count": 1}
	else:
		# A damaged briefcase falls back to briefcase.json.previous, else it is kept aside
		# and the case starts empty (a resumed save restores its own copy of the items).
		var loaded := SAVE_FILE.read_checked(path, 1 << 20, func(value: Variant) -> String:
			if value is Dictionary and (value.get("version") is float or value.get("version") is int) and value.version > 1:
				return SAVE_FILE.NEWER
			return "" if valid_document(value) else "invalid inventory")
		if loaded.status != "ok":
			last_error = loaded.message
			push_warning("[inventory] " + last_error)
		if loaded.status == "newer":
			# Left untouched for the newer build; no transaction may overwrite it.
			writable = false
			return false
		if loaded.doc != null: decoded = loaded.doc
	# Items held at exit go back into the case (old slot, same stack or first empty slot).
	# A failed open must not let a later payment overwrite the unread balance with zero.
	# Only an explicit reopen of a supported document may lift this write guard.
	writable = true
	if restore_document(decoded): return true
	writable = false
	return false

## Detached snapshot for game saves; callers cannot mutate live items through it.
func document() -> Dictionary:
	return {"version": 1, "slots": slots.duplicate(true), "checked_out": loans.duplicate(true), "bits": bits}

## The caller owns served-order deduplication. True means the payment was saved.
func credit_bits(amount: int) -> bool:
	if amount <= 0 or amount > MAX_BITS - bits: return false
	return _commit(slots, loans, bits + amount)

## Reward and activity receipt share one authoritative world checkpoint. The
## callback is synchronous: no input or autosave can interleave with the commit.
## A failed standalone mirror cannot undo an already durable world checkpoint.
func credit_bits_with_checkpoint(amount: int, persist: Callable) -> bool:
	if not writable or amount <= 0 or amount > MAX_BITS - bits or not persist.is_valid(): return false
	var proposed: Dictionary = document()
	proposed.bits = bits + amount
	if not valid_document(proposed) or persist.call(proposed) != true: return false
	bits = int(proposed.bits)
	last_error = ""
	if not save_path.is_empty() and SAVE_FILE.write(ProjectSettings.globalize_path(save_path), proposed) != OK:
		last_error = "Reward saved in the world checkpoint; inventory mirror could not be written."
	changed.emit()
	return true

func debit_bits(amount: int) -> bool:
	if amount <= 0 or amount > bits: return false
	return _commit(slots, loans, bits - amount)

func restore_document(doc: Dictionary) -> bool:
	if not valid_document(doc): return false
	# Validate the original before migration; never mutate a caller's checkpoint.
	var migrated: Dictionary = doc.duplicate(true)
	# Legacy home keys no longer exist in Equestria. Validate first, then remove
	# only exact old identities in this detached transaction; all other items remain.
	for index in migrated.slots.size():
		if migrated.slots[index].get("id", "") == "house-key": migrated.slots[index] = {}
	for token: String in migrated.checked_out.keys():
		if migrated.checked_out[token].get("id", "") == "house-key": migrated.checked_out.erase(token)
	# Foods no longer kept become their pre-made replacement; overflow is refunded (2026-10-15).
	RETIRED.migrate(migrated)
	var mixed: Dictionary = {}
	var spellings: Dictionary = {}
	for slot: Dictionary in doc.slots:
		if slot.is_empty() or int(slot.count) <= 0: continue
		var id: String = CATALOG.canonical(str(slot.id))
		if spellings.has(id) and spellings[id] != slot.id: mixed[id] = true
		else: spellings[id] = slot.id
	_canonicalize(migrated.slots, migrated.checked_out)
	var recovered: Array = migrated.slots
	for i in SLOT_COUNT:
		if not recovered[i].is_empty() and int(recovered[i].count) <= 0: recovered[i] = {}
	var dropped: Dictionary = {}
	for token in migrated.checked_out:
		var loan: Dictionary = migrated.checked_out[token]
		if loan.get("equipped", false): continue # Already in the stack; never add twice.
		if loan.has("world_transform"):
			dropped[token] = loan.duplicate(true)
			continue
		# Held when the game closed: back into the case.
		var at := _place(recovered, str(loan.id), int(loan.slot), int(loan.get("bites", 0)))
		if at < 0:
			dropped[token] = loan.duplicate(true)   # no room: kept, never lost
			continue
		_add_unit(recovered, at, loan)
	# Only merge stacks that previously used different names for the same item.
	# Ordinary transactions keep slot indices stable for equipped references.
	for id: String in mixed:
		for target in SLOT_COUNT:
			if recovered[target].get("id", "") != id or recovered[target].has("bites"): continue
			for source in range(target + 1, SLOT_COUNT):
				if recovered[source].get("id", "") != id or recovered[source].has("bites"): continue
				var amount: int = mini(int(recovered[source].count), CATALOG.stack(id) - int(recovered[target].count))
				if amount <= 0: continue
				recovered[target].count += amount
				recovered[source].count -= amount
				if recovered[source].count == 0: recovered[source] = {}
	return _commit(recovered, dropped, mini(MAX_BITS, int(migrated.get("bits", 0))))

## Where an item goes: its old slot if it fits there, else a stack of the same thing with room,
## else the first empty slot. -1 when the case is full.
static func _place(where: Array, id: String, prefer: int, bites: int = 0) -> int:
	id = CATALOG.canonical(id)
	if prefer >= 0 and prefer < SLOT_COUNT:
		var s: Dictionary = where[prefer]
		if s.is_empty() or (bites == 0 and _stacks_with(s, id)): return prefer
	if bites == 0:
		for i in SLOT_COUNT:
			if _stacks_with(where[i], id): return i
	for i in SLOT_COUNT:
		if where[i].is_empty(): return i
	return -1

## A partly eaten portion keeps a slot of its own; whole items never stack onto it.
static func _stacks_with(slot: Dictionary, id: String) -> bool:
	return not slot.is_empty() and not slot.has("bites") and CATALOG.canonical(str(slot.id)) == id and int(slot.count) < CATALOG.stack(id)

static func _valid_bites(value: Variant) -> bool:
	return (value is int or value is float) and value == int(value) and int(value) >= 1 and int(value) <= MAX_BITES

## One unit of a loan back into a slot, carrying its completed bites.
static func _add_unit(next: Array, index: int, loan: Dictionary) -> void:
	if next[index].is_empty():
		next[index] = {"id": loan.id, "count": 0}
		if int(loan.get("bites", 0)) > 0: next[index].bites = int(loan.bites)
	next[index].count += 1

static func encode_pose(pose: Transform3D) -> Array:
	var result: Array = []
	for v in [pose.basis.x, pose.basis.y, pose.basis.z, pose.origin]:
		result.append_array([v.x, v.y, v.z])
	return result

static func decode_pose(values: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(values[0],values[1],values[2]),Vector3(values[3],values[4],values[5]),Vector3(values[6],values[7],values[8])),Vector3(values[9],values[10],values[11]))

static func valid_pose(value: Variant) -> bool:
	if not value is Array or value.size() != 12: return false
	for n in value:
		if not (n is int or n is float) or not is_finite(float(n)) or absf(n) > 100000: return false
	var pose := decode_pose(value)
	return pose.basis.is_equal_approx(pose.basis.orthonormalized()) and pose.basis.determinant() > .99

static func valid_picnic_heights(value: Variant) -> bool:
	if not value is Array or value.size() != 143: return false
	for height: Variant in value:
		if not (height is float or height is int) or not is_finite(float(height)) or absf(float(height)) > .5: return false
	for z in 11:
		for x in 13:
			var index: int = z * 13 + x
			if x > 0 and absf(float(value[index]) - float(value[index - 1])) > .11: return false
			if z > 0 and absf(float(value[index]) - float(value[index - 13])) > .11: return false
	return true

func set_dropped(token: String, pose: Transform3D) -> bool:
	if not loans.has(token): return false
	var checked := loans.duplicate(true)
	var next: Array = slots.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].world_transform = encode_pose(pose)
	checked[token].erase("furnishing_home")
	return _commit(next, checked)

## Placing uses the existing loose unit; equipped references leave their stack once.
func set_furnishing(token: String, pose: Transform3D, home_id: String, size: float = 1.0) -> bool:
	if not loans.has(token) or not FURNISHING.has(str(loans[token].id)): return false
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].world_transform = encode_pose(pose)
	checked[token].furnishing_home = home_id
	if size != 1.0: checked[token].furnishing_size = size
	else: checked[token].erase("furnishing_size")
	return _commit(next, checked)

## An equipped blanket becomes exactly one loose, deployed unit in this saved transaction.
func set_picnic_deployed(token: String, pose: Transform3D, heights: Array = []) -> bool:
	if not loans.has(token) or CATALOG.canonical(str(loans[token].id)) != "goods:folded-blanket": return false
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].world_transform = encode_pose(pose)
	checked[token].picnic_deployed = true
	if not heights.is_empty(): checked[token].picnic_heights = heights.duplicate()
	return _commit(next, checked)

## A held folding easel becomes one loose, standing unit in this saved transaction (world/painting/).
func set_easel_open(token: String, pose: Transform3D) -> bool:
	if not loans.has(token) or CATALOG.canonical(str(loans[token].id)) != "goods:easel": return false
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].world_transform = encode_pose(pose)
	checked[token].easel_open = true
	return _commit(next, checked)

## A held folding game board becomes one loose, open unit (world/minigames/board_games/board_fold.gd).
func set_board_open(token: String, pose: Transform3D) -> bool:
	if not loans.has(token) or CATALOG.canonical(str(loans[token].id)) != "goods:game-board": return false
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].world_transform = encode_pose(pose)
	checked[token].board_open = true
	return _commit(next, checked)

func pick_up(token: String) -> bool:
	if not loans.has(token): return false
	var checked := loans.duplicate(true)
	COOKING_STATE.detach(checked, token)
	checked[token].erase("world_transform")
	checked[token].erase("picnic_deployed")
	checked[token].erase("easel_open")
	checked[token].erase("board_open")
	checked[token].erase("picnic_heights")
	checked[token].erase("furnishing_home")
	checked[token].erase("furnishing_size")
	return _commit(slots, checked)

func update_drops(poses: Dictionary) -> bool:
	var checked := loans.duplicate(true)
	for token in poses:
		if checked.has(token) and checked[token].has("world_transform"):
			checked[token].world_transform = encode_pose(poses[token])
	if checked == loans: return true
	return _commit(slots, checked)

static func valid_document(doc: Variant) -> bool:
	if not doc is Dictionary or doc.get("version") != 1: return false
	var balance: Variant = doc.get("bits", 0)
	if not (balance is int or balance is float): return false
	if not is_finite(float(balance)) or balance < 0 or balance > MAX_BITS: return false
	if balance != int(balance): return false
	if not doc.get("slots") is Array or doc.slots.size() != SLOT_COUNT: return false
	if not doc.get("checked_out") is Dictionary: return false
	for loan in doc.checked_out.values():
		if not loan is Dictionary or not loan.get("slot") is float and not loan.get("slot") is int: return false
		if loan.has("world_transform") and not valid_pose(loan.world_transform): return false
		if loan.has("bites") and not _valid_bites(loan.bites): return false
		if not FURNISHING.valid_loan(loan): return false
		if loan.has("picnic_heights") and (not loan.get("picnic_deployed", false) or not valid_picnic_heights(loan.picnic_heights)): return false
		if loan.has("picnic_deployed") and (loan.picnic_deployed != true or not loan.picnic_deployed is bool or CATALOG.canonical(str(loan.get("id"))) != "goods:folded-blanket" or not loan.has("world_transform") or loan.get("equipped", false)): return false
		if loan.has("easel_open") and (not loan.easel_open is bool or loan.easel_open != true or CATALOG.canonical(str(loan.get("id"))) != "goods:easel" or not loan.has("world_transform") or loan.get("equipped", false)): return false
		if loan.has("board_open") and (not loan.board_open is bool or loan.board_open != true or CATALOG.canonical(str(loan.get("id"))) != "goods:game-board" or not loan.has("world_transform") or loan.get("equipped", false)): return false
		var i := int(loan.slot)
		if loan.slot != i or i < 0 or i >= SLOT_COUNT or not (CATALOG.has(str(loan.get("id"))) or loan.get("id") == "house-key"): return false
	for i in SLOT_COUNT:
		var slot = doc.slots[i]
		if not slot is Dictionary: return false
		if slot.is_empty(): continue
		if not (CATALOG.has(str(slot.get("id"))) or slot.get("id") == "house-key"): return false
		if not slot.get("count") is float and not slot.get("count") is int: return false
		var count := int(slot.count)
		if count != slot.count or count < 0 or count > CATALOG.stack(slot.id): return false
		if slot.has("bites") and (not _valid_bites(slot.bites) or count != 1): return false
	if not COOKING_STATE.valid_loans(doc.checked_out): return false
	var equipped_counts: Dictionary = {}
	for loan: Dictionary in doc.checked_out.values():
		if loan.has("equipped") and not loan.equipped is bool: return false
		if not loan.get("equipped", false): continue
		var index: int = int(loan.slot)
		var slot: Dictionary = doc.slots[index]
		if loan.has("world_transform") or CATALOG.canonical(str(slot.get("id", ""))) != CATALOG.canonical(str(loan.id)): return false
		equipped_counts[index] = int(equipped_counts.get(index, 0)) + 1
		if equipped_counts[index] > int(slot.get("count", 0)): return false
	return true

## Atomic replacement: return the previous hand item and equip the new slot in one save.
## Empty slots intentionally leave the hand empty. Other hands' references remain reserved.
func select_slot(index: int, previous: String = "") -> Dictionary:
	if index < 0 or index >= SLOT_COUNT or (not previous.is_empty() and not loans.has(previous)): return {}
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if not previous.is_empty():
		COOKING_STATE.detach(checked, previous)
		var old: Dictionary = checked[previous]
		if not old.get("equipped", false):
			var target: int = _place(next, str(old.id), int(old.slot), int(old.get("bites", 0)))
			if target < 0: return {}
			_add_unit(next, target, old)
		checked.erase(previous)
	var token: String = ""
	if not next[index].is_empty():
		var used: int = 0
		for loan: Dictionary in checked.values():
			if loan.get("equipped", false) and int(loan.slot) == index: used += 1
		if used >= int(next[index].count): return {}
		_serial += 1
		token = "%d_%d" % [Time.get_ticks_usec(), _serial]
		checked[token] = {"id": next[index].id, "slot": index, "equipped": true}
		if next[index].has("bites"): checked[token].bites = int(next[index].bites)
	if not _commit(next, checked): return {}
	return {"token": token}

func available(index: int) -> int:
	if index < 0 or index >= SLOT_COUNT: return 0
	var amount: int = int(slots[index].get("count", 0))
	for loan: Dictionary in loans.values():
		if loan.get("equipped", false) and int(loan.slot) == index: amount -= 1
	return amount

static func _remove_unit(next: Array, index: int) -> void:
	next[index].count -= 1
	if next[index].count <= 0: next[index] = {}

## Consumed food can leave a physical empty cup/bowl; convert the reference to a loose loan.
func replace_held(token: String, id: String) -> bool:
	id = CATALOG.canonical(id)
	if not loans.has(token) or not CATALOG.has(id): return false
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	COOKING_STATE.detach(checked, token)
	checked[token].id = id
	checked[token].erase("bites")
	return _commit(next, checked)

func reserved(index: int) -> int:
	var count := 0
	for loan in loans.values():
		if int(loan.slot) == index: count += 1
	return count

func take(index: int) -> String:
	if not writable or index < 0 or index >= SLOT_COUNT or slots[index].is_empty() or available(index) <= 0: return ""
	var next := slots.duplicate(true)
	var checked := loans.duplicate(true)
	_serial += 1
	var token := "%d_%d" % [Time.get_ticks_usec(), _serial]
	checked[token] = {"id": next[index].id, "slot": index}
	if next[index].has("bites"): checked[token].bites = int(next[index].bites)
	next[index].count -= 1
	if next[index].count <= 0: next[index] = {}
	return token if _commit(next, checked) else ""

func can_put(token: String, index: int) -> bool:
	if not loans.has(token) or index < 0 or index >= SLOT_COUNT: return false
	var slot: Dictionary = slots[index]
	var loan: Dictionary = loans[token]
	if loan.get("equipped", false) and int(loan.slot) == index: return true
	if slot.is_empty(): return true
	if loan.has("bites") or slot.has("bites"): return false
	return slot.id == loan.id and int(slot.count) < CATALOG.stack(loan.id)

func put(token: String, index: int = -1) -> bool:
	if not loans.has(token): return false
	if loans[token].get("equipped", false) and (index < 0 or index == int(loans[token].slot)):
		var released: Dictionary = loans.duplicate(true)
		released.erase(token)
		return _commit(slots, released)
	if index < 0: index = _place(slots, str(loans[token].id), int(loans[token].slot), int(loans[token].get("bites", 0)))
	if index < 0:
		last_error = "No room in the briefcase."
		return false
	if not can_put(token, index): return false
	var next := slots.duplicate(true)
	var checked := loans.duplicate(true)
	COOKING_STATE.detach(checked, token)
	var loan: Dictionary = checked[token]
	if loan.get("equipped", false): _remove_unit(next, int(loan.slot))
	_add_unit(next, index, loan)
	checked.erase(token)
	return _commit(next, checked)

## Adds items that come from the world (a book taken off a shelf). Fills matching stacks first,
## then the first empty slot. Returns the slot it went into, or -1 when there is no room.
func grant(id: String, count: int = 1) -> int:
	id = CATALOG.canonical(id)
	if not writable or not CATALOG.has(id) or count <= 0: return -1
	var next := slots.duplicate(true)
	var target := -1
	for i in SLOT_COUNT:
		if not next[i].is_empty() and not next[i].has("bites") and CATALOG.canonical(str(next[i].id)) == id and next[i].count + count <= CATALOG.stack(id):
			target = i; break
	if target < 0:
		for i in SLOT_COUNT:
			if next[i].is_empty(): target = i; break
	if target < 0:
		last_error = "No room in the briefcase."
		return -1
	if next[target].is_empty(): next[target] = {"id": id, "count": 0}
	next[target].count += count
	return target if _commit(next, loans) else -1

## Every briefcase unit of `id` that is not in a hand leaves the case (the spa's hoof file goes
## back to its counter, world/minigames/spa/spa_hands.gd). True when nothing was left to remove.
func discard(id: String) -> bool:
	id = CATALOG.canonical(id)
	var next: Array = slots.duplicate(true)
	var changed := false
	for i in SLOT_COUNT:
		if next[i].is_empty() or CATALOG.canonical(str(next[i].id)) != id: continue
		var keep := 0
		for loan: Dictionary in loans.values():
			if loan.get("equipped", false) and int(loan.slot) == i: keep += 1
		if int(next[i].count) <= keep: continue
		next[i].count = keep
		if keep <= 0: next[i] = {}
		changed = true
	return not changed or _commit(next, loans)

## Eaten or otherwise used up: the loan ends without returning to its slot.
func consume(token: String) -> bool:
	if not loans.has(token): return false
	var checked := loans.duplicate(true)
	var next: Array = slots.duplicate(true)
	if checked[token].get("equipped", false): _remove_unit(next, int(checked[token].slot))
	COOKING_STATE.detach(checked, token)
	checked.erase(token)
	return _commit(next, checked)

## A bitten portion becomes its own unit: it leaves an equipped stack and saves its bites,
## so stowing, dropping or reloading keeps what was already eaten.
func set_bites(token: String, bites: int) -> bool:
	if not loans.has(token) or not _valid_bites(bites): return false
	var next: Array = slots.duplicate(true)
	var checked: Dictionary = loans.duplicate(true)
	if checked[token].get("equipped", false):
		_remove_unit(next, int(checked[token].slot))
		checked[token].erase("equipped")
	checked[token].bites = bites
	return _commit(next, checked)

func move_slot(source: int, target: int) -> bool:
	if source == target or source < 0 or target < 0 or source >= SLOT_COUNT or target >= SLOT_COUNT: return false
	# Stow equipped items before rearranging their stacks.
	for loan: Dictionary in loans.values():
		if loan.get("equipped", false) and int(loan.slot) in [source, target]: return false
	var next := slots.duplicate(true)
	if next[source].is_empty(): return false
	if not next[target].is_empty() and next[source].id == next[target].id and not next[source].has("bites") and not next[target].has("bites"):
		var amount := mini(next[source].count, CATALOG.stack(next[source].id) - next[target].count)
		if amount <= 0: return false
		next[source].count -= amount
		next[target].count += amount
		if next[source].count == 0: next[source] = {}
	else:
		var old: Dictionary = next[source]
		next[source] = next[target]
		next[target] = old
	return _commit(next, loans)

func _commit(next: Array, checked: Dictionary, next_bits: int = bits) -> bool:
	if not writable: return false
	var doc := {"version": 1, "slots": next, "checked_out": checked, "bits": next_bits}
	if not valid_document(doc):
		last_error = "Invalid inventory transaction."
		return false
	# Normalize detached inputs only after validation, so failed writes leave both
	# live state and caller-owned documents unchanged. No stack rearrangement here.
	doc = doc.duplicate(true)
	_canonicalize(doc.slots, doc.checked_out)
	if not save_path.is_empty():
		var absolute := ProjectSettings.globalize_path(save_path)
		if SAVE_FILE.write(absolute, doc) != OK:
			last_error = "Inventory save failed. Items and bits unchanged."
			return false
	slots = doc.slots
	loans = doc.checked_out
	bits = next_bits
	last_error = ""
	changed.emit()
	return true

## Inputs must already have passed valid_document and belong to a detached snapshot.
static func _canonicalize(next: Array, checked: Dictionary) -> void:
	for slot: Dictionary in next:
		if not slot.is_empty(): slot.id = CATALOG.canonical(str(slot.id))
	for loan: Dictionary in checked.values():
		loan.id = CATALOG.canonical(str(loan.id))
