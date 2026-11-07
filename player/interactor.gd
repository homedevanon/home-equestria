extends Node3D
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
## Player-side reach: what you are looking at, and what you can do to it.
##
## Lives on the camera so both rigs share it. In VR this is the wrong shape --
## reach should come from the hand, not the gaze -- but the verbs and the pony
## API are identical either way, so M6 replaces the ray and keeps everything
## below it.

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const REACH := 3.0
## Where a carried pony sits relative to the camera: low and forward, roughly
## where your arms would be. Carrying something at eye level looks like
## levitation.
const HOLD_OFFSET := Vector3(0.0, -0.45, -0.85)
## AnonPony has no arms to lift or throw a pony with (docs/ANONPONY_DESIGN_2026_10_01.md section 10).
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")

@export var pet_cooldown := 0.6

var held: Node3D
var _ray: RayCast3D
var _hold: Node3D
var _cooldown := 0.0
var _following := false
## Desktop semantic/presentation owner; null in XR and isolated older fixtures.
var desktop_actions: Node
## Carrying a pony, G is a wind-up (dev 2026-10-14): a tap puts her down; held, a meter by the
## crosshair fills green, orange, red, and letting go throws her that hard. Shift+G still
## throws at full strength at once.
const CHARGE_TAP := 0.25
const CHARGE_FULL := 1.4
var _charge_from := -1.0
var _meter: Control
## Holding K while carrying lifts her face to his (dev 2026-10-14: K did nothing while she sat
## at his chest, out of kissing reach). Closed loop on her lips; kept while the kiss lasts. Held in
## his heading's frame, so turning while kissing carries her round with him instead of leaving the
## lift pointing where he used to face.
var _kiss_lift := Vector3.ZERO
## Bridal kiss reach (pony_carry.gd kiss_reach_goal): his view pitch when K went down; looking more
## than REACH_LOOK_AWAY up or down from it lets her go until K is pressed again.
var _reach_pitch := NAN
var _reach_dropped := false
const REACH_LOOK_AWAY := 35.0
## A kiss that ends while K is still down lets her go too (else she rests at his lips, staring).
var _reach_kissed := false
## Bridal carried, she rides his stride: a small dip per footfall, trailing his own head bob
## (desktop_player.gd _bob_phase) and deeper the faster he goes.
const CRADLE_BOB := .012 # Metres at his walking speed.
const CRADLE_BOB_MAX := 1.6 # Of that, at most (sprinting).
const CRADLE_BOB_LAG := .45 # Radians her weight trails his step.
const CRADLE_BOB_RATE := .5 # Dips per footfall: one every other step, a slower sway than his head's.
var _cradle_bob := 0.0
var _player_body: Node
## The carry-turn key (B by default) while carrying turns her round to face him; she rides a little further out so her face
## is not in his. Eased (0 = facing away, 1 = facing him); cleared when she leaves his arms.
const FACING_EXTRA_REACH := 0.12
const FACING_TURN_SECONDS := 0.45
var facing_player := false
var _facing := 0.0
## Bridal carry (pony_carry.gd cradle): hold G on a pony to lift her into it, or hold B while
## carrying her (tap B still turns her). Hold B again for the ordinary carry; G sets her down,
## after she is swung upright so she lands on her hooves. Lower and closer than the chest carry.
## From his eyes, turned with his body only: right, up, forward.
const CRADLE_OFFSET := Vector3(0.0, -0.45, -0.22)
## Her heading in his arms: a quarter turn to his left (pony_carry.gd CRADLE_HEAD/BELLY aim her
## from there, in his frame).
const CRADLE_YAW := PI * 0.5
const KEY_HOLD_SECONDS := 0.35
var cradled := false
var _pick_from := -1.0
var _b_from := -1.0
var _drop_upright := false
## Laying her in bed (cradle_rest.gd bed_spot): G while she sleeps or dozes in his arms over a bed,
## or looking at one, and he leans down and lays her on the mattress instead of setting her on her
## hooves; she lands lying, asleep. He stands still meanwhile (desktop_player.gd lay_hold).
const LAY_SECONDS := 1.5
const LAY_LEAN := .3 # Metres his eyes come down.
const LAY_PITCH := -.45 # His view tips down at least this far (radians).
const LAY_ABOVE := .3 # Her barrel this far over her rest spot when he lets go.
var _laying := -1.0
var _lay: Dictionary = {}
var _lay_start := Vector3.ZERO
var _lay_pitch := 0.0
## Kissing her from sleep (pony_carry.gd kiss_sleepy), he leans down to her.
const SLEEPY_KISS_LEAN := .08
const LEAN_RATE := .5 # Metres a second.
var _lean := 0.0
var _sleepy_kiss := false


