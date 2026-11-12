extends RefCounted
## Resolve a house trip into approach, opening and crossing the entrance.
const HOME=preload("res://world/buildings/house_interior.gd")
enum Phase { APPROACH, OPEN, CROSS }
var home:Node3D
var entering:=false
var phase:=Phase.APPROACH
var goal:=Vector3.INF
var last_progress:=Vector3.INF
var blocked_seconds:=0.0
var _escape_goal:=Vector3.INF
var _escape_retry_at:=0
var _peer_retry_at:=0
var _yielding_peer:WeakRef
## The door-opening gesture plays once per door leg (UnicornMagic handle glow or a raised hoof).
var gestured:=false
var waiting_for_ticket := false
var _realigned_exit := false
func clear(pony:Node) -> void:
	if is_instance_valid(home) and is_instance_valid(home.door()):home.door().release_passage(pony)
	if is_instance_valid(home) and home.has_method("release_visit"):home.release_visit(pony)
	home=null;goal=Vector3.INF;phase=Phase.APPROACH;gestured=false;waiting_for_ticket=false
	_realigned_exit=false
	# Unloading residents are cleared after leaving the tree; there is no house to find then.
	if is_instance_valid(pony) and pony.is_inside_tree():pony.set_meta(&"house_navigation",here(pony)!=null)
	last_progress=Vector3.INF;blocked_seconds=0
	_escape_goal=Vector3.INF;_escape_retry_at=0
	_yielding_peer=null
func active() -> bool:return is_instance_valid(home)

## --- House lookups (the same answers as house_interior.gd at(), reused) ---------------------
## Every navigator asked HOME.at() two or three times per logic tick, each call fetching the whole
## house group and testing every house (2026-10-14 profile: ~50 us per tick). The group is now
## fetched once per physics frame for everyone, a goal's house is kept until the goal or the set
## of houses changes, and her own position is tested only against the houses near her (here()).
## Houses are buildings: they never move once placed.
static var _houses:Array=[]
static var _houses_tree:SceneTree
static var _houses_frame:=-1
## Bumped whenever the set of houses differs from the last fetch.
static var _houses_generation:=0
## The houses of `tree`, fetched once per physics frame (or at once when their number changes).
static func houses(tree:SceneTree) -> Array:
	var frame:=Engine.get_physics_frames()
	if frame!=_houses_frame or tree!=_houses_tree or tree.get_node_count_in_group(&"house_interiors")!=_houses.size():
		_houses_frame=frame
		var now:Array=tree.get_nodes_in_group(&"house_interiors")
		if tree!=_houses_tree or now!=_houses:
			_houses_tree=tree;_houses=now;_houses_generation+=1
	return _houses
## house_interior.gd at() over the shared list (keep the two in step).
static func house_at(tree:SceneTree,point:Vector3) -> Node3D:
	for house:Node3D in houses(tree):
		if (house.global_position-point).length_squared()>house._reach_squared():continue
		if house.contains(point):return house
	return null
## Her own house: the houses whose reach comes within HERE_NEAR metres of her are kept in group
## order and tested each call exactly as at() tests them; every other house stays out of reach
## until she has moved `_here_clear` metres from `_here_at`, when the list is rebuilt.
const HERE_NEAR:=3.0
var _here_at:=Vector3.INF
var _here_clear:=0.0
var _here_generation:=-1
var _here_near:Array=[]
func here(pony:Node3D) -> Node3D:
	var list:Array=houses(pony.get_tree())
	var at:=pony.global_position
	if _here_generation!=_houses_generation or not (at.distance_squared_to(_here_at)<_here_clear*_here_clear):
		_here_near.clear()
		var clear:=INF
		for house:Node3D in list:
			var gap:=(house.global_position-at).length()-sqrt(house._reach_squared())
			if gap<=HERE_NEAR:_here_near.append(house)
			else:clear=minf(clear,gap)
		# A centimetre short of the true margin covers rounding in the square roots.
		_here_at=at;_here_clear=clear-.01;_here_generation=_houses_generation
	for house:Node3D in _here_near:
		if (house.global_position-at).length_squared()>house._reach_squared():continue
		if house.contains(at):return house
	return null
