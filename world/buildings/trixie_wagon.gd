extends Node3D
## Trixie's wagon as her home: expanded 1.5x (dev, 2026-10-07), with the
## wider bunk and galley against its new walls. The door panel is cut out
## of the mesh, the walls collide two-sided from the wagon's own triangles, a ramp climbs to
## the door sill, and one small bed stands against the back wall. The HouseInterior is
## reserved for Trixie (pony_population assigns it to nopony else).
## Model units: door at -Z (steps), shafts at +Z, floor top ~0.88, ceiling ~3.15.
const MESH := preload("res://world/props/rnl/rnl_trixie_wagon/mesh_0.res")
const BUNK_PATH := "res://world/props/household/trixie-wide-bunk.scn"
class WagonHome extends "res://world/buildings/authored_home.gd":
	# Preserve the existing save identity when the expanded wagon shifts on its lot.
	func _init() -> void: home_kind = "wagon"

const EXPANSION := 1.5
const SCALE := 1.1 * EXPANSION
## Wall-mounted furniture stays metre-sized; translate it with the enlarged wall.
const BUNK_SHIFT := Vector3(.431, 0, .67)
const BUNK_SIZE := Vector3(1.20, .075, 2.15)
const BUNK_FRAME := Vector3(.70 * 1.20 / .67, .13, 1.78 * 2.15 / 1.74)
# Hold the wall-facing and head edges fixed while growing into the clear aisle.
const BUNK_GROW_SHIFT := Vector3(-(BUNK_FRAME.x - .70) * .5, 0, -(BUNK_FRAME.z - 1.78) * .5)
## A 1.281m shift and 10-degree turn clear the fair tent without terrain changes.
## Native wheel support, ramp and drawn neighbor geometry: test_trixie_placed.gd.
const SPOT := Vector3(316.8, 3.815, -229.0)
const YAW := 5.93453292519943
const FLOOR := 0.88
const DOOR := AABB(Vector3(-0.475, 0.89, -1.80), Vector3(0.95, 1.83, 0.24))
## The doorknob (inside and outside halves) pokes past DOOR's faces, so the cut left it floating in
## the empty doorway (player board #53, 2026-11-08). Its own two separate pieces lie in this box.
const KNOB := AABB(Vector3(-0.50, 1.57, -1.815), Vector3(0.11, 0.11, 0.28))
const INSIDE := Rect2(-0.85, -1.68, 1.70, 2.98)   # x, z of the interior floor (model units)
const OWNER := "trixie"
var ramp_toe_y := 0.0

func _ready() -> void:
	name = "TrixieWagon"
	var ground := SPOT.y
	if is_instance_valid(WorldTerrain.instance):
		var h: float = WorldTerrain.instance.height_at(SPOT)
		if is_finite(h): ground = h
	global_transform = Transform3D(Basis(Vector3.UP, YAW), Vector3(SPOT.x, ground, SPOT.z))
	_retire_scenery_wagon()
	var model := Node3D.new(); model.name = "Model"; model.scale = Vector3.ONE * SCALE; add_child(model)
	var mesh := _without_door()
	var view := MeshInstance3D.new(); view.name = "Exterior"; view.mesh = mesh; model.add_child(view)
	# Seen from inside too: the source faces are one-sided.
	for s in mesh.get_surface_count():
		var material: BaseMaterial3D = mesh.surface_get_material(s).duplicate()
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		view.set_surface_override_material(s, material)
	var shape := mesh.create_trimesh_shape(); shape.backface_collision = true
	var body := StaticBody3D.new(); body.name = "Walls"; body.collision_mask = 0
	var holder := CollisionShape3D.new(); holder.shape = shape; body.add_child(holder); model.add_child(body)
	# Match the actual terrain at the widened toe, while keeping the floor and
	# accepted steps fixed. Sampling once adds no per-frame terrain work.
	if is_instance_valid(WorldTerrain.instance):
		var lowest := INF
		for x: float in [-.45,0,.45]:
			var at := to_global(Vector3(x,0,-3.9)*SCALE)
			var height: float = WorldTerrain.instance.height_at(at)
			if is_finite(height): lowest=minf(lowest,height)
		if is_finite(lowest): ramp_toe_y=(lowest-global_position.y)/SCALE
	# Up to the sill over the steps: a pony climbs a slope, not the 0.9 m step.
	var ramp := preload("res://world/buildings/stair_brush.gd").build({"center_x": 0.0, "width": 0.9,
		"back_z": DOOR.position.z + DOOR.size.z, "landing_z": -1.95, "toe_z": -3.9, "height": FLOOR, "toe_y": ramp_toe_y})
	model.add_child(ramp)
	# Collision only: the wagon's own steps are what you see.
	for part: MeshInstance3D in ramp.find_children("*", "MeshInstance3D", true, false): part.visible = false
	var door := Node.new(); door.name = "FrontDoor"; door.set_script(preload("res://world/buildings/open_doorway.gd")); add_child(door)
	_add_home()

## The scenery bake still carries the old, half-sunken wagon: this one replaces it.
func _retire_scenery_wagon() -> void:
	var town := get_parent()
	var old := town.find_child("trixie_wagon_01", true, false) if town != null else null
	if old != null: old.queue_free()

