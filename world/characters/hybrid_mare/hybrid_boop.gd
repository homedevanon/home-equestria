extends Node
## Boop: a pointed finger pressed against her nose makes a squee/honk. The World setting
## "Boop Makes Mares Horny" restores the old flustered face, blush and floating hearts.
##
## Trigger rule (dev): ONLY when the finger is outstretched and the physics hand actually
## collides with and stops against her nose. So three gates, every physics tick, per hand:
##   1. pointing pose: trigger released (index extended) while the grip is squeezed;
##   2. the hand's RigidBody3D reports the Snoot body among its colliding bodies (the physics
##      hand is blocked by it, so the visible hand stops on her nose instead of clipping in);
##   3. the contact is with the NOSE sphere itself (body-shape contact signals name the shape),
##      not the muzzle or skull spheres.
## Each finger withdrawal rearms immediately; no cooldown or timed rearm delay.
##
## The Snoot is an AnimatableBody3D (layer 2 = pony, mask 0) with a small sphere at the nose
## and a larger one for the skull, following the OpenPony head bones each physics tick. The
## mare's own body has mask 1 so she never collides with it; the player's body capsule and
## physics hands already collide with layer 2.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const SQUEES := [preload("res://world/audio/pony/squee_1.ogg"), preload("res://world/audio/pony/squee_2.ogg")]
## Kiss sounds (KISS_SOURCE.md): kiss.wav plus kiss_2.wav, kiss_3.wav, ... when present.
static var _kiss_streams: Array[AudioStream] = []
static var _soft_kisses := 0
## Soft breaths (breath_NN.wav, KISS_SOURCE.md) for the deep-kiss breather; very quiet.
static var _breath_streams: Array[AudioStream] = []
var _breath_sound: AudioStreamPlayer3D
const FREDDY_PATH := "res://world/audio/pony/freddy_nose_honk.wav"
static var _freddy_stream: AudioStreamWAV
@export_enum("Mixed", "Squees", "Freddy honk") var boop_sound := 0
const NOSE_BONE := "mFaceNoseCenter"
const HEAD_BONE := "mHead"
const CHEEK_BONES := {"left": "mFaceCheekLowerLeft", "right": "mFaceCheekLowerRight"}
## Head as three spheres in native head-bone space, so a pointed finger can travel along the
## muzzle to the nose without the palm jamming on a big skull ball: skull (back of the head),
## muzzle (nose base), nose tip.
const SKULL_LOCAL := Vector3(0.0, 0.135, 0.0)
const SKULL_RADIUS := 0.085
const MUZZLE_BONE := "mFaceNoseBase"
const MUZZLE_RADIUS := 0.045
const NOSE_RADIUS := 0.03
## Collision layer bit for her face (3 = value 4): hands stop on it, the player's body and her
## own capsule ignore it.
const FACE_LAYER := 4
## Per identity (PonyIdentity.heart_colors); Dash defaults.
var heart_colors: Array[Color] = [Color("ff5c8a"), Color("ff2f5f"), Color("ff86b0")]

@export var tip_reach := 0.055
## Index finger extended = trigger released. Grip is free: a fist with the index out and an
## open-hand poke both count (dev: "only when my finger is outstretched").
@export var pointing_trigger_max := 0.3
@export var pointing_grip_min := 0.0
## Gentle by request (dev 2026-10-06): about a third as loud as the old -18 dB.
@export var squee_db := -28.0
@export var blush_color := Color(1.0, 0.42, 0.58)
## Blush envelope seconds: rise, hold, fall.
@export var blush_rise := 0.25
@export var blush_hold := 2.4
@export var blush_fall := 1.6

var mare: Node3D
var head_skeleton: Skeleton3D
var snoot: AnimatableBody3D
var boops := 0
var kisses := 0
var blush_amount := 0.0
## Dialogue owns this weight, independently of the physical blush envelope below.
## Releasing a face must not start another several-second touch blush.
var expression_blush := 0.0:
	set(value):
		value = clampf(value, 0.0, 1.0)
		if is_equal_approx(expression_blush, value): return
		expression_blush = value
		_blush_idle = false
		wake_tick()
