extends RefCounted
## Who lives where, as the player chose it (Settings > World > "Who lives where", 2026-11-24).
## Writes the world's population.json only through the game's own config script (load_file,
## assign, save_file), so a mod's copy of that script keeps its own flags, and records the
## choices in a side file beside it:
##   user://worlds/<id>/population_choices.json  {version, not_spawned[], homes{id: region}, preset}
## pony_population.gd puts these choices back whenever anything else rewrites the assignments
## (an older checkpoint, a one-time migration). "Not spawned" = absent from the assignments.
## open("") edits the template new worlds copy: user://population/roster.json + choices.json.

signal changed

const CONFIG = preload("res://world/population/pony_population_config.gd")
const HOUSEHOLDS = preload("res://world/population/pony_households.gd")
const SAVE_FILE = preload("res://world/save_file.gd")
const FILE := "population_choices.json"
const TEMPLATE_CHOICES := "user://population/choices.json"
const PRESET_DIR := "res://world/population/presets"
const USER_PRESET_DIR := "user://population/presets"
const BUILTIN_PRESETS := ["show_default", "everypony", "fewer_ponies"]
## Beta: the arrival story brings Twilight anyway, so she cannot be moved or removed.
const LOCKED := ["twilight_sparkle"]
const ROSTER := "res://world/characters/background/roster.json"
const TRIBES := {"twilight_sparkle": "alicorn", "rainbow_dash": "pegasus", "rarity": "unicorn",
	"pinkie_pie": "earth", "applejack": "earth", "fluttershy": "pegasus", "celestia": "alicorn",
	"luna": "alicorn", "zecora": "other", "spike": "other"}

## pony_identity.gd Race, in its order.
const IDENTITY_TRIBES := ["earth", "pegasus", "unicorn", "alicorn"]
static var _identities: Dictionary = {}

var world_dir := ""
var population_path := ""
var choices_path := ""
var config := CONFIG.new()
var choices: Dictionary = {}
var _undo: Dictionary = {}

static func open(dir: String) -> RefCounted:
	var made: RefCounted = load("res://world/population/population_choices.gd").new()
	made.call("_open", dir)
	return made

func _open(dir: String) -> void:
	world_dir = dir
	if dir.is_empty():
		population_path = CONFIG.LIVE_PATH
		choices_path = TEMPLATE_CHOICES
	else:
		population_path = dir.path_join("population.json")
		choices_path = dir.path_join(FILE)
	_reload()

func _reload() -> void:
	config = CONFIG.new()
	config.load_file(population_path)
	choices = read(choices_path)
	if choices.is_empty(): choices = empty()

static func empty() -> Dictionary:
	return {"version": 1, "not_spawned": [], "homes": {}, "preset": ""}

## The side file, cleaned: {} when it is missing or not a version 1 choices file.
static func read(path: String) -> Dictionary:
	var data: Variant = SAVE_FILE.parse(path, 1 << 20)
	if not data is Dictionary or int((data as Dictionary).get("version", 0)) != 1: return {}
	var out := empty()
	var gone: Variant = (data as Dictionary).get("not_spawned", [])
	if gone is Array:
		for id: Variant in gone:
			if id is String and not (id as String) in out.not_spawned: (out.not_spawned as Array).append(id)
	var homes: Variant = (data as Dictionary).get("homes", {})
	if homes is Dictionary:
		for id: Variant in homes:
			if id is String and (homes as Dictionary)[id] is String: out.homes[id] = (homes as Dictionary)[id]
	out.preset = str((data as Dictionary).get("preset", ""))
	return out

## The choices that can apply: known ponies (`known`: id -> scene, the catalogue), known regions,
## never a locked pony or the summoned pony.
static func usable(chosen: Dictionary, known: Dictionary) -> Dictionary:
	var region_ids := {}
	for r: Dictionary in CONFIG.regions(): region_ids[str(r.id)] = true
	var out := empty()
	for id: String in chosen.get("not_spawned", []):
		if known.has(id) and not id in LOCKED and id != CONFIG.BARBIEPONE: (out.not_spawned as Array).append(id)
	var homes: Dictionary = chosen.get("homes", {})
	for id: String in homes:
		if known.has(id) and not id in LOCKED and id != CONFIG.BARBIEPONE and region_ids.has(str(homes[id])): out.homes[id] = str(homes[id])
	out.preset = str(chosen.get("preset", ""))
	return out

