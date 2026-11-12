extends Node
## A painting session at one easel (docs/PAINTING_STATION_2026_10_22.md section 6). Loaded by
## the easel's Wake (easel_wake.gd) on the first grip or E, freed again when the player walks
## off, sits idle for 30 s or folds the easel. Everything it uses loads with it: the painting
## core (world/painting/core/), the canvas shader and the live tool models.
##
## The canvas is an RGBA8 Image of 180 x 292 cells (292 x 180 landscape) in an ImageTexture,
## updated at most 45 times a second when cells change. Contact and dips are plane and distance
## math on cached markers (cell_picker.gd, dip_detector.gd); no physics, no viewports.
const CORE := "res://world/painting/core/"
const MODELS := "res://world/painting/models/"
const SHADER := "res://world/painting/canvas_face.gdshader"
const BUILD := preload("res://world/painting/easel_build.gd")
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
## Tool -> session tool id. The scraper is the core's sponge.
const TOOL_IDS := {"brush": &"brush", "pencil": &"pencil", "scraper": &"sponge"}
const TOOL_MODELS := {"brush": "brush.glb", "pencil": "pencil.glb", "scraper": "scraper.glb"}
const TOOL_HOOKS := {"brush": "Hook_Brush", "pencil": "Hook_Pencil", "scraper": "Hook_Scraper"}
const TOOL_WORDS := {"brush": "Paint", "pencil": "Draw", "scraper": "Scrape"}
const BASE := {"P": Vector2i(45, 73), "L": Vector2i(73, 45)}
const LEVEL := 2
const STROKE_TIMEOUT_MS := 250
const UPLOAD_MS := 22          # at most 45 uploads a second
const HAPTIC_MS := 40
const IDLE_SECONDS := 30.0
const DESKTOP_REACH := 2.5
const DESKTOP_LEAVE := 3.0
const GRIP_RELEASE := 0.25
const CANVAS_GRIP := 0.08
## A tool in a VR hand: pointing forward out of the fist, tilted 30 degrees down like a pen.
const HOLD := Transform3D(Basis(Vector3.RIGHT, -0.5), Vector3(0, -0.01, -0.02))
## The desktop tool at rest: lower right of the view, tip forward and a little up.
const DESKTOP_REST := Transform3D(Basis(Vector3.RIGHT, 0.35) * Basis(Vector3.UP, 0.25), Vector3(0.2, -0.22, -0.42))
const WITNESS_RANGE := 12.0

var easel: Node3D
var wake: Area3D
var key := ""
var inventory: Node
var orient := "P"
var session: RefCounted
var picker: RefCounted
var dips: RefCounted
var texture: ImageTexture
var material: ShaderMaterial
var face: MeshInstance3D
var palette: Node3D
var tools: Dictionary = {}
var tips: Dictionary = {}
## side ("left", "right", "desktop") -> tool name
var holders: Dictionary = {}
var desktop := false
var _touching: Dictionary = {}
var _prev_cell: Dictionary = {}
var _break_at: Dictionary = {}
var _haptic_at: Dictionary = {}
var _upload_at := 0
var _upload_due := false
var _dirty := false
var _idle := 0.0
var _closing := false
var _lmb := false
var _begin_frame := -1
var _desktop_pose_owned := false
var _io: Script
var _names: Script
var _bristles: Array[StandardMaterial3D] = []
var _bristle_colour := Color(0.93, 0.88, 0.76)

func setup(p_easel: Node3D, p_wake: Area3D, p_key: String, ui: Node) -> void:
	easel = p_easel; wake = p_wake; key = p_key; inventory = ui
	process_physics_priority = -60
	_io = load(CORE + "painting_io.gd")
	_names = load(CORE + "color_names.gd")
	orient = str(easel.get_meta("painting_orient", "P"))
	palette = BUILD.marker(easel, "PaletteFrame")
	_new_session(true)
	_configure_dips()
	var hooked := BUILD.marker(easel, "HookedTools")
	if hooked != null: hooked.hide()
	for tool: String in TOOL_IDS:
		var scene := load(MODELS + str(TOOL_MODELS[tool])) as PackedScene
		if scene == null: continue
		var node: Node3D = scene.instantiate()
		node.name = "Live" + tool.capitalize()
		easel.add_child(node)
		for mesh: GeometryInstance3D in node.find_children("*", "GeometryInstance3D", true, false):
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if tool == "brush": _find_bristles(mesh)
		var tip := node.find_child("Tip", true, false) as Node3D
		tips[tool] = BUILD.local_of(node, tip) if tip != null else Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.17))
		tools[tool] = node
		_hang(tool)
	add_to_group("interaction_hint_sources")
	REGISTRY.register_live(self)
	set_physics_process(true)
	set_process_input(true)

