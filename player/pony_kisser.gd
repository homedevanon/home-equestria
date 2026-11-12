extends Node
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
## Holding the button arms one kiss, fired when the player's mouth touches a mare's face.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
## His lips from the headset camera (the midpoint between his eyes): about 7 cm below and 2 cm in
## front, the front surface where the lips meet (round 11, dev 2026-09-28: "her mouth WRAPPED around
## mine"). Until then it sat 8 cm in front of his face, so her lips met his in mid-air, in view.
const MOUTH_OFFSET := Vector3(0.0, -0.07, -0.02)
const CONTACT_REACH := 0.055 # Mouth radius plus small headset-fit tolerance, metres.
const COOLDOWN_MS := 0 # Each fresh press is one kiss; holding the button never repeats it.
const VR_ACTION := &"ax_button" # Left X; right A remains jump.
## AnonPony (docs/ANONPONY_DESIGN_2026_10_01.md section 9): she kisses with her own muzzle, and a
## young player (filly or colt) only ever gets the forehead kiss (pony_affection.gd).
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const PONY_FORM := preload("res://player/pony_form.gd")

var camera: Camera3D
var body: Node
var controller: Node
var ponies: Array[Node3D] = []
var _down := false
var _used_hold := false
var _next_kiss_ms := 0
var kisses := 0
var _active: Node
var _hug_down := false
var _hug_used := false
var _hug_absent := 0.0
## Group hug (player bug board #28): other ponies close by who welcome a hug join the one he
## hugs (pony_affection.begin checks each one's trust); they all let go with her.
const GROUP_HUG_REACH := 1.4
var _group_hug: Array[Node] = []
## She started this kiss (relationship_runtime kiss_player): it holds without his button until it
## turns deep; his button press ends it as usual.
var _her_kiss := false
var _face_probe:=SphereShape3D.new()
var _face_query:=PhysicsShapeQueryParameters3D.new()
## Desktop camera near plane, restored after a kiss: her face comes within 5 cm of his eye.
var _near := -1.0
const KISS_NEAR := .01
## Bridal carry (pony_carry.gd cradle): her body stays in his arms and she reaches up to him with
## her neck and a little of her chest (pony_carry.gd kiss_reach_goal); the kiss starts, as ever,
## when their lips touch. His looking up or down must not drag her head round
## after his view: the kiss keeps the view pitch it started with and follows only his turning.
## Looking too far up or down, or her lips falling short of his, ends it instead of clipping.
var _cradle_face := Basis()
var _cradle_locked := false
var _cradle_short := 0.0
var _cradle_time := 0.0
const CRADLE_LIPS_OUT := .012
const CRADLE_LOOK_AWAY := 35.0 # Degrees up or down from where the kiss started.
const CRADLE_MISS := .04 # Metres her lips may fall short of their goal...
const CRADLE_MISS_SECONDS := .35 # ...for this long before she gives up,
const CRADLE_GRACE := 1.2 # once she has had this long to reach up to him.


func setup(view: Camera3D, movement_body: Node, left_controller: Node = null) -> void:
	# Before the navigator (-10) and her Affection (-5): she reads his mouth from this very tick.
	process_physics_priority = -20
	camera = view
	body = movement_body
	controller = left_controller
	if controller != null:
		controller.button_pressed.connect(_pressed)
		controller.button_released.connect(_released)
		if controller.has_method("is_button_pressed"):
			_down = controller.is_button_pressed(VR_ACTION)


func add_pony(pony: Node3D) -> void:
	if pony.has_method("kiss_contact_distance") and not ponies.has(pony): ponies.append(pony)


func _pressed(action: StringName) -> void:
	if action != VR_ACTION or _down: return
	_down = true
	# A deep kiss carries on by itself; pressing again is how he ends it.
	if _deep_kiss() or _her_kiss:
		_used_hold = true
		_end_contact()
		return
	_used_hold = false
	_attempt_held_kiss()


func _released(action: StringName) -> void:
	if action == VR_ACTION:
		_down = false
		if not _deep_kiss() and not _her_kiss: _end_contact()


## A deep kiss (pony_affection.gd): she keeps it going without the button and holds him there.
func _deep_kiss() -> bool:
	return is_instance_valid(_active) and _active.kind == "kiss" and _active.deep


func _input(event: InputEvent) -> void:
	# A GUI may consume key-up after opening a menu; always release the latch.
	if controller == null and event is InputEventKey and event.physical_keycode == KEY_K and not event.pressed:
		_down = false
		if not _deep_kiss() and not _her_kiss: _end_contact()
	if controller == null and event is InputEventKey and event.physical_keycode == KEY_H and not event.pressed:
		_hug_down=false;_hug_used=false;_end_contact()


