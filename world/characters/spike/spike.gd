extends CharacterBody3D
## Spike, Twilight's baby dragon assistant (dev 2026-10-18: "add spike. full feature parity").
##
## He walks on two legs, so the ponies' four-legged motor and solver (pony_locomotion.gd) cannot
## drive him. This body answers the same calls instead: the navigator's motion contract
## (accept_navigation_motion and its feedback fields), postures (sit, lie down, sleep), holds and
## throws, conversation (say, gaze, line faces, lip sync), touch (pets, boops, forehead kisses),
## crowd tiers and the helper objects other systems read off a pony (posture, carry, thrown,
## hoof_hold, expressions, boop_node, touch_body). Everything above the body (navigation, day
## plans, living world, night rest, AI, relationships, population) then works on him unchanged.
##
## Model: world/characters/spike/spike.glb, built by tools/spike/spike_anims.py through the Blender
## MCP (keyed clips for every state and gesture). The model faces +Z, so it turns half round
## under Pivot to face this body's -Z like the ponies.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const PROFILE := preload("res://world/characters/locomotion/pony_gait_profile.gd")
const MODEL := preload("res://world/characters/spike/spike.glb")
const IDENTITY_DEFAULT := "res://world/characters/spike/spike.tres"
const FACE := preload("res://world/characters/spike/spike_face.gd")
const POSTURE := preload("res://world/characters/spike/spike_posture.gd")
const PARTS := preload("res://world/characters/spike/spike_parts.gd")
const LOOK := preload("res://world/characters/spike/spike_look.gd")
const TOUCH := preload("res://world/characters/spike/spike_touch.gd")
const AFFECTION := preload("res://world/characters/spike/spike_affection.gd")
const EYE_SHADER := preload("res://world/characters/spike/spike_eye.gdshader")
## The model's own iris art; the eye locators already rest them a little toward his nose.
const IRIS_L := preload("res://world/characters/spike/spike_iris_l.png")
const IRIS_R := preload("res://world/characters/spike/spike_iris_r.png")
const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")

enum Motion { STANDING, STARTING, MOVING, STOPPING, UNSUPPORTED, HELD }
enum SimTier { HERO, NEAR, FAR }
const NAV_MODE_STOP := 0
const NAV_MODE_TRAVEL := 1
const NAV_MODE_STEP_TURN := 2
const NAV_MODE_BRAKE := 3
const NAV_MODE_HOLD := 4
const NAV_REFUSAL_NONE := 0
const NAV_REFUSAL_SUPPORT := 1
const NAV_REFUSAL_TOUCH := 2
const NAV_REFUSAL_TURN_SUPPORT := 3
const CLOUD_LAYER := 1 << 9

signal hoof_planted(world_position: Vector3)
signal audio_jumped(world_position: Vector3)
signal audio_landed(world_position: Vector3, impact_speed: float)
signal speech_finished
signal speech_started
signal speech_failed(message: String)
signal physical_reaction(kind: String)

@export var identity: Resource
@export var ai_profile := "res://world/ai/characters/spike.json"

## Clips that loop; everything else plays once.
const LOOPS := ["idle", "walk", "run", "sit", "lie", "sleep", "carried", "sit_chair", "talk", "hug", "kiss", "fall", "cower", "dance", "write"]
## Whole-body states the base layer crossfades between.
const BASE_CLIPS := ["idle", "walk", "run", "sit", "sit_chair", "lie", "sleep", "carried", "fall", "hug", "kiss", "cower", "dance", "write"]
## Upper-body gestures (played over walking or sitting) and whole-body actions.
const GESTURES := ["wave", "point", "shrug", "eat", "door", "talk"]
const ACTIONS := ["cheer", "jump", "fire", "kick"]
## Bones the upper-body layers own.
const UPPER := ["Spine2", "Head", "LeftShoulder", "LeftArm", "LeftForearm", "ValveBiped.Bip01_L_Hand", "RightShoulder",
	"RightArm", "RightForearm", "ValveBiped.Bip01_R_Hand"]
const RIGHT_HAND := "ValveBiped.Bip01_R_Hand"
## Ground speed of each loop at playback speed 1 (measured from the clip's stride), and where the
## walk turns into a run.
const WALK_NATIVE := 0.42
const RUN_NATIVE := 0.95
const RUN_FROM := 0.8
const STEP_WALK := 0.12
const STEP_RUN := 0.17

var profile: Resource
var body_scale := 1.0
var sleep_style := "side"
var sleeping := false:
	set(value):
		sleeping = value
		if expressions != null: expressions.sleeping = value
		if value and posture != null and posture.requested != "lie_down" and grounded() and not _held: posture.request("lie_down")
var motion_paused := false
var conversation_target: Node3D
var action_gaze_target: Node3D
var navigation_steering := false
var actual_speed := 0.0
var steer_turn_rate := 4.0
var state: int = Motion.STANDING
var sim_tier: int = SimTier.HERO
## Set by the crowd ranking (pony_crowd.gd); Spike is one body and runs every tick regardless.
var hero_divisor := 1
var far_logic_divisor := 1
var far_tick_divisor := 1
var floor_mask := 1
var moving_support: Node3D
var nav_executed_speed := 0.0
var nav_executed_yaw_rate := 0.0
var nav_refusal := NAV_REFUSAL_NONE
var nav_wall_normal := Vector3.ZERO
var nav_speed_scale := 1.0
var backing := false
var steer_through_touch := false

## Helper objects under a pony's names (spike_parts.gd).
var posture: RefCounted
var flight: RefCounted = null
var thrown: RefCounted
var hoof_hold: RefCounted
var carry: RefCounted
var placement_recovery: RefCounted
var expressions: RefCounted
var boop_node: Node3D
var touch_body: Node3D
var magic: Node3D = null
var head: Node3D = null
var secondary: RefCounted = null
var excitement: Node = null
var pivot: Node3D
var skeleton: Skeleton3D
var water_escape: RefCounted
## No posed cuddle session (world/relationships/cuddle/session.gd): those solvers drive a pony rig.
var cuddle_supported := false

## Hold state (the grabber and desktop carry write these through begin_grab etc.).
var _held := false
var _interaction := ""
var _interaction_seconds := 0.0
var _touch_force := Vector3.ZERO
var _hand_targets: Dictionary = {}
var _hold_target := Vector3.ZERO
var _hold_yaw := INF
var _hold_root_offset := Vector3.ZERO
var _hold_velocity := Vector3.ZERO
var _ground_velocity := Vector3.ZERO
var _collision: CollisionShape3D

