extends RefCounted
## Painting save state (docs/PAINTING_STATION_2026_10_22.md section 8), in the style of
## world/books/book_library.gd: which work-in-progress PNG each easel shows, and the labels of
## finished paintings ("art:<id>" items). The images are write-once files under
## <world>/paintings/; this keeps only pointers and labels, saved in paintings.json and in each
## checkpoint under the additive "paintings" key.
##
## Always loaded (item catalogue, saves, game), so it preloads nothing of the painting runtime:
## easels and runtimes are reached only by load() and duck-typed calls.
const SAVE_FILE = preload("res://world/save_file.gd")
const VERSION := 1
const MAX_ENTRIES := 512
const MAX_LABEL := 80
## A finished picture is a painting unless its row says otherwise: "photo" for the photo camera's
## prints (world/items/photo_camera.gd), which show as a small print instead of a framed canvas.
const KIND_PHOTO := "photo"
## Empty canvas cells, flattened (the same value as the core's painting_io.EMPTY_COLOR).
const CANVAS_COLOR := Color8(242, 238, 228)
## Easel roots (easel_build.gd) join this group so a load or restore can refresh their faces.
const EASEL_GROUP := &"painting_easels"
const EASEL_BUILD := "res://world/painting/easel_build.gd"
static var _dir := ""
static var _state := {"version": VERSION, "wip": {}, "art": {}}
static var _live: Array[WeakRef] = []
static var _serial := 0
static var _tasks: Array[int] = []

## The paintings of one world live beside its books.json.
static func open_world(world_dir: String) -> void:
	_dir = world_dir.path_join("paintings") if not world_dir.is_empty() else ""
	_state = _empty()
	if not _dir.is_empty():
		var value: Variant = SAVE_FILE.parse(_dir.path_join("paintings.json"))
		if valid_state(value): _state = _clean(value)
	_refresh_easels()

static func snapshot() -> Dictionary:
	return _state.duplicate(true)

static func valid_state(value: Variant) -> bool:
	if not value is Dictionary: return false
	var doc: Dictionary = value
	if doc.has("version") and not ((doc.version is int or doc.version is float) and int(doc.version) == VERSION): return false
	var wips: Variant = doc.get("wip", {})
	var arts: Variant = doc.get("art", {})
	if not wips is Dictionary or not arts is Dictionary: return false
	if (wips as Dictionary).size() > MAX_ENTRIES or (arts as Dictionary).size() > MAX_ENTRIES: return false
	for key: Variant in wips:
		var row: Variant = wips[key]
		if not key is String or not valid_key(key) or not row is Dictionary: return false
		if not valid_file(row.get("file")) or not row.get("orient") in ["P", "L"]: return false
		var colours: Variant = row.get("label", "")
		if not colours is String or (colours as String).length() > MAX_LABEL: return false
	for id: Variant in arts:
		var row: Variant = arts[id]
		if not id is String or not valid_art_id(id) or not row is Dictionary: return false
		if not row.get("orient") in ["P", "L"]: return false
		var label: Variant = row.get("label", "")
		if not label is String or (label as String).length() > MAX_LABEL: return false
		if row.has("kind") and row.get("kind") != KIND_PHOTO: return false
		if row.has("printed") and not row.get("printed") is bool: return false
	var bare: Variant = doc.get("bare", {})
	if not bare is Dictionary or (bare as Dictionary).size() > MAX_ENTRIES: return false
	for key: Variant in bare:
		if not key is String or not valid_key(key) or not bare[key] is bool: return false
	return true

## A slot's own pointers and labels replace the current ones; the images are shared files.
static func restore(value: Dictionary) -> bool:
	if not valid_state(value): return false
	var next := _clean(value)
	if not _dir.is_empty() and SAVE_FILE.write(_dir.path_join("paintings.json"), next) != OK: return false
	# A session open on the old state ends without writing over the restored pointers.
	for ref: WeakRef in _live:
		var runtime: Variant = ref.get_ref()
		if is_instance_valid(runtime): runtime.call("close", false)
	_live.clear()
	_state = next
	_refresh_easels()
	return true

static func wip(key: String) -> Dictionary:
	return (_state.wip.get(key, {}) as Dictionary).duplicate()