func _unhandled_input(event: InputEvent) -> void:
	if controller != null or not event is InputEventKey: return
	if event.physical_keycode==KEY_H and not event.echo:
		_hug_down=event.pressed
		if not event.pressed:_hug_used=false;_end_contact()
		get_viewport().set_input_as_handled();return
	if event.physical_keycode != KEY_K or event.echo: return
	if not event.pressed:
		_down = false
		return
	if _down: return
	_down = true
	if _deep_kiss() or _her_kiss:
		_used_hold = true
		_end_contact()
		get_viewport().set_input_as_handled()
		return
	_used_hold = false
	_attempt_held_kiss()
	get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(_delta)
	if started > 0: CPU_PROFILE.record("kisser", started)

func _physics_step(_delta: float) -> void:
	_hug_absent+=_delta
	if not is_instance_valid(camera):_end_contact();return
	if is_instance_valid(body) and (body.get("controls_locked")==true or body.get_meta("knocked_down",false)):
		_down=false;_hug_down=false;_end_contact();return
	if controller!=null and controller.has_method("get_is_active") and not controller.get_is_active():
		_down=false;_end_contact();return
	if controller==null and Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:_end_contact();return
	if is_instance_valid(_active):
		if _active.kind=="hug":_hug_absent=0.0
		var actor:Node3D=_active.mare
		var deep:=_deep_kiss()
		var stay:bool=(_down or deep or _her_kiss) if _active.kind=="kiss" else (_hug_down if controller==null else _embracing(actor))
		var gap:float=actor.kiss_contact_distance(mouth_world(),-camera.global_basis.z.normalized())
		# The kiss IK brings her lips to his; a clear pull-back ends a light kiss. A deep kiss
		# follows him instead (her neck, then her body) until he is well out of reach.
		if _active.kind=="kiss" and not deep and not _her_kiss and not actor.is_held() and gap>.2 and not _touching_heads(mouth_world()).has(actor.get_instance_id()):stay=false
		if actor.global_position.distance_to(camera.global_position)>1.8:stay=false
		if not stay or _active.kind.is_empty():_end_contact()
		elif _cradled(actor):
			var face:=_steady_face()
			# Bridal carried, her head is posed by the reach (pony_carry.gd), not the kiss pose.
			var carry:Object=actor.get("carry")
			var miss:float=float(carry.get("kiss_reach_miss")) if carry!=null and carry.get("kiss_reach_miss")!=null else 0.0
			_cradle_time+=_delta
			_cradle_short=_cradle_short+_delta if miss>CRADLE_MISS and _cradle_time>CRADLE_GRACE else 0.0
			var lips:float=_active.mouth_point().distance_to(_active.target)
			var away:=_looked_away()
			if away or _cradle_short>CRADLE_MISS_SECONDS:
				print("[bridal kiss] ended: %s at t=%.1fs lips-gap=%.1fcm miss=%.1fcm"%["looked away" if away else "out of reach",_cradle_time,lips*100.0,miss*100.0])
				_end_contact()
				return
			_active.target=camera.global_position+face*(MOUTH_OFFSET*preload("res://player/player_mouth.gd").human_scale(camera)+Vector3(0.0,0.0,-CRADLE_LIPS_OUT))
			_active.eye=camera.global_position
			_active.face=face
		else:
			_active.target=mouth_world()
			_active.eye=camera.global_position
			_active.face=camera.global_basis.orthonormalized()
		for joined:Node in _group_hug.duplicate():
			if not is_instance_valid(joined) or joined.kind!="hug" or joined.mare.global_position.distance_to(camera.global_position)>1.8:
				if is_instance_valid(joined) and joined.kind=="hug":joined.end()
				_group_hug.erase(joined);continue
			joined.target=mouth_world();joined.eye=camera.global_position;joined.face=camera.global_basis.orthonormalized()
	_kiss_near((is_instance_valid(_active) and _active.kind=="kiss") or _bridal_reaching())
	# While she holds him in a deep kiss, the move stick does nothing (turning still works).
	if is_instance_valid(body):
		if _deep_kiss():body.set_meta("kiss_hold",true)
		elif body.has_meta("kiss_hold"):body.remove_meta("kiss_hold")
	_attempt_held_kiss()
	if not is_instance_valid(_active):_attempt_hug()


func _attempt_held_kiss() -> void:
	if not _down or _used_hold: return
	if controller != null:
		if controller.has_method("get_is_active") and not controller.get_is_active(): return
	elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if try_kiss(): _used_hold = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_down=false;_hug_down=false;_end_contact()


