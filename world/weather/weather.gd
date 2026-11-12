extends Node3D
## Mist and fog weights lowered (dev 2026-10-02: "lower the frequency of fog"; halved again 2026-10-14): about 1 dry spell in
## 24 (was 12, before that 5).
## Random weather (dev 2026-09-23): clear, cloudy, rain, thunderstorm, snow and fog spells of
## a few minutes each, blending into one another. Drives the volumetric clouds and the sun,
## ambient and fog through SkyController; rain and snow fall around the camera (not inside
## houses); storms flash lightning with recorded thunder delayed by distance. Weather only publishes
## whether it is wet or cold (conditions_changed, is_wet(), is_cold(), is_snowing()); the life owner
## world/life/weather_shelter.gd decides which ponies go indoors (M-SEA-07, hazard H1, 2026-11-08:
## weather issues no navigation commands). pony_awareness reads describe() for dialogue.
## `-- --weather <kind>` (or `--weather=<kind>`) pins a kind for testing. Debug keys: F1 next season, F2 next
## weather (Shift+F2 previous), instant, clouds included; F3 a lightning strike with thunder right now.
## Seasons (W1-SEAS-A 2026-11-08): the season formula, its F1 offset, the season look and every
## season_* shader uniform moved to world/seasons/season_state.gd; `season` here mirrors it for the
## weather odds and older readers. The current weather is saved through season_state
## (save_state/restore_state). Weather odds follow the biome under the camera (climate map: no
## snow where snow cannot lie, desert rarely wet), and rain streaks and flakes dim with the sky
## at night instead of glowing (M-SEA-06).
const KINDS := {
	"clear":     {"weight": 3.0, "clouds": [-1.0, 1.0, 0.0], "sun": 1.0, "overcast": 0.0, "fog": 0.0, "rain": 0.0, "snow": 0.0, "hail": 0.0, "gust": 0.0},
	"cloudy":    {"weight": 2.0, "clouds": [0.68, 1.3, 0.2], "sun": 0.75, "overcast": 0.3, "fog": 0.0, "rain": 0.0, "snow": 0.0, "hail": 0.0, "gust": 0.1},
	"windy":     {"weight": 1.0, "clouds": [0.5, 1.1, 0.1], "sun": 0.9, "overcast": 0.1, "fog": 0.0, "rain": 0.0, "snow": 0.0, "hail": 0.0, "gust": 1.0},
	"mist":      {"weight": 0.17, "clouds": [0.45, 0.9, 0.15], "sun": 0.75, "overcast": 0.3, "fog": 0.45, "rain": 0.0, "snow": 0.0, "hail": 0.0, "gust": 0.0},
	"fog":       {"weight": 0.1, "clouds": [0.55, 1.0, 0.3], "sun": 0.55, "overcast": 0.5, "fog": 0.85, "rain": 0.0, "snow": 0.0, "hail": 0.0, "gust": 0.0},
	"drizzle":   {"weight": 1.2, "clouds": [0.8, 1.4, 0.45], "sun": 0.5, "overcast": 0.6, "fog": 0.08, "rain": 0.22, "snow": 0.0, "hail": 0.0, "gust": 0.1},
	"sunshower": {"weight": 0.6, "clouds": [0.42, 1.2, 0.1], "sun": 1.0, "overcast": 0.05, "fog": 0.0, "rain": 0.45, "snow": 0.0, "hail": 0.0, "gust": 0.1},
	"rain":      {"weight": 1.3, "clouds": [0.9, 1.9, 0.62], "sun": 0.3, "overcast": 0.85, "fog": 0.06, "rain": 0.6, "snow": 0.0, "hail": 0.0, "gust": 0.25},
	"storm":     {"weight": 0.6, "clouds": [0.97, 2.4, 0.9], "sun": 0.12, "overcast": 1.0, "fog": 0.1, "rain": 1.0, "snow": 0.0, "hail": 0.0, "gust": 0.6},
	"hail":      {"weight": 0.35, "clouds": [0.93, 2.2, 0.8], "sun": 0.2, "overcast": 0.9, "fog": 0.05, "rain": 0.25, "snow": 0.0, "hail": 1.0, "gust": 0.4},
	"snow":      {"weight": 0.5, "clouds": [0.88, 1.6, 0.4], "sun": 0.4, "overcast": 0.8, "fog": 0.18, "rain": 0.0, "snow": 1.0, "hail": 0.0, "gust": 0.15},
	# Never picked directly: the grey build-up before any rain, hail or snow.
	"gathering": {"weight": 0.0, "clouds": [0.84, 1.7, 0.5], "sun": 0.45, "overcast": 0.6, "fog": 0.02, "rain": 0.0, "snow": 0.0, "hail": 0.0, "gust": 0.3},
	"blizzard":  {"weight": 0.3, "clouds": [0.98, 2.4, 0.7], "sun": 0.15, "overcast": 1.0, "fog": 0.55, "rain": 0.0, "snow": 1.0, "hail": 0.0, "gust": 1.0},
}
const WORDS := {"clear": "clear skies", "cloudy": "cloudy, grey patches over the sun", "windy": "very windy, gusts shaking the grass and trees",
	"mist": "a light mist over the ground", "fog": "thick fog, you can barely see far", "drizzle": "drizzling, a fine light rain",
	"sunshower": "a sunshower: raining while the sun is out", "rain": "raining steadily", "storm": "a thunderstorm: heavy rain, thunder and lightning",
	"hail": "hailing, little ice pellets bouncing everywhere", "gathering": "grey clouds gathering, it looks like it will rain soon", "snow": "snowing", "blizzard": "a blizzard: driving snow and howling wind"}
