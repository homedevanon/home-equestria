extends RefCounted
## Source mesh and texture data read once per session (W1-PERF-HITCH, 2026-11-08).
##
## Mesh.surface_get_arrays, ArrayMesh "_surfaces" and Texture2D.get_image read the data back from
## the GPU (Forward+ keeps no CPU copy: each call is a full GPU sync) and decode it on the main
## thread. Every identity's near and far mesh gather (hybrid_near_mesh.gd, hybrid_far_mesh.gd) read
## the same imported body, head and hair meshes and the same coat textures again: the 90-250 ms
## gather frames in the bench logs and part of the 1.4 s after a spawn.
##
## Only resources loaded from a file are kept (`resource_path` set): ponies share them and nothing
## edits them in place. Meshes and textures built at runtime (fitted marks, snouts, lids, tail
## anchors) are read as before and never stored, so the cache cannot grow with the crowd.
## Only what a second identity reads is kept: most hair meshes and coat textures belong to one
## pony, and keeping every read held ~220 MB on the bench world (headless census, 2026-11-08);
## the shared body, head and eye data is what the next identity reads again. Gathers name their
## identity with `begin()`; the near and far gathers of one identity count as one reader.
## Callers must not modify what these return; duplicate first (an Array shallowly: its packed
## arrays copy on write). Main thread only. `clear()` at world teardown
## (hybrid_near_mesh.gd discard_pending).
static var _arrays: Dictionary = {}   # "<mesh instance id>:<surface>" -> Array
static var _stored: Dictionary = {}   # mesh instance id -> Array (ArrayMesh "_surfaces")
static var _images: Dictionary = {}   # texture instance id -> Image
static var _first: Dictionary = {}    # "<kind>:<key>" -> identity that read it first (not kept)
static var _reader := ""
## Set false to compare against the uncached reads (tools/profile/test_hitch_sources.gd).
static var enabled := true

static func _shared(resource: Resource) -> bool:
	return enabled and resource != null and not resource.resource_path.is_empty()

## The identity whose gather reads next (hybrid_near_mesh.gd and hybrid_far_mesh.gd _gather).
static func begin(identity: String) -> void:
	_reader = identity

## True when another identity read `key` before: the data is shared, keep it.
static func _keep(key: String) -> bool:
	var first: Variant = _first.get(key)
	if first == null:
		_first[key] = _reader
		return false
	return str(first) != _reader

## mesh.surface_get_arrays(surface), read once for a shared mesh.
static func arrays(mesh: Mesh, surface: int) -> Array:
	if not _shared(mesh): return mesh.surface_get_arrays(surface)
	var key := "%d:%d" % [mesh.get_instance_id(), surface]
	var found: Variant = _arrays.get(key)
	if found == null:
		found = mesh.surface_get_arrays(surface)
		if _keep("a:" + key): _arrays[key] = found
	return found

## The ArrayMesh's stored surfaces (the saved-resource layout, `mesh.get("_surfaces")`), read once.
static func stored(mesh: ArrayMesh) -> Array:
	if not _shared(mesh): return mesh.get("_surfaces")
	var key := mesh.get_instance_id()
	var found: Variant = _stored.get(key)
	if found == null:
		found = mesh.get("_surfaces")
		if _keep("s:%d" % key): _stored[key] = found
	return found

## texture.get_image(), read once for a shared texture.
static func image(texture: Texture2D) -> Image:
	if not _shared(texture): return texture.get_image()
	var key := texture.get_instance_id()
	var found: Variant = _images.get(key)
	if found == null:
		found = texture.get_image()
		if found == null: return null
		if _keep("i:%d" % key): _images[key] = found
	return found

static func clear() -> void:
	_arrays.clear(); _stored.clear(); _images.clear(); _first.clear(); _reader = ""

## Approximate bytes held (diagnostics only; walks every entry).
static func bytes() -> Dictionary:
	var mesh_bytes := 0
	for entry: Array in _arrays.values(): mesh_bytes += _array_bytes(entry)
	var stored_bytes := 0
	for surfaces: Array in _stored.values():
		for surface: Variant in surfaces:
			if surface is Dictionary:
				for value: Variant in (surface as Dictionary).values(): stored_bytes += _value_bytes(value)
	var image_bytes := 0
	for picture: Image in _images.values(): image_bytes += picture.get_data_size()
	return {"surfaces": _arrays.size(), "meshes": _stored.size(), "images": _images.size(),
		"array_mb": snappedf(mesh_bytes / 1048576.0, 0.1), "stored_mb": snappedf(stored_bytes / 1048576.0, 0.1),
		"image_mb": snappedf(image_bytes / 1048576.0, 0.1)}

static func _array_bytes(entry: Array) -> int:
	var total := 0
	for value: Variant in entry: total += _value_bytes(value)
	return total

static func _value_bytes(value: Variant) -> int:
	match typeof(value):
		TYPE_PACKED_BYTE_ARRAY: return (value as PackedByteArray).size()
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY: return value.size() * 4
		TYPE_PACKED_VECTOR2_ARRAY: return value.size() * 8
		TYPE_PACKED_VECTOR3_ARRAY: return value.size() * 12
		TYPE_PACKED_COLOR_ARRAY: return value.size() * 16
		TYPE_ARRAY: return _array_bytes(value)
	return 0
