extends WorldEnvironment
## The single writer for atmosphere.
##
## TimeOfDay says *when* it is, Quality says *how much we can afford*, and this
## node is the only thing that turns either into Environment/light state. Keeping
## one writer is deliberate: time-of-day and quality both want to touch fog, and
## two writers means whichever ran last wins at random.
##
## The Environment is built in code rather than stored in the .tscn so every
## tunable number lives here in one readable place.

const COLOR_GRADE := preload("res://world/sky/color_grade.gd")
const ZoneProcessorRef := preload("res://world/zone_processor.gd")
const StreetLamps := preload("res://world/street_lamps.gd")
const GrassyFieldsCloudsRef := preload("res://world/sky/grassy_clouds.gd")

@export var sun_path: NodePath = ^"../Sun"
@export var moon_path: NodePath = ^"../Moon"

# --- Sun ------------------------------------------------------------------
const SUN_DAY_COLOR := Color(1.0, 0.972, 0.926)
const SUN_GOLDEN_COLOR := Color(1.0, 0.564, 0.282)
const SUN_DAY_ENERGY := 1.65
const SUN_GOLDEN_ENERGY := 1.25

# --- Moon -----------------------------------------------------------------
const MOON_COLOR := Color(0.55, 0.66, 1.0)
const MOON_ENERGY := 0.13  # was 0.20; toon bands have no N.L falloff, so moonlight lit cel coats 2x the ground (2026-09-07, measured in captures/round7*)

# --- Fog ------------------------------------------------------------------
const FOG_DAY_COLOR := Color(0.72, 0.82, 0.95)
const FOG_GOLDEN_COLOR := Color(0.98, 0.66, 0.42)
const FOG_NIGHT_COLOR := Color(0.06, 0.09, 0.18)
## Depth fog tied to the draw distance (15 km world, 2026-09-09). Exponential fog was a
## compromise at every scale: 0.0016/m greyed the town at 400 m, 0.00007/m still hazed the
## mid-range from the air yet left the far clip popping at 53 % visibility. Depth mode keeps
## the first FOG_CLEAR fraction of the draw distance clear, then ramps to FOG_MAX at
## FOG_END_FRACTION of it so geometry fades out before the camera far clip cuts it.
const FOG_CLEAR := 0.30
const FOG_END_FRACTION := 0.95
const FOG_MAX := 0.92
## Fog ramp shape: > 1 keeps the mid-range clearer and gathers the fog toward the end.
const FOG_CURVE := 1.6
## Dawn mist. The single cheapest trick for making a valley feel real, so it is
## overdriven a little relative to physical plausibility: the ramp starts this close.
const FOG_DAWN_BEGIN := 800.0
## Share of mornings that bring dawn mist, picked per day (dev 2026-10-14: 1 in 10, and light: the
## glowing mist looked pretty but he could not see).
const MISTY_MORNINGS := 0.1
## Extra volumetric haze at the mist's peak (was 1.8, nearly tripling the shafts).
const DAWN_GLOW := 0.5

static func _misty_morning() -> bool:
	return float(absi(hash("dawn_mist" + str(int(TimeOfDay.day)))) % 1000) / 1000.0 < MISTY_MORNINGS

## Multiplied by volumetric_fog_length, so this is optical depth across 128 m --
## small numbers go a long way and anything near 0.02 reads as heavy smoke.
## Everything beyond the 128 m froxel volume inherits the fog accumulated at its end, so
## this is also the whole world's haze: 0.007 (optical depth 0.9, 59 % fog past 128 m) was
## the veil that greyed every aerial capture of the 15 km world (2026-09-09, fog probe).
## 0.002 keeps ~23 % for the shafts; the sun's volumetric energy is raised to compensate.
const VOL_FOG_BASE_DENSITY := 0.002
## High anisotropy is what turns the sun into visible shafts through trees.
const VOL_FOG_ANISOTROPY := 0.62

# --- Ambient --------------------------------------------------------------
## Ambient is driven explicitly rather than taken from the sky's radiance map.
## AMBIENT_SOURCE_SKY contributed literally nothing here -- raising its energy
## 2.2x produced a pixel-identical frame -- so every shadowed surface rendered
## pure black on the presets without SDFGI to cover for it. Authoring the colour
## also means shadow fill is art-directable instead of whatever the scattering
## model happens to produce.
const AMBIENT_DAY_COLOR := Color(0.52, 0.66, 0.92)
const AMBIENT_GOLDEN_COLOR := Color(0.80, 0.56, 0.42)
const AMBIENT_NIGHT_COLOR := Color(0.55, 0.62, 0.78)
const AMBIENT_DAY_ENERGY := 0.85
## Broad, dim skylight keeps unlit surfaces legible without a camera-following lamp.
## Colour is authored in sRGB; Environment converts it to linear irradiance.
const AMBIENT_NIGHT_ENERGY := 0.22

# --- Look overhaul, stage 1: light and air (dev 2026-11-10) -------------------
## The moods the old rules got wrong, measured on the baseline sheets
## (captures/look-2026-11-10): cloud cover turned the fill light neutral grey and cut the colour
## by 22 %, so every snowfall was flat grey and a snowy sunset went brown; golden hour had a warm
## sun AND a warm fill, so shade had no opposite hue and the grass went olive; and the blue hour
## after sunset was already full night, with a black sky and black land.
## Rollback: LOOK_MOODS = false restores every old rule exactly. House interiors and the window
## cards keep reading the old fill (interior_light) either way.
const LOOK_MOODS := true
## Golden hour: the sun is orange, so the shade keeps the sky's cool violet-blue.
const LOOK_GOLDEN_FILL := Color(0.60, 0.55, 0.84)
const LOOK_GOLDEN_EXPOSURE := 0.18
## Blue hour: for a while after sunset and before sunrise the sky still lights the land deep blue.
const LOOK_TWILIGHT_FILL := Color(0.36, 0.42, 0.96)
const LOOK_TWILIGHT_ENERGY := 0.26
const LOOK_TWILIGHT_HAZE := Color(0.10, 0.16, 0.42)
## How much of the day sky's colour and brightness the dome keeps at the peak of the blue hour.
const LOOK_TWILIGHT_SKY := 0.24
## Cloud cover: a cool blue-grey light that keeps its colour (was neutral grey 0.72, 0.74, 0.78).
const LOOK_OVERCAST_FILL_DAY := Color(0.60, 0.69, 0.90)
const LOOK_OVERCAST_FILL_NIGHT := Color(0.44, 0.50, 0.86)
const LOOK_OVERCAST_HAZE_DAY := Color(0.62, 0.70, 0.86)
const LOOK_OVERCAST_HAZE_NIGHT := Color(0.12, 0.17, 0.38)
const LOOK_OVERCAST_SATURATION := 0.94   # was 0.78
const LOOK_OVERCAST_FILL_ENERGY := 0.86  # was 0.72
const LOOK_OVERCAST_EXPOSURE := 0.90     # was 0.78
const LOOK_OVERCAST_SHADOW_FADE := 0.70  # was 0.85
## Under full cloud this share of the sunset glow is kept off the land, the haze and the dome
## (grey cloud times orange glow is the brown sky).
const LOOK_OVERCAST_GOLDEN_CUT := 0.75
## Winter over SEASON_GRADES: bluer shade and haze, and nearly full colour so the blue shows.
const LOOK_WINTER_GRADE := {"ambient": Color(0.86, 0.95, 1.14), "fog": Color(0.90, 0.97, 1.10), "saturation": 0.97}

