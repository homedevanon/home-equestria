extends Node
## Quality ladder.
##
## Dev box is a 4080 Super but the shipping floor is a 3060 holding 90 fps in
## stereo, so LOW is the preset that actually has to make frame time. The big
## atmosphere uses an explicit ambient floor at every preset, matching XR. SDFGI
## replaces ambient with occluded probes, which blacked out closed rooms despite
## the night visibility floor. Direct lights, shadows and preset SSAO retain depth.
## Everything
## here is only cost knobs -- SkyController owns the actual Environment writes so
## there is exactly one writer for atmosphere (see world/sky_controller.gd).
##
## 2026-09-29 (dev: "performance tiers for medium and low and ultra low that actually run on
## extremely low memory/gpu power systems ... sacrificing the least amount of visual fidelity"):
## five tiers, Very Low / Low / Medium / High / Ultra. High and Ultra are the earlier presets;
## Medium is roughly the old Low look with lighter shadows; Low and Very Low cut scenery,
## effects and distance only. Ponies keep full fidelity in every tier: every pony stays present
## (the population and nearby_limit are never lowered by a preset), HERO range stays the
## spitting-distance 4 m so faces, hands and kissing are untouched, and the tiers only move
## ponies onto the clip tier and the merged far mesh sooner and tick the far ones less often.
## docs/PERFORMANCE_TIERS_2026_09_29.md has the table, the wiring and the limits.

enum Preset { VERY_LOW, LOW, MEDIUM, HIGH, ULTRA }

signal preset_changed(preset: int)

const LOG_LEVEL := preload("res://world/debug/log_level.gd")
const PRESET_NAMES: Array[String] = ["Very Low", "Low", "Medium", "High", "Ultra"]

## Temporary --debug experiments; never merged into saved quality settings.
const LIGHTING_TESTS := {
	"baseline": {"label": "Baseline — current game", "note": "Restores normal lighting and the current quality settings."},
	"contact": {"label": "Contact shading", "note": "Less uniform fill, with SSAO to define corners and contact.", "ssao": true},
	"fill": {"label": "Local room fill", "note": "Two shadowed fill lights in the room you occupy. Approximate bounce.", "fill": true},
	"ssil": {"label": "Screen-space indirect light", "note": "SSIL + contact shading. Cannot use surfaces outside the camera view.", "ssao": true, "ssil": true},
	"sdfgi": {"label": "Realtime SDFGI", "note": "Dynamic bounce; high GPU cost. Allow several seconds to settle.", "sdfgi": true},
	"reflection": {"label": "Local reflection probe", "note": "Room reflections. Refresh after changing lamps or time of day.", "probe": true},
	"atmosphere": {"label": "Atmosphere + room fill", "note": "Local fill and reflections, soft glow and light volumetric haze.", "fill": true, "probe": true, "atmosphere": true},
	"combined": {"label": "SSIL + room fill", "note": "Local fill, SSIL, contact shading and room reflections.", "fill": true, "probe": true, "ssil": true, "ssao": true},
}

