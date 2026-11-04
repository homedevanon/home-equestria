extends RefCounted
## Crowd clip tiers of pony_locomotion.gd (split 2026-10-13; docs/CLIP_TIER_2026_09_25.md): the
## hand-off into and out of the solver-baked clips, and the choice of gait and posture clip. The
## per-step clip motion (_far_tick, _clip_logic, _clip_step, the posture ticks) stays in the pony
## beside the state it shares with the motor. Calls back go through `pony.` so overrides apply.

const BAKED_GAITS := preload("res://world/characters/locomotion/baked_gaits.gd")


## Into NEAR/FAR from the solver: no collision body, the terrain modifier off, the solved pose
## baked into a hand-off clip, and the mixer advanced by hand from _far_tick.
static func enter(pony: Node) -> void:
	pony._logic_delta = 0.0
	pony._logic_steps = 0
	pony._clip_pitch = 0.0
	pony._clip_pitch_target = 0.0
	pony._clip_floor = NAN
	pony._clip_probe_logic = 0
	pony._clip_floor_from_ray = false
	pony._clip_ahead_certified = false
	pony._clip_advance_delta = 0.0
	pony._clip_pivot_settled = false
	pony._posture_pivot_settled = false
	pony._posture_clip_held = false
	pony._clip_blocked = false
	pony._clip_gait_hold = 0.0
	var desired: Vector3 = pony._desired
	var wanted := desired.length()
	pony._clip_wanted = wanted
	pony._clip_yaw = atan2(-desired.x, -desired.z) if wanted > 0.01 else pony.rotation.y
	# Start the first gait clip where the solver's leading leg was, in the gait it was in.
	var step_timing: RefCounted = pony.step_timing
	var hero_gait: String = step_timing.gait
	pony._clip_enter_phase = step_timing.gallop_phase if hero_gait == "gallop" else step_timing.phases[0]
	pony._clip_gait = hero_gait if hero_gait != "trot" else trot_band(pony.profile, "", pony.actual_speed)
	# The head keeps its look: the live head layer starts from the secondary's current angles.
	var secondary: RefCounted = pony.secondary
	var head := PackedVector3Array([secondary.head_angles, secondary.gaze_angles, secondary._neck_gaze])
	pony.clip_head_from = head
	pony.clip_head_to = head.duplicate()
	var collision: CollisionShape3D = pony._collision
	if collision != null:
		collision.disabled = true
	# A hand-off back to the solver still under way ends here.
	pony._hero_blend = 1.0
	pony._overlap_age = -1.0
	end_overlap(pony)
	pony.modifier.active = false
	pony._bake_handoff()
	var pivot: Node3D = pony.pivot
	pony._clip_from = pivot.transform
	pony._clip_blend = 0.0
	pony._clip_age = 0.0
	pony._clip_blend_end = 0.0
	pony._clip_static = false
	var skeleton: Skeleton3D = pony.skeleton
	skeleton.reset_bone_poses()
	for foot: Dictionary in pony.feet:
		foot.planted = false
		foot.valid = false
	pony.self_collision.reset()
	step_timing.reset()
	# Manual: advanced from _far_tick every physics step.
	var animation: AnimationPlayer = pony.animation
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation.speed_scale = 1.0
	var posture: RefCounted = pony.posture
	if posture != null and posture.active() and pony._posture_clip(posture.advance_sleep(0.0)).exact:
		# Mid-posture the baked clip at the posture's own clip time is the solver's pose without
		# the gaze, and the live head adds that gaze back at once: no crossfade needed. (While a
		# sleep pose blends on some other timeline, the hand-off clip below bridges the two.)
		pony._clip_blend = 1.0
		pony._play_posture_clip(posture.advance_sleep(0.0), true)
		animation.advance(0.0)
		return
	var handoff: String = pony.HANDOFF
	animation.play(handoff if animation.has_animation(handoff) else pony._baked_name(BAKED_GAITS.STAND))
	animation.advance(0.0)


