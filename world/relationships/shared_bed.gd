extends "res://world/life/couch.gd"
## Lie down on a bed and cuddle (dev 2026-09-28: "add the ability for me to cuddle a mare in vr on
## a bed. make sure the mares TOUCH the bed not float off of it. slightly clip into the bed as to
## simulate depressing into the foam"). Every bed works: the shared home's after moving in, the
## Golden Oak guest bed, and any other bed the first time you aim at it (Seating installs one).
##
## VR: aim the right controller at a bed and pull the trigger to sit on it. Touch the mattress with
## the empty right hand and pull the trigger again to lie back. A willing mare nearby (she welcomes
## hugs, the cuddle rule) walks over, climbs in on the open side and lies against you; grip +
## trigger on any part of her poses the cuddle. Trigger on the mattress sits you up. While lying,
## the move stick shifts you along the mattress (up = toward the foot) and only B stands you up
## (dev 2026-09-29); sat up, the stick or B stands. Desktop: E sits, Ctrl lies back, WASD shifts,
## Q stands (Space no longer does, dev 2026-10-22), C and the mouse pose.
## She gets up and carries on (a paused "follow me" resumes) when you stand, stay sat up for ten
## seconds, or she no longer welcomes it. Both bodies rest on the drawn bedding, not the flat
## physics mattress (world/life/couch/mattress.gd); hers presses into it (pony_posture soft_sink).
const MATTRESS := preload("res://world/life/couch/mattress.gd")
const SEAT_SCRIPT := preload("res://world/life/seat.gd")
const EXIT := preload("res://world/life/couch/exit_space.gd")
const BED_FIT := preload("res://world/life/bed_fit.gd")
const BED_OWNER := "leisure:bed:"
## Thread fix "beds" (2026-11-19, posts 43717764/43717774: a JRHNBR mare could not get into bed with
## him; at "Same height" and "Hoers" every mare was refused, at JRHNBR every princess). A mare of any
## size now joins him: Anon lies toward the wall side as far as his own body allows, and her spot is
## fitted to the mattress for her own body (bed_fit.gd). Her floor spot, hop and exit are measured
## with her real collision capsule, not her navigation footprint (0.45 m x size, wider than a bed's
## floor margin from x1.7). Rollback: SIZE_GATE true refuses by scale_fits() as before.
const SIZE_GATE := false
## A mare walking to her spot who stands still this long within HOP_REACH x her body scale of it
## hops in from there (canon 1.8 m: NightRest's "climb in from anywhere reasonably near the bed").
const HOP_REACH := 1.8
const STALL_SECONDS := 2.0
## Anon's reclined head, in from the headboard end (pony bed: 0.62 m toward it from the middle).
const HEAD_IN := 0.43
## Head to hips along the mattress for the reclined avatar (anon_body hip_drop 0.652, 15 degrees).
const HIP_ALONG := 0.63
## Reclined eye over the bedding under the hips, so the hips just press into the foam,
## and at least this far over a pillow under the head.
const EYE_OVER_HIPS := 0.26
const EYE_OVER_PILLOW := 0.1
## Centre to centre, lying side by side: her barrel against your side.
const BESIDE := 0.44
## A bed narrower than this sleeps one; you lie in the middle.
const MARE_HALF_WIDTH := 0.22
## Head to the sitting hips along the mattress (where he sits facing the foot before lying back).
const SIT_ALONG := 0.77
## M-LIF-06 (player board #56, private #326/#360, 2026-11-08): HEAD_IN, HIP_ALONG, SIT_ALONG,
## EYE_OVER_HIPS, EYE_OVER_PILLOW and Anon's half of BESIDE are his body at 6 ft 0 in; they scale with
## his height setting (Settings.anon_height_scale(), 1.0 at 6 ft, so a 6 ft Anon lies exactly as
## before). A mare's half of BESIDE and her length scale with her own body_scale: an adult stallion
## (1.2x the size setting) is laid out at his own size when he joins, not refused for being bigger
## than the setting. Nothing about the contact, the solver or joint limits changes.

var house: Node3D
## A bed with no house API behind it (installed by Seating); `house` beds come from ensure_bed.
var bed_node: Node3D
var partner_id := ""
var runtime: Node
var _bed: Node3D
var _scan := 0.0
var _frame := Transform3D.IDENTITY
var _half := Vector3(1.02, 0.55, 1.05)
var _laid_for: Array = []
var _lane := 0.0
var _side := 1.0
var _mare_fits := false
## The mare size the layout was made for: the ponies' size setting (thread 43671981: at "same
## height as Anon" every mare used to be refused outright). Her half of BESIDE and her footprint
## grow with it; Anon's half stays.
var _mare_scale := 1.0
## Anon's height over the 6 ft Anon these lengths were measured on (1.0 without Settings).
var _anon := 1.0
var _mare_rest := Transform3D.IDENTITY
var _mare_front := Vector3.INF
## The floor she hops from and back to when no measured spot fits her (_hop_spot); INF otherwise.
var _fallback_front := Vector3.INF
var _eye := Vector3.INF
var _eye_floor := -INF
var _top_y := 0.0
var _exit := Vector3.INF
var _sleeper: Node3D
var _sleeper_willing := false
var _guest: Dictionary = {}
var _marked: Array = []
var _cooldowns: Dictionary = {}
var _join_in := 1.0
var _away := 0.0
var _upright := 0.0
var _body_support: Node3D

func _ready() -> void:
	autonomous = false
	add_to_group("couches")
	# Before Navigator and Seating, as on the sofa.
	process_physics_priority = -20

## The rest on `bed`, installed on first use. Seating calls this when you aim at any bed.
static func for_bed(bed: Node3D) -> Node3D:
	var existing: Variant = bed.get_meta("bed_rest") if bed.has_meta("bed_rest") else null
	if is_instance_valid(existing) and not (existing as Node).is_queued_for_deletion(): return existing as Node3D
	var rest: Node3D = load("res://world/relationships/shared_bed.gd").new()
	rest.name = "BedRest"
	rest.set("bed_node", bed)
	bed.add_child(rest)
	rest.call("refresh")
	return rest

