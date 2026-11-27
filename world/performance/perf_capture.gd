extends Node
## Performance capture for a headset or a slow machine (performance map 2026-11-21): one minute of
## the real game written to user://performance/capture-<time>.json, then nothing more. Off unless
## asked for; when off, `install()` returns without creating anything and no callback exists.
##
## Turn it on (developer builds and unlocked player builds, world/dev_tools.gd), any one of:
## - launch argument `--perf-capture` (or `--perf-capture=<seconds per part>`, default 20), e.g.
##   `equestria -- --perf-capture`;
## - the setting `debug/perf_capture` = true (autoload/settings.gd, when that row exists);
## - a file `user://performance/capture.on` (on the Quest: Android/data/<package>/files/performance/
##   capture.on); its text may be a number of seconds per part. It stays: every launch captures
##   until the file is removed.
## Play normally while it runs; it starts SETTLE seconds after the loading cover lifts and prints
## "[perf-capture]" lines to the log.
##
## Three parts, each `seconds` long, on world/performance/step_slices.gd:
## 1. clean: frame time distribution, physics steps per frame, the step's phases (callbacks,
##    skeleton queue, deferred calls, timers, navigation and Jolt), card time per frame, card time by
##    render pass when the device reports it (desktop: start the engine with --profile-gpu), memory,
##    crowd tiers. Nothing extra runs in the game during this part except one edge node pair.
## 2. owners: the same with owner markers: callback and queued time per root/Game child, per pony
##    tier, navigators and mod nodes (marker cost measured and subtracted).
## 3. labels: the CPU labels inside the pony step, crowd and services (tools/crowd_cpu_profile.gd).
const SLICES := preload("res://world/performance/step_slices.gd")
const LABELS := preload("res://tools/crowd_cpu_profile.gd")
const DEV := preload("res://world/dev_tools.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const RT := preload("res://world/perf/render_thread.gd")
const FLAG_FILE := "user://performance/capture.on"
const SETTLE := 20.0
const DEFAULT_SECONDS := 20.0
var game: Node
var seconds := DEFAULT_SECONDS
var trigger := ""


## Called once per world by world/game_player_rig.gd. Creates the capture only when asked for.
static func install(host: Node) -> void:
	if not DEV.enabled(): return
	var wanted := ""
	var length := DEFAULT_SECONDS
	for arg: String in DEV.user_args():
		if arg == "--perf-capture" or arg.begins_with("--perf-capture="):
			wanted = "argument"
			if arg.contains("="): length = arg.get_slice("=", 1).to_float()
	if wanted.is_empty():
		var settings: Node = host.get_node_or_null("/root/Settings")
		if settings != null and settings.has_method("get_value") and settings.call("get_value", "debug/perf_capture") == true:
			wanted = "setting"
	if wanted.is_empty() and FileAccess.file_exists(FLAG_FILE):
		wanted = "file"
		var text := FileAccess.get_file_as_string(FLAG_FILE).strip_edges()
		if text.is_valid_float(): length = text.to_float()
	if wanted.is_empty(): return
	var capture: Node = load("res://world/performance/perf_capture.gd").new()
	capture.name = "PerfCapture"
	capture.game = host
	capture.seconds = clampf(length if length > 0.0 else DEFAULT_SECONDS, 5.0, 300.0)
	capture.trigger = wanted
	host.add_child(capture)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false); set_physics_process(false)
	_run.call_deferred()


