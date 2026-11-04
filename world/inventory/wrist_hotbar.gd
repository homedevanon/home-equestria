extends Node3D
## Five quick slots, the first five briefcase slots (dev 2026-09-30: exactly five on the wrist,
## the whole inventory only in the briefcase). Placement and input belong to the inventory.
const CARRIER := preload("res://world/inventory/forearm_panel.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const SLOTS := 5
## Footer actions under the strip. Outside the store's 0-26 slot range on purpose.
const OPEN_CASE := 27
const EMPTY_HAND := 28
const OPEN_MAP := 29
const OPEN_APPEARANCE := 30
const OPEN_PONIES := 31
const HEAD_LOCAL := Transform3D(Basis(Vector3(2, 0, 0), Vector3(0, 2, 0), Vector3(0, 0, 2)), Vector3(0, -.20, -.75))
const HUD_FONT := preload("res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf")
const HEAD_HINT := "Inventory       Empty hand"
var head_controls := false
var world_popup := false
var _head_labels: Array[Label3D] = []
signal slot_selected(index: int)
signal slot_move(source: int, target: int)
var message := ""
var selected := -1
var move_source := -1
var _panels: Array[Panel] = []
var _keys: Array[Label3D] = []
var _hint: Label3D
var _hud_hint: Label
var _selected_material := StandardMaterial3D.new()
const PITCH := .038
## Half width of the strip's backing: outer cell edge plus a 6 mm border.
const STRIP_HALF := (SLOTS - 1) * .5 * PITCH + .023
## Height above a slot a hand still counts as on it: 5 cm made dev dip into the sleeve to
## hit a 3 cm slot (2026-09-30: "WAY more reliable"); 8 cm lets a relaxed hand hover.
const REACH := Vector3(.021, .024, .08)
var store: RefCounted
var hovered := -1
var _cells: Array[MeshInstance3D] = []
var _icons: Array[Sprite3D] = []
var _counts: Array[Label3D] = []
var _idle := StandardMaterial3D.new()
var _lit := StandardMaterial3D.new()
var _hud: CanvasLayer
var _hud_icons: Array[TextureRect] = []
var _hud_counts: Array[Label] = []
var _carrier: CARRIER
var _footer_carrier: CARRIER
var _carrier_pending := false
var _message_tween: Tween
const ERROR_RED := Color("ff5252")
const VR_HINT := "Point + grip: equip  ·  L / R grip: cycle\n[ Inventory ]       [ Empty hand ]"
const DESKTOP_HINT := "Click: equip  ·  Shift-click two slots: move  ·  I: briefcase  ·  Q: drop"

func setup(inventory: RefCounted, desktop: bool) -> void:
	store = inventory
	store.changed.connect(refresh)
	add_to_group(CATALOG.ICON_CAMERA.GROUP)
	for m in [_idle, _lit, _selected_material]:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# The sleeve outline writes no depth. Draw cuff layers after that pass while
		# retaining depth tests against opaque hands, sleeves and world objects.
		m.render_priority = 1
	_idle.albedo_color = Color(.12, .14, .13, .72)
	_lit.albedo_color = Color(.45, .70, .85, .85)
	_selected_material.albedo_color = Color(.93, .80, .45, .95)
	if desktop: _build_hud()
	else: _build_strip()
	if not desktop:
		_hint = Label3D.new(); _hint.render_priority = 2; _hint.pixel_size = .00020; _hint.font_size = 36
		_hint.text = VR_HINT
		_hint.position = Vector3(0, -.037, .006); add_child(_hint)
		_carrier = CARRIER.new(); add_child(_carrier)
		for i in 3:
			var caption := Label3D.new()
			caption.text = ["Map", "Appearance", "Ponies"][i]
			caption.font_size = 44; caption.pixel_size = .00028; caption.outline_size = 3; caption.font = HUD_FONT
			caption.position = Vector3((i - 1) * .066, -.078, .006)
			caption.double_sided = false; caption.render_priority = 2; caption.hide()
			add_child(caption); _head_labels.append(caption)
		_footer_carrier = CARRIER.new(); _footer_carrier.name = "ForearmFooter"; add_child(_footer_carrier)
	hide()
	refresh()

func _build_strip() -> void:
	for i in SLOTS:
		var x := (i - (SLOTS - 1) * .5) * PITCH
		var cell := MeshInstance3D.new(); var box := BoxMesh.new(); box.size = Vector3(.034, .034, .004)
		cell.mesh = box; cell.material_override = _idle; cell.position = Vector3(x, 0, 0)
		cell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; add_child(cell); _cells.append(cell)
		var icon := Sprite3D.new(); icon.render_priority = 2; icon.pixel_size = .00021; icon.position = Vector3(x, .002, .004)
		icon.shaded = false; icon.double_sided = false; icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(icon); _icons.append(icon)
		var count := Label3D.new(); count.render_priority = 2; count.pixel_size = .00018; count.font_size = 56; count.outline_size = 14
		count.position = Vector3(x + .011, -.012, .005); count.double_sided = false
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; add_child(count); _counts.append(count)
		var key := Label3D.new(); key.render_priority = 2; key.pixel_size = .00016; key.font_size = 40; key.outline_size = 10
		key.text = str(i + 1); key.modulate = Color(1, 1, 1, .6); key.double_sided = false
		key.position = Vector3(x - .012, .012, .005); add_child(key); _keys.append(key)

func _build_hud() -> void:
	_hud = CanvasLayer.new(); _hud.layer = 5; add_child(_hud)
	var bar := Control.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE; _hud.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	var width := SLOTS * 72 - 6
	bar.offset_left = -width * .5; bar.offset_right = width * .5; bar.offset_top = -80; bar.offset_bottom = -14
	# Pony speech captions sit above the bar and its hint (world/ui/speech_caption.gd).
	bar.add_to_group("caption_clearance")
	for i in SLOTS:
		var panel := Panel.new(); panel.size = Vector2(66, 66)
		panel.position = Vector2(i * 72, 0)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE; bar.add_child(panel); _panels.append(panel)
		var icon := TextureRect.new(); icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; icon.position = Vector2(9, 7); icon.size = Vector2(48, 48)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE; panel.add_child(icon); _hud_icons.append(icon)
		var key := Label.new(); key.text = str(i + 1); key.position = Vector2(5, 1)
		key.mouse_filter = Control.MOUSE_FILTER_IGNORE; key.add_theme_font_size_override("font_size", 13); panel.add_child(key)
		var count := Label.new(); count.position = Vector2(34, 44); count.size = Vector2(28, 20)
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE; count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count.add_theme_font_size_override("font_size", 15); panel.add_child(count); _hud_counts.append(count)
		var button := Button.new(); button.flat = true; button.size = panel.size
		button.focus_mode = Control.FOCUS_NONE; panel.add_child(button)
		button.pressed.connect(func():
			if Input.is_key_pressed(KEY_SHIFT):
				if move_source < 0: move_source = i
				else: slot_move.emit(move_source, i); move_source = -1
			else: slot_selected.emit(i))
	# Messages are wider than five slots; centre a wide line just above the bar.
	_hud_hint = Label.new(); _hud_hint.position = Vector2(width * .5 - 360, -40)
	_hud_hint.size = Vector2(720, 36); _hud_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_hint.text = DESKTOP_HINT
	_hud_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE; bar.add_child(_hud_hint)
	_hud_hint.add_to_group("caption_clearance")

func select(index: int) -> void:
	selected = index; refresh()

## item_icon_camera.gd took this item's picture.
func icon_ready(_id: String) -> void:
	refresh()

func refresh() -> void:
	for i in SLOTS:
		var slot: Dictionary = store.slots[i]
		var texture: Texture2D = null if slot.is_empty() else CATALOG.icon(slot.id)
		var amount := 0 if slot.is_empty() else int(slot.count)
		var text := "" if slot.is_empty() else str(amount)
		var alpha := .35 if not slot.is_empty() and amount == 0 else 1.0
		if not _icons.is_empty():
			_cells[i].material_override = _selected_material if i == selected else _lit if i == hovered else _idle
			_icons[i].texture = texture; _icons[i].modulate.a = alpha; _counts[i].text = text
		if not _hud_icons.is_empty():
			var style := StyleBoxFlat.new(); style.bg_color = Color(.10, .12, .11, .88)
			style.set_corner_radius_all(5); style.set_border_width_all(3 if i == selected else 1)
			style.border_color = Color("edcd84") if i == selected else Color("718278")
			_panels[i].add_theme_stylebox_override("panel", style)
			_hud_icons[i].texture = texture; _hud_icons[i].modulate.a = alpha; _hud_counts[i].text = text

	if _hud_hint != null: _hud_hint.visible = not message.is_empty()
	_queue_carrier()

func set_message(value: String, flash_red: bool = false) -> void:
	if _message_tween != null: _message_tween.kill()
	message = value
	if _hint != null:
		_hint.visible = not world_popup or not value.is_empty()
		_hint.text = value if not value.is_empty() else HEAD_HINT if head_controls else VR_HINT
	if _hud_hint != null:
		_hud_hint.text = value if not value.is_empty() else DESKTOP_HINT
		_hud_hint.add_theme_font_size_override("font_size", 24 if flash_red else 16)
		_hud_hint.visible = not value.is_empty()
	_queue_carrier()
	_message_colour(ERROR_RED if flash_red else Color.WHITE)
	if flash_red:
		_message_tween = create_tween()
		for pulse in 2:
			_message_tween.tween_method(_message_colour, ERROR_RED, Color("a52626"), 0.22)
			_message_tween.tween_method(_message_colour, Color("a52626"), ERROR_RED, 0.22)

## Resize only when display content changes, after Label3D has rebuilt its bounds.
func _queue_carrier() -> void:
	if not is_instance_valid(_carrier) or _carrier_pending: return
	_carrier_pending = true
	_fit_carrier.call_deferred()

func _fit_carrier() -> void:
	_carrier_pending = false
	if not is_instance_valid(_carrier) or not is_inside_tree(): return
	var rect := Rect2(-STRIP_HALF, -0.023, STRIP_HALF * 2.0, 0.046)
	for node: Node in get_children():
		if node == _hint or not node is VisualInstance3D or not node.visible: continue
		var box: AABB = node.transform * node.get_aabb()
		var ink := Rect2(Vector2(box.position.x, box.position.y), Vector2(box.size.x, box.size.y)).grow(0.004)
		rect = rect.merge(ink)
	_carrier.fit(rect)
	# Support all of the footer's actual glyphs and join it to the row, without empty
	# lower corners reaching into the elbow fold.
	if is_instance_valid(_footer_carrier) and is_instance_valid(_hint):
		var box: AABB = _hint.transform * _hint.get_aabb()
		_footer_carrier.visible = _hint.visible and box.size.x > 0.0 and box.size.y > 0.0
		if _footer_carrier.visible:
			var footer := Rect2(Vector2(box.position.x, box.position.y), Vector2(box.size.x, box.size.y)).grow(0.004)
			footer.size.y = maxf(footer.size.y, rect.position.y - footer.position.y)
			_footer_carrier.fit(footer)

func _message_colour(colour: Color) -> void:
	if _hint != null: _hint.modulate = colour
	if _hud_hint != null: _hud_hint.modulate = colour

func set_hud_visible(value: bool) -> void:
	if _hud != null: _hud.visible = value

## The rendered elbow/wrist frame owns both cuff surfaces; no hand-facing billboard.
const FOREARM_SCALE := .8
# Leave the elbow fold outside the carrier even when the forearm bends and rolls.
const FOREARM_SPAN := .72
const FOREARM_FORWARD := .125
const FOREARM_LIFT := .055 # No-avatar lab fallback; the real rig supplies measured sleeve clearance.
func place_forearm(frame:Transform3D, length:float, clearance:float=-1.) -> void:
	if not frame.is_finite() or absf(frame.basis.determinant())<.0001 or not is_finite(length) or length<.05:return
	# Leave the elbow fold free. This fixed fit/offset is carried by the forearm,
	# never recomputed from wrist flex or a camera-facing billboard.
	# The five-slot backing is 0.198 display units wide, so most adult forearms reach the
	# FOREARM_SCALE cap (3 cm slot pitch); only a short forearm shrinks the strip.
	var fit:float=minf(FOREARM_SCALE,length*FOREARM_SPAN/(STRIP_HALF*2.))
	var lift:float=clearance if clearance>0. and is_finite(clearance) else FOREARM_LIFT*length/.3
	var centre:Vector3=frame.origin+frame.basis.x.normalized()*length*FOREARM_FORWARD+frame.basis.z.normalized()*lift
	global_transform=Transform3D(frame.basis.orthonormalized().scaled(Vector3.ONE*fit),centre)

## Compatibility for standalone glove labs without an avatar skeleton.
func place(wrist:Vector3, hand_dir:Vector3, back:Vector3) -> void:
	if not wrist.is_finite() or not hand_dir.is_finite() or not back.is_finite() or hand_dir.length_squared()<.000001:return
	var along:=hand_dir.normalized()
	back-=along*back.dot(along)
	if back.length_squared()<.000001:return
	back=back.normalized()
	place_forearm(Transform3D(Basis(along,back.cross(along),back),wrist-along*.15),.3)

## Slot under either point (grip centre or fingertip), -1 when neither is close.
## How far behind the strip's face (into the arm) a release still lands in a slot: a thing let go
## just past the slot does not fall (dev 2026-10-01: "a little clearance BEHIND to make sure it
## doesnt just fall"). Was 2 cm.
const BEHIND_CLEARANCE := 0.07
## Half the accepted height across the strip, in pitches (was 0.48).
const SLOT_ACROSS := 0.75

func slot_at(a: Vector3, b: Vector3 = Vector3.INF) -> int:
	if not is_visible_in_tree(): return -1
	for point: Vector3 in [a, b]:
		if not point.is_finite(): continue
		var p: Vector3 = to_local(point)
		# Fitting a shorter forearm must not shrink the accepted world-space hover reach.
		var reach:float=REACH.z*maxf(1.,FOREARM_SCALE/maxf(global_basis.z.length(),.001))
		if p.z < -BEHIND_CLEARANCE or p.z > reach: continue
		var index: int = _local_slot(p)
		if index >= 0: return index
	return -1

func _local_slot(p: Vector3) -> int:
	if head_controls and p.y > -.095 and p.y < -.062 and absf(p.x) < STRIP_HALF:
		return [OPEN_MAP, OPEN_APPEARANCE, OPEN_PONIES][clampi(int(floor((p.x + .099) / .066)), 0, 2)]
	if not world_popup and p.y > -.053 and p.y < -.034 and absf(p.x) < STRIP_HALF:
		return OPEN_CASE if p.x < 0 else EMPTY_HAND
	# The nearest slot, generous across and along the strip (dev 2026-10-01: "allow the hitbox to
	# be forgiving").
	var best := -1
	var best_gap := INF
	for i in SLOTS:
		var centre := Vector2((i - (SLOTS - 1) * .5) * PITCH, 0)
		var gap := absf(p.x - centre.x)
		if gap < PITCH * .5 and absf(p.y - centre.y) < PITCH * SLOT_ACROSS and gap < best_gap:
			best = i; best_gap = gap
	return best

func ray_slot(origin: Vector3, direction: Vector3) -> int:
	if not is_visible_in_tree(): return -1
	var normal: Vector3 = global_basis.z.normalized()
	var denominator: float = normal.dot(direction)
	if denominator >= -.001: return -1
	var distance: float = normal.dot(global_position - origin) / denominator
	if distance < 0 or distance > 1.8: return -1
	return _local_slot(to_local(origin + direction * distance))

func place_head(head: Transform3D) -> void:
	global_transform = head * HEAD_LOCAL

func hover(index: int) -> bool:
	if index == hovered: return false
	hovered = index
	for i in _cells.size():
		_cells[i].material_override = _selected_material if i == selected else _lit if i == index else _idle
	return index >= 0

## Fixed camera-local geometry follows tracking without a process-time world-pose copy.
func set_head_controls(value: bool) -> void:
	if head_controls == value: return
	head_controls = value
	_hint.text = message if not message.is_empty() else HEAD_HINT if value else VR_HINT
	_hint.font = HUD_FONT if value else null
	_hint.pixel_size = .00032 if value else .00020
	_hint.font_size = 40 if value else 36
	_hint.outline_size = 3 if value else 12
	_hint.position.y = -.044 if value else -.037
	for caption: Label3D in _head_labels: caption.visible = value
	_queue_carrier()

## Five physical cells only; full inventory and three menu buttons live elsewhere.
func set_world_popup(value: bool) -> void:
	world_popup = value
	set_head_controls(false)
	if _hint != null: _hint.visible = not value or not message.is_empty()
	_queue_carrier()