## The solver's last prepared pose as a one-key looping clip in this pony's own library, so
## `_far_tick`'s first `play(clip, blend)` crossfades from it instead of cutting. Every bone is
## keyed, not only the gait clips' bones: a mare looking up at the player had her neck cut 45°
## to rest at the switch (dev 2026-09-17); the mixer now blends bones the target clip leaves
## unkeyed from the hand-off pose to their rest value.
static func bake_handoff(pony: Node) -> void:
	var baked: AnimationLibrary = pony._baked
	var base := String(baked.get_meta("base_path", "")) if baked != null else ""
	if base.is_empty():
		return
	var skeleton: Skeleton3D = pony.skeleton
	var prepared: Array = pony.modifier.prepared
	var pose_of: Array = prepared if prepared.size() == skeleton.get_bone_count() else []
	var clip := Animation.new()
	clip.length = 1.0
	clip.loop_mode = Animation.LOOP_LINEAR
	for bone in skeleton.get_bone_count():
		var pose: Transform3D = pose_of[bone] if not pose_of.is_empty() else skeleton.get_bone_pose(bone)
		var path := NodePath(base + ":" + skeleton.get_bone_name(bone))
		var k := clip.add_track(Animation.TYPE_POSITION_3D)
		clip.track_set_path(k, path)
		clip.position_track_insert_key(k, 0.0, pose.origin)
		k = clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(k, path)
		clip.rotation_track_insert_key(k, 0.0, pose.basis.get_rotation_quaternion())
		k = clip.add_track(Animation.TYPE_SCALE_3D)
		clip.track_set_path(k, path)
		clip.scale_track_insert_key(k, 0.0, pose.basis.get_scale())
	var animation: AnimationPlayer = pony.animation
	var library: AnimationLibrary
	if animation.has_animation_library("handoff"):
		library = animation.get_animation_library("handoff")
		if library.has_animation("crowd_handoff"):
			library.remove_animation("crowd_handoff")
	else:
		library = AnimationLibrary.new()
		animation.add_animation_library("handoff", library)
	library.add_animation("crowd_handoff", clip)


## Back onto the solver: the pose the clip was showing, the clip's phase and speed, collision on.
static func leave(pony: Node) -> void:
	pony._set_rest_frozen(false)
	pony._clip_static = false
	var skeleton: Skeleton3D = pony.skeleton
	var animation: AnimationPlayer = pony.animation
	# Until the solver's first tick prepares its own pose, the terrain modifier shows the pose
	# the clip was showing, not whatever it last prepared before she left for the clip tier, and
	# the solver's first poses ease in from it (pony_terrain_modifier.gd start_handoff).
	var shown := shown_pose(pony)
	pony.modifier.prepared = shown
	# Mid-posture (lying, asleep, seated) the solver's FK picks up at the clip's own time below,
	# so only a standing or walking pony eases in from the shown pose.
	var mid_posture: bool = pony.posture != null and pony.posture.active()
	if mid_posture: pony.modifier.cancel_handoff()
	else: pony.modifier.start_handoff(shown)
	# The pivot too: the clip pivot pitches the model about her root, the solver's tilts it about
	# the hips and adds the secondary's sway, so on a slope the two sat ~10 cm apart.
	pony._hero_from = (pony.pivot as Node3D).transform
	pony._hero_from_frame = Engine.get_physics_frames()
	pony._hero_blend = 0.0
	# The clip pivot carries no sway or give (the NEAR stand's lean is a pose layer, eased out by
	# the hand-off above): the solver's starts from none and builds it up after _spawn_settle.
	var secondary: RefCounted = pony.secondary
	secondary.offset = Vector3.ZERO
	secondary.roll = 0.0
	secondary._strength = 0.0
	pony._body_offset = Vector3.ZERO
	pony._body_offset_velocity = Vector3.ZERO
	# The solver picks up at the clip's phase and speed: a pony walking into close range keeps
	# walking instead of stopping to restart her gait.
	var clip_phase := 0.0
	var clip_moving: bool = pony._clip_gait_playing()
	if clip_moving and animation.current_animation_length > 0.0:
		clip_phase = fposmod(animation.current_animation_position / animation.current_animation_length, 1.0)
	animation.pause()
	animation.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	animation.speed_scale = 1.0
	skeleton.reset_bone_poses()
	pony.modifier.active = true
	var collision: CollisionShape3D = pony._collision
	if collision != null:
		collision.disabled = false
	var actual_speed: float = pony.actual_speed
	clip_moving = clip_moving and actual_speed > 0.05
	# A walking pony keeps the clip root's velocity: from zero, the first step read as a 15 m/s²
	# start in _update_give and kicked her body (the give) sideways and back.
	var carried: Vector3 = pony.velocity if clip_moving else Vector3.ZERO
	carried.y = 0.0
	pony.velocity = carried
	pony._command_speed = actual_speed if clip_moving else 0.0
	pony._ground_velocity = carried
	pony._previous_horizontal_velocity = carried
	pony._body_height = 0.0
	# Start from the clip's slope pitch, not level: same sign convention (forward edge up).
	pony._body_tilt = Quaternion(Vector3.RIGHT, float(pony._clip_pitch))
	pony._blend = 1.0 if clip_moving else 0.0
	pony._stop_elapsed = 0.0
	pony.state = pony.Motion.MOVING if clip_moving else pony.Motion.STANDING
	pony.step_timing.reset(clip_phase)
	pony.phase = clip_phase
	var posture: RefCounted = pony.posture
	if posture != null and posture.active():
		# Mid-posture: the solver's FK picks up at the same clip time the baked clip was at, and
		# the posture owns the pivot.
		pony._hero_blend = 1.0
		posture._last_source_time = -1.0
		if posture.phase != "recover":
			posture._join_time = maxf(posture._join_time, 1.0)
	pony._initialized = false
	pony._spawn_settle = 0.35
	pony._corner_speed = INF
	pony._blocked = false
	pony._unsupported_seconds = 0.0
	pony._heightmap_supported = false
	# The grid height that carried her at a distance may sit under the real surface.
	if pony.is_inside_tree():
		pony._recover_support()
	if posture == null or not posture.active():
		settle_root(pony)
	# Whatever she walked into without collision she now eases out of (ease_overlap).
	end_overlap(pony)
	pony._overlap_age = 0.0


