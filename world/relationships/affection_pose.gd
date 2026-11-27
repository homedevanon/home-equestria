extends SkeletonModifier3D
## Small bounded neck lean for hugs, the kiss, and a supported rear-leg kick, layered after
## locomotion.
## The kiss (round 11, dev 2026-09-28: "her mouth WRAPPED around mine ... i want to see the bridge
## of her nose and her face not her mouth", "she needs a turn radius limited skeleton", "when i
## move my head around there's no lag"): her lips press onto his, her muzzle tipped up so her nose
## passes his and her lips sit below and behind her own muzzle, out of his sight. Her head chases
## that pose instead of snapping to it: her lip goal follows a critically damped spring with a top
## speed and her head angle a spring with a top turn rate. Her neck carries the head inside the
## rig's joint limits (pony_joint_limits.gd) and only a short way; beyond that her body turns and
## steps (pony_affection.gd reads neck_demand). Her skull and nose always stay clear of his eyes,
## at once, whatever the lag. While she kisses, her head wanders (turn, nod, tilt, pressing in and
## easing off, lips sliding) and in a deep kiss she changes the side she leans to now and then.
## Values come from the kiss pose lab (tools/affection/kiss_pose_lab.tscn, KISS_FILE).
var mare: Node3D
var target := Vector3.ZERO
var mouth_in_head := Vector3.ZERO
var amount := 0.0
var buck_amount := 0.0
## Idle fidgets (pony_affection.gd fidget): one hind leg stretched back, toe pointed; a yawn's
## raised head. Small additive turns, well inside the buck's range.
var stretch_amount := 0.0
var stretch_left := true
var yawn_amount := 0.0
## Most the mouth may move toward the target, metres, outside a kiss.
const REACH := .02
var reach := REACH
## Kissing: Anon's eye and face basis (world; -z is where he looks). His lips are `target`.
var kissing := false
## A deep (held) kiss: full wandering motion, side changes, her hooves up if enabled.
var deep := false
## 0..1 while she draws back to gaze at him between kisses (pony_affection.gd _breather).
var pause := 0.0
var eye := Vector3.INF
var face := Basis.IDENTITY
var skull_in_head := Vector3.ZERO
var nose_in_head := Vector3.ZERO
var skull_radius := .085
var face_in_head := PackedVector3Array()
## Unused since the kiss IK above; kept for callers that still set it.
var press := 0.0
var neck: Array[int] = []
## Chest bones a kiss leans with, lightly, when her neck alone cannot reach him.
var chest: Array[int] = []
var head := -1
## World mouth/skull/nose points from the visible head, captured by begin(). Outside
## skeleton_updated the body skeleton reports its unmodified pose, so the head-local offsets are
## bound here, against the pose the modifiers actually built (a frame with no IK applied).
var bind_mouth := Vector3.INF
var bind_skull := Vector3.INF
var bind_nose := Vector3.INF
var _applied := 0.0
var _face_bound := false
## Her head's own forward and up, head-local, from the bound pose.
var _head_forward := Vector3.FORWARD
var _head_up := Vector3.UP
var _motion := 0.0
var _sway: Dictionary = {}
var _rng := RandomNumberGenerator.new()
## Physics frame whose pass the native body batch took over (rig_batch.gd); this script's pass
## returns at once in that frame. 0: never.
var rig_batch_step := 0
## Foreleg bones per side: upperArm, lowerArm, carpus (wrist), hoof tip.
var _legs: Array[Dictionary] = []
## A supported rear raises the torso about the hips; it never translates her body toward his
## chest. She finishes the approach and plants the hind feet before rising.
const MAX_REAR := deg_to_rad(65.0)
var embrace := {}
var _rear_now := 0.0
var _rear_speed := 0.0
var rear_step_ahead := 0.0
var rear_wanted := false
var _rear_plants: Array[Vector3] = []
var _hoof_goals: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _hips := -1
var _hind: Array[Dictionary] = []

## Kneeling (dev 2026-11-25): his mouth is lower than her neck reaches (he crouches, sits or
## lies down). Her body tips chest-down about her hind hips and sinks, her hind hooves stay
## where they stood, and her forelegs fold under her until she rests on her knees. 0: standing,
## 1: as low as she goes. The opposite of the supported rear, and never together with it.
## Rotations only, every joint inside its limit (_turn); nothing stretches.
const KNEEL_PITCH := deg_to_rad(17.0)
## Metres her whole body sinks at a full kneel (times her size); her forelegs' own folded
## height stops it sooner.
const KNEEL_SINK := .15
## How far below her resting lips his mouth may be before her body joins her neck (metres).
const KNEEL_NECK := .04
## Her knee joint's centre stays this far above the ground (the skin round it), metres.
const KNEEL_KNEE := .03
## The fold her foreleg ends in: forearm a little behind upright, cannon folded back under it.
const KNEEL_FOREARM := deg_to_rad(-5.0)
## Share of her knee's own bending range the full fold uses.
const KNEEL_FOLD_SHARE := .97
## On the way down her forearm swings this far forward (from straight down) while her knee
## folds, which keeps her hoof under her elbow; this share of the fold is that first part.
const KNEEL_KNEE_FORWARD := deg_to_rad(66.0)
const KNEEL_FIRST := .4
## Share of her pastern's own bending range that tucks her hoof at the end.
const KNEEL_PASTERN_SHARE := .6
var _kneel_now := 0.0
var _kneel_speed := 0.0
var _kneel_plants: Array[Vector3] = []
## Set by pony_affection.gd while she has to turn or step: she rises first.
var kneel_block := false
## True while his mouth is low enough that she kneels or is about to.
var kneel_wanted := false
## Test probes set this; the kneel then leaves its measurements in kneel_report.
var kneel_trace := false
var kneel_report := {}

## The kiss chain, root to tip, and the bones that carry her head toward his lips (tip first).
var _chain: Array[int] = []
var _carriers: Array[int] = []
var _neck1 := -1
var _neck2 := -1
## Her animated (pre-kiss) local rotations this pass, by bone.
var _anim: Dictionary = {}
## Grounded kisses reserve chest flex so her body steps instead. A held kiss uses the existing
## spine joint ranges, including the low spine only when the mouth needs substantial lowering.
## No joint range is changed. On the ground she bows a little at the withers
## to bring her head down under his mouth (always inside the spine's joint limits).
const CHEST_MAX := deg_to_rad(12.0)
## Bridal carried (pony_carry.gd cradle), her body stays in his arms: her chest curls up only this
## far to help her neck reach him.
const CRADLE_CHEST_MAX := deg_to_rad(25.0)
## Share of the remaining head turn each bone takes, neck1 -> neck2 -> head: the turn spreads
## along the neck (about 20/30/50 %) instead of all at the skull.
const SPREAD: Array[float] = [.2, .375, 1.0]
## Half his interpupillary distance: the kiss keeps her face clear of both of his eyes.
const EYE_HALF := .032
## How far her neck lowers her head, and how far her head tips up from its idle angle, while
## kissing (world metres and degrees, inside the joint limits with room left for following).
## A lower mouth or a steeper look down from him gets less chin-up. Leaning or turning further
## instead (the offline search's nose-passing fallback) ran her neck out of joint range; his own
## nose is never drawn in the headset, so she keeps her posed lean.
const HEAD_DROP := .10
const CHIN_MAX := 45.0
## Neck forward: the most her muzzle tips up or down (radians) to keep her lips at his mouth's
## height while her neck leans.
const LEAN_TIP_UP := deg_to_rad(28.0)
const LEAN_TIP_DOWN := deg_to_rad(8.0)
## The most her whole neck leans forward, and back, from its rest (radians, shared by neck1 and
## neck2; each bone's own joint limit still applies). Her head joint has to take the lean back
## out to keep her head level, plus the chin-up, inside its own 30°: a neck that leans further
## than this leaves her head no room and her muzzle drops.
## How fast her neck lean and the tip of her muzzle may change (radians a second).
const LEAN_RATE := deg_to_rad(70.0)
var _neck_lean := 0.0
var _neck_tip := 0.0
const LEAN_MAX := deg_to_rad(22.0)
const LEAN_BACK := deg_to_rad(10.0)
## How far (metres) her neck draws her head back toward her chest when he leans in.
const BACK_GIVE := .03
## Follow state (world). Where her lips are heading, how fast, her head angle and its spin.
var _goal := Vector3.INF
## Where her lips should be this frame (world); the kneel keeps _goal near it.
var _want := Vector3.INF
var _goal_speed := Vector3.ZERO
var _aim := Quaternion.IDENTITY
var _spin := Vector3.ZERO
var _last_eye := Vector3.INF
var _last_face := Basis.IDENTITY
## After a kiss ends, her head eases back from the last kiss pose until `amount` reaches 0.
var _fading := false
## Which side she leans to (tilt sign): chosen per kiss, changed now and then in a deep kiss.
var _side := 1.0
var _side_now := 1.0
var _side_wait := 0.0
## For pony_affection.gd's body motion: how far (world metres) her lips would have to travel from
## where her head naturally sits, turned to the kiss angle, and the root of her neck (world).
var neck_demand := Vector3.ZERO
var neck_base := Vector3.INF
## Where her lips would sit with her head turned to the kiss angle and her neck as animated (world);
## INF outside a kiss. neutral_lips + neck_demand is where her lips are heading.
var neutral_lips := Vector3.INF
## Diagnostics for the lab and tests: radians of head angle her joint limits held back, and metres
## her lips miss their (reach-limited) goal.
var limited := 0.0
var miss := 0.0
var _reach_error := Vector3.ZERO
## Which clearance last pushed her back from his eyes ("skull", "nose", "mane" or "").
var cleared_by := ""
## The head angle she was last asked for (world), before following and limits.
var posed_aim := Quaternion.IDENTITY
## Her mane in front of her face (pony_head space), sampled once per mare (sample_hair): a
## forelock can hang further forward than her nose, and must not brush his eyes either.
var hair_in_head := PackedVector3Array()
var _hair_sampled := false