## 0..1 from her flustered face: the blush spreads from the cheeks across the bridge of the nose.
var nose_blush := 0.0
var _nose_decal: Decal
var hearts_alive := 0
var _nose_bone := -1
var _head_bone := -1
var _hands: Dictionary = {}       # side -> RigidBody3D
var _controllers: Dictionary = {} # side -> Node (XRController3D)
var _tip_bones: Dictionary = {}   # side -> int
var _input_override: Dictionary = {} # side -> Vector2(trigger, grip), tests
var _latched: Dictionary = {"left": false, "right": false}
## Ignore momentary contact loss from her own flinch while the finger stays still.
var _touch_tip: Dictionary = {}
var _nose_contacts: Dictionary = {"left": 0, "right": 0}   # live contacts with NoseShape per hand
var _blush_time := -1.0
var _decals: Array[Decal] = []
var _squee: AudioStreamPlayer3D
var _kiss_sound: AudioStreamPlayer3D
var _hearts: Array = []  # [{sprite, t, life, origin, phase}]
var _heart_texture: Texture2D
var _boop_head_nudge := 0.0
const SCRATCH := preload("res://world/characters/hybrid_mare/head_scratch_gesture.gd")
var _skull_contacts := {"left":0,"right":0}
var _scratches := {"left":SCRATCH.new(),"right":SCRATCH.new()}
var head_scratches := 0
var strong_blush_time := 0.0
var hand_sampler: Callable
var _visible_samples: Dictionary = {}
var _visible_ready:Dictionary={}
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md) moves the face spheres and blush decals
## with the same transforms; null keeps _sync_snoot()'s GDScript.
var _native: RefCounted
var _native_bones := PackedInt32Array()
var _skull_shape: Node3D
var _muzzle_shape: Node3D
## A pointing fingertip within FINGER_NEAR of her nose: hybrid_mare.gd holds her head still so the
## nose stays where the finger is aimed (dev 2026-10-29: "keep their nose still").
const FINGER_NEAR := 0.25
var finger_near := false
## A finger on her nose pushes it in a little (dev 2026-10-29): the nose bone and the NoseShape
## sphere move PRESS_DEPTH along the press, so the physics hand follows it in.
const PRESS_DEPTH := 0.008
## World offset of the pressed nose, eased toward the press and back.
var press_offset := Vector3.ZERO
var _press_dir := Vector3.ZERO
var _press_until := 0
var _nose_shape: Node3D
var _nose_press: NosePress


## Moves one bone by a skeleton-space offset after the face modifiers (mouth, eyes) ran. Off while
## nothing presses, so it costs nothing on the crowd.
class NosePress extends SkeletonModifier3D:
	var bone := -1
	var offset := Vector3.ZERO

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null or bone < 0: return
		var parent := sk.get_bone_parent(bone)
		var parent_basis := sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
		sk.set_bone_pose_position(bone, sk.get_bone_pose_position(bone) + parent_basis.inverse() * offset)


func setup(target_mare: Node3D, skeleton: Skeleton3D) -> void:
	mare = target_mare
	head_skeleton = skeleton
	_nose_bone = skeleton.find_bone(NOSE_BONE)
	_head_bone = skeleton.find_bone(HEAD_BONE)
	if _nose_bone < 0 or _head_bone < 0:
		push_error("Hybrid boop: nose/head bones missing on the OpenPony head")
		return
	snoot = AnimatableBody3D.new()
	snoot.name = "Snoot"
	snoot.sync_to_physics = true
	snoot.collision_layer = FACE_LAYER | preload("res://player/head_contact_query.gd").LAYER
	snoot.collision_mask = 0
	for spec in [[NOSE_RADIUS, "NoseShape"], [MUZZLE_RADIUS, "MuzzleShape"], [SKULL_RADIUS, "SkullShape"]]:
		var shape := SphereShape3D.new()
		shape.radius = spec[0]
		var cs := CollisionShape3D.new()
		cs.name = spec[1]
		cs.shape = shape
		if spec[1]=="SkullShape":cs.shape=preload("res://world/characters/hybrid_mare/skull_contact.tres")
		snoot.add_child(cs)
	# Child of the mare herself, so a ray hit on the snoot resolves to her `pet`.
	mare.add_child(snoot)
	_nose_shape = snoot.get_node("NoseShape")
	_nose_press = NosePress.new()
	_nose_press.name = "NosePress"
	_nose_press.bone = _nose_bone
	_nose_press.active = false
	skeleton.add_child(_nose_press)
	_native = NATIVE.create() if NATIVE.enabled("boop") else null
	if _native != null:
		_native_bones = PackedInt32Array([_head_bone, _nose_bone, skeleton.find_bone(MUZZLE_BONE),
			skeleton.find_bone(CHEEK_BONES["left"]), skeleton.find_bone(CHEEK_BONES["right"])])
		_skull_shape = snoot.get_node("SkullShape")
		_muzzle_shape = snoot.get_node("MuzzleShape")
	_sync_snoot()
	_build_blush()
	_squee = AudioStreamPlayer3D.new()
	_squee.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	_squee.name = "BoopSquee"
	_squee.max_distance = 14.0
	_squee.unit_size = 1.2
	add_child(_squee)
	set_process(false)  # _process only drifts hearts; _spawn_hearts() turns it on


