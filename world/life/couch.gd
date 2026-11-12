extends Node3D
## Reclining and company on the original cushions. The sofa never extends.
## All dimensions are in the furnishing frame's real metres, before the house enters Jolt.
const PLAYER_REST = preload("res://world/life/couch/player_rest.gd")
const NAP_COMPANY := preload("res://world/relationships/shared_nap_company.gd")
const OPEN_SECONDS := 0.8
const FRONT := 0.33
const END := 1.85
const WIDTH := 1.6
const HEIGHT := 0.42
const OWNER := "leisure:couch:"
var seats: Array[Node3D] = []
var opened := false
var extension := 0.0
var autonomous := true
var _check_in := 8.0
var _cooldown := 0.0
var _mattress: MeshInstance3D
var _support: StaticBody3D
var _legs: Array[MeshInstance3D] = []
var _ponies: Dictionary = {}
## Anon lying here with a willing mare nearby: her AI hears about it and decides whether to join
## (cuddle(), relationship_runtime.gd); nothing walks her over by script (dev 2026-09-28).
var _asked: Dictionary = {}
var _accepting := false

static func install(frame: Node3D) -> Node3D:
	var existing := frame.get_node_or_null("Couch")
	if existing != null: return existing as Node3D
	var couch := load("res://world/life/couch.gd").new() as Node3D
	couch.name = "Couch"
	frame.add_child(couch)
	return couch

func _ready() -> void:
	add_to_group("couches")
	for node in get_parent().get_children():
		if node is Node3D and node.get("for_player") == true:
			seats.append(node)
			node.set_meta("couch", self)
	_build_pullout()
	# Before Navigator and Seating: interrupted couch ownership never cancels a new command.
	process_physics_priority = -20

func _build_pullout() -> void:
	# Compatibility name for existing callers; no added furniture or floor collider.
	pass

var _shown_extension := NAN
func _update_pullout() -> void:
	_shown_extension = extension

func can_open() -> bool:
	# Perf 0.1.0: the same test without a lambda and its allocation (beds ask every tick).
	return seats.size() == 2 and is_instance_valid(seats[0]) and is_instance_valid(seats[1])

func head_side(seat: Node3D) -> float:
	var actual: Node3D = seat.get_meta("couch_seat", seat)
	for other: Node3D in seats:
		if other == actual: continue
		var who: Variant = (other.get_meta("occupant") if other.has_meta("occupant") else null)
		if is_instance_valid(who) and who.get("controls_locked") != null:
			return -1.0 if to_local(other.global_position).x < 0.0 else 1.0
	return -1.0 if to_local(actual.global_position).x < 0.0 else 1.0

func rest_frame(seat: Node3D) -> Node3D:
	var key := "RestFrame_" + str(seat.get_instance_id())
	var frame := get_node_or_null(key) as Node3D
	if frame == null:
		frame = Node3D.new(); frame.name = key; add_child(frame)
		frame.set_meta("couch", self); frame.set_meta("couch_seat", seat)
	frame.global_transform = Transform3D(global_basis.orthonormalized() * Basis(Vector3.UP, head_side(seat)*PI/2.0), seat.global_position)
	return frame

func open() -> bool:
	if opened: return true
	if not can_open(): return false
	opened = true
	_wake()
	return true

## An empty, closed sofa only counts down to its next company check, so it stops ticking and a
## physics timer wakes it for that check (23 town sofas ticked every step, 2026-10-14). open()
## (every invite and player rest goes through it) wakes it at once.
var _sleep_id := 0
var _slept_at := 0
func _sleep_until_check() -> void:
	if not _ponies.is_empty() or opened or extension != 0.0 or not is_inside_tree(): return
	_sleep_id += 1
	_slept_at = Time.get_ticks_msec()
	set_physics_process(false)
	get_tree().create_timer(maxf(_check_in, 0.0), false, true).timeout.connect(_check_in_due.bind(_sleep_id))

func _check_in_due(id: int) -> void:
	if id != _sleep_id or is_physics_processing(): return
	_check_in = 0.0
	_wake()

