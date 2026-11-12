extends Node
## Scooping and throwing snowballs (W2-SEAS-F, design 6.2), a grab provider on the pattern of
## world/inventory/harvest_pickup.gd. Where world/seasons/snow_cover_query.gd says the snow at the
## palm (VR) or the looked-at ground (desktop) is deeper than SCOOP_COVER, grip (VR) or E / click
## (desktop) scoops a snowball into the hand. VR: let go with a swing to throw, gently near the
## ground to set it down for rolling. Desktop: Q or click throws, E sets it down on snow to roll.
## A snowball in a hand never enters the briefcase (it is snow, not an item).
## In the groups (grab_providers, interaction_hint_sources, desktop_item_presentations) and taking
## input only while snow play is active; physics runs only while a hand holds a snowball.
const FLIGHT := preload("res://player/wing_flight.gd")
const TARGETS := preload("res://world/inventory/grab_targets.gd")
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
## Snow cover (snow_cover_query.gd) needed to scoop a snowball (and to grow a rolled ball).
const SCOOP_COVER := 0.4
const HOLD := Transform3D(Basis.IDENTITY, Vector3(.19, -.18, -.42))
const GROUPS := ["grab_providers", "interaction_hint_sources", "desktop_item_presentations"]
## VR: the palm must be this close above the snow to scoop.
const SCOOP_HEIGHT := 0.22
const DESKTOP_REACH := 2.6
const THROW_SPEED := 11.0
const THROW_LIFT := 2.2
## VR: a release slower than this is a set-down (on snow near the ground) or a drop.
const SWING_SPEED := 1.6
const SET_DOWN_HEIGHT := 0.35
const SAMPLE_SECONDS := 0.1

var play: Node
var inventory: Node
var held: Dictionary = {}          # side -> snowball
var _markers: Dictionary = {}      # side -> Node3D scoop marker (the router needs a target node)
var _track: Dictionary = {}        # side -> [[time, position], ...]
var enabled := false

func setup(owner_play: Node) -> void:
	play = owner_play
	process_physics_priority = -60
	set_physics_process(false)
	set_enabled(false)

## NOTIFICATION_READY turns input and physics back on for any node that defines _input,
## _unhandled_input or _physics_process; setup() ran before this node entered the tree.
func _ready() -> void:
	set_process_input(enabled); set_process_unhandled_input(enabled)
	set_physics_process(not held.is_empty())

## Joins the provider groups and takes input only while snow play is on.
func set_enabled(on: bool) -> void:
	enabled = on
	for group: String in GROUPS:
		if on and not is_in_group(group): add_to_group(group)
		elif not on and is_in_group(group): remove_from_group(group)
	set_process_input(on); set_process_unhandled_input(on)
	if not on:
		for side: String in held.keys(): drop(side)

func _ui() -> Node:
	if not is_instance_valid(inventory) and is_instance_valid(play): inventory = play.call("ui")
	return inventory if is_instance_valid(inventory) else null

func _available() -> bool:
	var ui := _ui()
	if ui == null or not enabled: return false
	var camera: Variant = ui.get("camera")
	if not camera is Camera3D or not is_instance_valid(camera): return false
	var body: Variant = ui.get("player_body")
	if not body is Node or not is_instance_valid(body) or bool((body as Node).get("controls_locked")): return false
	return not (ui.has_method("_quick_blocked") and bool(ui.call("_quick_blocked")))

func _desktop() -> bool:
	var ui := _ui()
	return ui != null and bool(ui.get("_desktop"))

func _player_body() -> Node:
	var ui := _ui()
	var body: Variant = ui.get("player_body") if ui != null else null
	return body as Node if body is Node and is_instance_valid(body) else null

# ------------------------------------------------------------------ where snow can be scooped

## Desktop: the looked-at snowy ground within reach, {"point", "cover"} or {}.
func desktop_spot() -> Dictionary:
	if not _available() or not _desktop(): return {}
	var ui := _ui()
	var camera: Camera3D = ui.get("camera")
	var excluded: Array[RID] = []
	var body := _player_body()
	if body is CollisionObject3D: excluded.append((body as CollisionObject3D).get_rid())
	var from := camera.global_position
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * DESKTOP_REACH, 1 | 2 | 8 | (1 << 17), excluded))
	if hit.is_empty() or not _ground_hit(hit): return {}
	var cover: float = play.call("cover_at", hit.position)
	return {"point": hit.position, "cover": cover} if cover > SCOOP_COVER else {}

