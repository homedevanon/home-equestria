extends Node3D
## Desktop presentation for the accepted Anon rig. Context adapters own actions;
## these untracked poses are visual animation, never controller/gesture samples.
const BODY := preload("res://player/anon_body.tscn")
const PUNCH := preload("res://player/animations/desktop_punch.tres")
const FORM := preload("res://world/life/player_form.gd")
const CONTACT_TIME := .28
## A boop is unhurried (dev 2026-10-29: "slower than an instant boop teleport"): the finger takes
## BOOP_REACH to arrive, rests a moment and takes BOOP_RETURN to go back to his side.
const BOOP_REACH := .55
const BOOP_RETURN := .5
## How far the boop finger tips up from level, so his hand comes from below and leaves her nose
## in view (dev 2026-10-29).
const BOOP_TILT := .45
const MAX_REACH := 1.05
signal action_contact(kind: String, target: Vector3, side: String)
signal action_finished(kind: String)
var avatar: Node3D
var camera: Camera3D
var player_body: Node3D
var active_side := "right"
var _hands: Dictionary = {}
var _holds: Dictionary = {}
var _rest_hands: Dictionary = {}
var _kind := ""
var _target := Vector3.ZERO
var _normal := Vector3.UP
var _elapsed := 0.0
var _duration := .7
var _contact_done := false
var _start_eye := Vector3.ZERO
var _start_forward := Vector3.FORWARD
var _sequence := 0
var _torso_yaw := 0.0
var _torso_forward := 0.0
var _enabled := true
var _avatar_processing := true
var _point_forward: Dictionary = {}
var _point_tip_local: Dictionary = {}

func setup(view: Camera3D, body: Node3D) -> void:
	camera = view
	player_body = body
	process_priority = -30
	# Keep the rig's scale/axes independent from the locomotion capsule.
	top_level = true
	for side: String in ["left", "right"]:
		var hand := Marker3D.new()
		hand.name = side.capitalize() + "PresentationHand"
		add_child(hand)
		_hands[side] = hand
	avatar = BODY.instantiate()
	avatar.name = "AnonBody"
	avatar.calibration_path = ""
	avatar.desktop_pose_driver = self
	add_child(avatar)
	avatar.setup(camera, _hands.left, _hands.right)
	_blob_shadow()
	_sync_height()
	var settings := get_node_or_null("/root/Settings")
	if settings != null and settings.has_signal("changed"):
		settings.changed.connect(_on_setting_changed)
	advance(0.0)

func _on_setting_changed(key: String) -> void:
	if key == "player/height_cm": _sync_height.call_deferred()

## His body stands at the rig's standing eye (player/desktop_player.gd apply_height, from Anon's
## chosen height), not at whatever the camera showed first: a live height change resizes the body,
## hands and every reach and offset measured in avatar.model_scale. Bare fixtures keep the old
## first-tall-eye reading.
func _sync_height() -> void:
	if not is_instance_valid(avatar) or not is_instance_valid(player_body) or not player_body.has_method("eye_height"): return
	if is_instance_valid(player_body.get("form_driver") as Object): return
	avatar.standing_eye_height = float(player_body.call("eye_height"))
	avatar.height_calibrated = true