func _wake() -> void:
	if is_physics_processing(): return
	_sleep_id += 1
	_cooldown = maxf(0.0, _cooldown - float(Time.get_ticks_msec() - _slept_at) / 1000.0)
	set_physics_process(true)

func begin_player(player: Node3D, seat: Node3D, camera: Camera3D, avatar: Node3D = null) -> Node:
	if seat not in seats or (seat.get_meta("occupant") if seat.has_meta("occupant") else null) != player: return null
	if avatar != null and not anon_fits(float(avatar.model_scale)): return null
	if player.has_meta("couch_sleeping") or not open(): return null
	var rest := PLAYER_REST.new()
	rest.name = "CouchRest"
	rest.configure(self, player, seat, camera, avatar)
	player.add_child(rest)
	player.set_meta("couch_sleeping", true)
	return rest

func approach(seat: Node3D) -> Vector3:
	return to_global(Vector3(to_local(seat.global_position).x, 0.02, 0.95))

func pony_transform(seat: Node3D, actor: Node3D = null) -> Transform3D:
	var side := head_side(seat)
	var company := partner(seat)
	var closeness: String = NAP_COMPANY.closeness(actor) if actor != null else "none"
	var on_chest: bool = is_instance_valid(company) and company.get_meta("couch_sleeping", false)
	if closeness == "beside": on_chest = false
	var seat_y := to_local(seat.global_position).y
	var at := Vector3(side*0.08 if on_chest else -side*0.22, seat_y + (0.16 if on_chest else 0.02), 0.02)
	if on_chest and closeness == "shoulder": at = Vector3(side*.23, seat_y+.02, .19)
	return Transform3D(global_basis.orthonormalized() * Basis(Vector3.UP, -side*PI/2.0), to_global(at))

func sleep_eye(seat: Node3D) -> Vector3:
	return to_global(Vector3(head_side(seat)*0.61, to_local(seat.global_position).y+0.46, -0.08))

## Where an empty right hand touches the cushions to recline or sit up (VR trigger).
func touch_zone(point: Vector3) -> bool:
	var local := to_local(point)
	return absf(local.x) <= 0.85 and local.z >= -0.12 and local.z <= 0.65 and absf(local.y - HEIGHT) <= 0.3

## Room-scale walking remains real: a VR rest ends once the head leaves this furniture.
func rest_contains(seat: Node3D, head: Vector3) -> bool:
	return head.distance_to(sleep_eye(seat)) <= 1.0

## Lowest eye height a reclined VR player may reach before the rig lifts (-INF: no limit).
func rest_floor(_seat: Node3D) -> float:
	return -INF

func partner(seat: Node3D) -> Node3D:
	var actual: Node3D = seat.get_meta("couch_seat", seat)
	for other in seats:
		if not is_instance_valid(other) or other == actual: continue
		var who: Variant = (other.get_meta("occupant") if other.has_meta("occupant") else null)
		if is_instance_valid(who): return who as Node3D
	return null

func eligible(actor: Node3D) -> bool:
	if actor == null or not actor.has_method("request_posture"): return false
	if actor.get("sleeping") == null or actor.get("sleeping") == true: return false
	if actor.get("_held") or actor.get("motion_paused") or actor.has_meta("seating"): return false
	if actor.get_meta("active_follow", false) or (actor.get("conversing") == true and not _accepting): return false
	if actor.has_method("action_interruption_reason") and not actor.action_interruption_reason().is_empty(): return false
	if actor.get("flight") != null and actor.flight.active(): return false
	if actor.get("hoof_hold") != null and actor.hoof_hold.active(): return false
	if actor.get("carry") != null and actor.carry.blend > 0.0: return false
	if not str(actor.get("_interaction")).is_empty(): return false
	if not fits(actor): return false
	var nav := actor.get_node_or_null("Navigator")
	if nav != null and "reserved_by" in nav and not str(nav.reserved_by).is_empty(): return false
	if nav == null: return false
	# Her AI choosing to join (accept(), M-AI-19): a chat's "social:" ownership, and its walk up to
	# talk, are not a command of hers to keep.
	var chatting: bool = _accepting and str(nav.command_owner).begins_with("social:")
	if (nav._has_target and not chatting) or is_instance_valid(nav._follow_target): return false
	if not (chatting or nav.command_owner.is_empty() or nav.command_owner.begins_with("life:") or nav.command_owner.begins_with("bond:")): return false
	return (chatting or float(actor.get("actual_speed")) < 0.05) and actor.global_position.distance_to(global_position) < 3.5