# --- session, canvas and texture ------------------------------------------------------------

func _new_session(load_saved: bool) -> void:
	var base: Vector2i = BASE.get(orient, BASE.P)
	session = load(CORE + "paint_session.gd").new(base.x, base.y)
	session.name_dips = false
	for i in LEVEL: session.double_resolution()
	if load_saved:
		var row := REGISTRY.wip(key)
		var file := REGISTRY.path(str(row.get("file", ""))) if not row.is_empty() else ""
		if not file.is_empty() and FileAccess.file_exists(file):
			var saved := Image.load_from_file(file)
			if saved != null and saved.get_size() == session.canvas.get_size():
				saved.convert(Image.FORMAT_RGBA8)
				_io.map_empty_color(saved)
				session.load_image(saved, LEVEL)
	session.brush_size = 3
	session.sponge_size = 3
	var size: Vector2 = BUILD.FACE_SIZE.get(orient, BUILD.FACE_SIZE.P)
	picker = load(CORE + "cell_picker.gd").new()
	picker.configure(size, session.canvas.get_cols(), session.canvas.get_rows())
	face = BUILD.canvas_face(easel)
	texture = ImageTexture.create_from_image(session.canvas.get_image())
	material = ShaderMaterial.new()
	material.shader = load(SHADER) as Shader
	material.set_shader_parameter("canvas_tex", texture)
	material.set_shader_parameter("blank", REGISTRY.CANVAS_COLOR)
	if face != null: face.material_override = material
	session.canvas.take_dirty_rect()
	_touching.clear(); _prev_cell.clear(); _break_at.clear()

func _configure_dips() -> void:
	dips = load(CORE + "dip_detector.gd").new()
	if palette == null: return
	var frame := BUILD.local_of(easel, palette).affine_inverse()
	var wells := PackedVector2Array()
	var surface := 0.0
	for i in 10:
		var well := BUILD.marker(easel, "Paint_%02d" % i)
		if well == null: continue
		var at := frame * BUILD.local_of(easel, well).origin
		wells.append(Vector2(at.x, at.z)); surface += at.y
	surface /= maxf(1.0, wells.size())
	var water := BUILD.marker(easel, "RinseWater")
	var rim := BUILD.marker(easel, "RinseRim")
	var water_at := frame * BUILD.local_of(easel, water).origin if water != null else Vector3(0, -1, 0)
	var rim_at := frame * BUILD.local_of(easel, rim).origin if rim != null else Vector3(0, -2, 0)
	dips.configure(wells, surface, Vector2(water_at.x, water_at.z), water_at.y, rim_at.y, PackedVector2Array(), surface, NAN, true)

func has_paint() -> bool:
	return session != null and session.canvas.get_image().get_used_rect().has_area()

func is_held(tool: String) -> bool:
	return tool in holders.values()

func tool_node(tool: String) -> Node3D:
	return tools.get(tool) as Node3D

# --- each tick ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _closing or not is_instance_valid(easel) or not is_instance_valid(inventory): return
	var now := Time.get_ticks_msec()
	for side: String in holders.keys(): _tick_tool(side, now)
	for tool: StringName in _break_at.keys():
		if now - int(_break_at[tool]) >= STROKE_TIMEOUT_MS:
			session.touch_end(tool); _break_at.erase(tool)
	if session.canvas.take_dirty_rect().has_area(): _upload_due = true
	if _upload_due and now - _upload_at >= UPLOAD_MS:
		texture.update(session.canvas.get_image()); _upload_at = now; _upload_due = false
	if desktop:
		var camera := _camera()
		if camera == null or face == null or camera.global_position.distance_to(face.global_position) > DESKTOP_LEAVE: end_desktop()
		elif not _desktop_available(): end_desktop()
		else: _present_desktop()
	if holders.is_empty() and not desktop:
		_idle += delta
		if _idle >= IDLE_SECONDS: close(true)
	else: _idle = 0.0

