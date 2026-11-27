extends RefCounted
## Baked walk-grid chunks shipped with the game (perf overhaul 2026-11-21, lane walk_grid).
##
## tools/navigation/bake_walk_grid.gd samples a town's chunks offline through the run-time sampler
## and writes res://world/navigation/baked/<zone>.wgb. WalkGridService uses a baked chunk only
## when its key (walk_grid_keys.gd) equals the key the player's own world gives that chunk, so a
## placed house, a mod's building or a sculpted hill makes exactly those chunks sample as before.
##
## File: "WGB1", u32 format, u32 key version, u32 index length, index (var_to_bytes of
## {coords: PackedInt32Array x,z pairs, keys: PackedStringArray, derive_keys: PackedStringArray,
## offsets: PackedInt64Array, sizes: PackedInt32Array}), then one zstd blob per chunk: floor_y,
## slope_deg, water_depth, headroom, flags, paint_cost, trail_weight back to back.
## Format 2 stores each chunk painted (as WalkGridService publishes it) with the key of that paint
## (derive_keys); a player whose map paint or trail textures differ gets the sampled arrays back
## by strip_paint() and paints them. Format 1 (sampled, no derive keys) is still read.
const MAGIC := "WGB1"
const FORMAT := 2
const DIR := "res://world/navigation/baked"
const SLOTS := WalkGrid.CHUNK_CELLS * WalkGrid.CHUNK_CELLS * WalkGrid.SPANS
const COLUMNS := WalkGrid.CHUNK_CELLS * WalkGrid.CHUNK_CELLS
## Raw size of one chunk: three float arrays, three byte arrays per slot, one byte per column.
const RAW_SIZE := SLOTS * 4 * 3 + SLOTS * 3 + COLUMNS


static func path_for(zone_id: String) -> String:
	return DIR.path_join(zone_id + ".wgb")


static func pack(chunk: WalkChunk) -> PackedByteArray:
	var raw := PackedByteArray()
	raw.append_array(chunk.floor_y.to_byte_array())
	raw.append_array(chunk.slope_deg)
	raw.append_array(chunk.water_depth.to_byte_array())
	raw.append_array(chunk.headroom.to_byte_array())
	raw.append_array(chunk.flags)
	raw.append_array(chunk.paint_cost)
	var trail := chunk.trail_weight
	if trail.size() != SLOTS:
		trail = PackedByteArray(); trail.resize(SLOTS)
	raw.append_array(trail)
	return raw.compress(FileAccess.COMPRESSION_ZSTD)


static func unpack(coord: Vector2i, blob: PackedByteArray) -> WalkChunk:
	var raw := blob.decompress(RAW_SIZE, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != RAW_SIZE: return null
	var chunk := WalkChunk.new()
	chunk.coord = coord
	var at := 0
	chunk.floor_y = raw.slice(at, at + SLOTS * 4).to_float32_array(); at += SLOTS * 4
	chunk.slope_deg = raw.slice(at, at + SLOTS); at += SLOTS
	chunk.water_depth = raw.slice(at, at + SLOTS * 4).to_float32_array(); at += SLOTS * 4
	chunk.headroom = raw.slice(at, at + SLOTS * 4).to_float32_array(); at += SLOTS * 4
	chunk.flags = raw.slice(at, at + SLOTS); at += SLOTS
	chunk.paint_cost = raw.slice(at, at + COLUMNS); at += COLUMNS
	chunk.trail_weight = raw.slice(at, at + SLOTS)
	return chunk


## The sampled arrays of a painted chunk: painting only sets the PAINT_* flag bits, the trail
## weights and the paint costs, which sampling leaves clear, empty and at PAINT_SCALE.
static func strip_paint(chunk: WalkChunk) -> void:
	var flags := chunk.flags
	for slot in flags.size():
		flags[slot] = flags[slot] & ~(WalkGrid.PAINT_BLOCK | WalkGrid.PAINT_TRAIL | WalkGrid.PAINT_FORD)
	chunk.flags = flags
	chunk.trail_weight.fill(0)
	chunk.paint_cost.fill(int(WalkGrid.PAINT_SCALE))


## entries: Array of [coord: Vector2i, key: String, blob: PackedByteArray, derive_key: String].
## Returns bytes written.
static func write(path: String, key_version: int, entries: Array) -> int:
	var coords := PackedInt32Array()
	var keys := PackedStringArray()
	var derive_keys := PackedStringArray()
	var offsets := PackedInt64Array()
	var sizes := PackedInt32Array()
	var offset := 0
	for entry: Array in entries:
		var c: Vector2i = entry[0]
		coords.append(c.x); coords.append(c.y)
		keys.append(str(entry[1]))
		derive_keys.append(str(entry[3]) if entry.size() > 3 else "")
		offsets.append(offset)
		sizes.append((entry[2] as PackedByteArray).size())
		offset += (entry[2] as PackedByteArray).size()
	var index := var_to_bytes({"coords": coords, "keys": keys, "derive_keys": derive_keys, "offsets": offsets, "sizes": sizes})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return -1
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_32(FORMAT); f.store_32(key_version); f.store_32(index.size())
	f.store_buffer(index)
	for entry: Array in entries: f.store_buffer(entry[2])
	var total := f.get_length()
	f.close()
	return total


## {coord: [key, absolute offset, size, derive key ("" in format 1)]} or {} when the file is
## missing, foreign or of another key version.
static func read_index(path: String, key_version: int) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return {}
	if f.get_buffer(4).get_string_from_ascii() != MAGIC: return {}
	var format := f.get_32()
	if format < 1 or format > FORMAT or f.get_32() != key_version: return {}
	var length := f.get_32()
	var parsed: Variant = bytes_to_var(f.get_buffer(length))
	var base := 16 + length
	f.close()
	if not parsed is Dictionary: return {}
	var index: Dictionary = parsed
	var coords: PackedInt32Array = index.get("coords", PackedInt32Array())
	var keys: PackedStringArray = index.get("keys", PackedStringArray())
	var offsets: PackedInt64Array = index.get("offsets", PackedInt64Array())
	var sizes: PackedInt32Array = index.get("sizes", PackedInt32Array())
	var derive_keys: PackedStringArray = index.get("derive_keys", PackedStringArray())
	var out := {}
	for i in keys.size():
		out[Vector2i(coords[i * 2], coords[i * 2 + 1])] = [keys[i], base + offsets[i], sizes[i], derive_keys[i] if i < derive_keys.size() else ""]
	return out


## One chunk by its index entry (any thread).
static func load_chunk(path: String, coord: Vector2i, entry: Array) -> WalkChunk:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return null
	f.seek(int(entry[1]))
	var blob := f.get_buffer(int(entry[2]))
	f.close()
	return unpack(coord, blob)
