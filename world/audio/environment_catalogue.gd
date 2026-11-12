extends RefCounted
## Finite, recorded environment and ground-contact variants. Provenance is retained privately.
const GRASS := [
	preload("res://world/audio/designed/environment/grass_01.ogg"),
	preload("res://world/audio/designed/environment/grass_02.ogg"),
	preload("res://world/audio/designed/environment/grass_03.ogg"),
	preload("res://world/audio/designed/environment/grass_04.ogg"),
	preload("res://world/audio/designed/environment/grass_05.ogg"),
	preload("res://world/audio/designed/environment/grass_06.ogg"),
]
const STONE := [
	preload("res://world/audio/designed/environment/stone_01.ogg"),
	preload("res://world/audio/designed/environment/stone_02.ogg"),
	preload("res://world/audio/designed/environment/stone_03.ogg"),
	preload("res://world/audio/designed/environment/stone_04.ogg"),
	preload("res://world/audio/designed/environment/stone_05.ogg"),
	preload("res://world/audio/designed/environment/stone_06.ogg"),
]
const WOOD := [
	preload("res://world/audio/designed/environment/wood_01.ogg"),
	preload("res://world/audio/designed/environment/wood_02.ogg"),
	preload("res://world/audio/designed/environment/wood_03.ogg"),
	preload("res://world/audio/designed/environment/wood_04.ogg"),
	preload("res://world/audio/designed/environment/wood_05.ogg"),
	preload("res://world/audio/designed/environment/wood_06.ogg"),
]
const SNOW := [
	preload("res://world/audio/designed/environment/snow_01.ogg"),
	preload("res://world/audio/designed/environment/snow_02.ogg"),
	preload("res://world/audio/designed/environment/snow_03.ogg"),
	preload("res://world/audio/designed/environment/snow_04.ogg"),
	preload("res://world/audio/designed/environment/snow_05.ogg"),
	preload("res://world/audio/designed/environment/snow_06.ogg"),
]
## Hoof one-shots cut from recorded clip-clops (tools/audio/extract_hoofsteps.py in the private
## root; picks, scores and sources in its archive manifest). Hard: wood and stone; soft: grass,
## dirt, sand; water: a hoof in shallow water.
const HOOF := [
	preload("res://world/audio/hooves/hard_01.ogg"),
	preload("res://world/audio/hooves/hard_02.ogg"),
	preload("res://world/audio/hooves/hard_03.ogg"),
	preload("res://world/audio/hooves/hard_04.ogg"),
	preload("res://world/audio/hooves/hard_05.ogg"),
	preload("res://world/audio/hooves/hard_06.ogg"),
	preload("res://world/audio/hooves/hard_07.ogg"),
	preload("res://world/audio/hooves/hard_08.ogg"),
	preload("res://world/audio/hooves/hard_09.ogg"),
	preload("res://world/audio/hooves/hard_10.ogg"),
]
const HOOF_SOFT := [
	preload("res://world/audio/hooves/soft_01.ogg"),
	preload("res://world/audio/hooves/soft_02.ogg"),
	preload("res://world/audio/hooves/soft_03.ogg"),
	preload("res://world/audio/hooves/soft_04.ogg"),
	preload("res://world/audio/hooves/soft_05.ogg"),
	preload("res://world/audio/hooves/soft_06.ogg"),
	preload("res://world/audio/hooves/soft_07.ogg"),
	preload("res://world/audio/hooves/soft_08.ogg"),
	preload("res://world/audio/hooves/soft_09.ogg"),
	preload("res://world/audio/hooves/soft_10.ogg"),
]
const HOOF_WATER := [
	preload("res://world/audio/hooves/water_01.ogg"),
	preload("res://world/audio/hooves/water_02.ogg"),
	preload("res://world/audio/hooves/water_03.ogg"),
	preload("res://world/audio/hooves/water_04.ogg"),
]
const CLOTH := [
	preload("res://world/audio/designed/environment/cloth_01.ogg"),
	preload("res://world/audio/designed/environment/cloth_02.ogg"),
	preload("res://world/audio/designed/environment/cloth_03.ogg"),
	preload("res://world/audio/designed/environment/cloth_04.ogg"),
]
const SPLASH := [
	preload("res://world/audio/designed/environment/splash_01.ogg"),
	preload("res://world/audio/designed/environment/splash_02.ogg"),
	preload("res://world/audio/designed/environment/splash_03.ogg"),
	preload("res://world/audio/designed/environment/splash_04.ogg"),
]
const LEAVES := [
	preload("res://world/audio/designed/environment/leaves_01.ogg"),
	preload("res://world/audio/designed/environment/leaves_02.ogg"),
]
const MUD := [
	preload("res://world/audio/designed/environment/mud_01.ogg"),
]
const GRAVEL := [
	preload("res://world/audio/designed/environment/gravel_01.ogg"),
]
## Seasons (W2-SEAS-J): "ice" is a frozen slab (hard steps until a real ice creak recording
## exists), "puddle" a wet-season puddle on terrain (ground_contact_audio.gd decides both).
const FOOT_MATERIALS := {"grass": GRASS, "dirt": GRASS, "sand": GRASS, "stone": STONE, "wood": WOOD, "snow": SNOW, "leaves": LEAVES, "mud": MUD, "gravel": GRAVEL, "cloud": CLOTH, "cloth": CLOTH, "water": SPLASH, "ice": STONE, "puddle": SPLASH}
const HOOF_MATERIALS := {"grass": HOOF_SOFT, "dirt": HOOF_SOFT, "sand": HOOF_SOFT, "stone": HOOF, "wood": HOOF, "snow": SNOW, "leaves": LEAVES, "mud": MUD, "gravel": GRAVEL, "cloud": CLOTH, "cloth": CLOTH, "water": HOOF_WATER, "ice": HOOF, "puddle": HOOF_WATER}
## A puddle step under a cue's own level: the splash set is louder than a footfall, the wading
## hoof set about as loud as a soft hoof.
const PUDDLE_FOOT_DB := -9.0
const PUDDLE_HOOF_DB := -2.0
## Seasonal ambience beds (world/ambience.gd). Recorded only; each is one line to swap when a
## better recording is added. The winter bed is the CC0 mild-wind recording, played as a steady
## loop a little lower in pitch. Autumn rustle: no dedicated canopy leaf-rustle recording exists
## in the project yet, so the same wind recording plays positioned at a nearby tree crown.
const WINTER_WIND := preload("res://world/audio/designed/environment/breeze.ogg")
const LEAF_RUSTLE := preload("res://world/audio/designed/environment/breeze.ogg")
const EVENTS := {
	"env_footstep": {"streams": GRASS, "materials": FOOT_MATERIALS, "volume_db": -13.0, "distance": 18.0, "cooldown": .45, "concurrency": 4, "priority": 1},
	# Footfalls arrive on the baked plants (pony_hoof_plants.gd), each hoof gated to one per
	# landing: the fast trot's diagonal pair lands 39-51 ms apart at clip speed 1 and clip-tier
	# ponies play up to 1.6x (24 ms), so the per-pony gap only stops same-tick duplicates.
	# A full cue replaces its farthest voice for a nearer footfall (the player's own pony and the
	# closest mare are never silenced by the crowd behind them).
	"env_hoofstep": {"streams": HOOF_SOFT, "materials": HOOF_MATERIALS, "volume_db": -16.0, "distance": 18.0, "cooldown": .02, "concurrency": 4, "priority": 1, "pitch_min": .94, "pitch_max": 1.06, "replace_farthest": true},
	"env_hoof_wade": {"streams": HOOF_WATER, "volume_db": -18.0, "distance": 18.0, "cooldown": .1, "concurrency": 3, "priority": 1, "pitch_min": .92, "pitch_max": 1.06},
	"env_land": {"streams": GRASS, "materials": FOOT_MATERIALS, "volume_db": -15.0, "distance": 18.0, "cooldown": .25, "concurrency": 2, "priority": 1, "pitch_min": .86, "pitch_max": .94},
	"env_hoof_land": {"streams": HOOF_SOFT, "materials": HOOF_MATERIALS, "volume_db": -16.0, "distance": 18.0, "cooldown": .25, "concurrency": 2, "priority": 1, "pitch_min": .90, "pitch_max": .98},
	"env_jump": {"streams": CLOTH, "volume_db": -23.0, "distance": 6.0, "cooldown": .35, "concurrency": 2, "priority": 1},
	"env_splash": {"streams": SPLASH, "volume_db": -17.0, "distance": 18.0, "cooldown": .4, "concurrency": 2, "priority": 2},
	"env_wade": {"streams": SPLASH, "volume_db": -23.0, "distance": 10.0, "cooldown": .85, "concurrency": 2, "priority": 1},
	"env_water_edge": {"streams": [preload("res://world/audio/designed/environment/water_edge.ogg")], "volume_db": -14.0, "distance": 28.0, "cooldown": 0.0, "concurrency": 1, "priority": 0, "bus": "Ambience", "loop": true},
	"env_rain": {"streams": [preload("res://world/audio/designed/environment/rain_outdoors.ogg")], "volume_db": -24.0, "distance": 400.0, "concurrency": 1, "priority": 1, "bus": "Ambience", "loop": true, "spatial": false},
	"env_rain_roof": {"streams": [preload("res://world/audio/designed/environment/rain_roof.ogg")], "volume_db": -27.0, "distance": 400.0, "concurrency": 1, "priority": 0, "bus": "Ambience", "loop": true, "spatial": false},
	"env_thunder": {"streams": [preload("res://world/audio/designed/environment/thunder_01.ogg")], "volume_db": -19.0, "distance": 400.0, "cooldown": 8.0, "concurrency": 1, "priority": 1, "bus": "Ambience", "spatial": false, "pitch_min": .94, "pitch_max": 1.01},
	# Kicked or jumped-in leaf piles (W2-SEAS-E calls play_event(pile, "env_leaf_kick", {"intensity": 0..1}, at)).
	"env_leaf_kick": {"streams": LEAVES, "volume_db": -15.0, "distance": 16.0, "cooldown": .12, "concurrency": 3, "priority": 1, "pitch_min": .88, "pitch_max": 1.08},
	"env_tree_creak": {"streams": [preload("res://world/audio/designed/environment/tree_creak.ogg")], "volume_db": -28.0, "distance": 40.0, "cooldown": 90.0, "concurrency": 1, "priority": 0, "bus": "Ambience"},
}