const BLEND_SECONDS := 45.0
## Seasons (dev 2026-09-23): one every Settings "Season length" in-game days, spring first, each
## with its own weather odds. The look and the formula live in world/seasons/season_state.gd.
const SEASON_DAYS := 20
const SEASONS := ["spring", "summer", "autumn", "winter"]
const SEASON_STATE := preload("res://world/seasons/season_state.gd")
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const SEASON_LOOK := SEASON_STATE.SEASON_LOOK
## Weather odds multiplied per season: no snow outside winter, winter rain falls as snow.
const SEASON_WEATHER := {
	"spring": {"rain": 1.4, "drizzle": 1.5, "sunshower": 1.6, "hail": 1.3, "mist": 1.3, "storm": 0.8, "snow": 0.0, "blizzard": 0.0},
	"summer": {"rain": 0.7, "drizzle": 0.8, "sunshower": 1.3, "hail": 1.0, "mist": 0.6, "storm": 1.6, "clear": 1.3, "snow": 0.0, "blizzard": 0.0},
	"autumn": {"rain": 1.5, "drizzle": 1.4, "sunshower": 0.4, "hail": 0.3, "mist": 1.8, "fog": 1.6, "cloudy": 1.3, "windy": 1.7, "snow": 0.0, "blizzard": 0.0},
	"winter": {"rain": 0.0, "drizzle": 0.0, "sunshower": 0.0, "hail": 0.2, "storm": 0.0, "snow": 3.0, "blizzard": 1.0, "fog": 1.2, "mist": 1.0, "cloudy": 1.3, "windy": 1.3},
}
## Snow odds in the last quarter of autumn (season_state lets a light dusting lie then).
const LATE_AUTUMN_SNOW := 0.3
var season := "spring"
## The F1 debug steps and the season look, now season_state's (kept for older callers and tests).
var _season_offset: int:
	get:
		var state := _seasons()
		return int(state.get("offset")) if state != null else 0
	set(value):
		var state := _seasons()
		if state != null: state.set("offset", value)
var _season_look: Dictionary:
	get:
		var state := _seasons()
		return state.call("look") if state != null else {}
var _season_state: Node
var _own_season_state := false
## Climate under the camera when the weather last changed: x snow allowed, y wetness response.
var _climate_bias := Vector2.ONE
var _rain_material: StandardMaterial3D
var _snow_material: StandardMaterial3D
## Life owner that sends ponies home in the wet (made by setup() beside Weather when the game has
## a population, so the chess pack's game.gd needs no new line).
const SHELTER := preload("res://world/life/weather_shelter.gd")
## Heavy rain, hail or a blizzard (wet), snow falling or winter (cold), or snow starting/stopping
## changed. Emitted on the 0.25 s apply beat only when one of them flips; never per frame.
signal conditions_changed(wet: bool, cold: bool)
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CATALOGUE := preload("res://world/audio/environment_catalogue.gd")
const RAIN_RECORDING := preload("res://world/audio/designed/environment/rain_outdoors.ogg")

var game: Node
var kind := "clear"
var params := {}          # current blended values
var _from := {}
var _to := {}
var _blend := 1.0
var _next_change := 0.0
var _pinned := ""
var _rain: GPUParticles3D
var _snow: GPUParticles3D
## Snowfall look (dev 2026-11-10: "the snow particle effects isn't right ... they never actually
## FALL down"). The fall is a field of flakes around the eye (world/weather/snow_field.gd, which
## explains why the emitter could not do it) and the air itself closes in (LOOK_SNOW_AIR).
## The emitter below stays for rollback only. Rollback: LOOK_SNOW = false.
const LOOK_SNOW := true
const LOOK_SNOW_FIELD := preload("res://world/weather/snow_field.gd")
## A flake hangs in open air with the whole sky around it; the ground under it sees half the sky.
## So it carries the fill light this many times on top of what a surface gets.
const LOOK_SNOW_SKY_LIGHT := 1.1
## Falling snow fills the air: at full snowfall this much of the view closes in (the sky
## controller turns it into haze range and colour). 0 = flakes over a clear scene, as before.
const LOOK_SNOW_AIR := 0.6
var _snow_field: Node3D
var _hail: GPUParticles3D
var _base_wind := {}     # grass ring material -> its calm wind
var _rain_sound: AudioStreamPlayer
var _rain_target := -80.0
var _rain_gain := -80.0
var _roof_handle := 0
var _audio_timer := 0.0
var _flash: DirectionalLight3D
var _lightning_in := 8.0
var _apply_timer := 0.0
var _published_wet := false
var _published_cold := false
var _published_snowing := false
var _precipitation_timer := 0.0
var _precipitation_active := false
var _precipitation_state: Array = []
var _weather_particles := true
var _weather_particle_scale := 1.0
var _sky_state: Array = []
## dev 2026-10-20 perf pass: the roof heightfield re-renders every piece of geometry in its
## 64 m box from above each time it steps after the camera (every metre walked or flown), even
## on dry days when nothing falls. It now follows the camera only while rain, snow or hail is
## emitting; the drops never see it otherwise. false restores the always-following field.
const ROOFS_FOLLOW_ONLY_WHILE_FALLING := true
var _roofs: GPUParticlesCollisionHeightField3D