func _tick_tool(side: String, now: int) -> void:
	var tool: String = holders[side]
	var node: Node3D = tools.get(tool)
	if node == null: holders.erase(side); return
	var id: StringName = TOOL_IDS[tool]
	var pose: Transform3D
	var local := Vector3(0, 0, 1)
	var tip := Vector3.ZERO
	if side == "desktop":
		var aim := desktop_aim()
		if _lmb and str(aim.kind) == "canvas":
			pose = _pose_for_tip(tool, aim.point, aim.direction)
			tip = aim.point
			local = face.global_transform.affine_inverse() * tip
			local.z = 0.0
		else:
			var camera := _camera()
			if camera == null: return
			pose = camera.global_transform * DESKTOP_REST
			tip = pose * tips[tool].origin
	else:
		var sample: Dictionary = inventory.hand_sample(side)
		var hand: Transform3D = sample.get("pose", Transform3D.IDENTITY)
		if not sample.get("active", false) or not hand.is_finite() or float(sample.get("grip", 0.0)) < GRIP_RELEASE:
			put_back(side); return
		hand.origin = sample.get("grip_position", hand.origin)
		pose = hand.orthonormalized() * HOLD
		tip = pose * tips[tool].origin
		if face != null: local = face.global_transform.affine_inverse() * tip
	_contact(side, id, local, now)
	# The drawn tool never shows through the canvas.
	if bool(_touching.get(side, false)) and local.z < 0.0 and face != null:
		pose.origin += face.global_basis.z.normalized() * -local.z
	node.global_transform = pose
	if tool == "brush" and not bool(_touching.get(side, false)) and side != "desktop": _dip(side, tip)

func _contact(side: String, id: StringName, local: Vector3, now: int) -> void:
	var was := bool(_touching.get(side, false))
	var touching: bool = picker.update_contact(local.z, was, id) and picker.local_to_cell(local) != picker.NO_CELL
	if touching:
		var prev: Vector2i = _prev_cell.get(side, picker.NO_CELL)
		var cell: Vector2i = picker.local_to_center_cell(local, session.footprint_size(id), prev if was else picker.NO_CELL)
		var changed := 0
		if not was: changed = session.touch_begin(id, cell)
		elif cell != prev: changed = session.touch_move(id, cell)
		_prev_cell[side] = cell
		_break_at.erase(id)
		if changed > 0:
			_dirty = true
			if now - int(_haptic_at.get(side, 0)) >= HAPTIC_MS:
				_haptic_at[side] = now
				if side != "desktop": inventory._haptic(side)
	elif was:
		session.touch_break(id)
		_break_at[id] = now
		_prev_cell.erase(side)
	_touching[side] = touching

func _dip(side: String, tip: Vector3) -> void:
	if palette == null: return
	var code: int = dips.update(palette.global_transform.affine_inverse() * tip)
	if code >= 0 and code < 10:
		session.dip(code, dips.last_light); _tint_brush()
		if side != "desktop": inventory._haptic(side)
	elif code == dips.RINSE:
		session.rinse(); _tint_brush()
		if side != "desktop": inventory._haptic(side)

func _pose_for_tip(tool: String, point: Vector3, direction: Vector3) -> Transform3D:
	var up := Vector3.UP if absf(direction.normalized().dot(Vector3.UP)) < 0.98 else Vector3.BACK
	var basis := Basis.looking_at(direction, up)
	return Transform3D(basis, point - basis * tips[tool].origin)

# --- tools ----------------------------------------------------------------------------------

func _hang(tool: String) -> void:
	var node: Node3D = tools.get(tool)
	var hook := BUILD.marker(easel, str(TOOL_HOOKS[tool]))
	if node == null: return
	node.transform = BUILD.local_of(easel, hook) if hook != null else Transform3D.IDENTITY

## VR grip near a hook (the offer comes from the Wake).
func take_tool(side: String, tool: String) -> bool:
	if _closing or not tools.has(tool) or is_held(tool) or holders.has(side): return false
	if side != "desktop" and inventory.hand_busy(side): return false
	holders[side] = tool
	dips.reset()
	var hand: Variant = inventory.hands.get(side) if side != "desktop" else null
	if hand is Node and is_instance_valid(hand):
		(hand as Node).set_meta("inventory_busy", true); (hand as Node).set_meta("painting_grip", self)
	if side != "desktop": inventory._haptic(side)
	_idle = 0.0
	return true

