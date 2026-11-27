extends Node3D
## Door wear (dev 2026-11-18: worn ground where everypony walks in and out, so houses look lived in
## and joined to the land). For the houses near the camera, a patch of worn, bare earth on the
## ground in front of the front door: narrow at the sill, fanning out and fading into the grass.
## Decal nodes (albedo only): projected in the world, so the headset sees them like any other
## ground; nothing is drawn on the screen, so it works in VR.
## Snow buries the patch (it fades out with season_state snow_cover()); rain darkens it (wetness()).
## The texture is built in code once (no asset file).
##
## Trial: off unless the game is started with the user argument --look-door-wear=on.
## Cost: a 0.5 Hz step that re-picks the nearest houses; a fixed pool of POOL decals, hidden when
## unused; one shared 128x128 RGBA8 texture. Each house's interior node is looked up once and cached.
## Limits: the front door is the HouseInterior doorway (the one travel portal); houses without an
## interior node get no patch. The box is BOX_HEIGHT_M tall around the terrain height at the patch
## centre, so a steep slope can clip the far end. Decals reach every visual layer: a pony standing
## on the patch gets the dirt on its lower legs where they face up (normal_fade keeps it off
## vertical faces).
## Rollback: start without the argument (the node then creates nothing), or POOL = 0.

const PLAYER_VIEW := preload("res://world/player_view.gd")
const STEP := 2.0
const POOL := 16
const RANGE := 70.0
## How far the patch runs out from the door, in metres.
const LENGTH_M := 3.2
## Patch width = max(MIN_WIDTH_M, door width in metres * WIDTH_PER_DOOR).
const MIN_WIDTH_M := 1.7
const WIDTH_PER_DOOR := 1.7
## The patch begins this far outside the doorway, so the sill is left alone.
const START_M := 0.25
const BOX_HEIGHT_M := 1.0
const TEXTURE_SIZE := 128
const NOISE_SEED := 20261118
## No authored bare-earth colour constant exists in world/terrain or world/biomes: the trodden
## ground is the texture layers town_dirt / dirt_trail (world/terrain/textures.json ids 4 and 1,
## textures_gen/pv_town_dirt.png and pv_dirt_trail.png, average sRGB about (0.69, 0.61, 0.36)
## and (0.68, 0.58, 0.35) before terrain lighting). The patch takes the town dirt's average, so a
## doorstep reads as the same earth as the town's paths. Whether the decal shows it at the same
## brightness as the terrain does is unverified by render.
const DIRT_COLOR := Color(0.69, 0.61, 0.36)
## Colour multiplier at full wetness.
const WET_DARKEN := 0.72
## Decal opacity with no snow.
const STRENGTH := 0.55
const NORMAL_FADE := 0.5
## Godot's Decal maps its texture over the box's local X (u) and local Z (v), v growing with +Z,
## projecting along local -Y. The decal's +Z points away from the door, so row 0 of the texture is
## the door end. Unverified by render: if the patch fans toward the door, set FLIP_V = true.
const FLIP_V := false

static var enabled: bool = "--look-door-wear=on" in OS.get_cmdline_user_args() or "--look-door-wear=on" in OS.get_cmdline_args()

var _decals: Array[Decal] = []
var _timer := 0.0
var _report := ""
## house instance id -> its interior Node3D, found once.
var _interiors: Dictionary = {}
## house instance id -> steps left before a house found without an interior is searched again.
var _misses: Dictionary = {}
## Steps between searches of a house that had no interior (15 steps = 30 s).
const MISS_RETRY := 15


func _ready() -> void:
	if not enabled:
		set_process(false)
		return
	var texture := _build_texture()
	for i in POOL:
		var decal := Decal.new()
		decal.texture_albedo = texture
		decal.albedo_mix = 1.0
		decal.emission_energy = 0.0
		decal.upper_fade = 0.4; decal.lower_fade = 0.4
		decal.normal_fade = NORMAL_FADE
		decal.distance_fade_enabled = true
		decal.distance_fade_begin = RANGE * 0.7; decal.distance_fade_length = RANGE * 0.3
		decal.visible = false
		add_child(decal)
		_decals.append(decal)