const CONFIG := {
	# Measured on the dev 4080S at 2064x2208 (one Quest-3 eye): Low 0.79 ms,
	# Ultra 2.72 ms against an 11 ms budget. Tripling the pixel count barely
	# moved those numbers, so this workload is draw-call bound, not pixel bound
	# -- resolution and shader cost are nearly free here, and the lever that
	# would actually matter is batching the town's 3294 mesh instances.
	#
	# That headroom is why Medium (the old Low) keeps volumetric fog: the fog and god rays do
	# most of the emotional work in this art direction. Low and Very Low are for machines
	# without that headroom (iGPUs, 2-4 GB cards) and drop them for depth fog plus ambient.
	#
	# Key reference (consumers in brackets):
	#   draw_distance          camera far clip, depth fog end, forest fill reach [sky_controller, game, biome_foliage]
	#   crowd_hero_budget      0 = no HERO tier at all (no live solver) [pony_crowd]
	#   physics_hz             physics ticks per second (60 everywhere: 30 made the XR rig and hands jitter, dev 2026-09-29) [quality]
	#   interior_range         house interiors stop drawing past this many metres while the door is shut, 0 = never [house_interior]
	#   crowd_far_tick_divisor gates FAR support/rest work (4 on desktop, 3 Ultra, 5 Very Low).
	#     Cached root movement stays at 60 Hz and gait poses at 30 Hz; scheduled logic beats
	#     always execute even between work beats [pony_crowd, pony_locomotion]
	#   nav_search_limit       cells one route search may expand before giving up [walk_grid_service]
	#   nav_sample_budget_us   main-thread walk-grid sampling per physics tick (x6 for an urgent route) [walk_grid_service]
	#   far_mesh_lods          generate LODs on the merged far pony mesh [hybrid_far_mesh]
	#   terrain_window_m       Terrain3D regions resident around the player, 0 = whole world (12 MB each) [world_terrain]
	#   terrain_texel_m        2.0 loads the baked 512-texel regions (3 MB each) [world_terrain]
	#   texture_mip_drop       imported textures lose this many top mip levels at load; needs a restart [settings, texture_mip_loader]
	#   volume_clouds/cloud_steps  volumetric raymarch layer vs the flat painted clouds, march steps [sky_controller]
	#   shadows_enabled        sun/moon shadow maps at all [sky_controller]
	#   shadow_split_1         sun's first cascade boundary as a share of shadow_max_distance (default 0.06) [sky_controller]
	#   scaling_mode           Viewport.scaling_3d_mode for render_scale < 1; FSR2 falls back to bilinear at 100% [this node]
	#   desktop_msaa           MSAA off the headset; "msaa" is what XR keeps [this node]
	#   render_scale           also capped to about 1080p's pixel count on bigger desktop windows while Settings says Auto [this node]
	#   use_taa                desktop TAA from Settings → Anti-aliasing [this node]
	#   mipmap_bias            Viewport.texture_mipmap_bias [this node]
	#   grass_density/grass_range_mul/grass_rings  ground grass coverage, ring radii, ring count [settings.apply_grass, ground_grass]
	#   grass_lite_clumps     near grass rings use the fewer-segment clumps (High and below) [ground_grass]
	#   pony_impostor_from    FAR ponies past this distance draw as a camera-facing picture [pony_impostors]
	#   impostor_from          camera distance where trees become baked impostor quads [painted_tree_batches]
	#   lamp_fade_begin        omni street lamp fade start [street_lamps, sky_controller]
	#   weather_particle_scale/firefly_scale  rain/snow/hail amount, firefly swarm count [weather, fireflies]
	#   small_caster           town meshes under this size stop casting sun shadows [town_render_budget]
	#   reflections            sky reflections on materials [sky_controller]
	#   ocean/ocean_cascades   FFT vs classic sea, FFT cascade count [world_water, world_ocean]
	#   terrain_mesh_size/terrain_mesh_lods/terrain_projection  Terrain3D clipmap detail and cliff projection [world_terrain]
	#   zone_resident_budget   detailed zones kept resident [zone_manager]
	#   crowd_hero_distance/crowd_near_distance/crowd_far_divisor  pony tiers and FAR logic rate [pony_crowd]
	#     (Low..Ultra FAR decide every 6th step, 10 Hz, since 2026-10-13: their motion still runs every step)
	#   season keys            see SEASON_CONFIG below (merged into every tier)
	Preset.VERY_LOW: {
		# 1.5 km: the valley and the town; Canterlot and the far ranges sit in the fog.
		"draw_distance": 600.0,
		"sdfgi": false,
		"volumetric_fog": false,
		"ssao": false,
		"ssil": false,
		"glow": false,
		"glow_levels": 2,
		# No fog volume and no GI: the ambient floor and a thicker depth fog carry the depth.
		"ambient_boost": 1.5,
		"fog_density_mul": 1.6,
		"vol_fog_density_mul": 0.0,
		# No positional light casts shadows (street_lamps.gd, zone_processor.gd), so the
		# positional atlas can be the minimum on the low tiers at zero visual cost.
		"shadow_atlas": 1024,
		"directional_shadow_size": 1024,
		"shadow_blur": 1.0,
		"shadow_max_distance": 20.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"soft_shadow_quality": 0,
		# Sun shadows stay, tiny and hard (1024 map, 20 m): ponies and houses must never float
		# (dev 2026-09-29). The Shadows row can still switch them off.
		"shadows_enabled": false,
		"msaa": Viewport.MSAA_DISABLED,
		"render_scale": 0.7,
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA,
		"mesh_lod_threshold": 8.0,
		"mipmap_bias": 1.0,
		"volume_clouds": false,
		"cloud_steps": 12,
		"grass_density": 0.2,
		"grass_range_mul": 0.6,
		"grass_rings": 1,
		"grass_lite_clumps": true,
		"pony_impostor_from": 80.0,
		"impostor_from": 0.0,
		"lamp_fade_begin": 25.0,
		"weather_particle_scale": 0.4,
		"firefly_scale": 0.4,
		"small_caster": 5.0,
		"reflections": false,
		"ocean": "classic",
		"ocean_cascades": 2,
		"terrain_mesh_size": 16,
		"terrain_mesh_lods": 6,
		"terrain_projection": false,
		"terrain_window_m": 1600.0,
		"terrain_texel_m": 2.0,
		"texture_mip_drop": 1,
		"zone_resident_budget": 1,
		"crowd_hero_distance": 4.0,
		# dev 2026-09-29: the potato tier tried no HERO tier + LOD'd far meshes; boops died and the
		# frame did not move, so ponies keep their normal tiers here. FPS comes from the world.
		"crowd_hero_budget": 1000,
		"far_mesh_lods": false,
		"crowd_near_distance": 20.0,
		"crowd_far_divisor": 12,
		"physics_hz": 60,
		"interior_range": 20.0,
		"crowd_far_tick_divisor": 5,
		# Total route work, not a per-frame budget. Keep reachability across presets;
		# the 8,000 cap repeatedly abandoned ordinary town trips. Native work is sliced.
		"nav_search_limit": 100000,
		"nav_sample_budget_us": 1000,
	},
	Preset.LOW: {
		"draw_distance": 3000.0,
		"sdfgi": false,
		"volumetric_fog": false,
		"ssao": false,
		"ssil": false,
		"glow": false,
		"glow_levels": 3,
		"ambient_boost": 1.5,
		"fog_density_mul": 1.3,
		"vol_fog_density_mul": 0.0,
		"shadow_atlas": 1024,
		# The sun uses its own map, separate from the positional atlas.
		"directional_shadow_size": 2048,
		"shadow_blur": 1.5,
		# The coarse directional map needs depth separation on Terrain3D slopes.
		"shadow_depth_bias": 0.1,
		"shadow_max_distance": 40.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"soft_shadow_quality": 1,
		"shadows_enabled": true,
		"msaa": Viewport.MSAA_DISABLED,
		"render_scale": 0.85,
		"scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
		# Outlines are computed per-pixel after MSAA resolves, so MSAA does
		# nothing for them. Supersampling and FXAA are what smooth the lines.
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA,
		"mesh_lod_threshold": 4.0,
		"mipmap_bias": 0.5,
		"volume_clouds": false,
		"cloud_steps": 18,
		"grass_density": 0.5,
		"grass_range_mul": 0.7,
		"grass_rings": 2,
		"grass_lite_clumps": true,
		"pony_impostor_from": 100.0,
		"impostor_from": 180.0,
		"lamp_fade_begin": 35.0,
		"weather_particle_scale": 0.7,
		"firefly_scale": 0.7,
		"small_caster": 3.0,
		"reflections": true,
		"ocean": "fft",
		"ocean_cascades": 2,
		"terrain_mesh_size": 32,
		"terrain_mesh_lods": 7,
		"terrain_projection": true,
		"terrain_window_m": 3200.0,
		"terrain_texel_m": 1.0,
		"texture_mip_drop": 0,
		"zone_resident_budget": 2,
		"crowd_hero_distance": 4.0,
		"crowd_hero_budget": 1000,
		# Same distant face/tail cutoff as Very Low; close interactions retain full detail.
		"crowd_near_distance": 20.0,
		"crowd_far_divisor": 6,
		"physics_hz": 60,
		"interior_range": 40.0,
		"crowd_far_tick_divisor": 4,
		"nav_search_limit": 100000,
		"nav_sample_budget_us": 1000,
	},
	Preset.MEDIUM: {
		# The old Low look (fog, god rays, 6 km) with lighter shadows.
		"draw_distance": 6000.0,
		"sdfgi": false,
		"volumetric_fog": true,
		"ssao": false,
		"ssil": false,
		"glow": true,
		"glow_levels": 4,
		# No GI, so lift ambient and lean on aerial perspective to keep depth.
		"ambient_boost": 1.45,
		"fog_density_mul": 1.25,
		"vol_fog_density_mul": 0.55,
		"shadow_atlas": 1024,
		"directional_shadow_size": 4096,
		"shadow_blur": 1.25,
		"shadow_max_distance": 60.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"soft_shadow_quality": 2,
		"shadows_enabled": true,
		"msaa": Viewport.MSAA_2X,
		# Desktop drops MSAA for SMAA (dev 2026-10-23): MSAA never smoothed the alpha-cut grass and
		# leaf cards and cost more with every extra pixel. "msaa" above is what VR keeps.
		"desktop_msaa": Viewport.MSAA_DISABLED,
		"render_scale": 1.00,
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2,
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_SMAA,
		"mesh_lod_threshold": 2.0,
		"mipmap_bias": 0.0,
		"volume_clouds": true,
		"cloud_steps": 18,
		"grass_density": 0.75,
		"grass_range_mul": 1.0,
		"grass_rings": 3,
		"grass_lite_clumps": true,
		"pony_impostor_from": 120.0,
		"impostor_from": 300.0,
		"lamp_fade_begin": 45.0,
		"weather_particle_scale": 1.0,
		"firefly_scale": 1.0,
		"small_caster": 3.0,  # dev 2026-10-14: small town shadows only on Ultra
		"reflections": true,
		"ocean": "fft",
		"ocean_cascades": 3,
		"terrain_mesh_size": 32,
		"terrain_mesh_lods": 7,
		"terrain_projection": true,
		"terrain_window_m": 4500.0,
		"terrain_texel_m": 1.0,
		"texture_mip_drop": 0,
		"zone_resident_budget": 3,
		"crowd_hero_distance": 4.0,
		"crowd_hero_budget": 1000,
		"crowd_near_distance": 30.0,
		"crowd_far_divisor": 6,
		"physics_hz": 60,
		"interior_range": 40.0,
		"crowd_far_tick_divisor": 4,
		"nav_search_limit": 100000,
		"nav_sample_budget_us": 1000,
	},
	Preset.HIGH: {
		# Camera far clip and the end of the depth fog (15 km world, WORLD.md).
		"draw_distance": 12000.0,
		"sdfgi": false,
		"volumetric_fog": true,
		"ssao": true,
		"ssil": false,
		"glow": true,
		"glow_levels": 5,
		"ambient_boost": 1.0,
		"fog_density_mul": 1.0,
		"vol_fog_density_mul": 1.0,
		"shadow_atlas": 1024,
		# The sun uses its own map, separate from the positional atlas.
		# 4096 and 60 m (dev 2026-10-23 "do all of it", GPU pass: 8192 cost up to 0.37 ms, the
		# 60-100 m band ~180k shadow triangles). Ultra keeps 8192 and 150 m.
		"directional_shadow_size": 4096,
		"shadow_blur": 1.05,
		"shadow_max_distance": 60.0,
		# 2 cascades (was 4, dev 2026-10-23 triangle pass): every shadow caster is drawn once per
		# cascade. The near cascade covers 20 m (a third of 60 m) so close shadows keep their resolution.
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow_split_1": 0.33,
		"soft_shadow_quality": 4,
		"shadows_enabled": true,
		"msaa": Viewport.MSAA_2X,
		# Desktop drops MSAA for SMAA (dev 2026-10-23): MSAA never smoothed the alpha-cut grass and
		# leaf cards and cost more with every extra pixel. "msaa" above is what VR keeps.
		"desktop_msaa": Viewport.MSAA_DISABLED,
		"render_scale": 1.00,
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2,
		# Outlines are computed per-pixel after MSAA resolves, so MSAA does
		# nothing for them. Supersampling and SMAA (or FSR2 when upscaling) smooth the lines.
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_SMAA,
		"mesh_lod_threshold": 1.0,
		"mipmap_bias": 0.0,
		"volume_clouds": true,
		"cloud_steps": 18,  # 28 until the 2026-10-23 GPU pass (clouds 0.2-0.5 ms)
		"grass_density": 1.0,
		"grass_range_mul": 1.0,
		"grass_rings": 3,
		"grass_lite_clumps": true,  # High too (dev 2026-10-23 grass cost pass: +2-4 FPS); Ultra keeps the full clumps
		"pony_impostor_from": 150.0,
		"impostor_from": 500.0,
		"lamp_fade_begin": 45.0,
		"weather_particle_scale": 1.0,
		"firefly_scale": 1.0,
		"small_caster": 3.0,  # dev 2026-10-14: small town shadows only on Ultra
		"reflections": true,
		"ocean": "fft",
		"ocean_cascades": 4,
		"terrain_mesh_size": 32,
		"terrain_mesh_lods": 7,
		"terrain_projection": true,
		"terrain_window_m": 0.0,
		"terrain_texel_m": 1.0,
		"texture_mip_drop": 0,
		"zone_resident_budget": 3,
		"crowd_hero_distance": 4.0,
		"crowd_hero_budget": 1000,
		"crowd_near_distance": 30.0,
		"crowd_far_divisor": 6,
		"physics_hz": 60,
		"interior_range": 40.0,
		"crowd_far_tick_divisor": 4,
		"nav_search_limit": 100000,
		"nav_sample_budget_us": 1000,
	},
	Preset.ULTRA: {
		# Camera far clip and the end of the depth fog (15 km world, WORLD.md).
		"draw_distance": 15000.0,
		"sdfgi": false,
		"volumetric_fog": true,
		"ssao": true,
		"ssil": false,
		"glow": true,
		"glow_levels": 5,
		"ambient_boost": 1.0,
		"fog_density_mul": 1.0,
		"vol_fog_density_mul": 1.3,
		"shadow_atlas": 1024,
		# The sun uses its own map, separate from the positional atlas.
		"directional_shadow_size": 8192,
		"shadow_blur": 1.00,
		"shadow_max_distance": 150.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"soft_shadow_quality": 5,
		"shadows_enabled": true,
		"msaa": Viewport.MSAA_2X,
		# Desktop drops MSAA for SMAA (dev 2026-10-23): MSAA never smoothed the alpha-cut grass and
		# leaf cards and cost more with every extra pixel. "msaa" above is what VR keeps.
		"desktop_msaa": Viewport.MSAA_DISABLED,
		"render_scale": 1.00,
		"scaling_mode": Viewport.SCALING_3D_MODE_FSR2,
		# Outlines are computed per-pixel after MSAA resolves, so MSAA does
		# nothing for them. Supersampling and SMAA (or FSR2 when upscaling) smooth the lines.
		"screen_space_aa": Viewport.SCREEN_SPACE_AA_SMAA,
		"mesh_lod_threshold": 1.0,
		"mipmap_bias": 0.0,
		"volume_clouds": true,
		"cloud_steps": 28,
		"grass_density": 1.0,
		"grass_range_mul": 1.0,
		"grass_rings": 3,
		"grass_lite_clumps": false,
		"pony_impostor_from": 250.0,
		"impostor_from": 500.0,
		"lamp_fade_begin": 45.0,
		"weather_particle_scale": 1.0,
		"firefly_scale": 1.0,
		"small_caster": 1.6,
		"reflections": true,
		"ocean": "fft",
		"ocean_cascades": 4,
		"terrain_mesh_size": 48,
		"terrain_mesh_lods": 7,
		"terrain_projection": true,
		"terrain_window_m": 0.0,
		"terrain_texel_m": 1.0,
		"texture_mip_drop": 0,
		"zone_resident_budget": 3,
		"crowd_hero_distance": 4.0,
		"crowd_hero_budget": 1000,
		"crowd_near_distance": 30.0,
		"crowd_far_divisor": 6,
		"physics_hz": 60,
		"interior_range": 40.0,
		"crowd_far_tick_divisor": 3,
		"nav_search_limit": 100000,
		"nav_sample_budget_us": 1000,
	},
}

