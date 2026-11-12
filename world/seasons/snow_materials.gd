extends Node
## Seasons WP-C (W2-SEAS-C, M-SEA-14, design 6.2): snow and rain-wetness on roofs, fences, benches
## and props by material swap. Same meshes, same draw calls, no next_pass or overlay.
##
## tools/seasons/build_snow_materials.gd generated one shader per StandardMaterial3D variant the town
## uses (world/seasons/materials/snow_*.gdshader: Godot's own StandardMaterial3D code plus
## season_snow_on()/season_wet(), listed in materials/manifest.json). This node, a child of
## SeasonState (season_state.gd FEATURES), swaps the town's outside materials for ShaderMaterials on
## those shaders while there is snow cover or wetness and 'Seasonal effects' is not Off, and swaps
## every one back when both reach zero or the setting goes Off. The ShaderMaterial carries the
## source's own parameters and texture objects (no copies). Interiors, linings, furniture, windows,
## plants, food and characters are never touched; neither is any ShaderMaterial (interior_surface).
##
## Cost: a 1 Hz check of two floats; a scan spread over frames (SCAN_BUDGET_USEC) when it switches
## on, and while on, nodes entering the tree are queued (node_added) and scanned on the next frame.
## The shaders are warmed by game_loading._warm_up_pipelines: hidden holders under this node carry
## one material per shader from setup on, so the first winter frame compiles nothing.

const CODE := preload("res://world/seasons/materials/standard_code.gd")
const MANIFEST_PATH := "res://world/seasons/materials/manifest.json"
const GROUP := "season_snow_materials"
const TICK := 1.0
const SCAN_BUDGET_USEC := 1500
## Game children whose subtrees hold the town, its props and the railway.
const ROOT_NAMES := ["Zones", "RailNetwork"]
## A node is left alone when its name or an ancestor's (below the scan root) contains one of these.
const EXCLUDE_NODES := ["interior", "room", "lining", "furniture", "inside", "indoor", "bed", "kitchen",
		"window", "glass", "shadow", "warmup", "fooditem", "food_", "edible", "portion", "shopitem",
		"shopdisplay", "pricecard", "outfit", "grass", "foliage", "flower", "daisy", "tree", "bush",
		"water", "river", "skeleton", "door", "ceiling", "floor", "candle", "cloudominium", "curtain",
		"stair", "impostor", "hearth", "cauldron", "dining", "furnish", "usable", "spavenue", "balloon"]
## Removed from a node name before the word test ("OutdoorProps" is not a door, "Streets" not a tree).
const NODE_NAME_KEEP := ["outdoor", "street"]
## A material is left alone when its resource name contains one of these.
const EXCLUDE_MATERIALS := ["glass", "window", "leaf", "leaves", "flower", "bush", "grass", "plant",
		"shroom", "thorn", "daisy", "lupin", "rose", "sunflower", "cypress", "tuft", "balloon",
		"banner", "yellow_light", "bulb", "water", "fire", "food", "candle", "glow", "cloudominium",
		"curtain", "linen", "pillow", "carpet", "rug", "floor", "ceiling", "decke", "inner", "interior",
		"plaster", "wallpaper", "bed", "canopy", "crown", "foliage", "brightgreen", "red_apple",
		"appleleaf", "apples", "flag", "liquid", "sash", "lining"]

enum Slot { OVERRIDE, SURFACE, MESH }

var season_state: Node
## Test hooks: explicit scan roots, and a forced on/off (null = follow the season).
var roots_override: Array[Node] = []
var force: Variant = null
## Build-tool mode (tools/seasons/build_snow_materials.gd): scan and record, swap nothing.
var surveying := false
## Survey result: variant key -> {"variant": Dictionary, "uses": int, "materials": {name: uses}}.
var survey: Dictionary = {}
## True while the season materials are in place.
var active := false
var shaders: Dictionary = {}               # variant key -> Shader
var stats := {"scanned": 0, "swapped": 0, "unsupported": 0, "missing_shader": 0, "restored": 0}