func mouth_world() -> Vector3:
	var form: Node = PONY_FORM.find(get_tree()) if is_inside_tree() else null
	if form != null and is_instance_valid(form.get("avatar")): return form.mouth_world()
	# Desktop: his mouth below the eye follows Anon's chosen height (player_mouth.gd human_scale).
	var scale_m: float = XRServer.world_scale if camera is XRCamera3D else preload("res://player/player_mouth.gd").human_scale(camera)
	return camera.global_position + camera.global_basis.orthonormalized() * MOUTH_OFFSET * scale_m


func _touching_heads(mouth:Vector3)->Dictionary:
	_face_probe.radius=CONTACT_REACH;_face_query.shape=_face_probe
	_face_query.collision_mask=preload("res://player/head_contact_query.gd").LAYER
	_face_query.transform=Transform3D(Basis.IDENTITY,mouth)
	var touching:Dictionary={}
	for hit:Dictionary in camera.get_world_3d().direct_space_state.intersect_shape(_face_query,16):
		var collider:Node=hit.collider as Node
		if collider!=null:touching[collider.get_parent().get_instance_id()]=true
	return touching

func try_kiss() -> bool:
	if not is_instance_valid(camera) or not camera.is_inside_tree(): return false
	if is_instance_valid(body) and body.get("controls_locked") == true: return false
	if Time.get_ticks_msec() < _next_kiss_ms: return false
	var mouth := mouth_world()
	var forward := -camera.global_basis.z.normalized()
	var touching:Dictionary=_touching_heads(mouth)
	var nearest: Node3D
	var distance := CONTACT_REACH
	for index in range(ponies.size() - 1, -1, -1):
		var pony := ponies[index]
		if not is_instance_valid(pony):
			ponies.remove_at(index)
			continue
		if not pony.is_inside_tree() or not pony.is_visible_in_tree(): continue
		var face: Vector3 = pony.listen_point()
		# Actual mouth/surface contact is authoritative, including tilted cheek/forehead kisses.
		if not touching.has(pony.get_instance_id()) and forward.dot(face-camera.global_position)<=0.0:continue
		var gap: float = pony.kiss_contact_distance(mouth, forward)
		# The fitted skull is convex, not a sphere: cheek/forehead contact counts too.
		if touching.has(pony.get_instance_id()):gap=minf(gap,0.0)
		if gap <= distance:
			nearest = pony
			distance = gap
	if nearest == null: return false
	var affection:Node=nearest.get_node_or_null("Affection")
	if affection==null or not affection.begin("kiss",mouth):
		_used_hold=true # A refusal is one event, never sixty attempts per second.
		return false
	_active=affection if affection.kind=="kiss" else null
	if _active!=null:
		_active.eye=camera.global_position;_active.face=camera.global_basis.orthonormalized()
		if _cradled(nearest):print("[bridal kiss] start gap=%.1fcm"%(nearest.kiss_contact_distance(mouth,forward)*100.0))
	kisses += 1
	_next_kiss_ms = Time.get_ticks_msec() + COOLDOWN_MS
	return true

## A willing adult chooses to kiss him. The same owner drives targets, button cancellation,
## deep-kiss timing and player movement lock for either initiator.
func begin_from_pony(pony: Node3D) -> bool:
	if not is_instance_valid(camera) or not camera.global_position.is_finite(): return false
	if is_instance_valid(_active) or pony.identity == null or pony.identity.filly or pony.sleeping or _young_player(): return false
	if not is_instance_valid(body) or body.get("controls_locked") == true or body.get_meta("knocked_down", false): return false
	if controller != null and controller.has_method("get_is_active") and not controller.get_is_active(): return false
	if controller == null and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return false
	var runtime: Node = pony.get_meta("relationship_runtime") if pony.has_meta("relationship_runtime") else null
	if runtime == null or runtime.bonds.kiss_barred(str(pony.get_meta("relationship_id", ""))): return false
	if pony.global_position.distance_to(camera.global_position) > 1.8: return false
	var affection := pony.get_node_or_null("Affection")
	if affection == null: return false
	affection.eye = camera.global_position; affection.face = camera.global_basis.orthonormalized()
	if not affection.begin("kiss", mouth_world(), true) or affection.kind != "kiss": return false
	_active = affection; _her_kiss = true; _used_hold = true
	return true

## A filly or colt player (world/life/player_form.gd): no pony starts a kiss with them.
func _young_player() -> bool:
	return is_inside_tree() and PLAYER_FORM.is_young(PLAYER_FORM.active(get_tree()))