## Seasonal feature knobs per tier, Very Low .. Ultra (seasons design 6.9). One table instead of
## five dictionary rows so the tiers stay side by side; get_config/get_value merge it into the
## tier. Consumers read these with their own defaults, so a missing key never blocks them:
##   season_particle_scale  falling leaves/petals amount [world/seasons/season_particles]
##   snow_trails            trail image size in px, 0 = off [world/seasons/snow_trail]
##   leaf_piles             most live autumn leaf piles [world/seasons/leaf_piles]
##   roof_snow              snow on roofs and props, false = terrain only [season shader include users]
##   wet_surfaces/puddles   wet darkening and rain rings / standing puddles [snow_trail, ice_slabs, ground_contact_audio]
##   water_ice_look         "flat" plain ice colour or "full" cracks and detail [world/seasons/ice_slabs]
##   bare_tree_mode         "vertex_collapse" at every tier; the bare impostor atlas for Ultra waits on
##                          the dev's call (D-03), so distant bare trees stay hash-thinned impostors
## A standalone headset (Quest) always reads the Very Low column, whatever tier the player picks:
## seasons are scenery cost on an 8 GB shared-memory device. The raw values here are the tier's;
## the "Seasonal effects" setting (Full/Reduced/Off) comes on top through season_value().
const SEASON_CONFIG := {
	"season_particle_scale": [0.25, 0.5, 0.75, 1.0, 1.0],
	"snow_trails": [0, 0, 128, 256, 256],
	"leaf_piles": [4, 8, 16, 24, 32],
	"roof_snow": [false, true, true, true, true],
	"wet_surfaces": [false, true, true, true, true],
	"puddles": [false, false, true, true, true],
	"water_ice_look": ["flat", "full", "full", "full", "full"],
	"bare_tree_mode": ["vertex_collapse", "vertex_collapse", "vertex_collapse", "vertex_collapse", "vertex_collapse"],
}
## Keys the "Seasonal effects" setting thins: Reduced halves particles and piles, Off zeroes
## particles, trails and piles. Colours, snow cover, ice and wet looks are kept at every level.
const SEASON_EFFECT_KEYS := ["season_particle_scale", "snow_trails", "leaf_piles"]
const SEASON_EFFECT_LEVELS := {"off": 0, "reduced": 1, "full": 2}
## Quest/Android: season keys come from the Very Low column at every tier (tests flip it).
var season_force_very_low := OS.has_feature("android")