## Releasing the grip anywhere puts the tool back on its hook.
func put_back(side: String) -> void:
	var tool: String = str(holders.get(side, ""))
	holders.erase(side)
	if bool(_touching.get(side, false)):
		var id: StringName = TOOL_IDS.get(tool, &"brush")
		session.touch_break(id); _break_at[id] = Time.get_ticks_msec()
	_touching.erase(side); _prev_cell.erase(side)
	dips.reset()
	if not tool.is_empty(): _hang(tool)
	var hand: Variant = inventory.hands.get(side) if side != "desktop" and is_instance_valid(inventory) else null
	if hand is Node and is_instance_valid(hand) and (hand as Node).has_meta("painting_grip") and (hand as Node).get_meta("painting_grip") == self:
		(hand as Node).remove_meta("painting_grip"); (hand as Node).remove_meta("inventory_busy")

func _find_bristles(mesh: GeometryInstance3D) -> void:
	if not mesh is MeshInstance3D or (mesh as MeshInstance3D).mesh == null: return
	var instance := mesh as MeshInstance3D
	for surface in instance.mesh.get_surface_count():
		var source := instance.mesh.surface_get_material(surface)
		if source == null or not source.resource_name.to_lower().begins_with("bristle"): continue
		var tinted: StandardMaterial3D = source.duplicate() if source is StandardMaterial3D else StandardMaterial3D.new()
		if source is StandardMaterial3D: _bristle_colour = (source as StandardMaterial3D).albedo_color
		instance.set_surface_override_material(surface, tinted)
		_bristles.append(tinted)

func _tint_brush() -> void:
	var colour: Color = session.brush.color()
	for tinted: StandardMaterial3D in _bristles:
		tinted.albedo_color = _bristle_colour if colour.a8 == 0 else colour

# --- the canvas itself ----------------------------------------------------------------------

## VR grip on the canvas with a free hand: take a painted canvas off, or turn a blank one.
func canvas_grip(side: String) -> bool:
	if _closing: return false
	if side != "desktop" and inventory.hand_busy(side): return false
	if has_paint(): return finish(side)
	return turn_canvas()

func turn_canvas() -> bool:
	if has_paint() or _closing: return false
	for side: String in _touching.keys():
		if bool(_touching[side]): return false
	orient = "L" if orient == "P" else "P"
	BUILD.mount_canvas(easel, orient)
	_new_session(false)
	if is_instance_valid(wake): wake.call("cache_markers")
	REGISTRY.clear_wip(key)
	SFX.play_event(easel, "prop_blanket", {"intensity": .35})
	return true

## Take the finished painting off: a new owned "art:<id>" item in this hand, a fresh canvas on
## the easel, and a passive world-memory event for the ponies who saw it (section 9-10). With no
## room for it (full briefcase, or too many loose things) nothing changes and the hint says why.
func finish(side: String) -> bool:
	if _closing or not has_paint(): return false
	if not _room_for_painting(): return _no_room()
	session.end_all_touches()
	_break_at.clear()
	var id := "%x-%04x" % [int(Time.get_unix_time_from_system()), randi() & 0xffff]
	var image: Image = session.canvas.get_image_copy()
	# The ten paint names now; the 4961-name label follows from a worker (painting_registry).
	var label := colour_label(image, false)
	var pose := face.global_transform.orthonormalized() if face != null else easel.global_transform
	pose.origin -= pose.basis.z * 0.03
	if side == "desktop": end_desktop()
	if not REGISTRY.write_png(image.duplicate() as Image, "art_%s.png" % id): return false
	REGISTRY.add_art(id, orient, label)
	var item: Node3D = inventory.spawn_owned_drop("art:" + id, pose)
	# Refused after all: the picture stays on the easel and in its work in progress. The drop
	# already said why (no slot, or the loose cap after tidying), so that line stays.
	if item == null: return _no_room(true)
	REGISTRY.clear_wip(key)
	var hand_pose: Transform3D = pose
	if side == "desktop":
		var camera := _camera()
		if camera != null: hand_pose = camera.global_transform
	else:
		var sample: Dictionary = inventory.hand_sample(side)
		hand_pose = sample.get("pose", pose)
	inventory._take_pick(side, {"target": item, "kind": "item"}, hand_pose)
	REGISTRY.name_art_later(id, image, (get_script() as Script).resource_path, CORE + "color_names.gd", CORE + "pigment_brush.gd", item)
	session.new_canvas(BASE[orient].x, BASE[orient].y)
	for i in LEVEL: session.double_resolution()
	texture = ImageTexture.create_from_image(session.canvas.get_image())
	material.set_shader_parameter("canvas_tex", texture)
	session.canvas.take_dirty_rect()
	_dirty = false
	_record_reaction(id, label)
	SFX.play_event(easel, "prop_blanket", {"intensity": .45})
	# An owned easel with bought canvases (M-ACT-03): it stands empty until Anon puts up a new
	# blank canvas (easel_wake.gd mount_canvas_from_hand); the session ends with it.
	if REGISTRY.needs_bought_canvas(key):
		REGISTRY.set_bare(key, true)
		BUILD.refresh_canvas(easel)
		close.call_deferred(false)
	return true