func setup(host: Node) -> void:
	game = host
	add_to_group("weather")
	_refresh_particle_settings()
	var settings: Node = get_node_or_null("/root/Settings")
	if settings != null and not settings.changed.is_connected(_on_settings_changed): settings.changed.connect(_on_settings_changed)
	var quality: Node = get_node_or_null("/root/Quality")
	if quality != null and not quality.preset_changed.is_connected(_on_quality_changed): quality.preset_changed.connect(_on_quality_changed)
	var pinned := SEASON_STATE._arg(preload("res://world/dev_tools.gd").user_args(), "--weather")
	if KINDS.has(pinned): _pinned = pinned
	kind = _pinned if _pinned != "" else "clear"
	params = KINDS[kind].duplicate(); _from = params.duplicate(); _to = params.duplicate()
	_next_change = randf_range(180.0, 420.0)
	_build_precipitation()
	# Rain and snow stop on whatever is above the ground: a top-down heightfield of the
	# world around the camera (roofs, trees, porches), refreshed as the camera moves.
	var roofs := GPUParticlesCollisionHeightField3D.new(); roofs.name = "PrecipitationRoofs"
	roofs.size = Vector3(64, 60, 64)
	roofs.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
	roofs.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	roofs.follow_camera_enabled = not ROOFS_FOLLOW_ONLY_WHILE_FALLING
	add_child(roofs)
	_roofs = roofs
	_build_audio()
	_flash = DirectionalLight3D.new(); _flash.name = "LightningFlash"
	_flash.light_color = Color(0.82, 0.86, 1.0); _flash.light_energy = 0.0; _flash.shadow_enabled = false
	# Between strikes it lights nothing: a visible directional light is worked out for every lit
	# pixel even at zero energy. The mask, not `visible`, so the sky shader's light order stays.
	_flash.light_cull_mask = 0
	_flash.rotation_degrees = Vector3(-70, 20, 0); add_child(_flash)
	_published_wet = is_wet(); _published_cold = is_cold(); _published_snowing = is_snowing()
	if host != null and host.get("population") != null and host.get_node_or_null("WeatherShelter") == null:
		var shelter := SHELTER.new(); shelter.name = "WeatherShelter"
		host.add_child(shelter); shelter.setup(host, self)

func describe() -> String:
	return WORDS.get(kind, "")

## "early autumn", "winter", "late spring": thirds of the season at any season length (M-SEA-03).
func describe_season() -> String:
	var state := _seasons()
	return str(state.call("describe_season")) if state != null else season

## The current weather for the save (world_context.state.seasons.weather, written by season_state).
func save_state() -> Dictionary:
	var kept := {}
	for key: String in params:
		if params[key] is float or params[key] is int: kept[key] = snappedf(float(params[key]), 0.001)
	return {"kind": kind, "queued": _queued, "next_change": snappedf(_next_change, 0.1), "params": kept}

## Back to a saved weather (a load mid-blizzard is a blizzard), sky included. A --weather pin wins.
func restore_state(data: Dictionary) -> bool:
	if _pinned != "" or not KINDS.has(str(data.get("kind", ""))): return false
	kind = str(data.kind)
	var queued := str(data.get("queued", ""))
	_queued = queued if KINDS.has(queued) else ""
	_to = (KINDS[kind] as Dictionary).duplicate()
	params = _to.duplicate()
	var saved: Variant = data.get("params")
	if saved is Dictionary:
		for key: String in params:
			var value: Variant = (saved as Dictionary).get(key)
			if key != "clouds" and (value is float or value is int) and is_finite(float(value)): params[key] = float(value)
	_from = params.duplicate()
	# Saved mid-blend: finish the blend toward the kind's own values.
	_blend = 1.0 if params == _to else 0.0
	var next: Variant = data.get("next_change")
	_next_change = clampf(float(next), 1.0, 1200.0) if (next is float or next is int) and is_finite(float(next)) else randf_range(180.0, 420.0)
	_precipitation_timer = 0.0; _precipitation_state.clear(); _sky_state.clear()
	if is_inside_tree():
		_apply_sky()
		var sky: Node = get_tree().get_first_node_in_group("sky_controller")
		if sky != null and sky.has_method("snap_clouds"): sky.snap_clouds()
	print("[weather] restored ", kind, (" -> " + _queued) if _queued != "" else "")
	return true