## Physics hands and controllers from the XR rig (either side may be null).
func arm(left_hand: Node3D, right_hand: Node3D, left_controller: Node, right_controller: Node) -> void:
	wake_tick()
	_hands = {"left": left_hand, "right": right_hand}
	_controllers = {"left": left_controller, "right": right_controller}
	for side in _hands:
		_tip_bones[side] = -1
		var hand: Node3D = _hands[side]
		if hand == null: continue
		if hand is CollisionObject3D:
			(hand as CollisionObject3D).collision_mask |= FACE_LAYER
		if hand is RigidBody3D:
			var body := hand as RigidBody3D
			body.max_contacts_reported = maxi(body.max_contacts_reported, 4)
			body.contact_monitor = true
			body.body_shape_entered.connect(_on_hand_shape_entered.bind(side))
			body.body_shape_exited.connect(_on_hand_shape_exited.bind(side))
		var sk: Skeleton3D = hand.get("skeleton") if "skeleton" in hand else null
		if sk == null: continue
		for b in sk.get_bone_count():
			if sk.get_bone_name(b).ends_with("IndexTip"):
				_tip_bones[side] = b
		if sk.get_bone_count() > 0 and _tip_bones[side] < 0:
			push_warning("Hybrid boop: no IndexTip bone on the %s hand" % side)


## Tests: force the trigger/grip reading for a side (null clears).
func set_input_override(side: String, trigger_grip: Variant) -> void:
	if trigger_grip == null: _input_override.erase(side)
	else: _input_override[side] = trigger_grip


func nose_world() -> Vector3:
	return (head_skeleton.global_transform * head_skeleton.get_bone_global_pose(_nose_bone)).origin


## Kisses use dev's own recording, cut into single soft kisses (kiss_soft_NN.wav, KISS_SOURCE.md,
## dev 2026-09-28: "the kiss noises need to be way more subtle"); the BigSoundBank kisses remain
## as the fallback. `soft`: the held-kiss variant, at a narrower pitch.
func play_kiss(volume_db := -22.0, soft := false) -> void:
	kisses += 1
	if _kiss_streams.is_empty():
		for i in range(1, 40):
			var path := "res://world/audio/pony/kiss_soft_%02d.wav" % i
			if ResourceLoader.exists(path): _kiss_streams.append(load(path))
		_soft_kisses = _kiss_streams.size()
		if _kiss_streams.is_empty():
			_kiss_streams.append(load("res://world/audio/pony/kiss.wav"))
			for i in range(2, 10):
				var path := "res://world/audio/pony/kiss_%d.wav" % i
				if ResourceLoader.exists(path): _kiss_streams.append(load(path))
	if _kiss_sound == null:
		_kiss_sound = AudioStreamPlayer3D.new()
		_kiss_sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		_kiss_sound.name = "KissSound"
		_kiss_sound.unit_size = 1.0
		_kiss_sound.max_distance = 6.0
		snoot.add_child(_kiss_sound)
	var pool := _kiss_streams if _soft_kisses > 0 or not soft else _kiss_streams.slice(0, mini(3, _kiss_streams.size()))
	_kiss_sound.stream = pool.pick_random()
	_kiss_sound.pitch_scale = randf_range(.97, 1.03) if soft else randf_range(.95, 1.05)
	_kiss_sound.volume_db = volume_db
	_kiss_sound.play()


func play_breath(volume_db := -34.0) -> void:
	if _breath_streams.is_empty():
		for i in range(1, 40):
			var path := "res://world/audio/pony/breath_%02d.wav" % i
			if ResourceLoader.exists(path): _breath_streams.append(load(path))
	if _breath_streams.is_empty(): return
	if _breath_sound == null:
		_breath_sound = AudioStreamPlayer3D.new()
		_breath_sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
		_breath_sound.name = "BreathSound"
		_breath_sound.unit_size = 1.0
		_breath_sound.max_distance = 3.0
		snoot.add_child(_breath_sound)
	if _breath_sound.playing: return
	_breath_sound.stream = _breath_streams.pick_random()
	_breath_sound.pitch_scale = randf_range(.96, 1.04)
	_breath_sound.volume_db = volume_db
	_breath_sound.play()