## Air: distance has to look like distance. The old ramp left the first 30 % of the view (3.6 km
## on High) with no haze at all. Now haze starts LOOK_HAZE_BEGIN metres out and rises quickly, then
## slowly: about 14 % at 300 m, 29 % at 1 km, 50 % at 3 km, and FOG_MAX at the far clip as before.
## More of it takes the sky's colour in that direction (aerial perspective), so far ridges go warm
## toward a low sun and blue away from it. Rollback: LOOK_HAZE = false.
const LOOK_HAZE := true
const LOOK_HAZE_BEGIN := 120.0
const LOOK_HAZE_CURVE := 0.45
const LOOK_HAZE_AERIAL := 0.55

## Snow in the air: at weather_snow 1 the haze reaches full strength this many metres out and
## begins at arm's length; its colour is the fill light on white snow. Rollback: LOOK_SNOW_AIR = false.
const LOOK_SNOW_AIR := true
const LOOK_SNOW_AIR_RANGE := 520.0
## Falling snow closes the sky too: no stars, sunset band or cloud edges behind it, and the far
## hills melt into it instead of standing as a cut-out. Share of the sky the snow air covers at
## weather_snow 1 (clear weather keeps the engine value below).
const LOOK_SNOW_AIR_SKY := 0.92
const FOG_SKY_AFFECT := 0.12

## Cloud shadows on the ground (world/terrain/gaea_fragment.gdshaderinc reads look_cloud_shadow):
## how dark the shade under a cloud gets in full sun. None at night or under full cloud.
## Rollback: LOOK_CLOUD_SHADOWS = false.
const LOOK_CLOUD_SHADOWS := true
const LOOK_CLOUD_SHADOW_STRENGTH := 0.42
var _cloud_shadow_written := -1.0
var _daylight_written := -1.0

## 1 at the heart of the blue hour (sun a little under the horizon), 0 by day and in full night.
static func twilight_amount(elevation: float) -> float:
	return smoothstep(-0.50, -0.20, elevation) * (1.0 - smoothstep(-0.10, 0.10, elevation))

# --- Regional look ----------------------------------------------------------
## Biome presets select lighting_profiles.json entries. The same painted weights that
## dress the ground and vegetation drive these multipliers, independent of zone residency.
const PROFILES_PATH := "res://world/lighting_profiles.json"
const PROFILE_INTERVAL := 0.5
const PROFILE_FALLOFF := 150.0
var _profiles: Dictionary = {}
var _profile: Dictionary = {}
var _profile_timer := 0.0
var _profile_region := ""
var _last_light_update := -1000
var _last_clock_hour := -100.0

## Lamps come up as the sun goes down, over this band of the daylight factor.
const LAMP_ON_BELOW := 0.45
const LAMP_FULL_BELOW := 0.08

var sun: DirectionalLight3D
var moon: DirectionalLight3D
var _sky_material: ShaderMaterial
var _grassy_clouds: GrassyFieldsClouds
## time_changed fires every frame, but 130 lamps do not need rewriting that
## often -- only step them when the level has actually moved.
var _lamp_level := -1.0
var _dream_state: Dictionary = {}
var debug_lighting: Node

# --- Reflection cubemap cadence (perf 0.1.0) ----------------------------------
## The sky's radiance cubemap (sky reflections on materials) was re-rendered every frame,
## 0.23-0.28 ms of GPU at every spot including interiors, because the sky shader read TIME and
## POSITION and the cloud drift was written to the material each frame. Those per-frame values
## now reach the shader as global uniforms (_push_sky_frame), which do not dirty the cubemap, so
## it refreshes when the sky itself changes (the sun steps at 4 Hz in _on_time_changed, palette
## and weather writes) and at least every RADIANCE_REFRESH_SEC. The visible sky still moves
## every frame. Rollback: SKY_RADIANCE_THROTTLE = false re-renders the cubemap every frame again.
const SKY_RADIANCE_THROTTLE := true
const RADIANCE_REFRESH_SEC := 0.25
## The global uniforms shaders/sky.gdshader reads (project.godot [shader_globals] declares them;
## _ensure_sky_globals adds any a stale project settings file lacks before the shader compiles).
const SKY_GLOBALS := {
	&"sky_time": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
	&"sky_eye": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
	&"sky_cloud_offset": [RenderingServer.GLOBAL_VAR_TYPE_VEC2, Vector2.ZERO],
	&"sky_cloud_shape": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0.45, 1.0, 0.0)],
	&"look_cloud_shadow": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
	&"sky_daylight": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 1.0],
}
const PLAYER_VIEW := preload("res://world/player_view.gd")
var _sky_time := 0.0
var _sky_clock_usec := 0
var _sky_time_rollover := 3600.0
var _radiance_age := 0.0
## Last value written per sky material parameter by _sky_param: every write re-renders the
## cubemap, so unchanged values are not written again.
var _sky_params: Dictionary = {}

# --- Season grade (W2-SEAS-K 2026-11-08, M-SEA-23; seasons design 6.8) ------------------------
## A cooler, paler winter and a warmer autumn: multipliers on the sun, ambient and fog colours,
## the saturation, and a paler winter sky dome. Spring and summer are the unchanged look. A season's
## grade arrives whole on its first day like its palettes (season_state SEASON_LOOK); only the sun
## path moves day by day, lowest at midwinter. It tilts the visible sun's orbit (the horizon
## crossings stay at 06:00 and 18:00), so day length, daylight and bedtimes do not change (D-04).
## The colours fade out where the climate map has no seasons (desert, badlands, jungle, coast,
## sea: channel R, D-06), sampled at the camera on the 2 Hz profile step while a grade is active.
## season_state (group "season_state") is found on the profile step and drives
## set_season_grade() from its season_changed/day_stepped signals: one call per day step.
const CLIMATE_MAP := preload("res://world/seasons/climate_map.gd")
const SEASON_STATE_GROUP := "season_state"
const SEASON_ORDER := ["spring", "summer", "autumn", "winter"]
## Peak extra orbit tilt at midwinter: the noon sun drops from about 58 to 50 degrees.
const WINTER_SUN_DROP_DEG := 8.0
## Climate weight steps (each step re-applies the grade; the sky dome writes only on change).
const SEASON_CLIMATE_STEP := 0.05
## shaders/sky.gdshader's day palette defaults, used when the renderer cannot report them (headless).
const SKY_PALETTE_FALLBACK := {&"day_zenith": Color(0.18, 0.38, 0.78), &"day_horizon": Color(0.62, 0.78, 0.95)}
const SEASON_GRADES := {
	"spring": {},
	"summer": {},
	"autumn": {"sun": Color(1.0, 0.95, 0.86), "ambient": Color(1.03, 0.97, 0.88), "fog": Color(1.02, 0.95, 0.86),
		"saturation": 1.05, "horizon": Color(0.84, 0.76, 0.62), "horizon_mix": 0.18},
	"winter": {"sun": Color(0.93, 0.96, 1.0), "sun_mul": 0.93, "ambient": Color(0.93, 0.98, 1.06), "fog": Color(0.97, 1.0, 1.05),
		"saturation": 0.85, "zenith": Color(0.42, 0.58, 0.84), "zenith_mix": 0.3, "horizon": Color(0.82, 0.88, 0.95), "horizon_mix": 0.4},
}
## The grade in force: SEASON_GRADES[season] plus "sun_drop_deg" (tests read it).
var season_grade: Dictionary = {}
## How many times set_season_grade changed the grade (tests).
var season_grade_writes := 0
var _grade_season := ""
var _grade_progress := -1.0
var _season_climate := 1.0
var _season_node: Node
var _grade_sun := Color.WHITE
var _grade_sun_mul := 1.0
var _grade_ambient := Color.WHITE
var _grade_fog := Color.WHITE
var _grade_saturation := 1.0
var _grade_sun_drop := 0.0
var _sky_palette_base: Dictionary = {}


