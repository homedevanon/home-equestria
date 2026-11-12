extends Node3D
## Bootstrap. Chooses the player rig, starts zone streaming, and hosts the
## unattended capture mode used to verify visuals without a headset.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
## Scenario mods (world/modding/scenario.gd, M-MOD-10): world stamp, initial state, start node.
const SCENARIO := preload("res://world/modding/scenario.gd")
const TITLE_SCENE := "res://world/ui/title_screen.tscn"

# The physics rig: xr-kit force-driven hands, joint grab, visible Anon body.
# The old xr_player.tscn (xr-tools ranged pickup) is retired but kept on disk.
const XR_PLAYER := preload("res://player/xr_player_physics.tscn")
const DESKTOP_PLAYER := preload("res://player/desktop_player.tscn")
## Seated VR (dev 2026-10-01: "just VR but you use the keyboard"): the desktop rig's script with
## a headset camera (ViewAnchor/XROrigin/XRCamera) in place of Camera3D.
const SEATED_PLAYER := preload("res://player/seated_player.tscn")
const LAUNCH_CONFIG := preload("res://world/launch_config.gd")

## Player height relative to a real adult. The source project authored Ponyville around
## pony-height cameras, so a full-size human reads as a giant walking through a
## model village. dev's call from the first playtest: about 40% smaller.
##
## In VR the headset defines eye height physically, so this cannot be applied by
## moving a camera -- it becomes XRServer.world_scale, which rescales the whole
## tracking space instead. Same number, two mechanisms.
# 2026-10-13: slightly smaller Anon in both desktop and VR (five percent).
const PLAYER_SCALE := 0.95
# Preserve the tracked body's existing relative sizing and real-height calibration.
const VR_PLAYER_SCALE := 1.14

## Parts split out by responsibility (2026-10-13). Each is a RefCounted helper holding this
## node; the state stays here, with a forward for every name other scripts, tests,
## Callables or signal connections reach. TOWN_ADAPTERS is static.
const TOWN_ADAPTERS := preload("res://world/game_town_adapters.gd")
const LOADING := preload("res://world/game_loading.gd")
const PLAYER_RIG := preload("res://world/game_player_rig.gd")
const MARE_WIRING := preload("res://world/game_mare_wiring.gd")
const RESIDENTS := preload("res://world/game_residents.gd")
const ROSTER_LAB := preload("res://world/game_roster_lab.gd")
const CAPTURE_HARNESS := preload("res://world/game_capture_harness.gd")
var _loading := LOADING.new(self)
var _player_rig := PLAYER_RIG.new(self)
var _mare_wiring := MARE_WIRING.new(self)
var _residents := RESIDENTS.new(self)
var _roster_lab := ROSTER_LAB.new(self)
var _capture_harness := CAPTURE_HARNESS.new(self)

@onready var zones: Node3D = $Zones
@onready var spawn: Marker3D = $PlayerSpawn

var player: Node3D
## Opening title over the live world: set by the launch scene (world/ui/title_screen.gd) for the
## next boot; title_active while the title menu is up (world/ui/title_vista.gd).
static var title_mode := false
var title_active := false
var title_vista: Node
var arrival: Node
var shop_world: Node
var needs: Node
var sleep: Node
var luna_dream: Node
var wardrobe: Node
## Set while Anon sleeps (world/life/player_sleep.gd); princess visits wait for him to be awake.
var player_sleeping := false
## The room-scale controller rig (player/xr_player_physics.tscn). False in seated VR.
var xr_active := false
## The view is in a headset: room-scale, or seated (keyboard and mouse, desktop rig script).
var headset_view := false
var seated_vr := false
## Seated only: the 2D HUD shown on a floating screen in the headset (world/ui/virtual_screen.gd).
var virtual_screen: Node
var world_map: Node
var cuddle_input: Node
var pony_head_guard:Node
var kisser: Node
var inventory: Node
@export var inventory_save_path := "user://inventory/briefcase.json"
@export var context_world_id:="default"
@export var context_save_root:="user://worlds"
var world_context:Node
## world/ai/encounters/encounter_runtime.gd: story purposes that survive interruptions.
var encounters: Node
var relationship_runtime: Node
var picnic_runtime: Node
var saves:Node
var life:Node
var railway:Node
var rail_network:Node3D
var save_menu:Node
var settings_menu:Node
var pause_menu:Node
var hayburger:Node3D
var food_world:Node
var apple_bucking:Node3D
var fishing:Node3D
var balloon:Node3D
var desktop_presentation: Node3D
var desktop_interactions: Node
var harvest_pickup: Node
var flight_audio: Node3D
var mechanics: Node

