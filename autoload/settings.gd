extends Node
## Player settings: one ConfigFile at user://settings.cfg, validated and applied live.
## SPECS is the single definition of every setting (type, range, labels); TABS is the
## single definition of the settings page rows, shared by the home screen, the F7 panel,
## the desktop Escape pause menu and the VR panel (world/ui/settings_page.gd builds it).
## Key rebinds live in user://input.cfg. docs/ALPHA_SETTINGS.md lists every key.

signal changed(key: String)

const PATH := "user://settings.cfg"
const INPUT_PATH := "user://input.cfg"
const PACKS := "res://tools/build/packs.gd"
## "Start in VR" lives in user://launch.cfg (world/launch_config.gd), which project.godot
## reads before any script runs; it is not stored in settings.cfg.
const LAUNCH := "res://world/launch_config.gd"
const OUTLINES := ["Off", "Fine", "Ink", "Bold"]
const OUTLINE_LABELS := {"Off": "Off", "Fine": "Thin", "Ink": "Ink", "Bold": "Thick"}
## Pony size presets from dev's chart (2026-09-15): canon show proportion, mounting
## height, same height as Anon, full horse. "follows_anon": the scale is for a 6 ft Anon and
## grows or shrinks with his chosen height (player/height_cm, pony_scale()).
const PONY_SIZES := [
	{"name": "canon", "label": "Canon", "scale": 1.0},
	{"name": "mounting", "label": "JRHNBR", "scale": 1.35},
	{"name": "same height", "label": "Same height as Anon", "scale": 1.7, "follows_anon": true},
	{"name": "hoers", "label": "Hoers", "scale": 2.3},
]
const BUSES := ["Voice", "SFX", "Ambience", "Music"]
## The height (6 ft 0 in) the current Anon stands for: his body, eye, hands, held offsets and
## reach were all tuned at it, so anon_height_scale() divides by it.
const ANON_REFERENCE_CM := 182.88
const DEFAULTS := {
	"setup/completed": false,
	# dev 2026-10-31: the machine check is opt-in. A new desktop player is asked once before the
	# title (world/ui/quality_prompt.gd); saying no keeps High. True once asked (or on old installs).
	"setup/quality_asked": false,
	"setup/season": 0,
	"title/view": "random",
	# Anon's real-world height (dev 2026-11-03: "scale anon using real world height with his current
	# being 6 foot tall"). 6 ft 0 in is the Anon every system was tuned for: anon_height_scale() 1.0.
	"player/height_cm": ANON_REFERENCE_CM,
	"ponies/size": "canon",
	"ponies/max_nearby": 0,
	"ponies/boop_makes_mares_horny": false,
	"video/quality": "High",
	# The tier a "Custom" quality started from: its keys stay under the edited rows (hidden).
	"video/quality_base": "High",
	"video/shadows": "preset",
	"video/draw_distance": 0,
	"video/grass_density": 100,
	"video/foliage_density": 100,
	# Clouds: "preset" follows the quality tier (flat painted clouds on Low and Very Low),
	# "flat" and "volumetric" force one look on every tier.
	"video/clouds": "preset",
	"video/weather_particles": true,
	"video/vr_desktop_effects": false,
	"video/color_grade": true,
	"video/ocean": "preset",
	# 0 = Auto: the preset's own scale, capped to about 1080p's pixel count on bigger windows.
	"video/render_scale": 0,
	"video/antialiasing": "preset",
	"video/upscaler": "preset",
	"video/vsync": false,
	"video/fps_cap": 0,
	# dev 2026-10-31: one more frame queued ahead of the GPU (frame_queue_size 3) is the 0.1.0 pass's
	# biggest desktop FPS win (crowd 336 -> 405 FPS) but adds a frame of input lag (16 ms at 60 FPS).
	# "preset" turns it on for Medium and below, off for High and Ultra (dev's call); the player can
	# force it either way. Boot-only: written to user://launch.cfg.
	"video/frames_ahead": "preset",
	"video/window": "windowed",
	# Windowed mode's size (dev 2026-10-27); the project's own window is 1600 x 900.
	"video/window_size": "1600x900",
	"video/pony_impostors": "preset",
	"controls/mouse_sensitivity": 100,
	"controls/invert_y": false,
	"controls/fov": 75,
	"vr/start_mode": "ask",
	"vr/seated": false,
	"vr/turn_mode": "smooth",
	"vr/snap_angle": 30,
	"vr/turn_speed": 140,
	"vr/move_hand": "left",
	"inventory/hud_placement": "gesture",
	"audio/master": 100,
	"audio/voice": 100,
	"audio/sfx": 100,
	"audio/ambience": 100,
	"audio/wind": 100,
	"audio/music": 80,
	"voice/tts": true,
	# Share of a word's syllables Ponese says (dev 2026-11-03): fewer sounds for the same words make
	# lines shorter and less tiring. 100 = every syllable (PonyPoneseVoice "syllables" option).
	"voice/ponese_syllables": 100,
	"world/day_length_minutes": 60.0,
	"world/season_days": 20,
	"world/weather_frequency": 100,
	# New games: "play" the forest opening, or "skip" it and wake in Golden Oak Library.
	"world/opening": "play",
	"access/subtitles": true,
	"access/subtitle_scale": 100,
	"access/speech_text": "auto",
	"access/caption_card": false,
	"access/caption_opacity": 65,
	"access/ui_scale": 100,
	"access/reduced_motion": false,
	"ai/freeze_while_talking": true,
	"ai/freeze_while_thinking": false,
	"ai/freeze_effect": false,
	"reading/paper": "cream",
	"reading/font": "literata",
	"reading/size": 26,
	# A quiet check for a newer signed release when a world opens, every 6 hours at most
	# (world/update/updater.gd, dev 2026-10-28).
	"updates/check": true,
	# Settings > Updates pressed five times shows the Debug tab and opens the developer tools in
	# a player build too (world/dev_tools.gd, dev 2026-10-30).
	"debug/unlocked": false,
}
## Validation and display. choice: [value, label] pairs; int/float: min, max, step, fmt;
## bool: [off label, on label]. "note" is appended to the row label ("restart" etc.).
const SPECS := {
	"inventory/hud_placement": {"type": "choice", "options": [["gesture", "Hand gestures"]]},
	"setup/completed": {"type": "bool"},
	"setup/quality_asked": {"type": "bool"},
	"setup/season": {"type": "int", "min": 0, "max": 3, "step": 1},
	"title/view": {"type": "choice", "options": [["random", "Random"], ["above_ponyville", "Above Ponyville"], ["golden_oak", "Golden Oak Library"], ["fluttershy_cottage", "Fluttershy's cottage"], ["zecora_hut", "Zecora's hut"], ["town_square", "Town square"], ["sweet_apple_acres", "Sweet Apple Acres"]]},
	# Shown and typed in feet and inches or centimetres ("unit": "height", height_text/parse_height_cm);
	# the arrows move one inch. Stored in centimetres.
	"player/height_cm": {"type": "float", "unit": "height", "min": 120.0, "max": 230.0, "step": 0.1, "arrow_step": 2.54, "typed": true,
		"width_sample": "7 ft 11 in (229.9 cm)"},
	"ponies/size": {"type": "choice", "options": [["canon", "Canon"], ["mounting", "JRHNBR"], ["same height", "Same height as Anon"], ["hoers", "Hoers"]]},
	"video/pony_impostors": {"type": "choice", "options": [["preset", "Preset"], [80, "80 m"], [100, "100 m"], [120, "120 m"], [150, "150 m"], [250, "250 m"], [0, "Unlimited"]]},
	"ponies/max_nearby": {"type": "choice", "options": [[0, "Unlimited"], [4, "4"], [8, "8"], [12, "12"], [16, "16"], [24, "24"], [32, "32"], [48, "48"], [64, "64"]]},
	"ponies/boop_makes_mares_horny": {"type": "bool", "labels": ["Off", "On"]},
	"video/quality": {"type": "choice", "options": [["Very Low", "Very Low"], ["Low", "Low"], ["Medium", "Medium"], ["High", "High"], ["Ultra", "Ultra"], ["Custom", "Custom"]]},
	"video/quality_base": {"type": "choice", "options": [["Very Low", "Very Low"], ["Low", "Low"], ["Medium", "Medium"], ["High", "High"], ["Ultra", "Ultra"]]},
	"video/shadows": {"type": "choice", "options": [["preset", "Follow preset"], ["off", "Off"], ["very_low", "Very Low"], ["low", "Low"], ["medium", "Medium"], ["high", "High"]]},
	"video/draw_distance": {"type": "choice", "options": [[0, "Follow preset"], [600, "600 m"], [900, "900 m"], [1500, "1.5 km"], [3000, "3 km"], [6000, "6 km"], [9000, "9 km"], [12000, "12 km"], [15000, "15 km"]]},
	"video/grass_density": {"type": "int", "min": 0, "max": 100, "step": 25, "fmt": "%d%%", "zero": "Off"},
	"video/foliage_density": {"type": "int", "min": 25, "max": 100, "step": 25, "fmt": "%d%%", "note": "new areas"},
	"video/clouds": {"type": "choice", "options": [["preset", "Follow preset"], ["flat", "Flat sky clouds"], ["volumetric", "Volumetric"]]},
	"video/weather_particles": {"type": "bool", "labels": ["Off", "On"]},
	# dev 2026-09-25: try the desktop glow in the headset. Restart the game after changing it.
	"video/vr_desktop_effects": {"type": "bool", "labels": ["Off (restart)", "On (restart)"]},
	"video/color_grade": {"type": "bool", "labels": ["Off", "On"]},
	"video/ocean": {"type": "choice", "options": [["preset", "Follow preset"], ["fft", "Stylized waves"], ["classic", "Classic flat"]]},
	"video/render_scale": {"type": "choice", "options": [[0, "Auto"], [50, "50%"], [55, "55%"], [60, "60%"], [65, "65%"], [70, "70%"], [75, "75%"], [80, "80%"], [85, "85%"], [90, "90%"], [95, "95%"], [100, "100%"], [105, "105%"], [110, "110%"], [115, "115%"], [120, "120%"], [125, "125%"], [130, "130%"], [135, "135%"], [140, "140%"], [145, "145%"], [150, "150%"]]},
	"video/antialiasing": {"type": "choice", "options": [["preset", "Follow preset"], ["off", "Off"], ["fxaa", "FXAA"], ["smaa", "SMAA"], ["taa", "TAA"], ["msaa2", "MSAA 2x"], ["msaa4", "MSAA 4x"]], "note": "desktop"},
	"video/upscaler": {"type": "choice", "options": [["preset", "Follow preset"], ["bilinear", "Bilinear"], ["fsr1", "FSR 1"], ["fsr2", "FSR 2"]], "note": "below 100%"},
	"video/vsync": {"type": "bool", "labels": ["Off", "On"], "note": "desktop"},
	"video/frames_ahead": {"type": "choice", "options": [["preset", "Follow preset (restart)"], ["off", "Off (restart)"], ["on", "On (restart)"]], "note": "more FPS, +1 frame input lag"},
	"video/fps_cap": {"type": "choice", "options": [[0, "Unlimited"], [30, "30"], [60, "60"], [72, "72"], [90, "90"], [120, "120"], [144, "144"], [165, "165"], [240, "240"]], "note": "desktop"},
	"video/window": {"type": "choice", "options": [["windowed", "Windowed"], ["fullscreen", "Fullscreen"], ["exclusive", "Exclusive fullscreen (can be slower)"]]},
	# The settings page lists only the sizes that fit the screen (window_sizes()).
	"video/window_size": {"type": "choice", "options": [["1280x720", "1280 × 720"], ["1280x800", "1280 × 800"], ["1600x900", "1600 × 900"],
		["1680x1050", "1680 × 1050"], ["1920x1080", "1920 × 1080"], ["1920x1200", "1920 × 1200"], ["2560x1440", "2560 × 1440"],
		["2560x1600", "2560 × 1600"], ["3840x2160", "3840 × 2160"], ["maximized", "Maximized"]], "note": "windowed mode"},
	# Player board #3 (2026-10-25): 25 % steps were too coarse for high-DPI mice. Any whole
	# percent is valid and can be typed; the arrows move by `arrow_step`.
	"controls/mouse_sensitivity": {"type": "int", "min": 1, "max": 400, "step": 1, "arrow_step": 5, "typed": true, "fmt": "%d%%"},
	"controls/invert_y": {"type": "bool", "labels": ["Off", "On"]},
	"controls/fov": {"type": "int", "min": 60, "max": 110, "step": 5, "fmt": "%d°"},
	"vr/start_mode": {"type": "choice", "options": [["ask", "Ask every launch"], ["auto", "Auto (headset if found)"], ["on", "On"], ["off", "Off"]], "note": "applies on next launch"},
	# Seated VR (dev 2026-10-01): headset view with keyboard and mouse; --seated / --room-scale win.
	"vr/seated": {"type": "bool", "labels": ["Room-scale with controllers", "Seated: keyboard and mouse"], "note": "applies on next launch"},
	"vr/turn_mode": {"type": "choice", "options": [["smooth", "Smooth"], ["snap", "Snap"]]},
	"vr/snap_angle": {"type": "int", "min": 15, "max": 90, "step": 15, "fmt": "%d°"},
	"vr/turn_speed": {"type": "int", "min": 60, "max": 360, "step": 20, "fmt": "%d°/s"},
	"vr/move_hand": {"type": "choice", "options": [["left", "Left stick moves"], ["right", "Right stick moves"]]},
	"audio/master": {"type": "int", "min": 0, "max": 100, "step": 10, "fmt": "%d%%"},
	"audio/voice": {"type": "int", "min": 0, "max": 100, "step": 10, "fmt": "%d%%"},
	"audio/sfx": {"type": "int", "min": 0, "max": 100, "step": 10, "fmt": "%d%%"},
	"audio/ambience": {"type": "int", "min": 0, "max": 100, "step": 10, "fmt": "%d%%"},
	"audio/wind": {"type": "int", "min": 0, "max": 100, "step": 10, "fmt": "%d%%"},
	"audio/music": {"type": "int", "min": 0, "max": 100, "step": 10, "fmt": "%d%%"},
	"voice/tts": {"type": "bool", "labels": ["Ponese only", "Character voices (TTS)"]},
	"voice/ponese_syllables": {"type": "int", "min": 25, "max": 100, "step": 5, "fmt": "%d%%", "note": "shorter pony speech"},
	"world/day_length_minutes": {"type": "float", "min": 15.0, "max": 720.0, "presets": [15.0, 30.0, 60.0, 90.0, 180.0, 360.0, 720.0], "fmt": "%.0f real minutes"},
	"world/season_days": {"type": "int", "min": 5, "max": 60, "step": 5, "fmt": "%d days"},
	"world/weather_frequency": {"type": "int", "min": 0, "max": 300, "step": 25, "fmt": "%d%%", "zero": "Never wet"},
	"world/opening": {"type": "choice", "options": [["play", "Play the forest opening"], ["skip", "Skip, start in Golden Oak"]], "note": "new games"},
	"access/subtitles": {"type": "bool", "labels": ["Off", "On"]},
	"access/subtitle_scale": {"type": "int", "min": 75, "max": 250, "step": 25, "fmt": "%d%%"},
	# Where pony speech shows (world/ai/overhead_dialogue.gd). A VR tester could not read the
	# overhead words up close (2026-10-20): auto keeps them overhead on desktop, bottom in VR.
	"access/speech_text": {"type": "choice", "options": [["auto", "Auto (bottom in VR)"], ["overhead", "Over the pony's head"], ["caption", "Bottom caption"]]},
	# A card behind the desktop bottom caption (world/ui/speech_caption.gd). Off by default: the
	# words' subtitle colours (world/ai/subtitle_colors.gd) read over the world without one.
	"access/caption_card": {"type": "bool", "labels": ["Off", "On"]},
	"access/caption_opacity": {"type": "int", "min": 10, "max": 100, "step": 5, "fmt": "%d%%"},
	"access/ui_scale": {"type": "int", "min": 75, "max": 200, "step": 25, "fmt": "%d%%"},
	"access/reduced_motion": {"type": "bool", "labels": ["Off", "On"]},
	# Time stops while Anon talks (world/ai/talk_freeze.gd, dev 2026-10-29).
	"ai/freeze_while_talking": {"type": "bool", "labels": ["Off", "On"]},
	"ai/freeze_while_thinking": {"type": "bool", "labels": ["Off", "On"], "note": "slow local models"},
	"ai/freeze_effect": {"type": "bool", "labels": ["Off", "On"]},
	# Printed pages of the physical books (world/books/book_typesetter.gd), dev 2026-09-26.
	"reading/paper": {"type": "choice", "options": [["white", "White"], ["cream", "Cream"], ["sepia", "Sepia"], ["grey", "Grey"], ["night", "Night"]]},
	"reading/font": {"type": "choice", "options": [["literata", "Literata (book serif)"], ["atkinson", "Atkinson Hyperlegible"], ["dyslexic", "OpenDyslexic"], ["celestia", "Celestia (Equestrian)"]]},
	"reading/size": {"type": "int", "min": 16, "max": 44, "step": 2, "fmt": "%d px"},
	"updates/check": {"type": "bool", "labels": ["Off", "On"]},
	"debug/unlocked": {"type": "bool", "labels": ["Off", "On"]},
}
## Actions offered for rebinding (project.godot [input]); debug actions are left out.
const BINDABLE := [["Move forward", "move_forward"], ["Move back", "move_back"], ["Move left", "move_left"],
	["Move right", "move_right"], ["Sprint", "move_sprint"], ["Jump / fly up", "move_jump"], ["Push to talk", "voice_talk"],
	["Walk (tap to toggle)", "move_walk"], ["Turn carried pony", "carry_turn"], ["Get up / stay awake", "stand_up"]]