func is_pointing(side: String) -> bool:
	var reading := _read_input(side)
	return reading.x <= pointing_trigger_max and reading.y >= pointing_grip_min


func _read_input(side: String) -> Vector2:
	if _input_override.has(side): return _input_override[side]
	var controller: Node = _controllers.get(side)
	if controller == null or not controller.has_method("get_float"): return Vector2(1.0, 0.0)
	return Vector2(controller.get_float("trigger"), controller.get_float("grip"))


## Push her nose in along `direction` (world, toward her) for the next 0.12 s; call it every
## frame the finger stays on it.
func press(direction: Vector3) -> void:
	if not direction.is_finite() or direction.length_squared() < .0001: return
	wake_tick()
	_press_dir = direction.normalized()
	_press_until = Time.get_ticks_msec() + 120


func _advance_press(delta: float) -> void:
	var wanted := _press_dir * PRESS_DEPTH if Time.get_ticks_msec() < _press_until else Vector3.ZERO
	press_offset = press_offset.move_toward(wanted, delta * PRESS_DEPTH / .1)
	var pressed := press_offset.length_squared() > 1e-9
	if _nose_shape != null: _nose_shape.position = snoot.global_basis.inverse() * press_offset if pressed else Vector3.ZERO
	if _nose_press != null:
		_nose_press.active = pressed
		if pressed: _nose_press.offset = head_skeleton.global_basis.inverse() * press_offset


func tip_world(side: String) -> Vector3:
	if _visible_samples.has(side):return _visible_samples[side].tip
	var hand: Node3D = _hands.get(side)
	var bone: int = _tip_bones.get(side, -1)
	if bone >= 0:
		var sk: Skeleton3D = hand.get("skeleton")
		return (sk.global_transform * sk.get_bone_global_pose(bone)).origin
	return hand.global_position


func _shape_name(body_shape_index: int) -> String:
	var owner_id := snoot.shape_find_owner(body_shape_index)
	var owner := snoot.shape_owner_get_owner(owner_id)
	return owner.name if owner != null else ""


func _on_hand_shape_entered(_rid: RID, body: Node, body_shape_index: int, _local: int, side: String) -> void:
	if body == snoot and _shape_name(body_shape_index) == "SkullShape":
		_skull_contacts[side] += 1
	if body == snoot and _shape_name(body_shape_index) == "NoseShape":
		_nose_contacts[side] += 1


func _on_hand_shape_exited(_rid: RID, body: Node, body_shape_index: int, _local: int, side: String) -> void:
	if body == snoot and _shape_name(body_shape_index) == "SkullShape":
		_skull_contacts[side] = maxi(_skull_contacts[side]-1,0)
	if body == snoot and _shape_name(body_shape_index) == "NoseShape":
		_nose_contacts[side] = maxi(_nose_contacts[side] - 1, 0)


func touching_nose(side: String) -> bool:
	return _nose_contacts.get(side, 0) > 0 or (_input_override.has(side) and touching_snoot(side)
		and tip_world(side).distance_to(nose_world()) <= tip_reach)


func touching_snoot(side: String) -> bool:
	var hand: Node3D = _hands.get(side)
	if hand == null or not hand.has_method("get_colliding_bodies"): return false
	return snoot in hand.get_colliding_bodies()


