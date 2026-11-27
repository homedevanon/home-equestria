extends Node
## "Summon the Great Evil" (dev 2026-10-30), a button in Settings > World. Press it and the pause
## menu closes, a second passes, night falls at once, lightning hits the ground in front of you
## (flash, thunder, a screen shake sized to the impact, sparks, dirt clods and dust), and Sunset
## Shimmer stands in the scorch. Her irises blaze white: the glow dies down over a few seconds,
## the white holds for ten, then slowly fades back to her own colour.
## She stays: a real resident of this world (population.json `barbiepone`), sized by the pony
## size setting, wired to the AI and saved. While she is here the button reads "Exorcise the
## Evil"; that strikes her once more, she fades out and leaves the world for good.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIEW := preload("res://world/player_view.gd")
const PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const CONFIG := preload("res://world/population/pony_population_config.gd")
const ACTION := "spawn_barbiepone"
const ID := CONFIG.BARBIEPONE
const NIGHT_HOURS := 22.5
const STRIKE_DISTANCE := 4.5
const GLOW_PEAK := 3.0
const GLOW_SECONDS := 4.0
const WHITE_SECONDS := 10.0
const WHITE_FADE_SECONDS := 4.0
const EXORCISE_FADE_SECONDS := 3.0
const SCORCH_SECONDS := 30.0
const SHAKE_SECONDS := 0.9
const SHAKE_AMOUNT := 0.11
const EYE_WHITE := Color(1.0, 1.0, 1.0)

var host: Node3D
var _busy := false
var _shake := 0.0
var _shake_left := 0.0
var _camera: Camera3D


func setup(game: Node3D) -> Node:
	host = game
	Settings.changed.connect(_on_setting)
	Settings.action_labels[ACTION] = func() -> String: return "Exorcise the Evil" if summoned() else ""
	return self


func _exit_tree() -> void:
	Settings.action_labels.erase(ACTION)
	if is_instance_valid(_camera): _camera.h_offset = 0.0; _camera.v_offset = 0.0


func _population() -> Node:
	var population: Variant = host.get("population")
	return population if is_instance_valid(population) else null


func summoned() -> bool:
	var population := _population()
	return population != null and population.config.barbiepone


func _on_setting(key: String) -> void:
	if key != "action:" + ACTION or _busy: return
	if summoned(): exorcise()
	else: summon()


func _close_menus() -> void:
	if is_instance_valid(host.pause_menu) and host.pause_menu.get("opened") == true: host.pause_menu.close()
	if is_instance_valid(host.settings_menu) and host.settings_menu.get("opened") == true: host.settings_menu.close()


func _say(text: String) -> void:
	Settings.message = text
	print("[great evil] ", text)


# ------------------------------------------------------------------ summon
func summon() -> void:
	var population := _population()
	if population == null: _say("The world is not ready."); return
	if population._spawning == ID or population.visiting.has(ID): return
	_busy = true
	var path: String = CONFIG.BARBIEPONE_SCENE
	ResourceLoader.load_threaded_request(path, "PackedScene")
	_close_menus()
	if not await SHUTDOWN.seconds(self, 1.0): return
	_camera = VIEW.camera(self)
	if _camera == null: _busy = false; return
	TimeOfDay.hours = NIGHT_HOURS
	var forward: Vector3 = -_camera.global_basis.z; forward.y = 0.0
	if forward.length_squared() < 1e-4: forward = Vector3.FORWARD
	var at: Vector3 = _camera.global_position + forward.normalized() * STRIKE_DISTANCE
	at.y = host._ground_y(Vector2(at.x, at.z))
	_strike(at)
	var scorch := _scorch(at)
	_fade_later([scorch], SCORCH_SECONDS, 4.0, true)
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		if not await SHUTDOWN.physics_frame(self): return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	var region := str(WorldLayout.nearest(at).get("id", "ponyville"))
	if not CONFIG.regions().any(func(r: Dictionary) -> bool: return str(r.id) == region): region = "ponyville"
	# She lives here now: this world's population keeps her (saved, streamed, re-spawned on load).
	population.visiting[ID] = true
	population.config.barbiepone = true
	population.config.assignments[ID] = region
	if not population.config.save_file(population.config_path):
		population.visiting.erase(ID); population.config.barbiepone = false; population.config.assignments.erase(ID)
		_say("Could not save the summoning: " + population.config.error); _busy = false; return
	population._stamp = population._signature()
	var actor: Node3D = null
	if packed != null: actor = await host._spawn_resident(ID, region, at, packed, region, self)
	if not is_instance_valid(population): return
	population.visiting.erase(ID)
	if not is_instance_valid(actor):
		_say("The Great Evil is loose, though she couldn't take hold here. She'll show up nearby."); _busy = false; return
	_register(actor, region)
	var toward: Vector3 = _camera.global_position; toward.y = actor.global_position.y
	if toward.distance_squared_to(actor.global_position) > 1e-4 and actor.has_method("reset_motion"):
		actor.reset_motion(Transform3D(Basis.looking_at(toward - actor.global_position, Vector3.UP), actor.global_position))
	_busy = false
	await _glare(actor)