## Ground, not an object: an up-facing static surface at the terrain height (when terrain exists).
func _ground_hit(hit: Dictionary) -> bool:
	var normal: Vector3 = hit.get("normal", Vector3.ZERO)
	if normal.y < 0.6: return false
	var collider: Variant = hit.get("collider")
	if collider is RigidBody3D or collider is CharacterBody3D or collider is AnimatableBody3D: return false
	if collider is Node and ((collider as Node).has_meta("item_id") or (collider as Node).has_meta("token")): return false
	var point: Vector3 = hit.position
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.has_ground(point):
		return absf(WorldTerrain.instance.height_at(point) - point.y) < 0.35
	return true

## VR: the snow under this palm, {"point", "cover"} or {} (palm within SCOOP_HEIGHT of snow).
func hand_spot(palm: Vector3) -> Dictionary:
	if not palm.is_finite(): return {}
	var ground := Vector3.INF
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.has_ground(palm):
		ground = Vector3(palm.x, WorldTerrain.instance.height_at(palm), palm.z)
	elif is_inside_tree():
		var excluded: Array[RID] = []
		var body := _player_body()
		if body is CollisionObject3D: excluded.append((body as CollisionObject3D).get_rid())
		var hit := get_viewport().world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(palm + Vector3.UP * 0.1, palm + Vector3.DOWN * (SCOOP_HEIGHT + 0.1), 1, excluded)) if get_viewport() != null and get_viewport().world_3d != null else {}
		if not hit.is_empty() and _ground_hit(hit): ground = hit.position
	if not ground.is_finite() or palm.y - ground.y > SCOOP_HEIGHT or palm.y - ground.y < -0.15: return {}
	var cover: float = play.call("cover_at", ground)
	return {"point": ground, "cover": cover} if cover > SCOOP_COVER else {}

# ------------------------------------------------------------------ VR grab provider

func _marker(side: String) -> Node3D:
	var marker: Node3D = _markers.get(side)
	if not is_instance_valid(marker):
		marker = Node3D.new(); marker.name = "ScoopMarker_" + side
		add_child(marker); _markers[side] = marker
	return marker

func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not _available() or held.has(side) or _desktop(): return {}
	var ui := _ui()
	if ui.has_method("hand_busy") and bool(ui.call("hand_busy", side)): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var palm: Vector3 = sample.get("grip_position", pose.origin)
	if not sample.get("active", false) or not pose.is_finite() or not palm.is_finite(): return {}
	# A snowball lying on the snow first.
	var best: Dictionary = {}
	var gap := TARGETS.REACH
	for ball: Node3D in play.call("loose_snowballs"):
		var d := palm.distance_to(ball.global_position) - FX.MODEL_RADIUS
		if d < gap:
			gap = d; best = {"target": ball, "point": ball.global_position, "distance": maxf(d, 0.0), "text": side.capitalize() + " grip · Pick up the snowball"}
	if not best.is_empty(): return best
	var spot := hand_spot(palm)
	if spot.is_empty(): return {}
	var marker := _marker(side)
	marker.global_position = spot.point
	return {"target": marker, "point": spot.point, "distance": maxf(palm.y - (spot.point as Vector3).y, 0.0), "text": side.capitalize() + " grip · Scoop a snowball", "visible_pick": false}