var _desired := Vector3.ZERO
var _face_direction := Vector3.ZERO
var _nav_motion := false
var _nav_speed := 0.0
var _nav_yaw_rate := 0.0
var _nav_mode := NAV_MODE_STOP
var _nav_frame := -1
var _nav_gait_speed := 0.0
var _speed := 0.0
var _lunge_velocity := Vector3.ZERO
var _lunge_left := 0.0
var _jump_request := 0.0
var _air_time := 0.0
var _step_travel := 0.0
var _left_step := true
var _unsupported_seconds := 0.0

var _model: Node3D
var _anim: AnimationPlayer
var tree: AnimationTree
var _tree_root: AnimationNodeBlendTree
var _base_clip := "idle"
var _talk_mix := 0.0
var _look: SkeletonModifier3D
var _voice: AudioStreamPlayer3D
var _cues: Array = []
var _speech_time := -1.0
var _speech_generation := 0
var _pending_stream: AudioStream
var _pending_path := ""
var _mouth_hold_left := 0.0
var _mouth_hold := 0.0
## Seconds left of the playing gesture / action (game time, so tests and slow frames agree).
var _gesture_left := 0.0
var _action_left := 0.0
var _crowd: Node
var _crowd_visible := true
## 0.1.0 perf pass: the per-frame pass sets its two tree parameters only when they change, keeps
## the Affection node and his head bone instead of looking them up every frame, and between HERO and
## FAR (4-45 m, where the ponies run baked clips on the physics tick) plays his tree and skeleton on
## the physics tick instead of every rendered frame. Rollback: NEAR_PHYSICS_RATE = false.
const NEAR_PHYSICS_RATE := true
var _talk_set := -1.0
var _scale_set := INF
var _affection: Node
var _head_bone := -2


## The navigator is added before this body enters the tree, and its _ready (children first) reads
## the gait profile: the profile and the helper objects exist from construction.
func _init() -> void:
	profile = PROFILE.new()
	# His own navigation size (the walk grid caches room per profile): his body is 0.16 m round
	# and 0.75 m tall, so a pony's 0.45 m / 1.2 m route capsule would keep him out of gaps he fits.
	# 0.3 m keeps a margin round his body; 0.85 m covers his spines.
	profile.radius = 0.3
	profile.clearance = 0.85
	profile.walk_speed = Vector2(0.35, 0.6)
	profile.trot_speed = Vector2(1.6, 2.6)
	profile.gallop_speed = Vector2(2.6, 3.4)
	profile.max_travel_speed = 3.4
	profile.acceleration = 3.0
	profile.braking = 4.5
	profile.hip_height = 0.17
	posture = POSTURE.new(); posture.bind(self)
	thrown = PARTS.Throw.new(); thrown.bind(self)
	hoof_hold = PARTS.HoofHold.new()
	carry = PARTS.Carry.new(); carry.bind(self)
	placement_recovery = PARTS.Recovery.new()
	water_escape = PARTS.WaterEscape.new()

func _ready() -> void:
	if identity == null: identity = load(IDENTITY_DEFAULT)
	if identity != null and str(identity.get("ai_profile")) != "": ai_profile = str(identity.ai_profile)
	_build_body()
	_build_model()
	expressions = FACE.new()
	var eyes: Array[ShaderMaterial] = []
	var face_mesh := _dress_materials(eyes)
	expressions.bind(face_mesh, eyes)
	_look = LOOK.new(); _look.name = "SpikeLook"; _look.body = self
	skeleton.add_child(_look)
	var touch := TOUCH.new(); touch.name = "SpikeTouch"
	add_child(touch); touch.bind(self, skeleton)
	touch_body = touch; boop_node = touch
	if get_node_or_null("Affection") == null:
		var affection := AFFECTION.new(); affection.name = "Affection"; affection.spike = self
		add_child(affection)
	_voice = AudioStreamPlayer3D.new(); _voice.name = "Voice"; _voice.unit_size = 4.0
	_voice.bus = "Voice" if AudioServer.get_bus_index("Voice") >= 0 else "Master"
	add_child(_voice)
	_voice.finished.connect(_on_voice_finished)
	add_to_group("ai_characters")
	add_to_group(PonyCrowd.MEMBERS)
	_crowd = PonyCrowd.for_pony(self)


func _build_body() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.16
	shape.height = 0.66
	_collision = CollisionShape3D.new()
	_collision.name = "Collision"
	_collision.shape = shape
	_collision.position.y = shape.height / 2.0
	add_child(_collision)
	collision_layer = 2
	floor_mask = 1
	collision_mask = floor_mask
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(profile.max_slope_degrees)
	floor_constant_speed = true


func _build_model() -> void:
	pivot = Node3D.new(); pivot.name = "Pivot"
	add_child(pivot)
	_model = MODEL.instantiate() as Node3D
	_model.name = "Model"
	_model.rotation.y = PI
	pivot.add_child(_model)
	skeleton = _model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_anim = _model.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	_anim.stop()
	for library_name in _anim.get_animation_library_list():
		var library := _anim.get_animation_library(library_name)
		for clip in library.get_animation_list():
			library.get_animation(clip).loop_mode = Animation.LOOP_LINEAR if str(clip) in LOOPS else Animation.LOOP_NONE
	_build_tree()


## Base states crossfade (Transition), scaled to ground speed; a talking-hands loop and one-shot
## gestures ride the upper body; one-shot actions take the whole body.
func _build_tree() -> void:
	_tree_root = AnimationNodeBlendTree.new()
	var base := AnimationNodeTransition.new()
	base.xfade_time = 0.25
	for clip: String in BASE_CLIPS:
		base.add_input(clip)
		var node := AnimationNodeAnimation.new(); node.animation = clip
		_tree_root.add_node("clip_" + clip, node)
	_tree_root.add_node("base", base)
	for i in BASE_CLIPS.size(): _tree_root.connect_node("base", i, "clip_" + BASE_CLIPS[i])
	_tree_root.add_node("speed", AnimationNodeTimeScale.new())
	_tree_root.connect_node("speed", 0, "base")
	var talk_clip := AnimationNodeAnimation.new(); talk_clip.animation = "talk"
	_tree_root.add_node("talk_clip", talk_clip)
	var talk := AnimationNodeBlend2.new(); _filter_upper(talk)
	_tree_root.add_node("talk", talk)
	_tree_root.connect_node("talk", 0, "speed"); _tree_root.connect_node("talk", 1, "talk_clip")
	# One fixed clip node per gesture, chosen by a Transition parameter. Swapping the clip of a
	# node while the tree runs crashed Godot 4.5 (signal 11 in the town lab), so nothing in the
	# tree resource changes after it is built; playback only sets parameters.
	_add_picker("gesture_pick", GESTURES + ["write"])
	var gesture := AnimationNodeOneShot.new(); _filter_upper(gesture)
	gesture.fadein_time = 0.2; gesture.fadeout_time = 0.3
	# Looping clips (write) still end as a one-shot.
	gesture.break_loop_at_end = true
	_tree_root.add_node("gesture", gesture)
	_tree_root.connect_node("gesture", 0, "talk"); _tree_root.connect_node("gesture", 1, "gesture_pick")
	_add_picker("action_pick", ACTIONS)
	var action := AnimationNodeOneShot.new()
	action.fadein_time = 0.15; action.fadeout_time = 0.25
	_tree_root.add_node("action", action)
	action.break_loop_at_end = true
	_tree_root.connect_node("action", 0, "gesture"); _tree_root.connect_node("action", 1, "action_pick")
	_tree_root.connect_node("output", 0, "action")
	tree = AnimationTree.new(); tree.name = "AnimationTree"
	_model.add_child(tree)
	tree.anim_player = tree.get_path_to(_anim)
	tree.root_node = tree.get_path_to(_model)
	tree.tree_root = _tree_root
	tree.active = true
	tree.set("parameters/base/transition_request", "idle")


