extends Node3D
## Drives the Anon avatar's IK targets from the VR rig.
##
## Tracked points (mainspring's pattern, minus its placement module):
##   head target  <- XRCamera3D, offset back from the eyes to the head bone
##   hand targets <- tracked controllers, with the measured wrist/palm offset;
##                   torso/shoulders/arms compensate, never the tracked endpoint
##   hip target   <- hangs below the head at spine length, yawed with the view
##   foot targets <- planted on this node's floor plane and stepped toward
##                   their ideal spot under the hips, alternating
##
## RenIKPlacement was tried and removed: it gravity-drops the armature when
## its ground rays miss and reorients hips when it decides the player is
## lying down. The player body already owns grounding.
##
## Three things this file decides on its own, because nothing tracks them:
##   * height: the model is scaled so its eyes sit where the headset does,
##     measured from the tallest steady head height seen (calibrate()
##     re-measures on demand);
##   * sitting: when the head drops well below that height for a moment the
##     legs collapse away (BodyPartHide), since a standing pair of legs under
##     a seated player is worse than none;
##   * mode: FULL shows the body; HANDS hides it and hands the visuals back
##     to the xr-kit gloves. ARMS (c_hands-style forearms) is future work.
##
## Assign sources at runtime (game.gd or the rig scene) via setup().

const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
enum BodyMode { FULL, HANDS }

## A foot has just landed (or, while gliding, a stride's worth of travel
## passed). World position of the contact, for footstep audio.
signal stepped(world_position: Vector3)

## Eye height of the unscaled model: the point between the eyebrows, from the
## face profile measured by tools/probe_anon_hand_offsets.gd (head bone rest
## at y 1.631, brow surface at y 1.72, 8.3 cm in front of the bone).
const MODEL_EYE_HEIGHT := 1.72
## The converted rig rests facing +Z; the IK composes targets with the rest
## orientation, so every yaw target carries this half turn.
const REST_FACING := Basis(Vector3.UP, PI)
## Native skinned fingertip-cap centroids, measured by audit_anon_fingertips.gd.
const INDEX_CAP := {"left":Vector3(.031052,.007872,.001548),"right":Vector3(.032006,.009204,.003748)}
## Head height below this fraction of the calibrated standing height counts
## as sitting or crouching once it has held for `seated_delay`.
const SEATED_FRACTION := 0.72
## Above this hip speed the feet glide instead of stepping; the legs are
## barely in view while sprinting and rapid alternate steps read as flailing.
const STEP_MAX_SPEED := 1.5

## Camera sits between the eyebrows; camera-local offset from there to the
## head bone (down and back).
@export var head_offset := Vector3(0, -0.089, 0.083)
## Desktop only: how much further forward (camera-local, metres at scale 1) the body sits under
## the eye than head_offset puts it. The camera itself never moves.
@export var desktop_body_forward := 0.05
## Head-to-hip drop when standing straight (measured spine length + neck).
@export var hip_drop := 0.652
## Lateral distance from the hips to each planted foot.
@export var feet_spread := 0.11
## Rotation from the physics hand frame to the hand bone, per hand. The rest
## pose is a palms-down T-pose (left fingers +X, right fingers -X, palms -Y);
## an identity controller means fingers forward (-Z), palm inward, thumb up.
## The controller pose is the palm; the hand BONE is the wrist, ~7 cm behind
## it along the controller's +Z (dev, round 5: hands stopped short).
@export var left_hand_offset := Transform3D(Basis(Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)), Vector3(0.0, 0.0, 0.07))
@export var right_hand_offset := Transform3D(Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)), Vector3(0.0, 0.0, 0.07))
@export var body_mode := BodyMode.FULL:
	set(value):
		body_mode = value
		_apply_mode()
@export var seated_delay := 0.4
## A foot steps once its planted spot drifts this far from where the hips
## want it, or the hips have yawed this far past it.
## Longer strides and a floor on the time between landings: 0.24 m read as a
## goblin shuffle (dev, 2026-09-07).
@export var step_distance := 0.32
@export var min_step_interval := 0.2
var _step_cooldown := 0.0
@export var step_yaw_degrees := 64.0
@export var step_seconds := 0.28
@export var step_height := 0.05

## Calibrated standing eye height in rig space; 0 until measured.
var standing_eye_height := 0.0
var seated := false
## Set while the player sits on a seat in VR (the rig is lowered, so head height alone would
## read as standing): hides the legs like a detected sit.
var force_seated := false
## A physical couch supplies untracked torso/foot targets. Head and hands remain observed.
var couch_rest_frame: Node3D
var couch_rest_amount := 0.0
var _couch_company := 0.0
var model_scale := 1.0

var _camera: Node3D
var _left_hand: Node3D
var _right_hand: Node3D
var _tall_seconds := 0.0
var _tall_height := 0.0
var _low_seconds := 0.0
var _leg_hide: SkeletonModifier3D
var _model: Node3D
var _gloves: Array[Node] = []
var _last_hip := Vector3.INF
var _hip_speed := 0.0
# Per foot: planted world position, step start, step goal, step progress.
var _feet: Array[Dictionary] = []
## Clothing binds the rig's flight state once, not a scene lookup during IK.
var wing_flight: RefCounted
# World transforms that replace the physics hands while something (the
# pony grabber) parks a hand elsewhere; null follows the physics hand.
var _hand_override: Dictionary = {"left": null, "right": null}
## Grip closes the hand. Finger bones curl about their local -Z, the axis that
## moves the fingertips toward the palm on this rig (tools/probe_finger_axis.gd).
@export var fist_angle := 80.0
## Relaxed hand: a little curl and a little spread, so an open hand does not
## read as a stiff rig pose. Both fade out as the grip closes.
@export var rest_curl := 14.0
@export var rest_splay := 4.0
var _grip: Dictionary = {"left": 0.0, "right": 0.0}
var _trigger: Dictionary = {"left": 0.0, "right": 0.0}
var _grip_input: Dictionary = {"left": null, "right": null}
var _trigger_input: Dictionary = {"left": null, "right": null}
var _skeleton: Skeleton3D
var _finger_bones: Dictionary = {"left": [], "right": []}
var _interaction_bones: Dictionary = {}
var _interaction_hands: Dictionary = {}
var _forearm_back: Dictionary = {}
var _forearm_clearance: Dictionary = {}
signal interaction_hands_updated
var _glide_travel := 0.0
var _body_yaw := 0.0
var _yaw_initialized := false
## Optional desktop animation provider. It adjusts inferred torso targets only;
## tracked VR sources never receive these authored action poses.
var desktop_pose_driver: Node3D