var _snow: Dictionary = {}                 # source material instance id -> ShaderMaterial or null
var _sources: Dictionary = {}              # season material instance id -> source material
var _slots: Array = []                     # [WeakRef target, Slot, index, original, season material]
var _swapped_meshes: Dictionary = {}       # mesh instance id -> true (mesh-level swaps)
var _excluded: Dictionary = {}             # node instance id -> bool
var _root_ids: Dictionary = {}             # scan root instance id -> true
var _compacted_at := 0
var _queue: Array = []
var _incoming: Array = []
var _restoring: Array = []                 # slots still to put back (spread over frames)
var _missing: Dictionary = {}              # source material instance id -> variant key without a shader
var _timer: Timer
var _warmup: Node3D
var _listening := false

func _init() -> void:
	add_to_group(GROUP)
	set_process(false)

func _ready() -> void:
	_load_manifest()

## Season hookup (called by season_state._add_features).
func setup(state: Node) -> void:
	season_state = state
	if shaders.is_empty(): _load_manifest()
	if state != null and state.has_signal("effects_changed") and not state.is_connected("effects_changed", _on_effects_changed):
		state.connect("effects_changed", _on_effects_changed)
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null and quality.has_signal("preset_changed") and not quality.is_connected("preset_changed", _on_preset_changed):
		quality.connect("preset_changed", _on_preset_changed)
	if _roof_snow_allowed(): _add_warmup()
	if _timer == null:
		_timer = Timer.new(); _timer.name = "SnowMaterialsTick"; _timer.wait_time = TICK; _timer.autostart = true
		_timer.timeout.connect(refresh)
		add_child(_timer)

func _exit_tree() -> void:
	if active or not _restoring.is_empty(): deactivate(true)

# ------------------------------------------------------------------ state

## Switches on or off to match the season (also called by the 1 Hz timer).
func refresh() -> void:
	var want := _wanted()
	if want and not active: activate()
	elif not want and active: deactivate()
	elif active and _slots.size() > maxi(256, _compacted_at * 2): _compact()

## Drop the records of nodes that left the tree for good (streamed out) while on.
func _compact() -> void:
	_slots = _slots.filter(func(slot: Array) -> bool: return (slot[0] as WeakRef).get_ref() != null)
	_compacted_at = _slots.size()
	_excluded.clear()

func _wanted() -> bool:
	if force != null: return bool(force)
	if shaders.is_empty() or season_state == null or not is_instance_valid(season_state): return false
	if not _roof_snow_allowed(): return false
	if season_state.has_method("effects_level") and int(season_state.call("effects_level")) <= 0: return false
	var cover := float(season_state.call("snow_cover")) if season_state.has_method("snow_cover") else 0.0
	var wet := float(season_state.call("wetness")) if season_state.has_method("wetness") else 0.0
	return cover > 0.0 or (wet > 0.0 and _quality_flag("wet_surfaces"))

## Quality key `roof_snow` (W2-SEAS-L; off on Very Low / Quest). Missing key = allowed.
func _roof_snow_allowed() -> bool:
	return _quality_flag("roof_snow")

## A W2-SEAS-L bool quality key (`roof_snow`, `wet_surfaces`); no Quality autoload or key = true.
func _quality_flag(key: String) -> bool:
	var quality: Node = get_node_or_null("/root/Quality")
	if quality == null or not quality.has_method("get_value"): return true
	return bool(quality.call("get_value", key, true))

func _on_effects_changed(_level: int) -> void: refresh()

func _on_preset_changed(_preset: int) -> void:
	if _roof_snow_allowed(): _add_warmup()
	refresh()

