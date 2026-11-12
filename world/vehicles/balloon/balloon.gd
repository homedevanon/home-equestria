extends CharacterBody3D
## A freely piloted platform. No destination teleport or camera-relative flight controls.
const SFX = preload("res://world/audio/interaction_sounds.gd")
var _foley_time := 0.0
var _burner_audio := 0
var _last_vent := 0.0
var _last_controls := Vector2.ZERO
const FITTINGS=preload("res://world/vehicles/balloon/basket.gd")
const OWNER:="vehicle:balloon"
const CONTROL_LAYER:=1<<21
var game:Node
var inventory:Node
var hands:Node
var home:=Transform3D.IDENTITY
var lift:=0.0
var vent:=0.0
var steering:=Vector2.ZERO
var gate_open:=true
var landed:=true
var passengers:Array[Dictionary]=[]
var _player:CharacterBody3D
var _player_floor_layers:=0
var _scan:=0.0
var _gate_angle:=0.0
var _empty_time:=0.0
var saved_passengers:Dictionary={}
var _ground_height:=NAN
## Followers board by themselves (dev 2026-09-28: "does the AI have the tools to follow me into
## the balloon"): a pony following Anon (her AI's follow, a date, "come along") walks to the ramp
## foot and climbs in while he is aboard a landed balloon with the gate open. Lift waits for her,
## up to BOARD_WAIT s, instead of leaving her behind. Aboard, she sits down after a moment.
const BOARD_OWNER:="vehicle:balloon:boarding"
const BOARD_RANGE:=14.0
const BOARD_WAIT:=12.0
const SPOTS:=[Vector3(-.65,.27,-.35),Vector3(.65,.27,-.35),Vector3(-.65,.27,.55),Vector3(.65,.27,.55)]
var _evicting:Dictionary={} # actor -> true while she hops out
var _boarding:Dictionary={} # id -> {actor,nav,owner,follow,wander,executors,stage,clock,best,stuck}
var _lift_wait:=0.0

static func attach(town:Node)->Node3D:
 var original:Node3D=town.find_child("airballoon_01",true,false) as Node3D
 if original==null:return null
 var ship:CharacterBody3D=load("res://world/vehicles/balloon/balloon.gd").new()
 ship.name="SkyBalloon";original.get_parent().add_child(ship);ship.global_transform=original.global_transform;ship.home=ship.global_transform
 original.reparent(ship);original.transform=Transform3D.IDENTITY
 for node:CollisionObject3D in original.find_children("*","CollisionObject3D",true,false):
  node.collision_layer=0;node.collision_mask=0
 for mesh:MeshInstance3D in original.find_children("*","MeshInstance3D",true,false):_open_doorway(mesh)
 FITTINGS.build(ship)
 ship._finish_build()
 return ship

static func _open_doorway(node:MeshInstance3D)->void:
 # Preserve envelope and suspension; replace the closed basket with a boardable shell.
 var mesh:=ArrayMesh.new()
 for si:int in node.mesh.get_surface_count():
  var a:Array=node.mesh.surface_get_arrays(si);var vertices:PackedVector3Array=a[Mesh.ARRAY_VERTEX]
  var indices:PackedInt32Array=a[Mesh.ARRAY_INDEX];var kept:=PackedInt32Array()
  if indices.is_empty():
   for i:int in vertices.size():indices.append(i)
  for i:int in range(0,indices.size(),3):
   var top:float=maxf(vertices[indices[i]].y,maxf(vertices[indices[i+1]].y,vertices[indices[i+2]].y))
   if top<1.9:continue
   kept.append(indices[i]);kept.append(indices[i+1]);kept.append(indices[i+2])
  if kept.is_empty():continue
  a[Mesh.ARRAY_INDEX]=kept
  mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,a)
  mesh.surface_set_material(mesh.get_surface_count()-1,FITTINGS.material(Color("d4ad65")) if si in [1,9] else node.mesh.surface_get_material(si))
 node.mesh=mesh

func _finish_build()->void:
 collision_layer=1;collision_mask=1|(1<<18);motion_mode=CharacterBody3D.MOTION_MODE_FLOATING
 process_physics_priority=-80
 set_meta("ai_label","flyable hot-air balloon")
 add_to_group("hot_air_balloons") # place_directory.gd lists it as an AI destination while landed.
 # Envelope clearance: stops free steering through buildings, not just the basket.
 var cs:=CollisionShape3D.new();var sphere:=SphereShape3D.new();sphere.radius=2.9;cs.shape=sphere;cs.position.y=5.8;add_child(cs)
 add_collision_exception_with($Gate);add_collision_exception_with($Ramp)
 _set_gate(true,true)