@onready var _head_target: Node3D = %HeadTarget
@onready var _hip_target: Node3D = %HipsTarget
@onready var _left_target: Node3D = %LeftHandTarget
@onready var _right_target: Node3D = %RightHandTarget
@onready var _left_foot: Node3D = %LeftFootTarget
@onready var _right_foot: Node3D = %RightFootTarget


func _ready() -> void:
	_model = get_node_or_null("Model")
	_leg_hide = find_child("LegHide", true, false) as SkeletonModifier3D
	_skeleton = find_child("Skeleton3D", true, false) as Skeleton3D
	# Unclothed base plus separate garments, fully dressed until a wardrobe says otherwise.
	preload("res://world/customization/anon_garments.gd").assemble(self)
	_load_calibration()
	var settings := get_node_or_null("/root/Settings")
	if settings != null and settings.has_signal("changed"): settings.changed.connect(_on_setting_changed)
	if _skeleton != null:
		for side: String in ["left", "right"]:
			var prefix := side.capitalize()
			var bones: Array = []
			# Entries: bone, curl weight, splay weight, is_index. Splay about local Y
			# spreads the index toward the thumb and the ring away; the sign
			# mirrors between hands (probe_finger_axis.gd).
			var outward := -1.0 if side == "left" else 1.0
			var splays := {"Index": outward, "Middle": 0.0, "Ring": -outward, "Little": -1.6 * outward}
			for finger: String in ["Index", "Middle", "Ring", "Little"]:
				for seg: String in ["Proximal", "Intermediate", "Distal"]:
					var b := _skeleton.find_bone(prefix + finger + seg)
					if b >= 0:
						bones.append([b, 1.0, splays[finger] if seg == "Proximal" else 0.0, finger == "Index"])
			for seg: String in ["Metacarpal", "Proximal", "Distal"]:
				var b := _skeleton.find_bone(prefix + "Thumb" + seg)
				if b >= 0:
					# Thumb curls the other way about its local Z (dev: "the
					# thumb goes OUT instead of in").
					bones.append([b, -0.45, 0.0, false])
			_finger_bones[side] = bones
			var ids:Array[int]=[]
			for part in ["IndexDistal","Hand","IndexProximal","LittleProximal","MiddleProximal","LowerArm"]:
				ids.append(_skeleton.find_bone(prefix+part))
			if -1 not in ids:
				_interaction_bones[side]=ids
				var rest_points:Array[Vector3]=[]
				for bone:int in ids:rest_points.append(_skeleton.get_bone_global_rest(bone).origin)
				var rest_back:Vector3=-(rest_points[2]-rest_points[3]).cross(rest_points[4]-rest_points[1]).normalized()*(1. if side=="left" else -1.)
				_forearm_back[side]=_skeleton.get_bone_global_rest(ids[5]).basis.inverse()*rest_back
				_forearm_clearance[side]=_measure_forearm_shell(ids,rest_back)
		_skeleton.skeleton_updated.connect(_cache_interaction_hands)
	for i in 2:
		_feet.append({"planted": Vector3.INF, "from": Vector3.ZERO, "to": Vector3.ZERO, "progress": 1.0, "yaw": 0.0})
	_apply_mode()


## `gloves` are the xr-kit hand visuals to show again in HANDS mode.
func setup(camera: Node3D, left_hand: Node3D, right_hand: Node3D, gloves: Array[Node] = []) -> void:
	_camera = camera
	_left_hand = left_hand
	_right_hand = right_hand
	_gloves = gloves
	_apply_mode()


## Resume the owned desktop copy at the player's present location. A hidden
## body must not sweep an old hand pose across the world after a form switch.
func reset_desktop_pose() -> void:
	if not is_instance_valid(desktop_pose_driver): return
	_head_hand_previous.clear()
	_interaction_hands.clear()
	_last_hip = Vector3.INF
	for foot: Dictionary in _feet: foot.planted = Vector3.INF


## Diagnostic only, not called: swaps the eldskald cel material and its hull
## outline for Godot's toon StandardMaterial3D. Tried for the look-down lag
## (dev, 2026-09-06, headset round 3); it changed nothing, the lag was shadow
## filtering. Kept for the next bisect.
func _apply_xr_materials() -> void:
	var quality: Node = get_node_or_null("/root/Quality")
	if quality == null or not bool(quality.get("xr_mode")):
		return
	var cache: Dictionary = {}
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for si in mi.mesh.get_surface_count():
			var src := mi.get_active_material(si)
			if not src is ShaderMaterial:
				continue
			var sm := src as ShaderMaterial
			var mat: StandardMaterial3D = cache.get(sm.get_rid())
			if mat == null:
				mat = StandardMaterial3D.new()
				var color: Variant = sm.get_shader_parameter("color")
				mat.albedo_color = color if color is Color else Color.WHITE
				var tex: Variant = sm.get_shader_parameter("base_texture")
				if tex is Texture2D:
					mat.albedo_texture = tex
				mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
				mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				mat.roughness = 1.0
				cache[sm.get_rid()] = mat
			mi.set_surface_override_material(si, mat)


## Grip amount 0..1 for one side; null reads the controller again (tests, grabber).
func set_grip(side: String, amount: Variant) -> void:
	_grip_input[side] = amount


## Optional authored index curl for desktop pointing. Null preserves the
## existing grip/controller trigger behavior used by every tracked VR caller.
func set_trigger(side: String, amount: Variant) -> void:
	_trigger_input[side] = amount


func grip_amount(side: String) -> float:
	return float(_grip[side])