const KISS_FILE := "res://world/relationships/kiss_pose.json"
## turn/nod/tilt: degrees about Anon's up, right and line of sight (nod < 0 tips her muzzle up;
## tilt > 0 rolls her head toward his left). lips: where her upper lip lands from his mouth,
## metres along his right, up and toward her (negative presses in); the side value follows the
## side she leans to. hold: 0 leaves her head angle to the animation, 1 holds the posed angles.
## reach: how far forward (metres) her neck carries her lips beyond where the head turn alone
## puts them; her body steps for the rest. Sideways and up her neck reaches as far as its joint
## limits allow (a body turn cannot move her lips sideways: her head sits over her turning axis). eye_clear/nose_clear/mane_clear: metres her
## skull surface, nose and forelock keep from each of his eyes.
## Round 11 defaults (captures/kiss_probes offline search and rigid renders): muzzle 45° up from
## his line of sight, a 15° lean, her mouth 1 cm toward the lean. From his eyes she shows her
## nose bridge, eyes and forehead; her lips sit under her muzzle, out of view.
## pursuit_time: seconds her lips take to settle on a moved target (critically damped);
## pursuit_speed: fastest her lips travel, m/s; turn_rate: fastest her head turns, degrees/s.
## step_after: metres her lips would have to reach forward before she steps closer (0 = never);
## body_turn: degrees his eyes may be off her line before she turns her body to him (0 = never).
## sway_*: how far her kissing head wanders (degrees; sway_reach/sway_side metres in and out and
## sideways), sway_speed how quickly. side_switch: seconds between changes of lean side in a deep
## kiss (0 = always the posed side). rear enables a supported rise when the neck needs lift;
## rear_time sets its rise time and rear_neck reserves a little neck lift before rising.
## hooves enables shoulder/chest support during that rise; it never moves her chest toward his.
## hoof_width/hoof_drop place his shoulders relative to the eye, in metres.
## Neck forward (dev 2026-11-22: "her head goes down and then UP like she's pushing her neck down
## and then tilting her head up instead of leaning her horse neck forwards"): the 45° chin-up put
## her head joint 15 cm under his mouth and folded her neck back to tip her muzzle up. Now her
## muzzle points at his mouth along his line of sight with a small chin-up (nod), she stops
## walking in sooner (step_after, step_done: metres of forward reach at which she starts and
## stops stepping) and her neck leans forward from its base for the rest (reach). neck_forward 1:
## her chest bows only when her neck alone cannot bring her lips to his (a low mouth); 0: the
## chest joins every pass, as before. KISS_POSTURE_BEFORE holds the earlier values.
const KISS_DEFAULTS := {"turn": 0.0, "nod": -12.0, "tilt": 15.0, "hold": 1.0, "lips": [-0.01, 0.0, 0.0],
	"reach": .18, "eye_clear": .03, "nose_clear": .045, "mane_clear": .02,
	"pursuit_time": .28, "pursuit_speed": .5, "turn_rate": 110.0, "step_after": .09, "step_done": .065, "body_turn": 20.0,
	"neck_forward": 1.0,
	"sway_turn": 7.0, "sway_nod": 5.0, "sway_tilt": 6.0, "sway_reach": .006, "sway_side": .008, "sway_speed": 1.0,
	"side_switch": 8.0,
	"rear": 1.0, "rear_time": 1.0, "rear_neck": .015, "hooves": 1.0, "hoof_width": .13, "hoof_drop": .19}

## Where her carpi rest on Anon's shoulders (world): his torso stays upright under his head.
static func shoulder_points(eye_world: Vector3, face_world: Basis, settings: Dictionary) -> Array[Vector3]:
	var forward := -face_world.z; forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > .0001 else Vector3.FORWARD
	var right := forward.cross(Vector3.UP).normalized()
	var neck := eye_world + Vector3.DOWN * float(settings.hoof_drop) - forward * .06
	var points: Array[Vector3] = [neck - right * float(settings.hoof_width), neck + right * float(settings.hoof_width)]
	return points
static var kiss_pose: Dictionary = {}
## The kiss posture before the neck-forward change, for comparison and rollback: these values in
## kiss_pose.json, or posture_before(true) for this run.
const KISS_POSTURE_BEFORE := {"nod": -45.0, "reach": .10, "step_after": .06, "step_done": .025, "neck_forward": 0.0}

static func posture_before(on: bool) -> void:
	var settings := kiss_settings()
	for key: String in KISS_POSTURE_BEFORE: settings[key] = (KISS_POSTURE_BEFORE if on else KISS_DEFAULTS)[key]

static func kiss_settings() -> Dictionary:
	if kiss_pose.is_empty(): load_kiss_pose()
	return kiss_pose

static func load_kiss_pose() -> void:
	kiss_pose = KISS_DEFAULTS.duplicate(true)
	if not FileAccess.file_exists(KISS_FILE): return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(KISS_FILE))
	if not parsed is Dictionary: return
	for key: String in KISS_DEFAULTS:
		var value: Variant = (parsed as Dictionary).get(key)
		if key == "lips":
			if value is Array and (value as Array).size() == 3: kiss_pose.lips = [float(value[0]), float(value[1]), float(value[2])]
		elif value is float or value is int: kiss_pose[key] = float(value)

static func save_kiss_pose() -> bool:
	var file := FileAccess.open(KISS_FILE, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(kiss_settings(), "\t") + "\n")
	return true

func _ready() -> void:
	var sk := get_skeleton()
	head=sk.find_bone("pony_head")
	for name: String in ["pony_head","pony_neck2","pony_neck1"]:
		var bone := sk.find_bone(name)
		if bone>=0:neck.append(bone)
	for name: String in ["pony_spine3","pony_spine2"]:
		var bone := sk.find_bone(name)
		if bone>=0:chest.append(bone)
	_neck1 = sk.find_bone("pony_neck1")
	_neck2 = sk.find_bone("pony_neck2")
	for name: String in ["pony_spine1","pony_spine2","pony_spine3","pony_neck1","pony_neck2","pony_head"]:
		var bone := sk.find_bone(name)
		if bone>=0: _chain.append(bone)
	for name: String in ["pony_neck2","pony_neck1","pony_spine3","pony_spine2"]:
		var bone := sk.find_bone(name)
		if bone>=0: _carriers.append(bone)
	for side: String in ["L","R"]:
		var leg := {"upper": sk.find_bone("pony_upperArm_"+side), "lower": sk.find_bone("pony_lowerArm_"+side),
			"carpus": sk.find_bone("pony_wrist_"+side), "tip": sk.find_bone("pony_finger_%s_end"%side)}
		if leg.carpus<0: leg.carpus = sk.find_bone("pony_hand_"+side)
		if leg.upper>=0 and leg.lower>=0 and leg.carpus>=0 and leg.tip>=0: _legs.append(leg)
	_hips = sk.find_bone("pony_hips")
	for side: String in ["L","R"]:
		var hind := {"upper": sk.find_bone("pony_femur_"+side), "lower": sk.find_bone("pony_legLower_"+side),
			"end": sk.find_bone("pony_tarsal_"+side), "tip": sk.find_bone("pony_hoof_%s_end"%side),
			"plant": Vector3.INF, "from": Vector3.INF, "to": Vector3.INF, "step": -1.0, "cannon": Vector3.ZERO}
		if hind.upper>=0 and hind.lower>=0 and hind.end>=0 and hind.tip>=0: _hind.append(hind)
	# From the global generator: random in game, repeatable in a test that calls seed().
	_rng.seed = randi()

## A new contact (pony_affection.begin): a kiss follows him; a hug leans. A kiss begun while the
## last one still eases out carries on from where her head is.
func begin_contact(kiss: bool) -> void:
	kissing = kiss
	if not kiss: _fading = false

## True while her face may be right against his: a kiss, or its release easing out.
func kiss_face() -> bool:
	return amount > .001 and (kissing or _fading)