## Goal points (live goal, journey goal) keep their house until the point or the houses change.
var _goal_houses:={}
var _goal_generation:=-1
func house_of(tree:SceneTree,point:Vector3) -> Node3D:
	houses(tree)
	if _goal_generation!=_houses_generation or _goal_houses.size()>8:
		_goal_houses.clear();_goal_generation=_houses_generation
	var known:Variant=_goal_houses.get(point,false)
	if typeof(known)!=TYPE_BOOL:return known as Node3D
	var found:=house_at(tree,point)
	_goal_houses[point]=found
	return found
## A failed route releases its passage/visit claim immediately. Actual indoor support still
## keeps house_navigation true; another pony need not wait for this abandoned lease.
func abandon(pony:Node) -> void:
	if active() and is_instance_valid(pony):
		clear(pony)
func update(nav:Node) -> bool:
	var pony:Node3D=nav.pony
	var from:Node3D=here(pony)
	var to:Node3D=house_of(pony.get_tree(),nav._live_goal)
	if from==null and (not active() or (entering and phase==Phase.APPROACH)):
		var journey:bool=nav._journey_goal.is_finite()
		if sky_trip(nav,to):pony.set_meta(&"house_navigation",false);return true
		if journey and not nav._journey_goal.is_finite():to=house_of(pony.get_tree(),nav._live_goal)
	# The outdoor approach is an ordinary grid route; only the doorway and the inside pin her HERO.
	pony.set_meta(&"house_navigation",from!=null or (active() and phase!=Phase.APPROACH))
	if active() and entering and to!=home and phase!=Phase.CROSS:clear(pony)
	if not active():
		# Distinct indoor addresses can share an authored internal connection (the
		# bakery and its tower bedroom). Finish any owned doorway CROSS first, then
		# use that adapter's complete indoor route instead of exiting and re-entering.
		var connected: Node3D = _connected_route(from, to)
		if connected != null:
			if not connected.fits(pony.profile):
				clear(pony); nav._fail("This pony cannot fit through the connected indoor route"); return true
			nav._cancel_queries(); nav._needs_path = false
			walk(nav, _waypoint(connected, pony, pony.global_position, nav._live_goal), connected, nav._live_goal)
			return true
		if from==to:
			# Arrival can occur one tick after handing off the doorway, when the
			# motor coasts from the crossing radius into the final arrival radius.
			var final:Vector3=nav._journey_goal if nav._journey_goal.is_finite() else nav._live_goal
			if not (nav._moving_goal and nav.command_target_speed>.3) and horizontal(pony.global_position,final)<nav.arrival_distance and absf(pony.global_position.y-final.y)<.3:
				nav._cancel_queries();nav.path.clear();nav._needs_path=false;nav._has_target=false
				nav._journey_goal=Vector3.INF;nav._journey_via=[];nav._approaching_player=false
				nav.state=nav.State.ARRIVED;nav.reason="Inside house" if from!=null else "Arrived"
				if nav._wandering:nav._begin_rest()
				nav.arrived.emit();nav._halt();return true
			if from!=null:
				nav._cancel_queries();nav._needs_path=false
				var next:Vector3=_waypoint(from,pony,pony.global_position,nav._live_goal)
				walk(nav,next,from,nav._live_goal);return true
			return false
		home=from if from!=null else to
		if not home.fits(pony.profile):
			clear(pony);nav._fail("This pony cannot fit through the house doorway");return true
		entering=from==null;phase=Phase.APPROACH
		if entering and home.has_method("request_visit") and not home.request_visit(pony):
			clear(pony);nav._fail("Bakery is busy; choose another stop");return true
		set_goal(nav,home.outside() if entering else home.inside())
	if entering and phase==Phase.APPROACH and home.has_method("request_visit") and not home.request_visit(pony):
		clear(pony);nav._fail("Bakery is busy; choose another stop");return true
	if phase==Phase.APPROACH:
		var door:Node=home.door()
		if is_instance_valid(door) and door.has_method("queue_passage"):
			var ticket:Dictionary=door.queue_passage(pony,entering,home.outside(),home.inside(),home)
			if not ticket.is_empty() and not bool(ticket.get("admitted",false)):
				var waiting:Vector3=ticket.get("wait",Vector3.INF)
				waiting_for_ticket=true
				if not waiting.is_finite():
					nav._halt();nav.state=nav.State.WAITING;nav.reason="Waiting for safe space beside doorway";return true
				if goal.distance_to(waiting)>.05:set_goal(nav,waiting)
				if horizontal(pony.global_position,waiting)<.35 and absf(pony.global_position.y-waiting.y)<.3:
					nav._halt();nav.state=nav.State.WAITING;nav.reason="Waiting beside doorway";return true
				if not entering:walk(nav,_waypoint(home,pony,pony.global_position,waiting),home,waiting);return true
				# Outdoor waiters retain ordinary terrain search/following toward their own
				# supported spot; they never share the owner's ramp or authored portal line.
				return false
			if waiting_for_ticket:
				waiting_for_ticket=false
				set_goal(nav,home.outside() if entering else home.inside())
	if phase==Phase.APPROACH and horizontal(pony.global_position,goal)<.45 and level(pony.global_position,goal):
		phase=Phase.OPEN;nav._cancel_queries();nav.path.clear()
	elif phase==Phase.APPROACH and horizontal(pony.global_position,goal)<(SKY_WALK if entering and sky(home) else 3.0) and level(pony.global_position,goal) \
			and (nav.path.is_empty() or horizontal(pony.global_position,nav.path[-1])<.6):
		# The grid route ends at the nearest walkable cell, often short of the ramp toe:
		# cover the last metres directly on the controller's own probes.
		walk(nav,goal);return true
	if phase==Phase.OPEN:
		pony.set_meta("house_navigation",true)
		# Only within the crowd's NEAR range (W1-PERF-PONY, like hybrid_mare FAR_DOOR_LIFT): a pony
		# 50-180 m away was promoted to HERO on every tick she waited at a door, then ranked down again.
		if not (pony.has_method("_beyond_near_range") and bool(pony.call("_beyond_near_range"))):
			pony.set_sim_tier(pony.SimTier.HERO)
		nav._halt();nav.state=nav.State.WAITING;nav.reason="Opening house door"
		var door:Node=home.door()
		# Open entrances use a plain Node; only physical door leaves have a handle/rotation.
		if not gestured and door is Node3D and door.has_method("handle_world") and door.rotation.y<1.4 and pony.has_method("door_gesture"):
			gestured=true;pony.door_gesture(door)
		if home.door().request_passage(pony):
			phase=Phase.CROSS;set_goal(nav,home.inside() if entering else home.outside())
		return true
	if phase==Phase.CROSS:
		if not home.door().request_passage(pony):
			nav._halt();nav.state=nav.State.WAITING;nav.reason="Waiting for doorway to clear";return true
		# Reversing a follow inside a small room can turn her off the narrow
		# portal line. Rejoin through the room's swept route once, instead of
		# freezing for the full obstruction timeout. Keep the passage ticket;
		# a genuine blockage still reaches the ordinary bounded failure path.
		if not entering and not _realigned_exit and from==home and blocked_seconds>1.0 \
				and off_line(pony.global_position,PackedVector3Array([home.inside(),home.outside()]))>.25:
			_realigned_exit=true;phase=Phase.APPROACH
			last_progress=pony.global_position;blocked_seconds=0
			set_goal(nav,home.inside());nav._halt();return true
		var line_start:Vector3=home.outside() if entering else home.inside()
		var on_far_side:bool=from==home if entering else from==null
		# A curved/collision-adjusted body may pass the inside endpoint beside it. Once
		# on the correct floor beyond that plane, the physical crossing is complete:
		# don't retain its ticket while turning back through another customer's space.
		if horizontal(pony.global_position,goal)<.3 or (on_far_side and crossed_target(pony.global_position,line_start,goal)):
			var left:Node3D=null if entering else home
			clear(pony);set_goal(nav,nav._live_goal)
			if sky(left) and fly_off(nav,left):return true
			return update(nav)
		# A narrow authored portal is finer than the outdoor grid's erosion.
		# Walk its centre line using the real controller; collision and ground
		# probes remain authoritative, never teleport or disable the leaf.
		walk(nav,goal,null,Vector3.INF,home.outside() if entering else home.inside())
		return true
	if not entering:
		walk(nav,_waypoint(home,pony,pony.global_position,goal),home,goal);return true
	return false
