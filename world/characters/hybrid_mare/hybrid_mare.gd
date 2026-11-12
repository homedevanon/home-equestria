extends "res://world/characters/locomotion/pony_locomotion.gd"
## The hybrid mare: native body and locomotion (this class) wearing the OpenPony head.
##
## Body: world/characters/hybrid_mare/body.glb, the native mare with her head cut at the neck and
## a bell-shaped neck lofted up to the OpenPony head rim (tools/fit_bell_hybrid_neck.py in Blender,
## tools/merge_hybrid_body.py for the GLB). Head: the untouched OpenPony export through
## OpenPonyMare (materials, mouth, lip-sync, eyes), body meshes hidden, placed at the fitted rest
## offset and linked bone-to-bone by HybridNeckLink.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const HEAD_SCENE := preload("res://world/characters/openpony/openpony_mare.tscn")
const NECK_LINK := preload("res://world/characters/hybrid_mare/hybrid_neck_link.gd")
const OUTLINE_EXCLUSION := preload("res://world/post_outline_exclusion.gd")
const EYE_MOTION := preload("res://world/characters/openpony/openpony_eye_motion.gd")
const SNOUT_DETAIL := preload("res://world/characters/hybrid_mare/snout_detail.gd")
const CACHED_LASHES := "res://world/characters/openpony/lashes_cached.png"
const LASH_STYLES := preload("res://world/characters/hybrid_mare/lash_styles.gd")
const IDENTITY := preload("res://world/characters/hybrid_mare/pony_identity.gd")
const STALLION_BODY := preload("res://world/characters/hybrid_mare/stallion_body.glb")
## Offline torso variants. Keep native exports for gait references and reversible art review.
const BODY_SHAPES := {
	"res://world/characters/hybrid_mare/body.glb": "res://world/characters/body_shapes/mare.scn",
	"res://world/characters/hybrid_mare/stallion_body.glb": "res://world/characters/body_shapes/stallion.scn",
}
const HAIR_LINK := preload("res://world/characters/hybrid_mare/hybrid_hair_link.gd")
const TAIL_MOTION := preload("res://world/characters/hybrid_mare/hybrid_tail_motion.gd")
const EXPRESSIONS := preload("res://world/characters/hybrid_mare/hybrid_expressions.gd")
const ATTENTION := preload("res://world/characters/hybrid_mare/hybrid_attention.gd")
const IDLE_TWITCHES := preload("res://world/life/idle/pony_idle_twitches.gd")
const IDLE_BODY := preload("res://world/life/idle/pony_idle_body.gd")
const BOOP := preload("res://world/characters/hybrid_mare/hybrid_boop.gd")
const TOUCH_BODY := preload("res://world/characters/hybrid_mare/pony_touch_body.gd")
const FAR_MESH := preload("res://world/characters/hybrid_mare/hybrid_far_mesh.gd")
const IMPOSTORS := preload("res://world/characters/hybrid_mare/pony_impostors.gd")
const NEAR_MESH := preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd")
const PINKIE_BOUNCE := preload("res://world/characters/hybrid_mare/pinkie_bounce.gd")
const EXPRESSION_STANCE := preload("res://world/characters/hybrid_mare/expression_stance.gd")
var expression_stance := EXPRESSION_STANCE.new()
## Only Pinkie allocates this optional travel style; every other mare keeps the same gait path.
var pinkie_bounce: RefCounted
## OpenPony model root relative to the native model root, rest to rest. Blender fit translation
## (0, -0.1302, -0.1105) in Z-up becomes (0, -0.1105, +0.1302) in Godot.
@export var head_offset := Vector3(0.0, -0.1105, 0.1302)
## Fillies (dev 2026-09-23): the adult rig at filly proportions, per a tip from the thread:
## overall 0.62 (on top of the pony size setting), neck 0.9 and an intact 1.4× head,
## and legs 10 % thicker at the same length (body_shapes/filly.scn, tools/body_shape/build_filly.gd).
const FILLY_SCALE := 0.62
const FILLY_BODY := "res://world/characters/body_shapes/filly.scn"
## The original face and rig stay unchanged; the body neck is fitted to their enlarged rim.
const FILLY_FIT := preload("res://world/characters/hybrid_mare/filly_fit.gd")
const FILLY_PUPIL_SCALE := 1.25
## Every pony's pupils 20% bigger (dev 2026-10-23), on top of the filly and reference-face scales.
const PUPIL_SCALE := 1.2
const REFERENCE_FACE := preload("res://world/characters/openpony/reference_face.gd")
@export var reference_face_enabled := false
var reference_face: SkeletonModifier3D
const FILLY_PROPORTIONS := preload("res://world/characters/hybrid_mare/filly_proportions.gd")

func set_body_scale(scale_factor: float) -> void:
	super.set_body_scale(scale_factor * (FILLY_SCALE if identity != null and identity.filly else 1.0))

## Offline proportion fits move the complete native face rig as one frame.
@export var head_scale := Vector3.ONE
## Shared posed head width; 1.0 restores the baseline for visual A/B checks.
@export var head_width_factor := 0.92
## Tail fit in the hybrid pivot's coordinates: seat its base on the upper rump.
## The mane retains the head fit; the tail follows this separate pelvis offset.
@export var tail_mount_offset := Vector3(0.0, 0.075, -0.025)
## OpenPony meshes that the native body replaces (the horn is shown again for unicorns).
const HIDDEN_HEAD_MESHES := ["Torso", "Pelvis", "Left Front Leg", "Right Front Leg", "Left Back Leg",
	"Right Back Leg", "Tail", "Tail Base and LOD", "Wings Pegasus", "Cutie Mark", "Unicorn Horn"]
const SHADED_HEAD_MESHES := ["Head", "Ears1", "InnerMouth", "Teeth", "Tongue", "Unicorn Horn"]
## The teeth's shade band: a warm off-white for every coat.
const TEETH_SHADE := Color(0.88, 0.87, 0.84)
## The Head's Lip surfaces (the lip lining that curls into the mouth). Their hull, grown the full
## outline width along the lining's up/down normals, crossed every open speech mouth as a stray
## ink line and put spurs past the corners (viseme review round 2), but closed it draws the
## resting lip seam. So it keeps its width at rest and drops to 0 while speech parts the lips
## (PonyMouth.lip_open_changed); the approved faces are drawn as before.
var _lip_hulls: Array[ShaderMaterial] = []
var _lip_open := false
## [Lip material, the same side's Snout material] pairs: PonyMouth.lip_tone_changed lights the lip
## colour toward the snout's for the pursed "oo" (viseme review round 3); 0 restores it.
var _lip_tones: Array = []
var _lip_tone := 0.0
## Native body nodes that only pegasi wear, and the cutie mark patches (Godot imports the
## ".L/.R" suffixes as "_L/_R", so match on the prefix).
const WING_PREFIX := "wing folded"
const MARK_PREFIX := "Cutie mark"
## OpenPony's devkit head occlusion bake (Left_Head_Mixed_AO), the head's counterpart of BODY_AO.
const HEAD_AO := preload("res://world/characters/openpony/native/body_ao.png")
## Coat colour the head must match; identity.coat_fill when an identity is set.
@export var head_coat := COAT_FILL
## Whose head she watches (the player's camera). Left empty, the navigator's attention target
## or the viewport's current camera is used, so the lab, desktop and XR rigs all work.
@export var attention_target: Node3D
## Which AI persona speaks through her (world/ai/characters/*.json).
@export var ai_profile := "res://world/ai/characters/rainbow_dash.json"
## Re-emitted from the OpenPony head when a spoken line ends.
signal speech_finished
signal speech_started
signal speech_failed(message:String)
signal physical_reaction(kind:String)

var _adult_head_transform := Transform3D.IDENTITY
var head: Node3D
var _head_model: Node
var neck_link: HybridNeckLink
var eye_motion: SkeletonModifier3D
var hair: Node3D
var hair_skeleton: Skeleton3D
var hair_link: Node
var tail_motion: SkeletonModifier3D
var expressions: RefCounted
var attention: RefCounted
## Ear flicks and tail swishes while she stands or rests quietly (world/life/idle/).
var idle_twitches: RefCounted = IDLE_TWITCHES.new()
## Breath and weight shifts over the NEAR tier's frozen stand clip (world/life/idle/).
var idle_body: IDLE_BODY
var conversation_target: Node3D
var action_gaze_target: Node3D
## Eased eye point while a boop finger comes in; BOOP_EYE_EASE is its time constant (s).
var _boop_eye := Vector3.INF
const BOOP_EYE_EASE := .16
var _action_gaze_point: Node3D
var _conversation_gaze_point: Node3D
var boop_node: Node
var touch_body: Node3D
var excitement: Node
var magic: Node3D
const UNICORN_MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
## Asleep (night rest): eyes shut, head down, no attention; talking to her wakes her face only.
var sleep_style := "head_down"
## Seconds a boop in her sleep keeps her eyes shut even if a reaction starts talking.
const BOOP_ASLEEP_SECONDS := 4.0
var _boop_asleep := 0.0
var sleeping := false:
	set(value):
		sleeping = value
		if not value and expressions != null: expressions.release_touch("sleep")
		if not value and _snore != null: _snore.visible = false

var _snore: Label3D
var _snore_time := 0.0
## Six ponies in town: beyond `hair_lod_distance` the decimated devkit hair (…LOD1 nodes) is
## shown; beyond `far_distance` eyes/attention/expressions idle (blinks stay). Lashes and
## brows stop drawing past `detail_range`.
@export var hair_lod_distance := 12.0
@export var far_distance := 15.0
@export var detail_range := 25.0
var _far := false
var _hair_lod := false
## Zero asks for a distance pass on the next frame (wakes _process). Between passes _process is
## off unless a picture animates or a mesh is being built; a Timer sets this every 0.25 s
## (2026-10-23 CPU pass: 44 ponies x every frame for a quarter-second check).
var _lod_timer := 0.0:
	set(value):
		_lod_timer = value
		if value <= 0.0: set_process(true)
