extends Node
## Contact-driven affectionate response. Leaves XR tracking and the pony's mesh intact.
## A young player (AnonPony filly or colt, world/life/player_form.gd) is never kissed romantically:
## every pony gives them the filly's forehead kiss, never starts a kiss and never deepens one.
const PLAYER_FORM := preload("res://world/life/player_form.gd")
var mare: Node3D
var pose: SkeletonModifier3D
var kind := ""
var target := Vector3.ZERO
var amount := 0.0
var elapsed := 0.0
var afterglow_left := 0.0
var _return_kiss := false
var _return_serial := 0
var _landing := false
var _buck_time := -1.0
var _buck_player: CharacterBody3D
var _buck_hit := false
var _buck_work := false
var _fidget := ""
var _fidget_time := -1.0
const FIDGET_SECONDS := {"stretch": 2.6, "yawn": 2.2}
var _owner := ""
var _wander := true
var _claimed_nav := false
## Deep kiss (dev 2026-09-28): a returned kiss held past DEEP_AFTER. She presses in with a slow
## jaw rhythm, eyes mostly shut, varied kiss sounds and now and then a soft "mm" in her voice.
const DEEP_AFTER := .6
var deep := false
var initiated_by_pony := false
var _next_smack := 0.0
var _next_hum := 0.0
## Once deep (dev 2026-09-28) she keeps the kiss going without the button and ends it herself
## after DEEP_MIN-DEEP_MAX s. Now and then she draws back, gazes at him half-lidded and breathes
## softly, then kisses him again.
const DEEP_MIN := 10.0
const DEEP_MAX := 24.0
var _deep_left := 0.0
var _pause := -1.0
var _pause_length := 0.0
var _next_pause := 0.0
var _next_breath := 0.0
## Her body follows him through a kiss (round 11, dev 2026-09-28: "MOVING towards me with her
## neck and her body and her legs"): she turns in place once his eyes are body_turn degrees off her
## line (seen from the root of her neck), until they are within TURN_DONE, and walks straight
## closer at WALK_SPEED once her lips would have to reach step_after metres forward, until
## STEP_DONE (affection_pose.gd neck_demand). Her head sits almost over her turning axis, so a turn
## unloads her neck's swing; it cannot move her lips sideways. Her neck does that.
const TURN_DONE := deg_to_rad(6.0)
const STEP_DONE := .025
## Backing up during a kiss stops once her neck gives back no more than this (metres).
const BACK_DONE := .01
## Seconds he must keep leaning in before she backs up.
const BACK_WAIT := .3
const WALK_SPEED := .3
var _turning := false
var _stepping := false
var _backing := false
var _back_wait := 0.0
var _steered := false
## Anon's eye and facing while kissing (pony_kisser.gd), for the kiss IK's clearance.
var eye := Vector3.INF
var face := Basis.IDENTITY

func _ready() -> void:
	pose=preload("res://world/relationships/affection_pose.gd").new()
	pose.name="AffectionPose";pose.mare=mare;mare.skeleton.add_child(pose)
	set_process(false);set_physics_process(false)
	process_priority=20
	# After the navigator (-10), which halts her every tick while she is claimed, and before her
	# own locomotion (0): what the kiss asks of her body is what she does this tick.
	process_physics_priority=-5

func mouth_point() -> Vector3:
	var sk: Skeleton3D=mare.boop_node.head_skeleton
	var bone:=sk.find_bone("mFaceLipUpperCenter")
	if bone<0:bone=sk.find_bone("mFaceNoseBase")
	return sk.global_transform*sk.get_bone_global_pose(bone).origin

