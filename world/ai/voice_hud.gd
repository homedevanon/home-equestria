extends Node
## The mic icon: shows when the game is listening, pulses while it hears you, and reports
## thinking / speaking. Desktop: a CanvasLayer icon bottom-centre. VR: a small unlit quad
## parked low in the camera's view (no post-process, so it is drawn into both eyes).

const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")
const CAPTION := preload("res://world/ui/speech_caption.gd")

const COLORS := {
	"off": Color(0.55, 0.55, 0.55, 0.35),
	"listening": Color(1.0, 1.0, 1.0, 0.85),
	"hearing": Color(0.45, 1.0, 0.55, 1.0),
	"feedback": Color(0.8, 0.65, 1.0, 1.0),
	"muted": Color(0.6, 0.6, 0.6, 0.5),
	"thinking": Color(1.0, 0.85, 0.35, 1.0),
	"speaking": Color(0.55, 0.8, 1.0, 1.0),
	"error": Color(1.0, 0.35, 0.35, 1.0),
}

var state := "off"
var detail := ""
var _texture: Texture2D
var _rect: TextureRect
var _label: Label
## Her words at the bottom of the screen on desktop (world/ui/speech_caption.gd); `_label` is
## for the listening/thinking status.
var _caption: CAPTION
var _sprite: Sprite3D
var _label3d: Label3D
var _time := 0.0
var _pulse := 0.0
var _line_text := ""
var _speaker := ""
var _voice: WeakRef
var _word_cues: Array = []
var _revealed := 0
var _dialogue: OVERHEAD
var _viewer: WeakRef
## Until when the "Speech off" hint shows after a talk press with speech turned off.
var _off_hint_until := -1.0
const OFF_HINT := "Speech off: Pause > AI & voice > Speech"
## A desktop activity that shows the spoken words in its own panel (the board view,
## world/minigames/board_games/board_view.gd): while it is set, no caption at the bottom and
## no words over her head; each line arrives through words_shown as it is revealed instead.
var words_owner: Object
var _words_were_elsewhere := false
signal words_shown(actor: Node, speaker: String, text: String, shown: int)

func start_line(speaker:String,text:String,actor:Node,cues:Array=[]) -> void:
	_clear_dialogue()
	_line_text="";_speaker="";_word_cues=[];_revealed=0
	if not is_instance_valid(actor) or not actor is Node3D or not actor.is_inside_tree():
		set_state(state, "")
		return
	_speaker=speaker;_line_text=text;_voice=weakref(actor);_revealed=0
	_word_cues=cues.duplicate(true)
	_dialogue=OVERHEAD.new()
	_dialogue.set_fallback_labels(_caption, _label3d, speaker)
	_dialogue.caption_full=text
	add_child(_dialogue)
	if is_instance_valid(words_owner): _dialogue.subtitle_enabled = false
	var camera: Node3D = _viewer.get_ref() if _viewer != null else null
	_dialogue.show_for(actor, camera)
	if _word_cues.is_empty():
		var progress:Dictionary=actor.speech_progress() if actor.has_method("speech_progress") else {}
		_word_cues=preload("res://world/ai/speech_sentences.gd").timed_words(text,float(progress.get("duration",maxf(1.0,text.length()*.065))))
	set_state("speaking",speaker+": ")
	words_shown.emit(actor, speaker, text, 0)

func finish_line() -> void:
	if not _line_text.is_empty():
		var page := preload("res://world/ai/speech_sentences.gd").display_page(_line_text,_line_text.length())
		if is_instance_valid(_dialogue): _dialogue.text=page; _dialogue.caption_text=_line_text
		set_state("speaking",_speaker+": "+page)
		words_shown.emit(_voice.get_ref() if _voice != null else null, _speaker, _line_text, _line_text.length())
	# Retain the weak actor anchor through the short completed-line pause.
	_line_text="";_word_cues=[]

func _clear_dialogue() -> void:
	if is_instance_valid(_dialogue):
		_dialogue.clear()
		_dialogue.queue_free()
	_dialogue=null
	_voice=null