func _ready() -> void:
	SHUTDOWN.reset()
	SOUNDS.setup(self)
	WorldWater.use_fft_ocean = true
	Settings.changed.connect(_on_setting_changed)
	# Colliders, special homes, Hayburger, balloon and render budget on the town (game_town_adapters.gd).
	var town:=get_node_or_null("Zones/PonyvilleTown")
	if town!=null: TOWN_ADAPTERS.attach(self, town)
	# AI playtester (tools/playtest/): drives the real inputs over a local socket.
	if "--playtest-bridge" in preload("res://world/dev_tools.gd").user_args():
		var bridge: Node = load("res://tools/playtest/bridge.gd").new()
		bridge.name = "PlaytestBridge"; bridge.game = self; add_child(bridge)
	# Development labs that need the real, fully booted world: `-- --lab res://tools/x.gd`.
	# The script is a Node with a `game` property; it waits for loading itself.
	var lab_path := _arg_value(preload("res://world/dev_tools.gd").user_args(), "--lab")
	if lab_path != "" and ResourceLoader.exists(lab_path) and get_tree().root.get_node_or_null("Lab") == null:
		var lab: Node = load(lab_path).new()
		lab.name = "Lab"; lab.set("game", self); add_child(lab)
	if preload("res://world/launch_config.gd").require_vr():
		var xr_interface := XRServer.find_interface("OpenXR")
		if xr_interface == null or not xr_interface.is_initialized():
			preload("res://world/launch_config.gd").fail_required_vr(get_tree())
			return
	if "--capture" in preload("res://world/dev_tools.gd").user_args():
		await _run_capture()
		return
	if "--probe" in preload("res://world/dev_tools.gd").user_args():
		await _run_probe()
		return
	if "--perf" in preload("res://world/dev_tools.gd").user_args():
		await _run_perf()
		return
	if "--perf-stereo" in preload("res://world/dev_tools.gd").user_args():
		await _run_perf_stereo()
		return
	# Pegasus flight routes load off the main thread while the world loads (native_air.gd).
	preload("res://world/characters/locomotion/native_air.gd").warm()
	world_context=preload("res://world/ai/world_context.gd").new()
	world_context.name="WorldContext";add_child(world_context)
	# Durable story encounters (docs/plans/AI_CONTEXT_AND_INTERRUPTION_RESILIENCE_2026_10_02.md).
	encounters=preload("res://world/ai/encounters/encounter_runtime.gd").new()
	encounters.name="Encounters";add_child(encounters);encounters.setup(self)
	var requested_world:=_arg_value(preload("res://world/dev_tools.gd").user_args(),"--world-id")
	var saves_script:=preload("res://world/game_saves.gd")
	if requested_world.is_empty() and saves_script.requested_world.is_empty() and "--new-game" in preload("res://world/dev_tools.gd").user_args():
		saves_script.stage_new_game()
	if not saves_script.requested_world.is_empty():requested_world=saves_script.requested_world;saves_script.requested_world=""
	if not requested_world.is_empty():context_world_id=requested_world
	if saves_script.start_fresh:
		TimeOfDay.day = saves_script.fresh_start_day
		TimeOfDay.hours = 8.5
		TimeOfDay.active_seconds = 0.0
		TimeOfDay.paused = false
	var context_root:=OS.get_environment("EQ_CONTEXT_ROOT")
	if context_root.is_empty():
		context_root=context_save_root
		if DisplayServer.get_name()=="headless":context_root="user://test_context/"+str(OS.get_process_id())
	# A world with no memory yet (no context.json or its backup) is brand new: a running scenario
	# stamps it (SCENARIO.begin_world below).
	var context_file:=context_root.path_join(context_world_id).path_join("context.json")
	var context_existed:=FileAccess.file_exists(context_file) or FileAccess.file_exists(context_file+".previous")
	if not world_context.open_world(context_world_id,context_root):push_warning(world_context.error)
	preload("res://world/props/ponyville_kit/kit_state.gd").install(self)
	preload("res://world/books/book_library.gd").open_world(world_context.path.get_base_dir())
	preload("res://world/painting/painting_registry.gd").open_world(world_context.path.get_base_dir())
	if OS.has_feature("android") or "--perf-ticker" in preload("res://world/dev_tools.gd").user_args():
		var ticker := preload("res://world/debug/perf_ticker.gd").new(); ticker.name = "PerfTicker"; get_tree().root.add_child.call_deferred(ticker)
	WorldTerrain.ensure(zones)
	WorldTerrain.instance.focus(spawn.position)  # windowed tiers load the regions around the spawn first
	fishing=preload("res://world/minigames/fishing/fishing_runtime.gd").new()
	fishing.name="RiverFishing";add_child(fishing)
	fishing.prepare(self,WorldTerrain.instance.height_at)
	var ground := WorldTerrain.instance.height_at(spawn.position)
	if is_finite(ground): spawn.position.y = ground + 0.5
	_spawn_player()
	relationship_runtime=preload("res://world/relationships/relationship_runtime.gd").new()
	relationship_runtime.name="Relationships";add_child(relationship_runtime);relationship_runtime.setup(self)
	picnic_runtime=preload("res://world/relationships/picnic_runtime.gd").new()
	picnic_runtime.name="Picnic";add_child(picnic_runtime);picnic_runtime.setup(self)
	# Loading screen from the first frame until everything below is ready (dev 2026-09-24).
	var cover: Node = preload("res://world/ui/loading_cover.gd").new()
	cover.name = "LoadingCover"; add_child(cover); cover.setup(_find_camera(player), xr_active)
	if title_mode: cover.show_logo()
	life = preload("res://world/life/living_world_runtime.gd").new()
	life.name = "LivingWorld"
	add_child(life)
	life.setup(self, context_world_id)
	# dev 2026-09-25: "completely remove the current train tracks running all over the place".
	# No Railway node: no track, carriages, platforms or ticket menu. Every other user checks
	# is_instance_valid(railway), so the living world plans walks and saves carry no railway.
	railway = null
	# The railway network dev sketched on 2026-09-26 (tools/rail_sketch/, docs/RAILWAYS_2026_09_26.md):
	# ground-level track, rack sections, tunnels and one timetabled train per line. Separate from
	# `railway` (the old single Meadowline service, whose save data and pony trips stay switched off).
	rail_network = preload("res://world/railway/rail_network.gd").new()
	rail_network.name = "RailNetwork"
	add_child(rail_network)
	rail_network.setup(self)
	# Restore stock and seasonal harvests before either service can populate.
	food_world=preload("res://world/food/food_world.gd").new()
	food_world.name="FoodWorld";add_child(food_world)
	needs=preload("res://world/life/player_needs.gd").new()
	needs.name="PlayerNeeds";add_child(needs);needs.setup(self)
	sleep=preload("res://world/life/player_sleep.gd").new()
	sleep.name="PlayerSleep";add_child(sleep);sleep.setup(self)
	luna_dream=preload("res://world/life/luna_dream.gd").new()
	luna_dream.name="LunaDream";add_child(luna_dream);luna_dream.setup(self)
	wardrobe=preload("res://world/characters/accessories/pony_wardrobe.gd").new()
	wardrobe.name="PonyWardrobe";add_child(wardrobe);wardrobe.setup(self)
	var feeding:Node=preload("res://world/relationships/hand_feeding.gd").new()
	feeding.name="HandFeeding";add_child(feeding);feeding.setup(self)
	# The shared mechanics hub (docs/MECHANICS_ARCHITECTURE_2026_11_01.md): facts, ledger, market.
	mechanics=preload("res://world/mechanics/mechanics.gd").new()
	mechanics.name="Mechanics";add_child(mechanics);mechanics.setup(self)
	shop_world=preload("res://world/shop/shop_world.gd").new()
	shop_world.name="ShopWorld";add_child(shop_world)
	apple_bucking=preload("res://world/minigames/apple_bucking/apple_bucking.gd").new()
	apple_bucking.name="AppleBucking";add_child(apple_bucking)
	saves=preload("res://world/game_saves.gd").new();saves.name="GameSaves";add_child(saves)
	saves.setup(self,world_context.path.get_base_dir().path_join("saves"))
	var resumed:Dictionary=saves.take_resume()
	if not resumed.is_empty() and not saves.restore(resumed):
		push_warning("Could not restore the saved game.");resumed={}
	var saved_body:Node=player.get_node("Body") if xr_active else player
	# Held still under the loading screen (a resumed game also until its position is back).
	saved_body.set_physics_process(false)
	# Scenario mods: a new world is stamped with the running scenario and gets its initial state
	# before the arrival story reads the context; a world of another scenario (or a vanilla world
	# while one runs) is not entered: back to the title, its saves untouched (the menus refuse
	# them first; this catches --world-id and the autosave resume).
	var resume_block:String=str(saves.get("scenario_block")) if saves.get("scenario_block") is String else ""
	var is_new_world:bool=not context_existed and resumed.is_empty() and resume_block.is_empty()
	var scenario_block:String=resume_block if not resume_block.is_empty() else SCENARIO.begin_world(self,is_new_world)
	if not scenario_block.is_empty():
		_leave_for_title(scenario_block)
		return
	# A new world begins with the arrival story (world/life/arrival_story.gd): the player wakes
	# in the Everfree. Placed before the title view so the title returns him there.
	arrival = preload("res://world/life/arrival_story.gd").new()
	arrival.name = "ArrivalStory"; add_child(arrival); arrival.prepare(self, resumed)
	# The scenario's start node ("ScenarioStart"): instead of the opening (skip_opening) or before it.
	SCENARIO.start_world(self, arrival, is_new_world)
	# Opening title (world/ui/title_vista.gd): the player waits at a view of Ponyville while the
	# save's real place is remembered; nothing is saved until Continue.
	if title_mode:
		title_mode = false
		title_active = true
		title_vista = preload("res://world/ui/title_vista.gd").new()
		title_vista.name = "TitleVista"; add_child(title_vista); title_vista.prepare(self)
	save_menu=preload("res://world/ui/save_menu.gd").new();add_child(save_menu);save_menu.setup(saves,inventory)
	pause_menu=preload("res://world/ui/pause_menu.gd").new();pause_menu.name="PauseMenu"
	settings_menu=preload("res://world/ui/settings_menu.gd").new();add_child(settings_menu);settings_menu.setup(inventory,pause_menu)
	add_child(pause_menu);pause_menu.setup(self,inventory,save_menu,settings_menu,player.get_node("Body") if xr_active else player)
	if xr_active:settings_menu.bind_controller(player.find_child("XRControllerLeft",true,false))
	add_child(preload("res://world/events/barbiepone/barbiepone.gd").new().setup(self))
	if xr_active:world_map.saves_requested.connect(save_menu.toggle)
	else:
		var save_button:=Button.new();save_button.text="Saved games · F6"
		# A floating chip in the menus' look (world/ui/menu_style.gd "Float"), right under the map.
		save_button.theme_type_variation="Float";save_button.icon=preload("res://world/ui/menu_icon.gd").texture("save",16)
		world_map.panel.add_child(save_button);save_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		save_button.position=Vector2(world_map.panel.size.x-save_button.get_combined_minimum_size().x,world_map.panel.size.y+8)
		save_button.pressed.connect(save_menu.toggle)
	var runtime_profile: Node
	if "--profile-runtime" in preload("res://world/dev_tools.gd").user_args():
		runtime_profile = load("res://tools/runtime_profile.gd").new()
		add_child(runtime_profile)
	var player_camera := _find_camera(player)
	# The XR player root never moves (its Body does), so the streaming anchor is the head:
	# anchoring the root left every zone but the spawn pair unloaded in VR (2026-09-18).
	ZoneManager.setup(zones, player_camera if player_camera != null else player)
	if player_camera != null:
		player_camera.far = Quality.get_value("draw_distance", 9000.0)
	social = preload("res://world/ai/pony_social_groups.gd").new()
	social.name = "SocialGroups"
	add_child(social)
	social.director = director
	social.world_context=world_context
	if director != null: director.social = social
	var args := preload("res://world/dev_tools.gd").user_args()
	if _arg_value(args, "--character") != "" or _arg_value(args, "--roster") != "":
		await _spawn_roster()
	else:
		population = preload("res://world/population/pony_population.gd").new()
		population.name = "Population"
		add_child(population)
		population.setup(self, player_camera)
		if not resumed.is_empty():saves.restore_residents(resumed)
		life.bind_population(population)
		if is_instance_valid(railway): railway.bind_population()
		var seating := preload("res://world/life/seating.gd").new()
		seating.name = "Seating"; add_child(seating)
		var night_rest := preload("res://world/life/night_rest.gd").new()
		night_rest.name = "NightRest"; add_child(night_rest); night_rest.setup(population)
		var rescue := preload("res://world/life/stuck_rescue.gd").new()
		rescue.name = "StuckRescue"; add_child(rescue); rescue.setup(population)
		# Daily plans rolled from loot tables (docs/DAY_PLANS.md).
		var day_runner := preload("res://world/life/day/day_runner.gd").new()
		day_runner.name = "DayRunner"; add_child(day_runner); day_runner.setup(population, night_rest)
		# Ponies switch their house lamps on at dusk and off before bed (lit windows far away).
		var house_lamps := preload("res://world/life/house_lamps.gd").new()
		house_lamps.name = "HouseLamps"; add_child(house_lamps); house_lamps.setup(population, night_rest)
		# Back onto the ground if the player ever ends up under the world.
		var ground_rescue := preload("res://world/player_ground_rescue.gd").new()
		ground_rescue.name = "PlayerGroundRescue"; add_child(ground_rescue); ground_rescue.setup(self)
		var weather := preload("res://world/weather/weather.gd").new()
		weather.name = "Weather"; add_child(weather); weather.setup(self)
		# Look overhaul 2026-11-10: warm light and smoke at lit houses, motes in the air (each has its own ENABLED switch).
		var town_warmth := preload("res://world/look/town_warmth.gd").new(); town_warmth.name = "TownWarmth"; add_child(town_warmth)
		var air_motes := preload("res://world/vfx/air_motes.gd").new(); air_motes.name = "AirMotes"; add_child(air_motes)
		var bird_flocks := preload("res://world/vfx/bird_flocks.gd").new(); bird_flocks.name = "BirdFlocks"; add_child(bird_flocks)
		var cold_breath := preload("res://world/vfx/cold_breath.gd").new(); cold_breath.name = "ColdBreath"; add_child(cold_breath)
		var season_state := preload("res://world/seasons/season_state.gd").new(); season_state.name = "SeasonState"; add_child(season_state); season_state.setup(self)
		var fireflies := preload("res://world/life/fireflies.gd").new()
		fireflies.name = "Fireflies"; add_child(fireflies)
		var visits := preload("res://world/life/princess_visits.gd").new()
		visits.name = "PrincessVisits"; add_child(visits); visits.setup(self)
		# Trixie's stage shows at the schoolhouse (world/events/trixie_show/).
		var trixie_show := preload("res://world/events/trixie_show/show_runtime.gd").new()
		trixie_show.name = "TrixieShow"; add_child(trixie_show); trixie_show.setup(self)
	if not await _load_everything(cover): return
	cover.show_text("Almost there…")
	cover.set_progress(0.9)
	var timberwolves := preload("res://world/creatures/everfree_timberwolves.gd").new()
	timberwolves.name = "Timberwolves"; add_child(timberwolves)
	timberwolves.camera_source = _player_eye_camera
	var forest_soundscape := preload("res://world/life/everfree_soundscape.gd").new()
	forest_soundscape.name = "EverfreeSoundscape"; add_child(forest_soundscape)
	forest_soundscape.camera_source = timberwolves.camera_source
	if is_instance_valid(hayburger): hayburger.setup(self)
	for spa_venue: Node in get_tree().get_nodes_in_group("spa_venue"): spa_venue.setup(self)
	fishing.setup()
	if is_instance_valid(balloon):balloon.setup(self)
	food_world.setup(self)
	shop_world.setup(self)
	apple_bucking.commit_harvest=saves.commit_harvest
	apple_bucking.markers_changed.connect(_refresh_activity_markers)
	apple_bucking.setup(self)
	harvest_pickup = preload("res://world/inventory/harvest_pickup.gd").new()
	harvest_pickup.name = "HarvestPickup"; add_child(harvest_pickup)
	harvest_pickup.setup(apple_bucking, inventory)
	apple_bucking.harvest_completed.connect(func(_tree_id:String,receipt:String)->void:
		# The "harvested" fact is written with the payment (game_saves.gd commit_harvest).
		if is_instance_valid(relationship_runtime):relationship_runtime.shared_activity("orchard",apple_bucking.player_position(),receipt,["applejack"]))
	if is_instance_valid(inventory):
		var interaction_hints := preload("res://world/ui/interaction_hints.gd").new()
		interaction_hints.name = "InteractionHints"; add_child(interaction_hints)
		interaction_hints.setup(self, inventory)
	_refresh_activity_markers()
	Settings.apply_scene()
	# Stock creation can take hundreds of milliseconds on its first physics
	# pass. Finish it under the cover, after restored state and shop/harvest
	# anchors exist, so those materials also participate in pipeline warmup.
	if not await SHUTDOWN.physics_frame(self): return
	food_world.prepare_loaded()
	shop_world.prepare_loaded()
	if not await _warm_up_pipelines(): return
	saves.ready_to_save=not title_active
	if title_active: title_vista.reveal(cover)
	else:
		# PK-014 (W1-PERF-HITCH hook 1): the body's first physics tick (250-275 ms in VR) runs under
		# the cover, not as the first visible frame.
		saved_body.set_physics_process(true)
		if not await SHUTDOWN.physics_frame(self): return
		cover.finish()
	var hitch := preload("res://world/debug/hitch_monitor.gd").new()
	hitch.name = "HitchMonitor"
	add_child(hitch)
	if "--terrain-review" in args or "--gaea-cost" in args:
		add_child(load("res://tools/gaea_world_review.gd").new())
	if runtime_profile != null:
		runtime_profile.begin(self)

