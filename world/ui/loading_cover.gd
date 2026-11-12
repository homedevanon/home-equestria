extends Node
## Full cover while a game loads (dev 2026-09-24: "when you LOAD IN everything should be
## READY"). Desktop: a CanvasLayer over the window. Headset: a dark sphere around the camera
## drawn over everything, with the same text in front of the eyes. game.gd shows it before the
## first frame of the world and removes it once the ponies are out and the pipelines are warm.
##
## Its look (2026-10-27): the menus' twilight sky (world/ui/menu_card.gd) with the logo, the
## world being entered and a bar. The title (world/ui/title_screen.gd) raises one over the menu as
## soon as a game is chosen, and `trip` carries its world and progress over the scene change to
## the game's own cover. No frame is drawn while the world is built, so the title's last frame
## (this cover) stays on screen until the game's takes over. It stands above a new world's shut
## eyes (world/life/arrival_wake.gd) and fades away onto them.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const SKY := preload("res://world/ui/menu_card.gd")

const INK := Color("0e1420")
const GOLD := Color("edd6a2")
## Over the wake's eyelids (CanvasLayer 121, sphere priority 110), under the pause menu (140).
const LAYER := 122
const PRIORITY := 112
const FADE_OUT := 0.6
## What the title's cover hands the game's: {title, line, icon, tint, progress}.
static var trip := {}
## Flavour lines (dev 2026-11-11: "on loading screens, add flavor splash text ... in the
## equestrian font"): one is drawn per load, in the heading font, under the logo. The title's
## cover and the game's cover of the same load show the same line.
const SPLASHES := [
	"THREE STARS - GR15", ">everycreature", "No hooves", "MARES", "/)", ":ilovethem:", ">rape", "IWTCIRD", "Lurk moar",
	"Ziggers tongue my ponut!", "The best cheap knockoff of PonyPonyParadise crudely stuffed into goat simulator!",
	"Giddy up!", ">aislop >>>/trash/", "MARESMARESMARESMARES", "I LOVE THEM!", "Full of snowpity!", "Mare is for care!",
]
static var splash := ""

const BAR_SHADER := """
shader_type canvas_item;
uniform vec2 size_px = vec2(560.0, 10.0);
uniform float fill = 0.0;
uniform float motion = 1.0;
uniform vec4 track : source_color = vec4(1.0, 1.0, 1.0, 0.13);
uniform vec4 from_color : source_color = vec4(0.965, 0.651, 0.851, 1.0);
uniform vec4 to_color : source_color = vec4(0.753, 0.435, 0.859, 1.0);

float pill(vec2 p, vec2 half_size) {
	vec2 q = abs(p) - half_size + vec2(half_size.y);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - half_size.y;
}

void fragment() {
	// The cover's fade arrives in COLOR (its modulate).
	vec4 tint = COLOR;
	vec2 px = UV * size_px;
	vec2 half_size = size_px * 0.5;
	float outer = clamp(0.5 - pill(px - half_size, half_size), 0.0, 1.0);
	float w = max(fill * size_px.x, size_px.y);
	float inner = clamp(0.5 - pill(px - vec2(w * 0.5, half_size.y), vec2(w * 0.5, half_size.y)), 0.0, 1.0) * step(0.0005, fill);
	vec3 colour = mix(from_color.rgb, to_color.rgb, clamp(px.x / max(1.0, w), 0.0, 1.0));
	// A soft gleam runs along the filled part.
	float sweep = fract(TIME * 0.28) * (w + 160.0) - 80.0;
	colour += vec3(0.32) * motion * exp(-pow((px.x - sweep) / 46.0, 2.0));
	vec4 col = mix(track, vec4(colour, 1.0), inner);
	COLOR = vec4(col.rgb, col.a * outer) * tint;
}
"""
static var _bar_shader: Shader

var _layer: CanvasLayer
var _label: Label
var _sphere: MeshInstance3D
var _label3d: Label3D
var _root: Control
var _sky: Control
var _content: VBoxContainer
var _picture: TextureRect
var _badge: Panel
var _name: Label
var _line: Label
var _bar: Control
var _caption: Label
var _note: Label
var _splash: Label
var _splash3d: Label3D
var _gaps: Array[Control] = []
var _rig: Node3D
var _logo3d: Sprite3D
var _title3d: Label3D
var _line3d: Label3D
var _track3d: MeshInstance3D
var _fill3d: MeshInstance3D
var _logo_mode := false
var _shown := 0.0
var _target := 0.0
var _smooth := false
var _fading: Tween