func _ready() -> void:
	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0, 0, -REACH)
	_ray.collide_with_areas = false
	_ray.collide_with_bodies = true
	# World is layer 1, ponies (and the hybrid's snoot) layer 2.
	_ray.collision_mask = 3
	add_child(_ray)

	_hold = Node3D.new()
	_hold.name = "HoldPoint"
	_hold.position = HOLD_OFFSET
	add_child(_hold)


func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("interactor", started)

func _physics_step(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	_update_kiss_lift(delta)
	_update_meter()
	_update_keys()
	_update_facing(delta)
	if _laying >= 0.0: _update_laying(delta)
	_update_lean(delta)
	if is_instance_valid(held) and held.has_method("update_grab"):
		held.update_grab(_hold.global_position + _heading() * _kiss_lift, global_position)
		if held.has_method("set_hold_yaw"):
			# Cradled, she lies across his arms with her head to his left.
			var turn := lerpf(PI * smoothstep(0.0, 1.0, _facing), CRADLE_YAW, smoothstep(0.0, 1.0, cradle_amount()))
			var yaw := global_basis.get_euler().y + turn
			# Laid in bed, she turns to lie along it, head to the pillow.
			if _laying >= 0.0:
				var spot: Transform3D = _lay.spot
				yaw = lerp_angle(yaw, spot.basis.get_euler().y, _lay_ease())
			held.set_hold_yaw(yaw)
	if _drop_upright and is_instance_valid(held) and cradle_amount() <= 0.1:
		_drop_upright = false
		_drop()


## G released: a short tap sets her down, a wind-up throws her (a menu may eat the key-up, so
## this listens before the GUI).
func _input(event: InputEvent) -> void:
	if _charge_from < 0.0 or not (event is InputEventKey) or event.pressed or (event as InputEventKey).physical_keycode != KEY_G: return
	var held_for := Time.get_ticks_msec() / 1000.0 - _charge_from
	_charge_from = -1.0
	if not is_instance_valid(held): return
	if held_for < CHARGE_TAP: _drop()
	else: _throw(charge(held_for))
	get_viewport().set_input_as_handled()


## Throw strength 0..1 after holding G for `held_for` seconds.
static func charge(held_for: float) -> float:
	return clampf((held_for - CHARGE_TAP) / (CHARGE_FULL - CHARGE_TAP), 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	var body: Node = get_parent()
	while body != null:
		if FLIGHT_INPUT.reserves_mouse(event,body): return
		if "controls_locked" in body and body.controls_locked: return
		body = body.get_parent()
	# A left click interacts like E (dev 2026-09-30: "clicking should be interact/use"): sit,
	# open a door, pet. The inventory takes the click first when a held thing has a use.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _interact():
			get_viewport().set_input_as_handled()
		return
	# Right click on a shut door knocks (player bug board #31); on a pony it slaps
	# (desktop_interactions.gd), which this ray never reaches first.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not is_instance_valid(held) and _ray.is_colliding() \
				and _ray.get_collider() != null and _ray.get_collider().has_method("knock_from_desktop"):
			if _ray.get_collider().knock_from_desktop(): preload("res://player/door_knock.gd").answer(_ray.get_collider())
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# Turn a carried pony round (Settings: "Turn carried pony", B by default); held, it switches
	# to and from the bridal carry (_update_keys tells the two apart).
	if is_instance_valid(held) and InputMap.has_action("carry_turn") and event.is_action_pressed("carry_turn"):
		_b_from = Time.get_ticks_msec() / 1000.0
		get_viewport().set_input_as_handled()
		return
	match (event as InputEventKey).physical_keycode:
		KEY_E:
			if _interact(): get_viewport().set_input_as_handled()
		KEY_G:
			if PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())):
				return
			if is_instance_valid(held) and event.shift_pressed:
				if _throw(1.0): get_viewport().set_input_as_handled()
			elif is_instance_valid(held):
				_charge_from = Time.get_ticks_msec() / 1000.0
				get_viewport().set_input_as_handled()
			elif held != null:
				if _drop(): get_viewport().set_input_as_handled()
			elif not is_instance_valid(desktop_actions) or desktop_actions.can_accept_world_action():
				if _try_pick_up():
					_pick_from = Time.get_ticks_msec() / 1000.0
					get_viewport().set_input_as_handled()
		KEY_R:
			_toggle_follow()


