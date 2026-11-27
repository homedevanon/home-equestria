extends Node3D
## One physical text plane shared by both eyes: the words in the speaker's coat colour (lifted
## when dark) with a thick black outline on the letters themselves, no plate behind them (dev
## 2026-10-01: "the black box behind the text shouldnt exist i meant a black border around the
## letters"; text "basically just bigger"). Beyond NEAR_DISTANCE the plane grows with distance,
## so the words keep their size on screen instead of shrinking away.
## A small 2D text viewport redraws only when content changes. Its physical quad uses a fog-free
## material; Label3D cannot disable its own fog.
## Looking away routes the same words to the bottom caption (world/ui/speech_caption.gd on
## desktop, a head-locked Label3D in VR). The "Pony speech text" setting (access/speech_text) can
## keep them on that caption always; auto does so in VR.
const PIXEL_SIZE := 0.0026
const FONT_SIZE := 48
const OUTLINE := 14
const WRAP_WIDTH := 760.0
const PADDING := Vector2(0.035, 0.022)
const BORDER_WIDTH := 0.006
const NEAR_DISTANCE := 2.5
const MAX_GROWTH := 6.0
## Text colours darker than this (relative luminance) are lifted toward white over the outline.
const MIN_LUMINANCE := 0.35
const CAPTION := preload("res://world/ui/speech_caption.gd")

var text := "":
	set(value):
		text = value
		if is_instance_valid(label):
			label.text = value
			_queue_layout()
var label: Label
var ink: MeshInstance3D
var text_viewport: SubViewport
var pixel_size := PIXEL_SIZE
var plate: MeshInstance3D
var border: MeshInstance3D
var speaker_color := Color.WHITE
var plate_color := Color.BLACK
var border_color := Color.WHITE
var subtitle_enabled := true
var subtitle_scale := 1.0
## "auto" (overhead on desktop, caption in VR), "overhead" or "caption".
var speech_text := "auto"
var _actor: WeakRef
var _viewer: WeakRef
var _settings: Node
var _layout_pending := false
var _layout_ready := false
var looking_at_speaker := false
## Desktop: the bottom caption (world/ui/speech_caption.gd). VR: the head-locked Label3D.
var fallback_label: CAPTION
var fallback_label3d: Label3D
var _fallback_speaker := ""
var _owned_fallback: Node
## For the desktop caption: all of her line said so far (the caption rolls its lines up instead of
## paging) and the whole line (its width). Empty: the page in `text`.
var caption_text := ""
var caption_full := ""
## Her colours for the bottom caption, the same as these words: fill, outline, shadow.
var caption_palette := {}

func set_fallback_labels(desktop: CAPTION, xr: Label3D, speaker: String) -> void:
	fallback_label = desktop
	fallback_label3d = xr
	_fallback_speaker = speaker

func _ensure_fallback(viewer: Node3D) -> void:
	if is_instance_valid(fallback_label) or is_instance_valid(fallback_label3d): return
	if viewer is XRCamera3D:
		fallback_label3d = Label3D.new()
		fallback_label3d.pixel_size = .0007
		fallback_label3d.font_size = 40
		fallback_label3d.outline_size = 10
		fallback_label3d.no_depth_test = true
		fallback_label3d.shaded = false
		fallback_label3d.render_priority = 100
		fallback_label3d.width = 900.0
		fallback_label3d.autowrap_mode = TextServer.AUTOWRAP_WORD
		fallback_label3d.position = Vector3(0, -.30, -.7)
		viewer.add_child(fallback_label3d)
		_owned_fallback = fallback_label3d
	else:
		var layer := CanvasLayer.new()
		layer.layer = 90
		add_child(layer)
		_owned_fallback = layer
		fallback_label = CAPTION.new()
		layer.add_child(fallback_label)

func _update_fallback(show_words: bool) -> void:
	if is_instance_valid(fallback_label):
		if show_words:
			fallback_label.show_line(_fallback_speaker, caption_palette, text if caption_text.is_empty() else caption_text,
				text if caption_full.is_empty() else caption_full)
		else:
			fallback_label.hide_line()
	var words := ((_fallback_speaker + ": ") if not _fallback_speaker.is_empty() else "") + text if show_words else ""
	if is_instance_valid(fallback_label3d):
		if fallback_label3d.text != words: fallback_label3d.text = words
		fallback_label3d.visible = show_words
		# Her colour while it carries her words, over its black outline as above her head.
		fallback_label3d.modulate = caption_palette.get("fill", Color.WHITE) if show_words else Color.WHITE
		fallback_label3d.font_size = roundi(40 * subtitle_scale)

## Whether the words may go overhead at all; otherwise they stay on the HUD caption.
## VR is the headset camera, the same test _ensure_fallback uses.
func _overhead_allowed(viewer: Node3D) -> bool:
	match speech_text:
		"overhead": return true
		"caption": return false
	return not (viewer is XRCamera3D)