func rest_word() -> String:
	return "couch"

## Her settled lie-down reaches this far from her root along her length (pony_postures.res lie_down
## bounds: -0.33..+0.42 m at canon size); she lies along the cushions at most this far off centre
## (pony_transform: beside him -0.22, on his chest 0.08, on his shoulder 0.23).
const MARE_HALF_LENGTH := 0.42
const MARE_OFF_CENTRE := 0.23
var _cushion_half := -1.0

## Whether she lies within the cushions at her size. Canon size (and smaller) always did; a bigger
## mare (size setting, thread 43671981) joins when her length fits the seat (the 1.6 m sofa takes
## JRHNBR size, not "same height as Anon").
func fits(actor: Node3D) -> bool:
	var scale_factor := float(actor.get("body_scale"))
	if scale_factor <= 1.05: return true
	return MARE_OFF_CENTRE + MARE_HALF_LENGTH * scale_factor <= cushion_half_span()

## Anon reclined on the cushions at body scale `scale` (avatar.model_scale: his height setting, and in
## VR the headset's world scale too). Was a flat refusal above 1.3 (a chosen VR height over about
## 6 ft 10 in, private board #360) that no geometry asked for. Measured instead: his eye rests at
## sleep_eye (0.61 m off centre), the back of his head ANON_HEAD_BACK x scale beyond it must stay
## within the sofa's end (cushions plus ANON_ARM_REST of armrest), and his hips, ANON_HIP_ALONG x scale
## from the eye, must still lie on the cushions. The 1.6 m sofa takes him up to about 2.2.
const ANON_HEAD_BACK := 0.12
const ANON_HIP_ALONG := 0.63
const ANON_ARM_REST := 0.1
const ANON_EYE_OFF_CENTRE := 0.61
func anon_fits(scale: float) -> bool:
	if not is_finite(scale) or scale <= 0.0: return false
	var span := cushion_half_span()
	if span <= 0.0: span = WIDTH * 0.5
	return ANON_EYE_OFF_CENTRE + ANON_HEAD_BACK * scale <= span + ANON_ARM_REST \
		and ANON_EYE_OFF_CENTRE - ANON_HIP_ALONG * scale >= -span

## Half the seat cushions' length along the sofa (its SeatSolid boxes), measured once; 0 if none.
func cushion_half_span() -> float:
	if _cushion_half >= 0.0: return _cushion_half
	_cushion_half = 0.0
	var solid := get_parent().get_node_or_null("SeatSolid") if get_parent() != null else null
	if solid == null: return _cushion_half
	for node: Node in solid.find_children("*", "CollisionShape3D", true, false):
		var holder := node as CollisionShape3D
		if not holder.shape is BoxShape3D: continue
		var middle := to_local(holder.global_position).x
		var half := (holder.shape as BoxShape3D).size.x * 0.5
		_cushion_half = maxf(_cushion_half, maxf(absf(middle - half), absf(middle + half)))
	return _cushion_half

## Tell her AI that Anon is lying here (once per 90 s per mare).
func ask_company(actor: Node3D) -> void:
	var key := actor.get_instance_id()
	if Time.get_ticks_msec() < int(_asked.get(key, 0)): return
	_asked[key] = Time.get_ticks_msec() + 90000
	if actor.has_signal("physical_reaction"): actor.physical_reaction.emit("anon_resting:" + rest_word())