## Sit or stand, open or close the door in view, else pet the pony in view. True when handled.
func _interact() -> bool:
	# An easel's canvas, tray or hooks: start painting (world/painting/easel_wake.gd).
	if _ray.is_colliding() and _ray.get_collider() != null and _ray.get_collider().has_meta("painting_easel"):
		var easel: Variant = _ray.get_collider().get_meta("painting_easel")
		if is_instance_valid(easel): return bool((easel as Node).call("desktop_begin"))
	# The box beside an open folding game board: E packs it up, before the board or the seat beside
	# it can take the key (world/minigames/board_games/board_fold.gd).
	if not is_instance_valid(held):
		var in_front := _ray.global_position.distance_to(_ray.get_collision_point()) if _ray.is_colliding() else REACH
		var board: RigidBody3D = preload("res://world/minigames/board_games/board_fold.gd").box_in_view(get_tree(), _ray.global_position, -_ray.global_basis.z, minf(in_front, REACH))
		if board != null: return preload("res://world/minigames/board_games/board_fold.gd").pack_desktop(board)
	# Carrying a pony (busy below), the door in view still opens: past her, world only.
	if is_instance_valid(held) and _toggle_door_past_held(): return true
	# The game table in Golden Oak: the board view (world/minigames/board_games/board_table.gd);
	# not while carrying a pony.
	if not is_instance_valid(held) and _ray.is_colliding() and _ray.get_collider() != null and _ray.get_collider().has_meta("board_table"):
		var table: Variant = _ray.get_collider().get_meta("board_table")
		if is_instance_valid(table) and bool((table as Node).call("desktop_begin")): return true
	if is_instance_valid(desktop_actions) and desktop_actions.busy(): return false
	if _try_seat(): return true
	if _ray.is_colliding() and _ray.get_collider().has_method("toggle_door"):
		_ray.get_collider().toggle_door()
		return true
	return _try_pet()

func _toggle_door_past_held() -> bool:
	var door := door_past_held()
	if door == null: return false
	door.toggle_door()
	return true


## The door in view past the pony in his arms (world only), or null.
func door_past_held() -> Object:
	_ray.collision_mask = 1
	_ray.force_raycast_update()
	var door: Object = _ray.get_collider() if _ray.is_colliding() else null
	_ray.collision_mask = 3
	_ray.force_raycast_update()
	return door if door != null and door.has_method("toggle_door") else null

## E while seated stands up; E looking at a seat (within 1 m of where you look) sits down.
func _try_seat() -> bool:
	var body: Node = get_parent()
	while body != null and not body.has_method("sit_on"): body = body.get_parent()
	if body == null: return false
	if is_instance_valid(body.get("seat")):
		body.stand_up()
		return true
	if not _ray.is_colliding() or _ray.get_collider() is CharacterBody3D: return false
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating.has_method("player_seat_near"): return false
	var seat: Node3D = seating.player_seat_near(_ray.get_collision_point(), 1.0, body, _ray.get_collider())
	return seat != null and body.sit_on(seat)

