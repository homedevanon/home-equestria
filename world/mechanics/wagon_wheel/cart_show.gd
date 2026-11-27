extends RefCounted
## What the apple wagon looks like (wagon_wheel.gd owns the state; this only draws it): the whole or
## the broken cart, the apples spilled beside a broken one, and the two moments Anon may watch.
##   break: the whole cart shudders, the broken one drops onto its broken wheel past its rest tilt
##          and settles, dust puffs at the broken corner and the apples roll off the mound.
##   mend:  the broken cart rights itself, then the whole one shows.
## Both carts share one tree (root > RnlAppleacresWagon (the body) > Mesh1, Apple_Mound, Solid;
## root > Apple_Source, one apple parked under the ground). The broken body's authored tilt is read
## from the scene. Timed steps are Tweens made on the wagon wheel node (they end with it) with
## callbacks, no coroutine waits. A break or mend nopony watches is a plain swap (wagon_wheel.gd).
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const BODY := "RnlAppleacresWagon"
const MESH := "Mesh1"
const MOUND := "Apple_Mound"
const APPLE := "Apple_Source"
## The shudder before the break: the whole body's Z turn, degrees, one step each.
const SHUDDER := [1.2, -1.2, 0.8, 0.0]
const SHUDDER_SECONDS := 0.25
const DROP_SECONDS := 0.35
const OVERSHOOT := 1.25
const SETTLE_SECONDS := 0.2
const LEVEL_SECONDS := 0.45
## Spilled apples: how many, how far past the cart's edge on its low side, over what arc.
const APPLES := 6
const APPLE_NEAR := 0.6
const APPLE_FAR := 1.6
const APPLE_ARC := 100.0
const APPLE_RANGE := 40.0
const APPLE_FLIGHT_MIN := 0.4
const APPLE_FLIGHT_MAX := 0.6
const APPLE_RISE := 0.3
const APPLE_SOUNDS := 3
## The dust at the broken wheel.
const DUST_AMOUNT := 16
const DUST_LIFE := 0.6
const DUST_COLOR := Color(0.84, 0.76, 0.62, 0.65)

var wheel: Node   # wagon_wheel.gd
var wagon: Node3D
var whole: Node3D
var broken: Node3D
var whole_body: Node3D
var broken_body: Node3D
var authored := Transform3D.IDENTITY   # the broken body's own tilt
var apples: Array = []                 # MeshInstance3D, children of the wagon
var _apple_key := ""
var _tweens: Array = []
var _end := ""   # while a moment plays: the picture it ends on, "broken" or "whole"
var _landed := 0
var _body_settled := false

func _init(owner_wheel: Node) -> void:
	wheel = owner_wheel

## The wagon and its two cart models (either may be null when its scene is missing).
func bind(on_wagon: Node3D, whole_cart: Node3D, broken_cart: Node3D) -> void:
	clear()
	wagon = on_wagon; whole = whole_cart; broken = broken_cart
	whole_body = whole.get_node_or_null(BODY) as Node3D if whole != null else null
	broken_body = broken.get_node_or_null(BODY) as Node3D if broken != null else null
	authored = broken_body.transform if broken_body != null else Transform3D.IDENTITY

## The wagon is gone: tweens stop, apples go, nothing is held.
func clear() -> void:
	_kill()
	_free_apples()
	wagon = null; whole = null; broken = null; whole_body = null; broken_body = null
	_end = ""

func busy() -> bool:
	return not _end.is_empty()

## The resting picture: the broken cart (with its apples, spilled by `key`) or the whole one.
func rest(show_broken: bool, key: String) -> void:
	if busy() or not _bound(): return
	whole.visible = not show_broken
	broken.visible = show_broken
	if whole_body != null and whole_body.transform != Transform3D.IDENTITY: whole_body.transform = Transform3D.IDENTITY
	if broken_body != null and broken_body.transform != authored: broken_body.transform = authored
	if not show_broken: _free_apples()
	elif apples.is_empty(): _spill(key, false)

func _bound() -> bool:
	return is_instance_valid(wagon) and is_instance_valid(whole) and is_instance_valid(broken)

# --- The break ------------------------------------------------------------------------------------