func grab_take(side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	var target: Variant = offer.get("target")
	if target is RigidBody3D and is_instance_valid(target) and (target as Node).get("play") == play:
		return take(side, target as RigidBody3D)
	var point: Variant = offer.get("point")
	return scoop(side, point if point is Vector3 else Vector3.INF)

# ------------------------------------------------------------------ holding

## A new snowball from the snow at `point` into this hand.
func scoop(side: String, point: Vector3) -> bool:
	if not _available() or held.has(side): return false
	var ui := _ui()
	if ui.has_method("hand_busy") and bool(ui.call("hand_busy", side)): return false
	if point.is_finite() and float(play.call("cover_at", point)) <= SCOOP_COVER: return false
	var ball: RigidBody3D = play.call("spawn_snowball", point if point.is_finite() else Vector3.ZERO)
	if ball == null: return false
	if point.is_finite():
		play.call("stamp_trail", point, 0.12)
		FX.sound(ball, "snow_play_scoop", point)
	return take(side, ball)

## Takes a snowball (new or lying) into this hand.
func take(side: String, ball: RigidBody3D) -> bool:
	if not _available() or held.has(side) or not is_instance_valid(ball): return false
	var ui := _ui()
	if ui.has_method("hand_busy") and bool(ui.call("hand_busy", side)): return false
	ball.call("hold")
	held[side] = ball
	_track[side] = []
	if side == "desktop": ui.set_meta("desktop_activity_owner", self)
	else:
		var hands: Variant = ui.get("hands")
		var hand: Variant = (hands as Dictionary).get(side) if hands is Dictionary else null
		if hand is Node and is_instance_valid(hand): (hand as Node).set_meta("snow_owner", self)
	if ui.has_method("_claim"): ui.call("_claim", side, true)
	if ui.has_method("_haptic"): ui.call("_haptic", side)
	set_physics_process(true)
	return true

func _clear_hand(side: String) -> void:
	held.erase(side); _track.erase(side)
	if held.is_empty(): set_physics_process(false)
	var ui := _ui()
	if ui == null: return
	if side == "desktop":
		if ui.has_meta("desktop_activity_owner") and ui.get_meta("desktop_activity_owner") == self:
			var presentation: Variant = ui.get("desktop_presentation")
			if presentation is Object and is_instance_valid(presentation) and (presentation as Object).has_method("clear_hold_target"): (presentation as Object).call("clear_hold_target", "right")
			ui.remove_meta("desktop_activity_owner")
			if ui.has_method("_claim"): ui.call("_claim", side, false)
	else:
		var hands: Variant = ui.get("hands")
		var hand: Variant = (hands as Dictionary).get(side) if hands is Dictionary else null
		if not (hand is Node and is_instance_valid(hand)):
			if ui.has_method("_claim"): ui.call("_claim", side, false)
		elif (hand as Node).has_meta("snow_owner") and (hand as Node).get_meta("snow_owner") == self:
			(hand as Node).remove_meta("snow_owner")
			if ui.has_method("_claim"): ui.call("_claim", side, false)

## Throws the snowball in this hand.
func throw(side: String, velocity: Vector3) -> bool:
	var ball: RigidBody3D = held.get(side)
	if not is_instance_valid(ball): _clear_hand(side); return false
	_clear_hand(side)
	ball.call("throw", velocity, _player_body())
	return true

## Sets the snowball down on the snow below it, where it becomes a ball to roll (snowman.gd).
## On no snow it is simply dropped.
func set_down(side: String) -> bool:
	var ball: RigidBody3D = held.get(side)
	if not is_instance_valid(ball): _clear_hand(side); return false
	var at := ball.global_position
	if side == "desktop":
		var spot := desktop_spot()
		if spot.is_empty(): return false
		at = spot.point
	else:
		var spot := hand_spot(at)
		if not spot.is_empty(): at = spot.point
		elif is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.has_ground(at): at.y = WorldTerrain.instance.height_at(at)
	_clear_hand(side)
	if play.call("place_ball", ball, at) == null: ball.call("throw", Vector3.ZERO, _player_body())
	return true

func drop(side: String) -> void:
	var ball: RigidBody3D = held.get(side)
	_clear_hand(side)
	if is_instance_valid(ball): ball.call("throw", Vector3.ZERO, _player_body())

func _velocity(side: String) -> Vector3:
	var samples: Array = _track.get(side, [])
	if samples.size() < 2: return Vector3.ZERO
	var last: Array = samples[-1]
	var first: Array = samples[0]
	for s: Array in samples:
		if float(last[0]) - float(s[0]) <= SAMPLE_SECONDS: first = s; break
	var dt := float(last[0]) - float(first[0])
	if dt < 0.008: return Vector3.ZERO
	return ((last[1] as Vector3) - (first[1] as Vector3)) / dt

func _physics_process(_delta: float) -> void:
	if held.is_empty(): set_physics_process(false); return
	var ui := _ui()
	for side: String in held.keys():
		var ball: RigidBody3D = held[side]
		if not is_instance_valid(ball) or str(ball.get("state")) != "held": _clear_hand(side); continue
		if not _available(): drop(side); continue
		if side == "desktop":
			var camera: Camera3D = ui.get("camera")
			ball.global_transform = camera.global_transform * HOLD
			var presentation: Variant = ui.get("desktop_presentation")
			if presentation is Object and is_instance_valid(presentation) and (presentation as Object).has_method("set_hold_target"): (presentation as Object).call("set_hold_target", "right", ball.global_transform, "hold")
			continue
		var sample: Dictionary = ui.call("hand_sample", side)
		var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
		var palm: Vector3 = sample.get("grip_position", pose.origin)
		if not sample.get("active", false) or not pose.is_finite() or not palm.is_finite(): drop(side); continue
		ball.global_position = palm
		var samples: Array = _track.get(side, [])
		samples.append([Time.get_ticks_usec() * 0.000001, palm])
		if samples.size() > 10: samples.pop_front()
		_track[side] = samples
		if float(sample.get("grip", 0.0)) < .25:
			var v := _velocity(side)
			if v.length() > SWING_SPEED: throw(side, (v * 1.15).limit_length(22.0))
			elif not hand_spot(palm).is_empty() or _near_ground(palm): set_down(side)
			else: throw(side, v)

func _near_ground(palm: Vector3) -> bool:
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.has_ground(palm):
		return palm.y - WorldTerrain.instance.height_at(palm) < SET_DOWN_HEIGHT
	return false

# ------------------------------------------------------------------ desktop input and hints

func _input(event: InputEvent) -> void:
	if not held.has("desktop") or not _desktop() or not _available(): return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT.reserves_mouse(event, _player_body()): return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	var camera: Camera3D = _ui().get("camera")
	var aim := -camera.global_basis.z * THROW_SPEED + Vector3.UP * THROW_LIFT
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Q:
			if event.shift_pressed:
				if not set_down("desktop"): drop("desktop")
			else: throw("desktop", aim)
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_E:
			set_down("desktop"); get_viewport().set_input_as_handled()
		elif event.physical_keycode in [KEY_I, KEY_U, KEY_TAB, KEY_J]:
			drop("desktop")
		elif event.physical_keycode == KEY_G or event.physical_keycode >= KEY_1 and event.physical_keycode <= KEY_5:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		if event.pressed: throw("desktop", aim)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not _desktop() or held.has("desktop") or not _available(): return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT.reserves_mouse(event, _player_body()): return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	var pressed: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	pressed = pressed or (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E)
	if not pressed: return
	var ui := _ui()
	if ui.has_method("hand_busy") and bool(ui.call("hand_busy", "desktop")): return
	var spot := desktop_spot()
	if not spot.is_empty() and scoop("desktop", spot.point): get_viewport().set_input_as_handled()

func interaction_hint() -> Dictionary:
	if not _desktop() or not _available(): return {}
	if held.has("desktop"):
		var ball: Node3D = held.desktop
		var down := "   E · Set it down to roll" if not desktop_spot().is_empty() else ""
		return {"target": ball, "point": ball.global_position, "text": "Click / Q · Throw" + down, "outline": null}
	var ui := _ui()
	if ui.has_method("hand_busy") and bool(ui.call("hand_busy", "desktop")): return {}
	var spot := desktop_spot()
	if spot.is_empty(): return {}
	return {"target": _marker("desktop"), "point": spot.point, "text": "Click / E · Scoop a snowball", "outline": null}

func item_presentation() -> Dictionary:
	var ball: Variant = held.get("desktop")
	return {"action": "hold", "held": ball, "target": ball, "point": (ball as Node3D).global_position, "helper": false, "progress": 0.0} if ball is Node3D and is_instance_valid(ball) else {}

func cancel_desktop_activity() -> void:
	if held.has("desktop"): drop("desktop")

func _exit_tree() -> void:
	for side: String in held.keys(): drop(side)
