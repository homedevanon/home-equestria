extends RefCounted
## Solver-baked gait clips for the crowd's clip tiers (docs/CLIP_TIER_2026_09_25.md).
##
## tools/bake_pony_gaits.gd runs the full procedural solver headless on flat ground and records
## one loop-clean cycle per gait (walk, trot_slow, trot, trot_fast, gallop) plus a standing pose, and the
## posture system's own output for sit, lie_down, their rises, holds and the sleep poses. The clips
## are shared by every pony with the same body skeleton (bone names, parents and rest poses):
## one AnimationLibrary per layout at DIRECTORY/<layout key>.res. The old native trot and the
## synthetic crowd_stand clip are never played any more (dev 2026-09-25: "we cant use the native
## animation because atp its noticeable"); a layout without a bake keeps its ponies on the solver.
## trot_slow (2026-10-31) is the solver's own trot at a slow pace (short strides, the cadence floor),
## so a slow pony slow-trots instead of playing the everyday trot clip in slow motion (dev: "it
## should be trot -> walk -> gallop"; their "walk" is the everyday trot clip).

const DIRECTORY := "res://world/characters/baked_gaits/"
const LIBRARY := &"baked"
## Bumped whenever the bake's recording or clip layout changes; older files are ignored.
const VERSION := 3
const GAITS: Array[String] = ["walk", "trot_slow", "trot", "trot_fast", "gallop"]
const STAND := "stand"

static var _keys := {}  # model scene path -> layout key
static var _libraries := {}  # layout key -> AnimationLibrary, or null once found missing


## Bone count plus an MD5 of every bone's name, parent and rest transform (raw bytes).
static func layout_key(skeleton: Skeleton3D) -> String:
	var md5 := HashingContext.new()
	md5.start(HashingContext.HASH_MD5)
	for bone in skeleton.get_bone_count():
		md5.update(skeleton.get_bone_name(bone).to_utf8_buffer())
		md5.update(var_to_bytes(skeleton.get_bone_parent(bone)))
		md5.update(var_to_bytes(skeleton.get_bone_rest(bone)))
	return "%d_%s" % [skeleton.get_bone_count(), md5.finish().hex_encode().substr(0, 12)]


static func path_for(key: String) -> String:
	return DIRECTORY + key + ".res"


## Track path prefix from the player's root node to the skeleton ("Armature/Skeleton3D").
static func base_path(player: AnimationPlayer, skeleton: Skeleton3D) -> String:
	var root := player.get_node_or_null(player.root_node)
	return String(root.get_path_to(skeleton)) if root != null else ""


## Leaving a world (quit to title, new game, reload): the next world loads fresh libraries.
## This cache boundary alone did not fix animation startup crashes: callers must stop
## playback before changing libraries (ARRIVAL_CRASH_AND_MENU_POINTERS_2026_10_11.md).
static func forget() -> void:
	_libraries.clear()


## Adds this layout's baked library to `player` as "baked"; null when there is none.
static func attach(player: AnimationPlayer, skeleton: Skeleton3D, source_path: String) -> AnimationLibrary:
	var key: String = _keys.get(source_path, "")
	if key.is_empty():
		key = layout_key(skeleton)
		if not source_path.is_empty():
			_keys[source_path] = key
	var library: AnimationLibrary
	if _libraries.has(key):
		library = _libraries[key]
	else:
		var path := path_for(key)
		# Each world its own copy (forget()): never the instance a freed world's players held.
		library = ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as AnimationLibrary if ResourceLoader.exists(path) else null
		if library != null and int(library.get_meta("version", 0)) != VERSION:
			push_warning("[crowd] baked gaits %s are version %d, want %d: rebake with tools/bake_pony_gaits.gd" %
				[path, int(library.get_meta("version", 0)), VERSION])
			library = null
		elif library == null:
			push_warning("[crowd] no baked gaits for skeleton layout %s (%s): its ponies stay on the full solver; bake with tools/bake_pony_gaits.gd" %
				[key, source_path])
		if library != null:
			# In memory only: the footfall table (pony_hoof_plants.gd) is keyed by layout.
			library.set_meta(&"layout_key", key)
		_libraries[key] = library
	if library == null:
		return null
	if base_path(player, skeleton) != String(library.get_meta("base_path", "")):
		push_warning("[crowd] baked gaits %s address %s, this model's skeleton is at %s" %
			[key, library.get_meta("base_path", ""), base_path(player, skeleton)])
		return null
	if not player.has_animation_library(LIBRARY):
		player.add_animation_library(LIBRARY, library)
	return library


## World speed (m/s at body scale 1) the clip was baked at.
static func speed(library: AnimationLibrary, gait: String) -> float:
	return float((library.get_meta("speeds", {}) as Dictionary).get(gait, 1.0))
