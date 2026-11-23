extends "res://world/terrain/world_terrain.gd"
func height_at(point: Vector3) -> float:
	return NAN if floori(point.x) in [2, 10] else 0.0

func normal_at(_point: Vector3) -> Vector3:
	return Vector3.UP
