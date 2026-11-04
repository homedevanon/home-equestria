extends RefCounted
## Pinkie's occasional happy travel style. Navigation and the swept ground motor remain
## authoritative. Existing native trot leg samples share one contact/swing clock; only the
## presentation rises above that ground frame, after certifying the space it will occupy.
const FK := preload("res://world/characters/locomotion/limb_solver.gd")
const WATER := preload("res://world/water/water_contact.gd")
const VIEW := preload("res://world/player_view.gd")
const STANCE := 0.26
const CYCLE := 0.58
const LIFT := 0.18
const BLEND_SECONDS := 0.32
const FACE_SOURCE := "pinkie_bounce"
var pony: CharacterBody3D
var amount := 0.0
var phase := 0.0
var remaining := 0.0
var cooldown := 0.0
var autonomous := true
var cycles := 0
var _check_wait := 0.0
var _ending := false
var _planted := false
var _anchors := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var _normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
var _rng := RandomNumberGenerator.new()

func bind(actor: CharacterBody3D) -> void:
	pony = actor
	_rng.randomize()
	cooldown = _rng.randf_range(18.0, 40.0)

func active() -> bool:
	return remaining > 0.0 or amount > 0.0

## Also usable by an authored happy moment; it never bypasses the physical/interaction gates.
func request(seconds: float = 4.0) -> bool:
	if active() or not eligible(): return false
	# A clip-tier actor has no active collision body. Wake it before the swept clearance test.
	var previous_tier: int = pony.sim_tier
	var previous_phase: int = pony.sim_phase
	pony.set_sim_tier(pony.SimTier.HERO, 0)
	if not clear_route():
		pony.set_sim_tier(previous_tier, previous_phase)
		return false
	remaining = clampf(seconds, 1.2, 6.0)
	phase = 0.0
	amount = 0.0
	_ending = false
	_planted = false
	cycles = 0
	return true

func advance(delta: float) -> void:
	if not active():
		cooldown = maxf(0.0, cooldown - delta)
		_check_wait -= delta
		if not autonomous or cooldown > 0.0 or _check_wait > 0.0: return
		_check_wait = 1.0
		if eligible():
			cooldown = _rng.randf_range(40.0, 90.0)
			if _rng.randf() < 0.55: request(_rng.randf_range(2.8, 5.0))
		return
	# Physical owners take over immediately. Ordinary stopping/conversation settles this
	# short hop and fades its pose; neither keeps her eyes shut or delays an interaction.
	if physically_interrupted():
		cancel()
		return
	remaining = maxf(0.0, remaining - delta)
	if remaining <= 0.0 or not eligible(): _ending = true
	var previous := phase
	phase = fposmod(phase + delta / CYCLE, 1.0)
	if phase < previous:
		cycles += 1
		_planted = false
		if not _ending and not clear_route(): _ending = true
	# Finish the flight part before returning to normal contact. Fade-out at ground level
	# holds this clock, so an expiring style cannot start one extra hop during its blend.
	if _ending and (phase < STANCE or previous < STANCE):
		phase = minf(phase, STANCE * 0.5)
		remaining = 0.0
		amount = move_toward(amount, 0.0, delta / BLEND_SECONDS)
	else:
		amount = move_toward(amount, 1.0, delta / BLEND_SECONDS)
	if not _ending and pony.expressions != null:
		pony.expressions.touch(FACE_SOURCE, 0.0, amount)
	elif pony.expressions != null:
		pony.expressions.release_touch(FACE_SOURCE)
	if not active():
		cooldown = _rng.randf_range(40.0, 90.0)
		_planted = false

func cancel() -> void:
	remaining = 0.0
	amount = 0.0
	_ending = false
	_planted = false
	cooldown = _rng.randf_range(40.0, 90.0)
	if pony.expressions != null: pony.expressions.release_touch(FACE_SOURCE)

func physically_interrupted() -> bool:
	return pony.motion_paused or pony._held or pony.hoof_hold.active() or pony.carry.blend > 0.0 \
		or not pony._interaction.is_empty() or pony.sleeping \
		or (pony.posture != null and pony.posture.active()) \
		or (pony.thrown != null and pony.thrown.active()) \
		or (pony.flight != null and pony.flight.active()) or pony.water_escape.active \
		or is_instance_valid(pony.moving_support) \
		or (pony.activity_mouth_pose != null and pony.activity_mouth_pose.active())

func eligible() -> bool:
	if pony.identity == null or pony.identity.character() != "pinkie_pie" or physically_interrupted(): return false
	if not pony.grounded() or pony.backing or pony.has_meta("affection_active"): return false
	if is_instance_valid(pony.conversation_target) or is_instance_valid(pony.action_gaze_target): return false
	if pony.head != null and pony.head.is_speaking(): return false
	var speed: float = Vector2(pony.velocity.x, pony.velocity.z).length() / pony.body_scale
	if speed < 0.65 or speed > 2.5 or absf(pony._yaw_rate) > 0.45: return false
	if pony._desired.length_squared() < 0.04 and not pony._nav_motion: return false
	if pony.is_on_wall() or pony._blocked or pony._slope_angle > deg_to_rad(7.0): return false
	var nav: Node = pony.get_node_or_null("Navigator")
	if nav != null:
		if nav.house_travel.active() or nav.house_travel.here(pony) != null: return false
		if nav._contact_approach.is_finite(): return false
		if nav._has_target and pony.global_position.distance_to(nav.target) < 3.0: return false
	elif pony._indoors(pony.global_position):
		return false
	var camera := VIEW.camera(pony)
	if camera != null:
		var distance := camera.global_position.distance_squared_to(pony.global_position)
		if distance < 2.4 * 2.4 or distance > 45.0 * 45.0: return false
	return true

