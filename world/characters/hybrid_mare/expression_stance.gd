extends RefCounted
## An angry standing accent, through the existing terrain/leg solver. The motor,
## source poses and ground locks stay authoritative; these offsets never accumulate.
const SPREAD := .023
const LOWER := .020
const ENTER_SECONDS := .55
const LEAVE_SECONDS := .4
const WALK_RELEASE_SECONDS := .12
var pony: CharacterBody3D
var amount := 0.0
var _drop := 0.0

func advance(delta: float) -> void:
	if amount <= 0.0 and pony.expressions.brace_weight <= 0.0: return
	if unavailable():
		amount = 0.0
		return
	var standing: bool = pony.state == pony.Motion.STANDING and pony.actual_speed < .025 \
		and pony._desired.length_squared() < .0001 and pony._turn_step_speed < .025
	var wanted: float = pony.expressions.brace_weight if standing else 0.0
	var seconds := ENTER_SECONDS if wanted > amount else (LEAVE_SECONDS if standing else WALK_RELEASE_SECONDS)
	amount = move_toward(amount, wanted, delta / seconds)

func unavailable() -> bool:
	if pony.sim_tier != pony.SimTier.HERO or not pony.corrections_enabled or not pony._initialized: return true
	if pony.motion_paused or pony.sleeping or not pony.grounded() or pony._held: return true
	if pony.carry.blend > 0.0 or pony.hoof_hold.active() or not pony._interaction.is_empty(): return true
	if pony.posture != null and pony.posture.active(): return true
	if pony.water_escape.active or is_instance_valid(pony.moving_support): return true
	if pony.activity_mouth_pose != null and pony.activity_mouth_pose.active(): return true
	if pony.pinkie_bounce != null and pony.pinkie_bounce.active(): return true
	return false

func apply_body() -> void:
	_drop = LOWER * amount * pony.body_scale
	if _drop > 0.0: pony.pivot.position.y -= _drop

func apply_contacts() -> void:
	if amount <= 0.0: return
	var targets: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var sideways: Vector3 = pony.global_basis.x.normalized()
	for i in pony.feet.size():
		var foot: Dictionary = pony.feet[i]
		var old: Vector3 = foot.target
		var normal: Vector3 = foot.normal
		# Walking may begin during the short release. Its lifted hooves belong to
		# the gait, while loaded hooves and the body ease out of the accent.
		if not foot.planted:
			targets.append(old)
			normals.append(normal)
			continue
		var leg: Dictionary = pony.profile.legs[i]
		var side := signf(Vector3(leg.neutral_sole).x)
		var spread: Vector3 = sideways * side * SPREAD * amount * pony.body_scale
		var hit: Dictionary = pony._probe(old + spread)
		# Never spread a hoof over an edge or lower the body without support.
		if not foot.valid or hit.is_empty() or absf(float(hit.position.y) - old.y) > .04 * pony.body_scale:
			pony.pivot.position.y += _drop
			_drop = 0.0
			amount = 0.0
			return
		targets.append(hit.position)
		normals.append(hit.normal)
	for i in pony.feet.size():
		var foot: Dictionary = pony.feet[i]
		foot.basis = Basis(Quaternion(Vector3(foot.normal), normals[i])) * Basis(foot.basis)
		foot.target = targets[i]
		foot.normal = normals[i]
