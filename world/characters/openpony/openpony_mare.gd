extends Node3D
## The OpenPony mare: the devkit export (tools/export_openpony.py) plus the
## baked devkit clips (tools/export_openpony_anims.py) merged into one
## AnimationPlayer, dressed in show colours and native layered eye textures.
##
## Both GLBs are local-only (gitignored). The clip GLB's tracks are
## "Avatar/Skeleton3D:<bone>" relative to its own root, which is also the
## layout of the model GLB, so the library transfers as is.
##
## Talking: `speak(wav, text)` analyses the wav (LipSync: Rhubarb Lip Sync, or
## loudness when the binary is missing), plays it from her head and drives the
## PonyMouth modifier with the timed visemes while the body clip keeps playing.

const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const MODEL := "res://world/characters/openpony/openpony.glb"
@export var model_path := MODEL
## Fillies: bigger pupils and a third eye shine (openpony_eye_layer.gdshader).
var pupil_scale := 1.0
var third_shine := false
var reference_eyes := false
## Reviewed September 24 artwork, tinted by each identity's iris color.
@export var show_eyes_enabled := true
const SHOW_EYE_SURFACE := preload("res://world/characters/openpony/show_eyes/eye_surface.res")
const SHOW_IRIS := preload("res://world/characters/openpony/show_eyes/iris.gdshader")
const FACE_SCULPT := preload("res://world/characters/openpony/face_sculpt.gd")
const AUDIO_MIX := preload("res://world/audio/audio_mix.gd")
var face_sculpt: RefCounted
var _sculpt_iris_shape := Vector2.ONE
var _sculpt_amount := 0.0
var _sculpt_closure := 0.0
var _show_eye_mesh: MeshInstance3D
var _eye_head_bone := -1
var _eye_bind_pose := Transform3D.IDENTITY
var _eye_rest_from_pose := Transform3D.IDENTITY
var _eye_details := Vector3(1.0, 0.0, 0.0)
const CLIPS := "res://world/characters/openpony/openpony_anims.glb"
const CUTIE_MARK := "res://world/characters/rainbow_dash/rainbow_dash_RD_CutieMark.png"
## Painted by tools/paint_openpony_lashes.py from the devkit UV guide (local-only).
const LASHES := "res://world/characters/openpony/lashes.png"

## Rainbow Dash: coat, mane/tail line, mouth, eyes (show guide values).
@export var coat_color := Color("9bdbf5")
@export var line_color := Color("6babda")
@export var mouth_color := Color("7a2f4a")
@export var tongue_color := Color("d9668a")
@export var iris_color := Color("c42b7b")
@export var clip_at_start := ""

signal speech_finished
signal speech_started
signal speech_failed(message:String)

var skeleton: Skeleton3D
var player: AnimationPlayer
var model: Node3D
var mouth: PonyMouth
var voice: AudioStreamPlayer3D
var _eye_layers: Array[ShaderMaterial] = []
static var _clips: AnimationLibrary
var _cues: Array = []
var _speech_time := -1.0
var _speech_generation := 0
var _pending_stream: AudioStreamWAV
## `debugmouth` on the command line prints cue counts and viseme changes.
var _debug_mouth := "debugmouth" in preload("res://world/dev_tools.gd").user_args()


## 1 when the run has no sound device (tests), 0 when it has, -1 not asked yet. Asked once: the
## command line was read again every frame of every spoken line.
static var _silent_driver := -1