## Her AI chose to join him (cuddle()): the usual invite, allowed right after she has spoken.
func accept(actor: Node3D) -> bool:
	if NAP_COMPANY.closeness(actor) == "none": return false
	for seat in seats:
		if not is_instance_valid(seat) or not seat.free_for(actor): continue
		_accepting = true
		var joined := invite(actor, seat)
		_accepting = false
		return joined
	return false

## Public fixture/interaction entry; never moves an actor here. Seating owns the walk and hop.
func invite(actor: Node3D, seat: Node3D) -> bool:
	if seat not in seats or not seat.free_for(actor) or not eligible(actor): return false
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating == null or not seating._ready_done: return false
	var front := approach(seat)
	if absf(actor.global_position.y - front.y) > 0.3: return false
	var sight := PhysicsRayQueryParameters3D.create(actor.global_position + Vector3.UP * 0.6, front + Vector3.UP * 0.6, 1)
	if not get_world_3d().direct_space_state.intersect_ray(sight).is_empty(): return false
	if not open(): return false
	var nav := actor.get_node("Navigator")
	var token := OWNER + str(get_instance_id())
	var previous := {"owner": nav.command_owner, "wander": nav.wander_enabled, "style": actor.sleep_style}
	nav.command_owner = token
	var rest := {"posture": "lie_down", "owner": token, "front": front, "rest": pony_transform(seat, actor), "couch": self}
	if not seating.sit(actor, 3.5, seat, rest):
		nav.command_owner = previous.owner
		return false
	_ponies[actor.get_instance_id()] = {"actor": actor, "seat": seat, "previous": previous, "token": token, "elapsed": 0.0, "sleep": false, "waking": false}
	return true

## Check the local boarding arc against furniture/people; the known mattress is its support.
func hop_clear(actor: CharacterBody3D, from: Vector3, to: Vector3) -> bool:
	if extension < 0.99: return false
	var exclusions: Array[RID] = [actor.get_rid()]
	for body in get_parent().find_children("*", "PhysicsBody3D", true, false): exclusions.append(body.get_rid())
	var shape := CapsuleShape3D.new()
	shape.radius = float(actor.profile.radius)
	shape.height = maxf(float(actor.profile.clearance), shape.radius * 2.0)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1 | 2 | 2048
	query.exclude = exclusions
	for sample in range(1, 9):
		var t := float(sample) / 8.0
		var at: Vector3 = from.lerp(to, t) + Vector3.UP * (sin(PI * t) * 0.3 * actor.body_scale + shape.height * 0.5 + 0.03)
		query.transform = Transform3D(Basis.IDENTITY, at)
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): return false
	return true

