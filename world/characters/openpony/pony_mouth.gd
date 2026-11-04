class_name PonyMouth
extends SkeletonModifier3D
## Mouth shapes for the OpenPony rig, blended on the Bento face bones.
##
## Base shapes are sampled at start-up from the devkit clips in the mare's
## AnimationPlayer (tools/export_openpony_anims.py): one shape = the delta of a
## set of face bones between the skeleton rest and one frame of one clip.
## Weights blend on top of whatever pose the body clip left on those bones, so
## an idle or a walk keeps playing while she talks. Visemes are Rhubarb Lip
## Sync's mouth shapes (A-H, X) expressed as weight mixes of the base shapes
## (VISEMES); expressions (smile, frown...) are a second layer added on top.
##
## Must be a child of the Skeleton3D (SkeletonModifier3D rule). Runs after the
## AnimationPlayer because the player writes the pose first, modifiers next.

## Bone name prefixes a mouth shape may touch. Eyes, brows and ears stay with
## the eye system; the nose stays still (sneeze wrinkles it).
const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const MOUTH := ["mFaceJaw", "mFaceChin", "mFaceTeethLower", "mFaceTeethUpper", "mFaceLip", "mFaceCheekLower"]
const TONGUE := ["mFaceTongue"]

## Base shapes: source clip, time in seconds (-1 = last frame), bone prefixes.
## Picked from tools/probe_openpony_mouth.gd (which bones each clip moves).
const SHAPES := {
	# Authored on the same face bones through Blender MCP for the November 2 sheet.
	"round": {"pose":"res://world/characters/openpony/face_sculpt/round_mouth.json"},
	# Speech poses authored through Blender MCP (tools/face_rig/viseme_shapes_mcp.py, dev
	# 2026-11-03: "oo" lips must stay on the muzzle; "ss" a slightly open mouth with real teeth).
	"ss": {"pose":"res://world/characters/openpony/face_sculpt/ss_mouth.json"},
	"oo": {"pose":"res://world/characters/openpony/face_sculpt/oo_mouth.json"},
	"ao": {"pose":"res://world/characters/openpony/face_sculpt/ao_mouth.json"},
	"press": {"pose":"res://world/characters/openpony/face_sculpt/press_mouth.json"},
	"fv": {"pose":"res://world/characters/openpony/face_sculpt/fv_mouth.json"},
	"tongue_up": {"pose":"res://world/characters/openpony/face_sculpt/tongue_up.json"},
	"jaw_wide": {"pose":"res://world/characters/openpony/face_sculpt/jaw_wide.json"},
	"lift": {"pose":"res://world/characters/openpony/face_sculpt/lift.json"},
	# The talk clip's opening made left/right symmetric, for speech only (open_soft stays as the
	# approved faces use it).
	"talk": {"clip": "talk_2", "time": 1.13, "bones": MOUTH, "mirror": true},
	"open": {"clip": "sneeze", "time": 0.33, "bones": MOUTH},
	"open_soft": {"clip": "talk_2", "time": 1.13, "bones": MOUTH},
	"open_lips": {"clip": "mouth_open_tongue", "time": 0.0, "bones": MOUTH},
	"tongue": {"clip": "mouth_open_tongue", "time": 0.0, "bones": TONGUE},
	"pout": {"clip": "mouth_pout", "time": -1.0, "bones": MOUTH},
	"smile": {"clip": "mouth_smile", "time": -1.0, "bones": MOUTH},
	"smile_teeth": {"clip": "mouth_smile_teeth", "time": 0.0, "bones": MOUTH},
	"smile_big": {"clip": "mouth_smile_big", "time": -1.0, "bones": MOUTH},
	"frown": {"clip": "mouth_frown", "time": 0.0, "bones": MOUTH},
	"frown_big": {"clip": "mouth_frown_big", "time": 0.0, "bones": MOUTH},
	"neutral": {"clip": "mouth_neutral", "time": 0.0, "bones": MOUTH},
	"yikes": {"clip": "mouth_yikes", "time": 0.0, "bones": MOUTH},
	# The devkit's curled-lip poses (dev 2026-10-01: the resting face).
	"smirk": {"clip": "mouth_smirk", "time": -1.0, "bones": MOUTH},
	"catsmile": {"clip": "mouth_catsmile", "time": -1.0, "bones": MOUTH},
}

