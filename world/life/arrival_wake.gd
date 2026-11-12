extends Node
## Waking in the Everfree (dev 2026-10-01): black with ringing ears, then eyes opening on the
## forest floor, head on the ground looking up into the trees; sitting up; getting up; and only
## then control. Eyelids blink between the poses, so in a headset the view only ever moves
## while the eyes are shut. Desktop uses a separate camera for the lying and sitting views;
## a headset lowers the XR origin instead and hides the body until Anon stands.
## AnonPony (player/pony_form.gd, docs/ANONPONY_DESIGN_2026_10_01.md 8.2) wakes on its side with
## its head on the ground, sits on its haunches and stands; its body stays hidden until it stands.
## Seated VR (headset view, keyboard and mouse) holds the rig's view while the origin is lowered.
## Inspired by the opening beats of PonyPonyParadise (docs/research/PONYPONYPARADISE_INTRO_2026_09_27.md);
## the words are our own.
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const PONY_FORM := preload("res://player/pony_form.gd")
const LINES := {
	"black": ["...", "Ringing. Nothing but ringing in my ears.", "Cold, wet ground under my back. Moss. Rot. Leaves."],
	"lying": "Trees. Huge, twisted trees, everywhere above me.",
	"sit": "I have to sit up.",
	"sitting": "My head is pounding. Where... where am I?",
	"up": "Up. Get up.",
}
## AnonPony's lines where they differ (the rest come from LINES).
const LINES_PONY := {
	"black": ["...", "Ringing. Nothing but ringing in my ears.", "Cold, wet ground under my side. Moss. Rot. Leaves."],
	"lying": "Trees. Huge, twisted trees, all around me.",
}
var game: Node
## The view is in a headset (room-scale or seated): eyelid sphere, 3D words, origin drop.
var headset := false
## The room-scale controller rig (game.xr_active): its body is the "Body" node.
var room_scale := false
var _form: Node
var _held_view := false
var _layer: CanvasLayer
var _top: ColorRect
var _bottom: ColorRect
var _black: ColorRect
var _text: Label
var _sphere: MeshInstance3D
var _sphere_mat: StandardMaterial3D
var _text3d: Label3D
var _camera: Camera3D
var _player_camera: Camera3D
var _ring: AudioStreamPlayer
## The ringing starts quieter and keeps fading through the whole wake (dev 2026-10-02: "a little
## too loud for a little too long"): RING_START_DB down to RING_END_DB over RING_FADE_SECONDS,
## quickest at first, so it is barely there by the time he stands; then the last fade to silence.
const RING_START_DB := -15.0
const RING_END_DB := -42.0
const RING_FADE_SECONDS := 24.0
var _ring_fade: Tween
var _heart: AudioStreamPlayer
var _origin: Node3D
var _origin_drop := 0.0
var _model: Node3D
var _closed := 1.0
var _drift_from := Transform3D.IDENTITY
var _drift_to := Transform3D.IDENTITY
var _drift_time := 0.0
var _drift_length := 1.0
var running := false

