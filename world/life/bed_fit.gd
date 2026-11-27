extends RefCounted
## A mare of any size lies IN the bed she walks into, is invited into or is laid in (thread fix
## "beds", 2026-11-19, posts 43717764/43717774/43714939; tools/life_beds/test_bed_sizes.gd). Every
## bed gave one rest spot made for a canon mare (house_beds.gd bed_rest: 15 cm toward the foot from
## the middle). At "Same height" and "Hoers" a mare's head went through the headboard into the wall,
## and a princess's already at JRHNBR. fit() only moves the rest along and across the mattress, by
## the reach of her own body: rotations and her size are never touched, nor any limit or tolerance.
## A spot where she already lies inside the mattress (every canon mare) is returned unchanged.
##
## Her reach comes from her own skeleton's rest pose (a princess is longer than a mare at the same
## size setting), measured once per pony, times how much further the settled lie_down reaches than
## the rest pose. Measured 2026-11-19 on Fluttershy, Celestia, Luna and Big McIntosh (lying / rest,
## largest of the four, rounded up): nose 1.15, rump 1.30, sides 1.00.
const LYING_AHEAD := 1.16
const LYING_BEHIND := 1.30
const LYING_SIDE := 1.02
## A canon mare's rest-pose reach (metres at scale 1, measured): for actors without a skeleton.
const MARE_REST := {"ahead": .50, "behind": .33, "left": .42, "right": .16}
const BED_SIZE := Vector3(2.05, 1.1, 2.1)
## Her nose stays this far inside the headboard end, her body this far inside the sides and foot.
const HEAD_GAP := .06
const EDGE_GAP := .03
## Rollback switch: false gives every rest exactly as the bed laid it out (the old placement).
const FIT_ENABLED := true
const MATTRESS := preload("res://world/life/couch/mattress.gd")

## Her settled lie-down reach from her root, in metres at her current size, in her own frame:
## ahead (nose), behind (rump), left (her folded legs), right (her back).
static func lying_reach(actor: Node3D) -> Dictionary:
	var unit: Dictionary = MARE_REST
	if is_instance_valid(actor):
		if actor.has_meta("bed_fit_rest_reach"): unit = actor.get_meta("bed_fit_rest_reach")
		else:
			unit = _rest_reach(actor)
			actor.set_meta("bed_fit_rest_reach", unit)
	var scale := _scale(actor)
	return {"ahead": float(unit.ahead) * LYING_AHEAD * scale, "behind": float(unit.behind) * LYING_BEHIND * scale,
		"left": float(unit.left) * LYING_SIDE * scale, "right": float(unit.right) * LYING_SIDE * scale}

## A canon-proportioned mare's reach at body scale `scale` (layouts made before a pony is chosen).
static func mare_reach(scale: float) -> Dictionary:
	return {"ahead": float(MARE_REST.ahead) * LYING_AHEAD * scale, "behind": float(MARE_REST.behind) * LYING_BEHIND * scale,
		"left": float(MARE_REST.left) * LYING_SIDE * scale, "right": float(MARE_REST.right) * LYING_SIDE * scale}

## `rest` (a lying spot on `bed`, world) moved along and across the mattress so her nose clears the
## headboard and her body lies on the mattress as far as it reaches. Head first: a body longer than
## the mattress keeps her head and chest on it and her hindquarters over the foot end. `reach` from
## lying_reach()/mare_reach(). Her basis is kept exactly.
static func fit(bed: Node3D, rest: Transform3D, reach: Dictionary) -> Transform3D:
	if not FIT_ENABLED or not is_instance_valid(bed) or not rest.origin.is_finite(): return rest
	var half: Vector3 = Vector3(bed.get_meta("bed_size", BED_SIZE)) * .5
	var frame := Transform3D(bed.global_basis.orthonormalized(), bed.global_position)
	var inverse := frame.affine_inverse()
	var root := inverse * rest.origin
	var basis := frame.basis.inverse() * rest.basis.orthonormalized()
	var ahead := -basis.z; ahead.y = 0.0
	var right := basis.x; right.y = 0.0
	if ahead.length() < .01 or right.length() < .01: return rest
	ahead = ahead.normalized(); right = right.normalized()
	var points: Array[Vector3] = [ahead * float(reach.ahead), -ahead * float(reach.behind), -right * float(reach.left), right * float(reach.right)]
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
	for p: Vector3 in points:
		lo = lo.min(Vector2(p.x, p.z)); hi = hi.max(Vector2(p.x, p.z))
	# Along the bed: the headboard is -Z. Her head end first, then the foot end if there is room.
	var head_limit := -half.z + HEAD_GAP
	var foot_limit := half.z - EDGE_GAP
	var min_z := root.z + lo.y
	var max_z := root.z + hi.y
	if min_z < head_limit: root.z += head_limit - min_z
	elif max_z > foot_limit: root.z -= minf(max_z - foot_limit, min_z - head_limit)
	# Across: inside both sides; wider than the mattress, centred.
	var side_lo := -half.x + EDGE_GAP - lo.x
	var side_hi := half.x - EDGE_GAP - hi.x
	if side_lo <= side_hi: root.x = clampf(root.x, side_lo, side_hi)
	else: root.x = (side_lo + side_hi) * .5
	return Transform3D(rest.basis, frame * root)

