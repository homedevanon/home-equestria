extends Node3D
const BLUE=Color("35b7ff")
const BITS := preload("res://world/ai/bit_payments.gd")
const BOND := preload("res://world/relationships/bond_rules.gd")
var owner_ui:Node
var store:Node
var panel:Node3D
var pointer:Node3D
var active:=false
var target:Node3D
var selected:Node3D
var _overlays:Dictionary={}
var _material:ShaderMaterial
var _pressed:=false
var _armed:=false
var _old_mouse:int
var _lock_owned:=false
var _hand_overlays:Dictionary={}
var _hand_material:ShaderMaterial
var _aura:MeshInstance3D
var _refresh:=0.
var _excluded:Array[RID]=[]
# Perf 0.1.0: _process only runs while the inspector is open (toggle/close).
func _ready():set_process(active)
func setup(ui:Node,context:Node):
	set_process(active)
	owner_ui=ui;store=context
	var body:Variant=owner_ui.player_body
	if is_instance_valid(body):
		var rig:Node=body.get_parent() if body.name=="Body" else body
		for node in rig.find_children("*","CollisionObject3D",true,false):_excluded.append(node.get_rid())
		if rig is CollisionObject3D:_excluded.append(rig.get_rid())
	panel=preload("res://world/ui/profile/pony_profile_view.gd").new();add_child(panel)
	panel.closed.connect(close);panel.back.connect(back)
	panel.pay.connect(_pay);panel.hire_show.connect(_hire_show)
	panel.ask_her.connect(_ask_her);panel.end_it.connect(_end_it)
	pointer=preload("res://world/ui/controller_pointer.gd").new();add_child(pointer);pointer.set_color(BLUE)
	_material=ShaderMaterial.new();_material.shader=load("res://addons/cel-shader/outline-tinted.gdshader");_material.set_shader_parameter("outline_color",BLUE);_material.set_shader_parameter("outline_width",.006)
	_hand_material=ShaderMaterial.new();_hand_material.shader=load("res://world/ui/profile/hand_glow.gdshader");_hand_material.set_shader_parameter("outline_color",BLUE);_hand_material.set_shader_parameter("outline_width",.003)
	_aura=MeshInstance3D.new();var sphere:=SphereMesh.new();sphere.radius=.055;sphere.height=.11;sphere.radial_segments=16;sphere.rings=8;_aura.mesh=sphere
	var mat:=StandardMaterial3D.new();mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;mat.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA;mat.albedo_color=Color(BLUE,.16);mat.emission_enabled=true;mat.emission=BLUE;_aura.material_override=mat;_aura.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(_aura);_aura.hide()
	if is_instance_valid(store) and is_instance_valid(store.impressions):store.impressions.changed.connect(_changed)
	# The relationship page also follows her record (contract section 5 D).
	if BOND.DYNAMIC and is_instance_valid(store):
		var bonds:Variant=store.get("player_bonds")
		if bonds is Node and is_instance_valid(bonds) and bonds.has_signal("changed") and not bonds.changed.is_connected(_changed):bonds.changed.connect(_changed)
func toggle():
	if active:close();return
	if owner_ui.hand_busy("right"):return
	if owner_ui.customizer.opened:return # Preserve an unsaved outfit.
	if owner_ui._desktop:
		var focus:Control=get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:return
		if owner_ui.has_method("_release_desktop_activity"):
			if not owner_ui._release_desktop_activity():return
		elif owner_ui.has_meta("desktop_activity_owner") and is_instance_valid(owner_ui.get_meta("desktop_activity_owner")):return
		# The wrist belongs to this inventory and can release its own lock. A
		# title, pause, case or another panel's lock must remain with that owner.
		if "_desktop_wrist" in owner_ui and owner_ui._desktop_wrist:owner_ui._toggle_desktop_wrist(false)
		if is_instance_valid(owner_ui.player_body) and "controls_locked" in owner_ui.player_body and owner_ui.player_body.controls_locked:return
	owner_ui._release_case();owner_ui.case.close();owner_ui._close_map();owner_ui.wrist.hide()
	active=true;_armed=false;_pressed=false;owner_ui._claim("right",true);set_process(true)
	var hand:Variant=owner_ui.hands.get("right")
	if is_instance_valid(hand):hand.set_meta("pony_inspection",true)
	if owner_ui._desktop:
		_old_mouse=Input.mouse_mode;Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(owner_ui.player_body) and "controls_locked" in owner_ui.player_body:
			_lock_owned=not owner_ui.player_body.controls_locked;owner_ui.player_body.controls_locked=true