## by_her: her own intention, rechecked for adult/willing status; no reaction event about him.
func begin(value: String, point: Vector3, by_her := false) -> bool:
	if value not in ["kiss","hug"]:return false
	# A spa client on the table is a customer, not a date (M-SPA-03; spa_customers._end_affection
	# stays the fallback): no kiss or hug, and no bonds contact recorded first.
	if is_instance_valid(mare) and mare.has_meta("spa_client"):return false
	var runtime: Node=(mare.get_meta("relationship_runtime") if mare.has_meta("relationship_runtime") else null)
	if value=="kiss" and by_her:
		if mare.sleeping or mare.identity.filly or _young_player() or _buck_time>=0 or runtime==null:return false
		if runtime.bonds.kiss_barred(str(mare.get_meta("relationship_id", ""))):return false
		mare.boop_node.play_kiss()
		mare.expressions.fluster(1.0)
	elif value=="kiss":
		# Physical contact always happens on the button; willingness controls the response.
		mare.boop_node.play_kiss()
		if mare.sleeping:return true
		# A filly gets a forehead kiss: no romance check, no pose, just a happy little fluster. So
		# does a young player, from every pony.
		if mare.identity.filly or _young_player():
			mare.expressions.fluster(.8);mare.physical_reaction.emit("kiss");return true
		var reciprocates:bool=runtime!=null and runtime.affection_allowed(mare,value)
		mare.physical_reaction.emit("kiss" if reciprocates else "kiss_refused")
		# An unwelcome kiss: she turns her face away. Only pressing on after being refused within
		# half a minute earns a buck; bucking is a last resort (dev 2026-09-28).
		if not reciprocates and runtime!=null and runtime.bonds.refused_again(str(mare.get_meta("relationship_id","")),"kiss"):
			buck(runtime.game.inventory.player_body)
		if not reciprocates or _buck_time>=0:return true
		mare.expressions.fluster(1.0)
	elif _buck_time>=0 or mare.identity.filly or mare.sleeping or mare.is_speaking() or mare.is_held() or runtime==null or not runtime.affection_allowed(mare,value):return false
	else:mare.physical_reaction.emit("hug")
	cancel_afterglow()
	_landing=false
	if value=="kiss":
		var director := get_tree().get_first_node_in_group("conversation_director")
		if director != null: director.kiss_started(str(mare.identity.id))
		mare.stop_speaking()
	kind=value;target=point;elapsed=0.0;deep=false;initiated_by_pony=by_her
	# The pose binds these against the modified head it actually moves (affection_pose.gd).
	pose.bind_mouth=mouth_point()
	pose.begin_contact(value=="kiss")
	pose.reach=pose.REACH
	if value=="kiss":
		pose.bind_skull=mare.boop_node.skull_world()
		pose.bind_nose=mare.boop_node.nose_world()
		var head_scale:float=mare.boop_node.head_skeleton.global_basis.get_scale().x
		pose.skull_radius=mare.boop_node.SKULL_RADIUS*maxf(head_scale,.01)
		pose.sample_hair()
		if mare.is_held():pose.sample_face()
	_claim()
	set_process(true);set_physics_process(true)
	return true

func end() -> void:
	var kissed := kind=="kiss"
	var return_later := kissed and not initiated_by_pony
	if kissed:
		afterglow_left=60.0; _return_kiss=return_later; _return_serial+=1
	kind="";deep=false;initiated_by_pony=false;pose.reach=pose.REACH;pose.press=0.0;pose.kissing=false;eye=Vector3.INF
	_pause=-1.0;pose.pause=0.0
	if is_instance_valid(mare):mare.expressions.stare(afterglow_left>0.0, .5)
	_steer_stop()
	_landing=pose._rear_now>.001
	if not _landing:_release()

func _young_player() -> bool:
	return is_inside_tree() and PLAYER_FORM.is_young(PLAYER_FORM.active(get_tree()))

## True while her face may be right against his (a kiss or its release easing out); the eye guard
## then leaves her head to the kiss IK (pony_head_guard.gd).
func kissing_face() -> bool:
	return kind=="kiss" or (is_instance_valid(pose) and pose.kiss_face()) or _bridal_reach()

## Bridal carried and reaching up to kiss him (pony_carry.gd kiss_reach): her face is meant to come
## to his, so the eye guard treats it as a kiss face.
func _bridal_reach() -> bool:
	var carry: Object = mare.get("carry") if is_instance_valid(mare) else null
	return carry != null and carry.get("kiss_reach") != null and float(carry.get("kiss_reach")) > 0.0

func _claim() -> void:
	if _claimed_nav:return
	var nav:=mare.get_node_or_null("Navigator")
	_claimed_nav=false
	if nav!=null and not mare.is_held() and not mare.get_meta("cuddle_active",false):
		_owner=nav.command_owner;_wander=nav.wander_enabled
		nav.stay();nav.command_owner="affection";nav.wander_enabled=false
		_claimed_nav=true
	mare.set_meta("affection_active",true)