static func _connected_route(from: Node3D, to: Node3D) -> Node3D:
	if from == null or to == null or from == to: return null
	if from.has_method("connects_to") and from.connects_to(to): return from
	if to.has_method("connects_to") and to.connects_to(from): return to
	return null
## `house` and `final`: the room's own waypoints toward `final` (the native follower takes them all
## at once instead of one point at a time).
## `line_from`: the start of a doorway's centre line ending at `destination` (rejoined first).
func walk(nav:Node,destination:Vector3,house:Node3D=null,final:=Vector3.INF,line_from:=Vector3.INF) -> void:
	var pony:CharacterBody3D=nav.pony
	if not last_progress.is_finite() or pony.global_position.distance_to(last_progress)>.08:
		last_progress=pony.global_position;blocked_seconds=0
	else:blocked_seconds+=nav.get_physics_process_delta_time()
	if blocked_seconds>15:
		clear(pony);nav._fail("House passage obstructed; waiting for a clear route");return
	# Guarded: test Navigator stubs (tools/boutique/test_door_travel.gd) have no native_follow.
	if nav.get("native_follow") == true:
		native_walk(nav,destination,house,final,line_from);return
	var offset:=destination-pony.global_position;offset.y=0
	var velocity:=offset.normalized()*minf(1.2,offset.length()*2)
	var query:=PhysicsShapeQueryParameters3D.new()
	var shape:=CylinderShape3D.new();shape.radius=pony.profile.radius;shape.height=pony.profile.clearance
	query.shape=shape;query.transform.origin=pony.global_position+velocity*.3+Vector3.UP*(shape.height*.5+.05)
	query.collision_mask=2|2048;query.exclude=[pony.get_rid()]
	var hits:=pony.get_world_3d().direct_space_state.intersect_shape(query,1)
	if not hits.is_empty():
		# Two ponies nose to nose in a doorway both waited for the other forever, then gave
		# up and stood there (dev 2026-09-23). The pony with the higher id backs off and
		# steps aside so the other can pass; the other waits a moment.
		var other:Object=hits[0].collider
		if other is CharacterBody3D and other!=pony and other.has_method("grounded"):
			if pony.get_instance_id()>other.get_instance_id():
				var away:Vector3=pony.global_position-(other as Node3D).global_position;away.y=0
				if away.length()<.01:away=-offset
				velocity=(away.normalized()+away.normalized().cross(Vector3.UP)*.8).normalized()*.5
				blocked_seconds=maxf(0,blocked_seconds-nav.get_physics_process_delta_time()*2)
			else:velocity=Vector3.ZERO
		else:velocity=Vector3.ZERO
	pony.set_desired_velocity(velocity);nav.agent.velocity=Vector3.ZERO
	nav.state=nav.State.MOVING;nav.reason="Walking inside / through house doorway";nav._stuck_time=0