func _ready() -> void:
	var packed: PackedScene = load(model_path)
	if packed == null:
		push_error("OpenPony model missing: run tools/export_openpony.py")
		return
	model = packed.instantiate()
	model.name = "Model"
	add_child(model)
	for node in model.find_children("*", "Skeleton3D", true, false):
		skeleton = node
		break
	player = AnimationPlayer.new()
	player.name = "AnimationPlayer"
	model.add_child(player)
	var library := _clip_library()
	if library != null:
		player.add_animation_library("", library)
	# This authored basis is the mare's exact imported mesh; alternate model families
	# need their own authored basis rather than transplanting a different sculpt.
	if show_eyes_enabled and model_path == MODEL:
		face_sculpt = FACE_SCULPT.new()
		face_sculpt.bind(model)
	_dress()
	if face_sculpt != null:
		_eye_head_bone = skeleton.find_bone("HEAD")
		for index in _show_eye_mesh.skin.get_bind_count():
			if _show_eye_mesh.skin.get_bind_name(index) == &"HEAD":
				_eye_bind_pose = _show_eye_mesh.skin.get_bind_pose(index)
		skeleton.skeleton_updated.connect(_update_eye_projection)
	_attach_mouth()
	# Capture/lab aids from the command line: hide=Prefix,Prefix hides meshes,
	# shape=name[:weight] holds one mouth shape, viseme=D holds a Rhubarb
	# viseme, speak=/path.wav talks (LipSync analysis, then audio + visemes).
	for arg in preload("res://world/dev_tools.gd").user_args():
		if arg.begins_with("hide="):
			for prefix in arg.trim_prefix("hide=").split(","):
				for node in model.find_children(prefix + "*", "MeshInstance3D", true, false):
					(node as MeshInstance3D).visible = false
		elif arg.begins_with("shape=") and mouth:
			var parts := arg.trim_prefix("shape=").split(":")
			mouth.set_shape(parts[0], float(parts[1]) if parts.size() > 1 else 1.0, 0.0)
		elif arg.begins_with("viseme=") and mouth:
			mouth.set_viseme(arg.trim_prefix("viseme="), 0.0)
		elif arg.begins_with("speak="):
			speak(arg.trim_prefix("speak="))
	if clip_at_start != "" and player.has_animation(clip_at_start):
		player.play(clip_at_start)
	# _process only runs a spoken line (_on_cues turns it on, the line's end turns it off).
	if _speech_time < 0.0:
		set_process(false)


## Every head shares one clip library: heads only play and sample the clips (mouth, eye and
## face shapes), so reloading the clip GLB and duplicating its 99 clips per pony bought nothing.
static func _clip_library() -> AnimationLibrary:
	if _clips != null or not ResourceLoader.exists(CLIPS):
		return _clips
	var clip_scene: Node = (load(CLIPS) as PackedScene).instantiate()
	var sources := clip_scene.find_children("*", "AnimationPlayer", true, false)
	if not sources.is_empty():
		var source := sources[0] as AnimationPlayer
		var library := AnimationLibrary.new()
		for name in source.get_animation_list():
			var anim: Animation = source.get_animation(name).duplicate()
			# Idle and face loops play as loops; one-shot clips stay one-shot.
			if name.begins_with("idle") or name.begins_with("walk") or name.begins_with("run") \
					or name.begins_with("fly") or name.begins_with("hover") or name.begins_with("tail") \
					or name.begins_with("swim") or name.begins_with("sit") or name.begins_with("sleep"):
				anim.loop_mode = Animation.LOOP_LINEAR
			library.add_animation(name, anim)
		_clips = library
	clip_scene.free()
	return _clips


## PonyMouth under the skeleton (modifier rule), shapes sampled from the clip
## library; the voice plays from the head bone.
func _attach_mouth() -> void:
	if skeleton == null:
		return
	mouth = PonyMouth.new()
	mouth.name = "PonyMouth"
	skeleton.add_child(mouth)
	var count := mouth.build(player)
	if count == 0:
		push_warning("PonyMouth: no mouth shapes (clip library missing?)")
	var head := BoneAttachment3D.new()
	head.name = "HeadAttachment"
	head.bone_name = "mHead"
	skeleton.add_child(head)
	voice = AudioStreamPlayer3D.new()
	voice.bus = "Voice" if AudioServer.get_bus_index("Voice") >= 0 else "Master"
	voice.name = "Voice"
	# dev 2026-10-01: "allow speech to travel farther" (was 3 m / 30 m).
	voice.unit_size = 6.0
	voice.max_distance = 80.0
	head.add_child(voice)