func _release() -> void:
	var nav:=mare.get_node_or_null("Navigator")
	if _claimed_nav and nav!=null and nav.command_owner=="affection":
		nav.stay();nav.command_owner=_owner;nav.wander_enabled=_wander
		# Persistent follow commands will refresh their route on their next tick.
	_claimed_nav=false
	mare.remove_meta("affection_active")

func _process(delta: float) -> void:
	if not is_instance_valid(mare):return
	_advance_afterglow(delta)
	if _landing:
		if pose._rear_now<=.001:_landing=false;_release()
		else:mare.stop()
	if not kind.is_empty() and (mare.sleeping or (mare.is_held() and kind!="kiss") or (kind!="kiss" and mare.is_speaking())):end()
	# A kiss eases in over 0.6 s: her face comes to his rather than snapping.
	amount=move_toward(amount,0.0 if kind.is_empty() else 1.0,delta/(.6 if kind=="kiss" else .3))
	elapsed+=delta
	pose.amount=amount;pose.target=target;pose.eye=eye;pose.face=face;pose.deep=deep
	if kind=="kiss":_deep_kiss(delta)
	if amount>.001:
		# One gentle settling motion, not a repeated speech-viseme loop.
		var settle:=sin(clampf(elapsed/.7,0.0,1.0)*PI)
		var flutter:=.05*pow(maxf(0.0,sin(elapsed*TAU*4.0)),2.0) if elapsed<.65 else 0.0
		# A deep kiss leaves the lids to the flustered loop: shut, a rare peek, shut again.
		mare.expressions.touch("affection",.25*amount,(0.0 if deep else 1.0-flutter)*amount)
		if deep:
			var jaw:=.5+.5*sin(elapsed*TAU*.8)
			mare.head.mouth.set_expression("pout",(.35-.15*jaw)*amount)
			mare.head.mouth.set_expression("open_soft",(.08+.3*jaw)*amount)
		else:
			mare.head.mouth.set_expression("pout",.18*amount if kind=="kiss" else 0.0)
			mare.head.mouth.set_expression("open_soft",.025*settle*amount if kind=="kiss" else 0.0)
		# A kiss is steered by the kiss IK alone; the head look would pitch her face down to his lips.
		if kind!="kiss":
			var local:Vector3=mare.global_basis.inverse()*(target-mare.listen_point())
			var angles:=Vector3(clampf(atan2(local.y,Vector2(local.x,local.z).length()),-.25,.3),clampf(atan2(-local.x,-local.z),-.5,.5),deg_to_rad(4.0)*amount)
			mare.secondary.look_toward(angles,.2)
		else:mare.secondary.look_toward(Vector3.ZERO,.2)
	else:
		mare.expressions.release_touch("affection")
		mare.head.mouth.set_expression("pout",0.0);mare.head.mouth.set_expression("open_soft",0.0)
		if _buck_time<0 and _fidget_time<0 and afterglow_left<=0.0 and not _landing:set_process(false);set_physics_process(false)

## Her eyes linger after contact; only a player-started kiss schedules the one return invitation.
func _advance_afterglow(delta: float) -> void:
	if afterglow_left<=0.0: return
	var runtime: Node=mare.get_meta("relationship_runtime") if mare.has_meta("relationship_runtime") else null
	var id := str(mare.identity.id)
	if mare.sleeping or _buck_time>=0 or (runtime!=null and runtime.bonds!=null and not runtime.bonds.welcomes(id,"kiss")):
		cancel_afterglow(); return
	afterglow_left=maxf(0.0,afterglow_left-delta)
	mare.expressions.stare(true,.5)
	if afterglow_left>0.0:return
	mare.expressions.stare(false)
	if _return_kiss and runtime!=null and runtime.has_method("invite_after_kiss"):
		runtime.invite_after_kiss(id,_return_serial)
	_return_kiss=false

func cancel_afterglow() -> void:
	afterglow_left=0.0; _return_kiss=false; _return_serial+=1
	if is_instance_valid(mare):mare.expressions.stare(false)

