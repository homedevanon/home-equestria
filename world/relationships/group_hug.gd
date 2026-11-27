extends Node
## Group hug (player bug board #28, Anon's design 2026-11-20). While Anon hugs one pony
## (player/pony_kisser.gd _attempt_hug), up to three other ponies standing close by join in, each
## one at least his friend (player_bonds.gd stage "friend" or closer), awake, free (no plan step or
## shift, no story scene, not carried, not already in a hug or kiss) and not angry with him.
##
## Where they stand: a ring around him a quarter turn apart, counted from the pony he hugs. The
## first joiner comes to his side (the side the nearest of them already stands on), the second
## behind him, the third to his other side. Each walks round to a line-up point just outside her
## spot and steps in facing him, so her muzzle rests against him at her own height. A spot her body
## would share with the pony he hugs or another joiner turns a little round, or moves a little
## outward, until it is clear; her length comes from her own skeleton, so this holds at every pony
## size. Nobody teleports.
##
## On arrival she starts the ordinary hug (pony_affection.begin("hug")): exactly what one hug gives
## her today, once. When he lets go of the pony he hugs, every joiner steps back and her navigator
## goes back to whoever held it before; one pulled away by something more important (sleep, a
## carry, a story scene, her day plan) simply leaves. One world event names who was in it.
## A pony's own [cuddle] reply while he hugs joins the same way (join(), relationship_runtime.gd).
## Ticks only while a joiner walks in, hugs or steps back.

const BONDS := preload("res://world/relationships/player_bonds.gd")
const MAX_JOINERS := 3
## How far (metres, flat) a pony may stand from him and still choose to come over with [cuddle].
const TAG_REACH := 6.0
## His torso's half depth at chest height for a 1.0 Anon height (player_mouth.gd human_scale).
const ANON_RADIUS := .17
## A pony's body half width at size 1.0, for keeping joiners' bodies apart.
const BODY_RADIUS := .15
## Metres (at size 1.0) outside her spot where she lines up before she steps in.
const APPROACH := .45
## Metres per second: a walk, under the trot band, which starts near 0.45 m/s.
const WALK_SPEED := .4
const STEP_SPEED := .3
const ARRIVE := .05
## She walks round him in arcs of this much at a time, never across the pony he hugs, on a ring
## clear of the joiners already there.
const AROUND := deg_to_rad(50.0)
## Seconds of slack on top of her walk's length at WALK_SPEED before a blocked walk gives up.
const WALK_SECONDS := 8.0
const BACK_SECONDS := 1.2
const BACK_SPEED := .25
## He walked this far from a joiner (metres): she lets go.
const LET_GO := 1.8
## The navigator owner while she walks in or steps back (pony_affection.gd holds it while she hugs).
const OWNER := "group_hug"

var camera: Camera3D
## Anon's height against the 1.0 reference; the player's kisser (player/pony_kisser.gd) sets it before
## each gather or join, from player_mouth.gd human_scale.
var anon_scale := 1.0
## The Affection node (pony_affection.gd) of the pony he hugs; null when no group hug runs.
var first: Node
## One row per joiner: mare, affection, nav, spot, dir, owner, wander, phase, t, lined, around.
var joiners: Array[Dictionary] = []
var _center := Vector3.ZERO
var _toward_first := Vector3.FORWARD
var _slots: Array[float] = []
var _occupied: Array[Dictionary] = []
var _hugged: Array[Node3D] = []
var _count := 0
var _running := false


func _ready() -> void:
	# After the navigators (-10), which halt a claimed pony every tick, and before the pony bodies (0).
	process_physics_priority = -4
	set_physics_process(false)