## Perf 0.1.0: an empty bed's tick (four beds in town, every tick) skips the cuddle tending, which
## with no occupant, guest or marked mare only advances its timers (done here). false: always tend.
const SHARED_BED_IDLE_SKIP := true

func _physics_process(delta: float) -> void:
	extension = move_toward(extension, 1.0 if opened else 0.0, delta / OPEN_SECONDS)
	_scan -= delta
	if _scan <= 0.0:
		_scan = 0.5
		refresh()
	if not can_open() or seats.size() < 2 or not is_instance_valid(seats[1]): return
	if SHARED_BED_IDLE_SKIP and _guest.is_empty() and _marked.is_empty() and seats[0].free_for() and seats[1].free_for():
		# Nobody on it, no guest, nobody marked: _tend would only advance these timers.
		_away += delta; _upright += delta; _join_in = 1.5
		opened = false
		return
	_tend(delta)
	# Open while anybody uses it: exits and hops then use the floor beside the bed.
	opened = not seats[0].free_for() or not seats[1].free_for() or not _guest.is_empty()

## Find the bed, bind to it once, and lay out who lies where while nobody is on it.
func refresh() -> void:
	var bed := _find_bed()
	if bed == null: return
	if bed != _bed or seats.size() < 2 or not is_instance_valid(seats[0]) or not is_instance_valid(seats[1]):
		if not _claim(bed): return
		_bind(bed)
	_scan_mattress()
	if not seats[0].free_for() or not _guest.is_empty(): return
	var lane := _house_lane()
	_mare_scale = _size_setting()
	_anon = _anon_scale()
	var signature := [_bed.global_transform, _sleeper.get_instance_id() if is_instance_valid(_sleeper) else 0, lane if is_finite(lane) else 99.0, _mare_scale, _anon]
	if signature != _laid_for:
		_laid_for = signature
		_layout()

func _find_bed() -> Node3D:
	if is_instance_valid(bed_node): return bed_node
	if is_instance_valid(house) and house.has_method("ensure_bed"): return house.ensure_bed("player") as Node3D
	return null

## One rest per bed. The shared home's (it knows the partner) replaces another; others defer.
func _claim(bed: Node3D) -> bool:
	var other: Variant = bed.get_meta("bed_rest") if bed.has_meta("bed_rest") else null
	if is_instance_valid(other) and other != self and not (other as Node).is_queued_for_deletion():
		if partner_id.is_empty() or not str(other.get("partner_id")).is_empty(): return false
		(other as Node).queue_free()
	bed.set_meta("bed_rest", self)
	return true

func _bind(bed: Node3D) -> void:
	for old: Variant in seats:
		if is_instance_valid(old): (old as Node).queue_free()
	seats.clear()
	if is_instance_valid(_bed) and _bed != bed and _bed.has_meta("bed_rest") and _bed.get_meta("bed_rest") == self: _bed.remove_meta("bed_rest")
	_bed = bed
	_laid_for = []
	_frame = Transform3D(bed.global_basis.orthonormalized(), bed.global_position)
	_half = _bed_size() * 0.5
	var mine := SEAT_SCRIPT.new()
	mine.name = "PlayerBedSeat"; mine.for_ponies = false
	bed.add_child(mine)
	mine.set_meta("couch", self)
	var hers := SEAT_SCRIPT.new()
	hers.name = "CompanionBedSeat"; hers.for_ponies = false; hers.for_player = false
	bed.add_child(hers)
	hers.set_meta("couch", self)
	seats.append(mine); seats.append(hers)

func _bed_size() -> Vector3:
	var size: Vector3 = Vector3(2.05, 1.1, 2.1)
	if _bed.has_meta("bed_size"): size = _bed.get_meta("bed_size")
	elif _bed.has_meta("size"): size = _bed.get_meta("size")
	return size

## Who lies where, in the bed's unscaled frame (+Z toward the foot, metres): Anon's lane and the side
## she climbs in on, then both bodies' heights from the mattress actually drawn there.
func _layout() -> void:
	_frame = Transform3D(_bed.global_basis.orthonormalized(), _bed.global_position)
	_half = _bed_size() * 0.5
	var head_z := _head_z()
	var open_side: Vector3 = _bed.get_meta("side_local") if _bed.has_meta("side_local") else Vector3.ZERO
	_side = 1.0 if open_side.x >= 0.0 else -1.0
	var shared_lane := _house_lane()
	if is_finite(shared_lane):
		# The shared home's lane for "player"; NightRest tucks the partner into the other one.
		_lane = shared_lane
		if absf(_lane) > 0.01: _side = -signf(_lane)
	elif is_instance_valid(_sleeper):
		# Somepony already sleeps here: lie down beside her.
		_side = 1.0 if (_frame.affine_inverse() * _sleeper.global_position).x >= 0.0 else -1.0
		_lane = -_side * minf(0.48, maxf(_half.x - 0.3, 0.0))
	else:
		_lane = -_side * _beside() * 0.5
		if not SIZE_GATE: _lane = _lane_for(_mare_scale)
	_mare_fits = not is_instance_valid(_sleeper) and (not SIZE_GATE or scale_fits(_mare_scale))
	if not _mare_fits and not is_finite(shared_lane) and not is_instance_valid(_sleeper): _lane = 0.0
	var sit_z := _sit_z()
	var seat_at := _frame * Vector3(_lane, 0.0, sit_z)
	_top_y = _top_at(seat_at)
	var hip_top := _surface(_frame * Vector3(_lane, 0.0, minf(head_z + HIP_ALONG * _anon, sit_z)))
	var head_at := _frame * Vector3(_lane, 0.0, head_z)
	var eye_y := maxf(hip_top + EYE_OVER_HIPS * _anon, _surface(head_at) + EYE_OVER_PILLOW * _anon)
	_eye = Vector3(head_at.x, eye_y, head_at.z)
	_eye_floor = eye_y - 0.06
	# Sit facing the foot, then lie back with the head toward the pillows.
	seats[0].global_transform = Transform3D(Basis.looking_at(_frame.basis.z, Vector3.UP), Vector3(seat_at.x, _top_y, seat_at.z))
	_lay_mare(_mare_scale)
	_exit = _frame * Vector3(-_side * (_half.x + 0.5), 0.02, sit_z)
	# anon_body leans a reclined torso toward company from this frame's x (as on the sofa), and the
	# interaction hint reads the sofa's cushion band (x +-0.85, z -0.12..0.65, 0.42 up) in it:
	# stand the frame on the mattress beside you, on her side.
	var hint_at := _frame * Vector3(_lane + _side * 0.35, 0.0, head_z + 0.42)
	global_transform = Transform3D(_frame.basis, Vector3(hint_at.x, _top_y - HEIGHT, hint_at.z))