func _looking_at_pony() -> Node3D:
	if not _ray.is_colliding():
		return null
	var hit := _ray.get_collider()
	if hit == null:
		return null
	# The pony script lives on the CharacterBody3D itself.
	if hit.has_method("pet"):
		return hit
	var parent = hit.get_parent()
	return parent if parent != null and parent.has_method("pet") else null


## Body part is inferred from where the ray lands relative to her, so petting
## her head reads differently from petting her back without needing a separate
## collider per body part.
func _part_from_hit(pony: Node3D) -> String:
	var point := _ray.get_collision_point()
	var local: Vector3 = pony.global_transform.affine_inverse() * point
	if local.z < -0.25:
		return "head"
	if local.z > 0.3:
		return "flank"
	if local.y > 0.55:
		return "back"
	return "side"


func _try_pet() -> bool:
	# The contextual desktop owner selects actual nose/coat surfaces and owns its click.
	if is_instance_valid(desktop_actions): return false
	if _cooldown > 0.0:
		return false
	var pony := _looking_at_pony()
	if pony == null:
		return false
	var part := _part_from_hit(pony)
	pony.pet(part)
	_cooldown = pet_cooldown
	print("[interact] petted %s on the %s" % [pony.name, part])
	return true


func _try_pick_up() -> bool:
	var pony := _looking_at_pony()
	if pony == null:
		return false
	if pony.has_method("begin_grab"):
		pony.begin_grab("chest", _hold.global_position, global_position)
	else:
		pony.pick_up(_hold)
		pony.position = Vector3.ZERO
		pony.rotation = Vector3.ZERO
	held = pony
	cradled = false
	_drop_upright = false
	# She keeps the way she faced him: facing him when lifted, she is held facing him (B turns her).
	var ahead := -pony.global_basis.z
	var to_him := global_position - pony.global_position
	ahead.y = 0.0; to_him.y = 0.0
	facing_player = ahead.dot(to_him) > 0.0
	_facing = 1.0 if facing_player else 0.0
	if is_instance_valid(desktop_actions): desktop_actions.pony_acquired()
	SOUNDS.play_at(pony, "prop_contact_cloth")
	print("[interact] picked up %s" % pony.name)
	return true


func _drop() -> bool:
	if held == null:
		return false
	if _laying >= 0.0: return true
	if is_instance_valid(held) and cradle_amount() > 0.9 and _begin_laying(): return true
	if is_instance_valid(held) and (cradled or cradle_amount() > 0.1):
		# Out of the cradle first; _physics_step sets her down once she is upright.
		cradled = false
		facing_player = true
		_drop_upright = true
		return true
	if held.has_method("end_interaction"):
		held.end_interaction()
		held = null
		if is_instance_valid(desktop_actions): desktop_actions.pony_released()
		return true
	# Drop at her feet in front of the player rather than at the hold point, so
	# she lands on the ground instead of hovering where your hands were.
	var world := get_tree().current_scene
	var front := global_position + (-global_transform.basis.z * 1.2)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(front + Vector3.UP * 2.0,
		front + Vector3.DOWN * 6.0)
	q.exclude = [held.get_rid()]
	var hit := space.intersect_ray(q)
	var at: Vector3 = hit["position"] if hit.has("position") else front

	held.drop(at, world)
	print("[interact] dropped %s" % held.name)
	held = null
	if is_instance_valid(desktop_actions): desktop_actions.pony_released()
	return true


func _throw(power := 1.0) -> bool:
	if not is_instance_valid(held) or not held.has_method("throw_pony"): return false
	_charge_from = -1.0
	var momentum := -global_basis.z.normalized() * lerpf(3.0, 12.0, power) + Vector3.UP * lerpf(1.0, 3.0, power)
	if held.throw_pony(momentum):
		print("[interact] threw %s" % held.name)
		held = null
		if is_instance_valid(desktop_actions): desktop_actions.pony_released()
		return true
	return false