## Actions the game creates itself with these default keys (not in project.godot's [input]): the
## playtester's walk toggle and carry turn, and getting up (2026-10-24, made rebindable).
const CODE_ACTIONS := {"move_walk": KEY_ALT, "carry_turn": KEY_B, "stand_up": KEY_Q}
## Page rows: [label, key]. "bind:<action>" is a key capture, "action:<id>" a button.
const TABS := [
	["AI Settings", []],
	["Prompts", []],
	["Saved notes", []],
	["Graphics", [["Quality preset", "video/quality"], ["Shadows", "video/shadows"], ["Draw distance", "video/draw_distance"],
		["Grass density", "video/grass_density"], ["Trees & plants", "video/foliage_density"], ["Max nearby ponies", "ponies/max_nearby"], ["Pony pictures from", "video/pony_impostors"],
["Clouds", "video/clouds"], ["Rain & snow particles", "video/weather_particles"], ["Ocean", "video/ocean"], ["Glow in VR", "video/vr_desktop_effects"], ["Colour grade", "video/color_grade"],
		["Render scale", "video/render_scale"], ["Upscaler", "video/upscaler"], ["Anti-aliasing", "video/antialiasing"], ["V-Sync", "video/vsync"], ["FPS cap", "video/fps_cap"], ["Extra frame ahead", "video/frames_ahead"], ["Window", "video/window"], ["Window size", "video/window_size"]]],
	["Controls", [["Mouse sensitivity", "controls/mouse_sensitivity"], ["Invert mouse Y", "controls/invert_y"], ["Field of view", "controls/fov"],
		["Move forward", "bind:move_forward"], ["Move back", "bind:move_back"], ["Move left", "bind:move_left"], ["Move right", "bind:move_right"],
		["Sprint", "bind:move_sprint"], ["Jump / fly up", "bind:move_jump"], ["Push to talk", "bind:voice_talk"],
		["Walk (tap to toggle)", "bind:move_walk"], ["Turn carried pony", "bind:carry_turn"], ["Get up / stay awake", "bind:stand_up"],
		["Reset keys to defaults", "action:reset_bindings"], ["Controls map", "action:controls_map"]]],
	["Controls map", []],
	["VR comfort", [["Start in VR", "vr/start_mode"], ["Play style", "vr/seated"], ["Turning", "vr/turn_mode"], ["Snap angle", "vr/snap_angle"], ["Smooth turn speed", "vr/turn_speed"], ["Movement stick", "vr/move_hand"],
		["Measure my height now", "action:measure_height"], ["Forget measured height", "action:forget_height"]]],
	["Audio", [["Master volume", "audio/master"], ["Voice volume", "audio/voice"], ["Effects volume", "audio/sfx"], ["Ambience volume", "audio/ambience"], ["Flight wind volume", "audio/wind"], ["Music volume", "audio/music"], ["Pony voices", "voice/tts"], ["Ponese syllables", "voice/ponese_syllables"]]],
	["World", [["Day length (time speed)", "world/day_length_minutes"], ["Season length", "world/season_days"], ["Title screen view", "title/view"], ["Rain & snow frequency", "world/weather_frequency"], ["Opening", "world/opening"], ["Anon's height (your real height)", "player/height_cm"], ["Pony size", "ponies/size"],
		["Boop Makes Mares Horny", "ponies/boop_makes_mares_horny"],
		["Ponies freeze while I talk or type", "ai/freeze_while_talking"], ["A pony freezes while she thinks", "ai/freeze_while_thinking"], ["Time-stop look (vignette, slow sound)", "ai/freeze_effect"], ["Summon the Great Evil", "action:spawn_barbiepone"]]],
	["Accessibility", [["Subtitles", "access/subtitles"], ["Subtitle size", "access/subtitle_scale"], ["Caption background", "access/caption_card"], ["Background opacity", "access/caption_opacity"], ["Pony speech text", "access/speech_text"], ["Menu text size", "access/ui_scale"], ["Reduced motion", "access/reduced_motion"]]],
	["Reading", [["Paper", "reading/paper"], ["Font", "reading/font"], ["Text size", "reading/size"]]],
	["Mods", []],
	["Updates", [["Check for new versions", "updates/check"]]],
	# Hidden until unlocked (world/ui/settings_page.gd _build_debug).
	["Debug", []],
]
## Shadow tiers the "Shadows" row selects on top of the quality preset (Quality.user_overrides).
const SHADOW_TIERS := {
	"off": {"shadows_enabled": false},
	"very_low": {"shadows_enabled": true, "soft_shadow_quality": 0, "directional_shadow_size": 1024, "shadow_atlas": 1024, "shadow_max_distance": 20.0},
	"low": {"shadows_enabled": true, "soft_shadow_quality": 1, "directional_shadow_size": 2048, "shadow_atlas": 2048, "shadow_max_distance": 60.0},
	"medium": {"shadows_enabled": true, "soft_shadow_quality": 2, "directional_shadow_size": 4096, "shadow_atlas": 4096, "shadow_max_distance": 100.0},
	"high": {"shadows_enabled": true, "soft_shadow_quality": 4, "directional_shadow_size": 8192, "shadow_atlas": 8192, "shadow_max_distance": 150.0},
}
## Rows a quality preset writes when chosen (dev 2026-09-29: "quality preset changes all relevant
## settings with it; change a setting after that and it switches to Custom"). Editing one of
## these away from the preset's value turns the preset row into "Custom", whose other keys keep
## following video/quality_base.
const PRESET_ROWS := ["video/shadows", "video/draw_distance", "video/clouds", "video/ocean", "video/render_scale"]
## Desktop anti-aliasing row (dev 2026-10-23: "make it all customizable") over the preset's own;
## the headset keeps its MSAA 2x whatever this says.
const AA_MODES := {
	"off": {"desktop_msaa": Viewport.MSAA_DISABLED, "screen_space_aa": Viewport.SCREEN_SPACE_AA_DISABLED, "use_taa": false},
	"fxaa": {"desktop_msaa": Viewport.MSAA_DISABLED, "screen_space_aa": Viewport.SCREEN_SPACE_AA_FXAA, "use_taa": false},
	"smaa": {"desktop_msaa": Viewport.MSAA_DISABLED, "screen_space_aa": Viewport.SCREEN_SPACE_AA_SMAA, "use_taa": false},
	"taa": {"desktop_msaa": Viewport.MSAA_DISABLED, "screen_space_aa": Viewport.SCREEN_SPACE_AA_DISABLED, "use_taa": true},
	"msaa2": {"desktop_msaa": Viewport.MSAA_2X, "screen_space_aa": Viewport.SCREEN_SPACE_AA_DISABLED, "use_taa": false},
	"msaa4": {"desktop_msaa": Viewport.MSAA_4X, "screen_space_aa": Viewport.SCREEN_SPACE_AA_DISABLED, "use_taa": false},
}
const UPSCALERS := {"bilinear": Viewport.SCALING_3D_MODE_BILINEAR, "fsr1": Viewport.SCALING_3D_MODE_FSR, "fsr2": Viewport.SCALING_3D_MODE_FSR2}
var _values: Dictionary = DEFAULTS.duplicate()
var _applying_quality := false
var _display_applied := false
## Where writes go (tests point these at scratch files so a player's settings stay put).
var path := PATH
var input_path := INPUT_PATH
var write_launch := true