func _unprofiled_physics_process(delta: float) -> void:
	if snoot == null: return
	if mare.sim_tier != 0 or mare._far == true:
		finger_near = false
		_press_until = 0
		if press_offset != Vector3.ZERO: _advance_press(1.0)
		# Beyond hand reach (clip tiers, 6 m and out): blush fades, decals follow only while shown.
		_advance_blush(delta)
		if blush_amount > 0.0: _sync_snoot()
		elif _blush_idle and strong_blush_time <= 0.0: _park()
		return
	_sync_snoot()
	_advance_scratching(delta)
	var near := false
	var nose := nose_world() if FAR_HAND_REACH > 0.0 else Vector3.INF
	for side in _hands:
		if not is_instance_valid(_hands[side]): continue
		if _hand_far(side, nose):
			# Nothing below can happen this far out; what it would have left behind for a far hand.
			_visible_samples.erase(side)
			_visible_ready[side] = false
			_latched[side] = false
			continue
		_visible_samples.erase(side)
		if _hands[side].get_meta("pony_inspection",false) or _hands[side].get_meta("inventory_busy",false):
			_visible_ready[side]=false;continue
		if hand_sampler.is_valid():
			var sample:Dictionary=hand_sampler.call(side)
			if not sample.get("active",false):
				_visible_ready[side]=false;_latched[side]=false;continue
			_visible_samples[side]=sample
		var pointing_here := is_pointing(side)
		var tip_now := tip_world(side)
		if pointing_here and tip_now.is_finite() and tip_now.distance_to(nose_world()) < FINGER_NEAR: near = true
		var touching := touching_snoot(side)
		var on_nose := touching_nose(side)
		if _visible_samples.has(side):
			var tip:Vector3=_visible_samples[side].tip
			if tip.is_finite() and tip.distance_to(nose_world())>tip_reach+.02:_visible_ready[side]=true
			on_nose=_visible_ready.get(side,false) and tip.is_finite() and tip.distance_to(nose_world())<=tip_reach
			if on_nose:
				var wrist:Vector3=_visible_samples[side].pose.origin
				var wall:=mare.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(wrist,nose_world(),1))
				on_nose=wall.is_empty()
			touching=on_nose
		if on_nose and pointing_here: press(nose_world() - tip_now)
		if not on_nose:
			if _touch_tip.has(side) and tip_world(side).distance_to(_touch_tip[side]) > 0.005:
				_latched[side] = false
			continue
		if _latched[side]: continue
		var pointing := is_pointing(side)
		if not pointing or not touching:
			_debug_contact(side, pointing, on_nose)
			continue
		_latched[side] = true
		_touch_tip[side] = tip_world(side)
		boop()
	finger_near = near
	_advance_press(delta)
	_advance_blush(delta)


## A hand whose physics body and tracked controller are both farther than FAR_HAND_REACH from her
## nose (0.1.0 perf pass): the boop gates (pointing, fingertip within 5.5 cm, contact) and the 25 cm
## nose hold cannot pass, so the inventory's hand sample, controller reads and contact lists are not
## asked for. Her visible-hand ready flag restarts as cleared: a hand coming in sets it again on its
## way through 7.5 cm, as before. Rollback: FAR_HAND_REACH = 0.0.
const FAR_HAND_REACH := 0.8

func _hand_far(side: String, nose: Vector3) -> bool:
	if FAR_HAND_REACH <= 0.0 or not nose.is_finite(): return false
	var reach := FAR_HAND_REACH * FAR_HAND_REACH
	if (_hands[side] as Node3D).global_position.distance_squared_to(nose) < reach: return false
	var controller: Variant = _controllers.get(side)
	return not (is_instance_valid(controller) and controller is Node3D \
		and (controller as Node3D).global_position.distance_squared_to(nose) < reach)


func _advance_scratching(delta: float) -> void:
	var frame:=head_skeleton.global_transform*head_skeleton.get_bone_global_pose(_head_bone)
	var active:=false
	for side in _hands:
		var hand:Node3D=_hands[side]
		if not is_instance_valid(hand):_scratches[side].reset();continue
		if hand.get_meta("pony_inspection",false):_scratches[side].reset();continue
		var local:Vector3=frame.affine_inverse()*hand.global_position
		var contact:bool=_skull_contacts[side]>0 and touching_snoot(side) and local.y>SKULL_LOCAL.y-.025
		var before:int=_scratches[side].reactions
		active=_scratches[side].advance(delta,contact,hand.global_position,frame,SKULL_LOCAL) or active
		head_scratches+=_scratches[side].reactions-before
	if active:
		if not mare.has_meta("spa_client"): sustain_blush()   # spa care never blushes
		mare.expressions.touch("scratch",.7,.45)
		mare.begin_touch(Vector3.ZERO,.35)
	else:mare.expressions.release_touch("scratch")


func _unprofiled_process(delta: float) -> void:
	_advance_hearts(delta)