func _toggle_follow() -> void:
	var pony := _looking_at_pony()
	if pony == null:
		return
	# Hybrid/background ponies route through their Navigator child; the old native
	# mare and OpenPony actors answer follow()/stay() themselves.
	var mover: Node = pony if pony.has_method("follow") else pony.get_node_or_null("Navigator")
	if mover == null or not mover.has_method("follow"):
		print("[interact] %s cannot follow (no navigator)" % pony.name)
		return
	if mover == pony.get_node_or_null("Navigator"):
		mover.command_owner = "player:desktop-follow:%d" % Time.get_ticks_usec()
	_following = not _following
	if _following:
		mover.follow(get_parent().get_parent())
		print("[interact] %s is following" % pony.name)
	else:
		mover.stay()
		print("[interact] %s will stay" % pony.name)


func _update_kiss_lift(delta: float) -> void:
	if not is_instance_valid(held) or held.get_node_or_null("Affection") == null:
		_kiss_lift = Vector3.ZERO
		return
	var affection: Node = held.get_node("Affection")
	# Bridal carried, her body stays in his arms: she reaches up with her neck instead
	# (pony_carry.gd kiss_reach_goal), her lips just in front of his so they touch.
	if cradle_amount() > 0.0:
		_kiss_lift = _kiss_lift.move_toward(Vector3.ZERO, delta * 1.5)
		var k_down := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_physical_key_pressed(KEY_K)
		var pitch := global_basis.get_euler().x
		if not k_down:
			_reach_pitch = NAN
			_reach_dropped = false
		elif is_nan(_reach_pitch):
			_reach_pitch = pitch
		elif absf(pitch - _reach_pitch) > deg_to_rad(REACH_LOOK_AWAY):
			_reach_dropped = true
		var kissing: bool = affection.get("kind") == "kiss"
		if _reach_kissed and not kissing and k_down: _reach_dropped = true
		_reach_kissed = kissing
		var reaching: bool = not _reach_dropped and (affection.get("kind") == "kiss" or (k_down and _kiss_welcome()))
		# His mouth by his heading alone: it doesn't swing with his eyes when he looks up or down.
		var carry: Object = _cradle_carry()
		carry.kiss_reach_goal = global_position + _heading() * Vector3(0.0, -0.07, -0.03) if reaching else Vector3.INF
		carry.kiss_reach_eye = global_position
		carry.kiss_reach_side = global_basis.x.normalized() * 0.032
		carry.kiss_reach_away = _heading() * Vector3.FORWARD
		return
	if affection.get("kind") == "kiss": return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_physical_key_pressed(KEY_K):
		var mouth := global_position + global_basis.orthonormalized() * Vector3(0.0, -0.07, -0.02)
		var lips: Vector3 = affection.mouth_point()
		if lips.is_finite():
			_kiss_lift = (_kiss_lift + _heading().inverse() * (mouth - lips) * minf(1.0, delta * 4.0)).limit_length(0.9)
		return
	_kiss_lift = _kiss_lift.move_toward(Vector3.ZERO, delta * 1.5)


func _begin_laying() -> bool:
	var rest: Node = held.get_node_or_null("CradleRest")
	var spot: Dictionary = rest.bed_spot(global_position, -global_basis.z) if rest != null else {}
	if spot.is_empty(): return false
	_lay = spot
	_laying = 0.0
	_lay_start = _hold.global_position
	var body := _body()
	_lay_pitch = float(body.get("_pitch")) if body != null and body.get("_pitch") != null else global_basis.get_euler().x
	if body != null: body.set_meta("lay_hold", true)
	return true


func _lay_ease() -> float:
	return smoothstep(0.0, 1.0, minf(_laying / LAY_SECONDS, 1.0))


