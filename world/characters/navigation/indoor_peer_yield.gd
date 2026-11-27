extends RefCounted
## A short courtesy move beneath an idle intention, using the existing native motor.
## Never takes command ownership or emits completion for the caller's stay command.
const SUPPORT := preload("res://world/navigation/roster_placement.gd")
var goal := Vector3.INF
var owner := ""
var intent := -1
var expires := 0
var cooldown := 0
var requester_ref:WeakRef

func clear() -> void:
	goal = Vector3.INF
	requester_ref=null

## 2026-11-19 (tools/interiors_nav/test_upstairs_exit.gd --house=library): a pony waiting inside
## for the door's passage ticket stands beside the doorway, often on the ticket holder's own way
## from the stairs to the door. She has a destination, so she could never be asked to step aside,
## and the holder pressed against her until her own trip gave up (Twilight and Spike, 20 to 40 s).
## A leaving pony that only waits for the door now steps aside like an idle one; her trip resumes
## where it was. Rollback: DOOR_WAITERS_YIELD = false.
static var DOOR_WAITERS_YIELD := true

static func _door_waiter(nav:Node) -> bool:
	var trip: RefCounted = nav.get("house_travel")
	return DOOR_WAITERS_YIELD and trip != null and trip.active() and bool(trip.waiting_for_ticket) and not bool(trip.entering)

func available(nav:Node) -> bool:
	var pony:CharacterBody3D = nav.pony
	return nav.native_follow and (not nav._has_target or _door_waiter(nav)) and not is_instance_valid(nav._follow_target) \
		and not is_instance_valid(nav._conversation_target) and not nav.face_point.is_finite() \
		and not pony.motion_paused and not pony._held and pony._interaction.is_empty() \
		and pony.get("sleeping") != true and pony.grounded() \
		and (pony.get("hoof_hold") == null or not pony.hoof_hold.active()) \
		and (pony.get("thrown") == null or not pony.thrown.active()) \
		and (pony.get("flight") == null or not pony.flight.active()) \
		and (not pony.has_method("posture_status") or str(pony.posture_status().get("kind", "stand")) == "stand" and str(pony.posture_status().get("requested", "stand")) == "stand")

func request(nav:Node, requester:Node, house:Node3D, final:Vector3) -> bool:
	if goal.is_finite(): return requester_ref!=null and requester_ref.get_ref()==requester
	var now := Time.get_ticks_msec()
	if now < cooldown or not available(nav): return false
	cooldown = now + 1000
	var pony:CharacterBody3D = nav.pony
	var other:CharacterBody3D = requester.pony
	var at := pony.global_position
	if absf(at.y-other.global_position.y) > .2 or not house.contains(at): return false
	# Only the pony actually occupying this near corridor is asked to move.
	var segment_end := other.global_position.move_toward(final, 2.0)
	var near := Geometry3D.get_closest_point_to_segment(at,other.global_position,segment_end)
	var separation:float = pony.profile.radius + other.profile.radius + .1
	if at.distance_to(near) > separation: return false
	var cramped:bool = not house._clear(at,at,pony)
	var best := Vector3.INF
	var score := INF
	var space := pony.get_world_3d().direct_space_state
	for radius:float in [.75,1.25,1.75,2.25]:
		for step in 16:
			var angle := float(step)*TAU/16.
			var wanted := at + Vector3(cos(angle),0,sin(angle))*radius
			if not house.contains(wanted): continue
			var point := SUPPORT.support(space,wanted,pony.profile,house,[pony.get_rid()])
			if not point.is_finite() or absf(point.y-at.y)>.15: continue
			var corridor := Geometry3D.get_closest_point_to_segment(point,other.global_position,final)
			if point.distance_to(corridor) < separation: continue
			if cramped:
				# Ignore the peer only for planning the departure. Furniture still gets
				# the unchanged full envelope, and the actual sweep includes that peer.
				if not house._clear(at,point,pony,false) or not nav.house_travel.controller_clear(pony,point): continue
			elif not house._clear(at,point,pony): continue
			var cost := at.distance_to(point)
			if cost < score: best=point;score=cost
	if not best.is_finite(): return false
	goal=best;owner=nav.command_owner;intent=nav._native_intent;expires=now+8000;requester_ref=weakref(requester)
	return true

func tick(nav:Node) -> bool:
	if not goal.is_finite(): return false
	if nav.command_owner != owner or nav._native_intent != intent:
		clear();return false
	if not available(nav):
		clear();nav.path.clear();nav._halt();return false
	if Time.get_ticks_msec()>=expires or nav.pony.global_position.distance_to(goal)<.12:
		clear();nav.path.clear();nav._halt();nav.state=nav.State.IDLE;nav.reason="Staying here";return true
	# The validated straight courtesy leg still uses the ordinary collision-aware motor.
	nav.house_travel.native_walk(nav,goal)
	nav.reason="Stepping aside inside the room"
	return true