## Ponese (tts_client.gd writes chatter_*.wav) gets its EQ bus, a clearer distance filter and a
## capped close-up level: inside 6 m it no longer climbs (it was +12 dB at chat distance), while
## the 6-80 m falloff stays as it was, so ponies are still heard from afar (dev 2026-11-03).
## Synthesised TTS keeps the Voice bus and Godot's defaults.
const PONESE_MAX_DB := 0.0
const PONESE_FILTER_HZ := 11000.0

func _route_voice(ponese: bool) -> void:
	var bus := "Voice" if AudioServer.get_bus_index("Voice") >= 0 else "Master"
	if ponese:
		AUDIO_MIX.ensure_ponese_bus()
		bus = AUDIO_MIX.PONESE_BUS
	voice.bus = bus
	voice.max_db = PONESE_MAX_DB if ponese else 3.0
	voice.attenuation_filter_cutoff_hz = PONESE_FILTER_HZ if ponese else 5000.0


## Say a wav (res://, user:// or absolute). `text` is the spoken line; with it
## Rhubarb uses its English recogniser for better shapes.
var _pending_path := ""
## A line that is still arriving from the voice server ("pcm://utterance/N" from tts_client.gd):
## played and lip-read by pcm_speech_player.gd while it comes in.
const PCM_UTTERANCE := preload("res://world/ai/pcm_utterance.gd")
const PCM_PLAYER := preload("res://world/characters/pcm_speech_player.gd")
var _pcm_player: Node

func speak(wav_path: String, text := "") -> void:
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
	if _debug_mouth:
		print("speak: analysing %s (%.2f s)" % [wav_path, stream.get_length()])
	LipSync.analyse_async(wav_path, text, _on_cues.bind(_speech_generation))


func _on_cues(cues: Array, generation := -1) -> void:
	if not is_inside_tree() or is_queued_for_deletion(): return
	if generation >= 0 and generation != _speech_generation: return
	if _debug_mouth:
		print("speak: cues arrived (%d), stream %s voice %s" % [cues.size(), _pending_stream != null, voice != null])
	if _pending_stream == null or voice == null:
		return
	_cues = cues
	_route_voice(_pending_path.get_file().begins_with("chatter_"))
	voice.stream = _pending_stream
	_pending_stream = null
	voice.play()
	# Always logged with [ai] says (conversation_director.gd): a clip played twice shows here twice.
	print("[voice] %s plays %s (%.1f s)" % [get_parent().name if get_parent() else name, _pending_path.get_file(), voice.stream.get_length()])
	_speech_time = 0.0
	_speech_peak = 0.0
	set_process(true)
	speech_started.emit()
	if _debug_mouth:
		print("speak: %d cues over %.2f s (%s)" % [cues.size(), LipSync.duration(cues), voice.stream.get_length()])


var _speech_peak := 0.0  # furthest raw playback position of the current line (seconds)

func is_speaking() -> bool:
	return _speech_time >= 0.0


func _speak_pcm(path: String) -> void:
	var utterance: RefCounted = PCM_UTTERANCE.take(path)
	if utterance == null or voice == null:
		if utterance != null: utterance.cancel()
		speech_failed.emit("PCM speech unavailable")
		return
	_pending_path = path
	_cues = []
	if mouth: mouth.set_viseme("X")
	_route_voice(false)
	_pcm_player = PCM_PLAYER.new()
	_pcm_player.debug = _debug_mouth
	add_child(_pcm_player)
	_pcm_player.started.connect(_pcm_started)
	_pcm_player.finished.connect(_pcm_finished)
	_pcm_player.failed.connect(_pcm_failed)
	_pcm_player.begin(utterance, voice)
	_cues = _pcm_player.cues


func _pcm_started() -> void:
	print("[voice] %s plays %s (streamed)" % [get_parent().name if get_parent() else name, _pending_path.get_file()])
	_speech_time = 0.0
	_speech_peak = 0.0
	set_process(true)
	speech_started.emit()


