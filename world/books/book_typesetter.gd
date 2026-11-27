extends Node
## Typesets the pages of the physical books (dev 2026-09-26: "the book should literally open up,
## per page, and have the text, on the page"). One offscreen SubViewport lays out a page
## (paper, fonts and size from Settings > Reading) and bakes it into a texture; books paste those
## textures on their paper. Pages are made one per frame, on request, and cached.
##
## A book is a stream of pages: 0 is the title page (cover art, title, author, credit), then every
## chapter's pages in order. An open book shows page n on the left and n + 1 on the right, n even.

signal page_ready(book_id: int, n: int)
const LIBRARY := preload("res://world/books/book_library.gd")
const RT := preload("res://world/perf/render_thread.gd")
## The page's shape (open_book.gd W:H) at a resolution sharp at reading distance in a headset.
const PAGE_PX := Vector2i(932, 1080)
## Settings > Reading size is in pixels of a 900 px tall page; scale it to this one.
const SIZE_SCALE := 1080.0 / 900.0
const MARGIN := 58.0
const HEADER := 62.0
const FOOTER := 64.0
const CACHE_PAGES := 16
const PAPERS := {
	"white": {"paper": Color("fbfaf6"), "ink": Color("202020"), "soft": Color("7a7670")},
	"cream": {"paper": Color("f4ecd8"), "ink": Color("35291c"), "soft": Color("8c7a62")},
	"sepia": {"paper": Color("e8d5ae"), "ink": Color("442f19"), "soft": Color("85693f")},
	"grey": {"paper": Color("d8d8d4"), "ink": Color("1d1d1d"), "soft": Color("5f5f5a")},
	"night": {"paper": Color("1d1c1a"), "ink": Color("d9d2c3"), "soft": Color("8a8375")},
}
const FONTS := {
	# The show's lettering as an option only: book pages keep a normal reading font by default
	# (dev 2026-09-30: "book need normal text for reading"). One weight: italics slant it,
	# bold emboldens it (_font below).
	"celestia": ["res://world/ui/fonts/CelestiaMediumRedux.ttf", "res://world/ui/fonts/CelestiaMediumRedux.ttf", ""],
	"literata": ["res://world/books/fonts/Literata.ttf", "res://world/books/fonts/Literata-Italic.ttf", ""],
	"atkinson": ["res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf", "res://world/books/fonts/AtkinsonHyperlegible-Italic.ttf", "res://world/books/fonts/AtkinsonHyperlegible-Bold.ttf"],
	"dyslexic": ["res://world/books/fonts/OpenDyslexic-Regular.otf", "res://world/books/fonts/OpenDyslexic-Italic.otf", "res://world/books/fonts/OpenDyslexic-Bold.otf"],
}

var viewport: SubViewport
var _paper: ColorRect
var _clip: Control
var _body: RichTextLabel
var _header: Label
var _footer: Label
var _title: Control
var _book := -1
var _meta := {}
var _doc := {}
var _layouts := {}         # chapter -> {"starts": [line], "heights": [px]}
var _laid_chapter := -2    # chapter whose text is in the label now
var _queue: Array = []     # [book id, page]
var _cache := {}           # "style|book|page" -> Texture2D
var _order: Array = []
var _busy := false
var _fonts := {}

## The one typesetter, made on first use under the scene root.
static func get_instance(tree: SceneTree) -> Node:
	var existing := tree.root.get_node_or_null("BookTypesetter")
	if existing != null: return existing
	var made: Node = load("res://world/books/book_typesetter.gd").new()
	made.name = "BookTypesetter"
	tree.root.add_child(made)
	return made

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = PAGE_PX
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	_paper = ColorRect.new()
	_paper.size = Vector2(PAGE_PX)
	viewport.add_child(_paper)
	_clip = Control.new()
	_clip.clip_contents = true
	_clip.position = Vector2(MARGIN, HEADER)
	_clip.size = Vector2(PAGE_PX.x - MARGIN * 2, _page_height())
	viewport.add_child(_clip)
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = false
	_body.fit_content = true
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size = Vector2(_clip.size.x, 10)
	_body.custom_minimum_size.x = _clip.size.x
	_clip.add_child(_body)
	_header = _label(Vector2(MARGIN, 16), Vector2(PAGE_PX.x - MARGIN * 2, 34), 20)
	_footer = _label(Vector2(MARGIN, PAGE_PX.y - FOOTER + 10), Vector2(PAGE_PX.x - MARGIN * 2, 36), 22)
	_title = Control.new()
	_title.size = Vector2(PAGE_PX)
	viewport.add_child(_title)
	var settings := get_node_or_null("/root/Settings")
	if settings != null: settings.changed.connect(func(key: String):
		if key.begins_with("reading/"): _restyle())
	_restyle()

func _page_height() -> float: return PAGE_PX.y - HEADER - FOOTER

# --- the page stream -----------------------------------------------------------------------