func _update_fists(delta: float) -> void:
	if _skeleton == null:
		return
	# Grip closes everything but the index (a point); trigger closes the index
	# too, so grip + trigger is the full fist (dev, 2026-09-07).
	var sources := {"left": _left_hand, "right": _right_hand}
	var run_fist := _run_fist()
	for side: String in ["left", "right"]:
		var grip_target := 0.0
		var trigger_target := 0.0
		if _grip_input[side] != null:
			grip_target = clampf(float(_grip_input[side]), 0.0, 1.0)
			trigger_target = grip_target
		elif sources[side] is XRController3D:
			var c := sources[side] as XRController3D
			grip_target = clampf(c.get_float("grip"), 0.0, 1.0)
			trigger_target = clampf(c.get_float("trigger"), 0.0, 1.0)
		if _trigger_input[side] != null: trigger_target = clampf(float(_trigger_input[side]), 0.0, 1.0)
		# Desktop running: fists, not open hands (dev 2026-11-03). desktop_anon.gd sends grip 0 for a
		# resting hand every frame, so only an action that drives the index (boop's point) opts out;
		# a held item already grips at least this much.
		if _trigger_input[side] == null:
			grip_target = maxf(grip_target, run_fist)
			trigger_target = maxf(trigger_target, run_fist)
		_grip[side] = move_toward(float(_grip[side]), grip_target, delta / 0.08)
		_trigger[side] = move_toward(float(_trigger[side]), trigger_target, delta / 0.08)
		var grip := float(_grip[side])
		var trigger := float(_trigger[side])
		for entry in _finger_bones[side]:
			var bone: int = entry[0]
			var is_index: bool = bool(entry[3])
			var close := trigger if is_index else maxf(grip, trigger)
			var curl: float = deg_to_rad(lerpf(rest_curl, fist_angle, close))
			var splay: float = deg_to_rad(rest_splay) * (1.0 - close)
			var rest: Basis = _skeleton.get_bone_rest(bone).basis
			var pose := rest * Basis(Vector3.UP, splay * float(entry[2])) \
				* Basis(Vector3.BACK, -curl * float(entry[1]))
			_skeleton.set_bone_pose_rotation(bone, pose.get_rotation_quaternion())


## Visible hands follow tracking, kept outside every pony's coat by a collide-and-slide of the
## palm, finger edges and fingertips (dev 2026-09-28: a petting hand must glide along her body,
## never catch on it and never sink in). The physics hands still touch her for petting and
## pushes, but no longer pin the visible hand where they snag.
var _physics_hands: Dictionary = {}
const PONY_HAND_CONTACT_LAYER := 4
var _head_contacts:=preload("res://player/head_contact_query.gd").new(PONY_HAND_CONTACT_LAYER)
var _head_hand_previous:Dictionary={}


func set_physics_hands(left: Node3D, right: Node3D) -> void:
	_physics_hands = {"left": left, "right": right}


func _hand_source(side: String, controller: Node3D) -> Variant:
	if controller == null:
		return null
	var resolved:Transform3D=controller.global_transform
	if _hand_override.get(side) is Transform3D:resolved=_hand_override[side]
	if not resolved.is_finite() or not is_inside_tree():return resolved
	# Contact reports can disappear once tracking is already inside the skull.
	# Sweep palm, thumb edge, little-finger edge and fingertips against the whole coat.
	var previous:Transform3D=_head_hand_previous.get(side,resolved)
	if HAND_SWEEP_GUARD and _hand_sweep_clear(get_world_3d().direct_space_state,previous,resolved):
		_head_hand_previous[side]=resolved
		return resolved
	for offset:Vector3 in [Vector3.ZERO,Vector3(0,0,-.07),Vector3(-.035,0,-.035),Vector3(.035,0,-.035),Vector3(0,0,-.12)]:
		var point:Vector3=resolved*offset
		var safe:Vector3=_head_contacts.slide(get_world_3d().direct_space_state,previous*offset,point,.03 if offset==Vector3.ZERO else .018)
		resolved.origin+=safe-point
	_head_hand_previous[side]=resolved
	return resolved


## dev 2026-10-20 perf pass: one overlap test around the whole sweep (both hand poses, every
## swept point of the palm/edges/fingertips, its ball and the slide's contact inflation) before
## the five collide-and-slides (about ten casts and overlap tests per hand per frame). With
## nothing on the contact layer inside it none of them can touch anything, so the hand comes out
## as tracked, exactly as the sweeps would leave it. A pony near the hand runs the full sweep
## unchanged; the rate stays every frame. false: always sweep.
const HAND_SWEEP_GUARD := true
var _sweep_shape:=SphereShape3D.new()
var _sweep_query:=PhysicsShapeQueryParameters3D.new()

func _hand_sweep_clear(space:PhysicsDirectSpaceState3D,previous:Transform3D,resolved:Transform3D)->bool:
	# Offsets above are x within .035 and z within .12 of the hand: |basis*offset| stays under this.
	var reach:=maxf(.035*previous.basis.x.length()+.12*previous.basis.z.length(),.035*resolved.basis.x.length()+.12*resolved.basis.z.length())
	# .05 covers the 3 cm palm ball, the 2 mm slide inflation, the 1 mm query margin and slack.
	_sweep_shape.radius=previous.origin.distance_to(resolved.origin)*.5+reach+.05
	_sweep_query.shape=_sweep_shape;_sweep_query.collision_mask=PONY_HAND_CONTACT_LAYER
	_sweep_query.transform=Transform3D(Basis.IDENTITY,(previous.origin+resolved.origin)*.5)
	return space.intersect_shape(_sweep_query,1).is_empty()


## Active carry/posing grips own the visible wrist, with skull collision applied afterward.
func set_hand_override(side: String, world: Variant) -> void:
	_hand_override[side] = world