## Black from the very first frame, before the loading cover lifts beneath it.
func setup(host: Node) -> void:
	game = host
	room_scale = bool(game.xr_active)
	var camera: Camera3D = game._find_camera(game.player)
	headset = camera is XRCamera3D
	_layer = CanvasLayer.new(); _layer.layer = 121
	# The window's own black; a headset shows the eyelid sphere, never this on the seated screen.
	_layer.set_meta(&"no_virtual_screen", true)
	add_child(_layer)
	_black = _rect(Control.PRESET_FULL_RECT)
	_top = _rect(Control.PRESET_TOP_WIDE); _bottom = _rect(Control.PRESET_BOTTOM_WIDE)
	_text = Label.new(); _text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; _text.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_text.offset_bottom = -90; _text.add_theme_font_size_override("font_size", 30)
	_text.add_theme_color_override("font_color", Color(0.92, 0.92, 0.88))
	_text.add_theme_color_override("font_outline_color", Color.BLACK); _text.add_theme_constant_override("outline_size", 8)
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE; _layer.add_child(_text)
	if headset and camera != null:
		var mesh := SphereMesh.new(); mesh.radius = 0.5; mesh.height = 1.0; mesh.flip_faces = true
		_sphere_mat = StandardMaterial3D.new(); _sphere_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_sphere_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; _sphere_mat.albedo_color = Color.BLACK
		_sphere_mat.no_depth_test = true; _sphere_mat.render_priority = 110; mesh.material = _sphere_mat
		_sphere = MeshInstance3D.new(); _sphere.name = "WakeEyelids"; _sphere.mesh = mesh
		_sphere.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; camera.add_child(_sphere)
		_text3d = Label3D.new(); _text3d.name = "WakeWords"; _text3d.position = Vector3(0, -0.12, -0.42)
		_text3d.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_text3d.pixel_size = 0.00045; _text3d.font_size = 40; _text3d.outline_size = 10
		_text3d.no_depth_test = true; _text3d.render_priority = 111; _text3d.width = 900.0
		_text3d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; camera.add_child(_text3d)
		preload("res://world/ui/head_locked_hud.gd").attach(camera,_text3d)
	_set_closed(1.0)
	_say("")

## White instead of black, no eyelids: Twilight's teleport flash (world/life/arrival_story.gd).
func whiten() -> void:
	for rect: ColorRect in [_black, _top, _bottom]: rect.color = Color(1, 0.97, 1)
	_top.hide(); _bottom.hide()
	if _sphere_mat != null: _sphere_mat.albedo_color = Color(1, 0.97, 1, _sphere_mat.albedo_color.a)

func _rect(preset: int) -> ColorRect:
	var rect := ColorRect.new(); rect.color = Color.BLACK; rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(preset); _layer.add_child(rect)
	return rect

## 0 = eyes open, 1 = shut. Desktop: lids meet in the middle, then the screen is black.
func _set_closed(amount: float) -> void:
	_closed = clampf(amount, 0.0, 1.0)
	var size: Vector2 = get_viewport().get_visible_rect().size if get_viewport() != null else Vector2(1920, 1080)
	var lid: float = size.y * 0.5 * smoothstep(0.0, 0.9, _closed)
	if is_instance_valid(_top): _top.offset_bottom = lid; _top.offset_top = 0
	if is_instance_valid(_bottom): _bottom.offset_top = -lid; _bottom.offset_bottom = 0
	if is_instance_valid(_black): _black.color.a = smoothstep(0.75, 1.0, _closed) if _top.visible else _closed
	if _sphere_mat != null: _sphere_mat.albedo_color.a = smoothstep(0.0, 1.0, _closed)

func _say(text: String) -> void:
	if is_instance_valid(_text): _text.text = text
	if is_instance_valid(_text3d): _text3d.text = text

## False when the world is going away (quit, reload) or this node left the tree: the caller stops.
func _lids(to: float, seconds: float) -> bool:
	var from := _closed
	var t := 0.0
	while t < seconds:
		if not await SHUTDOWN.frame(self) or not is_inside_tree(): return false
		t += get_process_delta_time()
		_set_closed(lerpf(from, to, smoothstep(0.0, 1.0, t / seconds)))
	_set_closed(to)
	return true

func _wait(seconds: float) -> bool:
	return await SHUTDOWN.seconds(self, seconds) and is_inside_tree()