func setup(host:Node)->void:
 game=host;inventory=host.inventory
 hands=preload("res://world/vehicles/balloon/controls.gd").new();add_child(hands);hands.setup(self,inventory)

func contains(point:Vector3,margin:=0.0)->bool:
 var p:=to_local(point)
 return absf(p.x)<1.43+margin and absf(p.z)<1.29+margin and p.y>0.05 and p.y<1.05

## A seated/standing VR rider may lean this far over the rail without stepping off the craft.
const LEAN:=.45
## The VR Body node is the room-scale rig origin; its capsule follows the headset
## (xr_grounded_body.gd), so the player stands under the camera, often a metre from the node.
## Testing the node kept a VR pilot "outside": no rope or helm grab, no lift (dev 2026-10-15:
## "the hot air balloon controls did not work in VR").
func _xr_camera(body:Node3D)->XRCamera3D:
 var camera:Camera3D=inventory.get("camera") as Camera3D if is_instance_valid(inventory) else null
 return camera as XRCamera3D if camera is XRCamera3D and body.is_ancestor_of(camera) else null

func player_feet(body:Node3D)->Vector3:
 var camera:=_xr_camera(body)
 return body.global_position if camera==null else Vector3(camera.global_position.x,body.global_position.y,camera.global_position.z)

## Boarding needs the feet on the deck; once aboard, leaning out over the rail stays aboard (VR).
func holds_player(rider:Variant)->bool:
 if not is_instance_valid(rider) or not rider is Node3D:return false
 var body:Node3D=rider as Node3D
 return contains(player_feet(body),LEAN if body==_player and _xr_camera(body)!=null else 0.0)

func set_controls(up:float,down:float,aim:Vector2)->void:
 lift=clampf(up,0,1);vent=clampf(down,0,1);steering=aim.limit_length(1)

## Closing always works. Opening needs the basket nearly still with ground or cloud under it:
## `landed` alone read only one centre ray within 13 cm, so a basket resting on an uneven cloud
## or a slope never counted as landed and the gate would not open (dev 2026-09-28).
func toggle_gate()->bool:
 if gate_open:_set_gate(false);return true
 if not can_open_gate():return false
 _set_gate(true);return true

func can_open_gate()->bool:
 return velocity.length()<=.3 and (landed or _resting_near_support())

func _resting_near_support()->bool:
 var excluded:Array[RID]=[get_rid(),$Gate.get_rid(),$Ramp.get_rid()]
 var space:=get_world_3d().direct_space_state
 for corner:Vector3 in [Vector3.ZERO,Vector3(1.3,0,1.15),Vector3(-1.3,0,1.15),Vector3(1.3,0,-1.15),Vector3(-1.3,0,-1.15)]:
  var at:=global_transform*corner
  if not space.intersect_ray(PhysicsRayQueryParameters3D.create(at+Vector3.UP*.1,at-Vector3.UP*.8,collision_mask,excluded)).is_empty():return true
 return is_finite(_ground_height) and global_position.y-_ground_height<.8

func _set_gate(open:bool,instant:=false)->void:
 if not instant and gate_open != open:SFX.play_at(self,"prop_balloon_gate")
 gate_open=open
 if instant:_gate_angle=PI*.5 if open else 0.0
 var ramp:Node3D=get_node_or_null("Ramp")
 if ramp!=null:
  ramp.visible=open
  for cs:CollisionShape3D in ramp.find_children("*","CollisionShape3D",true,false):cs.disabled=not open