## The clip root follows the ray floor with a lag (_clip_step) and a capsule on a slope rests above
## the point under its centre, so her first move_and_slide lifted her: 3 mm standing on a 10° slope,
## 16 mm walking up it, in one step. The root is put where the capsule rests now, and the pivot she
## eases in from (blend_pivot) moves down by as much, so the model stays where it was shown.
const SETTLE_REACH := 0.08

static func settle_root(pony: Node) -> void:
	var body3d := pony as CharacterBody3D
	if not body3d.is_inside_tree(): return
	var params := PhysicsTestMotionParameters3D.new()
	params.from = body3d.global_transform.translated(body3d.up_direction * SETTLE_REACH)
	params.motion = -body3d.up_direction * SETTLE_REACH * 2.0
	params.margin = body3d.safe_margin
	var result := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(body3d.get_rid(), params, result): return
	if result.get_collision_normal().dot(body3d.up_direction) < cos(body3d.floor_max_angle): return
	var lift: float = (body3d.up_direction * SETTLE_REACH + result.get_travel()).dot(body3d.up_direction)
	if absf(lift) < 0.0005 or absf(lift) >= SETTLE_REACH: return
	var world := body3d.up_direction * lift
	body3d.global_position += world
	var from: Transform3D = pony._hero_from
	from.origin -= body3d.global_basis.orthonormalized().inverse() * world
	pony._hero_from = from
	# Now, not at her next step: PonyCrowd may switch her after her step, and that frame is drawn.
	(pony.pivot as Node3D).transform = from


## The pose the clip tier was showing: the clip's bone poses plus the layers the modifier pass put
## over them and did not keep (ClipHead's live head in NEAR, the NEAR stand's IdleBody), applied
## here once more exactly as that pass did, at the influence it ran with.
static func shown_pose(pony: Node) -> Array[Transform3D]:
	var skeleton: Skeleton3D = pony.skeleton
	var clip_head: SkeletonModifier3D = pony._clip_head
	if pony._handoff_clip_head and clip_head != null:
		_layer(skeleton, clip_head, func() -> void: clip_head.call(&"_apply"))
	var idle_body: Variant = pony.get(&"idle_body")
	if idle_body is SkeletonModifier3D and (idle_body as SkeletonModifier3D).active \
			and float(idle_body.get(&"fade")) > 0.0 and not bool(pony._hidden_parked):
		_layer(skeleton, idle_body as SkeletonModifier3D, func() -> void: idle_body.call(&"_apply", 0.0))
	var shown: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		shown.append(skeleton.get_bone_pose(bone))
	return shown


static func _layer(skeleton: Skeleton3D, layer: SkeletonModifier3D, apply: Callable) -> void:
	var influence := layer.influence
	if influence <= 0.0: return
	var before: Array[Transform3D] = []
	if influence < 1.0:
		for bone in skeleton.get_bone_count():
			before.append(skeleton.get_bone_pose(bone))
	apply.call()
	for bone in before.size():
		skeleton.set_bone_pose(bone, before[bone].interpolate_with(skeleton.get_bone_pose(bone), influence))