func _pcm_finished() -> void:
	stop_speaking()
	speech_finished.emit()


func _pcm_failed(message: String) -> void:
	stop_speaking()
	speech_failed.emit(message)


func stop_speaking() -> void:
	_speech_generation += 1
	_pending_stream = null
	if is_instance_valid(_pcm_player):
		_pcm_player.cancel()
		_pcm_player.queue_free()
	_pcm_player = null
	if voice:
		voice.stop()
	_speech_time = -1.0
	if mouth:
		mouth.set_viseme("X")


func _exit_tree() -> void:
	stop_speaking()


func _unprofiled_process(delta: float) -> void:
	if _speech_time < 0.0:
		set_process(false)
		return
	if is_instance_valid(_pcm_player):
		# The stream player owns the clock and the end of the line.
		_speech_time = maxf(0.0, _pcm_player.time)
		_show_mouth()
		return
	# Do not let frame time run ahead and finish a real voice that is still playing.
	if _silent_driver < 0: _silent_driver = 1 if DisplayServer.get_name() == "headless" or "Dummy" in OS.get_cmdline_args() else 0
	var dummy := _silent_driver == 1
	if voice.playing and not dummy:
		_speech_time = maxf(0.0,voice.get_playback_position()+AudioServer.get_time_since_last_mix()-AudioServer.get_output_latency())
		_speech_peak = maxf(_speech_peak, voice.get_playback_position())
	else:_speech_time += delta
	var length := voice.stream.get_length() if voice.stream else LipSync.duration(_cues)
	if (dummy and _speech_time >= length + 0.05) or (not dummy and not voice.playing):
		# Judged on the furthest raw playback position, not the latency-corrected mouth clock: with
		# a high reported output latency (PipeWire, WiVRn) a line that played to its end looked
		# 0.15 s short, failed as "stopped early", and was voiced again in Ponese (dev heard
		# lines twice). Only a real cut-off, well before the end, counts as a failure.
		var incomplete:=not dummy and _speech_peak<minf(length*.6,length-.8)
		_speech_time = -1.0
		if mouth:
			mouth.set_viseme("X")
		if incomplete:speech_failed.emit("Voice playback stopped early")
		else:speech_finished.emit()
		return
	_show_mouth()


func _show_mouth() -> void:
	if mouth:
		var letter := LipSync.viseme_at(_cues, _speech_time)
		# Lips round before the "oo" sounds (viseme review 2026-11-03): look one cue ahead, but
		# never over a consonant that has to show (A press, B teeth, G f/v, H tongue).
		var ahead := LipSync.viseme_at(_cues, _speech_time + 0.06)
		if (ahead == "E" or ahead == "F") and letter in ["X", "C", "D"]:
			letter = ahead
		if _debug_mouth and letter != mouth.current_viseme:
			print("viseme %s at %.2f s" % [letter, _speech_time])
		mouth.set_viseme(letter)


## Colours by devkit material name. The eye cards retain the native PSD
## layers (base/shading/pupil/shine/highlights) and the skinned lid geometry.
func _dress() -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if show_eyes_enabled:
			if String(mesh.name).begins_with("Pupil"):
				mesh.hide()
				continue
			if mesh.name == "Eye":
				mesh.mesh = FACE_SCULPT.MESHES["Eye"] if face_sculpt != null else SHOW_EYE_SURFACE
				_show_eye_mesh = mesh
		for surface in mesh.mesh.get_surface_count():
			var source := mesh.get_active_material(surface)
			var name := (source.resource_name if source else "").to_lower()
			mesh.set_surface_override_material(surface, _material_for(mesh.name, name))


