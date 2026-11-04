extends RefCounted
## Building attachments on the streamed Ponyville town: two-sided triangle colliders, Trixie's
## wagon, the farm, the walk-in Hayburger, the special homes, the balloon and the render budget.
## Split out of game.gd's _ready (2026-10-13), same order, before navigation and the player load.


static func attach(game: Node3D, town: Node) -> void:
	# Town buildings collide with one-sided triangle meshes: from the back of a face you
	# walked straight through. Make every triangle-mesh collider in the town two-sided.
	for holder:CollisionShape3D in town.find_children("*","CollisionShape3D",true,false):
		if holder.shape is ConcavePolygonShape3D:(holder.shape as ConcavePolygonShape3D).backface_collision=true
	# Props that stood on ground the building pads raised come up with it (tools/terrain/
	# pad_lifts.gd writes the list; the kit dressing applies its own rows).
	var lifts_path := "res://world/towns/ponyville/pad_lifts.json"
	if FileAccess.file_exists(lifts_path):
		var lifts: Variant = JSON.parse_string(FileAccess.get_file_as_string(lifts_path))
		if lifts is Dictionary:
			for path: String in (lifts as Dictionary).get("nodes", {}):
				var prop := town.get_node_or_null(path) as Node3D
				if prop != null: prop.global_position.y += float(lifts.nodes[path])
	# Ramps, stoops and foundations in cartoon flagstone instead of flat grey (stone_dressing.gd).
	preload("res://world/buildings/stone_dressing.gd").apply(town)
	# Trixie's wagon is her home: its own house space, bed and doorway.
	town.add_child(preload("res://world/buildings/trixie_wagon.gd").new())
	# Sweet Apple Acres fences and orchard, on the north outskirts (farm_layout.json).
	town.add_child(preload("res://world/props/ponyville/farm_dressing.gd").new())
	# A walk-in Hayburger replaces its former filled scenery collider before
	# navigation/player loading. Customer visits start once population is ready.
	game.hayburger = preload("res://world/buildings/hayburger/hayburger_runtime.gd").new()
	game.hayburger.name = "Hayburger"; town.add_child(game.hayburger)
	var zecora_hut:Node3D=town.get_node_or_null("RNLScenery/Everfree/Zecora/zecorahut_2_01") as Node3D
	if zecora_hut!=null:
		preload("res://world/buildings/zecora/zecora_hut.gd").attach(zecora_hut)
	var cottage: Node3D = town.get_node_or_null("RNLScenery/Everfree/Fluttershy/snazzys_fluttershy_cottage_01") as Node3D
	if cottage != null:
		preload("res://world/buildings/fluttershy/cottage.gd").attach(cottage)
	var library: Node3D = town.get_node_or_null("RNLScenery/West/Library/goldenoaklibrary_01") as Node3D
	if library != null:
		preload("res://world/buildings/golden_oak/golden_oak.gd").attach(library)
	var boutique: Node3D = town.get_node_or_null("RNLScenery/Central/Boutique/rarityboutique_01") as Node3D
	var boutique_home: Script = load("res://world/buildings/boutique/boutique.gd") as Script
	if boutique != null and boutique_home != null and boutique_home.can_instantiate():
		boutique_home.call("attach", boutique)
	# Rainbow Dash's walk-in Cloudominium (dev 2026-09-28). Loaded, not preloaded: a broken
	# interior script must not stop the whole game from starting.
	var cloudominium: Node3D = town.get_node_or_null("RNLScenery/East/Sky/cloudominium_01") as Node3D
	var cloud_home: Script = load("res://world/buildings/cloudominium/cloudominium.gd") as Script
	if cloudominium != null and cloud_home != null and cloud_home.can_instantiate():
		var cloud_runtime: Node3D = cloud_home.call("attach", cloudominium)
		var cloud_drift: Node = cloud_runtime.get_node_or_null("CloudDrift")
		if cloud_drift != null: cloud_drift.game = game
	# The walk-in Day Spa (docs/SPA_PLAN_2026_10_29.md). Loaded, not preloaded: a broken spa
	# script cannot stop boot. Before the render budget, which would batch the old ramp.
	var spa_script: Script = load("res://world/minigames/spa/spa_venue.gd") as Script
	if spa_script != null and spa_script.can_instantiate(): spa_script.call("attach", town.get_node_or_null("RNLScenery/East/Shops/spa_01") as Node3D)
	# The public painting easel on Balloon Hill (world/painting/, 2026-10-22). Loaded, not
	# preloaded: it costs a static prop until someone paints, and a broken script cannot stop boot.
	var painting: Script = load("res://world/painting/station_install.gd") as Script
	if painting != null and painting.can_instantiate(): painting.call("attach", town)
	game.balloon=preload("res://world/vehicles/balloon/balloon.gd").attach(town)
	# Small parts stop casting shadows; houses become occluders (world/performance/).
	var budget: Node = preload("res://world/performance/town_render_budget.gd").new()
	budget.name = "RenderBudget"; town.add_child(budget); budget.setup(town)