func _process_modification_with_delta(_delta: float) -> void:
	if rig_batch_step > 0 and rig_batch_step == Engine.get_physics_frames() and Engine.is_in_physics_frame(): return
	if not is_instance_valid(mare):return
	var sk := get_skeleton()
	if head>=0 and _applied<=.001 and bind_mouth.is_finite():
		var head_world := sk.global_transform*sk.get_bone_global_pose(head)
		var to_head := head_world.affine_inverse()
		mouth_in_head = to_head*bind_mouth
		if bind_skull.is_finite(): skull_in_head = to_head*bind_skull
		if bind_nose.is_finite(): nose_in_head = to_head*bind_nose
		_rest_axes(sk)
		bind_mouth = Vector3.INF; bind_skull = Vector3.INF; bind_nose = Vector3.INF
		_face_bound = false
	_applied = 0.0
	# Face offsets are consumed by leans/kisses and a rear's landing, not idle fidgets.
	# Keep the initial binding available and refresh every active/fading pose pass.
	if not _face_bound or amount>.001 or _rear_now>0.0 or _kneel_now>0.0: _face_points()
	var kiss_now := amount>.001 and head>=0 and target.is_finite() and kissing and eye.is_finite()
	if not kiss_now:
		_motion = move_toward(_motion, 0.0, _delta)
		neck_demand = Vector3.ZERO; neutral_lips = Vector3.INF
		for leg in _hind: leg.plant = Vector3.INF; leg.step = -1.0
	if amount>.001 and head>=0 and target.is_finite():
		_applied = amount
		if _cradled():
			# Bridal carried, pony_carry.gd's kiss reach poses her head, neck and chest instead: this
			# pose would straighten her head to him and fold her pinned forelegs up into her face.
			_fading = false; _goal = Vector3.INF
		elif kiss_now:
			_fading = true
			_kiss(sk, _delta, true)
		elif _fading and _goal.is_finite() and _last_eye.is_finite(): _kiss(sk, _delta, false)
		else: _lean(sk)
	elif amount<=.001:
		_fading = false; _goal = Vector3.INF
		if _rear_now>.0:_rear_pose(sk,_delta,false,1.0,kiss_settings())
		if _kneel_now>.0:_kneel_pose(sk,_delta,false,kiss_settings())
	if buck_amount>.001:
		var axis := (sk.global_basis.inverse()*mare.global_basis.x).normalized()
		for name: String in ["pony_flank_L","pony_flank_R"]:
			_rotate(sk,name,axis,deg_to_rad(-55)*buck_amount)
		for name: String in ["pony_legLower_L","pony_legLower_R"]:
			_rotate(sk,name,axis,deg_to_rad(25)*buck_amount)
	if stretch_amount>.001 or yawn_amount>.001:
		var axis := (sk.global_basis.inverse()*mare.global_basis.x).normalized()
		if stretch_amount>.001:
			var side := "L" if stretch_left else "R"
			_rotate(sk,"pony_flank_"+side,axis,deg_to_rad(-24)*stretch_amount)
			_rotate(sk,"pony_legLower_"+side,axis,deg_to_rad(10)*stretch_amount)
			_rotate(sk,"pony_tarsal_"+side,axis,deg_to_rad(-18)*stretch_amount)
		if yawn_amount>.001:
			_rotate(sk,"pony_neck1",axis,deg_to_rad(10)*yawn_amount)
			_rotate(sk,"pony_head",axis,deg_to_rad(22)*yawn_amount)

## Her head's own forward and up (head-local), from the rig's rest pose: the kiss poses her head
## by these, never by whatever angle her animated head happened to have when the kiss began.
func _rest_axes(sk: Skeleton3D) -> void:
	var rest := sk.get_bone_global_rest(head).basis.orthonormalized()
	var model := sk.global_basis.orthonormalized().inverse()
	_head_forward = (rest.inverse()*(model*-mare.pivot.global_basis.z)).normalized()
	_head_up = (rest.inverse()*(model*mare.pivot.global_basis.y)).normalized()

## Her lips, nose and skull centre in pony_head space, exact at any moment: the neck link places
## the OpenPony mHead at pony_head * offset, and the OpenPony skeleton holds the face on mHead. A
## begin() during the last kiss's fade could otherwise bind them against a mismatched pose.
func _face_points() -> void:
	var link: Variant = mare.get("neck_link")
	var boop: Variant = mare.get("boop_node")
	if link == null or boop == null or not (link as Object).get("_linked") or (link as Object).get("_offsets").size() < 3: return
	var hs: Skeleton3D = boop.head_skeleton
	var m_head := hs.find_bone("mHead")
	var lips := hs.find_bone("mFaceLipUpperCenter")
	var nose := hs.find_bone("mFaceNoseCenter")
	if m_head<0 or lips<0 or nose<0: return
	var offset: Transform3D = (link as Object).get("_offsets")[2]
	var to_face := offset*hs.get_bone_global_pose(m_head).affine_inverse()
	mouth_in_head = to_face*hs.get_bone_global_pose(lips).origin
	nose_in_head = to_face*hs.get_bone_global_pose(nose).origin
	skull_in_head = offset*Vector3(boop.SKULL_LOCAL)
	_face_bound = true

## A hug or boop lean: the mouth moves at most `reach` toward the target.
func _lean(sk: Skeleton3D) -> void:
	var scale:=maxf(sk.global_basis.get_scale().x,.01)
	var weight := smoothstep(0.0, 1.0, amount)
	var mouth := sk.get_bone_global_pose(head)*mouth_in_head
	var goal := sk.global_transform.affine_inverse()*target
	goal=mouth+(goal-mouth).limit_length(reach/scale)*weight
	_ccd(sk, goal, neck, 1, deg_to_rad(2.5), weight, false)

## The kiss. live: he is kissing her now; otherwise her head eases out of the last kiss pose.
func _kiss(sk: Skeleton3D, delta: float, live: bool) -> void:
	var settings := kiss_settings()
	var to_sk := sk.global_transform.affine_inverse()
	var scale:=maxf(sk.global_basis.get_scale().x,.01)
	var weight := smoothstep(0.0, 1.0, amount)
	if live: _last_eye = eye; _last_face = face.orthonormalized()
	var his := _last_face
	_rest_axes(sk)
	_rear_pose(sk, delta, live, weight, settings)
	_kneel_pose(sk, delta, live, settings)
	var carried_feet: Array[Vector3] = []
	if mare.is_held():
		for leg in _legs: carried_feet.append(sk.get_bone_global_pose(int(leg.tip)).origin)
	# Her animated neck, before the kiss moves it.
	_anim.clear()
	for bone in _chain: _anim[bone] = sk.get_bone_pose_rotation(bone)
	var head_world := sk.global_transform*sk.get_bone_global_pose(head)
	var head_scale := head_world.basis.get_scale()
	var head_turn := head_world.basis.orthonormalized().get_rotation_quaternion()
	if not _goal.is_finite():
		# She starts from where her lips and head are now, and moves to him.
		_rest_axes(sk)
		_goal = head_world*mouth_in_head; _goal_speed = Vector3.ZERO
		_aim = head_turn; _spin = Vector3.ZERO
		var every := float(settings.side_switch)
		_side = 1.0 if every<=0.0 or _rng.randf()<.5 else -1.0
		_side_now = _side; _side_wait = every*_rng.randf_range(.6, 1.2)
	var forward := -his.z
	if live:
		_motion = move_toward(_motion, 1.0 if deep else .5, delta)
		var speed := float(settings.sway_speed)
		var wander := _motion*(1.0-.7*pause)
		_lean_side(settings, delta)
		var lips: Array = settings.lips
		# How far she can tip her muzzle up here: a mouth low against her, or him looking down
		# steeply, leaves less (HEAD_DROP, CHIN_MAX); she leans and turns further instead.
		# Carried in his hands she keeps the earlier chin-up: that pose was tuned around it.
		var nod_set := float(KISS_POSTURE_BEFORE.nod) if mare.is_held() and float(settings.get("neck_forward", 0.0))>0.0 else float(settings.nod)
		var chin := -nod_set*(1.0-.6*pause) + 6.0*(1.0-absf(_side_now))
		var low_chin := chin-clampf(chin-_chin_room(head_world, his), 0.0, 30.0)
		var used := minf(minf(chin,30.0), _chin_room(head_world, his, .08)) if mare.is_held() else low_chin
		# A breather draws her lips 7 cm back from his, eases her lean and lowers her muzzle to gaze.
		var depth := float(lips[2]) + float(settings.sway_reach)*_wander("reach", delta, speed)*wander + .07*pause
		var slide := float(lips[0])*_side_now + float(settings.sway_side)*_wander("side", delta, speed)*wander
		var want := target + his*Vector3(slide, float(lips[1]), -depth)
		# A gentler carried muzzle leaves less nose overhang. Seat the upper lip under his,
		# still within the original contact radius, rather than tipping her entire head up.
		if mare.is_held(): want = target + his*Vector3(slide*.4, float(lips[1])-.018, -depth-.006)
		# Her posed head: facing him (her forward along his +z, her up along his up), then turned,
		# nodded and tilted about his own axes. Mid side-change her muzzle lifts a little more.
		var facing := _frame(his.z, his.y)*_frame(_head_forward, _head_up).inverse()
		var turn := float(settings.turn)*_side_now + float(settings.sway_turn)*_wander("turn", delta, speed)*wander
		# The nod wander only tips her muzzle further up: tipping it down would show him her lips.
		var nod := -used - float(settings.sway_nod)*(_wander("nod", delta, speed)+1.0)*.5*wander
		var tilt := float(settings.tilt)*(1.0-.4*pause)*_side_now + float(settings.sway_tilt)*_wander("tilt", delta, speed)*wander
		var posed := Basis(his.y, deg_to_rad(turn))*Basis(his.x, deg_to_rad(nod))*Basis(his.z, deg_to_rad(tilt))*facing
		var aim := head_turn.slerp(posed.get_rotation_quaternion(), clampf(float(settings.hold),0.0,1.0))
		posed_aim = aim
		# She chases the pose: lips on a critically damped spring with a top speed, head on a
		# spring with a top turn rate. Nothing snaps to his head.
		_want = want
		_follow_goal(want, float(settings.pursuit_time), float(settings.pursuit_speed), delta)
		_follow_aim(aim, float(settings.pursuit_time), deg_to_rad(float(settings.turn_rate)), delta)
	# His eyes come first and at once: pushed back along his line of sight, no lag.
	var cleared := _clear_eye(_goal, Basis(_aim)*Basis.from_scale(head_scale), settings)
	_yield(cleared-_goal, forward)
	# The kiss owns her neck: from its rest (the middle of its joint ranges, not whatever look the
	# animation had put in it) the head turns to her aim, spread along the neck.
	var aim_sk := sk.global_basis.orthonormalized().get_rotation_quaternion().inverse()*_aim
	for bone: int in [_neck1, _neck2, head]:
		if bone>=0: sk.set_bone_pose_rotation(bone, sk.get_bone_rest(bone).basis.get_rotation_quaternion())
	_spread(sk, aim_sk)
	# Her neck carries her lips only a short way forward beyond where the head turn alone puts
	# them; her body steps for the rest (pony_affection.gd). Sideways and up and down stay with the
	# neck, inside its joint limits. Back only a little (BACK_GIVE): when he leans further into her
	# her body backs up (pony_affection.gd, back_up) instead of her neck folding her head into her chest
	# (dev 2026-10-14: "her neck can go INTO her body").
	var neutral := sk.global_transform*sk.get_bone_global_pose(head)*mouth_in_head
	var extend := _goal-neutral
	neck_demand = extend if live else Vector3.ZERO
	neutral_lips = neutral if live else Vector3.INF
	neck_base = sk.global_transform*sk.get_bone_global_pose(_neck1 if _neck1>=0 else head).origin
	var up: Vector3 = mare.pivot.global_basis.y.normalized()
	var ahead_axis: Vector3 = (-mare.pivot.global_basis.z).slide(up).normalized()
	var ahead := extend.dot(ahead_axis)
	var reach_now := float(settings.reach)
	var goal := _goal if mare.is_held() else _goal-ahead_axis*(ahead-clampf(ahead, -BACK_GIVE, reach_now))
	if not mare.is_held() and float(settings.get("neck_forward", 0.0))>0.0:
		aim_sk = _lean_neck(sk, to_sk*goal, aim_sk, delta)
		# The carry then settles the sideways part; her chest joins only for what her neck
		# leaves more than 1.5 cm short (a low mouth, a high one, a far one).
		# Knelt, her neck and withers have further to reach down than standing.
		_carry(sk, to_sk*goal, aim_sk, 12 if _kneel_now>.001 else 4)
	else: _carry(sk, to_sk*goal, aim_sk, 24 if mare.is_held() else 10)
	_hold_head(sk, aim_sk)
	# Whatever her joint limits did to the head angle, her face stays clear of his eyes.
	for i in 2:
		var short := _eye_short(sk.global_transform*sk.get_bone_global_pose(head), settings)
		if short<=.0005: break
		goal += forward*short
		_yield(forward*short, forward)
		_carry(sk, to_sk*goal, aim_sk, 3)
		_hold_head(sk, aim_sk)
	# Knelt as low as she goes and still above him, her face can stay near his eyes with no step
	# back to clear them: the room she gives must not carry her goal away from his mouth.
	if (_kneel_now>.001 or kneel_wanted) and _want.is_finite(): _goal = _want+(_goal-_want).limit_length(.12)
	var solved := sk.global_transform*sk.get_bone_global_pose(head)
	limited = solved.basis.orthonormalized().get_rotation_quaternion().angle_to(sk.global_basis.orthonormalized().get_rotation_quaternion()*aim_sk)
	_reach_error = goal-solved*mouth_in_head
	miss = _reach_error.length()
	# Chest flex must not swing the already-dangling carried forelegs behind her body.
	for k in carried_feet.size():
		var shoulder := sk.find_bone("pony_shoulder_"+("L" if k==0 else "R"))
		_limb_to(sk, int(_legs[k].tip), shoulder, carried_feet[k], 12)
	# Blend in and out from her animated neck.
	if weight<.999:
		for bone in _chain:
			sk.set_bone_pose_rotation(bone, Quaternion(_anim[bone]).slerp(sk.get_bone_pose_rotation(bone), weight))