var preset: int = Preset.HIGH:
	set(value):
		var clamped := clampi(value, 0, PRESET_NAMES.size() - 1)
		if clamped == preset and _applied:
			return
		preset = clamped
		_apply_viewport_settings()
		preset_changed.emit(preset)

# A bounded desktop diagnostic profile; normal gameplay presets are unchanged.
const PREVIEW_OVERRIDES := {
	"volumetric_fog": false, "glow": false,
	"shadow_max_distance": 35.0, "soft_shadow_quality": 3,
}
var preview_mode := false
var preview_shadows_enabled := true
# Stereo overrides, applied on top of any preset. Every screen-space or
# temporal effect goes: SDFGI, volumetric fog (temporal reprojection) and
# SSAO each lag head motion by a frame or two and read as a haze stuck to the
# lenses (dev, first headset session 2026-09-06: "a stagnant glaze"); bloom
# halos differ per eye; FXAA smears. Geometry AA and softer shadow edges stay.
const XR_OVERRIDES := {
	# Dense canopy already uses two cascades over 50 m. A 4096 atlas and medium
	# filtering cut the measured High XR-quality forest proxy from 12.5 to 7.2 ms.
	# Limit this tradeoff to the forest; open landscapes retain their existing atlas.
	"forest_shadow_atlas": 4096,
	"forest_soft_shadow_quality": 2,
	# The FFT ocean drops its finest (7 m) wave cascade in the headset (world_ocean.gd).
	"ocean_cascades": 3,
	# Persistent distant models cover the other regions. Keep native geometry/physics
	# for the two nearest zones instead of retaining a third full scene in VRAM.
	"zone_resident_budget": 2,
	# Crowd solver tiers (pony_crowd.gd): by distance only, no head-count cap (dev
	# 2026-09-17: no mare near the player may be FAR). A solver mare costs ~0.6 ms per tick,
	# a clip mare ~0.1 ms. 2026-09-25 (later): the clip tiers play the solver-baked gaits with a
	# live head (docs/CLIP_TIER_2026_09_25.md), so HERO is only "spitting distance".
	"crowd_hero_distance": 4.0,
	"crowd_near_distance": 30.0,
	"msaa": Viewport.MSAA_2X,
	"screen_space_aa": Viewport.SCREEN_SPACE_AA_DISABLED,
	# FSR is a desktop upscaler; the XR render target scales bilinearly.
	"scaling_mode": Viewport.SCALING_3D_MODE_BILINEAR,
	"glow": false,
	"sdfgi": false,
	"volumetric_fog": false,
	"ssao": false,
	"ssil": false,
	# 1.35 washed the town out and hid the cel bands (dev, round 4).
	"ambient_boost": 1.1,
	# The volumetric cloud march is half-res per eye: 18 steps in the headset.
	"cloud_steps": 18,
	# 2026-09-18: dev asked for the desktop look in the headset (these five plus the world ink
	# outline), then reverted it the same hour, unmeasured. The outline shader stayed
	# multiview-safe; only game.gd's `xr_active` gate keeps it off in XR now.
	# Shadow-map aliasing, not MSAA, is what reads as jagged edges in the
	# headset: shorter shadow range gives each split more texels, a real sun
	# disc gives a penumbra, and more blur hides what is left.
	# Headset trace 2026-09-06 (captures/performance/vr-round3.json): GPU 13-20
	# ms in daylight, worst looking down at one's own shadow, 6-8 ms once the
	# sun set. Shadow filtering is the budget. 16 taps, a smaller kernel and
	# two cascades over the 60 m range (blended cascades sample twice).
	# Round 4: PCSS itself is the cost (penumbra search + taps per pixel), and
	# two cascades halved near-shadow resolution ("shadows look like ass").
	# Round 5: any wide blur is grain. Godot rotates the filter taps by a
	# per-pixel screen hash, so blur 2.5-3.0 reads as a dither stuck to the
	# lenses (dev: "a chowder texture"). Hard filtering at the default blur:
	# crisp show-style edges, no screen-space pattern, cheapest path. Four
	# cascades over 60 m keep the edges clean. The sun disc has no effect here.
	# Round 6: single tap (quality 0) is a staircase that shimmers at distance
	# ("pixelated"); 8 taps at a small radius filter it without the hash grain
	# a wide kernel shows. Range 90 m so far shadows do not fade to flat; the
	# near cascades get more texels via split ratios in sky_controller.gd.
	# October 13 approved performance policy: 70 m, 4096 map and PCSS off;
	# retain four cascades/filtering, with matched views and headset review pending.
	"shadow_blur": 1.3,
	"soft_shadow_quality": 3,
	"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
	"shadow_max_distance": 70.0,
	"sun_angular_distance": 0.0,
	# History: 8192 -> 4096 took the PCSS-ultra worst view from 12.9 to 8.3 ms
	# in the desktop proxy (sampling, not the map, was the cost); round 5 went
	# back to 8192 once the filter was cheap. If the headset trace is over
	# budget, 6144 is the first fallback, then soft_shadow_quality 2.
	"directional_shadow_size": 4096,
	"mesh_lod_threshold": 2.0,
}
## XR values that are ceilings, not replacements: the headset takes the cheaper of the preset
## and the XR value, so a Low or Very Low headset run does not pay the 8192 map, four splits
## and MSAA the High-tier headset tuning above asks for. Effect bans (fog, SSAO, FXAA, FSR)
## and look choices (blur, ambient, sun disc) stay unconditional.
const XR_CEILINGS := ["directional_shadow_size", "soft_shadow_quality", "shadow_max_distance",
	"shadow_splits", "msaa", "cloud_steps", "crowd_near_distance", "zone_resident_budget", "ocean_cascades"]