func _physics_process(delta:float)->void:
 if not has_node("Gate"):return
 _scan-=delta
 var scanned:=false
 if _scan<=0:
  _scan=.25;_board_occupants();scanned=true
  _parked_scans=_parked_scans+1 if PARK_IDLE and _parked_idle() else 0
 # Parked idle: the boarding scan stays at 4 Hz; the full tick after it only every
 # PARKED_FULL_EVERY scans (W2 perf pass; the safety re-grounding then runs at 1 Hz).
 if PARK_IDLE and (not scanned or (_parked_scans-1)%PARKED_FULL_EVERY!=0) and _parked_idle():
  # The full tick's only changes while parked empty: its two timers.
  if is_instance_valid(inventory):_empty_time+=delta
  else:_empty_time=0
  _foley_time-=delta
  return
 _gate_angle=move_toward(_gate_angle,PI*.5 if gate_open else 0.0,delta*2)
 $Gate.rotation.y=_gate_angle
 var aboard:bool=holds_player(_player)
 if lift>.02 and gate_open:
  # A follower still climbing aboard holds the take-off (gate open, so no lift) a little while.
  if _lift_wait==0.0:_invite_followers()
  if not _boarding.is_empty() and _lift_wait<BOARD_WAIT:_lift_wait+=delta
  else:
   for id:String in _boarding.keys():_end_boarding(id,false)
   _lift_wait=0.0;_set_gate(false)
 elif lift<=.02:_lift_wait=0.0
 _step_boarding(delta)
 var wanted:=Vector3(steering.x*5.5,(lift-vent)*2.2,steering.y*5.5)
 if gate_open or absf(_gate_angle)>.01:wanted=Vector3.ZERO
 # Never leave a pilot behind; an empty craft gently settles straight down.
 if not aboard and is_instance_valid(inventory):
  wanted=Vector3.ZERO;_empty_time+=delta
  if _empty_time>2.0 and not landed and is_finite(_ground_height):wanted.y=-.6
 else:_empty_time=0
 velocity=velocity.move_toward(global_basis*wanted,delta*1.8)
 var was_landed := landed
 var landing_speed := maxf(0.0, -velocity.y)
 var before:=global_transform
 if velocity.length_squared()>.00001:
  var impact:KinematicCollision3D=move_and_collide(velocity*delta)
  if impact!=null:velocity=velocity.slide(impact.get_normal())
 _keep_above_ground()
 var displacement:=global_position-before.origin
 # Player is carried explicitly; suppress CharacterBody's automatic platform transfer.
 if is_instance_valid(_player):
  _player.global_position+=displacement
  if not holds_player(_player):_release_player()
 _update_passengers()
 var support:Dictionary=_support()
 landed=not support.is_empty() and velocity.length()<.18
 if not support.is_empty() and not was_landed and landing_speed > .2:SFX.play_event(self,"prop_balloon_land",{"intensity":clampf(landing_speed/1.8,.25,1.0)})
 # Ground/cloud contact stops downward drift without driving the basket into its floor.
 if not support.is_empty() and velocity.y<0:velocity.y=0
 var burning := lift>.03 and not gate_open and absf(_gate_angle)<=.01 and aboard
 _foley_time-=delta
 if burning:
  if _foley_time<=0:
   _foley_time=.4
   if _burner_audio==0:_burner_audio=SFX.start_loop(self,"prop_burner_loop",{"intensity":lift})
   if _burner_audio!=0 and not SFX.update_loop(self,_burner_audio,{"intensity":lift},$Flame.global_position):_burner_audio=0
 elif _burner_audio!=0:
  SFX.stop_loop(self,_burner_audio,.18);_burner_audio=0;_foley_time=0.0
 if vent>.05 and _last_vent<=.05 and not gate_open:SFX.play_event(self,"prop_vent",{"intensity":vent},$Vent.global_position)
 _last_vent=vent
 var controls:=Vector2(lift,vent)
 if controls.distance_to(_last_controls)>.12:
  SFX.play_event(self,"prop_rope",{"intensity":clampf(controls.distance_to(_last_controls)*2.0,.3,.7)})
  _last_controls=controls
 $Flame.visible=lift>.03 and not gate_open
 $LiftPulley.rotation.z=lift*3;$VentPulley.rotation.z=vent*3
 $Lift.position.y=1.52-lift*.3;$Vent.position.y=1.52-vent*.3
 $Helm.rotation=Vector3(-steering.y*.4,0,steering.x*.4)
 for spec:Array in [["LiftLine",lift],["VentLine",vent]]:
  var line:MeshInstance3D=get_node(spec[0]);line.scale.y=1+float(spec[1])*.3;line.position.y=2.05-float(spec[1])*.15
 _rest_key=[global_transform,lift,vent,steering,gate_open,_gate_angle]