## Rhubarb mouth shapes -> base shape weights.
##   A closed (M B P)      B slightly open, teeth (most consonants, EE)
##   C open (EH AE)        D wide open (AA)        E rounded, slightly open (AO ER)
##   F puckered (UW OW W)  G upper teeth on lip (F V)   H tongue up (L)   X rest
## No smile_teeth in speech (dev 2026-10-14: its lopsided grin read as a creepy, confused mouth).
## No sneeze "open" or devkit "pout" either: they threw the lips forward off the muzzle (dev
## 2026-11-03, "oo" lips came forward off the mesh). Round 1 (2026-11-03 viseme review): each
## letter is its own readable shape; the authored poses keep every lip on the muzzle surface.
## Round 2: F is a small near-round ring whose lips slide along the lip arch (no corner fold, no
## gash in profile); E is its own wider ring (ao), not a half-weight oo whose corners would cut
## inside the muzzle; B parts the lips over both rows of teeth with a dark gap between them.
const VISEMES := {
	"X": {},
	"A": {"press": 1.0},
	"B": {"ss": 1.0},
	"C": {"talk": 0.85, "lift": 1.0},
	"D": {"talk": 1.0, "jaw_wide": 1.0},
	"E": {"ao": 1.0},
	"F": {"oo": 1.0},
	"G": {"fv": 1.0},
	"H": {"talk": 0.65, "tongue_up": 1.0},
}
## How far the expression layer (the speaking smile) yields per viseme. Consonants keep the
## smile so the corners hold still through them; the wide vowel eases it; the rounded vowels
## release it, since the smile pulls the corners out against the rounding. No viseme active
## (X, or not speaking) yields nothing, so the resting faces are untouched.
const VISEME_YIELD := {"D": 0.3, "E": 1.0, "F": 1.0}
## Speech shapes that part the lips. While any is held above SPEECH_OPEN_AT, lip_open_changed
## tells the head (hybrid_mare.set_lip_hull_open) to drop the lip-lining hull that otherwise
## draws a stray ink line across the open mouth; expressions keep their approved ink.
const SPEECH_OPEN := ["ss", "oo", "ao", "talk", "jaw_wide", "lift", "tongue_up", "fv"]
const SPEECH_OPEN_AT := 0.05
## Called with true when speech parts the lips and false when they close again.
var lip_open_changed := Callable()
var _lip_open := false
## The pursed "oo" lights the dark lip colour toward the coat (viseme review round 3): pursed lips
## are lit skin, and at full lip colour the rolled-out lips framed the small opening as a dark box
## with bars. Per shape, the share of the lip-to-coat blend at full weight; lip_tone_changed gets
## the summed blend in LIP_TONE_STEP steps (0 = the approved lip colour, as in every expression).
const LIP_TONE := {"oo": 0.65}
const LIP_TONE_STEP := 0.05
var lip_tone_changed := Callable()
var _lip_tone := 0.0

## Weight easing time scale in seconds (Rhubarb cues are 50-200 ms long). Weights approach their
## targets exponentially: rising with a time constant of blend_time / OPEN_RATE (about 40 ms to
## 90%), falling with blend_time / CLOSE_RATE (about 75 ms to 90%), so mouths open crisply and
## close softly instead of flapping at one linear rate.
@export var blend_time := 0.06
const OPEN_RATE := 3.4
const CLOSE_RATE := 1.8
## A weight this close to its target snaps onto it (the mix cache then stops rebuilding).
const SETTLE := 0.004

var current_viseme := "X"

var _shapes := {}      # name -> {bone_idx: {"q": Quaternion, "p": Vector3}}
var _bones: Array[int] = []
## PonyCrowd NEAR mares: full run every `rate_divisor`-th physics tick, cached writes between.
var rate_divisor := 1
var rate_phase := 0
## The last full run's writes, in bone order (re-applied on the skipped ticks).
var _written_bones := PackedInt32Array()
var _written_rotations: Array[Quaternion] = []
var _written_positions := PackedVector3Array()
## [bone names, rests, source clips] -> [shapes, bones]. Every head of a model samples the same
## shapes from the same shared clip library; build() did it again for each spawned pony.
static var _built := {}
var _weights := {}     # name -> current weight
var _targets := {}     # name -> target weight (visemes + expressions)
var _viseme_targets := {}
var _expression := {}