## A free briefcase slot, the one limit spawn_owned_drop cannot fix itself (at the loose-item cap it
## puts a leftover back first, briefcase_drops.gd / loose_tidy.gd; W1-INVENTORY hook note).
func _room_for_painting() -> bool:
	var store: Variant = inventory.get("inventory")
	if not store is Object: return true
	var slots: Variant = (store as Object).get("slots")
	if not slots is Array: return true
	for slot: Variant in slots:
		if slot is Dictionary and (slot as Dictionary).is_empty(): return true
	return false

## `refused`: spawn_owned_drop refused and already showed its own reason; that line is kept.
func _no_room(refused := false) -> bool:
	if refused: return false
	var store: Variant = inventory.get("inventory")
	if store is Object: (store as Object).set("last_error", "No room in the briefcase for the painting.")
	if inventory.has_method("_error"): inventory.call("_error")
	return false

## "mostly cerulean and fern": the two most painted colours (4 bits per channel). `named` uses
## the 4961-name table; otherwise the nearest of the ten paints, which costs nothing to load.
func colour_label(image: Image, named: bool) -> String:
	return label_of(image, _names if named else null, load(CORE + "pigment_brush.gd") as Script)

## Static so a worker can run it (painting_registry.name_art_later); `names` null = paint names.
static func label_of(image: Image, names: Script, pigments: Script) -> String:
	var data := image.get_data()
	var counts := {}
	var cols := image.get_width()
	var step := 1 if names != null else 2
	for y in range(0, image.get_height(), step):
		for x in range(0, cols, step):
			var i := (y * cols + x) * 4
			if data[i + 3] == 0: continue
			var quantised := ((data[i] >> 4) << 8) | ((data[i + 1] >> 4) << 4) | (data[i + 2] >> 4)
			counts[quantised] = int(counts.get(quantised, 0)) + 1
	var keys := counts.keys()
	keys.sort_custom(func(a: int, b: int) -> bool: return int(counts[a]) > int(counts[b]))
	var words: Array[String] = []
	for quantised: int in keys:
		var colour := Color8(((quantised >> 8) & 15) * 17, ((quantised >> 4) & 15) * 17, (quantised & 15) * 17)
		var word := _colour_word(colour, names, pigments)
		if not word.is_empty() and word not in words: words.append(word)
		if words.size() >= 2: break
	if words.is_empty(): return ""
	return "mostly " + " and ".join(words)

static func _colour_word(colour: Color, names: Script, pigments: Script) -> String:
	if names != null:
		var hit: Dictionary = names.nearest(colour)
		if not hit.is_empty(): return str(hit.name).to_lower()
	if pigments == null: return ""
	var best := ""
	var gap := INF
	for i in int(pigments.PIGMENT_COUNT):
		var paint: Color = pigments.PIGMENT_RGB[i]
		var d := Vector3(paint.r - colour.r, paint.g - colour.g, paint.b - colour.b).length_squared()
		if d < gap: gap = d; best = str(pigments.PIGMENT_NAMES[i]).to_lower()
	return best

