extends RefCounted
## Reusable facial vocabulary, authored against the approved November 2 expression sheet.
## Upper lids, cheeks, iris proportions, pupil dilation and white heart shines are separate.
## Mouth entries always drive the real native lip/teeth/tongue rig. An empty map retains
## the ordinary closed resting smile; explicit smile 0 requests a neutral mouth.
const EYE_POSES := {
	"confident": {"sculpt":{"lid_flat_L":1, "lid_flat_R":1, "lid_angry_L":0.68, "lid_angry_R":0.68, "cheek_raise_R":0.82}, "iris_shape":[0.98, 1.06], "iris_drop":0.06, "shine_drop":0.17, "pupil":1},
	"squeezed": {"sculpt":{"lid_flat_L":1, "lid_flat_R":1, "lid_low_L":0.28, "lid_low_R":0.28, "lid_angry_L":0.35, "lid_angry_R":0.35, "cheek_raise_L":0.36, "cheek_raise_R":0.36}, "iris_shape":[1, 1], "iris_drop":0.12, "shine_drop":0.24, "pupil":1},
	"crooked": {"sculpt":{"eye_wide_L":0.25, "eye_wide_R":0.25, "cheek_raise_R":0.6}, "iris_shape":[1, 1.04], "iris_drop":0.015, "shine_drop":0, "pupil":1},
	"country": {"sculpt":{"lid_flat_L":0.88, "lid_flat_R":0.88, "lid_low_L":0.2, "lid_low_R":0.2, "lid_sad_L":0.14, "lid_sad_R":0.14}, "iris_shape":[1, 1.04], "iris_drop":0.08, "shine_drop":0.13, "pupil":1},
	"suspicious": {"sculpt":{"lid_flat_L":1, "lid_flat_R":1, "lid_low_L":0.05, "lid_low_R":0.25, "lid_angry_L":0.35, "lid_angry_R":0.35, "cheek_raise_L":0.22, "cheek_raise_R":0.22}, "iris_shape":[0.88, 1], "iris_drop":0.09, "shine_drop":0.18, "pupil":0.88},
	"warm": {"sculpt":{"cheek_raise_L":0.22, "cheek_raise_R":0.22}, "iris_shape":[1.04, 1.02], "iris_drop":0.015, "shine_drop":0, "pupil":1.05},
	"delighted": {"sculpt":{"eye_smile_L":1, "eye_smile_R":1}, "iris_shape":[1, 1], "iris_drop":0, "shine_drop":0, "pupil":1},
	"sad": {"sculpt":{"lid_flat_L":0.9, "lid_flat_R":0.9, "lid_sad_L":0.9, "lid_sad_R":0.9, "cheek_raise_L":0.5, "cheek_raise_R":0.5}, "iris_shape":[0.94, 1.06], "iris_drop":0.06, "shine_drop":0.03, "pupil":1.07},
	"rage": {"sculpt":{"lid_flat_L":1, "lid_flat_R":1, "lid_low_L":0.25, "lid_low_R":0.25, "lid_angry_L":1, "lid_angry_R":1, "cheek_raise_L":0.75, "cheek_raise_R":0.75}, "iris_shape":[0.9, 0.95], "iris_drop":0.12, "shine_drop":0.2, "pupil":0.3},
	"angry": {"sculpt":{"lid_flat_L":1, "lid_flat_R":1, "lid_angry_L":0.95, "lid_angry_R":0.95, "cheek_raise_L":0.68, "cheek_raise_R":0.68}, "iris_shape":[0.95, 1.03], "iris_drop":0.09, "shine_drop":0.16, "pupil":0.82},
	"fear": {"sculpt":{"eye_wide_L":0.75, "eye_wide_R":0.75}, "iris_shape":[0.78, 0.78], "iris_drop":0.025, "shine_drop":0, "pupil":0.6},
	"wide": {"sculpt":{"eye_wide_L":0.6, "eye_wide_R":0.6}, "iris_shape":[0.87, 0.92], "iris_drop":0, "shine_drop":0, "pupil":0.7},
	"anticipation": {"sculpt":{"lid_flat_L":1, "lid_flat_R":1, "lid_low_L":0.3, "lid_low_R":0.3, "lid_sad_L":0.12, "lid_sad_R":0.12, "cheek_raise_L":0.25, "cheek_raise_R":0.25}, "iris_shape":[1.03, 1.03], "iris_drop":0.13, "shine_drop":0.22, "pupil":1.05},
	"affectionate": {"sculpt":{"lid_flat_L":0.92, "lid_flat_R":0.92, "lid_sad_L":0.7, "lid_sad_R":0.7, "lid_low_L":0.1, "lid_low_R":0.1, "cheek_raise_L":0.3, "cheek_raise_R":0.3}, "iris_shape":[1.05, 1.05], "iris_drop":0.09, "shine_drop":0.18, "pupil":1.1},
	"disgust": {"sculpt":{"eye_wide_L":0.3, "lid_flat_R":0.35, "cheek_raise_L":0.35, "cheek_raise_R":0.5}, "iris_shape":[0.92, 1], "iris_drop":0.025, "shine_drop":0.03, "pupil":0.85},
	"confused": {"sculpt":{"lid_flat_L":0.6, "cheek_raise_R":0.15}, "iris_shape":[1, 1], "iris_drop":0.02, "shine_drop":0.07, "pupil":1},
	"shy": {"sculpt":{"lid_flat_L":0.45, "lid_flat_R":0.45, "lid_sad_L":0.55, "lid_sad_R":0.55, "cheek_raise_L":0.18, "cheek_raise_R":0.18}, "iris_shape":[1.03, 1.03], "iris_drop":0.04, "shine_drop":0.02, "pupil":1.08},
	# Smiling eyes for the faces that must read apart from the resting closed smile (dev 2026-11-03:
	# "neutral, happy, delighted and amused faces all look the same").
	# Delighted settles here after its brief closed-eye laugh (dev 2026-11-03: the earlier
	# 0.3/0.55 smiling eyes "a little less strong").
	"glad": {"sculpt":{"eye_smile_L":0.22, "eye_smile_R":0.22, "cheek_raise_L":0.42, "cheek_raise_R":0.42}, "iris_shape":[1.04, 1.02], "iris_drop":0.02, "shine_drop":0, "pupil":1.05},
	"happy": {"sculpt":{"eye_smile_L":0.1, "eye_smile_R":0.1, "cheek_raise_L":0.25, "cheek_raise_R":0.25}, "iris_shape":[1.04, 1.02], "iris_drop":0.02, "shine_drop":0, "pupil":1.05},
	"ooo": {"sculpt":{"eye_wide_L":0.35, "eye_wide_R":0.35}, "iris_shape":[0.64, 0.7], "iris_drop":0.02, "shine_drop":0, "pupil":0.7},
}
const MOUTH_POSES := {
	"frown": {"frown_big":0.9},
	"neutral": {"smile":0},
	"closed_smile": {"smile":1},
	# The resting face is already the full closed smile, so happy faces widen it.
	"grin": {"smile":1, "smile_big":0.45},
	"big_grin": {"smile":1, "smile_big":0.85},
	"amused": {"smile":1, "smirk":0.5},
	"smirk": {"smirk":1},
	"teeth": {"yikes":1},
	"pain": {"yikes":0.75, "frown_big":0.25},
	"ooo": {"round":1.0},
	"tongue_smile": {"open_lips":0.7, "tongue":1.0, "smile":0.65},
}
const LINE_FACES := {
	"neutral": {"mouth":{}, "lids":0},
	"happy": {"mouth":MOUTH_POSES.grin, "eye_pose":EYE_POSES.happy, "ears":"ears_alert", "ear_weight":0.6},
	"delighted": {"mouth":MOUTH_POSES.big_grin, "eye_pose":EYE_POSES.delighted, "eye_settle":EYE_POSES.glad, "blush":0.25, "ears":"ears_alert", "ear_weight":0.7},
	"silly": {"mouth":MOUTH_POSES.tongue_smile, "eye_pose":EYE_POSES.delighted, "eye_settle":EYE_POSES.warm, "blush":0.65, "ears":"ears_alert", "ear_weight":0.55},
	"amused": {"mouth":MOUTH_POSES.amused, "eye_pose":EYE_POSES.crooked, "eye_strength":0.75, "ears":"ears_side", "ear_weight":0.2},
	"crookedsmile": {"mouth":MOUTH_POSES.smirk, "eye_pose":EYE_POSES.crooked, "ears":"ears_alert", "ear_weight":0.4},
	"relaxed": {"mouth":{"smile":0.65}, "eye_pose":EYE_POSES.country, "ears":"ears_side", "ear_weight":0.33},
	"shy": {"mouth":{"smile":0.3}, "eye_pose":EYE_POSES.shy, "blush":0.85, "ears":"ears_side", "ear_weight":0.52},
	"sad": {"mouth":MOUTH_POSES.frown, "eye_pose":EYE_POSES.sad, "ears":"ears_side", "ear_weight":0.7},
	"annoyed": {"mouth":MOUTH_POSES.frown, "eye_pose":EYE_POSES.squeezed, "brows":"brows_angry", "weight":0.45},
	"angersmug": {"mouth":MOUTH_POSES.smirk, "eye_pose":EYE_POSES.confident, "ears":"ears_alert", "ear_weight":0.25},
	"suspicious": {"mouth":MOUTH_POSES.neutral, "eye_pose":EYE_POSES.suspicious, "ears":"ears_side", "ear_weight":0.28},
	"angry": {"mouth":{"frown_big":1}, "eye_pose":EYE_POSES.angry, "brows":"brows_angry", "weight":0.6, "ears":"ears_agitated", "ear_weight":0.6, "brace":0.75},
	"ponyrage": {"mouth":MOUTH_POSES.teeth, "eye_pose":EYE_POSES.rage, "brows":"brows_angry", "weight":0.8, "ears":"ears_agitated", "ear_weight":0.9, "brace":1.0},
	"fearful": {"mouth":{"yikes":0.9}, "eye_pose":EYE_POSES.fear, "brows":"brows_wide", "weight":0.55, "ears":"ears_side", "ear_weight":0.85},
	"disgusted": {"mouth":{"yikes":0.8, "frown_big":0.15}, "eye_pose":EYE_POSES.disgust, "brows":"brows_confused_left", "weight":0.4, "ears":"ears_side", "ear_weight":0.6},
	"surprised": {"mouth":{"open_soft":0.25}, "eye_pose":EYE_POSES.wide, "brows":"brows_wide", "weight":0.8, "ears":"ears_alert", "ear_weight":1},
	"confused": {"mouth":{"frown_big":0.35}, "eye_pose":EYE_POSES.confused, "brows":"brows_confused_left", "weight":0.7, "ears":"ears_alert", "ear_weight":0.35},
	"ooo": {"mouth":MOUTH_POSES.ooo, "eye_pose":EYE_POSES.ooo, "ears":"ears_alert", "ear_weight":0.75},
	"anticipation": {"mouth":MOUTH_POSES.closed_smile, "eye_pose":EYE_POSES.anticipation, "hearts":1, "blush":1, "ears":"ears_side", "ear_weight":0.4},
	"affectionate": {"mouth":{"smile":0.8}, "eye_pose":EYE_POSES.affectionate, "hearts":1, "blush":1, "ears":"ears_side", "ear_weight":0.5},
	"pain": {"mouth":MOUTH_POSES.pain, "eye_pose":EYE_POSES.delighted, "brows":"brows_sad", "weight":1, "ears":"ears_agitated", "ear_weight":0.9},
}