## Sample every shape in SHAPES from the player's clips. Returns the number of
## shapes that found their clip and moved at least one bone.
func build(player: AnimationPlayer) -> int:
	var skel := get_skeleton()
	if skel == null or player == null:
		return 0
	var names := PackedStringArray()
	var rests: Array[Transform3D] = []
	for i in skel.get_bone_count():
		names.append(skel.get_bone_name(i))
		rests.append(skel.get_bone_rest(i))
	var clips := []
	for shape_name in SHAPES:
		var clip: String = SHAPES[shape_name].get("clip", "")
		clips.append(player.get_animation(clip) if player.has_animation(clip) else null)
	var key := [names, rests, clips]
	_mix_valid = false
	if _built.has(key):
		# Shared, never edited: build() replaces _shapes instead of clearing it.
		_shapes = _built[key][0]
		_bones.assign(_built[key][1])
		return _shapes.size()
	_shapes = {}
	var bones := {}
	for shape_name in SHAPES:
		var def: Dictionary = SHAPES[shape_name]
		if def.has("pose"):
			var pose: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(def.pose))
			var authored := {}
			for bone_name: String in pose.positions:
				var bone := skel.find_bone(bone_name)
				if bone < 0: continue
				var p: Array = pose.positions[bone_name]
				authored[bone] = {"q":Quaternion.IDENTITY, "p":Vector3(p[0],p[1],p[2])}
				bones[bone] = true
			# Optional bone-local rotation deltas [x, y, z, w] (jaw_wide).
			var rotations: Dictionary = pose.get("rotations", {})
			for bone_name: String in rotations:
				var bone := skel.find_bone(bone_name)
				if bone < 0: continue
				var r: Array = rotations[bone_name]
				var entry: Dictionary = authored.get(bone, {"q":Quaternion.IDENTITY, "p":Vector3.ZERO})
				entry["q"] = Quaternion(r[0], r[1], r[2], r[3]).normalized()
				authored[bone] = entry
				bones[bone] = true
			_shapes[shape_name] = authored
			continue
		if not player.has_animation(def["clip"]):
			continue
		var anim := player.get_animation(def["clip"])
		var t: float = def["time"]
		if t < 0.0:
			t = anim.length
		t = clampf(t, 0.0, anim.length)
		var deltas := {}
		for i in anim.get_track_count():
			var bone := String(anim.track_get_path(i).get_subname(0))
			if not _matches(bone, def["bones"]):
				continue
			var idx := skel.find_bone(bone)
			if idx < 0:
				continue
			var rest := skel.get_bone_rest(idx)
			var d: Dictionary = deltas.get(idx, {"q": Quaternion.IDENTITY, "p": Vector3.ZERO})
			match anim.track_get_type(i):
				Animation.TYPE_ROTATION_3D:
					d["q"] = rest.basis.get_rotation_quaternion().inverse() * anim.rotation_track_interpolate(i, t)
				Animation.TYPE_POSITION_3D:
					d["p"] = anim.position_track_interpolate(i, t) - rest.origin
				_:
					continue
			deltas[idx] = d
		for idx in deltas.keys():
			var d: Dictionary = deltas[idx]
			if (d["q"] as Quaternion).get_angle() < 0.0005 and (d["p"] as Vector3).length() < 0.0001:
				deltas.erase(idx)
			else:
				bones[idx] = true
		if def.get("mirror", false):
			deltas = _symmetric(skel, deltas)
			for idx in deltas: bones[idx] = true
		if not deltas.is_empty():
			_shapes[shape_name] = deltas
	_bones.assign(bones.keys())
	_built[key] = [_shapes, _bones.duplicate()]
	return _shapes.size()


func shape_names() -> PackedStringArray:
	return PackedStringArray(_shapes.keys())


func shape_bone_count(shape_name: String) -> int:
	return (_shapes.get(shape_name, {}) as Dictionary).size()


## Rhubarb letter (A-H, X). Unknown letters read as X.
func set_viseme(letter: String, blend := -1.0) -> void:
	current_viseme = letter if VISEMES.has(letter) else "X"
	_viseme_targets = VISEMES[current_viseme]
	_retarget(blend)


