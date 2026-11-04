extends Node3D
const VIEW := preload("res://world/player_view.gd")
const CURRENCY := preload("res://world/ui/currency.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
## Physical restaurant stock, grill, assembly tray and service pass. Input adapters
## move these same objects on desktop and in VR; only the shift model awards bits.
const ASSETS: Dictionary = {
	"bun":"burger-bun-bottom", "lid":"burger-bun-top", "raw":"hay-patty",
	"patty":"hay-patty", "cheese":"cheese-slice", "tomato":"tomato-slice", "lettuce":"lettuce-leaf",
}
const GRILL: Vector3 = Vector3(-4.55, 1.12, -4.32)
const PREP: Vector3 = Vector3(2.2, 1.155, -4.4)
const PASS: Vector3 = Vector3(1.65, 1.06, -1.40)
const BIN: Vector3 = Vector3(3.10, 0.86, -2.1)
const SIGN: Vector3 = Vector3(2.65, 1.34, -1.43)
## The clock-in bell beside the work sign (board #110): turning the sign asks, ringing confirms.
const BELL: Vector3 = Vector3(2.2, 1.0525, -1.55)
const CONFIRM_SECONDS := 12.0
const MAX_LOOSE: int = 24
var restaurant: Node
var held: Dictionary = {}
var loose: Array[RigidBody3D] = []
var sources: Dictionary = {}
var _grill: RigidBody3D
var _stack: RigidBody3D
var _last_tray: Array = []
var _last_grill: String = ""
var _tickets: Array[Label3D] = []
var _sign_label: Label3D
var _status: Label3D
var _feedback: Label3D
var _stock_label: Label3D
var _active: bool = false
var _grill_audio := 0
var _audio_tick := 0.0
var _next_step: Label3D
var stations: Dictionary = {}
## "start" or "finish" while the sign is waiting for the bell; empty otherwise.
var confirm_action := ""
var _confirm_until_ms := 0
var _bell_dome: MeshInstance3D
const INGREDIENT_NAMES: Dictionary = {"bun":"bottom bun", "lid":"top bun", "raw":"raw hay patty", "patty":"grilled hay patty", "cheese":"cheese", "tomato":"tomato", "lettuce":"lettuce"}

func setup(host: Node) -> void:
	restaurant = host
	for spec: Array in [["bun",-0.7],["lid",-0.25],["cheese",0.2],["tomato",0.65],["lettuce",1.1]]:
		_stock(spec[0], Vector3(float(spec[1]), 1.075, -4.30))
	_stock("raw", Vector3(-3.35,1.075,-4.30))
	var sign: StaticBody3D = StaticBody3D.new()
	sign.name = "TurnOverWorkSign"; sign.collision_layer = 2; sign.collision_mask = 0
	sign.set_meta("kitchen_role", "sign"); add_child(sign); sign.position = SIGN
	_box(sign, Vector3(0.50,0.30,0.035), Vector3.ZERO, Color("7d553a"))
	_shape(sign, Vector3(0.52,0.32,0.09), Vector3.ZERO)
	_sign_label = _label(sign, "", Vector3(0,0,-0.023), 0.0024)
	_sign_label.rotation.y = PI
	_box(self, Vector3(0.07,0.25,0.07), SIGN - Vector3(0,0.25,0), Color("9b6546"))
	_box(self, Vector3(0.4,0.035,0.25), SIGN - Vector3(0,0.27,0), Color("9b6546"))
	_build_bell()
	# Open-topped waste bin. Only deliberate releases over its opening or inside it discard food.
	# Solid, so a desktop click aims at its floor (not the room floor, out of reach) and food
	# that misses lands in it instead of falling through.
	var bin_body: StaticBody3D = StaticBody3D.new(); bin_body.name = "ScrapsBin"
	bin_body.collision_layer = 1; bin_body.collision_mask = 0; add_child(bin_body)
	for offset: Vector3 in [Vector3(-.23,-.30,0), Vector3(.23,-.30,0), Vector3(0,-.30,-.23), Vector3(0,-.30,.23)]:
		var wall: Vector3 = Vector3(.035,.60,.48) if offset.x != 0 else Vector3(.48,.60,.035)
		_box(self, wall, BIN + offset, Color("7a5a3c")); _shape(bin_body, wall, BIN + offset)
	_box(self, Vector3(.48,.035,.48), BIN + Vector3(0,-.6,0), Color("7a5a3c"))
	_shape(bin_body, Vector3(.48,.035,.48), BIN + Vector3(0,-.6,0))
	_label(self,"Scraps",BIN+Vector3(0,-.22,-.25),.0022).rotation.y = PI
	# Every work destination stays visible even when it has no food on it.
	# Solid: desktop placement aims at the first world collider, and without its own the pad's
	# drop point was the worktop under the trays, below the PREP release band.
	_station("prep", PREP, Vector3(.64,.02,.54), Color("c49a6c"), true)
	_label(self,"Build",PREP+Vector3(0,.025,.20),.00165).rotation.x = -PI/2
	_station("grill", GRILL+Vector3(0,0,-.36), Vector3(1.0,.025,.055), Color("deb950"))
	_station("pass", PASS, Vector3(.64,.018,.52), Color("b0503d"))
	_station("bin", BIN+Vector3(0,-.30,.245), Vector3(.42,.4,.02), Color("7a5a3c"))
	_box(self,Vector3(2.5,.40,.025),Vector3(2.0,1.69,-4.9),Color("7d553a"))
	# Picture sign instead of three lines of instructions (dev 2026-09-30): raw patty, arrow,
	# golden patty, arrow, finished hayburger, on the board over the build tray.
	var guide: Node3D = Node3D.new(); guide.name = "RecipeGuide"; add_child(guide)
	guide.position = Vector3(2.0,1.74,-4.87)
	var steps: Array = [["raw", -.9], ["arrow", -.55], ["patty", -.2], ["arrow", .15], ["burger", .6]]
	for step: Array in steps:
		if step[0] == "arrow":
			_box(guide,Vector3(.16,.03,.02),Vector3(float(step[1]) - .02,0,.02),Color("f4e2bd"))
			for tip: float in [1.0, -1.0]:
				var head: MeshInstance3D = _box(guide,Vector3(.08,.028,.02),Vector3(float(step[1]) + .045,tip * .025,.02),Color("f4e2bd"))
				head.rotation.z = -tip * .7
			continue
		var holder: Node3D = Node3D.new(); guide.add_child(holder)
		holder.position = Vector3(float(step[1]),-.1,.07); holder.rotation.x = PI * .5
		if step[0] == "burger":
			var height: float = 0.0
			for kind: String in ["bun","patty","lettuce","lid"]:
				var layer: Node3D = _visual(holder,kind); layer.position.y += height
				height += float(layer.get_meta("height", .03)) * .8
		else:
			var piece: Node3D = _visual(holder,"patty")
			if step[0] == "raw": _tint(piece,Color("c4b46b"))
	_next_step = _label(self,"",Vector3(2.0,1.56,-4.875),.0016)
	# A tangible mat identifies the serving spot; no panel or menu owns movement.
	
	_label(self,"Serve",PASS+Vector3(0,.025,0),.0022).rotation = Vector3(-PI/2,PI,0)
	for index: int in range(3):
		var card: Node3D = Node3D.new(); card.name = "OrderTicket%d" % index
		add_child(card); card.position = Vector3(.55 + index*.83,2.32,-4.44)
		_box(card,Vector3(.79,.69,.014),Vector3.ZERO,Color("fff0d2"))
		_box(card,Vector3(.07,.04,.035),Vector3(0,.30,.01),Color("987239"))
		_box(card,Vector3(.025,.44,.025),Vector3(0,-.23,-.01),Color("987239"))
		var ticket: Label3D = _label(card,"",Vector3(0,0,.012),.0018)
		ticket.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; ticket.width = 410
		ticket.modulate = Color("423225"); _tickets.append(ticket)
	var notice: Node3D = Node3D.new(); notice.name = "CounterNote"; add_child(notice)
	notice.position = Vector3(-2.3,1.35,-1.65); notice.rotation.y = PI
	_box(notice,Vector3(1.48,.43,.035),Vector3.ZERO,Color("7d553a"))
	_box(notice,Vector3(.04,.30,.04),Vector3(0,-.25,-.04),Color("987239"))
	_feedback = _label(notice,"",Vector3(0,0,.025),.0020)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _feedback.width = 680
	_box(self,Vector3(1.0,.18,.035),GRILL+Vector3(0,.30,-.29),Color("7d553a"))
	_box(self,Vector3(.03,.27,.03),GRILL+Vector3(0,.075,-.30),Color("987239"))
	_status = _label(self,"",GRILL+Vector3(0,.30,-.27),.0023)
	# Each stock card names its ingredient; no board of instructions above them.
	_stock_label = _label(self,"",Vector3(-1.0,1.55,-4.88),.0018)
	refresh()

## A brass counter bell on a wooden foot: the physical "yes" to the sign's question.
func _build_bell() -> void:
	var bell: StaticBody3D = StaticBody3D.new()
	bell.name = "ClockInBell"; bell.collision_layer = 2; bell.collision_mask = 0
	bell.set_meta("kitchen_role", "bell"); add_child(bell); bell.position = BELL
	var foot: MeshInstance3D = _box(bell, Vector3(.17,.025,.17), Vector3(0,.0125,0), Color("7d553a"))
	foot.name = "BellFoot"
	_bell_dome = MeshInstance3D.new(); _bell_dome.name = "BellDome"
	var dome: SphereMesh = SphereMesh.new(); dome.radius = .07; dome.height = .07; dome.is_hemisphere = true
	_bell_dome.mesh = dome; _bell_dome.position = Vector3(0,.025,0)
	var brass: StandardMaterial3D = StandardMaterial3D.new(); brass.albedo_color = Color("c69b52"); brass.metallic = .45; brass.roughness = .35
	_bell_dome.material_override = brass; _bell_dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bell.add_child(_bell_dome)
	var button: MeshInstance3D = MeshInstance3D.new(); button.name = "BellButton"
	var knob: CylinderMesh = CylinderMesh.new(); knob.top_radius = .012; knob.bottom_radius = .014; knob.height = .03
	button.mesh = knob; button.material_override = brass; button.position = Vector3(0,.105,0)
	bell.add_child(button)
	_shape(bell, Vector3(.17,.12,.17), Vector3(0,.06,0))

## The last shift's pay slip for the counter note, for a while after clocking out.
func shift_summary() -> String:
	var until: Variant = restaurant.get("last_summary_until_ms")
	if not until is int or Time.get_ticks_msec() >= int(until): return ""
	return CURRENCY.text(str(restaurant.get("last_summary")))

## Turning the sign asks; the bell answers within CONFIRM_SECONDS.
func _ask(action: String) -> void:
	confirm_action = action
	_confirm_until_ms = Time.get_ticks_msec() + int(CONFIRM_SECONDS * 1000.0)

func confirm_pending() -> String:
	if not confirm_action.is_empty() and Time.get_ticks_msec() > _confirm_until_ms: confirm_action = ""
	return confirm_action

func _ring() -> void:
	if restaurant != null and restaurant.get("_bell") != null and restaurant._bell.is_inside_tree(): restaurant._bell.play()
	if is_instance_valid(_bell_dome) and _bell_dome.is_inside_tree():
		var tween: Tween = _bell_dome.create_tween()
		tween.tween_property(_bell_dome, "scale", Vector3(1.0,.8,1.0), .06)
		tween.tween_property(_bell_dome, "scale", Vector3.ONE, .12)

func _stock(kind: String, at: Vector3) -> void:
	_box(self,Vector3(.37,.03,.35),at-Vector3(0,.022,0),Color("dbc09a"))
	var item: RigidBody3D = _piece(kind)
	item.set_meta("kitchen_role","source"); item.position = at; sources[kind] = item
	# Labels are attached to small counter cards, with a stem down to the stock board.
	_box(self,Vector3(.36,.16,.015),at+Vector3(0,.13,-.17),Color("fff0d2"))
	_box(self,Vector3(.018,.11,.018),at+Vector3(0,.025,-.185),Color("987239"))
	var card: Label3D = _label(self,str(INGREDIENT_NAMES.get(kind,kind)).to_upper().replace(" ","\n"),at+Vector3(0,.13,-.160),.0015)
	card.modulate = Color("423225")

func working() -> bool:
	return restaurant != null and restaurant.shift != null and restaurant.shift.snapshot().state == "playing"

func refresh() -> void:
	if restaurant == null or restaurant.shift == null: return
	var data: Dictionary = restaurant.shift.snapshot()
	var active: bool = data.state == "playing"
	if _active and not active: reset_food()
	_active = active
	# A shop sign's two faces, no slogans (dev 2026-09-30); the counter note only speaks while
	# you work, with the shift's own messages.
	_sign_label.text = "Working" if active else "Help yourself"
	match confirm_pending():
		"start": _sign_label.text = "Confirm start?\nRing the bell"
		"finish": _sign_label.text = "Finish your shift?\nRing the bell"
	_feedback.text = CURRENCY.text(str(data.message)) if active else ""
	if not active: _feedback.text = shift_summary()
	_feedback.get_parent().visible = not _feedback.text.is_empty()
	var tray: Array = data.tray
	if tray != _last_tray:
		_last_tray = tray.duplicate()
		if is_instance_valid(_stack): _remove(_stack)
		_stack = null
		if not tray.is_empty():
			_stack = _body("burger",Vector3(.36,.32,.36)); _stack.position = PREP
			_stack.set_meta("kitchen_role","burger")
			_box(_stack,Vector3(.38,.018,.34),Vector3(0,.009,0),Color("f7ebcf"))
			var height: float = .018
			for kind: String in tray:
				var visual: Node3D = _visual(_stack,kind)
				visual.position.y += height
				height += float(visual.get_meta("height",.03))
	var grill: String = data.grill_state
	_sync_grill_audio(active and grill in ["cooking", "ready", "burnt"])
	if grill != _last_grill:
		_last_grill = grill
		if is_instance_valid(_grill): _remove(_grill)
		_grill = null
		if grill in ["cooking","ready","burnt"]:
			_grill = _piece("patty"); _grill.position = GRILL
			_grill.set_meta("kitchen_role","grill")
			if grill != "ready": _tint(_grill,Color("39281b") if grill == "burnt" else Color("c4b46b"))
	_status.text = ("GRILL: %.0fs" % data.grill_ready_in if grill == "cooking" else "GOLDEN — READY" if grill == "ready" else "BURNT — DISCARD" if grill == "burnt" else "PLACE HAY PATTY HERE") if active else ""
	for index: int in range(_tickets.size()):
		var ticket: Label3D = _tickets[index]
		ticket.get_parent().visible = index == 0 or (active and index < data.orders.size())
		if index == 0 and data.orders.is_empty(): ticket.text = "Waiting for a customer" if active else ""
		if index == 0 and not active and data.orders.is_empty(): ticket.get_parent().visible = false
		if index < data.orders.size():
			var order: Dictionary = data.orders[index]
			var lines: PackedStringArray = PackedStringArray(["%s · %s" % ["FIRST" if index == 0 else str(index+1),order.name],str(order.recipe_name)])
			var step: int = 0
			for ingredient: String in order.recipe:
				step += 1
				lines.append("%d. %s" % [step,str(INGREDIENT_NAMES.get(ingredient,ingredient)).capitalize()])
			lines.append(CURRENCY.amount(20))
			ticket.text = "\n".join(lines)

	_next_step.text = next_step(data) if active else ""
	if restaurant.get("business_open") == false:
		_sign_label.text = "Closed\n8 am – 10 pm"
		# A shift ended by closing time still shows its pay slip on the counter note.
		_feedback.text = shift_summary()
		_feedback.get_parent().visible = not _feedback.text.is_empty()
		_next_step.text = ""


func take(side: String, item: Node3D) -> bool:
	if held.has(side) or not is_instance_valid(item): return false
	if item.get_meta("kitchen_role","") == "sign":
		# Clock in or out needs a clear yes: the sign asks, the bell beside it confirms.
		if not working() and restaurant.get("business_open") == false: return false
		_ask("finish" if working() else "start")
		SFX.play_event(self, "prop_cover", {"intensity": .45}, item.global_position)
		refresh()
		return true
	if item.get_meta("kitchen_role","") == "bell":
		var action: String = confirm_pending()
		_ring()
		confirm_action = ""
		var was_working := working()
		if action == "start" and not was_working: restaurant.start_confirmed_shift()
		elif action == "finish" and was_working: restaurant.stop_working()
		refresh()
		return true
	if not working() or item in held.values(): return false
	var role: String = item.get_meta("kitchen_role","")
	if role == "source":
		# Stock never locks (thread 2026-11-01: "any food that i need to use will not be able to be
		# built" until the shift restarted): at the cap the oldest stray piece is cleared away.
		if loose.size() >= MAX_LOOSE and not _clear_oldest_stray(): return false
		var stock_pose: Transform3D = item.global_transform
		item = _piece(str(item.get_meta("ingredient"))); item.global_transform = stock_pose; loose.append(item)
	elif role == "grill":
		var state: String = restaurant.shift.snapshot().grill_state
		if state == "ready":
			if not restaurant.work_action("lift_patty"): return false
			item = _piece("patty"); item.position = GRILL; item.set_meta("cooked",true); loose.append(item)
		elif state == "burnt":
			if not restaurant.work_action("discard_patty"): return false
			item = _piece("raw"); item.position = GRILL; _tint(item,Color("39281b")); item.set_meta("burnt",true); loose.append(item)
		else: return false
	elif role != "burger" and item not in loose: return false
	# An unfinished burger may be carried too, to the scraps bin: before, a half-built stack whose
	# customer had gone could not be lifted, so nothing new could be built on the tray (board #307).
	held[side] = item; item.freeze = true; item.collision_layer = 0
	SFX.play_event(self, "prop_pickup", {"intensity": .5, "material": "soft"}, item.global_position)
	refresh(); return true

func move_held(side: String, pose: Transform3D) -> void:
	var item: RigidBody3D = held.get(side)
	if is_instance_valid(item) and pose.is_finite(): item.global_transform = pose

## Called only on deliberate release, never merely from moving over a work surface.
func release(side: String, intentional: bool = true) -> bool:
	var item: RigidBody3D = held.get(side)
	if not is_instance_valid(item): held.erase(side); return false
	var at: Vector3 = to_local(item.global_position)
	var role: String = item.get_meta("kitchen_role","")
	var kind: String = item.get_meta("ingredient","")
	var accepted: bool = false
	if working() and intentional:
		if _in_bin(at):
			if role == "burger": accepted = restaurant.work_action("discard_tray")
			elif item.get_meta("cooked",false): accepted = restaurant.work_action("discard_patty")
			else: accepted = true
		elif role == "burger":
			if _over(at,PASS,Vector2(.34,.29),.38): accepted = restaurant.work_action("serve")
		elif kind == "raw" and not item.get_meta("burnt",false) and _over(at,GRILL,Vector2(.65,.34),.32):
			accepted = restaurant.work_action("grill")
		elif not item.get_meta("burnt",false) and _over(at,PREP,Vector2(.30,.26),.45):
			accepted = restaurant.work_action("take_patty" if kind == "patty" and item.get_meta("cooked",false) else kind)
	held.erase(side)
	if accepted:
		var event := "prop_harvest_deposit" if _in_bin(at) else "prop_grill" if kind == "raw" and _over(at,GRILL,Vector2(.65,.34),.32) else "prop_serve"
		SFX.play_event(self, event, {"intensity": .65}, item.global_position)
		_remove(item)
	elif role == "burger" and not intentional:
		# The stack is the tray's burger: dropped by a lost hand, Q or the chat box taking the mouse,
		# it goes back on the build board instead of falling somewhere out of reach.
		item.transform = Transform3D(Basis.IDENTITY, PREP); item.collision_layer = 2
	else:
		item.freeze = false; item.collision_layer = 2; item.linear_velocity = Vector3.ZERO; item.angular_velocity = Vector3.ZERO
	refresh()
	return accepted

## Frees the oldest loose piece nopony needs: not in a hand and not the lifted golden patty (the
## grill's "held" state lives in it). False when there is none.
func _clear_oldest_stray() -> bool:
	for item: RigidBody3D in loose:
		if not is_instance_valid(item) or item in held.values() or item.get_meta("cooked", false): continue
		_remove(item)
		return true
	return false

func reset_food() -> void:
	_sync_grill_audio(false)
	held.clear()
	for item: RigidBody3D in loose.duplicate(): _remove(item)
	if is_instance_valid(_grill): _remove(_grill)
	if is_instance_valid(_stack): _remove(_stack)
	_grill = null; _stack = null; _last_tray = []; _last_grill = ""

func reachable(point: Vector3, reach: float = .23) -> Node3D:
	var nearest: Node3D
	var best: float = reach
	for child: Node in get_children():
		if not child is PhysicsBody3D or not child.has_meta("kitchen_role") or child in held.values() or child.is_queued_for_deletion(): continue
		var centre: Vector3 = child.global_position + Vector3.UP * .04
		var distance: float = point.distance_to(centre)
		if distance >= best: continue
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(point,centre,1)
		if not get_world_3d().direct_space_state.intersect_ray(query).is_empty(): continue
		nearest = child; best = distance
	return nearest

## From the bin's floor (where desktop clicks land) up to .55 over its rim (where VR hands let go).
func _in_bin(point: Vector3) -> bool:
	return _over(point,BIN-Vector3(0,.55,0),Vector2(.28,.28),1.1)

func _over(point: Vector3, centre: Vector3, half: Vector2, height: float) -> bool:
	return absf(point.x-centre.x) < half.x and absf(point.z-centre.z) < half.y and point.y >= centre.y-.07 and point.y < centre.y+height

func _remove(item: RigidBody3D) -> void:
	loose.erase(item)
	for side: String in held.keys():
		if held[side] == item: held.erase(side)
	if not item.is_queued_for_deletion(): item.collision_layer = 0; item.hide(); item.queue_free()

func _piece(kind: String) -> RigidBody3D:
	var item: RigidBody3D = _body(kind,Vector3(.29,.075,.29))
	item.set_meta("ingredient",kind)
	_visual(item,kind)
	return item

func _body(kind: String, size: Vector3) -> RigidBody3D:
	var item: RigidBody3D = RigidBody3D.new(); item.name = "Food_" + kind
	item.freeze = true; item.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	item.mass = .15; item.collision_layer = 2; item.collision_mask = 1
	item.continuous_cd = true; item.set_meta("kitchen_role","loose")
	add_child(item); _shape(item,size,Vector3(0,size.y*.5,0))
	return item

func _visual(parent: Node3D, kind: String) -> Node3D:
	var visual: Node3D = (load("res://world/props/food/%s.scn" % ASSETS[kind]) as PackedScene).instantiate()
	parent.add_child(visual)
	var bounds: AABB = _bounds(visual,visual)
	var factor: float = .28 / maxf(bounds.size.x,.001)
	visual.scale = Vector3.ONE * factor
	visual.position = Vector3(-bounds.get_center().x,-bounds.position.y,-bounds.get_center().z)*factor
	visual.set_meta("height",bounds.size.y*factor)
	# Tiny ingredients do not need four directional shadow submissions per surface.
	for mesh: GeometryInstance3D in visual.find_children("*", "GeometryInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if visual is GeometryInstance3D: visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return visual

func _bounds(node: Node3D, origin: Node3D) -> AABB:
	var box: AABB
	if node is MeshInstance3D: box = (origin.global_transform.affine_inverse()*node.global_transform)*node.get_aabb()
	for child: Node in node.get_children():
		if child is Node3D:
			var sub: AABB = _bounds(child,origin)
			if sub.size != Vector3.ZERO: box = sub if box.size == Vector3.ZERO else box.merge(sub)
	return box

func _tint(node: Node, colour: Color) -> void:
	if node is MeshInstance3D:
		var mat: StandardMaterial3D = StandardMaterial3D.new(); mat.albedo_color = colour; mat.roughness = .85
		node.material_override = mat
	for child: Node in node.get_children(): _tint(child,colour)

func _shape(body: PhysicsBody3D, size: Vector3, at: Vector3) -> void:
	var collider: CollisionShape3D = CollisionShape3D.new(); var shape: BoxShape3D = BoxShape3D.new()
	shape.size = size; collider.shape = shape; body.add_child(collider); collider.position = at

func _box(parent: Node3D, size: Vector3, at: Vector3, colour: Color) -> MeshInstance3D:
	var mesh: MeshInstance3D = MeshInstance3D.new(); var box: BoxMesh = BoxMesh.new()
	box.size = size; mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.mesh = box; parent.add_child(mesh); mesh.position = at
	var material: StandardMaterial3D = StandardMaterial3D.new(); material.albedo_color = colour; material.roughness = .8
	mesh.material_override = material
	return mesh

func _label(parent: Node3D, text: String, at: Vector3, pixel: float) -> Label3D:
	var label: Label3D = Label3D.new(); label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; parent.add_child(label); label.position = at
	CURRENCY.apply(label); label.text = CURRENCY.text(text); label.font_size = 28; label.pixel_size = pixel
	label.modulate = Color("fff0d2"); label.outline_size = 0; label.no_depth_test = false; label.shaded = true
	return label

func _station(key: String, at: Vector3, size: Vector3, colour: Color, solid: bool = false) -> void:
	var node: Node3D = Node3D.new(); node.name = key.capitalize() + "Station"
	add_child(node); node.position = at
	_box(node,size,Vector3.ZERO,colour)
	if solid:
		var pad: StaticBody3D = StaticBody3D.new(); pad.name = "Pad"
		pad.collision_layer = 1; pad.collision_mask = 0
		node.add_child(pad); _shape(pad,size,Vector3.ZERO)
	stations[key] = node

func next_step(data: Dictionary) -> String:
	if data.orders.is_empty(): return "Wait for a customer's spoken order and ticket."
	var tray: Array = data.tray
	if tray.has("lid"): return "Carry the whole burger to the red SERVE mat."
	if tray.is_empty(): return "Place a bottom bun on the green BUILD tray."
	if not tray.has("patty"):
		match str(data.grill_state):
			"empty": return "Take a raw hay patty to the grill on your left."
			"cooking": return "Patty cooking — wait until GOLDEN."
			"ready": return "Move the golden patty onto the bottom bun."
			"held": return "Place the cooked patty on the wooden build board."
			"burnt": return "Discard the burnt patty in the scraps bin; grill a fresh one."
	var recipe: Array = data.orders[0].recipe
	for index: int in range(mini(tray.size(),recipe.size())):
		if tray[index] != recipe[index]: return "Wrong stack: put it in the scraps bin and rebuild ticket 1."
	if tray.size() < recipe.size(): return "Add %s to the build board." % INGREDIENT_NAMES.get(recipe[tray.size()],recipe[tray.size()])
	return "Carry the burger to the red serving cloth."

func pickup_text(item: Node3D) -> String:
	if not is_instance_valid(item) or item in held.values(): return ""
	var role: String = item.get_meta("kitchen_role","")
	if role == "sign":
		if not working() and restaurant.get("business_open") == false: return ""
		return "Finish your shift" if working() else "Start a paid shift"
	if role == "bell":
		match confirm_pending():
			"start": return "Ring the bell: start the shift"
			"finish": return "Ring the bell: finish and get paid"
		return "Ring the bell"
	if not working(): return ""
	if role == "grill" and restaurant.shift.snapshot().grill_state not in ["ready","burnt"]: return ""
	if role == "burger": return "Pick up finished hayburger" if restaurant.shift.snapshot().tray.has("lid") else "Pick up unfinished burger"
	if role == "grill" and restaurant.shift.snapshot().grill_state == "burnt": return "Remove burnt patty"
	return "Pick up " + str(INGREDIENT_NAMES.get(item.get_meta("ingredient",""),"hay patty"))

func release_hint(side: String, world_point: Vector3 = Vector3.INF) -> Dictionary:
	var item: Node3D = held.get(side)
	if not is_instance_valid(item): return {}
	var at: Vector3 = to_local(world_point if world_point.is_finite() else item.global_position)
	var kind: String = item.get_meta("ingredient","")
	if _in_bin(at): return {"target":stations.bin,"text":"Discard in scraps"}
	if item.get_meta("kitchen_role","") == "burger":
		if _over(at,PASS,Vector2(.34,.29),.38) and restaurant.shift.snapshot().tray.has("lid"): return {"target":stations.pass,"text":"Serve hayburger"}
	elif kind == "raw" and _over(at,GRILL,Vector2(.65,.34),.32): return {"target":stations.grill,"text":"Place patty on grill"}
	elif _over(at,PREP,Vector2(.30,.26),.45): return {"target":stations.prep,"text":"Add to burger"}
	return {"target":item,"text":"Place / drop"}

## The physical hot grill stays audible until the patty is lifted/discarded or work ends.
## Keep the loop lease alive at 2Hz; no sound is generated by idle input/hint polling.
func _sync_grill_audio(active: bool) -> void:
	var camera: Camera3D = VIEW.camera(self)
	var at := to_global(GRILL)
	var audible := camera == null or camera.global_position.distance_squared_to(at) <= 100.0
	if not active or not audible:
		if _grill_audio != 0: SFX.stop_loop(self, _grill_audio, .2)
		_grill_audio = 0; _audio_tick = .5; set_process(active); return
	if _grill_audio == 0: _grill_audio = SFX.start_loop(self, "prop_sizzle_loop", {"intensity": .75})
	if _grill_audio != 0 and not SFX.update_loop(self, _grill_audio, {"intensity": .75}, at):
		_grill_audio = 0
	_audio_tick = .5; set_process(true)

func _process(delta: float) -> void:
	_audio_tick -= delta
	if _audio_tick <= 0.0:
		var active := false
		if is_instance_valid(restaurant) and restaurant.shift != null:
			var data: Dictionary = restaurant.shift.snapshot()
			active = data.state == "playing" and str(data.grill_state) in ["cooking", "ready", "burnt"]
		_sync_grill_audio(active)

func _exit_tree() -> void:
	SFX.release_source(self)