func _material_for(mesh_name: String, material_name: String) -> Material:
	var mat := StandardMaterial3D.new()
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	if "cutiemark" in material_name:
		mat.albedo_texture = load(CUTIE_MARK)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
	elif "inner mouth" in material_name:
		mat.albedo_color = mouth_color
	elif "tongue" in material_name:
		mat.albedo_color = tongue_color
	elif "teeth" in material_name:
		mat.albedo_color = Color(0.96, 0.96, 0.93)
	elif "eyelash" in material_name or "eyebrow" in material_name:
		mat.albedo_color = Color(0.05, 0.05, 0.08)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if ResourceLoader.exists(LASHES):
			mat.albedo_texture = load(LASHES)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = 0.4
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.0
	elif "pupil" in material_name:
		# Native cards cover the full eye: their PSD alpha defines iris/pupil
		# shapes. An opaque black material paints the entire card black.
		var layer := material_name.trim_prefix("left ").trim_prefix("right ").trim_prefix("pupil").strip_edges()
		var textures := {"": "eye_color", "2": "eye_shading", "3": "eye_pupil",
			"4": "eye_shine", "5": "eye_highlight", "6": "eye_highlight"}
		var texture_path: String = "res://world/characters/openpony/native/%s.png" % textures.get(layer, "eye_color")
		if ResourceLoader.exists(texture_path):
			var eye := ShaderMaterial.new()
			eye.shader = preload("res://world/characters/openpony/openpony_eye_base.gdshader") if layer == "" else preload("res://world/characters/openpony/openpony_eye_layer.gdshader")
			eye.set_shader_parameter("color_layer" if layer == "" else "layer_texture", load(texture_path))
			if layer == "": eye.set_shader_parameter("iris_color", iris_color)
			if layer == "3": eye.set_shader_parameter("pupil_scale", pupil_scale)
			if layer == "4": eye.set_shader_parameter("third_shine", third_shine)
			if reference_eyes:
				eye.set_shader_parameter("iris_scale", 1.30)
				if layer == "4": eye.set_shader_parameter("layer_opacity", .04)
				if layer in ["5", "6"]: eye.set_shader_parameter("oval_highlights", true)
			eye.render_priority = 10 + (1 if layer == "" else int(layer))
			eye.set_meta("left_eye", material_name.begins_with("left"))
			_eye_layers.append(eye)
			return eye
		mat.albedo_color = iris_color if layer == "" else Color(0,0,0,0)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif material_name.ends_with(" eye"):
		if show_eyes_enabled:
			# The export's Left surface is on the right in the frontal study.
			var side := "R" if material_name.begins_with("left") else "L"
			var eye := ShaderMaterial.new()
			eye.shader = SHOW_IRIS
			eye.set_shader_parameter("tint_mask",load("res://world/characters/openpony/show_eyes/tint_%s.res" % side))
			eye.set_shader_parameter("shine_ink",load("res://world/characters/openpony/show_eyes/ink_L.res"))
			eye.set_shader_parameter("iris_color",iris_color)
			# Original pupil path bounds, including the area covered by the shines.
			# Both eyes use the L drawing's extent, centred on the iris; R was 11% narrower,
			# 12% shorter and lower. These source transforms preserve the original art.
			eye.set_shader_parameter("pupil_metric", Vector3(8.846705,.007479,8.110767) if side == "L" else Vector3(8.910513,.722167,8.168281))
			eye.set_shader_parameter("tint_source", Vector4(.509766,.5,1,1) if side == "L" else Vector4(.496094,.499349,1.012821,.971074))
			# Drawn show lids (show_lid.gd): the export's Left Eye sits on -x, its nose side toward -UV.x.
			eye.set_shader_parameter("nose_sign",-1.0 if material_name.begins_with("left") else 1.0)
			eye.set_meta("show_iris",true)
			eye.set_meta("left_eye",material_name.begins_with("left"))
			_eye_layers.append(eye)
			return eye
		mat.albedo_color = Color(0.98, 0.98, 1.0)
	elif "lip" in material_name or "nostril" in material_name:
		mat.albedo_color = line_color
	elif "horn" in material_name or "horn" in mesh_name.to_lower():
		mat.albedo_color = coat_color
	else:
		mat.albedo_color = coat_color
	return mat