## A world this launch cannot play (scenario mods, world/modding/scenario.gd): nothing is saved,
## and the title says why.
func _leave_for_title(reason:String)->void:
	push_warning("[scenario] world %s not entered: %s"%[context_world_id,reason])
	SCENARIO.notice="Could not enter that world: %s."%reason
	if is_instance_valid(saves):saves.ready_to_save=false
	get_tree().change_scene_to_file.call_deferred(TITLE_SCENE)

func _refresh_activity_markers()->void:
	if not is_instance_valid(apple_bucking):return
	var markers:Array[Dictionary]=apple_bucking.activity_markers()
	for map_view:Node in get_tree().get_nodes_in_group("world_map_views"):
		map_view.set_activity_markers("apple_bucking",markers)


func _load_everything(cover: Node) -> bool:
	return await _loading._load_everything(cover)


func _warm_up_pipelines() -> bool:
	return await _loading._warm_up_pipelines()


func _wire_mare(mare: Node) -> void:
	_mare_wiring._wire_mare(mare)


func _inventory_path() -> String:
	return _player_rig._inventory_path()

func _spawn_player() -> void:
	_player_rig._spawn_player()


const TOON_OVERLAY := preload("res://world/toon_overlay.gd")
const AMBIENCE := preload("res://world/ambience.gd")