func setup(camera: Camera3D, xr: bool) -> void:
	# Seated VR has no room-scale rig (xr false) but still looks through the headset.
	xr = xr or camera is XRCamera3D
	_layer = CanvasLayer.new()
	_layer.layer = LAYER
	# The headset gets the sphere below; the layer stays on the desktop window, off the seated
	# virtual screen (world/ui/virtual_screen.gd).
	_layer.set_meta(&"no_virtual_screen", true)
	add_child(_layer)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = STYLE.theme()
	_layer.add_child(_root)
	_back = ColorRect.new()
	_back.color = STYLE.INK
	_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	_back.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_back)
	_sky = SKY.new()
	_sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Edge to edge: no rounded corners, rim or glow inside the window.
	_sky.radius = 0.0; _sky.inset = -6.0; _sky.glow = 0.0
	_root.add_child(_sky)
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 34)
	_label.add_theme_color_override("font_color", GOLD)
	_label.hide()
	_root.add_child(_label)
	_build_page()
	if xr and camera != null: _build_headset(camera)
	get_viewport().size_changed.connect(_fit)
	if splash.is_empty(): splash = SPLASHES[randi() % SPLASHES.size()]
	_splash.text = splash
	if _splash3d != null: _splash3d.text = splash
	show_text("Loading Equestria…")
	if not trip.is_empty():
		show_trip(str(trip.get("title", "")), str(trip.get("line", "")), str(trip.get("icon", "")), trip.get("tint", STYLE.FAINT))
		set_progress(float(trip.get("progress", 0.0)))
	_fit()

## The window's page: logo, world name with its badge, where and when, the bar and what is
## happening, centred as one group.
func _build_page() -> void:
	var margins := MarginContainer.new()
	margins.set_anchors_preset(Control.PRESET_FULL_RECT)
	margins.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(margins)
	_content = VBoxContainer.new()
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	_content.add_theme_constant_override("separation", 0)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margins.add_child(_content)
	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; _picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER; _picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	STYLE.sharp_picture(_picture, LOGO)
	_content.add_child(_picture)
	_splash = STYLE.label("", "Heading")
	_splash.add_theme_font_override("font", STYLE.HEADING)
	_splash.add_theme_color_override("font_color", GOLD)
	_splash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_splash.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(_splash)
	_gap()
	var row := HBoxContainer.new(); row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14); row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(row)
	_badge = Panel.new(); _badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE; _badge.hide()
	row.add_child(_badge)
	_name = STYLE.label("", "Heading")
	_name.add_theme_font_override("font", STYLE.HEADING)
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.hide()
	row.add_child(_name)
	_line = STYLE.label("", "Muted")
	_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_line.hide()
	_content.add_child(_line)
	_gap()
	if _bar_shader == null:
		_bar_shader = Shader.new(); _bar_shader.code = BAR_SHADER
	_bar = Control.new(); _bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var paint := ShaderMaterial.new(); paint.shader = _bar_shader
	paint.set_shader_parameter("motion", 0.0 if STYLE.still() else 1.0)
	_bar.material = paint
	_bar.draw.connect(func() -> void: _bar.draw_rect(Rect2(Vector2.ZERO, _bar.size), Color.WHITE))
	_bar.resized.connect(func() -> void: paint.set_shader_parameter("size_px", _bar.size))
	_content.add_child(_bar)
	_gap()
	_caption = STYLE.label("", "Muted")
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(_caption)
	_note = STYLE.label("", "Faint")
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.hide()
	_content.add_child(_note)

func _gap() -> void:
	var gap := Control.new(); gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(gap); _gaps.append(gap)