var xr_mode := false
## Settings → Glow in VR (dev 2026-09-25: "try only glow"): the headset keeps the preset's own
## glow instead of XR_OVERRIDES turning it off. SDFGI, volumetric fog and SSAO stay off in VR:
## they cost GPU time per eye and lagged head motion as "a stagnant glaze" (2026-09-06).
var vr_desktop_effects := false
const DESKTOP_EFFECTS := ["glow"]
# Process-local A/B knobs from `-- --quality key=value`, only honoured under the
# desktop perf proxy (--perf-stereo) and runtime profiler (--profile-runtime). Never a shipping path: measure with these,
# then move a proven win into a preset or XR_OVERRIDES.
var diagnostic_overrides: Dictionary = {}
## The player's own choices from the settings page (Settings autoload: shadows, draw
## distance, render scale). They sit above the preset and the XR overrides, below the
## diagnostic knobs.
var user_overrides: Dictionary = {}


func set_user_overrides(overrides: Dictionary) -> void:
	if overrides == user_overrides and _applied: return
	user_overrides = overrides.duplicate()
	_apply_viewport_settings()
	preset_changed.emit(preset)


func _parse_diagnostic_overrides() -> void:
	var args := preload("res://world/dev_tools.gd").user_args()
	if not ("--perf-stereo" in args or "--profile-runtime" in args):
		return
	for i in args.size() - 1:
		if args[i] != "--quality":
			continue
		var kv: PackedStringArray = args[i + 1].split("=", true, 1)
		if kv.size() != 2:
			continue
		var raw := kv[1]
		var value: Variant = str_to_var(raw)
		if value == null:
			value = raw
		diagnostic_overrides[kv[0]] = value
	if not diagnostic_overrides.is_empty():
		print("[quality] diagnostic overrides ", diagnostic_overrides)


func set_xr_mode(enabled: bool) -> void:
	xr_mode = enabled
	_apply_viewport_settings()
	preset_changed.emit(preset)

func set_preview_shadows(enabled: bool) -> void:
	preview_shadows_enabled = enabled
	preset_changed.emit(preset)

func set_preview_mode(enabled: bool) -> void:
	preview_mode = enabled
	_apply_viewport_settings()
	preset_changed.emit(preset)

var _applied := false


func _init() -> void:
	_adopt_patched_settings()