func use_book(id: int) -> bool:
	if id == _book: return not _doc.is_empty()
	_book = id
	_meta = LIBRARY.book(id)
	_doc = LIBRARY.text(id)
	_layouts.clear()
	_laid_chapter = -2
	return not _doc.is_empty() and not _doc.get("chapters", []).is_empty()

## (chapter, page) of page n in the current book: chapter -1 = title page, -2 = past the end.
func locate(n: int) -> Vector2i:
	if n <= 0: return Vector2i(-1, 0)
	var rest := n - 1
	for c in _doc.get("chapters", []).size():
		var count: int = _layout(c).starts.size()
		if rest < count: return Vector2i(c, rest)
		rest -= count
	return Vector2i(-2, 0)

## The page stream index of chapter c's first page.
func chapter_start(c: int) -> int:
	var n := 1
	for i in mini(c, _doc.get("chapters", []).size()):
		n += _layout(i).starts.size()
	return n

func chapter_count() -> int: return _doc.get("chapters", []).size()

## The page's texture, or null while it is being made (page_ready tells when).
func texture(book: int, n: int) -> Texture2D:
	var key := _key(book, n)
	if _cache.has(key): return _cache[key]
	request(book, n)
	return null

func request(book: int, n: int) -> void:
	if n < 0 or _cache.has(_key(book, n)): return
	for q: Array in _queue:
		if q[0] == book and q[1] == n: return
	_queue.append([book, n])

func _key(book: int, n: int) -> String: return "%s|%d|%d" % [_style_key(), book, n]

func _style_key() -> String:
	return "%s/%s/%d" % [_setting("reading/paper", "cream"), _setting("reading/font", "literata"), _size()]

func _process(_delta: float) -> void:
	if _busy or _queue.is_empty(): return
	var job: Array = _queue.pop_front()
	_busy = true
	await _render(int(job[0]), int(job[1]))
	_busy = false

func _render(book: int, n: int) -> void:
	if not use_book(book): return
	var at := locate(n)
	var colours: Dictionary = PAPERS.get(_setting("reading/paper", "cream"), PAPERS.cream)
	_title.visible = at.x == -1
	_clip.visible = at.x >= 0
	_header.text = ""
	_footer.text = ""
	if at.x == -1:
		_build_title(colours)
	elif at.x >= 0:
		_show_chapter_page(at.x, at.y)
		_header.text = str(_meta.get("title", "")) if n % 2 == 0 else str(_doc.chapters[at.x].get("title", ""))
		_footer.text = str(n)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if RT.active(): await RT.drawn(get_tree())
	else: await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if image == null: return
	image.generate_mipmaps()
	var texture := ImageTexture.create_from_image(image)
	var key := _key(book, n)
	_cache[key] = texture
	_order.append(key)
	while _order.size() > CACHE_PAGES: _cache.erase(_order.pop_front())
	page_ready.emit(book, n)

# --- layout --------------------------------------------------------------------------------

func _chapter_text(c: int) -> String:
	var ch: Dictionary = _doc.chapters[c]
	var parts := PackedStringArray()
	parts.append("[center][font_size=%d]%s[/font_size][/center]" % [int(_size() * 1.35), str(ch.get("title", "")).replace("[", "[lb]")])
	parts.append("")
	for p: String in ch.get("paragraphs", []):
		parts.append(p)
		parts.append("")
	return "\n".join(parts)

func _set_chapter(c: int) -> void:
	if _laid_chapter == c: return
	_body.text = _chapter_text(c)
	_body.size.x = _clip.size.x
	_laid_chapter = c

## Page breaks fall before the first line whose bottom would pass the page.
func _layout(c: int) -> Dictionary:
	if _layouts.has(c): return _layouts[c]
	_set_chapter(c)
	var starts: Array[int] = [0]
	var heights: Array[float] = []
	var height := _page_height()
	var lines := _body.get_line_count()
	var content := _body.get_content_height()
	var start_y := 0.0
	for line in lines:
		var top := _body.get_line_offset(line)
		var bottom: float = _body.get_line_offset(line + 1) if line + 1 < lines else float(content)
		if bottom - start_y > height and line > starts[-1]:
			heights.append(top - start_y)
			starts.append(line)
			start_y = top
	heights.append(maxf(content - start_y, 1.0))
	_layouts[c] = {"starts": starts, "heights": heights}
	return _layouts[c]

func _show_chapter_page(c: int, p: int) -> void:
	var layout := _layout(c)
	_set_chapter(c)
	p = clampi(p, 0, layout.starts.size() - 1)
	_body.position.y = -_body.get_line_offset(layout.starts[p])
	_clip.size.y = minf(layout.heights[p], _page_height())