## Sizes follow the window's height (laid out for 900 pixels).
func _fit() -> void:
	if _content == null or not is_inside_tree(): return
	var view := _root.get_viewport_rect().size
	var k := maxf(0.4, view.y / 900.0)
	(_content.get_parent() as MarginContainer).add_theme_constant_override("margin_left", int(view.x * 0.06))
	(_content.get_parent() as MarginContainer).add_theme_constant_override("margin_right", int(view.x * 0.06))
	var logo_height := minf(330.0 * k, view.x * 0.8 * LOGO.get_height() / LOGO.get_width())
	_picture.custom_minimum_size = Vector2(logo_height * LOGO.get_width() / LOGO.get_height(), logo_height)
	for i in _gaps.size(): _gaps[i].custom_minimum_size.y = [12.0, 34.0, 14.0][i] * k
	var name_size := int(round(46 * k))
	_name.add_theme_font_size_override("font_size", name_size)
	_line.add_theme_font_size_override("font_size", int(round(22 * k)))
	_caption.add_theme_font_size_override("font_size", int(round(21 * k)))
	_splash.add_theme_font_size_override("font_size", int(round(30 * k)))
	_note.add_theme_font_size_override("font_size", int(round(17 * k)))
	_badge.custom_minimum_size = Vector2.ONE * round(44 * k)
	_badge.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(_tint(), 0.22), Color(_tint(), 0.75), maxi(1, int(2 * k)), 99, 0, 0)))
	for child in _badge.get_children():
		child.custom_minimum_size = _badge.custom_minimum_size * 0.62; child.size = child.custom_minimum_size
		child.position = _badge.custom_minimum_size * 0.19
	# A long world name ends in "…" instead of running off the window.
	var room := view.x * 0.88 - (_badge.custom_minimum_size.x + 14.0 if _badge.visible else 0.0)
	_name.custom_minimum_size.x = minf(room, STYLE.HEADING.get_string_size(_name.text, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x + 4.0)
	_bar.custom_minimum_size = Vector2(minf(560.0 * k, view.x * 0.7), maxf(6.0, round(10.0 * k)))

func _tint() -> Color:
	var tint: Variant = trip.get("tint", STYLE.FAINT)
	return tint if tint is Color else STYLE.FAINT

## The headset's cover: the same words and bar half a metre ahead, inside a twilight sphere.
func _build_headset(camera: Camera3D) -> void:
	_rig = Node3D.new(); _rig.name = "LoadingCoverRig"
	camera.add_child(_rig)
	var mesh := SphereMesh.new()
	mesh.radius = 0.6
	mesh.height = 1.2
	mesh.flip_faces = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = STYLE.INK
	mat.no_depth_test = true
	mat.render_priority = PRIORITY
	mesh.material = mat
	_sphere = MeshInstance3D.new()
	_sphere.name = "LoadingSphere"
	_sphere.mesh = mesh
	_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_sphere)
	_logo3d = logo_sprite(_rig)
	_logo3d.pixel_size = 0.24 / LOGO.get_width(); _logo3d.position = Vector3(0, 0.07, -0.5)
	_logo3d.render_priority = PRIORITY + 2
	_title3d = _words3d(STYLE.HEADING, 64, 0.00032, STYLE.CREAM, -0.068)
	_line3d = _words3d(STYLE.REGULAR, 40, 0.00026, STYLE.MUTED, -0.09)
	_track3d = _bar3d(Color(1, 1, 1, 0.15), 0.0)
	_fill3d = _bar3d(STYLE.PINK, 0.001)
	_label3d = _words3d(STYLE.REGULAR, 36, 0.00026, STYLE.MUTED, -0.134)
	_label3d.name = "LoadingText"
	_splash3d = _words3d(STYLE.HEADING, 48, 0.00026, GOLD, -0.168)
	_splash3d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _splash3d.width = 1150.0
	_splash3d.vertical_alignment = VERTICAL_ALIGNMENT_TOP

func _words3d(font: Font, font_size: int, pixel: float, colour: Color, y: float) -> Label3D:
	var words := Label3D.new()
	words.font = font; words.font_size = font_size; words.pixel_size = pixel
	words.modulate = colour; words.outline_size = 0
	words.position = Vector3(0, y, -0.5)
	words.no_depth_test = true; words.render_priority = PRIORITY + 2
	_rig.add_child(words)
	return words

func _bar3d(colour: Color, nearer: float) -> MeshInstance3D:
	var quad := QuadMesh.new(); quad.size = Vector2(0.2, 0.005)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = colour
	mat.no_depth_test = true
	mat.render_priority = PRIORITY + 1 + int(nearer > 0.0)
	quad.material = mat
	var bar := MeshInstance3D.new(); bar.mesh = quad
	bar.position = Vector3(0, -0.113, -0.5 + nearer)
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bar.set_meta(&"alpha", colour.a)
	_rig.add_child(bar)
	return bar

