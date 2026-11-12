extends Node
## The Mods autoload: runs each active mod's entry script and gives mods their hooks.
## world/modding/mod_loader.gd has already mounted the packs, merged JSON and extended scripts.
## An entry script is a Node; it is added as a child of this autoload, so `Mods` is its parent:
##   extends Node
##   func _ready() -> void:
##       Mods.on_node("res://world/characters/locomotion/pony_locomotion.gd", _on_pony)
##       Mods.world_ready.connect(func(game: Node) -> void: print(Mods.state("my_mod")))
## Mods can also reach anything in the scene tree directly; these are the stable shortcuts.

const LOADER := preload("res://world/modding/mod_loader.gd")
const GAME_SCRIPT := "res://world/game.gd"
const SHUTDOWN := preload("res://world/shutdown_waits.gd")

## A world is starting (world/game.gd, under the loading cover, after its save is restored and
## before the arrival story reads it): `is_new` for a brand-new world, which a running scenario mod
## has just stamped (world/modding/scenario.gd). world_context is open; the world is not loaded yet.
signal world_starting(game: Node, is_new: bool)
## A world finished loading (world/game.gd ready). `game` exposes player, world_context, etc.
signal world_ready(game: Node)
## The world is being left (back to the title or quitting).
signal world_closed(game: Node)
## The player body exists in the world (desktop or VR rig).
signal player_ready(player: Node)

var game: Node
var _watchers: Array = []   # [matcher: Variant, callback: Callable]


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	for mod: Dictionary in LOADER.active(): _start(mod)


## Settings → Mods switch (mod_loader.gd switch()). Starts or stops the pack's entry scripts now
## when it can; returns false when the change waits for the next launch. An entry started
## mid-game has missed world_ready and player_ready: it reads `Mods.game` in its _ready instead.
## A stopped entry is freed; its _exit_tree must undo what it changed in the world.
func switch(file: String, enabled: bool) -> bool:
	if not LOADER.switch(file, enabled): return false
	for mod: Dictionary in LOADER.mods:
		if mod.file != file: continue
		if enabled and mod.errors.is_empty(): _start(mod)
		elif not enabled: _stop(str(mod.id))
	return true

func _start(mod: Dictionary) -> void:
	if str(mod.entry).is_empty() or has_node(NodePath(str(mod.id))): return
	var script := load(str(mod.entry)) as Script
	var node: Variant = script.new() if script != null and script.can_instantiate() else null
	if not node is Node:
		push_warning("[mods] %s: entry %s is not a Node script" % [mod.id, mod.entry]); return
	(node as Node).name = str(mod.id)
	add_child(node)

func _stop(id: String) -> void:
	var node := get_node_or_null(NodePath(id))
	if node == null: return
	remove_child(node)
	node.queue_free()
	_watchers = _watchers.filter(func(watcher: Array) -> bool:
		var owner := (watcher[1] as Callable).get_object() as Node
		return owner == null or (owner != node and not node.is_ancestor_of(owner)))


## Every mod found this launch, loaded or not (Settings → Mods lists these).
func list() -> Array: return LOADER.mods.duplicate(true)

## Every mod pack seen this launch, with its switch (the loader's own rows; prefer pack_rows()).
func packs() -> Array: return LOADER.packs.duplicate(true)

## Every mod pack seen this launch in mount order, in a stable shape for mod managers and the Mods
## screen (world/modding/mod_loader.gd pack_rows()): {file, ids, title, author, version, bundled,
## default_on, enabled, mounted, switched_on, switchable, held, superseded_by, reason, warning, overrides,
## patches, patch_of, patched_by, update, update_url, game_version, error, covered}. `file` is what switch() takes;
## bundled mods are "bundled/<file>".
func pack_rows() -> Array[Dictionary]: return LOADER.pack_rows()

## The scenario of the scenario mod running this launch ({id, name, version, mod, start, skip_opening,
## initial_state, description}), {} when none (world/modding/scenario.gd active_scenario()).
func scenario() -> Dictionary: return preload("res://world/modding/scenario.gd").active_scenario()

func is_active(id: String) -> bool:
	return LOADER.active().any(func(mod: Dictionary) -> bool: return mod.id == id)

## Calls `callback(node)` for every node that matches, now and whenever one enters the tree,
## once it is ready. `matcher` is a script path (the node's script or any script it extends),
## "group:<name>", "class:<Godot class>", or a Callable(node) -> bool.
func on_node(matcher: Variant, callback: Callable) -> void:
	_watchers.append([matcher, callback])
	for node: Node in get_tree().root.find_children("*", "", true, false):
		if node.is_node_ready() and matches(node, matcher): callback.call(node)

static func matches(node: Node, matcher: Variant) -> bool:
	if matcher is Callable: return bool((matcher as Callable).call(node))
	var text := str(matcher)
	if text.begins_with("group:"): return node.is_in_group(text.substr(6))
	if text.begins_with("class:"): return node.is_class(text.substr(6))
	var script := node.get_script() as Script
	while script != null:
		if script.resource_path == text: return true
		script = script.get_base_script()
	return false

## This mod's section of the world save (a Dictionary kept with the world; empty before a world
## is loaded). Change it in place, then call save_changed().
func state(id: String) -> Dictionary:
	var context: Node = game.get("world_context") if is_instance_valid(game) else null
	if context == null: return {}
	if not context.state.get("mods") is Dictionary: context.state["mods"] = {}
	var all: Dictionary = context.state.mods
	if not all.get(id) is Dictionary: all[id] = {}
	return all[id]

## Marks the world save dirty so a mod's state() changes are written with the next autosave.
func save_changed() -> void:
	var context: Node = game.get("world_context") if is_instance_valid(game) else null
	if context != null and context.has_method("_changed"): context._changed()

## Folder for a mod's own files outside the world save (settings, caches): user://mods/data/<id>.
func data_folder(id: String) -> String:
	var folder := LOADER.USER_DIR.path_join("data").path_join(id)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	return folder


func _on_node_added(node: Node) -> void:
	# A node added, removed and added again before it is ready would be connected twice
	# (player board #41: "Signal 'ready' is already connected").
	if _is_game(node):
		var game_ready := _on_game_ready.bind(node)
		if not node.ready.is_connected(game_ready): node.ready.connect(game_ready, CONNECT_ONE_SHOT)
	if _watchers.is_empty(): return
	var check := _check_watchers.bind(node)
	if not node.ready.is_connected(check): node.ready.connect(check, CONNECT_ONE_SHOT)

func _check_watchers(node: Node) -> void:
	if not is_instance_valid(node): return
	for watcher: Array in _watchers:
		if (watcher[1] as Callable).is_valid() and matches(node, watcher[0]): (watcher[1] as Callable).call(node)

static func _is_game(node: Node) -> bool:
	var script := node.get_script() as Script
	return script != null and script.resource_path == GAME_SCRIPT

func _on_game_ready(node: Node) -> void:
	game = node
	node.tree_exiting.connect(func() -> void:
		world_closed.emit(node)
		if game == node: game = null, CONNECT_ONE_SHOT)
	world_ready.emit(node)
	# The player rig can arrive a few frames after the world; wait for it, briefly.
	for i in 600:
		if not is_instance_valid(node) or not node.is_inside_tree(): return
		var player: Variant = node.get("player")
		if player is Node and is_instance_valid(player):
			player_ready.emit(player); return
		if not await SHUTDOWN.frame(self): return
