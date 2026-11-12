extends Node3D
## The briefcase look of a snowman part item (coal, stick): one mesh from
## world/props/seasons/snowman_parts.glb (Blender MCP) with the shared vertex-colour material.
## Item rows: world/seasons/data/snow_items.json.
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
@export var part := "Coal"
## The look scaled up for the hand (a lump of coal is tiny).
@export var display_scale := 1.0

func _ready() -> void:
	if get_node_or_null("Mesh") != null: return
	var mesh := FX.instance(part)
	mesh.name = "Mesh"
	mesh.scale *= display_scale
	add_child(mesh)