## Where a --character stands during normal play: just in front of the player
## spawn, close enough to walk up to without hunting for her. From the world layout
## (regions[ponyville].spawn) so the frame data owns every placement.
const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")

static var CHARACTER_SPOT: Vector2 = WorldLayout.spawn("ponyville")
var grabber: Node
var mares: Array = []
var _map_layers: MapLayers
const PONY := preload("res://world/characters/pony.gd")
const NAVIGATOR := preload("res://world/characters/navigation/pony_navigator.gd")
const GRABBER := preload("res://player/pony_grabber.gd")
const INTERACTOR := preload("res://player/interactor.gd")
const SPECTATOR := preload("res://player/spectator_view.gd")
const DIRECTOR := preload("res://world/ai/conversation_director.gd")
var director: Node
var _pending_spectator: Node

var character: CharacterBody3D
var social: Node
var population: Node
var _resident_navigation: Dictionary = {}


func _population_busy(actor: Node3D) -> bool:
	return _residents._population_busy(actor)


## Why the last _spawn_resident returned null (population logs it).
var spawn_failure := ""

func _resident_service(region_id: String, at: Vector3) -> WalkGridService:
	return _residents._resident_service(region_id, at)


func _resident_authored_home(id: String, region_id: String, index: int) -> Vector3:
	return _residents._resident_authored_home(id, region_id, index)