func set_debug_lighting(mode: String) -> void:
	if not is_instance_valid(debug_lighting) or not _dream_state.is_empty(): return
	debug_lighting.select(mode)
	_apply_quality()
	_apply_time()


## The sky owns environment changes, including the temporary lunar dream. A separate
## environment keeps normal-world settings intact; clock/weather signals cannot overwrite it.
func begin_luna_dream() -> void:
	if not _dream_state.is_empty() or environment == null: return
	set_debug_lighting("baseline")
	_dream_state = {"environment": environment, "process_mode": process_mode, "lights": []}
	for light: Light3D in [sun, moon]:
		if is_instance_valid(light):
			_dream_state.lights.append([light, light.visible]); light.visible = false
	var dream := environment.duplicate() as Environment
	dream.background_mode = Environment.BG_COLOR; dream.background_color = Color.BLACK
	dream.fog_enabled = false; dream.volumetric_fog_enabled = false
	dream.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	dream.ambient_light_color = Color("8491ac"); dream.ambient_light_energy = 0.22
	dream.ambient_light_sky_contribution = 0.0
	dream.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	dream.sdfgi_enabled = false
	dream.adjustment_color_correction = null
	dream.adjustment_saturation = 1.0; dream.adjustment_contrast = 1.04
	dream.tonemap_exposure = 1.0
	environment = dream
	process_mode = Node.PROCESS_MODE_DISABLED

func end_luna_dream() -> void:
	if _dream_state.is_empty(): return
	environment = _dream_state.environment
	process_mode = int(_dream_state.process_mode)
	for pair: Array in _dream_state.lights:
		if is_instance_valid(pair[0]): pair[0].visible = pair[1]
	_dream_state.clear()