## The console's registration: she is a live resident from this frame on.
func _register(actor: Node3D, region: String) -> void:
	var population := _population()
	population.live[ID] = {"actor": actor, "region": region}
	actor.set_meta("navigation_region", region)
	var life: Variant = host.get("life")
	if not is_instance_valid(life): return
	life.detach(ID)
	life._sync_roster()
	if life.core.state.residents.has(ID): life.core.state.residents[ID].region = region
	life.attach(ID, actor, true)


## White, glowing irises: the glow dies over GLOW_SECONDS, the white holds to WHITE_SECONDS, then
## eases back to her own colour. Materials are copies; the originals come back at the end.
func _glare(actor: Node3D) -> void:
	var eyes: Array = []   # [MeshInstance3D, surface or -1, original Material, copy, original iris colour]
	for wait in [4, 40]:
		for i in wait:
			if not await SHUTDOWN.physics_frame(self): return
		if not is_instance_valid(actor): return
		for mi: MeshInstance3D in actor.find_children("*", "MeshInstance3D", true, false):
			for s in mi.get_surface_override_material_count():
				var m: Material = mi.get_active_material(s)
				if not _is_iris(m) or m.has_meta("great_evil_eyes"): continue
				var copy: ShaderMaterial = m.duplicate()
				copy.set_meta("great_evil_eyes", true)
				var original: Variant = m.get_shader_parameter("iris_color")
				eyes.append([mi, s, m, copy, original if original is Color else EYE_WHITE])
				mi.set_surface_override_material(s, copy)
	var t := 0.0
	var total := WHITE_SECONDS + WHITE_FADE_SECONDS
	while t < total:
		var glow := GLOW_PEAK * clampf(1.0 - t / GLOW_SECONDS, 0.0, 1.0)
		var back := clampf((t - WHITE_SECONDS) / WHITE_FADE_SECONDS, 0.0, 1.0)
		for e: Array in eyes:
			if not is_instance_valid(e[0]): continue
			var copy: ShaderMaterial = e[3]
			copy.set_shader_parameter("iris_color", EYE_WHITE.lerp(e[4], back))
			copy.set_shader_parameter("glow", glow)
		if not await SHUTDOWN.physics_frame(self): return
		t += get_physics_process_delta_time()
	for e: Array in eyes:
		if is_instance_valid(e[0]) and (e[0] as MeshInstance3D).get_surface_override_material(e[1]) == e[3]:
			(e[0] as MeshInstance3D).set_surface_override_material(e[1], e[2])


static func _is_iris(m: Material) -> bool:
	return m is ShaderMaterial and (m.has_meta("show_iris") or (m as ShaderMaterial).get_shader_parameter("iris_color") != null)


# ------------------------------------------------------------------ exorcise
func exorcise() -> void:
	var population := _population()
	if population == null: return
	_busy = true
	_close_menus()
	population.config.barbiepone = false
	population.config.assignments.erase(ID)
	if not population.config.save_file(population.config_path):
		population.config.barbiepone = true; population.config.assignments[ID] = population.residence_region(ID)
		_say("Could not save the exorcism: " + population.config.error); _busy = false; return
	population._stamp = population._signature()
	var entry: Dictionary = population.live.get(ID, {})
	var actor: Node3D = entry.get("actor") if is_instance_valid(entry.get("actor")) else null
	if actor == null: _busy = false; return
	if not await SHUTDOWN.seconds(self, 1.0): return
	if not is_instance_valid(actor): _busy = false; return
	_camera = VIEW.camera(self)
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null and nav.has_method("stay"): nav.stay()
	_strike(actor.global_position, false)
	var parts: Array = []
	for g in actor.find_children("*", "GeometryInstance3D", true, false): parts.append(g)
	await _fade_later(parts, 0.0, EXORCISE_FADE_SECONDS, false)
	if is_instance_valid(actor) and is_instance_valid(population) and population.live.get(ID, {}).get("actor") == actor:
		host._despawn_resident(ID, actor); population.live.erase(ID)
	elif is_instance_valid(actor):
		actor.queue_free()
	_busy = false