func _reveal_words() -> void:
	var actor: Node = _voice.get_ref() if _voice != null else null
	if _voice != null and (not is_instance_valid(actor) or not actor.is_inside_tree() or actor.is_queued_for_deletion()):
		_clear_dialogue();_line_text="";_word_cues=[]
		set_state(state, "")
		return
	if state!="speaking" or _line_text.is_empty() or actor==null:return
	if not actor.has_method("speech_progress"):return
	var progress:Dictionary=actor.speech_progress()
	var elapsed:=float(progress.get("time",0.0))
	var end:=_revealed
	for cue in _word_cues:
		if float(cue.start)>elapsed:break
		end=maxi(end,int(cue.end_char))
	if end!=_revealed:
		_revealed=end
		var page := preload("res://world/ai/speech_sentences.gd").display_page(_line_text,end)
		if is_instance_valid(_dialogue): _dialogue.text=page; _dialogue.caption_text=_line_text.left(end)
		set_state("speaking",_speaker+": "+page)
		words_shown.emit(actor, _speaker, _line_text, end)

func _exit_tree() -> void:
	_clear_dialogue()
	# XR status nodes are camera children, not owned descendants of this HUD.
	if is_instance_valid(_sprite): _sprite.queue_free()
	if is_instance_valid(_label3d): _label3d.queue_free()


## The speech input, so the glyph can follow the push-to-talk button (set by the director).
var speech: Node

func setup(camera: Node3D, xr: bool) -> void:
	_viewer = weakref(camera) if is_instance_valid(camera) else null
	_texture = _mic_texture()
	if xr and camera != null:
		_sprite = Sprite3D.new()
		_sprite.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_sprite.name = "VoiceMic"
		_sprite.texture = _texture
		_sprite.pixel_size = 0.0009
		_sprite.shaded = false
		_sprite.double_sided = true
		_sprite.no_depth_test = true
		_sprite.render_priority = 100
		_sprite.position = Vector3(0.25, -0.20, -0.75)
		camera.add_child(_sprite)
		preload("res://world/ui/head_locked_hud.gd").attach(camera,_sprite)
		_label3d = Label3D.new()
		_label3d.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_label3d.name = "VoiceStatus"
		_label3d.pixel_size = 0.0007
		_label3d.font_size = 40
		_label3d.outline_size = 10
		_label3d.no_depth_test = true
		_label3d.shaded = false
		_label3d.double_sided = true
		_label3d.render_priority = 100
		_label3d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label3d.width = 900.0
		_label3d.autowrap_mode = TextServer.AUTOWRAP_WORD
		_label3d.position = Vector3(0.0, -0.43, -0.85)
		camera.add_child(_label3d)
		preload("res://world/ui/head_locked_hud.gd").attach(camera,_label3d)
	else:
		var layer := CanvasLayer.new()
		layer.name = "VoiceHud"
		layer.layer = 90
		add_child(layer)
		_rect = TextureRect.new()
		_rect.texture = _texture
		_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_rect.custom_minimum_size = Vector2(48, 48)
		_rect.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_rect.position = Vector2(-24, -84)
		_rect.size = Vector2(48, 48)
		layer.add_child(_rect)
		_label = Label.new()
		_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_label.position = Vector2(-300, -32)
		_label.size = Vector2(600, 24)
		_label.position.y=-140;_label.size.y=120
		_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		_label.add_theme_constant_override("outline_size", 4)
		layer.add_child(_label)
		_caption = CAPTION.new()
		layer.add_child(_caption)
	set_state(state, detail)