## The Settings autoload mounts the patch packs (tools/build/packs.gd) in its _init, after the
## engine already read its script from the base pack, so a patched settings.gd never ran (its
## window size, the magic switch). Quality is created next, before either enters the tree: it
## compiles the pack's settings.gd (packed as text) and hands it to the Settings node, whose
## new _init then skips mounting again; only when the pack's REVISION is higher than the running
## script's (0 without one), so a build that already carries the change keeps its own.
const SETTINGS_SOURCE := "res://autoload/settings.gd"
static func _adopt_patched_settings() -> void:
	if not OS.has_feature("template"): return
	var loop := Engine.get_main_loop() as SceneTree
	var node: Node = Settings if loop != null else null
	if node == null or node.get_script() == null: return
	var have := int((node.get_script() as Script).get_script_constant_map().get("REVISION", 0))
	var text := FileAccess.get_file_as_string(SETTINGS_SOURCE)
	var found := RegEx.create_from_string("const\\s+REVISION\\s*:?=\\s*(\\d+)").search(text)
	if found == null or int(found.get_string(1)) <= have: return
	var patched := GDScript.new()
	patched.source_code = text
	if patched.reload() != OK or int(patched.get_script_constant_map().get("REVISION", 0)) <= have:
		push_warning("[quality] the patch pack's settings.gd did not compile; keeping the built-in one")
		return
	Engine.set_meta(&"home_equestria_packs_mounted", true)
	node.set_script(patched)
	print("[quality] Settings runs the patch pack's script (revision %d)" % int(patched.get_script_constant_map().get("REVISION", 0)))


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_parse_diagnostic_overrides()
	_apply_viewport_settings()
	get_viewport().size_changed.connect(_on_window_resized)
	_plan_engine_threads()
	# Player builds log errors and warnings only until debug mode is on (world/debug/log_level.gd).
	LOG_LEVEL.apply()
	var settings := get_node_or_null("/root/Settings")
	if settings != null: settings.changed.connect(func(key: String) -> void:
		if key == "debug/unlocked": LOG_LEVEL.apply())


# Engine threads (dev 2026-10-20 multithreading), checked against the Godot 4.5-stable source:
#   threading/worker_pool/max_threads  read once in Main::setup to size the WorkerThreadPool
#     (-1 = OS.get_processor_count(), logical CPUs). Jolt's job system, navigation avoidance,
#     threaded resource loads, the render/physics pump tasks and our own group tasks all share
#     this one pool. Boot-only, so it goes through user://launch.cfg and applies next launch.
#   threading/worker_pool/low_priority_thread_ratio  how many pool threads low-priority tasks
#     may hold (clamped 1..threads-1). Engine default 0.3 kept: ResourceLoader threaded loads
#     and background searches are low priority; per-frame work must pass high_priority = true.
#   rendering/driver/threads/thread_model  stays Safe (rendering on the main thread). 4.5 marks
#     Separate experimental: "known bugs which can lead to crashing, especially when using
#     particles or resizing the window. Not recommended for use in production" (the game has
#     weather/firefly particles and an OpenXR swapchain). A/B it with Godot's own
#     `--render-thread separate` command-line flag, which wins over project settings.
#   physics/3d/run_on_separate_thread  stays off. With it, Jolt only hands out
#     direct_space_state and body_test_motion (move_and_slide) between sync and end_sync, i.e.
#     inside _physics_process; the 2026-10-20 audit found about 85 ray/shape/move_and_slide call
#     sites reached from _process, input, _ready or signals (eye guard, interactor, hands,
#     foliage cells, zone manager, minigames) and about 170 more behind public functions, while
#     Jolt was about 1 % of the main thread in the town profile. Server getters called from
#     _process would also wait for the running step through the command queue.
# Nothing here can change at runtime in 4.5: the pool, the render thread and the physics server
# are all created before any script runs.
const LAUNCH_CONFIG := preload("res://world/launch_config.gd")


## Boot-only thread settings for a machine with `cpus` logical CPUs. The pool leaves one CPU to
## the main thread, which runs scripts and render submission and is the frame's critical path
## (workers + main on every logical CPU let the OS preempt it); a standalone headset also leaves
## one to the OpenXR runtime/compositor threads.
static func thread_plan(cpus: int, android: bool) -> Dictionary:
	var reserve := 2 if android else 1
	return {"threading/worker_pool/max_threads": maxi(2, cpus - reserve)}


## Writes this machine's thread plan to launch.cfg for the next launch (not from headless
## tests or the editor, which must never touch the player's file).
func _plan_engine_threads() -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("editor") or OS.has_feature("web"): return
	var err: Error = LAUNCH_CONFIG.write_overrides(thread_plan(OS.get_processor_count(), OS.has_feature("android")))
	if err != OK: push_warning("[quality] could not write thread settings to launch.cfg: %s" % error_string(err))
	print("[quality] %d logical CPUs, %d worker threads (%d low priority), render thread %s, physics thread %s" % [
		OS.get_processor_count(), worker_threads(), low_priority_threads(),
		"separate" if render_thread_separate() else "main",
		"separate" if bool(ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false)) else "main"])


## WorkerThreadPool threads this process booted with (4.5 does not expose the pool's size to
## scripts): the max_threads setting, or the logical CPU count when it is -1. Use it to size
## work splits; add_group_task(..., -1) already uses the whole pool.
static func worker_threads() -> int:
	var setting := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	return setting if setting >= 0 else OS.get_processor_count()


## Pool threads low-priority tasks may occupy at once (the engine's own clamp).
static func low_priority_threads() -> int:
	var threads := worker_threads()
	var ratio := float(ProjectSettings.get_setting("threading/worker_pool/low_priority_thread_ratio", 0.3))
	return clampi(int(threads * ratio), 1, maxi(1, threads - 1))


## True when rendering runs on its own thread (Godot's --render-thread flag, else the setting).
## RenderingServer calls are then queued, and its getters stall the main thread until the render
## thread catches up.
static func render_thread_separate() -> bool:
	var args := OS.get_cmdline_args()
	var at := args.find("--render-thread")
	if at >= 0 and at + 1 < args.size(): return args[at + 1] == "separate"
	return int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1)) == 2


## The XR value for `key` over the preset's `base`: the cheaper of the two for XR_CEILINGS
## keys (kept in the preset's own type), the XR value otherwise. Mesh LOD uses
## the larger threshold because a larger projected error selects cheaper meshes.
func _xr_value(key: String, base: Variant) -> Variant:
	var xr: Variant = XR_OVERRIDES[key]
	# Larger pixel thresholds select cheaper meshes; Low must keep its coarser value.
	if key == "mesh_lod_threshold" and base != null: return maxf(float(base), float(xr))
	if key in XR_CEILINGS and base != null and float(base) < float(xr): return base
	return xr


func get_config() -> Dictionary:
	var config: Dictionary = CONFIG[preset].duplicate()
	var tier := season_tier()
	for key: String in SEASON_CONFIG: config[key] = SEASON_CONFIG[key][tier]
	if preview_mode:config.merge(PREVIEW_OVERRIDES, true)
	if preview_mode:config["shadows_enabled"] = preview_shadows_enabled
	config.merge(user_overrides, true)
	if xr_mode:
		for key: String in XR_OVERRIDES:
			if vr_desktop_effects and key in DESKTOP_EFFECTS: continue
			config[key] = _xr_value(key, config.get(key, null))
	config.merge(diagnostic_overrides, true)
	return config