## Centre to centre lying side by side: Anon's half of BESIDE at his height plus hers at `scale`
## (the size setting unless given: a joining pony's own body_scale).
func _beside(scale := -1.0) -> float:
	return BESIDE * 0.5 * (_anon + (_mare_scale if scale <= 0.0 else scale))

## His reclined eye, in from the headboard end: HEAD_IN at his height, kept on the mattress.
func _head_z() -> float:
	return -_half.z + minf(HEAD_IN * _anon, maxf(_half.z - 0.2, HEAD_IN))

## Where he sits facing the foot (and the floor exit beside it): SIT_ALONG at his height, short of
## the foot end.
func _sit_z() -> float:
	return minf(_head_z() + SIT_ALONG * _anon, maxf(_half.z - 0.2, _head_z() + 0.3))

## Whether a pony of body scale `scale` lies beside him on this mattress: her barrel beside his
## (BESIDE at both sizes) inside the bed's width, and her whole length (couch.gd MARE_HALF_LENGTH)
## from her spot inside its length. Canon size always fitted the house bed (2.05 x 2.1 m).
func scale_fits(scale: float) -> bool:
	if absf(_lane + _side * _beside(scale)) + MARE_HALF_WIDTH * scale > _half.x: return false
	return scale <= 1.05 or absf(_head_z() + 0.55) + MARE_HALF_LENGTH * scale <= _half.z

## Her spot beside his lane for body scale `scale`: the layout's size, or a joining pony's own
## (`actor`: fitted for her own body's reach, bed_fit.gd).
## Anon's lane was laid out before he lay down (_layout, for a mare at the size setting) and is
## never moved under him; a longer body (a princess) is fitted beside it.
func _lay_mare(scale: float, actor: Node3D = null) -> void:
	var mare_at := _frame * Vector3(_lane + _side * _beside(scale), 0.0, _head_z() + 0.55)
	# She lands on the physics mattress; pony_posture then sinks her into the drawn bedding.
	_mare_rest = Transform3D(Basis.looking_at(-_frame.basis.z, Vector3.UP), Vector3(mare_at.x, _top_at(mare_at) + 0.02, mare_at.z))
	_mare_rest = BED_FIT.fit_actor(_bed, _mare_rest, actor) if actor != null else BED_FIT.fit(_bed, _mare_rest, BED_FIT.mare_reach(scale))
	if seats.size() > 1 and is_instance_valid(seats[1]): seats[1].global_transform = _mare_rest

## Anon's lane on a bed he does not share by household: half of BESIDE toward the wall side, as
## before, and further toward it while her outer side (her back, or her folded legs) would hang off
## the open side; never further than his own body (MARE_HALF_WIDTH x his height) allows. A canon
## mare's lane is the old one exactly.
func _lane_for(scale: float) -> float:
	var lane := -_side * _beside(scale) * 0.5
	var reach: Dictionary = BED_FIT.mare_reach(scale)
	var her_x := lane + _side * _beside(scale)
	# Her body's +x side is the bed's +x (she faces the headboard): her back (right) on +x.
	var outer := (her_x + float(reach.right)) if _side > 0.0 else (-her_x + float(reach.left))
	var over := outer - (_half.x - BED_FIT.EDGE_GAP)
	if over <= 0.0: return lane
	var wall_most := maxf(0.0, _half.x - BED_FIT.EDGE_GAP - MARE_HALF_WIDTH * _anon)
	return -_side * minf(absf(lane) + over, maxf(absf(lane), wall_most))

## Anon's height setting over the 6 ft Anon (1.0 when the Settings autoload is absent, fixtures).
func _anon_scale() -> float:
	var settings: Node = get_node_or_null("/root/Settings")
	return float(settings.call("anon_height_scale")) if settings != null and settings.has_method("anon_height_scale") else 1.0

## The ponies' size setting (1.0 canon; 1.0 when the Settings autoload is absent, fixtures).
func _size_setting() -> float:
	var settings: Node = get_node_or_null("/root/Settings")
	return float(settings.call("pony_scale")) if settings != null and settings.has_method("pony_scale") else 1.0

## The shared home's own lane for "player" when its bed sleeps two; NAN otherwise.
func _house_lane() -> float:
	if not is_instance_valid(house) or bed_node != null or not house.has_method("bed_shared") or not house.bed_shared("player"): return NAN
	var rest: Transform3D = house.bed_rest("player")
	return (_frame.affine_inverse() * rest.origin).x if rest.origin.is_finite() else NAN

