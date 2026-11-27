extends RefCounted
## Watches player displacement and accidental/saved rooftop landings. House floors and
## cloud platforms never start a rescue. Revalidate destinations against physics.
## A pony dropped or thrown onto a roof, a narrow prop or furniture (bed, table) gets down by
## herself (2026-10-15): a short confused look, then pegasi fly off roofs outdoors and everypony
## hops down to validated floor; only with no clear hop is she placed on validated ground.
## Sitting, lying or sleeping on furniture is her choice and stays.
const PLACEMENT := preload("res://world/navigation/roster_placement.gd")
const THROW := preload("res://world/characters/locomotion/pony_throw.gd")
const WAIT_SECONDS := 4.0
## Furniture is low: a short look over the edge, then the hop.
const HOP_WAIT_SECONDS := 1.5
## Edge search on a raised support: steps out to EDGE_REACH; walking on that far means connected
## ground. Height changes within EDGE_RISE per step are walkable (stairs, thresholds, rugs).
const EDGE_STEP := .3
const EDGE_REACH := 2.4
const EDGE_RISE := .3
## Longest/highest hop she takes; beyond it, flight or validated placement.
const HOP_REACH := 8.0
const HOP_DROP := 6.0
const HOP_TRIES := 2
## Seconds past the wait spent looking for a clear hop before validated placement instead.
const HOP_SEARCH_SECONDS := 6.0
var pending := false
var stranded := 0.0
var timer := 0.0
var safe_transform := Transform3D.IDENTITY
var has_safe := false
var safe_home: WeakRef
var search_index := 0
var hops := 0
var _watch_timer := -1.0
var _edges: Array[Vector3] = []
var _island := false
var _edges_at := Vector3.INF

func picked_up(pony: CharacterBody3D) -> void:
	if not pony._held:
		var hit: Dictionary = _floor(pony)
		if not hit.is_empty() and not _roof(pony,hit) and not _isolated(pony,hit.position):
			safe_transform = pony.global_transform
			safe_transform.origin = hit.position + Vector3.UP * .03
			has_safe = true; safe_home = null
			for home: Node3D in pony.get_tree().get_nodes_in_group("house_interiors"):
				if home.contains(hit.position): safe_home = weakref(home); break
	pending = true; stranded = 0.0; timer = 0.0; search_index = 0; hops = 0; _edges_at = Vector3.INF

## Let go of inside a wall, a rock or the ground (2026-10-25 player report: she was lost there,
## and the save kept her there). Hands can reach through geometry; a body cannot. When both her
## chest and her back are hidden from the player's head by world geometry, she is put down on
## validated floor between the player and where she was let go, else under the player, else back
## where she was picked up. A rail or table edge hides only one of the two and changes nothing.
static func clear_release(actor: CharacterBody3D, head: Vector3, fallback := Vector3.INF) -> bool:
	if not head.is_finite() or head == Vector3.ZERO or not actor.is_inside_tree(): return false
	var space := actor.get_world_3d().direct_space_state
	var exclude: Array[RID] = [actor.get_rid()]
	var scale: float = float(actor.get("body_scale")) if actor.get("body_scale") != null else 1.0
	var at := actor.global_position
	for height: float in [.45, .8]:
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(head, at + Vector3.UP * height * scale, 1, exclude)).is_empty(): return false
	var profile: Resource = actor.get("profile")
	if profile == null: return false
	var below := Vector3(head.x, head.y - 1.0, head.z)
	var toward := Vector3(at.x - head.x, 0.0, at.z - head.z)
	var spots: Array[Vector3] = []
	for reach: float in [1.0, .6, .0]:
		spots.append(below + toward.limit_length(reach))
	if fallback.is_finite(): spots.append(fallback)
	for wanted: Vector3 in spots:
		var ground := space.intersect_ray(PhysicsRayQueryParameters3D.create(wanted + Vector3.UP * .9, wanted + Vector3.DOWN * 3.0, 1, exclude))
		if ground.is_empty(): continue
		var home: Node3D = null
		for interior: Node3D in actor.get_tree().get_nodes_in_group("house_interiors"):
			if interior.contains(ground.position, true): home = interior; break
		var spot := PLACEMENT.support(space, ground.position, profile, home, exclude)
		if not spot.is_finite(): continue
		# Never through the wall again: the player must see where she is set down.
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(head, spot + Vector3.UP * .45 * scale, 1, exclude)).is_empty() and wanted != fallback: continue
		var pose := actor.global_transform; pose.origin = spot
		actor.reset_motion(pose)
		var navigator: Node = actor.get_node_or_null("Navigator")
		if navigator != null:
			var wandering: bool = navigator.wander_enabled
			navigator.stay(); navigator.wander_enabled = wandering
		print("[pony] %s let go inside geometry, set down at %s" % [actor.name, str(spot.snapped(Vector3.ONE * .01))])
		return true
	return false