## Degrees her muzzle may tip up from his line of sight, from where her lips must go (his mouth
## height against her head's lowest kissing height) and how far he looks down at her.
func _chin_room(head_world: Transform3D, his: Basis, drop := HEAD_DROP) -> float:
	var up := Vector3.UP
	var lips := head_world.basis*mouth_in_head
	var ahead := Vector2((lips-up*lips.dot(up)).length(), lips.dot(up))
	# Her upper lip's height above the head joint at world chin-up t: ahead.x*sin t + ahead.y*cos t.
	var radius := ahead.length()
	var lead := atan2(-ahead.y, ahead.x)
	var above := (target-head_world.origin).dot(up) + drop
	var world := CHIN_MAX if above>=radius else rad_to_deg(lead + asin(clampf(above/radius, -1.0, 1.0)))
	var down := rad_to_deg(asin(clampf(his.z.normalized().dot(up), -1.0, 1.0)))
	return minf(world, CHIN_MAX) - down

## Push the followed lips by `push` (world): he moved into her, so she gives way this instant and
## loses any speed toward him.
func _yield(push: Vector3, forward: Vector3) -> void:
	if push.length_squared()<.00000001: return
	_goal += push
	var toward := _goal_speed.dot(-forward)
	if toward>0.0: _goal_speed += forward*toward

## Which way she leans. In a deep kiss she changes sides every so often, slowly.
func _lean_side(settings: Dictionary, delta: float) -> void:
	var every := float(settings.side_switch)
	if every<=0.0: _side = 1.0
	elif deep and pause<=.01:
		_side_wait -= delta
		if _side_wait<=0.0: _side = -_side; _side_wait = every*_rng.randf_range(.7, 1.4)
	_side_now = move_toward(_side_now, _side, delta/1.4)

## Critically damped follow of her lip goal (Game Programming Gems 4 smooth damp): settles in
## about `time` seconds and never travels faster than about `top` m/s.
func _follow_goal(want: Vector3, time: float, top: float, delta: float) -> void:
	time = maxf(time, .02)
	var omega := 2.0/time
	var x := omega*delta
	var decay := 1.0/(1.0+x+.48*x*x+.235*x*x*x)
	var change := (_goal-want).limit_length(maxf(top, .01)*time)
	var aim := _goal-change
	var temp := (_goal_speed+change*omega)*delta
	_goal_speed = (_goal_speed-temp*omega)*decay
	var next := aim+(change+temp)*decay
	if (want-_goal).dot(next-want)>0.0:
		next = want; _goal_speed = Vector3.ZERO
	_goal = next

## Her head angle follows on a critically damped spring, never spinning faster than `top` rad/s.
func _follow_aim(want: Quaternion, time: float, top: float, delta: float) -> void:
	var omega := 2.0/maxf(time, .02)
	var error := (want*_aim.inverse()).normalized()
	if error.w<0.0: error = -error
	var angle := error.get_angle()
	var turn := error.get_axis()*angle if angle>.00001 else Vector3.ZERO
	_spin += (turn*omega*omega-_spin*2.0*omega)*delta
	_spin = _spin.limit_length(maxf(top, .01))
	var step := _spin*delta
	if step.length()>.000001: _aim = (Quaternion(step.normalized(), step.length())*_aim).normalized()

## Joint-limited kiss neck, in skeleton space: the head's turn to `aim` spreads along the neck
## (SPREAD), then _carry moves the head so her lips reach the goal, the head keeping its angle.
## Every bone stays inside the rig's joint limits.
func _spread(sk: Skeleton3D, aim: Quaternion) -> void:
	_aim_along(sk, aim, [_neck1, _neck2, head], SPREAD)

## Turn the head toward `aim` (skeleton space) through `bones`, each taking `shares[k]` of what is
## left, each held inside its joint limits.
func _aim_along(sk: Skeleton3D, aim: Quaternion, bones: Array[int], shares: Array[float]) -> void:
	for k in bones.size():
		if bones[k]<0: continue
		var rest := aim*_turn_of(sk, head).inverse()
		_turn(sk, bones[k], Quaternion.IDENTITY.slerp(rest.normalized(), shares[k]))