## The physics mattress under a point (this bed's own collider), else its measured top.
func _top_at(point: Vector3) -> float:
	var measured := float(_bed.get_meta("mattress_top")) if _bed.has_meta("mattress_top") else 0.6
	var fallback := _bed.to_global(Vector3(0.0, measured, 0.0)).y
	var query := PhysicsRayQueryParameters3D.create(Vector3(point.x, fallback + 0.6, point.z), Vector3(point.x, fallback - 0.5, point.z), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not hit.collider is Node or not (hit.collider == _bed or _bed.is_ancestor_of(hit.collider)): return fallback
	return float(hit.position.y)

## The drawn bedding around a point (a 16 cm cross), world y.
func _surface(point: Vector3) -> float:
	var top := _top_at(point)
	var at := Vector3(point.x, top, point.z)
	var across := _frame.basis.x * 0.08
	var along := _frame.basis.z * 0.08
	var points: Array[Vector3] = [at, at + across, at - across, at + along, at - along]
	return MATTRESS.visible_top(_bed, points, top)

## Somepony already lying on this mattress: a sleeping partner, or one who lay down here herself.
func _scan_mattress() -> void:
	_sleeper = null
	var guest: Node3D = _guest.actor if not _guest.is_empty() and is_instance_valid(_guest.actor) else null
	var measured := float(_bed.get_meta("mattress_top")) if _bed.has_meta("mattress_top") else 0.6
	var top := _bed.to_global(Vector3(0.0, measured, 0.0)).y
	var inverse := _frame.affine_inverse()
	for node: Node in get_tree().get_nodes_in_group("ai_characters"):
		var actor := node as Node3D
		if actor == null or actor == guest: continue
		# Position first (cheap, and rejects nearly every pony), then the method lookup (W2 perf pass).
		var local := inverse * actor.global_position
		if absf(local.x) > _half.x + 0.1 or absf(local.z) > _half.z + 0.1 or absf(actor.global_position.y - top) > 0.4: continue
		if not actor.has_method("posture_status"): continue
		if actor.posture_status().requested == "lie_down":
			_sleeper = actor
			break
	_sleeper_willing = is_instance_valid(_sleeper) and _willing(_sleeper)
	if guest != null: _guest.willing = _willing(guest)

func can_open() -> bool:
	return is_instance_valid(_bed) and not seats.is_empty() and is_instance_valid(seats[0])

func rest_frame(seat: Node3D) -> Node3D:
	var frame := get_node_or_null("RestFrame") as Node3D
	if frame == null:
		frame = Node3D.new(); frame.name = "RestFrame"; add_child(frame); frame.set_meta("couch", self)
	frame.global_transform = Transform3D(_frame.basis * Basis(Vector3.UP, PI), seat.global_position)
	return frame

func sleep_eye(seat: Node3D) -> Vector3:
	return _eye if _eye.is_finite() else seat.global_position + Vector3.UP * EYE_OVER_HIPS * _anon

## Lying down for real in VR: the view stops at a head resting on the bedding.
func rest_floor(_seat: Node3D) -> float:
	return _eye_floor

## Room-scale moves stay on the bed; stepping off it ends the rest (height is held by rest_floor).
func rest_contains(_seat: Node3D, head: Vector3) -> bool:
	var local := _frame.affine_inverse() * head
	return absf(local.x) <= _half.x + 0.45 and absf(local.z) <= _half.z + 0.45

## Shifting while lying stays on the mattress: head between the pillows and the foot end.
func shift_contains(_seat: Node3D, head: Vector3) -> bool:
	var local := _frame.affine_inverse() * head
	return absf(local.x) <= maxf(_half.x - 0.12, 0.1) and local.z >= -_half.z + 0.12 and local.z <= _half.z - 0.15

## The whole mattress is the cushion you touch to lie back or sit up.
func touch_zone(point: Vector3) -> bool:
	if not is_instance_valid(_bed): return false
	var local := _frame.affine_inverse() * point
	return absf(local.x) <= _half.x + 0.1 and absf(local.z) <= _half.z + 0.1 and absf(point.y - _top_y) <= 0.3

## Her standing collision capsule (radius, height): the body that really moves through the room.
## Her navigation profile's radius (0.45 m x size) is a route footprint, a whole bed-side margin wide
## from x1.7 (thread fix "beds"); it stays the fallback for actors without a capsule.
static func body_capsule(actor: Node3D) -> Vector2:
	if actor == null: return Vector2(.19, .85)
	var posture: Variant = actor.get("posture")
	var shape: Variant = posture.get("_standing_shape") if posture != null else null
	if not shape is CapsuleShape3D:
		var holder: Variant = actor.get("_collision")
		shape = (holder as CollisionShape3D).shape if holder is CollisionShape3D else null
	if shape is CapsuleShape3D: return Vector2((shape as CapsuleShape3D).radius, (shape as CapsuleShape3D).height)
	return Vector2(float(actor.profile.radius), float(actor.profile.clearance))

## A hop-down spot that is still this bed's mattress, not the floor beside it (seating.gd _hop_off).
func exit_on_bed(point: Vector3) -> bool:
	if not is_instance_valid(_bed) or not point.is_finite(): return false
	var local := _frame.affine_inverse() * point
	return absf(local.x) <= _half.x + 0.1 and absf(local.z) <= _half.z + 0.1 and local.y > 0.25

## Seating's hop down off this bed measures the floor beside it with this capsule when her profile's
## size finds no floor there (seating.gd _hop_off). Rollback SIZE_GATE: the profile's size only.
func exit_size(actor: Node3D) -> Vector2:
	return body_capsule(actor) if not SIZE_GATE else Vector2(float(actor.profile.radius), float(actor.profile.clearance))

func approach(seat: Node3D) -> Vector3:
	if seats.size() > 1 and seat == seats[1] and _mare_front.is_finite(): return _mare_front
	return _exit if _exit.is_finite() else _frame * Vector3(0.0, 0.02, _half.z + 0.6)

func pony_transform(_seat: Node3D, actor: Node3D = null) -> Transform3D:
	var rest := _mare_rest
	if actor == null: return rest
	var mode := NAP_COMPANY.closeness(actor)
	if mode == "shoulder":
		rest.origin += _frame.basis * Vector3(-_side * .165, 0, -.33)
		rest.basis *= Basis(Vector3.UP,_side*.5)
	elif mode == "snuggle":
		if is_instance_valid(_body_support):
			# The torso is physical support, so the mattress never substitutes for it. Her spot beside
			# him is wider for a bigger mare or a taller Anon (_beside); she still moves onto his torso
			# (player board #56; the same .35 m at canon sizes).
			var wider := maxf(0.0, _beside(_body_scale(actor)) - BESIDE)
			rest.origin += _frame.basis * Vector3(-_side*(.35 + wider),0,-.12)
			rest.origin.y=maxf(rest.origin.y,_body_support.landing_height())
		else:
			rest.origin += _frame.basis * Vector3(-_side*.17,0,-.33)
			rest.basis *= Basis(Vector3.UP,_side*.5)
	# Closer company turns and moves her: her head stays off the headboard (bed_fit.gd). A bigger body
	# lies back by its extra reach so her head lands at his shoulder, not past his head (board #56).
	if mode in ["shoulder", "snuggle"]:
		rest.origin -= BED_FIT.extra_head_reach(rest, actor)
		rest = BED_FIT.fit_actor(_bed, rest, actor)
	return rest

## The one beside you: from your seat, the mare lying here; from hers, you.
func partner(seat: Node3D) -> Node3D:
	if seats.size() > 1 and seat == seats[1]:
		var who: Variant = seats[0].get_meta("occupant") if is_instance_valid(seats[0]) and seats[0].has_meta("occupant") else null
		return who as Node3D if is_instance_valid(who) else null
	var guest: Variant = _guest.get("actor")
	if is_instance_valid(guest) and str(_guest.state) == "resting": return guest as Node3D
	return _sleeper if is_instance_valid(_sleeper) else null

## A willing, idle (or following you) grown-up mare on this floor near the bed.
func eligible(actor: Node3D) -> bool:
	if actor == null or not actor is CharacterBody3D or not actor.has_method("request_posture"): return false
	var to_bed := actor.global_position - _frame.origin
	if Vector2(to_bed.x, to_bed.z).length() > 8.0 or absf(to_bed.y) > 0.5: return false
	if actor.get("sleeping") != false or actor.get("_held") == true or actor.get("motion_paused") == true: return false
	for busy: String in ["seating", "fishing_companion", "balloon_passenger", "cuddle_active"]:
		if actor.has_meta(busy): return false
	if actor.get_meta("affection_active", false): return false
	if actor.has_method("action_interruption_reason") and not str(actor.action_interruption_reason()).is_empty(): return false
	if actor.get("flight") != null and actor.flight.active(): return false
	# Her own size, measured against this mattress beside him (an adult stallion is 1.2x the size
	# setting: refused outright before, player board #56). _invite lays her spot out at her size.
	var body: Variant = actor.get("body_scale")
	if SIZE_GATE and not scale_fits(float(body) if body != null else 1.0): return false
	if Time.get_ticks_msec() < int(_cooldowns.get(actor.get_instance_id(), 0)): return false
	var nav := actor.get_node_or_null("Navigator")
	if nav == null: return false
	if "reserved_by" in nav and not str(nav.reserved_by).is_empty(): return false
	var owner := str(nav.command_owner)
	var routine := owner.is_empty() or owner == "rest_after_command" or owner.begins_with("life:") or owner.begins_with("bond:") or owner.begins_with("day:")
	# M-AI-19 (thread 43686931: Fluttershy never joined him already lying in her bed): a chat owns her
	# navigator as "social:talk", often while she walks up to talk, so her own cuddle() after the
	# chat was refused. Her AI choosing to join (accept()) counts the chat as routine.
	var chatting := _accepting and owner.begins_with("social:")
	var following := _is_player(nav.get("_follow_target")) or not _spoken_follow(actor, nav).is_empty()
	if not following and not chatting and (not routine or nav.get("_has_target") == true): return false
	return _willing(actor)

## Public entry (fixtures, other callers): she walks over and lies down beside you.
func invite(actor: Node3D, _seat: Node3D) -> bool:
	return eligible(actor) and _invite(actor)

func rest_word() -> String:
	return "bed"

## Her AI chose to join him (cuddle()).
func accept(actor: Node3D) -> bool:
	if not _guest.is_empty() or not _mare_fits or is_instance_valid(_sleeper): return false
	_accepting = true
	var joined := invite(actor, null)
	_accepting = false
	return joined

## Her capsule's hop from the floor onto her spot clears walls and furniture (the bed never counts).
## Her navigation profile's capsule first (as before); where that is too big for the room (from about
## x1.7, thread fix "beds") her real collision capsule, the body that actually makes the hop.
func hop_clear(actor: CharacterBody3D, from: Vector3, to: Vector3) -> bool:
	if _hop_clear(actor, from, to, Vector2(float(actor.profile.radius), float(actor.profile.clearance))): return true
	if SIZE_GATE: return false
	if _hop_clear(actor, from, to, body_capsule(actor)): return true
	# No measured spot fits her: the floor she stood on, or the bed's side marker, is her way in and
	# out, unchecked as NightRest's own climb and wake hop to that marker are.
	for spot: Vector3 in [_fallback_front, _side_floor(actor)]:
		if spot.is_finite() and (spot.distance_to(from) < 0.3 or spot.distance_to(to) < 0.3): return true
	return false

func _hop_clear(actor: CharacterBody3D, from: Vector3, to: Vector3, capsule: Vector2) -> bool:
	if not is_instance_valid(_bed): return false
	var exclusions: Array[RID] = [actor.get_rid()]
	for body: Node in _bed.find_children("*", "CollisionObject3D", true, false): exclusions.append((body as CollisionObject3D).get_rid())
	var shape := CapsuleShape3D.new()
	shape.radius = capsule.x
	shape.height = maxf(capsule.y, shape.radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.exclude = exclusions
	for sample in range(1, 9):
		var t := float(sample) / 8.0
		var at: Vector3 = from.lerp(to, t) + Vector3.UP * (sin(PI * t) * 0.3 * actor.body_scale + shape.height * 0.5 + 0.03)
		query.transform = Transform3D(Basis.IDENTITY, at)
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	return true

func _tend(delta: float) -> void:
	var who: Variant = seats[0].get_meta("occupant") if seats[0].has_meta("occupant") else null
	var present := is_instance_valid(who)
	var reclined: bool = present and bool((who as Node).get_meta("couch_sleeping", false))
	_away = 0.0 if present else _away + delta
	_upright = 0.0 if reclined else _upright + delta
	_mark_company(reclined)
	if _guest.is_empty():
		# Settle in first; then the nearest willing mare (your partner, or whoever follows you, first).
		_join_in = _join_in - delta if reclined else 1.5
		if _join_in <= 0.0:
			_join_in = 1.5
			if _mare_fits and not is_instance_valid(_sleeper):
				var chosen := _pick_companion()
				if chosen != null: ask_company(chosen)
		return
	if not is_instance_valid(_guest.actor):
		_clear_body_support(null)
		_guest = {}
		return
	var actor: Node3D = _guest.actor
	var nav := actor.get_node_or_null("Navigator")
	if nav == null or nav.command_owner != _guest.token or actor.get("_held") == true:
		# A new command or a pickup owns her now.
		_finish_guest()
		return
	var seating := get_tree().get_first_node_in_group("pony_seating")
	var phase: String = seating.phase(actor) if seating != null else ""
	_guest.clock = float(_guest.clock) + delta
	var done: bool = _away > 1.5 or _upright > 10.0 or not bool(_guest.willing)
	if is_instance_valid(_body_support) and not _body_support.is_physics_processing():done=true
	match str(_guest.state):
		"joining":
			if phase == "": _finish_guest()
			elif phase == "seated": _guest.state = "resting"
			elif done or float(_guest.clock) > 45.0:
				if phase == "approach": _finish_guest()
				else: _leave()
			elif phase == "approach" and not SIZE_GATE: _hop_when_stalled(actor, seating, delta)
		"resting":
			if phase == "": _finish_guest()
			elif done: _leave()
		"leaving":
			if phase == "" or float(_guest.clock) > 12.0: _finish_guest()
			elif phase == "seated" and actor.posture_status().requested != "stand": actor.request_posture("stand")

func _pick_companion() -> Node3D:
	var best: Node3D = null
	var best_score := INF
	for node: Node in get_tree().get_nodes_in_group("ai_characters"):
		var actor := node as Node3D
		if actor == null or not eligible(actor): continue
		var score := actor.global_position.distance_to(_mare_rest.origin)
		if not partner_id.is_empty() and str(actor.get_meta("relationship_id", "")) == partner_id: score -= 20.0
		var nav := actor.get_node("Navigator")
		if _is_player(nav.get("_follow_target")) or not _spoken_follow(actor, nav).is_empty(): score -= 10.0
		if score < best_score:
			best = actor
			best_score = score
	return best

## Anon carried her here and set her down on the mattress beside him (cradle_rest.gd lay_down, thread
## fix "beds"): she stays as his bed company without walking round and climbing in. Her own will
## decides as for an invitation (she welcomes resting with him); false leaves her to the caller.
func place_guest(actor: Node3D) -> bool:
	if not can_open() or seats.size() < 2 or not is_instance_valid(seats[1]): return false
	var who: Variant = seats[0].get_meta("occupant") if seats[0].has_meta("occupant") else null
	if not is_instance_valid(who) or not bool((who as Node).get_meta("couch_sleeping", false)): return false
	if not _guest.is_empty() or is_instance_valid(_sleeper) or not _willing(actor) or not actor.has_node("Navigator"): return false
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating.has_method("seat_at_rest"): return false
	if not _invite(actor, true): return false
	if not bool(seating.call("seat_at_rest", actor)):
		_finish_guest()
		return false
	return true

func _invite(actor: Node3D, placed := false) -> bool:
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not bool(seating.get("_ready_done")) or not _mare_fits: return false
	if not seats[1].free_for(actor) or not actor is CharacterBody3D: return false
	var body: Variant = actor.get("body_scale")
	_lay_mare(float(body) if body != null else _mare_scale, actor)
	var front := _front_for(actor as CharacterBody3D)
	_fallback_front = Vector3.INF
	if not SIZE_GATE and not front.is_finite():
		# No measured floor spot fits her (a princess at Hoers is 2.9 m tall and 1 m wide by her route
		# footprint): the floor she stands on now, when she is within a hop of her spot, else the bed's
		# own side marker, NightRest's climb-in and wake-up spot for this bed.
		front = _hop_spot(actor)
		_fallback_front = front
	# Laid here by Anon she needs no floor spot to walk to: the exit beside the bed is her way off.
	if placed and not front.is_finite(): front = _exit
	if not front.is_finite() or not open(): return false
	var nav: Node = actor.get_node("Navigator")
	var follow := _spoken_follow(actor, nav)
	var previous := {"owner": nav.command_owner, "wander": nav.wander_enabled, "follow": nav.get("_follow_target")}
	var token := BED_OWNER + str(get_instance_id())
	# The executor would keep steering her toward you; it waits until she gets up again.
	if not follow.is_empty(): follow.executor.set_physics_process(false)
	nav.stay()
	nav.command_owner = token
	if NAP_COMPANY.closeness(actor)=="snuggle":
		var player:Node3D=partner(seats[1])
		if is_instance_valid(player):
			_body_support=preload("res://world/relationships/shared_bed_support.gd").new()
			_body_support.name="SharedTorsoSupport";_bed.add_child(_body_support)
			if _body_support.bind(player,actor):actor.set_meta("shared_nap_on_top",true)
			else:_clear_body_support(actor)
	var rest := {"posture": "lie_down", "owner": token, "front": front, "rest": pony_transform(seats[1], actor), "couch": self}
	if not seating.sit(actor, 8.0, seats[1], rest):
		_clear_body_support(actor)
		nav.command_owner = previous.owner
		nav.wander_enabled = previous.wander
		if not follow.is_empty(): follow.executor.set_physics_process(follow.processing)
		elif is_instance_valid(previous.follow): nav.follow(previous.follow)
		return false
	_mare_front = front
	actor.set_meta("bed_fit_bed", _bed)   # bed_fit.gd lying_words, while she is his bed company
	_guest = {"actor": actor, "token": token, "previous": previous, "follow": follow, "state": "joining", "clock": 0.0, "willing": true}
	return true

## Thread fix "beds": the floor a big mare is allowed to hop from or to when no measured spot fits
## her: where she stands, if within HOP_REACH x her size of her spot on the mattress and on the floor
## the bed stands on, else the bed's side marker on that floor. INF when neither is.
func _hop_spot(actor: Node3D) -> Vector3:
	var here := actor.global_position
	var to_rest := Vector2(here.x - _mare_rest.origin.x, here.z - _mare_rest.origin.z).length()
	if not exit_on_bed(here) and absf(here.y - _frame.origin.y) < 0.5 and to_rest <= HOP_REACH * _body_scale(actor): return here
	return _side_floor(actor)

## The bed's side marker (house_beds.gd bed_side: NightRest's climb-in and wake-up spot) dropped onto
## the floor the bed stands on; INF without a marker or floor there.
func _side_floor(actor: Node3D) -> Vector3:
	if not is_instance_valid(_bed) or not _bed.has_meta("side_local"): return Vector3.INF
	var side := _bed.to_global(Vector3(_bed.get_meta("side_local")))
	var skip: Array[RID] = []
	if actor is CollisionObject3D: skip.append((actor as CollisionObject3D).get_rid())
	for body: Node in _bed.find_children("*", "CollisionObject3D", true, false): skip.append((body as CollisionObject3D).get_rid())
	if _bed is CollisionObject3D: skip.append((_bed as CollisionObject3D).get_rid())
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(side + Vector3.UP * 0.45, side + Vector3.DOWN * 1.2, 1, skip))
	if hit.is_empty() or absf(float(hit.position.y) - _frame.origin.y) >= 0.5: return Vector3.INF
	return hit.position + Vector3.UP * 0.04

## Seating's hop down off this bed when no measured floor fits her (seating.gd _hop_off): the floor
## she came up from, else the side marker. Only without SIZE_GATE.
func exit_fallback(actor: Node3D) -> Vector3:
	if SIZE_GATE: return Vector3.INF
	if _fallback_front.is_finite(): return _fallback_front
	return _side_floor(actor)

func _body_scale(actor: Node3D) -> float:
	var body: Variant = actor.get("body_scale")
	return float(body) if body != null else _mare_scale

## While she walks to her spot: stalled (a big mare turning on the spot in a furnished room, or a
## route that ends short) within a hop of her spot, she hops in from where she stands, as NightRest
## climbs in from anywhere near her own bed.
func _hop_when_stalled(actor: Node3D, seating: Node, delta: float) -> void:
	var here := actor.global_position
	var last: Vector3 = _guest.get("last_at", Vector3.INF)
	if last.is_finite() and here.distance_to(last) < 0.05: _guest.still = float(_guest.get("still", 0.0)) + delta
	else: _guest.still = 0.0
	_guest.last_at = here
	if float(_guest.still) < STALL_SECONDS or not seating.has_method("hop_from_here"): return
	_guest.still = 0.0
	var spot := _hop_spot(actor)
	if not spot.is_finite() or spot.distance_to(here) > 0.3: return
	_fallback_front = spot
	if bool(seating.call("hop_from_here", actor)): _mare_front = spot

## Clear floor beside her spot on the open side, else the bed's own side marker, else the foot.
## Thread fix "beds": the three spots measured with her navigation profile, as before; a bigger mare's
## profile (0.45 m x size) overlapped the bed itself at those spots from x1.7, so the same sides again
## a profile radius out from the mattress; last, with her real collision capsule.
func _front_for(actor: CharacterBody3D) -> Vector3:
	var local := _frame.affine_inverse() * _mare_rest.origin
	var radius := float(actor.profile.radius)
	var sizes: Array[Vector2] = [Vector2(radius, float(actor.profile.clearance))]
	if not SIZE_GATE: sizes.append(body_capsule(actor))
	for size: Vector2 in sizes:
		var candidates: Array[Vector3] = [_frame * Vector3(_side * (_half.x + 0.55), 0.0, local.z)]
		if _bed.has_meta("side_local"): candidates.append(_bed.to_global(Vector3(_bed.get_meta("side_local"))))
		candidates.append(_frame * Vector3(local.x, 0.0, _half.z + 0.6))
		if not SIZE_GATE and size.x + 0.1 > 0.55:
			candidates.append(_frame * Vector3(_side * (_half.x + size.x + 0.1), 0.0, local.z))
			candidates.append(_frame * Vector3(local.x, 0.0, _half.z + size.x + 0.1))
		for at: Vector3 in candidates:
			var floor_at: Vector3 = EXIT.clear_floor(actor, at, size.y, size.x)
			# The floor the bed stands on (she may already lie on the mattress, set down there).
			if floor_at.is_finite() and absf(floor_at.y - _frame.origin.y) < 0.5: return floor_at
	return Vector3.INF

func _leave() -> void:
	_guest.state = "leaving"
	_guest.clock = 0.0
	var actor: Node3D = _guest.actor
	_unmark(actor)
	if actor.has_meta("bed_fit_bed"): actor.remove_meta("bed_fit_bed")
	BED_FIT.mark_left_bed(actor, _bed)
	actor.request_posture("stand")

## Hand her back: her previous owner and wander, then a paused spoken follow or her follow target.
func _finish_guest() -> void:
	var entry := _guest
	_guest = {}
	_fallback_front = Vector3.INF
	# Her spot was laid out at her size (_invite): lay the bed out again for the size setting.
	_laid_for = []
	if not is_instance_valid(entry.get("actor")):
		_clear_body_support(null)
		return
	var actor: Node3D = entry.actor
	if actor.has_meta("bed_fit_bed"): actor.remove_meta("bed_fit_bed")
	_clear_body_support(actor)
	_unmark(actor)
	_cooldowns[actor.get_instance_id()] = Time.get_ticks_msec() + 20000
	var nav := actor.get_node_or_null("Navigator")
	var owned: bool = nav != null and nav.command_owner == entry.token
	if owned:
		nav.stay()
		nav.command_owner = entry.previous.owner
		nav.wander_enabled = entry.previous.wander
	var follow: Dictionary = entry.follow
	if not follow.is_empty() and is_instance_valid(follow.executor):
		var executor: Node = follow.executor
		if executor.movement.get("id") == follow.id:
			if owned:
				executor.set("_last_goal", Vector3.INF)
				executor.set("_last_target", Vector3.INF)
				executor.set_physics_process(true)
			else:
				# A newer command owns her: drop only the paused follow, never the new route.
				executor.movement = {}
				executor.set_physics_process(not executor.gaze.is_empty())
				actor.remove_meta("active_follow")
	elif owned and is_instance_valid(entry.previous.follow):
		nav.follow(entry.previous.follow)

## A spoken "follow me" (the action executor): paused while she lies here, resumed after.
func _spoken_follow(actor: Node3D, nav: Node) -> Dictionary:
	var director := get_tree().get_first_node_in_group("conversation_director")
	var actions: Variant = director.get("actions") if director != null else null
	if not is_instance_valid(actions) or not actions.get("executors") is Dictionary: return {}
	for executor: Variant in actions.executors.values():
		if not is_instance_valid(executor) or executor.get("actor") != actor: continue
		var movement: Dictionary = executor.movement
		if movement.get("type") != "follow" or nav.command_owner != movement.get("id"): return {}
		var target: Variant = movement.target.get_ref() if movement.get("target") is WeakRef else null
		if not _is_player(target): return {}
		return {"executor": executor, "id": movement.id, "processing": executor.is_physics_processing()}
	return {}

func _is_player(node: Variant) -> bool:
	if not is_instance_valid(node) or not node is Node: return false
	var who: Variant = seats[0].get_meta("occupant") if not seats.is_empty() and is_instance_valid(seats[0]) and seats[0].has_meta("occupant") else null
	for mine: Variant in [who, preload("res://world/player_view.gd").camera(self)]:
		if is_instance_valid(mine) and (node == mine or (node as Node).is_ancestor_of(mine) or (mine as Node).is_ancestor_of(node)): return true
	return false

func _willing(actor: Node3D) -> bool:
	return NAP_COMPANY.closeness(actor) != "none"

## couch_cuddle (the sofa's flag) lets cuddle/player_input begin a posing session with whoever
## lies beside you, and curls an awake companion against you.
func _mark_company(reclined: bool) -> void:
	var wanted: Array = []
	if reclined:
		var guest: Variant = _guest.get("actor")
		if is_instance_valid(guest) and str(_guest.state) == "resting":
			var status: Dictionary = guest.posture_status()
			if status.requested == "lie_down" and status.settled: wanted.append(guest)
		if is_instance_valid(_sleeper) and _sleeper_willing: wanted.append(_sleeper)
	for i in range(_marked.size() - 1, -1, -1):
		var actor: Variant = _marked[i]
		if not is_instance_valid(actor): _marked.remove_at(i)
		elif actor not in wanted: _unmark(actor)
	for actor: Variant in wanted:
		if actor not in _marked:
			_marked.append(actor)
			(actor as Node).set_meta("couch_cuddle", true)
			(actor as Node).add_to_group(&"couch_cuddle")  # cuddle/player_input.gd READY_GROUP
		if actor == _guest.get("actor"): actor.expressions.touch("couch", .15, .85)
		var player: Variant = seats[0].get_meta("occupant") if seats[0].has_meta("occupant") else null
		if is_instance_valid(player): NAP_COMPANY.attach(actor, player, self)

func _unmark(actor: Node3D) -> void:
	_release_company(actor)
	_marked.erase(actor)
	if actor.has_meta("couch_cuddle"): actor.remove_meta("couch_cuddle")
	if actor.is_in_group(&"couch_cuddle"): actor.remove_from_group(&"couch_cuddle")
	if actor.get("expressions") != null: actor.expressions.release_touch("couch")

func _exit_tree() -> void:
	if not _guest.is_empty() and is_instance_valid(_guest.actor) and str(_guest.state) != "leaving":
		(_guest.actor as Node).call("request_posture", "stand")
	_finish_guest()
	for actor: Variant in _marked.duplicate():
		if is_instance_valid(actor): _unmark(actor)
	_marked.clear()
	super._exit_tree()
	for seat: Variant in seats:
		if is_instance_valid(seat): (seat as Node).queue_free()
	if is_instance_valid(_bed) and _bed.has_meta("bed_rest") and _bed.get_meta("bed_rest") == self: _bed.remove_meta("bed_rest")

func _clear_body_support(actor:Node3D)->void:
	if is_instance_valid(_body_support):_body_support.queue_free()
	_body_support=null
	if is_instance_valid(actor) and actor.has_meta("shared_nap_on_top"):actor.remove_meta("shared_nap_on_top")