func _ready() -> void:
	COLOR_GRADE.start()
	add_to_group("sky_controller")
	sun = get_node_or_null(sun_path) as DirectionalLight3D
	moon = get_node_or_null(moon_path) as DirectionalLight3D
	_load_profiles()
	_build_environment()
	if "--debug" in preload("res://world/dev_tools.gd").user_args():
		debug_lighting = load("res://world/debug/lighting_controls.gd").new()
		add_child(debug_lighting)
	TimeOfDay.time_changed.connect(_on_time_changed)
	Quality.preset_changed.connect(_on_quality_changed)
	_apply_quality()
	_apply_time()
	_sky_time_rollover = maxf(float(ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs", 3600.0)), 1.0)
	# Before every frame, after all scripts ran, and also while the tree is paused (TIME ran on).
	if not RenderingServer.frame_pre_draw.is_connected(_push_sky_frame):
		RenderingServer.frame_pre_draw.connect(_push_sky_frame)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_push_sky_frame):
		RenderingServer.frame_pre_draw.disconnect(_push_sky_frame)


## Per-frame sky inputs as global uniforms (see SKY_RADIANCE_THROTTLE): the clock that replaced
## TIME (same seconds, scaled by Engine.time_scale like the renderer's), the player's camera
## position that replaced POSITION, and the clouds' drift and weather shape. Also keeps the
## reflection cubemap no older than RADIANCE_REFRESH_SEC.
func _push_sky_frame() -> void:
	if _sky_material == null or not is_inside_tree() or not _dream_state.is_empty(): return
	var now := Time.get_ticks_usec()
	var step := float(now - _sky_clock_usec) * 0.000001 if _sky_clock_usec > 0 else 0.0
	_sky_clock_usec = now
	_sky_time = fmod(_sky_time + step * Engine.time_scale, _sky_time_rollover)
	RenderingServer.global_shader_parameter_set(&"sky_time", _sky_time)
	var camera := PLAYER_VIEW.camera(self)
	if camera != null and camera.is_inside_tree():
		# The rendered (physics-interpolated) camera position, as POSITION was.
		RenderingServer.global_shader_parameter_set(&"sky_eye", camera.get_global_transform_interpolated().origin)
	RenderingServer.global_shader_parameter_set(&"sky_cloud_offset", _cloud_offset)
	RenderingServer.global_shader_parameter_set(&"sky_cloud_shape", _cloud_now)
	_radiance_age += step
	if SKY_RADIANCE_THROTTLE and _radiance_age < RADIANCE_REFRESH_SEC: return
	# Cubemap-only copies of the cloud state (its overcast greying), then one write that marks
	# the cubemap dirty even when nothing else changed (stars, flat-cloud drift in reflections).
	_sky_param(&"cloud_coverage", _cloud_now.x)
	_sky_param(&"cloud_darkness", _cloud_now.z)
	_sky_material.set_shader_parameter(&"exposure", _sky_params.get(&"exposure", 1.0))
	_radiance_age = 0.0


## Writes a sky material parameter only when it changed (each write re-renders the cubemap).
func _sky_param(param: StringName, value: Variant) -> void:
	if _sky_material == null: return
	if _sky_params.has(param) and _sky_params[param] == value: return
	_sky_params[param] = value
	_sky_material.set_shader_parameter(param, value)
	_radiance_age = 0.0


## The renderer loads [shader_globals] from project settings at boot; a build whose settings
## predate these entries would fail to compile the sky shader, so add what is missing first.
## (RenderingServer's own global list/type getters are editor-only and error at runtime.)
static var _sky_globals_added := false
static func _ensure_sky_globals() -> void:
	if _sky_globals_added: return
	_sky_globals_added = true
	for global_name: StringName in SKY_GLOBALS:
		if ProjectSettings.has_setting("shader_globals/" + String(global_name)): continue
		var entry: Array = SKY_GLOBALS[global_name]
		RenderingServer.global_shader_parameter_add(global_name, int(entry[0]) as RenderingServer.GlobalShaderParameterType, entry[1])


func _build_environment() -> void:
	_ensure_sky_globals()
	_sky_material = ShaderMaterial.new()
	_sky_material.shader = load("res://shaders/sky.gdshader")
	_sky_material.set_shader_parameter("cloud_texture", load("res://world/sky/clouds_tile.png"))
	# NASA SVS CGI Moon Kit colour map, 2k (public domain; see THIRD_PARTY.md).
	_sky_material.set_shader_parameter("moon_texture", load("res://world/sky/moon_color_2k.png"))

	var sky := Sky.new()
	sky.sky_material = _sky_material
	# Realtime skies are locked to 256 by the renderer; anything else is ignored.
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	# The sun moves continuously, so the radiance map has to keep up or indirect
	# light lags behind the visible sky at sunrise/sunset. Realtime keeps the fast filter; with
	# no TIME/POSITION in the shader it re-renders only when dirtied (SKY_RADIANCE_THROTTLE).
	sky.process_mode = Sky.PROCESS_MODE_REALTIME

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_sky_contribution = 0.0
	# Reflections still come from the sky -- that part works.
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	# AgX compresses everything below the white point, so a high value reads as a
	# flat, muddy image. Keep it low enough that daylight midtones stay bright.
	env.tonemap_white = 2.2

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_curve = LOOK_HAZE_CURVE if LOOK_HAZE else FOG_CURVE
	env.fog_sun_scatter = 0.35
	# Aerial perspective is what sells distance on the low preset, where there is
	# no GI to give far geometry any atmosphere of its own.
	env.fog_aerial_perspective = LOOK_HAZE_AERIAL if LOOK_HAZE else 0.30
	# Tinting the sky by the fog colour is what turned a blue noon sky grey.
	env.fog_sky_affect = FOG_SKY_AFFECT

	# Defaults to 1.0, which lets the fog volume paint over the sky and turns a
	# clear noon grey. It was the reason High looked worse than Low, which has no
	# volumetrics at all. Depth fog still tints the sky via fog_sky_affect.
	env.volumetric_fog_sky_affect = 0.08
	env.volumetric_fog_length = 128.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_anisotropy = VOL_FOG_ANISOTROPY
	env.volumetric_fog_albedo = Color(1.0, 1.0, 1.0)
	env.volumetric_fog_gi_inject = 1.0

	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.12
	env.glow_hdr_threshold = 1.05
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	env.ssao_radius = 1.6
	env.ssao_intensity = 1.4
	env.ssil_radius = 3.0

	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.25
	env.sdfgi_use_occlusion = true
	env.sdfgi_bounce_feedback = 0.5
	env.sdfgi_energy = 1.1

	env.adjustment_enabled = true
	# AgX desaturates by design; nudge back toward the cartoon palette.
	env.adjustment_saturation = 1.22
	env.adjustment_contrast = 1.04

	environment = env
	if "--old-clouds" in preload("res://world/dev_tools.gd").user_args(): _build_grassy_clouds()
	else:
		_build_volume_clouds()
		# Settings → Graphics → Clouds: follow the quality tier (flat painted clouds on Low and
		# Very Low, quality.gd volume_clouds), or force volumetric / flat. _apply_quality applies it.
		var settings := get_node_or_null("/root/Settings")
		if settings != null: settings.changed.connect(_on_setting_changed)


## Volumetric cloud layer (sky.gdshader VolumeClouds): one tileable 3D noise, a new seed,
## wind and base coverage every day. Weather overrides coverage/density/darkness through
## set_cloud_weather(); changes ease in over a minute or so.
## Weather (world/weather/weather.gd): sun left through the clouds 0..1, overcast 0..1
## (grey, flat ambient), fog 0..1 (near, grey). Set by set_weather_light().
var weather_sun := 1.0
var weather_overcast := 0.0
var weather_fog := 0.0
var _cloud_day := -1
var _cloud_now := Vector3(0.45, 1.0, 0.0)     # coverage, density, darkness (shown)
var _cloud_goal := Vector3(0.45, 1.0, 0.0)
var _cloud_weather := Vector3(-1, -1, -1)      # weather request, -1 = the day's own sky

func _build_volume_clouds() -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.045
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	var tex := NoiseTexture3D.new()
	tex.width = 64; tex.height = 64; tex.depth = 64
	tex.seamless = true
	tex.normalize = true
	tex.noise = noise
	_sky_material.set_shader_parameter("cloud_noise", tex)
	_sky_material.set_shader_parameter("volume_clouds", true)
	_sky_material.set_shader_parameter("cloud_opacity", 0.0)
	_sky_material.set_shader_parameter("cloud_bank_opacity", 0.0)

func _on_setting_changed(key: String) -> void:
	if key == "video/clouds": _apply_clouds()


## The cloud layer for the current tier and the player's Clouds row: volumetric or flat, and
## the march step count (Very Low 12, Low 18, Medium 18, High/Ultra 28; XR caps at 18).
func _apply_clouds() -> void:
	if _sky_material == null: return
	var settings := get_node_or_null("/root/Settings")
	var mode := str(settings.get_value("video/clouds")) if settings != null else "preset"
	var on: bool = bool(Quality.get_value("volume_clouds", true)) if mode == "preset" else mode == "volumetric"
	_sky_material.set_shader_parameter("cloud_steps", int(Quality.get_value("cloud_steps", 28)))
	set_volume_clouds(on)


## Switch between the volumetric layer and the shader's flat painted clouds and banks.
func set_volume_clouds(on: bool) -> void:
	if _sky_material == null or _sky_material.get_shader_parameter("cloud_noise") == null: return
	_sky_material.set_shader_parameter("volume_clouds", on)
	var sky_shader: Shader = _sky_material.shader
	_sky_material.set_shader_parameter("cloud_opacity", 0.0 if on else RenderingServer.shader_get_parameter_default(sky_shader.get_rid(), "cloud_opacity"))
	_sky_material.set_shader_parameter("cloud_bank_opacity", 0.0 if on else RenderingServer.shader_get_parameter_default(sky_shader.get_rid(), "cloud_bank_opacity"))
	if on: _update_volume_clouds(0.0)

var _cloud_wind := 1.0
var _cloud_wind_now := 1.0
var _cloud_drift_day := Vector2(4.0, 1.5)
var _cloud_offset := Vector2.ZERO
func set_cloud_wind(multiplier: float) -> void:
	_cloud_wind = multiplier

## Falling snow fills the air (weather.gd LOOK_SNOW_AIR): 0 none .. 1 the view closes to
## LOOK_SNOW_AIR_RANGE. Snow in the air is lit like the flakes: it takes the fill light's colour.
var weather_snow := 0.0
func set_weather_snow(amount: float) -> void:
	if is_equal_approx(amount, weather_snow): return
	weather_snow = amount
	_apply_time()

func set_weather_light(sun_left: float, overcast: float, fog: float) -> void:
	weather_sun = sun_left; weather_overcast = overcast; weather_fog = fog
	_apply_time()

## Weather: coverage 0..1, density multiplier, darkness 0..1. Negative = back to the day's sky.
func set_cloud_weather(coverage: float, density := 1.0, darkness := 0.0) -> void:
	_cloud_weather = Vector3(coverage, density, darkness)

## Jump straight to the requested cloud state (weather debug key).
func snap_clouds() -> void:
	_cloud_now = _cloud_goal if _cloud_weather.x < 0.0 else _cloud_weather
	_update_volume_clouds(0.0)

func _update_volume_clouds(delta: float) -> void:
	if _sky_material == null or _sky_material.get_shader_parameter("volume_clouds") != true: return
	var day := int(TimeOfDay.day)
	if day != _cloud_day:
		_cloud_day = day
		var rng := RandomNumberGenerator.new(); rng.seed = hash("clouds" + str(day))
		_sky_material.set_shader_parameter("cloud_seed", Vector2(rng.randf() * 50.0, rng.randf() * 50.0))
		var heading := rng.randf() * TAU
		_cloud_drift_day = Vector2.from_angle(heading) * rng.randf_range(2.0, 6.0)
		var first := _cloud_goal == Vector3(0.45, 1.0, 0.0) and _cloud_now == _cloud_goal
		_cloud_goal = Vector3(rng.randf_range(0.28, 0.62), 1.0, 0.0)
		if first: _cloud_now = _cloud_goal
	# Integrate the drift (m/s) into an offset; the wind eases in over a few seconds.
	_cloud_wind_now = move_toward(_cloud_wind_now, _cloud_wind, delta * 0.5)
	# Offset and _cloud_now reach the shader as globals in _push_sky_frame (no cubemap re-render).
	_cloud_offset += _cloud_drift_day * _cloud_wind_now * delta
	var goal := _cloud_goal if _cloud_weather.x < 0.0 else _cloud_weather
	_cloud_now = _cloud_now.move_toward(goal, delta / 60.0)

func _build_grassy_clouds() -> void:
	var clouds := GrassyFieldsCloudsRef.new()
	clouds.name = "GrassyFieldsClouds"
	add_child(clouds)
	if "--grassy-clouds-off" in preload("res://world/dev_tools.gd").user_args() or not clouds.initialize_clouds(_sky_material):
		clouds.queue_free()
		return
	_grassy_clouds = clouds
	# Keep the procedural sky cards as a fallback until native cards and their
	# materials are available, then remove their duplicate overdraw.
	_sky_material.set_shader_parameter("cloud_opacity", 0.0)
	_sky_material.set_shader_parameter("cloud_bank_opacity", 0.0)


## Street lamps and lanterns, lit by the zone processor and dimmed by daylight.
func _update_lamps(daylight: float) -> void:
	var level: float = 1.0 - smoothstep(LAMP_FULL_BELOW, LAMP_ON_BELOW, daylight)
	if absf(level - _lamp_level) < 0.002: return
	_lamp_level = level
	for node in get_tree().get_nodes_in_group(ZoneProcessorRef.NIGHT_LIGHT_GROUP):
		var light := node as OmniLight3D
		if light == null:
			continue
		StreetLamps.apply(light, level)


func _refresh_lamps() -> void:
	_lamp_level = -1.0
	_update_lamps(TimeOfDay.daylight())


func _load_profiles() -> void:
	_profiles = {}
	if FileAccess.file_exists(PROFILES_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROFILES_PATH))
		if parsed is Dictionary:
			_profiles = parsed.get("profiles", {})
	_profile = _profiles.get("default", {}).duplicate()


