extends RefCounted
## Per-biome season response (M-SEA-02, W1-SEAS-A 2026-11-08): one RGBA8 texel per 32 m over the
## whole biome field, baked once from world/biomes/presets.json and the biome weights
## (world/biomes/biome_field.gd), cached in BAKED. Channels: R snow susceptibility, G deciduous
## share (autumn colour and leaf fall), B wetness response (wet ground, rain odds), A ice allowed.
## Default: no snow, no autumn orange and no ice in Desert, Badlands, Jungle and Coast; the desert
## barely gets wet (design decision D-06/D8 may give them a light frost later). A preset may carry
## its own "climate": [r, g, b, a] row, which wins over the table below.
##
## Runtime reads the cached Image only (never bakes: the bake walks every biome tile, seconds of
## work). Bake: tools/seasons/test_climate_map.gd --bake (or ClimateMap.bake_to_file()). The
## season_climate_map / season_climate_rect globals are set by season_state.gd. Without the baked
## file every channel reads 1 (the old behaviour) on the GPU and on the CPU.
const BAKED := "res://world/seasons/baked/climate.res"
const PRESETS := "res://world/biomes/presets.json"
const FIELD := preload("res://world/biomes/biome_field.gd")
## 32 m texels over the biome field's tiles (x -8..9, z -8..5 of 1024 m: 18432 x 14336 m). The
## design said 512 x 512; that is 16384 m and would cut the east and west edges off, so the map
## keeps 32 m per texel and grows to 576 x 448 (1.0 MB, the same budget).
const TEXEL := 32.0
const ORIGIN := Vector2(-8192.0, -8192.0)
const SIZE := Vector2i(576, 448)
## [snow, deciduous, wet, ice] by preset key.
const BY_KEY := {
	"sea": [0.0, 0.0, 0.0, 0.0],
	"plain": [1.0, 1.0, 1.0, 1.0],
	"forest": [1.0, 1.0, 1.0, 1.0],
	"dark_forest": [1.0, 0.85, 1.0, 1.0],
	"desert": [0.0, 0.0, 0.15, 0.0],
	"badlands": [0.0, 0.0, 0.3, 0.0],
	"mountain": [1.0, 0.3, 0.8, 1.0],
	"snow": [1.0, 0.0, 0.5, 1.0],
	"swamp": [1.0, 0.7, 1.0, 1.0],
	"jungle": [0.0, 0.0, 1.0, 0.0],
	"hills": [1.0, 1.0, 1.0, 1.0],
	"crystal": [1.0, 0.0, 0.6, 1.0],
	"coast": [0.0, 0.0, 0.8, 0.0],
}

static var _image: Image
static var _texture: ImageTexture
static var _tried := false

static func rect() -> Rect2:
	return Rect2(ORIGIN, Vector2(SIZE) * TEXEL)

## The cached map, or null when it was never baked.
static func image() -> Image:
	if not _tried:
		_tried = true
		var loaded: Resource = load(BAKED) if ResourceLoader.exists(BAKED) else null
		if loaded is Image and (loaded as Image).get_size() == SIZE:
			_image = loaded as Image
			if _image.get_format() != Image.FORMAT_RGBA8: _image.convert(Image.FORMAT_RGBA8)
		elif loaded != null:
			push_warning("climate_map: %s is not a %dx%d image; bake it again" % [BAKED, SIZE.x, SIZE.y])
	return _image

static func texture() -> Texture2D:
	if _texture == null and image() != null: _texture = ImageTexture.create_from_image(_image)
	return _texture

## The shader rect (origin x, origin z, size x, size z); zero size when nothing is baked.
static func shader_rect() -> Vector4:
	if image() == null: return Vector4.ZERO
	var r := rect()
	return Vector4(r.position.x, r.position.y, r.size.x, r.size.y)

## Forgets the cached map (after a bake, or in tests).
static func reload() -> void:
	_image = null; _texture = null; _tried = false

