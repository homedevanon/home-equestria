extends Node3D
## A letter as a thing in the hand (docs/LETTERS_PLAN_2026_10_29.md section 7), the root of
## letter_item.tscn for "letter:<id>" items, like book_item.gd for books: folded, it is the
## Ponyville kit's letter (activity/letter.scn) lying flat; opened, it is one sheet of paper whose
## two faces are the open book's printed page quads (open_book.gd _page_quad, scaled to the sheet)
## carrying the handwriting (letter_ink.gd). The sheet's frame follows the book's: the writing
## faces +Y, the head of the page is -Z, +X the reader's right. Where the open sheet is held
## (in front of the eyes, or up from the hand in VR) is set by letter_tool.gd each frame.
const INK := preload("res://world/letters/paper/letter_ink.gd")
const OPEN_BOOK := preload("res://world/books/open_book.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const W := 0.15
const H := 0.21
## The folded letter: 0.22 x 0.14 m, a few millimetres thick (letter.glb), laid flat and centred.
const FOLDED_SIZE := Vector3(0.22, 0.013, 0.14)
const OPEN_SECONDS := 0.22
## Desktop: how far before the eyes the open sheet is held; the wheel brings it closer (dev
## 2026-11-03). At READ_NEAR the sheet fills the height of a 75 degree view.
const READ_FAR := 0.33
const READ_NEAR := 0.14
const ZOOM_STEP := 0.03
const ZOOM_EASE := 14.0
@export var item_id := ""
var opened := false
## The side being read, counting from 0; two sides make one sheet of a long letter.
var page := 0
## 0 the front faces the reader, 1 the sheet is turned over to its back.
var side := 0
## A letter being written shows its last side, where the words are going.
var follow_end := false
var _reading_at := READ_FAR
var _reading_goal := READ_FAR
var ink: Node
var folded: Node3D
var sheet: Node3D
var _paper: Node3D
var _front: MeshInstance3D
var _back: MeshInstance3D
var _tween: Tween

func _ready() -> void:
	if item_id.is_empty():
		var parent := get_parent()
		if parent != null and parent.has_meta("item_id"): item_id = str(parent.get_meta("item_id"))
	folded = get_node_or_null("Folded") as Node3D
	if folded != null:
		# letter.glb stands upright, hanging from its top edge: lay it flat and centre it.
		folded.transform = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(0, 0.0042, -0.07))
		for mesh: GeometryInstance3D in folded.find_children("*", "GeometryInstance3D", true, false):
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ink = INK.new(); ink.name = "Ink"; add_child(ink)
	ink.laid_out.connect(_show_pages)

func letter_id() -> String:
	return item_id.substr(7) if item_id.begins_with("letter:") else ""

## The inventory's body around the folded letter (briefcase_drops.gd _make_item calls this).
func configure_body(_item: RigidBody3D, shape: CollisionShape3D) -> void:
	var box := BoxShape3D.new(); box.size = FOLDED_SIZE
	shape.shape = box
	shape.position = Vector3(0, FOLDED_SIZE.y * 0.5, 0)

## Another page source with ink's interface (sides, texture(side), laid_out, show_text):
## the photo journal's pictures (world/items/photo_journal_pages.gd).
func use_ink(other: Node) -> void:
	if is_instance_valid(ink):
		remove_child(ink); ink.queue_free()
	ink = other
	add_child(ink)
	ink.laid_out.connect(_show_pages)

## The handwriting to show (the open sheet updates as it is written).
func refresh(text: String, stationery: String, pony_hand := false) -> void:
	ink.show_text(text, stationery, pony_hand)

func sides() -> int:
	return int(ink.get("sides"))

func open_sheet() -> void:
	if opened: return
	opened = true; page = 0; side = 0
	_build()
	SFX.play_at(self, "page")
	if folded != null: folded.visible = false
	sheet.visible = true
	_show_pages()
	_animate(1.0)

func fold() -> void:
	if not opened: return
	opened = false
	SFX.play_at(self, "page")
	_animate(0.0, func() -> void:
		if not opened:
			sheet.visible = false
			if folded != null: folded.visible = true)

func more_pages() -> bool:
	return page < sides() - 1

## On to the next side: over to the back of this sheet, or the front of the next one.
func next_page() -> void:
	_go_to(page + 1)

func previous_page() -> void:
	_go_to(page - 1)

func _go_to(index: int) -> void:
	if not opened or index < 0 or index >= sides() or index == page: return
	page = index
	SFX.play_at(self, "page")
	_show_pages()

## Desktop wheel: +1 brings the open sheet closer to the eyes, -1 back.
func zoom(step: int) -> void:
	_reading_goal = clampf(_reading_goal - step * ZOOM_STEP, READ_NEAR, READ_FAR)

## `base` (letter_tool.gd READ_DESKTOP) moved in to the wheel's distance, centred as it nears.
func reading_pose(base: Transform3D) -> Transform3D:
	_reading_at = lerpf(_reading_at, _reading_goal, 1.0 - exp(-get_process_delta_time() * ZOOM_EASE))
	var near := inverse_lerp(READ_FAR, READ_NEAR, _reading_at)
	return Transform3D(base.basis, Vector3(0.0, base.origin.y * (1.0 - near), -_reading_at))

## Where the open sheet is: the reader's view or the holding hand (letter_tool.gd).
func place(pose: Transform3D) -> void:
	if sheet == null or not opened: return
	# A turned sheet shows its back: half a turn about the page's head-to-foot axis.
	sheet.global_transform = pose * Transform3D(Basis(Vector3.BACK, PI) if side == 1 else Basis.IDENTITY, Vector3.ZERO)

func _build() -> void:
	if sheet != null: return
	sheet = Node3D.new(); sheet.name = "Sheet"; sheet.visible = false
	add_child(sheet)
	_paper = Node3D.new(); _paper.name = "Paper"
	sheet.add_child(_paper)
	# open_book.gd's printed page quads span one book page (x 0..W, z -H/2..H/2); scaled and
	# shifted onto this sheet, the front faces +Y and the back faces -Y with its u mirrored.
	var maker: Node3D = OPEN_BOOK.new()
	_front = maker._page_quad("Front", 1.0, false)
	_back = maker._page_quad("Back", 1.0, true)
	maker.free()
	for quad: MeshInstance3D in [_front, _back]:
		quad.scale = Vector3(W / OPEN_BOOK.W, 1.0, H / OPEN_BOOK.H)
		quad.position = Vector3(-W * 0.5, 0, 0)
		_paper.add_child(quad)

func _show_pages() -> void:
	if sheet == null: return
	page = sides() - 1 if follow_end else clampi(page, 0, sides() - 1)
	side = page % 2
	_set_texture(_front, ink.texture(page - side))
	_set_texture(_back, ink.texture(page - side + 1))

static func _set_texture(quad: MeshInstance3D, texture: Texture2D) -> void:
	var material := quad.material_override as StandardMaterial3D
	material.albedo_texture = texture
	material.albedo_color = Color.WHITE if texture != null else Color(0.95, 0.93, 0.88)
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR

func _animate(to: float, done := Callable()) -> void:
	if _tween != null: _tween.kill()
	_tween = create_tween()
	# The sheet unfolds from a third of its height to full size, and folds back the same way.
	_tween.tween_method(func(t: float) -> void:
		if _paper != null: _paper.scale = Vector3(1.0, 1.0, lerpf(0.33, 1.0, t)), 1.0 - to, to, OPEN_SECONDS)
	if done.is_valid(): _tween.tween_callback(done)