## The whole wake. `feet` is where Anon lies (on the ground), `facing` toward the stump.
func play(feet: Vector3, facing: Vector3) -> void:
	running = true
	var body: Node = game.player.get_node("Body") if room_scale else game.player
	if "controls_locked" in body: body.controls_locked = true
	_player_camera = game._find_camera(game.player)
	# AnonPony stays hidden through the black, lying and sitting: only set_avatar_shown(true),
	# after standing, clears this hide.
	_form = PONY_FORM.find(get_tree())
	if is_instance_valid(_form): _form.set_avatar_shown(false)
	var pony := is_instance_valid(_form)
	# The pony's standing eye above its feet (about 0.82 m grown-up, 0.51 m young).
	var eye: float = float(body.eye_height()) if pony and body.has_method("eye_height") else 0.0
	if pony and eye <= 0.05: eye = PONY_FORM.estimate_eye_height(_form.get("form"))
	_hide_hud(true)
	_start_sound()
	for line: String in _line("black"):
		_say(line)
		if not await _wait(2.4): return
	var up := Vector3.UP
	facing.y = 0.0; facing = facing.normalized() if facing.length() > 0.1 else Vector3.FORWARD
	var side := facing.cross(up).normalized()
	# Lying on his back, feet toward the stump: looking up into the canopy, head turned a little.
	# AnonPony lies on its side, head on the ground, the view rolled (a headset cannot roll; it
	# only takes the height).
	var head := feet - facing * 1.45 + up * 0.17
	var lying := _pose(head, head + up * 2.0 + facing * 0.55 + side * 0.4, -facing)
	var lying_turn := _pose(head, head + up * 1.6 + facing * 1.0 - side * 0.2, -facing)
	if pony:
		head = feet - facing * (0.9 * eye) + up * (0.16 * eye)
		var roll := (-facing + side * 0.6).normalized()
		lying = _pose(head, head + up * 1.5 + facing * 1.0 + side * 0.3, roll)
		lying_turn = _pose(head, head + up * 1.3 + facing * 1.2 + side * 0.05, roll)
	_enter_pose(lying, lying_turn, 5.0, head.y)
	_say(_line("lying"))
	# Eyes flutter open: half, shut, a crack, shut, then open.
	if not await _lids(0.45, 0.35) or not await _lids(1.0, 0.2) or not await _wait(0.35): return
	if not await _lids(0.7, 0.3) or not await _lids(1.0, 0.25) or not await _wait(0.5): return
	if not await _lids(0.0, 0.7) or not await _wait(3.6): return
	if not await _lids(1.0, 0.45): return
	_say(_line("sit"))
	if not await _wait(1.1): return
	# Sitting up where he lay, looking down past his knees at the stump and its apples. AnonPony
	# sits on its haunches, looking down at the stump.
	var seat := feet - facing * 1.05 + up * 0.88
	var sitting := _pose(seat, seat + facing * 2.0 - up * 0.75 + side * 0.15, up)
	var sitting_look := _pose(seat, seat + facing * 2.0 - up * 0.55 - side * 0.35, up)
	if pony:
		seat = feet - facing * (0.6 * eye) + up * (0.88 * eye)
		sitting = _pose(seat, seat + facing * 2.0 - up * (0.7 * eye), up)
		sitting_look = _pose(seat, seat + facing * 2.0 - up * (0.55 * eye) - side * 0.35, up)
	_enter_pose(sitting, sitting_look, 3.8, seat.y)
	_say(_line("sitting"))
	if not await _lids(0.0, 0.55) or not await _wait(3.4): return
	if not await _lids(1.0, 0.4): return
	_say(_line("up"))
	if not await _wait(0.9): return
	_stand(feet - facing * (0.7 * eye if pony else 0.75), facing)
	# Shown where the rig now stands (reset there by PonyForm).
	if is_instance_valid(_form): _form.set_avatar_shown(true)
	if not await _lids(0.0, 0.7): return
	_say("")
	_hide_hud(false)
	if is_instance_valid(body) and "controls_locked" in body: body.controls_locked = false
	_fade_sound(3.0)
	if not await _wait(3.2): return
	running = false
	queue_free()

func _line(key: String) -> Variant:
	return LINES_PONY[key] if is_instance_valid(_form) and LINES_PONY.has(key) else LINES[key]