## Render detail by camera distance (0.25 s cadence), independent of the solver tier. dev
## 2026-09-17: throw away what the eye cannot see, like an image codec.
## - The show outline (the hull next_pass, screen-constant width via `distance_scale`) draws
##   at every distance and on the far mesh: dev 2026-09-18, dropping it past six metres made
##   the near/far switch obvious ("you can literally see their eyes aren't there"). Inside
##   `ink_distance` the world-ink mask passes are added too (base, hull, mask, mask hull) so the
##   desktop post-process outline does not double her lines; beyond it two passes per surface.
## - Beyond `shadow_proxy_distance` one merged shadows-only mesh (the far mesh's surfaces in
##   one, hybrid_far_mesh.gd) casts instead of the rigs' 52 surfaces per cascade. Head and hair
##   ride their body bones rigidly in it, which is what the links do anyway.
@export var ink_distance := 6.0
@export var shadow_proxy_distance := 3.0
var _ink := true
var shadow_proxy: MeshInstance3D
var _shadow_proxy := false
var _shadow_proxy_waiting := false
## FAR render LOD: the merged single-skeleton mesh (hybrid_far_mesh.gd) replaces the three
## rigs' meshes; the head/hair links pause while it shows. `far_mesh_enabled` is the A/B switch.
@export var far_mesh_enabled := true
var far_mesh: MeshInstance3D
## The far mesh's eye surfaces (iris, brows, lashes): drawn like the rig's eyes, no ink mask.
var far_eyes: MeshInstance3D
var _far_mesh_shown := false
var _far_mesh_waiting := false:
	set(value):
		_far_mesh_waiting = value
		if value: set_process(true)
## Beyond pony_impostors.distance() a FAR pony shows one camera-facing quad instead of her far
## mesh, alternating its stand and mid-stride frames while she moves (pony_impostors.gd).
var impostor: MeshInstance3D
var _impostor_shown := false
var _impostor_clock := 0.0
var _impostor_pose := 0
## NEAR render (HERO and NEAR tiers): the rig meshes merged per skeleton at full detail
## (hybrid_near_mesh.gd, 2026-09-25): ~9 visible meshes and ~13 surfaces instead of ~15.5 and
## ~33 (Mane Six average), same look (tools/profile/near_mesh_parity.gd).
## The rig meshes stay, hidden, as the fallback. `near_mesh_enabled` (or `--near-mesh off` on
## the command line) is the A/B switch; `set_near_mesh` toggles it live.
@export var near_mesh_enabled := true
var _near: Dictionary = {}
var _near_waiting := true:
	set(value):
		_near_waiting = value
		if value: set_process(true)
## Hidden rig meshes are not free: parking them measured 1.5-4 ms for 47 walking NEAR ponies
## (tools/profile/skin_bench.gd, noisy; nothing measurable on a FAR crowd).
## A rig mesh that is not visible in the tree lets go of its skeleton and takes it back the moment
## it shows (visibility_changed). Covers the never-shown OpenPony body parts, the rig meshes behind
## the near mesh and the whole rig behind the far mesh. `--park-hidden off` or `set_rig_parking`.
@export var park_hidden_rig_meshes := "--park-hidden" not in preload("res://world/dev_tools.gd").user_args()
## unicorn_magic.gd reads the horn's skeleton path at its first cast; it keeps its skeleton.
const KEEP_SKELETON := ["Unicorn Horn"]
const PARKED := &"parked_skeleton"
var _flank: Node
var _rig_watched: Array[MeshInstance3D] = []


func _ready() -> void:
	if identity != null and identity.stallion:
		model_scene = STALLION_BODY
	if identity != null and identity.filly and not identity.stallion and ResourceLoader.exists(FILLY_BODY):
		model_scene = load(FILLY_BODY)
	elif model_scene.resource_path in BODY_SHAPES:
		model_scene = load(BODY_SHAPES[model_scene.resource_path])
	super._ready()
	if skeleton == null or pivot == null:
		return
	expression_stance.pony = self
	var lod_clock := Timer.new(); lod_clock.name = "LodClock"; lod_clock.wait_time = 0.25
	lod_clock.timeout.connect(func() -> void: _lod_timer = 0.0)
	add_child(lod_clock)
	lod_clock.start(randf_range(0.02, 0.25))   # spread the ponies' passes over the quarter second
	lod_clock.timeout.connect(func() -> void: lod_clock.wait_time = 0.25, CONNECT_ONE_SHOT)
	# After ClipHead, before the proportions: the NEAR stand's breath and weight (off until wanted).
	idle_body = IDLE_BODY.new()
	idle_body.name = "IdleBody"
	idle_body.pony = self
	idle_body.active = false
	skeleton.add_child(idle_body)
	idle_body.bind(skeleton)
	if not is_equal_approx(head_width_factor, 1.0) or (identity != null and (identity.filly or not is_equal_approx(identity.wing_scale, 1.0))):
		# After the locomotion/posture modifiers: neck/head/wing proportions on the posed rig.
		var proportions := FILLY_PROPORTIONS.new(); proportions.name = "FillyProportions"
		proportions.neck_scale = 0.9 if identity != null and identity.filly else 1.0
		proportions.head_width = head_width_factor
		if identity != null: proportions.wing_scale = identity.wing_scale
		skeleton.add_child(proportions)
	if identity != null and identity.filly:
		set_body_scale(1.0)
	if identity == null:
		identity = IDENTITY.new()
	if ai_profile == "res://world/ai/characters/rainbow_dash.json" and identity.ai_profile != "":
		ai_profile = identity.ai_profile
	head = HEAD_SCENE.instantiate()
	head.name = "OpenPonyHead"
	if identity.stallion: head.model_path = "res://world/characters/openpony/openpony_stallion.glb"
	if reference_face_enabled:
		head.model_path = "res://world/characters/openpony/reference_%s.scn" % ("stallion" if identity.stallion else "mare")
		head.reference_eyes = true
	head.coat_color = identity.coat_fill
	head.line_color = identity.coat_line
	head.iris_color = identity.iris_color
	if identity.filly:
		head.pupil_scale = FILLY_PUPIL_SCALE; head.third_shine = true
	if reference_face_enabled: head.pupil_scale = 1.12 if identity.filly else 1.07
	head.pupil_scale *= PUPIL_SCALE
	pivot.add_child(head)
	var model_root: Node3D = skeleton.owner if skeleton.owner is Node3D else pivot.get_child(0)
	_adult_head_transform = model_root.transform * Transform3D(Basis.from_scale(head_scale), head_offset)
	head.transform = _adult_head_transform * (FILLY_FIT.head_frame() if identity.filly else Transform3D.IDENTITY)
	var head_model: Node = head.get("model")
	for node in head_model.find_children("*", "MeshInstance3D", true, false):
		if String(node.name) in HIDDEN_HEAD_MESHES:
			(node as MeshInstance3D).visible = false
		if node.name == "Unicorn Horn":
			(node as MeshInstance3D).visible = identity.has_horn()
			if identity.has_horn() and magic == null:
				magic = UNICORN_MAGIC.new()
				magic.name = "UnicornMagic"
				add_child(magic)
				magic.setup(node, UNICORN_MAGIC.color_for(identity))
	_dress_body_for_race()
	var head_skeleton: Skeleton3D = head.get("skeleton")
	if head_skeleton == null:
		push_error("Hybrid mare: OpenPony head has no skeleton")
		return
	head_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	neck_link = NECK_LINK.new()
	neck_link.name = "HybridNeckLink"
	add_child(neck_link)
	if not neck_link.link(skeleton, head_skeleton):
		push_error("Hybrid mare: neck link failed")
	eye_motion = EYE_MOTION.new()
	eye_motion.name = "NativeEyeMotion"
	head_skeleton.add_child(eye_motion)
	eye_motion.bind(head.player)
	eye_motion.surface_update = head.update_show_eyes
	if reference_face_enabled:
		reference_face = REFERENCE_FACE.new()
		reference_face.name = "ReferenceFace"
		head_skeleton.add_child(reference_face)
		reference_face.bind(head_model, head_skeleton)
	expressions = EXPRESSIONS.new()
	expressions.bind(head.mouth, eye_motion)
	if head.show_eyes_enabled: expressions.show_head = head
	expressions.rest_smile = identity.rest_smile
	expressions.interest_smile = identity.interest_smile
	if reference_face_enabled or head.show_eyes_enabled:
		expressions.interest_lids = 0.0
		expressions.idle_lids_enabled = false
	attention = ATTENTION.new()
	attention.notice_distance = identity.notice_distance
	attention.close_distance = identity.close_distance
	boop_node = BOOP.new()
	boop_node.name = "HybridBoop"
	boop_node.blush_color = identity.blush_color
	boop_node.heart_colors = identity.heart_colors
	add_child(boop_node)
	boop_node.setup(self, head_skeleton)
	# Hand-only collision over the rest of her body, and petting (pony_touch_body.gd).
	touch_body = TOUCH_BODY.new()
	touch_body.setup(self)
	add_child(touch_body)
	# Excitement while kissed or scratched, and on her AI's [excited]/[wings:...] tags: wings
	# spread, a horn sparks, an earth pony kicks a hind hoof and raises a forehoof.
	excitement = preload("res://world/characters/hybrid_mare/excitement.gd").new()
	excitement.name = "Excitement"; excitement.setup(self); add_child(excitement)
	if head.has_signal("speech_finished"):
		head.speech_finished.connect(func(): speech_finished.emit())
		head.speech_started.connect(func(): speech_started.emit())
		head.speech_failed.connect(func(why:String):speech_failed.emit(why))
	add_to_group("ai_characters")
	_dress_lashes(head_model)
	_restore_eyebrows(head_model)
	# LOD simplification independently collapses the closely layered cards.
	# Keep the authored facial tessellation (21,432 triangles including head).
	for node in head_model.find_children("*", "MeshInstance3D", true, false):
		if node.name == "Head":
			SNOUT_DETAIL.prepare(node)
		elif String(node.name) in ["Eye", "Pupil", "Pupil_001", "Pupil.001", "Eyelashes", "Eyebrows"]:
			_remove_face_lods(node)
	_head_model = head_model
	if preserve_model_materials and show_shading:
		_dress_head()
	_attach_devkit_hair()
	preload("res://world/characters/hybrid_mare/hybrid_dock.gd").apply(self)
	var flank:=preload("res://world/characters/hybrid_mare/pony_flank_touch.gd").new()
	flank.name="FlankTouch";add_child(flank);flank.setup(self)
	_flank = flank
	_exclude_world_ink()
	if identity.character() == "pinkie_pie":
		pinkie_bounce = PINKIE_BOUNCE.new()
		pinkie_bounce.bind(self)
	# Lashes and brows draw at every distance (dev 2026-09-18): a mare whose eyes vanish at
	# `detail_range` reads as a different model, and two alpha cards cost nothing.


