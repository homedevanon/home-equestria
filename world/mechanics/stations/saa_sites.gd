extends Node
## Places the Sweet Apple Acres stations (P5 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, 8.2-8.5)
## once the farm dressing (world/props/ponyville/farm_dressing.gd, group "apple_orchards") has built
## its orchard: Anon's row (planting_plot.gd), the cider press (cider_press.gd) and the cider stand
## (world/mechanics/jobs/cider_stand.gd), all parented to the farm dressing. Created by the hub
## (mechanics.gd setup); checks every 2 s until the farm is ready, then stops. Roster labs and
## fixtures without a farm never place anything.
const PLOT := preload("res://world/mechanics/stations/planting_plot.gd")
const PRESS := preload("res://world/mechanics/stations/cider_press.gd")
const STAND := preload("res://world/mechanics/jobs/cider_stand.gd")
## The press stands beside the farm's cider barrels, between the barn and the Apple family house.
const PRESS_AT := Vector3(42.5, 0.0, -447.0)
const CHECK := 2.0
var hub: Node
var plot: Node3D
var press: Node3D
var stand: Node3D
var _timer: Timer

func _ready() -> void:
	name = "SweetAppleAcresSites"
	_timer = Timer.new(); _timer.wait_time = CHECK; _timer.autostart = true
	_timer.timeout.connect(check)
	add_child(_timer)

## Places the nodes under a built farm. True once placed (then the check stops).
func check() -> bool:
	if is_instance_valid(plot): return true
	if not is_inside_tree() or not is_instance_valid(hub): return false
	var farm: Node3D = get_tree().get_first_node_in_group("apple_orchards") as Node3D
	if farm == null or not bool(farm.get("_built")): return false
	place(farm)
	if is_instance_valid(_timer): _timer.stop()
	return true

func place(farm: Node3D) -> void:
	var game: Node = hub.get("game")
	plot = PLOT.new()
	plot.game = game; plot.stations = hub.get("stations"); plot.facts = hub.get("facts"); plot.farm = farm
	farm.add_child(plot)
	press = PRESS.new()
	press.game = game; press.stations = hub.get("stations")
	farm.add_child(press)
	var at: Vector3 = farm.call("_ground", PRESS_AT) if farm.has_method("_ground") else PRESS_AT
	press.global_position = at if at.is_finite() else PRESS_AT
	stand = STAND.new()
	stand.game = game; stand.jobs = hub.get("jobs"); stand.stations = hub.get("stations"); stand.asks = hub.get("asks"); stand.facts = hub.get("facts")
	farm.add_child(stand)