func set_state(value: String, text := "") -> void:
	if value!="speaking":
		_line_text="";_word_cues=[];_clear_dialogue()
	state = value
	detail = text
	# Speech turned off: the hint only flashes when the talk button is pressed (_process); a
	# text-only player's typing box sat under a standing "Speech off" line (player 2026-10-30).
	# The shared presentation fills these same labels when looking away from the actor.
	var status_text := "" if value == "speaking" else text
	if _label != null:
		_label.text = "Feedback" if value == "feedback" else status_text
		# Anchor offsets, not position: once in the tree, position is absolute within the
		# layer, so position.y = -140 put every subtitle above the top of the screen (2026-09-22).
		_label.offset_top = -84 if value == "feedback" else -140
		_label.offset_bottom = _label.offset_top + (48 if value == "feedback" else 120)
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER if value == "feedback" else VERTICAL_ALIGNMENT_TOP
	if _label3d != null:
		_label3d.text = "" if value == "speaking" else ("Feedback" if value == "feedback" else (("%s\n%s" % [state, status_text]) if status_text != "" else state))
		_label3d.position.y = -.24 if value == "feedback" else -.30
	if state == "hearing":
		_pulse = 1.0
	if value == "speaking" and is_instance_valid(_dialogue): _dialogue._update_pose()


func _process(delta: float) -> void:
	var elsewhere := is_instance_valid(words_owner)
	# Hidden while the owner shows the words; afterwards back as the subtitle setting has it
	# (Settings.apply_subtitles), never shown just because no owner is set.
	if _label != null:
		if elsewhere and _label.visible: _label.visible = false
		elif not elsewhere and _words_were_elsewhere: _label.visible = _subtitles_on()
	if is_instance_valid(_dialogue):
		if elsewhere: _dialogue.subtitle_enabled = false
		elif _words_were_elsewhere: _dialogue._apply_settings()
	_words_were_elsewhere = elsewhere
	_reveal_words()
	if is_instance_valid(_dialogue): _dialogue._update_pose()
	_time += delta
	var color: Color = COLORS.get(state, COLORS["off"])
	if state == "hearing":
		color = color.lerp(Color(1, 1, 1, 1), 0.5 + 0.5 * sin(_time * 12.0))
	elif state == "thinking":
		color.a = 0.6 + 0.4 * (0.5 + 0.5 * sin(_time * 5.0))
	elif state == "speaking":
		color.a = 0.7 + 0.3 * (0.5 + 0.5 * sin(_time * 9.0))
	# The mic glyph only while push-to-talk is held (dev 2026-09-23), desktop and VR.
	var held: bool = speech != null and speech.has_method("_ptt_pressed") and speech._ptt_pressed()
	if state == "off" and detail == "" and _label != null:
		if held: _off_hint_until = _time + 2.0
		_label.text = OFF_HINT if _time < _off_hint_until else ""
	if _rect != null:
		_rect.modulate = color
		_rect.visible = held and state != "feedback"
	# VR: the text only while she works.
	if _sprite != null:
		_sprite.modulate = color
		_sprite.visible = held
	if _label3d != null:
		if state != "speaking":
			_label3d.modulate = color
			_label3d.visible = state in ["thinking", "error", "feedback"]


func _subtitles_on() -> bool:
	var settings := get_node_or_null("/root/Settings")
	var value: Variant = settings.call("get_value", "access/subtitles") if settings != null and settings.has_method("get_value") else null
	return value == null or bool(value)


## A microphone glyph drawn into an image: capsule head, cradle arc, stem and base.
static func _mic_texture() -> Texture2D:
	var size := 96
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var white := Color(1, 1, 1, 1)
	for y in size:
		for x in size:
			var px := float(x) + 0.5
			var py := float(y) + 0.5
			var a := 0.0
			# Capsule: centre column 48, from y 14 to 52, radius 13.
			var cx := 48.0
			var cy := clampf(py, 27.0, 40.0)
			if Vector2(px - cx, py - cy).length() <= 13.0:
				a = 1.0
			# Cradle arc: ring radius 21 around (48, 40), lower half only, thickness 4.
			var ring := Vector2(px - 48.0, py - 40.0)
			var r := ring.length()
			if py >= 40.0 and absf(r - 21.0) <= 2.2:
				a = 1.0
			# Stem and base.
			if absf(px - 48.0) <= 2.0 and py >= 60.0 and py <= 76.0:
				a = 1.0
			if absf(py - 77.0) <= 2.2 and absf(px - 48.0) <= 14.0:
				a = 1.0
			if a > 0.0:
				image.set_pixel(x, y, white)
	return ImageTexture.create_from_image(image)