## Down to the mattress in his arms, his view following her; at the end she leaves them lying.
func _update_laying(delta: float) -> void:
	if not is_instance_valid(held):
		_end_laying()
		return
	_laying += delta
	var t := _lay_ease()
	var spot: Transform3D = _lay.spot
	_hold.global_position = _lay_start.lerp(spot.origin + Vector3.UP * LAY_ABOVE, t)
	var body := _body()
	var camera: Node3D = body.get("camera") if body != null else null
	if body != null and body.get("_pitch") != null and camera != null:
		var pitch := lerpf(_lay_pitch, minf(_lay_pitch, LAY_PITCH), t)
		body.set("_pitch", pitch)
		camera.rotation.x = pitch
	if _laying < LAY_SECONDS: return
	var pony := held
	var rest: Node = pony.get_node_or_null("CradleRest")
	var spot_data := _lay
	_end_laying()
	pony.end_interaction()
	held = null
	cradled = false
	if is_instance_valid(desktop_actions): desktop_actions.pony_released()
	if rest != null: rest.lay_down(spot_data)
	print("[interact] laid %s in bed" % pony.name)


func _end_laying() -> void:
	_laying = -1.0
	_lay = {}
	var body := _body()
	if body != null and body.has_meta("lay_hold"): body.remove_meta("lay_hold")


## His eyes come down while he lays her in bed or kisses her from sleep (desktop_player.gd lean_down).
func _update_lean(delta: float) -> void:
	var carry: Variant = _cradle_carry()
	var reaching: bool = carry != null and carry.kiss_reach_goal.is_finite()
	_sleepy_kiss = reaching and (_sleepy_kiss or carry.kiss_sleepy == true)
	var want := LAY_LEAN * _lay_ease() if _laying >= 0.0 else (SLEEPY_KISS_LEAN if _sleepy_kiss else 0.0)
	_lean = move_toward(_lean, want, delta * LEAN_RATE)
	var body := _body()
	if body == null: return
	if _lean > 0.0: body.set_meta("lean_down", _lean)
	elif body.has_meta("lean_down"): body.remove_meta("lean_down")


## His body (desktop_player.gd), found once.
func _body() -> CharacterBody3D:
	if not is_instance_valid(_player_body):
		_player_body = get_parent()
		while _player_body != null and not _player_body is CharacterBody3D: _player_body = _player_body.get_parent()
	return _player_body as CharacterBody3D


## She reaches up to his lips only where a kiss may happen at all (pony_kisser.gd try_kiss): a grown
## pony, awake, who welcomes his kisses, and he is not a foal. A filly, a sleeper or a pony who does
## not want it stays lying in his arms.
func _kiss_welcome() -> bool:
	var identity: Variant = held.get("identity")
	if identity == null or identity.filly or held.get("sleeping") == true: return false
	if PLAYER_FORM.is_young(PLAYER_FORM.active(get_tree())): return false
	var runtime: Node = held.get_meta("relationship_runtime") if held.has_meta("relationship_runtime") else null
	return runtime != null and runtime.get("bonds") != null and runtime.bonds.welcomes(str(held.get_meta("relationship_id", "")), "kiss")


## His heading alone (no pitch): the frame the kiss lift lives in.
func _heading() -> Basis:
	return Basis(Vector3.UP, global_basis.get_euler().y)


## Eases her round toward (or away from) him and moves the hold point out to match.
func _update_facing(delta: float) -> void:
	if not is_instance_valid(held):
		facing_player = false
		_facing = 0.0
		cradled = false
		_drop_upright = false
		if _laying >= 0.0: _end_laying()
	else:
		_facing = move_toward(_facing, 1.0 if facing_player else 0.0, delta / FACING_TURN_SECONDS)
	var carry: Variant = _cradle_carry()
	if carry != null: carry.cradle_goal = cradled
	# His arms' reach follows Anon's chosen height (6 ft = these numbers; player_mouth.gd human_scale).
	var arm_scale := preload("res://player/player_mouth.gd").human_scale(get_parent() as Node3D)
	_hold.position = (HOLD_OFFSET + Vector3(0.0, 0.0, -FACING_EXTRA_REACH * smoothstep(0.0, 1.0, _facing))) * arm_scale
	# Cradled, she rests in his arms, not in his gaze: only his turning moves her, never his
	# looking up or down (that is his neck).
	var cradled_amount := smoothstep(0.0, 1.0, cradle_amount())
	if cradled_amount > 0.0:
		var arms := global_position + Basis(Vector3.UP, global_basis.get_euler().y) * CRADLE_OFFSET * arm_scale
		arms.y += _stride_bob(delta)
		_hold.global_position = _hold.global_position.lerp(arms, cradled_amount)
	else:
		_cradle_bob = 0.0


