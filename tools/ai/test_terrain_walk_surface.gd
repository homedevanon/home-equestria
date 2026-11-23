extends SceneTree
## Run with the exported project. All coordinates belong to an isolated physics fixture.

var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("TERRAIN_WALK_FAIL ", label)

func slab(site: Node3D, x: int, height: float, layer := 1) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	var shape := BoxShape3D.new()
	shape.size = Vector3(.45,.08,.45)
	var holder := CollisionShape3D.new()
	holder.shape = shape
	body.add_child(holder)
	body.position = Vector3(x+.125, height-.04, .125)
	site.add_child(body)
	return body

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var grid: Script = load("res://world/navigation/walk_grid.gd")
	var chunk_type: Script = load("res://world/navigation/walk_chunk.gd")
	var service_type: Script = load("res://world/navigation/walk_grid_service.gd")
	var site := Node3D.new()
	root.add_child(site)
	slab(site,0,-.54)
	slab(site,1,2.0)
	slab(site,2,-.54)
	slab(site,3,.015)
	slab(site,4,3.0)
	slab(site,4,1.5)
	var physical_ground := slab(site,5,.24)
	slab(site,7,-.54)
	slab(site,7,.2,1 << 15)
	slab(site,8,.72).set_meta("navigation_ceiling", true)
	slab(site,11,2.0)
	slab(site,11,-.54)
	var service: Node = service_type.bake(site, {"id":"terrain-walk-fixture"})
	service.set_physics_process(false)
	var fixture: Script = load(get_script().resource_path.get_base_dir().path_join("terrain_walk_fixture.gd"))
	var terrain: Node = fixture.new()
	terrain.terrain = physical_ground
	terrain.instance = terrain
	service._blockers[0] = AABB(Vector3(6.08,.25,.08),Vector3(.1,.1,.1))
	await physics_frame
	await physics_frame
	var expected := [[0,-.54],[2.0,0],[-.54],[.015],[3.0,1.5],[.24],[0],[0,-.54],[0],[0],[],[2.0,0]]
	var modes := ["script"]
	if ClassDB.class_has_method("PonyColumnSampler", "sample_terrain_columns"):
		check(service._column_sampler != null, "native sampler selected")
		modes.append("native")
	else:
		check(service._column_sampler == null, "script selected for older native library")
	for mode in modes:
		var chunk: Resource = chunk_type.new()
		chunk.allocate()
		for x in expected.size():
			var column := x*4
			if mode == "script":
				service._sample_column(chunk,column)
			else:
				var count: int = service._column_sampler.sample_terrain_columns(site.get_world_3d().direct_space_state,
					service._ray,service._volume,chunk,column,1,Time.get_ticks_usec()+10000,service.bounds,
					service._blockers.values(),terrain)
				check(count == 1, "native sampled column %d" % x)
			var first: int = column*grid.SPANS
			for i in grid.SPANS:
				var occupied: bool = bool(chunk.flags[first+i] & grid.SOLID)
				var label := "%s column %d span %d" % [mode,x,i]
				check(occupied == (i < expected[x].size()), label + " occupancy")
				if occupied and i < expected[x].size():
					check(absf(chunk.floor_y[first+i]-float(expected[x][i]))<.005, label + " height")
		check(absf(chunk.headroom[1]-.54)<.005, mode + " buried span clearance")
		check(chunk.headroom[4*grid.SPANS+1]>1.8 and chunk.headroom[4*grid.SPANS+1]<2.05, mode + " bridge underside")
		check(chunk.headroom[24*grid.SPANS] == 0, mode + " blocker on inserted terrain")
		check(absf(chunk.water_depth[28*grid.SPANS]-.2)<.005 and bool(chunk.flags[28*grid.SPANS]&grid.WATER), mode + " terrain water depth")
		check(chunk.headroom[32*grid.SPANS]>.5 and chunk.headroom[32*grid.SPANS]<.75, mode + " low ceiling")
	terrain.instance = null
	terrain.terrain = null
	terrain.free()
	site.free()
	print("TERRAIN_WALK_DONE checks=", checks, " failures=", failures)
	quit(0 if failures==0 else 1)