## Rest-mesh scan at setup, repeated when garments change (refresh_forearm_clearance).
## Material changes keep the same sleeve geometry; hidden garments do not count.
func _measure_forearm_shell(ids:Array[int], back:Vector3)->Vector2:
	var elbow:Vector3=_skeleton.get_bone_global_rest(ids[5]).origin
	var wrist:Vector3=_skeleton.get_bone_global_rest(ids[1]).origin
	var length:float=elbow.distance_to(wrist)
	if length<.05:return Vector2(.2,.2)
	var along:Vector3=(wrist-elbow)/length
	back=(back-along*back.dot(along)).normalized()
	var across:Vector3=back.cross(along)
	var centre:Vector3=(elbow+wrist)*.5
	var extent:=Vector2.ZERO
	for node:Node in _model.find_children("*","MeshInstance3D",true,false):
		var mesh_node:=node as MeshInstance3D
		if mesh_node.mesh==null or not mesh_node.visible:continue
		var local:Transform3D=_skeleton.global_transform.affine_inverse()*mesh_node.global_transform
		for surface:int in mesh_node.mesh.get_surface_count():
			var vertices:PackedVector3Array=mesh_node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for vertex:Vector3 in vertices:
				var offset:Vector3=local*vertex-centre
				var z:float=offset.dot(back)
				# Whole forearm, wider than the five-slot strip and the inner buttons,
				# excluding the torso/other arm.
				if absf(offset.dot(along))>length*.49 or absf(offset.dot(across))>length*.4 or absf(z)>length*.65:continue
				extent.x=maxf(extent.x,z);extent.y=maxf(extent.y,-z)
	# Budget the accepted 10 mm outline, a visible 12 mm air gap, and the
	# complete 8 mm carrier underside. The old extra 4 mm left only 2–4 mm
	# after cell thickness, before considering the elbow fold.
	return (extent+Vector2.ONE*(.010+.012+.008))/length


## Garments changed (world/customization/clothing_profile.gd): a bare arm is thinner than a
## sleeve, so the forearm strip and buttons move down onto what is visible.
func refresh_forearm_clearance() -> void:
	if _skeleton == null: return
	for side: String in _interaction_bones:
		var ids: Array[int] = []
		ids.assign(_interaction_bones[side])
		var rest_back: Vector3 = _skeleton.get_bone_global_rest(ids[5]).basis * Vector3(_forearm_back[side])
		_forearm_clearance[side] = _measure_forearm_shell(ids, rest_back)


func _cache_interaction_hands() -> void:
	# Read after skinning modifiers, before Godot restores the pre-IK pose.
	# Skeleton updates already queued at scene removal can still emit this signal.
	if not is_inside_tree() or not is_instance_valid(_skeleton) or not _skeleton.is_inside_tree():
		_interaction_hands.clear()
		return
	for side in _interaction_bones:
		var ids:Array=_interaction_bones[side]
		var points:Array[Vector3]=[]
		for b in ids:points.append((_skeleton.global_transform*_skeleton.get_bone_global_pose(b)).origin)
		var distal:=_skeleton.get_bone_global_pose(ids[0])
		var tip:Vector3=_skeleton.global_transform*(distal*INDEX_CAP[side])
		# finger x thumb-side is the palm (left; mirrored right). The old operand order gave the
		# back of the hand, so slaps only landed backhanded (dev 2026-10-15; tools/relationships/test_palm_side.gd).
		var normal:Vector3=(points[4]-points[1]).cross(points[2]-points[3]).normalized()*(1.0 if side=="left" else -1.0)
		var lower:Transform3D=_skeleton.global_transform*_skeleton.get_bone_global_pose(ids[5])
		var along:Vector3=points[1]-points[5]
		var length:float=along.length()
		var back:Vector3=lower.basis*Vector3(_forearm_back[side])
		if not lower.is_finite() or not tip.is_finite() or not normal.is_finite() or not along.is_finite() or length<.05 or length>1.:
			_interaction_hands.erase(side);continue
		along/=length
		back-=along*back.dot(along)
		if not back.is_finite() or back.length_squared()<.000001:
			_interaction_hands.erase(side);continue
		back=back.normalized()
		# Lower-arm bone owns the mount's roll. Wrist/finger flex cannot rotate its cuff.
		var frame:=Transform3D(Basis(along,back.cross(along),back),(points[1]+points[5])*.5)
		var palm_center: Vector3 = (points[1] + (points[2] + points[3] + points[4]) / 3.0) * 0.5
		_interaction_hands[side]={"tip":tip,"palm":normal,"palm_center":palm_center,"wrist":points[1],"elbow":points[5],"forearm":frame,"forearm_length":length,"forearm_outer":Vector2(_forearm_clearance[side]).x*length,"forearm_inner":Vector2(_forearm_clearance[side]).y*length}
	interaction_hands_updated.emit()


func _exit_tree() -> void:
	_interaction_hands.clear()
	_head_hand_previous.clear()


func interaction_hand(side:String) -> Dictionary:
	return _interaction_hands.get(side,{}) if body_mode==BodyMode.FULL else {}


## The IK skeleton still runs in gloves-only mode; its forearm anchors remain available.
func interaction_forearm(side:String) -> Dictionary:
	var sample:Dictionary=_interaction_hands.get(side,{})
	if sample.is_empty():return {}
	return {"forearm":sample.forearm,"forearm_length":sample.forearm_length,"forearm_outer":sample.forearm_outer,"forearm_inner":sample.forearm_inner}


## Forget the measured height; the next steady tall reading becomes standing.
func calibrate() -> void:
	height_calibrated = false
	standing_eye_height = 0.0
	_tall_seconds = 0.0
	_tall_height = 0.0


func _apply_mode() -> void:
	if _model != null:
		_model.visible = body_mode == BodyMode.FULL
	for glove in _gloves:
		if glove is MeshInstance3D:
			(glove as MeshInstance3D).visible = body_mode != BodyMode.FULL


## Desktop: the body's IK targets follow at the physics rate, not every rendered frame (2026-10-23
## CPU pass, dev chose it knowing the body may trail the camera slightly at high FPS). The headset
## keeps every frame: there the body must hold still against the head.
var _body_delta := 0.0
var _body_physics_frame := -1

func _process(delta: float) -> void:
	_body_delta += delta
	if is_instance_valid(desktop_pose_driver) and not _xr_active():
		var tick := Engine.get_physics_frames()
		if tick == _body_physics_frame: return
		_body_physics_frame = tick
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	var step := _body_delta
	_body_delta = 0.0
	_process_step(step)
	if started > 0: CPU_PROFILE.record("anon_body", started)