## A Transition named `picker` over one clip node per name (no crossfade: a one-shot fades it).
func _add_picker(picker: String, clips: Array) -> void:
	var pick := AnimationNodeTransition.new()
	pick.xfade_time = 0.0
	for clip: String in clips:
		pick.add_input(clip)
		var node := AnimationNodeAnimation.new(); node.animation = clip
		_tree_root.add_node(picker + "_" + clip, node)
	_tree_root.add_node(picker, pick)
	for i in clips.size(): _tree_root.connect_node(picker, i, picker + "_" + clips[i])

func _filter_upper(node: AnimationNode) -> void:
	node.filter_enabled = true
	var sample := _anim.get_animation("wave")
	if sample == null: return
	for i in sample.get_track_count():
		var path := sample.track_get_path(i)
		var bone := str(path.get_concatenated_subnames())
		var upper := bone in UPPER or bone.contains("Finger")
		if upper: node.set_filter_path(path, true)


## Cel look like the ponies (toon diffuse and specular on the model's own colours), the drawn eyes,
## and the face mesh whose shape keys carry his expressions.
func _dress_materials(eyes: Array[ShaderMaterial]) -> MeshInstance3D:
	var face_mesh: MeshInstance3D
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null: continue
		mi.visibility_range_end = 220.0
		mi.visibility_range_end_margin = 10.0
		if mi.mesh.get_blend_shape_count() > 0 and face_mesh == null: face_mesh = mi
		for s in mi.mesh.get_surface_count():
			var source := mi.mesh.surface_get_material(s)
			var label := source.resource_name.to_lower() if source != null else ""
			if label.begins_with("eyeball"):
				var eye := ShaderMaterial.new()
				eye.shader = EYE_SHADER
				eye.set_shader_parameter("iris_texture", IRIS_L if label.ends_with("_l") else IRIS_R)
				mi.set_surface_override_material(s, eye)
				eyes.append(eye)
			elif source is StandardMaterial3D:
				mi.set_surface_override_material(s, _toon(source as StandardMaterial3D, label))
	return face_mesh

## The ponies' show look (pony_dressing.gd preset 3): the cel bands with a guide-style shadow
## colour, so shade keeps his purple instead of taking the sky's blue, and the lit line around him.
const CEL_BASE := preload("res://addons/cel-shader/cel-shader-base.gdshader")
const OUTLINE_LIT := preload("res://addons/cel-shader/cel-outline-lit.gdshader")
const SHADE := Color(0.93, 0.91, 0.96, 1.0)
## The model's own colours with toon light bands (the cel shader's fixed shade darkened his
## lavender towards blue-violet, dev 2026-10-18: "the colors are wrong"), plus the ponies' lit line.
func _toon(source: StandardMaterial3D, label: String) -> StandardMaterial3D:
	var mat := source.duplicate() as StandardMaterial3D
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	mat.specular_mode = BaseMaterial3D.SPECULAR_TOON
	mat.roughness = 0.9
	mat.metallic_specular = 0.15
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	if label in ["teeth", "tongue"]: return mat
	var line: Color = mane_line() if label in ["backspines", "hair", "ears"] else coat_line()
	var outline := ShaderMaterial.new()
	outline.shader = OUTLINE_LIT
	outline.set_shader_parameter("color", line)
	outline.set_shader_parameter("shadow_color", Color(line.r * SHADE.r, line.g * SHADE.g, line.b * SHADE.b, 1.0))
	outline.set_shader_parameter("face_viewer", true)
	outline.set_shader_parameter("outline_width", 0.003)
	outline.set_shader_parameter("specular", Color(0, 0, 0, 0))
	outline.set_shader_parameter("fresnel", Color(0, 0, 0, 0))
	mat.next_pass = outline
	return mat