func play(clip: String) -> void:
	if player != null and player.has_animation(clip):
		player.play(clip)


func apply_gaze(angles: Vector2) -> void:
	_shown_eyes = Vector3(INF, INF, INF)
	for material in _eye_layers:
		if material.has_meta("show_iris"):
			material.set_shader_parameter("gaze_uv",show_gaze_uv(angles))
			continue
		var side := -1.0 if material.get_meta("left_eye") else 1.0
		material.set_shader_parameter("gaze_uv", Vector2(clampf(angles.x * side * 0.08, -0.04, 0.04), clampf(-angles.y * 0.08, -0.04, 0.04)))


static func show_gaze_uv(angles: Vector2) -> Vector2:
	return Vector2(clampf(angles.x*.40,-.12,.12),clampf(-angles.y*.25,-.10,.10))


## The last update_show_eyes values: the same gaze and closure again set nothing (0.1.0 perf pass;
## each set re-uploads the material and the eye mesh's blend weights). Rollback: SKIP_SAME_EYES = false.
const SKIP_SAME_EYES := true
var _shown_eyes := Vector3(INF, INF, INF)
var _shown_right := Vector2(INF, INF)
var _shown_drop := INF
## Iris lowered on the eye, in eye UV (a line face sets it, hybrid_expressions.gd "iris_drop"): with
## the lids squeezing from both sides the iris sits in the middle of what stays open (dev 2026-11-02).
var iris_drop := 0.0
## Drawn show lids (dev 2026-11-02, show_lid.gd): amount, upper and lower lid, iris squash, as the
## line face last set them; the same values again set nothing.
var _show_lid := []
var _lash_materials: Array[ShaderMaterial] = []
var _lid_coat_ready := false
const SHOW_LID := preload("res://world/characters/openpony/show_lid.gd")

## The expression's lids drawn on the eye: amount 0 leaves the eye as modelled. upper / lower are
## show_lid.gd lids [base, slant, saddle, line]; shape squashes the iris (x wider, y taller); ends are
## the opening's outer and nose ends in nose-x and its roundness.
func set_show_lid(amount: float, upper: Vector4, lower: Vector4, shape: Vector2,
		ends := Vector3(-9.0, 9.0, 2.0)) -> void:
	if not show_eyes_enabled: return
	var values := [amount, upper, lower, shape, ends]
	if values == _show_lid: return
	_show_lid = values
	if not _lid_coat_ready: _ready_show_lid()
	for material in _eye_layers:
		if not material.has_meta("show_iris"): continue
		material.set_shader_parameter("lid_amount", amount)
		material.set_shader_parameter("lid_upper", upper)
		material.set_shader_parameter("lid_lower", lower)
		material.set_shader_parameter("lid_ends", Vector4(ends.x, ends.y, ends.z, 0.0))
		material.set_shader_parameter("iris_shape", shape.lerp(Vector2.ONE, 1.0 - clampf(amount, 0.0, 1.0)))
	for material in _lash_materials:
		material.set_shader_parameter("lid_amount", amount)
		material.set_shader_parameter("lid_upper", upper)
		material.set_shader_parameter("lid_lower", lower)
		material.set_shader_parameter("lid_ends", Vector4(ends.x, ends.y, ends.z, 0.0))

## The drawn lid wears the head's own coat (its cel fill and shade); the lash rings hide under it.
func _ready_show_lid() -> void:
	_lid_coat_ready = true
	var fill := coat_color
	var shade := Color(0, 0, 0, 0)
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.name == "Eyelashes":
			# The ring carries its rest lid frame (show_lid.gd baked_ring); its overrides stay.
			var overrides: Array[Material] = []
			for si in mesh.mesh.get_surface_count(): overrides.append(mesh.get_surface_override_material(si))
			mesh.mesh = SHOW_LID.baked_ring(mesh.mesh)
			for si in overrides.size(): mesh.set_surface_override_material(si, overrides[si])
			for si in mesh.mesh.get_surface_count():
				var lash := mesh.get_active_material(si) as ShaderMaterial
				if lash != null and lash not in _lash_materials: _lash_materials.append(lash)
		elif mesh.name == "Head":
			var coat := mesh.get_active_material(0) as ShaderMaterial
			if coat != null and coat.get_shader_parameter("color") is Color:
				fill = coat.get_shader_parameter("color")
				var shadow: Variant = coat.get_shader_parameter("shadow_color")
				if shadow is Color: shade = shadow
	for material in _eye_layers:
		if not material.has_meta("show_iris"): continue
		material.set_shader_parameter("lid_coat", fill)
		material.set_shader_parameter("lid_coat_shade", shade)