func _deep_kiss(delta: float) -> void:
	if not deep:
		if elapsed<DEEP_AFTER or _young_player():return
		deep=true;_next_smack=randf_range(1.5,3.0);_next_hum=randf_range(6.0,10.0)
		_deep_left=randf_range(DEEP_MIN,DEEP_MAX);_next_pause=randf_range(3.5,7.0)
		mare.physical_reaction.emit("deep_kiss")
	_deep_left-=delta
	if _deep_left<=0.0 and _pause<0.0:end();return
	if _breather(delta):return
	mare.expressions.fluster(.5,false)
	# Soft single kisses now and then, not a machine gun of smacks (dev 2026-09-28: "the sound
	# effects suck"), and an occasional quiet "mm".
	_next_smack-=delta
	if _next_smack<=0.0:
		mare.boop_node.play_kiss(-29.0,true);_next_smack=randf_range(2.5,5.0)
	_next_hum-=delta
	if _next_hum<=0.0:
		# A rare, barely-there "mm" (dev 2026-09-28: "way way quieter and way less frequent").
		_next_hum=randf_range(8.0,16.0)
		var voice:Node=mare.vocal() if mare.has_method("vocal") else null
		if voice!=null and randf()<.3:voice.play(str(mare.identity.id),"m",mare.boop_node.snoot,-32.0)

## A breather: she draws back a little, gazes at him half-lidded and breathes, then kisses again.
## True while it lasts (no smacks or hums then).
func _breather(delta: float) -> bool:
	if _pause<0.0:
		_next_pause-=delta
		if _next_pause>0.0:return false
		if randf()>.6:_next_pause=randf_range(2.0,4.0);return false
		_pause=0.0;_pause_length=randf_range(1.2,2.3);_next_breath=randf_range(.1,.4)
	_pause+=delta
	# Ease back over 0.35 s, hold the gaze, lean in again over 0.45 s.
	pose.pause=smoothstep(0.0,.35,_pause)*(1.0-smoothstep(_pause_length-.45,_pause_length,_pause))
	mare.expressions.stare(_pause<_pause_length-.3,.5)
	_next_breath-=delta
	if _next_breath<=0.0:
		mare.boop_node.play_breath();_next_breath=randf_range(.9,1.4)
	if _pause>=_pause_length:
		_pause=-1.0;pose.pause=0.0;_next_pause=randf_range(4.0,10.0)
		mare.expressions.stare(false)
		return false
	return true

## Her body carries what her neck should not: she turns in place to face him, and walks closer
## with real steps when her lips would have to reach too far. Runs each physics tick after the
## navigator's halt and before her locomotion reads its request. No backing gait exists: when he
## presses in, her neck leans back instead.
func _steer() -> void:
	var settings:Dictionary=pose.kiss_settings()
	var start:=deg_to_rad(float(settings.body_turn))
	var step_after:=float(settings.step_after)
	if kind!="kiss" or not eye.is_finite() or not pose.neutral_lips.is_finite() or not pose.neck_base.is_finite() or mare.is_held() or mare.sleeping or _buck_time>=0 \
			or not mare.has_method("face_direction") or not mare.grounded() or pose._rear_now>.001:
		_steer_stop();return
	if pose.rear_wanted and pose.rear_step_ahead<=.025:
		_steer_stop();return
	var forward:Vector3=-mare.global_basis.z;forward.y=0.0;forward=forward.normalized()
	var demand:Vector3=pose.neck_demand;demand.y=0.0
	var to_him:Vector3=eye-pose.neck_base;to_him.y=0.0
	var yaw:=forward.signed_angle_to(to_him,Vector3.UP) if to_him.length()>.05 else 0.0
	_turning=start>0.0 and absf(yaw)>(TURN_DONE if _turning else start)
	var ahead:float=pose.rear_step_ahead if pose.rear_wanted else demand.dot(forward)
	_stepping=step_after>0.0 and ahead>(STEP_DONE if _stepping else step_after)
	# He leans into her: her neck gives only BACK_GIVE (affection_pose.gd), then she steps back
	# with a real backward walk (pony_locomotion.gd back_up), never turning away from him.
	# Only a lean that lasts (BACK_WAIT): the press as a kiss lands is not him pushing in.
	var pushed:bool=not pose.rear_wanted and mare.has_method("back_up") and ahead<-(BACK_DONE if _backing else pose.BACK_GIVE)
	_back_wait=_back_wait+get_physics_process_delta_time() if pushed else 0.0
	_backing=pushed and (_backing or _back_wait>=BACK_WAIT)
	# His hands on her (petting) must not freeze her through a kiss (pony_locomotion.gd).
	mare.set("steer_through_touch",true)
	if _turning:
		mare.face_direction(to_him.normalized());_steered=true
	elif _stepping:
		mare.set_desired_velocity(forward*WALK_SPEED);_steered=true
	elif _backing:
		mare.back_up(WALK_SPEED);_steered=true
	elif _steered:
		mare.stop();_steered=false

