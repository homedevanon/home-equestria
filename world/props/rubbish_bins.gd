extends Node3D
## Places the two fixed rubbish bins (world/props/rubbish_bin.gd, player board card 69). Made once by
## the Ponyville scenery (world/shop/market_stalls.gd) as its child.
## - The market bin stands against the back of the produce kiosk, about two metres from the apple
##   bucket already there: out of the customer aisle in front of the stalls and clear of the tents.
## - The home bin stands beside Anon's front door, wherever his home is (the rule of
##   letter_courier.gd player_home), on the other side of the door path from his mailbox
##   (player_mailbox.gd stands that one OUT 2.6 m out and 1.5 m to the right).
## A slow timer (POLL seconds, no per-frame work) places a bin once its ground is known and moves the
## home bin when he moves house; a door with no ground near it (a cloud home) gets no bin.
const BIN := preload("res://world/props/rubbish_bin.gd")
## The produce kiosk (also world/navigation/place_directory.gd MARKET_STALL) and the bin's spot in
## its frame: its customers stand at -Z, its back wall is at +2.33 m, its west end at +2.33 m X.
const MARKET_ANCHOR := "Town/Market/kiosk_01_02"
const MARKET_SPOT := Vector3(1.4, 0.0, 2.6)
## From the front door step (house_interior.gd outside()): HOME_OUT metres away from the house and
## HOME_SIDE metres to its right (negative: left), clear of the doorway.
const HOME_OUT := 0.4
const HOME_SIDE := -1.4
## Metres the ground at a spot may lie below or above the door step or the kiosk.
const GROUND_STEP := 4.0
const POLL := 2.0
## Tests: a Callable(Vector3) -> float for the ground height instead of the terrain.
var ground_height: Callable
var market_bin: StaticBody3D
var home_bin: StaticBody3D
var _home: Node3D

func _ready() -> void:
	var timer := Timer.new()
	timer.name = "Poll"
	timer.wait_time = POLL
	timer.autostart = true
	timer.timeout.connect(refresh)
	add_child(timer)
	refresh.call_deferred()

## Places whatever bin is missing and follows Anon's home.
func refresh() -> void:
	if not is_inside_tree(): return
	if not is_instance_valid(market_bin): market_bin = _market()
	var home := player_home()
	if home != null and home == _home and is_instance_valid(home_bin): return
	if is_instance_valid(home_bin): home_bin.queue_free()
	home_bin = null
	_home = null
	if home == null: return
	home_bin = _at_home(home)
	if home_bin != null: _home = home

## Anon's house in the loaded world (the rule of letter_courier.gd player_home), or null.
func player_home() -> Node3D:
	for home: Node in get_tree().get_nodes_in_group("house_interiors"):
		if not home is Node3D or not home.is_inside_tree(): continue
		if str(home.get_meta("reserved_for", "")) == "player" or bool(home.get_meta("shared_player_home", false)): return home
	return null

func _market() -> StaticBody3D:
	var scenery := get_parent()
	var kiosk: Node3D = scenery.get_node_or_null(MARKET_ANCHOR) as Node3D if scenery != null else null
	if kiosk == null: return null
	var at: Vector3 = kiosk.to_global(MARKET_SPOT)
	var ground := _ground(at)
	if not is_finite(ground) or absf(ground - kiosk.global_position.y) > GROUND_STEP: return null
	at.y = ground
	var facing := Basis(Vector3.UP, kiosk.global_rotation.y)
	return _build("MarketRubbishBin", Transform3D(facing, at))

func _at_home(home: Node3D) -> StaticBody3D:
	if not home.has_method("outside"): return null
	var door: Vector3 = home.call("outside")
	var middle: Vector3 = home.call("center") if home.has_method("center") else home.global_position
	var out := Vector3(door.x - middle.x, 0.0, door.z - middle.z)
	if out.length_squared() < 0.01: return null
	out = out.normalized()
	var right := out.cross(Vector3.UP).normalized()
	var at := door + out * HOME_OUT + right * HOME_SIDE
	var ground := _ground(at)
	if not is_finite(ground) or absf(ground - door.y) > GROUND_STEP: return null
	at.y = ground
	return _build("HomeRubbishBin", Transform3D(Basis.looking_at(out, Vector3.UP), at))

func _ground(at: Vector3) -> float:
	if ground_height.is_valid(): return float(ground_height.call(at))
	if is_instance_valid(WorldTerrain.instance): return WorldTerrain.instance.height_at(at)
	return NAN

func _build(bin_name: String, at: Transform3D) -> StaticBody3D:
	var bin: StaticBody3D = BIN.new()
	bin.name = bin_name
	# Transform before add_child: a body keeps the scale it entered with (Jolt).
	bin.transform = global_transform.affine_inverse() * at
	add_child(bin)
	return bin
