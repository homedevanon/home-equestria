extends Node3D
## Saved games panel (F6, the pause menu's Save/Load, the VR map): the saves browser
## (world/ui/save_browser.gd) on a menu card. Every world is a folder, every save a card with its
## screenshot, what kind of save it is, the in-game day and time, where the player was and as
## whom, when it was saved and how long the world has been played (dev 2026-10-15: "its really
## unclear what save games are what"); saves take names, tags and stars, and New save makes as
## many as wanted (dev 2026-10-27: "we need more place with folders and tag for save").
## Desktop: a card sized to the window on its own layer, scaled up with a big window. VR: a World Panel in front of the
## player, pointed at with the right controller. F5 quick-saves into slot 1, F8 loads it.
## Data: world/saves/save_catalogue.gd (headers only); loading validates (world/game_saves.gd).
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const VIEW := preload("res://world/player_view.gd")
const CARD := preload("res://world/ui/menu_card.gd")
const FX := preload("res://world/ui/menu_fx.gd")
const BROWSER := preload("res://world/ui/save_browser.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
## The largest desktop card in layout pixels (world/ui/menu_style.gd fit_card); a smaller window
## gets a smaller one.
const DESKTOP_SIZE := Vector2(1440, 840)
var saves:Node
var ui:Node
var panel:Node3D
var pointer:Node3D
var content:Control
var canvas:CanvasLayer
var browser:Control
var opened:=false
var _armed:=false
var _mouse_mode:int
var _old_lock:=false
var _input_states:Dictionary={}
var _old_physics:=true
var _built_size:=Vector2.ZERO
var _card:Control

func setup(store:Node,inventory_ui:Node)->void:
	saves=store;ui=inventory_ui
	if ui._desktop:
		canvas=CanvasLayer.new();canvas.layer=150;add_child(canvas)
		var shade:=ColorRect.new();shade.color=Color(0.04,0.01,0.07,0.5);shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		canvas.add_child(shade)
		content=Control.new();canvas.add_child(content);canvas.hide()
		# A window resized while the panel shows: it fits the new one at once.
		get_viewport().size_changed.connect(func()->void:if opened:_place_desktop())
	else:
		panel=preload("res://world/ui/spatial_menu_panel.gd").new();add_child(panel);panel.hide();content=panel.content
		pointer=preload("res://world/ui/controller_pointer.gd").new();add_child(pointer)

## Desktop: the card as big as the window allows, scaled with it and centred. The first call
## builds the browser (true), which then needs opening; later sizes reshape it in place, so an open
## save's page or editor stays.
func _place_desktop()->bool:
	var screen:=Vector2(get_viewport().get_visible_rect().size)
	var scale:=STYLE.window_scale(screen)
	var rebuilt:=_build(STYLE.fit_card(screen,DESKTOP_SIZE))
	content.scale=Vector2.ONE*scale;STYLE.sharpen(get_viewport(),scale)
	content.position=((screen-content.size*scale)*.5).floor()
	if rebuilt and opened:browser.open();browser.first_focus().grab_focus()
	return rebuilt

## The card and the browser for `card_size`: built once, then resized in place.
func _build(card_size:Vector2)->bool:
	if browser!=null and card_size==_built_size:return false
	_built_size=card_size
	content.size=card_size
	if browser!=null:
		_card.size=card_size;browser.relayout(card_size-Vector2(68,58))
		return false
	var card:=CARD.new();card.size=card_size;content.add_child(card);_card=card
	browser=BROWSER.new();browser.panel=panel
	browser.position=Vector2(34,30)
	content.add_child(browser)
	browser.setup(card_size-Vector2(68,58),20,saves,panel!=null)
	if panel!=null:browser.redraw=panel.refresh
	browser.closed.connect(close)
	browser.load_requested.connect(_load)
	var fx:=FX.new();content.add_child(fx);fx.attach(content,browser.redraw);browser.fx=fx
	return true

func _load(entry:Dictionary)->void:
	var here:=str(saves.directory).get_base_dir().get_file()
	if str(entry.get("world_id",""))==here or not saves.has_method("load_world_save"):saves.load_save(str(entry.path))
	else:saves.load_world_save(entry)

func toggle()->void:
	if opened:close();return
	if ui.customizer.opened:return
	if ui.hand_busy("right") or ui.hand_busy("left"):return
	# Before this panel draws: saves made from it show the world under it.
	if saves.has_method("remember_view"):saves.remember_view(self)
	if ui._desktop:DESKTOP_OWNER.cancel_current(ui)
	if is_instance_valid(ui.inspector):ui.inspector.close()
	ui._close_map();ui._release_case();ui.case.close();ui.wrist.hide()
	opened=true;_armed=false;_old_lock=ui.player_body.controls_locked;ui.player_body.controls_locked=true
	_old_physics=ui.is_physics_processing()
	for node in [ui,ui.inspector,ui.map_menu]:
		if not is_instance_valid(node):continue
		_input_states[node]=node.is_processing_input();node.set_process_input(false)
		if node==ui.map_menu:node.set_meta("save_menu_open",true)
	ui._claim("right",true);ui._claim("left",true);ui.set_physics_process(false)
	if ui._desktop:
		_mouse_mode=Input.mouse_mode;Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
		_place_desktop();canvas.show()
	else:
		_build(Vector2(panel.PIXELS))
		panel.global_position=ui.camera.global_position-ui.camera.global_basis.z*1.4
		panel.look_at(ui.camera.global_position,Vector3.UP,true);panel.show();panel.tick=1.0/20.0;panel.refresh()
	browser.open()
	browser.first_focus().grab_focus()
	_menu_sound("prop_ui_confirm")

func close()->void:
	if not opened:return
	_menu_sound("prop_ui_back")
	opened=false
	ui._claim("right",false);ui._claim("left",false);ui.set_physics_process(_old_physics);ui.player_body.controls_locked=_old_lock
	for node in _input_states:
		if is_instance_valid(node):node.set_process_input(_input_states[node]);node.remove_meta("save_menu_open")
	_input_states.clear()
	if ui._desktop:canvas.hide();Input.mouse_mode=_mouse_mode;STYLE.sharpen(get_viewport(),1.0)
	else:panel.press(false);panel.hide();panel.tick=0.0;pointer.hide()
	if saves.has_method("release_view"):saves.release_view(self)

func _menu_sound(event:String)->void:
	var camera:Camera3D=VIEW.camera(self)
	if camera!=null:SOUNDS.play_at(camera,event,camera.global_position)

func _process(_delta:float)->void:
	if not opened or ui._desktop:return
	var sample:Dictionary=ui.hand_sample("right")
	if not sample.get("active",false):_armed=false;panel.press(false);pointer.hide();return
	var pose:Transform3D=sample.aim
	if not pose.is_finite():_armed=false;panel.press(false);pointer.hide();return
	var pressed:bool=sample.trigger>.6
	if not pressed:_armed=true
	var pixel:Vector2=panel.ray_to_pixel(pose.origin,-pose.basis.z)
	panel.point_at(pixel);panel.press(pressed and _armed and pixel.x>=0)
	pointer.aim(pose.origin,panel.pixel_to_world(pixel) if pixel.x>=0 else pose.origin-pose.basis.z*2.)

func _input(event:InputEvent)->void:
	if event is InputEventKey and event.pressed and not event.echo:
		if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:return
		match event.physical_keycode:
			KEY_F6:toggle();get_viewport().set_input_as_handled()
			KEY_F5:saves.save_slot(0);get_viewport().set_input_as_handled()
			KEY_F8:
				get_viewport().set_input_as_handled()   # handled first: the reload frees this viewport
				# Refused (a scenario save with its mod off, a vanilla one with a scenario on, a busy
				# save): say why on the hotbar instead of nothing happening.
				saves.message=""
				if not saves.load_save(saves.slot_path(0)) and str(saves.message)!="" and ui.get("hotbar")!=null:ui.hotbar.set_message(str(saves.message),true)
			KEY_ESCAPE:
				if opened:
					# A save's page or an editor closes first, then the panel.
					if not browser.back():close()
					get_viewport().set_input_as_handled()