func set_face_sculpt(weights: Dictionary, shape := Vector2.ONE) -> void:
	if face_sculpt == null: return
	face_sculpt.set_weights(weights)
	if not _lid_coat_ready: _ready_show_lid()
	var amount := 0.0
	for weight: float in weights.values(): amount = maxf(amount, weight)
	if shape == _sculpt_iris_shape and is_equal_approx(amount, _sculpt_amount): return
	_sculpt_iris_shape = shape
	_sculpt_amount = amount
	_apply_sculpt_appearance()


func _apply_sculpt_appearance() -> void:
	var visible := 1.0 - smoothstep(0.0, .85, _sculpt_closure)
	for material in _eye_layers:
		if material.has_meta("show_iris"):
			material.set_shader_parameter("iris_shape", Vector2.ONE.lerp(_sculpt_iris_shape, visible))
			material.set_shader_parameter("iris_projection", visible if _sculpt_amount > .00001 else 0.0)
	for material in _lash_materials: material.set_shader_parameter("sculpt_amount", _sculpt_amount * visible)


func _update_eye_projection() -> void:
	if _eye_head_bone < 0: return
	var unpose := (skeleton.get_bone_global_pose(_eye_head_bone) * _eye_bind_pose).affine_inverse()
	if unpose.is_equal_approx(_eye_rest_from_pose): return
	_eye_rest_from_pose = unpose
	if face_sculpt != null: face_sculpt.set_lid_projection(unpose)
	for material in _eye_layers:
		if material.has_meta("show_iris"): material.set_shader_parameter("eye_rest_from_pose", unpose)


## Pupil size, white heart highlights and their position are independent of lid geometry.
func set_eye_details(pupil: float, hearts: float, shine_offset: float) -> void:
	var details := Vector3(clampf(pupil, .15, 1.35), clampf(hearts, 0.0, 1.0), clampf(shine_offset, -.1, .4))
	if details.is_equal_approx(_eye_details): return
	_eye_details = details
	for material in _eye_layers:
		if not material.has_meta("show_iris"): continue
		material.set_shader_parameter("pupil_dilation", details.x)
		material.set_shader_parameter("heart_shines", details.y)
		material.set_shader_parameter("shine_drop", details.z)


func update_show_eyes(left_angles: Vector2, right_angles: Vector2, lid_closure: float) -> void:
	if not show_eyes_enabled: return
	if face_sculpt != null: face_sculpt.set_closure(lid_closure)
	if face_sculpt != null and not is_equal_approx(_sculpt_closure, lid_closure):
		_sculpt_closure = lid_closure
		_apply_sculpt_appearance()
	var shown := Vector3(left_angles.x, left_angles.y, lid_closure)
	if SKIP_SAME_EYES and shown == _shown_eyes and right_angles == _shown_right and iris_drop == _shown_drop: return
	_shown_eyes = shown
	_shown_right = right_angles
	_shown_drop = iris_drop
	for material in _eye_layers:
		if material.has_meta("show_iris"):
			material.set_shader_parameter("gaze_uv",show_gaze_uv(left_angles if material.get_meta("left_eye") else right_angles) + Vector2(0.0, iris_drop))
	if _show_eye_mesh != null:
		_show_eye_mesh.set_blend_shape_value(0,smoothstep(0.0,.45,lid_closure))


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_process(delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("head_process", started)