## Plays the break Anon watches; the apples are spilled by `key` (the favour id).
func play_break(key: String) -> void:
	finish()
	if not _bound(): return
	_end = "broken"
	_apple_key = key
	_body_settled = false
	_free_apples()
	whole.visible = true; broken.visible = false
	_cue("prop_wagon_crack")
	var tween := _tween()
	var step := SHUDDER_SECONDS / float(SHUDDER.size())
	for degrees: float in SHUDDER:
		if whole_body != null: tween.tween_property(whole_body, "rotation:z", deg_to_rad(degrees), step)
		else: tween.tween_interval(step)
	tween.tween_callback(_drop_starts)
	tween.tween_method(_tilt, 0.0, OVERSHOOT, DROP_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(_hits_ground)
	tween.tween_method(_tilt, OVERSHOOT, 1.0, SETTLE_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_settled)

func _drop_starts() -> void:
	if not _alive(): return
	whole.visible = false
	if whole_body != null: whole_body.transform = Transform3D.IDENTITY
	broken.visible = true
	if broken_body != null: broken_body.transform = Transform3D.IDENTITY

func _hits_ground() -> void:
	if not _alive(): return
	_cue("prop_wagon_drop")
	_dust()
	_spill(_apple_key, true)

func _settled() -> void:
	if not _alive(): return
	if broken_body != null: broken_body.transform = authored
	_body_settled = true
	_maybe_done()

## The break is over once the body has settled and every apple has landed.
func _maybe_done() -> void:
	if _end == "broken" and _body_settled and _landed >= apples.size(): _end = ""

## The broken body at `amount` of its authored tilt (0 level, 1 at rest, more past it).
func _tilt(amount: float) -> void:
	if not _alive() or broken_body == null: return
	broken_body.transform = Transform3D(Basis.from_euler(authored.basis.get_euler() * amount), authored.origin * amount)

# --- The mend -------------------------------------------------------------------------------------

## Plays the mend Anon made: the broken cart rights itself, then the whole one shows.
func play_mend() -> void:
	finish()
	if not _bound(): return
	if not broken.visible:
		rest(false, "")
		return
	_end = "whole"
	_cue("prop_wagon_fit")
	var tween := _tween()
	tween.tween_method(_tilt, 1.0, 0.0, LEVEL_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_mended)

func _mended() -> void:
	if not _alive(): return
	_end = ""
	rest(false, "")
	_cue("prop_wagon_fit")

# --- Ending a moment ------------------------------------------------------------------------------

## Stops whatever plays and shows the picture it was heading for.
func finish() -> void:
	var end := _end
	_kill()
	_end = ""
	if end.is_empty() or not _bound(): return
	if end == "broken":
		var key := _apple_key
		_free_apples()
		rest(true, key)
	else:
		rest(false, "")

## Tests: advances every running tween by `delta` seconds (callbacks may start new ones; call again).
func step(delta: float) -> void:
	for tween: Variant in _tweens.duplicate():
		if tween is Tween and (tween as Tween).is_valid(): (tween as Tween).custom_step(delta)
	_tweens = _tweens.filter(func(tween: Variant) -> bool: return tween is Tween and (tween as Tween).is_valid())

func _tween() -> Tween:
	var tween: Tween = wheel.create_tween()
	_tweens = _tweens.filter(func(old: Variant) -> bool: return old is Tween and (old as Tween).is_valid())
	_tweens.append(tween)
	return tween

func _kill() -> void:
	for tween: Variant in _tweens:
		if tween is Tween and (tween as Tween).is_valid(): (tween as Tween).kill()
	_tweens.clear()

## Still drawing on a wagon in the tree; otherwise the moment ends where it was heading.
func _alive() -> bool:
	if _bound() and wagon.is_inside_tree(): return true
	finish()
	return false

func _cue(cue: String) -> void:
	if is_instance_valid(wagon): wheel.cue(cue, wheel.middle())

# --- Apples and dust ------------------------------------------------------------------------------

## Six apples on the ground on the cart's low side, placed by a hash of `key` (the same favour id
## gives the same apples after a reload). `roll`: they roll there from the mound top.
func _spill(key: String, roll: bool) -> void:
	_free_apples()
	var source := broken.get_node_or_null(APPLE) as MeshInstance3D if is_instance_valid(broken) else null
	if source == null or source.mesh == null: return
	_apple_key = key
	_landed = 0
	var box := source.mesh.get_aabb()
	var size := source.transform.basis.get_scale()
	var lift := -box.position.y * size.y
	var start := _mound_top()
	var places := spots(key)
	for index: int in places.size():
		var spot: Vector3 = places[index]
		var apple := MeshInstance3D.new()
		apple.name = "SpilledApple%d" % index
		apple.mesh = source.mesh
		for surface: int in source.get_surface_override_material_count():
			apple.set_surface_override_material(surface, source.get_surface_override_material(surface))
		apple.visibility_range_end = APPLE_RANGE
		apple.visibility_range_end_margin = 2.0
		apple.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		wagon.add_child(apple)
		var yaw := TAU * _unit(key, "yaw", index)
		apple.global_transform = Transform3D(Basis(Vector3.UP, yaw).scaled(size), spot + Vector3.UP * lift)
		apples.append(apple)
		if roll and start.is_finite():
			var end := apple.global_position
			apple.global_position = start
			var flight := lerpf(APPLE_FLIGHT_MIN, APPLE_FLIGHT_MAX, _unit(key, "flight", index))
			var tween := _tween()
			tween.tween_method(_roll_apple.bind(apple, start, end), 0.0, 1.0, flight)
			tween.tween_callback(_apple_lands.bind(apple))

func _roll_apple(amount: float, apple: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	if is_instance_valid(apple): apple.global_position = from.lerp(to, amount) + Vector3.UP * APPLE_RISE * 4.0 * amount * (1.0 - amount)

func _apple_lands(apple: MeshInstance3D) -> void:
	if not is_instance_valid(apple): return
	_landed += 1
	if _landed <= APPLE_SOUNDS: wheel.cue("prop_wagon_apple", apple.global_position)
	_maybe_done()

func _free_apples() -> void:
	for apple: Variant in apples:
		if is_instance_valid(apple): (apple as Node).queue_free()
	apples.clear()

## Where the apples of `key` lie (world points on the ground), or [] without a broken cart.
func spots(key: String) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not _bound(): return result
	var low := _low_side()
	var middle: Vector3 = wagon.to_local(wheel.middle())
	var edge := _edge(low, middle)
	for index: int in APPLES:
		var share := (float(index) + 0.5) / float(APPLES) - 0.5
		var angle := deg_to_rad(share * APPLE_ARC + (_unit(key, "turn", index) - 0.5) * APPLE_ARC / float(APPLES) * 0.6)
		var out := low.rotated(Vector3.UP, angle)
		var at := Vector3(middle.x, 0.0, middle.z) + low * edge + out * lerpf(APPLE_NEAR, APPLE_FAR, _unit(key, "far", index))
		var world: Vector3 = wagon.to_global(at)
		world.y = wheel.ground_height(world)
		result.append(world)
	return result

## The horizontal way the tilted body's up leans, in the wagon's frame.
func _low_side() -> Vector3:
	var up := (broken.transform.basis * authored.basis) * Vector3.UP
	var flat := Vector3(up.x, 0.0, up.z)
	return flat.normalized() if flat.length() > 0.0001 else Vector3.RIGHT

## How far the cart's body reaches from its middle toward `side` (wagon frame).
func _edge(side: Vector3, middle: Vector3) -> float:
	var mesh := broken_body.get_node_or_null(MESH) as MeshInstance3D if broken_body != null else null
	if mesh == null or mesh.mesh == null: return 1.0
	var into_wagon := broken.transform * authored * mesh.transform
	var box := mesh.mesh.get_aabb()
	var reach := 0.0
	for corner: int in 8:
		var point: Vector3 = into_wagon * box.get_endpoint(corner)
		reach = maxf(reach, Vector3(point.x - middle.x, 0.0, point.z - middle.z).dot(side))
	return reach

func _mound_top() -> Vector3:
	var mound := broken_body.get_node_or_null(MOUND) as MeshInstance3D if broken_body != null else null
	if mound == null or mound.mesh == null: return wheel.middle()
	var box := mound.mesh.get_aabb()
	return mound.global_transform * Vector3(box.get_center().x, box.end.y, box.get_center().z)

## One shot of pale dust at the broken body's lowest corner, freed when it is done.
func _dust() -> void:
	var mesh := broken_body.get_node_or_null(MESH) as MeshInstance3D if broken_body != null else null
	if mesh == null or mesh.mesh == null: return
	var box := mesh.mesh.get_aabb()
	var lowest := Vector3.INF
	for corner: int in 8:
		var point: Vector3 = broken.global_transform * authored * mesh.transform * box.get_endpoint(corner)
		if not lowest.is_finite() or point.y < lowest.y: lowest = point
	var dust := CPUParticles3D.new()
	dust.name = "WheelDust"
	dust.one_shot = true
	dust.amount = DUST_AMOUNT
	dust.lifetime = DUST_LIFE
	dust.explosiveness = 0.9
	dust.direction = Vector3.UP
	dust.spread = 70.0
	dust.initial_velocity_min = 0.3
	dust.initial_velocity_max = 0.9
	dust.gravity = Vector3(0.0, -0.6, 0.0)
	dust.damping_min = 0.6
	dust.damping_max = 1.2
	dust.scale_amount_min = 0.6
	dust.scale_amount_max = 1.4
	dust.color = DUST_COLOR
	dust.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new(); quad.size = Vector2(0.18, 0.18)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	quad.material = material
	dust.mesh = quad
	dust.finished.connect(dust.queue_free)
	wagon.add_child(dust)
	dust.global_position = lowest
	dust.emitting = true
	wheel.cue("dust", lowest, false)

## 0..1 from `key`, a salt and an index: the same favour id gives the same apples.
static func _unit(key: String, salt: String, index: int) -> float:
	return float(hash("%s|%s|%d" % [key, salt, index]) & 0xFFFFFF) / float(0xFFFFFF)
