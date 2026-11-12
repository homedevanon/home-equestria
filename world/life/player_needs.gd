extends Node
## Optional shared meals and cider effects. Eating is never required.
const CATALOG := preload("res://world/food/food_catalog.gd")
const SOBER_PER_HOUR := 7.5
const PASS_OUT_DRUNK := 4.0
const ALCOHOL := {"food:sweet-apple-acres-cider": 1.0}
var game: Node
var drunk := 0.0
var _last_clock := -1.0
var _sway_time := 0.0
var _fainting := false

func setup(host: Node) -> void:
	game = host
	add_to_group("player_needs")

## Autoloads live as long as the tree: looked up once, not by path every physics tick.
var _clock_node: Node
var _settings_node: Node

func _clock_hours() -> float:
	if not is_instance_valid(_clock_node): _clock_node = get_node_or_null("/root/TimeOfDay")
	var clock := _clock_node
	return float(clock.day) * 24.0 + float(clock.hours) if clock != null else 0.0

func _physics_process(delta: float) -> void:
	if game == null or not is_instance_valid(game.get("player")): return
	var now := _clock_hours()
	var hours := now - _last_clock if _last_clock >= 0.0 else 0.0
	_last_clock = now
	# Big jumps (sleep, loading, debug time) are settled by whoever made them (pass_time).
	if hours < 0.0 or hours > 1.0: hours = 0.0
	var busy: bool = game.get("title_active") == true or game.get_node_or_null("LoadingCover") != null
	if not busy: pass_time(hours)
	_apply(delta)

## Cider wears off as game time passes, including sleep.
func pass_time(hours: float) -> void:
	if hours <= 0.0: return
	drunk = maxf(0.0, drunk - SOBER_PER_HOUR * hours)

## Called by the eating paths (world/food/food_interaction.gd, briefcase_inventory.gd).
func ate(id: String) -> void:
	var entry: Dictionary = CATALOG.definition(id) if CATALOG.has(id) else {}
	drunk += float(entry.get("alcohol", ALCOHOL.get(id, 0.0)))
	if drunk >= PASS_OUT_DRUNK: _faint("Too much cider. You wake up at home, head pounding.")
	print("[needs] ate %s: cider %.1f" % [id, drunk])
	_shared_meal()

## Eating with ponies around counts as a meal together for each grown-up within a few metres
## (relationship_runtime.shared_activity; its own cooldown keeps it to one per meal).
func _shared_meal() -> void:
	var runtime: Node = game.get("relationship_runtime")
	var camera: Camera3D = game._find_camera(game.player)
	if not is_instance_valid(runtime) or camera == null: return
	var company: Array = []
	for pony: Variant in game.mares:
		if not is_instance_valid(pony) or (pony as Node3D).global_position.distance_to(camera.global_position) > 4.0: continue
		var identity: Resource = pony.get("identity")
		if identity == null or bool(identity.get("filly")) or bool(pony.get("sleeping")): continue
		company.append(str(identity.id))
	if not company.is_empty():
		runtime.shared_activity("meal", camera.global_position, "meal_%d" % int(Time.get_unix_time_from_system() / 600.0), company)

func _faint(message: String) -> void:
	if _fainting: return
	var sleep: Node = get_tree().get_first_node_in_group("player_sleep")
	if sleep == null or sleep.sleeping: return
	_fainting = true
	await sleep.faint(message)
	_fainting = false

## The sleep transition settles recovery before its waking checkpoint is written.
func recover_from_faint() -> void:
	drunk = 0.0

## Cider sway and drift on whichever rig is live.
func _apply(delta: float) -> void:
	var body: Node = game.player.get_node("Body") if game.xr_active else game.player
	_sway_time += delta
	var level := clampf(drunk / PASS_OUT_DRUNK, 0.0, 1.0)
	# Walking drifts: a slow wandering sideways pull while moving.
	# Perf 0.1.0: sober (level 0) every value below is zero or unchanged, so a write is made only
	# when it differs (a rotation write re-sends the camera's transform to its whole subtree).
	if "drunk_drift" in body:
		var wander := Vector3(sin(_sway_time * 0.9) + 0.5 * sin(_sway_time * 2.3), 0.0, cos(_sway_time * 0.7) * 0.6)
		var drift := wander * level * 1.4
		if body.drunk_drift != drift: body.drunk_drift = drift
	# Desktop view: a gentle roll and wobble (never in the headset: comfort).
	if not game.xr_active:
		var camera: Camera3D = game._find_camera(game.player)
		if camera != null:
			var roll := sin(_sway_time * 1.3) * 0.06 * level
			if camera.rotation.z != roll: camera.rotation.z = roll
			if not is_instance_valid(_settings_node): _settings_node = get_node("/root/Settings")
			var base := float(_settings_node.get_value("controls/fov"))
			if level > 0.001 or absf(camera.fov - base) > 0.05:
				camera.fov = lerpf(camera.fov, base + sin(_sway_time * 0.8) * 4.0 * level, 0.1)

func snapshot() -> Dictionary:
	return {"drunk": drunk}

func restore(value: Variant) -> void:
	if not value is Dictionary: return
	# Old saves can contain hunger; it is deliberately ignored.
	drunk = clampf(float(value.get("drunk", 0.0)), 0.0, PASS_OUT_DRUNK)