## Under the ground (thread fix "sunk", 2026-11-19; docs/THREAD_FIX_SUNK_2026_11_19.md): a pony whose
## root is more than SUNK_GAP under the terrain heightmap, outside every house and with no floor of
## any kind under her hooves, is put back on the ground above her. Nothing else brings back a pony on
## the clip tiers that is more than ~0.9 m under (pony_locomotion.gd _clip_step follows only floors
## within 1.5 hip heights, a lying or sitting clip-tier pony follows none) and the solver's own
## re-seat (pony_support_recovery.gd) only runs once the crowd makes her HERO, which needs his eyes
## within 4 m of her root: a pony a metre under the road right beside him stays on NEAR, sunk.
## Every SUNK_EVERY seconds per pony (staggered), on the watchers' beat: one heightmap read and a
## compare; the house test and one short ray only for a pony already found that deep. Rollback:
## SUNK_RESCUE = false.
const SUNK_RESCUE := true
const SUNK_GAP := 0.35
## A lying, sitting or sleeping pony does not move, so no slope lag: anything this deep is a sink.
const SUNK_GAP_RESTING := 0.2
const SUNK_EVERY := 2.0
## Floor rays down from just above her root: a cellar, tunnel or deck under her is a floor.
const SUNK_FLOOR_ABOVE := 0.3
const SUNK_FLOOR_BELOW := 0.6
var _sunk_timer := -1.0

func _check_sunk(pony: CharacterBody3D, delta: float) -> void:
	if _sunk_timer < 0.0:
		_sunk_timer = float(pony.get_instance_id() % 97) / 97.0 * SUNK_EVERY
		return
	_sunk_timer -= delta
	if _sunk_timer > 0.0: return
	_sunk_timer = SUNK_EVERY
	if pony._held or pony.motion_paused or is_instance_valid(pony.moving_support) or not pony.is_inside_tree(): return
	if pony.thrown != null and pony.thrown.active(): return
	if not is_instance_valid(WorldTerrain.instance): return
	var at := pony.global_position
	var ground: float = WorldTerrain.instance.height_at(at)
	if not is_finite(ground): return
	var posture: Object = pony.get("posture")
	var resting: bool = posture != null and posture.active()
	if at.y > ground - (SUNK_GAP_RESTING if resting else SUNK_GAP) * pony.body_scale: return
	if _indoors(pony, at): return
	var space := pony.get_world_3d().direct_space_state
	var exclude: Array[RID] = [pony.get_rid()]
	# Started under the surface, so the terrain itself (crossed only from above) is never hit here.
	var above := minf(SUNK_FLOOR_ABOVE, ground - at.y - 0.1)
	var under := PhysicsRayQueryParameters3D.create(at + Vector3.UP * above, at - Vector3.UP * SUNK_FLOOR_BELOW, pony.floor_mask, exclude)
	if not space.intersect_ray(under).is_empty(): return
	# Where the column has collision, its top near the heightmap (a path or plaza over the terrain);
	# else the heightmap itself, which the clip tiers and the solver's own support both accept.
	var surface := ground
	var column := PhysicsRayQueryParameters3D.create(Vector3(at.x, ground + 0.6, at.z), Vector3(at.x, ground - 0.6, at.z), pony.floor_mask, exclude)
	var top := space.intersect_ray(column)
	if not top.is_empty() and not PLACEMENT.building(top.collider): surface = float(top.position.y)
	var to := Vector3(at.x, surface + 0.02, at.z)
	var flight: Object = pony.get("flight")
	var flying: String = str(flight.get("state")) if flight != null and flight.active() else ""
	print("[pony] %s was %.2f m under the ground (tier %d%s%s); set back on it at %s" % [pony.name, ground - at.y,
		int(pony.get("sim_tier")), ", flight " + flying if flying != "" else "", ", " + str(posture.get("kind")) if resting else "",
		str(to.snapped(Vector3.ONE * 0.01))])
	if resting and flying == "":
		# Lying, sitting or asleep: the same rest, on the ground. The clip tiers measure their floor
		# again from here; the solver re-seats on it.
		pony.global_position = to
		pony.velocity = Vector3.ZERO
		pony._clip_floor = NAN
		pony._clip_probe_logic = 0
		pony._clip_floor_from_ray = false
		pony.reset_physics_interpolation()
		return
	pony.reset_motion(Transform3D(pony.global_basis, to))
	pony.reset_physics_interpolation()
	# Her command, owner and goal stay (stuck_rescue.gd _set_down): only where she stands changed,
	# so her route is planned again from here.
	var nav: Node = pony.get_node_or_null("Navigator")
	if nav != null and "path" in nav and "_needs_path" in nav:
		var travel: Variant = nav.get("house_travel")
		if travel is Object and (travel as Object).has_method("clear"): travel.call("clear", pony)
		nav.set("path", PackedVector3Array())
		nav.set("_needs_path", true)
		if "_stuck_time" in nav: nav.set("_stuck_time", 0.0)