# ------------------------------------------------------------------ state
func _process(delta: float) -> void:
	if game == null: return
	if _label_time > 0.0:
		_label_time -= delta
		if _label_time <= 0.0: _label.visible = false
	_next_change -= delta
	if _next_change <= 0.0 and _pinned == "":
		if _queued != "": _change(_queued, true)
		else: _change(_pick())
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / BLEND_SECONDS)
		for k in _to:
			if k == "clouds": continue
			if _to[k] is float: params[k] = lerpf(float(_from[k]), float(_to[k]), smoothstep(0.0, 1.0, _blend))
	_apply_timer -= delta
	if _apply_timer <= 0.0:
		_apply_timer = 0.25
		_apply_sky()
		_update_season()
		_publish_conditions()
	_update_precipitation(delta)
	_update_weather_audio(delta)
	_update_lightning(delta)

## Chance that a given day brings any rain, storm or snow at all (dev 2026-09-23: rain
## much rarer, skewed by season). Dry days only get clear, cloudy or fog.
const WET_DAY := {"spring": 0.25, "summer": 0.12, "autumn": 0.28, "winter": 0.22}
const WET_KINDS := ["rain", "storm", "snow", "drizzle", "sunshower", "hail", "blizzard"]

func wet_day() -> bool:
	var clock := get_node_or_null("/root/TimeOfDay")
	var day := int(clock.day) if clock != null else 0
	return float(absi(hash("wet" + str(day))) % 1000) / 1000.0 < float(WET_DAY.get(season, 0.2)) * _frequency()

func _odds(k: String) -> float:
	if k in WET_KINDS and not wet_day(): return 0.0
	var wet := _frequency() if k in WET_KINDS else 1.0
	var by_season := float(SEASON_WEATHER[season].get(k, 1.0))
	if k == "snow" and season == "autumn" and _late_autumn(): by_season = LATE_AUTUMN_SNOW
	# The biome under the camera: no snow where it cannot lie, the desert seldom wet.
	var place := _climate_bias.y if k in WET_KINDS else 1.0
	if k in ["snow", "blizzard"]: place *= _climate_bias.x
	return float(KINDS[k].weight) * (0.35 if k == kind else 1.0) * by_season * wet * place

func _late_autumn() -> bool:
	var state := _seasons()
	return state != null and float(state.call("progress")) >= SEASON_STATE.LATE_AUTUMN

## Climate (world/seasons/climate_map.gd) at the camera: x snow susceptibility, y wetness response.
func _camera_climate() -> Vector2:
	var cam := preload("res://world/player_view.gd").camera(self) if is_inside_tree() else null
	if cam == null: return Vector2.ONE
	var xz := Vector2(cam.global_position.x, cam.global_position.z)
	return Vector2(snappedf(CLIMATE.sample(xz, 0), 0.05), snappedf(CLIMATE.sample(xz, 2), 0.05))

## Player settings (Settings autoload): season length in days, and a multiplier on how
## often days turn wet and how likely wet kinds are once they do (0 = never).
func _season_days() -> int:
	var settings := get_node_or_null("/root/Settings")
	return maxi(1, int(settings.season_days())) if settings != null else SEASON_DAYS

func _frequency() -> float:
	var settings := get_node_or_null("/root/Settings")
	return float(settings.weather_frequency()) if settings != null else 1.0

func _setting(key: String, fallback: Variant) -> Variant:
	var settings := get_node_or_null("/root/Settings")
	return settings.get_value(key) if settings != null else fallback

func _refresh_particle_settings() -> void:
	_weather_particles = bool(_setting("video/weather_particles", true))
	var quality: Node = get_node_or_null("/root/Quality")
	_weather_particle_scale = float(quality.get_value("weather_particle_scale", 1.0)) if quality != null else 1.0
	_precipitation_timer = 0.0; _precipitation_state.clear(); _sky_state.clear()

func _on_settings_changed(key: String) -> void:
	if key in ["video/weather_particles", "video/quality", "video/quality_base"]: _refresh_particle_settings()

func _on_quality_changed(_preset: int) -> void:
	_refresh_particle_settings()

func _pick() -> String:
	_climate_bias = _camera_climate()
	var total := 0.0
	for k in KINDS: total += _odds(k)
	var roll := randf() * total
	for k in KINDS:
		roll -= _odds(k)
		if roll <= 0.0: return k
	return "clear"

## The game's season_state (group "season_state"); a Weather standing alone (tests) makes its
## own, ticked from here, so the season and its look still follow the clock.
func _seasons() -> Node:
	if is_instance_valid(_season_state) and _season_state.is_inside_tree(): return _season_state
	if not is_inside_tree(): return null
	var found: Node = get_tree().get_first_node_in_group(SEASON_STATE.GROUP)
	_own_season_state = false
	if found == null:
		found = SEASON_STATE.new(); found.set("auto_tick", false); found.name = "SeasonState"
		add_child(found)
		_own_season_state = true
	_season_state = found
	return found

## The season follows season_state (the whole day number only: the time of day never changes its
## colours). season_state writes the uniforms and re-renders the grass probe.
func _update_season() -> void:
	var state := _seasons()
	if state == null: return
	if _own_season_state: state.call("tick")
	season = str(state.call("season"))