func _launch_mode() -> String:
	if not ResourceLoader.exists(LAUNCH): return "off"
	var script := load(LAUNCH) as Script
	var file := ConfigFile.new()
	if file.load(str(script.get_script_constant_map().get("PATH", "user://launch.cfg"))) != OK: return "ask"
	var mode := str(file.get_value("launch", "vr", "ask"))
	return mode if mode in ["ask", "auto", "on", "off"] else "ask"
var _default_bindings: Dictionary = {}   # action -> physical keycode from project.godot
## Last message from a settings action (height measurement etc.), shown by the page.
var message := ""
## The world's command console (world/debug/command_console.gd) for Settings > Debug; null on the
## title screen.
var debug_console: Node


## The packs mount inside _init, after the engine read this script from the base pack, so a
## patch pack's copy of it would never run: Quality, created next, hands the node the mounted
## copy when it carries REVISION (autoload/quality.gd _adopt_patched_settings). That copy's
## _init must not mount the packs or boot the mods again (PACKS_MOUNTED).
const REVISION := 6
const PACKS_MOUNTED := &"home_equestria_packs_mounted"


func _init() -> void:
	if Engine.has_meta(PACKS_MOUNTED): return
	# Exported builds: data packs beside the executable, before anything reads res:// from
	# them (tools/build/packs.gd; a no-op in source runs).
	if ResourceLoader.exists(PACKS): (load(PACKS) as Script).call("load_extra_packs")
	# Mods load after the game's packs and before any other game script (world/modding/mod_loader.gd).
	preload("res://world/modding/mod_loader.gd").boot()
	_register_mip_loader()