## Swap every eligible material under the scan roots (spread over frames) and keep new nodes covered.
func activate() -> void:
	if active: return
	_finish_restore()
	active = true
	_excluded.clear()
	_root_ids.clear()
	if not _listening:
		get_tree().node_added.connect(_on_node_added)
		_listening = true
	# Multimeshes first: a shared multi-surface mesh is swapped at mesh level, and mesh instances
	# scanned after it pin their original material where they are excluded (indoors).
	var multimeshes: Array = []
	var instances: Array = []
	for root: Node in _roots():
		multimeshes.append_array(root.find_children("*", "MultiMeshInstance3D", true, false))
		instances.append_array(root.find_children("*", "MeshInstance3D", true, false))
	_queue = _plan_mesh_swaps(multimeshes) + instances
	set_process(true)

## Put every original back. Spread over frames like the scan (the real town has ~2500 swaps, ~12 ms
## in one go); a dry or melted season material already looks exactly like its source, so nothing
## shows. `immediate` restores at once (leaving the tree, tests).
func deactivate(immediate := false) -> void:
	active = false
	if _listening:
		if get_tree() != null and get_tree().node_added.is_connected(_on_node_added): get_tree().node_added.disconnect(_on_node_added)
		_listening = false
	_queue.clear(); _incoming.clear()
	_restoring.append_array(_slots)
	_slots.clear()
	_compacted_at = 0
	_swapped_meshes.clear()
	_snow.clear()
	_sources.clear()
	_missing.clear()
	_excluded.clear()
	if immediate: _finish_restore()
	else: set_process(not _restoring.is_empty())

func _finish_restore() -> void:
	while not _restoring.is_empty(): _restore(_restoring.pop_back())

## Runs only while a scan is pending.
func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	while not _restoring.is_empty() and Time.get_ticks_usec() - started < SCAN_BUDGET_USEC:
		_restore(_restoring.pop_back())
	if not _restoring.is_empty(): return
	while not _queue.is_empty() and Time.get_ticks_usec() - started < SCAN_BUDGET_USEC:
		scan(_queue.pop_back())
	if _queue.is_empty():
		# Nodes added this frame wait one frame: their parents' _ready and deferred setup run first.
		_queue = _incoming
		_incoming = []
		if _queue.is_empty(): set_process(false)

## Finish any pending restore or scan now (tests and loading screens).
func flush() -> void:
	_finish_restore()
	_queue.append_array(_incoming); _incoming.clear()
	while not _queue.is_empty(): scan(_queue.pop_back())
	set_process(false)

func _on_node_added(node: Node) -> void:
	if node is GeometryInstance3D:
		_incoming.append(node)
		if not is_processing(): set_process(true)

func _roots() -> Array[Node]:
	if not roots_override.is_empty(): return roots_override
	var out: Array[Node] = []
	var game: Node = season_state.get("game") as Node if season_state != null and is_instance_valid(season_state) else null
	if game == null or not is_instance_valid(game): return out
	for name: String in ROOT_NAMES:
		var root := game.get_node_or_null(name)
		if root != null: out.append(root)
	return out

# ------------------------------------------------------------------ scanning

## Swap one geometry node's eligible materials (no-op for anything not eligible).
func scan(node: Variant) -> void:
	if not is_instance_valid(node) or not (node as Node).is_inside_tree(): return
	stats.scanned += 1
	if node is MeshInstance3D: _scan_instance(node)
	elif node is MultiMeshInstance3D: _scan_multimesh(node)

func _scan_instance(mi: MeshInstance3D) -> void:
	var mesh := mi.mesh
	if mesh == null: return
	if mi.material_override != null:
		var snow := season_material(mi.material_override)
		if snow != null and not is_excluded(mi): _swap(mi, Slot.OVERRIDE, 0, mi.material_override, snow)
		return
	for s in mesh.get_surface_count():
		var over := mi.get_surface_override_material(s)
		var source := over if over != null else mesh.surface_get_material(s)
		if source == null: continue
		if over == null and _sources.has(source.get_instance_id()):
			# This mesh was swapped at mesh level for a multimesh; indoors keep the original.
			if is_excluded(mi): _swap(mi, Slot.SURFACE, s, null, _sources[source.get_instance_id()])
			continue
		var snow := season_material(source)
		if snow != null and not is_excluded(mi): _swap(mi, Slot.SURFACE, s, over, snow)
		elif snow == null: _note_missing(source, mi)