## He hugs `affection`'s pony: the ponies within `reach` (flat metres) who may, walk in. Returns
## how many come.
func gather(affection: Node, ponies: Array, view: Camera3D, reach: float) -> int:
	finish()
	if not is_instance_valid(affection) or str(affection.kind) != "hug" or not is_instance_valid(view): return 0
	first = affection; camera = view; _count = 0; _running = true
	_center = _flat(view.global_position)
	var mare: Node3D = affection.mare
	var toward := _flat(affection.mouth_point()) - _center
	if toward.length() < .05: toward = _flat(mare.global_position) - _center
	if toward.length() < .05: toward = _flat(-view.global_basis.z)
	_toward_first = toward.normalized() if toward.length() > .001 else Vector3.FORWARD
	_occupied = [_footprint(mare, affection)]
	_hugged = [mare]
	var candidates: Array[Node3D] = []
	for pony: Variant in ponies:
		if pony is Node3D and _eligible(pony as Node3D, reach): candidates.append(pony as Node3D)
	# His side the nearest of them already stands on comes first, then behind him, then the other side.
	var side := 1.0
	var nearest := INF
	for pony: Node3D in candidates:
		var here := _flat(pony.global_position) - _center
		if here.length() < nearest and here.length() > .05:
			nearest = here.length()
			side = 1.0 if _toward_first.signed_angle_to(here, Vector3.UP) >= 0.0 else -1.0
	_slots = [side * PI * .5, PI, -side * PI * .5]
	return _fill(candidates)


## Her own choice ([cuddle] while he hugs someone): she comes over too, if she may and a spot is
## left. True when she is on her way.
func join(pony: Node3D) -> bool:
	if not is_instance_valid(first) or str(first.kind) != "hug" or not is_instance_valid(camera): return false
	if _count >= MAX_JOINERS or not _eligible(pony, TAG_REACH): return false
	var one: Array[Node3D] = [pony]
	return _fill(one) > 0


## He let go of the pony he hugs (pony_kisser.gd _end_contact): the group hug ends for everyone.
## Cheap and harmless when none runs.
func finish() -> void:
	if not _running: return
	_note()
	_running = false; first = null; _slots.clear(); _occupied.clear(); _hugged.clear(); _count = 0
	for joiner: Dictionary in joiners.duplicate():
		match str(joiner.phase):
			"walk": _drop(joiner)
			"hug":
				var affection: Node = joiner.affection
				if is_instance_valid(affection) and str(affection.kind) == "hug": affection.end()
				_step_back(joiner)
	if joiners.is_empty(): set_physics_process(false)


## True while she is part of the current or the last group hug (walking in, hugging, stepping back).
func includes(pony: Node) -> bool:
	for joiner: Dictionary in joiners:
		if joiner.mare == pony: return true
	return false


func _fill(candidates: Array[Node3D]) -> int:
	var added := 0
	var height_scale := anon_scale
	while not _slots.is_empty() and not candidates.is_empty() and _count < MAX_JOINERS:
		var dir := _toward_first.rotated(Vector3.UP, _slots.pop_front())
		# The nearest of them to this spot takes it.
		var best: Node3D = null
		var best_gap := INF
		for pony: Node3D in candidates:
			var gap := _flat(pony.global_position).distance_to(_center + dir)
			if gap < best_gap: best = pony; best_gap = gap
		var placed := _place(best, dir, height_scale)
		if placed.is_empty(): continue
		candidates.erase(best)
		_claim(best, placed)
		added += 1
	if added > 0: set_physics_process(true)
	return added


## Where she stands for this side of him: her muzzle against him, her body clear of the others.
func _place(pony: Node3D, dir: Vector3, height_scale: float) -> Dictionary:
	var affection: Node = pony.get_node("Affection")
	var size := maxf(float(pony.get("body_scale")), .1)
	var forward := _flat(-pony.global_basis.z).normalized()
	var root := _flat(pony.global_position)
	var front := clampf((_flat(affection.mouth_point()) - root).dot(forward), .2 * size, 1.2 * size)
	var back := clampf((root - _flat(_tail_point(pony))).dot(forward), .2 * size, 1.0 * size)
	var radius := BODY_RADIUS * size
	for push: float in [0.0, .05, .1, .15, .2, .3]:
		for turn: float in [0.0, .26, -.26, .52, -.52]:
			var out := dir.rotated(Vector3.UP, turn)
			var mouth := _center + out * (ANON_RADIUS * height_scale + push)
			var body := {"a": mouth + out * .1 * size, "b": mouth + out * (front + back), "r": radius}
			if _clear(body): return {"spot": mouth + out * front, "dir": out, "body": body, "muzzle": ANON_RADIUS * height_scale + push}
	return {}


