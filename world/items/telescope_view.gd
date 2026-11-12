extends Node3D
## Twilight's telescope in the Golden Oak loft (M-ACT-04; thread 43657217: "maybe a telescope for a
## closer glance" at the moon): an eyepiece view like the photo camera's (photo_camera.gd), on the
## static brass telescope that golden_oak/interior.gd builds (reference_furniture.gd telescope()).
## - VR: put an eye to the eyepiece (kneel; it is at pony height) and that eye alone sees the
##   telescope's view in a round window, black around it; the other eye keeps the room.
## - Desktop: look at the telescope within reach and click (or press E) to look through it; the
##   mouse turns it, the wheel zooms, a click, E or right click steps back, and walking away does too.
## At night with the moon up the telescope starts on the moon (the sky shader draws it with its 2k
## map, shaders/sky.gdshader); otherwise it starts along its brass tube. Focused at infinity: the
## view begins NEAR metres out, so the trunk, the canopy and close roofs never fill it.
## Cost: nothing per frame until used. A 4 Hz timer only measures the headset's distance in VR;
## the hint answers with one distance check when the player is not near. The SubViewport is made on
## first use and draws only while someone looks through it.
const FOV := 6.0
const FOV_MIN := 1.5
const FOV_MAX := 14.0
const VIEW_SIZE := Vector2i(1024, 1024)
const NEAR := 30.0
const FAR := 8000.0
## The tube in this node's frame: the eyepiece at the origin, the objective TUBE metres along -Z.
const TUBE := 0.87
## Desktop: aim within this many metres of the tube's axis, from this far away at most.
const AIM_RADIUS := 0.16
const DESK_REACH := 2.2
## VR: an eye this close (metres) to the eyepiece looks through it; the head this close turns on the
## per-frame eye check.
const EYE_REACH := 0.09
const HEAD_NEAR := 0.6
const IPD_HALF := 0.032
const VR_POLL := 0.25
## Desktop: the eye moving this far from where it started looking ends the look.
const WALK_OFF := 0.6
const HINT := "Click · Look through the telescope"
const OVERLAY_SHADER := """
shader_type canvas_item;
// Twilight's telescope on the desktop (telescope_view.gd): a round window, darker toward its rim.
void fragment() {
	float r = length(UV - 0.5);
	float window = 1.0 - smoothstep(0.45, 0.49, r);
	vec3 colour = texture(TEXTURE, UV).rgb * mix(1.0, 0.5, smoothstep(0.25, 0.47, r));
	COLOR = vec4(colour * window, 1.0);
}
"""
const FINDER_SHADER := """
shader_type spatial;
// Twilight's telescope in VR (telescope_view.gd): drawn for one eye only, the view in a round window.
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform sampler2D view : source_color, filter_linear, repeat_disable;
uniform int eye = 0;
void fragment() {
	if (VIEW_INDEX != eye) discard;
	vec2 c = UV - 0.5;
	float r = length(c);
	float window = 1.0 - smoothstep(0.1, 0.125, r);
	vec3 colour = texture(view, c * 4.0 + 0.5).rgb * mix(1.0, 0.5, smoothstep(0.06, 0.12, r));
	ALBEDO = colour * window;
	ALPHA = 1.0;
}
"""

var inventory: Node
var _viewport: SubViewport
var _lens: Camera3D
var _overlay: CanvasLayer
var _finder: MeshInstance3D
var _poll: Timer
var _fov := FOV
## Desktop look: the eye, and where it was and how it faced when the look began.
var _eye: Camera3D
var _eye_origin := Vector3.ZERO
## Where the view started (the moon or the tube) and how the eye or head faced when the look began,
## as (yaw, pitch): the telescope turns by as much as he turns, about its own mount.
var _start_angles := Vector2.ZERO
var _eye_angles := Vector2.ZERO
var _vr_looking := false

## Puts the view on the telescope golden_oak/interior.gd just built (its "OpticalTube"). Null when
## there is no telescope.
static func attach(interior: Node3D) -> Node3D:
	var tube := interior.find_child("OpticalTube", true, false) as Node3D
	if tube == null or not tube.get_parent() is Node3D: return null
	var barrel := tube.get_parent() as Node3D
	var relative := Transform3D.IDENTITY
	var at: Node = barrel
	while at != null and at != interior:
		if not at is Node3D: return null
		relative = (at as Node3D).transform * relative
		at = at.get_parent()
	if at != interior: return null
	var view := (load("res://world/items/telescope_view.gd") as GDScript).new() as Node3D
	view.name = "TelescopeView"
	# reference_furniture.gd: the tube runs along the barrel's +Y, the eyepiece at y -0.42.
	var axis := (relative.basis * Vector3.UP).normalized()
	view.transform = Transform3D(Basis.looking_at(axis, Vector3.UP), relative * Vector3(0, -0.42, 0))
	interior.add_child(view)
	return view