## With the native follower the authored doorway/indoor line is one more corridor for the same
## follower and motor (one movement writer): a two-point corridor from where she stands, resent
## only when the authored point moves. Collision, support and neighbour checks stay live; the
## walk grid's erosion does not apply to these hand-placed lines.
func native_walk(nav:Node,destination:Vector3,house:Node3D=null,final:=Vector3.INF,line_from:=Vector3.INF) -> void:
	var pony:Node3D=nav.pony
	if _yielding_peer!=null:
		var peer:Node=_yielding_peer.get_ref()
		if is_instance_valid(peer) and peer.indoor_yield.goal.is_finite():
			blocked_seconds=0;nav._halt();nav.state=nav.State.WAITING;nav.reason="Waiting for a pony to step aside";return
		_yielding_peer=null
	var points:=PackedVector3Array([pony.global_position])
	if house!=null and final.is_finite():
		# The room's waypoints (line up at the opening, step through, bend round the corner), all of
		# them, so she walks through instead of braking at every one.
		var at:=pony.global_position
		for i in 6:
			var next:Vector3=_waypoint(house,pony,at,final)
			if next.distance_to(at)<.01:break
			points.append(next)
			if next.distance_to(final)<.01:break
			at=next
	elif line_from.is_finite():
		# Through a doorway: back onto its centre line a little ahead of where she is along it,
		# then straight along it, never a diagonal from wherever a turn swung her into the frame.
		var along:=Vector3(destination.x-line_from.x,0,destination.z-line_from.z)
		var t:=clampf(Vector3(pony.global_position.x-line_from.x,0,pony.global_position.z-line_from.z).dot(along)/maxf(along.length_squared(),1e-6),0.0,1.0)
		var join:=line_from.lerp(destination,minf(1.0,t+.3/maxf(along.length(),.01)))
		if horizontal(join,destination)>.05 and horizontal(pony.global_position,join)>.05:points.append(join)
		points.append(destination)
	else:points.append(destination)
	if points.size()<2 and house!=null and final.is_finite():
		# A controller can stop legally beside furniture while the room's wider route
		# envelope overlaps its corner. Recover through a physically swept short leg,
		# then resume the existing room route; never teleport or change either shape.
		var departure:=_departure(nav,house,final)
		if departure.is_finite(): points.append(departure)

	else:
		_escape_goal=Vector3.INF
	if house!=null and final.is_finite() and blocked_seconds>.35:_request_peer_yield(nav,house,final)
	if points.size()<2 or horizontal(pony.global_position,points[-1])<.05:
		nav._halt();nav.state=nav.State.WAITING;nav.reason="Walking inside / through house doorway";return
	var changed:bool=not nav._native_authored or nav.path.size()!=points.size()
	for i in range(1,points.size()):
		if changed:break
		changed=nav.path[i].distance_to(points[i])>.05
	# A turn-round can swing her off a short indoor line; its end then lies beside her and the
	# follower brakes there. Start the line again from where she stands.
	if not changed and off_line(pony.global_position,nav.path)>.25:changed=true
	if changed:
		nav.path=points;nav._path_serial+=1
	nav._native_authored=true;nav._native_speed_cap=1.2;nav._needs_path=false
	nav._native_tick(nav.get_physics_process_delta_time())
	nav.state=nav.State.MOVING;nav.reason="Walking inside / through house doorway";nav._stuck_time=0