func _xr_active() -> bool:
	var vp := get_viewport()
	return vp != null and vp.use_xr

func _process_step(delta: float) -> void:
	if _camera == null:
		return
	# A non-finite headset pose (tracking drop) must not reach the IK targets;
	# they simply keep last frame's values. xr_grounded_body holds the camera
	# itself, this is the belt to its braces.
	if not _camera.global_transform.is_finite() or not global_transform.is_finite():
		return
	var floor_y: float = global_position.y
	var eye_height: float = _camera.global_position.y - floor_y
	if is_instance_valid(desktop_pose_driver):
		# Desktop height is a configured body measurement, not the user's saved
		# headset calibration or a crouched frame becoming a new standing height.
		if standing_eye_height <= 0.0 and eye_height > 1.0:
			standing_eye_height = eye_height
			height_calibrated = true
		_update_height(delta, eye_height)
	elif not is_instance_valid(couch_rest_frame):
		if not _chosen_height_checked: _first_chosen_height()
		_update_height(delta, eye_height / _tracking_scale())
	var scale := model_scale
	# Desktop: the body sits DESKTOP_BODY_FORWARD further forward under the camera (dev 2026-11-03:
	# "my viewpoint is pushed too far forward. move my body forward, not my viewpoint back").
	var offset := head_offset
	if is_instance_valid(desktop_pose_driver): offset.z -= desktop_body_forward
	var head: Transform3D = _camera.global_transform.translated_local(offset * scale)
	_head_target.global_transform = Transform3D(head.basis * REST_FACING, head.origin)

	# Head-right remains well-defined when looking through straight up/down;
	# flattening head-forward used to reverse torso yaw by 180 degrees there.
	var right_flat := Vector3(head.basis.x.x, 0, head.basis.x.z)
	if right_flat.length_squared() > .16:
		var wanted_yaw := atan2(-right_flat.z, right_flat.x)
		if not _yaw_initialized:
			_body_yaw = wanted_yaw
			_yaw_initialized = true
		else:
			_body_yaw = lerp_angle(_body_yaw, wanted_yaw, 1.0-exp(-delta/.12))
	var yaw_angle := _body_yaw
	var facing := Basis(Vector3.UP, yaw_angle)
	var fwd := -facing.z
	var yaw := facing * REST_FACING
	# The spine cannot shorten. When the head is lower than a straight spine
	# allows (sitting, crouching), the hips slide back by the spare length,
	# so the torso reclines instead of hunching into the player's lap.
	var spine := hip_drop * scale
	var hip_h: float = maxf(head.origin.y - spine, floor_y + 0.25 * scale)
	var drop: float = head.origin.y - hip_h
	var back: float = sqrt(maxf(0.0, spine * spine - drop * drop))
	var hip := Vector3(head.origin.x, hip_h, head.origin.z) - fwd * (0.04 * scale + back)
	# At floor height use head tilt as a reclining estimate, fading it out well
	# before standing. Without torso trackers this is an estimate, not a measured pose.
	var recline := 1.0-smoothstep(.45*scale,.85*scale,eye_height)
	var head_up := head.basis.y.normalized()
	var tilted_hip := head.origin-head_up*spine-fwd*.04*scale
	hip = hip.lerp(tilted_hip,recline)
	var spine_up := (head.origin-hip).normalized()
	var tilt := Basis(Quaternion(Vector3.UP,spine_up))
	_hip_target.global_transform = Transform3D(tilt*yaw, hip)

	# Sitting: head well below standing for a moment. Legs shrink away.
	var low := standing_eye_height > 0.0 and eye_height < standing_eye_height * _tracking_scale() * SEATED_FRACTION
	_low_seconds = _low_seconds + delta if low else 0.0
	seated = force_seated or _low_seconds >= seated_delay
	if _leg_hide != null:
		# Animated desktop legs sit and crouch properly, so they stay visible (anon_motion.gd).
		var animated_legs: bool = _motion != null and _motion.amount > .5
		_leg_hide.influence = move_toward(_leg_hide.influence, 1.0 if seated and not is_instance_valid(couch_rest_frame) and not animated_legs else 0.0, delta / 0.25)

	# Feet: ideal spots under the hips, reached by alternating steps.
	var hip_flat := Vector3(head.origin.x, floor_y, head.origin.z)
	if _last_hip.is_finite():
		_hip_speed = lerpf(_hip_speed, hip_flat.distance_to(_last_hip) / maxf(delta, 0.0001), 0.3)
	_last_hip = hip_flat
	var right_dir: Vector3 = facing.x
	if wing_flight != null and wing_flight.active:
		# Relaxed airborne legs: no invented planted steps or footstep sounds.
		for i in 2:
			_feet[i].planted = hip_flat + right_dir * (-1.0 if i == 0 else 1.0) * feet_spread * scale - fwd * 0.08 * scale + Vector3.UP * 0.09 * scale
			_feet[i].progress = 1.0; _feet[i].yaw = yaw_angle
	else:
		_step_feet(delta, hip_flat, right_dir * feet_spread * scale, yaw_angle)
	_left_foot.global_transform = Transform3D(Basis(Vector3.UP, _feet[0].yaw) * REST_FACING, _foot_position(0))
	_right_foot.global_transform = Transform3D(Basis(Vector3.UP, _feet[1].yaw) * REST_FACING, _foot_position(1))

	if is_instance_valid(desktop_pose_driver): _apply_desktop_motion(delta, hip_flat, yaw_angle, scale)
	if is_instance_valid(couch_rest_frame): _apply_couch_targets(head, scale)
	if is_instance_valid(desktop_pose_driver): desktop_pose_driver.apply_torso_pose(_hip_target, facing)

	var left_source: Variant = _hand_source("left", _left_hand)
	var right_source: Variant = _hand_source("right", _right_hand)
	if left_source != null and (left_source as Transform3D).is_finite():
		_left_target.global_transform = (left_source as Transform3D) * left_hand_offset
	if right_source != null and (right_source as Transform3D).is_finite():
		_right_target.global_transform = (right_source as Transform3D) * right_hand_offset
	_update_fists(delta)


