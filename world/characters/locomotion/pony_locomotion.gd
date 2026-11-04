extends CharacterBody3D
## Desktop locomotion: animation rhythm, world-space contacts, bounded terrain IK.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
## Split by responsibility (2026-10-13). This file stays the pony's motor, crowd tiers and solver
## dispatch (the per-step work and its state); cold setup and APIs live beside it.
const DRESSING := preload("res://world/characters/locomotion/pony_dressing.gd")
const RIG_SETUP := preload("res://world/characters/locomotion/pony_rig_setup.gd")
const HOLD := preload("res://world/characters/locomotion/pony_hold_api.gd")
const CLIP_TIER := preload("res://world/characters/locomotion/pony_clip_tier.gd")
const SUPPORT := preload("res://world/characters/locomotion/pony_support_recovery.gd")

const MODEL := preload("res://world/characters/native_mare/native_mare_smooth.glb")
const PROFILE := preload("res://world/characters/locomotion/pony_gait_profile.gd")
const SOLVER := preload("res://world/characters/locomotion/limb_solver.gd")
## The C++ solver (native/pony_solver, docs/NATIVE_SOLVER_2026_09_25.md) when its extension is
## loaded: forward kinematics, the leg solve, joint limits, hoof contacts and self-collision,
## same math as the GDScript. `-- --native-solver off` keeps the GDScript (A/B and parity
## tests); so does any platform the extension is not built for.
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
## Solves every free HERO pony of a physics tick at once, on all cores (pony_solve_batch.gd).
const SOLVE_BATCH := preload("res://world/characters/locomotion/pony_solve_batch.gd")
var _solve_batch: Node
var _solve_profile: Resource
var _solve_use_correction := false
var _native: RefCounted
var _native_contact_profile: Resource
var _native_contacts: bool = NATIVE.enabled("contacts")
## _probe() and the free-standing _update_body() in PonySolverNative.
var _native_probe := false
var _native_body := false
var _body_profile: Resource
const MODIFIER := preload("res://world/characters/locomotion/pony_terrain_modifier.gd")
const LIMITS := preload("res://world/characters/locomotion/pony_joint_limits.gd")
const CARRY := preload("res://world/characters/locomotion/pony_carry.gd")
const SECONDARY := preload("res://world/characters/locomotion/pony_secondary_motion.gd")
const STEP_TIMING := preload("res://world/characters/locomotion/pony_step_timing.gd")
const SELF_COLLISION := preload("res://world/characters/locomotion/pony_self_collision.gd")
const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")
## Finer opt-in wall timings inside the physics step (tools/crowd_cpu_profile.gd, --cpu-labels);
## one bool test per site while disabled.
const LOCO_CPU := preload("res://tools/crowd_cpu_profile.gd")
enum Motion { STANDING, STARTING, MOVING, STOPPING, UNSUPPORTED, HELD }

## A hoof has just taken weight while she moves. World contact position.
signal hoof_planted(world_position: Vector3)
## Physical motor outcomes for scene-owned foley; listeners never advance the rig.
signal audio_jumped(world_position: Vector3)
signal audio_landed(world_position: Vector3, impact_speed: float)

@export var corrections_enabled := true
@export var model_scene: PackedScene = MODEL
## Current character exports already contain their coat, mane and mark materials.
@export var preserve_model_materials := false
## Show-style cel look on the exported art: eldskald's cel bands plus a
## coloured line, coat #6BABDA, mane and tail #1B98D1 (kefkafloyd's Rainbow
## Dash colour guide; dev, 2026-09-06: "add mlp cel shading to the dashie").
@export var show_shading := true
## The look's shaders, textures and numbered presets live in pony_dressing.gd; these aliases keep
## the names subclasses use.
const CEL_BASE := DRESSING.CEL_BASE
const CEL_CUTOUT := DRESSING.CEL_CUTOUT
const CEL_OCCLUSION := DRESSING.CEL_OCCLUSION
## marebody_ao.png turned out black (peak 40/255, 99th percentile 0): a failed bake that was
## never actually applied, because the wings shared the coat material's cache slot. The coat is
## plain cel bands until a real bake exists (dev, 2026-09-08). The file is dead, kept by policy.
@export var ao_light_affect := 0.85
## Side-axis scale of the head bone (1 = as modelled). dev: "less wide".
@export var head_width := 0.88
const BODY_ALBEDO_VARIED := DRESSING.BODY_ALBEDO_VARIED
const OUTLINE_TINTED := DRESSING.OUTLINE_TINTED
const OUTLINE_LIT := DRESSING.OUTLINE_LIT
@export var outline_width := 0.0035
const COAT_LINE := Color("6BABDA")
## kefkafloyd's guide: coat fill and the coat's shadow fill. Every cel material gets a shadow
## band in the same ratio, so the coat shades to the guide's exact hex and other colours
## (tail, mouth) darken and cool the same way (dev, 2026-09-08: "the exact hex code").
const COAT_FILL := Color("9BDBF5")
const COAT_SHADE := Color("8CC7E7")
## Who this pony is (PonyIdentity): coat/mane colours, race, hair, mark. Unset = Rainbow Dash
## through the constants above, so the native mare and old tests behave as before.
@export var identity: Resource
## Broad subtle albedo variation over the coat (BODY_ALBEDO_VARIED); off = flat show hex.
@export var coat_variation := false
## Numbered shading looks so dev can pick one by number (lab: --shading N, keys F1..F6).
const SHADING_VERSIONS := DRESSING.SHADING_VERSIONS
@export var shading_version := 3
var _model: Node
## 2D eyes, VRChat style: the native export's eye-white and lid meshes ride
## the live skeleton; a planar UV2 over each white carries the native iris texture
## as a detail layer whose offset follows the gaze (dev, 2026-09-06: "EYES").
## Round 8: the eyes are modelled into the head in Blender (socket recess,
## iris card, clear dome, lashes; export names EyeCard_*/EyeDome/EyeLash/
## EyeSocketWall) and dressed by _apply_show_shading. The old runtime
## attachment stays behind this flag for reference.
@export var eyes_enabled := false
const EYES_SOURCE := DRESSING.EYES_SOURCE
const EYE_SHADER := DRESSING.EYE_SHADER
const IRIS_TOP := DRESSING.IRIS_TOP
const IRIS_BOTTOM := DRESSING.IRIS_BOTTOM
const IRIS_LINE := DRESSING.IRIS_LINE
## Head-space placement nudges, in the model's rest frame (x right, y up, z
## back), applied about each eye's own centre. dev iterates these in the lab.
@export var eye_offset := Vector3(0.0, 0.008, -0.012)
@export var eye_scale := 1.15
## How far the lash line drops at full closure, as a fraction of eye height.
@export var lash_travel := 0.55
## Iris radius as a fraction of the eye height, pupil as a fraction of the iris.
@export var iris_radius := 0.46
@export var pupil_radius := 0.62
## How far (fraction of eye height) a radian of gaze slides the iris.
@export var gaze_travel := 0.35
## Idle inward bias of both irises (UV units); wall-eyed is derpy (dev).
@export var convergence := 0.11
## Iris width as a fraction of the eye-white width, and how far (UV) a full
## radian of gaze slides it.
var _eye_materials: Dictionary = {}
var _eye_meshes: Array[MeshInstance3D] = []
var _outline_materials: Array[ShaderMaterial] = []
const EYELIDS := preload("res://world/characters/locomotion/pony_eyelids.gd")
var eyelids: RefCounted = EYELIDS.new()
var _idle_seconds := 0.0
var _was_held := false
var _lid_hold := false
var _debug_gaze := INF
@export var gaze_u_sign: Dictionary = {"left": 1.0, "right": 1.0}
const MANE_LINE := Color("1B98D1")
## Navigation asks for tight turns; manual animation-lab steering is unchanged.
var navigation_steering := false
## Heading change rates in radians per second: while travelling with navigation_steering, and
## the stepping turn on the spot. The player's pony raises both (player_pony.gd).
var steer_turn_rate := 1.8
var face_turn_rate := 0.45
## Upward speed for the next step (jump()); 0 when none is waiting.
var _jump_request := 0.0
var profile := PROFILE.new()
var joint_limits := LIMITS.new()
var carry := CARRY.new()
var secondary := SECONDARY.new()
## Optional leased physical activity pose, applied before the ordinary support
## solve. No activity receives ownership of body translation or foot contacts.
var activity_mouth_pose: RefCounted
var step_timing := STEP_TIMING.new()
var self_collision := SELF_COLLISION.new()
var state := Motion.STANDING
var phase := 0.0
var actual_speed := 0.0
var flight: RefCounted
var thrown: RefCounted
var placement_recovery := preload("res://world/characters/locomotion/placement_recovery.gd").new()
var motion_paused := false
## Pegasi also stand on cloud floors (the Cloudominium); everypony else falls through them.
const CLOUD_LAYER := 1 << 18
var floor_mask := 1
var single_step := false
var feet: Array[Dictionary] = []
var skeleton: Skeleton3D
var animation: AnimationPlayer
var pivot: Node3D
var modifier: SkeletonModifier3D
var posture: RefCounted
var hoof_hold:=preload("res://world/characters/locomotion/pony_hoof_hold.gd").new()

var source_pose: Array[Transform3D] = []
var corrected_pose: Array[Transform3D] = []
var _model_frame := Transform3D.IDENTITY
var _desired := Vector3.ZERO
var _body_height := 0.0
var _body_tilt := Quaternion.IDENTITY
var _blend := 0.0
var _stop_elapsed := 0.0
var _initialized := false
var _blocked := false
var _yaw_rate := 0.0
var _face_direction := Vector3.ZERO
var _turn_step_speed := 0.0
var _turn_ground_safe := true
var _tick := 0
var _command_speed := 0.0
var _ground_velocity := Vector3.ZERO
var _stride_scale := 1.0
var _slope_angle := 0.0
var _body_offset := Vector3.ZERO
var _body_offset_velocity := Vector3.ZERO
var _previous_horizontal_velocity := Vector3.ZERO
var _touch_force := Vector3.ZERO
var _interaction := ""
var _interaction_seconds := 0.0
var _held := false
var _hold_target := Vector3.ZERO
var _hold_velocity := Vector3.ZERO
## Yaw the holder wants her at (turning the hand turns her); INF = keep.
var _hold_yaw := INF
var _collision_cooldown := 0.0
var _hold_root_offset := Vector3.ZERO
var _joint_limit_correction := 0.0
var _hand_targets: Dictionary = {}
var _spawn_settle := 0.0
var _pose_batch: Node
var _gpu_pose_pending := false
## Crowd simulation tier (world/characters/crowd/pony_crowd.gd): HERO runs the procedural
## solver every tick (or every other tick past PonyCrowd.close_distance); NEAR and FAR play
## the solver-baked gait clips (baked_gaits.gd, docs/CLIP_TIER_2026_09_25.md) with real floor
## rays and no collision body. NEAR keeps the full render, a live head, eyes and tail springs;
## FAR is the merged far mesh. `sim_phase` offsets the shared whole-step and logic clocks.
enum SimTier { HERO, NEAR, FAR }
const BAKED_GAITS := preload("res://world/characters/locomotion/baked_gaits.gd")
const HOOF_PLANTS := preload("res://world/characters/locomotion/pony_hoof_plants.gd")
const CLIP_HEAD := preload("res://world/characters/locomotion/pony_clip_head.gd")
## NEAR tail springs, eyes and mouth run every third tick; PonyCrowd spreads phases 0..2.
const NEAR_DIVISOR := 3
## Clip-tier pony logic (speed, heading, support rays, gait choice, attention, navigator) runs
## at 20 Hz, a third of the ponies per 60 Hz step (dev 2026-09-25: "the same tickspeed as
## minecraft"); the root, the clip and the interpolated head and tail move every step.
const LOGIC_DIVISOR := 3
## FAR ponies may tick their logic less often than NEAR (PonyCrowd.far_divisor from the quality
## tier; LOGIC_DIVISOR by default, so nothing changes on High/Ultra).
var far_logic_divisor := LOGIC_DIVISOR
## HERO solve rate divisor: 1 beside the player, 2 (30 Hz) for HERO mares farther than
## PonyCrowd.close_distance. dev 2026-09-17: the gait need not be solved every tick.
var hero_divisor := 1
## Eye and mouth modifier cadence while HERO: NEAR_DIVISOR for a pinned mare beyond
## PonyCrowd.hero_distance, else 1 (set by PonyCrowd.rank()).
var detail_divisor := 1
## Physics time a settled rest has skipped since its last run (posture branch).
var _posture_delta := 0.0
var sim_tier := SimTier.HERO
var sim_phase := 0
var _crowd: Node
var _collision: CollisionShape3D
## This layout's baked gait library ("baked/<gait>" on `animation`); null keeps her HERO.
var _baked: AnimationLibrary
## Hoofsteps (pony_hoof_plants.gd): NEAR emits hoof_planted at the footfalls baked from these
## clips; HERO holds each contact-model plant until the shown hoof is down.
var _hoof_plants: RefCounted = HOOF_PLANTS.new()
## Physics time since the last clip-tier logic tick, and steps taken since it.
var _logic_delta := 0.0
var _logic_steps := 0
var _clip_gait := ""
var _clip_gait_hold := 0.0
## Clip-tier travel set by the logic tick: speed wanted, heading, and whether the ground ahead
## failed the support check.
var _clip_wanted := 0.0
var _clip_yaw := 0.0
var _clip_blocked := false
var _clip_probe_logic := 0
## Live head in the clip tiers: the secondary's head, gaze and neck-gaze angles at the last two
## logic ticks, interpolated every step by pony_clip_head.gd over the clip's neck.
var clip_head_from := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var clip_head_to := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var _clip_head: SkeletonModifier3D
## Clip tiers: body pitch from the floor under nose and dock, so hooves do not float or sink
## on hills the way a flat clip would.
var _clip_pitch := 0.0
## The pivot already holds the converged clip pitch (_clip_step), or the settled posture slope
## `_posture_pivot_slope` (_clip_posture_step); any other pivot writer clears them.
var _clip_pivot_settled := false
var _posture_pivot_settled := false
var _posture_pivot_slope := Basis.IDENTITY
## Hand-off into the clip tiers (dev 2026-09-17: a visible jump when a mare left HERO range):
## the solved pose is baked into a one-key clip the AnimationPlayer crossfades from, and the
## HERO pivot (tilt, body height) blends into the clip pivot over `CLIP_HANDOFF_SECONDS`.
const HANDOFF := "handoff/crowd_handoff"
const CLIP_HANDOFF_SECONDS := 0.35
var _clip_from := Transform3D.IDENTITY
var _clip_blend := 1.0
## Hand-off back out of the clip tiers (pony_clip_tier.gd leave, dev 2026-11-03 "about 4 m away
## ... for like 1 frame she'll zap away ... or her head will jitter"): the solver's pivot eases in
## from the clip pivot she showed (`_hero_from`, physics frame `_hero_from_frame`), and a body
## she walked into without collision is eased out of instead of thrown out (`_overlap_*`).
## `_handoff_clip_head`: ClipHead was layering her head when she left.
var _hero_from := Transform3D.IDENTITY
var _hero_blend := 1.0
var _hero_from_frame := -1
var _overlap_age := -1.0
var _overlap_exceptions: Array = []
var _handoff_clip_head := false
## HERO's leading-leg phase when she entered the clip tier: the first gait clip starts there.
var _clip_enter_phase := 0.0
## Seconds in the clip tier since the last hand-off; the hand-off clip is dropped from the
## player once its crossfade is over (it keys every bone, which the mixer would keep walking).
var _clip_age := 0.0
## Clip-tier postures: physics time the mixer still runs for after a hold clip starts (its
## crossfade); after that a settled hold is not advanced at all.
var _mixer_hold := 0.0
## A settled sleep on the clip tiers is one pose: after REST_FREEZE_SECONDS asleep her skeletons
## stop updating altogether (their modifiers switch to manual), so skinning, tail, eyes, links and
## head cost nothing until she wakes, moves, or comes within hero range.
const REST_FREEZE_SECONDS := 2.0
var _rest_frozen := false
## Off-screen clip-tier ponies (0.1.0 perf pass). PonyCrowd hides the model pivot of a pony outside
## the view (crowd_hidden): nothing of her draws or casts a shadow, yet her three rigs still ran
## their modifier passes (live head, eyes, mouth, tail, idle breath) and her NEAR gait clip still
## posed every bone each step, about 100-150 us per NEAR pony per physics tick for a picture nobody
## sees. While hidden her rigs run no passes (manual, like a frozen sleeper) and a looping gait's
## clock runs without posing (as FAR already did); her logic, navigation, root motion and footfall
## sounds carry on unchanged. Shown again, PonyCrowd poses the clip and set_crowd_hidden() hands the
## rigs back with one pass in that same frame, before it is drawn. HERO ponies are not parked.
## Rollback: HIDDEN_RIG_PARK = false.
const HIDDEN_RIG_PARK := true
var _asleep_seconds := 0.0
## _clip_age at which the last animation.play() crossfade ends. The hand-off clip is removed
## only after that: removing a clip the mixer is still fading out makes every advance fail with
## "!has_animation" until the fade would have ended.
var _clip_blend_end := 0.0
## The baked stand is one key per channel: once its crossfade is over, advancing the mixer
## rewrites the same pose and dirties every bone (skins, skeleton_updated) on every step.
## Set by _clip_logic while the stand plays; any other clip clears it.
var _clip_static := false
## Hidden stable gait: the clock is current, but no bone tracks were evaluated.
var _clip_pose_deferred := false
## A FAR pony drawn as a picture (hybrid_mare.gd impostor): under a pixel of movement per tick,
## so she moves on her work beats only and her skeleton pose is not evaluated (2026-10-23 CPU pass).
var coarse_motion := false
var _coarse_motion_delta := 0.0
## One advance after a tier change even on a settled stand: leaving NEAR stops the live head, and
## the skins still hold its last look until something updates the skeleton.
var _clip_refresh := false
## Clip time a FAR gait has not been advanced by yet (posed every other step, _clip_step).
var _clip_advance_delta := 0.0
## Clip-tier floor and slope come from three real rays every third logic tick (dev
## 2026-09-17: mares "literally clip through the floor" on the grid's 0.25 m cells);
## the walk grid, then the heightmap, only where the rays find no collision.
var _clip_floor := NAN
var _clip_floor_at := Vector3.ZERO
var _clip_pitch_target := 0.0
## A stationary pony's floor refreshes skipped since the last rays (at most CLIP_FLOOR_KEEP), the
## yaw those rays were cast at, and whether the centre ray hit real collision.
const CLIP_FLOOR_KEEP := 12
## A floor ray this far under her is checked against the walk grid before she follows it down.
const CLIP_DROP_CHECK := 0.5
var _clip_floor_keep := 0
var _clip_floor_yaw := 0.0
var _clip_floor_from_ray := false
## The support check ahead (_clip_logic): where and along which heading the last ray certified
## support, how far out, and how many logic ticks have reused it.
var _clip_ahead_certified := false
var _clip_ahead_skips := 0
var _clip_ahead_from := Vector3.ZERO
var _clip_ahead_dir := Vector3.ZERO
var _clip_ahead_reach := 0.0
## Support recovery. The big world only has terrain collision in a window around the
## camera (Terrain3D dynamic mode) and zone bodies arrive seconds after a zone loads, so
## a simulated pony can lose her floor, sink, and be trapped when collision appears above
## her. Unsupported bodies are re-seated on the real surface when one exists and held at
## the heightmap height when none does; nothing else moves her.
var _unsupported_seconds := 0.0
var _heightmap_supported := false
## Visual/physical size multiplier (1 = canon). Model pivot, capsule and the gait
## profile's calibration follow it; contacts still come from the real hooves.
var body_scale := 1.0
var _corner_speed := INF
## Corner rays only while she wants to move (0.1.0 perf pass): standing with no request, the four
## rays of _terrain_corner_speed() feed minf(0, ...) and change nothing. _corner_stale makes the
## first step she wants to move measure at once, solve tick or not. Rollback: CORNER_IDLE_SKIP = false.
const CORNER_IDLE_SKIP := true
var _corner_stale := true
## Settled stand (0.1.0 perf pass): a HERO pony standing on a still floor slides her capsule by
## exactly zero every step. After two such slides in a row, only every SETTLED_MOVE_RECHECK-th
## step slides again (10 Hz floor recheck); between them the last slide's result is kept (velocity,
## floor and wall state). Never while held, airborne, turning, on a moving support or on the
## full-rate path (touch, carry, flight, the player's own pony). Rollback: SETTLED_MOVE_SKIP = false.
const SETTLED_MOVE_SKIP := true
const SETTLED_MOVE_RECHECK := 6
var _settled_moves := 0
var _settled_skips := 0
var _settled_velocity := Vector3.ZERO
var _settled_at := Vector3.INF
var _leg_cache: Array[Dictionary] = []
## Last well-defined bend direction per leg; a fully extended leg (gallop kick) has
## no measurable bend and must not flip its knee from tick to tick.
var _leg_poles: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
## Gait request before slope/corner/blocking reductions: hills slow the trot, they do
## not turn a trot into a walk.
var _gait_request := 0.0
## True when no trot or gallop sample moves a lid bone off its rest: open lids (closure 0)
## then already sit where apply_lids would write them.
var _lids_static := true


