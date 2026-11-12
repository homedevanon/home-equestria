extends RefCounted
## Behind the loading screen: wait for zones and residents, then warm every material's pipelines once.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const WARMUP_GRID := preload("res://world/pipeline_warmup_grid.gd")
const TERRAIN_RESUME := preload("res://world/terrain/player_repair_resume.gd")
const COTTAGE_RESUME := preload("res://world/buildings/fluttershy/cottage_checkpoint_resume.gd")
const FAR_MESH := preload("res://world/characters/hybrid_mare/hybrid_far_mesh.gd")
const NEAR_MESH := preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd")
const IMPOSTORS := preload("res://world/characters/hybrid_mare/pony_impostors.gd")

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


## The meshes the ponies in view asked for while loading (merged far and near meshes, far impostor
## atlases) finish behind the cover. The 2026-11-08 bench saw them in the first seconds of play
## instead: far mesh assembly and near mesh gathers (GPU readbacks, 50-250 ms frames) and the first
## impostor bake, whose new 4x MSAA pipelines were the 0.9 s shader burst about a second after
## the cover. Far mesh steps run several per frame here (one per frame in play). Bounded: a pony
## that sits or sleeps only gathers once she stands, so the wait also ends when nothing moved
## for PONY_MESH_STALL_MS. Impostors are not waited for headless (no frames are drawn there).
const PONY_MESH_WAIT_MS := 15000
const PONY_MESH_STALL_MS := 1500
const PONY_MESH_STEPS := 4
const FAR_TIER := 2  # pony_locomotion.gd SimTier.FAR
## Impostor bakes take ~35 drawn frames each, one identity at a time. The first one builds the
## bake studio and its pipelines (the 0.9 s burst) and always finishes behind the cover; the rest
## get this long and then carry on in play, where each shot is one small render.
const IMPOSTOR_WAIT_MS := 3000
var _wait_started := 0

func _wait_for_pony_meshes() -> bool:
	var cover: Node = host.get_node_or_null("LoadingCover")
	var started := Time.get_ticks_msec()
	_wait_started = started
	var progress_at := started
	var last_done := -1
	var left := 0
	var timeline: Array[String] = []  # "<seconds>s:<work left>" whenever the count changes (log only)
	FAR_MESH.steps_per_frame = PONY_MESH_STEPS
	while Time.get_ticks_msec() - started < PONY_MESH_WAIT_MS:
		var was := left
		left = _pony_mesh_work()
		var now := Time.get_ticks_msec()
		if (left != was or timeline.is_empty()) and timeline.size() < 24: timeline.append("%.1fs:%d" % [(now - started) / 1000.0, left])
		if left == 0: break
		# Atlases count as progress only while impostors are waited for (first bake, IMPOSTOR_WAIT_MS):
		# later bakes finishing every ~35 frames would otherwise reset the stall timer behind a stuck
		# pony and hold the cover for the whole PONY_MESH_WAIT_MS (review 2026-11-08).
		var impostors_counted := IMPOSTORS.atlases.is_empty() or now - started < IMPOSTOR_WAIT_MS
		var done: int = FAR_MESH.cache.size() + NEAR_MESH.cache.size() + (IMPOSTORS.atlases.size() if impostors_counted else 0)
		# Worker builds in flight count as progress; the stall timer runs only when nothing is.
		if done != last_done or _building() or (IMPOSTORS.atlases.is_empty() and _impostors_pending() > 0):
			last_done = done; progress_at = now
		elif now - progress_at > PONY_MESH_STALL_MS: break
		if is_instance_valid(cover): cover.show_text("Dressing the ponies…\n%d to go" % left)
		if not await SHUTDOWN.frame(host):
			FAR_MESH.steps_per_frame = 1
			return false
	FAR_MESH.steps_per_frame = 1
	print("[game] loading screen: pony meshes in %.1f s (%d far, %d near, %d impostors cached; %d left%s)" % [
		(Time.get_ticks_msec() - started) / 1000.0, FAR_MESH.cache.size(), NEAR_MESH.cache.size(), IMPOSTORS.atlases.size(), left,
		"" if left == 0 else ": " + ", ".join(_pony_mesh_leftovers())])
	print("[game] pony mesh wait, work left over time: ", " ".join(timeline))
	return true