func _ready() -> void:
	# Also while paused, so the pause menu ends a look instead of sitting under the view.
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("interaction_hint_sources")
	set_process(false)
	_poll = Timer.new(); _poll.wait_time = VR_POLL; _poll.autostart = true
	_poll.timeout.connect(_vr_poll)
	add_child(_poll)

func _exit_tree() -> void:
	_stop()
	if is_instance_valid(_finder): _finder.queue_free()

# ------------------------------------------------------------------ finding the player
func _inventory() -> Node:
	if is_instance_valid(inventory): return inventory
	if not is_inside_tree(): return null
	for source: Node in get_tree().get_nodes_in_group("interaction_hint_sources"):
		if source != self and source.has_method("hand_sample") and "_desktop" in source:
			inventory = source; return inventory
	return null

func _desktop() -> bool:
	var found := _inventory()
	return found != null and bool(found.get("_desktop"))

## The middle of the brass tube, in the world.
func tube_middle() -> Vector3:
	return global_transform * Vector3(0, 0, -TUBE * 0.5)

## Is the desktop eye on the tube, within reach, with nothing in between?
func aimed(eye: Camera3D) -> bool:
	if eye == null or not eye.is_inside_tree(): return false
	var from := eye.global_position
	if from.distance_squared_to(tube_middle()) > (DESK_REACH + TUBE) * (DESK_REACH + TUBE): return false
	var ahead := from - eye.global_basis.z * DESK_REACH
	var points := Geometry3D.get_closest_points_between_segments(from, ahead, global_position, global_transform * Vector3(0, 0, -TUBE))
	if points[0].distance_to(points[1]) > AIM_RADIUS: return false
	var query := PhysicsRayQueryParameters3D.create(from, points[0], 1)
	var found := _inventory()
	var body: Variant = found.get("player_body") if found != null else null
	if body is CollisionObject3D: query.exclude = [(body as CollisionObject3D).get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func interaction_hint() -> Dictionary:
	if looking() or not _desktop(): return {}
	var eye := get_viewport().get_camera_3d()
	if not aimed(eye): return {}
	# The telescope draws inside the room's merged mesh, so no outline: the prompt alone.
	return {"target": self, "text": HINT, "point": tube_middle(), "outline": null, "visible_pick": true}

# ------------------------------------------------------------------ the view
func looking() -> bool:
	return _eye != null or _vr_looking

## Where the view starts: the moon at night when it is up, else along the tube.
func start_direction() -> Vector3:
	var axis := -global_basis.z
	var sky := get_node_or_null("/root/TimeOfDay")
	if sky != null and sky.has_method("moon_direction") and sky.has_method("daylight"):
		var moon: Vector3 = sky.moon_direction()
		if moon.y > 0.05 and float(sky.daylight()) < 0.35: axis = moon.normalized()
	return axis

## (yaw, pitch) of a direction, as a camera's rotation (YXZ) faces it.
static func angles(direction: Vector3) -> Vector2:
	var d := direction.normalized()
	return Vector2(atan2(-d.x, -d.z), asin(clampf(d.y, -1.0, 1.0)))

func _make_view() -> void:
	if is_instance_valid(_viewport): return
	_viewport = SubViewport.new()
	_viewport.name = "TelescopeViewport"
	_viewport.size = VIEW_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_lens = Camera3D.new(); _lens.name = "Lens"
	_lens.fov = _fov; _lens.near = NEAR; _lens.far = FAR
	# Placed from _process, not on the physics tick.
	_lens.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_viewport.add_child(_lens)

func _draw_view(on_: bool) -> void:
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on_ else SubViewport.UPDATE_DISABLED

## The lens faces where it started, turned by how far the eye or head turned since.
func _place_lens(facing: Vector3) -> void:
	var now := angles(facing)
	var pitch := clampf(_start_angles.y + now.y - _eye_angles.y, -1.55, 1.55)
	_lens.global_transform = Transform3D(Basis.from_euler(Vector3(pitch, _start_angles.x + now.x - _eye_angles.x, 0)), global_position)
	_lens.fov = _fov

func _begin(facing: Vector3) -> void:
	_make_view()
	_start_angles = angles(start_direction()); _eye_angles = angles(facing); _fov = FOV
	_place_lens(facing)
	_draw_view(true)

## Desktop: look through the telescope with this eye.
func start(eye: Camera3D) -> void:
	if eye == null or looking(): return
	_eye = eye; _eye_origin = eye.global_position
	_begin(-eye.global_basis.z)
	_set_overlay(true)
	set_process(true)

func _stop() -> void:
	_eye = null; _vr_looking = false
	_set_overlay(false)
	if is_instance_valid(_finder): _finder.hide()
	_draw_view(false)
	set_process(false)

func stop() -> void:
	_stop()

func _process(_delta: float) -> void:
	if _eye != null:
		if not is_instance_valid(_eye) or not _eye.is_inside_tree() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
				or get_tree().paused or _eye.global_position.distance_to(_eye_origin) > WALK_OFF:
			_stop(); return
		# The mouse still turns Anon; the telescope turns with him from where it started.
		_place_lens(-_eye.global_basis.z)
		return
	_vr_tick()

func _unhandled_input(event: InputEvent) -> void:
	if not _desktop(): return
	var key := event as InputEventKey
	var button := event as InputEventMouseButton
	var use := (key != null and key.pressed and not key.echo and key.physical_keycode == KEY_E) \
		or (button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT)
	if _eye != null:
		if button != null and button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_fov = clampf(_fov * (0.85 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.85), FOV_MIN, FOV_MAX)
			_lens.fov = _fov
			get_viewport().set_input_as_handled()
		elif use or (button != null and button.pressed and button.button_index == MOUSE_BUTTON_RIGHT):
			_stop(); get_viewport().set_input_as_handled()
		return
	if not use or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or get_tree().paused: return
	var eye := get_viewport().get_camera_3d()
	if aimed(eye):
		start(eye); get_viewport().set_input_as_handled()

func _set_overlay(on_: bool) -> void:
	if not on_:
		if is_instance_valid(_overlay): _overlay.queue_free()
		_overlay = null
		return
	if is_instance_valid(_overlay): return
	_overlay = CanvasLayer.new(); _overlay.layer = 60
	var black := ColorRect.new(); black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT); black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(black)
	var view := TextureRect.new()
	view.texture = _viewport.get_texture()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new(); material.shader = Shader.new(); material.shader.code = OVERLAY_SHADER
	view.material = material
	_overlay.add_child(view)
	var words := Label.new(); words.text = "Wheel · Zoom   Click or E · Step back"
	words.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	words.offset_left = -400; words.offset_right = 400; words.offset_top = -64; words.offset_bottom = -24
	words.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	words.add_theme_font_size_override("font_size", 22)
	words.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	words.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(words)
	add_child(_overlay)