## CCD on the neck (then the chest, a little) moving her head so her lips go to `goal`. After each
## bend the head's angle is restored through every bone below the one that bent, so no single
## joint (least of all the head's own) has to take all of it.
func _carry(sk: Skeleton3D, goal: Vector3, aim: Quaternion, passes: int) -> void:
	var carriers: Array[int] = _carriers.duplicate()
	var low_spine := sk.find_bone("pony_spine1")
	var low_share := smoothstep(.10, .18, -neck_demand.y) if mare.is_held() else 0.0
	if low_share>.001: carriers.append(low_spine)
	# Neck forward: on the ground her neck does the reaching. Her chest joins a pass only while
	# her lips are still more than 1.5 cm short after the neck bones have turned.
	var neck_first: bool = not mare.is_held() and float(kiss_settings().get("neck_forward", 0.0))>0.0
	var short := .015/maxf(sk.global_basis.get_scale().x, .01)
	for step in passes:
		for bone: int in carriers:
			var head_pose := sk.get_bone_global_pose(head)
			var place := goal-head_pose.basis*mouth_in_head
			if neck_first and bone not in [_neck1, _neck2] and head_pose.origin.distance_to(place)<short: continue
			var pose := sk.get_bone_global_pose(bone)
			var from := head_pose.origin-pose.origin
			var to := place-pose.origin
			var axis := from.cross(to)
			if from.length()<.001 or to.length()<.001 or axis.length()<.000001: continue
			var chest_bone := bone not in [_neck1, _neck2]
			_turn(sk, bone, Quaternion(axis.normalized(), minf(from.angle_to(to), deg_to_rad(2.0 if chest_bone else 8.0))))
			if chest_bone:
				var anim: Quaternion = _anim.get(bone, sk.get_bone_pose_rotation(bone))
				var now := sk.get_bone_pose_rotation(bone)
				var bent := anim.angle_to(now)
				var cap := CHEST_MAX*low_share if bone==low_spine else ((CRADLE_CHEST_MAX if _cradled() else PI) if mare.is_held() else CHEST_MAX)
				if bent>cap: sk.set_bone_pose_rotation(bone, anim.slerp(now, cap/bent))
				if neck_first: _keep_aim(sk, aim, [_neck1, _neck2, head], [.34, .5, 1.0])
				else: _aim_along(sk, aim, [_neck1, _neck2, head], [.34, .5, 1.0])
			elif bone==_neck1:
				if neck_first: _keep_aim(sk, aim, [_neck2, head], [.5, 1.0])
				else: _aim_along(sk, aim, [_neck2, head], [.5, 1.0])
			else: _hold_head(sk, aim)

## Neck forward: her neck leans as one piece from its base (neck1 and neck2 turn the same way
## about her own left-right axis, 60 % and 40 %) to carry her lips to `goal`, her head joint
## keeping her head on `aim`. A leaning neck carries her head on an arc, a little lower the
## further it leans, so her muzzle then tips up or down by what her lips are still short. Both
## angles are found by narrowing a range (the lip error has one low point in each); every bone
## is held inside its joint limit at every try. Returns the head angle she ends on.
func _lean_neck(sk: Skeleton3D, goal: Vector3, aim: Quaternion, delta: float) -> Quaternion:
	if _neck1<0 or _neck2<0: return aim
	if amount<.02:
		_neck_lean = 0.0; _neck_tip = 0.0
	var axis := (sk.global_basis.inverse()*mare.global_basis.x).normalized()
	var rest1 := sk.get_bone_pose_rotation(_neck1)
	var rest2 := sk.get_bone_pose_rotation(_neck2)
	# Each angle is looked for only close to where it was a frame ago (LEAN_RATE): her neck
	# moves there, it never jumps to another answer.
	var step := LEAN_RATE*delta
	var lean_from := _neck_lean
	var tip_from := _neck_tip
	# First the lean, then the tip of her muzzle, then the lean again.
	for turn_now in 3:
		var low := maxf(tip_from-step, -LEAN_TIP_DOWN) if turn_now==1 else maxf(lean_from-step, -LEAN_MAX)
		var high := minf(tip_from+step, LEAN_TIP_UP) if turn_now==1 else minf(lean_from+step, LEAN_BACK)
		for i in 5:
			var a := lerpf(low, high, 1.0/3.0)
			var b := lerpf(low, high, 2.0/3.0)
			var miss_a := _lean_miss(sk, goal, aim, axis, rest1, rest2, _neck_lean if turn_now==1 else a, a if turn_now==1 else _neck_tip)
			var miss_b := _lean_miss(sk, goal, aim, axis, rest1, rest2, _neck_lean if turn_now==1 else b, b if turn_now==1 else _neck_tip)
			if miss_a<miss_b: high = b
			else: low = a
		if turn_now==1: _neck_tip = (low+high)*.5
		else: _neck_lean = (low+high)*.5
	_lean_miss(sk, goal, aim, axis, rest1, rest2, _neck_lean, _neck_tip)
	return Quaternion(axis, _neck_tip)*aim

## Poses her neck at `lean` and her head at `aim` tipped by `tip`; returns how far her lips are
## then from `goal`.
func _lean_miss(sk: Skeleton3D, goal: Vector3, aim: Quaternion, axis: Vector3, rest1: Quaternion, rest2: Quaternion, lean: float, tip: float) -> float:
	sk.set_bone_pose_rotation(_neck1, rest1)
	sk.set_bone_pose_rotation(_neck2, rest2)
	_turn(sk, _neck1, Quaternion(axis, lean*.6))
	_turn(sk, _neck2, Quaternion(axis, lean*.4))
	_hold_head(sk, Quaternion(axis, tip)*aim)
	return (goal-sk.get_bone_global_pose(head)*mouth_in_head).length()

## Neck forward: after a neck or chest bone has leaned, her head joint alone puts her head back
## on its angle, so the lean stays in her neck (a horse reaching forward) instead of the next
## neck bone bending back against it. Only what her head joint cannot take inside its limit
## goes back along `bones`, as before.
func _keep_aim(sk: Skeleton3D, aim: Quaternion, bones: Array[int], shares: Array[float]) -> void:
	_hold_head(sk, aim)
	if _turn_of(sk, head).angle_to(aim)>deg_to_rad(1.5): _aim_along(sk, aim, bones, shares)

## She is bridal carried (pony_carry.gd cradle_goal).
func _cradled() -> bool:
	var carry: Object = mare.get("carry")
	return carry != null and carry.get("cradle_goal") == true

## The head turns to `aim` (skeleton space), as far as its own joint limit allows.
func _hold_head(sk: Skeleton3D, aim: Quaternion) -> void:
	var pose := sk.get_bone_global_pose(head)
	pose.basis = Basis(aim)*Basis.from_scale(pose.basis.get_scale())
	sk.set_bone_global_pose(head, pose)
	_limit(sk, head)

func _turn_of(sk: Skeleton3D, bone: int) -> Quaternion:
	return sk.get_bone_global_pose(bone).basis.orthonormalized().get_rotation_quaternion()

## Rotate `bone` by `turn` (skeleton space, about its own origin), then keep it in its limits.
func _turn(sk: Skeleton3D, bone: int, turn: Quaternion) -> void:
	var pose := sk.get_bone_global_pose(bone)
	pose.basis = Basis(turn)*pose.basis
	sk.set_bone_global_pose(bone, pose)
	_limit(sk, bone)

## The rig's joint limit for `bone` (pony_joint_limits.gd, the same limits locomotion keeps).
func _limit(sk: Skeleton3D, bone: int) -> void:
	var limits: Variant = mare.get("joint_limits")
	if limits == null: return
	var held: Basis = limits.constrain(bone, Basis(sk.get_bone_pose_rotation(bone)))
	sk.set_bone_pose_rotation(bone, held.get_rotation_quaternion())

## His eyes: the midpoint the headset reports and each eye beside it.
func _eyes() -> Array[Vector3]:
	var side := _last_face.x.normalized()*EYE_HALF
	var eyes: Array[Vector3] = [_last_eye, _last_eye-side, _last_eye+side]
	return eyes

## Metres her head (world transform) must move back along his line of sight to clear his eyes.
func _eye_short(head_world: Transform3D, settings: Dictionary) -> float:
	var skull := head_world*skull_in_head
	var nose := head_world*nose_in_head
	var short := 0.0
	var mane := float(settings.mane_clear)
	var by := ""
	for at in _eyes():
		var s := skull_radius+float(settings.eye_clear)-skull.distance_to(at)
		if s>short: short = s; by = "skull"
		s = maxf(float(settings.nose_clear), .05 if mare.is_held() else .045)-nose.distance_to(at)
		if s>short: short = s; by = "nose"
		if mare.is_held():
			for p in face_in_head:
				s=.044-(head_world*p).distance_to(at)
				if s>short: short=s; by="face"
		for p in hair_in_head:
			s = mane-(head_world*p).distance_to(at)
			if s>short: short = s; by = "mane"
	if short>0.0: cleared_by = by
	return short

## A small rigid surface sample catches forehead/cheek clearance that the three touch spheres
## miss at flatter carried angles. Cached per mare; ordinary kissing keeps its accepted solver.
func sample_face() -> void:
	if not face_in_head.is_empty():return
	var hs: Skeleton3D=mare.boop_node.head_skeleton
	var offset: Transform3D=mare.neck_link._offsets[2]
	var to_head := offset*(hs.global_transform*hs.get_bone_global_pose(hs.find_bone("mHead"))).affine_inverse()
	var points := {}
	for node in mare.head.model.find_children("*","MeshInstance3D",true,false):
		var mi := node as MeshInstance3D
		if mi.mesh==null or mi.skin==null or not mi.is_visible_in_tree() or mi.get_node_or_null(mi.skeleton)!=hs:continue
		var binds: Array[Transform3D]=[]
		for b in mi.skin.get_bind_count():
			var bone := mi.skin.get_bind_bone(b)
			var name := String(mi.skin.get_bind_name(b))
			if not name.is_empty():bone=hs.find_bone(name)
			binds.append(to_head*hs.global_transform*hs.get_bone_global_pose(bone)*mi.skin.get_bind_pose(b) if bone>=0 else Transform3D())
		for surface in mi.mesh.get_surface_count():
			var arrays: Array=mi.mesh.surface_get_arrays(surface)
			if arrays[Mesh.ARRAY_BONES]==null:continue
			var verts: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array=arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
			var per := bones.size()/maxi(verts.size(),1)
			for i in verts.size():
				var point := Vector3.ZERO
				for k in per:point+=(binds[bones[i*per+k]]*verts[i])*weights[i*per+k]
				var cell := Vector3i(roundi(point.x/.008),roundi(point.y/.008),roundi(point.z/.008))
				points[cell]=point
	face_in_head=PackedVector3Array(points.values())