func _record_reaction(id: String, label: String) -> void:
	var scene := get_tree().current_scene
	var context: Variant = scene.get("world_context") if scene != null else null
	var director := get_tree().get_first_node_in_group("conversation_director")
	if not is_instance_valid(context) or director == null or face == null: return
	var characters: Variant = director.get("characters")
	if not characters is Dictionary: return
	var space := easel.get_world_3d().direct_space_state
	var witnesses: Array = []
	for pony_id: Variant in characters:
		var row: Variant = characters[pony_id]
		var node: Variant = row.get("node") if row is Dictionary else null
		if not pony_id is String or not node is Node3D or not is_instance_valid(node): continue
		var eye: Vector3 = (node as Node3D).global_position + Vector3.UP * 1.0
		if eye.distance_to(face.global_position) > WITNESS_RANGE: continue
		# Only ponies on the picture side see it (the canvas back has no collider).
		if (eye - face.global_position).dot(face.global_basis.z) <= 0.0: continue
		var query := PhysicsRayQueryParameters3D.create(eye, face.global_position + face.global_basis.z * 0.05, 1)
		var exclude: Array[RID] = []
		if node is CollisionObject3D: exclude.append((node as CollisionObject3D).get_rid())
		var panel := easel.get_node_or_null("PaintPanel") as CollisionObject3D
		if panel != null: exclude.append(panel.get_rid())
		query.exclude = exclude
		if space.intersect_ray(query).is_empty(): witnesses.append(pony_id)
	if witnesses.is_empty(): return
	var station := key.begins_with("station:")
	var text := ("Anon finished a painting at the easel on Balloon Hill: %s." if station else "Anon finished a painting at his easel: %s.") % (label if not label.is_empty() else "a new picture")
	context.call("record", "painting", text, witnesses, [], "painting:" + id, "Balloon Hill" if station else "outdoors")

# --- desktop --------------------------------------------------------------------------------

## E or a click on the PaintPanel: the brush comes into the desktop hand.
func desktop_begin() -> bool:
	if _closing or desktop or holders.has("desktop") or not bool(inventory.get("_desktop")): return false
	if inventory.hand_busy("desktop") or not DESKTOP_OWNER.claim(inventory, self): return false
	desktop = true
	_begin_frame = Engine.get_process_frames()
	var tool := "brush"
	for name: String in ["brush", "pencil", "scraper"]:
		if not is_held(name): tool = name; break
	holders["desktop"] = tool
	_lmb = false
	_idle = 0.0
	return true

func end_desktop() -> void:
	if not desktop: return
	desktop = false
	_lmb = false
	if holders.has("desktop"): put_back("desktop")
	_clear_desktop_pose()
	if is_instance_valid(inventory): DESKTOP_OWNER.release(inventory, self)

## Menus (I, U, Tab, J, Escape) cancel the desktop owner before they take the mouse.
func cancel_desktop_activity() -> void:
	end_desktop()

func _camera() -> Camera3D:
	return inventory.get("camera") as Camera3D if is_instance_valid(inventory) else null

func _desktop_available() -> bool:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or get_tree().paused: return false
	var body: Variant = inventory.get("player_body")
	if body is Node and "controls_locked" in body and bool(body.controls_locked): return false
	return true

## What the crosshair is on, nearest first: {kind: canvas|well|rinse|hook|none, point, direction,
## index (well), tool (hook)}.
func desktop_aim() -> Dictionary:
	var camera := _camera()
	var result := {"kind": "none", "point": Vector3.ZERO, "direction": Vector3.FORWARD}
	if camera == null: return result
	var origin := camera.global_position
	var direction := -camera.global_basis.z.normalized()
	result.direction = direction
	var best := DESKTOP_REACH
	if face != null:
		var plane := face.global_transform.orthonormalized()
		var normal := plane.basis.z
		var denom := direction.dot(normal)
		if absf(denom) > 0.0001:
			var t := (plane.origin - origin).dot(normal) / denom
			if t > 0.0 and t < best:
				var local := plane.affine_inverse() * (origin + direction * t)
				var half: Vector2 = (BUILD.FACE_SIZE.get(orient, BUILD.FACE_SIZE.P) as Vector2) * 0.5
				if absf(local.x) <= half.x and absf(local.y) <= half.y:
					best = t; result.kind = "canvas"; result.point = origin + direction * t
	if not holders.has("desktop") or str(holders.desktop) == "brush":
		for i in 10:
			var well := BUILD.marker(easel, "Paint_%02d" % i)
			if well == null: continue
			var t := _ray_sphere(origin, direction, well.global_position + Vector3.UP * 0.008, 0.03)
			if t < best: best = t; result.kind = "well"; result.index = i; result.point = origin + direction * t
		var water := BUILD.marker(easel, "RinseWater")
		if water != null:
			var t := _ray_sphere(origin, direction, water.global_position + Vector3.UP * 0.012, 0.04)
			if t < best: best = t; result.kind = "rinse"; result.point = origin + direction * t
	for tool: String in TOOL_HOOKS:
		if is_held(tool) or not tools.has(tool): continue
		var node: Node3D = tools[tool]
		var a := node.global_position
		var b: Vector3 = node.global_transform * tips[tool].origin
		for k in 4:
			var t := _ray_sphere(origin, direction, a.lerp(b, k / 3.0), 0.025)
			if t < best: best = t; result.kind = "hook"; result.tool = tool; result.point = origin + direction * t
	return result