## No hotbar, map or overlays while his eyes open (as world/ui/title_vista.gd does).
var _hidden_layers: Array[CanvasLayer] = []
func _hide_hud(hide: bool) -> void:
	if hide:
		for node: Node in game.find_children("*", "CanvasLayer", true, false):
			var layer := node as CanvasLayer
			if layer == _layer or not layer.visible or str(layer.get_path()).contains("LoadingCover"): continue
			layer.visible = false; _hidden_layers.append(layer)
		if is_instance_valid(game.inventory) and "hud_hidden" in game.inventory: game.inventory.hud_hidden = true
		return
	if is_instance_valid(game.inventory) and "hud_hidden" in game.inventory: game.inventory.hud_hidden = false
	for layer: CanvasLayer in _hidden_layers:
		if is_instance_valid(layer): layer.visible = true
	_hidden_layers.clear()

func _pose(eye: Vector3, look: Vector3, screen_up: Vector3) -> Transform3D:
	return Transform3D(Basis.looking_at(look - eye, screen_up), eye)

## Desktop: the wake camera takes the pose and drifts slowly while the eyes are open.
## Headset: the XR origin drops so the real eyes sit at the pose's height.
func _enter_pose(from: Transform3D, to: Transform3D, seconds: float, eye_y: float) -> void:
	if headset:
		_restore_origin()
		# Seated: the rig and AnonPony leave the eye to the wake until he stands.
		if not room_scale and "view_hold" in game.player:
			game.player.set("view_hold", true); _held_view = true
		_origin = game.player.find_child("XROrigin", true, false) as Node3D
		if _origin != null and is_instance_valid(_player_camera):
			_origin_drop = _player_camera.global_position.y - eye_y
			_origin.global_position.y -= _origin_drop
		if room_scale:
			_model = game.player.find_child("AnonBody", true, false) as Node3D
			if _model != null: _model.hide()
		return
	if not is_instance_valid(_camera):
		_camera = Camera3D.new(); _camera.name = "WakeCamera"; _camera.near = 0.03
		if is_instance_valid(_player_camera): _camera.fov = _player_camera.fov; _camera.environment = _player_camera.environment
		add_child(_camera)
	_drift_from = from; _drift_to = to; _drift_time = 0.0; _drift_length = seconds
	_camera.global_transform = from
	_camera.make_current()

func _process(delta: float) -> void:
	if not is_instance_valid(_camera) or not _camera.current: return
	_drift_time += delta
	var t := smoothstep(0.0, 1.0, minf(1.0, _drift_time / _drift_length))
	_camera.global_transform = _drift_from.interpolate_with(_drift_to, t)

func _restore_origin() -> void:
	if is_instance_valid(_origin) and _origin_drop != 0.0: _origin.global_position.y += _origin_drop
	_origin_drop = 0.0

## Standing: the real player view, placed beside where he lay, facing the stump.
func _stand(at: Vector3, facing: Vector3) -> void:
	# M-ARR-02: never read or move the rig once the world has left the tree (quit mid-wake).
	if not is_inside_tree() or not is_instance_valid(game) or not is_instance_valid(game.player) or not game.player.is_inside_tree(): return
	var heading := atan2(-facing.x, -facing.z)
	if room_scale:
		_restore_origin()
		if is_instance_valid(_model): _model.show()
		var body: Node3D = game.player.get_node("Body")
		var camera: Camera3D = _player_camera
		var xr_origin: Node3D = body.find_child("XROrigin", true, false) as Node3D
		if xr_origin != null and camera != null: xr_origin.rotate_y(heading - camera.global_rotation.y)
		if camera != null:
			body.global_position += Vector3(at.x - camera.global_position.x, at.y + 0.05 - body.global_position.y, at.z - camera.global_position.z)
		if "velocity" in body: body.set("velocity", Vector3.ZERO)
		return
	# Desktop and seated: the rig's own feet on the spot, turned so the view faces the stump (for
	# human desktop the same as setting the heading: its camera has no yaw of its own).
	var player: Node3D = game.player
	if headset:
		_restore_origin()
		_release_view()
	player.global_position = Vector3(at.x, at.y + 0.05, at.z)
	var yaw: float = _player_camera.global_rotation.y if is_instance_valid(_player_camera) else NAN
	if is_finite(yaw): player.rotate_y(heading - yaw)
	else: player.rotation.y = heading
	if headset:
		if "velocity" in player: player.set("velocity", Vector3.ZERO)
		return
	if "_pitch" in player: player.set("_pitch", -0.12)
	if is_instance_valid(_player_camera): _player_camera.rotation.x = -0.12; _player_camera.make_current()
	if is_instance_valid(_camera): _camera.queue_free()