func _spawn_resident(id: String, region_id: String, at: Vector3, packed: PackedScene, navigation_region := "", requester: Node = null) -> Node3D:
	return await _residents._spawn_resident(id, region_id, at, packed, navigation_region, requester)


func _despawn_resident(id: String, actor: Node3D) -> void:
	_residents._despawn_resident(id, actor)


func _release_cancelled_resident_service(region_id: String) -> void:
	_residents._release_cancelled_resident_service(region_id)


func _release_resident_service(region_id: String) -> void:
	_residents._release_resident_service(region_id)


func _spawn_roster() -> void:
	await _roster_lab._spawn_roster()


func _scatter_spots(count: int, radius: float, spacing: float) -> Array[Vector3]:
	return await _roster_lab._scatter_spots(count, radius, spacing)


var toon: Node
var _pending_character: Node3D


## Pony size and outline come from the Settings autoload (home-screen menu). Gameplay
## keys write through it: O / Shift+O outline, PageUp / PageDown size.
func pony_scale() -> float:
	return Settings.pony_scale()

## Adult stallions are this much bigger than mares (dev 2026-10-23: "make stallions bigger than
## mares by like 20%"); colts and fillies keep the size setting alone.
const STALLION_SIZE := 1.2

## The size setting for this pony, times STALLION_SIZE for an adult stallion.
func pony_scale_for(mare: Node) -> float:
	var identity: Resource = mare.get("identity") if "identity" in mare else null
	var stallion: bool = identity != null and bool(identity.get("stallion")) and not bool(identity.get("filly"))
	return pony_scale() * (STALLION_SIZE if stallion else 1.0)