## Desktop body animation (player/anon_motion.gd, dev 2026-11-03): the retargeted clips pose the
## body; the pelvis, feet, knees and resting hands follow them as IK targets. The camera head
## stays authoritative (valve_body_ik.gd pins the head to it), so does every action, held item
## and couch rest. desktop_anon.gd supplies the movement state; tracked VR never comes here.
const MOTION := preload("res://player/anon_motion.gd")
var _motion: RefCounted
var _motion_failed := false
var _motion_frame := Transform3D.IDENTITY
var _motion_frame_local := Transform3D.IDENTITY
var _motion_head := Vector3.INF
var _body_ik: SkeletonModifier3D

func _apply_desktop_motion(delta: float, hip_flat: Vector3, yaw_angle: float, body_scale: float) -> void:
	if _motion_failed or _skeleton == null: return
	if _motion == null:
		_motion = MOTION.new(_skeleton)
		_body_ik = find_child("BodyIK", true, false) as SkeletonModifier3D
		if not _motion.valid() or _body_ik == null or not "knee_hints" in _body_ik:
			_motion = null
			_motion_failed = true
			return
	var state: Dictionary = {}
	if not is_instance_valid(couch_rest_frame) and desktop_pose_driver.has_method("motion_state"):
		state = desktop_pose_driver.motion_state()
	if not state.is_empty(): state["scale"] = body_scale
	var was_on: bool = _motion.amount > 0.0
	_motion.update(delta, state)
	if _motion.amount <= 0.0:
		if was_on:
			_motion.reset_pose()
			_body_ik.knee_hints = {}
			_body_ik.leg_stretch = true
		return
	var body_yaw := yaw_angle
	if state.has("seat_yaw"): body_yaw = lerp_angle(yaw_angle, float(state.seat_yaw), float(_motion.seated))
	var frame_basis := Basis(Vector3.UP, body_yaw + float(_motion.leg_yaw)) * REST_FACING
	# The clip's head sits over the camera head, so the pelvis needs no sideways pin (a leaning
	# jog or crouch would otherwise drag its planted feet along).
	# Averaged over about a stride, so the frame follows the clip's lean, not each bob.
	var head_model: Vector3 = _motion.point("Head", Transform3D.IDENTITY, 1.0)
	_motion_head = head_model if not _motion_head.is_finite() else _motion_head.lerp(head_model, 1.0 - exp(-delta / .35))
	var head_offset: Vector3 = frame_basis * (_motion_head * body_scale)
	var origin := hip_flat - Vector3(head_offset.x, 0.0, head_offset.z)
	if state.get("seat") is Vector3 and float(_motion.seated) > 0.0:
		# Seat bones on the seat point (desktop_player.gd sits the body there): the hip joints ride
		# about 9 cm above them, as the procedural seated hips did.
		var on_seat: Vector3 = Vector3(state.seat) + Vector3.UP * .09 * body_scale - frame_basis * (_motion.seated_hips() * body_scale)
		origin = origin.lerp(on_seat, float(_motion.seated))
	_motion_frame = Transform3D(frame_basis, origin)
	# Hand markers are read by desktop_anon.gd every rendered frame: keep them on the moving body.
	_motion_frame_local = global_transform.affine_inverse() * _motion_frame
	var amount: float = _motion.amount
	_hip_target.global_transform = _blend_frame(_hip_target.global_transform, _motion.target("Hips", _motion_frame, body_scale), amount)
	var feet: float = _motion.feet_amount
	_left_foot.global_transform = _blend_frame(_left_foot.global_transform, _motion.foot_target(0, _motion_frame, body_scale, delta), feet)
	_right_foot.global_transform = _blend_frame(_right_foot.global_transform, _motion.foot_target(1, _motion_frame, body_scale, delta), feet)
	var animated_legs := feet > .5
	_body_ik.knee_hints = {"left": _motion.point("LeftLowerLeg", _motion_frame, body_scale),
		"right": _motion.point("RightLowerLeg", _motion_frame, body_scale)} if animated_legs else {}
	_body_ik.leg_stretch = not animated_legs

static func _blend_frame(from: Transform3D, to: Transform3D, weight: float) -> Transform3D:
	if weight >= 1.0: return to
	if weight <= 0.0: return from
	return Transform3D(from.basis.orthonormalized().slerp(to.basis.orthonormalized(), weight), from.origin.lerp(to.origin, weight))

## Loose-fist share while the desktop body jogs or sprints (anon_motion.gd weights).
const RUN_FIST := 0.9
func _run_fist() -> float:
	if _motion == null or float(_motion.amount) <= 0.0: return 0.0
	var weights: Dictionary = _motion.weights()
	return RUN_FIST * float(_motion.amount) * clampf(float(weights.get("jog", 0.0)) + float(weights.get("sprint", 0.0)), 0.0, 1.0)

## How much of the body the desktop animation owns now (0 when absent).
func motion_amount() -> float:
	return float(_motion.amount) if _motion != null else 0.0

## Animated resting hand as a desktop presentation hand marker (the IK target is
## marker * hand offset). Null while no animation runs.
func motion_hand_marker(side: String) -> Variant:
	if _motion == null or float(_motion.amount) <= 0.0: return null
	var bone_target: Transform3D = _motion.target("LeftHand" if side == "left" else "RightHand", global_transform * _motion_frame_local, model_scale)
	return bone_target * (left_hand_offset if side == "left" else right_hand_offset).affine_inverse()