func update(pony: CharacterBody3D, delta: float) -> void:
	if SUNK_RESCUE: _check_sunk(pony, delta)
	if pony._held or pony.motion_paused or is_instance_valid(pony.moving_support) or pony.get("sleeping") == true:
		stranded = 0.0; return
	# A story scene or town event placed her (Trixie on her show stage, meta event_placed): the
	# scene owns where she stands.
	var nav: Node = pony.get_node_or_null("Navigator")
	if (nav != null and str(nav.get("reserved_by")) != "") or pony.has_meta("event_placed"):
		stranded = 0.0; return
	if pony.thrown != null and pony.thrown.active(): return
	if pony.flight != null and pony.flight.active():
		# Normal flight has its own landing. A throw with nowhere to land can hover forever.
		if pony.flight.state != "rescue_hover": return
	else:
		if absf(pony.velocity.y) > .5: stranded = 0.0; return
	if not pending:
		# Stagger one support check every two seconds; no new per-frame town ray sweep.
		if _watch_timer<0.0:
			_watch_timer=.1+float(pony.get_instance_id()%101)/50.0;return
		_watch_timer-=delta
		if _watch_timer>0.0:return
		_watch_timer=2.0
		var observed:Dictionary=_floor(pony)
		var rescue_hover:bool=pony.flight!=null and pony.flight.state=="rescue_hover"
		if not rescue_hover and (observed.is_empty() or not _roof(pony,observed)):return
		pending=true;stranded=0.0;timer=0.0;search_index=0
	timer -= delta
	if timer > 0.0: return
	timer = .5
	var hit: Dictionary = _floor(pony)
	var hovering: bool = pony.flight != null and pony.flight.state == "rescue_hover"
	if hit.is_empty() and not hovering: return # falling/streaming is normal support recovery's job
	if not hovering and _entrance_support(hit):
		pending = false; stranded = 0.0; return
	var furniture := false
	if not hovering and not _roof(pony,hit) and not _isolated(pony,hit.position):
		# A bed, table or other raised island: stranded only when every way off is a drop.
		if (pony.posture != null and pony.posture.active()) or not _raised(pony,hit):
			pending = false; stranded = 0.0; return
		furniture = true
	if stranded == 0.0 and not hovering: _confused(pony)
	stranded += .5
	var wait: float = HOP_WAIT_SECONDS if furniture else WAIT_SECONDS
	if stranded < wait: return
	var hopping: bool = not hovering and hops < HOP_TRIES
	var space: PhysicsDirectSpaceState3D = pony.get_world_3d().direct_space_state
	var spots: Array[Vector3] = []
	# Prefer her own recent, known floor, including a real house floor. A blocked
	# or unloaded return point is not permission to place her there anyway.
	if has_safe and pony.global_position.distance_squared_to(safe_transform.origin) < 32.0*32.0:
		var home: Node3D = safe_home.get_ref() as Node3D if safe_home != null else null
		var safe := PLACEMENT.support(space,safe_transform.origin,pony.profile,home)
		if safe.is_finite(): spots.append(safe)
	# At most two local candidates per half-second; never a whole town ray sweep. While she
	# may still hop, keep collecting nearby ground: the known floor may be out of hop reach.
	for attempt in 2:
		if not spots.is_empty() and not hopping: break
		var ring:int=search_index/8
		var radius:float=float([2,4,8,12,18,26,38,54][ring])
		var angle: float = (search_index % 8) * TAU / 8.0
		search_index = (search_index + 1) % 64
		var at: Vector3 = pony.global_position + Vector3(cos(angle),0,sin(angle))*radius
		var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP,at-Vector3.UP*160.0,1,[pony.get_rid()])
		var ground: Dictionary = space.intersect_ray(ray)
		if ground.is_empty() or PLACEMENT.building(ground.collider): continue
		var spot := PLACEMENT.support(space,ground.position,pony.profile)
		if spot.is_finite(): spots.append(spot)
	var destination: Vector3 = spots[0] if not spots.is_empty() else Vector3.INF
	# A pegasus should use a certified flight corridor down when one exists (outdoors only).
	if destination.is_finite() and pony.has_method("request_flight") and (pony.flight==null or not pony.flight.active()) and pony.request_flight(destination):
		_clear_route(pony)
		stranded=0.0
		print("[pony] %s flying off inaccessible roof"%pony.name)
		return
	if hopping:
		# Everypony else hops: first to the floor just past the nearest edge, else to a
		# validated spot within one clear hop. Placement only after a few seconds without one.
		if furniture or _raised(pony,hit):
			for i in mini(_edges.size(),4):
				if _hop(pony,_edges[i]): return
		for spot: Vector3 in spots:
			if _hop(pony,spot): return
		if stranded < wait + HOP_SEARCH_SECONDS: return
	if not destination.is_finite(): return
	var pose: Transform3D = pony.global_transform; pose.origin = destination
	pony.reset_motion(pose)
	_clear_route(pony)
	pending = false; stranded = 0.0; hops = 0
	print("[pony] %s recovered from inaccessible support" % pony.name)