func get_value(key: String, fallback: Variant = null) -> Variant:
	if diagnostic_overrides.has(key):return diagnostic_overrides[key]
	if xr_mode and XR_OVERRIDES.has(key) and not (vr_desktop_effects and key in DESKTOP_EFFECTS):
		return _xr_value(key, user_overrides.get(key, CONFIG[preset].get(key, null)))
	if user_overrides.has(key):return user_overrides[key]
	if preview_mode and key == "shadows_enabled":return preview_shadows_enabled
	if preview_mode and PREVIEW_OVERRIDES.has(key):return PREVIEW_OVERRIDES[key]
	if SEASON_CONFIG.has(key):return SEASON_CONFIG[key][season_tier()]
	return CONFIG[preset].get(key, fallback)


## The column season keys come from: the preset, or Very Low on a standalone headset.
func season_tier() -> int:
	return Preset.VERY_LOW if season_force_very_low else preset


## A season key with the "Seasonal effects" setting applied (Settings video/seasonal_effects;
## `level` 0 off, 1 reduced, 2 full, -1 = read the setting). Plain get_value() returns the
## tier's own value for consumers that apply season_state.effects_level() themselves.
func season_value(key: String, fallback: Variant = null, level := -1) -> Variant:
	if level < 0: level = season_effects_level()
	return season_effect(key, get_value(key, fallback), level)


## The setting as a level: 0 off, 1 reduced, 2 full (also when Settings is absent).
func season_effects_level() -> int:
	var settings := get_node_or_null("/root/Settings")
	if settings == null or not settings.has_method("get_value"): return 2
	return int(SEASON_EFFECT_LEVELS.get(str(settings.call("get_value", "video/seasonal_effects")), 2))


## `value` of season key `key` at effects `level`: Off zeroes particles, trails and piles,
## Reduced halves particles and piles (piles round up, as world/seasons/leaf_piles.gd does).
static func season_effect(key: String, value: Variant, level: int) -> Variant:
	if level >= 2 or key not in SEASON_EFFECT_KEYS: return value
	if level <= 0: return 0.0 if value is float else 0
	if key == "season_particle_scale" and (value is float or value is int): return float(value) * 0.5
	if key == "leaf_piles" and (value is float or value is int): return int(ceil(float(value) * 0.5))
	return value


func preset_name() -> String:
	return PRESET_NAMES[preset]


func cycle() -> void:
	preset = (preset + 1) % PRESET_NAMES.size()


## First-launch tier from the machine (Settings calls this when user://settings.cfg does not
## exist yet; the pick is then stored like any chosen tier). Godot exposes no VRAM capacity,
## only usage (Performance.RENDER_VIDEO_MEM_USED), so capacity is inferred from the adapter
## name and type, with the usage figure as a floor. The rule:
##   software renderer (llvmpipe, lavapipe, SwiftShader, DEVICE_TYPE_CPU)  -> Very Low
##   integrated or unknown GPU: its VRAM is a share of system RAM (a quarter here);
##     under 2 GB (system RAM under 8 GB)                                  -> Very Low
##     otherwise                                                           -> Low
##   discrete GPU of the 1 GB class (GT xxx, GTX 4xx-6xx, Radeon HD, R5, R7 2xx) -> Very Low
##   discrete GPU of the 2 GB class (GTX 1050/1030/950/960/7xx, RX 460/550/540,
##     MX laptop chips, R7 3xx)                                            -> Low
##   older mid-range discrete (GTX 9xx/10xx/16xx, RX 4xx/5xx/Vega)        -> Medium
##   everything else (RTX, RX 6000+, Arc)                                 -> High
## `adapter_type` is a RenderingDevice.DeviceType; `physical_ram` and `vram_used` are bytes.
static func pick_default_quality(adapter: String, adapter_type: int, physical_ram: int, vram_used: int) -> String:
	# A standalone headset (Quest 3: 8 GB shared, the Low tier OOM-killed the app 2026-09-29)
	# always starts on the potato tier; the player can raise it in Settings.
	if OS.has_feature("android"): return "Very Low"
	const GIB := 1073741824
	var name := adapter.to_lower()
	var software := adapter_type == RenderingDevice.DEVICE_TYPE_CPU
	for token in ["llvmpipe", "lavapipe", "swiftshader", "softpipe", "software"]:
		if token in name: software = true
	if software: return PRESET_NAMES[Preset.VERY_LOW]
	if physical_ram > 0 and physical_ram < 4 * GIB: return PRESET_NAMES[Preset.VERY_LOW]
	var integrated := adapter_type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU
	for token in ["intel(r) hd", "intel(r) uhd", "iris", "radeon graphics", "radeon(tm) graphics", "vega 3", "vega 6", "vega 7", "vega 8", "vega 11", "apple m", "mali", "adreno"]:
		if token in name: integrated = true
	var discrete := adapter_type == RenderingDevice.DEVICE_TYPE_DISCRETE_GPU or _matches(name, "(rtx|gtx|geforce|radeon rx|rx [0-9]|arc a|arc b|vega 56|vega 64|radeon vii)")
	if integrated or not discrete:
		var shared := physical_ram / 4 if physical_ram > 0 else 0
		var vram := maxi(shared, vram_used)
		if physical_ram > 0 and vram < 2 * GIB: return PRESET_NAMES[Preset.VERY_LOW]
		return PRESET_NAMES[Preset.LOW]
	# Discrete: the 1 GB class, the 2 GB class, then generation.
	if _matches(name, "(gt [0-9]{3}|gtx 4[0-9]{2}|gtx 5[0-9]{2}|gtx 6[0-9]{2}|hd [0-9]{4}|r5 [0-9]|r7 2[0-9]{2})"):
		return PRESET_NAMES[Preset.VERY_LOW]
	if _matches(name, "(gtx 1050|gtx 1030|gt 1030|gtx 950|gtx 960|gtx 750|gtx 745|gtx 7[0-9]{2}|rx 460|rx 550|rx 540|mx[0-9]{3}|r7 3[0-9]{2})"):
		return PRESET_NAMES[Preset.LOW]
	if _matches(name, "(gtx 9[0-9]{2}|gtx 10[0-9]{2}|gtx 16[0-9]{2}|rx 4[0-9]{2}|rx 5[0-9]{2}|vega 56|vega 64|radeon vii)"):
		return PRESET_NAMES[Preset.MEDIUM]
	return PRESET_NAMES[Preset.HIGH]