func _without_door() -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in MESH.get_surface_count():
		var arrays := MESH.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array()
		for i in range(0, index.size(), 3):
			var c := (v[index[i]] + v[index[i + 1]] + v[index[i + 2]]) / 3.0
			if DOOR.has_point(c) or KNOB.has_point(c): continue
			kept.append_array([index[i], index[i + 1], index[i + 2]])
		arrays[Mesh.ARRAY_INDEX] = kept
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, MESH.surface_get_material(s))
	return out

## House space in the houses' convention: its own +Z toward the door, one unit = 0.1 m.
func _add_home() -> void:
	var home: Node3D = WagonHome.new(); home.name = "HouseInterior"; home.furnish = false
	home.transform = Transform3D(Basis(Vector3.UP, PI).scaled(Vector3.ONE * 10.0), Vector3.ZERO)
	var k := SCALE / 10.0
	home.floor_y = FLOOR * k
	home.floors.append(Rect2(-(INSIDE.end.x) * k, -(INSIDE.end.y) * k, INSIDE.size.x * k, INSIDE.size.y * k))
	home.doorway = Vector3(0.0, FLOOR * k, -INSIDE.position.y * k)
	home.door_width = DOOR.size.x * k
	home.approach = Vector3(0.0, 0.0, 4.1 * k)
	if is_instance_valid(WorldTerrain.instance):
		var outside := to_global(Vector3(0,0,-4.1)*SCALE)
		var ground: float = WorldTerrain.instance.height_at(outside)
		if is_finite(ground): home.approach.y=(ground-global_position.y)/10.0
	home.set_meta("reserved_for", OWNER)
	# Her bed first, so the houses' own placement never runs: pillows to the back wall.
	var bed: Node3D = (load(BUNK_PATH) as PackedScene).instantiate(); bed.name = "Bed"
	bed.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(.52, FLOOR * SCALE, .35) + BUNK_SHIFT + BUNK_GROW_SHIFT)
	# Add collision in metres before entering the tree; no inherited 10x house scale.
	var bed_body: StaticBody3D = StaticBody3D.new(); bed_body.collision_mask = 0
	var bed_shape: BoxShape3D = BoxShape3D.new(); bed_shape.size = BUNK_FRAME
	var bed_collider: CollisionShape3D = CollisionShape3D.new(); bed_collider.shape = bed_shape
	bed_collider.position.y = .4725; bed_body.add_child(bed_collider); bed.add_child(bed_body)
	add_child(bed)
	bed.set_meta("mattress_top", .5585)
	bed.set_meta("bed_size", BUNK_SIZE)
	bed.set_meta("side_local", Vector3(BUNK_SIZE.x * .5 + .25,0,0))
	bed.set_meta("house", home); bed.set_meta("slot", "wagon_wall")
	home.bed = bed
	add_child(home)
	_add_galley(home)
	_add_clutter(home)

func label() -> String: return "Trixie's wagon"

## Compact side-wall kitchen. Metre-sized prop inside the house's 10x convention.
## Stops before the bed's foot and leaves the centre aisle and front doorway free.
func _add_galley(home:Node3D) -> void:
	var galley:StaticBody3D=StaticBody3D.new();galley.name="WagonGalley"
	galley.collision_layer=1;galley.collision_mask=0
	home.add_child(galley)
	galley.global_transform=global_transform*Transform3D(Basis(Vector3.UP,PI*.5),Vector3(-.655 - BUNK_SHIFT.x,FLOOR*SCALE,-.65 * EXPANSION))
	galley.add_child((load("res://world/props/household/wagon-galley.scn") as PackedScene).instantiate())
	var box:BoxShape3D=BoxShape3D.new();box.size=Vector3(.84,.79,.43)
	var collider:CollisionShape3D=CollisionShape3D.new();collider.shape=box;collider.position=Vector3(0,.395,.015);galley.add_child(collider)
	galley.add_to_group("house_furniture");galley.set_meta("furniture","wagon-galley");galley.set_meta("kitchen",true)

func _add_clutter(home: Node3D) -> void:
	var clutter: Node3D = (load("res://world/props/household/trixie-wagon-clutter-roomy.scn") as PackedScene).instantiate()
	clutter.name = "ShelvesAndStageProps"; clutter.position.y = FLOOR * SCALE; add_child(clutter)
	clutter.add_to_group("house_furniture"); clutter.set_meta("house", home)
	# Actual furniture footprints; keep the central aisle and bunk approach open.
	var body: StaticBody3D = StaticBody3D.new(); body.collision_mask = 0; clutter.add_child(body)
	for spec: Array in [[Vector3(-.715,1.24,.73) * EXPANSION,Vector3(.31,2.23,1.10) * EXPANSION],
			# These cases move with the unchanged bunk; never grow through its mattress.
			[Vector3(.52,.20,.35) + BUNK_SHIFT,Vector3(.59,.40,1.62)],
			[Vector3(.72,1.62,.42) * EXPANSION,Vector3(.29,.08,1.82) * EXPANSION],
			[Vector3(.72,2.12,.42) * EXPANSION,Vector3(.29,.08,1.82) * EXPANSION],
			[Vector3(0,1.78,1.34) * EXPANSION,Vector3(1.67,.08,.19) * EXPANSION]]:
		var box: BoxShape3D = BoxShape3D.new(); box.size = spec[1]
		var collider: CollisionShape3D = CollisionShape3D.new(); collider.position = spec[0]; collider.shape = box
		body.add_child(collider)