## Coat and mouth only: the eye cards, lashes and brows keep OpenPonyMare's materials
## (a cel outline pass around an alpha-scissor lash card draws a black mask).
func _dress_head() -> void:
	var lips: Array[ShaderMaterial] = []
	var tone := _lip_tone
	set_lip_tone(0.0)  # the old materials get their lip colour back; the new ones take `tone` below
	_lip_tone = tone
	var tones: Array = []
	for node in _head_model.find_children("*", "MeshInstance3D", true, false):
		if String(node.name) in SHADED_HEAD_MESHES:
			if node.name == "Head": SNOUT_DETAIL.prepare(node)
			_apply_show_shading(node)
			if String(node.name) in ["InnerMouth", "Teeth", "Tongue"]:
				# Interior parts keep their real geometry and material colors. A
				# coat-colored hull around every internal edge obscures open mouths.
				for surface in node.mesh.get_surface_count():
					var interior := node.get_active_material(surface) as ShaderMaterial
					if interior != null: interior.next_pass = null
					# Teeth read off-white in their shade band, not tinted by the coat's shade
					# ratio (viseme review round 2: grey-pink/green/lavender teeth in "ss").
					if interior != null and node.name == "Teeth": interior.set_shader_parameter("shadow_color", TEETH_SHADE)
			if node.name == "Head":
				for surface in node.mesh.get_surface_count():
					var source: Material = node.mesh.surface_get_material(surface)
					var material := node.get_active_material(surface) as ShaderMaterial
					if source != null and source.resource_name.ends_with(" Lip") and material != null:
						var lip_hull := material.next_pass as ShaderMaterial
						if lip_hull != null: lips.append(lip_hull)
						var side := source.resource_name.trim_suffix(" Lip")
						for other in node.mesh.get_surface_count():
							var twin: Material = node.mesh.surface_get_material(other)
							var snout := node.get_active_material(other) as ShaderMaterial
							if twin != null and twin.resource_name == side + " Snout" and snout != null: tones.append([material, snout])
					if source != null and source.resource_name.ends_with(" Head") and material != null:
						var hull := material.next_pass as ShaderMaterial
						if hull != null: hull.set_shader_parameter("native_eye_socket_mask", true)
			if node.name == "Head" and not reference_face_enabled: SNOUT_DETAIL.dress(node)
	_lip_hulls = lips
	_lip_tones = tones
	var mouth: Variant = head.get("mouth")
	if mouth is PonyMouth:
		(mouth as PonyMouth).lip_open_changed = set_lip_hull_open
		(mouth as PonyMouth).lip_tone_changed = set_lip_tone
	if _lip_open: set_lip_hull_open(true)
	if _lip_tone > 0.0: set_lip_tone(_lip_tone)
	if head.face_sculpt != null:
		# MLP Vector Club: black at 5–15% over coat for expressive lids, or the
		# identity's explicit eyeshadow (Rarity, Luna, Maud, etc.).
		var lid_color: Color = identity.eyeshadow()
		var makeup := lid_color.a > 0.0
		head.face_sculpt.set_lid_color(lid_color if makeup else Color(0,0,0,.12), makeup)
		head.face_sculpt.set_freckles(identity.freckle_color)


func _redress() -> void:
	# The merged meshes carry materials built from the rig's; rebuild them after the re-dress.
	_near_detach()
	super._redress()
	if _head_model != null:
		_dress_head()
		if hair != null: _apply_show_shading(hair)
		_exclude_world_ink()
	# Fresh materials wear masks again; the next distance pass strips them where needed.
	_ink = true
	_lod_timer = 0.0
	_near_waiting = true


func _exclude_world_ink() -> void:
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not mi.is_visible_in_tree() or mi.mesh == null:
			continue
		# Merged near meshes whose rig meshes wore the mask (their hull is near_pony_outline).
		if mi.has_meta(NEAR_MESH.INK):
			OUTLINE_EXCLUSION.apply_to(mi, outline_width)
			continue
		# Alpha-bordered cards/decals are covered by the solid head/body beneath
		# them. Masking the entire card would also hide ink in its empty corners.
		var mat := mi.get_active_material(0) as ShaderMaterial
		if mat != null and mat.next_pass != null:
			var hull := mat.next_pass as ShaderMaterial
			if hull != null and hull.shader in [OUTLINE_LIT, OUTLINE_TINTED]:
				OUTLINE_EXCLUSION.apply_to(mi, outline_width)


## dev 2026-11-08 ("the head's colours are darker than the body's ... at the neck"): the body coat has no
## occlusion bake (plain cel bands), so the head's devkit bake (AO, 85% of direct light too) made the
## whole head darker than the neck it joins. The head keeps the occlusion shader (its snout detail
## lives there) with a white map, so head and body shade alike. Rollback: HEAD_COAT_AO = true.
const HEAD_COAT_AO := false
static var _no_ao: ImageTexture


func _coat_ao(mi: MeshInstance3D) -> Texture2D:
	if mi.name != "Head": return null
	if HEAD_COAT_AO: return HEAD_AO
	if _no_ao == null:
		var white := Image.create(1, 1, false, Image.FORMAT_L8); white.fill(Color.WHITE)
		_no_ao = ImageTexture.create_from_image(white)
	return _no_ao


## The impostor's stand/stride flip-book on the physics tick instead of every rendered frame
## (0.1.0 perf pass): its frames last 0.08-0.3 s, so a 1/60 s step cannot be seen, and a FAR
## crowd of pictures no longer keeps _process running every frame (16 ponies x ~2 us per frame).
## Rollback: IMPOSTOR_ON_PHYSICS = false (animated in _process as before).
const IMPOSTOR_ON_PHYSICS := true

func _unprofiled_process(delta: float) -> void:
	var animate := _impostor_shown and not IMPOSTOR_ON_PHYSICS
	if animate: _animate_impostor(delta)
	if _far_mesh_waiting:
		_poll_far_mesh()
	if _near_waiting:
		_poll_near_mesh()
	if park_hidden_rig_meshes and _rig_watched.is_empty() and _tick >= 3:
		set_rig_parking(true)
	if _lod_timer > 0.0:
		if not (animate or _far_mesh_waiting or _near_waiting): set_process(false)
		return
	_lod_timer = 0.25
	if not (animate or _far_mesh_waiting or _near_waiting): set_process(false)
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null: return
	var distance := global_position.distance_to(camera.global_position)
	var was_far: bool = _far
	_far = distance > far_distance or sim_tier == SimTier.FAR
	if _far != was_far: _wake_contact_ticks()
	_update_impostor(distance)
	if sim_tier != SimTier.FAR:
		_set_ink(distance <= ink_distance)
		_set_shadow_proxy(distance > shadow_proxy_distance)
	elif _shadow_proxy_waiting:
		_set_shadow_proxy(true)
	var lod := distance > hair_lod_distance
	if lod != _hair_lod:
		_hair_lod = lod
		_apply_hair_lod()


## Full hair near, the decimated …LOD1 nodes far (only where the GLB carries them).
func _apply_hair_lod() -> void:
	if hair == null: return
	NEAR_MESH.set_lod(_near, _hair_lod)
	for mi in hair.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta(NEAR_MESH.HIDDEN): continue  # merged: the near mesh swaps its own LOD
		var n := String(mi.name)
		if not n.begins_with(identity.hair_prefix + "Devkit"): continue
		var is_lod := n.ends_with("LOD1")
		var has_lod: bool = hair.find_child(n + "LOD1", true, false) != null if not is_lod else true
		if is_lod:
			mi.visible = _hair_lod
		elif has_lod:
			mi.visible = not _hair_lod


## A freed pony's meshes own their materials, and the engine frees each material before
## the instance that draws it. If that instance still has a pending render update (a material
## changed this frame), the update reads the freed material ('Parameter "material" is null').
## Dropping the meshes first ends those updates.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE: return
	for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		mi.mesh = null

## Physics time the clip tier's face logic has skipped since its last 20 Hz logic tick.
var _face_delta := 0.0
var _carry_reaction := preload("res://world/characters/locomotion/carry_reaction.gd").new()

func _physics_process(delta: float) -> void:
	if _impostor_shown and IMPOSTOR_ON_PHYSICS: _animate_impostor(delta)
	if not CROWD_PROFILE.enabled:
		_hybrid_physics(delta)
		return
	var started := Time.get_ticks_usec()
	_hybrid_physics(delta)
	CROWD_PROFILE.record("hybrid_physics_tier%d" % sim_tier, started)