## Bridal-carried (player/interactor.gd), her words sit too close and askew to read overhead.
static func _cradled(actor: Node3D) -> bool:
	var carry: Variant = actor.get("carry")
	return carry is RefCounted and carry.get("cradle_goal") == true

## Bridal carried, the caption is where all of her words go (the carry controls sit in the corner
## instead, world/ui/control_card.gd): it keeps more of her lines before rolling them away.
const CRADLED_CAPTION_LINES := 5
func _cradle_caption(cradled: bool) -> void:
	if is_instance_valid(fallback_label): fallback_label.max_lines = CRADLED_CAPTION_LINES if cradled else CAPTION.MAX_LINES

func _speaker_in_view(viewer: Node3D, anchor: Vector3) -> bool:
	if not is_instance_valid(viewer) or not viewer.is_inside_tree(): return false
	var toward := anchor - viewer.global_position
	if not toward.is_finite() or toward.length_squared() < .0001: return false
	# Small hysteresis avoids alternating HUD/overhead at the attention boundary.
	var threshold := .76 if looking_at_speaker else .80
	if (-viewer.global_basis.z).normalized().dot(toward.normalized()) < threshold: return false
	if viewer is Camera3D:
		if viewer.is_position_behind(anchor): return false
		var rect := viewer.get_viewport().get_visible_rect()
		if not rect.has_point(viewer.unproject_position(anchor)): return false
	return true

## The speaker's colour, lifted toward white until it reads over a black outline.
static func _readable(colour: Color) -> Color:
	var result := colour
	for i in 8:
		var linear := result.srgb_to_linear()
		if 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b >= MIN_LUMINANCE: break
		result = result.lerp(Color.WHITE, 0.25)
	return Color(result, 1.0)

static func palette_for(coat: Color) -> Dictionary:
	var ink := Color(coat.r, coat.g, coat.b, 1.0)
	var linear := ink.srgb_to_linear()
	var luminance := 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b
	var black_contrast := (luminance + 0.05) / 0.05
	var white_contrast := 1.05 / (luminance + 0.05)
	var background := Color.BLACK if black_contrast >= white_contrast else Color.WHITE
	return {"text": ink, "plate": background, "border": Color.WHITE if background == Color.BLACK else Color.BLACK,
		"contrast": maxf(black_contrast, white_contrast)}