## One base shape at a weight, for labs and captures. Replaces the viseme mix.
func set_shape(shape_name: String, weight: float, blend := -1.0) -> void:
	current_viseme = ""
	_viseme_targets = {shape_name: weight} if weight > 0.0 else {}
	_retarget(blend)


## Persistent layer under the visemes (smile while talking).
func set_expression(shape_name: String, weight: float, blend := -1.0) -> void:
	if weight > 0.0:
		_expression[shape_name] = weight
	else:
		_expression.erase(shape_name)
	_retarget(blend)


func clear(blend := -1.0) -> void:
	_expression.clear()
	set_viseme("X", blend)


func weight_of(shape_name: String) -> float:
	return _weights.get(shape_name, 0.0)


func _retarget(blend: float) -> void:
	_targets = {}
	for k in _viseme_targets:
		_targets[k] = _viseme_targets[k]
	var expression_scale := 1.0 - float(VISEME_YIELD.get(current_viseme, 0.0))
	for k in _expression:
		_targets[k] = minf(_targets.get(k, 0.0) + _expression[k] * expression_scale, 1.0)
	if blend == 0.0:
		_mix_valid = false
		_weights = _targets.duplicate()
		for k in _weights.keys():
			if _weights[k] <= 0.0:
				_weights.erase(k)
		_update_lip_open()


func _update_lip_open() -> void:
	if lip_tone_changed.is_valid():
		var tone := 0.0
		for shape: String in LIP_TONE:
			tone += float(_weights.get(shape, 0.0)) * float(LIP_TONE[shape])
		tone = snappedf(minf(tone, 1.0), LIP_TONE_STEP)
		if tone != _lip_tone:
			_lip_tone = tone
			lip_tone_changed.call(tone)
	if not lip_open_changed.is_valid():
		return
	var open := false
	for shape: String in SPEECH_OPEN:
		if float(_weights.get(shape, 0.0)) > SPEECH_OPEN_AT:
			open = true
			break
	if open != _lip_open:
		_lip_open = open
		lip_open_changed.call(open)


## Ease the weights toward their targets over `delta` seconds (see blend_time). Returns whether
## any weight moved. Public so review tools replay speech with the mouth's own easing.
func advance_weights(delta: float) -> bool:
	var rise := 1.0 if blend_time <= 0.0 else 1.0 - exp(-delta * OPEN_RATE / blend_time)
	var fall := 1.0 if blend_time <= 0.0 else 1.0 - exp(-delta * CLOSE_RATE / blend_time)
	var changed := false
	for k in _targets:
		var before: float = _weights.get(k, 0.0)
		var target: float = _targets[k]
		var w := before + (target - before) * (rise if target > before else fall)
		if absf(target - w) < SETTLE: w = target
		if w != before or not _weights.has(k): changed = true
		_weights[k] = w
	for k in _weights.keys():
		if not _targets.has(k):
			var w: float = _weights[k] * (1.0 - fall)
			changed = true
			if w < SETTLE:
				_weights.erase(k)
			else:
				_weights[k] = w
	return changed


func _unprofiled_process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or _bones.is_empty():
		return
	if rate_divisor > 1 and ((Engine.get_physics_frames() + rate_phase) % rate_divisor) != 0:
		# Clip-tier mare: re-apply the last full run (Skeleton3D reverts modifier writes).
		for k in _written_bones.size():
			skel.set_bone_pose_rotation(_written_bones[k], _written_rotations[k])
			skel.set_bone_pose_position(_written_bones[k], _written_positions[k])
		return
	var changed := advance_weights(get_process_delta_time() * rate_divisor)
	if changed: _update_lip_open()
	if _weights.is_empty():
		_written_bones.resize(0)
		_written_rotations.clear()
		_written_positions.resize(0)
		_mix_valid = false
		return
	if changed or not _mix_valid or influence != _mix_influence or not MIX_CACHE:
		_build_mix()
	var count := _mix_bones.size()
	_written_bones = _mix_bones
	_written_rotations.resize(count)
	_written_positions.resize(count)
	for k in count:
		var idx := _mix_bones[k]
		var q := (skel.get_bone_pose_rotation(idx) * _mix_rotations[k]).normalized()
		var p := skel.get_bone_pose_position(idx) + _mix_offsets[k]
		skel.set_bone_pose_rotation(idx, q)
		skel.set_bone_pose_position(idx, p)
		_written_rotations[k] = q
		_written_positions[k] = p