## fit() with her own reach (the common call), then her head kept out of the walls (clear_head).
static func fit_actor(bed: Node3D, rest: Transform3D, actor: Node3D) -> Transform3D:
	var reach := lying_reach(actor)
	return clear_head(bed, fit(bed, rest, reach), actor, reach)

## Rollback switch for clear_head: false keeps the fitted rest even where her body meets a wall.
const HEAD_CLEAR := true
## Probe points of a lying pony over her root at body scale 1: her head and ears (heights; along as a
## share of her nose reach) and the line of her back (heights; along her body, on her back's side).
## Conservative: only a wall these touch moves her. Probe radius, step and largest moves (x size).
const HEAD_HEIGHTS := [.35, .55, .75]
const HEAD_ALONG := [.7, .95]
const BACK_HEIGHTS := [.3, .5]
const BACK_ALONG := [-.6, 0.0, .5]
const HEAD_PROBE := .06
const CLEAR_STEP := .08
const ALONG_MAX := .6
const ACROSS_MAX := .4

## A bed against a wall or under a sloped roof (the cottage's eave along its side, the hut, the wagon
## bunk, the library bed): a big mare fitted to the mattress can still have her head, ears or back in
## the wall, and the physics then pushes her through the mattress onto the floor (Fluttershy at Hoers
## in her own bed). She is moved toward the foot and across the mattress in CLEAR_STEP x her size
## steps, nearest first, never with her root within 10 cm of the mattress edge, to the first spot
## where no probe meets anything but the bed and herself; if there is none the fitted rest is kept.
## A rest that is already clear (every canon mare in a town bed) is returned unchanged. Shape queries
## only when a rest is chosen, never per frame.
static func clear_head(bed: Node3D, rest: Transform3D, actor: Node3D, reach: Dictionary) -> Transform3D:
	if not HEAD_CLEAR or not FIT_ENABLED or not is_instance_valid(bed) or not is_instance_valid(actor) or not actor.is_inside_tree() or not rest.origin.is_finite(): return rest
	var basis := rest.basis.orthonormalized()
	var ahead := -basis.z; ahead.y = 0.0
	var right := basis.x; right.y = 0.0
	if ahead.length() < .01 or right.length() < .01: return rest
	ahead = ahead.normalized(); right = right.normalized()
	var scale := _scale(actor)
	var skip: Array[RID] = []
	if actor is CollisionObject3D: skip.append((actor as CollisionObject3D).get_rid())
	for body: Node in actor.find_children("*", "CollisionObject3D", true, false): skip.append((body as CollisionObject3D).get_rid())
	if bed is CollisionObject3D: skip.append((bed as CollisionObject3D).get_rid())
	for body: Node in bed.find_children("*", "CollisionObject3D", true, false): skip.append((body as CollisionObject3D).get_rid())
	var query := PhysicsShapeQueryParameters3D.new()
	var ball := SphereShape3D.new(); ball.radius = HEAD_PROBE * scale
	query.shape = ball; query.collision_mask = 1; query.exclude = skip
	var space := actor.get_world_3d().direct_space_state
	var probes: Array[Vector3] = []
	for along: float in HEAD_ALONG:
		for height: float in HEAD_HEIGHTS: probes.append(ahead * float(reach.ahead) * along + Vector3.UP * height * scale)
	for along: float in BACK_ALONG:
		var reach_along: float = float(reach.ahead) if along > 0.0 else float(reach.behind)
		for height: float in BACK_HEIGHTS: probes.append(ahead * reach_along * along + right * float(reach.right) * .8 + Vector3.UP * height * scale)
	var half: Vector3 = Vector3(bed.get_meta("bed_size", BED_SIZE)) * .5
	var inverse := Transform3D(bed.global_basis.orthonormalized(), bed.global_position).affine_inverse()
	var step := CLEAR_STEP * scale
	var moves: Array[Vector3] = []
	for i in int(ALONG_MAX / CLEAR_STEP) + 1:
		for j in range(-int(ACROSS_MAX / CLEAR_STEP), int(ACROSS_MAX / CLEAR_STEP) + 1):
			moves.append(-ahead * step * i + right * step * j)
	moves.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.length_squared() < b.length_squared())
	# Her sides over the mattress edge at the fitted rest; a move may not make that worse.
	var sides: Array[Vector3] = [-right * float(reach.left), right * float(reach.right)]
	var side_over := func(origin: Vector3) -> float:
		var worst := -INF
		for side: Vector3 in sides: worst = maxf(worst, absf((inverse * (origin + side)).x) - half.x)
		return worst
	var fitted_over: float = side_over.call(rest.origin)
	for move: Vector3 in moves:
		var at := rest.origin + move
		var local := inverse * at
		if move != Vector3.ZERO and (absf(local.x) > half.x - .1 or absf(local.z) > half.z - .1): continue
		if move != Vector3.ZERO and float(side_over.call(at)) > maxf(fitted_over, -EDGE_GAP) + .01: continue
		var blocked := false
		for probe: Vector3 in probes:
			query.transform = Transform3D(Basis.IDENTITY, at + probe)
			if not space.intersect_shape(query, 1).is_empty(): blocked = true; break
		if not blocked: return rest if move == Vector3.ZERO else Transform3D(rest.basis, at)
	return rest