func _fade_later(parts: Array, delay: float, seconds: float, free_after: bool) -> void:
	if delay > 0.0 and not await SHUTDOWN.seconds(self, delay): return
	var t := 0.0
	while t < seconds:
		t += get_physics_process_delta_time()
		for g: Variant in parts:
			if is_instance_valid(g): (g as GeometryInstance3D).transparency = clampf(t / seconds, 0.0, 1.0)
		if not await SHUTDOWN.physics_frame(self): return
	if free_after:
		for g: Variant in parts:
			if is_instance_valid(g): (g as Node).queue_free()


func _process(delta: float) -> void:
	if _shake_left > 0.0 and is_instance_valid(_camera):
		_shake_left -= delta
		var a: float = _shake * clampf(_shake_left / SHAKE_SECONDS, 0.0, 1.0)
		_camera.h_offset = randf_range(-a, a)
		_camera.v_offset = randf_range(-a, a) * 0.7
		if _shake_left <= 0.0: _camera.h_offset = 0.0; _camera.v_offset = 0.0


# ------------------------------------------------------------------ the strike
func _strike(at: Vector3, debris := true) -> void:
	_bolt(at)
	if debris: _particles(at)
	if is_instance_valid(_camera):
		SOUNDS.play_event(host, "env_thunder", {"intensity": 1.0}, _camera.global_position)
		# The headset never shakes: only the flat-screen camera does.
		if not host.xr_active: _shake = SHAKE_AMOUNT; _shake_left = SHAKE_SECONDS


func _bolt(at: Vector3) -> void:
	var bolt := Node3D.new(); bolt.name = "Lightning"; host.add_child(bolt)
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(0.85, 0.9, 1.0)
	glow.emission_enabled = true; glow.emission = Color(0.7, 0.8, 1.0); glow.emission_energy_multiplier = 6.0
	var top: Vector3 = at + Vector3(0, 60.0, 0)
	_chain(bolt, top, at, 24, 0.16, 2.6, glow)
	# Two side branches off the lower half.
	var mid: Vector3 = at.lerp(top, 0.35) + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1))
	_chain(bolt, mid, mid + Vector3(randf_range(-4, 4), -6.0, randf_range(-4, 4)), 5, 0.06, 0.8, glow)
	var low: Vector3 = at.lerp(top, 0.15) + Vector3(randf_range(-0.6, 0.6), 0, randf_range(-0.6, 0.6))
	_chain(bolt, low, low + Vector3(randf_range(-3, 3), -2.5, randf_range(-3, 3)), 4, 0.05, 0.6, glow)
	var light := OmniLight3D.new(); light.light_color = Color(0.8, 0.85, 1.0); light.light_energy = 18.0
	light.omni_range = 45.0; light.shadow_enabled = false
	bolt.add_child(light); light.global_position = at + Vector3(0, 2.0, 0)
	var sky := OmniLight3D.new(); sky.light_color = Color(0.75, 0.8, 1.0); sky.light_energy = 6.0; sky.omni_range = 160.0
	bolt.add_child(sky); sky.global_position = at + Vector3(0, 30.0, 0)
	var tween := bolt.create_tween()
	for strobe in [1.0, 0.3, 1.0, 0.0, 0.7, 0.0, 0.4, 0.0]:
		tween.tween_callback(func() -> void:
			bolt.visible = strobe > 0.0
			light.light_energy = 18.0 * strobe; sky.light_energy = 6.0 * strobe)
		tween.tween_interval(0.07)
	tween.tween_callback(bolt.queue_free)


func _chain(parent: Node3D, from: Vector3, to: Vector3, steps: int, radius: float, jitter: float, mat: Material) -> void:
	var points: Array[Vector3] = [from]
	for i in range(1, steps):
		var p: Vector3 = from.lerp(to, float(i) / steps)
		p += Vector3(randf_range(-jitter, jitter), 0, randf_range(-jitter, jitter))
		points.append(p)
	points.append(to)
	for i in points.size() - 1:
		var a: Vector3 = points[i]; var b: Vector3 = points[i + 1]
		var seg := MeshInstance3D.new()
		var cyl := CylinderMesh.new(); cyl.top_radius = radius; cyl.bottom_radius = radius * 0.8; cyl.height = a.distance_to(b)
		cyl.radial_segments = 6; cyl.rings = 1; seg.mesh = cyl; seg.material_override = mat
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(seg)
		seg.global_position = (a + b) * 0.5
		var dir: Vector3 = (b - a).normalized()
		var axis: Vector3 = Vector3.UP.cross(dir)
		if axis.length_squared() > 1e-6: seg.global_rotate(axis.normalized(), Vector3.UP.angle_to(dir))