func _run() -> void:
	print("[perf-capture] on (%s): starts %d s after loading, three parts of %d s" % [trigger, int(SETTLE), int(seconds)])
	# Wait for the world to finish loading: the loading cover came and went (game.gd adds it right
	# after this node), or saving is open.
	var waited := 0.0
	var cover_seen := false
	while waited < 600.0:
		var cover := game.get_node_or_null("LoadingCover")
		if cover != null: cover_seen = true
		var saves: Variant = game.get(&"saves")
		if cover == null and (cover_seen or (saves != null and saves.get(&"ready_to_save") == true)): break
		if not await SHUTDOWN.seconds(self, 0.25): return
		waited += 0.25
	if not await SHUTDOWN.seconds(self, SETTLE): return
	var out := _about()
	print("[perf-capture] part 1/3: clean")
	var clean: Variant = await _part(false, false)
	if clean == null: return
	out["clean"] = clean
	print("[perf-capture] part 2/3: owners")
	var owned: Variant = await _part(true, false)
	if owned == null: return
	out["owners"] = owned
	print("[perf-capture] part 3/3: labels")
	var labelled: Variant = await _part(false, true)
	if labelled == null: return
	out["labels"] = labelled
	out["memory_after"] = _memory()
	var path := "user://performance/capture-%s.json" % Time.get_datetime_string_from_system().replace(":", "-")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[perf-capture] cannot write " + path)
	else:
		file.store_string(JSON.stringify(out, "\t"))
		file.close()
		var step: Dictionary = clean.get("step_us", {})
		print("[perf-capture] wrote %s: %.1f FPS, step %.2f ms mean, %.2f steps per frame" % [ProjectSettings.globalize_path(path),
			float(clean.get("fps", 0.0)), float(step.get("mean_us", 0.0)) / 1000.0, float(clean.get("steps_per_frame", 0.0))])
	queue_free()


## One part; null when the world closed meanwhile.
func _part(owners: bool, labels: bool) -> Variant:
	var slices = SLICES.new()
	slices.install(get_tree(), game, owners, 1)
	if labels:
		LABELS.enabled = true
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	if not await SHUTDOWN.seconds(self, 0.5):
		slices.uninstall(); LABELS.enabled = false; return null
	slices.reset()
	if labels: LABELS.reset()
	var where := _where()
	var gpu := [0.0, 0.0, 0]
	var per_second: Array[int] = []
	var started := Time.get_ticks_usec()
	var frames_counted := 0
	while Time.get_ticks_usec() - started < seconds * 1e6:
		if not await SHUTDOWN.frame(self):
			slices.uninstall(); LABELS.enabled = false; return null
		gpu[0] += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		gpu[1] += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		gpu[2] += 1
		var second := int((Time.get_ticks_usec() - started) / 1e6)
		while per_second.size() <= second: per_second.append(0)
		per_second[second] += 1
		frames_counted += 1
	var wall := (Time.get_ticks_usec() - started) / 1e6
	var result: Dictionary = slices.report()
	slices.uninstall()
	result["fps"] = snappedf(frames_counted / maxf(wall, 0.001), 0.1)
	result["fps_per_second"] = per_second
	result["frame_ms"] = _frame_dist(slices.frame_walls)
	result["card_ms"] = snappedf(gpu[0] / maxi(1, int(gpu[2])), 0.001)
	result["render_submit_cpu_ms"] = snappedf(gpu[1] / maxi(1, int(gpu[2])), 0.001)
	result["where_start"] = where
	result["where_end"] = _where()
	if not owners and not labels:
		result["gpu_passes"] = await _gpu_passes()
	if labels:
		LABELS.enabled = false
		var report: Dictionary = LABELS.report()
		var rows: Array = []
		for label: String in report:
			if report[label] is Dictionary:
				rows.append([label, snappedf(float(report[label].ms_per_physics_tick) * 1000.0, 0.1), int(report[label].calls), snappedf(float(report[label].us_per_call), 0.01)])
		rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
		result["labels_us_per_tick"] = rows.slice(0, 60)
	result["memory"] = _memory()
	return result


static func _frame_dist(walls: PackedFloat64Array) -> Dictionary:
	if walls.is_empty(): return {}
	var sorted := Array(walls); sorted.sort()
	var sum := 0.0
	for v: float in sorted: sum += v
	var n := sorted.size()
	return {"mean": snappedf(sum / n, 0.001), "p50": snappedf(sorted[n / 2], 0.001), "p95": snappedf(sorted[int(n * 0.95)], 0.001),
		"p99": snappedf(sorted[int(n * 0.99)], 0.001), "max": snappedf(sorted[-1], 0.001), "n": n}