## What is happening; a second line ("Waking up the ponies…\n3 out, 9 to go") goes under it,
## quieter.
func show_text(text: String) -> void:
	if _label != null: _label.text = text
	if _label3d != null: _label3d.text = text
	if _caption != null: _caption.text = text.get_slice("\n", 0)
	show_note(text.substr(text.find("\n") + 1) if text.contains("\n") else "")

## A quieter second line under the caption ("" hides it).
func show_note(text: String) -> void:
	if _note != null: _note.text = text; _note.visible = not text.is_empty()
	if _label3d != null and not _logo_mode: _label3d.text = _caption.text + ("\n" + text if not text.is_empty() else "")

## The world being entered: its name (with its badge when `icon` names one) and a line under it.
func show_trip(title: String, line: String, icon := "", tint: Variant = STYLE.FAINT) -> void:
	trip.merge({"title": title, "line": line, "icon": icon, "tint": tint if tint is Color else STYLE.FAINT}, true)
	_name.text = title; _name.visible = not title.is_empty()
	_line.text = line; _line.visible = not line.is_empty()
	for child in _badge.get_children(): child.queue_free()
	_badge.visible = not icon.is_empty() and not title.is_empty()
	var name_colour := _tint().lerp(Color.WHITE, 0.35) if _badge.visible else STYLE.CREAM
	if _badge.visible: _badge.add_child(ICON.make(icon, 24.0, _tint()))
	_name.add_theme_color_override("font_color", name_colour)
	if _title3d != null:
		_title3d.text = title; _line3d.text = line
		_title3d.modulate = Color(name_colour, _title3d.modulate.a)
	_fit()

## How far along, 0 to 1; it never goes back. `smooth` glides there (a title that keeps drawing);
## otherwise it jumps, since a loading game draws a frame only now and then.
func set_progress(value: float, smooth := false) -> void:
	_target = maxf(_target, clampf(value, 0.0, 1.0))
	trip["progress"] = _target
	_smooth = smooth and not STYLE.still()
	if not _smooth: _shown = _target; _show_progress()

func _process(delta: float) -> void:
	if is_equal_approx(_shown, _target): return
	_shown = lerpf(_shown, _target, 1.0 - exp(-delta * 4.0))
	if absf(_shown - _target) < 0.002: _shown = _target
	_show_progress()

func _show_progress() -> void:
	if _bar != null: (_bar.material as ShaderMaterial).set_shader_parameter("fill", _shown)
	if is_instance_valid(_fill3d):
		_fill3d.scale.x = maxf(_shown, 0.001)
		_fill3d.position.x = -0.1 + 0.1 * _shown

## Fades the whole cover in over `seconds`.
func fade_in(seconds: float) -> void:
	_set_alpha(0.0)
	_fading = create_tween()
	_fading.tween_method(_set_alpha, 0.0, 1.0, maxf(0.01, seconds))

## Fully faded in, with the bar showing its value.
func is_settled() -> bool:
	return (_fading == null or not _fading.is_running()) and is_equal_approx(_shown, _target)

