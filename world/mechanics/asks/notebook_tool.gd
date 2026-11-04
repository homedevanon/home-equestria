extends Node3D
## Anon's notebook in a hand (P2b, docs/MECHANICS_ARCHITECTURE_2026_11_01.md 5.3): the favours and
## invitations ponies asked of him are written on its pages (asks.gd notebook_text), so he reads
## them in the world instead of a menu. Attached to the held item on first use (on()), like
## world/letters/paper/letter_tool.gd; briefcase_inventory.gd (desktop) and briefcase_vr_hands.gd
## (VR) forward the use button here. The page is the letters' own sheet (letter_sheet.gd as the
## notebook scene's NotebookPages child): the first click opens it with the current list in front
## of the eyes (desktop) or up from the hand (VR, book_hold.gd), the next turns a long list over,
## the next closes it. The closed notebook's covers hide while it is open.
const LETTER_TOOL := preload("res://world/letters/paper/letter_tool.gd")
const BOOK_HOLD := preload("res://world/books/book_hold.gd")
const ITEM_ID := "notebook"
const EMPTY := "No favours asked yet."

var item: Node3D
var _inventory: Node
var _vr_down: Dictionary = {}

static func on(held_item: Node3D) -> Node3D:
	var tool := held_item.get_node_or_null("NotebookTool") as Node3D
	if tool != null: return tool
	tool = (load("res://world/mechanics/asks/notebook_tool.gd") as GDScript).new()
	tool.name = "NotebookTool"; tool.item = held_item
	held_item.add_child(tool)
	return tool

static func handles(held_item: Node) -> bool:
	return is_instance_valid(held_item) and str(held_item.get_meta("item_id", "")) == ITEM_ID

func _ready() -> void:
	set_process(false)

func pages() -> Node3D:
	return item.find_child("NotebookPages", true, false) as Node3D if is_instance_valid(item) else null

func is_open() -> bool:
	var sheet := pages()
	return sheet != null and bool(sheet.get("opened"))

## The use button went down or up on this hand ("desktop", "left" or "right"); a press uses it.
func press(inventory: Node, side: String, down: bool) -> void:
	_inventory = inventory
	if down: use(inventory, side)

## Open with the current list, turn a long list over, then close.
func use(inventory: Node, _side: String) -> bool:
	_inventory = inventory
	var sheet := pages()
	if sheet == null: return false
	if not sheet.opened:
		sheet.refresh(text(), "plain", false)
		sheet.open_sheet()
		_covers(false)
		_place(null)
		set_process(true)
	elif sheet.more_pages(): sheet.next_page()
	else: _close(sheet)
	return true

## The page text: the open favours from the asks module, or the empty page.
func text() -> String:
	var asks: Node = get_tree().get_first_node_in_group("mechanics_asks") if is_inside_tree() else null
	return str(asks.call("notebook_text")) if asks != null and asks.has_method("notebook_text") else EMPTY

func _close(sheet: Node3D) -> void:
	sheet.fold()
	_covers(true)

## The closed notebook's own meshes (covers, pages block, spine).
func _covers(shown: bool) -> void:
	var sheet := pages()
	var body: Node = sheet.get_parent() if sheet != null else null
	if body == null: return
	for child: Node in body.get_children():
		if child is MeshInstance3D: (child as MeshInstance3D).visible = shown

func _process(_delta: float) -> void:
	var sheet := pages()
	if sheet == null or not sheet.opened:
		set_process(false); return
	# Out of the hand (thrown, set down, stashed) an open notebook closes.
	if not _in_hand():
		_close(sheet); set_process(false); return
	if is_instance_valid(_inventory) and bool(_inventory.get("_desktop")): _place(null)

func _in_hand() -> bool:
	if not is_instance_valid(_inventory): return false
	var held: Variant = _inventory.get("held")
	return held is Dictionary and (held as Dictionary).values().has(item)

## The open page: before the eyes on desktop (the letters' reading pose), up from the hand in VR.
func _place(sample: Variant) -> void:
	var sheet := pages()
	if sheet == null or not sheet.opened or not is_instance_valid(_inventory): return
	var eye: Camera3D = _inventory.get("camera")
	if eye == null: return
	if bool(_inventory.get("_desktop")) or not sample is Dictionary:
		sheet.place(eye.global_transform * sheet.reading_pose(LETTER_TOOL.READ_DESKTOP))
	else:
		var current: Basis = sheet.sheet.global_basis if sheet.sheet != null else Basis()
		sheet.place(BOOK_HOLD.from_hand(sample, eye.global_transform, current, true))

## VR, every physics tick in hand: the trigger (the books' hysteresis) and the page's pose.
func vr_step(inventory: Node, side: String, sample: Dictionary) -> void:
	_inventory = inventory
	var was: bool = _vr_down.get(side, false)
	var down := float(sample.get("trigger", 0.0)) > (0.3 if was else 0.7)
	if down != was:
		_vr_down[side] = down
		press(inventory, side, down)
	if sample.get("active", false): _place(sample)

## The control hint for the notebook in `side`'s hand (briefcase_inventory.gd interaction_hint).
func hint(side: String) -> Dictionary:
	var click := "Click" if side == "desktop" else "Trigger"
	var sheet := pages()
	var opened := sheet != null and bool(sheet.opened)
	var action := "Read notebook" if not opened else ("Turn page" if sheet.more_pages() else "Close notebook")
	return {"target": item, "text": "%s · %s" % [click, action], "point": item.global_position + Vector3.UP * 0.12, "outline": null}