## Puts usable() choices back into `target` (a pony_population_config). True when it changed anything.
static func put_back(target: RefCounted, chosen: Dictionary) -> bool:
	var assignments: Dictionary = target.get("assignments")
	var done := false
	for id: String in chosen.get("not_spawned", []):
		if assignments.has(id): target.call("assign", id, ""); done = true
	var homes: Dictionary = chosen.get("homes", {})
	for id: String in homes:
		if str(assignments.get(id, "")) != str(homes[id]): target.call("assign", id, str(homes[id])); done = true
	return done

## Every pony the screen offers (the summoned pony has her own button), sorted by name.
func ponies() -> Array[Dictionary]:
	var roster := _roster()
	var out: Array[Dictionary] = []
	for id: String in CONFIG.catalogue():
		if id == CONFIG.BARBIEPONE: continue
		var row: Dictionary = roster.get(id, {})
		# A mod's resident is in the catalogue but in none of the game's lists: her own identity says who she is.
		var identity: Resource = null if roster.has(id) or TRIBES.has(id) else scene_identity(id)
		if identity != null:
			row = {"display_name": str(identity.get("display_name")), "filly": bool(identity.get("filly")),
				"race": IDENTITY_TRIBES[clampi(int(identity.get("race")), 0, IDENTITY_TRIBES.size() - 1)]}
		var region := str(config.assignments.get(id, ""))
		var tribe := str(TRIBES.get(id, row.get("race", "other")))
		if not tribe in ["earth", "pegasus", "unicorn", "alicorn"]: tribe = "other"
		out.append({"id": id, "name": str(row.get("display_name", CONFIG.pony_name(id))), "region": region,
			"not_spawned": region.is_empty(), "locked": id in LOCKED, "tribe": tribe, "filly": bool(row.get("filly", false))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return out

## The identity resource a catalogue pony's scene carries (pony_identity.gd: display_name, race,
## filly, coat_fill, cutie_mark), or null. Asked only for a pony the game's lists do not know, which
## is a mod's resident; her scene is read once per session and never instanced.
static func scene_identity(id: String) -> Resource:
	if _identities.has(id): return _identities[id]
	var found: Resource = null
	var path := str(CONFIG.catalogue().get(id, ""))
	var scene: PackedScene = load(path) as PackedScene if not path.is_empty() and ResourceLoader.exists(path) else null
	if scene != null:
		var state := scene.get_state()
		for i in state.get_node_property_count(0):
			if state.get_node_property_name(0, i) == &"identity": found = state.get_node_property_value(0, i) as Resource
	_identities[id] = found
	return found

static func _roster() -> Dictionary:
	var out := {}
	var data: Variant = SAVE_FILE.parse(ROSTER)
	if data is Array:
		for row: Variant in data:
			if row is Dictionary: out[str((row as Dictionary).get("id", ""))] = row
	return out

## Every region a pony may live in; the places ponies live by default come first (common).
func regions() -> Array[Dictionary]:
	var common := {}
	var defaults: Variant = SAVE_FILE.parse(CONFIG.DEFAULT_ASSIGNMENTS)
	if defaults is Dictionary and (defaults as Dictionary).get("assignments") is Dictionary:
		for id: String in defaults.assignments: common[str(defaults.assignments[id])] = true
	var counts := {}
	for id: String in config.assignments:
		if id == CONFIG.BARBIEPONE: continue
		var region := str(config.assignments[id])
		counts[region] = int(counts.get(region, 0)) + 1
	var first: Array[Dictionary] = []
	var rest: Array[Dictionary] = []
	for r: Dictionary in CONFIG.regions():
		var id := str(r.id)
		var row := {"id": id, "name": str(r.get("name", id)), "count": int(counts.get(id, 0)), "common": common.has(id)}
		if common.has(id): first.append(row)
		else: rest.append(row)
	first.append_array(rest)
	return first

## Moves every pony in `ids` to `region` ("" means not spawned). Locked ponies are skipped.
func move(ids: PackedStringArray, region: String) -> void:
	if region.is_empty(): set_not_spawned(ids); return
	var valid := false
	for r: Dictionary in CONFIG.regions(): valid = valid or str(r.id) == region
	if not valid: return
	_change(ids, region)

func set_not_spawned(ids: PackedStringArray) -> void:
	_change(ids, "")

func _change(ids: PackedStringArray, region: String) -> void:
	_reload()
	var known := CONFIG.catalogue()
	var before := _snapshot()
	var any := false
	for id: String in ids:
		if id in LOCKED or id == CONFIG.BARBIEPONE or not known.has(id): continue
		config.assign(id, region)
		(choices.not_spawned as Array).erase(id)
		(choices.homes as Dictionary).erase(id)
		if region.is_empty(): (choices.not_spawned as Array).append(id)
		else: choices.homes[id] = region
		any = true
	if not any: return
	choices.preset = "custom"
	if _write(): _undo = before

func presets() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in BUILTIN_PRESETS:
		var data: Variant = SAVE_FILE.parse(PRESET_DIR.path_join(id + ".json"))
		if data is Dictionary: out.append({"id": id, "name": str((data as Dictionary).get("name", id)), "builtin": true})
	var mine: Array[Dictionary] = []
	var files := DirAccess.get_files_at(USER_PRESET_DIR) if DirAccess.dir_exists_absolute(USER_PRESET_DIR) else PackedStringArray()
	for file: String in files:
		if not file.ends_with(".json"): continue
		var data: Variant = SAVE_FILE.parse(USER_PRESET_DIR.path_join(file))
		if data is Dictionary: mine.append({"id": "user:" + file.get_basename(), "name": str((data as Dictionary).get("name", file.get_basename())), "builtin": false})
	mine.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	out.append_array(mine)
	return out

## Shipped presets start from the shipped population ("base": "default", which a town mod's own
## default_assignments.json replaces), keep only "only" when given, then apply "homes", put
## any pony still unplaced in "rest" when given, and remove "not_spawned". A saved preset is a
## whole population. Locked ponies and the summoned pony keep what they have.
func apply_preset(id: String) -> bool:
	var path := USER_PRESET_DIR.path_join(id.trim_prefix("user:") + ".json") if id.begins_with("user:") else PRESET_DIR.path_join(id + ".json")
	if not id.begins_with("user:") and not id in BUILTIN_PRESETS: return false
	var preset: Variant = SAVE_FILE.parse(path, 1 << 20)
	if not preset is Dictionary: return false
	_reload()
	var before := _snapshot()
	var known := CONFIG.catalogue()
	var region_ids := {}
	for r: Dictionary in CONFIG.regions(): region_ids[str(r.id)] = true
	var result := {}
	if str((preset as Dictionary).get("base", "")) == "default":
		var shipped := CONFIG.new()
		shipped.defaults()
		result = shipped.assignments.duplicate()
	var only: Variant = (preset as Dictionary).get("only")
	if only is Array:
		for pony: String in result.keys():
			if not pony in only: result.erase(pony)
	var homes: Variant = (preset as Dictionary).get("homes", {})
	if homes is Dictionary:
		for pony: Variant in homes: result[str(pony)] = str((homes as Dictionary)[pony])
	var rest := str((preset as Dictionary).get("rest", ""))
	if region_ids.has(rest):
		for pony: String in known:
			if not result.has(pony): result[pony] = rest
	var gone: Variant = (preset as Dictionary).get("not_spawned", [])
	if gone is Array:
		for pony: Variant in gone: result.erase(str(pony))
	for pony: String in LOCKED + [CONFIG.BARBIEPONE]:
		result.erase(pony)
		if config.assignments.has(pony): result[pony] = config.assignments[pony]
	var clean := {}
	for pony: String in result:
		if known.has(pony) and region_ids.has(str(result[pony])): clean[pony] = str(result[pony])
	config.assignments = clean
	choices = _whole(known)
	choices.preset = id
	if not _write(): return false
	_undo = before
	return true

## The current population as choices: every offered pony is either at home somewhere or not spawned.
func _whole(known: Dictionary) -> Dictionary:
	var out := empty()
	for pony: String in known:
		if pony in LOCKED or pony == CONFIG.BARBIEPONE: continue
		if config.assignments.has(pony): out.homes[pony] = str(config.assignments[pony])
		else: (out.not_spawned as Array).append(pony)
	return out

## Saves the current population as the player's own preset; returns its id, "" on failure.
func save_preset(preset_name: String) -> String:
	var label := preset_name.strip_edges()
	if label.is_empty(): return ""
	var slug := label.to_lower().validate_filename().replace(" ", "_").left(48)
	if slug.is_empty(): slug = "preset"
	_reload()
	var data := _whole(CONFIG.catalogue())
	data.erase("preset")
	data["name"] = label
	if SAVE_FILE.write(USER_PRESET_DIR.path_join(slug + ".json"), data) != OK: return ""
	changed.emit()
	return "user:" + slug

func can_undo() -> bool:
	return not _undo.is_empty()

## Undoes the last change (one step). The summoned pony keeps what she has now.
func undo() -> bool:
	if _undo.is_empty(): return false
	var back := _undo
	_reload()
	var restored: Dictionary = (back.assignments as Dictionary).duplicate()
	restored.erase(CONFIG.BARBIEPONE)
	if config.assignments.has(CONFIG.BARBIEPONE): restored[CONFIG.BARBIEPONE] = config.assignments[CONFIG.BARBIEPONE]
	config.assignments = restored
	choices = (back.choices as Dictionary).duplicate(true)
	if not _write(): return false
	_undo = {}
	return true

func _snapshot() -> Dictionary:
	return {"assignments": config.assignments.duplicate(), "choices": choices.duplicate(true)}

## population.json first (through the config script), then the side file; then the running
## population, if it is this world's, takes the new choices at once.
func _write() -> bool:
	if not config.save_file(population_path): return false
	if SAVE_FILE.write(choices_path, choices) != OK: return false
	var population := _running()
	if population != null: population.call("choices_changed")
	changed.emit()
	return true

## This world's running population node, or null (title screen, another world, the template).
func _running() -> Node:
	if world_dir.is_empty(): return null
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return null
	for node: Node in tree.get_nodes_in_group("pony_populations"):
		if not "config_path" in node or not node.has_method("choices_changed"): continue
		if str(node.get("config_path")).simplify_path() == population_path.simplify_path(): return node
	return null

## Free Ponyville homes in the running world (houses nopony lives in), -1 when unknown.
func free_homes() -> int:
	var population := _running()
	if population == null or not population.is_inside_tree() or not population.has_method("empty_plot"): return -1
	var houses: Array[Node] = population.get_tree().get_nodes_in_group("house_interiors")
	var plots := 0
	var free := 0
	for house: Node in houses:
		if not str(house.get_path()).contains("PonyvilleTown/plot"): continue
		plots += 1
		if bool(population.call("empty_plot", house)): free += 1
	return free if plots > 0 else -1

## Plain sentences about the current choices, for the window.
func warnings() -> PackedStringArray:
	var out := PackedStringArray()
	var population := _running()
	if population == null or not population.is_inside_tree(): return out
	var plots := 0
	var reserved := {}
	for house: Node in population.get_tree().get_nodes_in_group("house_interiors"):
		var owner := str(house.get_meta("reserved_for", "")) if house.has_meta("reserved_for") else ""
		if not owner.is_empty(): reserved[owner] = true
		elif str(house.get_path()).contains("PonyvilleTown/plot"): plots += 1
	if plots == 0: return out
	var households := {}
	for id: String in config.assignments:
		if str(config.assignments[id]) != "ponyville" or preload("res://world/life/night_rest.gd").SKY_HOMES.has(id): continue
		var family: Array = HOUSEHOLDS.members(id)
		var own := false
		for member: String in family: own = own or reserved.has(member)
		if not own: households[str(family[0])] = true
	if households.size() > plots:
		out.append("There are more Ponyville households (%d) than town houses (%d), so some ponies will share a house." % [households.size(), plots])
	if free_homes() == 0:
		out.append("No house in Ponyville is free, so a player who has no home yet cannot be given one.")
	return out