## After leave(): the solver's pivot (just written by _update_body) eased in from the clip pivot
## over HERO_PIVOT_SECONDS of solve steps, as long as the pivot's blend the other way (enter()).
## On a slope that is a ~10 cm glide: the clip pivot pitches the model about her root (the baked
## hooves stay on the ground), the solver's about her hips. The contacts and the leg solve that
## follow read this pivot, so the hooves are placed against the body as shown. Dropped if she is
## held, or if the solver path did not run soon after the hand-off (a posture, a throw or a
## flight took over).
const HERO_PIVOT_SECONDS := 0.35

static func blend_pivot(pony: Node, delta: float) -> void:
	if pony._held or Engine.get_physics_frames() - int(pony._hero_from_frame) > 10 + int(HERO_PIVOT_SECONDS * Engine.physics_ticks_per_second):
		pony._hero_blend = 1.0
		return
	pony._hero_blend = minf(1.0, float(pony._hero_blend) + delta / HERO_PIVOT_SECONDS)
	var pivot: Node3D = pony.pivot
	var from: Transform3D = pony._hero_from
	pivot.transform = from.interpolate_with(pivot.transform, smoothstep(0.0, 1.0, float(pony._hero_blend)))


## Clip tiers have no collision body, so a pony on them walks into posts, fences and other ponies;
## when collision came back one move_and_slide threw her out in a single step (a 28 mm sideways
## zap with a post 0.12 m inside her capsule, tools/locomotion/handoff_pop_lab.gd). Each HERO step
## after leave() the bodies she overlaps (not her floor) become collision exceptions and she eases
## out of them by hand, no faster than OVERLAP_SPEED; clear (or OVERLAP_SECONDS on) they are
## dropped again. OVERLAP_MIN_SECONDS keeps looking a few steps, while the re-enabled shape reaches
## the physics server.
const OVERLAP_SECONDS := 1.5
const OVERLAP_MIN_SECONDS := 0.1
const OVERLAP_EASE := 0.15
const OVERLAP_SPEED := 0.25
const OVERLAP_CLEAR := 0.002

static func ease_overlap(pony: Node, delta: float) -> void:
	end_overlap(pony)
	pony._overlap_age = float(pony._overlap_age) + delta
	if pony._held or float(pony._overlap_age) > OVERLAP_SECONDS:
		pony._overlap_age = -1.0
		return
	var body3d := pony as CharacterBody3D
	var params := PhysicsTestMotionParameters3D.new()
	params.from = body3d.global_transform
	params.motion = Vector3.ZERO
	params.margin = body3d.safe_margin
	params.recovery_as_collision = true
	params.max_collisions = 6
	var result := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(body3d.get_rid(), params, result)
	var push := result.get_travel()
	push.y = 0.0
	var floor_dot := cos(body3d.floor_max_angle)
	var bodies: Array[PhysicsBody3D] = []
	for i in result.get_collision_count():
		var body := result.get_collider(i) as PhysicsBody3D
		if body != null and not bodies.has(body) and result.get_collision_normal(i).dot(body3d.up_direction) < floor_dot:
			bodies.append(body)
	if bodies.is_empty() or push.length() < OVERLAP_CLEAR:
		if float(pony._overlap_age) >= OVERLAP_MIN_SECONDS: pony._overlap_age = -1.0
		return
	var exceptions: Array[PhysicsBody3D] = body3d.get_collision_exceptions()
	var held: Array = pony._overlap_exceptions
	for body in bodies:
		if not exceptions.has(body):
			body3d.add_collision_exception_with(body)
			held.append(body)
	var step: Vector3 = push * (1.0 - exp(-delta / OVERLAP_EASE))
	body3d.global_position += step.limit_length(OVERLAP_SPEED * delta)


static func end_overlap(pony: Node) -> void:
	var held: Array = pony._overlap_exceptions
	for body: Variant in held:
		if is_instance_valid(body): (pony as PhysicsBody3D).remove_collision_exception_with(body as Node)
	held.clear()


## Clip gait for a wanted and actual speed, from the current one: the solver's walk/trot and
## trot/gallop entry and exit, and the trot split three ways by speed: trot_slow (the solver's slow
## trot, short strides) below SLOW_SPLIT, the everyday trot, then trot_fast above the trot travel
## band's floor. Each split sits where both neighbouring clips stay inside RATE, so no travelling
## clip plays in slow motion (dev 2026-10-31: slow ponies used "the walk animation but
## slowmotionified").
static func choose_gait(profile: Resource, gait: String, wanted: float, speed: float) -> String:
	var gallop_ready: bool = wanted >= profile.gallop_entry and speed >= profile.gallop_entry - 0.8
	match gait:
		"gallop":
			if wanted < profile.gallop_exit or speed < profile.gallop_exit - 0.8:
				return trot_band(profile, "", speed)
		"walk":
			if gallop_ready: return "gallop"
			if wanted >= profile.trot_entry: return trot_band(profile, "", speed)
		_:
			if gallop_ready: return "gallop"
			if wanted > 0.0 and wanted < profile.trot_exit and speed < profile.trot_entry: return "walk"
			return trot_band(profile, gait, speed)
	return gait