## Reclining along the mattress uses a spine-length hip offset and reachable foot targets.
## Only inferred points blend. No head rotation, endpoint clamp, bone scale or custom pony pose.
func _apply_couch_targets(head: Transform3D, body_scale: float) -> void:
	var amount := smoothstep(0.0, 1.0, couch_rest_amount)
	var frame := couch_rest_frame.global_basis.orthonormalized()
	var forward := -frame.z
	var seated_up := (Vector3.UP * 0.9 - forward * 0.436).normalized()
	var lying_up := (Vector3.UP * 0.26 - forward * 0.966).normalized()
	var spine_up := seated_up.slerp(lying_up, amount)
	var couch: Variant = (couch_rest_frame.get_meta("couch") if couch_rest_frame.has_meta("couch") else null)
	var companion: Node3D = couch.partner(couch_rest_frame) if is_instance_valid(couch) else null
	var beside: bool = is_instance_valid(companion) and companion.has_method("posture_status") and companion.posture_status().requested == "lie_down"
	_couch_company = move_toward(_couch_company, 1.0 if beside else 0.0, get_process_delta_time() / 0.9)
	if is_instance_valid(couch) and _couch_company > 0.0:
		# A shoulder-to-shoulder cuddle comes from the inferred torso leaning toward company.
		# Normalization keeps the head-to-hip length intact; observed head/hands never move.
		var side := signf(couch.to_local(couch_rest_frame.global_position).x)
		spine_up += couch.global_basis.x.normalized() * side * 0.12 * amount * _couch_company
	spine_up = spine_up.normalized()
	var hip := head.origin - spine_up * hip_drop * body_scale
	var yaw := frame * REST_FACING
	var tilt := Basis(Quaternion(Vector3.UP, spine_up))
	_hip_target.global_transform = Transform3D(tilt * yaw, hip)
	# A bed supports longer, relaxed legs. The sofa keeps its existing knee bend.
	# These are inferred foot targets; tracked head/hands and native lengths stay intact.
	# 82cm leaves room for the lateral hip offset below the native 86.2cm reach.
	var leg_along := .82 if is_instance_valid(couch) and couch.rest_word() == "bed" else .72
	for side in [-1.0, 1.0]:
		var foot: Node3D = _left_foot if side < 0.0 else _right_foot
		var at: Vector3 = hip + (forward * leg_along - Vector3.UP * 0.035 + frame.x * side * feet_spread) * body_scale
		# The pull-out remains under the feet during waking. Rest the ankles on its surface;
		# lowering them to the room floor would put the shins through the extended mattress.
		var sitting: Vector3 = couch_rest_frame.global_position + forward * 0.52 + Vector3.UP * 0.10 + frame.x * side * feet_spread * body_scale
		foot.global_transform = Transform3D(yaw, sitting.lerp(at, amount))

## Hold both grips for two seconds while standing straight: that eye height
## becomes standing, saved for next launch (dev, 2026-09-07: "calibrate
## physical height"). The tallest-steady heuristic stays as the fallback.
const CALIBRATION_PATH := "user://calibration.json"
var _calib_hold := 0.0
var calibration_path := CALIBRATION_PATH
var height_calibrated := false
var calibration_message := ""
var _calibration_remaining := 0.0
var _calibration_samples: Array[float] = []


func _check_grip_calibration(delta: float, eye_height: float) -> void:
	if not (_left_hand is XRController3D and _right_hand is XRController3D):
		return
	var both: bool = (_left_hand as XRController3D).get_float("grip") > 0.9 \
		and (_right_hand as XRController3D).get_float("grip") > 0.9
	if not both:
		_calib_hold = 0.0
		return
	if _calib_hold < 0.0:
		return  # already fired this squeeze
	_calib_hold += delta
	if _calib_hold >= 2.0:
		_calib_hold = -1.0
		begin_height_calibration()

func begin_height_calibration() -> void:
	_calibration_remaining = 3.0
	_calibration_samples.clear()
	calibration_message = "Stand straight and look forward…"

func _finish_height_calibration() -> bool:
	if _calibration_samples.size() < 20:
		calibration_message = "Height not measured. Try again while standing still."
		return false
	_calibration_samples.sort()
	var count := _calibration_samples.size()
	if _calibration_samples[int(count * .9)] - _calibration_samples[int(count * .1)] > .06:
		calibration_message = "Hold still, then try again."
		return false
	return save_height_calibration(_calibration_samples[count / 2])

func save_height_calibration(value: float) -> bool:
	if not is_finite(value) or value < .8 or value > 2.5:
		calibration_message = "Height outside the supported range."
		return false
	if not calibration_path.is_empty():
		var file := FileAccess.open(calibration_path + ".tmp", FileAccess.WRITE)
		if file == null:
			calibration_message = "Could not save height."
			return false
		file.store_string(JSON.stringify({"standing_eye_height":value}))
		file.flush()
		var error := file.get_error()
		file.close()
		if error != OK or DirAccess.rename_absolute(ProjectSettings.globalize_path(calibration_path + ".tmp"), ProjectSettings.globalize_path(calibration_path)) != OK:
			calibration_message = "Could not save height."
			return false
	standing_eye_height = value
	height_calibrated = true
	calibration_message = "Height saved: %.2f m eye level." % value
	# The player's own rig: the measurement is Anon's height too (Settings, World tab), shown in
	# feet and inches; the 12 cm crown above the eye matches Settings.anon_eye_height_m.
	var settings := get_node_or_null("/root/Settings")
	if not calibration_path.is_empty() and settings != null and settings.has_method("anon_eye_height_m"):
		settings.call("set_value", "player/height_cm", (value + 0.12) * 100.0)
	return true

func _load_calibration() -> void:
	if calibration_path.is_empty() or not FileAccess.file_exists(calibration_path): return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(calibration_path))
	if not parsed is Dictionary: return
	var value: Variant = parsed.get("standing_eye_height")
	if (value is float or value is int) and is_finite(float(value)) and value >= .8 and value <= 2.5:
		standing_eye_height = float(value)
		height_calibrated = true


## Anon's chosen height (Settings player/height_cm, dev 2026-11-03) sizes the tracked VR body and
## hands; the headset keeps the camera. Only the player's own tracked rig (a calibration path and an
## XR camera) follows it: desktop bodies take the rig's eye (player/desktop_anon.gd), previews theirs.
var _chosen_height_checked := false
func _follows_chosen_height() -> bool:
	return not is_instance_valid(desktop_pose_driver) and not calibration_path.is_empty() and _camera is XRCamera3D

## First tracked frame: a stored choice wins over a saved headset measurement (which also stores
## one since 2026-11-03); with neither, the tallest-steady estimate stays.
func _first_chosen_height() -> void:
	_chosen_height_checked = true
	var settings := get_node_or_null("/root/Settings")
	if _follows_chosen_height() and settings != null and settings.has_method("is_chosen") and bool(settings.call("is_chosen", "player/height_cm")):
		_use_chosen_height()