## Bilinear CPU read of one channel (0 R snow, 1 G deciduous, 2 B wet, 3 A ice) at a world x/z,
## matching the shader's season_climate(). 1.0 without a baked map.
static func sample(xz: Vector2, channel: int) -> float:
	var im := image()
	if im == null: return 1.0
	var grid := ((xz - ORIGIN) / TEXEL - Vector2(0.5, 0.5)).clamp(Vector2.ZERO, Vector2(SIZE - Vector2i.ONE))
	var cell := Vector2i(floori(grid.x), floori(grid.y))
	var f := grid - Vector2(cell)
	var right := mini(cell.x + 1, SIZE.x - 1)
	var down := mini(cell.y + 1, SIZE.y - 1)
	var a: float = im.get_pixel(cell.x, cell.y)[channel]
	var b: float = im.get_pixel(right, cell.y)[channel]
	var c: float = im.get_pixel(cell.x, down)[channel]
	var d: float = im.get_pixel(right, down)[channel]
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)

## The nearest texel (no filtering), for tests.
static func texel_at(xz: Vector2) -> Color:
	var im := image()
	if im == null: return Color(1, 1, 1, 1)
	var p := ((xz - ORIGIN) / TEXEL).floor()
	return im.get_pixel(clampi(int(p.x), 0, SIZE.x - 1), clampi(int(p.y), 0, SIZE.y - 1))

## [snow, deciduous, wet, ice] per biome id, from presets.json ("climate" overrides the table).
static func responses(presets: Array) -> Array:
	var rows: Array = []
	rows.resize(FIELD.COUNT)
	for i in FIELD.COUNT: rows[i] = [1.0, 1.0, 1.0, 1.0]
	for preset: Variant in presets:
		if not preset is Dictionary: continue
		var id := int((preset as Dictionary).get("id", -1))
		if id < 0 or id >= FIELD.COUNT: continue
		var own: Variant = (preset as Dictionary).get("climate")
		if own is Array and (own as Array).size() == 4:
			rows[id] = [float(own[0]), float(own[1]), float(own[2]), float(own[3])]
		else:
			rows[id] = (BY_KEY.get(str((preset as Dictionary).get("key", "")), [1.0, 1.0, 1.0, 1.0]) as Array).duplicate()
	return rows

## Bakes the whole map from a biome field (a fresh one by default). Each texel averages four
## 4 m cells; tiles are walked one at a time so the field's tile cache stays warm.
static func bake(field: RefCounted = null) -> Image:
	if field == null: field = FIELD.new()
	var rows := responses(field.get("presets"))
	var out := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	var per_tile := int(float(FIELD.REGION) / TEXEL)   # texels per 1024 m biome tile
	for ty in range(0, SIZE.y, per_tile):
		for tx in range(0, SIZE.x, per_tile):
			for y in range(ty, mini(ty + per_tile, SIZE.y)):
				for x in range(tx, mini(tx + per_tile, SIZE.x)):
					var sum := Color(0, 0, 0, 0)
					for cell: Vector2i in sample_cells(Vector2i(x, y)):
						sum += _response(field.cell_weights(cell), rows)
					out.set_pixel(x, y, sum * 0.25)
	return out

## The four 4 m biome cells a texel averages (quarter points of the texel).
static func sample_cells(texel: Vector2i) -> Array[Vector2i]:
	var per := int(TEXEL / FIELD.CELL)
	var base := Vector2i(floori(ORIGIN.x / FIELD.CELL), floori(ORIGIN.y / FIELD.CELL)) + texel * per
	return [base + Vector2i(per / 4, per / 4), base + Vector2i(per * 3 / 4, per / 4),
		base + Vector2i(per / 4, per * 3 / 4), base + Vector2i(per * 3 / 4, per * 3 / 4)]

static func _response(weights: PackedFloat32Array, rows: Array) -> Color:
	var total := 0.0
	var c := Color(0, 0, 0, 0)
	for i in mini(weights.size(), rows.size()):
		var w := weights[i]
		if w <= 0.0: continue
		var row: Array = rows[i]
		c.r += w * float(row[0]); c.g += w * float(row[1]); c.b += w * float(row[2]); c.a += w * float(row[3])
		total += w
	if total <= 0.0: return Color(1, 1, 1, 1)
	return Color(c.r / total, c.g / total, c.b / total, c.a / total)

## Bakes and writes BAKED; returns the error code.
static func bake_to_file(field: RefCounted = null) -> Error:
	var im := bake(field)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BAKED.get_base_dir()))
	var err := ResourceSaver.save(im, BAKED, ResourceSaver.FLAG_COMPRESS)
	reload()
	return err