static func _waypoint(house:Node3D,pony:Node3D,from:Vector3,to:Vector3) -> Vector3:
	return house.local_waypoint_for(pony,from,to) if house.has_method("local_waypoint_for") else house.local_waypoint(from,to)

func _departure(nav:Node,house:Node3D,final:Vector3) -> Vector3:
	var pony:CharacterBody3D=nav.pony
	var at:=pony.global_position
	if _escape_goal.is_finite() and at.distance_to(_escape_goal)>.06: return _escape_goal
	var now:=Time.get_ticks_msec()
	if now<_escape_retry_at:return Vector3.INF
	_escape_retry_at=now+1000
	_escape_goal=Vector3.INF
	var holder:CollisionShape3D=pony.get("_collision") as CollisionShape3D
	if holder==null or holder.disabled or holder.shape==null:return Vector3.INF
	var space:=pony.get_world_3d().direct_space_state
	var angle:=atan2(final.z-at.z,final.x-at.x)
	for radius:float in [.25,.5,.8]:
		for step:int in [0,1,-1,2,-2,3,-3,4]:
			var turn:=angle+float(step)*TAU/8.
			var wanted:=at+Vector3(cos(turn),0,sin(turn))*radius
			if not house.contains(wanted):continue
			var safe:Vector3=preload("res://world/navigation/roster_placement.gd").support(space,wanted,pony.profile,house,[pony.get_rid()])
			if not safe.is_finite() or absf(safe.y-at.y)>.15:continue
			var next:Vector3=house._find_flat_waypoint(safe,final,pony,false) if house.has_method("local_waypoint_for") else house.local_waypoint(safe,final)
			if next.distance_to(safe)<.05:continue
			if not controller_clear(pony,safe):continue
			_escape_goal=safe
			return safe
	return Vector3.INF