func _clear(body: Dictionary) -> bool:
	for other: Dictionary in _occupied:
		var points := Geometry3D.get_closest_points_between_segments(body.a, body.b, other.a, other.b)
		if points[0].distance_to(points[1]) < float(body.r) + float(other.r): return false
	return true


## The pony he hugs, as a flat body segment from just behind her muzzle to her tail.
func _footprint(pony: Node3D, affection: Node) -> Dictionary:
	var size := maxf(float(pony.get("body_scale")), .1)
	var mouth := _flat(affection.mouth_point())
	var tail := _flat(_tail_point(pony))
	var along := (tail - mouth).normalized() if tail.distance_to(mouth) > .01 else _flat(pony.global_basis.z).normalized()
	return {"a": mouth + along * .1 * size, "b": tail, "r": BODY_RADIUS * size}


func _tail_point(pony: Node3D) -> Vector3:
	var skeleton: Variant = pony.get("skeleton")
	if skeleton is Skeleton3D:
		var sk := skeleton as Skeleton3D
		for bone_name: String in ["mTail1", "mPelvis"]:
			var bone := sk.find_bone(bone_name)
			if bone >= 0: return sk.global_transform * sk.get_bone_global_pose(bone).origin
	return pony.global_position + pony.global_basis.z * .6 * maxf(float(pony.get("body_scale")), .1)


## At least his friend, awake, free, not angry with him, close enough, and not already hugging.
func _eligible(pony: Node3D, reach: float) -> bool:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or not pony.is_visible_in_tree(): return false
	if (is_instance_valid(first) and pony == first.mare) or includes(pony): return false
	if pony.get("boop_node") == null or pony.has_meta("spa_client"): return false
	var identity: Variant = pony.get("identity")
	if not identity is Resource or bool((identity as Resource).get("filly")): return false
	if _flat(pony.global_position).distance_to(_center) > reach: return false
	var affection: Node = pony.get_node_or_null("Affection")
	if affection == null or not affection.has_method("buck_time") or not str(affection.kind).is_empty() or float(affection.buck_time()) >= 0.0: return false
	if pony.get("sleeping") == true or pony.is_held() or pony.is_speaking(): return false
	if pony.has_meta("affection_active") or pony.has_meta("cuddle_active"): return false
	if pony.has_method("action_interruption_reason") and not str(pony.action_interruption_reason()).is_empty(): return false
	var flight: Variant = pony.get("flight")
	if flight is Node and (flight as Node).has_method("active") and bool((flight as Node).call("active")): return false
	var nav: Node = pony.get_node_or_null("Navigator")
	if nav == null: return false
	var reserved: Variant = nav.get("reserved_by")
	if reserved != null and not str(reserved).is_empty(): return false
	# Her own ordinary day only: a plan step (a shift too) or a command from someone keeps her.
	var owner := str(nav.get("command_owner"))
	if not (owner.is_empty() or owner.begins_with("life:") or owner.begins_with("social:") or owner == "rest_after_command"): return false
	return _friend(pony)


## His friend or closer (player_bonds.gd stages), who welcomes a hug now (not angry, no space asked).
func _friend(pony: Node3D) -> bool:
	if not pony.has_meta("relationship_runtime") or not pony.has_meta("relationship_id"): return false
	var runtime: Variant = pony.get_meta("relationship_runtime")
	var bonds: Variant = (runtime as Object).get("bonds") if runtime is Object else null
	if not bonds is Object or not (bonds as Object).has_method("welcomes"): return false
	var id := str(pony.get_meta("relationship_id"))
	var row: Variant = bonds.peek(id) if (bonds as Object).has_method("peek") else bonds.record_for(id)
	var stage := str((row as Dictionary).get("stage", "acquaintance")) if row is Dictionary else "acquaintance"
	return BONDS.STAGES.find(stage) >= 1 and bool(bonds.welcomes(id, "hug"))