var _queued := ""

## Rain never arrives out of a clear sky: before any wet weather (a sunshower excepted)
## the sky greys over for 2-4 in-game hours first (dev 2026-09-23).
func _change(to: String, arriving := false) -> void:
	_precipitation_timer = 0.0; _sky_state.clear()
	_queued = ""
	if not arriving and to in WET_KINDS and to != "sunshower" and not (kind in WET_KINDS) and kind != "gathering":
		_queued = to
		to = "gathering"
	kind = to
	_from = params.duplicate(); _to = KINDS[to].duplicate(); _blend = 0.0
	if to == "gathering":
		_next_change = randf_range(2.0, 4.0) * _seconds_per_game_hour()
	else:
		_next_change = randf_range(240.0, 600.0) * (0.6 if to in ["storm", "fog"] else 1.0)
	print("[weather] ", to, (" -> " + _queued) if _queued != "" else "")

func _seconds_per_game_hour() -> float:
	var clock := get_node_or_null("/root/TimeOfDay")
	return (float(clock.day_length_minutes) * 60.0 / 24.0) if clock != null else 75.0

## For tests and the console: switch now, optionally without blending.
func force(to: String, instant := false) -> void:
	if not KINDS.has(to): return
	_change(to, true)
	if instant:
		_blend = 1.0; params = _to.duplicate()
		_apply_sky()
		var sky: Node = get_tree().get_first_node_in_group("sky_controller")
		if sky != null and sky.has_method("snap_clouds"): sky.snap_clouds()

var _label: Label
var _label_time := 0.0

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo: return
	if not preload("res://world/dev_tools.gd").enabled(): return
	var key: int = event.physical_keycode
	if key == KEY_F1:
		var state := _seasons()
		if state != null: state.call("step_season")
		_update_season()
		for grass in get_tree().root.find_children("GroundGrass", "", true, false):
			if grass.has_method("notify_terrain_changed"): grass.notify_terrain_changed()
		_note("Season: " + season + "  (F1 next season)")
		get_viewport().set_input_as_handled()
	elif key == KEY_F2:
		var order: Array = KINDS.keys()
		var next: String = order[posmod(order.find(kind) + (-1 if event.shift_pressed else 1), order.size())]
		force(next, true)
		_note("Weather: " + next + "  (F2 next · Shift+F2 back · F3 lightning)")
		get_viewport().set_input_as_handled()
	elif key == KEY_F3 and not event.shift_pressed:
		_strike()
		_note("Lightning")
		get_viewport().set_input_as_handled()

func _note(text: String) -> void:
	if _label == null:
		var layer := CanvasLayer.new(); layer.layer = 30; add_child(layer)
		_label = Label.new(); _label.position = Vector2(20, 120)
		_label.add_theme_font_size_override("font_size", 22)
		_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_label.add_theme_constant_override("outline_size", 6)
		layer.add_child(_label)
	_label.text = text; _label.visible = true; _label_time = 3.0

func _apply_sky() -> void:
	var sky: Node = get_tree().get_first_node_in_group("sky_controller")
	if sky == null: return
	var c: Array = _to.clouds
	var grass: Node = WorldTerrain.instance.get_node_or_null("GroundGrass") if is_instance_valid(WorldTerrain.instance) else null
	var materials: Array = []
	if grass != null:
		for ring in grass.get("rings"): materials.append(ring.material.get_rid())
	var ambience: Node = game.get_node_or_null("Ambience") if game != null else null
	var sky_material: Variant = sky.get("_sky_material")
	var state: Array = [sky.get_instance_id(), sky_material.get_instance_id() if is_instance_valid(sky_material) else 0, c,
		float(params.sun), float(params.overcast), float(params.fog), float(params.gust), materials, ambience.get_instance_id() if ambience != null else 0]
	if state == _sky_state: return
	_sky_state = state.duplicate(true)
	if float(c[0]) < 0.0: sky.set_cloud_weather(-1.0)
	else: sky.set_cloud_weather(float(c[0]), float(c[1]), float(c[2]))
	sky.set_weather_light(float(params.sun), float(params.overcast), float(params.fog))
	_apply_wind(sky, float(params.gust))

## Windy weather: grass bends harder, clouds race, the wind sound gusts often.
func _apply_wind(sky: Node, gust: float) -> void:
	# One grass node, under the terrain; searching the whole tree cost ~3 ms per call.
	var grass: Node = WorldTerrain.instance.get_node_or_null("GroundGrass") if is_instance_valid(WorldTerrain.instance) else null
	if grass != null:
		for ring in grass.get("rings"):
			var mat: ShaderMaterial = ring.material
			if not _base_wind.has(mat): _base_wind[mat] = mat.get_shader_parameter("wind") if mat.get_shader_parameter("wind") != null else Vector2(0.8, 0.35)
			mat.set_shader_parameter("wind", (_base_wind[mat] as Vector2) * (1.0 + gust * 3.0))
	if sky.has_method("set_cloud_wind"): sky.set_cloud_wind(1.0 + gust * 3.0)
	var ambience: Node = game.get_node_or_null("Ambience") if game != null else null
	if ambience != null and "wind_quiet_seconds" in ambience:
		ambience.wind_quiet_seconds = Vector2(90.0, 180.0).lerp(Vector2(3.0, 10.0), gust)
		ambience.wind_gust_seconds = Vector2(8.0, 14.0).lerp(Vector2(12.0, 25.0), gust)