## `label` is the picture's main colours ("mostly red and blue") for the easel's ai_label.
static func set_wip(key: String, file: String, orient: String, label: String = "") -> void:
	if not valid_key(key) or not valid_file(file) or not orient in ["P", "L"]: return
	if not _state.wip.has(key) and _state.wip.size() >= MAX_ENTRIES: return
	_state.wip[key] = {"file": file, "orient": orient}
	if not label.is_empty(): _state.wip[key].label = label.left(MAX_LABEL)
	_write()

static func clear_wip(key: String) -> void:
	if _state.wip.erase(key): _write()

## An owned easel's unfinished picture is kept under its loan token, which ends when the folded
## easel goes into the briefcase. Unfolding an easel with no picture of its own adopts the newest
## picture of an easel whose loan is gone (bagged easels are interchangeable units), so the
## picture travels with the easel and orphaned rows do not pile up.
static func adopt_carried_wip(token: String, loans: Dictionary) -> void:
	var key := "easel:" + token
	if not valid_key(key) or _state.wip.has(key): return
	var best := ""
	var newest := ""
	for other: String in _state.wip:
		if not other.begins_with("easel:") or loans.has(other.substr(6)): continue
		var file := str(_state.wip[other].file)
		if best.is_empty() or file > newest: best = other; newest = file
	if best.is_empty():
		# No picture to carry: an emptied easel (its canvas taken off and none put up) stays empty
		# when it is folded and unfolded again (M-ACT-03 bought canvases).
		var bare: Variant = _state.get("bare")
		var keys: Array = (bare as Dictionary).keys() if bare is Dictionary else []
		for other: String in keys:
			if other.begins_with("easel:") and not loans.has(other.substr(6)):
				_bare().erase(other)
				_bare()[key] = true
				_write()
				return
		return
	_state.wip[key] = _state.wip[best]
	_state.wip.erase(best)
	_write()

## Unique per process and time; files are write-once, so a name is never reused.
static func new_serial() -> String:
	_serial = (_serial + 1) % 10000
	var serial := "%d-%04d" % [int(Time.get_unix_time_from_system()), _serial]
	while not _dir.is_empty() and FileAccess.file_exists(path("wip_%s.png" % serial)):
		_serial = (_serial + 1) % 10000
		serial = "%d-%04d-%d" % [int(Time.get_unix_time_from_system()), _serial, randi() % 1000]
	return serial

## Bought canvases (M-ACT-03, docs/PAINTING_STATION_2026_10_22.md section 13): an owned easel
## whose finished painting was taken off stands empty until Anon puts a blank canvas ("goods:canvas")
## up on it (easel_wake.gd). The Balloon Hill station always has canvases. The rule is on while the
## shop sells canvases (the item exists in the catalogue); `canvas_rule` 1/0 forces it for tests.
const CANVAS_ITEM := "goods:canvas"
static var canvas_rule := -1

static func canvases_bought() -> bool:
	if canvas_rule >= 0: return canvas_rule == 1
	var catalog: Script = load("res://world/inventory/item_catalog.gd") as Script
	return catalog != null and bool(catalog.call("has", CANVAS_ITEM))

## True when this easel needs a bought canvas after its painting comes off.
static func needs_bought_canvas(key: String) -> bool:
	return key.begins_with("easel:") and canvases_bought()

static func is_bare(key: String) -> bool:
	var bare: Variant = _state.get("bare")
	return bare is Dictionary and bool((bare as Dictionary).get(key, false))

static func set_bare(key: String, bare: bool) -> void:
	if not valid_key(key) or bare == is_bare(key): return
	if bare:
		if _bare().size() >= MAX_ENTRIES: return
		_bare()[key] = true
	else: _bare().erase(key)
	if _bare().is_empty(): _state.erase("bare")
	_write()

static func _bare() -> Dictionary:
	if not _state.get("bare") is Dictionary: _state["bare"] = {}
	return _state["bare"]

static func add_art(id: String, orient: String, label: String, kind: String = "") -> void:
	if not valid_art_id(id) or not orient in ["P", "L"]: return
	if not _state.art.has(id) and _state.art.size() >= MAX_ENTRIES: return
	_state.art[id] = {"orient": orient, "label": label.left(MAX_LABEL)}
	if kind == KIND_PHOTO:
		_state.art[id].kind = KIND_PHOTO
		_state.art[id].printed = false
	_write()

static func is_photo(id: String) -> bool:
	return str((_state.art.get(id, {}) as Dictionary).get("kind", "")) == KIND_PHOTO