## The reaction; the gates above or a desktop pet on the head call it.
func boop() -> void:
	_play_squee()
	if not bool(Settings.get_value("ponies/boop_makes_mares_horny")): return
	# A spa client is not booped: no count, blush, hearts or "boop" for her AI
	# (SPA_PLAN_2026_10_29.md section 3).
	# Her eyes still squeeze shut and she squeaks (dev 2026-10-29: "they keep their eyes open"):
	# that face is not romance; blush, hearts, the count and the AI's "boop" stay off.
	if mare.has_meta("spa_client"):
		mare.expressions.boop()
		return
	wake_tick()
	boops += 1
	if mare.has_method("on_booped"): mare.on_booped()
	_blush_idle = false
	_blush_time = 0.0
	_blush_level = 1.0
	_full_until = Time.get_ticks_msec() + int((blush_rise + blush_hold + blush_fall) * 1000.0)
	_spawn_hearts()


var _debug_timer := 0.0
## Once a second while a hand touches her face without booping: why not (headset log).
func _debug_contact(side: String, pointing: bool, on_nose: bool) -> void:
	_debug_timer -= get_physics_process_delta_time()
	if _debug_timer > 0.0: return
	_debug_timer = 1.0
	var reading := _read_input(side)
	print("[boop] %s hand on her face: trigger %.2f grip %.2f pointing %s, on the nose sphere %s (hand %.0f mm from nose)" % [
		side, reading.x, reading.y, pointing, on_nose, (_hands[side] as Node3D).global_position.distance_to(nose_world()) * 1000.0])


func skull_world() -> Vector3:
	var head := head_skeleton.global_transform * head_skeleton.get_bone_global_pose(_head_bone)
	return head * SKULL_LOCAL


func muzzle_world() -> Vector3:
	var bone := head_skeleton.find_bone(MUZZLE_BONE)
	if bone < 0: return nose_world()
	return (head_skeleton.global_transform * head_skeleton.get_bone_global_pose(bone)).origin


func _sync_snoot() -> void:
	_place_nose_blush()
	if _native != null:
		_native.boop_sync(head_skeleton, _native_bones, snoot, _skull_shape, _muzzle_shape, _decals)
		return
	var head := head_skeleton.global_transform * head_skeleton.get_bone_global_pose(_head_bone)
	snoot.global_transform = Transform3D(Basis.IDENTITY, nose_world())
	(snoot.get_node("SkullShape") as CollisionShape3D).global_transform = head
	(snoot.get_node("MuzzleShape") as CollisionShape3D).global_position = muzzle_world()
	for i in _decals.size():
		var side: String = "left" if i == 0 else "right"
		var bone := head_skeleton.find_bone(CHEEK_BONES[side])
		if bone < 0: continue
		var cheek := head_skeleton.global_transform * head_skeleton.get_bone_global_pose(bone)
		# Outward, a touch forward and down: the cheek surface under the eye. Native head
		# forward is +Z, sides ±X.
		var sign := 1.0 if side == "left" else -1.0
		var normal: Vector3 = (head.basis * Vector3(sign * 0.8, -0.1, 0.5)).normalized()
		var basis := Basis()
		basis.y = normal
		basis.x = normal.cross(head.basis.y).normalized()
		basis.z = basis.x.cross(normal).normalized()
		var centre: Vector3 = cheek.origin + head.basis * Vector3(0.0, 0.035, 0.0) + normal * 0.005
		_decals[i].global_transform = Transform3D(basis, centre)


## Across the top of the muzzle, between nose and eyes; wider as she gets more flustered.
func _place_nose_blush() -> void:
	if _nose_decal == null: return
	var amount := maxf(expression_blush, blush_amount * _blush_level) * nose_blush
	_nose_decal.visible = amount > .01
	if not _nose_decal.visible: return
	var head := head_skeleton.global_transform * head_skeleton.get_bone_global_pose(_head_bone)
	# Native head forward is +Z, up +Y: the bridge faces up and forward.
	var normal: Vector3 = (head.basis * Vector3(0.0, 0.75, 0.66)).normalized()
	var basis := Basis()
	basis.y = normal
	basis.x = head.basis.x.normalized()
	basis.z = basis.x.cross(normal).normalized()
	_nose_decal.size = Vector3(lerpf(.06, .17, nose_blush), .09, .06)
	_nose_decal.albedo_mix = amount
	_nose_decal.global_transform = Transform3D(basis, nose_world().lerp(skull_world(), .3) + normal * .02)