func _set_alpha(alpha: float) -> void:
	if is_instance_valid(_root): _root.modulate.a = alpha
	if is_instance_valid(_sphere): (_sphere.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color.a = alpha
	for words: Node3D in [_logo3d, _title3d, _line3d, _label3d, _splash3d]:
		if is_instance_valid(words): words.set("modulate", Color(words.get("modulate"), alpha))
	for bar in [_track3d, _fill3d]:
		if is_instance_valid(bar): ((bar.mesh as QuadMesh).material as StandardMaterial3D).albedo_color.a = float(bar.get_meta(&"alpha")) * alpha

## Opening title (dev 2026-09-30): the game logo (dev 2026-10-08, world/ui/title/logo.png) on
## black, the same layout as the launch scene's card (world/ui/title_screen.gd), so the logo stays
## put while the world loads behind it. The loading line drops to a small note under it.
const LOGO := preload("res://world/ui/title/logo.png")
var _logos: Array[CanvasItem] = []
var _logos3d: Array[Sprite3D] = []
var _back: ColorRect

func show_logo() -> void:
	_logo_mode = true
	_sky.hide(); _content.get_parent().hide()
	_back.color = Color.BLACK
	_label.show()
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.offset_bottom = -60
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	_splash.reparent(_root)
	_splash.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_splash.offset_top = -150; _splash.offset_bottom = -100
	_splash.add_theme_font_size_override("font_size", 28)
	_logos.append(logo_rect(_layer))
	if is_instance_valid(_sphere):
		(_sphere.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color = Color.BLACK
		for item: Node3D in [_logo3d, _title3d, _line3d, _track3d, _fill3d]: item.hide()
		_label3d.text = _label.text
		_label3d.position = Vector3(0, -0.2, -0.45); _label3d.pixel_size = 0.00035
		_label3d.modulate = Color(1, 1, 1, 0.45)
		_splash3d.position.y = -0.245
		_logos3d.append(logo_sprite(_sphere.get_parent()))

## Desktop logo: one centred TextureRect on `layer` (shared with the launch scene's card).
static func logo_rect(layer: CanvasLayer) -> TextureRect:
	var rect := TextureRect.new(); rect.texture = LOGO
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.anchor_left = 0.15; rect.anchor_right = 0.85
	rect.anchor_top = 0.04; rect.anchor_bottom = 0.84
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	layer.add_child(rect)
	return rect

## Headset logo: one sprite half a metre in front of the eyes, drawn over the cover sphere.
static func logo_sprite(camera: Node3D) -> Sprite3D:
	var sprite := Sprite3D.new(); sprite.texture = LOGO
	sprite.pixel_size = 0.30 / LOGO.get_width()
	sprite.position = Vector3(0, 0.05, -0.5)
	sprite.no_depth_test = true; sprite.render_priority = PRIORITY + 2; sprite.shaded = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED; sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(sprite)
	return sprite

## Title reveal: the black fades away over `seconds` while the logo stays, then the logo fades
## over `logo_seconds`, then the cover is gone.
func reveal(seconds: float, logo_seconds: float) -> void:
	if is_instance_valid(_label): _label.text = ""
	if is_instance_valid(_label3d): _label3d.text = ""
	if is_instance_valid(_splash): _splash.text = ""
	if is_instance_valid(_splash3d): _splash3d.text = ""
	var tree := Engine.get_main_loop() as SceneTree
	var sphere_mat: StandardMaterial3D = _sphere.mesh.surface_get_material(0) if is_instance_valid(_sphere) else null
	var t := 0.0
	while t < seconds:
		t += tree.root.get_process_delta_time() if tree.root.get_process_delta_time() > 0.0 else 1.0 / 60.0
		var a := 1.0 - smoothstep(0.0, 1.0, t / seconds)
		if is_instance_valid(_back): _back.color.a = a
		if sphere_mat != null: sphere_mat.albedo_color.a = a
		if not await SHUTDOWN.frame(self): return
	if not await SHUTDOWN.seconds(self, 0.6): return
	t = 0.0
	while t < logo_seconds:
		t += tree.root.get_process_delta_time() if tree.root.get_process_delta_time() > 0.0 else 1.0 / 60.0
		var a := 1.0 - smoothstep(0.0, 1.0, t / logo_seconds)
		for item: CanvasItem in _logos: if is_instance_valid(item): item.modulate.a = a
		for sprite: Sprite3D in _logos3d: if is_instance_valid(sprite): sprite.modulate.a = a
		if not await SHUTDOWN.frame(self): return
	for sprite: Sprite3D in _logos3d: if is_instance_valid(sprite): sprite.queue_free()
	finish()

## Loading is over: the bar fills and the cover fades out (at once on the opening title). It
## stops answering to "LoadingCover" straight away, so whatever waits for loading to end (the
## arrival story, needs, visits) starts while it fades.
func finish() -> void:
	set_progress(1.0)
	trip = {}; splash = ""
	if _logo_mode or STYLE.still() or not is_inside_tree():
		_free(); return
	name = "LoadingCoverFading"
	if _fading != null: _fading.kill()
	_fading = create_tween()
	_fading.tween_method(_set_alpha, 1.0, 0.0, FADE_OUT)
	_fading.tween_callback(_free)

func _free() -> void:
	if is_instance_valid(_rig): _rig.queue_free()
	queue_free()
