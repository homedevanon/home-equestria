extends RefCounted
## The public easel on Balloon Hill (docs/PAINTING_STATION_2026_10_22.md section 7): beside the
## picnic tables, the painter facing over the canvas down to the market tents. Loaded once by
## world/game_town_adapters.gd through load(), so a broken painting script never stops the game.
## The pose is a constant measured once in tools/painting/painting_station_review.gd: no runtime
## raycast, no retry.
const BUILD := preload("res://world/painting/easel_build.gd")
const KEY := "station:balloon-hill"
## Easel origin on the ground; +Z (where the painter stands) faces away from the market.
## Measured 2026-10-22: the first spot (266, -281) sits on a 21 cm slope, so the lab moved it
## 4.5 m along the hill edge to flat, clear ground beside the picnic table.
const POSE := Transform3D(Basis(Vector3.UP, 2.5113), Vector3(266.0, 6.781, -285.5))

static func attach(town: Node) -> void:
	if not town is Node3D or not town.is_inside_tree() or town.get_node_or_null("PaintingStation") != null: return
	var station := Node3D.new(); station.name = "PaintingStation"
	town.add_child(station)
	station.global_transform = POSE
	var easel: Node3D = BUILD.build(station, KEY, false)
	if easel == null: return
	# The easel's own frame stops walkers; the PaintPanel covers canvas, tray and hooks. The
	# frame stays out of the space in front of the canvas, the wells and the hooks, so the desktop
	# ray finds the PaintPanel and ponies in front can see the picture.
	var frame := StaticBody3D.new(); frame.name = "Frame"
	frame.collision_layer = 1; frame.collision_mask = 0
	for part: Array in frame_parts(easel):
		var shape := BoxShape3D.new(); shape.size = part[1]
		var holder := CollisionShape3D.new(); holder.name = str(part[0]); holder.shape = shape; holder.transform = part[2]
		frame.add_child(holder)
	frame.set_meta("painting_easel", easel.get_node("Wake"))
	station.add_child(frame)
	# Shopkeepers who buy finished paintings (art_buyer.gd, M-ACT-03): one node per town, a 1 Hz
	# check that stops at once while Anon holds no painting.
	var buyer: Script = load("res://world/painting/art_buyer.gd") as Script
	if buyer != null and buyer.can_instantiate() and town.get_node_or_null("ArtBuyers") == null: town.add_child(buyer.new())

## [name, size, transform] boxes in easel space: the legs below the hanging tools, and the mast
## behind the canvas back, tilted with the canvas (its mount's axes).
static func frame_parts(easel: Node) -> Array:
	var parts: Array = [["Legs", Vector3(0.83, 0.6, 0.675), Transform3D(Basis.IDENTITY, Vector3(0, 0.3, -0.3075))]]
	var mount := BUILD.marker(easel, "CanvasMountP")
	if mount != null:
		var at := BUILD.local_of(easel, mount).orthonormalized()
		# Mount space: the face is z = 0, the canvas back z = -0.018, the mast centre z = -0.085.
		at.origin += at.basis * Vector3(0, -0.19, -0.085)
		parts.append(["Mast", Vector3(0.06, 1.32, 0.07), at])
	return parts
