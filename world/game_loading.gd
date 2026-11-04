extends RefCounted
## Behind the loading screen: wait for zones and residents, then warm every material's pipelines once.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const WARMUP_GRID := preload("res://world/pipeline_warmup_grid.gd")
const TERRAIN_RESUME := preload("res://world/terrain/player_repair_resume.gd")
const COTTAGE_RESUME := preload("res://world/buildings/fluttershy/cottage_checkpoint_resume.gd")

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Behind the loading screen: the zones stream in and every resident in range is spawned
## (population.begin_startup loads their scenes in parallel), so the world is complete when
## the player gets control. The clock stands still meanwhile. Gives up after 3 minutes.
func _load_everything(cover: Node) -> bool:
	TimeOfDay.hold("loading")
	cover.show_text("Loading the world…")
	cover.set_progress(0.6)
	await ZoneManager.wait_until_idle()
	if SHUTDOWN.active or not host.is_inside_tree() or host.is_queued_for_deletion():
		TimeOfDay.release("loading")
		return false
	if host.population != null:
		host.population.begin_startup()
		var deadline := Time.get_ticks_msec() + 180000
		while Time.get_ticks_msec() < deadline:
			var left: int = host.population.startup_candidates().size()
			cover.show_text("Waking up the ponies…\n%d out, %d to go" % [host.population.live.size(), left])
			cover.set_progress(0.62 + 0.24 * host.population.live.size() / maxf(1.0, host.population.live.size() + left))
			if left == 0: break
			var stepped := true
			for i in 10:
				if not await SHUTDOWN.physics_frame(host): stepped = false; break
			if not stepped:
				TimeOfDay.release("loading")
				return false
		host.population.end_startup()
		print("[game] loading screen: %d ponies out" % host.population.live.size())
	if not await _wait_for_furnishing(cover):
		TimeOfDay.release("loading")
		return false
	TimeOfDay.release("loading")
	# This also runs after TitleVista restores the saved place on Continue.
	# Only certified old terrain positions qualify, while body physics is held.
	TERRAIN_RESUME.repair_loaded_position(host)
	COTTAGE_RESUME.repair_loaded_position(host)
	return true


## Houses lay out their furniture over several frames each, taking turns 200 ms apart
## (house_interior.gd _furnish_when_ready, interior_furnisher.gd). A town still furnishing when
## the cover lifted made the first 5-10 s of play run at 70-200 ms frames (thread 43671981 D1;
## tools/profile/play_bench.gd --post-load --furnish-log: 12 houses left, 75-400 ms of main-thread
## work each). The houses that have started finish behind the cover; houses still waiting for a
## bed or floor are not counted, and the wait is bounded.
const FURNISH_WAIT_MS := 20000

func _wait_for_furnishing(cover: Node) -> bool:
	var deadline := Time.get_ticks_msec() + FURNISH_WAIT_MS
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() < deadline:
		var left := 0
		for house: Node in host.get_tree().get_nodes_in_group("house_interiors"):
			if house.get("furnish") == true and house.get("_furnished") == true and house.get("furnish_done") != true: left += 1
		if left == 0: break
		cover.show_text("Furnishing the houses…\n%d to go" % left)
		if not await SHUTDOWN.seconds(host, 0.1): return false
	print("[game] loading screen: houses furnished in %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	return true


## Draw every material in the scene once, up close, before play: Godot builds
## a pipeline the first time a material is seen, and in the headset that
## showed as a hitch on first sight (dev, 2026-09-07: "preload all shaders").
## One tiny quad per unique material in front of the camera for a few frames,
## shadows on so the shadow variants compile too.
func _warm_up_pipelines() -> bool:
	# Dummy rendering has no post-draw signal or GPU pipeline to warm. Awaiting
	# it in a headless boot kept this coroutine and its material references alive.
	if DisplayServer.get_name() == "headless": return true
	var camera := host._find_camera(host.player) as Camera3D
	if camera == null:
		return true
	var seen: Dictionary = {}
	for node in host.get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(si)
			if mat != null:
				seen[mat.get_rid()] = mat
	var before := _pipeline_counters()
	# Fit the entire material grid inside this camera. The old fixed 24-column
	# strip extended metres above the frustum when a town supplied thousands of
	# materials, so most warmup quads were never submitted.
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(1.0, viewport_size.y)
	var columns := maxi(1, ceili(sqrt(float(seen.size()) * aspect)))
	var rows := maxi(1, ceili(float(seen.size()) / columns))
	var depth := maxf(1.2, camera.near * 2.0)
	var footprint := WARMUP_GRID.footprint(camera, depth)
	if not footprint.has_area(): return true
	var corner := Vector3(footprint.position.x, footprint.end.y, -depth)
	var opposite := Vector3(footprint.end.x, footprint.position.y, -depth)
	var cell := Vector2((opposite.x - corner.x) / columns, (opposite.y - corner.y) / rows)
	var rig := Node3D.new()
	rig.name = "PipelineWarmup"
	camera.add_child(rig)
	var quad := QuadMesh.new()
	quad.size = cell.abs() * 0.7
	var i := 0
	for mat in seen.values():
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.position = Vector3(corner.x + (i % columns + 0.5) * cell.x, corner.y + (i / columns + 0.5) * cell.y, -depth)
		rig.add_child(mi)
		i += 1
	for frame in 6:
		if not await SHUTDOWN.rendered_frame(host):
			if is_instance_valid(rig): rig.queue_free()
			return false
	rig.queue_free()
	print("[game] pipeline warm-up: %d materials, compilations %s -> %s" % [seen.size(), before, _pipeline_counters()])
	return true


func _pipeline_counters() -> Dictionary:
	return {
		"mesh": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		"surface": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		"draw": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		"specialization": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION),
	}