static func _ray_sphere(origin: Vector3, direction: Vector3, centre: Vector3, radius: float) -> float:
	var t := (centre - origin).dot(direction)
	if t <= 0.0: return INF
	return t if (origin + direction * t).distance_to(centre) <= radius else INF

func _input(event: InputEvent) -> void:
	if event is InputEventKey and preload("res://world/ui/typing_guard.gd").active(): return  # typing never drives the game
	if not desktop or _closing or not is_instance_valid(inventory): return
	if Engine.get_process_frames() == _begin_frame and event is InputEventKey: return
	if FLIGHT_INPUT.reserves_mouse(event, inventory.get("player_body")): return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_E, KEY_Q]:
		end_desktop(); get_viewport().set_input_as_handled(); return
	if event is InputEventKey and event.physical_keycode in [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_G]:
		get_viewport().set_input_as_handled(); return
	if not event is InputEventMouseButton: return
	var click := event as InputEventMouseButton
	if click.button_index == MOUSE_BUTTON_LEFT:
		if not click.pressed:
			_lmb = false; get_viewport().set_input_as_handled(); return
		var aim := desktop_aim()
		match str(aim.kind):
			"canvas": _lmb = true
			"well":
				# One click loads the paint pure (the VR load-up: three dips in a row); RMB mixes.
				dips.reset()
				for i in int((load(CORE + "pigment_brush.gd") as Script).LOAD_UP_RUN): session.dip(int(aim.index), false)
				_tint_brush()
			"rinse":
				session.rinse(); _tint_brush()
			"hook":
				var tool := str(aim.tool)
				put_back("desktop"); holders["desktop"] = tool; dips.reset()
		get_viewport().set_input_as_handled()
	elif click.button_index == MOUSE_BUTTON_RIGHT and click.pressed:
		var aim := desktop_aim()
		if str(aim.kind) == "canvas":
			if has_paint(): finish("desktop")
			else: turn_canvas()
		elif str(aim.kind) == "well":
			dips.reset(); session.dip(int(aim.index), false); _tint_brush()
		get_viewport().set_input_as_handled()

func _present_desktop() -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	var node: Node3D = tools.get(str(holders.get("desktop", "")))
	if not is_instance_valid(visual) or node == null or not visual.has_method("set_hold_target"): return
	visual.call("set_hold_target", "right", node.global_transform, "hold"); _desktop_pose_owned = true

func _clear_desktop_pose() -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node if is_instance_valid(inventory) else null
	if _desktop_pose_owned and is_instance_valid(visual) and visual.has_method("clear_hold_target"): visual.call("clear_hold_target", "right")
	_desktop_pose_owned = false

## The tool in hand describes what it can do here (control_icons parses the text).
func interaction_hint() -> Dictionary:
	if _closing or not is_instance_valid(inventory): return {}
	if desktop:
		if not _desktop_available(): return {}
		var tool := str(holders.get("desktop", "brush"))
		var node: Node3D = tools.get(tool)
		var aim := desktop_aim()
		var stop := "   [E] Stop painting"
		match str(aim.kind):
			"canvas":
				var right := "   [RMB] Take painting off" if has_paint() else "   [RMB] Turn canvas"
				return {"target": easel.get_node_or_null("Canvas"), "text": "[LMB] " + str(TOOL_WORDS[tool]) + right + stop, "point": aim.point}
			"well":
				var paint := _pigment_name(int(aim.index))
				return {"target": node, "outline": null, "text": "[LMB] Load " + paint + "   [RMB] Mix in " + paint + stop, "point": aim.point}
			"rinse":
				return {"target": node, "outline": null, "text": "[LMB] Rinse brush" + stop, "point": aim.point}
			"hook":
				return {"target": tools.get(str(aim.tool)), "text": "[LMB] Take " + str(aim.tool) + stop, "point": aim.point}
		return {"target": node, "outline": null, "text": "[E] Stop painting", "point": node.global_position if node != null else easel.global_position}
	for side: String in ["right", "left"]:
		if not holders.has(side): continue
		var tool := str(holders[side])
		var node: Node3D = tools.get(tool)
		if node == null or face == null: continue
		var tip: Vector3 = node.global_transform * tips[tool].origin
		if tool == "brush" and palette != null:
			var local := palette.global_transform.affine_inverse() * tip
			if absf(local.y) < 0.08 and absf(local.x) < 0.45 and absf(local.z) < 0.12:
				var nearest := _nearest_well(tip)
				if nearest >= 0: return {"target": node, "outline": null, "text": "Dip · Mix in " + _pigment_name(nearest) + " · Dip 3 times: pure", "point": tip}
		var on_face := face.global_transform.affine_inverse() * tip
		if absf(on_face.z) < 0.15:
			return {"target": node, "outline": null, "text": "Touch canvas · " + str(TOOL_WORDS[tool]), "point": tip}
	return {}