## Her forelock and front mane as a few dozen points in pony_head space, from her actual hair mesh
## skinned at its current pose (once per mare: the mane rides rigidly on her head). Keeps the most
## forward hair in each 3 cm patch of her face.
func sample_hair() -> void:
	if _hair_sampled: return
	_hair_sampled = true
	var link: Variant = mare.get("neck_link")
	var boop: Variant = mare.get("boop_node")
	var hair: Variant = mare.get("hair")
	var hair_sk: Variant = mare.get("hair_skeleton")
	if link == null or boop == null or hair == null or hair_sk == null or (link as Object).get("_offsets").size() < 3: return
	var hs: Skeleton3D = boop.head_skeleton
	var m_head := hs.find_bone("mHead")
	if m_head<0: return
	var offset: Transform3D = (link as Object).get("_offsets")[2]
	var to_head := offset*(hs.global_transform*hs.get_bone_global_pose(m_head)).affine_inverse()
	var sk := hair_sk as Skeleton3D
	var best := {}
	for node in (hair as Node).find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.skin == null or not mi.is_visible_in_tree(): continue
		var binds: Array[Transform3D] = []
		for b in mi.skin.get_bind_count():
			var bone := mi.skin.get_bind_bone(b)
			var bind_name := String(mi.skin.get_bind_name(b))
			if not bind_name.is_empty(): bone = sk.find_bone(bind_name)
			binds.append(sk.global_transform*sk.get_bone_global_pose(bone)*mi.skin.get_bind_pose(b) if bone>=0 else Transform3D())
		for surface in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(surface)
			if arrays[Mesh.ARRAY_BONES] == null: continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var per := bones.size()/maxi(verts.size(), 1)
			for i in range(0, verts.size(), 3):
				var w := Vector3.ZERO
				var total := 0.0
				for k in per:
					var weight := weights[i*per+k]
					if weight<=0.0: continue
					w += (binds[bones[i*per+k]]*verts[i])*weight
					total += weight
				if total<=0.0: continue
				var p := to_head*(w/total)
				# pony_head: -x is her forward, +y up. Only hair out in front of her brow.
				if -p.x<.15 or p.y<-.06: continue
				var cell := Vector2i(roundi(p.y/.03), roundi(p.z/.03))
				if not best.has(cell) or -p.x > -Vector3(best[cell]).x: best[cell] = p
	hair_in_head = PackedVector3Array(best.values())

## A value in [-1, 1] easing to a fresh random target. The pace varies (dev 2026-09-28: "make
## the speed of the head shifting varied"): mostly 0.6-1.8 s, now and then a quick 0.25-0.5 s
## shift or a slow 2-3.5 s drift; scaled by speed.
func _wander(key: String, delta: float, speed: float) -> float:
	if not _sway.has(key): _sway[key] = {"from": 0.0, "to": 0.0, "t": 1.0, "length": 1.0}
	var s: Dictionary = _sway[key]
	s.t = float(s.t) + delta*maxf(speed, 0.0)
	if float(s.t) >= float(s.length):
		var pace := _rng.randf()
		s.from = s.to; s.to = _rng.randf_range(-1.0, 1.0); s.t = 0.0
		s.length = _rng.randf_range(.25, .5) if pace < .2 else (_rng.randf_range(2.0, 3.5) if pace > .82 else _rng.randf_range(.6, 1.8))
	return lerpf(float(s.from), float(s.to), smoothstep(0.0, 1.0, float(s.t)/float(s.length)))

## Rear only enough to lift the mouth into neck range. Forelegs may then find support, never
## drive the body spacing. Held bodies belong entirely to the hands and cannot rear here.
func _rear_pose(sk: Skeleton3D, delta: float, live: bool, _weight: float, settings: Dictionary) -> void:
	if _hips < 0 or _hind.size() != 2: return
	var allowed: bool = live and float(settings.rear)>0.0 and not mare.is_held() and mare.grounded() and (mare.posture == null or not mare.posture.active())
	var to_sk := sk.global_transform.affine_inverse()
	var forward := (-mare.global_basis.z).normalized()
	var up := Vector3.UP
	var axis := forward.cross(up).normalized()
	var hinge := (sk.get_bone_global_pose(sk.find_bone("pony_flank_L")).origin+sk.get_bone_global_pose(sk.find_bone("pony_flank_R")).origin)*.5
	var pivot := sk.global_transform*hinge
	var resting_lips := sk.global_transform*sk.get_bone_global_rest(head)*mouth_in_head
	var arc := resting_lips-pivot
	var desired := 0.0
	rear_step_ahead=0.0
	var animated_lips := sk.global_transform*sk.get_bone_global_pose(head)*mouth_in_head
	rear_wanted=allowed and amount>.8 and target.y-resting_lips.y>.18 and (_rear_now>.001 or target.y-animated_lips.y>.18)
	if rear_wanted:
		# A stable body-height target, independent of head wander and last frame's IK residual.
		var peak := clampf(atan2(arc.dot(forward),arc.dot(up)),0.0,deg_to_rad(45.0))
		var lift := maxf(0.0,target.y-resting_lips.y-.10+float(settings.rear_neck))
		var low := 0.0; var high := peak
		for i in 12:
			var mid := (low+high)*.5
			var raised := arc.dot(forward)*sin(mid)+arc.dot(up)*(cos(mid)-1.0)
			if raised<lift: low=mid
			else: high=mid
		desired=(low+high)*.5
		var final_ahead := arc.dot(forward)*cos(desired)-arc.dot(up)*sin(desired)
		rear_step_ahead=maxf(0.0,(target-pivot).dot(forward)-final_ahead+.02)
		if _rear_now<.001:
			# Preview the actual bounded neck on the future torso, then restore every pose.
			# This also handles the different resting head immediately after being carried.
			var predicted := _rear_neutral(sk,hinge,Basis((to_sk.basis*axis).normalized(),desired))
			rear_step_ahead=maxf(rear_step_ahead,(target-predicted).dot(forward)-.04)
		if _rear_now<.001 and (rear_step_ahead>.025 or mare.actual_speed>.025 or mare._blend>.05):desired=0.0
	# Critically damped rise and landing: no constant-speed start/stop or residual-driven pumping.
	var omega := 4.0/maxf(float(settings.rear_time),.2)
	var decay := exp(-omega*delta)
	var change := _rear_now-desired
	var temp := (_rear_speed+omega*change)*delta
	_rear_speed=(_rear_speed-omega*temp)*decay
	_rear_now=desired+(change+temp)*decay
	if mare.is_held(): _rear_now=0.0; _rear_speed=0.0
	if _rear_now<deg_to_rad(.3) and desired<.001: _rear_now=0.0; _rear_speed=0.0; _rear_plants.clear()
	var angle := _rear_now
	embrace={"ok": angle>.001, "rear": angle, "step": 0.0, "chest": false, "hug": 0.0, "points": []}
	if angle<=.001: return
	# Capture soles before rotating the torso. Their animation already supplies ordinary steps.
	if _rear_plants.is_empty():
		for leg in _hind: _rear_plants.append(sk.global_transform*sk.get_bone_global_pose(int(leg.tip)).origin)
	var plants: Array[Vector3] = []
	for plant in _rear_plants: plants.append(to_sk*plant)
	var rear := Basis((to_sk.basis*axis).normalized(), angle)
	# The rig root is a rigid frame, not a limb segment. Turn that frame about the hind-hip
	# line so the proximal leg joints stay planted; rotating about pony_hips lifted them.
	var root_bone := _hips
	while sk.get_bone_parent(root_bone)>=0: root_bone=sk.get_bone_parent(root_bone)
	var root_pose := sk.get_bone_global_pose(root_bone)
	root_pose.origin=hinge+rear*(root_pose.origin-hinge)
	root_pose.basis=rear*root_pose.basis
	sk.set_bone_global_pose(root_bone, root_pose)
	for k in _hind.size():
		var leg: Dictionary = _hind[k]
		var tip := int(leg.tip)
		# Counterturn the hip first, then distribute the residual through the real limb chain.
		var side := "L" if k==0 else "R"
		var flank := sk.find_bone("pony_flank_"+side)
		_turn(sk, flank, rear.get_rotation_quaternion().inverse())
		_limb_to(sk, tip, flank, plants[k], 36)
		embrace["plant_error_"+side] = sk.get_bone_global_pose(tip).origin.distance_to(plants[k])
	_support_forelegs(sk, to_sk, settings, angle/MAX_REAR)

