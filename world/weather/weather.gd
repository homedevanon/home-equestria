extends Node3D
## Mist and fog weights lowered (dev 2026-10-02: "lower the frequency of fog"; halved again 2026-10-14): about 1 dry spell in
## 24 (was 12, before that 5).
## Random weather (dev 2026-09-23): clear, cloudy, rain, thunderstorm, snow and fog spells of
## a few minutes each, blending into one another. Drives the volumetric clouds and the sun,
## ambient and fog through SkyController; rain and snow fall around the camera (not inside
## houses); storms flash lightning with recorded thunder delayed by distance. Most ponies with a home go indoors in rain and snow
## and come out again when it clears; pony_awareness reads describe() for dialogue.
## `-- --weather <kind>` pins a kind for testing. Debug keys: F1 next season, F2 next weather (Shift+F2
## previous), instant, clouds included; F3 a lightning strike with thunder right now.
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
## Seasons (dev 2026-09-23): one every 20 in-game days, spring first. Each sets the global
## shader values leaves/ground/grass/flowers read, and its own weather odds. A season's look
## arrives whole when its first day begins (dev 2026-10-01: the old three-day blend moved the
## grass and tree colours every in-game hour and looked bad and weird). F1 steps the season.
const SEASON_DAYS := 20
const SEASONS := ["spring", "summer", "autumn", "winter"]
const SEASON_LOOK := {
	"spring": {"leaf": Color(0.45, 0.85, 0.35), "leaf_amount": 0.25, "ground": Color(0.5, 0.85, 0.35), "ground_amount": 0.2, "snow": 0.0, "flowers": 1.8},
	"summer": {"leaf": Color(0.3, 0.6, 0.2), "leaf_amount": 0.0, "ground": Color(0.55, 0.75, 0.3), "ground_amount": 0.0, "snow": 0.0, "flowers": 1.0},
	"autumn": {"leaf": Color(1.0, 0.42, 0.08), "leaf_amount": 0.9, "ground": Color(0.82, 0.66, 0.28), "ground_amount": 0.6, "snow": 0.0, "flowers": 0.25},
	"winter": {"leaf": Color(0.55, 0.5, 0.42), "leaf_amount": 0.55, "ground": Color(0.7, 0.7, 0.62), "ground_amount": 0.5, "snow": 0.85, "flowers": 0.0},
}
## Weather odds multiplied per season: no snow outside winter, winter rain falls as snow.
const SEASON_WEATHER := {
	"spring": {"rain": 1.4, "drizzle": 1.5, "sunshower": 1.6, "hail": 1.3, "mist": 1.3, "storm": 0.8, "snow": 0.0, "blizzard": 0.0},
	"summer": {"rain": 0.7, "drizzle": 0.8, "sunshower": 1.3, "hail": 1.0, "mist": 0.6, "storm": 1.6, "clear": 1.3, "snow": 0.0, "blizzard": 0.0},
	"autumn": {"rain": 1.5, "drizzle": 1.4, "sunshower": 0.4, "hail": 0.3, "mist": 1.8, "fog": 1.6, "cloudy": 1.3, "windy": 1.7, "snow": 0.0, "blizzard": 0.0},
	"winter": {"rain": 0.0, "drizzle": 0.0, "sunshower": 0.0, "hail": 0.2, "storm": 0.0, "snow": 3.0, "blizzard": 1.0, "fog": 1.2, "mist": 1.0, "cloudy": 1.3, "windy": 1.3},
}
var season := "spring"
var _season_offset := 0   # F1 debug steps
var _season_look := {}
var _probe_snow := -1.0
var _probe_ground := -1.0
var _probe_ground_color := Color(-1, -1, -1)
const SHELTER_OWNER := "weather:"
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
var _shelter_timer := 0.0
var _sheltering := {}     # resident id -> true
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
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--weather")
	if at >= 0 and at + 1 < args.size() and KINDS.has(args[at + 1]): _pinned = args[at + 1]
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
	_flash.rotation_degrees = Vector3(-70, 20, 0); add_child(_flash)

func describe() -> String:
	return WORDS.get(kind, "")

func describe_season() -> String:
	var clock := get_node_or_null("/root/TimeOfDay")
	var into := int(fmod(float(clock.day) + _season_offset * _season_days(), _season_days())) if clock != null else 0
	return ("early " if into < 7 else ("late " if into >= 14 else "")) + season

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
	_update_precipitation(delta)
	_update_weather_audio(delta)
	_update_lightning(delta)
	_shelter_timer -= delta
	if _shelter_timer <= 0.0:
		_shelter_timer = 3.0
		_update_shelter()

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
	return float(KINDS[k].weight) * (0.35 if k == kind else 1.0) * float(SEASON_WEATHER[season].get(k, 1.0)) * wet

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
	var total := 0.0
	for k in KINDS: total += _odds(k)
	var roll := randf() * total
	for k in KINDS:
		roll -= _odds(k)
		if roll <= 0.0: return k
	return "clear"