## Per touched bone, the shapes' rotations multiplied in weight order and their offsets summed at
## the current weights (0.1.0 perf pass). A full run used to redo this slerp and dictionary walk
## for every bone and shape at every run; the weights sit still between visemes and in the resting
## smile, so it is rebuilt only when a weight or the influence changes. Applied as one rotation
## and one offset on the bone's own pose: the same product as before, multiplied in another
## grouping (float rounding only). Rollback: MIX_CACHE = false.
const MIX_CACHE := true
var _mix_bones := PackedInt32Array()
var _mix_rotations: Array[Quaternion] = []
var _mix_offsets := PackedVector3Array()
var _mix_valid := false
var _mix_influence := 1.0

func _build_mix() -> void:
	_mix_bones = PackedInt32Array()
	_mix_rotations.clear()
	_mix_offsets = PackedVector3Array()
	_mix_influence = influence
	_mix_valid = true
	for idx in _bones:
		var q := Quaternion.IDENTITY
		var p := Vector3.ZERO
		var touched := false
		for shape_name in _weights:
			var w: float = _weights[shape_name] * influence
			if w <= 0.0001:
				continue
			var d: Variant = _shapes[shape_name].get(idx)  # no default: `{}` allocated per miss
			if d == null:
				continue
			q = q * Quaternion.IDENTITY.slerp(d["q"], minf(w, 1.0))
			p += (d["p"] as Vector3) * w
			touched = true
		if touched:
			_mix_bones.append(idx)
			_mix_rotations.append(q)
			_mix_offsets.append(p)


## Left/right symmetric copy of a clip-sampled shape (the devkit clips are lopsided): each
## Left/Right pair gets the average of itself and its mirrored twin, centre bones lose their
## sideways offset and any turn that is not about the lateral axis. Mirrored in the parent's
## frame (the face bones' parents keep x lateral), so it holds for any rest orientation.
static func _symmetric(skel: Skeleton3D, deltas: Dictionary) -> Dictionary:
	var out := {}
	for idx: int in deltas:
		var bone := skel.get_bone_name(idx)
		var d: Dictionary = deltas[idx]
		var p: Vector3 = d["p"]
		var q := _to_parent(skel, idx, d["q"])
		var twin_name := bone.replace("Left", "Right") if "Left" in bone else bone.replace("Right", "Left")
		if twin_name == bone:
			out[idx] = {"q": _from_parent(skel, idx, Quaternion(q.x, 0.0, 0.0, q.w).normalized()), "p": Vector3(0.0, p.y, p.z)}
			continue
		var twin := skel.find_bone(twin_name)
		var twin_p := Vector3.ZERO
		var twin_q := Quaternion.IDENTITY
		if deltas.has(twin):
			twin_p = deltas[twin]["p"]
			twin_q = _to_parent(skel, twin, deltas[twin]["q"])
		var mp := (p + _mirror_p(twin_p)) * 0.5
		var mq := q.slerp(_mirror_q(twin_q), 0.5)
		out[idx] = {"q": _from_parent(skel, idx, mq), "p": mp}
		if twin >= 0 and not deltas.has(twin):
			out[twin] = {"q": _from_parent(skel, twin, _mirror_q(mq)), "p": _mirror_p(mp)}
	return out


static func _to_parent(skel: Skeleton3D, idx: int, q: Quaternion) -> Quaternion:
	var rest := skel.get_bone_rest(idx).basis.get_rotation_quaternion()
	return rest * q * rest.inverse()


static func _from_parent(skel: Skeleton3D, idx: int, q: Quaternion) -> Quaternion:
	var rest := skel.get_bone_rest(idx).basis.get_rotation_quaternion()
	return (rest.inverse() * q * rest).normalized()


static func _mirror_p(p: Vector3) -> Vector3:
	return Vector3(-p.x, p.y, p.z)


static func _mirror_q(q: Quaternion) -> Quaternion:
	return Quaternion(q.x, -q.y, -q.z, q.w)


static func _matches(bone: String, prefixes: Array) -> bool:
	for prefix in prefixes:
		if bone.begins_with(prefix):
			return true
	return false


func _process_modification() -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process_modification()
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("mouth", started)