func _nearest_well(at: Vector3) -> int:
	var best := -1
	var gap := 0.05
	for i in 10:
		var well := BUILD.marker(easel, "Paint_%02d" % i)
		if well == null: continue
		var d := Vector2(well.global_position.x - at.x, well.global_position.z - at.z).length()
		if d < gap: gap = d; best = i
	return best

func _pigment_name(index: int) -> String:
	var brush: Script = load(CORE + "pigment_brush.gd")
	return str(brush.PIGMENT_NAMES[index]).to_lower() if index >= 0 and index < brush.PIGMENT_COUNT else "paint"

# --- saving and closing ---------------------------------------------------------------------

## For a checkpoint (painting_registry.flush_live): a copy of the canvas and the file it goes to.
func checkpoint_image() -> Dictionary:
	if _closing or not _dirty: return {}
	_dirty = false
	if not has_paint():
		REGISTRY.clear_wip(key); return {}
	var copy: Image = session.canvas.get_image_copy()
	return {"image": copy, "file": "wip_%s.png" % REGISTRY.new_serial(), "key": key, "orient": orient, "label": colour_label(copy, false)}

func _bake() -> void:
	var shot := checkpoint_image()
	var flat: Image = null
	if not shot.is_empty():
		var copy: Image = shot.image
		flat = REGISTRY.flatten(copy.duplicate() as Image)
		if REGISTRY.write_png(copy, str(shot.file)):
			REGISTRY.set_wip(key, str(shot.file), orient, str(shot.label))
	if face == null: return
	if flat != null:
		flat.generate_mipmaps()
		face.material_override = BUILD.idle_material(ImageTexture.create_from_image(flat))
		var canvas := easel.get_node_or_null("Canvas")
		if canvas != null and not str(shot.label).is_empty(): canvas.set_meta("ai_label", "an easel with a painting in progress (%s)" % shot.label)
	else:
		BUILD.refresh_canvas(easel)

## Puts everything back and frees the session. `bake` stores unsaved work first.
func close(bake := true) -> void:
	if _closing: return
	end_desktop()
	for side: String in holders.keys(): put_back(side)
	if session != null: session.end_all_touches()
	if bake and session != null: _bake()
	elif is_instance_valid(easel): BUILD.refresh_canvas(easel)
	_closing = true
	_release()
	queue_free()

func _release() -> void:
	set_physics_process(false); set_process_input(false)
	if is_in_group("interaction_hint_sources"): remove_from_group("interaction_hint_sources")
	REGISTRY.unregister_live(self)
	if is_instance_valid(easel):
		var hooked := BUILD.marker(easel, "HookedTools")
		if hooked != null: hooked.show()
	for node: Variant in tools.values():
		if is_instance_valid(node): (node as Node).queue_free()
	tools.clear()
	if is_instance_valid(wake): wake.call("runtime_closed", self)

func _exit_tree() -> void:
	if _closing: return
	# Freed with its easel (streamed out, folded by other code, world teardown): no bake here;
	# the last checkpoint keeps the work (painting_registry.flush_live).
	_closing = true
	desktop = false
	_clear_desktop_pose()
	if is_instance_valid(inventory):
		DESKTOP_OWNER.release(inventory, self)
		for side: String in holders.keys():
			var hand: Variant = inventory.hands.get(side) if side != "desktop" else null
			if hand is Node and is_instance_valid(hand) and (hand as Node).has_meta("painting_grip") and (hand as Node).get_meta("painting_grip") == self:
				(hand as Node).remove_meta("painting_grip"); (hand as Node).remove_meta("inventory_busy")
	holders.clear()
	_release()