static func off_line(at:Vector3,line:PackedVector3Array) -> float:
	var best:=INF
	for i in range(1,line.size()):
		var a:=Vector3(line[i-1].x,0,line[i-1].z);var b:=Vector3(line[i].x,0,line[i].z)
		best=minf(best,Geometry3D.get_closest_point_to_segment(Vector3(at.x,0,at.z),a,b).distance_to(Vector3(at.x,0,at.z)))
	return best
func set_goal(nav:Node,point:Vector3) -> void:
	goal=point;nav.target=point;nav._needs_path=true;nav._cancel_queries();nav.path.clear();nav._reset_lookahead();nav._stuck_time=0.0
static func horizontal(a:Vector3,b:Vector3) -> float:return Vector2(a.x-b.x,a.z-b.z).length()
static func crossed_target(position:Vector3,from:Vector3,to:Vector3) -> bool:
	var line:=Vector2(to.x-from.x,to.z-from.z)
	return line.length_squared()>.001 and Vector2(position.x-to.x,position.z-to.z).dot(line)>=0.0 and absf(position.y-to.y)<.3
## Rainbow Dash's Cloudominium stands on a cloud (dev 2026-09-28): no grid route reaches its door.
## On the cloud a pony walks the last metres straight to it, and stacked floors (her bedroom over
## the entrance) mean a pony overhead is not at the door point below her.
const SKY_WALK:=8.0
static func sky(house:Node) -> bool:return house!=null and house.has_method("sky_home")
func level(a:Vector3,b:Vector3) -> bool:return not sky(home) or absf(a.y-b.y)<1.5
## Bound for a home on a cloud from anywhere off it: a flyer flies up to its door approach and
## walks in from there like any house; a pony without wings is refused instead of walking legs
## toward a cloud. Long trips aim at the house itself, not their next leg on the ground.
func sky_trip(nav:Node,to:Node3D) -> bool:
	var pony:Node3D=nav.pony
	var journey:bool=nav._journey_goal.is_finite()
	var target:Node3D=house_of(pony.get_tree(),nav._journey_goal) if journey else to
	if not sky(target):return false
	if journey:
		nav._live_goal=nav._journey_goal;nav.target=nav._journey_goal;nav._journey_goal=Vector3.INF
	var door_at:Vector3=target.outside()
	if horizontal(pony.global_position,door_at)<SKY_WALK and absf(pony.global_position.y-door_at.y)<1.5:return false
	nav._cancel_queries();nav.path.clear();nav._needs_path=true
	if pony.has_method("request_flight") and fly_to_cloud(pony,door_at):
		nav.state=nav.State.MOVING;nav.reason="Flying up to a home on a cloud";return true
	var flight:Object=pony.get("flight")
	nav._fail("A home on a cloud needs a flight: "+(str(flight.get("reason")) if flight!=null else "cannot fly"))
	return true