func _particles(at: Vector3) -> void:
	var burst := Node3D.new(); burst.name = "StrikeBurst"; host.add_child(burst); burst.global_position = at
	# Sparks: tiny white-orange slivers thrown up and out, falling fast.
	var spark_mesh := BoxMesh.new(); spark_mesh.size = Vector3(0.03, 0.03, 0.12)
	var spark_mat := StandardMaterial3D.new(); spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.albedo_color = Color(1.0, 0.85, 0.5); spark_mat.emission_enabled = true; spark_mat.emission = Color(1.0, 0.6, 0.2); spark_mat.emission_energy_multiplier = 4.0
	spark_mesh.material = spark_mat
	burst.add_child(_emitter(spark_mesh, 260, 1.3, 9.0, 20.0, 75.0, -22.0, Vector2(0.6, 1.2), 12.0))
	# Dirt clods: brown chunks, slower, tumbling.
	var dirt_mesh := BoxMesh.new(); dirt_mesh.size = Vector3(0.09, 0.07, 0.1)
	var dirt_mat := StandardMaterial3D.new(); dirt_mat.albedo_color = Color(0.32, 0.22, 0.13); dirt_mesh.material = dirt_mat
	burst.add_child(_emitter(dirt_mesh, 160, 1.8, 5.0, 13.0, 55.0, -24.0, Vector2(0.5, 1.6), 8.0))
	# Dust: soft tan puffs drifting up and spreading.
	var dust_mesh := QuadMesh.new(); dust_mesh.size = Vector2(0.9, 0.9)
	var dust_mat := StandardMaterial3D.new(); dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dust_mat.albedo_color = Color(0.5, 0.42, 0.3, 0.35); dust_mat.vertex_color_use_as_albedo = true
	# A soft round puff, not a square: radial alpha falloff.
	var puff := GradientTexture2D.new(); puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5); puff.fill_to = Vector2(0.5, 0.0); puff.width = 64; puff.height = 64
	var soft := Gradient.new(); soft.set_color(0, Color(1, 1, 1, 1)); soft.set_color(1, Color(1, 1, 1, 0)); puff.gradient = soft
	dust_mat.albedo_texture = puff
	dust_mesh.material = dust_mat
	var dust := _emitter(dust_mesh, 36, 2.6, 1.5, 4.0, 85.0, -0.3, Vector2(0.5, 1.4), 1.0)
	var fade := Gradient.new(); fade.set_color(0, Color(1, 1, 1, 1)); fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new(); ramp.gradient = fade
	(dust.process_material as ParticleProcessMaterial).color_ramp = ramp
	burst.add_child(dust)
	get_tree().create_timer(4.5).timeout.connect(func() -> void: if is_instance_valid(burst): burst.queue_free())


func _emitter(mesh: Mesh, amount: int, lifetime: float, v_min: float, v_max: float, spread: float, gravity_y: float, scale_range: Vector2, spin: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount; p.lifetime = lifetime; p.one_shot = true; p.explosiveness = 0.95; p.emitting = true
	p.draw_pass_1 = mesh; p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-30, -5, -30), Vector3(60, 60, 60))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE; m.emission_sphere_radius = 0.35
	m.direction = Vector3(0, 1, 0); m.spread = spread
	m.initial_velocity_min = v_min; m.initial_velocity_max = v_max
	m.gravity = Vector3(0, gravity_y, 0)
	m.scale_min = scale_range.x; m.scale_max = scale_range.y
	m.angular_velocity_min = -spin * 60.0; m.angular_velocity_max = spin * 60.0
	m.damping_min = 0.2; m.damping_max = 1.0
	p.process_material = m
	return p


func _scorch(at: Vector3) -> GeometryInstance3D:
	var mark := MeshInstance3D.new(); mark.name = "Scorch"
	var disc := CylinderMesh.new(); disc.top_radius = 1.3; disc.bottom_radius = 1.3; disc.height = 0.02; disc.radial_segments = 24; disc.rings = 1
	var mat := StandardMaterial3D.new(); mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.05, 0.04, 0.03, 0.8); mat.roughness = 1.0
	disc.material = mat; mark.mesh = disc; mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	host.add_child(mark); mark.global_position = at + Vector3(0, 0.015, 0)
	return mark
