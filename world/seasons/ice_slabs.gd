extends Node
## Frozen water you can walk on, and rain on the water (W2-SEAS-G, 2026-11-08; design
## captures/overhaul-2026-11-08/seasons/AUDIT_AND_DESIGN.md 6.2 "Frozen water" and 6.5).
## Child "IceSlabs" of SeasonState (instantiated from season_state.gd FEATURES).
##
## - Still water (WorldWater.still_water: the lake discs and the Ponyville canals) freezes when
##   season ice x climate A (ice allowed) at its centre rises above FREEZE_AT: a thin StaticBody3D
##   slab, group GROUP, on collision layer 1 (the ground the player and ponies stand on), lies
##   LIFT above the water mesh, and the material's `ice_solid` makes the ice sheet whole. It is
##   removed again only below THAW_BELOW (hysteresis). Swimming reads only the water layer from
##   above the feet, so feet on a slab never count as in the water.
## - Rivers never get a slab: toon_water.gdshader draws an ice rim at their banks (shader only).
## - Every WorldWater material gets `rain_amount` (weather params.rain) for the ripple rings, and
##   `ice_detail` from Quality "water_ice_look" (flat on the Quest tier).
## Physical ice stays at every Seasonal effects level (design 6.9: physical things are gameplay).
## No per-frame work: a 2 Hz timer, and material/physics writes only when something changes.

const GROUP := "ice_slab"
const FREEZE_AT := 0.6
const THAW_BELOW := 0.5
## Slab top above the still water mesh (the frozen sheet itself lies flat at the mesh).
const LIFT := 0.03
## Thickness of the lake disc slab (canal slabs are a one-surface copy of the canal mesh).
const THICKNESS := 0.4
const GROUND_LAYER := 1
const WATER_LAYER := 1 << 15
const TICK := 0.5
const RAIN_STEP := 0.02
const WORLD_WATER := preload("res://world/water/world_water.gd")

var season_state: Node
## Tests: no timer, and fixed ice / rain levels instead of season_state and weather.
var auto_tick := true
var ice_override := -1.0
var rain_override := -1.0
## Tests: a water node to use instead of WorldWater.instance.
var water_override: Node

var _water: Node
## One entry per still water mesh: {"mesh", "material", "xz", "slab", "frozen"}.
var _still: Array[Dictionary] = []
var _shapes: Dictionary = {}     # mesh instance id -> its slab Shape3D, kept for the next winter
var _rain := -1.0
var _detail := -1.0
var _ripples := true
var _timer: Timer


## The node's own group: ground_contact_audio.gd ICE_GROUP looks for "ice_slabs" on a footstep's
## collider and up to three parents (the slab bodies are its children), and season_world.gd finds
## this node by it. The bodies keep their own "ice_slab" group (W2-SEAS-J hook, W3).
const NODE_GROUP := "ice_slabs"

func setup(state: Node) -> void:
	season_state = state
	add_to_group(NODE_GROUP)
	var quality := get_node_or_null("/root/Quality")
	if quality != null and quality.has_signal("preset_changed") and not quality.is_connected("preset_changed", _on_quality_changed):
		quality.connect("preset_changed", _on_quality_changed)
	if auto_tick and _timer == null:
		_timer = Timer.new(); _timer.name = "IceTick"; _timer.wait_time = TICK; _timer.autostart = true
		_timer.timeout.connect(tick)
		add_child(_timer)
	tick()


func tick() -> void:
	if not _bind_water(): return
	var ice := ice_override if ice_override >= 0.0 else _season_ice()
	for entry: Dictionary in _still:
		_update_still(entry, ice)
	_update_rain()


## The slabs lying on the water now (tests, W2-SEAS-J footsteps use the group instead).
func slabs() -> Array[StaticBody3D]:
	var out: Array[StaticBody3D] = []
	for entry: Dictionary in _still:
		var slab: Variant = entry.get("slab")
		if slab is StaticBody3D and is_instance_valid(slab): out.append(slab)
	return out


## Points on top of the ice to stand or skate on, a few per frozen water (W2-SEAS-H skating reads
## this through season_world.ice_points). Lake: the centre and two rings; canals: spread centroids.
func slab_points() -> Array:
	var out: Array = []
	for entry: Dictionary in _still:
		if not bool(entry["frozen"]) or not is_instance_valid(entry["mesh"]): continue
		if not entry.has("points"): entry["points"] = _stand_points(entry["mesh"])
		out.append_array(entry["points"])
	return out