## One line every 2 s in the game log while kissing (dev 2026-09-28: proof the head motion runs
## in the real game, not only in the lab): wander angles, lip gap, lag state, body turn/step.
var _log_left := 0.0
func _log_kiss(delta: float) -> void:
	_log_left-=delta
	if _log_left>0.0:return
	_log_left=2.0
	var his:=face.orthonormalized()
	# Angles in the pose's own convention: turn/nod/tilt about his axes from "facing him".
	var facing:Basis=pose._frame(his.z,his.y)*pose._frame(pose._head_forward,pose._head_up).inverse()
	var e:=(his.inverse()*Basis(pose._aim)*facing.inverse()*his).get_euler()
	print("[kiss] %s deep=%s lips-gap=%.1fcm head turn/nod/tilt=%.0f/%.0f/%.0f° limited=%.0f° wander=%.2f turning=%s stepping=%s side=%.1f pause=%.2f held=%s rear=%.1f° initiator=%s"%[str(mare.identity.id) if mare.get("identity")!=null else mare.name,str(deep),mouth_point().distance_to(target)*100.0,rad_to_deg(e.y),rad_to_deg(e.x),rad_to_deg(e.z),rad_to_deg(pose.limited),pose._motion,str(_turning),str(_stepping),pose._side_now,pose.pause,str(mare.is_held()),rad_to_deg(pose._rear_now),"pony" if initiated_by_pony else "player"])

func _steer_stop() -> void:
	if _steered and is_instance_valid(mare):mare.stop()
	_steered=false;_turning=false;_stepping=false;_backing=false
	if is_instance_valid(mare):mare.set("steer_through_touch",false)

func buck(player: CharacterBody3D) -> bool:
	if not is_instance_valid(player) or _buck_time>=0 or mare.is_held() or mare.sleeping or not mare.grounded():return false
	if player.global_position.distance_to(mare.global_position)>2.4 or mare.posture_status().requested!="stand":return false
	if player.get("controls_locked")==true:return false
	end();cancel_afterglow();_claim();_buck_player=player;_buck_time=0.0;_buck_hit=false
	set_process(true);set_physics_process(true)
	return true

## A work buck (day action split_wood.gd): the same accepted rear-leg kick with no player, no
## turning and no knockback. The caller holds her navigation lease, faces her first and judges
## contact itself; buck_time() is the kick's clock (-1 when idle), peak at about 0.85 s.
func work_buck() -> bool:
	if _buck_time>=0 or not kind.is_empty() or afterglow_left>0.0 or mare.is_held() or mare.sleeping or not mare.grounded():return false
	if mare.posture_status().requested!="stand":return false
	_buck_work=true;_buck_player=null;_buck_time=0.0;_buck_hit=false
	set_process(true);set_physics_process(true)
	return true

## An idle fidget (world/characters/hybrid_mare/hybrid_fidgets.gd): "stretch" (one hind leg
## stretched back) or "yawn" (head up, mouth open, eyes shut). Only from a settled stand with
## nothing else on her; anything that touches her ends it (fidget_active() turns false).
func fidget(what: String, left := true) -> bool:
	if not FIDGET_SECONDS.has(what) or _fidget_time>=0 or _buck_time>=0 or not kind.is_empty() or afterglow_left>0.0:return false
	if mare.is_held() or mare.sleeping or not mare.grounded() or mare.is_speaking():return false
	var status:Dictionary=mare.posture_status()
	if status.requested!="stand" or not bool(status.get("settled",true)):return false
	_fidget=what;_fidget_time=0.0;pose.stretch_left=left
	set_process(true);set_physics_process(true)
	return true

func fidget_active() -> bool:
	return _fidget_time>=0

