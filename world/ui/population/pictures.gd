extends RefCounted
## Pictures for the "Who lives where" cards (world/ui/population/population_window.gd).
## card_texture: an approved show vector when one exists, else the baked photo of her in-game
## model, else a coat disc with her cutie mark from the map icon atlas (as the journal draws
## her), else a plain coat disc with the first letter of her name. Never null.
## Photos are baked by tools/population/bake_portraits.gd; vectors stay empty in the beta.
## Every texture is made once and kept for the session.
const PORTRAITS := "res://world/ui/population/portraits/%s.webp"
const VECTORS := "res://world/ui/population/vectors/%s.webp"
const PONY_DATA := preload("res://world/ui/pony_map_data.gd")
const RESOURCE_IMAGE := preload("res://world/resource_image.gd")
const LETTER_FONT := "res://world/ui/fonts/CelestiaMediumRedux.ttf"
## Final disc edge in pixels; drawn at twice this and scaled down for a smooth rim.
const SIDE := 256
const RING := 0.035
## The journal's mark square (world/ui/ai_context_page.gd _portrait): 0.66 of the disc, centred.
const MARK := 0.66
const LETTER := 0.5
static var _cards: Dictionary = {}
static var _photos: Dictionary = {}
static var _atlas: Image


static func card_texture(id: String) -> Texture2D:
	if _cards.has(id): return _cards[id]
	var texture := _load(VECTORS % id)
	if texture == null: texture = photo_texture(id)
	if texture == null: texture = RESOURCE_IMAGE.upload(disc_image(id))
	_cards[id] = texture
	return texture


static func photo_texture(id: String) -> Texture2D:
	if not _photos.has(id): _photos[id] = _load(PORTRAITS % id)
	return _photos[id]


## Source runs read the file itself: a fresh bake has an import sidecar but no import yet, and
## loading it as a resource fails. Exported games load the imported texture.
static func _load(path: String) -> Texture2D:
	if OS.has_feature("editor"):
		if not FileAccess.file_exists(path): return null
		var image := Image.load_from_file(ProjectSettings.globalize_path(path))
		return RESOURCE_IMAGE.upload(image) if image != null and not image.is_empty() else null
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


## The fallback disc as an image of SIDE pixels: coat with a darker rim, then her mark, or the
## first letter of her name when the atlas has no mark for her (blank flanks, Cheerilee, Spike,
## Zecora).
static func disc_image(id: String) -> Image:
	PONY_DATA.load_icons()
	var icon: Dictionary = PONY_DATA.icons.get(id, {})
	var coat := _coat(id, icon)
	var ring := coat.darkened(0.4)
	var big := SIDE * 2
	var image := Image.create_empty(big, big, false, Image.FORMAT_RGBA8)
	_fill_disc(image, big * 0.5, ring)
	_fill_disc(image, big * (0.5 - RING), coat)
	var mark: Image = null
	if not icon.is_empty() and not bool(icon.get("blank", false)): mark = _mark(icon)
	elif icon.is_empty(): mark = _own_mark(id)
	if mark != null:
		var mark_side := int(big * MARK)
		mark.resize(mark_side, mark_side, Image.INTERPOLATE_LANCZOS)
		image.blend_rect(mark, Rect2i(Vector2i.ZERO, mark.get_size()), Vector2i.ONE * ((big - mark_side) / 2))
	else:
		var letter := _letter(_name(id, icon).trim_prefix("Princess ").left(1).to_upper(), ring, int(big * LETTER))
		if letter != null: image.blend_rect(letter, Rect2i(Vector2i.ZERO, letter.get_size()), (Vector2i.ONE * big - letter.get_size()) / 2)
	image.resize(SIDE, SIDE, Image.INTERPOLATE_LANCZOS)
	return image