## Desktop Anon has no walk cycle, so his cast shadow slid over the ground on still legs
## (thread 43671981). His body casts none here; a soft contact blob under his feet goes with
## him and hides with him (pony form, disabled). The headset body keeps its real shadow.
func _blob_shadow() -> void:
	for node: Node in avatar.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The hidden head's shadow-only stand-in (head_hide_modifier.gd) would float alone.
	for node: Node in avatar.find_children("*", "SkeletonModifier3D", true, false):
		if "shadow_head" in node: node.set("shadow_head", false)
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	gradient.colors = PackedColorArray([Color(0, 0, 0, .5), Color(0, 0, 0, .3), Color(0, 0, 0, 0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient; texture.width = 64; texture.height = 64
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(.5, .5); texture.fill_to = Vector2(1.0, .5)
	var blob := Decal.new()
	blob.name = "BlobShadow"
	blob.texture_albedo = texture
	# Feet level: from a little below the floor to his shins; steep surfaces (his legs, walls) fade out.
	blob.size = Vector3(.62, .6, .62)
	blob.position = Vector3(0, .05, 0)
	blob.normal_fade = .5
	avatar.add_child(blob)

func set_enabled(value: bool) -> void:
	var resuming := value and not _avatar_processing
	_enabled = value
	if not value: cancel_action()
	if is_instance_valid(avatar):
		avatar.visible = value
		_avatar_processing = value
		avatar.process_mode = Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED
		if resuming: avatar.reset_desktop_pose()

func is_busy() -> bool:
	return not _kind.is_empty()

## Turn of the boop hand about its pointing finger that lays it flat, palm down, back of the hand
## up (measured on the accepted rig: tools/anon/review_boop_hand.gd with EQ_BOOP_ROLL).
var BOOP_ROLL := -PI * .5

func request_action(kind: String, target: Vector3, normal: Vector3 = Vector3.UP, side: String = "right") -> bool:
	if not _enabled or is_busy() or not is_instance_valid(camera) or not target.is_finite() or not normal.is_finite(): return false
	if side not in ["left", "right"] or _holds.has(side): return false
	if kind not in ["punch", "slap", "reach", "boop", "pet", "hold", "read", "eat"]: return false
	if kind in ["punch", "slap"] and is_instance_valid(avatar.couch_rest_frame): return false
	if is_instance_valid(player_body) and player_body.get("controls_locked") == true: return false
	if camera.global_position.distance_to(target) > MAX_REACH * avatar.model_scale: return false
	_kind = kind
	active_side = side
	_target = target
	_normal = normal.normalized() if normal.length_squared() > .0001 else Vector3.UP
	# The nose offer can retain the surrounding coat's normal. A pointed
	# finger follows the actual approach line into the nose, not that patch.
	if kind == "boop": _normal = (camera.global_position - target).normalized()
	_elapsed = 0.0
	_duration = PUNCH.length if kind in ["punch", "slap"] else (.95 if kind == "pet" else (BOOP_REACH + .35 + BOOP_RETURN if kind == "boop" else .65))
	_contact_done = false
	_start_eye = camera.global_position
	_start_forward = -camera.global_basis.z
	_sequence += 1
	return true

## Continued contextual petting follows the same touched surface without
## restarting anticipation/contact. The input owner stops renewing on release. A boop
## follows her nose the same way.
func update_action_target(kind: String, target: Vector3, normal: Vector3 = Vector3.UP) -> bool:
	if _kind != kind or kind not in ["pet", "boop"] or not target.is_finite() or not normal.is_finite(): return false
	if not is_instance_valid(camera) or camera.global_position.distance_to(target) > MAX_REACH * avatar.model_scale: return false
	_target = target
	# A boop follows her live nose (pressed in after contact); its approach line stays.
	if kind == "boop": return true
	if normal.length_squared() > .0001: _normal = normal.normalized()
	_duration = maxf(_duration, _elapsed + .25)
	return true

## Held objects can supply their actual grip frame every frame. The opposite
## arm supports a book; this does not acquire an item or publish a tracked hand.
func set_hold_target(side: String, world: Transform3D, kind: String = "hold") -> void:
	if side not in ["left", "right"] or not world.is_finite(): return
	_holds[side] = {"frame": world, "kind": kind}

func clear_hold_target(side: String) -> void:
	_holds.erase(side)

## Physical rest owns its supported untracked hand markers. Held item/contact
## actions can still use one arm; the other follows the established rest pose.
func set_rest_hand_targets(left: Node3D, right: Node3D) -> void:
	_rest_hands = {"left": left, "right": right}
	if _kind in ["punch", "slap"]: cancel_action()

func clear_rest_hand_targets(left: Node3D, right: Node3D) -> void:
	if _rest_hands.get("left") == left and _rest_hands.get("right") == right: _rest_hands.clear()

func cancel_action() -> void:
	var previous := _kind
	_kind = ""
	_elapsed = 0.0
	_torso_yaw = 0.0
	_torso_forward = 0.0
	if not previous.is_empty(): action_finished.emit(previous)

func _process(delta: float) -> void:
	advance(delta)

func advance(delta: float) -> void:
	if not is_instance_valid(camera) or not is_instance_valid(avatar) or not camera.global_transform.is_finite(): return
	var human := not FORM.is_pony(FORM.active(get_tree()))
	var shown := _enabled and human
	if avatar.visible != shown: avatar.visible = shown
	if _avatar_processing != shown:
		_avatar_processing = shown
		avatar.process_mode = Node.PROCESS_MODE_INHERIT if _avatar_processing else Node.PROCESS_MODE_DISABLED
		if _avatar_processing: avatar.reset_desktop_pose()
	if not avatar.visible:
		cancel_action()
		return
	if is_instance_valid(player_body): global_position = player_body.global_position
	var flat_right := Vector3(camera.global_basis.x.x, 0, camera.global_basis.x.z).normalized()
	var forward := Vector3.UP.cross(flat_right).normalized()
	var frame := Basis(flat_right, Vector3.UP, -forward)
	var scale: float = avatar.model_scale
	var eye := camera.global_position
	var busy := is_busy()
	if busy:
		if eye.distance_to(_start_eye) > .2 * scale or (-camera.global_basis.z).dot(_start_forward) < .70 or (is_instance_valid(player_body) and player_body.get("controls_locked") == true):
			cancel_action()
			busy = false
		else:
			_elapsed += maxf(delta, 0.0)
	var contact_amount := 0.0
	var active_offset := Vector3.ZERO
	var helper_offset := Vector3.ZERO
	_torso_yaw = 0.0
	_torso_forward = 0.0
	if busy and _kind in ["punch", "slap"]:
		contact_amount = float(PUNCH.value_track_interpolate(0, _elapsed))
		active_offset = PUNCH.value_track_interpolate(1, _elapsed)
		helper_offset = PUNCH.value_track_interpolate(2, _elapsed)
		_torso_yaw = float(PUNCH.value_track_interpolate(3, _elapsed)) * (1.0 if active_side == "right" else -1.0)
		_torso_forward = float(PUNCH.value_track_interpolate(4, _elapsed)) * scale
	elif busy:
		var reach := BOOP_REACH if _kind == "boop" else .25
		var back := BOOP_RETURN if _kind == "boop" else .20
		contact_amount = smoothstep(0.0, reach, _elapsed) * (1.0 - smoothstep(_duration - back, _duration, _elapsed))
		_torso_forward = contact_amount * .018 * scale
	for side: String in ["left", "right"]:
		var sign_side := 1.0 if side == "right" else -1.0
		if not _point_forward.has(side) and not busy:
			var visible_hand: Dictionary = avatar.interaction_hand(side)
			var previous_marker: Node3D = _hands[side]
			if visible_hand.has("tip") and visible_hand.has("wrist"):
				var actual_forward: Vector3 = Vector3(visible_hand.tip) - Vector3(visible_hand.wrist)
				if actual_forward.length_squared() > .0001:
					_point_forward[side] = (previous_marker.global_basis.inverse() * actual_forward).normalized()
					_point_tip_local[side] = previous_marker.to_local(Vector3(visible_hand.tip)) / maxf(scale, .001)
		# Arms hang by the sides at rest (dev 2026-10-13: "they should be by my side"), not held
		# out in front of the chest; actions still reach out from here. Straight down, parallel to
		# the body (dev 2026-10-22: they jutted forward): the shoulder joint sits 0.24 m below the eye
		# and the arm reaches about 0.66 m to the palm (tools/anon/probe_rest_arms.gd), so the old
		# 0.80 m target bent the elbows and the IK pole swung the forearms out in front.
		var rest := Vector3(sign_side * .22, -.88, .01)
		var palm := eye + frame * rest * scale
		var hand_basis := frame
		# Hanging hands point their fingers at the ground, not ahead (dev 2026-10-14): turn the
		# rest frame so the measured finger direction (marker space) points straight down.
		var finger: Vector3 = _point_forward.get(side, Vector3.FORWARD)
		var finger_world := (frame * finger).normalized()
		if finger_world.cross(Vector3.DOWN).length_squared() > .000001:
			hand_basis = Basis(Quaternion(finger_world, Vector3.DOWN)) * frame
		# Animated body (player/anon_motion.gd): resting hands swing with the walk and lie on the
		# knees when seated; actions and held items still start from wherever the hand is.
		var animated_hand: Variant = avatar.motion_hand_marker(side) if avatar.has_method("motion_hand_marker") else null
		if animated_hand is Transform3D and (animated_hand as Transform3D).is_finite():
			var animated_weight: float = avatar.motion_amount()
			palm = palm.lerp((animated_hand as Transform3D).origin, animated_weight)
			hand_basis = hand_basis.orthonormalized().slerp((animated_hand as Transform3D).basis.orthonormalized(), animated_weight)
		var grip := .0
		var trigger: Variant = null
		var supported: Node3D = _rest_hands.get(side) as Node3D
		if is_instance_valid(avatar.couch_rest_frame) and is_instance_valid(supported) and supported.global_transform.is_finite():
			palm = supported.global_position
			hand_basis = supported.global_basis.orthonormalized()
		if busy:
			if side == active_side:
				# Closed-fist knuckles lie ahead of the palm frame. Keep that
				# measured offset outside the trunk instead of sinking the hand.
				var clearance := .125 if _kind == "boop" else (.055 if _kind == "punch" else .035)
				var surface := _target + _normal * clearance * scale
				var boop_direction := Vector3.ZERO
				if _kind == "boop":
					# Point into the nose, hand flat (dev 2026-10-14), tipped up BOOP_TILT so the hand
					# comes from below her nose. Keep the original fingertip reach and arm lengths.
					boop_direction = (Vector3(-_normal.x, 0.0, -_normal.z).normalized() + Vector3.UP * BOOP_TILT).normalized()
					surface = _target - boop_direction * clearance * scale
				if _kind == "pet": surface += flat_right * sin((_elapsed - .25) * TAU * 2.0) * .045 * contact_amount * scale
				var variation := Vector3(0, float((_sequence % 3) - 1) * .012, 0)
				palm = (palm + frame * (active_offset + variation) * scale).lerp(surface, contact_amount)
				# At extension palm == surface; normalizing their round-off
				# residue previously turned the finger sideways. Aim at the
				# real contact, retaining its deliberate palm clearance.
				var toward: Vector3
				if _kind == "boop":
					toward = boop_direction
				else:
					toward = (surface - palm).normalized()
					if toward.length_squared() < .5: toward = -_normal
				if absf(toward.dot(Vector3.UP)) < .95:
					var contact_basis := Basis.looking_at(toward, Vector3.UP)
					if _kind == "boop" and _point_forward.has(side):
						# Measure the accepted rig's actual open index direction
						# in its desktop source frame; its hand axes differ from
						# the controller convention. Rotate presentation only.
						contact_basis *= Basis(Quaternion(Vector3(_point_forward[side]), Vector3.FORWARD))
						# Right side up: turn the hand about the pointing finger so it lies flat,
						# back of the hand up (dev 2026-10-14: it faced him, then stood on its side).
						contact_basis = Basis(toward.normalized(), BOOP_ROLL) * contact_basis
						if _point_tip_local.has(side):
							# End at the visible index cap, measured from this rig's
							# post-IK rest hand, rather than treating its palm as a tip.
							var finger_contact: Vector3 = _target - contact_basis*Vector3(_point_tip_local[side])*scale
							palm += (finger_contact-surface)*contact_amount
					if _kind == "slap":
						var fingers := (Vector3.UP - _normal * _normal.dot(Vector3.UP)).normalized()
						var across := _normal * (1.0 if side == "right" else -1.0)
						contact_basis = Basis(across, -fingers.cross(across), -fingers)
					hand_basis = hand_basis.slerp(contact_basis, contact_amount)
				grip = 1.0 if _kind in ["punch", "boop"] else .0
				if _kind == "boop": trigger = 0.0
			else:
				# The helper rises with the punch and returns after the striking
				# shoulder. Never another independent controllable desktop hand.
				palm += frame * helper_offset * scale
				grip = .65 if _kind == "punch" else .15
		if _holds.has(side):
			var held: Dictionary = _holds[side]
			var held_frame: Transform3D = held.frame
			palm = held_frame.origin
			hand_basis = held_frame.basis.orthonormalized()
			# A massaging hand (spa_hands.gd) lies open on her leg.
			grip = .0 if held.kind == "rub" else .55
		var marker: Node3D = _hands[side]
		# Reading support is assigned after the loop below, so it is not
		# accidentally overwritten by the helper's ordinary rest pose.
		marker.global_transform = Transform3D(hand_basis, palm)
		avatar.set_grip(side, grip)
		avatar.set_trigger(side, trigger)
	for side: String in _holds:
		var held: Dictionary = _holds[side]
		var helper_side := "left" if side == "right" else "right"
		if held.kind == "read" and not _holds.has(helper_side) and not busy:
			var held_frame: Transform3D = held.frame
			var helper: Node3D = _hands[helper_side]
			helper.global_transform = Transform3D(held_frame.basis.orthonormalized(), held_frame.origin - held_frame.basis.x * (1.0 if side == "right" else -1.0) * .20 * scale)
			avatar.set_grip(helper_side, .4)
	if busy and not _contact_done and _elapsed >= (BOOP_REACH if _kind == "boop" else CONTACT_TIME):
		_contact_done = true
		action_contact.emit(_kind, _target, active_side)
	if busy and _elapsed >= _duration: cancel_action()

## Movement state for the animated desktop body (player/anon_motion.gd via anon_body.gd).
## Empty means "no clip": swimming, a knockdown and AnonPony keep their own presentation.
func motion_state() -> Dictionary:
	var body := player_body as CharacterBody3D
	if body == null or not is_instance_valid(camera): return {}
	if is_instance_valid(body.get("form_driver") as Object): return {}
	var knockdown: Variant = body.get("knockdown")
	if knockdown is Object and bool((knockdown as Object).get("active")): return {}
	var swimming: Variant = body.get("swimming")
	if swimming is Object and bool((swimming as Object).get("active")): return {}
	var seat: Variant = body.get("seat")
	if seat is Node3D and is_instance_valid(seat):
		var seat_forward := -(seat as Node3D).global_basis.z
		return {"seated": true, "seat": body.global_position, "seat_yaw": atan2(-seat_forward.x, -seat_forward.z)}
	var wings: Variant = body.get("wing_flight")
	var airborne: bool = body.get("flying") == true or (wings is Object and bool((wings as Object).get("active")))
	var flat_right := Vector3(camera.global_basis.x.x, 0, camera.global_basis.x.z).normalized()
	var forward := Vector3.UP.cross(flat_right).normalized()
	var moving := body.get_real_velocity()
	moving.y = 0.0
	var angle := 0.0
	if moving.length_squared() > .0001:
		angle = atan2(forward.cross(moving).y, forward.dot(moving))
	var crouch := 1.0 if body.get("crouching") == true else 0.0
	var stand_eye: Variant = body.get("_stand_eye")
	var eye: Variant = body.get("_eye_height")
	if (stand_eye is float) and (eye is float) and float(stand_eye) > .1:
		crouch = clampf((float(stand_eye) - float(eye)) / (float(stand_eye) * .45), 0.0, 1.0)
	return {"speed": moving.length(), "move_angle": angle, "on_floor": body.is_on_floor() and not airborne, "crouch": crouch}

## Anon body calls this after placing its ordinary inferred pelvis. The head,
## camera, feet and tracked VR endpoint code remain owned by their usual paths.
func apply_torso_pose(hip: Node3D, facing: Basis) -> void:
	if not is_busy(): return
	hip.global_position -= -facing.z * _torso_forward
	hip.global_basis = Basis(Vector3.UP, _torso_yaw) * hip.global_basis

## The pointing index tip (world) of `side`'s hand, measured on this rig; the palm if unmeasured.
func fingertip(side: String = "right") -> Vector3:
	var hand: Node3D = _hands.get(side) as Node3D
	if not is_instance_valid(hand): return Vector3.INF
	if _point_tip_local.has(side): return hand.global_transform * (Vector3(_point_tip_local[side]) * avatar.model_scale)
	return hand.global_position

func hand_frame(side: String = "right") -> Transform3D:
	var hand: Node3D = _hands.get(side) as Node3D
	return hand.global_transform if is_instance_valid(hand) else Transform3D.IDENTITY

func debug_snapshot() -> Dictionary:
	return {"kind": _kind, "elapsed": _elapsed, "contact_done": _contact_done, "torso_yaw": _torso_yaw, "target": _target, "active_side": active_side}