## Kneel just far enough to bring her resting lips down to his mouth; her neck does the rest.
## Held bodies, seated or lying ponies and a rearing pony do not kneel. The Kissing mod switches
## the game's rear off (settings.rear) while its own rear has her body: the kneel yields too.
func _kneel_pose(sk: Skeleton3D, delta: float, live: bool, settings: Dictionary) -> void:
	if _hips < 0 or _hind.size() != 2 or _legs.size() != 2: return
	var scale := maxf(sk.global_basis.get_scale().x, .01)
	var allowed: bool = live and float(settings.get("kneel", 1.0))>0.0 and float(settings.rear)>0.0 and not kneel_block \
		and not mare.is_held() and mare.grounded() and (mare.posture == null or not mare.posture.active()) \
		and _rear_now<=.001 and not rear_wanted
	var to_sk := sk.global_transform.affine_inverse()
	var forward := (-mare.global_basis.z).normalized()
	var up := Vector3.UP
	var axis := forward.cross(up).normalized()
	var hinge := (sk.get_bone_global_pose(sk.find_bone("pony_flank_L")).origin+sk.get_bone_global_pose(sk.find_bone("pony_flank_R")).origin)*.5
	var desired := 0.0
	if allowed and amount>.8:
		var resting_lips := sk.global_transform*sk.get_bone_global_rest(head)*mouth_in_head
		# Her neck holds her head level whatever her body does, so what the tip lowers is the
		# base of her neck, not her lips at the end of it.
		var arc := sk.global_transform*sk.get_bone_global_rest(_neck1 if _neck1>=0 else head).origin-sk.global_transform*hinge
		var drop := resting_lips.y-target.y-KNEEL_NECK*scale
		# She starts to kneel standing still; once down she follows him without waiting.
		if drop>0.0 and (_kneel_now>.001 or (mare.actual_speed<=.025 and mare._blend<=.05)):
			var low := 0.0; var high := 1.0
			for i in 12:
				var mid := (low+high)*.5
				var tipped := KNEEL_PITCH*mid
				var lowered := arc.dot(forward)*sin(tipped)+arc.dot(up)*(1.0-cos(tipped))+KNEEL_SINK*scale*mid
				if lowered<drop: low=mid
				else: high=mid
			desired=(low+high)*.5
	kneel_wanted=desired>.02
	# Critically damped, as the rear: no constant-speed start or stop.
	var omega := 4.0/maxf(float(settings.get("kneel_time", .7)),.2)
	var decay := exp(-omega*delta)
	var change := _kneel_now-desired
	var temp := (_kneel_speed+omega*change)*delta
	_kneel_speed=(_kneel_speed-omega*temp)*decay
	_kneel_now=clampf(desired+(change+temp)*decay,0.0,1.0)
	if mare.is_held(): _kneel_now=0.0; _kneel_speed=0.0
	if _kneel_now<.003 and desired<.001: _kneel_now=0.0; _kneel_speed=0.0; _kneel_plants.clear()
	if _kneel_now<=0.0: return
	# Hind soles and the ground under her forehooves, before her body moves.
	if _kneel_plants.is_empty():
		# A hind hoof caught mid-step is set down level with the other.
		var floor_y := INF
		for leg in _hind: floor_y=minf(floor_y,(sk.global_transform*sk.get_bone_global_pose(int(leg.tip)).origin).y)
		for leg in _hind:
			var sole := sk.global_transform*sk.get_bone_global_pose(int(leg.tip)).origin
			_kneel_plants.append(Vector3(sole.x, floor_y, sole.z))
	var ground := INF
	for leg in _legs: ground=minf(ground,(sk.global_transform*sk.get_bone_global_pose(int(leg.tip)).origin).y)
	var axis_sk := (to_sk.basis*axis).normalized()
	var turn := Basis(axis_sk, -KNEEL_PITCH*_kneel_now)
	var root_bone := _hips
	while sk.get_bone_parent(root_bone)>=0: root_bone=sk.get_bone_parent(root_bone)
	var root_pose := sk.get_bone_global_pose(root_bone)
	root_pose.origin=hinge+turn*(root_pose.origin-hinge)+to_sk.basis*(Vector3.DOWN*(KNEEL_SINK*scale*_kneel_now))
	root_pose.basis=turn*root_pose.basis
	sk.set_bone_global_pose(root_bone, root_pose)
	# Her forelegs fold to stand on the ground. Folded all the way and still too long: her body
	# stays that much higher (the fold, not the sink, is the limit).
	var short := 0.0
	for leg in _legs: short=maxf(short,_fold_foreleg(sk, leg, axis_sk, forward, ground, scale))
	if short>.001:
		root_pose.origin+=to_sk.basis*(Vector3.UP*short)
		sk.set_bone_global_pose(root_bone, root_pose)
		for leg in _legs: _fold_foreleg(sk, leg, axis_sk, forward, ground, scale)
	for k in _hind.size():
		var side := "L" if k==0 else "R"
		var flank := sk.find_bone("pony_flank_"+side)
		_turn(sk, flank, turn.get_rotation_quaternion().inverse())
		_limb_to(sk, int(_hind[k].tip), flank, to_sk*_kneel_plants[k], 36)
	if kneel_trace:
		kneel_report={"kneel": _kneel_now, "wanted": desired, "short": short, "ground": ground}
		for k in 2:
			var side := "L" if k==0 else "R"
			var world := sk.global_transform
			kneel_report["fore_"+side]=[(world*sk.get_bone_global_pose(int(_legs[k].lower)).origin).y-ground,
				(world*sk.get_bone_global_pose(int(_legs[k].carpus)).origin).y-ground, (world*sk.get_bone_global_pose(int(_legs[k].tip)).origin).y-ground]
			kneel_report["hind_"+side]=(world*sk.get_bone_global_pose(int(_hind[k].tip)).origin).distance_to(_kneel_plants[k])
		kneel_report["chest"]=(sk.global_transform*sk.get_bone_global_pose(chest[0]).origin).y-ground if not chest.is_empty() else 0.0

## Fold one foreleg until its lowest point (knee or hoof) stands on `ground`: the knee goes
## forward as the cannon folds back under it, then the forearm comes upright onto the knee.
## Each joint turns about its own hinge (pony_joint_limits.gd), inside that hinge's range, and
## keeps the sideways set the animation gave it. Returns how far (world metres) the fully
## folded leg still reaches below the ground.
func _fold_foreleg(sk: Skeleton3D, leg: Dictionary, axis_sk: Vector3, forward: Vector3, ground: float, scale: float) -> float:
	var lower := int(leg.lower); var carpus := int(leg.carpus); var tip := int(leg.tip)
	if _foreleg_low(sk, carpus, tip, scale)>=ground: return 0.0
	var limits: Variant = mare.get("joint_limits")
	var hinges: Array[Dictionary] = []
	for bone: int in [lower, carpus, sk.get_bone_children(carpus)[0] if sk.get_bone_children(carpus).size()>0 else -1]:
		var hinge := _hinge_of(sk, limits, bone)
		if hinge.is_empty(): break
		hinge["bone"] = bone
		hinges.append(hinge)
	if hinges.size()<2:
		# A rig without a limit table for these joints: no fold, her body stays higher.
		return maxf(0.0, ground-_foreleg_low(sk, carpus, tip, scale))
	var elbow: Dictionary = hinges[0]
	# Radians her forearm swings forward (seen from her side) for each radian of elbow bend.
	var forearm_from := _sagittal(sk, lower, carpus, forward)
	var probe := deg_to_rad(12.0)*(1.0 if float(elbow.upper)-float(elbow.angle)>float(elbow.angle)-float(elbow.lower) else -1.0)
	_set_hinge(sk, lower, elbow, float(elbow.angle)+probe)
	var rate := (_sagittal(sk, lower, carpus, forward)-forearm_from)/probe
	if absf(rate)<.2: rate=1.0 if rate>=0.0 else -1.0
	var low := 0.0; var high := 1.0
	for i in 9:
		var mid := (low+high)*.5
		_fold_to(sk, lower, carpus, hinges, forearm_from, rate, mid)
		if _foreleg_low(sk, carpus, tip, scale)<ground: low=mid
		else: high=mid
	_fold_to(sk, lower, carpus, hinges, forearm_from, rate, high)
	return maxf(0.0, ground-_foreleg_low(sk, carpus, tip, scale))

## The fold has two parts, and through both the leg only ever gets shorter. First her knee
## goes forward and her cannon folds back under it, her hoof staying below her elbow. Then,
## her knee folded as far as it goes, her forearm comes down upright onto the knee and her hoof
## slides back behind it.
func _fold_to(sk: Skeleton3D, lower: int, carpus: int, hinges: Array[Dictionary], forearm_from: float, rate: float, folded: float) -> void:
	var first := clampf(folded/KNEEL_FIRST, 0.0, 1.0)
	var second := clampf((folded-KNEEL_FIRST)/(1.0-KNEEL_FIRST), 0.0, 1.0)
	var forearm := lerpf(lerpf(forearm_from, maxf(forearm_from, KNEEL_KNEE_FORWARD), first), KNEEL_FOREARM, second)
	_set_hinge(sk, lower, hinges[0], float(hinges[0].angle)+(forearm-forearm_from)/rate)
	# Her knee folds toward the wide end of its range: the way that joint bends.
	var knee: Dictionary = hinges[1]
	var end := float(knee.lower) if absf(float(knee.lower))>absf(float(knee.upper)) else float(knee.upper)
	_set_hinge(sk, carpus, knee, lerpf(float(knee.angle), end*KNEEL_FOLD_SHARE, first))
	# Then her pastern tucks her hoof up behind the knee she rests on.
	if hinges.size()>2:
		var pastern: Dictionary = hinges[2]
		var tuck := float(pastern.lower) if absf(float(pastern.lower))>absf(float(pastern.upper)) else float(pastern.upper)
		_set_hinge(sk, int(pastern.bone), pastern, lerpf(float(pastern.angle), tuck*KNEEL_PASTERN_SHARE, second))