## Every photo of this world, newest first (ids start with their hex time).
static func photos() -> Array[String]:
	var found: Array[String] = []
	for id: String in _state.art:
		if is_photo(id): found.append(id)
	found.sort()
	found.reverse()
	return found

## A photo prints once from the journal. Photos from before the journal came with their print.
static func can_print(id: String) -> bool:
	return is_photo(id) and not bool((_state.art[id] as Dictionary).get("printed", true))

static func mark_printed(id: String) -> void:
	if not is_photo(id): return
	_state.art[id].printed = true
	_write()

static func art(id: String) -> Dictionary:
	return (_state.art.get(id, {}) as Dictionary).duplicate()

static func is_art(item_id: String) -> bool:
	return item_id.begins_with("art:") and valid_art_id(item_id.substr(4))

static func art_id(item_id: String) -> String:
	return item_id.substr(4) if is_art(item_id) else ""

## The file's path in this world's painting folder ("" when no world is open).
static func path(file: String) -> String:
	return _dir.path_join(file) if not _dir.is_empty() else ""

static func art_path(id: String) -> String:
	return path("art_%s.png" % id) if valid_art_id(id) else ""

## Live runtimes (easel_runtime.gd) are only held weakly and only asked for checkpoint_image().
static func register_live(runtime: Object) -> void:
	unregister_live(runtime)
	_live.append(weakref(runtime))

static func unregister_live(runtime: Object) -> void:
	var kept: Array[WeakRef] = []
	for ref: WeakRef in _live:
		var other: Variant = ref.get_ref()
		if is_instance_valid(other) and other != runtime: kept.append(ref)
	_live = kept

## Before a checkpoint: every open session stores its current picture (a copy taken here; the
## flatten, encode and write run on a worker) and points its easel at it.
static func flush_live() -> void:
	for ref: WeakRef in _live.duplicate():
		var runtime: Variant = ref.get_ref()
		if not is_instance_valid(runtime): continue
		var shot: Variant = runtime.call("checkpoint_image")
		if not shot is Dictionary or (shot as Dictionary).is_empty(): continue
		var image: Variant = shot.get("image")
		if image is Image and write_png(image, str(shot.get("file", ""))):
			set_wip(str(shot.get("key", "")), str(shot.get("file", "")), str(shot.get("orient", "P")), str(shot.get("label", "")))

## Flattens a canvas image copy (empty cells become CANVAS_COLOR, RGB8) and writes it to `file`
## in this world's folder on a WorkerThreadPool task (tmp file, then rename). False when there is
## no world folder or the name is not a painting file.
static func write_png(canvas_copy: Image, file: String) -> bool:
	if _dir.is_empty() or canvas_copy == null or canvas_copy.is_empty(): return false
	if not (valid_file(file) or (file.begins_with("art_") and file.ends_with(".png") and valid_art_id(file.trim_prefix("art_").trim_suffix(".png")))): return false
	_collect()
	_tasks.append(WorkerThreadPool.add_task(_write_png_task.bind(canvas_copy, ProjectSettings.globalize_path(path(file))), false, "Painting PNG"))
	return true

## Empty cells (alpha 0) become CANVAS_COLOR; RGB8. Changes `canvas_copy`'s format only.
static func flatten(canvas_copy: Image) -> Image:
	var flat := Image.create_empty(canvas_copy.get_width(), canvas_copy.get_height(), false, Image.FORMAT_RGBA8)
	flat.fill(CANVAS_COLOR)
	if canvas_copy.get_format() != Image.FORMAT_RGBA8: canvas_copy.convert(Image.FORMAT_RGBA8)
	flat.blend_rect(canvas_copy, Rect2i(Vector2i.ZERO, canvas_copy.get_size()), Vector2i.ZERO)
	flat.convert(Image.FORMAT_RGB8)
	return flat

static func _write_png_task(canvas_copy: Image, target: String) -> void:
	var bytes := flatten(canvas_copy).save_png_to_buffer()
	if bytes.is_empty(): return
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK: return
	var file := FileAccess.open(target + ".tmp", FileAccess.WRITE)
	if file == null: return
	file.store_buffer(bytes); file.flush()
	var failed := file.get_error() != OK
	file.close()
	if not failed: DirAccess.rename_absolute(target + ".tmp", target)