## dev 2026-10-20 perf pass: parked, empty and settled, a full tick only repeats itself (same gate,
## pulley, helm and line writes, which re-send four collision bodies, plus a support ray and five
## terrain samples), so between boarding scans (4 Hz, each followed by a full tick) it is skipped.
## Anything that changes (controls, gate, pose, a rider, a passenger, a boarding) runs full ticks.
## Rollback: PARK_IDLE = false.
const PARK_IDLE:=true
## Rollback of the 1 Hz parked full tick: PARKED_FULL_EVERY = 1 (a full tick after every scan).
const PARKED_FULL_EVERY:=4
var _parked_scans:=0
var _rest_key:Array=[]
func _parked_idle()->bool:
 # Field by field: no Array built per tick (same comparison as _rest_key==[...]).
 return landed and velocity==Vector3.ZERO and lift==0.0 and vent==0.0 and steering==Vector2.ZERO and _burner_audio==0 \
  and _lift_wait==0.0 and not is_instance_valid(_player) and passengers.is_empty() and _boarding.is_empty() and _evicting.is_empty() \
  and _gate_angle==(PI*.5 if gate_open else 0.0) and _rest_key.size()==6 and _rest_key[0]==global_transform and _rest_key[1]==lift \
  and _rest_key[2]==vent and _rest_key[3]==steering and _rest_key[4]==gate_open and _rest_key[5]==_gate_angle

func _support()->Dictionary:
 var excluded:Array[RID]=[get_rid(),$Gate.get_rid(),$Ramp.get_rid()]
 var hit:=get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(global_position+Vector3.UP*.09,global_position-Vector3.UP*.13,collision_mask,excluded))
 if not hit.is_empty():return hit # Solid cloud/platform support still wins.
 if is_finite(_ground_height) and absf(global_position.y-_ground_height)<.13:
  return {"position":Vector3(global_position.x,_ground_height,global_position.z),"normal":Vector3.UP}
 return {}

## Terrain3D streams collision around the player. Its heightmap remains available
## at a parked balloon, so absent physics must never mean permission to fall forever.
func _keep_above_ground()->void:
 _ground_height=NAN
 if not is_instance_valid(WorldTerrain.instance):return
 for offset:Vector3 in [Vector3.ZERO,Vector3(-1.5,0,-1.35),Vector3(1.5,0,-1.35),Vector3(-1.5,0,1.35),Vector3(1.5,0,1.35)]:
  var height:float=WorldTerrain.instance.height_at(global_position+global_basis*offset)
  if is_finite(height):_ground_height=maxf(_ground_height,height) if is_finite(_ground_height) else height
 if not is_finite(_ground_height):return
 var minimum:float=_ground_height+.02
 if global_position.y>=minimum:return
 var recovered:bool=minimum-global_position.y>1.0
 if recovered:print("[balloon] recovered underground position ",global_position," to ground y=",minimum)
 global_position.y=minimum
 velocity.y=maxf(0.0,velocity.y)
 if recovered:
  lift=0;vent=0;steering=Vector2.ZERO;landed=true
  _set_gate(true,true)

func _board_occupants()->void:
 if not is_instance_valid(game):return
 var body:CharacterBody3D=inventory.player_body if is_instance_valid(inventory) else null
 if is_instance_valid(body) and not is_instance_valid(_player) and holds_player(body):
  _player=body;_player_floor_layers=body.platform_floor_layers;body.platform_floor_layers=0
 var population:Node=game.get("population") as Node
 if population==null:return
 # Ponies never get in on their own (dev 2026-10-16: "ponies should not enter the balloon on
 # their own period, without the player to operate the controls"). Only a follower Anon takes
 # aboard (_invite_followers) or a rider restored with the save comes in; anypony else found in
 # the basket or up on its rim hops down to the ramp foot.
 var anon_aboard:bool=holds_player(_player)
 # Neither box below (basket or rim) reaches past ~3.1 m of the origin in local space: ponies
 # farther away skip the per-pony property and passenger lookups (45 ponies, 4 scans a second).
 var size:=global_basis.get_scale().abs()
 var reach:float=SCAN_REACH*maxf(size.x,maxf(size.y,size.z))
 var centre:=global_position
 for id:String in population.live:
  var actor:Node3D=population.live[id].get("actor") as Node3D
  if not is_instance_valid(actor) or actor.global_position.distance_squared_to(centre)>reach*reach:continue
  if actor.get("_held")==true or _boarding.has(id) or _evicting.has(actor):continue
  var existing:=false
  for row:Dictionary in passengers:existing=existing or row.actor==actor
  if existing:continue
  # A pegasus flying through is not in the basket (and must not be hopped to the ground mid-air).
  if actor.get("flight")!=null and actor.flight.active():continue
  var at:=actor.global_position
  if contains(at):
   var invited:bool=saved_passengers.has(id) or (is_instance_valid(nav_of(actor)) and _follows_player(actor,nav_of(actor)))
   if anon_aboard and invited and board(actor,id):continue
   # Never hopped out into the air or onto a cloud she would fall through: she rides along
   # (or waits) until the basket is down where she can stand.
   if _can_step_off(actor):_evict(actor)
   elif anon_aboard:board(actor,id)
  elif _on_rim(at) and _can_step_off(actor):_evict(actor)
 _invite_followers()