func cancel_fidget() -> void:
	if _fidget_time>=0:_end_fidget()

func _advance_fidget(delta: float) -> void:
	if mare.is_held() or mare.sleeping or not mare.grounded() or mare.is_speaking() or not kind.is_empty() or _buck_time>=0 or mare.actual_speed>.08:
		_end_fidget();return
	_fidget_time+=delta
	var total:float=FIDGET_SECONDS[_fidget]
	var ease_in:=smoothstep(0.0,total*.3,_fidget_time)
	var ease_out:=1.0-smoothstep(total*.7,total,_fidget_time)
	var a:=minf(ease_in,ease_out)
	if _fidget=="stretch":pose.stretch_amount=a
	else:
		pose.yawn_amount=a
		# Eyes shut through the face's own touch channel; the jaw drops wide (sneeze "open") and soft.
		if mare.get("expressions")!=null:mare.expressions.touch("yawn",0.0,a)
		if mare.get("head")!=null and mare.head.mouth!=null:
			mare.head.mouth.set_expression("open",a);mare.head.mouth.set_expression("open_soft",.7*a)
	if _fidget_time>=total:_end_fidget()

func _end_fidget() -> void:
	if _fidget=="yawn":
		if mare.get("expressions")!=null:mare.expressions.release_touch("yawn")
		if mare.get("head")!=null and mare.head.mouth!=null:
			mare.head.mouth.set_expression("open",0.0);mare.head.mouth.set_expression("open_soft",0.0)
	_fidget="";_fidget_time=-1.0;pose.stretch_amount=0.0;pose.yawn_amount=0.0

func buck_time() -> float:
	return _buck_time

func cancel_work_buck() -> void:
	if _buck_work and _buck_time>=0:_finish_buck()

func _physics_process(delta: float) -> void:
	# The kisser (pony_kisser.gd) writes his mouth, eye and face every physics tick; hand them to
	# the pose in the same tick, before the skeleton's modifiers run.
	if kind=="kiss":
		pose.target=target;pose.eye=eye;pose.face=face;pose.deep=deep
		_steer()
		_log_kiss(delta)
	elif _steered:_steer_stop()
	if _fidget_time>=0:_advance_fidget(delta)
	if _buck_time<0:return
	if _buck_work:
		if mare.is_held() or mare.sleeping or not mare.grounded():_finish_buck();return
		_buck_time+=delta
		pose.buck_amount=sin(clampf((_buck_time-.55)/.6,0.0,1.0)*PI)
		if _buck_time>1.3:_finish_buck()
		return
	if not is_instance_valid(_buck_player) or mare.is_held() or mare.sleeping:
		_finish_buck();return
	_buck_time+=delta
	var toward:Vector3=_buck_player.global_position-mare.global_position;toward.y=0.0
	if _buck_time<.55 and toward.length()>.05:
		mare.rotation.y=rotate_toward(mare.rotation.y,atan2(toward.x,toward.z),delta*5.0)
	pose.buck_amount=sin(clampf((_buck_time-.55)/.6,0.0,1.0)*PI)
	if _buck_time>=.8 and not _buck_hit:
		_buck_hit=true
		if toward.length()<2.4 and toward.normalized().dot(mare.global_basis.z.normalized())>.65:
			var query:=PhysicsRayQueryParameters3D.create(mare.global_position+Vector3.UP*.6,_buck_player.global_position+Vector3.UP*.6,1,[mare.get_rid(),_buck_player.get_rid()])
			if mare.get_world_3d().direct_space_state.intersect_ray(query).is_empty() and _buck_player.has_method("receive_buck"):
				_buck_player.receive_buck(toward.normalized()*5.5+Vector3.UP*2.2)
	if _buck_time>1.3:_finish_buck()

func _finish_buck() -> void:
	var work:=_buck_work
	_buck_work=false
	_buck_time=-1.0;pose.buck_amount=0.0;_buck_player=null
	# A work buck never claimed her navigation: the day action holds it.
	if not work:_release()

func _exit_tree() -> void:
	if is_instance_valid(mare):
		mare.expressions.release_touch("affection")
		mare.head.mouth.set_expression("pout",0.0);mare.head.mouth.set_expression("open_soft",0.0)
		_release()
	if is_instance_valid(pose):pose.queue_free()