## A finished painting's colour names from the 4961-name table, on a worker (loading the table
## and reading every cell would stall a VR frame): its row and the item's ai_label change when
## done. The scripts go as paths (easel_runtime.gd's static label_of, the colour-name table and
## the paints), so nothing is preloaded and the task holds no Script past engine shutdown.
static func name_art_later(id: String, image: Image, labeller: String, names: String, pigments: String, item: Node) -> void:
	if not valid_art_id(id) or image == null: return
	_collect()
	var target: Variant = weakref(item) if is_instance_valid(item) else null
	_tasks.append(WorkerThreadPool.add_task(_name_art_task.bind(id, image, labeller, names, pigments, target), false, "Painting label"))

static func _name_art_task(id: String, image: Image, labeller: String, names: String, pigments: String, item: Variant) -> void:
	var script := load(labeller) as Script
	if script == null: return
	var label := str(script.call("label_of", image, load(names) as Script, load(pigments) as Script))
	_apply_art_label.call_deferred(id, label, item)

static func _apply_art_label(id: String, label: String, item: Variant) -> void:
	if label.is_empty() or not _state.art.has(id): return
	_state.art[id].label = label.left(MAX_LABEL)
	_write()
	var node: Variant = (item as WeakRef).get_ref() if item is WeakRef else null
	if not node is Node or not is_instance_valid(node): return
	var nodes: Array[Node] = [node as Node]
	nodes.append_array((node as Node).get_children())
	for at: Node in nodes:
		if at.has_meta("ai_id") and str(at.get_meta("ai_id")) == "painting:" + id:
			at.set_meta("ai_label", "a painting by Anon (%s)" % label.left(MAX_LABEL))

## Waits for every PNG write still running (tests and quit paths).
static func finish_writes() -> void:
	for task: int in _tasks: WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()

static func _collect() -> void:
	for task: int in _tasks.duplicate():
		if WorkerThreadPool.is_task_completed(task):
			WorkerThreadPool.wait_for_task_completion(task); _tasks.erase(task)

static func valid_key(key: String) -> bool:
	var rest := ""
	if key.begins_with("station:"): rest = key.substr(8)
	elif key.begins_with("easel:"): rest = key.substr(6)
	else: return false
	return rest.length() >= 1 and rest.length() <= 96 and _only(rest, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-")

static func valid_file(file: Variant) -> bool:
	if not file is String or not (file as String).begins_with("wip_") or not (file as String).ends_with(".png"): return false
	var middle: String = (file as String).substr(4, (file as String).length() - 8)
	return middle.length() >= 1 and middle.length() <= 40 and _only(middle, "0123456789abcdefghijklmnopqrstuvwxyz-")

static func valid_art_id(id: String) -> bool:
	return id.length() >= 6 and id.length() <= 40 and _only(id, "0123456789abcdef-")

static func _only(text: String, allowed: String) -> bool:
	for c in text:
		if not c in allowed: return false
	return true

static func _empty() -> Dictionary:
	return {"version": VERSION, "wip": {}, "art": {}}

static func _clean(value: Dictionary) -> Dictionary:
	var next := _empty()
	var wips: Dictionary = value.get("wip", {})
	var arts: Dictionary = value.get("art", {})
	for key: String in wips:
		next.wip[key] = {"file": str(wips[key].file), "orient": str(wips[key].orient)}
		if not str(wips[key].get("label", "")).is_empty(): next.wip[key].label = str(wips[key].label)
	for id: String in arts:
		next.art[id] = {"orient": str(arts[id].orient), "label": str(arts[id].get("label", ""))}
		if str(arts[id].get("kind", "")) == KIND_PHOTO: next.art[id].kind = KIND_PHOTO
		if arts[id].has("printed"): next.art[id].printed = bool(arts[id].printed)
	var bare: Variant = value.get("bare", {})
	if bare is Dictionary and not (bare as Dictionary).is_empty():
		next["bare"] = {}
		for key: String in bare:
			if bool(bare[key]): next.bare[key] = true
	return next

static func _write() -> void:
	if not _dir.is_empty(): SAVE_FILE.write(_dir.path_join("paintings.json"), _state)

static func _refresh_easels() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null: return
	var easels: Array[Node] = tree.get_nodes_in_group(EASEL_GROUP)
	if easels.is_empty(): return
	var build: Script = load(EASEL_BUILD) as Script
	if build == null: return
	for easel: Node in easels: build.call("refresh_canvas", easel)