# ------------------------------------------------------------------ rain and snow
func _build_precipitation() -> void:
	_rain = _particles("Rain", 9000, 1.8, Vector3(24, 1, 24), Vector3(0, -15.0, 0), 0.15)
	var streak := QuadMesh.new(); streak.size = Vector2(0.012, 0.55)
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = RAIN_COLOR
	rm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	rm.billboard_keep_scale = true
	streak.material = rm
	_rain_material = rm
	_rain.draw_pass_1 = streak
	# Snow drifts down from 18 m and lives long enough to reach the ground (and settle on roofs).
	_snow = _particles("Snow", 9000, 17.0, Vector3(26, 1, 26), Vector3(0, -1.25, 0), 0.4)
	var flake := QuadMesh.new(); flake.size = Vector2(0.09, 0.09)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var dot := GradientTexture2D.new(); dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5); dot.fill_to = Vector2(1.0, 0.5)
	var g := Gradient.new(); g.set_color(0, Color(1, 1, 1, 1)); g.set_color(1, Color(1, 1, 1, 0)); dot.gradient = g
	sm.albedo_texture = dot
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	flake.material = sm
	_snow_material = sm
	_snow.draw_pass_1 = flake
	var pm: ParticleProcessMaterial = _snow.process_material
	pm.turbulence_enabled = true; pm.turbulence_noise_strength = 1.4; pm.turbulence_noise_scale = 4.0
	if LOOK_SNOW:
		_snow_field = LOOK_SNOW_FIELD.new(); _snow_field.name = "SnowField"
		add_child(_snow_field)
	# Hail: small white pellets, falling fast and bouncing off roofs and the ground.
	_hail = _particles("Hail", 3500, 2.2, Vector3(22, 1, 22), Vector3(0, -17.0, 0), 0.1)
	var pellet := QuadMesh.new(); pellet.size = Vector2(0.035, 0.035)
	var hm := StandardMaterial3D.new()
	hm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	hm.albedo_texture = dot; hm.albedo_color = Color(0.95, 0.97, 1.0); hm.roughness = 0.3
	hm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	pellet.material = hm
	_hail.draw_pass_1 = pellet
	var hp: ParticleProcessMaterial = _hail.process_material
	hp.gravity = Vector3(0, -9.8, 0)
	hp.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	hp.collision_bounce = 0.35; hp.collision_friction = 0.4

const RAIN_COLOR := Color(0.78, 0.84, 0.95, 0.38)

## Unshaded drops would glow at full brightness on a dark night (M-SEA-06): they take the sky's
## light level instead (daylight, the moon, overcast), in 0.02 steps so the materials change rarely.
func _sky_light() -> float:
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	if clock == null or not clock.has_method("daylight"): return 1.0
	var daylight := float(clock.call("daylight"))
	var moon := float(clock.call("moon_lit_fraction")) if clock.has_method("moon_lit_fraction") else 0.5
	var sky: Node = get_tree().get_first_node_in_group("sky_controller") if is_inside_tree() else null
	var overcast := float(sky.get("weather_overcast")) if sky != null and sky.get("weather_overcast") != null else float(params.get("overcast", 0.0))
	return snappedf(lerpf(0.07 + 0.1 * moon, 1.0, daylight) * lerpf(1.0, 0.75, overcast), 0.02)

func _apply_drop_light(level: float) -> void:
	if _rain_material != null: _rain_material.albedo_color = Color(RAIN_COLOR.r * level, RAIN_COLOR.g * level, RAIN_COLOR.b * level, RAIN_COLOR.a)
	if _snow_material != null:
		if LOOK_SNOW:
			# The flakes are lit by the scene itself (snow_flake.gdshader), plus the sky's fill light.
			var glow := Color(0.5, 0.6, 0.9) * 0.2
			var sky: Node = get_tree().get_first_node_in_group("sky_controller") if is_inside_tree() else null
			var env: Environment = sky.get("environment") as Environment if sky != null else null
			if env != null: glow = env.ambient_light_color * env.ambient_light_energy * LOOK_SNOW_SKY_LIGHT
			if _snow_field != null: _snow_field.call("set_sky_light", glow)
		else:
			_snow_material.albedo_color = Color(level, level, level, 1.0)

func _particles(name: String, amount: int, lifetime: float, extents: Vector3, velocity: Vector3, spread: float) -> GPUParticles3D:
	var p := GPUParticles3D.new(); p.name = name
	p.amount = amount; p.lifetime = lifetime; p.local_coords = false
	p.amount_ratio = 0.0; p.emitting = false
	p.visibility_aabb = AABB(Vector3(-32, -40, -32), Vector3(64, 50, 64))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = extents
	m.direction = velocity.normalized(); m.spread = spread * 30.0
	m.initial_velocity_min = velocity.length() * 0.85; m.initial_velocity_max = velocity.length() * 1.1
	m.gravity = Vector3.ZERO
	# Stop at roofs, trees and the ground (the heightfield collider below follows the camera).
	m.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	p.process_material = m
	add_child(p)
	return p