## Potato tiers drop imported textures' top mip levels at load (autoload/texture_mip_loader.gd).
## Read straight from the settings file: this runs before _ready and before the first texture.
func _register_mip_loader() -> void:
	if DisplayServer.get_name() == "headless": return
	var config := ConfigFile.new()
	if config.load(PATH) != OK: return
	var chosen := str(config.get_value("video", "quality", ""))
	var base := str(config.get_value("video", "quality_base", chosen)) if chosen == "Custom" else chosen
	var quality_script: GDScript = load("res://autoload/quality.gd")
	var index: int = (quality_script.PRESET_NAMES as Array).find(base)
	if index < 0: return
	var drop := int((quality_script.CONFIG as Dictionary)[index].get("texture_mip_drop", 0))
	if drop <= 0: return
	var loader: ResourceFormatLoader = load("res://autoload/texture_mip_loader.gd").new()
	loader.drop = drop
	ResourceLoader.add_resource_format_loader(loader, true)
	print("[settings] %s tier: imported textures load %d mip level(s) down" % [base, drop])


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var config := ConfigFile.new()
	var first_launch := config.load(PATH) != OK
	if not first_launch:
		for key in DEFAULTS:
			var raw: Variant = config.get_value(key.get_slice("/", 0), key.get_slice("/", 1), DEFAULTS[key])
			var clean: Variant = validate(key, raw)
			_values[key] = clean if clean != null else DEFAULTS[key]
	elif DisplayServer.get_name() != "headless" and OS.has_feature("android"):
		# No settings file yet on a headset: pick the quality tier for this machine
		# (Quality.pick_default_quality documents the rule). Desktop players are asked instead
		# (setup/quality_asked, world/ui/quality_prompt.gd).
		var pick: String = (load("res://autoload/quality.gd") as Script).call("pick_for_this_machine")
		if validate("video/quality", pick) != null:
			_values["video/quality"] = pick
			_store("video/quality", pick)
			_adopt_preset(pick)
			print("[settings] first launch on %s: quality %s" % [RenderingServer.get_video_adapter_name(), pick])
	# Installs from before the question had their tier picked or chosen already: never ask them.
	if not first_launch and not config.has_section_key("setup", "quality_asked"):
		_values["setup/quality_asked"] = true; _store("setup/quality_asked", true)
	# launch.cfg follows the stored choice (written only when it differs).
	_write_frames_ahead()
	# Render scale used to mirror the preset (100%, 85% on Low, 70% on Very Low) instead of Auto;
	# move a stored mirror value to Auto once, so only a scale the player chose stays literal.
	if not first_launch and not config.has_section_key("video", "render_scale_auto"):
		var old_base := str(config.get_value("video", "quality_base", config.get_value("video", "quality", "")))
		var old_mirror := {"Very Low": 70, "Low": 85}.get(old_base, 100) as int
		# get_value with a null default still logs an error for a missing key: check first.
		var stored: Variant = config.get_value("video", "render_scale") if config.has_section_key("video", "render_scale") else null
		if stored == null or ((stored is int or stored is float) and int(stored) == old_mirror):
			_values["video/render_scale"] = 0; _store("video/render_scale", 0)
		_store("video/render_scale_auto", true)
	# Caption backdrop (soft, solid or none), then a 0-100% opacity, became Caption background, off
	# by default now that the words carry their own subtitle colours, and its Background opacity
	# (10-100%). A saved opacity says whether there was a card; else a solid backdrop carries over.
	if not first_launch and not config.has_section_key("access", "caption_card"):
		if config.has_section_key("access", "caption_opacity"):
			var stored := int(config.get_value("access", "caption_opacity"))
			_values["access/caption_card"] = stored > 0; _store("access/caption_card", stored > 0)
			if stored <= 0: _values["access/caption_opacity"] = DEFAULTS["access/caption_opacity"]; _store("access/caption_opacity", DEFAULTS["access/caption_opacity"])
		elif config.has_section_key("access", "caption_backdrop"):
			var solid := str(config.get_value("access", "caption_backdrop")) == "solid"
			_values["access/caption_card"] = solid; _store("access/caption_card", solid)
			if solid: _values["access/caption_opacity"] = 90; _store("access/caption_opacity", 90)
	# Retire the rejected placement switch; item/save formats are unchanged.
	_values["inventory/hud_placement"] = "gesture"
	_store("inventory/hud_placement", "gesture")
	_values["vr/start_mode"] = _launch_mode()
	_ensure_code_actions()
	for pair in BINDABLE: _default_bindings[pair[1]] = _action_key(pair[1])
	_load_bindings()
	_ensure_buses()
	_apply_audio()
	_apply_display(true)
	_apply_text_scale()
	# Quality is the next autoload: its node does not exist yet during this _ready.
	_apply_quality.call_deferred()