## Hop down to `spot` when it is in reach and the whole arc is clear (pony_throw.gd hop).
## She lands on her hooves; landing back up here simply starts the wait again.
func _hop(pony: CharacterBody3D, spot: Vector3) -> bool:
	var from: Vector3 = pony.global_position
	if Vector2(spot.x-from.x,spot.z-from.z).length() > HOP_REACH or from.y-spot.y > HOP_DROP or spot.y-from.y > EDGE_RISE: return false
	if pony.thrown == null: pony.thrown = THROW.new(); pony.thrown.bind(pony)
	if not pony.thrown.hop(spot): return false
	hops += 1; stranded = 0.0; _edges_at = Vector3.INF
	_clear_route(pony)
	print("[pony] %s hopping down (%.1f m drop)" % [pony.name, from.y-spot.y])
	return true

## A short "how do I get down?" face; the expression layer releases it by itself.
func _confused(pony: CharacterBody3D) -> void:
	var face: Object = pony.get("expressions")
	if face == null or not str(face.dialogue_face).is_empty(): return
	face.set_dialogue("confused"); face.finish_dialogue()

## True when she stands on a raised island (bed, table, crate, platform): no direction walks on
## for EDGE_REACH, and at least one direction drops off an edge. `_edges` then holds the floor
## spots just past those edges that pass the spawn support/clearance check, nearest first.
## Cached while she stays put; at most 8 directions of short rays, only while recovery is pending.
func _raised(pony: CharacterBody3D, hit: Dictionary) -> bool:
	if pony.global_position.distance_squared_to(_edges_at) < .04: return _island
	_edges_at = pony.global_position
	_edges.clear(); _island = false
	var collider: Node = hit.collider
	if collider is CollisionObject3D and collider.collision_layer & (1 << 18): return false
	var space: PhysicsDirectSpaceState3D = pony.get_world_3d().direct_space_state
	var home: Node3D = _home_at(pony,hit.position)
	var top: float = hit.position.y
	var chest: Vector3 = Vector3.UP * .45 * pony.body_scale
	var exclude: Array[RID] = [pony.get_rid()]
	var drops := 0
	var spots: Array[Vector3] = []
	for i in 8:
		var direction := Vector3(cos(i*TAU/8.0),0,sin(i*TAU/8.0))
		var height: float = top
		var edge := -1.0
		var distance := 0.0
		var previous: Vector3 = hit.position
		while true:
			distance += EDGE_STEP
			if edge < 0.0 and distance > EDGE_REACH: return false # walks on: connected ground
			if edge >= 0.0 and distance > edge + 1.2: break
			var at: Vector3 = hit.position + direction * distance
			# A wall or headboard at body height ends this direction, before or past the edge.
			var wall := PhysicsRayQueryParameters3D.create(Vector3(previous.x,height,previous.z)+chest,Vector3(at.x,height,at.z)+chest,1,exclude)
			if not space.intersect_ray(wall).is_empty(): break
			previous = at
			var probe := PhysicsRayQueryParameters3D.create(Vector3(at.x,top+.5,at.z),Vector3(at.x,top-HOP_DROP,at.z),pony.floor_mask,exclude)
			var ground: Dictionary = space.intersect_ray(probe)
			if ground.is_empty() or ground.normal.y < .65:
				if edge < 0.0: break # a void or steep face: no way on, nothing to hop to
				continue
			var y: float = ground.position.y
			if edge < 0.0:
				if absf(y-height) <= EDGE_RISE: height = y; continue
				if y > height: break
				edge = distance; drops += 1
			var spot := PLACEMENT.support(space,ground.position,pony.profile,home,exclude)
			if spot.is_finite(): spots.append(spot); break
	if drops == 0: return false
	var here: Vector3 = pony.global_position
	spots.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_squared_to(here) < b.distance_squared_to(here))
	_edges = spots; _island = true
	return true