func _cel(source: StandardMaterial3D, label: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = CEL_BASE
	mat.set_shader_parameter("color", source.albedo_color)
	if source.albedo_texture != null: mat.set_shader_parameter("base_texture", source.albedo_texture)
	# The shade multiplies the fill (texture or flat colour): same hue, one band darker.
	var flat := source.albedo_color if source.albedo_texture == null else Color.WHITE
	mat.set_shader_parameter("shadow_color", Color(flat.r * SHADE.r, flat.g * SHADE.g, flat.b * SHADE.b, 1.0) if source.albedo_texture == null else SHADE)
	mat.set_shader_parameter("specular", Color(0.1, 0.1, 0.1, 0.1))
	mat.set_shader_parameter("fresnel", Color(0.1, 0.1, 0.1, 0.1))
	if label in ["teeth", "tongue"]: return mat
	var line: Color = mane_line() if label == "acces" else coat_line()
	var outline := ShaderMaterial.new()
	outline.shader = OUTLINE_LIT
	outline.set_shader_parameter("color", line)
	outline.set_shader_parameter("shadow_color", Color(line.r * SHADE.r, line.g * SHADE.g, line.b * SHADE.b, 1.0))
	outline.set_shader_parameter("face_viewer", true)
	outline.set_shader_parameter("outline_width", 0.003)
	outline.set_shader_parameter("specular", Color(0, 0, 0, 0))
	outline.set_shader_parameter("fresnel", Color(0, 0, 0, 0))
	mat.next_pass = outline
	return mat


# --- motion contract (same as pony_locomotion.gd) -------------------------------------------

func set_body_scale(scale_factor: float) -> void:
	scale_factor = clampf(scale_factor, 0.25, 4.0)
	if is_equal_approx(scale_factor, body_scale): return
	var relative := scale_factor / body_scale
	body_scale = scale_factor
	profile.rescale(relative)
	var capsule := (_collision.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	capsule.radius = 0.16 * body_scale
	capsule.height = 0.66 * body_scale
	_collision.shape = capsule
	_collision.position.y = capsule.height / 2.0
	floor_snap_length = 0.3 * body_scale
	pivot.scale = Vector3.ONE * body_scale

func back_up(speed: float) -> void:
	speed = clampf(speed, 0.0, 0.3)
	if speed <= 0.0:
		if backing: stop()
		return
	if posture.active(): posture.request("stand")
	_nav_motion = false
	_face_direction = Vector3.ZERO
	backing = true
	var back := global_basis.z; back.y = 0.0
	_desired = back.normalized() * speed

func set_desired_velocity(world_velocity: Vector3) -> void:
	if posture.active() and world_velocity.length() > .05: posture.request("stand")
	backing = false
	_nav_motion = false
	_face_direction = Vector3.ZERO
	_desired = Vector3(world_velocity.x, 0.0, world_velocity.z).limit_length(profile.max_travel_speed)

func stop() -> void:
	_nav_motion = false
	backing = false
	_desired = Vector3.ZERO
	_face_direction = Vector3.ZERO

func accept_navigation_motion(forward_speed: float, yaw_rate: float, mode: int, gait_speed := -1.0) -> void:
	if not (is_finite(forward_speed) and is_finite(yaw_rate)):
		stop(); return
	if posture.active() and (forward_speed > .05 or mode == NAV_MODE_STEP_TURN): posture.request("stand")
	_face_direction = Vector3.ZERO
	_nav_motion = true
	_nav_speed = clampf(forward_speed, 0.0, profile.max_travel_speed)
	_nav_yaw_rate = clampf(yaw_rate, -steer_turn_rate, steer_turn_rate)
	_nav_mode = mode
	_nav_gait_speed = clampf(gait_speed, 0.0, profile.max_travel_speed) if gait_speed >= 0.0 and is_finite(gait_speed) else _nav_speed
	_nav_frame = Engine.get_physics_frames()
	var forward := -global_basis.z; forward.y = 0.0
	_desired = forward.normalized() * _nav_speed if forward.length_squared() > 1e-6 else Vector3.ZERO

func _nav_motion_live() -> bool:
	if not _nav_motion: return false
	if Engine.get_physics_frames() - _nav_frame > 6:
		_nav_motion = false
		_desired = Vector3.ZERO
		return false
	return true

func face_direction(world_direction: Vector3) -> void:
	_nav_motion = false
	backing = false
	_desired = Vector3.ZERO
	_face_direction = Vector3(world_direction.x, 0.0, world_direction.z).normalized() if world_direction.is_finite() else Vector3.ZERO

func jump(speed: float) -> bool:
	if not is_on_floor() or _held: return false
	_jump_request = speed
	return true

func lunge(world_velocity: Vector3, seconds: float) -> void:
	_nav_motion = false
	_lunge_velocity = Vector3(world_velocity.x, 0.0, world_velocity.z).limit_length(profile.max_travel_speed)
	_lunge_left = maxf(seconds, 0.0)

func grounded() -> bool:
	return is_on_floor() or _air_time < 0.2

func reset_motion(world_transform: Transform3D) -> void:
	thrown.cancel()
	posture.reset()
	global_transform = world_transform
	velocity = Vector3.ZERO
	_speed = 0.0
	_air_time = 0.0
	stop()

func set_moving_support(frame: Node3D) -> void:
	moving_support = frame

func apply_body_impulse(world_impulse: Vector3) -> void:
	velocity += world_impulse.limit_length(0.3)

func begin_touch(world_force: Vector3 = Vector3(0.0, -2.0, 0.0), seconds: float = 0.8) -> void:
	if _held: return
	_interaction = "PETTING"
	_interaction_seconds = maxf(seconds, 0.0)
	_touch_force = world_force.limit_length(8.0)

func _touch_blocks() -> bool:
	return not _interaction.is_empty() and not (steer_through_touch and _interaction == "PETTING")


# --- holding ---------------------------------------------------------------------------------

func begin_grab(grip: String, world_target: Vector3, player_head: Vector3) -> void:
	placement_recovery.picked_up(self)
	if sleeping: sleeping = false
	thrown.cancel()
	_hand_targets.clear()
	_held = true
	floor_snap_length = 0.0
	_hold_velocity = velocity
	_hold_target = world_target
	_hold_root_offset = get_grip_transform(grip).origin - global_position
	_interaction = "HELD"
	_interaction_seconds = 0.0
	_touch_force = Vector3.ZERO
	carry.begin(grip, player_head)
	posture.reset(true)
	physical_reaction.emit("picked_up")

func begin_two_hand_grab(left_target: Vector3, right_target: Vector3, player_head: Vector3) -> void:
	begin_grab("chest", (left_target + right_target) * 0.5, player_head)
	_hand_targets = {"left_chest": left_target, "right_chest": right_target}

func update_hand_grab(grip: String, world_target: Vector3, player_head: Vector3) -> void:
	if not _hand_targets.has(grip): return
	_hand_targets[grip] = world_target
	var hold := Vector3.ZERO
	for target: Vector3 in _hand_targets.values(): hold += target / _hand_targets.size()
	_hold_target = hold
	carry.look_target = player_head

func release_hand_grab(grip: String) -> void:
	if not _hand_targets.has(grip):
		if _hand_targets.is_empty() and grip == carry.grip_name: end_interaction()
		return
	_hand_targets.erase(grip)
	if _hand_targets.is_empty(): end_interaction()
	elif _hand_targets.size() == 1:
		carry.grip_name = _hand_targets.keys()[0]
		_hold_target = _hand_targets.values()[0]

func update_grab(world_target: Vector3, player_head: Vector3) -> void:
	var shift: Vector3 = world_target - _hold_target
	for grip: String in _hand_targets: _hand_targets[grip] = Vector3(_hand_targets[grip]) + shift
	_hold_target = world_target
	carry.look_target = player_head

func update_hold(world_position: Vector3) -> void:
	update_grab(world_position + _hold_root_offset, carry.look_target)

func begin_hold(world_position: Vector3) -> void:
	var offset: Vector3 = get_grip_transform().origin - global_position
	begin_grab("chest", world_position + offset, global_position - global_basis.z * 1.5 + Vector3.UP * 1.5)

func set_hold_yaw(yaw: float) -> void:
	_hold_yaw = yaw

func get_grip_transform(grip: String = "chest") -> Transform3D:
	return carry.grip_transform(grip)

func end_interaction() -> void:
	var was_held := _held
	if _held: floor_snap_length = 0.3 * body_scale
	_held = false
	_interaction = ""
	_interaction_seconds = 0.0
	_touch_force = Vector3.ZERO
	_hand_targets.clear()
	_hold_yaw = INF
	var head: Vector3 = carry.look_target
	carry.end()
	if was_held: preload("res://world/characters/locomotion/placement_recovery.gd").clear_release(self, head)

func throw_pony(momentum: Vector3) -> bool:
	end_interaction()
	if not thrown.launch(momentum): return false
	physical_reaction.emit("thrown")
	return true

func is_held() -> bool: return _held
func resting_hold() -> bool: return false
func is_pinned() -> bool: return _held
func body_pinned() -> bool: return _held
func needs_full_rate() -> bool: return _held or thrown.active()


# --- crowd tiers -----------------------------------------------------------------------------

func set_sim_tier(tier: int, _phase: int = 0) -> void:
	if tier == sim_tier: return
	sim_tier = tier
	# Far away nothing reads his pose closely: freeze the skeleton work, keep the body moving.
	tree.active = tier != SimTier.FAR
	_look.active = tier == SimTier.HERO
	if NEAR_PHYSICS_RATE:
		# HERO keeps the per-frame tree and modifier pass (the look modifier runs there); NEAR has no
		# active modifier and FAR no tree.
		var hero := tier == SimTier.HERO
		tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE if hero \
			else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
		skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE if hero \
			else Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS

func set_detail_divisor(_divisor: int, _phase: int = 0) -> void: pass
func is_logic_tick() -> bool: return true
func logic_divisor() -> int: return 1
func logic_alpha() -> float: return 1.0
func has_clip_tier() -> bool: return false
## No baked clips, but set_sim_tier above handles NEAR/FAR itself, so the crowd ranks him by
## distance instead of pinning him to HERO everywhere (2026-10-23 CPU pass: full detail at 300 m).
func own_far_tier() -> bool: return true
func refresh_hidden_clip() -> void: pass
func refresh_geometry_variant(_variant: String) -> void: pass
func set_near_mesh(_on: bool) -> void: pass
func clip_floor_hit(_point: Vector3) -> Dictionary: return {}
func set_rig_parking(_on: bool) -> void: pass


# --- posture ---------------------------------------------------------------------------------

func request_posture(kind: String) -> bool:
	return posture.request(kind)

func posture_status() -> Dictionary:
	return {"kind": posture.kind if posture.progress > 0.0 else "stand", "requested": posture.requested, "settled": posture.settled(), "refusal": posture.refusal}

func is_sitting() -> bool:
	return posture.requested == "sit" and posture.progress > 0.5

func stand_up() -> void:
	posture.request("stand")

func wake_up() -> void:
	if not sleeping: return
	sleeping = false
	posture.request("sit")


# --- physics ---------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	posture.update(delta)
	carry.advance(delta)
	if _interaction_seconds > 0.0:
		_interaction_seconds -= delta
		if _interaction_seconds <= 0.0 and _interaction == "PETTING": _interaction = ""
	if _held:
		_hold_step(delta)
		return
	if thrown.step(delta):
		state = Motion.UNSUPPORTED
		return
	var forward := -global_basis.z; forward.y = 0.0; forward = forward.normalized()
	var wanted := 0.0
	var yaw_rate := 0.0
	nav_refusal = NAV_REFUSAL_NONE
	var still: bool = motion_paused or sleeping or posture.progress > 0.0 or _touch_blocks()
	if _lunge_left > 0.0:
		_lunge_left -= delta
		var lunge_dir := _lunge_velocity.normalized()
		if lunge_dir.length() > 0.1: yaw_rate = _turn_toward(lunge_dir, delta)
		wanted = _lunge_velocity.length()
	elif still:
		if _touch_blocks(): nav_refusal = NAV_REFUSAL_TOUCH
	elif _nav_motion_live():
		if _nav_mode == NAV_MODE_STEP_TURN:
			yaw_rate = _nav_yaw_rate
		elif _nav_mode in [NAV_MODE_STOP, NAV_MODE_HOLD, NAV_MODE_BRAKE]:
			wanted = 0.0
			yaw_rate = _nav_yaw_rate if _nav_mode == NAV_MODE_HOLD else 0.0
		else:
			wanted = _nav_speed
			yaw_rate = clampf(_nav_yaw_rate / maxf(_nav_speed, 0.05) * maxf(_speed, 0.05), -steer_turn_rate, steer_turn_rate) if _nav_speed > 0.0001 else _nav_yaw_rate
	elif _desired.length() > 0.02:
		var dir := _desired.normalized()
		if backing:
			wanted = -_desired.length()
		else:
			yaw_rate = _turn_toward(dir, delta)
			wanted = _desired.length() * maxf(0.0, forward.dot(dir))
	elif _face_direction.length() > 0.1:
		yaw_rate = _turn_toward(_face_direction, delta)
	rotation.y += yaw_rate * delta
	nav_executed_yaw_rate = yaw_rate
	var rate: float = profile.acceleration if absf(wanted) > absf(_speed) else profile.braking
	_speed = move_toward(_speed, wanted, rate * delta)
	forward = -global_basis.z; forward.y = 0.0; forward = forward.normalized()
	var horizontal := forward * _speed
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if is_on_floor():
		_air_time = 0.0
		if _jump_request > 0.0:
			velocity.y = _jump_request
			_jump_request = 0.0
			audio_jumped.emit(global_position)
			play_action("jump")
		else:
			velocity.y = minf(velocity.y, 0.0)
	else:
		_air_time += delta
		velocity.y -= 9.8 * delta
	var was_air := _air_time > 0.25
	var fall_speed := -velocity.y
	if _slide_still(wanted):
		_slide_rested += 1
	else:
		move_and_slide()
		_slide_rested = 0
		_slide_rest = global_position
	if is_on_floor() and was_air: audio_landed.emit(global_position, fall_speed)
	_hold_heightmap(delta)
	_ground_velocity = get_real_velocity()
	actual_speed = Vector2(_ground_velocity.x, _ground_velocity.z).length()
	nav_executed_speed = absf(_speed)
	nav_wall_normal = get_wall_normal() if is_on_wall() else Vector3.ZERO
	if is_on_wall() and _speed > 0.1 and _ground_velocity.length() < 0.05: nav_refusal = NAV_REFUSAL_SUPPORT
	_footsteps(delta)
	if not grounded(): state = Motion.UNSUPPORTED
	elif actual_speed > 0.05: state = Motion.MOVING
	else: state = Motion.STANDING

## Standing still on a still floor (0.1.0 perf pass), move_and_slide only repeated its floor snap
## and casts against the room: no motion, same floor, same contacts. He then keeps his place and floor
## state for up to SLIDE_RECHECK ticks between real calls. Any velocity, push, jump, wanted speed,
## moved position (a teleport, a carry) or moving floor slides as before, and the recheck finds a
## vanished floor within 1/15 s. Rollback: SLIDE_RECHECK = 0.
const SLIDE_RECHECK := 3
var _slide_rested := 0
var _slide_rest := Vector3.INF

func _slide_still(wanted: float) -> bool:
	return _slide_rested < SLIDE_RECHECK and wanted == 0.0 and _speed == 0.0 and _jump_request <= 0.0 \
		and velocity.length_squared() < 1e-8 and is_on_floor() and global_position == _slide_rest \
		and get_platform_velocity() == Vector3.ZERO and get_platform_angular_velocity() == Vector3.ZERO


func _turn_toward(direction: Vector3, delta: float) -> float:
	var forward := -global_basis.z; forward.y = 0.0
	if forward.length() < 0.01 or direction.length() < 0.01: return 0.0
	var angle := forward.normalized().signed_angle_to(direction.normalized(), Vector3.UP)
	return clampf(angle / maxf(delta, 1e-4), -steer_turn_rate, steer_turn_rate)

## The big world only has terrain collision near the camera: with no floor under him and the
## heightmap above his feet, he stands on the heightmap instead of falling through (as ponies do).
func _hold_heightmap(delta: float) -> void:
	if is_on_floor():
		_unsupported_seconds = 0.0
		return
	_unsupported_seconds += delta
	if _unsupported_seconds < 0.25 or not is_instance_valid(WorldTerrain.instance): return
	var h: float = WorldTerrain.instance.height_at(global_position)
	if not is_finite(h): return
	var space := get_world_3d().direct_space_state
	var below := space.intersect_ray(PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.4, global_position - Vector3.UP * 2.0, floor_mask, [get_rid()]))
	if below.is_empty() and global_position.y < h + 0.05:
		global_position.y = h
		velocity.y = 0.0
		_air_time = 0.0

func _hold_step(delta: float) -> void:
	state = Motion.HELD
	var goal := _hold_target - _hold_root_offset
	var before := global_position
	global_position = global_position.lerp(goal, minf(1.0, delta * 18.0))
	velocity = (global_position - before) / maxf(delta, 1e-4)
	if is_finite(_hold_yaw): rotation.y = lerp_angle(rotation.y, _hold_yaw, minf(1.0, delta * 10.0))
	elif carry.look_target.is_finite():
		var toward: Vector3 = carry.look_target - global_position; toward.y = 0.0
		if toward.length() > 0.05: rotation.y = lerp_angle(rotation.y, atan2(-toward.x, -toward.z), minf(1.0, delta * 6.0))
	actual_speed = 0.0
	_speed = 0.0

func _footsteps(delta: float) -> void:
	if not is_on_floor() or actual_speed < 0.05: return
	_step_travel += actual_speed * delta
	var step := (STEP_RUN if actual_speed > RUN_FROM else STEP_WALK) * body_scale
	if _step_travel < step: return
	_step_travel = 0.0
	_left_step = not _left_step
	var side := global_basis.x * (0.07 if _left_step else -0.07) * body_scale
	hoof_planted.emit(global_position + side)


# --- animation, face and gaze ------------------------------------------------------------------

func _process(delta: float) -> void:
	_gesture_left = maxf(0.0, _gesture_left - delta)
	_action_left = maxf(0.0, _action_left - delta)
	_choose_base()
	var speaking := is_speaking()
	_talk_mix = move_toward(_talk_mix, 1.0 if speaking and _base_clip in ["idle", "sit", "sit_chair"] and not gesture_playing() else 0.0, delta * 3.0)
	if _talk_mix != _talk_set:
		_talk_set = _talk_mix
		tree.set("parameters/talk/blend_amount", _talk_mix)
	if speaking:
		if is_instance_valid(_pcm_player): _speech_time = maxf(0.0, _pcm_player.time)
		else: _speech_time += delta
		expressions.viseme = LipSync.viseme_at(_cues, _speech_time) if not _cues.is_empty() else "X"
	_mouth_hold_left = maxf(0.0, _mouth_hold_left - delta)
	expressions.mouth_open = _mouth_hold if _mouth_hold_left > 0.0 else 0.0
	expressions.pucker = 0.0
	var interest := 0.0
	var gaze_point := _gaze_point()
	if gaze_point.is_finite():
		_look.target = gaze_point
		_look.weight = move_toward(_look.weight, 1.0, delta * 2.0)
		var camera := get_viewport().get_camera_3d()
		if camera != null and gaze_point.distance_to(camera.global_position) < 0.5: interest = 1.0
		_eye_gaze(gaze_point)
	else:
		_look.weight = move_toward(_look.weight, 0.0, delta * 2.0)
		expressions.gaze = Vector2.ZERO
	if sim_tier != SimTier.FAR: expressions.advance(delta, posture.active(), interest, speaking)

func _choose_base() -> void:
	var clip := "idle"
	var clip_scale := 1.0
	var posture_clip: String = posture.clip()
	if not is_instance_valid(_affection): _affection = get_node_or_null("Affection")
	var affection := _affection
	if _held or carry.blend > 0.5: clip = "carried"
	elif thrown.active() or (_air_time > 0.35 and velocity.y < -1.0): clip = "fall"
	elif posture_clip != "": clip = posture_clip
	elif affection != null and str(affection.kind) == "hug": clip = "hug"
	elif has_meta("dancing"): clip = "dance"
	elif actual_speed > 0.05 or absf(_speed) > 0.05:
		var speed: float = maxf(actual_speed, absf(_speed)) / body_scale
		if speed > RUN_FROM:
			clip = "run"; clip_scale = clampf(speed / RUN_NATIVE, 0.7, 2.8)
		else:
			clip = "walk"; clip_scale = clampf(speed / WALK_NATIVE, 0.5, 2.0)
		if backing or _speed < 0.0: clip_scale = -clip_scale
	if clip != _base_clip:
		_base_clip = clip
		tree.set("parameters/base/transition_request", clip)
	if clip_scale != _scale_set:
		_scale_set = clip_scale
		tree.set("parameters/speed/scale", clip_scale)

## Where he looks: an action target, then his conversation partner, then the player close by.
func _gaze_point() -> Vector3:
	if sleeping: return Vector3.INF
	if is_instance_valid(action_gaze_target): return action_gaze_target.global_position
	if is_instance_valid(conversation_target):
		return conversation_target.listen_point() if conversation_target.has_method("listen_point") else conversation_target.global_position + Vector3.UP * 1.0
	if _held and carry.look_target.is_finite(): return carry.look_target
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var d := camera.global_position.distance_to(global_position)
		var notice: float = float(identity.notice_distance) if identity != null else 5.0
		if d < notice:
			var toward := camera.global_position - global_position; toward.y = 0.0
			var forward := -global_basis.z; forward.y = 0.0
			if toward.length() > 0.01 and forward.normalized().dot(toward.normalized()) > -0.2: return camera.global_position
	return Vector3.INF

## Slide the drawn irises the rest of the way the head did not turn.
func _eye_gaze(point: Vector3) -> void:
	if _head_bone == -2: _head_bone = skeleton.find_bone("Head")
	var head_bone := _head_bone
	if head_bone < 0: return
	var head_frame: Transform3D = skeleton.global_transform * skeleton.get_bone_global_pose(head_bone)
	var eye_centre := head_frame.origin + Vector3.UP * 0.16 * body_scale
	var local := (global_basis.orthonormalized().inverse() * (point - eye_centre))
	var yaw := atan2(-local.x, -local.z)
	var pitch := atan2(local.y, Vector2(local.x, local.z).length())
	var head_yaw: float = _look.get("_yaw")
	var head_pitch: float = _look.get("_pitch")
	expressions.gaze = Vector2(clampf((yaw - head_yaw) * 0.12, -0.1, 0.1), clampf((pitch - head_pitch) * 0.12, -0.08, 0.08))

## Plays an upper-body gesture over whatever he is doing. False if the clip does not exist or one
## is already playing.
func play_gesture(clip: String) -> bool:
	if sim_tier == SimTier.FAR or not _anim.has_animation(clip) or gesture_playing(): return false
	if clip not in GESTURES: return false
	tree.set("parameters/gesture_pick/transition_request", clip)
	tree.set("parameters/gesture/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_gesture_left = _anim.get_animation(clip).length
	return true

func gesture_playing() -> bool:
	return _gesture_left > 0.0

## Plays a whole-body action (cheer, jump, fire, kick).
func play_action(clip: String) -> bool:
	if not _anim.has_animation(clip) or _action_left > 0.0: return false
	if clip not in ACTIONS: return false
	tree.set("parameters/action_pick/transition_request", clip)
	tree.set("parameters/action/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_action_left = _anim.get_animation(clip).length
	return true

## Holds his mouth open for a while (a yawn, a bite, a breath of fire).
func mouth_hold(seconds: float, amount: float) -> void:
	_mouth_hold_left = seconds
	_mouth_hold = amount

## Dialogue gesture tags (pony_dialogue_tags.gd). A pony's [hoofraise] is his pointing claw;
## his own: [wave], [cheer], [point], [shrug], [fire] (a puff of green flame), [eat].
func gesture(name: String) -> bool:
	var parts := name.split(":")
	match parts[0]:
		"hoofraise", "point": return play_gesture("point")
		"wave": return play_gesture("wave")
		"shrug": return play_gesture("shrug")
		"eat": return play_gesture("eat")
		"cheer": return play_action("cheer")
		"fire": return breathe_fire()
	return false

func door_gesture(_door: Node3D) -> void:
	play_gesture("door")

## A breath of green dragon fire (his letter-sending flame). Plays the clip and the flame.
func breathe_fire(letter: Node3D = null) -> bool:
	if not play_action("fire"): return false
	mouth_hold(2.2, 0.8)
	var flame := preload("res://world/characters/spike/spike_fire.gd").new()
	add_child(flame)
	flame.start(self, letter)
	return true

## Where something held in his right claw sits (snacks, the letter): the hand bone, a little
## out along the fingers, at a claw-sized scale.
func claw_frame() -> Transform3D:
	var bone := skeleton.find_bone(RIGHT_HAND)
	var hand: Transform3D = skeleton.global_transform * skeleton.get_bone_global_pose(bone) if bone >= 0 else global_transform
	var basis := global_basis.orthonormalized().scaled(Vector3.ONE * 0.6 * body_scale)
	return Transform3D(basis, hand.origin + global_basis.orthonormalized() * Vector3(0, 0.0, -0.03) * body_scale)

## Writes a quick note on a scroll and sends it to Princess Celestia with his fire, as he does
## for Twilight's friendship reports: the letter appears in his claw, he scribbles, then one
## green breath turns it to sparks. False while he is held, asleep or busy.
const LETTER := "res://world/props/ponyville_kit/activity/letter.scn"
var _letter_busy := false
func send_letter() -> bool:
	if _letter_busy or _held or sleeping or thrown.active() or gesture_playing() or _action_left > 0.0: return false
	_letter_busy = true
	_letter_run()
	return true

func _letter_run() -> void:
	var holder := Node3D.new(); holder.name = "SpikeLetter"; holder.top_level = true
	add_child(holder)
	if ResourceLoader.exists(LETTER): holder.add_child((load(LETTER) as PackedScene).instantiate())
	var follow := func(): if is_instance_valid(holder): holder.global_transform = claw_frame()
	stop()
	for i in 2:
		_play_write()
		var left := 1.2
		while left > 0.0:
			follow.call()
			if not await SHUTDOWN.seconds(self, 0.05): return
			left -= 0.05
	follow.call()
	if breathe_fire(holder):
		# Sent: Princess Celestia answers the next morning (world/ai/celestia_reply.gd; player thread
		# report 2026-10-29, a letter that never got a reply stayed on Twilight's mind for days).
		get_tree().call_group("celestia_reply", "letter_sent", str(identity.id) if identity != null else "spike")
	else: holder.queue_free()
	if not await SHUTDOWN.seconds(self, 2.0): return
	_letter_busy = false

## Princess Celestia's answer coming back (world/ai/celestia_reply.gd): one green belch, and the
## reply scroll grows out of the flame into his claw; he holds it up a moment, then tucks it away.
## False while he is held, asleep or busy, so the reply waits for him.
func receive_letter() -> bool:
	if _letter_busy or _held or sleeping or thrown.active() or gesture_playing() or _action_left > 0.0: return false
	stop()
	if not breathe_fire(): return false
	_letter_busy = true
	_reply_run()
	return true

func _reply_run() -> void:
	# spike_fire.gd lights the flame BREATH_DELAY (0.95 s) in; the scroll appears inside it.
	if not await SHUTDOWN.seconds(self, 1.1): return
	var holder := Node3D.new(); holder.name = "SpikeReply"; holder.top_level = true
	add_child(holder)
	if ResourceLoader.exists(LETTER): holder.add_child((load(LETTER) as PackedScene).instantiate())
	var held := 0.0
	while held < 4.0:
		holder.global_transform = claw_frame().scaled_local(Vector3.ONE * clampf(held / 0.3, 0.05, 1.0))
		if not await SHUTDOWN.seconds(self, 0.05): return
		held += 0.05
	holder.queue_free()
	_letter_busy = false

## The "write" loop as a short upper-body gesture.
func _play_write() -> void:
	if not _anim.has_animation("write"): return
	tree.set("parameters/gesture_pick/transition_request", "write")
	tree.set("parameters/gesture/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_gesture_left = 1.2

func cast_magic(_seconds := 2.5) -> bool: return false
func request_flight(_destination: Vector3, _hover_seconds := 0.0, _long_range := false) -> bool: return false
func request_fun_flight() -> bool: return false
func request_trick(_kind: String, _centre := Vector3.INF) -> bool: return false
func request_show(_moves: Array, _centre := Vector3.INF) -> bool: return false
func request_arrival(_landing: Vector3) -> bool: return false

func action_interruption_reason() -> String:
	if has_meta("balloon_passenger"): return "Riding a hot-air balloon"
	if get_meta("affection_active", false): return "Affection or defensive gesture"
	if thrown.active(): return "Recovering from a throw"
	if _held: return "Being held"
	if motion_paused: return "Motion paused"
	if not _interaction.is_empty(): return "Physical interaction"
	if not grounded(): return "Waiting for safe ground support"
	return ""


# --- conversation ------------------------------------------------------------------------------

func set_action_gaze(target: Node3D) -> void:
	action_gaze_target = target

func set_conversation_target(listener: Node3D, _hold_position := true) -> void:
	conversation_target = listener

## A line that is still arriving from the voice server ("pcm://utterance/N" from tts_client.gd).
const PCM_UTTERANCE := preload("res://world/ai/pcm_utterance.gd")
const PCM_PLAYER := preload("res://world/characters/pcm_speech_player.gd")
var _pcm_player: Node

func supports_pcm_speech() -> bool:
	return is_instance_valid(_voice)

func _speak_pcm(path: String) -> void:
	var utterance: RefCounted = PCM_UTTERANCE.take(path)
	if utterance == null or not is_instance_valid(_voice):
		if utterance != null: utterance.cancel()
		speech_failed.emit("PCM speech unavailable")
		return
	_pending_path = path
	_cues = []
	_pcm_player = PCM_PLAYER.new()
	add_child(_pcm_player)
	_pcm_player.started.connect(func() -> void:
		print("[voice] %s plays %s (streamed)" % [name, _pending_path.get_file()])
		_speech_time = 0.0
		speech_started.emit())
	_pcm_player.finished.connect(_pcm_ended.bind(""))
	_pcm_player.failed.connect(_pcm_ended)
	_pcm_player.begin(utterance, _voice)
	_cues = _pcm_player.cues

## The stream player's end: only a line that played out counts as finished.
func _pcm_ended(message: String) -> void:
	_drop_pcm_player()
	_speech_time = -1.0
	_cues = []
	expressions.viseme = "X"
	if message.is_empty(): speech_finished.emit()
	else: speech_failed.emit(message)

func _drop_pcm_player() -> void:
	if is_instance_valid(_pcm_player):
		_pcm_player.cancel()
		_pcm_player.queue_free()
	_pcm_player = null

func say(wav_path: String, text := "") -> void:
	stop_speaking()
	if PCM_UTTERANCE.is_uri(wav_path):
		_speak_pcm(wav_path)
		return
	var stream := LipSync.load_wav(wav_path)
	if stream == null or stream.get_length() <= 0.0:
		speech_failed.emit("Cannot load voice audio")
		return
	_pending_stream = stream
	_pending_path = wav_path
	_speech_generation += 1
	LipSync.analyse_async(wav_path, text, _on_cues.bind(_speech_generation))

func _on_cues(cues: Array, generation := -1) -> void:
	if not is_inside_tree() or is_queued_for_deletion(): return
	if generation != _speech_generation or _pending_stream == null: return
	_cues = cues
	_voice.stream = _pending_stream
	_pending_stream = null
	_voice.play()
	print("[voice] %s plays %s (%.1f s)" % [name, _pending_path.get_file(), _voice.stream.get_length()])
	_speech_time = 0.0
	speech_started.emit()

func _on_voice_finished() -> void:
	if _speech_time < 0.0: return
	_speech_time = -1.0
	_cues = []
	expressions.viseme = "X"
	speech_finished.emit()

func stop_speaking() -> void:
	_speech_generation += 1
	_pending_stream = null
	_drop_pcm_player()
	if _voice != null and _voice.playing: _voice.stop()
	if _speech_time >= 0.0:
		_speech_time = -1.0
		_cues = []
		expressions.viseme = "X"
		speech_finished.emit()

func is_speaking() -> bool:
	return _speech_time >= 0.0

func speech_progress() -> Dictionary:
	if _voice == null or _voice.stream == null: return {}
	# A line still arriving from the voice server has no length yet: callers estimate from the text.
	if is_instance_valid(_pcm_player): return {"time": maxf(0.0, _speech_time)}
	return {"time": maxf(0.0, _speech_time), "duration": _voice.stream.get_length()}

func listen_point() -> Vector3:
	return boop_node.nose_world() if boop_node != null else global_position + Vector3.UP * 0.5 * body_scale

func speech_indicator_point() -> Vector3:
	return global_position + Vector3.UP * 0.95 * body_scale

func awareness_forward() -> Vector3:
	var yaw: float = _look.get("_yaw") if _look != null else 0.0
	return (Basis(Vector3.UP, yaw) * -global_basis.z).normalized()

func vocal() -> Node:
	var runtime: Variant = get_meta("relationship_runtime") if has_meta("relationship_runtime") else null
	if runtime == null or not is_instance_valid(runtime.game) or not is_instance_valid(runtime.game.director): return null
	return runtime.game.director.vocal

func set_dialogue_expression(value: String) -> void:
	if expressions != null: expressions.set_dialogue(value)

func clear_dialogue_expression() -> void:
	if expressions != null: expressions.clear_dialogue()

func finish_dialogue_expression() -> void:
	if expressions != null: expressions.finish_dialogue()


# --- touch -------------------------------------------------------------------------------------

func arm_boop(left_hand: Node3D, right_hand: Node3D, left_controller: Node, right_controller: Node) -> void:
	boop_node.arm(left_hand, right_hand, left_controller, right_controller)

func boop() -> void:
	boop_node.boop()

func on_booped() -> void:
	expressions.boop()
	physical_reaction.emit("boop")

func pet(part: String) -> void:
	touch_body.desktop_pet(part)

func boop_count() -> int: return boop_node.boops
func kiss_count() -> int: return boop_node.kisses
func pet_count() -> int: return touch_body.pets
func is_being_petted() -> bool: return touch_body.petting
func pet_region() -> String: return touch_body.pet_region
func is_hoof_held() -> bool: return false
func hoofhold_count() -> int: return 0

func kiss_contact_distance(point: Vector3, _approach := Vector3.ZERO) -> float:
	# His forehead: between the eyes and the front spine.
	var forehead := global_transform * (Vector3(0, 0.66, -0.17) * body_scale)
	return point.distance_to(forehead)

func coat_fill() -> Color: return identity.coat_fill if identity != null else Color("9e73cc")
func coat_line() -> Color: return identity.coat_line if identity != null else Color("5c3380")
func coat_shade() -> Color: return identity.coat_shade if identity != null else Color("8460b0")
func mane_line() -> Color: return identity.mane_line if identity != null else Color("24733a")