## True while a far or near mesh build is still running on a worker thread.
static func _building() -> bool:
	for pending: Dictionary in FAR_MESH._pending.values():
		if not WorkerThreadPool.is_task_completed(pending.task): return true
	for pending: Dictionary in NEAR_MESH._pending.values():
		if not WorkerThreadPool.is_task_completed(pending.task): return true
	return false


## What the wait gave up on, for the log line above (once per load; at most 8 names).
func _pony_mesh_leftovers() -> Array[String]:
	var out: Array[String] = []
	if not FAR_MESH._pending.is_empty(): out.append("%d far builds" % FAR_MESH._pending.size())
	if not NEAR_MESH._pending.is_empty(): out.append("%d near builds" % NEAR_MESH._pending.size())
	if _impostors_pending() > 0: out.append("%d impostor bakes (they go on in play)" % _impostors_pending())
	for pony: Node in host.get_tree().get_nodes_in_group(PonyCrowd.MEMBERS):
		if out.size() >= 8: break
		if pony.get("_far_mesh_waiting") == true and pony.has_method("_far_mesh_can_gather") and bool(pony.call("_far_mesh_can_gather")):
			out.append("%s far" % pony.name)
		elif pony.get("_near_waiting") == true and pony.get("_far_mesh_shown") != true and pony.get("sim_tier") != FAR_TIER:
			var tick: Variant = pony.get("_tick")
			if tick is int and int(tick) >= 3: out.append("%s near (tier %s)" % [pony.name, str(pony.get("sim_tier"))])
	return out


## Pony mesh work still open: worker builds, ponies waiting for a far mesh they can gather now
## or for their near mesh, and impostor bakes queued or running.
func _pony_mesh_work() -> int:
	# Finished builds whose pony stopped waiting were counted here for the whole 15 s before (the
	# wait never stalled out): assemble them now, count only the ones still running.
	var work: int = FAR_MESH.harvest() + NEAR_MESH.harvest()
	for pony: Node in host.get_tree().get_nodes_in_group(PonyCrowd.MEMBERS):
		if pony.get("_far_mesh_waiting") == true and pony.has_method("_far_mesh_can_gather") and bool(pony.call("_far_mesh_can_gather")):
			work += 1
		elif pony.get("_near_waiting") == true and pony.get("_far_mesh_shown") != true and pony.get("sim_tier") != FAR_TIER:
			var tick: Variant = pony.get("_tick")
			if tick is int and int(tick) >= 3: work += 1
	if IMPOSTORS.atlases.is_empty() or Time.get_ticks_msec() - _wait_started < IMPOSTOR_WAIT_MS:
		work += _impostors_pending()
	return work


## Impostor bakes queued or running; 0 headless (no frames are drawn there, a bake never ends).
func _impostors_pending() -> int:
	if DisplayServer.get_name() == "headless": return 0
	var bank: Node = host.get_tree().root.get_node_or_null(IMPOSTORS.NAME)
	return int(bank.call("pending")) if bank != null and bank.has_method("pending") else 0


## Draw every material in the scene once, up close, before play: Godot builds
## a pipeline the first time a material is seen, and in the headset that
## showed as a hitch on first sight (dev, 2026-09-07: "preload all shaders").
## One tiny quad per unique material in front of the camera for a few frames,
## shadows on so the shadow variants compile too.
func _warm_up_pipelines() -> bool:
	# Pony meshes first, so their materials (far mesh atlases, impostors) are warmed below too.
	if not await _wait_for_pony_meshes(): return false
	# Dummy rendering has no post-draw signal or GPU pipeline to warm. Awaiting
	# it in a headless boot kept this coroutine and its material references alive.
	if DisplayServer.get_name() == "headless": return true
	var camera := host._find_camera(host.player) as Camera3D
	if camera == null:
		return true
	var seen := _scene_materials()
	# The impostor quad's pipelines, even when no pony shows a finished atlas yet (they all share
	# pony_impostor.gdshader, so one atlas warms them all).
	for entry: Dictionary in IMPOSTORS.atlases.values():
		var impostor: Material = entry.get("material")
		if impostor != null: seen[impostor.get_rid()] = impostor; break
	var samples := _pony_mesh_samples()
	var effects := _effect_samples()
	var before := _pipeline_counters()
	var rig := _warm_rig(camera, seen.values(), samples, effects)
	if rig == null:
		for node: Node in effects: node.free()
		return true
	for frame in 6:
		if not await SHUTDOWN.rendered_frame(host):
			if is_instance_valid(rig): rig.queue_free()
			return false
	rig.queue_free()
	print("[game] pipeline warm-up: %d materials, %d pony meshes, compilations %s -> %s" % [seen.size(), samples.size(), before, _pipeline_counters()])
	return true