func _physics_process(delta: float) -> void:
	extension = move_toward(extension, 1.0 if opened else 0.0, delta / OPEN_SECONDS)
	if extension != _shown_extension: _update_pullout()
	var seating := get_tree().get_first_node_in_group("pony_seating") if not _ponies.is_empty() else null
	for id in _ponies.keys():
		var entry: Dictionary = _ponies[id]
		if not is_instance_valid(entry.actor): _ponies.erase(id); continue
		var actor: Node3D = entry.actor
		var nav := actor.get_node_or_null("Navigator")
		var interrupted: bool = nav == null or nav.command_owner != entry.token or bool(actor.get("_held"))
		var phase: String = seating.phase(actor) if seating != null else ""
		entry.elapsed += delta
		if interrupted or phase == "":
			_release_pony(id, not interrupted)
			continue
		if entry.waking: continue
		if entry.elapsed > 240.0 or (entry.sleep and actor.posture_status().requested != "lie_down"):
			actor.sleeping = false
			actor.request_posture("stand")
			entry.waking = true
			continue
		var companion: Node3D=partner(entry.seat)
		var cuddling: bool=phase=="seated" and actor.posture_status().requested == "lie_down" and is_instance_valid(companion) and companion.get_meta("couch_sleeping",false)
		if cuddling and NAP_COMPANY.closeness(actor) == "none":
			actor.request_posture("stand"); entry.waking = true
			_release_company(actor)
			continue
		if cuddling and actor.posture_status().settled: NAP_COMPANY.attach(actor, companion, self)
		elif not cuddling:
			if actor.get_node_or_null("SharedNapCompany") != null:
				actor.request_posture("stand"); entry.waking = true
			_release_company(actor)
		actor.set_meta("couch_cuddle",cuddling)
		# cuddle/player_input.gd READY_GROUP: its per-tick hover looks only at these ponies.
		if cuddling: actor.add_to_group(&"couch_cuddle")
		elif actor.is_in_group(&"couch_cuddle"): actor.remove_from_group(&"couch_cuddle")
		if cuddling: actor.expressions.touch("couch",.15,.85)
		else: actor.expressions.release_touch("couch")
		if phase == "seated" and actor.posture_status().requested == "lie_down" and entry.elapsed > 60.0 and not actor.get_meta("cuddle_active",false):
			if not entry.sleep:
				actor.sleep_style = "head_down"
				actor.sleeping = true
				entry.sleep = true
	_check_in -= delta
	_cooldown = maxf(0.0, _cooldown - delta)
	if _check_in <= 0.0:
		_check_in = randf_range(10.0, 18.0)
		if autonomous and _cooldown <= 0.0: _choose_company()
	# Never retract under either occupant, even after waking or a failed approach.
	if opened and _ponies.is_empty():
		var occupied := false
		for seat in seats:
			if is_instance_valid(seat) and not seat.free_for(): occupied = true
		if not occupied:
			opened = false
	_sleep_until_check()

func _choose_company() -> void:
	var next: Node3D
	var sleeping_player := false
	for seat in seats:
		if not is_instance_valid(seat): continue
		if seat.free_for(): next = seat
		else:
			var who: Variant = (seat.get_meta("occupant") if seat.has_meta("occupant") else null)
			if is_instance_valid(who) and who.get_meta("couch_sleeping", false): sleeping_player = true
	if next == null or not _ponies.is_empty(): return
	if randf() > (0.65 if sleeping_player else 0.15): return
	for actor in get_tree().get_nodes_in_group("ai_characters"):
		if sleeping_player:
			var runtime: Node = (actor.get_meta("relationship_runtime") if actor.has_meta("relationship_runtime") else null)
			if runtime == null or not runtime.bonds.welcomes(str(actor.get_meta("relationship_id", "")), "hug"): continue
			if eligible(actor): ask_company(actor); return
			continue
		if eligible(actor) and invite(actor, next): return

func _release_pony(id: int, request_stand: bool) -> void:
	var entry: Dictionary = _ponies[id]
	_ponies.erase(id)
	_cooldown = 25.0
	if not is_instance_valid(entry.actor): return
	var actor: Node3D = entry.actor
	actor.remove_meta("couch_cuddle")
	if actor.is_in_group(&"couch_cuddle"): actor.remove_from_group(&"couch_cuddle")
	_release_company(actor)
	actor.expressions.release_touch("couch")
	actor.sleeping = false
	actor.sleep_style = entry.previous.style
	var nav := actor.get_node_or_null("Navigator")
	if request_stand: actor.request_posture("stand")
	# If someone took ownership, their route, speed, target and wander policy are untouched.
	if nav != null and nav.command_owner == entry.token:
		nav.stay()
		nav.command_owner = entry.previous.owner
		nav.wander_enabled = entry.previous.wander

func _exit_tree() -> void:
	for id in _ponies.keys(): _release_pony(id, true)
	for seat in seats:
		if not is_instance_valid(seat): continue
		var who: Variant = (seat.get_meta("occupant") if seat.has_meta("occupant") else null)
		# During scene reset the player's branch may have already left the world.
		# Its floor queries are invalid then; only evacuate a still-live occupant.
		if is_instance_valid(who) and who.is_inside_tree() and who.has_method("stand_up"): who.stand_up()
		if seat.has_meta("couch"): seat.remove_meta("couch")

func _release_company(actor: Node) -> void:
	var company := actor.get_node_or_null("SharedNapCompany")
	if company != null: company.finish()
