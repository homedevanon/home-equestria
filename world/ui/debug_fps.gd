extends Node
## Small desktop/stereo HUD and a bounded live diagnostic file.
## F10 cycles full profile → FPS only → off. F9 records a trace independently.
## Player builds (world/dev_tools.gd) show only the FPS number: F10 toggles it, no F9 trace.
enum DisplayMode { FULL, FPS, OFF }
const DEV := preload("res://world/dev_tools.gd")
const RT := preload("res://world/perf/render_thread.gd")
var display_mode := DisplayMode.FULL if DEV.enabled() else DisplayMode.FPS
## Existing capture tools can still hide the display with enabled=false.
var enabled: bool:
	get: return display_mode != DisplayMode.OFF
	set(value): display_mode = (DisplayMode.FULL if DEV.enabled() else DisplayMode.FPS) if value else DisplayMode.OFF
var report_path:="user://performance/live.json"
var camera:Camera3D
var stereo:=false
var label:Node
var canvas:CanvasLayer
var samples:Array[float]=[]
var summary:Dictionary={}
var _clock:=0.0
var _write_clock:=0.0
var _last:=0
var _profile:Node
## Trial render_thread: each RenderingServer getter waits for the draw in progress there, so the
## adapter name is read once and the render times at most once a second.
var _rt_adapter:=""
var _rt_gpu_ms:=0.0
var _rt_cpu_ms:=0.0
var _rt_read_ms:=-1000000

func setup(head:Camera3D,xr:bool)->void:
	camera=head;stereo=xr
	if xr:
		var text:=Label3D.new();text.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF
		text.position=Vector3(0,.22,-1.0);text.pixel_size=.0007;text.font_size=42;text.outline_size=2
		text.font=preload("res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf")
		text.no_depth_test=true;text.shaded=false;text.modulate=Color("d8f5da")
		text.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		head.add_child(text);label=text
		preload("res://world/ui/head_locked_hud.gd").attach(head,text)
	else:
		canvas=CanvasLayer.new();add_child(canvas)
		var text:=Label.new();text.position=Vector2(14,14);text.mouse_filter=Control.MOUSE_FILTER_IGNORE
		text.add_theme_font_size_override("font_size",20);text.add_theme_constant_override("outline_size",6)
		canvas.add_child(text);label=text
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(),true)
	_last=Time.get_ticks_usec()
	_refresh()

func _process(delta:float)->void:
	if not is_instance_valid(camera):return
	var now:=Time.get_ticks_usec()
	if _last>0:samples.append((now-_last)/1000.0)
	_last=now
	if samples.size()>120:samples.pop_front()
	_clock+=delta;_write_clock+=delta
	if _clock>=.25:_clock=0;_refresh()
	if _write_clock>=2.0:
		_write_clock=0
		if not report_path.is_empty():
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(report_path.get_base_dir()))
			var file:=FileAccess.open(report_path,FileAccess.WRITE)
			if file:file.store_string(JSON.stringify(summary))

func _refresh()->void:
	var sorted:=samples.duplicate();sorted.sort()
	var mean:=0.0
	for value in samples:mean+=value
	mean/=maxi(samples.size(),1)
	var vp:=get_viewport().get_viewport_rid()
	var rt:=RT.active()
	if rt:
		if _rt_adapter.is_empty():_rt_adapter=RenderingServer.get_video_adapter_name()
		if Time.get_ticks_msec()-_rt_read_ms>=1000:
			_rt_read_ms=Time.get_ticks_msec()
			_rt_gpu_ms=RenderingServer.viewport_get_measured_render_time_gpu(vp)
			_rt_cpu_ms=RenderingServer.viewport_get_measured_render_time_cpu(vp)
	summary={"time":Time.get_datetime_string_from_system(true),"pid":OS.get_process_id(),
		"gpu":_rt_adapter if rt else RenderingServer.get_video_adapter_name(),"xr":stereo,
		"fps":Engine.get_frames_per_second(),"frame_ms":mean,
		"p95_ms":sorted[mini(sorted.size()-1,int(sorted.size()*.95))] if not sorted.is_empty() else 0.0,
		"gpu_ms":_rt_gpu_ms if rt else RenderingServer.viewport_get_measured_render_time_gpu(vp),
		"render_cpu_ms":_rt_cpu_ms if rt else RenderingServer.viewport_get_measured_render_time_cpu(vp),
		"physics_ms":Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0,
		"process_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000.0,
		"draw_calls":int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"triangles":int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"vram_mb":Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576.0,
		"pipelines":int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)),
		"position":[camera.global_position.x,camera.global_position.y,camera.global_position.z],
		"view_rotation":[camera.global_rotation.x,camera.global_rotation.y,camera.global_rotation.z],
		"world_hour":get_node("/root/TimeOfDay").hours,
		"timing_note":"Wall includes presentation waits; Performance counters can lag by one second. GPU is engine viewport timing."}
	if label!=null:
		label.visible=enabled
		if display_mode == DisplayMode.FPS:
			label.text = "%d FPS" % summary.fps
		elif display_mode == DisplayMode.FULL:
			label.text="%d FPS  ·  %.1f ms  ·  p95 %.1f\nGPU %.1f ms  ·  physics %.1f ms\n%d draws  ·  %.1f M tris"%[summary.fps,mean,summary.p95_ms,summary.gpu_ms,summary.physics_ms,summary.draw_calls,summary.triangles/1000000.0]

func _unhandled_key_input(event:InputEvent)->void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_F9 and DEV.enabled():
		start_profile();get_viewport().set_input_as_handled();return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_F10:
		if DEV.enabled(): display_mode = (display_mode + 1) % DisplayMode.size()
		else: display_mode = DisplayMode.OFF if display_mode == DisplayMode.FPS else DisplayMode.FPS
		_refresh();get_viewport().set_input_as_handled()

func start_profile()->void:
	if is_instance_valid(_profile):return
	_profile=load("res://tools/runtime_profile.gd").new()
	_profile.keep_open=true
	add_child(_profile)
	_profile._out="user://performance/trace-%d.json"%Time.get_unix_time_from_system()
	_profile.begin(get_parent())
	_profile.completed.connect(func():
		_profile.queue_free();_profile=null)

func _exit_tree()->void:
	if stereo and is_instance_valid(label):label.queue_free()