func _process(delta: float) -> void:
	_update_volume_clouds(delta)
	_profile_timer -= delta
	if _profile_timer > 0.0:
		return
	_profile_timer = PROFILE_INTERVAL
	if not is_instance_valid(_season_node): _seek_season_state()
	_update_profile()


# ------------------------------------------------------------------ season grade

## Sets the seasonal grade for a season and its progress (0 on its first day .. 1). Returns
## false, and touches nothing, when neither changed.
func set_season_grade(season: String, progress: float) -> bool:
	var p := clampf(progress, 0.0, 1.0)
	if season == _grade_season and is_equal_approx(p, _grade_progress): return false
	_grade_season = season; _grade_progress = p
	season_grade = (SEASON_GRADES.get(season, {}) as Dictionary).duplicate()
	if LOOK_MOODS and season == "winter": season_grade.merge(LOOK_WINTER_GRADE, true)
	season_grade["sun_drop_deg"] = WINTER_SUN_DROP_DEG * winter_depth(season, p)
	season_grade_writes += 1
	_refresh_season_mix()
	_apply_time()
	return true


## 1 at midwinter, 0 at midsummer, 0.5 at the middle of spring and autumn; smooth over the year.
static func winter_depth(season: String, progress: float) -> float:
	var index := SEASON_ORDER.find(season)
	if index < 0: return 0.0
	var year := (float(index) + clampf(progress, 0.0, 1.0)) / 4.0
	return 0.5 + 0.5 * cos(TAU * (year - 0.875))


func _seek_season_state() -> void:
	if not is_inside_tree(): return
	var node := get_tree().get_first_node_in_group(SEASON_STATE_GROUP)
	if node == null or not node.has_signal("day_stepped") or not node.has_method("progress"): return
	_season_node = node
	node.connect("season_changed", _on_season_step)
	node.connect("day_stepped", _on_season_step)
	_on_season_step()


func _on_season_step(_value: Variant = null) -> void:
	if not is_instance_valid(_season_node): return
	set_season_grade(str(_season_node.call("season")), float(_season_node.call("progress")))


## Season colours fade where the climate has no seasons (0..1, stepped by SEASON_CLIMATE_STEP).
func _set_season_climate(weight: float) -> void:
	var w := snappedf(clampf(weight, 0.0, 1.0), SEASON_CLIMATE_STEP)
	if w == _season_climate: return
	_season_climate = w
	_refresh_season_mix()


## The cached multipliers _apply_time reads, and the sky dome's palette (written only on change).
func _refresh_season_mix() -> void:
	var g := season_grade
	var w := _season_climate
	_grade_sun = Color.WHITE.lerp(g.get("sun", Color.WHITE), w)
	_grade_sun_mul = lerpf(1.0, float(g.get("sun_mul", 1.0)), w)
	_grade_ambient = Color.WHITE.lerp(g.get("ambient", Color.WHITE), w)
	_grade_fog = Color.WHITE.lerp(g.get("fog", Color.WHITE), w)
	_grade_saturation = lerpf(1.0, float(g.get("saturation", 1.0)), w)
	_grade_sun_drop = deg_to_rad(float(g.get("sun_drop_deg", 0.0)))
	if _sky_material == null: return
	var neutral := not g.has("zenith") and not g.has("horizon")
	if neutral and _sky_palette_base.is_empty(): return
	for key: String in ["zenith", "horizon"]:
		var param := StringName("day_" + key)
		var base := _sky_palette_default(param)
		var target: Color = g.get(key, base)
		_sky_param(param, base.lerp(target, float(g.get(key + "_mix", 0.0)) * w))


func _sky_palette_default(param: StringName) -> Color:
	if _sky_palette_base.has(param): return _sky_palette_base[param]
	var value: Variant = RenderingServer.shader_get_parameter_default(_sky_material.shader.get_rid(), param)
	var base: Color = SKY_PALETTE_FALLBACK.get(param, Color(1, 1, 1))
	if value is Color: base = value
	elif value is Vector3: base = Color((value as Vector3).x, (value as Vector3).y, (value as Vector3).z)
	_sky_palette_base[param] = base
	return base


## Ground biome weights drive the environment. Blend in time and release the ground
## influence above the canopy so a high flycam does not tint the whole world forest-green.
func _update_profile() -> void:
	if _profiles.is_empty():
		return
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null:
		return
	var pos := camera.global_position
	_update_forest_shadows(pos)
	if season_grade.has("sun"): _set_season_climate(CLIMATE_MAP.sample(Vector2(pos.x, pos.z), 0))
	var influences: Dictionary = {}
	var field: WorldBiomeField = WorldTerrain.instance.biomes if is_instance_valid(WorldTerrain.instance) else null
	if field != null:
		var weights := field.sample_weights(Vector2(pos.x, pos.z))
		var ground: float = WorldTerrain.instance.height_at(pos)
		var ground_weight := 1.0 - smoothstep(35.0, 110.0, pos.y - ground) if is_finite(ground) else 1.0
		for i in weights.size():
			var preset: Dictionary = field.presets[i]
			var profile_name: String = preset.get("lighting", "default")
			var weight := weights[i] * ground_weight
			influences[profile_name] = float(influences.get(profile_name, 0.0)) + weight
		influences["default"] = float(influences.get("default", 0.0)) + 1.0 - ground_weight
	else:
		influences["default"] = 1.0
	var blend: Dictionary = {}
	var total := 0.0
	var nearest := "default"
	var greatest := 0.0
	for name: String in influences:
		var w: float = influences[name]
		if w <= 0.0001: continue
		if w > greatest: greatest = w; nearest = name
		var prof: Dictionary = _profiles.get("default", {}).duplicate()
		prof.merge(_profiles.get(name, {}), true)
		total += w
		for key in prof:
			if str(key).begins_with("_"):
				continue
			var v: Variant = prof[key]
			if v is Array:
				var c := Color(float(v[0]), float(v[1]), float(v[2]))
				blend[key] = (blend.get(key, Color(0, 0, 0)) as Color) + c * w
			else:
				blend[key] = float(blend.get(key, 0.0)) + float(v) * w
	if total <= 0.0:
		return
	for key in blend:
		if blend[key] is Color:
			blend[key] = (blend[key] as Color) / total
		else:
			blend[key] = float(blend[key]) / total
	for key in blend:
		if _profile.has(key):
			if blend[key] is Color and _profile[key] is Color:
				blend[key] = (_profile[key] as Color).lerp(blend[key], 0.3)
			elif not (blend[key] is Color) and not (_profile[key] is Color):
				blend[key] = lerpf(float(_profile[key]), float(blend[key]), 0.3)
	_profile = blend
	if nearest != _profile_region:
		_profile_region = nearest
	_apply_time()