## White texels; alpha is the wear: strong at the door (row 0), narrow there and fanning out,
## broken up by noise so the edge is ragged, gone at the far end.
static func _build_texture() -> ImageTexture:
	var image := Image.create_empty(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = NOISE_SEED
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.045
	var last := float(TEXTURE_SIZE - 1)
	for row in TEXTURE_SIZE:
		var t := float(TEXTURE_SIZE - 1 - row if FLIP_V else row) / last
		var along := 1.0 - smoothstep(0.15, 1.0, t)
		var half := lerpf(0.55, 0.95, t)
		for column in TEXTURE_SIZE:
			var u := float(column) / last * 2.0 - 1.0
			var across := 1.0 - smoothstep(half * 0.45, half, absf(u))
			var n := noise.get_noise_2d(float(column), float(row)) * 0.5 + 0.5
			var raw := along * across * clampf(0.55 + 0.9 * n, 0.0, 1.0)
			image.set_pixel(column, row, Color(1.0, 1.0, 1.0, smoothstep(0.16, 0.58, raw)))
	return ImageTexture.create_from_image(image)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0: return
	_timer = STEP
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	var snow := 0.0
	var wet := 0.0
	var season: Node = get_tree().get_first_node_in_group("season_state")
	if is_instance_valid(season):
		if season.has_method("snow_cover"): snow = float(season.call("snow_cover"))
		if season.has_method("wetness"): wet = float(season.call("wetness"))
	var strength := STRENGTH * (1.0 - clampf(snow, 0.0, 1.0))
	if strength < 0.02:
		_log(0, 0, snow)
		for decal in _decals: decal.visible = false
		return
	var colour := DIRT_COLOR * lerpf(1.0, WET_DARKEN, clampf(wet, 0.0, 1.0))
	# Every house in range, lit or not, nearest first.
	var near: Array = []
	for glow: Node in get_tree().get_nodes_in_group("window_glow"):
		var houses: Variant = glow.get("_houses")
		if not houses is Array: continue
		for entry: Variant in houses:
			var house := entry as Node3D
			if not is_instance_valid(house) or not house.is_inside_tree(): continue
			var d := house.global_position.distance_to(eye)
			if d > RANGE: continue
			near.append([d, house])
	near.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	_forget_gone()
	var used := 0
	for row: Array in near:
		if used >= _decals.size(): break
		var house: Node3D = row[1]
		var interior := _interior_of(house)
		if interior == null: continue
		var doorway_value: Variant = interior.get("doorway")
		if not doorway_value is Vector3: continue
		var doorway: Vector3 = doorway_value
		var width_value: Variant = interior.get("door_width")
		var door_width: float = float(width_value) if (width_value is float or width_value is int) else 0.12
		var to_world := interior.global_transform
		# In interior space the house lies toward -Z of the doorway (house_interior.gd inside()).
		var outward := to_world.basis * Vector3(0.0, 0.0, 1.0)
		outward.y = 0.0
		if outward.length_squared() < 0.0001: continue
		outward = outward.normalized()
		var door_m := door_width * to_world.basis.get_scale().x
		var width_m := maxf(MIN_WIDTH_M, door_m * WIDTH_PER_DOOR)
		var door_world := interior.to_global(doorway)
		var at := door_world + outward * (START_M + LENGTH_M * 0.5)
		if is_instance_valid(WorldTerrain.instance):
			var ground: float = WorldTerrain.instance.height_at(at)
			if is_finite(ground): at.y = ground
		var decal := _decals[used]
		used += 1
		# Projects down its own -Y; its +Z (texture v) runs away from the door.
		decal.global_transform = Transform3D(Basis(Vector3.UP.cross(outward).normalized(), Vector3.UP, outward), at)
		decal.size = Vector3(width_m, BOX_HEIGHT_M, LENGTH_M)
		decal.modulate = Color(colour.r, colour.g, colour.b, strength)
		decal.visible = true
	for i in range(used, _decals.size()):
		_decals[i].visible = false
	_log(near.size(), used, snow)


func _log(houses: int, shown: int, snow: float) -> void:
	var report := "[door_wear] houses=%d shown=%d snow=%.2f" % [houses, shown, snow]
	if report != _report:
		_report = report
		print(report)


## The house's interior node: its "HouseInterior" child, else the first descendant in group
## "house_interiors". Found ones are cached; a miss is searched again next step (interiors of
## some buildings are added at runtime).
func _interior_of(house: Node3D) -> Node3D:
	var id := house.get_instance_id()
	if _interiors.has(id):
		var cached: Variant = _interiors[id]
		if is_instance_valid(cached): return cached as Node3D
		_interiors.erase(id)
	# A house that had none is searched again only every MISS_RETRY steps: walking its whole
	# subtree every step would cost more than the patch is worth.
	var wait: int = int(_misses.get(id, 0))
	if wait > 0:
		_misses[id] = wait - 1
		return null
	var interior := house.get_node_or_null("HouseInterior") as Node3D
	if interior == null:
		var queue: Array[Node] = [house]
		while not queue.is_empty() and interior == null:
			var node: Node = queue.pop_front()
			for child: Node in node.get_children():
				if child.is_in_group("house_interiors") and child is Node3D:
					interior = child as Node3D
					break
				queue.append(child)
	if interior != null:
		_interiors[id] = interior
		_misses.erase(id)
	else:
		_misses[id] = MISS_RETRY
	return interior


## Drops cache entries whose house or interior is gone.
func _forget_gone() -> void:
	for id: Variant in _interiors.keys():
		if not is_instance_id_valid(int(id)) or not is_instance_valid(_interiors[id]):
			_interiors.erase(id)
	for id: Variant in _misses.keys():
		if not is_instance_id_valid(int(id)): _misses.erase(id)