func _on_setting_changed(key: String) -> void:
	if key == "ponies/size":
		# Impostor pictures were taken at the old size.
		preload("res://world/characters/hybrid_mare/pony_impostors.gd").atlases.clear()
		for mare in mares:
			if is_instance_valid(mare) and mare.has_method("set_body_scale"): mare.set_body_scale(pony_scale_for(mare))
		print("[ponies] size preset: %s (x%.2f)" % [Settings.display(key), pony_scale()])


## Leaving the world (quit to title, or a saved game reloading the scene): the zone
## streamer is an autoload and would otherwise keep this scene's freed zones.
func _exit_tree() -> void:
	# Every coroutine still waiting resumes now and unwinds while scripts live: one left
	# suspended at engine exit strands its pooled locals (errors when quitting).
	SHUTDOWN.begin()
	preload("res://world/characters/locomotion/baked_gaits.gd").forget()
	# Pony instances no longer poll their shared jobs after this scene leaves.
	# Join before renderer shutdown; retain completed caches for ordinary reloads.
	preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd").discard_pending()
	preload("res://world/characters/hybrid_mare/hybrid_far_mesh.gd").discard_pending()
	preload("res://world/characters/hybrid_mare/pony_touch_body.gd").discard_pending()
	preload("res://world/sky/color_grade.gd").finish()
	preload("res://world/characters/lip_sync.gd").join_all()
	preload("res://world/characters/locomotion/native_air.gd").join()
	if ZoneManager.container != null and is_instance_valid(ZoneManager.container) and is_ancestor_of(ZoneManager.container):
		ZoneManager.reset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and preload("res://world/dev_tools.gd").enabled():
		if (event as InputEventKey).physical_keycode == KEY_PAGEUP: Settings.cycle("ponies/size", 1)
		elif (event as InputEventKey).physical_keycode == KEY_PAGEDOWN: Settings.cycle("ponies/size", -1)
		elif (event as InputEventKey).physical_keycode == KEY_F3 and event.shift_pressed: _debug_magic()