func _stand_points(mesh: MeshInstance3D) -> Array:
	var points: Array = []
	var xform := mesh.global_transform
	if mesh.mesh is CylinderMesh:
		var disc: CylinderMesh = mesh.mesh
		var top := disc.height * 0.5 + LIFT
		points.append(xform * Vector3(0.0, top, 0.0))
		for ring: float in [0.3, 0.6]:
			for i in 6:
				var angle := TAU * float(i) / 6.0 + ring
				points.append(xform * Vector3(cos(angle) * disc.top_radius * ring, top, sin(angle) * disc.top_radius * ring))
		return points
	if mesh.mesh == null or mesh.mesh.get_surface_count() == 0: return points
	var arrays := mesh.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangles := index.size() / 3 if not index.is_empty() else verts.size() / 3
	for k in mini(16, triangles):
		var t := (triangles * (2 * k + 1) / 32) * 3
		var a := verts[index[t] if not index.is_empty() else t]
		var b := verts[index[t + 1] if not index.is_empty() else t + 1]
		var c := verts[index[t + 2] if not index.is_empty() else t + 2]
		points.append(xform * ((a + b + c) / 3.0 + Vector3.UP * LIFT))
	return points


func is_frozen(water_name: String) -> bool:
	for entry: Dictionary in _still:
		var item: Variant = entry["mesh"]
		if is_instance_valid(item) and str((item as Node).name) == water_name: return bool(entry["frozen"])
	return false


func _season_ice() -> float:
	if season_state == null or not is_instance_valid(season_state) or not season_state.has_method("ice"): return 0.0
	return float(season_state.call("ice"))


func _climate_ice(xz: Vector2) -> float:
	if season_state == null or not is_instance_valid(season_state) or not season_state.has_method("climate"): return 1.0
	return float(season_state.call("climate", xz, 3))


## Finds the world's water (it may arrive after the seasons, or be rebuilt by a zone reload).
func _bind_water() -> bool:
	var water: Node = water_override if water_override != null else WORLD_WATER.instance
	if water == null or not is_instance_valid(water) or not water.is_inside_tree():
		if _water != null: _unbind()
		return false
	if water == _water: return true
	_unbind()
	_water = water
	var meshes: Variant = water.get("still_water")
	if meshes is Array:
		for item: Variant in meshes:
			if not item is MeshInstance3D or not is_instance_valid(item): continue
			var mesh: MeshInstance3D = item
			var material := mesh.material_override as ShaderMaterial
			var centre: Vector3 = mesh.global_transform * mesh.get_aabb().get_center()
			_still.append({"mesh": mesh, "material": material, "xz": Vector2(centre.x, centre.z), "slab": null, "frozen": false})
	_rain = -1.0
	_detail = -1.0
	_apply_quality()
	return true


func _unbind() -> void:
	for entry: Dictionary in _still:
		_remove_slab(entry)
	_still.clear()
	_shapes.clear()
	_water = null


func _update_still(entry: Dictionary, ice: float) -> void:
	var item: Variant = entry["mesh"]
	if not is_instance_valid(item): return
	var mesh: MeshInstance3D = item
	var level := ice * _climate_ice(entry["xz"]) if ice > 0.0 else 0.0
	var was: bool = entry["frozen"]
	var frozen := level > FREEZE_AT or (was and level >= THAW_BELOW)
	if frozen == was: return
	entry["frozen"] = frozen
	if frozen: _add_slab(entry)
	else: _remove_slab(entry)
	var material: ShaderMaterial = entry["material"]
	if material != null: material.set_shader_parameter("ice_solid", 1.0 if frozen else 0.0)
	print("[ice] ", mesh.name, " frozen" if frozen else " thawed", " (ice %.2f)" % level)


func _add_slab(entry: Dictionary) -> void:
	var mesh: MeshInstance3D = entry["mesh"]
	var shape := _slab_shape(mesh)
	if shape == null: return
	var body := StaticBody3D.new()
	body.name = "IceSlab_" + str(mesh.name)
	body.collision_layer = GROUND_LAYER
	body.collision_mask = 0
	body.add_to_group(GROUP)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	if mesh.mesh is CylinderMesh:
		var disc: CylinderMesh = mesh.mesh
		collider.position = Vector3(0.0, disc.height * 0.5 + LIFT - THICKNESS * 0.5, 0.0)
	else:
		collider.position = Vector3(0.0, LIFT, 0.0)
	body.add_child(collider)
	# Jolt keeps the scale a body enters with: place it before it enters the tree.
	body.transform = mesh.global_transform
	add_child(body)
	entry["slab"] = body