## Card time by render pass over 60 frames when the device captures timestamps (desktop: engine
## started with --profile-gpu, or the editor's visual profiler). Otherwise a note. Godot 4.5's help
## text says --gpu-profile, but only --profile-gpu is parsed (main.cpp). The viewport's own
## render-time markers (vp_begin/vp_end) are always there and do not count as passes.
func _gpu_passes() -> Variant:
	if RT.active(): return "not read with a separate render thread"
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return "no RenderingDevice (Compatibility renderer)"
	var passes := false
	for k in rd.get_captured_timestamps_count():
		if not rd.get_captured_timestamp_name(k).begins_with("vp_"): passes = true; break
	if not passes: return "not reported by this run (desktop: start the engine with --profile-gpu)"
	var sums := {}
	var order: Array = []
	var frames := 0
	for i in 60:
		if not await SHUTDOWN.rendered_frame(self): return "cancelled"
		var count := rd.get_captured_timestamps_count()
		if count < 2: continue
		frames += 1
		# Each marker is captured where its pass starts, so the time up to the next marker is its pass
		# (the engine's own --profile-gpu print reads them the same way).
		for k in range(0, count - 1):
			var key := rd.get_captured_timestamp_name(k)
			if not sums.has(key): sums[key] = 0.0; order.append(key)
			sums[key] += (rd.get_captured_timestamp_gpu_time(k + 1) - rd.get_captured_timestamp_gpu_time(k)) / 1e6
	var rows: Array = []
	for key: String in order:
		var ms: float = sums[key] / maxi(frames, 1)
		if ms >= 0.005: rows.append([key, snappedf(ms, 0.001)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	return {"frames": frames, "ms_per_pass": rows}


func _where() -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	var crowd: Node = get_tree().root.get_node_or_null("PonyCrowd")
	var near := 0
	if camera != null:
		for pony: Node in get_tree().get_nodes_in_group(SLICES.MEMBERS):
			if pony is Node3D and (pony as Node3D).global_position.distance_to(camera.global_position) < 12.0: near += 1
	var clock: Node = get_tree().root.get_node_or_null("TimeOfDay")
	return {"camera": [snappedf(camera.global_position.x, 0.1), snappedf(camera.global_position.y, 0.1), snappedf(camera.global_position.z, 0.1)] if camera != null else [],
		"ponies_within_12m": near, "crowd": crowd.get(&"statistics") if crowd != null else {},
		"hour": snappedf(float(clock.get(&"hours")), 0.01) if clock != null else -1.0,
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))}


static func _memory() -> Dictionary:
	var info := OS.get_memory_info()
	return {"static_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1),
		"static_peak_mb": snappedf(OS.get_static_memory_peak_usage() / 1048576.0, 0.1),
		"video_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"texture_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"buffer_mb": snappedf(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, 0.1),
		"system_available_mb": snappedf(float(info.get("available", -1)) / 1048576.0, 0.1),
		"system_physical_mb": snappedf(float(info.get("physical", -1)) / 1048576.0, 0.1),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))}


func _about() -> Dictionary:
	var xr_interface := XRServer.find_interface("OpenXR")
	var xr := xr_interface != null and xr_interface.is_initialized() and get_viewport().use_xr
	var settings: Node = get_tree().root.get_node_or_null("Settings")
	var quality: Node = get_tree().root.get_node_or_null("Quality")
	var about := {"schema": 1, "when": Time.get_datetime_string_from_system(true), "trigger": trigger, "seconds_per_part": seconds,
		"platform": OS.get_name(), "model": OS.get_model_name(), "cpu": OS.get_processor_name(), "cpu_threads": OS.get_processor_count(),
		"gpu": RenderingServer.get_video_adapter_name(), "gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"renderer": str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), "engine": Engine.get_version_info().get("string", ""),
		"xr": xr, "viewport": [get_viewport().size.x, get_viewport().size.y], "scale_3d": get_viewport().scaling_3d_scale,
		"physics_hz": Engine.physics_ticks_per_second, "max_steps_per_frame": Engine.max_physics_steps_per_frame,
		"preset": str(settings.call("get_value", "video/quality")) if settings != null else "",
		"quality": quality.call("get_config") if quality != null and quality.has_method("get_config") else {},
		"ponies": get_tree().get_nodes_in_group(SLICES.MEMBERS).size(), "memory_before": _memory(),
		"note": "Frame times are wall clock between process frames on the main thread (in a headset they include the compositor's pacing). Step phases and owners are exact main-thread microseconds; owner tables have the measured marker cost subtracted."}
	if xr:
		about["eye_size"] = [xr_interface.get_render_target_size().x, xr_interface.get_render_target_size().y]
		about["refresh_hz"] = float(xr_interface.call("get_display_refresh_rate")) if xr_interface.has_method("get_display_refresh_rate") else 0.0
	return about