func _claim(pony: Node3D, placed: Dictionary) -> void:
	var nav: Node = pony.get_node("Navigator")
	var size := maxf(float(pony.get("body_scale")), .1)
	var dir: Vector3 = placed.dir
	var line: Vector3 = placed.spot + dir * APPROACH * size
	# Her way round passes outside every joiner already placed (the pony he hugs is never crossed).
	var ring := (line - _center).length()
	for index in range(1, _occupied.size()):
		var other: Dictionary = _occupied[index]
		ring = maxf(ring, maxf((other.a - _center).length(), (other.b - _center).length()) + float(other.r) + BODY_RADIUS * size + .1)
	var here := _flat(pony.global_position) - _center
	var turn := absf(angle_difference(_toward_first.signed_angle_to(here, Vector3.UP), _toward_first.signed_angle_to(dir, Vector3.UP)))
	var walk := (ring * turn + here.length() + ring) / WALK_SPEED
	var joiner := {"mare": pony, "affection": pony.get_node("Affection"), "nav": nav, "spot": placed.spot, "dir": dir,
		"owner": str(nav.get("command_owner")), "wander": bool(nav.get("wander_enabled")), "phase": "walk", "t": 0.0,
		"lined": false, "around": _around_sign(pony, dir), "muzzle": placed.muzzle, "ring": ring, "limit": walk + WALK_SECONDS}
	nav.stay(); nav.set("command_owner", OWNER); nav.set("wander_enabled", false)
	# His hands resting on her must not freeze her walk in (pony_locomotion.gd _touch_blocks).
	pony.set("steer_through_touch", true)
	joiners.append(joiner); _occupied.append(placed.body); _count += 1
	print("[hug] %s walks in: %.0f degrees round him from the pony he hugs, muzzle %.2f m from his middle" % [pony.name,
		rad_to_deg(_toward_first.signed_angle_to(placed.dir, Vector3.UP)), float(placed.muzzle)])


## Which way round him she walks: never across the pony he hugs (angle 0).
func _around_sign(pony: Node3D, dir: Vector3) -> float:
	var here := _flat(pony.global_position) - _center
	var from := _toward_first.signed_angle_to(here, Vector3.UP) if here.length() > .05 else 0.0
	var to := _toward_first.signed_angle_to(dir, Vector3.UP)
	if absf(to) < PI - .01 and signf(from) == signf(to): return 1.0 if to >= from else -1.0
	return 1.0 if from >= 0.0 else -1.0


func _physics_process(delta: float) -> void:
	for joiner: Dictionary in joiners.duplicate():
		_tick(joiner, delta)
	if joiners.is_empty(): set_physics_process(false)


func _tick(joiner: Dictionary, delta: float) -> void:
	var mare: Node3D = joiner.mare if is_instance_valid(joiner.mare) else null
	var nav: Node = joiner.nav if is_instance_valid(joiner.nav) else null
	var affection: Node = joiner.affection if is_instance_valid(joiner.affection) else null
	if mare == null or nav == null or affection == null or not is_instance_valid(camera):
		joiners.erase(joiner); return
	var phase := str(joiner.phase)
	var owner := str(nav.get("command_owner"))
	var reserved: Variant = nav.get("reserved_by")
	var ours := owner == OWNER or (phase == "hug" and owner == "affection")
	# Pulled away by something more important: she just leaves.
	if mare.get("sleeping") == true or mare.is_held() or not ours or (reserved != null and not str(reserved).is_empty()):
		if phase == "hug" and str(affection.kind) == "hug": affection.end()
		_drop(joiner); return
	joiner.t = float(joiner.t) + delta
	match phase:
		"walk": _walk(joiner, mare, affection)
		"hug": _hold(joiner, mare, affection)
		"back":
			if float(joiner.t) < BACK_SECONDS: mare.back_up(BACK_SPEED)
			else: _drop(joiner)


func _walk(joiner: Dictionary, mare: Node3D, affection: Node) -> void:
	var size := maxf(float(mare.get("body_scale")), .1)
	var pos := _flat(mare.global_position)
	var spot: Vector3 = joiner.spot
	var dir: Vector3 = joiner.dir
	var line := spot + dir * APPROACH * size
	if float(joiner.t) > float(joiner.limit):
		# Something blocks her way: close enough, she hugs from there; else she goes back.
		if _flat(affection.mouth_point()).distance_to(_center) < float(joiner.muzzle) + .3: _arrive(joiner, mare, affection)
		else: _drop(joiner)
		return
	var waypoint := line
	var speed := WALK_SPEED
	if bool(joiner.lined) or pos.distance_to(line) < .15:
		joiner.lined = true; waypoint = spot; speed = STEP_SPEED
		# At or past her spot along her line in: she is there.
		if (pos - spot).dot(dir) <= ARRIVE: _arrive(joiner, mare, affection); return
	else:
		var here := pos - _center
		var from := _toward_first.signed_angle_to(here, Vector3.UP)
		var to := _toward_first.signed_angle_to(dir, Vector3.UP)
		var around := float(joiner.around)
		var left := fposmod((to - from) * around, TAU)
		if left > AROUND and left < TAU - .01:
			waypoint = _center + _toward_first.rotated(Vector3.UP, from + around * AROUND) * float(joiner.ring)
	var go := waypoint - pos
	if go.length() > .001: mare.set_desired_velocity(go.normalized() * speed)


