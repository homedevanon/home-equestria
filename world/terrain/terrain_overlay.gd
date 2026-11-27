extends RefCounted
## Published sculpt heights and biome control bits share a one-byte coverage mask.
## Older extensions and other image formats use the original per-pixel path.
const PARALLEL_OVERLAYS := true
static var _native := PARALLEL_OVERLAYS and ClassDB.class_exists(&"PonyTerrainOverlay") and ClassDB.class_has_method(&"PonyTerrainOverlay", &"apply") and not ("--terrain-overlays=script" in OS.get_cmdline_user_args())
static var peak_threads := 0

static func apply(map: Image, bytes: PackedByteArray, coverage: Image, bounds: Rect2i, painted: Image = null) -> bool:
	if _native:
		var threads: int = ClassDB.class_call_static(&"PonyTerrainOverlay", &"apply", map, bytes, coverage, bounds, painted)
		if threads > 0:
			peak_threads = maxi(peak_threads, threads)
			return true
	var saved := Image.create_from_data(map.get_width(), map.get_height(), false, Image.FORMAT_RF, bytes)
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			if coverage.get_pixel(x, y).r <= 0: continue
			var pixel := saved.get_pixel(x, y)
			if painted != null:
				if not is_finite(pixel.r): return false
				painted.set_pixel(x, y, Color.WHITE)
			map.set_pixel(x, y, pixel)
	return true