func _update_precipitation(delta := 0.0) -> void:
	var wet: bool = float(params.get("rain", 0.0)) > 0.01 or float(params.get("snow", 0.0)) > 0.01 or float(params.get("hail", 0.0)) > 0.01
	if not wet:
		if _precipitation_active:
			for emitter: GPUParticles3D in [_rain, _snow, _hail]:
				emitter.emitting = false; emitter.amount_ratio = 0.0
			if _snow_field != null: _snow_field.call("set_fall", 0.0, 0.0, Vector3.ZERO, false)
			_rain_target = -80.0
			_set_roofs_follow(false)
			var clear_sky: Node = get_tree().get_first_node_in_group("sky_controller")
			if clear_sky != null and clear_sky.has_method("set_weather_snow"): clear_sky.call("set_weather_snow", 0.0)
		_precipitation_active = false; _precipitation_state.clear(); _precipitation_timer = 0.0
		return
	var cam := preload("res://world/player_view.gd").camera(self)
	if cam == null: return
	_precipitation_timer -= delta
	if _precipitation_timer > 0.0 and _precipitation_active:
		_follow_precipitation(cam); return
	_precipitation_timer = 0.2; _precipitation_active = true
	var indoors: bool = _precipitation_indoors(cam)
	# "Rain & snow particles" off hides the drops; the sky, light and sound still change.
	var particles: bool = _weather_particles
	var rain := 0.0 if indoors or not particles else float(params.rain)
	# Snow only falls where it can lie (climate map: none over the desert, jungle or beach).
	# Indoors the new fall is hidden, not stopped: it is already in the air when the player steps
	# out, instead of starting from the sky again.
	var snow := 0.0 if (indoors and not LOOK_SNOW) or not particles else float(params.snow) * snappedf(CLIMATE.sample(Vector2(cam.global_position.x, cam.global_position.z), 0), 0.05)
	var hail := 0.0 if indoors or not particles else float(params.hail)
	# Quality tiers thin the drops (weather_particle_scale: Low 0.7, Very Low 0.4); never off by preset.
	var scale: float = _weather_particle_scale
	rain *= scale; snow *= scale; hail *= scale
	# Wind drives rain and snow sideways (blizzards nearly horizontal).
	var gust := float(params.gust)
	var push := Vector3(1.0, 0.0, 0.35).normalized() * gust
	var rain_heard := maxf(float(params.rain), float(params.hail) * 0.8)
	var light := _sky_light() if rain > 0.01 or snow > 0.01 else -1.0
	var state: Array = [rain, snow, hail, push, rain_heard, indoors, light]
	if state != _precipitation_state:
		_precipitation_state = state
		if light >= 0.0: _apply_drop_light(light)
		_rain.amount_ratio = rain; _rain.emitting = rain > 0.01
		_snow.amount_ratio = 0.0 if LOOK_SNOW else snow; _snow.emitting = snow > 0.01 and not LOOK_SNOW
		_hail.amount_ratio = hail; _hail.emitting = hail > 0.01
		_set_roofs_follow(_rain.emitting or _snow.emitting or _hail.emitting)
		(_rain.process_material as ParticleProcessMaterial).gravity = push * 4.0
		if LOOK_SNOW:
			if _snow_field != null: _snow_field.call("set_fall", snow, gust, push, indoors)
			var sky_node: Node = get_tree().get_first_node_in_group("sky_controller")
			if sky_node != null and sky_node.has_method("set_weather_snow"): sky_node.call("set_weather_snow", clampf(float(params.snow) * LOOK_SNOW_AIR, 0.0, 1.0))
		else:
			(_snow.process_material as ParticleProcessMaterial).gravity = push * 3.5
		# A recording of rain stays at its natural pitch; ice does not make rain squeak.
		_rain_target = linear_to_db(maxf(rain_heard, .0001) * (.12 if indoors else 1.0)) - 24.0
	_follow_precipitation(cam)

## Drops already falling when emission stops keep the field where they are (it stays put).
## Turning it on again snaps it to the camera and redraws it once, before the new drops land.
func _set_roofs_follow(on: bool) -> void:
	if not ROOFS_FOLLOW_ONLY_WHILE_FALLING or not is_instance_valid(_roofs): return
	if _roofs.follow_camera_enabled != on: _roofs.follow_camera_enabled = on

func _precipitation_indoors(cam: Camera3D) -> bool:
	return preload("res://world/buildings/house_interior.gd").at(get_tree(), cam.global_position - Vector3.UP * 1.2) != null

func _follow_precipitation(cam: Camera3D) -> void:
	if _rain.emitting: _rain.global_position = cam.global_position + Vector3.UP * 14.0
	if _snow.emitting: _snow.global_position = cam.global_position + Vector3.UP * 18.0
	if _hail.emitting: _hail.global_position = cam.global_position + Vector3.UP * 14.0