## A joint's bend about its own hinge now, and what the animation set it sideways (swing).
## Empty when the rig's limit table does not carry the bone.
func _hinge_of(_sk: Skeleton3D, limits: Variant, bone: int) -> Dictionary:
	if limits == null or bone<0 or not limits.joints.has(bone): return {}
	var joint: Dictionary = limits.joints[bone]
	var parent := Basis(joint.parent)
	var turned := (parent*Basis(_sk.get_bone_pose_rotation(bone))*Basis(joint.rest).inverse()*parent.inverse()).get_rotation_quaternion()
	var split: Dictionary = limits._split(turned, joint.axis)
	return {"parent": parent, "rest": Basis(joint.rest), "axis": Vector3(joint.axis), "lower": float(joint.lower), "upper": float(joint.upper),
		"angle": float(split.angle), "swing": Quaternion(split.swing)}

func _set_hinge(sk: Skeleton3D, bone: int, hinge: Dictionary, angle: float) -> void:
	var bent := Quaternion(hinge.swing)*Quaternion(Vector3(hinge.axis), clampf(angle, float(hinge.lower), float(hinge.upper)))
	sk.set_bone_pose_rotation(bone, (Basis(hinge.parent).inverse()*Basis(bent)*Basis(hinge.parent)*Basis(hinge.rest)).get_rotation_quaternion())

## The angle of the line from bone `from` to bone `to`, seen from her side: 0 straight down,
## positive toward her front (radians).
func _sagittal(sk: Skeleton3D, from: int, to: int, forward: Vector3) -> float:
	var line := sk.global_basis*(sk.get_bone_global_pose(to).origin-sk.get_bone_global_pose(from).origin)
	return atan2(line.dot(forward), -line.y)

## World height of the lowest part of her lower foreleg: her knee's skin or her hoof tip.
func _foreleg_low(sk: Skeleton3D, carpus: int, tip: int, scale: float) -> float:
	return minf((sk.global_transform*sk.get_bone_global_pose(carpus).origin).y-KNEEL_KNEE*scale,
		(sk.global_transform*sk.get_bone_global_pose(tip).origin).y)

## Measure future kissing reach without committing the torso or touching the planted feet.
func _rear_neutral(sk: Skeleton3D, hinge: Vector3, turn: Basis) -> Vector3:
	var root_bone := _hips
	while sk.get_bone_parent(root_bone)>=0:root_bone=sk.get_bone_parent(root_bone)
	var original := sk.get_bone_global_pose(root_bone)
	var posed := original
	posed.origin=hinge+turn*(posed.origin-hinge);posed.basis=turn*posed.basis
	var saved: Array[Quaternion]=[]
	for bone: int in [_neck1,_neck2,head]:saved.append(sk.get_bone_pose_rotation(bone))
	sk.set_bone_global_pose(root_bone,posed)
	for bone: int in [_neck1,_neck2,head]:sk.set_bone_pose_rotation(bone,sk.get_bone_rest(bone).basis.get_rotation_quaternion())
	_spread(sk,sk.global_basis.orthonormalized().get_rotation_quaternion().inverse()*_aim)
	var lips := sk.global_transform*sk.get_bone_global_pose(head)*mouth_in_head
	sk.set_bone_global_pose(root_bone,original)
	var chain: Array[int]=[_neck1,_neck2,head]
	for k in chain.size():sk.set_bone_pose_rotation(chain[k],saved[k])
	return lips

## Bounded rotational CCD on every actual link. Never relocates a joint or stretches a bone.
func _limb_to(sk: Skeleton3D, tip: int, root: int, goal: Vector3, passes: int) -> void:
	for step in passes:
		var bone := sk.get_bone_parent(tip)
		while bone>=0:
			var at := sk.get_bone_global_pose(bone).origin
			var from := sk.get_bone_global_pose(tip).origin-at
			var to := goal-at
			var axis := from.cross(to)
			if axis.length_squared()>.000000001:
				_turn(sk, bone, Quaternion(axis.normalized(), minf(from.angle_to(to), deg_to_rad(8.0))))
			if bone==root: break
			bone=sk.get_bone_parent(bone)

## Shoulders when in reach; otherwise the front of his chest. A free hoof simply stays raised
## as close as its joints permit. No torso translation or extra reach is granted for contact.
func _support_forelegs(sk: Skeleton3D, to_sk: Transform3D, settings: Dictionary, raised: float) -> void:
	if _legs.size()!=2: return
	var shoulders := shoulder_points(_last_eye, _last_face, settings)
	var facing := -_last_face.z; facing.y=0.0
	facing=facing.normalized() if facing.length_squared()>.001 else Vector3.FORWARD
	var blend := clampf(raised*3.0, 0.0, 1.0)
	var points: Array[Vector3] = []
	var on_chest := false
	for k in 2:
		var leg: Dictionary = _legs[k]
		var side := "L" if k==0 else "R"
		var shoulder := sk.find_bone("pony_shoulder_"+side)
		var start := sk.global_transform*sk.get_bone_global_pose(int(leg.upper)).origin
		var tip := sk.global_transform*sk.get_bone_global_pose(int(leg.tip)).origin
		# A small forward fold also runs with support off, so lifted hooves do not point down.
		var goal := start + facing*-.18 + Vector3.DOWN*.28
		if float(settings.hooves)>.0:
			var candidate: Vector3 = shoulders[1-k]
			if start.distance_to(candidate)>.32:
				candidate=_last_eye + facing*.07 + Vector3.DOWN*clampf(_last_eye.y-start.y+.22, .4, .65)
				candidate+=_last_face.x*(float(settings.hoof_width)*(-1.0 if k==0 else 1.0))
				on_chest=true
			goal=goal.lerp(candidate, clampf(float(settings.hooves), 0.0, 1.0))
		points.append(goal)
		# Aim through shoulder/elbow only. Curling every toe joint to a nearby target made
		# corkscrew forelegs even though each individual joint was technically in range.
		var at_goal := to_sk*tip.lerp(goal,blend)
		for pass_index in 12:
			for bone: int in [int(leg.lower),int(leg.upper),shoulder]:
				var at := sk.get_bone_global_pose(bone).origin
				var from := sk.get_bone_global_pose(int(leg.tip)).origin-at
				var to := at_goal-at
				var axis := from.cross(to)
				if axis.length_squared()>.000000001:
					_turn(sk,bone,Quaternion(axis.normalized(),minf(from.angle_to(to),deg_to_rad(8.0))))
	embrace.chest=on_chest; embrace.hug=blend; embrace.points=points

## Orthonormal basis whose x is `forward` and y is `up` made perpendicular.
func _frame(forward: Vector3, up: Vector3) -> Basis:
	var x := forward.normalized()
	var y := (up-x*up.dot(x)).normalized()
	if not y.is_finite() or y.length_squared()<.5: y = x.cross(Vector3.RIGHT).normalized()
	return Basis(x, y, x.cross(y))

## Rotate each chain bone so her mouth moves toward `goal`. keep_head holds the head's world angle.
func _ccd(sk: Skeleton3D, goal: Vector3, chain: Array[int], steps: int, cap: float, weight: float, keep_head: bool) -> void:
	for step in steps:
		for bone in chain:
			var held := sk.get_bone_global_pose(head).basis
			var pose := sk.get_bone_global_pose(bone)
			var mouth := sk.get_bone_global_pose(head)*mouth_in_head
			var from := mouth-pose.origin
			var to := goal-pose.origin
			var axis := from.cross(to)
			if from.length()<.001 or to.length()<.001 or axis.length()<.00001:continue
			pose.basis=Basis(axis.normalized(),minf(from.angle_to(to),cap)*weight)*pose.basis
			sk.set_bone_global_pose(bone,pose)
			_limit(sk, bone)
			if keep_head and bone!=head:
				var head_pose := sk.get_bone_global_pose(head)
				head_pose.basis = held
				sk.set_bone_global_pose(head, head_pose)
				_limit(sk, head)

## His lips, moved back along his line of sight until her head, turned by `head_basis` (world,
## with scale), clears both of his eyes.
func _clear_eye(lips: Vector3, head_basis: Basis, settings: Dictionary) -> Vector3:
	var forward := -_last_face.z
	var goal := lips
	for i in 4:
		var short := _eye_short(Transform3D(head_basis, goal-head_basis*mouth_in_head), settings)
		if short<=0.0: break
		goal += forward*short
	return goal

## Bend `name` by `angle` about `axis` (skeleton space, about its own origin), then hold it inside
## the rig's joint limits like every other pose writer: a kick or stretch can never bend a leg
## past where it can go (dev 2026-10-14: "a pony body CANNOT move weirdly").
func _rotate(sk: Skeleton3D, name: String, axis: Vector3, angle: float) -> void:
	var bone:=sk.find_bone(name)
	if bone<0:return
	var pose:=sk.get_bone_global_pose(bone)
	pose.basis=Basis(axis,angle)*pose.basis
	sk.set_bone_global_pose(bone,pose)
	_limit(sk, bone)
