extends Node
## The photo journal's pages (world/items/photo_journal.gd): the same interface as a letter's ink
## (letter_ink.gd), so the journal's sheet is the letters' own sheet (letter_sheet.gd use_ink). One
## photo to a side, newest first. Only the two sides of the open sheet exist as viewports: a side
## is drawn when it comes up, so a full journal costs no more than two pictures.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const INK := preload("res://world/letters/paper/letter_ink.gd")
const PAPER := Color(0.93, 0.90, 0.82)
const INK_COLOUR := Color(0.25, 0.20, 0.16)
const PHOTO_RECT := Rect2(36, 120, 648, 486)
const EMPTY := "No photos yet."
const FONT_SIZE := 44
signal laid_out

var sides := 1
var photos: Array[String] = []
var _views: Array[SubViewport] = []
var _pictures: Array[TextureRect] = []
var _captions: Array[Label] = []
var _drawn := [-1, -1]

## The journal as it stands now: the photo list, and every side redrawn when next shown.
func reload() -> void:
	photos = REGISTRY.photos()
	sides = maxi(1, photos.size())
	_drawn = [-1, -1]
	laid_out.emit()

## letter_sheet.gd refresh() is for handwriting; the journal has none.
func show_text(_value: String, _stationery: String, _pony := false) -> void:
	pass

func photo(side: int) -> String:
	return photos[side] if side >= 0 and side < photos.size() else ""

func texture(side: int) -> Texture2D:
	if side >= sides: return null
	var view := side % 2
	_make()
	if int(_drawn[view]) != side:
		_drawn[view] = side
		_fill(view, side)
	return _views[view].get_texture()

func _fill(view: int, side: int) -> void:
	var id := photo(side)
	var image: Image = Image.load_from_file(REGISTRY.art_path(id)) if not id.is_empty() else null
	_pictures[view].texture = ImageTexture.create_from_image(image) if image != null and not image.is_empty() else null
	if id.is_empty(): _captions[view].text = EMPTY
	else: _captions[view].text = "Photo %d of %d%s" % [photos.size() - side, photos.size(), "\nPrinted" if not REGISTRY.can_print(id) else ""]
	_views[view].render_target_update_mode = SubViewport.UPDATE_ONCE

func _make() -> void:
	while _views.size() < 2:
		var view := SubViewport.new()
		view.size = INK.PAGE_PX
		view.disable_3d = true
		view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(view)
		var paper := ColorRect.new()
		paper.size = Vector2(INK.PAGE_PX); paper.color = PAPER
		view.add_child(paper)
		var picture := TextureRect.new()
		picture.position = PHOTO_RECT.position; picture.size = PHOTO_RECT.size
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		view.add_child(picture)
		var caption := Label.new()
		caption.position = Vector2(36, 640); caption.size = Vector2(648, 240)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_font_override("font", load(INK.FONT_ANON) as Font)
		caption.add_theme_font_size_override("font_size", FONT_SIZE)
		caption.add_theme_color_override("font_color", INK_COLOUR)
		view.add_child(caption)
		_views.append(view); _pictures.append(picture); _captions.append(caption)