## The season follows the whole day number only: the time of day never changes its colours.
## Winter snow must not survive into spring or summer.
func _update_season() -> void:
	var clock := get_node_or_null("/root/TimeOfDay")
	if clock == null: return
	var length := _season_days()
	var day: int = int(clock.day) + _season_offset * length
	var index := posmod(day / length, 4)
	var look: Dictionary = SEASON_LOOK[SEASONS[index]].duplicate()
	var changed: bool = SEASONS[index] != season
	season = SEASONS[index]
	# A snow spell can still be fading after a clock/season jump. Only winter may add
	# ground snow; a stale weather blend must not whiten warm-season grass.
	look.snow = maxf(float(look.snow), float(params.get("snow", 0.0)) * 0.6) if season == "winter" else 0.0
	if look == _season_look: return
	_season_look = look
	var leaf: Color = look.leaf; var ground: Color = look.ground
	RenderingServer.global_shader_parameter_set("season_leaf", Vector4(leaf.r, leaf.g, leaf.b, float(look.leaf_amount)))
	RenderingServer.global_shader_parameter_set("season_ground", Vector4(ground.r, ground.g, ground.b, float(look.ground_amount)))
	RenderingServer.global_shader_parameter_set("season_snow", float(look.snow))
	RenderingServer.global_shader_parameter_set("season_flowers", float(look.flowers))
	if changed: print("[season] ", season)
	# Grass takes its colour from a render of the ground: refresh it for the new look, and
	# when snow weather adds cover.
	var tint_delta := maxf(absf(ground.r - _probe_ground_color.r), maxf(absf(ground.g - _probe_ground_color.g), absf(ground.b - _probe_ground_color.b)))
	if changed or absf(float(look.snow) - _probe_snow) > 0.08 or absf(float(look.ground_amount) - _probe_ground) > 0.08 or tint_delta > 0.08:
		_probe_snow = float(look.snow); _probe_ground = float(look.ground_amount)
		_probe_ground_color = ground
		for grass in get_tree().root.find_children("GroundGrass", "", true, false):
			if grass.has_method("refresh_colour"): grass.refresh_colour()

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
		_season_offset += 1
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
	rm.albedo_color = Color(0.78, 0.84, 0.95, 0.38)
	rm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	rm.billboard_keep_scale = true
	streak.material = rm
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
	_snow.draw_pass_1 = flake
	var pm: ParticleProcessMaterial = _snow.process_material
	pm.turbulence_enabled = true; pm.turbulence_noise_strength = 1.4; pm.turbulence_noise_scale = 4.0
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
			_rain_target = -80.0
			_set_roofs_follow(false)
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
	var snow := 0.0 if indoors or not particles else float(params.snow)
	var hail := 0.0 if indoors or not particles else float(params.hail)
	# Quality tiers thin the drops (weather_particle_scale: Low 0.7, Very Low 0.4); never off by preset.
	var scale: float = _weather_particle_scale
	rain *= scale; snow *= scale; hail *= scale
	# Wind drives rain and snow sideways (blizzards nearly horizontal).
	var gust := float(params.gust)
	var push := Vector3(1.0, 0.0, 0.35).normalized() * gust
	var rain_heard := maxf(float(params.rain), float(params.hail) * 0.8)
	var state: Array = [rain, snow, hail, push, rain_heard, indoors]
	if state != _precipitation_state:
		_precipitation_state = state
		_rain.amount_ratio = rain; _rain.emitting = rain > 0.01
		_snow.amount_ratio = snow; _snow.emitting = snow > 0.01
		_hail.amount_ratio = hail; _hail.emitting = hail > 0.01
		_set_roofs_follow(_rain.emitting or _snow.emitting or _hail.emitting)
		(_rain.process_material as ParticleProcessMaterial).gravity = push * 4.0
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
	var tween := create_tween()
	for strobe in [flash, flash * 0.3, flash * 0.9, 0.0]:
		tween.tween_property(_flash, "light_energy", strobe, 0.05)
	tween.tween_property(_flash, "light_energy", 0.0, 0.25)
	# Sound travels ~343 m/s: far strikes rumble late and soft.
	# A bound method loses its connection with the Weather owner on world exit.
	get_tree().create_timer(distance / 343.0).timeout.connect(_play_thunder.bind(distance))


func _play_thunder(distance: float) -> void:
	if not is_inside_tree(): return
	var cam := preload("res://world/player_view.gd").camera(self)
	if cam == null: return
	SOUNDS.play_event(self, "env_thunder", {"intensity": clampf(900.0 / distance, .12, 1.0)}, cam.global_position)

# ------------------------------------------------------------------ ponies take shelter
func _wet() -> bool: return float(params.rain) > 0.35 or float(params.snow) > 0.45 or float(params.hail) > 0.4

func _update_shelter() -> void:
	var population: Node = game.get("population")
	if population == null or not ("live" in population): return
	var wet := _wet()
	for id: String in population.live.keys():
		var actor: Node3D = population.live[id].get("actor")
		if not is_instance_valid(actor): continue
		var nav := actor.get_node_or_null("Navigator")
		if nav == null: continue
		var owner: String = nav.command_owner
		if wet and not _sheltering.has(id):
			# Most go home; a few (and pegasi, who run the weather) carry on.
			if hash(id + kind) % 100 >= 72: continue
			if actor.identity != null and actor.identity.has_method("has_wings") and actor.identity.has_wings(): continue
			if not (owner.is_empty() or owner.begins_with("life:") or owner.begins_with("social:")): continue
			if actor.get("_held") or actor.get("sleeping"): continue
			var director: Variant = game.get("director")
			if is_instance_valid(director) and director.holds_in_place(id): continue
			var house: Node3D = population.home_house(id) if population.has_method("home_house") else null
			if house == null or house.contains(actor.global_position): continue
			nav.stay(); nav.command_owner = SHELTER_OWNER + id
			nav.go_to(house.inside(), nav.Gait.TROT)
			nav.command_owner = SHELTER_OWNER + id
			_sheltering[id] = true
		elif not wet and _sheltering.has(id):
			_sheltering.erase(id)
			if owner.begins_with(SHELTER_OWNER):
				nav.stay(); nav.command_owner = ""