func _home_at(pony: CharacterBody3D, point: Vector3) -> Node3D:
	for home: Node3D in pony.get_tree().get_nodes_in_group("house_interiors"):
		if home.contains(point,true): return home
	return null

func _clear_route(pony:CharacterBody3D)->void:
	var navigator: Node = pony.get_node_or_null("Navigator")
	if navigator != null:
		# Invalidate stale roof routes, then allow the existing daily activity to resume.
		var wandering: bool = navigator.wander_enabled
		navigator.stay(); navigator.wander_enabled = wandering

func _floor(pony: CharacterBody3D) -> Dictionary:
	var ray := PhysicsRayQueryParameters3D.create(pony.global_position+Vector3.UP*.25,
		pony.global_position-Vector3.UP*.45,pony.floor_mask,[pony.get_rid()])
	return pony.get_world_3d().direct_space_state.intersect_ray(ray)

func _roof(pony: CharacterBody3D, hit: Dictionary) -> bool:
	if hit.is_empty(): return false
	if _entrance_support(hit): return false
	var collider: Node = hit.collider
	if collider is CollisionObject3D and collider.collision_layer & (1 << 18): return false
	if not PLACEMENT.building(collider) or _indoors(pony,hit.position): return false
	# The restaurant and other specialty rooms have no HouseInterior registration.
	# A ceiling overhead makes their floor an interior, not the building's roof.
	# A flag, finial or single beam above a roof is not an interior ceiling.
	var covered:=0
	for offset:Vector3 in [Vector3.ZERO,Vector3(.4,0,0),Vector3(-.4,0,0),Vector3(0,0,.4),Vector3(0,0,-.4)]:
		var at:Vector3=hit.position+offset*pony.body_scale
		var roof_ray:=PhysicsRayQueryParameters3D.create(at+Vector3.UP*.08,at+Vector3.UP*8.0,1,[pony.get_rid()])
		var above:Dictionary=pony.get_world_3d().direct_space_state.intersect_ray(roof_ray)
		if not above.is_empty() and PLACEMENT.building(above.collider):covered+=1
	return covered<3

## Set only on the verified entrance collision hull, never on the whole building.
## A real floor ray must hit it; an active house route alone is not safe support.
func _entrance_support(hit: Dictionary) -> bool:
	var collider: Node = hit.get("collider") as Node
	return is_instance_valid(collider) and bool(collider.get_meta(&"house_entrance_support", false))

func _indoors(pony: CharacterBody3D, point: Vector3) -> bool:
	for home: Node3D in pony.get_tree().get_nodes_in_group("house_interiors"):
		if home.contains(point,true): return true
	return false

func _isolated(pony: CharacterBody3D, point: Vector3) -> bool:
	# A prop top too narrow to step off without a fall is another trapped placement.
	# Beds/interior furniture are deliberate supported rests, not isolated outdoors.
	if _indoors(pony,point): return false
	var floor_hit: Dictionary = _floor(pony)
	if not floor_hit.is_empty() and floor_hit.collider is CollisionObject3D and floor_hit.collider.collision_layer & (1 << 18): return false
	var reach: float = maxf(.8,pony.profile.radius*2.0)
	for i in 8:
		var at: Vector3 = point + Vector3(cos(i*TAU/8),0,sin(i*TAU/8))*reach
		var ray := PhysicsRayQueryParameters3D.create(at+Vector3.UP*.2,at-Vector3.UP*.5,pony.floor_mask,[pony.get_rid()])
		var hit: Dictionary = pony.get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty() and hit.normal.y > .65: return false
	return true