## Seated: the rig (or AnonPony) places the eye again.
func _release_view() -> void:
	if _held_view and is_instance_valid(game) and is_instance_valid(game.player): game.player.set("view_hold", false)
	_held_view = false

# ---------------------------------------------------------------- ringing and heartbeat
func _start_sound() -> void:
	var bus := "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	_ring = AudioStreamPlayer.new(); _ring.stream = _tone(); _ring.bus = bus; _ring.volume_db = RING_START_DB; add_child(_ring); _ring.play()
	_ring_fade = create_tween()
	_ring_fade.tween_property(_ring, "volume_db", RING_END_DB, RING_FADE_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_heart = AudioStreamPlayer.new(); _heart.stream = _beat(); _heart.bus = bus; _heart.volume_db = -4.0; add_child(_heart); _heart.play()

func _fade_sound(seconds: float) -> void:
	if _ring_fade != null and _ring_fade.is_valid(): _ring_fade.kill()
	for player: AudioStreamPlayer in [_ring, _heart]:
		if not is_instance_valid(player): continue
		var tween := create_tween(); tween.tween_property(player, "volume_db", -60.0, seconds)
		tween.tween_callback(player.stop)

## Tinnitus: two close high tones beating slowly, looped.
static func _tone() -> AudioStreamWAV:
	var rate := 22050; var length := rate * 2
	var bytes := PackedByteArray(); bytes.resize(length * 2)
	for i in length:
		var t := float(i) / rate
		var v := sin(TAU * 5600.0 * t) * 0.22 + sin(TAU * 5607.0 * t) * 0.12 + sin(TAU * 3900.0 * t) * 0.04
		bytes.encode_s16(i * 2, roundi(clampf(v, -1.0, 1.0) * 32767))
	var wav := AudioStreamWAV.new(); wav.format = AudioStreamWAV.FORMAT_16_BITS; wav.mix_rate = rate
	wav.data = bytes; wav.loop_mode = AudioStreamWAV.LOOP_FORWARD; wav.loop_end = length
	return wav

## A slow, heavy heartbeat: lub-dub every 1.15 s, looped.
static func _beat() -> AudioStreamWAV:
	var rate := 22050; var length := int(rate * 1.15)
	var bytes := PackedByteArray(); bytes.resize(length * 2)
	for i in length:
		var t := float(i) / rate
		var v := 0.0
		for hit: Array in [[0.0, 0.9], [0.24, 0.6]]:
			var dt := t - float(hit[0])
			if dt >= 0.0: v += sin(TAU * 52.0 * dt) * exp(-dt * 18.0) * float(hit[1])
		bytes.encode_s16(i * 2, roundi(clampf(v, -1.0, 1.0) * 32767))
	var wav := AudioStreamWAV.new(); wav.format = AudioStreamWAV.FORMAT_16_BITS; wav.mix_rate = rate
	wav.data = bytes; wav.loop_mode = AudioStreamWAV.LOOP_FORWARD; wav.loop_end = length
	return wav

func _exit_tree() -> void:
	if not _hidden_layers.is_empty(): _hide_hud(false)
	_restore_origin()
	_release_view()
	if is_instance_valid(_model): _model.show()
	if is_instance_valid(_sphere): _sphere.queue_free()
	if is_instance_valid(_text3d): _text3d.queue_free()
	if is_instance_valid(_player_camera) and is_instance_valid(_camera) and _camera.current: _player_camera.make_current()