static func _coat(id: String, icon: Dictionary) -> Color:
	var value: Array = icon.get("coat", [])
	if value.size() >= 3: return Color(float(value[0]), float(value[1]), float(value[2]))
	# Ponies outside the atlas keep their identity resource beside their scene.
	for path: String in ["res://world/characters/background/%s.tres" % id, "res://world/characters/%s/%s.tres" % [id, id]]:
		if not ResourceLoader.exists(path): continue
		var identity := load(path)
		var fill: Variant = identity.get("coat_fill") if identity != null else null
		if fill is Color: return Color(fill.r, fill.g, fill.b)
	var own: Resource = _modded(id)
	if own != null and own.get("coat_fill") is Color:
		var coat: Color = own.get("coat_fill")
		return Color(coat.r, coat.g, coat.b)
	return Color(0.6, 0.7, 0.8)


## A mod's resident: the identity her scene carries (population_choices.gd scene_identity), else null.
static func _modded(id: String) -> Resource:
	return (load("res://world/population/population_choices.gd") as GDScript).call("scene_identity", id)


## Her own cutie mark picture as a square image, or null.
static func _own_mark(id: String) -> Image:
	var own: Resource = _modded(id)
	var texture: Texture2D = own.get("cutie_mark") as Texture2D if own != null else null
	var image: Image = texture.get_image() if texture != null else null
	if image == null or image.is_empty(): return null
	if image.is_compressed() and image.decompress() != OK: return null
	image.convert(Image.FORMAT_RGBA8)
	return image


static func _name(id: String, icon: Dictionary) -> String:
	var text := str(icon.get("name", ""))
	if text.is_empty() and icon.is_empty():
		var own: Resource = _modded(id)
		if own != null: text = str(own.get("display_name"))
	return text if not text.is_empty() else id.replace("_", " ").capitalize()


## One row of fill_rect per pixel line: native, so a disc costs a few milliseconds.
static func _fill_disc(image: Image, radius: float, color: Color) -> void:
	var centre := image.get_width() * 0.5
	for y in image.get_height():
		var dy := y + 0.5 - centre
		if absf(dy) >= radius: continue
		var half := sqrt(radius * radius - dy * dy)
		var left := int(round(centre - half))
		image.fill_rect(Rect2i(left, y, int(round(centre + half)) - left, 1), color)


static func _mark(icon: Dictionary) -> Image:
	if _atlas == null:
		_atlas = RESOURCE_IMAGE.read(PONY_DATA.ICON_ATLAS)
		if _atlas == null: return null
		if _atlas.get_format() != Image.FORMAT_RGBA8: _atlas.convert(Image.FORMAT_RGBA8)
	var rect: Array = icon.get("rect", [])
	if rect.size() < 4: return null
	return _atlas.get_region(Rect2i(int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3])))


## The letter in `color`, `height` pixels tall, from the game's UI font. The imported font is a
## distance field; a plain copy of its data rasterises real coverage instead.
static func _letter(text: String, color: Color, height: int) -> Image:
	var source := load(LETTER_FONT) as FontFile
	if text.is_empty() or source == null: return null
	# Not kept: a font held in a static outlives the text server at quit and logs a leak.
	var font := FontFile.new()
	font.data = source.data
	var size := Vector2i(height, 0)
	var glyph := font.get_glyph_index(height, text.unicode_at(0), 0)
	if glyph == 0: return null
	font.render_glyph(0, size, glyph)
	var page := font.get_texture_image(0, size, font.get_glyph_texture_idx(0, size, glyph))
	if page == null or page.is_empty(): return null
	var shape := page.get_region(Rect2i(font.get_glyph_uv_rect(0, size, glyph)))
	shape.convert(Image.FORMAT_RGBA8)
	var used := shape.get_used_rect()
	if not used.has_area(): return null
	shape = shape.get_region(used)
	shape.resize(maxi(1, int(height * float(used.size.x) / used.size.y)), height, Image.INTERPOLATE_LANCZOS)
	# Keep the glyph's coverage as alpha, in the rim colour.
	var data := shape.get_data()
	var r := color.r8
	var g := color.g8
	var b := color.b8
	for i in range(0, data.size(), 4):
		data[i] = r; data[i + 1] = g; data[i + 2] = b
	return Image.create_from_data(shape.get_width(), shape.get_height(), false, Image.FORMAT_RGBA8, data)