## Farthest local point of the rim box (1.78, 1.9, 1.64) plus slack; contains() is inside it.
const SCAN_REACH:=3.2
## Landed where she can stand: solid ground, or a cloud only for a pony who walks on clouds.
func _can_step_off(actor:Node3D)->bool:
 if not landed:return false
 var support:CollisionObject3D=_support().get("collider") as CollisionObject3D
 var on_cloud:bool=support!=null and (support.collision_layer&(1<<18))!=0
 return not on_cloud or (int(actor.get("floor_mask"))&(1<<18))!=0

func nav_of(actor:Node3D)->Node:
 return actor.get_node_or_null("Navigator")

## On the basket's walls or rim (above the deck box, within a hand of its sides).
func _on_rim(point:Vector3)->bool:
 var p:=to_local(point)
 return absf(p.x)<1.43+.35 and absf(p.z)<1.29+.35 and p.y>0.05 and p.y<1.9

## A pony that got in (or up on the rim) on her own: a short hop down to the ramp foot. A walk
## that was taking her into the basket ends there.
func _evict(actor:Node3D)->void:
 _evicting[actor]=true
 saved_passengers.erase(str(actor.get("identity").id) if actor.get("identity")!=null else "")
 actor.motion_paused=true
 var from:=actor.global_position;var to:=_ramp_foot()
 var tween:=create_tween().bind_node(actor)
 tween.tween_method(func(t:float)->void:
  actor.global_position=from.lerp(to,t)+Vector3.UP*sin(PI*t)*.4,0.0,1.0,.8)
 tween.tween_callback(func()->void:
  _evicting.erase(actor)
  actor.motion_paused=false
  actor.reset_motion(Transform3D(Basis.looking_at(-global_basis.z,Vector3.UP),to+Vector3.UP*.02))
  var nav:Node=nav_of(actor)
  if nav!=null and bool(nav.get("_has_target")) and _on_rim(nav.target):nav.stay())

## Followers of Anon near a landed, open balloon he is aboard start walking up the ramp.
func _invite_followers()->void:
 var population:Node=game.get("population") as Node if is_instance_valid(game) else null
 if population==null:return
 if holds_player(_player) and gate_open and (landed or _resting_near_support()):
  for id:String in population.live:
   if _boarding.has(id) or passengers.size()+_boarding.size()>=SPOTS.size():continue
   var actor:Node3D=population.live[id].get("actor") as Node3D
   if not is_instance_valid(actor) or contains(actor.global_position) or actor.get("_held")==true or actor.get("sleeping")==true or actor.has_meta("balloon_passenger"):continue
   if actor.global_position.distance_to(global_position)>BOARD_RANGE:continue
   var nav:Node=actor.get_node_or_null("Navigator")
   if nav!=null and _follows_player(actor,nav):_start_boarding(id,actor,nav)

func _player_node(node:Variant)->bool:
 if not is_instance_valid(node) or not node is Node:return false
 var rig:Node=game.get("player") as Node if is_instance_valid(game) else null
 for mine:Variant in [_player,rig,preload("res://world/player_view.gd").camera(self)]:
  if is_instance_valid(mine) and (node==mine or (mine as Node).is_ancestor_of(node) or (node as Node).is_ancestor_of(mine)):return true
 return false