func _build_blush() -> void:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			# Feathered all the way from the centre: no visible edge, just a warm patch.
			var r := Vector2(x + 0.5 - 32.0, y + 0.5 - 32.0).length() / 32.0
			var a := 1.0 - smoothstep(0.0, 1.0, r)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	var texture := ImageTexture.create_from_image(image)
	for side in ["left", "right"]:
		var decal := Decal.new()
		decal.name = "Blush" + side.capitalize()
		decal.texture_albedo = texture
		# Sideways oval: wide across the cheek, short top to bottom (dev).
		decal.size = Vector3(0.12, 0.09, 0.055)
		decal.modulate = blush_color
		decal.albedo_mix = 0.0
		decal.upper_fade = 0.6
		decal.lower_fade = 0.6
		decal.cull_mask = 0xFFFFF
		add_child(decal)
		_decals.append(decal)
	_nose_decal = Decal.new()
	_nose_decal.name = "BlushNose"
	_nose_decal.texture_albedo = texture
	_nose_decal.modulate = blush_color
	_nose_decal.albedo_mix = 0.0
	_nose_decal.upper_fade = 0.6
	_nose_decal.lower_fade = 0.6
	_nose_decal.cull_mask = 0xFFFFF
	_nose_decal.visible = false
	add_child(_nose_decal)


## Hold the blush at its peak. `level` scales how red it gets (petting asks for a light blush);
## a boop, scratch or hoof hold asks for the full one.
func sustain_blush(level: float = 1.0) -> void:
	wake_tick()
	_blush_time=clampf(_blush_time,0.0,blush_rise)
	_level_request=maxf(_level_request,level)
	_blush_idle = false
var _blush_level := 1.0
var _level_request := 0.0
var _full_until := 0
## No blush, no request, nothing pending: _advance_blush would rewrite the same values.
var _blush_idle := false
## Beyond hand reach with no blush to fade, the physics tick has nothing to do and is off.
## A blush request, a boop, armed hands, or the mare's tier or distance change wakes it.
var _parked := false


func wake_tick() -> void:
	if _parked:
		_parked = false
		set_physics_process(true)
		if is_instance_valid(snoot):
			snoot.process_mode = Node.PROCESS_MODE_INHERIT
			_sync_snoot()


## Parked beyond hand reach, the snoot collider also leaves the physics space: an animatable
## body re-syncs its transform to Jolt every tick even when nothing can touch it (Jolt ablation
## 2026-10-14: the 125 animatable bodies cost about 0.5 ms of physics per frame, 40 of them snoots).
func _park() -> void:
	_parked = true
	set_physics_process(false)
	if is_instance_valid(snoot): snoot.process_mode = Node.PROCESS_MODE_DISABLED

func _advance_blush(delta: float) -> void:
	if _blush_idle and strong_blush_time <= 0.0: return
	strong_blush_time=maxf(0.0,strong_blush_time-delta)
	if strong_blush_time>0:sustain_blush()
	if _blush_time < 0.0:
		blush_amount = 0.0
	else:
		_blush_time += delta
		if _blush_time < blush_rise:
			blush_amount = smoothstep(0.0, 1.0, _blush_time / blush_rise)
		elif _blush_time < blush_rise + blush_hold:
			blush_amount = 1.0
		else:
			blush_amount = 1.0 - smoothstep(0.0, 1.0, (_blush_time - blush_rise - blush_hold) / blush_fall)
			if blush_amount <= 0.0:
				blush_amount = 0.0
				_blush_time = -1.0
	if Time.get_ticks_msec() < _full_until: _level_request = 1.0
	if _level_request > 0.0: _blush_level = move_toward(_blush_level, _level_request, delta * 1.5)
	_level_request = 0.0
	var color_weight := maxf(blush_amount * _blush_level * (1.0 if strong_blush_time > 0 else .75), expression_blush * .75)
	blush_amount = maxf(blush_amount, expression_blush)
	for decal in _decals:
		decal.albedo_mix = color_weight
		decal.visible = blush_amount > 0.0
	if blush_amount <= 0.0 and _nose_decal != null: _nose_decal.visible = false
	_blush_idle = _blush_time < 0.0 and strong_blush_time <= 0.0 and expression_blush <= 0.0 and Time.get_ticks_msec() >= _full_until


