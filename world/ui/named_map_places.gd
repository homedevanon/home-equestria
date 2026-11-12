extends RefCounted
## Read-only map addresses. Never asks population to assign a home or touches saves.
const DATA := "res://world/ui/named_map_places.json"
const APPEARANCE := preload("res://world/ui/pony_map_data.gd")
const FADE_FROM := 0.75
const FADE_TO := 1.8
const FONT_SIZE := 16
## Existing physical destinations, sampled only with their live town. No aerial rebuild.
const SHOPS := [
	{"id": "shop:hayburger", "name": "Hayburger", "path": "Hayburger/RestaurantInterior", "at": Vector3.ZERO},
	{"id": "shop:spa", "name": "Day Spa", "path": "RNLScenery/East/Shops/spa_01", "at": Vector3.ZERO},
	{"id": "ponyville:market:produce", "name": "Produce market", "path": "RNLScenery/Town/Market/kiosk_01_02", "at": Vector3(0, 0, -1.8)},
	{"id": "ponyville:market:goods", "name": "General goods", "path": "RNLScenery/Town/Market/tent_friagram_lightbrown_01", "at": Vector3(0, 0, 8.2)},
]

static func opacity(zoom: float) -> float:
	return smoothstep(FADE_FROM, FADE_TO, zoom)

## The file never changes during a session; the map asks every 2 s while it shows.
static var _document: Variant = null
static var _document_read := false

static func defaults(houses := false) -> Array:
	if not _document_read:
		_document_read = true
		_document = JSON.parse_string(FileAccess.get_file_as_string(DATA)) if FileAccess.file_exists(DATA) else null
	var document: Variant = _document
	var result: Array = []
	if not document is Dictionary: return result
	for row: Dictionary in document.get("places", []):
		if row.kind == "house" and not houses: continue
		result.append({"id": row.id, "name": row.name, "kind": row.kind, "position": Vector2(row.x, row.z), "local_place": true})
	return result

static func sample(reference: Node3D) -> Array:
	if not is_instance_valid(reference) or not reference.is_inside_tree(): return []
	var tree := reference.get_tree()
	var space := reference.get_world_3d()
	var populations: Array = tree.get_nodes_in_group("pony_populations")
	var population: Node
	for candidate: Node in populations:
		if "anchor" in candidate and is_instance_valid(candidate.anchor) and candidate.anchor.get_world_3d() == space:
			population = candidate; break
	var result: Array = []
	for house: Node3D in tree.get_nodes_in_group("house_interiors"):
		if not house.is_inside_tree() or house.get_world_3d() != space or house.is_queued_for_deletion(): continue
		var residents: Array = population.residents_of(house.place_id()) if population != null else []
		var names: Array[String] = []
		var player_home := str(house.get_meta("reserved_for", "")) == "player" or bool(house.get_meta("shared_player_home", false))
		if player_home: names.append("Your")
		for id: String in residents:
			if id != "player": names.append(str(APPEARANCE.appearance(id).name))
		# Generic vacant plots are not named destinations. Authored landmarks remain useful.
		var label: String = house.label()
		if names.is_empty() and (label.begins_with("House ") or house.place_id() == "shop:sugarcube_corner"): continue
		if names.size() == 1: label = "Your home" if player_home else names[0] + "'s home"
		elif names.size() > 1:
			if player_home: label = "Your home · " + " & ".join(names.slice(1))
			else: label = " & ".join(names) + "'s home"
		if house.place_id() == "house:carousel_boutique":
			label = "Rarity's Boutique" + (" · " + label if not names.is_empty() else "")
		var at: Vector3 = house.center()
		result.append({"id": house.place_id(), "name": label, "kind": "house", "position": Vector2(at.x, at.z), "local_place": true})
	for town: Node3D in tree.get_nodes_in_group("town_roots"):
		if town.get_world_3d() != space: continue
		for spec: Dictionary in SHOPS:
			var anchor := town.get_node_or_null(str(spec.path)) as Node3D
			if anchor == null or anchor.is_queued_for_deletion(): continue
			var at: Vector3 = anchor.to_global(spec.at)
			result.append({"id": spec.id, "name": spec.name, "kind": "shop", "position": Vector2(at.x, at.z), "local_place": true})
		for key: String in ["town_hall", "sugarcube_corner"]:
			var building := town.get_node_or_null(key) as Node3D
			if building == null: continue
			var label := "Town Hall" if key == "town_hall" else "Sugarcube Corner"
			result.append({"id": "landmark:" + key, "name": label, "kind": "landmark", "position": Vector2(building.global_position.x, building.global_position.z), "local_place": true})
	result.sort_custom(func(a: Dictionary, b: Dictionary): return a.id < b.id)
	return result