func _remove_slab(entry: Dictionary) -> void:
	var slab: Variant = entry.get("slab")
	entry["slab"] = null
	if slab is StaticBody3D and is_instance_valid(slab):
		var body: StaticBody3D = slab
		var resting := _bodies_on(body, entry["mesh"])
		if body.get_parent() != null: body.get_parent().remove_child(body)
		body.queue_free()
		# Sleeping props on the ice do not notice it going: wake them so they drop in.
		for rigid: RigidBody3D in resting:
			if is_instance_valid(rigid): rigid.sleeping = false


## Rigid bodies lying on a slab: one box query over the water's footprint (only at a thaw).
func _bodies_on(slab: StaticBody3D, mesh_item: Variant) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	if not slab.is_inside_tree() or not is_instance_valid(mesh_item): return out
	var mesh: MeshInstance3D = mesh_item
	var aabb := mesh.get_aabb()
	var box := BoxShape3D.new()
	box.size = Vector3(aabb.size.x, aabb.size.y + 1.6, aabb.size.z)   # canals step down across town
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = mesh.global_transform * Transform3D(Basis.IDENTITY, aabb.get_center() + Vector3.UP * 0.7)
	# Skip the ground layer too: over the canals the box spans the whole town, whose terrain and
	# building trimeshes (layer 1) would fill every pass triangle by triangle before a prop is found.
	# Loose props live on their own layers (items 1 << 17, shelf, minigame layers).
	query.collision_mask = 0xFFFFFFFF & ~WATER_LAYER & ~GROUND_LAYER
	# A query reports a hit per triangle of a big mesh (terrain), so repeat it with every collider
	# already seen excluded until a pass comes back short.
	var exclude: Array[RID] = [slab.get_rid()]
	var space := slab.get_world_3d().direct_space_state
	for _pass in 12:
		query.exclude = exclude
		var hits := space.intersect_shape(query, 64)
		for hit: Dictionary in hits:
			var rid: RID = hit.get("rid", RID())
			if exclude.has(rid): continue
			exclude.append(rid)
			var collider: Variant = hit.get("collider")
			if collider is RigidBody3D: out.append(collider)
		if hits.size() < 64: break
	return out


func _slab_shape(mesh: MeshInstance3D) -> Shape3D:
	var key := mesh.get_instance_id()
	if _shapes.has(key): return _shapes[key]
	var shape: Shape3D = null
	if mesh.mesh is CylinderMesh:
		var disc: CylinderMesh = mesh.mesh
		var cylinder := CylinderShape3D.new()
		cylinder.radius = maxf(disc.top_radius, disc.bottom_radius)
		cylinder.height = THICKNESS
		shape = cylinder
	elif mesh.mesh != null:
		var surface := mesh.mesh.create_trimesh_shape()
		if surface != null:
			surface.backface_collision = true
			shape = surface
	if shape != null: _shapes[key] = shape
	return shape


func _update_rain() -> void:
	var rain := rain_override if rain_override >= 0.0 else _weather_rain()
	if not _ripples: rain = 0.0
	rain = clampf(rain, 0.0, 1.0)
	if _rain >= 0.0 and absf(rain - _rain) < RAIN_STEP and not (rain == 0.0 and _rain != 0.0): return
	_rain = rain
	_set_all("rain_amount", rain)


func _weather_rain() -> float:
	var weather := get_tree().get_first_node_in_group("weather") if is_inside_tree() else null
	if weather == null: return 0.0
	var params: Variant = weather.get("params")
	if not params is Dictionary: return 0.0
	var p: Dictionary = params
	return float(p.get("rain", 0.0))


func _set_all(param: String, value: float) -> void:
	if _water == null or not is_instance_valid(_water): return
	var materials: Variant = _water.get("water_materials")
	if not materials is Array: return
	for item: Variant in materials:
		if item is ShaderMaterial: (item as ShaderMaterial).set_shader_parameter(param, value)


func _on_quality_changed(_preset: int) -> void:
	_apply_quality()
	_update_rain()


## Quality "water_ice_look" flat -> plain ice colour; "wet_surfaces" off -> no ripple rings.
func _apply_quality() -> void:
	var quality := get_node_or_null("/root/Quality")
	var look := "full"
	var wet: Variant = true
	if quality != null and quality.has_method("get_value"):
		look = str(quality.call("get_value", "water_ice_look", "full"))
		wet = quality.call("get_value", "wet_surfaces", true)
	_ripples = not (wet is bool and not wet) and str(wet) != "off"
	var detail := 0.0 if look == "flat" else 1.0
	if detail != _detail:
		_detail = detail
		_set_all("ice_detail", detail)
	_rain = -1.0