# ------------------------------------------------------------------ sound
func _build_audio() -> void:
	SOUNDS.register_catalogue(self, CATALOGUE.EVENTS)
	_rain_sound = AudioStreamPlayer.new(); _rain_sound.name = "RainSound"
	_rain_sound.stream = RAIN_RECORDING.duplicate()
	(_rain_sound.stream as AudioStreamOggVorbis).loop = true
	_rain_sound.volume_db = -80.0
	add_child(_rain_sound)
	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		settings.route(_rain_sound, "WorldAmbience")
	else: _rain_sound.bus = "WorldAmbience" if AudioServer.get_bus_index("WorldAmbience") >= 0 else "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"


func _update_weather_audio(delta: float) -> void:
	if not is_instance_valid(_rain_sound): return
	_rain_gain = lerpf(_rain_gain, _rain_target, 1.0 - exp(-delta * 4.0))
	_rain_sound.volume_db = _rain_gain
	if _rain_target > -65.0 and not _rain_sound.playing: _rain_sound.play()
	elif _rain_gain < -65.0 and _rain_target <= -65.0 and _rain_sound.playing: _rain_sound.stop()
	_audio_timer -= delta
	if _audio_timer > 0.0: return
	_audio_timer = .35
	var cam := preload("res://world/player_view.gd").camera(self)
	if cam == null: return
	var ambience: Node = game.get_node_or_null("Ambience") if is_instance_valid(game) else null
	var room: Node3D = ambience.get("room") as Node3D if is_instance_valid(ambience) and "room" in ambience else null
	var rain := maxf(float(params.get("rain", 0.0)), float(params.get("hail", 0.0)) * .8)
	var gain := rain if is_instance_valid(room) else 0.0
	if gain > .01:
		if _roof_handle == 0: _roof_handle = SOUNDS.start_loop(self, "env_rain_roof", {"intensity": gain})
		if _roof_handle != 0 and not SOUNDS.update_loop(self, _roof_handle, {"intensity": gain}, cam.global_position): _roof_handle = 0
	elif _roof_handle != 0:
		SOUNDS.stop_loop(self, _roof_handle, .6)
		_roof_handle = 0
	# Use the same door-aware shelter as wildlife; no second room scan for sound.
	if is_instance_valid(ambience) and "outdoor_gain" in ambience and rain > .01:
		_rain_target = -24.0 + linear_to_db(maxf(rain * float(ambience.get("outdoor_gain")), .0001))

# ------------------------------------------------------------------ lightning
func _update_lightning(delta: float) -> void:
	if kind != "storm" or _blend < 0.5: return
	_lightning_in -= delta
	if _lightning_in > 0.0: return
	_lightning_in = randf_range(6.0, 22.0)
	_strike()

func _strike() -> void:
	var distance := randf_range(250.0, 3200.0)
	var flash := clampf(2600.0 / distance, 0.4, 4.0)
	# Reduced motion: a soft single brightening instead of strobing flashes.
	if bool(_setting("access/reduced_motion", false)): flash = minf(flash, 0.5)
	_flash.light_cull_mask = 0xFFFFFFFF
	var tween := create_tween()
	for strobe in [flash, flash * 0.3, flash * 0.9, 0.0]:
		tween.tween_property(_flash, "light_energy", strobe, 0.05)
	tween.tween_property(_flash, "light_energy", 0.0, 0.25)
	tween.tween_callback(func() -> void:
		if is_instance_valid(_flash) and _flash.light_energy <= 0.0: _flash.light_cull_mask = 0)
	# Sound travels ~343 m/s: far strikes rumble late and soft.
	# A bound method loses its connection with the Weather owner on world exit.
	get_tree().create_timer(distance / 343.0).timeout.connect(_play_thunder.bind(distance))


func _play_thunder(distance: float) -> void:
	if not is_inside_tree(): return
	var cam := preload("res://world/player_view.gd").camera(self)
	if cam == null: return
	SOUNDS.play_event(self, "env_thunder", {"intensity": clampf(900.0 / distance, .12, 1.0)}, cam.global_position)

# ------------------------------------------------------------------ wet and cold, for life owners
## Wet enough to send ponies indoors: steady rain, hail or a blizzard. Plain snow is not (M-SEA-07:
## light snow no longer sends everypony home; some go out to play in it).
func is_wet() -> bool:
	if params.is_empty(): return false
	return float(params.rain) > 0.35 or float(params.hail) > 0.4 or (float(params.snow) > 0.45 and float(params.gust) > 0.6)

func is_snowing() -> bool:
	return not params.is_empty() and float(params.snow) > 0.2

func is_cold() -> bool:
	return is_snowing() or season == "winter"

func _publish_conditions() -> void:
	var wet := is_wet()
	var cold := is_cold()
	var snowing := is_snowing()
	if wet == _published_wet and cold == _published_cold and snowing == _published_snowing: return
	_published_wet = wet; _published_cold = cold; _published_snowing = snowing
	conditions_changed.emit(wet, cold)