func get_value(key: String) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


## The accepted form of `value` for `key`, or null when it cannot be accepted.
static func validate(key: String, value: Variant) -> Variant:
	var spec: Dictionary = SPECS.get(key, {})
	if spec.is_empty(): return null
	match str(spec.type):
		"bool":
			return value if value is bool else null
		"int":
			if not (value is int or value is float) or not is_finite(float(value)): return null
			var step := int(spec.step)
			var v := clampi(roundi(float(value)), int(spec.min), int(spec.max))
			return int(spec.min) + roundi(float(v - int(spec.min)) / step) * step
		"float":
			if not (value is int or value is float) or not is_finite(float(value)): return null
			return clampf(float(value), float(spec.min), float(spec.max))
		"choice":
			for option in spec.options:
				if typeof(option[0]) == TYPE_INT and (value is int or value is float) and int(value) == int(option[0]) and float(value) == float(int(value)): return option[0]
				if typeof(option[0]) == TYPE_STRING and value is String and value == option[0]: return option[0]
			return null
	return null


func set_value(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key): return
	var clean: Variant = validate(key, value)
	if clean == null or same_value(_values.get(key), clean): return
	_values[key] = clean
	if key == "vr/start_mode":
		if write_launch and ResourceLoader.exists(LAUNCH): (load(LAUNCH) as Script).call("write", str(clean))
		changed.emit(key)
		return
	_store(key, clean)
	if key == "video/quality" and str(clean) != "Custom": _adopt_preset(str(clean))
	elif key in PRESET_ROWS and str(_values["video/quality"]) != "Custom":
		var rows := preset_rows(str(_values["video/quality"]))
		if rows.has(key) and rows[key] != clean:
			_values["video/quality"] = "Custom"; _store("video/quality", "Custom"); changed.emit("video/quality")
	_apply(key)
	changed.emit(key)


## The row values a tier stands for, read from Quality's table. Empty for "Custom"/unknown.
func preset_rows(name: String) -> Dictionary:
	var quality := get_node_or_null("/root/Quality")
	if quality == null: return {}
	var index: int = (quality.PRESET_NAMES as Array).find(name)
	if index < 0: return {}
	var config: Dictionary = quality.CONFIG[index]
	var shadows := "off"
	if bool(config.get("shadows_enabled", true)):
		var size := int(config.get("directional_shadow_size", 8192))
		for tier: String in ["very_low", "low", "medium", "high"]:
			if int(SHADOW_TIERS[tier].directional_shadow_size) == size: shadows = tier
	return {"video/shadows": shadows, "video/draw_distance": int(config.get("draw_distance", 12000.0)),
		"video/clouds": "volumetric" if bool(config.get("volume_clouds", true)) else "flat",
		"video/ocean": str(config.get("ocean", "fft")), "video/render_scale": 0}


## Choosing a tier writes its rows and remembers it as the base for a later Custom.
func _adopt_preset(name: String) -> void:
	_values["video/quality_base"] = name; _store("video/quality_base", name)
	var rows := preset_rows(name)
	for row: String in rows:
		var clean: Variant = validate(row, rows[row])
		if clean == null or _values.get(row) == clean: continue
		_values[row] = clean; _store(row, clean); changed.emit(row)


func _store(key: String, value: Variant) -> void:
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(key.get_slice("/", 0), key.get_slice("/", 1), value)
	config.save(path)


## Step a setting forward/backward and return its display text. The ◀ ▶ arrows stop at the
## first and last value instead of wrapping round (dev 2026-10-23: going all the way down
## must not jump from Very Low to Ultra).
func cycle(key: String, step: int) -> String:
	var spec: Dictionary = SPECS.get(key, {})
	match str(spec.get("type", "")):
		"bool":
			set_value(key, not bool(get_value(key)))
		"int":
			set_value(key, clampi(int(get_value(key)) + int(spec.get("arrow_step", spec.step)) * step, int(spec.min), int(spec.max)))
		"float":
			if str(spec.get("unit", "")) == "height":
				# One inch a press, landing on whole inches.
				var inches := roundi(float(get_value(key)) / 2.54) + step
				set_value(key, clampf(inches * 2.54, float(spec.min), float(spec.max)))
				return display(key)
			var presets: Array = spec.presets
			var current := float(get_value(key)); var index := presets.find(current)
			if index < 0:
				index = 0
				for i in presets.size():
					if absf(presets[i] - current) < absf(presets[index] - current): index = i
			set_value(key, presets[clampi(index + step, 0, presets.size() - 1)])
		"choice":
			# Window size steps only through the sizes this screen holds.
			var options: Array = window_sizes() if key == "video/window_size" else spec.options
			var index := 0
			for i in options.size():
				if same_value(options[i][0], get_value(key)): index = i
			set_value(key, options[clampi(index + step, 0, options.size() - 1)][0])
	return display(key)


func display(key: String) -> String:
	var spec: Dictionary = SPECS.get(key, {})
	var value: Variant = get_value(key)
	match str(spec.get("type", "")):
		"bool":
			var labels: Array = spec.get("labels", ["Off", "On"])
			return str(labels[1] if bool(value) else labels[0])
		"int":
			if int(value) == 0 and spec.has("zero"): return str(spec.zero)
			return str(spec.get("fmt", "%d")) % int(value)
		"float":
			if str(spec.get("unit", "")) == "height": return height_text(float(value))
			return str(spec.get("fmt", "%.2f")) % float(value)
		"choice":
			for option in spec.options:
				if same_value(option[0], value): return str(option[1])
	return str(value)