func _build_title(colours: Dictionary) -> void:
	for child in _title.get_children(): child.queue_free()
	var y := 84.0
	var art: Texture2D = LIBRARY.cover_texture(_book)
	if art != null:
		var frame := TextureRect.new()
		frame.texture = art
		frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.position = Vector2(MARGIN, y)
		frame.size = Vector2(PAGE_PX.x - MARGIN * 2, 340)
		_title.add_child(frame)
		y += 362
	var title := _label(Vector2(MARGIN, y), Vector2(PAGE_PX.x - MARGIN * 2, 140), 48, _title)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.text = str(_meta.get("title", ""))
	title.add_theme_font_override("font", _font(0))
	title.add_theme_color_override("font_color", colours.ink)
	y += 150
	var by := _label(Vector2(MARGIN, y), Vector2(PAGE_PX.x - MARGIN * 2, 42), 30, _title)
	by.text = "by " + str(_meta.get("author", ""))
	by.add_theme_font_override("font", _font(1))
	by.add_theme_color_override("font_color", colours.ink)
	y += 66
	var blurb := RichTextLabel.new()
	blurb.bbcode_enabled = true
	blurb.scroll_active = false
	blurb.position = Vector2(MARGIN + 10, y)
	blurb.size = Vector2(PAGE_PX.x - MARGIN * 2 - 20, PAGE_PX.y - y - 200)
	blurb.add_theme_font_override("normal_font", _font(1))
	blurb.add_theme_font_size_override("normal_font_size", 23)
	blurb.add_theme_color_override("default_color", colours.ink)
	blurb.text = "[center]%s[/center]" % str(_meta.get("short", "")).replace("[", "[lb]")
	_title.add_child(blurb)
	var credit := _label(Vector2(MARGIN, PAGE_PX.y - 190), Vector2(PAGE_PX.x - MARGIN * 2, 168), 18, _title)
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	credit.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	credit.add_theme_color_override("font_color", colours.soft)
	# House books (book_library.gd HOUSE_LIBRARY) were written for the game and carry their own line.
	if _meta.has("credit"): credit.text = str(_meta.credit); return
	credit.text = "Written by %s. All rights belong to the author; cover art as shown on the story's page.\nRead, favourite and thank the author at\n%s\n%s words · rated %s · %s" % [
		str(_meta.get("author", "")), str(_meta.get("url", "")), _thousands(int(_meta.get("words", 0))),
		str(_meta.get("rating", "")).capitalize(), str(_meta.get("source", ""))]

# --- look ----------------------------------------------------------------------------------

func _restyle() -> void:
	var colours: Dictionary = PAPERS.get(_setting("reading/paper", "cream"), PAPERS.cream)
	_paper.color = colours.paper
	var size_px := _size()
	_body.add_theme_font_override("normal_font", _font(0))
	_body.add_theme_font_override("italics_font", _font(1))
	_body.add_theme_font_override("bold_font", _font(2))
	_body.add_theme_font_override("bold_italics_font", _font(3))
	for slot in ["normal_font_size", "italics_font_size", "bold_font_size", "bold_italics_font_size"]:
		_body.add_theme_font_size_override(slot, size_px)
	_body.add_theme_color_override("default_color", colours.ink)
	_body.add_theme_constant_override("line_separation", int(size_px * 0.28))
	for l: Label in [_header, _footer]:
		l.add_theme_color_override("font_color", colours.soft)
		l.add_theme_font_override("font", _font(1))
	_layouts.clear()
	_laid_chapter = -2

func _setting(key: String, fallback: Variant) -> Variant:
	var settings := get_node_or_null("/root/Settings")
	return settings.get_value(key) if settings != null else fallback

func _size() -> int: return int(round(clampi(int(_setting("reading/size", 26)), 16, 44) * SIZE_SCALE))

func _font(style: int) -> Font:
	var family := str(_setting("reading/font", "literata"))
	var key := "%s_%d" % [family, style]
	if _fonts.has(key): return _fonts[key]
	var paths: Array = FONTS.get(family, FONTS.literata)
	var font: Font
	var wght := TextServerManager.get_primary_interface().name_to_tag("wght")
	match style:
		0:
			font = load(paths[0])
		1:
			font = load(paths[1])
			if family == "celestia":
				var slant := FontVariation.new(); slant.base_font = font
				slant.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.22, 1), Vector2.ZERO); font = slant
		2:
			if str(paths[2]).is_empty():
				var v := FontVariation.new(); v.base_font = load(paths[0])
				if family == "celestia": v.variation_embolden = 0.6
				else: v.variation_opentype = {wght: 680}
				font = v
			else:
				font = load(paths[2])
		_:
			var v := FontVariation.new(); v.base_font = load(paths[1])
			if family == "literata": v.variation_opentype = {wght: 680}
			elif family == "celestia":
				v.variation_embolden = 0.6
				v.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.22, 1), Vector2.ZERO)
			else: v.variation_embolden = 0.6
			font = v
	_fonts[key] = font
	return font

func _label(at: Vector2, extent: Vector2, font_size: int, parent: Node = null) -> Label:
	var l := Label.new()
	l.position = at
	l.size = extent
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_font_size_override("font_size", font_size)
	(parent if parent != null else viewport).add_child(l)
	return l

static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
