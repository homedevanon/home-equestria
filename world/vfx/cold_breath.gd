extends Node3D
## Breath in the cold (dev 2026-11-10: "small details and liveliness"; the look brief's first
## feeling is shelter, cold outside and warm inside). In winter, or whenever it snows, a mare near
## the player breathes out a small cloud: a few soft wisps leave her mouth, drift forward and up,
## swell and are gone in a second and a half. Then nothing for a few seconds, each mare on her own
## rhythm. It is the cheapest sign there is that the air is cold and that she is alive.
##
## What a breath looks like, so the numbers below are not guesses: it starts the size of the
## mouth, not of the head; it is thin (most of it is seen against something dark or with light
## behind it); it slows at once, because warm breath has no push; it rises a little; it is gone
## before the next one. Indoors there is none (the house is warm).
##
## The wisp is a real asset (world/vfx/textures/smoke_soft_a.png, CC0) that dev may swap.
## Cost: PUFFS one-shot emitters of WISPS particles, started at most once per mare every few
## seconds; a 4 Hz step over the mares in the "ai_characters" group; while a mare breathes out,
## her emitter follows her mouth each frame. Nothing runs outside winter or snow but a 1 Hz check.
## Only mares with a head skeleton (hybrid_mare.gd boop_node) breathe; the far crowd does not.
## Rollback: ENABLED = false.

const ENABLED := true
const PLAYER_VIEW := preload("res://world/player_view.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const TEXTURE := preload("res://world/vfx/textures/smoke_soft_a.png")
## Mares breathing visibly at once, and how near the player a mare must be (metres).
const PUFFS := 6
const REACH := 12.0
const WISPS := 8
## Seconds between a mare's breaths [least, most]; how long she breathes out; how long a wisp lives.
const PERIOD := Vector2(3.4, 4.8)
const EXHALE := 0.9
const LIFE := 1.6
## Width of a full-grown wisp in metres, and its thickest opacity.
const SIZE := 0.34
const OPACITY := 0.34
const STEP := 0.25
## The mouth sits this far under the nose point the boop uses (metres); the face's own lip bones
## have their origins near the neck on this skeleton (first shots put the breath on her scarf).
const MOUTH_UNDER_NOSE := 0.05
## How much of her own motion the breath keeps, so a walking mare does not walk through it at once.
const CARRIED := 0.85

var _emitters: Array = []        # GPUParticles3D
var _skeletons: Array = []       # the mare's boop node each emitter follows, null = free
var _until: Array = []           # clock time the breath out ends
var _next: Dictionary = {}       # mare instance id -> clock time of her next breath
var _material: StandardMaterial3D
var _timer := 0.0
var _clock := 0.0
var _rng := RandomNumberGenerator.new()
## Breaths started since the scene loaded (read by tools/look/baseline_shots.gd).
var breaths := 0


func _ready() -> void:
	if not ENABLED:
		set_process(false)
		return
	# The emitters follow a mouth every drawn frame, not on physics ticks.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_rng.randomize()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_texture = TEXTURE
	_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_material.billboard_keep_scale = true
	_material.vertex_color_use_as_albedo = true
	_material.disable_receive_shadows = true
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.16)); grow.add_point(Vector2(0.35, 0.6)); grow.add_point(Vector2(1.0, 1.0))
	var grow_texture := CurveTexture.new(); grow_texture.curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.0)); fade.set_color(1, Color(1, 1, 1, 0.0))
	fade.add_point(0.12, Color(1, 1, 1, OPACITY)); fade.add_point(0.5, Color(1, 1, 1, OPACITY * 0.45))
	var fade_texture := GradientTexture1D.new(); fade_texture.gradient = fade
	for index: int in PUFFS:
		var puff := GPUParticles3D.new()
		puff.amount = WISPS
		puff.lifetime = LIFE
		puff.one_shot = true
		# The wisps leave over the breath out, not all at once.
		puff.explosiveness = 1.0 - EXHALE / LIFE
		puff.local_coords = false
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		puff.visibility_aabb = AABB(Vector3(-1.5, -1.0, -1.5), Vector3(3.0, 3.0, 3.0))
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		process.emission_sphere_radius = 0.015
		process.spread = 16.0
		process.initial_velocity_min = 0.35; process.initial_velocity_max = 0.6
		process.gravity = Vector3(0.0, 0.1, 0.0)
		process.inherit_velocity_ratio = CARRIED
		process.damping_min = 0.5; process.damping_max = 0.8
		process.angle_min = 0.0; process.angle_max = 360.0
		process.scale_min = 0.8; process.scale_max = 1.2
		process.scale_curve = grow_texture
		process.color_ramp = fade_texture
		puff.process_material = process
		var quad := QuadMesh.new(); quad.size = Vector2(SIZE, SIZE); quad.material = _material
		puff.draw_pass_1 = quad
		puff.emitting = false
		add_child(puff)
		_emitters.append(puff); _skeletons.append(null); _until.append(0.0)