## Every material on a MeshInstance3D in the scene, by RID.
func _scene_materials() -> Dictionary:
	var seen: Dictionary = {}
	for node in host.get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(si)
			if mat != null:
				seen[mat.get_rid()] = mat
	return seen


## The warm-up grid under `camera`: a quad per material, then the pony mesh samples; null when the
## camera has no usable footprint. The caller frees it after a few drawn frames.
func _warm_rig(camera: Camera3D, materials: Array, samples: Array[MeshInstance3D], effects: Array[GeometryInstance3D] = []) -> Node3D:
	# Fit the entire material grid inside this camera. The old fixed 24-column
	# strip extended metres above the frustum when a town supplied thousands of
	# materials, so most warmup quads were never submitted.
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(1.0, viewport_size.y)
	var cells := materials.size() + samples.size() + effects.size()
	var columns := maxi(1, ceili(sqrt(float(cells) * aspect)))
	var rows := maxi(1, ceili(float(cells) / columns))
	var depth := maxf(1.2, camera.near * 2.0)
	var footprint := WARMUP_GRID.footprint(camera, depth)
	if not footprint.has_area(): return null
	var corner := Vector3(footprint.position.x, footprint.end.y, -depth)
	var opposite := Vector3(footprint.end.x, footprint.position.y, -depth)
	var cell := Vector2((opposite.x - corner.x) / columns, (opposite.y - corner.y) / rows)
	var rig := Node3D.new()
	rig.name = "PipelineWarmup"
	camera.add_child(rig)
	var quad := QuadMesh.new()
	quad.size = cell.abs() * 0.7
	var i := 0
	for mat: Material in materials:
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.position = Vector3(corner.x + (i % columns + 0.5) * cell.x, corner.y + (i / columns + 0.5) * cell.y, -depth)
		rig.add_child(mi)
		i += 1
	# Pony meshes as they really draw: skinned by their own skeleton, in their own vertex layout,
	# with every pass and shadow setting (a quad warms the material, not those). One mesh per new
	# [vertex format, shaders, shadow] combination; the scale fits it in its cell.
	for sample: MeshInstance3D in samples:
		var skeleton := sample.get_node_or_null(sample.skeleton) as Skeleton3D
		if skeleton == null: continue
		var mi := MeshInstance3D.new()
		mi.mesh = sample.mesh
		mi.skin = sample.skin
		for si in sample.mesh.get_surface_count(): mi.set_surface_override_material(si, sample.get_active_material(si))
		mi.material_overlay = sample.material_overlay
		mi.cast_shadow = sample.cast_shadow
		var extent := maxf(sample.mesh.get_aabb().get_longest_axis_size(), 0.01)
		mi.scale = Vector3.ONE * minf(absf(cell.x), absf(cell.y)) * 0.7 / extent
		mi.position = Vector3(corner.x + (i % columns + 0.5) * cell.x, corner.y + (i / columns + 0.5) * cell.y, -depth)
		rig.add_child(mi)
		mi.skeleton = mi.get_path_to(skeleton)
		i += 1
	# Effects that first appear mid-session (see _effect_samples), as they really draw.
	for effect: GeometryInstance3D in effects:
		effect.scale = Vector3.ONE * minf(absf(cell.x), absf(cell.y)) * 0.35
		effect.position = Vector3(corner.x + (i % columns + 0.5) * cell.x, corner.y + (i / columns + 0.5) * cell.y, -depth)
		rig.add_child(effect)
		i += 1
	return rig