## "6 ft 0 in (182.9 cm)": the nearest whole inch, and centimetres to a tenth (whole when whole).
static func height_text(cm: float) -> String:
	var inches := roundi(cm / 2.54)
	var tenths := roundi(cm * 10.0)
	var metric := ("%d" % (tenths / 10)) if tenths % 10 == 0 else ("%.1f" % (tenths / 10.0))
	return "%d ft %d in (%s cm)" % [inches / 12, inches % 12, metric]


## A typed height in centimetres, or -1.0: 5'10", 5 ft 10 in, 6 feet, 70 in, 178 cm, 1.78 m. A bare
## number is metres up to 3, feet below 9, inches below 100, else centimetres. Centimetres win
## when the text has both (the row's own "6 ft 0 in (182.9 cm)").
static func parse_height_cm(text: String) -> float:
	var t := text.strip_edges().to_lower().replace(",", ".").replace("\u2019", "'").replace("\u2032", "'") \
		.replace("\u201d", "\"").replace("\u2033", "\"")
	var number := "(\\d+(?:\\.\\d+)?)"
	var found := RegEx.create_from_string(number + "\\s*cm").search(t)
	if found != null: return found.get_string(1).to_float()
	found = RegEx.create_from_string("^" + number + "\\s*m(?:etres?|eters?)?$").search(t)
	if found != null: return found.get_string(1).to_float() * 100.0
	found = RegEx.create_from_string(number + "\\s*(?:'|ft|feet|foot)").search(t)
	if found != null:
		var inches := RegEx.create_from_string(number).search(t.substr(found.get_end()))
		return (found.get_string(1).to_float() * 12.0 + (inches.get_string(1).to_float() if inches != null else 0.0)) * 2.54
	found = RegEx.create_from_string("^" + number + "\\s*(?:\"|in|inch|inches)$").search(t)
	if found != null: return found.get_string(1).to_float() * 2.54
	if not t.is_valid_float(): return -1.0
	var bare := t.to_float()
	if bare <= 3.0: return bare * 100.0
	if bare < 9.0: return bare * 30.48
	if bare < 100.0: return bare * 2.54
	return bare


## The value typed into a row's field, or null when the text says nothing usable. Whole numbers
## (with an optional %) for int rows; feet/inches or centimetres for the height row.
static func parse_typed(key: String, text: String) -> Variant:
	var spec: Dictionary = SPECS.get(key, {})
	if str(spec.get("unit", "")) == "height":
		var cm := parse_height_cm(text)
		return cm if cm > 0.0 else null
	var digits := text.strip_edges().trim_suffix("%").strip_edges()
	return digits.to_int() if digits.is_valid_int() else null


## Options can mix kinds ("preset" beside 80): == between a String and an int is an error in a
## debug build, so the kinds are compared first.
static func same_value(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


## Label with its note: "Trees & plants (new areas)".
static func row_label(label: String, key: String) -> String:
	var note := str(SPECS.get(key, {}).get("note", ""))
	return label if note.is_empty() else "%s (%s)" % [label, note]


func pony_scale() -> float:
	var preset: Dictionary = PONY_SIZES[_size_index()]
	return float(preset.scale) * (anon_height_scale() if bool(preset.get("follows_anon", false)) else 1.0)


## Anon's chosen real-world height over the 6 ft Anon the game was tuned for (1.0 at 6 ft 0 in).
## Desktop: his eye, capsule, body, hands, held and carried offsets. VR: his body and hands (the
## headset keeps the camera); see player/desktop_player.gd apply_height and player/anon_body.gd.
func anon_height_scale() -> float:
	return float(get_value("player/height_cm")) / ANON_REFERENCE_CM


## His standing eye in real metres for that height (the same 12 cm below the crown as the headset
## measurement in player/anon_body.gd).
func anon_eye_height_m() -> float:
	return float(get_value("player/height_cm")) / 100.0 - 0.12


## Whether the player has stored `key` (chosen it), as opposed to running on its default.
func is_chosen(key: String) -> bool:
	var config := ConfigFile.new()
	return config.load(path) == OK and config.has_section_key(key.get_slice("/", 0), key.get_slice("/", 1))


## Back to the default and no longer stored as chosen; listeners hear it like any change.
func forget_value(key: String) -> void:
	if not DEFAULTS.has(key): return
	var config := ConfigFile.new()
	if config.load(path) == OK and config.has_section_key(key.get_slice("/", 0), key.get_slice("/", 1)):
		config.erase_section_key(key.get_slice("/", 0), key.get_slice("/", 1))
		config.save(path)
	var was: Variant = _values.get(key)
	_values[key] = DEFAULTS[key]
	if same_value(was, DEFAULTS[key]): return
	_apply(key)
	changed.emit(key)


func tts_enabled() -> bool:
	return bool(get_value("voice/tts"))


func _size_index() -> int:
	var wanted := str(get_value("ponies/size"))
	for i in PONY_SIZES.size():
		if PONY_SIZES[i].name == wanted: return i
	return 0


## Route a player to one of the settings buses ("Voice", "SFX", "Ambience").
static func route(player: Node, bus: String) -> void:
	if player == null: return
	if AudioServer.get_bus_index(bus) < 0: return
	player.set("bus", bus)


# ------------------------------------------------------------------ applying
func _apply(key: String) -> void:
	if key == "video/quality": _write_frames_ahead()
	if key.begins_with("audio/"): _apply_audio()
	elif key in ["video/quality", "video/shadows", "video/draw_distance", "video/render_scale", "video/antialiasing", "video/upscaler"]: _apply_quality()
	elif key in ["video/vsync", "video/fps_cap", "video/window"]: _apply_display(key == "video/window")
	elif key == "video/window_size": _apply_window_size()
	elif key == "video/frames_ahead": _write_frames_ahead()
	elif key == "access/ui_scale": _apply_text_scale()
	elif key == "video/grass_density": apply_grass()
	elif key in ["access/subtitles", "access/subtitle_scale"]: apply_subtitles()
	elif key == "player/height_cm" and bool(PONY_SIZES[_size_index()].get("follows_anon", false)): _pony_size_follows_anon()


## "Same height as Anon" ponies follow his height. One "ponies/size" change once a slider drag
## settles (every listener rescales every pony and clears the impostor pictures).
var _pony_follow_pending := false
func _pony_size_follows_anon() -> void:
	if _pony_follow_pending or not is_inside_tree(): return
	_pony_follow_pending = true
	var waited: bool = await preload("res://world/shutdown_waits.gd").seconds(self, 0.3)
	_pony_follow_pending = false
	if waited: changed.emit("ponies/size")


## Everything that lives in the world scene; game.gd calls this once the world is built.
func apply_scene() -> void:
	apply_grass()
	apply_subtitles()


func _apply_quality() -> void:
	var quality := get_node_or_null("/root/Quality")
	if quality == null: return
	var names: Array = quality.PRESET_NAMES
	var chosen := str(get_value("video/quality"))
	var base := str(get_value("video/quality_base")) if chosen == "Custom" else chosen
	var index := names.find(base)
	# Rows that merely mirror the base tier leave its own full tuning in place; only rows the
	# player moved away from it become overrides.
	var mirror := preset_rows(base)
	var overrides := {}
	var shadows := str(get_value("video/shadows"))
	if SHADOW_TIERS.has(shadows) and shadows != str(mirror.get("video/shadows", "")): overrides.merge(SHADOW_TIERS[shadows])
	var draw := int(get_value("video/draw_distance"))
	if draw > 0 and draw != int(mirror.get("video/draw_distance", 0)): overrides["draw_distance"] = float(draw)
	var scale := int(get_value("video/render_scale"))
	if scale > 0: overrides["render_scale"] = scale / 100.0
	var aa := str(get_value("video/antialiasing"))
	if AA_MODES.has(aa): overrides.merge(AA_MODES[aa])
	var upscaler := str(get_value("video/upscaler"))
	if UPSCALERS.has(upscaler): overrides["scaling_mode"] = UPSCALERS[upscaler]
	quality.vr_desktop_effects = bool(get_value("video/vr_desktop_effects"))
	_applying_quality = true
	if index >= 0 and quality.preset != index: quality.preset = index
	quality.set_user_overrides(overrides)
	_applying_quality = false
	if not quality.preset_changed.is_connected(_on_quality_changed): quality.preset_changed.connect(_on_quality_changed)


## Quality also changes from the debug key and when XR starts: keep the stored preset and
## the XR display rules in step.
func _on_quality_changed(preset: int) -> void:
	var quality := get_node_or_null("/root/Quality")
	if quality == null: return
	var preset_name: String = quality.PRESET_NAMES[preset]
	if _applying_quality: return  # our own write
	if str(get_value("video/quality")) == "Custom" and preset_name == str(get_value("video/quality_base")): return
	if preset_name != str(get_value("video/quality")): set_value("video/quality", preset_name)
	_apply_display()
	apply_grass()


func _xr_running() -> bool:
	var quality := get_node_or_null("/root/Quality")
	return quality != null and bool(quality.xr_mode)


## V-Sync, FPS cap and window mode are desktop concerns: the headset paces XR frames. `sizing`
## also sets the windowed size (at launch and when the Window row changes, not on every apply,
## so a window the player resized by hand stays as it is).
## "Extra frame ahead" into user://launch.cfg (frame_queue_size, read once at boot; Godot's default is
## 2). Desktop only: Quest keeps 2. Never from headless tests or the editor (the player's file).
## Medium and below queue the extra frame unless the player chose otherwise (a Custom setup
## follows the tier it started from).
const FRAMES_AHEAD_TIERS := ["Medium", "Low", "Very Low"]
func frames_ahead_on() -> bool:
	var mode := str(get_value("video/frames_ahead"))
	if mode != "preset": return mode == "on"
	var tier := str(get_value("video/quality"))
	if tier == "Custom": tier = str(get_value("video/quality_base"))
	return tier in FRAMES_AHEAD_TIERS

func _write_frames_ahead() -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("editor") or OS.has_feature("android"): return
	var queue := 3 if frames_ahead_on() else 2
	var err: Error = preload("res://world/launch_config.gd").write_overrides({"rendering/rendering_device/vsync/frame_queue_size": queue})
	if err != OK: push_warning("[settings] could not write the frame queue to launch.cfg: %s" % error_string(err))

func _apply_display(sizing := false) -> void:
	if DisplayServer.get_name() == "headless": return
	if _xr_running():
		Engine.max_fps = 0
		return
	Engine.max_fps = int(get_value("video/fps_cap"))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(get_value("video/vsync")) else DisplayServer.VSYNC_DISABLED)
	var mode: int = {"windowed": DisplayServer.WINDOW_MODE_WINDOWED, "fullscreen": DisplayServer.WINDOW_MODE_FULLSCREEN,
		"exclusive": DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN}.get(str(get_value("video/window")), DisplayServer.WINDOW_MODE_WINDOWED)
	var current := DisplayServer.window_get_mode()
	# A `--fullscreen`/`-f` launch keeps its window at startup; the stored row applies once the
	# player changes it (it used to undo the flag on the first apply).
	if not _display_applied and mode == DisplayServer.WINDOW_MODE_WINDOWED and ("--fullscreen" in OS.get_cmdline_args() or "-f" in OS.get_cmdline_args()):
		_display_applied = true
		return
	# Likewise a launch with its own `--resolution`, or `--maximized`/`-m`, keeps its window.
	if not _display_applied:
		for flag: String in ["--resolution", "--maximized", "-m"]:
			if flag in OS.get_cmdline_args(): sizing = false
	_display_applied = true
	# A maximized/minimized window counts as windowed: leave it alone.
	var windowed := current in [DisplayServer.WINDOW_MODE_WINDOWED, DisplayServer.WINDOW_MODE_MAXIMIZED, DisplayServer.WINDOW_MODE_MINIMIZED]
	if not (mode == DisplayServer.WINDOW_MODE_WINDOWED and windowed) and current != mode:
		DisplayServer.window_set_mode(mode)
	if sizing and mode == DisplayServer.WINDOW_MODE_WINDOWED: _apply_window_size()