func _use_chosen_height() -> void:
	var settings := get_node_or_null("/root/Settings")
	if settings == null or not settings.has_method("anon_eye_height_m"): return
	standing_eye_height = float(settings.call("anon_eye_height_m"))
	height_calibrated = true

func _on_setting_changed(key: String) -> void:
	if key == "player/height_cm" and _follows_chosen_height(): _use_chosen_height()


func _tracking_scale() -> float:
	return maxf(XRServer.world_scale, .001) if _camera is XRCamera3D else 1.0

func _update_height(delta: float, eye_height: float) -> void:
	_check_grip_calibration(delta, eye_height)
	if _calibration_remaining > 0.0:
		_calibration_remaining = maxf(0.0, _calibration_remaining - delta)
		# First second lets the hand return from the menu; measure the last two.
		if _calibration_remaining <= 2.0 and is_finite(eye_height) and eye_height >= .8 and eye_height <= 2.5:
			_calibration_samples.append(eye_height)
		calibration_message = "Stand straight… %d" % ceili(_calibration_remaining)
		if _calibration_remaining == 0.0: _finish_height_calibration()
	# The tallest height held steadily for a second is standing. A glance
	# upward or a stretch does not count; a short sample does not either.
	if eye_height > 1.0 and absf(eye_height - _tall_height) < 0.04:
		_tall_seconds += delta
	else:
		_tall_seconds = 0.0
		_tall_height = eye_height
	if not height_calibrated and _tall_seconds >= 1.0 and _tall_height > standing_eye_height:
		standing_eye_height = _tall_height
	var wanted := 1.0
	if standing_eye_height > 0.0:
		wanted = standing_eye_height / MODEL_EYE_HEIGHT if height_calibrated else clampf(standing_eye_height / MODEL_EYE_HEIGHT, 0.75, 1.3)
	else:
		# Until measured, assume the world scale the game applies to the
		# tracking space, exactly what game.gd used to hard-set.
		wanted = XRServer.world_scale if XRServer.world_scale > 0.0 else 1.0
	if standing_eye_height > 0.0: wanted *= _tracking_scale()
	if absf(wanted - model_scale) > 0.0005:
		model_scale = lerpf(model_scale, wanted, 1.0 - exp(-delta / 0.3))
		if _model != null:
			_model.scale = Vector3.ONE * model_scale


func _step_feet(delta: float, hip_flat: Vector3, spread: Vector3, yaw_angle: float) -> void:
	var ideals := [hip_flat - spread, hip_flat + spread]
	_step_cooldown = maxf(_step_cooldown - delta, 0.0)
	var any_stepping := false
	for i in 2:
		var foot: Dictionary = _feet[i]
		if not Vector3(foot.planted).is_finite() or Vector3(foot.planted).distance_to(ideals[i]) > 1.5:
			# First frame, teleport, or a room-scale jump: just stand there.
			foot.planted = ideals[i]
			foot.progress = 1.0
			foot.yaw = yaw_angle
		if foot.progress < 1.0:
			any_stepping = true
	if _hip_speed > STEP_MAX_SPEED:
		# Glide: keep the feet under the hips without stepping animation, but
		# still report strides so the footsteps keep pace with the run.
		_glide_travel += _hip_speed * delta
		if _glide_travel >= 1.1 * model_scale:
			_glide_travel = 0.0
			stepped.emit(hip_flat)
		for i in 2:
			var foot: Dictionary = _feet[i]
			foot.planted = Vector3(foot.planted).lerp(ideals[i], 1.0 - exp(-delta / 0.08))
			foot.progress = 1.0
			foot.yaw = lerp_angle(foot.yaw, yaw_angle, 1.0 - exp(-delta / 0.1))
		return
	for i in 2:
		var foot: Dictionary = _feet[i]
		if foot.progress < 1.0:
			foot.progress = minf(1.0, foot.progress + delta / float(foot.get("duration", step_seconds)))
			foot.yaw = lerp_angle(foot.yaw, yaw_angle, foot.progress)
			if foot.progress >= 1.0:
				foot.planted = foot.to
				_step_cooldown = min_step_interval
				stepped.emit(foot.to)
			continue
		if any_stepping:
			continue
		var drift: float = Vector3(foot.planted).distance_to(ideals[i])
		var twist: float = absf(angle_difference(foot.yaw, yaw_angle))
		# The foot further from its spot steps first.
		var other: Dictionary = _feet[1 - i]
		var other_drift: float = Vector3(other.planted).distance_to(ideals[1 - i])
		if _step_cooldown > 0.0:
			continue
		if (drift > step_distance or twist > deg_to_rad(step_yaw_degrees)) and drift >= other_drift:
			foot.from = foot.planted
			# Land ahead of the hips in the direction of travel, further the
			# faster they move, as a real step does; a standing shuffle lands
			# on the spot.
			var travel: Vector3 = (ideals[i] - Vector3(foot.planted)).limit_length(1.0)
			foot.to = ideals[i] + travel.normalized() * minf(0.35, _hip_speed * 0.4) if _hip_speed > 0.05 else ideals[i]
			foot.progress = 0.0
			foot.duration = lerpf(step_seconds, step_seconds * 0.6, clampf(_hip_speed / STEP_MAX_SPEED, 0.0, 1.0))
			any_stepping = true


func _foot_position(i: int) -> Vector3:
	var foot: Dictionary = _feet[i]
	if foot.progress >= 1.0:
		return foot.planted
	var t: float = smoothstep(0.0, 1.0, foot.progress)
	var lift: float = sin(PI * foot.progress) * step_height * model_scale
	return Vector3(foot.from).lerp(foot.to, t) + Vector3.UP * lift


func get_debug_snapshot() -> Dictionary:
	return {"standing_eye_height": standing_eye_height, "model_scale": model_scale, "seated": seated,
		"leg_hide": _leg_hide.influence if _leg_hide != null else -1.0, "hip_speed": _hip_speed,
		"feet": _feet.duplicate(true), "mode": BodyMode.keys()[body_mode]}