static func _matches(text: String, pattern: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK: return false
	return regex.search(text) != null


## The pick for this machine: High, Medium, Low or Very Low, never Ultra (dev 2026-10-31: Ultra is
## only ever the player's own choice, on any GPU).
static func pick_for_this_machine() -> String:
	var memory: Dictionary = OS.get_memory_info()
	var pick := pick_default_quality(RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_type(),
		int(memory.get("physical", 0)), int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)))
	return PRESET_NAMES[Preset.HIGH] if pick == PRESET_NAMES[Preset.ULTRA] else pick


## Viewport-level knobs. Everything Environment-shaped is applied by
## SkyController instead, so time-of-day and quality can never fight.
## Global physics stays 60 Hz for every tier; pony-only cadence has its own owner.
func _apply_physics_rate() -> void:
	var hz := int(get_value("physics_hz", 60))
	if hz > 0 and Engine.physics_ticks_per_second != hz: Engine.physics_ticks_per_second = hz


## Desktop windows bigger than 1080p render about 1080p's pixel count and upscale (dev 2026-10-23,
## fullscreen at 1440p cost a quarter of the GPU's FPS), unless the player set Render scale
## themselves. In XR the interface's render target is what gets scaled (Godot multiplies the
## requested eye size by scaling_3d_scale), so render_scale stays a plain per-tier VR knob.
const AUTO_SCALE_PIXELS := 1920.0 * 1080.0

## The most "Auto" draws a window of `size` at: about 1080p's pixel count (no cap below it).
static func auto_cap(size: Vector2) -> float:
	if size.x * size.y <= AUTO_SCALE_PIXELS: return INF
	return snappedf(maxf(sqrt(AUTO_SCALE_PIXELS / (size.x * size.y)), 0.5), 0.05)


## The 3D scale Render scale "Auto" gives a desktop window of `size` on the current tier
## (Settings → Graphics shows it in pixels).
func auto_render_scale(size: Vector2) -> float:
	return minf(float(CONFIG[preset].get("render_scale", 1.0)), auto_cap(size))


func _apply_render_scale(vp: Viewport, cfg: Dictionary, android: bool = OS.has_feature("android")) -> void:
	var scale := float(cfg["render_scale"])
	var mode: int = cfg.get("scaling_mode", Viewport.SCALING_3D_MODE_BILINEAR)
	var aa: int = cfg["screen_space_aa"]
	if not xr_mode and not android and not user_overrides.has("render_scale") and not diagnostic_overrides.has("render_scale"):
		scale = minf(scale, auto_cap(Vector2(vp.get_visible_rect().size)))
	# Headsets render their eye buffers 1:1 (see _apply_viewport_settings); a window resize must
	# not bring the preset's scale back.
	if xr_mode or android:
		scale = 1.0; mode = Viewport.SCALING_3D_MODE_BILINEAR
	# FSR2 at 100% or above is a costly native anti-aliasing pass, not an upscale.
	if mode == Viewport.SCALING_3D_MODE_FSR2 and scale >= 0.999: mode = Viewport.SCALING_3D_MODE_BILINEAR
	# FSR2 is temporal and smooths edges itself; a post filter on top only blurs.
	if mode == Viewport.SCALING_3D_MODE_FSR2: aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.scaling_3d_mode = mode
	vp.scaling_3d_scale = scale
	vp.screen_space_aa = aa
	# Settings → Anti-aliasing "TAA" (desktop only; FSR2 already resolves temporally).
	vp.use_taa = bool(cfg.get("use_taa", false)) and not xr_mode and not android and mode != Viewport.SCALING_3D_MODE_FSR2


func _on_window_resized() -> void:
	var vp := get_viewport()
	if vp != null and _applied: _apply_render_scale(vp, get_config())


func _apply_viewport_settings(android: bool = OS.has_feature("android")) -> void:
	_apply_physics_rate()
	_applied = true
	var vp := get_viewport()
	if vp == null:
		return
	var cfg := get_config()
	vp.msaa_3d = cfg["msaa"] if xr_mode else cfg.get("desktop_msaa", cfg["msaa"])
	_apply_render_scale(vp, cfg, android)
	vp.texture_mipmap_bias = cfg.get("mipmap_bias", 0.0)
	# Quest (Mobile renderer, OpenXR swapchain): a scaled 3D buffer breaks every draw list
	# ("custom region must be contained within the framebuffer rectangle", frozen view);
	# the eye buffers stay 1:1 there (_apply_render_scale). PC headsets too (player report
	# 2026-10-25, PSVR2 through SteamVR on Windows, Low preset's 0.7): the scaled picture filled
	# only the top-left of each eye and of the desktop mirror instead of being stretched over it.
	# The runtime's own resolution setting (SteamVR per-game resolution) is the VR resolution knob.
	if android:
		# Headset (dev 2026-09-29: "so pixelized, the moving pixels hurt"): MSAA 2x is near-free on
		# a tile GPU and the only anti-aliasing that holds still in VR; no FXAA pass, no mip bias.
		vp.msaa_3d = Viewport.MSAA_2X
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.texture_mipmap_bias = 0.0
	vp.positional_shadow_atlas_size = cfg["shadow_atlas"]
	vp.mesh_lod_threshold = cfg["mesh_lod_threshold"]
	RenderingServer.directional_soft_shadow_filter_set_quality(cfg["soft_shadow_quality"])
	RenderingServer.positional_soft_shadow_filter_set_quality(cfg["soft_shadow_quality"])
	# The sun's shadow map is entirely separate from the positional atlas above.
	# Only setting the atlas left the directional shadow at its default size
	# stretched over a 100 m+ range, which is what made shadow edges pixelated.
	# 16-bit depth, as SkyController's twilight budget sets it right after every preset change
	# (perf 0.1.0): asking for 32-bit here freed and reallocated the whole map twice per change.
	RenderingServer.directional_shadow_atlas_set_size(
		cfg["directional_shadow_size"], true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_cycle_quality") and preload("res://world/dev_tools.gd").enabled():
		cycle()
		print("[quality] preset -> ", preset_name())