## The window sizes that fit this screen's usable area (Window size lists only these), and
## "maximized".
func window_sizes() -> Array:
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	var out: Array = []
	for option: Array in SPECS["video/window_size"].options:
		var size := _window_size(str(option[0]))
		if size == Vector2i.ZERO or (size.x <= usable.x and size.y <= usable.y) or option[0] == get_value("video/window_size"): out.append(option)
	return out


static func _window_size(choice: String) -> Vector2i:
	return Vector2i.ZERO if not "x" in choice else Vector2i(int(choice.get_slice("x", 0)), int(choice.get_slice("x", 1)))


## Windowed mode at the chosen size, in the middle of its screen (a size bigger than the screen
## shrinks to fit it), or maximized. Through the root Window, not DisplayServer.window_set_size:
## on X11 that records the new size before the window changes, so the resize event then looks
## like no change and the game kept drawing 1600 x 900 in a corner of a bigger window (dev
## 2026-10-27, "IS this normal").
func _apply_window_size() -> void:
	if DisplayServer.get_name() == "headless" or _xr_running() or str(get_value("video/window")) != "windowed": return
	var window: Window = get_tree().root if is_inside_tree() else null
	if window == null: return
	var choice := str(get_value("video/window_size"))
	if choice == "maximized":
		window.mode = Window.MODE_MAXIMIZED; return
	if window.mode != Window.MODE_WINDOWED: window.mode = Window.MODE_WINDOWED
	var usable := DisplayServer.screen_get_usable_rect(window.current_screen)
	var size := _window_size(choice)
	if size.x > usable.size.x or size.y > usable.size.y:
		var fit := minf(float(usable.size.x) / size.x, float(usable.size.y - 40) / size.y)
		size = Vector2i((Vector2(size) * fit).floor())
	window.size = size
	window.position = usable.position + (usable.size - size) / 2


## The FPS cap the game should run at (the title screen caps menus at 60 on its own).
func fps_cap() -> int:
	return 0 if _xr_running() else int(get_value("video/fps_cap"))


## Menu text size: default font size for every Control without its own size.
func _apply_text_scale() -> void:
	var size := roundi(16.0 * int(get_value("access/ui_scale")) / 100.0)
	ThemeDB.fallback_font_size = size
	var tree := get_tree()
	if tree == null: return
	var theme: Theme = tree.root.theme if tree.root.theme != null else Theme.new()
	theme.default_font_size = size
	tree.root.theme = theme


func mouse_sensitivity() -> float:
	return 0.0022 * int(get_value("controls/mouse_sensitivity")) / 100.0


func weather_frequency() -> float:
	return int(get_value("world/weather_frequency")) / 100.0


func season_days() -> int:
	return int(get_value("world/season_days"))


