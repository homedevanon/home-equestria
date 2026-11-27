extends RefCounted
## Trial "render_thread" (2026-11-24): the game half of running the engine with
## `--render-thread separate` (the engine half is a patched binary; stock 4.5 hangs at boot and
## crashes at exit in that mode). With a separate render thread:
## - RenderingDevice calls are refused off the render thread, so readbacks go through
##   RenderingServer.call_on_render_thread;
## - frame_post_draw arrives as a deferred call, up to two frames late, so "UPDATE_ONCE, await
##   frame_post_draw, read" can read the picture from before the update: drawn() waits instead;
## - every synchronous RenderingServer getter waits for the draw in progress.
## Off (old code everywhere) unless the trial is on AND the thread is separate. Static only:
##   const RT := preload("res://world/perf/render_thread.gd")   ...   if RT.active(): ...
const TRY := preload("res://world/perf/try_switch.gd")

static var _active := -1
static var _readback: Dictionary = {}   # viewport instance id -> bool

## The engine was started with a separate render thread. Asked on the main thread, the server's own
## answer is exact: is_on_render_thread() is true there only when the main thread renders. (The
## engine consumes `--render-thread <mode>`, so OS.get_cmdline_args() never holds it; the argument
## and project-setting test below is only the fallback for worker threads, where
## is_on_render_thread() is false in both modes.)
static func separate() -> bool:
	if OS.get_thread_caller_id() == OS.get_main_thread_id(): return not RenderingServer.is_on_render_thread()
	var args := OS.get_cmdline_args()
	var at := args.find("--render-thread")
	if at >= 0 and at + 1 < args.size(): return args[at + 1] == "separate"
	return int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1)) == 2

static func active() -> bool:
	if _active < 0:
		var on := TRY.on("render_thread") and separate()
		if OS.get_thread_caller_id() != OS.get_main_thread_id(): return on   # cached from the main thread only
		_active = 1 if on else 0
	return _active == 1

## Awaited from the main thread: afterwards the draw of the frame the caller was in has finished
## (the process frame counter rises after that frame's draw was queued; force_sync then waits for it).
static func drawn(tree: SceneTree) -> void:
	var f := Engine.get_process_frames()
	while Engine.get_process_frames() <= f:
		await tree.process_frame
	RenderingServer.force_sync()

## Whether this viewport's texture can be read back asynchronously on the render thread. Asked once
## per viewport per run (one synchronisation each).
static func readback_ok(viewport: Viewport) -> bool:
	if viewport == null or viewport.get_texture() == null: return false
	var key := viewport.get_instance_id()
	if _readback.has(key): return bool(_readback[key])
	var rid := viewport.get_texture().get_rid()
	var answer := [false]
	RenderingServer.call_on_render_thread(func() -> void:
		var device := RenderingServer.get_rendering_device()
		if device == null or not device.has_method("texture_get_data_async"): return
		var texture := RenderingServer.texture_get_rd_texture(rid)
		if not texture.is_valid() or not device.texture_is_valid(texture): return
		var format: RDTextureFormat = device.texture_get_format(texture)
		answer[0] = format != null and format.format in [RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB])
	RenderingServer.force_sync()
	_readback[key] = bool(answer[0])
	return bool(answer[0])
