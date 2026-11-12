extends Node3D
## A heap of snow dropped off a roof beside a house door (W2-SEAS-F, design 6.2 'Snow piles'):
## the snowball mesh flattened, no collision. Walking through it fast or touching it with a hand
## bursts it into a big puff (snow_play.gd checks the player against piles at 4 Hz); it comes
## back the next day while there is snow.
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
const SIZE := Vector3(0.75, 0.26, 0.55)

var key := ""
var burst_day := -1
var radius := SIZE.x

func _init() -> void:
	name = "SnowPile"
	var mesh := FX.instance("Snowball_LOD1")
	mesh.name = "Mesh"
	mesh.scale = SIZE / FX.MODEL_RADIUS
	mesh.position = Vector3(0, SIZE.y * 0.35, 0)
	mesh.visibility_range_end = 70.0
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)

func intact() -> bool: return visible

## Bursts into a puff with a real snow sample; hidden until `day` has passed.
func burst(day: int, level := 2) -> void:
	if not visible: return
	visible = false
	burst_day = day
	var at := global_position + Vector3.UP * SIZE.y * 0.5
	FX.puff(get_parent() if get_parent() != null else self, at, 2.2, level)
	FX.sound(self, "snow_play_burst", at)