## Her dip this tick from his stride (0 standing still, flying or swimming).
func _stride_bob(delta: float) -> float:
	var want := 0.0
	var body := _body()
	if body != null and body.get("_bob_phase") != null and body.is_on_floor():
		var speed := Vector2(body.velocity.x, body.velocity.z).length()
		var walk := float(body.get("walk_speed")) if body.get("walk_speed") != null else 4.0
		if speed > .1:
			want = -absf(sin(float(body.get("_bob_phase")) * CRADLE_BOB_RATE - CRADLE_BOB_LAG)) * CRADLE_BOB * minf(speed / walk, CRADLE_BOB_MAX)
	_cradle_bob = lerpf(_cradle_bob, want, minf(1.0, 12.0 * delta))
	return _cradle_bob


## The held pony's carry state when she can be cradled (Spike and older actors cannot).
func _cradle_carry() -> Variant:
	if not is_instance_valid(held): return null
	var carry: Variant = held.get("carry")
	return carry if carry is RefCounted and "cradle_goal" in carry else null


## How far into the bridal carry she is, 0..1 (eased on her side by pony_carry.gd).
func cradle_amount() -> float:
	var carry: Variant = _cradle_carry()
	return float(carry.cradle) if carry != null else 0.0


## Hold G on a pony to lift her straight into the bridal carry; the carry-turn key (B) tapped
## turns her, held switches between the bridal and the ordinary carry.
func _update_keys() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _pick_from >= 0.0:
		if not is_instance_valid(held) or not Input.is_physical_key_pressed(KEY_G): _pick_from = -1.0
		elif now - _pick_from >= KEY_HOLD_SECONDS:
			_pick_from = -1.0
			if _cradle_carry() != null: cradled = true
	if _b_from < 0.0: return
	if not is_instance_valid(held) or _drop_upright:
		_b_from = -1.0
	elif not (InputMap.has_action("carry_turn") and Input.is_action_pressed("carry_turn")):
		if not cradled: facing_player = not facing_player
		_b_from = -1.0
	elif now - _b_from >= KEY_HOLD_SECONDS:
		_b_from = -1.0
		if cradled:
			cradled = false
			facing_player = true
		elif _cradle_carry() != null:
			cradled = true


## The throw meter by the crosshair while G winds up.
func _update_meter() -> void:
	var charging := _charge_from >= 0.0 and is_instance_valid(held)
	if not charging:
		if is_instance_valid(_meter): _meter.visible = false
		return
	var held_for := Time.get_ticks_msec() / 1000.0 - _charge_from
	if held_for < CHARGE_TAP:
		if is_instance_valid(_meter): _meter.visible = false
		return
	if not is_instance_valid(_meter):
		var layer := CanvasLayer.new(); layer.name = "ThrowMeter"; layer.layer = 20
		add_child(layer)
		_meter = ThrowMeter.new()
		layer.add_child(_meter)
	_meter.visible = true
	(_meter as ThrowMeter).value = charge(held_for)
	_meter.queue_redraw()


## A ring below the crosshair, filling clockwise, green to orange to red (Zelda's stamina wheel).
class ThrowMeter extends Control:
	var value := 0.0
	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var centre := size * 0.5 + Vector2(0.0, 64.0)
		var radius := 22.0
		draw_arc(centre, radius, 0.0, TAU, 48, Color(0.0, 0.0, 0.0, 0.45), 9.0, true)
		var green := Color(0.35, 0.85, 0.3)
		var orange := Color(1.0, 0.62, 0.12)
		var red := Color(0.95, 0.22, 0.16)
		var colour := green.lerp(orange, value * 2.0) if value < 0.5 else orange.lerp(red, value * 2.0 - 1.0)
		if value > 0.001:
			draw_arc(centre, radius, -PI * 0.5, -PI * 0.5 + TAU * value, 48, colour, 6.0, true)