func _arrive(joiner: Dictionary, mare: Node3D, affection: Node) -> void:
	mare.stop()
	mare.set("steer_through_touch", false)
	var axis := _flat(camera.global_position)
	var mouth: Vector3 = affection.mouth_point()
	if is_instance_valid(first) and str(first.kind) == "hug" and affection.begin("hug", Vector3(axis.x, mouth.y, axis.z)):
		joiner.phase = "hug"; joiner.t = 0.0
		_hugged.append(mare)
	else:
		_step_back(joiner)


## Hugging: her lean goes to him at her muzzle's height, and she keeps facing him.
func _hold(joiner: Dictionary, mare: Node3D, affection: Node) -> void:
	if str(affection.kind) != "hug":
		_step_back(joiner); return
	var axis := _flat(camera.global_position)
	if mare.global_position.distance_to(camera.global_position) > LET_GO:
		affection.end(); _drop(joiner); return
	var mouth: Vector3 = affection.mouth_point()
	affection.target = Vector3(axis.x, mouth.y, axis.z)
	var to := axis - _flat(mare.global_position)
	var forward := _flat(-mare.global_basis.z)
	if to.length() > .05 and forward.length() > .01 and forward.angle_to(to) > deg_to_rad(8.0): mare.face_direction(to.normalized())


func _step_back(joiner: Dictionary) -> void:
	joiner.phase = "back"; joiner.t = 0.0


## She goes back to what she was doing: her navigator returns to whoever held it, if it is still ours.
func _drop(joiner: Dictionary) -> void:
	joiners.erase(joiner)
	var mare: Node3D = joiner.mare if is_instance_valid(joiner.mare) else null
	var nav: Node = joiner.nav if is_instance_valid(joiner.nav) else null
	if mare != null: mare.set("steer_through_touch", false)
	if nav == null or str(nav.get("command_owner")) != OWNER: return
	if mare != null: mare.stop()
	nav.stay(); nav.set("command_owner", str(joiner.owner)); nav.set("wander_enabled", bool(joiner.wander))


## One world event, once the group hug ends, naming who was in it (at least one pony joined).
func _note() -> void:
	if _hugged.size() < 2 or not is_instance_valid(first): return
	var runtime: Variant = first.mare.get_meta("relationship_runtime") if first.mare.has_meta("relationship_runtime") else null
	var game: Variant = (runtime as Object).get("game") if runtime is Object else null
	var context: Variant = (game as Object).get("world_context") if game is Object else null
	if not context is Object or not (context as Object).has_method("record"): return
	var names := PackedStringArray()
	var ids: Array = []
	for pony: Node3D in _hugged:
		if not is_instance_valid(pony) or pony.get("identity") == null: continue
		names.append(str(pony.identity.display_name))
		ids.append(str(pony.get_meta("relationship_id")) if pony.has_meta("relationship_id") else str(pony.identity.id))
	if names.size() < 2: return
	var listed := ", ".join(names.slice(0, names.size() - 1)) + " and " + names[names.size() - 1]
	ids.append("player")
	(context as Object).call("record", "affection", "%s had a group hug with Anon." % listed, ids, ids)


func _flat(point: Vector3) -> Vector3:
	return Vector3(point.x, 0.0, point.z)


func _exit_tree() -> void:
	for joiner: Dictionary in joiners.duplicate():
		var affection: Node = joiner.affection if is_instance_valid(joiner.affection) else null
		if str(joiner.phase) == "hug" and affection != null and str(affection.kind) == "hug": affection.end()
		_drop(joiner)