## Where she lies, in a few words for her AI ("lying in your own bed beside Anon"), while she lies on
## a bed; "" otherwise. pony_awareness.gd puts it in place of "on the house floor" (posts 43717764,
## board #304: in bed with him, ponies said they were on the floor). One ray, only for a lying pony.
static func lying_words(actor: Node3D) -> String:
	if not is_instance_valid(actor) or not actor.is_inside_tree() or not actor.has_method("posture_status"): return ""
	var status: Dictionary = actor.posture_status()
	if str(status.get("kind", "")) != "lie_down" and str(status.get("requested", "")) != "lie_down": return ""
	var bed := bed_under(actor)
	# Lying on Anon himself in that bed (shared_bed.gd snuggle: his torso holds her, so the ray finds
	# him, not the mattress): the bed whose company she is.
	var company: Variant = actor.get_meta("bed_fit_bed") if actor.has_meta("bed_fit_bed") else null
	if bed == null and is_instance_valid(company) and actor.has_meta("shared_nap_on_top"): bed = company as Node3D
	if bed == null: return ""
	if str(status.get("requested", "")) == "lie_down" and actor.has_meta("bed_fit_left_bed"): actor.remove_meta("bed_fit_left_bed")
	var words := "lying in " + whose_bed(bed, actor)
	if _anon_lies_on(bed): words += " on Anon" if actor.has_meta("shared_nap_on_top") else " beside Anon"
	return words

## How long after she got out of a bed her AI still hears so (board #304: up beside the bed she said
## she had woken on the floor or rolled out of bed).
const LEFT_BED_SECONDS := 120.0

## NightRest and the carry wake-up call this as she hops down out of `bed` (actor meta, no save field).
static func mark_left_bed(actor: Node3D, bed: Node3D) -> void:
	if not is_instance_valid(actor) or not is_instance_valid(bed): return
	actor.set_meta("bed_fit_left_bed", {"at": Time.get_ticks_msec(), "words": whose_bed(bed, actor)})

## "standing beside your own bed, just up out of it" for LEFT_BED_SECONDS after she got out of it,
## while she still stands near it; "" otherwise.
static func left_bed_words(actor: Node3D) -> String:
	if not is_instance_valid(actor) or not actor.has_meta("bed_fit_left_bed"): return ""
	var left: Variant = actor.get_meta("bed_fit_left_bed")
	if not left is Dictionary or Time.get_ticks_msec() - int((left as Dictionary).get("at", 0)) > int(LEFT_BED_SECONDS * 1000.0):
		actor.remove_meta("bed_fit_left_bed")
		return ""
	return "standing beside %s, just up out of it" % str((left as Dictionary).get("words", "a bed"))

## Anon rests on a bed without its seat (desktop sit/lie keys, the VR grounded body): a mattress is
## under his body. pony_awareness.gd player_posture says "in bed", not "on the ground".
static func player_on_bed(body: Node) -> bool:
	return body is Node3D and (body as Node3D).is_inside_tree() and bed_under(body as Node3D) != null