## Model, rig, native solver, look, capsule, modifiers and baked clips, in that order
## (pony_rig_setup.gd).
func _ready() -> void:
	RIG_SETUP.build(self)


## Resize this pony: model pivot, collision capsule and every speed/reach calibration.
func set_body_scale(scale_factor: float) -> void:
	scale_factor = clampf(scale_factor, 0.25, 4.0)
	if is_equal_approx(scale_factor, body_scale): return
	var relative := scale_factor / body_scale
	body_scale = scale_factor
	profile.rescale(relative)
	if _collision != null and _collision.shape is CapsuleShape3D:
		var capsule := (_collision.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
		capsule.radius = 0.19 * body_scale
		capsule.height = 0.85 * body_scale
		_collision.shape = capsule
		_collision.position.y = capsule.height / 2.0
	floor_snap_length = 0.3 * body_scale
	if posture != null: posture.rescale(relative)
	_apply_body_scale()


func _apply_body_scale() -> void:
	if pivot == null: return
	_set_pivot_scaled(pivot.transform)


## `pivot.transform = t` then _apply_body_scale() in one write (0.1.0 perf pass): every pivot write
## re-notifies her whole model subtree, and the solver wrote it twice per step. Same transform.
func _set_pivot_scaled(t: Transform3D) -> void:
	_clip_pivot_settled = false
	_posture_pivot_settled = false
	t.basis = t.basis.orthonormalized().scaled_local(Vector3.ONE * body_scale)
	pivot.transform = t


## Step straight backwards at `speed` m/s (0 stops) without turning: the walk played in
## reverse, as a horse backs up (dev 2026-10-14). Any other motion request ends it.
var backing := false
const BACK_SPEED_MAX := 0.35

func back_up(speed: float) -> void:
	if hoof_hold.active(): return
	speed = clampf(speed, 0.0, BACK_SPEED_MAX)
	if speed <= 0.0:
		if backing: stop()
		return
	if posture != null and posture.active(): posture.request("stand")
	_nav_motion = false
	_face_direction = Vector3.ZERO
	backing = true
	var back := global_basis.z
	back.y = 0.0
	_desired = back.normalized() * speed

func set_desired_velocity(world_velocity: Vector3) -> void:
	if hoof_hold.active():return
	if posture != null and posture.active() and world_velocity.length() > .05: posture.request("stand")
	backing = false
	_nav_motion = false
	_face_direction = Vector3.ZERO
	_desired = Vector3(world_velocity.x, 0.0, world_velocity.z)
	_desired = _desired.limit_length(profile.max_travel_speed)


func stop() -> void:
	_nav_motion = false
	backing = false
	_desired = Vector3.ZERO
	_face_direction = Vector3.ZERO


## --- Navigation motion contract (docs/NAVIGATION_PHASE_2_2026_10_02.md) -------------------
## With -- --native-navigation follow the native follower commands, once per navigator tick, a
## forward speed (m/s) and a yaw rate (rad/s, positive turns left) for the next physical moves.
## On both the solver and the clip tiers it replaces the velocity path's
## max(0, cos(heading_error)) translation suppression and the blanket 0.4 s wall cooldown:
## curvature is kept at the speed actually executed (hills, corners and the unsafe-support brake
## may slow her), translation and yaw integrate together at the midpoint heading, wall contact
## keeps only the tangent the slide achieved, and a supported stepping turn walks the legs round
## on the spot. Any other writer (set_desired_velocity, stop, face_direction, lunge) takes the
## body back at once, and a command nobody renewed expires within a logic beat.
const NAV_MODE_STOP := 0
const NAV_MODE_TRAVEL := 1
const NAV_MODE_STEP_TURN := 2
const NAV_MODE_BRAKE := 3
const NAV_MODE_HOLD := 4
const NAV_REFUSAL_NONE := 0
const NAV_REFUSAL_SUPPORT := 1
const NAV_REFUSAL_TOUCH := 2
const NAV_REFUSAL_TURN_SUPPORT := 3
var _nav_motion := false
var _nav_speed := 0.0
var _nav_yaw_rate := 0.0
var _nav_mode := NAV_MODE_STOP
var _nav_frame := -1
## Feedback for the follower's next tick: what the motor executed and why it refused.
var nav_executed_speed := 0.0
var nav_executed_yaw_rate := 0.0
var nav_refusal := NAV_REFUSAL_NONE
var nav_wall_normal := Vector3.ZERO
## The terrain speed factor of the last step (hills): reported to the follower, which scales its
## target speed by it once, instead of the motor scaling the command (see _physics_process).
var nav_speed_scale := 1.0
## The follower's target travel speed: the gait follows it while the command accelerates toward it.
var _nav_gait_speed := 0.0


func accept_navigation_motion(forward_speed: float, yaw_rate: float, mode: int, gait_speed := -1.0) -> void:
	if hoof_hold.active(): return
	if not (is_finite(forward_speed) and is_finite(yaw_rate)):
		stop()
		return
	if posture != null and posture.active() and (forward_speed > .05 or mode == NAV_MODE_STEP_TURN): posture.request("stand")
	_face_direction = Vector3.ZERO
	_nav_motion = true
	_nav_speed = clampf(forward_speed, 0.0, profile.max_travel_speed)
	_nav_yaw_rate = clampf(yaw_rate, -steer_turn_rate, steer_turn_rate)
	_nav_mode = mode
	_nav_gait_speed = clampf(gait_speed, 0.0, profile.max_travel_speed) if gait_speed >= 0.0 and is_finite(gait_speed) else _nav_speed
	_nav_frame = Engine.get_physics_frames()
	# The legacy fields other code reads (the clip hand-off, traces) see the same request.
	var forward := -global_basis.z
	forward.y = 0.0
	_desired = forward.normalized() * _nav_speed if forward.length_squared() > 1e-6 else Vector3.ZERO


## The navigation command still owns her this step: renewed within one logic beat (the clip tiers'
## navigator runs at 20 Hz, a potato FAR pony every far_tick_divisor-th step).
func _nav_motion_live() -> bool:
	if not _nav_motion: return false
	var hold := 2 if sim_tier == SimTier.HERO else logic_divisor() * maxi(far_tick_divisor, 1) + 2
	if Engine.get_physics_frames() - _nav_frame > hold:
		_nav_motion = false
		_desired = Vector3.ZERO
		return false
	return true


## One step of a navigation command: the commanded curvature at the executed speed, or a supported
## stepping turn on the spot. Returns the midpoint heading the translation follows.
func _nav_turn(delta: float, horizontal_speed: float, solve_tick: bool) -> Vector3:
	var yaw := rotation.y
	var rate := 0.0
	if _nav_mode == NAV_MODE_STEP_TURN:
		if solve_tick:
			_turn_ground_safe = is_on_floor() and _turn_support_safe(signf(_nav_yaw_rate) * 0.12, true)
		if _turn_ground_safe:
			# The legs step first (the gait starts from the turn's stepping speed); the body yaws as
			# that walk blends in, exactly like the conversation turn above.
			_turn_step_speed = minf(0.23, maxf(0.12, absf(_nav_yaw_rate) * 0.15))
			rate = _nav_yaw_rate * _blend
		else:
			nav_refusal = NAV_REFUSAL_TURN_SUPPORT
	elif _nav_speed > 0.0001:
		rate = clampf(_nav_yaw_rate / _nav_speed * horizontal_speed, -steer_turn_rate, steer_turn_rate)
	var middle := yaw + rate * delta * 0.5
	if _nav_mode == NAV_MODE_STEP_TURN and rate != 0.0:
		global_transform = _stance_turn_transform(rate * delta)
	else:
		rotation.y = yaw + rate * delta
	_yaw_rate = rate
	return Vector3(-sin(middle), 0.0, -cos(middle))


## A hop off the ground (the player's pony on Space): `speed` m/s upward on the next step, while
## the gait carries on. False unless she stands on the floor.
func jump(speed: float) -> bool:
	if not is_on_floor() or _held or hoof_hold.active() or (flight != null and flight.active()): return false
	_jump_request = speed
	return true


## A short quick move she makes herself (a kiss following Anon, pony_affection.gd): overrides
## whatever the navigator asks for `seconds`, then hands movement back.
var _lunge_velocity := Vector3.ZERO
var _lunge_left := 0.0
func lunge(world_velocity: Vector3, seconds: float) -> void:
	_nav_motion = false
	_lunge_velocity = Vector3(world_velocity.x, 0.0, world_velocity.z).limit_length(profile.max_travel_speed)
	_lunge_left = maxf(seconds, 0.0)


## The wall the follower hears about (flattened normal, zero for none): a contact higher above her
## hooves than her step height. The round foot of her 0.19 m capsule touches any edge over 3.4 cm
## with a normal steeper than floor_max_angle, so is_on_wall() also reports a kerb, a door sill or
## the 5 cm apron where the spa steps meet the street, which she rides straight over. Reported, the
## follower marked that lip as an obstruction on the only way up and never climbed the steps
## (tools/spa/test_spa_walk_in.gd, 2026-10-31). Walls, furniture and ponies touch higher.
func _nav_wall_normal() -> Vector3:
	if not is_on_wall(): return Vector3.ZERO
	var lip: float = global_position.y + float(profile.step_height)
	for index: int in get_slide_collision_count():
		var hit := get_slide_collision(index)
		var normal := hit.get_normal()
		if normal.angle_to(up_direction) > floor_max_angle + 0.01 and hit.get_position().y > lip:
			return Vector3(normal.x, 0.0, normal.z)
	return Vector3.ZERO


## A kiss (pony_affection.gd) may still turn her and step her closer while his hands rest on her:
## petting alone then no longer freezes her heading and speed.
var steer_through_touch := false
func _touch_blocks() -> bool:
	return not _interaction.is_empty() and not (steer_through_touch and _interaction == "PETTING")


## A conversation may request a heading independently of forward movement.
## Rotation and foot contacts remain owned by this physics controller.
func face_direction(world_direction: Vector3) -> void:
	_nav_motion = false
	backing = false
	_desired = Vector3.ZERO
	_face_direction = Vector3(world_direction.x, 0.0, world_direction.z).normalized() if world_direction.is_finite() else Vector3.ZERO


func begin_touch(world_force: Vector3 = Vector3(0.0, -2.0, 0.0), seconds: float = 0.8) -> void:
	if _held or hoof_hold.active():
		return
	_interaction = "PETTING"
	_interaction_seconds = maxf(seconds, 0.0)
	_touch_force = world_force.limit_length(8.0)


func begin_hold(world_position: Vector3) -> void:
	HOLD.begin_hold(self, world_position)


## Tear down and rebuild the eyes with the current exports (lab tool).
func rebuild_eyes() -> void:
	DRESSING.rebuild_eyes(self)


func _attach_eyes(skeleton: Skeleton3D) -> void:
	DRESSING.attach_eyes(self, skeleton)


## The coloured outline hull is unshaded; dim it with the daylight so it
## does not glow at night. Night floor matches the unshaded eyes.
func _update_outlines() -> void:
	if _outline_materials.is_empty():
		return
	var tod: Node = get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(tod.call("daylight")) if tod != null and tod.has_method("daylight") else 1.0
	var brightness := lerpf(0.22, 1.0, smoothstep(0.0, 0.5, daylight))
	for mat in _outline_materials:
		mat.set_shader_parameter("brightness", brightness)


## Lab flags: --debug-lids <closure> holds the lids, --debug-gaze <yaw rad> holds the gaze.
func _read_eye_debug_args() -> void:
	DRESSING.read_eye_debug_args(self)


## Eye parts modelled into the export, recognised by material name. Returns
## true when the surface was handled here (no cel/outline for these).
func _dress_eye_surface(mi: MeshInstance3D, si: int, src: BaseMaterial3D) -> bool:
	return DRESSING.dress_eye_surface(self, mi, si, src)


func _debug_eyes(mount: Node3D) -> void:
	await DRESSING.debug_eyes(self, mount)


## Rest-space geometry moved into head-bone space, bones and weights dropped (pony_dressing.gd).
static func _rigid_in_head_space(mesh: Mesh, to_head: Transform3D, with_uv2: bool, push: float = 0.0, mirror_u: bool = false) -> ArrayMesh:
	return DRESSING.rigid_in_head_space(mesh, to_head, with_uv2, push, mirror_u)


## Aim both irises with the gaze the secondary motion already animates. The
## shader takes a world direction and reads its xy in the mesh's own frame,
## so build the vector in that frame: +x slides the iris to u+, +y to v-.
func _update_eyes() -> void:
	_update_outlines()
	if _eye_materials.is_empty():
		return
	var gaze: Vector3 = secondary.gaze_angles
	if carry.blend > 0.0:
		gaze = gaze.lerp(carry.eye_angles, carry.blend)
	var moving := state == Motion.MOVING or state == Motion.STARTING
	_idle_seconds = 0.0 if moving or _held else _idle_seconds + get_process_delta_time()
	if _held and not _was_held:
		eyelids.squint()
	_was_held = _held
	if not _lid_hold:
		eyelids.update(get_process_delta_time(), _idle_seconds, moving, secondary.is_looking())
	# Unshaded eyes follow the daylight by hand: full by day, a third at night.
	var tod: Node = get_node_or_null("/root/TimeOfDay")
	var daylight: float = float(tod.call("daylight")) if tod != null and tod.has_method("daylight") else 1.0
	# Pitch black night = black eyes too (dev); a full moon lends a little.
	var moon_lit: float = float(tod.call("moon_lit_fraction")) if tod != null and tod.has_method("moon_lit_fraction") else 0.0
	var brightness := clampf(0.04 + 0.96 * smoothstep(0.0, 0.5, daylight) + 0.14 * moon_lit * (1.0 - daylight), 0.0, 1.0)
	if is_finite(_debug_gaze):
		gaze = Vector3(0.0, _debug_gaze, 0.0)
	# The two cards' UVs are mirrored (u runs front on one side, back on the
	# other), so one shift moves both irises the same way: yaw left = u-.
	# `gaze_u_sign` per side is the escape hatch if an export disagrees.
	var shift := Vector2(-gaze.y * gaze_travel, gaze.x * gaze_travel)
	for side: String in _eye_materials:
		var mat: ShaderMaterial = _eye_materials[side]
		mat.set_shader_parameter("g_brightness", brightness)
		# Resting convergence: both irises a touch toward the nose. "Inward" is
		# u+ on her left card and u- on her right (mirrored UVs).
		var inward := convergence * (1.0 if side == "left" else -1.0)
		mat.set_shader_parameter("g_iris_shift", Vector2(shift.x * float(gaze_u_sign[side]) + inward, shift.y))
		mat.set_shader_parameter("g_lid_closure", eyelids.closure)


## Dress a model (or one MeshInstance3D) in the show cel look.
func _apply_show_shading(model: Node) -> void:
	DRESSING.apply_show_shading(self, model)


## Switch to a numbered look (SHADING_VERSIONS) and re-dress the current model.
func set_shading_version(version: int) -> void:
	if not SHADING_VERSIONS.has(version):
		return
	shading_version = version
	_outline_materials.clear()
	if _model != null and preserve_model_materials and show_shading:
		_redress()


func shading_name() -> String:
	return String(SHADING_VERSIONS.get(shading_version, {}).get("name", "?"))


## Re-dress everything this character wears (subclasses add their extra models).
func _redress() -> void:
	_apply_show_shading(_model)


## Shadow-band colour for a fill: this pony's coat shade ratio applied per channel.
func _shade_of(fill: Color) -> Color:
	var base := coat_fill()
	var shade := coat_shade()
	return Color(fill.r * shade.r / maxf(base.r, 0.001), fill.g * shade.g / maxf(base.g, 0.001),
		fill.b * shade.b / maxf(base.b, 0.001), 1.0)


## Identity colours with the Dash constants as the fallback.
func coat_fill() -> Color:
	return identity.coat_fill if identity != null else COAT_FILL


func coat_line() -> Color:
	return identity.coat_line if identity != null else COAT_LINE


func coat_shade() -> Color:
	return identity.coat_shade if identity != null else COAT_SHADE


func mane_line() -> Color:
	return identity.mane_line if identity != null else MANE_LINE


## Baked occlusion map for a coat mesh, or null for plain cel bands.
func _coat_ao(_mi: MeshInstance3D) -> Texture2D:
	return null


## Picking her up: pony_hold_api.gd.
func begin_grab(grip: String, world_target: Vector3, player_head: Vector3) -> void:
	HOLD.begin_grab(self, grip, world_target, player_head)


func begin_two_hand_grab(left_target: Vector3, right_target: Vector3, player_head: Vector3) -> void:
	HOLD.begin_two_hand_grab(self, left_target, right_target, player_head)


func update_hand_grab(grip: String, world_target: Vector3, player_head: Vector3) -> void:
	HOLD.update_hand_grab(self, grip, world_target, player_head)


func release_hand_grab(grip: String) -> void:
	HOLD.release_hand_grab(self, grip)


func set_hold_yaw(yaw: float) -> void:
	_hold_yaw = yaw


func update_hold(world_position: Vector3) -> void:
	_hold_target = world_position + _hold_root_offset


func update_grab(world_target: Vector3, player_head: Vector3) -> void:
	HOLD.update_grab(self, world_target, player_head)


func get_grip_transform(grip: String = "chest") -> Transform3D:
	return carry.grip_transform(grip)


func end_interaction() -> void:
	HOLD.end_interaction(self)


func throw_pony(momentum: Vector3) -> bool:
	if thrown == null:
		thrown = preload("res://world/characters/locomotion/pony_throw.gd").new()
		thrown.bind(self)
	return thrown.launch(momentum)


func apply_body_impulse(world_impulse: Vector3) -> void:
	_body_offset_velocity += global_basis.orthonormalized().inverse() * world_impulse.limit_length(0.3)


func reset_motion(world_transform: Transform3D) -> void:
	_set_rest_frozen(false)
	if thrown != null: thrown.cancel()
	if flight != null: flight.cancel()
	hoof_hold.reset()
	if posture != null: posture.reset()
	global_transform = world_transform
	velocity = Vector3.ZERO
	_command_speed = 0.0
	_ground_velocity = Vector3.ZERO
	_body_offset = Vector3.ZERO
	_body_offset_velocity = Vector3.ZERO
	_previous_horizontal_velocity = Vector3.ZERO
	_collision_cooldown = 0.0
	_nav_motion = false
	end_interaction()
	carry.reset()
	secondary.reset()
	step_timing.reset()
	self_collision.reset()
	_stride_scale = 1.0
	_slope_angle = 0.0
	_desired = Vector3.ZERO
	phase = 0.0
	actual_speed = 0.0
	state = Motion.STANDING
	_stance_root = Vector3.INF
	_blend = 0.0
	_stop_elapsed = 0.0
	_body_height = 0.0
	_body_tilt = Quaternion.IDENTITY
	_initialized = false
	_spawn_settle = 0.35
	_blocked = false
	# Clip tiers: forget the floor under where she was; the next logic tick casts from here.
	_clip_floor = NAN
	_clip_probe_logic = 0
	_clip_floor_from_ray = false
	_clip_ahead_certified = false
	_clip_pitch = 0.0
	_clip_pitch_target = 0.0
	_clip_yaw = rotation.y
	_clip_wanted = 0.0
	feet.clear()
	if pivot != null:
		pivot.transform = Transform3D.IDENTITY
		_apply_body_scale()
	for leg in profile.legs:
		feet.append({"name": leg.name, "planted": false, "valid": false,
			"lock": Vector3.ZERO, "lock_normal": Vector3.UP, "target": Vector3.ZERO, "normal": Vector3.UP,
			"basis": Basis.IDENTITY, "start": Vector3.ZERO, "landing": Vector3.ZERO,
			"landing_normal": Vector3.UP, "landing_valid": false, "landing_predicted": false, "progress": 0.0,
			"turn_prediction": Vector3.ZERO,
			"sole": Vector3.ZERO, "error": 0.0, "age": 0.0, "stop_start": Vector3.ZERO,
			"clearance": 0.0, "weight": 0.0, "offset": Vector3.ZERO,
			"limited": false, "correction_angle": 0.0, "dynamic_sole": Vector3.ZERO,
			"self_push": Vector3.ZERO, "self_penetration": 0.0})


var moving_support: Node3D
var _support_transform := Transform3D.IDENTITY
var _support_floor_layers := 0

func set_moving_support(frame: Node3D) -> void:
	if frame == moving_support: return
	if is_instance_valid(moving_support): platform_floor_layers = _support_floor_layers
	moving_support = frame
	if is_instance_valid(frame):
		_support_transform = frame.global_transform
		_support_floor_layers = platform_floor_layers
		platform_floor_layers = 0 # The rigid frame transfer below already carries the root.

func _follow_moving_support() -> void:
	if not is_instance_valid(moving_support): return
	var current := moving_support.global_transform
	var motion := current * _support_transform.affine_inverse()
	_support_transform = current
	if _held or (thrown != null and thrown.active()) or (flight != null and flight.active()): return
	global_transform = motion * global_transform
	for foot in feet:
		for key in ["lock", "target", "start", "landing", "stop_start"]: foot[key] = motion * Vector3(foot[key])
		for key in ["normal", "lock_normal", "landing_normal", "offset", "turn_prediction", "self_push"]: foot[key] = motion.basis * Vector3(foot[key])
		foot.basis = motion.basis * Basis(foot.basis)
	_previous_horizontal_velocity = motion.basis * _previous_horizontal_velocity
	_hoof_plants.carry(motion)
	if _stance_root.is_finite(): _stance_root = motion * _stance_root

var water_escape := preload("res://world/characters/locomotion/pony_water_escape.gd").new()
## Potato tier (dev 2026-09-29, Quest: the physics tick was 41 mares' per-tick script): a FAR
## mare runs support/logic/rest work only every far_tick_divisor-th tick with elapsed time.
## Cached root motion still runs every physics tick and gait poses keep their 30 Hz cadence:
## Godot interpolates adjacent physics transforms, not gaps between sparse body updates.
## PonyCrowd sets the divisor from quality.gd crowd_far_tick_divisor.
var far_tick_divisor := 1
var _far_tick_delta := 0.0
## Physics time since water_escape and placement_recovery last ran (clip tiers: the logic beat).
var _watch_delta := 0.0

## Records `label` from `since` and returns the next checkpoint (only called under LOCO_CPU.enabled).
static func _cpu_lap(label: String, since: int) -> int:
	LOCO_CPU.record(label, since)
	return Time.get_ticks_usec()

func _physics_process(delta: float) -> void:
	var prof := LOCO_CPU.enabled
	var lap := Time.get_ticks_usec() if prof else 0
	var motion_delta := delta
	# Physical contact cannot wait for the crowd's quarter-second ranking. Restore the
	# collider/solver before this step; dialogue alone still follows the crowd's range rule.
	if sim_tier != SimTier.HERO and body_pinned():
		set_sim_tier(SimTier.HERO, 0)
		hero_divisor = 1
		set_detail_divisor(1)
	# A FAR rig resting past her idle AffectionPose goes back on the per-tick pass the step her
	# PonyAffection starts (it ticks first, priority -5), before the pose can move.
	if _rig_rest_affection and (not is_instance_valid(_affection) or _affection.is_physics_processing() \
			or _affection.is_processing()):
		_update_rig_rates(true)
	# Entry/exit poses and their crossfades need the same per-tick mixer advance as
	# NEAR. Only settled posture holds may share the slower FAR work cadence.
	var posture_animating: bool = sim_tier == SimTier.FAR and posture != null and posture.active() \
		and (not resting_hold() or _mixer_hold > 0.0 or _clip_blend < 1.0 \
			or (posture._sleep_blend > 0.0 and posture._sleep_blend < 1.0))
	if far_tick_divisor > 1 and sim_tier == SimTier.FAR and not _held and not needs_full_rate() and not posture_animating:
		_far_tick_delta += delta
		# A scheduled navigation/logic beat must execute even between the slower work
		# beats. Delaying it to the next work beat introduces variable steering/braking lag.
		if ((Engine.get_physics_frames() + sim_phase) % far_tick_divisor) != 0 and not is_logic_tick():
			# Reuse the already-certified floor, heading and speed between decisions.
			# Resting/paused bodies stay where their posture or physical owner put them.
			if not motion_paused and (posture == null or not posture.active()):
				# Off screen or a picture: catch the movement up on the next beat instead.
				if coarse_motion or has_meta(PonyCrowd.HIDDEN): _coarse_motion_delta += motion_delta
				else: _clip_step(motion_delta)
			return
		delta = _far_tick_delta
		_far_tick_delta = 0.0
		motion_delta += _coarse_motion_delta
		_coarse_motion_delta = 0.0
	else:
		_far_tick_delta = 0.0
	# Both watchers work on 0.5 s and 2 s timers: on the clip tiers they run on the pony's logic
	# beat with the time since their last run (HERO, and a pony already swimming, every step).
	_watch_delta += delta
	if sim_tier == SimTier.HERO or water_escape.active or is_logic_tick():
		var watch_delta := _watch_delta
		_watch_delta = 0.0
		if water_escape.update(self, watch_delta): return
		if prof: lap = _cpu_lap("loco_water_escape", lap)
		placement_recovery.update(self, watch_delta)
		if prof: lap = _cpu_lap("loco_placement_recovery", lap)
	# PonyCrowd re-ranks every 0.25 s; touching, throwing or waking her must not wait for it.
	if hero_divisor > 1 or detail_divisor > 1:
		if needs_full_rate():
			hero_divisor = 1
			set_detail_divisor(1, sim_phase)
		elif hero_divisor > 2 and not resting_hold():
			hero_divisor = 2
	_follow_moving_support()
	if thrown != null and thrown.active():
		_clip_pivot_settled = false
		_posture_pivot_settled = false
		thrown.update(delta)
		return
	if flight != null and flight.active() and not _held and not hoof_hold.active():
		_clip_pivot_settled = false
		_posture_pivot_settled = false
		flight.update(delta)
		return
	if motion_paused and not single_step:
		return
	single_step = false
	hoof_hold.prepare(delta)
	if prof: lap = _cpu_lap("loco_pre_misc", lap)
	if posture != null and posture.active() and not _held and sim_tier != SimTier.HERO:
		# Sitting, lying and sleeping on the clip tiers: the same posture state machine, the
		# baked posture clips for the pose, and she stays exactly where she was put.
		_clip_posture_tick(delta)
		if prof: _cpu_lap("clip_posture_tick", lap)
		return
	if posture != null and posture.active() and not _held:
		_tick+=1
		_posture_delta+=delta
		# A settled rest on the floor runs every hero_divisor-th tick with the time it skipped;
		# the terrain modifier keeps re-applying the prepared pose in between.
		if hero_divisor>1 and ((_tick+sim_phase)%hero_divisor)!=0 and resting_hold() and is_on_floor(): return
		var step:=_posture_delta
		_posture_delta=0.0
		_maintain_support(step)
		if _interaction_seconds>0.0:
			_interaction_seconds-=step
			if _interaction_seconds<=0.0: end_interaction()
		velocity=Vector3(0,-.25 if is_on_floor() else (0.0 if _heightmap_supported else velocity.y-9.8*step),0)
		move_and_slide()
		_command_speed=0.0;actual_speed=0.0;_blend=0.0
		posture.update(step)
		secondary.update(step, phase, 0.0, 1.0, profile.sway_amount, profile.hip_height, Vector3.ZERO, 1.0)
		posture.apply_attention()
		if prof: _cpu_lap("hero_posture", lap)
		return
	_posture_delta = 0.0
	if sim_tier != SimTier.HERO:
		_far_tick(delta, motion_delta)
		return
	_tick += 1
	# Just back from a clip tier inside something (pony_clip_tier.gd ease_overlap).
	if _overlap_age >= 0.0: CLIP_TIER.ease_overlap(self, delta)
	# Rays, support, contacts and the leg solve run every hero_divisor-th tick (30 Hz past
	# PonyCrowd.close_distance) with a matching step; the previous corrected pose stays
	# prepared in between. dev 2026-09-17: the solver need not run every tick for mares
	# that are not next to you.
	var divisor := hero_divisor
	var solve_tick := divisor <= 1 or ((_tick + sim_phase) % divisor) == 0
	var solve_delta := delta * maxi(divisor, 1)
	_collision_cooldown = maxf(0.0, _collision_cooldown - delta)
	if _interaction_seconds > 0.0:
		_interaction_seconds -= delta
		if _interaction_seconds <= 0.0:
			end_interaction()
	if _lunge_left > 0.0:
		_lunge_left -= delta
		_desired = _lunge_velocity if _lunge_left > 0.0 else Vector3.ZERO
		_face_direction = Vector3.ZERO
	var nav_motion := _nav_motion_live()
	if nav_motion: nav_refusal = NAV_REFUSAL_NONE
	var wanted_speed := _desired.length()
	# The native follower's wall contact keeps the slide's tangent; only the legacy path cools down.
	if _touch_blocks() or (_collision_cooldown > 0.0 and not nav_motion):
		wanted_speed = 0.0
	_gait_request = wanted_speed
	# The navigation command accelerates toward the follower's target; the gait follows the target.
	if nav_motion and wanted_speed > 0.0: _gait_request = maxf(wanted_speed, _nav_gait_speed)
	var slope_weight := clampf(_slope_angle / deg_to_rad(35.0), 0.0, 1.0)
	_stride_scale = 1.0
	var slope_scale := lerpf(1.0, 0.45, slope_weight)
	if nav_motion:
		# The follower already scaled its target by this factor (reported below); scaling its
		# command again would compound with its acceleration window into a crawl uphill.
		nav_speed_scale = slope_scale
	else:
		wanted_speed *= slope_scale
	# Hills are taken at the bottom of the trot band and at an unhurried walk: the
	# longer strides of a fast gait exceed planted reach once the ground tilts.
	# Ordinary rolling ground (under ~8 degrees) must not throttle a follower; real hills
	# bring the request down to the bottom of the trot band.
	var hill := smoothstep(deg_to_rad(8.0), deg_to_rad(16.0), _slope_angle)
	var hill_cap: float = lerpf(profile.max_travel_speed, profile.trot_speed.x, hill) if _gait_request >= profile.trot_entry \
		else lerpf(profile.trot_entry, profile.walk_speed.x, hill)
	wanted_speed = minf(wanted_speed, hill_cap)
	# The gait follows the caller's request capped by the hill, never by the slope's
	# speed scaling: a hill slows the trot, it does not turn it into a walk.
	_gait_request = minf(_gait_request, hill_cap)
	if solve_tick or _corner_stale:
		# Standing with nothing asked of her, the four corner rays only feed minf(0, ...): skip them
		# and measure on the first step she wants to move instead (CORNER_IDLE_SKIP).
		if CORNER_IDLE_SKIP and wanted_speed <= 0.0 and _command_speed <= 0.0:
			_corner_stale = true
		else:
			_corner_speed = _terrain_corner_speed()
			_corner_stale = false
	wanted_speed = minf(wanted_speed, _corner_speed)
	if solve_tick:
		_blocked = not _safe_ahead(maxf(wanted_speed, _command_speed))
	if _blocked:
		wanted_speed = 0.0
		_gait_request = 0.0
	_maintain_support(delta)
	if prof: lap = _cpu_lap("hero_speed_support", lap)
	var previous_position := global_position
	var was_grounded := is_on_floor() or _heightmap_supported
	_command_speed = move_toward(_command_speed, wanted_speed,
		(profile.acceleration if wanted_speed > _command_speed else profile.braking) * delta)
	var horizontal_speed := _command_speed
	_yaw_rate = 0.0
	_turn_step_speed = 0.0
	var facing := _face_direction.length_squared() > 0.5 and is_on_floor() and not _held \
		and not _touch_blocks() and _collision_cooldown <= 0.0 and horizontal_speed < 0.03
	var travel_forward := Vector3.ZERO
	if facing:
		var yaw_error := angle_difference(rotation.y, atan2(-_face_direction.x, -_face_direction.z))
		if solve_tick:
			_turn_ground_safe = _turn_support_safe(signf(yaw_error) * 0.12)
		if absf(yaw_error) > deg_to_rad(3.0) and _turn_ground_safe:
			# Start a supported walk before allowing yaw. Angular foot travel advances
			# its clock without pretending that the torso is translating.
			_turn_step_speed = minf(0.23, maxf(0.12, absf(yaw_error) * 0.3))
			var yaw_step := signf(yaw_error) * minf(absf(yaw_error), face_turn_rate * delta * _blend)
			_yaw_rate = yaw_step / delta
			rotation.y += yaw_step
	elif backing and wanted_speed > 0.01 and not _touch_blocks() and not _held:
		# Backing up: she keeps her heading and her body moves along her own +Z.
		travel_forward = global_basis.z.normalized()
	elif nav_motion and not _touch_blocks() and not _held:
		travel_forward = _nav_turn(delta, horizontal_speed, solve_tick)
	elif navigation_steering and _desired.length() > 0.01 and not _touch_blocks() and not _held:
		var want_yaw := atan2(-_desired.x, -_desired.z)
		var next_yaw := rotate_toward(rotation.y, want_yaw, steer_turn_rate * delta)
		_yaw_rate = angle_difference(rotation.y, next_yaw) / delta
		rotation.y = next_yaw
		horizontal_speed *= maxf(0.0, cos(angle_difference(rotation.y, want_yaw)))
	elif wanted_speed > 0.01 and horizontal_speed > 0.01:
		var want_yaw := atan2(-_desired.x, -_desired.z)
		var next_yaw := rotate_toward(rotation.y, want_yaw,
			horizontal_speed / (2.0 * profile.hip_height) * delta)
		_yaw_rate = angle_difference(rotation.y, next_yaw) / delta
		rotation.y = next_yaw
	var forward := travel_forward if travel_forward != Vector3.ZERO else -global_basis.z.normalized()
	velocity.x = forward.x * horizontal_speed
	velocity.z = forward.z * horizontal_speed
	velocity.y = -0.25 if is_on_floor() else (0.0 if _heightmap_supported else velocity.y - 9.8 * delta)
	if _jump_request > 0.0:
		velocity.y = _jump_request
		_jump_request = 0.0
		_heightmap_supported = false
		if not _held: audio_jumped.emit(global_position)
	if _held:
		# A spring drives the physical root toward the hand target. Collision
		# remains active; holding never teleports her through a wall.
		var grip_error := _hold_target - get_grip_transform(carry.grip_name).origin
		if not _hand_targets.is_empty():
			grip_error = Vector3.ZERO
			for grip: String in _hand_targets:
				grip_error += (Vector3(_hand_targets[grip]) - get_grip_transform(grip).origin) / _hand_targets.size()
		# Hard lock (dev, round 5: "locked to my hands no matter what"): the
		# grip goes exactly where the hand is this step, no spring. The carry
		# solver still reads the implied velocity for sway and weight.
		if has_meta("player_head_guard"):
			var guard:Node=get_meta("player_head_guard")
			if is_instance_valid(guard):grip_error=guard.limit_carry(self,grip_error)
		global_position += grip_error
		_hold_velocity = grip_error / maxf(delta, 0.0001)
		velocity = Vector3.ZERO
		if is_finite(_hold_yaw):
			rotation.y = rotate_toward(rotation.y, _hold_yaw, 25.0 * delta)
		# While the hind legs support the lift, raising the chest first pitches
		# about the hips. Lift the root once that supported rotation is spent.
		if true in carry.supports and carry.pitch < deg_to_rad(46.0):
			velocity.y = minf(velocity.y, 0.0)
	var vertical_speed_before_move := velocity.y
	if prof: lap = _cpu_lap("hero_steer", lap)
	# Standing still on a still floor (SETTLED_MOVE_SKIP): the capsule's slide has moved her by
	# exactly nothing for two steps in a row, so between rechecks keep that result instead of
	# sliding again (each slide also re-sends every mesh of her a new world transform).
	var still := SETTLED_MOVE_SKIP and not _held and velocity.x == 0.0 and velocity.z == 0.0 \
		and velocity.y == -0.25 and _yaw_rate == 0.0 and is_on_floor() and not _heightmap_supported \
		and not needs_full_rate()
	if still and global_position == _settled_at and _settled_moves >= 2 and _settled_skips < SETTLED_MOVE_RECHECK - 1:
		_settled_skips += 1
		velocity = _settled_velocity
	else:
		if not _move_player_step(delta): move_and_slide()
		_settled_skips = 0
		if still and global_position == previous_position and is_on_floor() and get_platform_velocity() == Vector3.ZERO:
			_settled_moves += 1
			_settled_velocity = velocity
			_settled_at = global_position
		else:
			_settled_moves = 0
			_settled_at = Vector3.INF
	if prof: lap = _cpu_lap("hero_move_and_slide", lap)
	if not _held and not was_grounded and is_on_floor():
		audio_landed.emit(global_position, maxf(0.0, -vertical_speed_before_move))
		# The capsule stops at the floor; her mass still settles briefly into
		# the supporting legs. Joint limits handle the resulting compression.
		_body_offset_velocity.y -= clampf(-vertical_speed_before_move, 0.0, 4.0) * 0.12
	if _held:
		_hold_velocity = velocity
	var displacement := global_position - previous_position
	if not _held and _initialized:
		_body_height -= displacement.y
	_ground_velocity = displacement / delta
	var horizontal_velocity := Vector3(_ground_velocity.x, 0.0, _ground_velocity.z)
	var acceleration := (horizontal_velocity - _previous_horizontal_velocity) / delta
	_previous_horizontal_velocity = horizontal_velocity
	_update_give(delta, acceleration)
	carry.update(delta, acceleration, _hold_target)
	if posture != null:posture.release_limits_when_safe()
	if is_on_wall() and horizontal_speed > 0.05 and not _held:
		if nav_motion or _preserve_wall_slide():
			# The slide already removed the motion into the wall: keep only the tangent the body
			# achieved. The follower sees the contact; repeated frontal contact repairs the route.
			_command_speed = minf(_command_speed, Vector2(displacement.x, displacement.z).length() / delta)
		else:
			_collision_cooldown = 0.4
			_command_speed = 0.0
			wanted_speed = 0.0
	if nav_motion:
		nav_executed_speed = horizontal_speed
		nav_executed_yaw_rate = _yaw_rate
		nav_wall_normal = _nav_wall_normal()
		if _blocked: nav_refusal = NAV_REFUSAL_SUPPORT
		elif _touch_blocks(): nav_refusal = NAV_REFUSAL_TOUCH
	actual_speed = displacement.length() / delta if is_on_floor() else 0.0
	if Vector2(displacement.x, displacement.z).length() < 0.00001:
		actual_speed = 0.0
	_keep_stance(delta)
	_update_state(delta, maxf(wanted_speed, _turn_step_speed))
	if not _held and (state == Motion.MOVING or state == Motion.STARTING or (state == Motion.STOPPING and actual_speed > 0.02)):
		step_timing.excluded_leg=hoof_hold.leg_index if hoof_hold.active() else -1
		step_timing.reversed = backing
		phase = step_timing.advance(delta, maxf(actual_speed, _turn_step_speed), phase, feet, global_basis.z.normalized(), maxf(_gait_request, _turn_step_speed))
	if prof: lap = _cpu_lap("hero_state_timing", lap)
	# Read a clean source pose every tick; the modifier's deferred write is never input.
	source_pose = _sample_source_pose()
	if prof: lap = _cpu_lap("hero_pose_sample_gait", lap)
	_update_secondary(delta)
	if prof: lap = _cpu_lap("hero_pose_sample_secondary", lap)
	secondary.apply_pose(source_pose, joint_limits)
	if prof: lap = _cpu_lap("hero_pose_sample_apply", lap)
	if activity_mouth_pose != null: activity_mouth_pose.apply_source(source_pose, delta)
	carry.apply_pose(source_pose, delta)
	hoof_hold.apply_source(source_pose,delta)
	_update_eyes()
	if prof: lap = _cpu_lap("hero_pose_sample_layers", lap)
	# Geometry lids ride the lid bones; the shader lid stays behind them. Open lids on an
	# unanimated lid rig already sit at rest in the sampled pose.
	if eyelids.closure != 0.0 or not _lids_static or carry.blend > 0.0:
		secondary.apply_lids(source_pose, eyelids.closure)
	if carry.blend > 0.0:
		joint_limits.apply(source_pose)
	if not _initialized and is_on_floor():
		_initialized = true
	if prof: lap = _cpu_lap("hero_pose_sample", lap)
	if not solve_tick:
		return
	_update_body(solve_delta)
	# Just back from a clip tier: the solver's pivot eases in from the clip's (pony_clip_tier.gd).
	if _hero_blend < 1.0: CLIP_TIER.blend_pivot(self, solve_delta)
	if activity_mouth_pose != null: activity_mouth_pose.apply_body_pivot(pivot)
	if prof: lap = _cpu_lap("hero_update_body", lap)
	if _initialized:
		_update_contacts(solve_delta)
		# hoof_planted once the shown hoof is down (pony_hoof_plants.gd), not when the model loads it.
		_hoof_plants.hero(self, solve_delta)
		_spawn_settle = maxf(0.0, _spawn_settle - solve_delta)
	if prof: lap = _cpu_lap("hero_contacts", lap)
	if _enqueue_solve(solve_delta):
		if prof: _cpu_lap("hero_enqueue_solve", lap)
		return
	_solve_pose(solve_delta)
	_finish_joint_constraints()
	if prof: lap = _cpu_lap("hero_solve", lap)
	var use_correction := corrections_enabled or _held or carry.blend > 0.0
	if not _gpu_pose_pending:
		modifier.prepared = corrected_pose if use_correction else source_pose.duplicate()
	if not use_correction:
		pivot.transform = Transform3D.IDENTITY
		_apply_body_scale()


## The unmodified gait source, before secondary motion, carry, hoof holding or constraints.
func _sample_source_pose() -> Array[Transform3D]:
	# blended_steps discards the gait at zero weight. Keep a fresh standing copy for the
	# live secondary/interaction layers without computing those unused gait transforms.
	if _blend <= 0.0: return profile.standing.duplicate()
	if profile.native_sampler != null:
		return profile.native_sampler.sample(phase, step_timing.phases, step_timing.walk_blend,
			step_timing.gallop_phase, step_timing.gallop_blend, step_timing.leg_blend, _blend)
	var authored_pose: Array[Transform3D]
	var leg_blends: PackedFloat64Array = step_timing.leg_blend
	var legs_all_gallop := leg_blends[0] >= 1.0 and leg_blends[1] >= 1.0 and leg_blends[2] >= 1.0 and leg_blends[3] >= 1.0
	var legs_all_trot := leg_blends[0] <= 0.0 and leg_blends[1] <= 0.0 and leg_blends[2] <= 0.0 and leg_blends[3] <= 0.0
	if step_timing.gallop_blend >= 1.0 and legs_all_gallop:
		authored_pose = profile.sample_gait_pose("gallop", step_timing.gallop_phase)
	else:
		authored_pose = profile.sample_steps(phase, step_timing.phases, step_timing.walk_blend)
		if step_timing.gallop_blend > 0.0 or not legs_all_trot:
			authored_pose = profile.blend_poses(authored_pose,
				profile.sample_gait_pose("gallop", step_timing.gallop_phase), step_timing.gallop_blend, leg_blends)
	return profile.blended_steps(authored_pose, _blend)


## --- Crowd tiers -------------------------------------------------------------

## Interactions keep a pony at full simulation whatever her distance.
func is_pinned() -> bool:
	return body_pinned()


## Physical interaction only (dev 2026-09-25: "remove pinning??? ... they dont need to be at full
## detail just because theyre sleeping if theyre still far away"): held, a hoof held, carried,
## thrown, flying, on a moving support, or being touched. Sitting, lying, sleeping, following,
## walking through a house and paused ponies go by distance like any other; the clip tiers play
## their baked postures. The hybrid adds conversation, which PonyCrowd limits to close range.
func body_pinned() -> bool:
	if activity_mouth_pose != null and activity_mouth_pose.active(): return true
	if water_escape.active: return true
	if is_instance_valid(moving_support): return true
	if thrown != null and thrown.active(): return true
	return (flight != null and flight.active()) or _held or hoof_hold.leg_index>=0 or not _interaction.is_empty() or carry.blend > 0.0


## Pinned reasons that keep the solver at every tick whatever the distance (PonyCrowd.rank()).
func needs_full_rate() -> bool:
	if activity_mouth_pose != null and activity_mouth_pose.active(): return true
	if _held or hoof_hold.leg_index >= 0 or carry.blend > 0.0 or not _interaction.is_empty(): return true
	if is_instance_valid(moving_support): return true
	return (thrown != null and thrown.active()) or (flight != null and flight.active())


## A seated or lying rest that has settled; the only state PonyCrowd runs at divisor 4.
func resting_hold() -> bool:
	return posture != null and not _held and posture.phase == "hold" and posture.settled()


func set_detail_divisor(divisor: int, _phase: int = 0) -> void:
	detail_divisor = maxi(divisor, 1)


## Floor support as the navigator sees it (FAR ponies stand on the grid, not on Jolt).
func grounded() -> bool:
	if thrown != null and thrown.active(): return false
	return (flight == null or not flight.active()) and (sim_tier != SimTier.HERO or is_on_floor() or _heightmap_supported)


## How far above her the floor the last rays measured is by now, carried along its slope. She lags
## a climb between rays (bridge ramps rise about 0.5 m per metre), and a ray cast from her height
## alone then starts under the deck and finds what lies below it: she walked in under the bridge
## and stayed there (player report 2026-10-30: Rainbow Dash lost on the way back from fishing).
func _clip_floor_rise() -> float:
	if not is_finite(_clip_floor): return 0.0
	var forward := -global_basis.z
	forward.y = 0.0
	var expected := _clip_floor + (global_position - _clip_floor_at).dot(forward.normalized()) * tan(_clip_pitch_target)
	return clampf(expected - global_position.y, 0.0, profile.hip_height)


## Re-seat the body on the ground beneath (or above, when she has sunk under it). With
## no collision at all here, hold the terrain heightmap height instead of falling.
func _maintain_support(delta: float) -> void:
	if is_on_floor() or _held:
		_unsupported_seconds = 0.0
		_heightmap_supported = false
	else:
		_unsupported_seconds += delta
		if _unsupported_seconds > 0.25 and (_tick % 15) == 0:
			_recover_support()


func _support_ray(above: float) -> Dictionary:
	return SUPPORT.support_ray(self, above)


func _is_house_floor(point: Vector3) -> bool:
	return SUPPORT.is_house_floor(self, point)


func _recover_support() -> void:
	SUPPORT.recover(self)


## Count of tier changes across all ponies (diagnostic for the crowd report).
static var transitions := 0

func set_sim_tier(tier: int, phase: int = 0) -> void:
	# A body layout without baked gaits has nothing to play: she stays on the full solver.
	if tier != SimTier.HERO and _baked == null:
		tier = SimTier.HERO
	sim_phase = phase
	if _clip_head != null:
		_clip_head.active = tier == SimTier.NEAR
	if posture != null:
		posture.clip_output = tier != SimTier.HERO
	if tier == sim_tier:
		return
	if skeleton == null or animation == null or modifier == null:
		return
	refresh_hidden_clip()
	transitions += 1
	var was_clips := sim_tier != SimTier.HERO
	_handoff_clip_head = sim_tier == SimTier.NEAR and _clip_head != null
	sim_tier = tier as SimTier
	_clip_refresh = true
	_rig_cache_valid = false
	if sim_tier != SimTier.HERO:
		if not was_clips: _enter_far()
	elif was_clips:
		_leave_far()
	# After a subclass's set_sim_tier has parked or woken its own modifiers.
	_update_rig_rates.call_deferred()


## Whether this pony's body layout has baked gait clips (PonyCrowd keeps the others HERO).
func has_clip_tier() -> bool:
	return _baked != null


## Into and out of the clip tiers, and the hand-off clip between them: pony_clip_tier.gd.
func _enter_far() -> void:
	CLIP_TIER.enter(self)


func _bake_handoff() -> void:
	CLIP_TIER.bake_handoff(self)


func _leave_far() -> void:
	CLIP_TIER.leave(self)


func _baked_name(clip: String) -> String:
	return String(BAKED_GAITS.LIBRARY) + "/" + clip


## True while a baked gait (not the stand or the hand-off) is the current clip.
func _clip_gait_playing() -> bool:
	var current := String(animation.current_animation)
	return current.begins_with(String(BAKED_GAITS.LIBRARY) + "/") and not current.ends_with("/" + BAKED_GAITS.STAND)


## Clip tiers (NEAR/FAR, docs/CLIP_TIER_2026_09_25.md): the solver-baked gait clips on the
## model's AnimationPlayer and no collision body. The pony's logic runs on every
## LOGIC_DIVISOR-th step of her phase group (_clip_logic, 20 Hz); the root, floor settle,
## pivot and clip advance every step (_clip_step), so the motion stays smooth.
func _far_tick(delta: float, motion_delta: float = -1.0) -> void:
	var prof := LOCO_CPU.enabled
	var lap := Time.get_ticks_usec() if prof else 0
	if _rest_frozen:
		_set_rest_frozen(false)
	_tick += 1
	_logic_delta += delta
	if is_logic_tick():
		var dt := _logic_delta
		_logic_delta = 0.0
		_logic_steps = 0
		_clip_logic(dt)
		if prof: lap = _cpu_lap("clip_logic", lap)
		if sim_tier == SimTier.FAR: _update_rig_rates()
		if prof: lap = _cpu_lap("clip_rig_rates", lap)
	else:
		_logic_steps += 1
	_clip_step(motion_delta if motion_delta >= 0.0 else delta)
	if prof: _cpu_lap("clip_step", lap)


## Whether this physics step runs the pony's logic: every step on the solver, every
## LOGIC_DIVISOR-th step on NEAR, far_logic_divisor-th step on FAR.
## The navigator shares this beat; NEAR eye and mouth modifiers retain their matching phase.
func is_logic_tick() -> bool:
	return sim_tier == SimTier.HERO or ((Engine.get_physics_frames() + sim_phase) % logic_divisor()) == 0


## Steps between logic ticks in the current tier: LOGIC_DIVISOR for NEAR, far_logic_divisor for FAR.
func logic_divisor() -> int:
	return maxi(1, far_logic_divisor) if sim_tier == SimTier.FAR else LOGIC_DIVISOR


## How far this step is between the last two logic states (1 on the solver): per-step visuals
## (the clip-tier head, the tail springs) interpolate by it, one logic step behind.
func logic_alpha() -> float:
	return 1.0 if sim_tier == SimTier.HERO else minf(1.0, float(_logic_steps + 1) / logic_divisor())


## The clip tiers' 20 Hz logic: travel request and heading, the support check ahead, floor and
## slope rays, gait clip and its rate, and the head's secondary motion.
func _clip_logic(dt: float) -> void:
	var prof := LOCO_CPU.enabled
	var lap := Time.get_ticks_usec() if prof else 0
	_collision_cooldown = 0.0
	var nav_motion := _nav_motion_live()
	var stepping := nav_motion and _nav_mode == NAV_MODE_STEP_TURN
	if nav_motion: nav_speed_scale = 1.0
	_clip_wanted = _desired.length()
	if _clip_wanted > 0.01 and not nav_motion and not backing:
		_clip_yaw = atan2(-_desired.x, -_desired.z)
	# No collision body here: certify support beyond the next logic step so neither stale
	# paths nor the terrain far below a cloud become a walkable drop.
	_clip_blocked = false
	var travel := maxf(_command_speed, _clip_wanted) * dt
	if _clip_wanted > 0.01 and travel > 0.0:
		var here := global_position
		var ahead := (1.0 if backing else -1.0) * global_basis.z.normalized()
		# One ray certifies two logic steps: it is cast a step further out, and the next tick
		# skips it when the point it needs (a step plus hip_height ahead, same heading) is no
		# farther than the one certified. She still stops at least hip_height short of a drop; a
		# blocked result, a turn or a second tick casts again.
		var moved := here - _clip_ahead_from
		var along := moved.dot(_clip_ahead_dir)
		if _clip_ahead_certified and _clip_ahead_skips < 1 and ahead.dot(_clip_ahead_dir) > 0.9986 and along >= 0.0 \
				and along + travel + profile.hip_height <= _clip_ahead_reach \
				and (moved - _clip_ahead_dir * along).length_squared() < 0.0025:
			_clip_ahead_skips += 1
		else:
			var reach := 2.0 * travel + profile.hip_height
			var point := here + ahead * reach
			var hit := _probe(point, _clip_floor_rise())
			var floor_y: float = float(hit.position.y) if not hit.is_empty() else (_crowd.floor_y(point, here.y) if _crowd != null else NAN)
			_clip_ahead_certified = true
			_clip_ahead_skips = 0
			_clip_ahead_from = here
			_clip_ahead_dir = ahead
			_clip_ahead_reach = reach
			if not is_finite(floor_y) or absf(floor_y - here.y) > maxf(profile.step_height, reach * tan(deg_to_rad(profile.max_slope_degrees))):
				_clip_blocked = true
				_clip_ahead_certified = false
				_command_speed = 0.0
	else:
		_clip_ahead_certified = false
	if nav_motion:
		nav_refusal = NAV_REFUSAL_SUPPORT if _clip_blocked else NAV_REFUSAL_NONE
		nav_wall_normal = Vector3.ZERO
	if prof: lap = _cpu_lap("clip_logic_ahead_probe", lap)
	_clip_probe_logic -= 1
	# A pony that has not moved or turned since the last rays found real collision under her keeps
	# that floor; the rays still run about every 2 s (CLIP_FLOOR_KEEP refreshes) in case it changed.
	if _clip_probe_logic <= 0 and _clip_blend >= 1.0 and _clip_floor_from_ray and is_finite(_clip_floor) and _clip_floor_keep < CLIP_FLOOR_KEEP \
			and rotation.y == _clip_floor_yaw and global_position.distance_squared_to(_clip_floor_at) < 0.0025:
		_clip_probe_logic = 3
		_clip_floor_keep += 1
	elif _clip_probe_logic <= 0 or _clip_blend < 1.0:
		_clip_probe_logic = 3
		_clip_floor_keep = 0
		_clip_floor_yaw = rotation.y
		var half: Vector3 = -global_basis.z.normalized() * 0.45
		var rise := _clip_floor_rise()
		var centre := _probe(global_position, rise)
		if not centre.is_empty() and float(centre.position.y) < global_position.y - CLIP_DROP_CHECK and _crowd != null:
			# A big drop where the walk grid knows a floor level with her: the ray began under a
			# deck she is stepping onto. Take the grid's floor, the branch below.
			var known: float = _crowd.floor_y(global_position, global_position.y)
			if is_finite(known) and known > float(centre.position.y) + CLIP_DROP_CHECK: centre = {}
		_clip_floor_from_ray = not centre.is_empty()
		if not centre.is_empty():
			_clip_floor = float(centre.position.y)
			var front := _probe(global_position + half, rise)
			var back := _probe(global_position - half, rise)
			if not front.is_empty() and not back.is_empty():
				_clip_pitch_target = clampf(atan2(float(front.position.y) - float(back.position.y), 0.9), -0.4, 0.4)
		else:
			_clip_floor = _crowd.floor_y(global_position, global_position.y) if _crowd != null else NAN
			if is_finite(_clip_floor) and _crowd != null:
				var front_y: float = _crowd.floor_y(global_position + half, _clip_floor)
				var back_y: float = _crowd.floor_y(global_position - half, _clip_floor)
				if is_finite(front_y) and is_finite(back_y):
					_clip_pitch_target = clampf(atan2(front_y - back_y, 0.9), -0.4, 0.4)
		_clip_floor_at = global_position
	if prof: lap = _cpu_lap("clip_logic_floor_rays", lap)
	# Gait: the solver's bands and hysteresis, with the trot split at the bottom of its travel
	# band between the two baked trot speeds.
	_clip_gait_hold = maxf(0.0, _clip_gait_hold - dt)
	if _clip_age > maxf(CLIP_HANDOFF_SECONDS + 0.15, _clip_blend_end + 0.1) and String(animation.current_animation) != HANDOFF \
			and animation.has_animation_library("handoff") and animation.get_animation_library("handoff").has_animation("crowd_handoff"):
		animation.get_animation_library("handoff").remove_animation("crowd_handoff")
	# A stepping turn walks the legs on the spot: the walk clip, slowly, while the root turns.
	var moving := actual_speed > 0.05 or _command_speed > 0.05 or stepping
	if moving and _clip_gait_hold <= 0.0:
		var gait_wanted := _clip_wanted
		if stepping: gait_wanted = profile.walk_speed.x
		elif nav_motion and _clip_wanted > 0.0: gait_wanted = maxf(_clip_wanted, _nav_gait_speed)
		var chosen := CLIP_TIER.choose_gait(profile, _clip_gait, gait_wanted, actual_speed)
		if chosen != _clip_gait:
			_clip_gait = chosen
			_clip_gait_hold = profile.gait_hold_seconds
	var clip := _baked_name(_clip_gait if moving else BAKED_GAITS.STAND)
	if String(animation.current_animation) != clip:
		var from_handoff := String(animation.current_animation) == HANDOFF
		# Keep the stride's phase across gait changes (every clip starts at the leading leg's
		# phase wrap); out of the hand-off, start where the solver's leading leg was.
		var at := _clip_enter_phase if from_handoff else 0.0
		if _clip_gait_playing() and animation.current_animation_length > 0.0:
			at = animation.current_animation_position / animation.current_animation_length
		var blend: float = CLIP_HANDOFF_SECONDS if from_handoff else profile.gait_blend_seconds
		animation.play(clip, blend)
		# The mixer's crossfade runs in clip time: at the slowest playback rate (the walk's floor,
		# also the stepping turn's 0.5) it lasts 2x.
		_clip_blend_end = _clip_age + blend / CLIP_TIER.WALK_RATE_FLOOR
		if moving:
			animation.seek(fposmod(at, 1.0) * animation.current_animation_length, false)
	_clip_static = not moving  # the stand clip is now current
	var clip_speed := BAKED_GAITS.speed(_baked, _clip_gait) * profile.body_scale
	# Each clip only near its own baked speed (pony_clip_tier.gd RATE): a slow pony slow-trots
	# (trot_slow) instead of playing the everyday trot in slow motion.
	animation.speed_scale = clampf(actual_speed / clip_speed, CLIP_TIER.rate_floor(_clip_gait), CLIP_TIER.RATE.y) \
		if moving and clip_speed > 0.0 else 1.0
	if stepping and actual_speed < 0.05: animation.speed_scale = 0.5
	# Backing up plays the walk clip in reverse (the same poses, the other way round).
	if backing and moving: animation.speed_scale = -absf(animation.speed_scale)
	if prof: lap = _cpu_lap("clip_logic_gait", lap)
	_hoof_plants.logic(self, sim_tier == SimTier.NEAR)
	if sim_tier == SimTier.NEAR:
		# The live head: the secondary's breath, give and gaze at this logic tick; ClipHead
		# interpolates from the previous tick's angles every step.
		# Every clip starts at the leading leg's phase wrap, like the solver's stride phase.
		var stride := animation.current_animation_position / animation.current_animation_length \
			if _clip_gait_playing() and animation.current_animation_length > 0.0 else phase
		secondary.update(dt, stride, clampf(actual_speed / profile.nominal_speed, 0.0, 1.0), 1.0,
			profile.sway_amount, profile.hip_height, Vector3.ZERO, 1.0)
		clip_head_from = clip_head_to
		clip_head_to = PackedVector3Array([secondary.head_angles, secondary.gaze_angles, secondary._neck_gaze])


## Clip gait for a wanted and actual speed, from the current one (pony_clip_tier.gd).
func _choose_clip_gait(gait: String, wanted: float, speed: float) -> String:
	return CLIP_TIER.choose_gait(profile, gait, wanted, speed)


## Every physics step in the clip tiers: turn toward the logic heading, move the root at the
## logic speed, settle on the floor and slope of the last rays, set the pivot, advance the clip.
func _clip_step(delta: float) -> void:
	_clip_age += delta
	var target := 0.0 if _clip_blocked else _clip_wanted
	_command_speed = move_toward(_command_speed, target,
		(profile.acceleration if target > _command_speed else profile.braking) * delta)
	var horizontal_speed := _command_speed
	_yaw_rate = 0.0
	var travel_forward := Vector3.ZERO
	# Writes that would not change anything are skipped below: every transform write re-notifies
	# her whole subtree (rigs, meshes, bodies, decals), and most clip-tier ponies stand still.
	if _nav_motion_live():
		# Navigation command: curvature at the executed speed (or a stepping turn), midpoint heading.
		var yaw := rotation.y
		var rate := 0.0
		if _nav_mode == NAV_MODE_STEP_TURN: rate = _nav_yaw_rate
		elif _nav_speed > 0.0001: rate = clampf(_nav_yaw_rate / _nav_speed * horizontal_speed, -steer_turn_rate, steer_turn_rate)
		_yaw_rate = rate
		if rate != 0.0:
			rotation.y = yaw + rate * delta
		travel_forward = Vector3(-sin(yaw + rate * delta * 0.5), 0.0, -cos(yaw + rate * delta * 0.5))
		nav_executed_speed = horizontal_speed
		nav_executed_yaw_rate = rate
	elif backing and _clip_wanted > 0.01:
		# Backing up keeps her heading; the clip plays in reverse (_clip_logic).
		travel_forward = global_basis.z.normalized()
	elif _clip_wanted > 0.01:
		var yaw := rotation.y
		var next_yaw := rotate_toward(yaw, _clip_yaw, 1.8 * delta)
		_yaw_rate = angle_difference(yaw, next_yaw) / delta
		if next_yaw != yaw:
			rotation.y = next_yaw
		horizontal_speed *= maxf(0.0, cos(angle_difference(rotation.y, _clip_yaw)))
	elif _face_direction.length_squared() > 0.5 and not _held and _collision_cooldown <= 0.0:
		# A standing turn toward a face request (navigator face_point: a group, a speaker, an
		# activity's work spot). The clip tier ignored it, so NEAR/FAR ponies never turned to
		# what they were told to face (real town activity run 2026-10-13). No stepping clip here;
		# twice HERO's face_turn_rate keeps a half turn to about 3.5 s.
		var yaw := rotation.y
		var next_yaw := rotate_toward(yaw, atan2(-_face_direction.x, -_face_direction.z), face_turn_rate * 2.0 * delta)
		_yaw_rate = angle_difference(yaw, next_yaw) / delta
		if next_yaw != yaw:
			rotation.y = next_yaw
	var before := global_position
	var forward := travel_forward if travel_forward != Vector3.ZERO else -global_basis.z.normalized()
	var next_position := before + forward * horizontal_speed * delta
	if is_finite(_clip_floor) and not has_meta("seated"):
		# Between the rays, follow the measured slope from where they were cast. A pony put on a
		# seat stays on it.
		var floor_y := _clip_floor + (next_position - _clip_floor_at).dot(forward) * tan(_clip_pitch_target)
		if absf(floor_y - next_position.y) <= profile.hip_height * 1.5:
			# Slower while handing off from HERO: that settle must not read as a hop.
			next_position.y = lerpf(next_position.y, floor_y, 1.0 - exp(-delta / (0.3 if _clip_blend < 1.0 else 0.12)))
	var prof := LOCO_CPU.enabled
	var lap := Time.get_ticks_usec() if prof else 0
	if next_position != before:
		global_position = next_position
	if prof: lap = _cpu_lap("clip_set_position", lap)
	_posture_pivot_settled = false
	# Once the pitch has converged and the pivot holds it, nothing below would change: skip it until
	# the logic tick moves the target (or a posture, hand-off or rescale writes the pivot).
	if not (_clip_pivot_settled and _clip_blend >= 1.0 and _clip_pitch == _clip_pitch_target):
		_clip_pivot_settled = false
		_clip_pitch = lerpf(_clip_pitch, _clip_pitch_target, 1.0 - exp(-delta / 0.25))
		if absf(_clip_pitch - _clip_pitch_target) < 1e-4:
			_clip_pitch = _clip_pitch_target
		var clip_pivot := Transform3D(Basis(Vector3.RIGHT, _clip_pitch).scaled(Vector3.ONE * body_scale), Vector3.ZERO)
		if _clip_blend < 1.0:
			_clip_blend = minf(1.0, _clip_blend + delta / CLIP_HANDOFF_SECONDS)
			pivot.transform = _clip_from.interpolate_with(clip_pivot, smoothstep(0.0, 1.0, _clip_blend))
		else:
			if pivot.transform != clip_pivot:
				pivot.transform = clip_pivot
			_clip_pivot_settled = _clip_pitch == _clip_pitch_target
	velocity = (global_position - before) / delta
	_ground_velocity = velocity
	_previous_horizontal_velocity = Vector3(velocity.x, 0.0, velocity.z)
	actual_speed = Vector2(velocity.x, velocity.z).length()
	var moving := actual_speed > 0.05
	state = Motion.MOVING if moving else Motion.STANDING
	_blend = 1.0 if moving else 0.0
	# A settled stand is one pose, left in place by the last advance (like a settled posture hold).
	if prof: lap = _cpu_lap("clip_pivot_state", lap)
	if _clip_refresh or not _clip_static or _clip_age <= _clip_blend_end:
		_clip_advance_delta += delta
		# A settled FAR gait (no crossfade, refresh or pin) poses her legs at 30 Hz, every other
		# step of her phase group with the time since; the root above still moves every step.
		if sim_tier == SimTier.FAR and not _clip_refresh and _clip_blend >= 1.0 \
				and _clip_age > _clip_blend_end and ((Engine.get_physics_frames() + sim_phase) & 1) != 0 \
				and not needs_full_rate():
			return
		_clip_refresh = false
		_advance_clip(_clip_advance_delta)
		_hoof_plants.step(self, animation, skeleton)
		_clip_advance_delta = 0.0
		if prof: _cpu_lap("clip_advance", lap)
	else:
		_clip_advance_delta = 0.0


func _advance_clip(delta: float) -> void:
	# Only the settled, looping baked gait has no signals, method tracks or posture timing.
	# Keep its clock exact while hidden, including changes of playback speed, so a gait switch
	# and the hand-back to HERO inherit the current phase. Crossfades still evaluate normally.
	if ((sim_tier == SimTier.FAR and (has_meta(PonyCrowd.HIDDEN) or coarse_motion)) \
				or (HIDDEN_RIG_PARK and sim_tier == SimTier.NEAR and has_meta(PonyCrowd.HIDDEN))) and not needs_full_rate() \
			and (posture == null or not posture.active()) and _clip_blend >= 1.0 \
			and _clip_age > _clip_blend_end and BAKED_GAITS.GAITS.has(_clip_gait) \
			and animation.current_animation == _baked_name(_clip_gait) \
			and animation.current_animation_length > 0.0:
		var at := animation.current_animation_position + delta * animation.get_playing_speed()
		animation.seek(fposmod(at, animation.current_animation_length), false)
		_clip_pose_deferred = true
		return
	_clip_pose_deferred = false
	animation.advance(delta)


## Called before PonyCrowd shows a hidden model or the tier hand-off reads its bones.
func refresh_hidden_clip() -> void:
	if not _clip_pose_deferred: return
	_clip_pose_deferred = false
	animation.advance(0.0)


## A posture on the clip tiers: pony_posture.gd's state machine on the 20 Hz logic beat, the
## baked posture clip matching its phase and clip time, and no movement at all, so a pony on a
## bench, in a bed or on the floor stays exactly where Seating, NightRest or her last step put her.
func _clip_posture_tick(delta: float) -> void:
	_tick += 1
	_logic_delta += delta
	posture.clip_output = true
	if is_logic_tick():
		var dt := _logic_delta
		_logic_delta = 0.0
		_logic_steps = 0
		_clip_posture_logic(dt)
		if sim_tier == SimTier.FAR: _update_rig_rates()
	else:
		_logic_steps += 1
	_clip_posture_step(delta)


func _clip_posture_logic(dt: float) -> void:
	if _rest_frozen:
		# Frozen asleep: only the state machine and the sleep state run (NightRest, seating and
		# the AI read them), until something changes.
		posture.update(dt)
		var still: String = posture.advance_sleep(dt) if posture.active() else ""
		if not posture.active() or posture.phase != "hold" or still == "" or get("sleeping") != true:
			_set_rest_frozen(false)
			if posture.active():
				_play_posture_clip(still)
		return
	if _interaction_seconds > 0.0:
		_interaction_seconds -= dt
		if _interaction_seconds <= 0.0: end_interaction()
	velocity = Vector3.ZERO
	_command_speed = 0.0
	actual_speed = 0.0
	_blend = 0.0
	state = Motion.STANDING
	posture.update(dt)
	if not posture.active():
		return  # recovered: the gait path takes her from the next step
	var style: String = posture.advance_sleep(dt)
	if sim_tier == SimTier.NEAR:
		secondary.update(dt, phase, 0.0, 1.0, profile.sway_amount, profile.hip_height, Vector3.ZERO, 1.0)
		clip_head_from = clip_head_to
		clip_head_to = PackedVector3Array([secondary.head_angles, secondary.gaze_angles, secondary._neck_gaze])
	# A hold whose clip is already playing: _play_posture_clip would only pick the same clip again.
	if not (_posture_clip_held and posture.phase == "hold" and posture.kind == _posture_clip_kind \
			and posture._sleep_style == _posture_clip_sleep and (posture._sleep_blend > 0.0) == _posture_clip_sleeping \
			and (style != "") == _posture_clip_styled and animation.current_animation == _posture_clip_name):
		_play_posture_clip(style)
	var asleep: bool = posture.phase == "hold" and style != "" and posture._sleep_blend >= 1.0 and _mixer_hold <= 0.0
	_asleep_seconds = _asleep_seconds + dt if asleep else 0.0
	if _asleep_seconds >= REST_FREEZE_SECONDS:
		_set_rest_frozen(true)


## Skeletons a settled clip-tier sleep freezes: the body here, plus the head and hair a hybrid adds.
func _rest_skeletons() -> Array[Skeleton3D]:
	return [skeleton]


## PonyCrowd hid (true) or showed (false) her model pivot; the rigs follow (HIDDEN_RIG_PARK).
func set_crowd_hidden(hidden: bool) -> void:
	if not HIDDEN_RIG_PARK or skeleton == null:
		return
	_update_rig_rates(not hidden)


## Rigs back on the per-tick pass after a hidden spell (subclasses reset what integrated over it).
func _rigs_unparked() -> void:
	pass


func _set_rest_frozen(frozen: bool) -> void:
	if not frozen:
		_asleep_seconds = 0.0
	if frozen == _rest_frozen:
		return
	_rest_frozen = frozen
	_update_rig_rates()


## Modifiers that only reshape the pose they are handed, with no clock or state of their own.
const POSE_ONLY_MODIFIERS: Array[String] = ["res://world/characters/hybrid_mare/filly_proportions.gd"]

## When each rig runs its modifier pass (2026-10-14). A frozen sleeper's rigs run none. A FAR rig
## whose active modifiers are all pose-only (FAR parks the tail springs, eyes, face, mouth and
## clip head; the hidden head and hair have none active) runs them only when its pose changes:
## Skeleton3D re-runs the modifiers on every pose write in either mode, so a walking FAR pony
## updates every step as before and a standing or hidden one keeps the identical skinned pose
## instead of recomputing it each tick (31 FAR bodies cost about 10 us each per step).
## dev 2026-10-20 perf pass: an AffectionPose at rest no longer keeps the rig on the per-tick pass
## (FAR_RIG_RESTING_AFFECTION). Every resident carries one, always active, so no FAR body ever went
## manual in the game; with the default head width (FillyProportions writes every pass) each FAR
## body, hidden or standing, re-skinned all its bones every physics step.
func _update_rig_rates(wake := false) -> void:
	var far := sim_tier == SimTier.FAR
	_rig_rest_affection = false
	var was_parked := _hidden_parked
	_hidden_parked = HIDDEN_RIG_PARK and sim_tier != SimTier.HERO and has_meta(PonyCrowd.HIDDEN)
	if was_parked and not _hidden_parked:
		_rigs_unparked()
	# Runs on every FAR logic tick: the rigs and each rig's non-pose-only modifiers are cached
	# (rebuilt on a tier or freeze change, a freed rig, or a rig whose children changed), and only
	# their `active` flags are read here (and an active AffectionPose's rest state), so a modifier
	# switched anywhere is still seen.
	if not _rig_cache_valid:
		_rig_cache = _rest_skeletons()
		_rig_watch.clear()
		_rig_children.clear()
		for rig in _rig_cache:
			_rig_watch.append([])
			_rig_children.append(-1)
		_rig_cache_valid = true
	for i in _rig_cache.size():
		var rig := _rig_cache[i]
		if not is_instance_valid(rig):
			_rig_cache_valid = false
			continue
		var manual := _rest_frozen or _hidden_parked
		var rest_affection := false
		if not manual and far:
			if rig.get_child_count() != _rig_children[i]:
				_rig_children[i] = rig.get_child_count()
				_rig_watch[i] = _watched_modifiers(rig)
			manual = true
			for modifier in _rig_watch[i]:
				if not is_instance_valid(modifier):
					_rig_children[i] = -1  # a modifier left: re-read this rig next time
					manual = false
					break
				if (modifier as SkeletonModifier3D).active:
					if _affection_resting(modifier as SkeletonModifier3D):
						rest_affection = true
						continue
					manual = false
					break
		if manual and not _rest_frozen and not _hidden_parked and rest_affection: _rig_rest_affection = true
		var mode := Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL if manual \
			else Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
		if rig.modifier_callback_mode_process == mode:
			continue
		rig.modifier_callback_mode_process = mode
		if (manual or wake) and rig.get_bone_count() > 0 and rig.is_inside_tree():
			# One last pass with the modifiers active now, as the next per-tick pass would show
			# (on a wake: her affection pose's first pass this same tick).
			rig.set_bone_pose_rotation(0, rig.get_bone_pose_rotation(0))


## _update_rig_rates' cache: the rigs, each rig's modifiers that are not pose-only, and the child
## count those were read at.
var _rig_cache: Array[Skeleton3D] = []
var _rig_watch: Array = []
var _rig_children := PackedInt32Array()
var _rig_cache_valid := false
## The rigs are parked because PonyCrowd hides her (HIDDEN_RIG_PARK).
var _hidden_parked := false

## Rollback switch (dev 2026-10-20 perf pass): false keeps every active AffectionPose on the
## per-tick pass, as before.
const FAR_RIG_RESTING_AFFECTION := true
## A FAR rig went manual past a resting AffectionPose: _physics_process watches her PonyAffection
## and hands the rig back the step it starts ticking.
var _rig_rest_affection := false
## Her PonyAffection node (relationship_runtime.gd adds it as "Affection"), looked up once.
var _affection: Node


## Her AffectionPose (world/relationships/affection_pose.gd) at rest: her PonyAffection is not
## ticking (every kiss, hug, buck, fidget and afterglow switches its process on before it moves the
## pose, and it switches off only once all of them are over) and nothing is left to ease out (no
## lean, buck, stretch, yawn, rear or kiss motion, face bound, no binding pending). Such a pass
## writes no bone, so skipping it changes nothing on screen. Any doubt counts as not resting.
func _affection_resting(modifier: SkeletonModifier3D) -> bool:
	if not FAR_RIG_RESTING_AFFECTION: return false
	if not is_instance_valid(_affection):
		_affection = get_node_or_null(^"Affection")
		if _affection == null: return false
	if _affection.is_processing() or _affection.is_physics_processing(): return false
	var pose: Variant = _affection.get(&"pose")
	if not (pose is SkeletonModifier3D) or pose != modifier: return false
	for key: StringName in [&"amount", &"buck_amount", &"stretch_amount", &"yawn_amount"]:
		var value: Variant = modifier.get(key)
		if not (value is float) or float(value) > .001: return false
	for key: StringName in [&"_rear_now", &"_motion"]:
		var value: Variant = modifier.get(key)
		if not (value is float) or float(value) > 0.0: return false
	var bind: Variant = modifier.get(&"bind_mouth")
	return modifier.get(&"_face_bound") == true and bind is Vector3 and not Vector3(bind).is_finite()


func _watched_modifiers(rig: Skeleton3D) -> Array[SkeletonModifier3D]:
	var watched: Array[SkeletonModifier3D] = []
	for child in rig.get_children():
		var modifier := child as SkeletonModifier3D
		if modifier == null:
			continue
		var script: Script = modifier.get_script()
		if script == null or not POSE_ONLY_MODIFIERS.has(script.resource_path):
			watched.append(modifier)
	return watched


## The baked clip for the posture's phase and clip time (pony_clip_tier.gd).
func _posture_clip(style: String) -> Dictionary:
	return CLIP_TIER.posture_clip(posture, style)


func _play_posture_clip(style: String, instant := false) -> void:
	_clip_static = false
	var choice := CLIP_TIER.posture_clip(posture, style)
	var clip: String = choice.clip
	var blend: float = choice.blend
	var name := _baked_name(clip)
	var current := String(animation.current_animation)
	if current != name:
		if current == HANDOFF:
			blend = CLIP_HANDOFF_SECONDS
		elif clip == posture.kind + "_hold" and (current == _baked_name(posture.kind) or current.is_empty()):
			blend = 0.0  # the entry clip ends on the hold pose
		elif clip.begins_with("sleep_") and (current == _baked_name("lie_down_" + clip) or current.is_empty()):
			blend = 0.0  # so does falling asleep while lying down
		if instant:
			blend = 0.0
		animation.play(name, blend)
		animation.speed_scale = choice.speed
		if not choice.hold:
			animation.seek(choice.time, false)
		_mixer_hold = blend + 0.1
	else:
		animation.speed_scale = choice.speed
		if not choice.hold and absf(animation.current_animation_position - float(choice.time)) > 0.04:
			animation.seek(choice.time, false)
	# What picked this hold clip (posture_clip's hold branch reads only these): _clip_posture_logic
	# skips the call while they and the playing clip stay the same.
	_posture_clip_held = choice.hold and posture.phase == "hold" and choice.speed == 1.0
	_posture_clip_kind = posture.kind
	_posture_clip_sleep = posture._sleep_style
	_posture_clip_sleeping = posture._sleep_blend > 0.0
	_posture_clip_styled = style != ""
	_posture_clip_name = animation.current_animation


var _posture_clip_held := false
var _posture_clip_kind := ""
var _posture_clip_sleep := ""
var _posture_clip_sleeping := false
var _posture_clip_styled := false
var _posture_clip_name := &""


func _clip_posture_step(delta: float) -> void:
	_clip_age += delta
	_clip_pivot_settled = false
	if _rest_frozen:
		return
	# Once the pivot has reached the posture's slope it stays there until that slope changes.
	if not (_posture_pivot_settled and _clip_blend >= 1.0 and posture._slope == _posture_pivot_slope):
		_posture_pivot_settled = false
		var target := Transform3D(posture._slope.orthonormalized().scaled_local(Vector3.ONE * body_scale), Vector3.ZERO)
		if _clip_blend < 1.0:
			_clip_blend = minf(1.0, _clip_blend + delta / CLIP_HANDOFF_SECONDS)
			pivot.transform = _clip_from.interpolate_with(target, smoothstep(0.0, 1.0, _clip_blend))
		elif not pivot.transform.is_equal_approx(target):
			pivot.transform = pivot.transform.interpolate_with(target, 1.0 - exp(-delta / 0.1))
		else:
			_posture_pivot_settled = true
			_posture_pivot_slope = posture._slope
	# A settled hold is one pose: once its crossfade is over the mixer is not advanced at all.
	var settled_hold: bool = posture.phase == "hold" and _mixer_hold <= 0.0 and _clip_blend >= 1.0
	_mixer_hold -= delta
	if not settled_hold:
		_advance_clip(delta)


## The clip tier's ground under `point`, shaped like a _probe() hit (tail floor contacts): the
## plane the last floor rays measured under her, sloped by their pitch, without another ray.
func clip_floor_hit(point: Vector3) -> Dictionary:
	if not is_finite(_clip_floor):
		return {}
	var forward := -global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var rise := tan(_clip_pitch_target)
	var y := _clip_floor + (point - _clip_floor_at).dot(forward) * rise
	return {"position": Vector3(point.x, y, point.z), "normal": (Vector3.UP - forward * rise).normalized()}


func _update_secondary(delta: float) -> void:
	# Spend less reach on decoration when the terrain already needs the legs.
	var reach_error := 0.0
	for foot in feet:
		if foot.valid:
			reach_error = maxf(reach_error, foot.error)
	var support := 1.0 if is_on_floor() and _initialized and not _held else 0.0
	var attention := support * (1.0 - carry.blend)
	if _spawn_settle > 0.0:
		support = 0.0
	support *= 1.0 - smoothstep(deg_to_rad(10.0), deg_to_rad(30.0), _slope_angle)
	support *= 1.0 - smoothstep(0.012, 0.030, reach_error)
	support *= 1.0 - carry.blend
	secondary.update(delta, phase, _blend * clampf(actual_speed / profile.nominal_speed, 0.0, 1.0),
		support, profile.sway_amount, profile.hip_height, _body_offset, attention)


func _update_give(delta: float, world_acceleration: Vector3) -> void:
	var local_acceleration := global_basis.orthonormalized().inverse() * world_acceleration.limit_length(15.0)
	var force := -local_acceleration * 0.6 + global_basis.orthonormalized().inverse() * _touch_force
	# Substeps keep the damped mass stable during slow frames and collisions.
	var steps := maxi(1, ceili(delta * 120.0))
	var dt := delta / steps
	for step in steps:
		_body_offset_velocity += (force - _body_offset * 110.0 - _body_offset_velocity * 17.0) * dt
		_body_offset += _body_offset_velocity * dt
		if _body_offset.length() > 0.04:
			_body_offset = _body_offset.limit_length(0.04)
			_body_offset_velocity *= 0.5


## Standing hooves are world locks with no reach limit (_update_contacts), and the legs only start
## above 0.05 m/s. A body moved more slowly than that, by a creeping command or a push, walked off
## its own hooves until the legs ran out of reach (dev 2026-11-04, Bon Bon). Past STANCE_SLIP she
## steps back under herself with the in-place walk a turn uses. Rollback: stance_step = false.
const STANCE_SLIP := 0.08
const STANCE_STEP_SPEED := 0.14
const STANCE_STEP_SECONDS := 0.6
var stance_step := true
var _stance_step_left := 0.0
var _stance_root := Vector3.INF

## How far her body has moved over the ground since her hooves took this stance, in metres.
func stance_slip() -> float:
	if state != Motion.STANDING or not _stance_root.is_finite(): return 0.0
	return Vector2(global_position.x - _stance_root.x, global_position.z - _stance_root.z).length()

func _keep_stance(delta: float) -> void:
	_stance_step_left = maxf(_stance_step_left - delta, 0.0)
	if state != Motion.STANDING or _stance_step_left > 0.0 or _spawn_settle > 0.0 or not _stance_root.is_finite():
		_stance_root = global_position
	if not stance_step: return
	if _stance_step_left == 0.0 and not _held and hoof_hold.leg_index < 0 and _interaction.is_empty() \
			and (posture == null or not posture.active()) and stance_slip() > STANCE_SLIP * body_scale:
		_stance_step_left = STANCE_STEP_SECONDS
	if _stance_step_left > 0.0: _turn_step_speed = maxf(_turn_step_speed, STANCE_STEP_SPEED)


func _update_state(delta: float, wanted_speed: float) -> void:
	if _held:
		state = Motion.HELD
		_blend = move_toward(_blend, 0.0, delta / 0.4)
		return
	if not is_on_floor() and not _heightmap_supported:
		if _initialized:
			state = Motion.UNSUPPORTED
			for foot in feet:
				foot.planted = false
				foot.valid = false
			_initialized = false
		return
	if state == Motion.UNSUPPORTED or state == Motion.HELD:
		state = Motion.STANDING
		_blend = 0.0
	if wanted_speed > 0.05 and (actual_speed > 0.02 or _turn_step_speed > 0.05 or not _initialized):
		if state == Motion.STANDING or state == Motion.STOPPING:
			if state == Motion.STANDING and maxf(_gait_request, _turn_step_speed) < profile.trot_entry:
				phase = step_timing.start_walk(wanted_speed)
			state = Motion.STARTING
		_blend = move_toward(_blend, 1.0, delta / profile.start_blend_seconds)
		if _blend >= 1.0:
			state = Motion.MOVING
	elif state == Motion.MOVING or state == Motion.STARTING:
		state = Motion.STOPPING
		_stop_elapsed = 0.0
		for foot in feet:
			foot.stop_start = foot.target
	if state == Motion.STOPPING:
		if actual_speed > 0.02:
			return
		if _stop_elapsed == 0.0:
			for foot in feet:
				foot.stop_start = foot.target
		_stop_elapsed += delta
		_blend = move_toward(_blend, 0.0, delta / 0.25)
		if _stop_elapsed > 0.25 and actual_speed < 0.02:
			state = Motion.STANDING


## Pivot a stepping turn around the stance, not the offset model root. Otherwise
## a narrow ramp can support every hoof yet the root's rotation sweeps them off its edge.
func _stance_turn_transform(yaw: float) -> Transform3D:
	var centre := Vector3.ZERO
	for leg in profile.legs: centre += Vector3(leg.neutral_sole)
	centre /= maxf(1.0, float(profile.legs.size()))
	centre = (_model_frame * centre) * body_scale
	var future := global_transform
	future.basis = Basis(Vector3.UP, yaw) * future.basis
	var shift := global_transform.basis * centre - future.basis * centre
	if is_on_floor():
		var normal := get_floor_normal()
		shift.y = -(normal.x * shift.x + normal.z * shift.z) / maxf(normal.y, 0.001)
	future.origin += shift
	return future

func _turn_support_safe(yaw: float, around_stance := false) -> bool:
	var future := _stance_turn_transform(yaw) if around_stance else global_transform
	if not around_stance: future.basis = Basis(Vector3.UP, yaw) * future.basis
	if around_stance and test_move(global_transform, future.origin - global_position): return false
	var normal := get_floor_normal() if is_on_floor() else Vector3.UP
	for leg in profile.legs:
		var point: Vector3 = future * ((_model_frame * Vector3(leg.neutral_sole)) * body_scale)
		var hit := _probe(point)
		# Neutral animation soles can be below the floor while the body settles or
		# tilts. Judge a step against the supporting plane, not that visual offset.
		var offset := point - global_position
		var floor_y := global_position.y - (normal.x * offset.x + normal.z * offset.z) / maxf(normal.y, 0.001)
		if hit.is_empty() or absf(float(hit.position.y) - floor_y) > profile.step_height \
			or Vector3(hit.normal).angle_to(Vector3.UP) > deg_to_rad(profile.max_slope_degrees):
			return false
	return true


func _probe(point: Vector3, rise := 0.0) -> Dictionary:
	if _native_probe and _native != null:
		# Same ray, mask, exclusion, seam retry and slope test, with one reused query object.
		return _native.probe(point, rise, profile.hip_height, floor_mask, profile.max_slope_degrees)
	var h: float = profile.hip_height
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * (h * 0.9 + rise),
		point - Vector3.UP * h * 1.5, floor_mask, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		# Jolt can miss a ray exactly on a shared triangle edge. Retry only
		# that miss, straddling it by 2 mm. Require the same continuous floor
		# on BOTH sides, so a ledge or a real gap cannot become support.
		var seam := Vector3(0.002, 0.0, 0.001)
		query.from += seam
		query.to += seam
		var first := get_world_3d().direct_space_state.intersect_ray(query)
		if first.is_empty():
			return {}
		query.from -= seam * 2.0
		query.to -= seam * 2.0
		var second := get_world_3d().direct_space_state.intersect_ray(query)
		if second.is_empty() or first.rid != second.rid \
				or absf(float(first.position.y) - float(second.position.y)) > 0.01:
			return {}
		if first.normal.dot(second.normal) < 0.99:
			return {}
		hit = first
		hit.position = (Vector3(first.position) + Vector3(second.position)) * 0.5
		hit.normal = (Vector3(first.normal) + Vector3(second.normal)).normalized()
	if hit.is_empty() or hit.normal.dot(Vector3.UP) < cos(deg_to_rad(profile.max_slope_degrees)):
		return {}
	return hit


## Direct player input keeps the physically achieved wall tangent, like the native follower.
## Legacy NPC steering retains its collision cooldown unless its body explicitly opts in.
func _preserve_wall_slide() -> bool:
	return false

## Only the player body supplies a step policy; NPC/native motor behavior stays unchanged.
func _move_player_step(_delta: float) -> bool:
	return false


func _safe_ahead(speed: float) -> bool:
	if speed < 0.01 or not _initialized:
		return true
	var forward := -global_basis.z.normalized()
	var lookahead := speed * speed / (2.0 * profile.braking) + profile.hip_height
	for fraction in [0.5, 1.0]:
		var point: Vector3 = global_position + forward * lookahead * fraction
		# Cast around the continued support plane. A level cast at stopping distance
		# starts inside a perfectly walkable uphill slope and used to report a gap.
		if is_on_floor():
			var normal := get_floor_normal()
			point.y -= normal.dot(forward) * lookahead * fraction / maxf(normal.y, .1)
		# Start the cast above the highest rise this check accepts: at the foot of a steep
		# stoop the pony still stands on flat ground, and a cast from hip height began
		# inside the ramp's collider, missed it and blocked her as if at a gap (2026-09-22).
		var rise: float = lookahead * fraction * tan(deg_to_rad(profile.max_slope_degrees))
		var hit := _probe(point, rise)
		if hit.is_empty() or absf(hit.position.y - global_position.y) > profile.hip_height * 0.2 + rise:
			return false
	return true


func _terrain_corner_speed() -> float:
	# A sharp slope break needs time to transfer support. Detect it across
	# the whole body and braking distance, before a hoof reaches the corner.
	var normals: Array[Vector3] = []
	var forward := -global_basis.z.normalized()
	var ahead := maxf(0.6, _command_speed * _command_speed / (2.0 * profile.braking) + 0.5)
	for distance in [-0.6, 0.0, ahead * 0.5, ahead]:
		var point: Vector3 = global_position + forward * distance
		if is_on_floor():
			var normal := get_floor_normal()
			point.y -= normal.dot(forward) * distance / maxf(normal.y, .1)
		var hit := _probe(point)
		if not hit.is_empty():
			normals.append(hit.normal)
	var bend := 0.0
	for first in normals:
		for second in normals:
			bend = maxf(bend, first.angle_to(second))
	var caution := smoothstep(deg_to_rad(8.0), deg_to_rad(28.0), bend)
	# The floor was 0.24 m/s: every house ramp and door sill slowed ponies (and the player's
	# pony) to a crawl (dev 2026-10-01: "just let ponies like go in"). The bottom of the trot
	# band keeps some care at a real bend without stopping anyone.
	return lerpf(profile.max_travel_speed, profile.trot_speed.x, caution)


func _update_contacts(delta: float) -> void:
	if _native != null and _native_contacts and not _held and hoof_hold.leg_index < 0 and feet.size() == 4:
		_update_contacts_native(delta)
		return
	var local_fk := _forward_kinematics(source_pose)
	var frame := global_transform * pivot.transform * _model_frame
	var adapted_fk := _forward_kinematics(source_pose, frame)
	for i in feet.size():
		var leg: Dictionary = profile.legs[i]
		var foot: Dictionary = feet[i]
		foot.age += delta
		var local_sole: Vector3 = profile.sole_point(leg, local_fk)
		foot.dynamic_sole = local_fk[leg.leaf].affine_inverse() * local_sole
		var source_sole: Vector3 = frame * local_sole
		if hoof_hold.owns(i):
			foot.planted=false;foot.valid=false;foot.weight=0.0;foot.target=source_sole
			foot.basis=adapted_fk[leg.leaf].basis.orthonormalized();foot.offset=Vector3.ZERO
			continue
		if _held:
			foot.planted = carry.supports[i]
			foot.valid = carry.supports[i]
			foot.lock = carry.anchors[i]
			foot.target = carry.anchors[i] if carry.supports[i] else source_sole
			foot.basis = carry.anchor_bases[i] if carry.supports[i] else adapted_fk[leg.leaf].basis.orthonormalized()
			foot.weight = 1.0 if carry.supports[i] else 0.0
			foot.limited = false
			foot.landing_predicted = false
			foot.offset = Vector3.ZERO
			continue
		var stride_amount: float = step_timing.stride_offset(i, actual_speed) * _blend
		var stride_offset := global_basis.z.normalized() * stride_amount
		var reference := frame * Vector3(local_sole.x, 0.0, local_sole.z) + stride_offset
		var current_reference := reference
		foot.turn_prediction = Vector3.ZERO
		var airborne := step_timing.leg_airborne(i)
		if airborne and maxf(actual_speed, _turn_step_speed) > 0.02:
			# The owning gait's clip still owns the swing. Probe where the body will be
			# when that swing ends, so the next planted contact already fits the turn.
			var touchdown_seconds := minf(0.45, step_timing.touchdown_seconds(i))
			var predicted_root := predict_turn_transform(global_transform, actual_speed,
				_yaw_rate, touchdown_seconds)
			var predicted_frame := predicted_root * pivot.transform * _model_frame
			reference = predicted_frame * Vector3(local_sole.x, 0.0, local_sole.z) \
				+ predicted_root.basis.z.normalized() * stride_amount
			foot.turn_prediction = reference - current_reference
		var previous_landing: Vector3 = foot.landing
		var previous_landing_normal: Vector3 = foot.landing_normal
		var previous_landing_valid: bool = foot.landing_valid and foot.landing_predicted
		var hit := _probe(reference)
		var weight: float = lerpf(1.0, step_timing.leg_contact_weight(i), _blend) if _blend > 0.0 else 1.0
		var desired_offset := Vector3.ZERO
		foot.limited = false
		foot.landing_valid = not hit.is_empty()
		foot.landing_predicted = false
		if not hit.is_empty():
			foot.landing = hit.position
			foot.landing_normal = hit.normal
			foot.landing_predicted = airborne
			foot.normal = hit.normal
			# Warp the floor underneath the selected gait's recovery. The gait
			# owns its leg curl; terrain correction only adapts its support.
			desired_offset = Vector3(hit.position) - reference
			var limit: float = profile.hip_height * 0.14 * body_scale
			foot.limited = desired_offset.length() > limit
			desired_offset = desired_offset.limit_length(limit)
			# Seat only the loaded portion of the footfall. Weight fades before
			# the original kick-off, allowing the entire distal chain to curl.
			desired_offset -= frame.basis.y.normalized() * maxf(local_sole.y, 0.0) * weight
		desired_offset += stride_offset
		var loaded := state == Motion.STANDING or (_blend > 0.999 and state != Motion.STOPPING and weight > 0.7)
		if loaded and not hit.is_empty():
			# At spawn on a slope, first establish the tilted support pose.
			# Otherwise a first-frame anchor can remain permanently out of reach.
			if state == Motion.STANDING and _spawn_settle > 0.0:
				foot.lock = hit.position
				foot.lock_normal = hit.normal
			if not foot.planted:
				# The last airborne probe is the forecast touchdown. Use it on the first
				# loaded frame; subsequent stance frames preserve the resulting lock.
				foot.lock = previous_landing if previous_landing_valid else hit.position
				foot.lock_normal = previous_landing_normal if previous_landing_valid else hit.normal
				foot.age = 0.0
				if state != Motion.STANDING:
					_hoof_plants.plant(i, hit.position)
			foot.planted = true
			foot.valid = true
			foot.landing_predicted = false
		else:
			foot.planted = false
			foot.valid = not hit.is_empty()
		foot.weight = weight
		if foot.planted and state != Motion.STANDING:
			var horizontal_lock := Vector3(foot.lock) - (source_sole + desired_offset)
			horizontal_lock.y = 0.0
			# A contact whose authored hoof has moved on by more than any stride
			# extension is stale (a gait blend re-timed the leg): release it so the
			# next loaded frame plants afresh instead of dragging toward an old lock.
			if horizontal_lock.length() > 0.3 * body_scale and step_timing.seconds_since_switch() < profile.gait_blend_seconds * 2.0:
				foot.planted = false
				foot.valid = not hit.is_empty()
				horizontal_lock = Vector3.ZERO
			desired_offset += horizontal_lock.limit_length(0.12 * body_scale)
			# Anchoring changes X/Z. On a hill its ground height changes too;
			# keeping the earlier sample placed an otherwise solved hoof inside
			# the slope. Re-sample the final contact, including its normal.
			var contact := _probe(source_sole + desired_offset)
			if not contact.is_empty():
				desired_offset.y = float(contact.position.y) - source_sole.y
				desired_offset.y += maxf(local_sole.y, 0.0) * (1.0 - weight) * frame.basis.y.y
				foot.normal = contact.normal
				foot.landing = contact.position
				hit = contact
		var contact_response := 0.02 if foot.planted else 0.045
		foot.offset = Vector3(foot.offset).lerp(desired_offset, 1.0 - exp(-delta / contact_response))
		if _held and not is_on_floor():
			foot.planted = false
			foot.valid = false
			foot.offset = Vector3(foot.offset).move_toward(Vector3.ZERO, delta * 0.25)
		foot.target = source_sole + Vector3(foot.offset)
		foot.basis = adapted_fk[leg.leaf].basis.orthonormalized()
		if foot.planted and state == Motion.STANDING:
			# Holding the actual contact also cancels the body's idle roll at
			# the hoof. Filtering a moving source would leave the sole skating.
			foot.target = foot.lock
			foot.offset = Vector3(foot.lock) - source_sole
			foot.normal = foot.lock_normal
			foot.basis = Basis(Quaternion(Vector3.UP, foot.normal)) * global_basis.orthonormalized() \
				* _model_frame.basis.orthonormalized() * Basis(leg.sole_basis)
		# The body already carries the mean slope. Only apply the residual
		# normal here, with a small angle budget during loaded contact.
		if not hit.is_empty() and not (foot.planted and state == Motion.STANDING):
			var up := frame.basis.y.normalized()
			var normal: Vector3 = hit.normal
			var angle := minf(up.angle_to(normal), deg_to_rad(12.0)) * weight
			var axis := up.cross(normal)
			if axis.length_squared() > 1e-10:
				foot.basis = Basis(axis.normalized(), angle) * Basis(foot.basis)


## _update_contacts() in PonySolverNative for a pony that is not held: the same foot state bit
## for bit. The terrain probes stay here; the native code runs the math between them.
## _update_contacts_native() reads its 20 timing values through one step_timing.contact_timing()
## call (0.1.0 perf pass; the same values bit for bit). Rollback: CONTACT_TIMING_BATCH = false.
const CONTACT_TIMING_BATCH := true
func _update_contacts_native(delta: float) -> void:
	if _native_contact_profile != profile:
		_native_contact_profile = profile
		var bones := PackedInt32Array()
		var heights := PackedFloat64Array()
		var bases: Array = []
		for leg in profile.legs:
			bones.append(int(leg.leaf)); bones.append(int(leg.end))
			heights.append(float(leg.end_height))
			bases.append(Basis(leg.sole_basis))
		_native.bind_contact_legs(bones, heights, bases)
	var predict := maxf(actual_speed, _turn_step_speed) > 0.02
	var timing := PackedFloat64Array()
	if CONTACT_TIMING_BATCH:
		timing = step_timing.contact_timing(_blend, predict)
	else:
		for i in 4:
			var airborne := step_timing.leg_airborne(i)
			timing.append(step_timing.stride_offset(i, actual_speed) * _blend)
			timing.append(1.0 if airborne else 0.0)
			timing.append(1.0 if airborne and predict else 0.0)
			timing.append(minf(0.45, step_timing.touchdown_seconds(i)) if airborne and predict else 0.0)
			timing.append(step_timing.leg_contact_weight(i) if _blend > 0.0 else 1.0)
	var prof := LOCO_CPU.enabled
	var lap := Time.get_ticks_usec() if prof else 0
	var references: PackedVector3Array = _native.contacts_begin(source_pose, feet, global_transform,
		pivot.transform, _model_frame, delta, timing, PackedFloat64Array([actual_speed, _yaw_rate]))
	if prof: lap = _cpu_lap("contacts_begin", lap)
	var hits: Array = [_probe(references[0]), _probe(references[1]), _probe(references[2]), _probe(references[3])]
	if prof: lap = _cpu_lap("contacts_probe4", lap)
	var planted: Array = _native.contacts_plant(feet, hits, PackedInt32Array([state, Motion.STANDING, Motion.STOPPING]),
		PackedFloat64Array([_blend, _spawn_settle, body_scale, profile.hip_height, step_timing.seconds_since_switch(),
			profile.gait_blend_seconds]))
	if prof: lap = _cpu_lap("contacts_plant", lap)
	if not (planted[2] as PackedVector3Array).is_empty():
		_hoof_plants.plant_native(self, planted[2])
	var points: PackedVector3Array = planted[0]
	var resample: PackedByteArray = planted[1]
	var contacts: Array = [{}, {}, {}, {}]
	for i in 4:
		if resample[i]:
			contacts[i] = _probe(points[i])
	_native.contacts_finish(feet, contacts, delta, PackedInt32Array([state, Motion.STANDING]), global_transform, _model_frame)
	if prof: _cpu_lap("contacts_resample_finish", lap)


## The rest of _update_body() in PonySolverNative: the same ten rays (through its probe, in
## the same order) and the same tilt, height and pivot.
func _update_body_native(delta: float) -> void:
	if _body_profile != profile:
		_body_profile = profile
		var soles := PackedVector3Array()
		for leg in profile.legs:
			soles.append(Vector3(leg.neutral_sole))
		_native.bind_body(soles)
	var result: Array = _native.update_body(global_transform, _body_tilt, _model_frame, _body_offset, secondary.offset,
		PackedFloat64Array([delta, _body_height, profile.hip_height, profile.max_slope_degrees, secondary.roll, floor_mask]))
	_body_tilt = result[1]
	_body_height = result[2]
	_slope_angle = result[3]
	_set_pivot_scaled(result[0])


## Forecast the root through a constant-rate turn. Mid-heading translation is the chord of
## the short anticipated arc; yaw is bounded by the caller's remaining swing time.
static func predict_turn_transform(current: Transform3D, speed: float,
		yaw_rate: float, seconds: float) -> Transform3D:
	var duration := clampf(seconds, 0.0, 0.45)
	var yaw := clampf(yaw_rate * duration, -deg_to_rad(50.0), deg_to_rad(50.0))
	var rotation := Basis(Vector3.UP, yaw)
	var forward := -current.basis.z.normalized()
	var midpoint_forward := Basis(Vector3.UP, yaw * 0.5) * forward
	return Transform3D(rotation * current.basis,
		current.origin + midpoint_forward * maxf(speed, 0.0) * duration)


func _update_body(delta: float) -> void:
	if _held:
		_body_height = move_toward(_body_height, 0.0, delta * 0.3)
		var rotation := carry.body_rotation()
		_body_tilt = _body_tilt.slerp(rotation, 1.0 - exp(-delta / 0.08))
		var center := carry.pivot_center
		var carried := Transform3D(Basis(_body_tilt), center - _body_tilt * center + _body_offset + Vector3.UP * _body_height)
		pivot.transform = carry.start_pivot.interpolate_with(carried, carry.blend)
		_apply_body_scale()
		if carry.cradle > 0.0: pivot.transform.basis = pivot.transform.basis.scaled_local(Vector3.ONE * carry.cradle_scale())
		return
	if not is_on_floor():
		_body_height = move_toward(_body_height, 0.0, delta * 0.3)
		_body_tilt = _body_tilt.slerp(Quaternion.IDENTITY, 1.0 - exp(-delta / 0.18))
		var center := carry.pivot_center
		_set_pivot_scaled(Transform3D(Basis(_body_tilt), center - _body_tilt * center + _body_offset + Vector3.UP * _body_height))
		return
	if _native_body and _native != null and _native_probe:
		_update_body_native(delta)
		return
	# Sample under the tilted footprint: pitching about the hips moves the
	# feet forward/backward substantially on a steep slope.
	var center := Vector3(0.0, profile.hip_height, 0.2927)
	var footprint := Transform3D(Basis(_body_tilt), center - _body_tilt * center)
	var points: Array[Vector3] = []
	for z in [-0.30, 0.05, 0.40]:
		for x in [-0.15, 0.15]:
			var local_point := footprint * Vector3(x, 0.0, z)
			var point := global_transform * local_point
			var hit := _probe(point)
			points.append(global_transform.affine_inverse() * Vector3(hit.position) if not hit.is_empty() else local_point)
	var longitudinal := (points[4] + points[5]) - (points[0] + points[1])
	var lateral := (points[1] + points[3] + points[5]) - (points[0] + points[2] + points[4])
	var dz := longitudinal.y / maxf(absf(longitudinal.z), 0.1)
	var dx := lateral.y / maxf(absf(lateral.x), 0.1)
	var local_normal := Vector3(-dx, 1.0, -dz).normalized()
	_slope_angle = Vector3.UP.angle_to(local_normal)
	var axis := Vector3.UP.cross(local_normal)
	var tilt_limit := deg_to_rad(minf(profile.max_slope_degrees, 40.0))
	var want_tilt := Quaternion.IDENTITY if axis.length_squared() < 1e-10 else Quaternion(axis.normalized(), minf(_slope_angle, tilt_limit))
	var weight := 1.0 - exp(-delta / 0.07)
	_body_tilt = _body_tilt.slerp(want_tilt, weight)
	var tilted := Transform3D(Basis(_body_tilt), center - _body_tilt * center)
	var height_sum := 0.0
	var count := 0
	for leg in profile.legs:
		var sole: Vector3 = global_transform * tilted * _model_frame * Vector3(leg.neutral_sole)
		var hit := _probe(sole)
		if not hit.is_empty():
			height_sum += float(hit.position.y) - sole.y
			count += 1
	var want_height := clampf(height_sum / maxi(count, 1), -profile.hip_height * 0.45, profile.hip_height * 0.45)
	_body_height = lerpf(_body_height, want_height, weight)
	var placed := tilted
	placed.origin.y += _body_height
	var give_rotation := Basis.from_euler(Vector3(_body_offset.z * 0.7, 0.0, -_body_offset.x * 0.8 + secondary.roll))
	var give := Transform3D(give_rotation, center - give_rotation * center + _body_offset + secondary.offset)
	_set_pivot_scaled(placed * give)


func _solve_pose(delta: float) -> void:
	corrected_pose = source_pose.duplicate()
	if not _initialized:
		return
	var frame := global_transform * pivot.transform * _model_frame
	var fk := _forward_kinematics(source_pose, frame)
	if is_instance_valid(_pose_batch) and _pose_batch.available and hoof_hold.leg_index<0:
		for foot in feet:
			foot.self_push = Vector3.ZERO
			foot.self_penetration = 0.0
		_pose_batch.enqueue(self, delta, frame, fk)
		return
	for i in feet.size():
		var foot: Dictionary = feet[i]
		foot.self_push = Vector3.ZERO
		foot.self_penetration = 0.0
		if (_held and not foot.valid) or hoof_hold.owns(i):
			continue
		_solve_leg(i, frame, fk, foot.target)
	if _held:
		# Carry poses hang the legs from their own anchors; those are not
		# contact targets, so this pass has nothing to push. Kept for later.
		self_collision.reset()
		return
	_resolve_self_collision(delta, frame, fk)


## Instead of _solve_pose() and _finish_joint_constraints() now: hand this tick's solve to the
## tree's PonySolveBatch, which runs every queued pony's at once and then calls _apply_solve().
## Only for a free pony (not held, no hoof held, not on the GPU pose batch); false keeps the
## inline solve. The inputs are read here, at the same point of the tick as the inline solve.
func _enqueue_solve(delta: float) -> bool:
	if not is_instance_valid(_solve_batch) or not _solve_batch.is_inside_tree() or not _initialized or _held \
			or hoof_hold.leg_index >= 0 or self_collision.native == null or feet.size() != 4 \
			or (is_instance_valid(_pose_batch) and _pose_batch.available):
		return false
	if _solve_profile != profile:
		_solve_profile = profile
		var bones := PackedInt32Array()
		var poles := PackedVector3Array()
		var flex := PackedFloat64Array()
		for leg in profile.legs:
			bones.append_array([leg.root, leg.proximal, leg.middle, leg.leaf])
			poles.append(Vector3(leg.pole))
			flex.append(float(leg.get("max_flex_degrees", 180.0)))
		_native.bind_pose_legs(bones, poles, flex, PackedFloat64Array([profile.hip_height * 0.0001, deg_to_rad(22.0)]),
			SELF_COLLISION.BELLY_FROM, SELF_COLLISION.BELLY_TO)
	var frame := global_transform * pivot.transform * _model_frame
	_native.solve_gather(source_pose, feet, _leg_poles, self_collision.pushes, frame, -global_basis.z.normalized(), delta,
		PackedFloat64Array([self_collision.hoof_radius, self_collision.segment_radius, self_collision.belly_radius,
			SELF_COLLISION.HOOF_LIFT]))
	_solve_use_correction = corrections_enabled or _held or carry.blend > 0.0
	_solve_batch.enqueue(self)
	return true


## PonySolveBatch: this tick's solve result, as _solve_pose() and _finish_joint_constraints()
## would have left it, then the end of the physics tick.
func _apply_solve() -> void:
	var result: Array = _native.solve_scatter(source_pose, feet, _leg_poles, self_collision.pushes)
	corrected_pose = result[0]
	self_collision.apply_native(result[1], result[2], result[3])
	_joint_limit_correction = joint_limits.apply_angles(result[4])
	modifier.prepared = corrected_pose if _solve_use_correction else source_pose.duplicate()
	if not _solve_use_correction:
		pivot.transform = Transform3D.IDENTITY
		_apply_body_scale()


func _forward_kinematics(pose: Array[Transform3D], frame := Transform3D.IDENTITY) -> Array[Transform3D]:
	if _native != null: return _native.forward_kinematics(pose, frame)
	return SOLVER.forward_kinematics(profile.parents, pose, frame)


func _complete_gpu_pose(delta: float, frame: Transform3D, fk: Array[Transform3D]) -> void:
	_gpu_pose_pending = false
	if posture != null and posture.active(): return
	if _held:
		self_collision.reset()
	else:
		_resolve_self_collision(delta, frame, fk)
	_finish_joint_constraints()
	var use_correction := corrections_enabled or _held or carry.blend > 0.0
	modifier.prepared = corrected_pose if use_correction else source_pose.duplicate()


func _solve_leg(i: int, frame: Transform3D, fk: Array[Transform3D], target: Vector3) -> void:
	# One shallow copy per leg, refreshed if the profile rebuilt its leg tables.
	if _leg_cache.size() != profile.legs.size():
		_leg_cache.clear()
		for source_leg in profile.legs:
			var cached: Dictionary = source_leg.duplicate()
			cached.native_bones = PackedInt32Array([cached.root, cached.proximal, cached.middle, cached.leaf])
			_leg_cache.append(cached)
	var leg: Dictionary = _leg_cache[i]
	var foot: Dictionary = feet[i]
	leg.sole = foot.dynamic_sole
	var line: Vector3 = (fk[leg.leaf].origin - fk[leg.root].origin).normalized()
	var pole: Vector3 = fk[leg.middle].origin - fk[leg.root].origin
	pole -= line * pole.dot(line)
	# Remembered in the body frame, so a turn does not replay a stale world direction.
	if pole.length_squared() < 0.0004:
		pole = frame.basis * (_leg_poles[i] if _leg_poles[i].length_squared() > 0.0 else Vector3(leg.pole))
	else:
		_leg_poles[i] = frame.basis.inverse() * pole
	if _native != null:
		# Same steps as below (solve, 22-degree budget, constrained refinement), in C++.
		var result: Array = _native.solve_leg(corrected_pose, source_pose, frame, leg.native_bones, Vector3(leg.sole),
			float(leg.get("max_flex_degrees", 180.0)), target, foot.basis, pole, profile.hip_height * 0.0001, deg_to_rad(22.0))
		if result[1]: foot.limited = true
		foot.correction_angle = result[0]
		return
	SOLVER.solve(profile.parents, corrected_pose, frame, leg,
		target, foot.basis, pole, profile.hip_height * 0.0001)
	var maximum := 0.0
	for bone in [leg.root, leg.middle, leg.leaf]:
		var before: Quaternion = source_pose[bone].basis.orthonormalized().get_rotation_quaternion()
		var after: Quaternion = corrected_pose[bone].basis.orthonormalized().get_rotation_quaternion()
		maximum = maxf(maximum, before.angle_to(after))
	# A contact target never earns permission to crush the leg. Preserve
	# the imported pose and expose the unsatisfied target in diagnostics.
	var budget := deg_to_rad(22.0)
	if maximum > budget:
		var blend := budget / maximum
		for bone in [leg.root, leg.middle, leg.leaf]:
			corrected_pose[bone] = source_pose[bone].interpolate_with(corrected_pose[bone], blend)
		foot.limited = true
	foot.correction_angle = minf(maximum, budget)
	SOLVER.refine_constrained(profile.parents, corrected_pose, source_pose, frame,
		leg, target, foot.basis, joint_limits, budget)
	for bone in [leg.root, leg.proximal, leg.middle, leg.leaf]:
		var before: Quaternion = source_pose[bone].basis.orthonormalized().get_rotation_quaternion()
		var after: Quaternion = corrected_pose[bone].basis.orthonormalized().get_rotation_quaternion()
		foot.correction_angle = maxf(foot.correction_angle, before.angle_to(after))


func _resolve_self_collision(delta: float, frame: Transform3D, fk: Array[Transform3D]) -> void:
	# Measure on the pose solved for contact alone, so a push is always the
	# full overlap rather than a residual, and vanishes as soon as the legs
	# clear each other. Pushed legs are then solved once more from the
	# authored pose, so the 22° budget still counts from the source.
	var forward := -global_basis.z.normalized()
	var solved := _forward_kinematics(corrected_pose, frame)
	var wanted := self_collision.measure(profile, solved, feet, frame, forward)
	if not self_collision.integrate(wanted, feet, delta):
		return
	for i in feet.size():
		var push: Vector3 = self_collision.pushes[i]
		if push == Vector3.ZERO or hoof_hold.owns(i):
			continue
		var leg: Dictionary = profile.legs[i]
		for bone in [leg.root, leg.proximal, leg.middle, leg.leaf]:
			corrected_pose[bone] = source_pose[bone]
		feet[i].self_push = push
		_solve_leg(i, frame, fk, Vector3(feet[i].target) + push)
	# Residual overlap after the leg did what its joints allow. Diagnostics only.
	solved = _forward_kinematics(corrected_pose, frame)
	self_collision.measure(profile, solved, feet, frame, forward)
	for i in feet.size():
		feet[i].self_penetration = self_collision.penetration[i]


func _finish_joint_constraints() -> void:
	if _gpu_pose_pending: return
	hoof_hold.solve(corrected_pose)
	_joint_limit_correction = joint_limits.apply(corrected_pose)
	var frame := global_transform * pivot.transform * _model_frame
	if carry.blend > 0.0: carry.dangle_forelegs(corrected_pose, frame, get_physics_process_delta_time() * maxi(hero_divisor, 1))
	if not _held:
		return
	var fk := _forward_kinematics(corrected_pose, frame)
	for i in 4:
		if not carry.supports[i]:
			continue
		var sole: Vector3 = fk[profile.legs[i].leaf] * Vector3(feet[i].dynamic_sole)
		# Contact is subordinate to finite reach and anatomical joint limits.
		# Release the anchor instead of lengthening or reversing a joint.
		if sole.distance_to(carry.anchors[i]) > 0.025:
			carry.release_support(i, corrected_pose)
			feet[i].planted = false
			feet[i].valid = false
			feet[i].target = sole


func _measure_visible_soles() -> void:
	if not is_inside_tree() or not skeleton.is_inside_tree():
		return
	for i in feet.size():
		var leg: Dictionary = profile.legs[i]
		feet[i].sole = skeleton.global_transform * skeleton.get_bone_global_pose(leg.leaf) * Vector3(feet[i].dynamic_sole)
		feet[i].error = Vector3(feet[i].sole).distance_to(feet[i].target)


func get_debug_snapshot() -> Dictionary:
	var grip_error := 0.0
	if _held:
		grip_error = _hold_target.distance_to(get_grip_transform(carry.grip_name).origin)
		for grip: String in _hand_targets:
			grip_error = maxf(grip_error, Vector3(_hand_targets[grip]).distance_to(get_grip_transform(grip).origin))
	return {"tick": _tick, "state": Motion.keys()[state], "phase": phase,
		"speed": actual_speed, "stride_scale": _stride_scale, "body_height": _body_height,
		"leg_phases": Array(step_timing.phases),
		"walking": step_timing.walking, "gait": step_timing.gait, "gallop_blend": step_timing.gallop_blend,
		"gallop_phase": step_timing.gallop_phase, "playback": step_timing.playback,
		"body_tilt": _body_tilt.get_angle(), "blocked": _blocked,
		"body_offset": _body_offset, "body_offset_velocity": _body_offset_velocity,
		"sway_offset": secondary.offset, "sway_roll": secondary.roll, "head_sway": secondary.head_angles,
		"gaze_angles": secondary.gaze_angles, "gaze_velocity": secondary.gaze_velocity,
		"interaction": _interaction, "held": _held, "collision_cooldown": _collision_cooldown,
		"carry_pitch": carry.pitch, "hind_supports": carry.supports.duplicate(),
		"grip_error": grip_error, "hand_count": _hand_targets.size(),
		"joint_limit_correction": _joint_limit_correction,
		"self_collision": self_collision.max_penetration, "self_pushes": self_collision.pushes.duplicate(),
		"grounded": is_on_floor(), "floor_normal": get_floor_normal(), "command_speed": _command_speed,
		"position": global_position, "feet": feet.duplicate(true)}


static func _smooth(value: float) -> float:
	return value * value * value * (value * (value * 6.0 - 15.0) + 10.0)


static func _find_class(node: Node, type: String) -> Node:
	if node.is_class(type):
		return node
	for child in node.get_children():
		var found := _find_class(child, type)
		if found != null:
			return found
	return null


func request_posture(kind: String) -> bool:
	if posture == null:
		if kind == "stand": return true
		posture=preload("res://world/characters/locomotion/pony_posture.gd").new()
		posture.bind(self)
		posture.clip_output = sim_tier != SimTier.HERO
	return posture.request(kind)

func posture_status() -> Dictionary:
	if posture == null: return {"kind":"stand","requested":"stand","settled":true,"refusal":""}
	return {"kind":posture.kind if posture.progress>0.0 else "stand","requested":posture.requested,"settled":posture.settled(),"refusal":posture.refusal}