func close():
	if not active:return
	active=false;set_process(false);_clear_hand();_highlight(null);selected=null;panel.press(false);panel.hide();pointer.hide();_aura.hide();owner_ui._claim("right",false);_clear_claim()
	if owner_ui._desktop:
		var other_ui:bool=owner_ui._map_open() or owner_ui.customizer.opened or owner_ui.case.visible
		Input.mouse_mode=Input.MOUSE_MODE_VISIBLE if other_ui else _old_mouse
		if _lock_owned and is_instance_valid(owner_ui.player_body):owner_ui.player_body.controls_locked=other_ui
	_lock_owned=false
func back():
	panel.press(false);panel.hide();selected=null;_armed=false
func _changed(id:String):
	if is_instance_valid(selected) and selected.identity.id==id:_populate()
func _populate():
	if not is_instance_valid(selected) or not is_instance_valid(store) or not is_instance_valid(store.impressions):return
	panel.show_profile(selected.identity.id,selected.identity,_facts(selected.identity.id))

## Only gather player-facing relationship facts used by the summary.
func _facts(id: String) -> Dictionary:
	var page := page_for(store.player_bonds, id)
	if not page.is_empty(): return _page_facts(id, page)
	var identity: Resource = selected.identity
	var bonds: Node = store.player_bonds
	var now := Time.get_unix_time_from_system()
	var record: Dictionary = bonds.record_for(id)
	var impression: Dictionary = store.impressions.profile(id)
	var note: Dictionary = store.impressions.notes.get(id, {})
	var info := {"bond":record, "impression":impression, "thought":str(note.get("thought", "")),
		"romance_available":not identity.filly and not bonds._young_player()}
	info.space = float(record.cooldowns.get("boundary", 0.0)) > now
	var relationships: Node = get_tree().get_first_node_in_group("player_relationships")
	info.ladder = relationships.ladder(id) if relationships != null and relationships.has_method("ladder") else {}
	var welcome := PackedStringArray()
	if bonds.welcomes(id, "hug"): welcome.append("hugs")
	if identity.filly: welcome.append("forehead kisses only")
	elif bonds.welcomes(id, "kiss"): welcome.append("kisses")
	info.welcome = " and ".join(welcome)
	var offer: Dictionary = bonds.pending(id)
	info.invitation = ""
	if not offer.is_empty():
		var requests := {"dating":"start dating", "move_in":"share a home", "engagement":"get engaged", "marriage":"get married", "kiss":"share a kiss", "hug":"have a hug", "break_up":"end the relationship"}
		var activity: String = requests.get(str(offer.kind), "spend time together")
		if offer.kind in ["outing", "date"]:
			activity = "go on a date" if offer.kind == "date" else "spend time together"
			var detail := str(offer.get("activity", "")).replace("_", " ")
			if not detail.is_empty(): activity += " (" + detail + ")"
		info.invitation = ("You asked to " if offer.by == "player" else "They would like to ") + activity + "."
	var plan: Dictionary = record.plan
	info.plan = ""
	if not plan.is_empty():
		info.plan = str(plan.get("activity", "time together")).replace("_", " ").capitalize()
		if bool(plan.get("date", false)): info.plan += " — a date"
	info.memories = _memories(id)
	# Why the bars moved, or why a gain did not count (pony_impressions.gd change list, 2026-11-19).
	info.changes = change_lines(store.impressions, id, bool(info.romance_available))
	info.love_today = love_today_line(store.impressions, id) if bool(info.romance_available) else ""
	_purse_facts(id, info)
	return info

## The relationship page (switch on): player_bonds.page(id) as it is, with the memories, purse
## and show of today's page.
func _page_facts(id: String, page: Dictionary) -> Dictionary:
	var info := {"page": page, "memories": _memories(id)}
	_purse_facts(id, info)
	return info

## player_bonds.page(id) while the switch is on and the node has it; {} means today's page.
static func page_for(bonds: Variant, id: String) -> Dictionary:
	if not BOND.DYNAMIC or not bonds is Node or not is_instance_valid(bonds) or not (bonds as Node).has_method("page"): return {}
	var page: Variant = (bonds as Node).call("page", id)
	return page if page is Dictionary else {}

## Her three newest story events with Anon in them.
func _memories(id: String) -> Array:
	var memories: Array[String] = []
	for event: Dictionary in store.events_for(id, 64):
		if "player" in event.get("subjects", []): memories.append(str(event.text).left(160))
	return memories.slice(maxi(0, memories.size() - 3))

func _purse_facts(id: String, info: Dictionary) -> void:
	var game: Node = owner_ui.get_parent()
	info.purse = BITS.balance(store, id)
	info.player_bits = int(owner_ui.inventory.bits) if owner_ui.get("inventory") != null else 0
	var show: Node = game.get_node_or_null("TrixieShow") if is_instance_valid(game) else null
	if id == "trixie" and show != null:
		info.show_price = int(show.SHOW_PRICE)
		info.show_ready = not show.active()