## The bed under her (a mattress collider within reach below her root), or null.
static func bed_under(actor: Node3D) -> Node3D:
	var from := actor.global_position + Vector3.UP * .3
	var skip: Array[RID] = []
	if actor is CollisionObject3D: skip.append((actor as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 1.0, 1, skip)
	var hit := actor.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return null
	var bed: Node3D = MATTRESS.bed_of(hit.collider)
	return bed if bed != null and bed.has_meta("mattress_top") else null

## "your own bed", "the bed you share with Anon", "Anon's bed", or "a bed in this house".
static func whose_bed(bed: Node3D, actor: Node3D) -> String:
	var house: Node3D = bed.get_meta("house") if bed.has_meta("house") and is_instance_valid(bed.get_meta("house")) else null
	var identity: Variant = actor.get("identity")
	var id := str(identity.get("id")) if identity != null else ""
	var sleepers: Variant = house.get("_sleepers") if house != null else null
	var list: Array = sleepers if sleepers is Array else []
	var anon_sleeps: bool = "player" in list or (house != null and bool(house.get_meta("shared_player_home", false)))
	var own: bool = house != null and not id.is_empty() and id in list and house.has_method("ensure_bed") and house.ensure_bed(id) == bed
	if own: return "the bed you share with Anon" if anon_sleeps and house.bed_shared(id) else "your own bed"
	if anon_sleeps: return "Anon's bed"
	# The house itself is named in her cover line ("HOUSE: inside ..."); a house's label can be a plot id.
	return "a bed in this house" if house != null else "a bed"

## Anon lies on this bed (its shared_bed.gd rest's player seat, reclined).
static func _anon_lies_on(bed: Node3D) -> bool:
	if not bed.has_meta("bed_rest"): return false
	var rest: Variant = bed.get_meta("bed_rest")
	if not is_instance_valid(rest): return false
	var seats: Variant = (rest as Object).get("seats")
	if not seats is Array or (seats as Array).is_empty() or not is_instance_valid((seats as Array)[0]): return false
	var seat: Node = (seats as Array)[0]
	var who: Variant = seat.get_meta("occupant") if seat.has_meta("occupant") else null
	return is_instance_valid(who) and bool((who as Node).get_meta("couch_sleeping", false))

## Her rest-pose reach over her body scale, from her skeleton in her model's own frame (the pivot's,
## so a carry or a lie-down tilt does not skew it). Hair, tail, wings, prop mounts and look targets
## are not body ("rd_opal_*" are mane bones under the head). MARE_REST when she has no skeleton.
static func _rest_reach(actor: Node3D) -> Dictionary:
	var skeleton: Variant = actor.get("skeleton")
	var pivot: Variant = actor.get("pivot")
	if not skeleton is Skeleton3D or not pivot is Node3D or not is_instance_valid(skeleton) or not (skeleton as Node).is_inside_tree(): return MARE_REST
	var bones: Skeleton3D = skeleton
	var into_pivot := (pivot as Node3D).global_transform.affine_inverse() * bones.global_transform
	var reach := {"ahead": 0.0, "behind": 0.0, "left": 0.0, "right": 0.0}
	for b in bones.get_bone_count():
		var name := bones.get_bone_name(b).to_lower()
		if name.contains("tail") or name.contains("mane") or name.contains("hair") or name.contains("wing") or name.contains("feather") \
				or name.contains("opal") or name.begins_with("mount") or name.begins_with("eyetarget"): continue
		var p := into_pivot * bones.get_bone_global_rest(b).origin
		reach.ahead = maxf(float(reach.ahead), -p.z); reach.behind = maxf(float(reach.behind), p.z)
		reach.left = maxf(float(reach.left), -p.x); reach.right = maxf(float(reach.right), p.x)
	if float(reach.ahead) < .1 or float(reach.behind) < .05: return MARE_REST
	return reach

static func _scale(actor: Node3D) -> float:
	var value: Variant = actor.get("body_scale") if is_instance_valid(actor) else null
	return float(value) if value != null else 1.0

## Player board #56: the shoulder and snuggle spots beside Anon (shared_bed.gd, shared_nap_grass.gd)
## were measured for a canon body, whose head then rests at his shoulder. A bigger body reaches
## further ahead of its root, so the same spot put a big mare's head past his head. This is how far
## back along her own facing her root moves so that her nose lands where the same body's nose lands
## at canon size: her extra lying reach. Zero at body scale 1 and below, so those spots are unchanged.
static func extra_head_reach(rest: Transform3D, actor: Node3D) -> Vector3:
	var scale := _scale(actor)
	if scale <= 1.0 or not rest.origin.is_finite(): return Vector3.ZERO
	var ahead := -rest.basis.orthonormalized().z
	ahead.y = 0.0
	if ahead.length() < .01: return Vector3.ZERO
	return ahead.normalized() * float(lying_reach(actor).ahead) * (1.0 - 1.0 / scale)