func _init() -> void:
	name = "OverheadDialogue"
	border = _quad("Border", 70)
	plate = _quad("Plate", 71)
	add_child(border)
	add_child(plate)
	text_viewport = SubViewport.new()
	text_viewport.name = "TextCanvas"
	text_viewport.disable_3d = true
	text_viewport.transparent_bg = true
	text_viewport.size = Vector2i(int(WRAP_WIDTH) + OUTLINE * 2, 64)
	text_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	text_viewport.gui_disable_input = true
	add_child(text_viewport)
	label = Label.new()
	label.name = "Words"
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_constant_override("outline_size", OUTLINE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	var font_path := str(ProjectSettings.get_setting("dev/theme/custom_font", ""))
	if not font_path.is_empty():
		var font := load(font_path) as Font
		# From its outlines, so the thick outline is drawn in full (CAPTION.outlined()).
		if font != null: label.add_theme_font_override("font", CAPTION.outlined(font))
	label.size = Vector2(WRAP_WIDTH, 1.0)
	label.position = Vector2(OUTLINE, OUTLINE)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_viewport.add_child(label)
	ink = _quad("Ink", 72)
	(ink.material_override as StandardMaterial3D).albedo_texture = text_viewport.get_texture()
	add_child(ink)
	# No plate or border behind the words: the outline carries the contrast.
	plate.visible = false
	border.visible = false
	visible = false

func _quad(node_name: String, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = QuadMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# All three planes use the same transparent queue and fog-free shader path.
	# Plate/border alpha stays exactly 1; only the text texture contains coverage alpha.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = priority
	material.disable_fog = true
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node

func _ready() -> void:
	# An actor parent may be scaled or tilted while held. Text remains metre-sized/upright.
	top_level = true
	_settings = get_node_or_null("/root/Settings")
	if is_instance_valid(_settings):
		_settings.changed.connect(_settings_changed)
	_apply_settings()
	_queue_layout()

func show_for(actor: Node3D, viewer: Node3D = null) -> void:
	set_process(true)
	_actor = weakref(actor) if is_instance_valid(actor) else null
	_viewer = weakref(viewer) if is_instance_valid(viewer) else null
	var coat := Color.WHITE
	if is_instance_valid(actor):
		var identity: Variant = actor.get("identity")
		if identity is Resource:
			var value: Variant = identity.get("coat_fill")
			if value is Color: coat = value
			if _fallback_speaker.is_empty(): _fallback_speaker = str(identity.get("display_name"))
	var palette := palette_for(coat)
	speaker_color = _readable(palette.text)
	# The caption at the bottom writes her words as they look here.
	caption_palette = {"fill": speaker_color, "outline": Color.BLACK, "shadow": Color.BLACK}
	plate_color = palette.plate
	border_color = palette.border
	label.add_theme_color_override("font_color", speaker_color)
	(plate.material_override as StandardMaterial3D).albedo_color = plate_color
	(border.material_override as StandardMaterial3D).albedo_color = border_color
	_update_pose()
	_queue_layout()

func clear() -> void:
	_actor = null
	_viewer = null
	text = ""
	visible = false
	looking_at_speaker = false
	_update_fallback(false)
	set_process(false)

func _settings_changed(key: String) -> void:
	if key in ["access/subtitles", "access/subtitle_scale", "access/speech_text"]: _apply_settings()

func _apply_settings() -> void:
	if is_instance_valid(_settings):
		subtitle_enabled = bool(_settings.get_value("access/subtitles"))
		subtitle_scale = float(_settings.get_value("access/subtitle_scale")) / 100.0
		speech_text = str(_settings.get_value("access/speech_text"))
	pixel_size = PIXEL_SIZE * subtitle_scale
	_queue_layout()

func _queue_layout() -> void:
	# Coalesce word/settings changes after the 2D Label updates its line layout.
	# Main-viewport texture dependencies render UPDATE_ONCE before sampling its ink.
	visible = false
	_layout_ready = false
	if _layout_pending or not is_inside_tree(): return
	_layout_pending = true
	_sync_layout.call_deferred()

func _sync_layout() -> void:
	_layout_pending = false
	if not is_inside_tree() or text.strip_edges().is_empty(): return
	label.size = Vector2(WRAP_WIDTH, 1.0)
	var height := maxf(label.get_minimum_size().y, label.get_theme_font("font").get_height(FONT_SIZE))
	label.size = Vector2(WRAP_WIDTH, ceilf(height))
	text_viewport.size = Vector2i(int(WRAP_WIDTH) + OUTLINE * 2, ceili(height) + OUTLINE * 2)
	var ink_size := Vector2(text_viewport.size) * pixel_size
	var padding := PADDING * subtitle_scale
	var size := ink_size + padding * 2.0
	(ink.mesh as QuadMesh).size = ink_size
	(plate.mesh as QuadMesh).size = size
	(border.mesh as QuadMesh).size = size + Vector2.ONE * BORDER_WIDTH * 2.0 * subtitle_scale
	# Anchor the bottom edge above the anatomical head point, not the text's centre.
	var center := Vector3(0.0, size.y * 0.5 + BORDER_WIDTH * subtitle_scale, 0.0)
	plate.position = center
	border.position = center - Vector3(0.0, 0.0, 0.001)
	ink.position = center + Vector3(0.0, 0.0, 0.001)
	text_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_layout_ready = true
	_update_pose()

func _process(_delta: float) -> void:
	_update_pose()

## Extra height of the bubble's bottom edge above the speech indicator point, metres.
const BUBBLE_LIFT := 0.15

func _update_pose() -> void:
	if not is_inside_tree(): return
	var actor: Node3D = _actor.get_ref() if _actor != null else null
	if not is_instance_valid(actor) or not actor.is_inside_tree() or actor.is_queued_for_deletion():
		clear()
		return
	var anchor: Vector3 = actor.speech_indicator_point() if actor.has_method("speech_indicator_point") else (actor.listen_point() if actor.has_method("listen_point") else actor.global_position) + Vector3.UP * 0.4
	# Higher than the speaking dots, clear of her ears and mane (dev 2026-10-14).
	anchor += Vector3.UP * BUBBLE_LIFT
	if not anchor.is_finite():
		visible = false
		looking_at_speaker = false
		_update_fallback(false)
		return
	var viewer: Node3D = _viewer.get_ref() if _viewer != null else null
	if not is_instance_valid(viewer): viewer = preload("res://world/player_view.gd").camera(self)
	var facing := viewer.global_basis.orthonormalized() if is_instance_valid(viewer) and viewer.is_inside_tree() else Basis.IDENTITY
	if not facing.is_finite():
		visible = false
		looking_at_speaker = false
		_update_fallback(false)
		return
	var growth := 1.0
	if is_instance_valid(viewer) and viewer.is_inside_tree():
		growth = clampf(viewer.global_position.distance_to(anchor) / NEAR_DISTANCE, 1.0, MAX_GROWTH)
	global_transform = Transform3D(facing.scaled(Vector3.ONE * growth), anchor)
	_ensure_fallback(viewer)
	looking_at_speaker = _overhead_allowed(viewer) and not _cradled(actor) and actor.is_visible_in_tree() and _speaker_in_view(viewer, anchor)
	_cradle_caption(_cradled(actor))
	var enabled := subtitle_enabled and not text.is_empty()
	visible = enabled and _layout_ready and looking_at_speaker
	_update_fallback(enabled and not looking_at_speaker)

func _exit_tree() -> void:
	if is_instance_valid(_owned_fallback) and _owned_fallback.get_parent() != self:
		_owned_fallback.queue_free()
	if is_instance_valid(_settings) and _settings.changed.is_connected(_settings_changed):
		_settings.changed.disconnect(_settings_changed)
	_actor = null
	_viewer = null