## The page's "Ask her": her next turn that answers him carries the one line (player_bonds.ask_flag).
func _ask_her() -> void:
	if not is_instance_valid(selected) or not is_instance_valid(store): return
	var bonds: Variant = store.get("player_bonds")
	if bonds is Node and is_instance_valid(bonds) and (bonds as Node).has_method("ask_flag"): (bonds as Node).call("ask_flag", str(selected.identity.id))
	_populate()

## The page's "End it", after its confirmation: ends things at once (player_bonds.end_it).
func _end_it() -> void:
	if not is_instance_valid(selected) or not is_instance_valid(store): return
	var bonds: Variant = store.get("player_bonds")
	if bonds is Node and is_instance_valid(bonds) and (bonds as Node).has_method("end_it"): (bonds as Node).call("end_it", str(selected.identity.id))
	_populate()

## The reasons player_bonds.gd love_fact and pony_impressions.gd name, in the profile's words.
const WHY_WORDS := {"romantic_talk": "romantic talk she welcomed", "kiss": "a kiss she returned", "her_kiss": "she kissed you",
	"affection": "a hug or a held hoof", "gift": "a gift she accepted", "activity": "something you did together", "date": "a date you kept",
	"together": "time spent together", "intimacy": "intimacy", "her reply": "how she took your words"}

## Newest first, at most four: "Day 12 · Love +1 · a kiss she returned".
static func change_lines(impressions: Node, id: String, romance: bool) -> Array:
	var rows: Variant = impressions.get("changes")
	var list: Array = (rows as Dictionary).get(id, []) if rows is Dictionary else []
	var lines: Array = []
	for i in range(list.size() - 1, -1, -1):
		var row: Variant = list[i]
		if not row is Dictionary or lines.size() >= 4: continue
		var love := int(row.get("love", 0)); var friendship := int(row.get("friendship", 0))
		if not romance and love != 0 and friendship == 0: continue
		var moved := PackedStringArray()
		if love != 0 and romance: moved.append("Love %+d" % love)
		if friendship != 0: moved.append("Friendship %+d" % friendship)
		var why := str(WHY_WORDS.get(str(row.get("why", "")), str(row.get("why", ""))))
		var note := str(row.get("note", ""))
		lines.append("Day %d · %s%s" % [int(row.get("day", 0)), (" · ".join(moved) + " · ") if not moved.is_empty() else "", why + (" (" + note + ")" if not note.is_empty() else "")])
	return lines

## "Love today: +3; 5 more can count today", or "" before any love.
static func love_today_line(impressions: Node, id: String) -> String:
	if not impressions.has_method("love_room"): return ""
	var row: Dictionary = impressions.xp_for(id)
	var today := int(preload("res://world/mechanics/facts.gd").clock().day)
	var got := int(row.get("love_today", 0)) if int(row.get("love_day", -1)) == today else 0
	var room := int(impressions.love_room(id))
	if got == 0 and room == 0: return "Love grows once you are friends."
	return "Love today: +%d; %s" % [got, ("%d more can count today" % room) if room > 0 else "that is all for today"]

## Pay buttons: the bits move here (bit_payments.gd); her model is only told afterwards.
func _pay(amount: int) -> void:
	if not is_instance_valid(selected): return
	var id: String = selected.identity.id
	if not BITS.pay(owner_ui.get_parent(), selected, id, amount).is_empty(): _populate(); return
	_tell(id, "Anon just paid you %d bits. You now have %d bits." % [amount, BITS.balance(store, id)])
	_populate()

## Trixie's hire button: SHOW_PRICE bits paid, then her show starts (show_runtime.gd paid_show).
func _hire_show() -> void:
	if not is_instance_valid(selected) or selected.identity.id != "trixie": return
	var show: Node = owner_ui.get_parent().get_node_or_null("TrixieShow")
	if show == null or show.active(): return
	var price := int(show.SHOW_PRICE)
	if not BITS.pay(owner_ui.get_parent(), selected, "trixie", price).is_empty(): _populate(); return
	var note: String = show.paid_show(price, true)
	_tell("trixie", "Anon just paid you %d bits to put on a stage show. %s" % [price, note.trim_prefix("[").trim_suffix("]")])
	_populate()

func _tell(id: String, note: String) -> void:
	var director: Variant = owner_ui.get_parent().get("director")
	if director is Node and is_instance_valid(director) and director.has_method("told_paid"): director.told_paid(id, note)

func _highlight(pony:Node3D):
	if target==pony:return
	for mesh in _overlays:
		if is_instance_valid(mesh) and mesh.material_overlay==_material:mesh.material_overlay=_overlays[mesh]
	_overlays.clear();target=pony
	if not is_instance_valid(pony):return
	for mesh in pony.find_children("*","MeshInstance3D",true,false):
		if mesh.mesh!=null:
			_overlays[mesh]=mesh.material_overlay;mesh.material_overlay=_material