## Long flights clear the terrain on the way but land on the terrain wherever the spot has no
## footprint: take one only onto the real cloud footprint, never to the ground under a cloud.
static func fly_to_cloud(pony:Node3D,at:Vector3) -> bool:
	var flight:Object=pony.get("flight")
	if flight!=null and flight.landing_surface(at).is_finite() and pony.request_flight(at,0.0,true):return true
	return pony.request_flight(at,0.0)
## Out of a cloud home's door onto its cloud: anywhere off that cloud is a flight away.
func fly_off(nav:Node,left:Node3D) -> bool:
	var pony:Node3D=nav.pony
	var far:Vector3=nav._journey_goal if nav._journey_goal.is_finite() else nav._live_goal
	var door_at:Vector3=left.outside()
	if not far.is_finite() or (horizontal(far,door_at)<SKY_WALK and absf(far.y-door_at.y)<1.5):return false
	var there:Node3D=HOME.at(pony.get_tree(),far)
	if not pony.has_method("request_flight") or not pony.request_flight(there.outside() if there!=null else far,0.0,true):return false
	nav._live_goal=far;nav.target=far;nav._journey_goal=Vector3.INF
	nav._cancel_queries();nav.path.clear();nav._needs_path=true
	nav.state=nav.State.MOVING;nav.reason="Flying down from a home on a cloud"
	return true

## Bounded neighbourhood query only after a blocked room route, never a scene scan.
func _request_peer_yield(nav:Node,house:Node3D,final:Vector3) -> void:
	var now:=Time.get_ticks_msec()
	if now<_peer_retry_at or not house.has_method("local_waypoint_for"):return
	_peer_retry_at=now+1000
	var pony:CharacterBody3D=nav.pony
	var query:=PhysicsShapeQueryParameters3D.new()
	var sphere:=SphereShape3D.new();sphere.radius=1.8
	query.shape=sphere;query.transform.origin=pony.global_position+Vector3.UP*.6
	query.collision_mask=2;query.exclude=[pony.get_rid()]
	var peers:Array[Node]=[]
	for hit:Dictionary in pony.get_world_3d().direct_space_state.intersect_shape(query,8):
		var peer:Node=hit.collider.get_node_or_null("Navigator")
		if peer!=null:peers.append(peer)
	if is_instance_valid(nav._follow_driver):
		for peer:Node in nav._follow_driver.nearby_navigators(pony.global_position,1.8):
			if peer!=nav and peer not in peers:peers.append(peer)
	for peer:Node in peers:
		if peer.get("indoor_yield")!=null and peer.indoor_yield.request(peer,nav,house,final):
			_yielding_peer=weakref(peer);return

## A physically valid stopped body may overlap its wider planning envelope. Certify
## only the short departure with its unchanged controller; destinations use full support.
static func controller_clear(pony:CharacterBody3D,to:Vector3) -> bool:
	var holder:CollisionShape3D=pony.get("_collision") as CollisionShape3D
	if holder==null or holder.shape==null:return false
	var sweep:=PhysicsShapeQueryParameters3D.new()
	sweep.shape=holder.shape;sweep.transform=holder.global_transform
	sweep.transform.origin+=Vector3.UP*.03
	sweep.margin=.001;sweep.motion=to-pony.global_position;sweep.collision_mask=pony.collision_mask|2
	sweep.exclude=[pony.get_rid()]
	var space:=pony.get_world_3d().direct_space_state
	if not space.intersect_shape(sweep,1).is_empty():return false
	var travel:=space.cast_motion(sweep)
	return travel.size()==2 and travel[0]>=.9999
