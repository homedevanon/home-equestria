extends RefCounted
## One magic hold: a thing lifted in a pony's magic, its glow, and letting it go. Shared by the
## unicorn's G telekinesis (player/unicorn_telekinesis.gd, goal along the view) and the VR magic
## hands (player/magic_hands/magic_hand.gd, goal at a controller's wisp), so both lift the same
## things the same way:
## - a pony (anything with begin_grab) is held with her own chest hold, pony_hold_api.gd;
## - a loose physics object floats with gravity off, driven by velocity toward the goal; items
##   resting where they were placed (frozen apples, shelved goods with an item_id) unfreeze.
## The thing wears the GMod magic aura: through the unicorn's UnicornMagic (her horn lights) when
## one is given, else a bare MagicAura in the caster's colour (earth ponies, pegasi).
## No class_name: callers preload this file.
const UNICORN_MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const MAGIC_AURA := preload("res://world/characters/magic/magic_aura.gd")
## Velocity per metre of error, and its ceiling, for a held object.
const FOLLOW_GAIN := 12.0
const FOLLOW_MAX := 14.0
## Angular velocity per radian of error, and its ceiling, when the goal has a rotation.
const TURN_GAIN := 10.0
const TURN_MAX := 12.0
## Heavier than this does not lift (wagons, carts).
const MAX_MASS := 150.0

var target: Node3D
var _gravity := 1.0
var _meshes: Array = []
var _magic: Node
var _active := false


## What magic would lift if it caught `hit` (a collider): the pony it belongs to (never `own`, the
## caster's own body), else a loose RigidBody3D light enough to lift, else null.
static func liftable(hit: Object, own: Node = null) -> Node3D:
	if not is_instance_valid(hit): return null
	# A pony's body parts are children of her CharacterBody3D.
	var pony := hit as Node
	while pony != null and not pony.has_method("begin_grab"): pony = pony.get_parent()
	if pony != null and pony != own: return pony as Node3D
	if hit is RigidBody3D:
		var body := hit as RigidBody3D
		# A pony's belongings shown in her home (world/mechanics/gifts/belongings.gd) stay put.
		if body.has_meta("belonging_key"): return null
		if (not body.freeze or body.has_meta("item_id")) and body.mass <= MAX_MASS: return body
	return null


func holding() -> bool:
	return is_instance_valid(target)


## The held thing was freed (eaten, stashed) without end(): call end() to put the glow out.
func stale() -> bool:
	return _active and not is_instance_valid(target)


## Lifts `thing` (from liftable()) towards `goal`; `from` is the caster's head. `magic` is the
## unicorn's UnicornMagic or null; `color` and `strength` are for the bare aura. False when it
## cannot be lifted.
func begin(thing: Node3D, goal: Vector3, from: Vector3, magic: Node = null, color := Color.MEDIUM_PURPLE, strength := 1.0) -> bool:
	if not is_instance_valid(thing) or not thing.is_inside_tree(): return false
	if thing.has_method("begin_grab"):
		thing.call("begin_grab", "chest", goal, from)
	elif thing is RigidBody3D:
		var body := thing as RigidBody3D
		body.freeze = false
		_gravity = body.gravity_scale
		body.gravity_scale = 0.0
		body.can_sleep = false
		body.sleeping = false
	else:
		return false
	target = thing
	_active = true
	if is_instance_valid(magic) and magic.has_method("glow_object"):
		_magic = magic
		_meshes = magic.call("glow_object", target, strength)
		if magic.has_method("hold"): magic.call("hold", true)
	else:
		var aura: Node3D = MAGIC_AURA.create(target, color, strength)
		_meshes = [aura] if aura != null else []
	return true


## Moves the held thing toward `goal` (a Vector3, or a Transform3D whose rotation the object also
## turns to). False when nothing is held or it is more than `max_error` from the goal, which the
## caller treats as losing it.
func follow(goal: Variant, from: Vector3, max_error := INF) -> bool:
	if not is_instance_valid(target): return false
	var at: Vector3 = (goal as Transform3D).origin if goal is Transform3D else goal
	if not at.is_finite(): return true
	if target.has_method("update_grab"):
		target.call("update_grab", at, from)
		return true
	var body := target as RigidBody3D
	if body == null: return false
	var error := at - body.global_position
	if error.length() > max_error: return false
	body.linear_velocity = (error * FOLLOW_GAIN).limit_length(FOLLOW_MAX)
	if goal is Transform3D and (goal as Transform3D).basis.is_finite():
		var turn := ((goal as Transform3D).basis.orthonormalized() * body.global_basis.orthonormalized().inverse()).get_rotation_quaternion()
		var angle := turn.get_angle()
		if angle > PI: angle -= TAU
		var axis := turn.get_axis()
		body.angular_velocity = (axis * angle * TURN_GAIN).limit_length(TURN_MAX) if axis.is_finite() and absf(angle) > 0.001 else Vector3.ZERO
	else:
		body.angular_velocity *= 0.85
	return true


## Lets go. An object gets `velocity` when one is given (null keeps what it has); a pony is thrown
## with `pony_throw` when it is not zero and she can be, else set down. Returns what it was.
func end(velocity: Variant = null, pony_throw := Vector3.ZERO) -> Node3D:
	var was := target
	if is_instance_valid(target):
		if target.has_method("end_interaction"):
			var thrown: bool = pony_throw != Vector3.ZERO and target.has_method("throw_pony") and target.call("throw_pony", pony_throw) == true
			if not thrown: target.call("end_interaction")
		elif target is RigidBody3D:
			var body := target as RigidBody3D
			body.gravity_scale = _gravity
			body.can_sleep = true
			if velocity is Vector3 and (velocity as Vector3).is_finite(): body.linear_velocity = velocity
	UNICORN_MAGIC.unglow_object(_meshes)
	if is_instance_valid(_magic) and _magic.has_method("hold"): _magic.call("hold", false)
	_meshes = []; _magic = null; target = null; _active = false
	return was if is_instance_valid(was) else null