func pick(origin:Vector3,direction:Vector3)->Dictionary:
	var query:=PhysicsRayQueryParameters3D.create(origin,origin+direction*25.,7)
	query.exclude=_excluded
	query.collide_with_areas=true
	var hit:=get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():return {"pony":null,"point":origin+direction*25.}
	var actor:Node=hit.collider
	while is_instance_valid(actor) and not actor.is_in_group("sim_ponies"):actor=actor.get_parent()
	return {"pony":actor if is_instance_valid(actor) and "identity" in actor and actor.identity!=null else null,"point":hit.position}
func ray_input(origin:Vector3,direction:Vector3,pressed:bool):
	if not active:return
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared()<.5:
		tracking_lost();return
	if not pressed:_armed=true
	if panel.visible:
		var pixel:Vector2=panel.ray_to_pixel(origin,direction);panel.point_at(pixel)
		pointer.aim(origin,panel.pixel_to_world(pixel) if pixel.x>=0 else origin+direction*3.)
		panel.press(pressed and _armed and pixel.x>=0)
	else:
		var hit:=pick(origin,direction);_highlight(hit.pony);pointer.aim(origin,hit.point)
		if pressed and not _pressed and _armed and is_instance_valid(target):
			selected=target;_populate();_highlight(null)
			var head:Camera3D=owner_ui.camera
			panel.global_position=head.global_position-head.global_basis.z*1.15
			panel.look_at(head.global_position,Vector3.UP,true);panel.show();_armed=false
	_pressed=pressed
func tracking_lost():
	_clear_hand()
	_armed=false;_pressed=false;_highlight(null);pointer.hide();_aura.hide();panel.press(false)
func update_hand(sample:Dictionary):
	if not sample.get("active",false):tracking_lost();return
	var controller:Variant=owner_ui.controllers.get("right")
	var pose:Transform3D=controller.global_transform if is_instance_valid(controller) else sample.pose
	if not pose.is_finite():tracking_lost();return
	_hand_material.set_shader_parameter("hand_center",pose.origin)
	if _hand_overlays.is_empty():
		for parent in [owner_ui.avatar,owner_ui.hands.get("right")]:
			if not is_instance_valid(parent):continue
			var meshes:Array=parent.find_children("*","MeshInstance3D",true,false)
			if parent is MeshInstance3D:meshes.append(parent)
			for mesh in meshes:
				if mesh.is_visible_in_tree() and not _hand_overlays.has(mesh):
					_hand_overlays[mesh]=mesh.material_overlay;mesh.material_overlay=_hand_material
	_aura.global_position=pose.origin;_aura.show()
	ray_input(pose.origin,-pose.basis.z.normalized(),float(sample.trigger)>.6)
func _process(delta:float):
	if not active:return
	if owner_ui._map_open() or owner_ui.customizer.opened or owner_ui.case.visible:close();return
	if selected!=null and (not is_instance_valid(selected) or selected.is_queued_for_deletion()):back()
	_refresh+=delta
	if _refresh>=1.:
		_refresh=0.;_populate()
func _input(event:InputEvent):
	if not owner_ui._desktop:return
	if event is InputEventKey and event.pressed and not event.echo:
		if not active and (event.ctrl_pressed or event.alt_pressed or event.meta_pressed or get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit):return
		if event.physical_keycode==KEY_J:toggle();get_viewport().set_input_as_handled();return
		if active and event.physical_keycode==KEY_ESCAPE:close();get_viewport().set_input_as_handled();return
		if active and panel.visible and panel.scroll_key(event.physical_keycode):get_viewport().set_input_as_handled();return
	if not active:return
	if event is InputEventMouse:
		var pressed:bool=_pressed
		if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:pressed=event.pressed
		ray_input(owner_ui.camera.project_ray_origin(event.position),owner_ui.camera.project_ray_normal(event.position),pressed)
		if panel.visible and event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var pixel: Vector2 = panel.ray_to_pixel(owner_ui.camera.project_ray_origin(event.position), owner_ui.camera.project_ray_normal(event.position))
			panel.scroll_wheel(event, pixel)
		get_viewport().set_input_as_handled()
func _clear_claim():
	var hand:Variant=owner_ui.hands.get("right")
	if is_instance_valid(hand):hand.remove_meta("pony_inspection")
func _clear_hand():
	for mesh in _hand_overlays:
		if is_instance_valid(mesh) and mesh.material_overlay==_hand_material:mesh.material_overlay=_hand_overlays[mesh]
	_hand_overlays.clear()
func _exit_tree():
	if active and is_instance_valid(owner_ui):
		close()
		return
	_clear_hand()
	_highlight(null)
	if is_instance_valid(owner_ui):owner_ui._claim("right",false);_clear_claim()