func _scan_multimesh(mmi: MultiMeshInstance3D) -> void:
	if mmi.material_override != null:
		var snow := season_material(mmi.material_override)
		if snow != null and not is_excluded(mmi): _swap(mmi, Slot.OVERRIDE, 0, mmi.material_override, snow)
		return
	var mesh: Mesh = mmi.multimesh.mesh if mmi.multimesh != null else null
	if mesh == null or mesh.get_surface_count() != 1 or is_excluded(mmi): return
	var snow := season_material(mesh.surface_get_material(0))
	if snow != null: _swap(mmi, Slot.OVERRIDE, 0, null, snow)
	else: _note_missing(mesh.surface_get_material(0), mmi)

## Multi-surface multimesh meshes cannot take a per-node material for one surface: their mesh is
## swapped once, unless an excluded multimesh shares it. Returns the multimeshes still to scan.
func _plan_mesh_swaps(multimeshes: Array) -> Array:
	var users: Dictionary = {}          # mesh id -> [mesh, any excluded user]
	var rest: Array = []
	for node: Variant in multimeshes:
		var mmi := node as MultiMeshInstance3D
		var mesh: Mesh = mmi.multimesh.mesh if mmi.multimesh != null else null
		if mmi.material_override != null or mesh == null or mesh.get_surface_count() < 2:
			rest.append(mmi); continue
		var id := mesh.get_instance_id()
		if not users.has(id): users[id] = [mesh, false]
		if is_excluded(mmi): users[id][1] = true
	for entry: Array in users.values():
		if entry[1]: continue
		var mesh: Mesh = entry[0]
		if not mesh is ArrayMesh: continue
		for s in mesh.get_surface_count():
			var source := mesh.surface_get_material(s)
			var snow := season_material(source) if source != null else null
			if snow != null: _swap(mesh, Slot.MESH, s, source, snow)
		_swapped_meshes[mesh.get_instance_id()] = true
	return rest

## The season material for a source material, or null when it is not converted.
func season_material(source: Material) -> ShaderMaterial:
	if source == null: return null
	var id := source.get_instance_id()
	if _snow.has(id): return _snow[id]
	var snow: ShaderMaterial = null
	if source is StandardMaterial3D and not is_excluded_material(source):
		var v := CODE.variant(source)
		if v.is_empty(): stats.unsupported += 1
		elif surveying:
			snow = ShaderMaterial.new()
			snow.set_meta("season_key", CODE.key(v))
			snow.set_meta("season_variant", v)
			snow.resource_name = source.resource_name
			_sources[snow.get_instance_id()] = source
		else:
			var shader: Shader = shaders.get(CODE.key(v))
			if shader == null: _missing[id] = CODE.key(v)
			else:
				snow = CODE.material_for(source, shader)
				_sources[snow.get_instance_id()] = source
	_snow[id] = snow
	return snow

## An eligible outside material whose variant the manifest lacks (rerun the build tool).
func _note_missing(source: Material, node: Node) -> void:
	if source == null or not _missing.has(source.get_instance_id()) or is_excluded(node): return
	stats.missing_shader += 1
	if OS.is_debug_build() and int(stats.missing_shader) <= 8:
		print("[seasons] no snow shader for %s on %s (rerun tools/seasons/build_snow_materials.gd)" % [source.resource_name, node.name])

## The source behind a season material (tests).
func source_of(material: Material) -> Material:
	return _sources.get(material.get_instance_id()) if material != null else null

static func is_excluded_material(material: Material) -> bool:
	var name := material.resource_name.to_lower()
	for word: String in EXCLUDE_MATERIALS:
		if name.contains(word): return true
	return false

