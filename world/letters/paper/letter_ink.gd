extends Node
## A letter's handwriting (docs/LETTERS_PLAN_2026_10_29.md section 7): an offscreen SubViewport
## per sheet lays out the text in the show's lettering on the stationery's paper, and the sheet's
## page quads (letter_sheet.gd) show its texture directly, so writing needs no image readback.
## Anon writes in CelestiaMediumRedux, a pony in its alternate cut. Crossed-out sentences ("~~",
## letter_text.gd) are struck through in ink. The text shrinks to fit one side; past the smallest
## size it stays that size and carries on over as many sides as it needs, two to a sheet (dev
## 2026-11-03: "the text is really small on longer letters"; a viewport per side, made only then).
## A layout is made once per frame at most, and only after the text or paper changed; the viewports
## then draw once.
const LETTER_TEXT := preload("res://world/letters/letter_text.gd")
const STATIONERY := preload("res://world/letters/stationery.gd")
const FONT_ANON := "res://world/ui/fonts/CelestiaMediumRedux.ttf"
const FONT_PONY := "res://world/ui/fonts/CelestiaMediumReduxAlternate.ttf"
## The sheet's shape (letter_sheet.gd W:H = 0.15:0.21), sharp at reading distance in a headset.
const PAGE_PX := Vector2i(720, 1008)
const MARGIN := Vector2(70.0, 76.0)
const SIZES := [48, 44, 40, 36, 33]
signal laid_out

var sides := 1
var font_size: int = SIZES[0]
var text := ""
var kind := "plain"
var pony_hand := false
## The bbcode drawn on the front (tests read it; headless runs draw nothing).
var bbcode := ""
var _pages: Array[SubViewport] = []
var _bodies: Array[RichTextLabel] = []
var _clips: Array[Control] = []
var _papers: Array[ColorRect] = []
var _dirty := false

func _ready() -> void:
	set_process(false)

## New text or paper for the sheet; laid out on the next frame.
func show_text(value: String, stationery: String, pony := false) -> void:
	text = value; kind = stationery if STATIONERY.valid(stationery) else "plain"; pony_hand = pony
	_dirty = true
	set_process(true)

func texture(side: int) -> Texture2D:
	if side >= sides or side >= _pages.size(): return null
	return _pages[side].get_texture()

func _process(_delta: float) -> void:
	set_process(false)
	if _dirty: layout()

## Lays the text out now (show_text defers to here).
func layout() -> void:
	_dirty = false
	_page(0)
	bbcode = _bbcode(text)
	var body := _bodies[0]
	var room := float(PAGE_PX.y) - MARGIN.y * 2.0
	sides = 1
	for size: int in SIZES:
		font_size = size
		_style(body, size)
		body.text = bbcode
		if body.get_content_height() <= room: break
	# Past the smallest size: each side ends at the last whole line that fits, the next carries on.
	var tops: Array[float] = [0.0]
	var lines := body.get_line_count()
	for line in lines:
		var bottom: float = body.get_line_offset(line + 1) if line + 1 < lines else body.get_content_height()
		if bottom - tops[-1] > room: tops.append(body.get_line_offset(line))
	sides = tops.size()
	for index in sides:
		_page(index)
		if index > 0:
			_style(_bodies[index], font_size)
			_bodies[index].text = bbcode
		_bodies[index].position.y = -tops[index]
		_clips[index].size.y = (tops[index + 1] - tops[index]) if index + 1 < sides else room
		_papers[index].color = STATIONERY.paper(kind)
		(_papers[index].get_child(0) as Control).queue_redraw()
		_pages[index].render_target_update_mode = SubViewport.UPDATE_ONCE
	laid_out.emit()

## "~~struck~~" -> [s], everything else escaped.
static func _bbcode(value: String) -> String:
	var out := ""
	var pieces := value.split(LETTER_TEXT.STRIKE)
	var closed := pieces.size() % 2 == 1
	for index in pieces.size():
		var piece := str(pieces[index]).replace("[", "[lb]")
		if index % 2 == 1 and (closed or index < pieces.size() - 1): out += "[s]" + piece + "[/s]"
		else: out += piece
	return out

func _page(index: int) -> void:
	while _pages.size() <= index:
		var viewport := SubViewport.new()
		viewport.name = "Side%d" % _pages.size()
		viewport.size = PAGE_PX
		viewport.disable_3d = true
		viewport.transparent_bg = false
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(viewport)
		var paper := ColorRect.new()
		paper.size = Vector2(PAGE_PX)
		viewport.add_child(paper)
		var motif := Control.new()
		motif.size = Vector2(PAGE_PX)
		motif.draw.connect(_draw_motif.bind(motif))
		paper.add_child(motif)
		var clip := Control.new()
		clip.clip_contents = true
		clip.position = MARGIN
		clip.size = Vector2(PAGE_PX) - MARGIN * 2.0
		viewport.add_child(clip)
		var body := RichTextLabel.new()
		body.bbcode_enabled = true
		body.scroll_active = false
		body.fit_content = true
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.size = Vector2(clip.size.x, 10)
		body.custom_minimum_size.x = clip.size.x
		clip.add_child(body)
		_pages.append(viewport); _papers.append(paper); _clips.append(clip); _bodies.append(body)

func _style(body: RichTextLabel, size: int) -> void:
	body.add_theme_font_override("normal_font", load(FONT_PONY if pony_hand else FONT_ANON) as Font)
	body.add_theme_font_size_override("normal_font_size", size)
	body.add_theme_color_override("default_color", STATIONERY.ink(kind))
	body.add_theme_constant_override("line_separation", int(size * 0.3))

## Floral and hearts paper: a few small flowers or hearts down the left margin and along the foot.
func _draw_motif(canvas: Control) -> void:
	var motif: Array = STATIONERY.MOTIF.get(kind, ["", Color.BLACK])
	if str(motif[0]).is_empty(): return
	var colour: Color = motif[1]
	var spots: Array[Vector2] = []
	for step in 7: spots.append(Vector2(30.0, 110.0 + step * 130.0))
	for step in 4: spots.append(Vector2(190.0 + step * 150.0, float(PAGE_PX.y) - 30.0))
	for spot: Vector2 in spots:
		if str(motif[0]) == "hearts": _heart(canvas, spot, 13.0, colour)
		else: _flower(canvas, spot, 12.0, colour)

static func _heart(canvas: Control, at: Vector2, size: float, colour: Color) -> void:
	var points := PackedVector2Array()
	for step in 24:
		var t := TAU * step / 24.0
		points.append(at + Vector2(16.0 * pow(sin(t), 3), -(13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t))) * size / 16.0)
	canvas.draw_colored_polygon(points, colour)

static func _flower(canvas: Control, at: Vector2, size: float, colour: Color) -> void:
	for petal in 5:
		canvas.draw_circle(at + Vector2.from_angle(TAU * petal / 5.0 - PI / 2.0) * size * 0.6, size * 0.45, colour)
	canvas.draw_circle(at, size * 0.32, Color("f2c94c"))