## Flat, dry travel only. Reject steps, banks, gaps and low ceilings before the next hop.
## The grounded capsule still collides normally with anything that arrives afterwards.
func clear_route() -> bool:
	var origin: Vector3 = pony.global_position
	var forward: Vector3 = -pony.global_basis.z.normalized()
	var travel: float = maxf(pony.actual_speed, 0.65 * pony.body_scale) * CYCLE + 0.3 * pony.body_scale
	var space := pony.get_world_3d().direct_space_state
	for part: float in [0.0, 0.5, 1.0]:
		var at := origin + forward * travel * part
		var hit: Dictionary = pony._probe(at)
		if hit.is_empty() or absf(float(hit.position.y) - origin.y) > 0.035 * pony.body_scale: return false
		if Vector3(hit.normal).angle_to(Vector3.UP) > deg_to_rad(7.0): return false
		if WATER.surface_above(space, at + Vector3.UP * 0.01) > at.y: return false
	var low := pony.global_transform
	low.origin += Vector3.UP * 0.04 * pony.body_scale
	var rise: Vector3 = Vector3.UP * (LIFT + 0.08) * pony.body_scale
	if pony.test_move(low, rise, null, 0.005): return false
	low.origin += rise
	if pony.test_move(low, forward * travel, null, 0.005): return false
	return true

func sample(normal: Array[Transform3D]) -> Array[Transform3D]:
	if amount <= 0.0: return normal
	var phases := PackedFloat64Array()
	for leg: Dictionary in pony.profile.legs:
		var progress: float = phase / STANCE * leg.contact_span if phase < STANCE \
			else leg.contact_span + (phase - STANCE) / (1.0 - STANCE) * (1.0 - leg.contact_span)
		phases.append(float(leg.contact_start) + progress)
	# Existing sample offsets/scales and constraints are unchanged. Reuse only the legs;
	# ordinary secondary/head/tail motion continues through the usual owner afterwards.
	var synced: Array[Transform3D] = pony.profile.sample_steps(phase, phases)
	for leg: Dictionary in pony.profile.legs:
		for bone: int in leg.chain:
			normal[bone] = normal[bone].interpolate_with(synced[bone], amount)
	return normal

func apply_body() -> void:
	if amount <= 0.0 or phase < STANCE: return
	var flight := (phase - STANCE) / (1.0 - STANCE)
	var lift: float = 4.0 * flight * (1.0 - flight) * LIFT * pony.body_scale * amount
	# A moving obstacle may enter a previously clear arc. Keep the presented body below it
	# too; the ordinary motor still handles forward contact and navigation repair.
	var from: Transform3D = pony.global_transform
	from.origin += Vector3.UP * 0.01 * pony.body_scale
	if pony.test_move(from, Vector3.UP * lift, null, 0.005):
		_ending = true
		return
	pony.pivot.position.y += lift

## Preserve the normal contact solution during entry/exit; at full weight the synchronous
## stance anchors all four hooves and flight follows the untouched source pose, not floor IK.
func contacts(delta: float) -> void:
	var pose: Array[Transform3D] = pony.source_pose
	var local_fk: Array[Transform3D] = FK.forward_kinematics(pony.profile.parents, pose)
	var frame: Transform3D = pony.global_transform * pony.pivot.transform * pony._model_frame
	var stance := phase < STANCE
	for i in 4:
		var leg: Dictionary = pony.profile.legs[i]
		var foot: Dictionary = pony.feet[i]
		var sole: Vector3 = pony.profile.sole_point(leg, local_fk)
		var source: Vector3 = frame * sole
		var target := source
		if stance:
			if not _planted:
				var hit: Dictionary = pony._probe(source)
				_anchors[i] = Vector3(hit.position) if not hit.is_empty() else source
				_normals[i] = Vector3(hit.normal) if not hit.is_empty() else Vector3.UP
				if amount > 0.8: pony._hoof_plants.plant(i, _anchors[i])
			target = _anchors[i]
		foot.dynamic_sole = local_fk[leg.leaf].affine_inverse() * sole
		foot.target = Vector3(foot.target).lerp(target, amount)
		var basis: Basis = (frame * local_fk[leg.leaf]).basis.orthonormalized()
		foot.basis = Basis(foot.basis).slerp(basis, amount)
		if amount >= 1.0:
			foot.planted = stance
			foot.valid = stance
			foot.lock = target
			foot.landing = _anchors[i]
			foot.landing_normal = _normals[i]
			foot.normal = _normals[i]
			foot.weight = 1.0 if stance else 0.0
			foot.offset = Vector3.ZERO
			foot.landing_predicted = false
			foot.limited = false
			foot.age += delta
	_planted = stance