func _pcol(key: String) -> Color:
	var v: Variant = _profile.get(key, null)
	return v if v is Color else Color(1, 1, 1)


func _pmul(key: String) -> float:
	return float(_profile.get(key, 1.0))


func _on_time_changed(_h: float) -> void:
	# A world scene on its way out (quit to title, load game) still hears the clock.
	if not is_inside_tree(): return
	# The clock advances at display rate; daylight/shadow/environment setters need
	# only 4Hz. Keep explicit clock jumps immediate (sleep, load and day controls).
	var now := Time.get_ticks_msec()
	if now - _last_light_update < 250 and absf(_h - _last_clock_hour) < .05: return
	_last_light_update = now; _last_clock_hour = _h
	_apply_time()


func _on_quality_changed(_p: int) -> void:
	_apply_quality()
	_apply_time()


func _apply_quality() -> void:
	if not _dream_state.is_empty(): return
	_shadow_budget_applied = -1  # Quality re-applies its base atlas/filter; re-evaluate the budget.
	var env := environment
	if env == null:
		return
	# The active camera's far clip follows the preset; cameras made later set their own.
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera != null:
		camera.far = Quality.get_value("draw_distance", 9000.0)
	env.sdfgi_enabled = Quality.get_value("sdfgi", false)
	env.volumetric_fog_enabled = Quality.get_value("volumetric_fog", false)
	env.ssao_enabled = Quality.get_value("ssao", false)
	env.ssil_enabled = Quality.get_value("ssil", false)
	env.glow_enabled = Quality.get_value("glow", true)
	# Very Low drops the sky reflections on materials (one less radiance read per pixel).
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY if bool(Quality.get_value("reflections", true)) else Environment.REFLECTION_SOURCE_DISABLED

	var levels: int = Quality.get_value("glow_levels", 5)
	for i in 7:
		env.set("glow_levels/%d" % (i + 1), 1.0 if i < levels else 0.0)
	_apply_clouds()
	# Street lamps and lanterns fade sooner on the low tiers (fewer lights in the cluster).
	var fade_begin: float = float(Quality.get_value("lamp_fade_begin", 45.0))
	if is_inside_tree():
		for node in get_tree().get_nodes_in_group(ZoneProcessorRef.NIGHT_LIGHT_GROUP):
			var lamp := node as OmniLight3D
			# House lamps keep their own short indoor fade (world/props/lamps/kit_lamp.gd).
			if lamp != null and lamp.distance_fade_enabled and not lamp.has_meta("indoor_lamp_fade"): lamp.distance_fade_begin = fade_begin

	if sun != null:
		sun.directional_shadow_max_distance = Quality.get_value("shadow_max_distance", 150.0)
		sun.directional_shadow_mode = Quality.get_value(
			"shadow_splits", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
		sun.shadow_blur = Quality.get_value("shadow_blur", 1.0)
		# Without blended splits the cascade boundaries show as hard seams
		# straight across the ground.
		sun.directional_shadow_blend_splits = true
		# Normal-offset bias scales with texel size; too little gives acne on the
		# large flat terrain, too much detaches shadows from what casts them.
		# Round 6: more normal offset, less constant bias; acne on the round cel
		# surfaces read as dither. Denser near cascades, fade only at the end.
		sun.shadow_normal_bias = 2.0
		sun.shadow_bias = float(Quality.get_value("shadow_depth_bias", 0.03))
		sun.directional_shadow_split_1 = float(Quality.get_value("shadow_split_1", 0.06))
		sun.directional_shadow_split_2 = 0.16
		sun.directional_shadow_split_3 = 0.4
		sun.directional_shadow_fade_start = 0.85
		# 0 = hard edges (desktop default); XR asks for a real sun disc.
		sun.light_angular_distance = Quality.get_value("sun_angular_distance", 0.0)
	if moon != null:
		moon.directional_shadow_max_distance = minf(float(Quality.get_value("shadow_max_distance", 150.0)), 60.0)
		moon.directional_shadow_mode = mini(int(Quality.get_value(
			"shadow_splits", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)), DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS) as DirectionalLight3D.ShadowMode
		moon.shadow_blur = Quality.get_value("shadow_blur", 1.0)
		moon.directional_shadow_blend_splits = true
		moon.shadow_normal_bias = 2.0
		moon.shadow_bias = float(Quality.get_value("shadow_depth_bias", 0.03))
		moon.directional_shadow_split_1 = 0.25
		moon.directional_shadow_split_2 = 0.16
		moon.directional_shadow_split_3 = 0.4
		moon.directional_shadow_fade_start = 0.85
	if _forest_shadows: _apply_forest_shadows()

	if is_instance_valid(debug_lighting): debug_lighting.apply_settings(environment)


func _apply_time() -> void:
	if not _dream_state.is_empty(): return
	var env := environment
	if env == null:
		return

	var daylight := TimeOfDay.daylight()
	var golden := TimeOfDay.golden_amount()
	var sun_dir := TimeOfDay.sun_direction()
	# Season grade: the visible sun's orbit tilts lower toward midwinter (horizon crossings kept).
	if _grade_sun_drop != 0.0: sun_dir = sun_dir.rotated(Vector3.RIGHT, _grade_sun_drop)
	var night := 1.0 - daylight
	var twilight := twilight_amount(TimeOfDay.sun_elevation()) * night if LOOK_MOODS else 0.0
	# The sunset glow that reaches land, haze and dome: less under cloud.
	var glow := golden * (1.0 - weather_overcast * LOOK_OVERCAST_GOLDEN_CUT) if LOOK_MOODS else golden

	if sun != null:
		sun.look_at_from_position(Vector3.ZERO, -sun_dir, Vector3.UP)
		sun.light_color = SUN_DAY_COLOR.lerp(SUN_GOLDEN_COLOR, golden) * _pcol("sun_tint") * _grade_sun
		sun.light_energy = lerpf(SUN_DAY_ENERGY, SUN_GOLDEN_ENERGY, golden) * daylight * _pmul("sun_mul") * weather_sun * _grade_sun_mul
		# Kept visible even at zero energy: the sky shader indexes lights by
		# order among *visible* directional lights, so hiding the sun at night
		# would promote the moon to LIGHT0 and swap the two in the sky.
		sun.visible = true
		# Fade the setting sun's shadow before handing the atlas workload to the
		# moon. Both full four-cascade passes used to run throughout twilight.
		# Keep lighting colours/energies independent of this shadow handover.
		# Overcast light is diffuse: shadows fade out under heavy cloud.
		sun.shadow_opacity = smoothstep(0.30,0.55,daylight) * (1.0 - weather_overcast * (LOOK_OVERCAST_SHADOW_FADE if LOOK_MOODS else 0.85))
		sun.shadow_enabled = sun.shadow_opacity > 0.0 and Quality.get_value("shadows_enabled", true)
		# Shafts are strongest at low sun; this is the god-ray dial.
		sun.light_volumetric_fog_energy = lerpf(2.2, 6.0, golden) * float(_profile.get("sun_mul", 1.0))

	if moon != null:
		var moon_dir := TimeOfDay.moon_direction()
		moon.look_at_from_position(Vector3.ZERO, -moon_dir, Vector3.UP)
		moon.light_color = MOON_COLOR
		moon.light_energy = MOON_ENERGY * night * TimeOfDay.moon_lit_fraction() * smoothstep(-0.06, 0.08, moon_dir.y)
		moon.visible = true
		moon.shadow_opacity = 1.0-smoothstep(0.08,0.30,daylight)
		moon.shadow_enabled = moon.shadow_opacity > 0.0 and moon_dir.y > 0.0 and Quality.get_value("shadows_enabled", true)
		moon.light_volumetric_fog_energy = 1.2
		_apply_twilight_shadow_budget()

	if _sky_material != null:
		_sky_param(&"daylight", maxf(daylight, twilight * LOOK_TWILIGHT_SKY))
		_sky_param(&"golden", glow)
		# No stars through cloud or snowfall.
		if LOOK_MOODS: _sky_param(&"star_brightness", 1.4 * (1.0 - clampf(weather_overcast * 1.25, 0.0, 1.0)))
		# Never fully dark: the night sky has to stay readable enough to walk by.
		_sky_param(&"exposure", lerpf(0.55, 1.0, maxf(daylight, twilight * 0.6)))

	var fog_color := FOG_NIGHT_COLOR.lerp(FOG_DAY_COLOR, daylight)
	fog_color = fog_color.lerp(LOOK_TWILIGHT_HAZE, twilight * 0.8)
	fog_color = fog_color.lerp(FOG_GOLDEN_COLOR, glow * 0.75) * _pcol("fog_tint") * _grade_fog
	env.fog_light_color = fog_color

	# Mist peaks in the hour around sunrise and burns off through the morning, on misty mornings
	# only (dev 2026-10-14: every daybreak and dusk fogged up and he could barely see).
	var dawn_mist: float = golden if TimeOfDay.hours < 12.0 and _misty_morning() else 0.0
	var density_mul: float = Quality.get_value("fog_density_mul", 1.0)
	var draw: float = Quality.get_value("draw_distance", 9000.0)
	var haze_begin: float = (LOOK_HAZE_BEGIN if LOOK_HAZE else draw * FOG_CLEAR) * _pmul("fog_clear_mul")
	env.fog_depth_begin = lerpf(haze_begin, minf(haze_begin, FOG_DAWN_BEGIN), dawn_mist)
	var local_fog := clampf(float(_profile.get("local_fog", 0.0)), 0.0, 1.0)
	# Blend extinction distances reciprocally. Linear kilometre/metre interpolation
	# leaves a 70% forest biome almost clear out to four kilometres.
	env.fog_depth_begin = 1.0 / lerpf(1.0 / maxf(env.fog_depth_begin, 1.0), 1.0 / float(_profile.get("fog_near", 30.0)), local_fog)
	env.fog_depth_end = 1.0 / lerpf(1.0 / (draw * FOG_END_FRACTION), 1.0 / float(_profile.get("fog_far", 260.0)), local_fog)
	env.fog_density = clampf(FOG_MAX * density_mul * _pmul("fog_density_mul"), 0.0, 1.0)
	if weather_fog > 0.0 or weather_overcast > 0.0:
		# Rain haze and fog banks: the far world greys out, fog pulls right in.
		var haze := maxf(weather_fog, weather_overcast * 0.45)
		var thick := clampf(weather_fog * 1.4, 0.0, 1.0)
		env.fog_depth_begin = lerpf(env.fog_depth_begin, 2.0, thick)
		env.fog_depth_end = lerpf(env.fog_depth_end, 70.0, thick)
		env.fog_depth_end = lerpf(env.fog_depth_end, minf(env.fog_depth_end, 1400.0), weather_overcast)
		env.fog_density = clampf(env.fog_density + haze * 0.5, 0.0, 1.0)
		var cloud_haze := Color(0.62, 0.65, 0.7) * lerpf(0.25, 1.0, daylight)
		if LOOK_MOODS: cloud_haze = LOOK_OVERCAST_HAZE_NIGHT.lerp(LOOK_OVERCAST_HAZE_DAY, daylight)
		env.fog_light_color = env.fog_light_color.lerp(cloud_haze, haze)

	var vol_mul: float = Quality.get_value("vol_fog_density_mul", 1.0)
	env.volumetric_fog_density = VOL_FOG_BASE_DENSITY * (1.0 + dawn_mist * DAWN_GLOW) * vol_mul
	env.volumetric_fog_emission = fog_color * 0.02 * daylight

	_update_lamps(daylight)
	var cloud_shadow := daylight * weather_sun * (1.0 - weather_overcast) * LOOK_CLOUD_SHADOW_STRENGTH if LOOK_CLOUD_SHADOWS else 0.0
	if absf(cloud_shadow - _cloud_shadow_written) > 0.01:
		_cloud_shadow_written = cloud_shadow
		RenderingServer.global_shader_parameter_set(&"look_cloud_shadow", cloud_shadow)
	# Spring blossom, petals and young leaf carry a little light of their own by day
	# (world/foliage/vegetation_color.gdshaderinc vegetation_spring_light); none at night.
	if absf(daylight - _daylight_written) > 0.01:
		_daylight_written = daylight
		RenderingServer.global_shader_parameter_set(&"sky_daylight", daylight)

	var ambient_boost: float = Quality.get_value("ambient_boost", 1.0)
	var ambient_color := AMBIENT_NIGHT_COLOR.lerp(AMBIENT_DAY_COLOR, daylight)
	# Region colour remains strong by day, subtler at night so dark-biome tints
	# cannot erase the common visibility floor.
	var ambient_tint := Color.WHITE.lerp(_pcol("ambient_tint"), lerpf(0.25, 1.0, daylight))
	# The fill as the old rules had it. House interiors and the far window cards (interior_light)
	# keep reading this one, so rooms and lit windows look as they did.
	var legacy_ambient := ambient_color.lerp(AMBIENT_GOLDEN_COLOR, golden * 0.6) * ambient_tint * _grade_ambient
	var base_energy := lerpf(
		AMBIENT_NIGHT_ENERGY, AMBIENT_DAY_ENERGY, daylight) * lerpf(1.0, ambient_boost, daylight) * lerpf(clampf(_pmul("ambient_mul"), 0.95, 1.10), _pmul("ambient_mul"), daylight)
	if LOOK_MOODS:
		# Shade opposite the light at sunset, deep blue through the blue hour.
		ambient_color = ambient_color.lerp(LOOK_GOLDEN_FILL, glow * 0.6).lerp(LOOK_TWILIGHT_FILL, twilight * 0.7)
		ambient_color = ambient_color * ambient_tint * _grade_ambient
	else:
		ambient_color = legacy_ambient
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = base_energy + LOOK_TWILIGHT_ENERGY * twilight
	# The dense Everfree's dark bark falls below the contrast pivot at night.
	# Neutral night contrast preserves the existing ambient fill instead of clipping it.
	env.adjustment_contrast = lerpf(float(_profile.get("night_contrast", 1.04)), 1.04, daylight)
	env.adjustment_saturation = lerpf(1.0, 1.22, daylight) * _pmul("saturation") * lerpf(1.0, LOOK_OVERCAST_SATURATION if LOOK_MOODS else 0.78, weather_overcast) * _grade_saturation
	if LOOK_MOODS:
		# Cloud cover: cooler and a little dimmer, but still coloured light.
		env.ambient_light_color = env.ambient_light_color.lerp(LOOK_OVERCAST_FILL_NIGHT.lerp(LOOK_OVERCAST_FILL_DAY, daylight), weather_overcast * 0.6)
		env.ambient_light_energy *= lerpf(1.0, LOOK_OVERCAST_FILL_ENERGY, weather_overcast)
		env.tonemap_exposure = lerpf(1.0, LOOK_OVERCAST_EXPOSURE, weather_overcast * (1.0 - weather_sun)) * (1.0 + LOOK_GOLDEN_EXPOSURE * glow)
	else:
		# Overcast: flat grey sky light instead of blue fill, a little dimmer.
		env.ambient_light_color = env.ambient_light_color.lerp(Color(0.72, 0.74, 0.78), weather_overcast * 0.6)
		env.ambient_light_energy *= lerpf(1.0, 0.72, weather_overcast)
		env.tonemap_exposure = lerpf(1.0, 0.78, weather_overcast * (1.0 - weather_sun))
	env.fog_sky_affect = FOG_SKY_AFFECT
	if LOOK_SNOW_AIR and weather_snow > 0.001:
		env.fog_sky_affect = lerpf(FOG_SKY_AFFECT, LOOK_SNOW_AIR_SKY, clampf(weather_snow * 1.5, 0.0, 1.0))
		# Distances blend by their reciprocals, like the forest fog above.
		env.fog_depth_begin = 1.0 / lerpf(1.0 / maxf(env.fog_depth_begin, 1.0), 1.0 / 6.0, weather_snow)
		env.fog_depth_end = 1.0 / lerpf(1.0 / maxf(env.fog_depth_end, 1.0), 1.0 / LOOK_SNOW_AIR_RANGE, weather_snow)
		env.fog_density = clampf(lerpf(env.fog_density, 0.96, weather_snow), 0.0, 1.0)
		# White snow in the air, lit by the fill light (and a little by the sun when it is out).
		var lit := env.ambient_light_color * clampf(env.ambient_light_energy * 1.25, 0.1, 1.0)
		var snow_air := lit.lerp(Color(0.86, 0.90, 0.97), daylight * 0.55)
		env.fog_light_color = env.fog_light_color.lerp(snow_air, clampf(weather_snow * 1.3, 0.0, 1.0))
	ambient_color = legacy_ambient
	var legacy_energy := base_energy * lerpf(1.0, 0.72, weather_overcast)
	# Room shells bypass GI to avoid the thin-roof leak. Match the exterior's linear
	# night irradiance, while retaining the accepted brighter daytime room fill.
	var inside := (ambient_color * legacy_energy).lerp(
		ambient_color.srgb_to_linear() * legacy_energy, night)
	RenderingServer.global_shader_parameter_set("interior_light", inside)
	_apply_grade(daylight, golden)
	if is_instance_valid(debug_lighting): debug_lighting.apply_time(environment, daylight)


## Storybook colour grade (world/sky/color_grade.gd); video/color_grade turns it off.
func _apply_grade(daylight: float, golden: float) -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings != null and not bool(settings.get_value("video/color_grade")):
		if environment.adjustment_color_correction != null: environment.adjustment_color_correction = null
		return
	var table: Texture3D = COLOR_GRADE.table(daylight, golden)
	if table != null and environment.adjustment_color_correction != table:
		environment.adjustment_color_correction = table


## Low sun puts most of the view in shadow and stretches every caster across the
## cascades: in the XR-quality proxy the directional shadows cost 2.4 ms at noon and
## 7 ms at golden hour with everything else flat, and the 8192 atlas is the largest
## single term (17:30, GPU ms: 16.2 base, 12.0 with a 4096 atlas, 13.2 hard filter, 14.4
## soft-low, 9.2 no shadows; captures/shaders/shadow-variants.log, 2026-09-15). Under
## about 20 degrees of light elevation the atlas drops to 4096 and the filter one step;
## under about 9 degrees the filter drops another step. Day keeps the full preset.
var _shadow_budget_applied := -1
## Under the Everfree's canopy nothing far casts a shadow anyone sees, yet every tree within the
## preset's shadow reach was drawn into four cascades (dev 2026-10-02, opening at 35 FPS on Ultra:
## the shadow pass drew 4.4 M triangles in 1270 draws, more than the view itself). There the sun
## and moon shadows reach FOREST_SHADOW_M in two cascades, with soft filtering capped at
## FOREST_SOFT_QUALITY; open ground keeps the preset.
const FOREST_SHADOW_M := 50.0
const FOREST_SOFT_QUALITY := 3
var _forest_shadows := false
var _forest_box := Rect2()

func _update_forest_shadows(pos: Vector3) -> void:
	if _forest_box.size == Vector2.ZERO:
		_forest_box = WorldLayout.footprint(WorldLayout.region("everfree"))
	var ground: float = WorldTerrain.instance.height_at(pos) if is_instance_valid(WorldTerrain.instance) else NAN
	var under_canopy := not is_finite(ground) or pos.y - ground < 30.0
	var forest := _forest_box.has_point(Vector2(pos.x, pos.z)) and under_canopy
	if forest == _forest_shadows: return
	_forest_shadows = forest
	_apply_forest_shadows()

func _apply_forest_shadows() -> void:
	var reach: float = float(Quality.get_value("shadow_max_distance", 150.0))
	var splits: int = int(Quality.get_value("shadow_splits", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS))
	if _forest_shadows:
		reach = minf(reach, FOREST_SHADOW_M)
		if splits == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS: splits = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	for light: DirectionalLight3D in [sun, moon]:
		if light == null: continue
		light.directional_shadow_max_distance = minf(reach, 60.0) if light == moon else reach
		var light_splits := mini(splits, DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS) if light == moon else splits
		light.directional_shadow_mode = light_splits as DirectionalLight3D.ShadowMode
		# Two cascades over 50 m: the near one covers the first quarter, not the first 6 %.
		light.directional_shadow_split_1 = 0.25 if _forest_shadows or light == moon else float(Quality.get_value("shadow_split_1", 0.06))
	_shadow_budget_applied = -1
	if sun != null: _apply_twilight_shadow_budget()

func _apply_twilight_shadow_budget() -> void:
	var base_quality: int = int(Quality.get_value("soft_shadow_quality", 3))
	if _forest_shadows: base_quality = mini(base_quality, int(Quality.get_value("forest_soft_shadow_quality", FOREST_SOFT_QUALITY)))
	var base_atlas: int = int(Quality.get_value("directional_shadow_size", 8192))
	if _forest_shadows: base_atlas = mini(base_atlas, int(Quality.get_value("forest_shadow_atlas", base_atlas)))
	var active: DirectionalLight3D = sun if sun.shadow_enabled else (moon if moon.shadow_enabled else null)
	var step := 0
	if active != null:
		# The light shines along -basis.z (downward by day), so basis.z.y is the sine of
		# the light's elevation above the horizon.
		var elevation: float = active.global_basis.z.y
		step = 2 if elevation < 0.15 else (1 if elevation < 0.35 else 0)
	if step == _shadow_budget_applied: return
	_shadow_budget_applied = step
	var quality := base_quality if step == 0 else mini(base_quality, 3 - step)
	var atlas := base_atlas if step == 0 else mini(base_atlas, 4096)
	RenderingServer.directional_soft_shadow_filter_set_quality(quality as RenderingServer.ShadowQuality)
	RenderingServer.directional_shadow_atlas_set_size(atlas, true)
