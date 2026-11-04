extends Node3D
## The photo journal in a hand (dev 2026-11-03: "save them to a photography journal and allow me to
## open said journal, view my photos, and print them as a physical object in my inventory once for
## 1 bit each"). Every photo the camera takes lands here (world/items/photo_camera.gd). Attached to
## the held item on first use (on()), like notebook_tool.gd; its page is the letters' sheet with
## photo_journal_pages.gd in place of ink. A click opens it, turns through the photos and closes it;
## holding the click on a photo prints that photo once, as a print in the briefcase to hang, keep or
## give. Desktop: wheel brings the page closer, right click goes back (briefcase_inventory.gd).
const ITEM_ID := "photo-journal"
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const LETTER_TOOL := preload("res://world/letters/paper/letter_tool.gd")
const BOOK_HOLD := preload("res://world/books/book_hold.gd")
const PAGES := preload("res://world/items/photo_journal_pages.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const PRINT_PRICE := 1
const PRINT_HOLD_SECONDS := 1.0
const NOTICE_SECONDS := 3.0

var item: Node3D
var _inventory: Node
var _pages: Node
var _vr_down: Dictionary = {}
var _press_side := ""
var _press_time := 0.0
var _notice := ""
var _notice_until := 0.0

static func on(held_item: Node3D) -> Node3D:
	var tool := held_item.get_node_or_null("PhotoJournalTool") as Node3D
	if tool != null: return tool
	tool = (load("res://world/items/photo_journal.gd") as GDScript).new()
	tool.name = "PhotoJournalTool"; tool.item = held_item
	held_item.add_child(tool)
	return tool

static func handles(held_item: Node) -> bool:
	return is_instance_valid(held_item) and str(held_item.get_meta("item_id", "")) == ITEM_ID

func _ready() -> void:
	set_process(false)

func sheet() -> Node3D:
	return item.find_child("NotebookPages", true, false) as Node3D if is_instance_valid(item) else null

func is_open() -> bool:
	var page := sheet()
	return page != null and bool(page.get("opened"))

## The photo on the side being read, or "".
func current_photo() -> String:
	return str(_pages.call("photo", int(sheet().get("page")))) if is_open() and _pages != null else ""

## The use button went down or up. A press on a closed journal opens it; on an open one a short
## press turns the page and a long one prints (_process).
func press(inventory: Node, side: String, down: bool) -> void:
	_inventory = inventory
	if down:
		if not is_open():
			use(inventory); return
		_press_side = side; _press_time = 0.0
		return
	if _press_side != side: return
	_press_side = ""
	use(inventory)

func use(inventory: Node) -> bool:
	_inventory = inventory
	var page := sheet()
	if page == null: return false
	if not page.opened:
		if _pages == null:
			_pages = PAGES.new(); _pages.name = "Photos"
			page.use_ink(_pages)
		_pages.reload()
		page.open_sheet()
		_covers(false)
		_place(null)
		set_process(true)
	elif page.more_pages(): page.next_page()
	else: _close(page)
	return true

## One print of the page's photo, once: paid and in the briefcase in the same step.
func print_photo(inventory: Node) -> bool:
	var id := current_photo()
	if id.is_empty() or not REGISTRY.can_print(id): return false
	var store: Object = inventory.get("inventory")
	if store == null: return false
	if int(store.get("bits")) < PRINT_PRICE:
		_say("A print costs %d bit" % PRINT_PRICE); return false
	if int(store.call("grant", "art:" + id, 1)) < 0:
		_say(str(store.get("last_error"))); return false
	store.call("debit_bits", PRINT_PRICE)
	REGISTRY.mark_printed(id)
	_pages.reload()
	SFX.play_at(self, "page")
	_say("Printed: it's in your briefcase")
	return true

func _say(text: String) -> void:
	_notice = text
	_notice_until = Time.get_ticks_msec() * 0.001 + NOTICE_SECONDS

func _close(page: Node3D) -> void:
	page.fold()
	_covers(true)

func _covers(shown: bool) -> void:
	var page := sheet()
	var body: Node = page.get_parent() if page != null else null
	if body == null: return
	for child: Node in body.get_children():
		if child is MeshInstance3D: (child as MeshInstance3D).visible = shown

func _process(delta: float) -> void:
	var page := sheet()
	if page == null or not page.opened:
		set_process(false); return
	if not _in_hand():
		_press_side = ""
		_close(page); set_process(false); return
	if not _press_side.is_empty():
		_press_time += delta
		if _press_time >= PRINT_HOLD_SECONDS:
			_press_side = ""
			print_photo(_inventory)
	if is_instance_valid(_inventory) and bool(_inventory.get("_desktop")): _place(null)

func _in_hand() -> bool:
	if not is_instance_valid(_inventory): return false
	var held: Variant = _inventory.get("held")
	return held is Dictionary and (held as Dictionary).values().has(item)

func _place(sample: Variant) -> void:
	var page := sheet()
	if page == null or not page.opened or not is_instance_valid(_inventory): return
	var eye: Camera3D = _inventory.get("camera")
	if eye == null: return
	if bool(_inventory.get("_desktop")) or not sample is Dictionary:
		page.place(eye.global_transform * page.reading_pose(LETTER_TOOL.READ_DESKTOP))
	else:
		var current: Basis = page.sheet.global_basis if page.sheet != null else Basis()
		page.place(BOOK_HOLD.from_hand(sample, eye.global_transform, current, true))

## VR, every physics tick in hand: the trigger (the books' hysteresis) and the page's pose.
func vr_step(inventory: Node, side: String, sample: Dictionary) -> void:
	_inventory = inventory
	var was: bool = _vr_down.get(side, false)
	var down := float(sample.get("trigger", 0.0)) > (0.3 if was else 0.7)
	if down != was:
		_vr_down[side] = down
		press(inventory, side, down)
	if sample.get("active", false): _place(sample)

## The control hint for the journal in `side`'s hand (briefcase_inventory.gd interaction_hint).
func hint(side: String) -> Dictionary:
	var desktop := side == "desktop"
	var click := "Click" if desktop else "Trigger"
	var page := sheet()
	var text := "%s · Open photo journal" % click
	if is_open():
		text = "%s · %s" % [click, "Next photo" if page.more_pages() else "Close journal"]
		var id := current_photo()
		if not id.is_empty() and REGISTRY.can_print(id):
			text += "   Hold %s · Print for %d bit" % [click.to_lower(), PRINT_PRICE]
		if desktop:
			text += "   Wheel · Closer"
			if int(page.get("page")) > 0: text += "   Right click · Back"
	if Time.get_ticks_msec() * 0.001 < _notice_until: text = _notice + "   " + text
	return {"target": item, "text": text, "point": item.global_position + Vector3.UP * 0.12, "outline": null}