## Playback rate of a travelling clip (actual over baked speed). The walk may slow further: it is
## the gait ponies start and stop in, and the slowest one there is.
const RATE := Vector2(0.72, 1.35)
const WALK_RATE_FLOOR := 0.5
## trot_slow / trot split in m/s at body scale 1: trot_slow is baked at 0.85 m/s (1.35x = 1.15),
## the trot at 1.6 m/s (0.72x = 1.15). The trot / trot_fast split sits 0.1 below the trot travel
## band's floor: trot 1.31x, trot_fast (2.8 m/s) 0.75x.
const SLOW_SPLIT := 1.15
const SPLIT_MARGIN := 0.05
const FAST_SPLIT_DROP := 0.1
const FAST_MARGIN := 0.07


static func rate_floor(clip_gait: String) -> float:
	return WALK_RATE_FLOOR if clip_gait == "walk" else RATE.x


## Which trot clip for `speed`, keeping the current one (`gait`) inside a small margin either side
## of each split so a pace drifting across it never flickers.
static func trot_band(profile: Resource, gait: String, speed: float) -> String:
	var body: float = profile.body_scale
	var slow := SLOW_SPLIT * body
	var fast: float = profile.trot_speed.x - FAST_SPLIT_DROP * body
	var slow_margin := SPLIT_MARGIN * body
	var fast_margin := FAST_MARGIN * body
	match gait:
		"trot_slow":
			if speed < slow + slow_margin: return gait
		"trot":
			if speed >= slow - slow_margin and speed < fast + fast_margin: return gait
		"trot_fast":
			if speed >= fast - fast_margin: return gait
	if speed < slow: return "trot_slow"
	return "trot" if speed < fast else "trot_fast"


## The baked clip for the posture's phase: the entry clip (played backwards while reversing), the
## hold, the sleep pose while settling in or asleep, the rise, then the stand clip for recovery.
## NightRest's bedtime (lie down and fall asleep together) and waking (rise while the sleep pose
## unwinds) have their own baked clips, so they match the solver's blend exactly; `exact` is
## false only while a sleep pose blends in or out on some other timeline (a crossfade then).
static func posture_clip(posture: RefCounted, style: String) -> Dictionary:
	var choice := {"clip": "", "time": posture.source_time, "speed": 1.0, "blend": 0.18, "hold": false, "exact": true}
	var sleep_pose: String = posture.sleep_pose_name(posture._sleep_style) if posture._sleep_style != "" else ""
	var sleep_seconds: float = posture.SLEEP_SECONDS.get(posture._sleep_style, 1.3)
	match posture.phase:
		"enter", "reverse":
			choice.clip = posture.kind
			choice.speed = -1.0 if posture.phase == "reverse" else 1.0
			if sleep_pose != "" and posture._sleep_blend > 0.0:
				choice.exact = false
				if posture.kind == "lie_down" and style != "" and absf(posture._sleep_blend - minf(1.0, posture.source_time / sleep_seconds)) < 0.05:
					choice.clip = "lie_down_sleep_" + sleep_pose
					choice.exact = true
		"exit":
			choice.clip = posture.clip
			if sleep_pose != "" and posture._sleep_blend > 0.0:
				choice.exact = false
				if posture.kind == "lie_down" and absf(posture._sleep_blend - maxf(0.0, 1.0 - posture.source_time / (sleep_seconds * 0.6))) < 0.05:
					choice.clip = "lie_down_stand_sleep_" + sleep_pose
					choice.exact = true
		"recover":
			choice.clip = BAKED_GAITS.STAND
			choice.blend = 0.2
			choice.hold = true
		_:
			choice.hold = true
			var sleep: bool = sleep_pose != "" and posture._sleep_blend > 0.0
			if sleep and style != "":
				choice.clip = "sleep_" + sleep_pose
				choice.blend = (1.0 - posture._sleep_blend) * posture.sleep_seconds(style)
			else:
				choice.clip = posture.kind + "_hold"
				choice.blend = posture._sleep_blend * posture.sleep_seconds("") if sleep else 0.18
			choice.exact = posture._sleep_blend <= 0.0 or posture._sleep_blend >= 1.0
	return choice