## Shift+F3: the nearest unicorn or alicorn lights her horn for three seconds.
func _debug_magic() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null: return
	var best: Node3D = null
	for pony in get_tree().get_nodes_in_group("sim_ponies"):
		if pony is Node3D and pony.get("magic") != null and (best == null or cam.global_position.distance_to(pony.global_position) < cam.global_position.distance_to(best.global_position)):
			best = pony
	if best != null and best.has_method("cast_magic"):
		best.cast_magic(3.0)
		print("[magic] ", best.name, " casts (", best.magic.color.to_html(false), ")")
	get_viewport().set_input_as_handled()


func _player_eye_camera() -> Camera3D:
	return _player_rig._player_eye_camera()


func _find_camera(node: Node) -> Node3D:
	return _player_rig._find_camera(node)


# --- Capture harness ------------------------------------------------------

## Development profiler (tools/); the capture harness reaches it through this name.
const RUNTIME_PROFILE_PATH := "res://tools/runtime_profile.gd"


func _run_capture() -> void:
	await _capture_harness._run_capture()


func _run_perf() -> void:
	await _capture_harness._run_perf()


const STEREO_EYE_HEIGHT := PLAYER_SCALE * 1.75


func _run_perf_stereo() -> void:
	await _capture_harness._run_perf_stereo()


func _run_probe() -> void:
	await _capture_harness._run_probe()


func _ground_y(xz: Vector2) -> float:
	return _capture_harness._ground_y(xz)


func _arg_value(args: PackedStringArray, key: String) -> String:
	var idx := args.find(key)
	if idx >= 0 and idx + 1 < args.size():
		return args[idx + 1]
	return ""