func _embracing(pony: Node3D) -> bool:
	if pony.get("boop_node")==null or pony.is_held():return false
	# The cheap test first: most ponies are far away.
	if pony.global_position.distance_to(camera.global_position)>=1.5:return false
	var hands:Dictionary=pony.boop_node._hands
	if not is_instance_valid(hands.get("left")) or not is_instance_valid(hands.get("right")):return false
	var sides:Array[float]=[]
	for side:String in ["left","right"]:
		var hand:Node3D=hands[side]
		if hand.get_meta("inventory_busy",false) or hand.get_meta("pony_inspection",false):return false
		var at:Vector3=pony.to_local(hand.global_position)/maxf(float(pony.body_scale),.01)
		if at.y<.3 or at.y>1.1 or at.z<-.65 or at.z>.45 or absf(at.x)>.5:return false
		sides.append(at.x)
	return sides[0]*sides[1]<-.01

func _attempt_hug() -> void:
	if _down:return # A kiss button hold must not also count as an unsolicited hug.
	var candidate:Node3D
	for pony:Node3D in ponies:
		if not is_instance_valid(pony) or not pony.is_inside_tree() or not pony.is_visible_in_tree():continue
		var intent:bool=_hug_down and pony.listen_point().distance_to(camera.global_position)<.85 if controller==null else _embracing(pony)
		if intent:candidate=pony;break
	if candidate==null:
		if _hug_absent>.5:_hug_used=false
		return
	_hug_absent=0.0
	if _hug_used:return
	_hug_used=true
	var affection:=candidate.get_node_or_null("Affection")
	if affection!=null and affection.begin("hug",mouth_world()):
		_active=affection
		SOUNDS.play_at(candidate,"prop_contact_cloth")
		for pony:Node3D in ponies:
			if pony==candidate or not is_instance_valid(pony) or not pony.is_inside_tree() or not pony.is_visible_in_tree():continue
			var flat:=pony.global_position-camera.global_position;flat.y=0.0
			if flat.length()>GROUP_HUG_REACH:continue
			var joining:Node=pony.get_node_or_null("Affection")
			if joining!=null and joining.kind.is_empty() and joining.begin("hug",mouth_world()):_group_hug.append(joining)
		if not _group_hug.is_empty():print("[hug] group hug: %d join %s"%[_group_hug.size(),candidate.name])

## Compatibility entry point for callers of the original AI-kiss implementation.
func kiss_from_pony(pony: Node3D) -> bool:
	return begin_from_pony(pony)

## She is bridal carried (pony_carry.gd cradle_goal).
func _cradled(actor: Node) -> bool:
	var carry: Object = actor.get("carry") if is_instance_valid(actor) else null
	return carry != null and carry.get("cradle_goal") == true

## A bridal-carried pony reaching up to his lips (pony_carry.gd kiss_reach): her muzzle comes as
## close to his eyes as in a kiss, so the near plane drops for it too.
func _bridal_reaching() -> bool:
	for pony: Node3D in ponies:
		if not is_instance_valid(pony) or not pony.has_method("is_held") or not pony.is_held(): continue
		var carry: Object = pony.get("carry")
		if carry != null and carry.get("kiss_reach") != null and float(carry.get("kiss_reach")) > 0.0: return true
	return false

## His view at the kiss's start, turned only as far as he has turned since.
func _steady_face() -> Basis:
	var view := camera.global_basis.orthonormalized()
	var heading := Basis(Vector3.UP, view.get_euler().y)
	if not _cradle_locked:
		_cradle_face = heading.inverse() * view
		_cradle_locked = true
	return heading * _cradle_face

## His view now pitched more than CRADLE_LOOK_AWAY from the kiss's start (turning doesn't count).
func _looked_away() -> bool:
	if not _cradle_locked: return false
	var view := camera.global_basis.orthonormalized()
	var now := Basis(Vector3.UP, view.get_euler().y).inverse() * view
	return rad_to_deg((-now.z).angle_to(-_cradle_face.z)) > CRADLE_LOOK_AWAY

func _end_contact() -> void:
	if is_instance_valid(_active):_active.end()
	for joined:Node in _group_hug:
		if is_instance_valid(joined) and joined.kind=="hug":joined.end()
	_group_hug.clear()
	_active=null;_her_kiss=false;_cradle_locked=false;_cradle_short=0.0;_cradle_time=0.0
	if is_instance_valid(body) and body.has_meta("kiss_hold"):body.remove_meta("kiss_hold")
	_kiss_near(false)

## The desktop camera's 5 cm near plane would cut her face during a kiss; the headset's is 1 cm.
func _kiss_near(on: bool) -> void:
	if not is_instance_valid(camera) or camera is XRCamera3D:return
	if on and _near<0.0:
		_near=camera.near;camera.near=minf(camera.near,KISS_NEAR)
	elif not on and _near>=0.0:
		camera.near=_near;_near=-1.0

func _exit_tree() -> void:
	_end_contact()