## Following Anon: her navigator's follow, a date (relationship lease "bond:"), or her AI's follow.
func _follows_player(actor:Node3D,nav:Node)->bool:
 if _player_node(nav.get("_follow_target")) or str(nav.command_owner).begins_with("bond:"):return true
 var actions:Node=game.director.get("actions") as Node if is_instance_valid(game) and game.get("director")!=null else null
 if actions==null:return false
 for executor:Node in actions.executors.values():
  if not is_instance_valid(executor) or executor.actor!=actor:continue
  var move:Dictionary=executor.movement
  if move.get("type","")=="follow" and move.get("target") is WeakRef:return _player_node((move.target as WeakRef).get_ref())
 return false

func _ramp_foot()->Vector3:
 return to_global(Vector3(0,0,-2.75))

func _free_spot()->Vector3:
 for local:Vector3 in SPOTS:
  var at:=to_global(local);var feet:=player_feet(_player) if is_instance_valid(_player) else Vector3.INF;var taken:=Vector2(at.x-feet.x,at.z-feet.z).length()<.55
  for row:Dictionary in passengers:taken=taken or (is_instance_valid(row.actor) and (row.actor as Node3D).global_position.distance_to(at)<.55)
  if not taken:return at
 return to_global(SPOTS[0])

## The nearest standing spot neither Anon nor another passenger is on, or INF when all are taken.
func _spot_for(actor:Node3D)->Vector3:
 var feet:=player_feet(_player) if is_instance_valid(_player) else Vector3.INF
 var best:=Vector3.INF;var best_d:=INF
 for local:Vector3 in SPOTS:
  var at:=to_global(local);var taken:=Vector2(at.x-feet.x,at.z-feet.z).length()<.55
  for row:Dictionary in passengers:
   if is_instance_valid(row.actor) and row.actor!=actor:
    var other:=(row.actor as Node3D).global_position;taken=taken or Vector2(at.x-other.x,at.z-other.z).length()<.55
  var d:=actor.global_position.distance_to(at)
  if not taken and d<best_d:best=at;best_d=d
 return best

func _start_boarding(id:String,actor:Node3D,nav:Node)->void:
 var row:Dictionary={"actor":actor,"nav":nav,"owner":nav.command_owner,"follow":nav.get("_follow_target"),"wander":nav.wander_enabled,"executors":[],"stage":"walk","clock":0.0,"best":INF,"stuck":0.0}
 var actions:Node=game.director.get("actions") as Node if game.get("director")!=null else null
 if actions!=null:
  for executor:Node in actions.executors.values():
   if is_instance_valid(executor) and executor.actor==actor:
    row.executors.append({"node":executor,"processing":executor.is_physics_processing()});executor.set_physics_process(false)
 nav.stay();nav.command_owner=BOARD_OWNER;nav.wander_enabled=false
 nav.go_to(_ramp_foot())
 _boarding[id]=row

func _step_boarding(delta:float)->void:
 for id:String in _boarding.keys():
  var row:Dictionary=_boarding[id]
  var actor:Node3D=row.actor as Node3D
  if not is_instance_valid(actor) or actor.get("_held")==true or not gate_open:_end_boarding(id,false);continue
  row.clock=float(row.clock)+delta
  if row.stage!="walk":continue
  if row.nav.command_owner!=BOARD_OWNER:_end_boarding(id,false);continue # a new command took her
  var foot:=_ramp_foot()
  var gap:=Vector2(actor.global_position.x-foot.x,actor.global_position.z-foot.z).length()
  if gap<float(row.best)-.05:row.best=gap;row.stuck=0.0
  else:row.stuck=float(row.stuck)+delta
  # The walk grid may not reach every ramp (a cloud landing): close enough, she hops the rest.
  if gap<.7 or (float(row.stuck)>2.5 and actor.global_position.distance_to(global_position)<6.0):_climb(id,row)
  elif float(row.clock)>30.0 or float(row.stuck)>6.0:_end_boarding(id,false)