## Effects nothing in the loaded scene draws yet, so their shaders and particle pipelines would
## compile mid-session: the first magic aura of a session (the arrival log lift, M-ARR-03: a new
## ShaderMaterial plus a GPUParticles3D start, a plausible native crash on Intel iGPU) and the
## autumn leaves (W2-SEAS-E: falling_leaf.gdshader on the particle quad, leaf_pile.gdshader on a
## MultiMesh). One small node each, in the warm-up grid under the cover; freed with the rig.
## The leaf particle process shader still compiles when its emitter is made (season, effects or
## quality change); it is generated per emitter.
func _effect_samples() -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	var aura_script := load("res://world/characters/magic/magic_aura.gd") as GDScript
	if aura_script != null:
		var disc := MeshInstance3D.new()
		disc.name = "WarmAuraDisc"
		disc.mesh = aura_script.call("_fan_mesh")
		var disc_material := ShaderMaterial.new()
		disc_material.shader = load("res://world/characters/magic/magic_aura.gdshader") as Shader
		disc_material.set_shader_parameter("alpha", 0.0)
		disc_material.render_priority = 100
		disc.material_override = disc_material
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.append(disc)
		var aura: Node3D = aura_script.new()
		var sparkles: GPUParticles3D = aura.call("_make_sparkles")
		aura.free()
		if sparkles != null:
			sparkles.name = "WarmAuraSparkles"
			out.append(sparkles)
	var leaf_mask := load("res://world/foliage/everfree_trees/leaf_mask.res") as Texture2D
	var falling := load("res://world/terrain/kits/grassy_fields/falling_leaf.gdshader") as Shader
	if falling != null:
		var leaf := MeshInstance3D.new()
		leaf.name = "WarmFallingLeaf"
		var quad := QuadMesh.new()
		var leaf_material := ShaderMaterial.new(); leaf_material.shader = falling
		if leaf_mask != null: leaf_material.set_shader_parameter("leaf_texture", leaf_mask)
		quad.material = leaf_material
		leaf.mesh = quad
		leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.append(leaf)
	var pile_shader := load("res://world/seasons/leaf_pile.gdshader") as Shader
	if pile_shader != null:
		var pile_material := ShaderMaterial.new(); pile_material.shader = pile_shader
		if leaf_mask != null: pile_material.set_shader_parameter("leaf_texture", leaf_mask)
		var quad := QuadMesh.new(); quad.material = pile_material
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = quad
		multimesh.instance_count = 1
		multimesh.set_instance_transform(0, Transform3D.IDENTITY)
		var pile := MultiMeshInstance3D.new()
		pile.name = "WarmLeafPile"
		pile.multimesh = multimesh
		pile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.append(pile)
	return out


## One pony MeshInstance3D per new [vertex format, shader chain, overlay, shadow mode] among every
## pony's skinned meshes (rig parts, hidden ones included, merged near meshes, far meshes, shadow
## proxies). Pipelines follow the shader and vertex layout, not the material copy, so ponies that
## spawn later (same rigs and shaders, their own colours) draw with pipelines built here.
const WARM_PONY_MESHES_MAX := 160

func _pony_mesh_samples() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var keys := {}
	for pony: Node in host.get_tree().get_nodes_in_group(PonyCrowd.MEMBERS):
		for node: Node in pony.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null or mi.skin == null or mi.get_node_or_null(mi.skeleton) == null: continue
			var fresh := false
			for si in mi.mesh.get_surface_count():
				var key := "%d|%s|%s|%d" % [mi.mesh.surface_get_format(si), _shader_key(mi.get_active_material(si)), _shader_key(mi.material_overlay), mi.cast_shadow]
				if not keys.has(key):
					keys[key] = true
					fresh = true
			if fresh: out.append(mi)
			if out.size() >= WARM_PONY_MESHES_MAX: return out
	return out


static func _shader_key(material: Material) -> String:
	var parts: Array[String] = []
	var at := material
	while at != null and parts.size() < 4:
		var sm := at as ShaderMaterial
		parts.append(str(sm.shader.get_rid().get_id()) if sm != null and sm.shader != null else at.get_class() + str(at.get_rid().get_id()))
		at = at.next_pass
	return ",".join(parts)


func _pipeline_counters() -> Dictionary:
	return {
		"mesh": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		"surface": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		"draw": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		"specialization": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION),
	}