## 0 = unlimited (the population streams every resident in range; crowd tiers LOD them).
func nearby_limit(_roster_limit: int) -> int:
	return maxi(int(get_value("ponies/max_nearby")), 0)


func foliage_density() -> float:
	return int(get_value("video/foliage_density")) / 100.0


## Ground grass (world/foliage/grass/ground_grass.gd): scale the per-texture coverage by the
## player's density times the quality tier's (grass_density: Medium 75 %, Low 50 %, Very Low 25 %).
func apply_grass() -> void:
	var tree := get_tree()
	if tree == null: return
	var scale := int(get_value("video/grass_density")) / 100.0
	var quality := get_node_or_null("/root/Quality")
	if quality != null: scale *= float(quality.get_value("grass_density", 1.0))
	for grass in tree.root.find_children("GroundGrass", "", true, false):
		if grass.has_method("set_density"):
			grass.set_density(scale); continue
		if not "rings" in grass: continue
		if not grass.has_meta("base_density"):
			var ids: Variant = null
			for ring: Dictionary in grass.rings:
				if not (ring.lod as Dictionary).has("shader"): ids = (ring.material as ShaderMaterial).get_shader_parameter("id_density"); break
			if ids == null: continue
			grass.set_meta("base_density", ids)
		var base: PackedFloat32Array = grass.get_meta("base_density")
		var scaled := PackedFloat32Array(); scaled.resize(base.size())
		for i in base.size(): scaled[i] = base[i] * scale
		for ring: Dictionary in grass.rings:
			if not (ring.lod as Dictionary).has("shader"): (ring.material as ShaderMaterial).set_shader_parameter("id_density", scaled)
		(grass as Node3D).visible = scale > 0.0


## Speech subtitles (world/ai/voice_hud.gd, owned by the voice work): hide or resize the
## desktop subtitle label and the VR status/subtitle Label3D from outside.
func apply_subtitles() -> void:
	var tree := get_tree()
	if tree == null: return
	var on := bool(get_value("access/subtitles"))
	var scale := int(get_value("access/subtitle_scale")) / 100.0
	for hud in tree.root.find_children("VoiceHud", "", true, false):
		var label: Variant = hud.get("_label")
		if label is Label:
			(label as Label).add_theme_font_size_override("font_size", roundi(16 * scale))
			(label as Label).visible = on
		var label3d: Variant = hud.get("_label3d")
		if label3d is Label3D:
			(label3d as Label3D).font_size = roundi(40 * scale)
			(label3d as Label3D).transparency = 0.0 if on else 1.0


# ------------------------------------------------------------------ key bindings
static func key_name(keycode: int) -> String:
	return "(none)" if keycode == 0 else OS.get_keycode_string(keycode)


func _action_key(action: String) -> int:
	if not InputMap.has_action(action): return 0
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			var k := event as InputEventKey
			return k.physical_keycode if k.physical_keycode != 0 else k.keycode
	return 0


func binding(action: String) -> int:
	return _action_key(action)


## The bound key's name for on-screen hints ("Alt", "B"), or `fallback` when unbound.
func key_label(action: String, fallback := "?") -> String:
	var k := _action_key(action)
	return fallback if k == 0 else OS.get_keycode_string(k)


func _ensure_code_actions() -> void:
	for action: String in CODE_ACTIONS:
		if InputMap.has_action(action): continue
		InputMap.add_action(action)
		_set_action_key(action, CODE_ACTIONS[action])


## Bind `keycode` to `action`; an action that already had that key takes the old one.
func bind_key(action: String, keycode: int) -> void:
	if not InputMap.has_action(action) or keycode == 0: return
	var previous := _action_key(action)
	for pair in BINDABLE:
		if pair[1] != action and _action_key(pair[1]) == keycode: _set_action_key(pair[1], previous)
	_set_action_key(action, keycode)
	_save_bindings()
	changed.emit("bind:" + action)


func reset_bindings() -> void:
	for pair in BINDABLE: _set_action_key(pair[1], int(_default_bindings.get(pair[1], 0)))
	_save_bindings()
	changed.emit("bind:")


func _set_action_key(action: String, keycode: int) -> void:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey: InputMap.action_erase_event(action, event)
	if keycode == 0: return
	var key := InputEventKey.new(); key.physical_keycode = keycode as Key
	InputMap.action_add_event(action, key)


func _save_bindings() -> void:
	var config := ConfigFile.new()
	for pair in BINDABLE:
		var k := _action_key(pair[1])
		if k != int(_default_bindings.get(pair[1], 0)): config.set_value("bindings", pair[1], k)
	config.save(input_path)


func _load_bindings() -> void:
	var config := ConfigFile.new()
	if config.load(input_path) != OK or not config.has_section("bindings"): return
	for action in config.get_section_keys("bindings"):
		var value: Variant = config.get_value("bindings", action, 0)
		if _default_bindings.has(action) and value is int and value > 0 and value < 0x2000000: _set_action_key(action, value)


# ------------------------------------------------------------------ page actions
func run_action(id: String) -> void:
	match id:
		"reset_bindings":
			reset_bindings(); message = "Keys reset to defaults."
		"measure_height":
			var anon := _anon_body()
			if anon == null or not anon.has_method("begin_height_calibration"): message = "Height is measured in VR only."
			else: anon.begin_height_calibration(); message = "Stand straight and look forward for three seconds…"
		"forget_height":
			# A measurement also set Anon's height (player/anon_body.gd): that goes back to 6 ft.
			forget_value("player/height_cm")
			var anon := _anon_body()
			if anon != null and anon.has_method("calibrate"): anon.calibrate()
			var calibration := "user://calibration.json"
			if FileAccess.file_exists(calibration): DirAccess.remove_absolute(ProjectSettings.globalize_path(calibration))
			message = "Measured height forgotten; Anon's height is 6 ft again, estimated while you stand in VR."
		"spawn_barbiepone":
			# world/events/barbiepone/barbiepone.gd answers the signal below.
			message = ""
	changed.emit("action:" + id)


## Live button text for an action row (the Great Evil button flips to "Exorcise the Evil" while
## she is in the world). Providers are Callables returning "" for the default label.
var action_labels: Dictionary = {}
func action_label(id: String, fallback: String) -> String:
	var provider: Variant = action_labels.get(id)
	if provider is Callable and (provider as Callable).is_valid():
		var text := str((provider as Callable).call())
		if not text.is_empty(): return text
	return fallback


func _anon_body() -> Node:
	var tree := get_tree()
	return tree.root.find_child("AnonBody", true, false) if tree != null else null


# ------------------------------------------------------------------ audio
func _ensure_buses() -> void:
	for name in BUSES:
		if AudioServer.get_bus_index(name) >= 0: continue
		AudioServer.add_bus()
		var index := AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(index, name)
		AudioServer.set_bus_send(index, "Master")

	preload("res://world/audio/audio_mix.gd").ensure_buses()


func _apply_audio() -> void:
	_set_volume("Master", int(get_value("audio/master")))
	_set_volume("Voice", int(get_value("audio/voice")))
	_set_volume("SFX", int(get_value("audio/sfx")))
	_set_volume("Ambience", int(get_value("audio/ambience")))
	_set_volume("Wind", int(get_value("audio/wind")))
	_set_volume("Music", int(get_value("audio/music")))


func _set_volume(bus: String, percent: int) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0: return
	AudioServer.set_bus_mute(index, percent <= 0)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(percent, 1) / 100.0))