## Up the ramp and in: a short eased hop to a free standing spot on the deck.
func _climb(id:String,row:Dictionary)->void:
 var actor:Node3D=row.actor as Node3D
 row.stage="climb";row.nav.stay()
 actor.motion_paused=true
 var from:=actor.global_position;var to:=_free_spot()
 var facing:=Basis.looking_at(Vector3(global_position.x-to.x,0,global_position.z-to.z).normalized() if Vector2(global_position.x-to.x,global_position.z-to.z).length()>.05 else -global_basis.z,Vector3.UP)
 var tween:=create_tween().bind_node(actor)
 tween.tween_method(func(t:float)->void:
  actor.global_position=from.lerp(to,t)+Vector3.UP*sin(PI*t)*.35*float(actor.get("body_scale") if actor.get("body_scale")!=null else 1.0),0.0,1.0,1.0)
 tween.tween_callback(func()->void:
  actor.motion_paused=false
  actor.reset_motion(Transform3D(facing,to+Vector3.UP*.02))
  _end_boarding(id,true))

func _end_boarding(id:String,aboard:bool)->void:
 if not _boarding.has(id):return
 var row:Dictionary=_boarding[id];_boarding.erase(id)
 var actor:Node3D=row.actor as Node3D
 if not is_instance_valid(actor):return
 actor.motion_paused=false
 var nav:Node=row.nav
 if is_instance_valid(nav) and nav.command_owner==BOARD_OWNER:
  nav.stay();nav.command_owner=row.owner;nav.wander_enabled=row.wander
  if is_instance_valid(row.follow):nav.follow(row.follow)
 for executor:Dictionary in row.executors:
  if is_instance_valid(executor.node):executor.node.set_physics_process(executor.processing)
 if aboard and contains(actor.global_position):board(actor,id)

func board(actor:Node3D,id:String)->bool:
 if not contains(actor.global_position) or actor.get("_held")==true or actor.get("sleeping")==true or actor.motion_paused:return false
 var nav:Node=actor.get_node_or_null("Navigator")
 if nav==null:return false
 # Each passenger on her own standing spot (2026-10-16: two ponies boarded where they stood and
 # sat inside each other); a full basket takes nopony more.
 var spot:=_spot_for(actor)
 if not spot.is_finite():return false
 var row:Dictionary={"actor":actor,"id":id,"nav":nav,"nav_processing":nav.is_physics_processing(),"follow":nav._follow_target,"owner":nav.command_owner,"wander":nav.wander_enabled}
 row.executors=[]
 if is_instance_valid(game) and game.get("director")!=null:
  var actions:Node=game.director.get("actions") as Node
  if actions!=null:
   for executor:Node in actions.executors.values():
    if is_instance_valid(executor) and executor.actor==actor:
     row.executors.append({"node":executor,"processing":executor.is_physics_processing()});executor.set_physics_process(false)
 nav.stay();nav.command_owner=OWNER;nav.set_physics_process(false)
 actor.reset_motion(Transform3D(actor.global_transform.basis,spot+Vector3.UP*.02));actor.set_moving_support(self)
 actor.set_meta("balloon_passenger",self)
 row.sit_at=Time.get_ticks_msec()*.001+2.5;row.sat=false
 saved_passengers.erase(id)
 passengers.append(row);return true

func _update_passengers()->void:
 for row:Dictionary in passengers.duplicate():
  var actor:Node3D=row.actor
  if not is_instance_valid(actor):passengers.erase(row);continue
  if bool(row.get("leaving",false)):continue
  if actor.get("_held")==true or (actor.thrown!=null and actor.thrown.active()) or not contains(actor.global_position):_release_passenger(row);continue
  # She stays aboard while Anon is; once he has stepped out of the landed basket, she follows.
  var anon_aboard:bool=holds_player(_player)
  # Gate shut (he climbed out over the side): after a moment they hop out after him too, instead
  # of staying in the landed basket forever.
  var now:=Time.get_ticks_msec()*.001
  if not landed or anon_aboard:row.alone_at=INF
  elif not is_finite(float(row.get("alone_at",INF))):row.alone_at=now
  if landed and not anon_aboard and (gate_open or now-float(row.alone_at)>2.0):
   # Non-cloudwalking passengers remain safely aboard when Anon opens the sky gate.
   if _can_step_off(actor):_disembark(row)
   continue
  # Hanging out: she sits down on the deck once she has settled in.
  if not bool(row.get("sat",true)) and Time.get_ticks_msec()*.001>float(row.get("sit_at",0.0)) and actor.has_method("request_posture"):
   if actor.posture_status().requested=="stand" and actor.request_posture("sit"):row.sat=true
   else:row.sit_at=Time.get_ticks_msec()*.001+1.0