## True when the node or an ancestor below the scan root is indoors, a plant, food, a window...
## Nodes outside every scan root are excluded too. Memoised per node for the scan.
func is_excluded(node: Node) -> bool:
	var id := node.get_instance_id()
	if _excluded.has(id): return _excluded[id]
	if _root_ids.is_empty():
		for root: Node in _roots(): _root_ids[root.get_instance_id()] = true
	var result := false
	if not _root_ids.has(id):
		var parent := node.get_parent()
		if parent == null: result = true
		else:
			var name := String(node.name).to_lower()
			for keep: String in NODE_NAME_KEEP: name = name.replace(keep, "")
			for word: String in EXCLUDE_NODES:
				if name.contains(word): result = true; break
			if not result: result = is_excluded(parent)
	_excluded[id] = result
	return result

func _swap(target: Object, kind: Slot, index: int, original: Material, snow: Material) -> void:
	if surveying:
		if not snow.has_meta("season_key"): return
		var key := str(snow.get_meta("season_key"))
		if not survey.has(key): survey[key] = {"variant": snow.get_meta("season_variant"), "uses": 0, "materials": {}}
		var entry: Dictionary = survey[key]
		entry.uses = int(entry.uses) + 1
		var label := snow.resource_name if snow.resource_name != "" else "(unnamed)"
		entry.materials[label] = int(entry.materials.get(label, 0)) + 1
		return
	match kind:
		Slot.OVERRIDE: (target as GeometryInstance3D).material_override = snow
		Slot.SURFACE: (target as MeshInstance3D).set_surface_override_material(index, snow)
		Slot.MESH: (target as Mesh).surface_set_material(index, snow)
	_slots.append([weakref(target), kind, index, original, snow])
	stats.swapped += 1

## Put one original back, unless something else replaced the season material meanwhile.
func _restore(slot: Array) -> void:
	var target: Object = (slot[0] as WeakRef).get_ref()
	if target == null: return
	var index: int = slot[2]
	var original: Material = slot[3]
	var snow: Material = slot[4]
	match slot[1]:
		Slot.OVERRIDE:
			var g := target as GeometryInstance3D
			if g.material_override == snow: g.material_override = original
		Slot.SURFACE:
			var mi := target as MeshInstance3D
			if mi.mesh != null and index < mi.mesh.get_surface_count() and mi.get_surface_override_material(index) == snow:
				mi.set_surface_override_material(index, original)
		Slot.MESH:
			var mesh := target as Mesh
			if index < mesh.get_surface_count() and mesh.surface_get_material(index) == snow:
				mesh.surface_set_material(index, original)
	stats.restored += 1

## Number of live swaps (tests).
func slot_count() -> int:
	return _slots.size()

# ------------------------------------------------------------------ manifest and warm-up

func _load_manifest() -> void:
	if not shaders.is_empty() or not FileAccess.file_exists(MANIFEST_PATH): return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not parsed is Dictionary: return
	var listed: Variant = (parsed as Dictionary).get("shaders")
	if not listed is Dictionary: return
	for key: String in (listed as Dictionary):
		var path := str(listed[key])
		if not ResourceLoader.exists(path): continue
		var shader: Variant = load(path)
		if shader is Shader: shaders[key] = shader

## One hidden quad per generated shader: game_loading._scene_materials() finds every MeshInstance3D
## material in the tree and the pipeline warm-up draws each once under the loading cover.
func _add_warmup() -> void:
	if _warmup != null or shaders.is_empty(): return
	_warmup = Node3D.new()
	_warmup.name = "SeasonMaterialWarmupHolders"
	_warmup.visible = false
	var quad := QuadMesh.new()
	quad.size = Vector2(0.01, 0.01)
	for key: String in shaders:
		var holder := MeshInstance3D.new()
		holder.mesh = quad
		holder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		material.shader = shaders[key]
		holder.material_override = material
		_warmup.add_child(holder)
	add_child(_warmup)

## The warm-up materials (tests).
func warmup_materials() -> Array[Material]:
	var out: Array[Material] = []
	if _warmup == null: return out
	for holder: Node in _warmup.get_children():
		out.append((holder as MeshInstance3D).material_override)
	return out