func _process(delta: float) -> void:
	_clock += delta
	_timer -= delta
	if _timer <= 0.0:
		_timer = STEP
		_decide()
	for index: int in _emitters.size():
		# Untyped first: a freed node must not be assigned to a typed variable.
		var held: Variant = _skeletons[index]
		if held == null: continue
		if _clock >= float(_until[index]) or not is_instance_valid(held) or not (held as Node).is_inside_tree():
			_skeletons[index] = null
			continue
		var mouth := _mouth(held as Node)
		if mouth.is_finite(): (_emitters[index] as GPUParticles3D).global_position = mouth


## The 4 Hz step: is it cold, and which mare near the player is due a breath.
func _decide() -> void:
	var tree := get_tree()
	var seasons: Node = tree.get_first_node_in_group("season_state")
	var weather: Node = tree.get_first_node_in_group("weather")
	var params: Dictionary = weather.get("params") if weather != null and weather.get("params") is Dictionary else {}
	var cold: bool = float(params.get("snow", 0.0)) > 0.05 or (seasons != null and str(seasons.call("season")) == "winter")
	if not cold:
		_timer = 1.0
		return
	var camera := PLAYER_VIEW.camera(self)
	if camera == null: return
	var eye := camera.global_position
	if not eye.is_finite(): return
	# Breath is lit by what light there is: nearly white by day, a dim blue-grey at night.
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(clock.call("daylight")) if clock != null else 1.0
	# It scatters the sky's light, so it stays a little lighter than the snow behind it.
	_material.albedo_color = Color(0.62, 0.68, 0.86).lerp(Color(1.0, 1.0, 1.0), daylight)
	if _next.size() > 96: _next.clear()
	for node: Node in tree.get_nodes_in_group("ai_characters"):
		var mare := node as Node3D
		if mare == null or not mare.is_visible_in_tree(): continue
		if mare.global_position.distance_squared_to(eye) > REACH * REACH: continue
		var id := mare.get_instance_id()
		if not _next.has(id):
			_next[id] = _clock + _rng.randf_range(0.2, PERIOD.y)
			continue
		if _clock < float(_next[id]): continue
		_next[id] = _clock + _rng.randf_range(PERIOD.x, PERIOD.y)
		var slot := _skeletons.find(null)
		if slot < 0: return
		_breathe(mare, slot)


func _breathe(mare: Node3D, slot: int) -> void:
	var boop: Variant = mare.get("boop_node")
	if not (boop is Node) or not (boop as Node).is_inside_tree(): return
	var skeleton := (boop as Node).get("head_skeleton") as Skeleton3D
	if skeleton == null or not skeleton.is_inside_tree() or int((boop as Node).get("_head_bone")) < 0: return
	var mouth := _mouth(boop as Node)
	if not mouth.is_finite() or HOUSE.at(get_tree(), mouth) != null: return
	# Out of the mouth: from the middle of the skull through the muzzle, never much downward.
	var skull: Vector3 = (boop as Node).call("skull_world")
	var out := mouth - skull
	if out.length_squared() < 0.0001: return
	out = out.normalized()
	out.y = maxf(out.y, -0.2)
	var puff := _emitters[slot] as GPUParticles3D
	(puff.process_material as ParticleProcessMaterial).direction = out.normalized()
	puff.global_position = mouth
	_skeletons[slot] = boop; _until[slot] = _clock + EXHALE
	puff.restart()
	breaths += 1


## Where her breath leaves her: just under the nose point of her boop node. INF when unknown.
func _mouth(boop: Node) -> Vector3:
	var skeleton := boop.get("head_skeleton") as Skeleton3D
	if skeleton == null or not skeleton.is_inside_tree(): return Vector3.INF
	# Spike's touch node has a head skeleton but no muzzle point: he has no breath cloud (the call
	# raised a script error on every breath and every frame of one, 1,093 in a 2 minute winter run).
	if not boop.has_method(&"muzzle_world") or not boop.has_method(&"skull_world"): return Vector3.INF
	var nose: Vector3 = boop.call("muzzle_world")
	return nose - skeleton.global_basis.y.normalized() * MOUTH_UNDER_NOSE