# ------------------------------------------------------------------ VR
## 4 Hz: in VR, wake the per-frame eye check only while the headset is near the eyepiece.
func _vr_poll() -> void:
	var found := _inventory()
	if found == null or bool(found.get("_desktop")): return
	var head: Camera3D = found.get("camera") as Camera3D
	var near := head != null and head.is_inside_tree() and head.global_position.distance_to(global_position) < HEAD_NEAR
	if near: set_process(true)
	elif _vr_looking: _stop()
	elif _eye == null: set_process(false)

## VR, every frame while the head is near: which eye (if any) is at the eyepiece.
func vr_tick(head: Camera3D) -> void:
	if head == null: return
	var eye := -1
	var best := EYE_REACH
	for index in 2:
		var at: Vector3 = head.global_transform * Vector3(-IPD_HALF if index == 0 else IPD_HALF, 0, 0)
		var gap := at.distance_to(global_position)
		if gap < best: best = gap; eye = index
	if eye < 0:
		if _vr_looking:
			_vr_looking = false
			if is_instance_valid(_finder): _finder.hide()
			_draw_view(false)
		return
	if not _vr_looking:
		_vr_looking = true
		_begin(-head.global_basis.z)
	if not is_instance_valid(_finder): _make_finder(head)
	if _finder.get_parent() != head: _finder.reparent(head, false)
	_finder.position = Vector3(-IPD_HALF if eye == 0 else IPD_HALF, 0, -0.12)
	(_finder.material_override as ShaderMaterial).set_shader_parameter("eye", eye)
	_finder.show()
	_place_lens(-head.global_basis.z)

func _vr_tick() -> void:
	var found := _inventory()
	if found == null or bool(found.get("_desktop")):
		set_process(false); return
	vr_tick(found.get("camera") as Camera3D)

func _make_finder(head: Camera3D) -> void:
	_finder = MeshInstance3D.new()
	_finder.name = "TelescopeFinder"
	var quad := QuadMesh.new(); quad.size = Vector2(0.5, 0.5)
	_finder.mesh = quad
	var material := ShaderMaterial.new(); material.shader = Shader.new(); material.shader.code = FINDER_SHADER
	material.set_shader_parameter("view", _viewport.get_texture())
	material.render_priority = 120
	_finder.material_override = material
	_finder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_finder.extra_cull_margin = 1.0
	head.add_child(_finder)