func _play_squee() -> void:
	_squee.global_position = nose_world()
	var honk := boop_sound == 2 or (boop_sound == 0 and randi() % 3 == 0)
	if honk and _freddy_stream == null and ResourceLoader.exists(FREDDY_PATH):
		_freddy_stream = load(FREDDY_PATH)
	honk = honk and _freddy_stream != null
	_squee.stream = _freddy_stream if honk else SQUEES[randi() % SQUEES.size()]
	# The honk recording is louder than the squees; keep it level with them.
	_squee.volume_db = squee_db - (6.0 if honk else 0.0)
	_squee.pitch_scale = 1.0 if honk else randf_range(0.98, 1.04)
	_squee.play()


func _heart_image() -> Texture2D:
	if _heart_texture != null: return _heart_texture
	var size := 96
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# Classic chunky heart: a 45° square for the point plus two lobes, as one smooth
	# distance field (the implicit-curve heart read as mouse ears at this size).
	var lobe_r := 0.46
	var lobes := [Vector2(-0.44, 0.30), Vector2(0.44, 0.30)]
	for py in size:
		for px in size:
			var x := (px + 0.5 - size * 0.5) / (size * 0.42)
			var y := (size * 0.5 - py - 0.5) / (size * 0.42) + 0.05
			# Rotated square (diamond) below the lobes.
			var d := absf(x) * 1.12 + absf(y + 0.05) - 0.95
			if y > 0.2: d = 10.0
			for c in lobes:
				d = minf(d, Vector2(x, y).distance_to(c) - lobe_r)
			var inside := clampf(0.5 - d * 14.0, 0.0, 1.0)
			var shine := 0.45 * clampf(1.0 - Vector2(x + 0.5, y - 0.45).length() * 3.5, 0.0, 1.0)
			image.set_pixel(px, py, Color(1.0, 1.0 - 0.15 * (1.0 - shine), 1.0 - 0.15 * (1.0 - shine), inside))
	_heart_texture = ImageTexture.create_from_image(image)
	return _heart_texture


## A relationship level-up (relationship_runtime.gd): the boop's hearts, with no boop counted.
func celebrate() -> void:
	if head_skeleton == null or _head_bone < 0: return
	_spawn_hearts()

func _spawn_hearts() -> void:
	var head := head_skeleton.global_transform * head_skeleton.get_bone_global_pose(_head_bone)
	var top: Vector3 = head * (SKULL_LOCAL + Vector3(0.0, SKULL_RADIUS + 0.02, 0.0))
	for i in 5:
		var sprite := Sprite3D.new()
		sprite.texture = _heart_image()
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.shaded = false
		sprite.double_sided = true
		sprite.no_depth_test = false
		sprite.pixel_size = 0.00075
		sprite.modulate = heart_colors[i % heart_colors.size()]
		sprite.transparency = 1.0
		add_child(sprite)
		var origin := top + Vector3(randf_range(-0.12, 0.12), randf_range(-0.02, 0.04), randf_range(-0.08, 0.08))
		sprite.global_position = origin
		_hearts.append({"sprite": sprite, "t": -0.13 * i, "life": randf_range(1.5, 2.0), "origin": origin,
			"phase": randf() * TAU, "rise": randf_range(0.32, 0.45)})
	hearts_alive = _hearts.size()
	set_process(true)


func _advance_hearts(delta: float) -> void:
	if _hearts.is_empty():
		set_process(false)
		return
	var write := 0
	for read in _hearts.size():
		var heart: Dictionary = _hearts[read]
		heart.t += delta
		var sprite: Sprite3D = heart.sprite
		if heart.t < 0.0:
			sprite.transparency = 1.0
			_hearts[write] = heart
			write += 1
			continue
		var u: float = heart.t / heart.life
		if u >= 1.0:
			sprite.queue_free()
			continue
		var pop: float = smoothstep(0.0, 0.18, u) * (0.75 + 0.25 * sin(heart.t * 9.0 + heart.phase) * 0.3)
		sprite.scale = Vector3.ONE * (0.6 + 0.4 * pop)
		sprite.global_position = heart.origin + Vector3(sin(heart.t * 3.1 + heart.phase) * 0.03,
			heart.rise * smoothstep(0.0, 1.0, u * 0.9), cos(heart.t * 2.3 + heart.phase) * 0.02)
		sprite.transparency = 1.0 - smoothstep(0.0, 0.12, u) * (1.0 - smoothstep(0.6, 1.0, u))
		_hearts[write] = heart
		write += 1
	_hearts.resize(write)
	hearts_alive = _hearts.size()


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process(delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("boop_process", started)


func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_physics_process(delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("boop_physics", started)