## Out of the basket: she stands, hops down the ramp to its foot, then is released (her follow of
## Anon resumes). The basket floor is not on the walk grid, so she cannot walk out herself.
func _disembark(row:Dictionary)->void:
 var actor:Node3D=row.actor as Node3D
 row.leaving=true
 if bool(row.get("sat",false)):actor.request_posture("stand");row.sat=false
 var tween:=create_tween().bind_node(actor)
 tween.tween_interval(.6)
 var from:=[Vector3.ZERO]
 tween.tween_callback(func()->void:actor.set_moving_support(null);actor.motion_paused=true;from[0]=actor.global_position)
 tween.tween_method(func(t:float)->void:
  actor.global_position=(from[0] as Vector3).lerp(_ramp_foot(),t)+Vector3.UP*sin(PI*t)*.3,0.0,1.0,.9)
 tween.tween_callback(func()->void:
  actor.motion_paused=false
  actor.reset_motion(Transform3D(Basis.looking_at(-global_basis.z,Vector3.UP),_ramp_foot()+Vector3.UP*.02))
  if passengers.has(row):_release_passenger(row))

func _release_passenger(row:Dictionary)->void:
 var actor:Node3D=row.actor
 if is_instance_valid(actor):
  actor.set_moving_support(null);actor.remove_meta("balloon_passenger")
  if bool(row.get("sat",false)) and actor.has_method("request_posture"):actor.request_posture("stand")
  var nav:Node=row.nav
  if is_instance_valid(nav):nav.set_physics_process(row.nav_processing)
  for executor:Dictionary in row.executors:
   if is_instance_valid(executor.node):executor.node.set_physics_process(executor.processing)
  if is_instance_valid(nav) and nav.command_owner==OWNER:
   nav.command_owner=row.owner;nav.wander_enabled=row.wander;nav.set_physics_process(row.nav_processing)
   if is_instance_valid(row.follow):nav.follow(row.follow)
 passengers.erase(row)

func _release_player()->void:
 if is_instance_valid(_player):_player.platform_floor_layers=_player_floor_layers
 _player=null

func owns(id:String)->bool:
 if saved_passengers.has(id):return true
 for row:Dictionary in passengers:
  if row.id==id:return true
 return false

func position_for(id:String)->Vector3:
 if saved_passengers.has(id):
  var p:Array=saved_passengers[id];return to_global(Vector3(p[0],p[1],p[2]))
 for row:Dictionary in passengers:
  if row.id==id and is_instance_valid(row.actor):return row.actor.global_position
 return Vector3.INF

func checkpoint()->Dictionary:
 var riders:Dictionary=saved_passengers.duplicate(true)
 for row:Dictionary in passengers:
  if is_instance_valid(row.actor):
   var p:Vector3=to_local(row.actor.global_position);riders[row.id]=[p.x,p.y,p.z]
 return {"position":[global_position.x,global_position.y,global_position.z],"yaw":rotation.y,"passengers":riders}

func restore(data:Dictionary)->bool:
 var p:Variant=data.get("position")
 if not p is Array or p.size()!=3:return false
 for n:Variant in p:
  if not (n is float or n is int) or not is_finite(float(n)):return false
 var yaw_value:Variant=data.get("yaw",home.basis.get_euler().y)
 if not (yaw_value is float or yaw_value is int):return false
 var at:=Vector3(p[0],p[1],p[2]);var yaw:float=float(yaw_value)
 if not at.is_finite() or not is_finite(yaw) or at.length()>50000:return false
 global_position=at;rotation.y=yaw;velocity=Vector3.ZERO;_set_gate(false,true)
 _keep_above_ground()
 var riders:Variant=data.get("passengers",{})
 if riders is Dictionary:
  for id:Variant in riders:
   var v:Variant=riders[id]
   if not id is String or not v is Array or v.size()!=3 or saved_passengers.size()>=4:continue
   if not v.all(func(n:Variant)->bool:return (n is float or n is int) and is_finite(float(n))):continue
   if contains(to_global(Vector3(v[0],v[1],v[2]))):saved_passengers[id]=v
 return true

func _exit_tree()->void:
 SFX.release_source(self)
 _release_player()
 for id:String in _boarding.keys():_end_boarding(id,false)
 for row:Dictionary in passengers.duplicate():_release_passenger(row)
