extends Node3D
signal dismissed
const VIEW := preload("res://world/customization/clothing_view.gd")
var profile: RefCounted
var ui: Control
var viewport: SubViewport
var mirror: SubViewport
var screen: Sprite3D
var camera: Camera3D
var opened := false
var _timer := 0.
var _avatar: Node3D
var _human_avatar: Node3D
var _preview_rect: TextureRect
var pony_mode := false
func setup(settings: RefCounted, head: Camera3D, player_avatar: Node3D):
	profile=settings;camera=head
	viewport=SubViewport.new();viewport.size=Vector2i(1200,760);viewport.disable_3d=true;viewport.gui_disable_input=true
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED;add_child(viewport)
	ui=VIEW.new();viewport.add_child(ui);ui.dirty.connect(refresh);ui.bind(profile);ui.store=get_parent().get("inventory") if get_parent()!=null else null
	_avatar=player_avatar;_human_avatar=player_avatar
	ui.height_available = is_instance_valid(_avatar) and _avatar.has_method("begin_height_calibration") and XRServer.primary_interface != null and XRServer.primary_interface.is_initialized()
	_preview_rect=TextureRect.new();_preview_rect.position=Vector2(672,93);_preview_rect.size=Vector2(480,576)
	_preview_rect.mouse_filter=Control.MOUSE_FILTER_IGNORE;ui.add_child(_preview_rect)
	screen=Sprite3D.new();screen.texture=viewport.get_texture();screen.pixel_size=.00078;screen.shaded=false
	screen.double_sided=false;screen.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;add_child(screen)
	hide();set_process(false)
func show_menu():
	# No crossover (dev 2026-10-14): the human wardrobe only for Anon, the pony one only for her.
	if pony_mode and not _is_pony():_use_human()
	if mirror==null:
		mirror=load("res://world/customization/pony_mirror.gd" if pony_mode else "res://world/customization/anon_mirror.gd").new();add_child(mirror);mirror.setup(profile,_avatar)
		_preview_rect.texture=mirror.get_texture()
	var forward:Vector3=-camera.global_basis.z;forward.y=0
	if forward.length_squared()<.01:forward=Vector3.FORWARD
	global_position=camera.global_position+forward.normalized()*.67+Vector3.DOWN*.20
	look_at(camera.global_position,Vector3.UP,true)
	opened=true;show();mirror.set_active(true);set_process(true);refresh()
func use_pony(actor: Node3D) -> void:
	if pony_mode and _avatar == actor:return
	pony_mode=true;_avatar=actor;profile.attach_pony(actor)
	if mirror!=null:mirror.queue_free();mirror=null
	ui.remove_child(_preview_rect);ui.free()
	ui=load("res://world/customization/pony_clothing_view.gd").new();viewport.add_child(ui)
	ui.dirty.connect(refresh);ui.bind(profile);ui.add_child(_preview_rect)
	ui.set_store(get_parent().get("inventory") if get_parent()!=null else null)

func _is_pony() -> bool:
	var form:GDScript=load("res://world/life/player_form.gd")
	return is_inside_tree() and form.call("is_pony",form.call("active",get_tree()))==true

## Back on two legs: the human wardrobe and mirror again.
func _use_human() -> void:
	pony_mode=false;_avatar=_human_avatar
	if mirror!=null:mirror.queue_free();mirror=null
	ui.remove_child(_preview_rect);ui.free()
	ui=VIEW.new();viewport.add_child(ui);ui.dirty.connect(refresh);ui.bind(profile);ui.store=get_parent().get("inventory") if get_parent()!=null else null;ui.add_child(_preview_rect)
	ui.height_available=is_instance_valid(_avatar) and _avatar.has_method("begin_height_calibration") and XRServer.primary_interface!=null and XRServer.primary_interface.is_initialized()
func close(save: bool = false):
	if not opened:return
	if save and not profile.save():ui.message=profile.last_error;ui.refresh();return
	if not save:profile.revert()
	opened=false;hide();mirror.set_active(false);set_process(false)
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED;dismissed.emit()
func refresh():
	if viewport!=null:viewport.render_target_update_mode=SubViewport.UPDATE_ONCE if opened else SubViewport.UPDATE_DISABLED
func _process(delta: float):
	if ui.height_available and not _avatar.calibration_message.is_empty():
		ui.message = _avatar.calibration_message; ui.queue_redraw()
	_timer+=delta
	if _timer>=.05:_timer=0.;refresh()
func activate(point: Vector2):
	if not opened:return
	if VIEW.HEIGHT.has_point(point) and ui.height_available: _avatar.begin_height_calibration()
	elif VIEW.SAVE.has_point(point):close(true)
	elif VIEW.CANCEL.has_point(point):close(false)
	elif Rect2(680,682,72,52).has_point(point):mirror.yaw-=.4
	elif Rect2(766,682,99,52).has_point(point):mirror.yaw=0.;mirror.zoom=3.
	elif Rect2(879,682,72,52).has_point(point):mirror.yaw+=.4
	else:ui.choose(point)
func world_point(pixel: Vector2, depth: float = 0.) -> Vector3:return to_global(Vector3((pixel.x-600)*.00078,(380-pixel.y)*.00078,depth))
func panel_point(at: Vector3) -> Vector3:
	var p:=to_local(at);return Vector3(p.x/.00078+600.,380.-p.y/.00078,p.z)
func ray_point(origin: Vector3, direction: Vector3) -> Vector3:
	var denominator:=global_basis.z.dot(direction)
	if denominator>=-.0001:return Vector3.INF
	var t:=global_basis.z.dot(global_position-origin)/denominator
	return panel_point(origin+direction*t) if t>=0 and t<=3. else Vector3.INF