func _hybrid_physics(delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	# Not held and already reset, update() would only reset it again.
	if _held or _carry_reaction.active: _carry_reaction.update(self, delta)
	if pinkie_bounce != null: pinkie_bounce.advance(delta)
	# The stance is HERO only: on the clip tiers advance() would only keep a zero amount at zero.
	if sim_tier == SimTier.HERO or expression_stance.amount > 0.0: expression_stance.advance(delta)
	super._physics_process(delta)
	# The face work below is the tier label minus this one.
	if started > 0: CROWD_PROFILE.record("hybrid_loco_total", started)
	if eye_motion == null or motion_paused or sim_tier == SimTier.FAR: return
	# Clip tiers: attention, expressions and eye timers on the pony's 20 Hz logic beat, which
	# the NEAR eye and mouth modifiers share (docs/CLIP_TIER_2026_09_25.md).
	_face_delta += delta
	if not is_logic_tick(): return
	delta = _face_delta
	_face_delta = 0.0
	_update_idle_body()
	if _rest_frozen:
		# A settled clip-tier sleep: the face is frozen with her skeletons; only the snore drifts.
		if sleeping: _update_snore(delta)
		return
	_update_contact_rules()
	eye_motion.advance(delta)
	var conversing: bool = is_instance_valid(conversation_target) or is_instance_valid(action_gaze_target) or head.is_speaking()
	_keep_partner_in_view(delta)
	if _far and not _held and not conversing and not (pinkie_bounce != null and pinkie_bounce.active()):
		# Out of sight of the player: blinks only, no attention or expression work.
		eye_motion.target_weight = 0.0
		# Except a sleeper's shut eyes: one who fell asleep out here slept with them open, and a
		# settled sleep freezes her face as it is until Anon walks up (player report 2026-10-28).
		if sleeping:
			expressions.touch("sleep", 0.0, 1.0)
			expressions.advance(delta, true)
		return
	var resting: bool = velocity.length() < 0.12 and not head.is_speaking()
	# Held: the carry pose owns her head and eyes; otherwise she watches the player when
	# they are near and fills quiet moments with small head looks.
	if is_instance_valid(action_gaze_target) and is_instance_valid(_action_gaze_point):
		_action_gaze_point.global_position = action_gaze_target.listen_point() if action_gaze_target.has_method("listen_point") else action_gaze_target.global_position
	if is_instance_valid(conversation_target) and is_instance_valid(_conversation_gaze_point):
		_conversation_gaze_point.global_position = conversation_target.listen_point() if conversation_target.has_method("listen_point") else conversation_target.global_position
	var listener := _conversation_gaze_point if is_instance_valid(conversation_target) else (_action_gaze_point if is_instance_valid(action_gaze_target) else _attention_target())
	var booping: bool = listener == _action_gaze_point and is_instance_valid(action_gaze_target) and action_gaze_target.has_meta("boop_finger")
	attention.min_distance = .015 if booping else .05
	attention.head_hold = (booping or boop_node.finger_near) and not _held
	attention.advance(delta, self, listener if conversing or not _held else null, resting, conversing)
	if hoof_hold.active() and hoof_hold.gesture_left <= 0.0:
		expressions.touch("hoof",.6,.42)
		if not has_meta("spa_client"): boop_node.sustain_blush()   # spa care never blushes
	else:expressions.release_touch("hoof")
	_boop_asleep = maxf(0.0, _boop_asleep - delta)
	# Booped in her sleep, her eyes stay shut even while a boop reaction plays (dev 2026-10-22).
	if sleeping and (not conversing or _boop_asleep > 0.0):
		expressions.touch("sleep", 0.0, 1.0)
		secondary.look_toward(Vector3.ZERO, 0.4)
		_update_snore(delta)
	elif sleeping:
		expressions.release_touch("sleep")
		if _snore != null: _snore.visible = false
	expressions.advance(delta, resting, attention.interest, head.is_speaking())
	# Standing or resting quietly: now and then an ear flick or a swish of the tail
	# (dev 2026-10-14: "completely still"). Never while held, carried, kissed or asleep.
	var quiet: bool = resting and not sleeping and not _held and not carry.active and not has_meta("affection_active") and is_in_group("sim_ponies")
	idle_twitches.advance(delta, self, quiet)
	boop_node.expression_blush = expressions.blush_weight
	boop_node.nose_blush = maxf(expressions.fluster_amount, expressions.blush_weight * .6)
	if expressions.fluster_amount > .05: boop_node.sustain_blush()
	_giggle_after_fluster(delta)
	# Briefly lead a turning head; once it settles, hold the fixation quietly.
	var residual: Vector3 = secondary.gaze_velocity * 0.05
	eye_motion.gaze = Vector2(residual.y, residual.x)
	# A booping finger coming to her nose (desktop_interactions.gd tags it): her eyes cross and drop onto
	# it, more the closer it gets (dev 2026-10-14).
	var cross := 0.0
	if is_instance_valid(action_gaze_target) and action_gaze_target.has_meta("boop_finger") and boop_node != null and boop_node.has_method("nose_world"):
		cross = 1.0 - smoothstep(.05, .30, action_gaze_target.global_position.distance_to(boop_node.nose_world()))
	eye_motion.cross_inward = .28 * cross
	if cross > 0.0: eye_motion.gaze.y -= 1.6 * cross
	if carry.active and not conversing:
		eye_motion.target_world = carry.look_target
		eye_motion.target_weight = carry.blend
	else:
		# A booping finger is followed smoothly, from where she was looking to the hand and in to
		# her nose (dev 2026-10-29: her eyes "instantly teleported" to it). Other looks unchanged.
		if booping and _boop_eye.is_finite(): _boop_eye = _boop_eye.lerp(attention.eye_target, 1.0 - exp(-delta / BOOP_EYE_EASE))
		else: _boop_eye = attention.eye_target
		eye_motion.target_world = _boop_eye
		eye_motion.target_weight = 0.0 if sleeping and not conversing else attention.interest

## A settled clip-tier sleep freezes the head and hair rigs with the body.
func _rest_skeletons() -> Array[Skeleton3D]:
	var rigs: Array[Skeleton3D] = [skeleton]
	var head_skeleton: Skeleton3D = head.get("skeleton") if head != null else null
	if head_skeleton != null: rigs.append(head_skeleton)
	if hair_skeleton != null: rigs.append(hair_skeleton)
	return rigs


## Back from a hidden spell with parked rigs (pony_locomotion.gd HIDDEN_RIG_PARK): the tail springs
## did not integrate meanwhile, so their remembered body velocity and rump turn are from before she
## was hidden. Read against her motion now, that gap would be one big acceleration and whip the tail
## on the first frame she is seen; start the springs' history afresh instead (as on their first
## step). The NEAR stand's body life catches up on the time it skipped (pony_idle_body.gd catch_up).
func _rigs_unparked() -> void:
	if tail_motion != null and tail_motion.has_method(&"reset_history"):
		tail_motion.reset_history()
	if idle_body != null:
		_update_idle_body()
		idle_body.catch_up()


## A slow "z Z z" drifting up from a sleeping pony.
func _update_snore(delta: float) -> void:
	if _snore == null:
		_snore = Label3D.new(); _snore.text = "z"; _snore.font_size = 64; _snore.pixel_size = .004
		_snore.billboard = BaseMaterial3D.BILLBOARD_ENABLED; _snore.outline_size = 10
		_snore.modulate = Color(.92, .95, 1.0); _snore.no_depth_test = false; add_child(_snore)
	_snore_time = fmod(_snore_time + delta, 3.0)
	var t := _snore_time / 3.0
	_snore.visible = true
	_snore.text = "z" if t < .33 else ("z Z" if t < .66 else "z Z z")
	_snore.global_position = listen_point() + Vector3.UP * (.25 + .3 * t) * body_scale
	_snore.modulate.a = sin(PI * t)


## Crowd tier (PonyCrowd): FAR parks the eyes, tail springs, attention and expressions and
## shows the merged far mesh. NEAR (clips) keeps everything the eye can see.
func set_sim_tier(tier: int, phase: int = 0) -> void:
	var before := sim_tier
	super.set_sim_tier(tier, phase)
	if sim_tier == before: return
	_wake_contact_ticks()
	var far := sim_tier == SimTier.FAR
	if eye_motion != null:
		eye_motion.active = not far
	if reference_face != null: reference_face.active = not far
	_set_face_rate(NEAR_DIVISOR if sim_tier == SimTier.NEAR else (detail_divisor if sim_tier == SimTier.HERO else 1), phase)
	if tail_motion != null: tail_motion.active = not far
	if idle_body != null and sim_tier != SimTier.NEAR:
		idle_body.wanted = false
		idle_body.fade = 0.0
		idle_body.active = false
	if far:
		_far = true
		_set_ink(false)
		_set_shadow_proxy(true)
		if far_mesh_enabled and _model != null:
			_far_mesh_waiting = true
			_poll_far_mesh()
	else:
		_far_mesh_waiting = false
		_set_impostor(false, {})
		_show_far_mesh(null, false)
		_near_waiting = true
		# The distance pass restores ink and own shadows where she now stands.
		_lod_timer = 0.0


## The NEAR stand's body life (pony_idle_body.gd): only on the frozen stand clip within 15 m, with
## nothing else holding her body; eased out before it switches off, so nothing pops.
func _update_idle_body() -> void:
	if idle_body == null: return
	idle_body.wanted = sim_tier == SimTier.NEAR and _clip_static and _clip_blend >= 1.0 and not _far \
		and (posture == null or not posture.active()) and not _held and not carry.active \
		and not has_meta("seated") and not has_meta("affection_active") and not motion_paused \
		and not has_meta(PonyCrowd.HIDDEN)
	if idle_body.wanted:
		if not idle_body.active: idle_body.active = true
	elif idle_body.active and idle_body.fade <= 0.0:
		idle_body.active = false


## Boop, touch and flank switch their own physics tick off while she is beyond hand reach with
## nothing to fade; a tier or distance change hands it back (each re-parks on its next tick if idle).
func _wake_contact_ticks() -> void:
	if is_instance_valid(boop_node): boop_node.wake_tick()
	if is_instance_valid(touch_body): touch_body.wake_tick()
	if is_instance_valid(_flank): _flank.wake_tick()


## Pinned HERO mares beyond PonyCrowd.hero_distance run eyes and mouth at the NEAR cadence.
func set_detail_divisor(divisor: int, phase: int = 0) -> void:
	var before := detail_divisor
	super.set_detail_divisor(divisor, phase)
	if detail_divisor != before and sim_tier == SimTier.HERO: _set_face_rate(detail_divisor, phase)


func _set_face_rate(divisor: int, phase: int) -> void:
	if eye_motion != null:
		eye_motion.rate_divisor = divisor
		eye_motion.rate_phase = phase
	if head != null and head.mouth != null:
		head.mouth.rate_divisor = divisor
		head.mouth.rate_phase = phase


## The far mesh is gathered from the live rigs, so the first pony of an identity to ask
## must have been linked and seated (a spawn-time gather bakes the unlinked head 15 cm low).
func _far_mesh_can_gather() -> bool:
	# The far mesh is cached per identity and bakes the pose she is in: never from a sit, lie or
	# sleep (postured ponies reach FAR since 2026-09-25), or every standing copy would lie flat.
	if posture != null and posture.active(): return false
	return _tick >= 3 and _clip_blend >= 1.0 and (sim_tier != SimTier.HERO or _initialized)


## The merged far mesh once it is built (worker thread); until then the stripped rig shows.
func _poll_far_mesh() -> void:
	if sim_tier != SimTier.FAR or not far_mesh_enabled:
		_far_mesh_waiting = false
		return
	# A cached mesh shows at once; a gather (first pony of the identity) waits for a settled pose.
	var mesh: ArrayMesh = FAR_MESH.cached(self)
	if mesh == null:
		if not _far_mesh_can_gather(): return
		mesh = FAR_MESH.request(self)
	if mesh == null:
		return
	_far_mesh_waiting = false
	_show_far_mesh(mesh, true)


func _show_far_mesh(mesh: ArrayMesh, show: bool) -> void:
	if show == _far_mesh_shown: return
	_far_mesh_shown = show
	if not show: _near_waiting = true
	if show:
		if far_mesh == null:
			far_mesh = MeshInstance3D.new()
			far_mesh.name = "FarMesh"
			var body_mesh: MeshInstance3D = _model.find_child("MareBody", true, false)
			skeleton.add_child(far_mesh)
			far_mesh.skin = body_mesh.skin
			far_mesh.skeleton = far_mesh.get_path_to(skeleton)
			far_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		far_mesh.mesh = mesh
		far_mesh.visible = not _impostor_shown
		# Its surfaces carry the hull pass; keep the desktop world ink off it like the rigs.
		OUTLINE_EXCLUSION.apply_to(far_mesh, outline_width)
		var eyes: ArrayMesh = FAR_MESH.eyes_cache.get(FAR_MESH._id(self))
		if eyes != null and eyes.get_surface_count() > 0:
			if far_eyes == null:
				far_eyes = MeshInstance3D.new()
				far_eyes.name = "FarEyes"
				skeleton.add_child(far_eyes)
				far_eyes.skin = far_mesh.skin
				far_eyes.skeleton = far_eyes.get_path_to(skeleton)
				far_eyes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			far_eyes.mesh = eyes
			# FAR collapses face bones onto pony_head; its cached brow pose cannot express
			# live asymmetry. Keep its ink absent instead of displaying a stale expression.
			if DisplayServer.get_name() != "headless": far_eyes.set_instance_shader_parameter("brow_amount", 0.0)
			far_eyes.visible = not _impostor_shown
	elif far_mesh != null:
		far_mesh.visible = false
		if far_eyes != null: far_eyes.visible = false
	# The three rigs' own meshes and the links that place the head and hair.
	for mi in _model.find_children("*", "MeshInstance3D", true, false):
		if mi == far_mesh or mi == far_eyes or mi == shadow_proxy: continue
		if show:
			if mi.visible: mi.set_meta(&"far_hidden", true); mi.visible = false
		elif mi.has_meta(&"far_hidden"):
			mi.remove_meta(&"far_hidden"); mi.visible = true
	if head != null: head.visible = not show
	# Nothing shows the hidden head's mouth; running, it rewrote the face rig every tick.
	if head != null and head.mouth != null: head.mouth.active = not show
	if hair != null: hair.visible = not show
	if neck_link != null: neck_link.enabled = not show
	if hair_link != null: hair_link.enabled = not show
	if not show and neck_link != null:
		# Re-seat the head and hair on the current pose right away.
		neck_link._on_source_updated()
		if hair_link != null:
			hair_link._body_updated()
			hair_link._head_updated()


## Impostor past the hand-over distance, only over a shown far mesh and nothing holding her.
func _update_impostor(distance: float) -> void:
	var from := IMPOSTORS.distance()
	var entry := {}
	var want := sim_tier == SimTier.FAR and _far_mesh_shown and from > 0.0 and distance > from and not _held
	if want:
		entry = IMPOSTORS.bank(get_tree()).atlas_for(self)
		want = not entry.is_empty()
	_set_impostor(want, entry)

func _set_impostor(show: bool, entry: Dictionary) -> void:
	if show == _impostor_shown: return
	_impostor_shown = show
	coarse_motion = show
	# The far mesh reads her skeleton again: bring the deferred clip pose up to date first.
	if not show: refresh_hidden_clip()
	if show:
		if impostor == null:
			impostor = MeshInstance3D.new()
			impostor.name = "Impostor"
			impostor.mesh = IMPOSTORS.quad()
			impostor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			impostor.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			add_child(impostor)
		impostor.material_override = entry.material
		impostor.visible = true
		_impostor_pose = 0
		impostor.set_instance_shader_parameter("pose", 0.0)
	elif impostor != null:
		impostor.visible = false
	if far_mesh != null: far_mesh.visible = _far_mesh_shown and not show
	if far_eyes != null and far_eyes.mesh != null: far_eyes.visible = _far_mesh_shown and not show

## Stand and mid-stride frames in turn, faster the faster she goes; standing still holds stand.
func _animate_impostor(delta: float) -> void:
	var speed: float = actual_speed / maxf(body_scale, 0.01)
	var pose := 0
	if speed > 0.1:
		_impostor_clock += delta
		var interval := clampf(0.1 / speed, 0.08, 0.3)
		pose = int(_impostor_clock / interval) % 2
	else:
		_impostor_clock = 0.0
	if pose != _impostor_pose:
		_impostor_pose = pose
		impostor.set_instance_shader_parameter("pose", float(pose))


## The merged near meshes once their geometry is built (worker thread, once per identity); until
## then, and in FAR, the rig meshes show.
func _poll_near_mesh() -> void:
	if not near_mesh_enabled or not NEAR_MESH.enabled or _model == null or not _near.is_empty():
		_near_waiting = false
		return
	if sim_tier == SimTier.FAR or _far_mesh_shown:
		# Nothing to attach while she is far: stop asking every frame (a pony that was FAR since
		# spawn kept _process on for the whole session). Leaving FAR and hiding the far mesh re-arm it.
		_near_waiting = false
		return
	if _tick < 3:
		return
	var plan: Variant = NEAR_MESH.request(self)
	if plan == null:
		return
	_near_waiting = false
	_near = NEAR_MESH.attach(self, plan, _hair_lod)
	if _lip_open: NEAR_MESH.set_lip_width(_near, 0.0)
	if _lip_tone > 0.0: NEAR_MESH.set_lip_tone(_near, _lip_tone)
	if not _rig_watched.is_empty():
		for mi in NEAR_MESH.instances(_near): _watch_rig_mesh(mi)  # hidden behind the far mesh
	if not _near.is_empty() and _ink:
		_exclude_world_ink()


## Speech parted (true) or closed (false) the lips: the lip-lining hull drops to 0 width / returns
## to the outline width, on the rig head and on the merged near mesh.
func set_lip_hull_open(open: bool) -> void:
	_lip_open = open
	for hull in _lip_hulls:
		if not hull.has_meta(&"lip_width"): hull.set_meta(&"lip_width", float(hull.get_shader_parameter("outline_width")))
		hull.set_shader_parameter("outline_width", 0.0 if open else float(hull.get_meta(&"lip_width")))
	NEAR_MESH.set_lip_width(_near, 0.0 if open else -1.0)


## The lip colour (colour and shade) blended `tone` of the way to the snout's, on the rig head and
## the merged near mesh; 0 puts back the built lip colour. The built colour is kept as metadata
## while toned, so the near-mesh build and a later restore read the real lip colour.
func set_lip_tone(tone: float) -> void:
	_lip_tone = tone
	for pair: Array in _lip_tones:
		var lip := pair[0] as ShaderMaterial
		var snout := pair[1] as ShaderMaterial
		for param: String in ["color", "shadow_color"]:
			var key := StringName("lip_base_" + param)
			if tone <= 0.0:
				if lip.has_meta(key):
					lip.set_shader_parameter(param, lip.get_meta(key))
					lip.remove_meta(key)
				continue
			if not lip.has_meta(key): lip.set_meta(key, lip.get_shader_parameter(param))
			var base: Color = lip.get_meta(key)
			lip.set_shader_parameter(param, base.lerp(snout.get_shader_parameter(param) as Color, tone))
	NEAR_MESH.set_lip_tone(_near, tone)


func _near_detach() -> void:
	if _near.is_empty(): return
	for mi in NEAR_MESH.instances(_near):
		if mi in _rig_watched:
			mi.visibility_changed.disconnect(_park_rig_mesh.bind(mi))
			_rig_watched.erase(mi)
	NEAR_MESH.detach(_near, _far_mesh_shown, _model)
	_near = {}
	_apply_hair_lod()
	if _ink: _exclude_world_ink()


## Rebuild only when an accessory changes the source geometry. Both variants stay cached;
## saved identity and other ponies' meshes remain unchanged.
func refresh_geometry_variant(variant: String) -> void:
	var previous: String = str(get_meta(&"geometry_variant", ""))
	if previous == variant: return
	var wanted_shadow := _shadow_proxy or _shadow_proxy_waiting
	if _far_mesh_shown: _show_far_mesh(null, false)
	_near_detach()
	set_meta(&"geometry_variant", variant)
	if shadow_proxy != null:
		shadow_proxy.visible = false
		shadow_proxy.queue_free()
		shadow_proxy = null
	_shadow_proxy = false
	_shadow_proxy_waiting = wanted_shadow
	_near_waiting = true
	_far_mesh_waiting = sim_tier == SimTier.FAR
	_lod_timer = 0.0
	_set_rig_shadows(sim_tier != SimTier.FAR)


## A/B switch for the merged near meshes (tools/profile/skin_bench.gd).
func set_near_mesh(on: bool) -> void:
	near_mesh_enabled = on
	if on: _near_waiting = true
	else: _near_detach()


## Watch every skinned rig mesh (body, head, hair): hidden ones let go of their skeleton.
func set_rig_parking(on: bool) -> void:
	park_hidden_rig_meshes = on
	for mi in _rig_watched:
		if not is_instance_valid(mi): continue
		mi.visibility_changed.disconnect(_park_rig_mesh.bind(mi))
		_unpark_rig_mesh(mi)
	_rig_watched.clear()
	if not on: return
	for root in [_model, _head_model, hair]:
		if root == null: continue
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi != far_mesh and mi != far_eyes and mi != shadow_proxy and not mi.skeleton.is_empty() \
					and not String(mi.name) in KEEP_SKELETON:
				_watch_rig_mesh(mi)


func _watch_rig_mesh(mi: MeshInstance3D) -> void:
	mi.visibility_changed.connect(_park_rig_mesh.bind(mi))
	_rig_watched.append(mi)
	_park_rig_mesh(mi)


func _park_rig_mesh(mi: MeshInstance3D) -> void:
	if mi.is_visible_in_tree():
		_unpark_rig_mesh(mi)
	elif not mi.has_meta(PARKED) and not mi.skeleton.is_empty():
		mi.set_meta(PARKED, mi.skeleton)
		mi.skeleton = NodePath()


func _unpark_rig_mesh(mi: MeshInstance3D) -> void:
	if mi.has_meta(PARKED):
		mi.skeleton = mi.get_meta(PARKED)
		mi.remove_meta(PARKED)


## World-ink mask overlays on (inside `ink_distance`) or off: 4 passes per surface against 2.
## The hull outline itself stays on at every distance.
func _set_ink(on: bool) -> void:
	if on == _ink: return
	_ink = on
	if on:
		_exclude_world_ink()
		return
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.has_meta(OUTLINE_EXCLUSION.META):
			mi.material_overlay = null
			mi.remove_meta(OUTLINE_EXCLUSION.META)


## One merged shadows-only caster instead of every rig surface. Until the far mesh is built
## (worker thread, once per identity, only from a settled pony) the rigs keep casting, except in
## FAR where they never did.
func _set_shadow_proxy(on: bool) -> void:
	if on and shadow_proxy == null and far_mesh_enabled and _model != null:
		var mesh: ArrayMesh = FAR_MESH.shadow_cache.get(FAR_MESH._id(self))
		if mesh == null and _far_mesh_can_gather():
			mesh = FAR_MESH.shadow_proxy(self)
		if mesh != null:
			var body_mesh: MeshInstance3D = _model.find_child("MareBody", true, false)
			shadow_proxy = MeshInstance3D.new()
			shadow_proxy.name = "ShadowProxy"
			skeleton.add_child(shadow_proxy)
			shadow_proxy.skin = body_mesh.skin
			shadow_proxy.skeleton = shadow_proxy.get_path_to(skeleton)
			shadow_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			# A shadow needs only the outline: coarser LODs sooner (2026-10-23 GPU pass, ~120k shadow triangles).
			shadow_proxy.lod_bias = 0.25
			shadow_proxy.mesh = mesh
	var shown := on and shadow_proxy != null
	_shadow_proxy_waiting = on and shadow_proxy == null
	if shadow_proxy != null: shadow_proxy.visible = shown
	_shadow_proxy = shown
	_set_rig_shadows(not shown and sim_tier != SimTier.FAR)


var _rig_shadows := true
func _set_rig_shadows(on: bool) -> void:
	if on == _rig_shadows: return
	_rig_shadows = on
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == shadow_proxy or mi == far_mesh or mi == far_eyes or mi.mesh == null: continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _sample_source_pose() -> Array[Transform3D]:
	var pose: Array[Transform3D] = super._sample_source_pose()
	return pinkie_bounce.sample(pose) if pinkie_bounce != null and pinkie_bounce.active() else pose


func _update_body(delta: float) -> void:
	super._update_body(delta)
	if pinkie_bounce != null and pinkie_bounce.active(): pinkie_bounce.apply_body()
	expression_stance.apply_body()


func _update_contacts(delta: float) -> void:
	# The ordinary contact pass is retained throughout the entry/exit blend. At full
	# bounce weight the style owns synchronous contacts, with the usual constrained solve.
	if pinkie_bounce == null or pinkie_bounce.amount < 1.0: super._update_contacts(delta)
	if pinkie_bounce != null and pinkie_bounce.active(): pinkie_bounce.contacts(delta)
	expression_stance.apply_contacts()


func body_pinned() -> bool:
	return (pinkie_bounce != null and pinkie_bounce.active()) or super.body_pinned()


func is_pinned() -> bool:
	return super.is_pinned() or is_instance_valid(action_gaze_target) or is_instance_valid(conversation_target) or (head != null and head.is_speaking())


func needs_full_rate() -> bool:
	return (pinkie_bounce != null and pinkie_bounce.active()) or super.needs_full_rate() or (head != null and head.is_speaking())


func speech_progress() -> Dictionary:
	if head == null or head.voice == null: return {}
	# A line still arriving from the voice server has no length yet: callers estimate from the text.
	if is_instance_valid(head._pcm_player): return {"time":maxf(0.0,head._speech_time)}
	return {"time":maxf(0.0,head._speech_time),"duration":head.voice.stream.get_length() if head.voice.stream else 0.0}


## True when say() also takes a line that is still arriving ("pcm://..." from tts_client.gd).
func supports_pcm_speech() -> bool:
	return head != null and head.has_method("_speak_pcm") and head.voice != null

func set_action_gaze(target: Node3D) -> void:
	action_gaze_target = target
	if is_instance_valid(target) and not is_instance_valid(_action_gaze_point):
		_action_gaze_point = Node3D.new()
		_action_gaze_point.name = "ActionGazePoint"
		add_child(_action_gaze_point)


## Talking gestures from dialogue tags ([hoofraise], [hoofraise:left|right]).
const HOOF_RAISE_SECONDS := 2.5
const HOOF_RAISE_REST_MS := 30000
var _last_hoof_raise_ms := -HOOF_RAISE_REST_MS
func gesture(name: String) -> bool:
	var parts := name.split(":")
	match parts[0]:
		"hoofraise":
			# Once as a chat starts, then down: a pony does not hold a hoof up through a whole
			# conversation, nor raise it for every line (dev 2026-10-14).
			if hoof_hold.leg_index >= 0 or Time.get_ticks_msec() - _last_hoof_raise_ms < HOOF_RAISE_REST_MS: return false
			var side := randi() % 2 if parts.size() < 2 else (0 if parts[1] == "left" else 1)
			if not hoof_hold.raise(side, HOOF_RAISE_SECONDS): return false
			_last_hoof_raise_ms = Time.get_ticks_msec()
			return true
		"magic":
			return cast_magic(2.5)
		"wings":
			if excitement == null or identity == null or not identity.has_wings(): return false
			return excitement.flutter() if parts.size() > 1 and parts[1] == "flutter" else excitement.spread()
		"excited":
			return excitement != null and excitement.spread()
	return false

## Opening a house door: a unicorn works the handle with magic (horn and handle glow in her
## colour); earth ponies and pegasi lift a forehoof to it, forearm level, bent 90 degrees.
## Past the crowd's NEAR range the forehoof is not lifted (W1-PERF-PONY, 2026-11-08): the lift needs
## the leg solver, and a held hoof pins her to it at every tick with the inline GDScript solve
## (about 0.5 ms a tick at the saved bench spot, ponies 50-180 m away entering houses) for a
## gesture drawn as a far mesh or a picture. The door still opens and she still waits at it.
## Rollback: FAR_DOOR_LIFT = true.
const FAR_DOOR_LIFT := false

func door_gesture(door: Node3D) -> void:
	if magic != null and sim_tier != SimTier.FAR:
		if cast_magic(1.8): door.magic_glow(magic.color, 1.8, global_position)
		return
	if not FAR_DOOR_LIFT and _beyond_near_range(): return
	if hoof_hold.leg_index < 0: hoof_hold.push_door(randi() % 2, door.handle_world())

## Farther from the camera than PonyCrowd draws NEAR ponies (where she would be FAR).
func _beyond_near_range() -> bool:
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null: return false
	var limit := 30.0
	if is_instance_valid(_crowd):
		var near: Variant = _crowd.get("near_distance")
		if near != null: limit = float(near)
	return global_position.distance_to(camera.global_position) > limit

## Light her horn in her magic colour for a while (unicorns and alicorns only).
func cast_magic(seconds := 2.5) -> bool:
	if magic == null or sim_tier == SimTier.FAR: return false
	return magic.cast(seconds)

## Someone rides her (M-LIF-09): her flight's obstacle and landing probes ignore the bodies under
## `nodes` (his body, hands, held things) as they ignore her own. [] on dismount (pony_flight.gd).
func set_flight_rider(nodes: Array) -> void:
	_ensure_flight()
	flight.set_rider(nodes)

func request_flight(destination: Vector3, hover_seconds := 0.0, long_range := false) -> bool:
	if identity != null and not identity.can_fly: return false   # Scootaloo can't fly (yet)
	if _indoors(global_position) or _indoors(destination): return false
	_ensure_flight()
	return flight.request(destination,hover_seconds,long_range)

## A short joyride nearby with a loop-de-loop or two (pegasi only).
func request_fun_flight() -> bool:
	if identity != null and not identity.can_fly: return false
	if _indoors(global_position): return false
	_ensure_flight()
	return flight.request_fun()

## A trick on request (pegasi; "rainboom" only for Rainbow Dash): "loop", "barrel_roll", "circle"
## (laps over `centre`, then a landing beside it) or "rainboom".
func request_trick(kind: String, centre := Vector3.INF) -> bool:
	if identity != null and not identity.can_fly: return false
	if _indoors(global_position): return false
	_ensure_flight()
	return flight.request_trick(kind, centre)

## An air show (pegasi): figures from pony_flight.gd SHOW_MOVES flown in turn near `centre`.
func request_show(moves: Array, centre := Vector3.INF) -> bool:
	if identity != null and not identity.can_fly: return false
	if _indoors(global_position): return false
	_ensure_flight()
	return flight.request_show(moves, centre)

## No flying inside a house: she took off into the ceiling and stuck there under the roof.
func _indoors(point: Vector3) -> bool:
	return is_inside_tree() and preload("res://world/buildings/house_interior.gd").at(get_tree(), point) != null

## Glide in from where she is (placed in the air) and land at `landing` (princess visits).
func request_arrival(landing: Vector3) -> bool:
	if identity != null and not identity.can_fly: return false
	_ensure_flight()
	return flight.arrive(landing)

func _ensure_flight() -> void:
	if flight == null:
		flight = preload("res://world/characters/locomotion/pony_flight.gd").new()
		flight.bind(self)

func action_interruption_reason() -> String:
	if has_meta("balloon_passenger"):return "Riding a hot-air balloon"
	if get_meta("affection_active",false):return "Affection or defensive gesture"
	if thrown != null and thrown.active(): return "Recovering from a throw"
	# Only a hand on her hoof; her own scripted raises (opening a door, excitement, fidgets) set
	# gesture_left and must not pause her trip at every door (2026-10-24 route probe).
	if hoof_hold.active() and hoof_hold.gesture_left <= 0.0:return "Player holding a hoof"
	if _held: return "Being held"
	if motion_paused: return "Motion paused"
	if not _interaction.is_empty(): return "Physical interaction"
	if not grounded() and (flight == null or not flight.active()): return "Waiting for safe ground support"
	return ""


## Head reach before a resting pony changes posture to see her conversation partner.
const LYING_VIEW_DEG := 60.0
const SITTING_VIEW_DEG := 110.0
var _view_check := 0.0

## Talking to someone she cannot see, she moves so her head can reach them (dev 2026-10-06):
## lying down she sits up; sitting with them behind her she stands, and the navigator's
## conversation facing turns her. Furniture seats, sleep, holds and walking are left alone.
func _keep_partner_in_view(delta: float) -> void:
	_view_check -= delta
	if _view_check > 0.0: return
	_view_check = 0.5
	if not is_instance_valid(conversation_target) or posture == null or not posture.active(): return
	# A requested rest or close contact is not permission to stand just to face a voice.
	if posture.intentional_rest or not _interaction.is_empty() or get_meta("affection_active",false): return
	# A spa client stays on the bath bench or massage table while Anon talks to her (player report 2026-10-30).
	if sleeping or _held or has_meta("seated") or has_meta("spa_client") or velocity.length() > 0.12: return
	var toward: Vector3 = conversation_target.global_position - global_position
	toward.y = 0.0
	var forward: Vector3 = -global_basis.z
	forward.y = 0.0
	if toward.length() < 0.2 or forward.length() < 0.01: return
	var angle: float = rad_to_deg(forward.angle_to(toward))
	# Behind her: stand straight up rather than sitting first.
	if posture.requested in ["lie_down", "sit"] and angle > SITTING_VIEW_DEG:
		posture.request("stand")
	elif posture.requested == "lie_down" and angle > LYING_VIEW_DEG:
		posture.request("sit")

func set_conversation_target(listener: Node3D, hold_position := true) -> void:
	conversation_target = listener
	if is_instance_valid(listener) and not is_instance_valid(_conversation_gaze_point):
		_conversation_gaze_point = Node3D.new()
		_conversation_gaze_point.name = "ConversationGazePoint"
		add_child(_conversation_gaze_point)
	if is_instance_valid(listener):
		_conversation_gaze_point.global_position = listener.listen_point() if listener.has_method("listen_point") else listener.global_position
	for child in get_children():
		if child.has_method("set_conversation_target"):
			child.set_conversation_target(listener, hold_position)


## Conversation hooks (world/ai/conversation_director.gd).
func say(wav_path: String, text := "") -> void:
	head.speak(wav_path, text)


func stop_speaking() -> void:
	head.stop_speaking()


func is_speaking() -> bool:
	return head.is_speaking()


## The thinking bubble's centre over her head. Its gap over the skull grows with a body bigger than
## canon, as the bubble does (pony_speech_indicator.gd), so it clears her ears (thread 43671981).
func speech_indicator_point() -> Vector3:
	var grow := maxf(1.0, body_scale)
	if boop_node == null or boop_node._head_bone < 0: return listen_point() + Vector3.UP * .4 * grow
	var frame: Transform3D = boop_node.head_skeleton.global_transform * boop_node.head_skeleton.get_bone_global_pose(boop_node._head_bone)
	var center: Vector3 = frame * boop_node.SKULL_LOCAL
	return center + Vector3.UP * (boop_node.SKULL_RADIUS * maxf(frame.basis.get_scale().x, maxf(frame.basis.get_scale().y, frame.basis.get_scale().z)) + .23 * grow)


func listen_point() -> Vector3:
	return boop_node.nose_world() if boop_node != null and boop_node.snoot != null else global_position + Vector3.UP * 0.8


func is_held() -> bool:
	return _held


func boop_count() -> int:
	return boop_node.boops if boop_node != null else 0


## A hand on her hoof (her AI's "the player is holding your hoof"). Her own lifts set gesture_left;
## a spa client's hoof care is not reported (SPA_PLAN_2026_10_29.md section 3).
func is_hoof_held() -> bool:
	return hoof_hold.active() and hoof_hold.gesture_left <= 0.0 and not has_meta("spa_client")

## Petting sessions so far (pony_touch_body.gd), for the awareness events.
func pet_count() -> int:
	return touch_body.pets if touch_body != null else 0

func is_being_petted() -> bool:
	return touch_body != null and touch_body.petting

func pet_region() -> String:
	return touch_body.pet_region if touch_body != null else ""

func hoofhold_count() -> int:
	return hoof_hold.grab_count

func kiss_count() -> int:
	return boop_node.kisses if boop_node != null else 0


func awareness_forward() -> Vector3:
	if boop_node == null: return -global_basis.z.normalized()
	var sk: Skeleton3D = boop_node.head_skeleton
	return (sk.global_transform * sk.get_bone_global_pose(boop_node._head_bone)).basis.z.normalized()


## XR: the physics hands and controllers that can boop her (game.gd wires these).
func arm_boop(left_hand: Node3D, right_hand: Node3D, left_controller: Node, right_controller: Node) -> void:
	boop_node.arm(left_hand, right_hand, left_controller, right_controller)


## Fire the boop reaction directly (desktop pet on the head, lab key, tests).
func boop() -> void:
	boop_node.boop()


## Distance from the player's mouth to the existing bone-following face volumes.
func kiss_contact_distance(point: Vector3, approach := Vector3.ZERO) -> float:
	if boop_node == null or not is_instance_valid(boop_node.snoot): return INF
	var sk: Skeleton3D = boop_node.head_skeleton
	var frame := sk.global_transform * sk.get_bone_global_pose(boop_node._head_bone)
	# Native head faces +Z. Reject the back of her skull/mane.
	if (frame.affine_inverse() * point).z < 0.0: return INF
	if approach.dot(frame.basis.z.normalized()) > 0.25: return INF
	var gap := INF
	for child in boop_node.snoot.get_children():
		var shape := child as CollisionShape3D
		if shape == null: continue
		if shape.disabled or not shape.shape is SphereShape3D: continue
		var radius: float = shape.shape.radius * maxf(shape.global_basis.get_scale().abs().x,
			maxf(shape.global_basis.get_scale().abs().y, shape.global_basis.get_scale().abs().z))
		gap = minf(gap, point.distance_to(shape.global_position) - radius)
	return gap


func kiss() -> void:
	expressions.kiss()
	boop_node.play_kiss()


## Her voice noises (world/ai/vocal_noises.gd), or null without a director.
func vocal() -> Node:
	var runtime: Variant = get_meta("relationship_runtime") if has_meta("relationship_runtime") else null
	if runtime == null or not is_instance_valid(runtime.game) or not is_instance_valid(runtime.game.director): return null
	return runtime.game.director.vocal


## Now and then a quiet breathy laugh once a long flustered spell of boops or kisses is over.
## Rare and far under dialogue (dev 2026-09-28: "way quieter, way less frequent, less cartoony").
var _fluster_seconds := 0.0
func _giggle_after_fluster(delta: float) -> void:
	if expressions.flustered():
		_fluster_seconds += delta
		return
	if _fluster_seconds > 1.5 and not sleeping and not is_speaking() and randf() < .25:
		var voice := vocal()
		if voice != null: voice.play(str(identity.id), "laugh", boop_node.snoot, -30.0)
	_fluster_seconds = 0.0


## Desktop interactor verb: petting her head is a boop.
func pet(part: String) -> void:
	if part == "head":
		boop()


## The face side of a boop: eyes shut, big smile, a small flinch up and back to the player.
func on_booped() -> void:
	physical_reaction.emit("boop")
	expressions.boop()
	# Asleep, her eyes stay shut through it: no flustered peeks, and the sleep lids hold through
	# the boop reaction (dev 2026-10-22).
	expressions.fluster(1.4, not sleeping)
	if sleeping: _boop_asleep = BOOP_ASLEEP_SECONDS
	# The flinch waits for the finger to go: it would pull her nose off it (dev 2026-10-29).
	if not attention.head_hold: secondary.look_toward(Vector3(deg_to_rad(9.0), attention.last_angles.y * 0.5, 0.0), 0.45)


## Contact rules (dev, headset round 7): the player's body and head never collide with her;
## only the physics hands do: her face spheres and the fitted body hulls (layer 4,
## pony_touch_body.gd). The hands no longer scan her capsule (layer 2, 2026-09-25). Held, her
## capsule still leaves the pony layer, and a grabbing fist passes through her hulls.
func _update_contact_rules() -> void:
	var wanted := 0 if _held else 2
	if collision_layer != wanted:
		collision_layer = wanted


func _attention_target() -> Node3D:
	if attention_target != null and is_instance_valid(attention_target):
		return attention_target
	var navigator := get_node_or_null("Navigator")
	if navigator != null:
		var target: Node3D = navigator.get("attention_target")
		if target != null and is_instance_valid(target):
			return target
	return preload("res://world/player_view.gd").camera(self)


## Source face mesh -> its copy without LODs. Every head of a model shares the source, so the copy
## is built (GPU readback and upload) once, not per spawn; nothing edits it afterwards.
static var _face_meshes := {}

func _remove_face_lods(mi: MeshInstance3D) -> void:
	var original := mi.mesh as ArrayMesh
	if original == null: return
	# The reviewed eye already has no LODs; keep its blink-clearance shape key.
	if original.get_blend_shape_count() > 0: return
	var mesh: ArrayMesh = _face_meshes.get(original)
	if mesh == null:
		mesh = ArrayMesh.new()
		for i in original.get_surface_count():
			mesh.add_surface_from_arrays(original.surface_get_primitive_type(i),
				original.surface_get_arrays(i), [], {}, original.surface_get_format(i) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
			mesh.surface_set_material(i, original.surface_get_material(i))
		_face_meshes[original] = mesh
	# Skin/binds and active material overrides belong to the instance and survive.
	mi.mesh = mesh


func _dress_lashes(model: Node) -> void:
	# Existing local OpenPony-compatible artwork, not the missing devkit image.
	# See THIRD_PARTY.md for the cache UUID. Keep the prior image as fallback.
	if not ResourceLoader.exists(CACHED_LASHES): return
	var style: Dictionary = LASH_STYLES.tips_for(identity.lash_style)
	for mi in model.find_children("Eyelashes", "MeshInstance3D", true, false):
		for si in mi.mesh.get_surface_count():
			var source := mi.get_active_material(si) as StandardMaterial3D
			if source == null: continue
			var mat := ShaderMaterial.new()
			mat.shader = preload("res://world/characters/openpony/openpony_lashes.gdshader")
			mat.set_shader_parameter("use_native_ring", true)
			mat.set_shader_parameter("authored_liner", mi.mesh.get_meta("authored_liner", false))
			mat.set_shader_parameter("native_lash_texture", load(CACHED_LASHES))
			mat.set_shader_parameter("lash_color", source.albedo_color)
			mat.set_shader_parameter("show_lash_tips", not identity.stallion)
			mat.set_shader_parameter("tips", style.tips)
			mat.set_shader_parameter("tip_curl", style.curl)
			# Authored heads wear lid colour on their moving skin; old heads retain
			# the source lash-card band as a fallback.
			mat.set_shader_parameter("eyeshadow_color", Color.TRANSPARENT if head.face_sculpt != null else identity.eyeshadow())
			mi.set_surface_override_material(si, mat)


## Wings only on pegasi; the identity's cutie mark on the native patches.
func _dress_body_for_race() -> void:
	for mi in _model.find_children("*", "MeshInstance3D", true, false):
		if String(mi.name).begins_with(WING_PREFIX):
			mi.visible = identity.has_wings()
		elif String(mi.name).begins_with(MARK_PREFIX):
			preload("res://world/characters/hybrid_mare/hybrid_mark_fit.gd").apply(mi,identity.cutie_mark,identity.id)
			if identity.cutie_mark == null:continue
			for si in mi.mesh.get_surface_count():
				var source := mi.get_active_material(si) as StandardMaterial3D
				if source == null: continue
				var mat := source.duplicate() as StandardMaterial3D
				mat.albedo_texture = identity.cutie_mark
				mat.texture_repeat = false
				mi.set_surface_override_material(si, mat)


func _restore_eyebrows(model: Node) -> void:
	for mi in model.find_children("Eyebrows", "MeshInstance3D", true, false):
		mi.visible = true
		for si in mi.mesh.get_surface_count():
			var mat := ShaderMaterial.new()
			mat.shader = preload("res://world/characters/openpony/openpony_brows.gdshader")
			mi.set_surface_override_material(si, mat)
		expressions.bind_brow_visual(mi)


func _attach_devkit_hair() -> void:
	if not ResourceLoader.exists(identity.hair_scene):
		push_warning("Missing Mane 6 hair for %s (%s): run tools/extract_devkit_hair.py through Blender MCP" % [identity.id, identity.hair_scene])
		return
	hair = (load(identity.hair_scene) as PackedScene).instantiate()
	hair.name = "Mane6%sHair" % identity.hair_prefix
	pivot.add_child(hair)
	# Keep the tail at body size. Head bone poses carry the uniform enlargement to the mane.
	hair.transform = _adult_head_transform
	if identity.hair_scene.ends_with("dash_devkit_hair.glb"): _flip_dash_tail_colours(hair)
	# Full meshes on, LOD copies and unlisted accessories off until the LOD logic asks.
	for mi in hair.find_children("*", "MeshInstance3D", true, false):
		var n := String(mi.name)
		var is_hair: bool = n == identity.hair_prefix + "DevkitMane" or n == identity.hair_prefix + "DevkitTail"
		mi.visible = is_hair or n in identity.accessories
		# A rigid piece on a bone of the hair rig (Applejack's hat): the identity may re-seat it.
		if identity.accessory_offsets.has(n) and (mi as MeshInstance3D).skin == null:
			var offset: Vector3 = identity.accessory_offsets[n]
			var parent := mi.get_parent() as Node3D
			if parent != null: mi.position += parent.global_basis.inverse() * (pivot.global_basis * offset)
	hair_skeleton = hair.find_children("*","Skeleton3D",true,false)[0]
	hair_skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS
	hair_link = HAIR_LINK.new()
	hair_link.name = "HybridHairLink"
	if reference_face_enabled:
		hair_link.skull_frame = Transform3D(Basis.from_scale(Vector3(float(_head_model.get_meta("reference_skull_width",1.0)),1,1)),Vector3.ZERO)
	add_child(hair_link)
	hair_link.bind(skeleton,head.skeleton,hair_skeleton,pivot.global_basis*identity.tail_mount_offset,pivot.global_basis*identity.mane_offset)
	preload("res://world/characters/hybrid_mare/hybrid_tail_anchor.gd").apply(self)
	tail_motion = TAIL_MOTION.new()
	tail_motion.name = "NativeTailMotion"
	hair_skeleton.add_child(tail_motion)
	tail_motion.bind(self)
	# Hide only the superseded body-model hair once its replacement is loaded.
	for mi in _model.find_children("*","MeshInstance3D",true,false):
		if "tail" in mi.name.to_lower() or "mane" in mi.name.to_lower(): mi.hide()
	if preserve_model_materials and show_shading: _apply_show_shading(hair)


## The devkit tail's strands run red on top to purple underneath; Dash's tail is purple on top
## (dev 2026-10-16). Swaps the stripe materials on a copy of the tail mesh, geometry untouched,
## before shading, near/far mesh bakes or LOD copies read it.
const DASH_TAIL_SWAP := {"red": "purple", "orange": "blue", "yellow": "green", "green": "yellow", "blue": "orange", "purple": "red"}
func _flip_dash_tail_colours(root: Node) -> void:
	var tail := root.find_child(identity.hair_prefix + "DevkitTail", true, false) as MeshInstance3D
	if tail == null or not tail.mesh is ArrayMesh: return
	var mesh := tail.mesh.duplicate() as ArrayMesh
	var by_colour := {}
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i)
		if mat == null: continue
		for colour: String in DASH_TAIL_SWAP:
			if mat.resource_name.to_lower().contains("_" + colour): by_colour[colour] = mat
	if by_colour.size() != DASH_TAIL_SWAP.size(): return
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i)
		if mat == null: continue
		for colour: String in DASH_TAIL_SWAP:
			if mat.resource_name.to_lower().contains("_" + colour):
				mesh.surface_set_material(i, by_colour[DASH_TAIL_SWAP[colour]])
				break
	tail.mesh = mesh


func set_dialogue_expression(value: String) -> void:
	if expressions != null: expressions.set_dialogue(value)

func clear_dialogue_expression() -> void:
	if expressions != null: expressions.clear_dialogue()

func finish_dialogue_expression() -> void:
	if expressions != null: expressions.finish_dialogue()


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process(delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("mare_process", started)
