extends RefCounted
## Save thumbnails (dev 2026-10-15: "add a screenshot of the last second it was loaded whenever you
## exit as preview"): the last frame the player saw, a 480x270 JPG beside the checkpoint
## (<name>.preview.jpg, world/saves/save_catalogue.gd).
##
## Where the frame comes from (world/game_saves.gd):
## - a menu that covers the view (pause, saved games) remembers the frame under it when it opens,
##   so saves and the quit save made from it show the world, not the menu;
## - rolling autosaves and quick saves read the current frame back from the GPU asynchronously
##   (no stall); the worker that writes the checkpoint waits briefly for it;
## - closing the window reads the current frame synchronously (it is the last thing that happens).
## The desktop viewport only. Headless runs and headsets (whose view is not the desktop window)
## save no picture and the menus draw a placeholder instead; the old picture is removed so it can
## never describe a different moment.
const SIZE := Vector2i(480, 270)
const QUALITY := 0.82
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const RT := preload("res://world/perf/render_thread.gd")


## An asynchronous GPU readback in flight: requested on the main thread, awaited on a worker.
class Pending extends RefCounted:
	var _mutex := Mutex.new()
	var _done := false
	var _image: Image

	func finish(value: Image) -> void:
		_mutex.lock()
		if not _done: _image = value; _done = true
		_mutex.unlock()

	## The frame, or null after timeout_ms (or after cancel()).
	func wait(timeout_ms: int) -> Image:
		var until := Time.get_ticks_msec() + timeout_ms
		while true:
			_mutex.lock()
			var finished := _done
			var value := _image
			_mutex.unlock()
			if finished: return value
			if Time.get_ticks_msec() >= until: return null
			OS.delay_msec(4)
		return null

	## The main thread is about to block on the worker: the readback can no longer arrive.
	func cancel() -> void:
		finish(null)


## Whether this viewport shows what the player sees on the desktop.
static func available(viewport: Viewport) -> bool:
	return viewport != null and DisplayServer.get_name() != "headless" and not viewport.use_xr and viewport.get_texture() != null


## The frame on screen now, full size, or null. Synchronous: one GPU readback stall.
static func grab(viewport: Viewport) -> Image:
	if not available(viewport): return null
	var image := viewport.get_texture().get_image()
	return image if image != null and not image.is_empty() else null


## The frame on screen now through an asynchronous readback; null when the renderer cannot
## (then grab() is the fallback).
static func request(viewport: Viewport) -> Pending:
	if not available(viewport): return null
	if RT.active():
		# Trial render_thread: the request and its callback run on the render thread; Pending is
		# mutex-guarded, so finishing it there is safe.
		if not RT.readback_ok(viewport): return null
		var rid := viewport.get_texture().get_rid()
		var waiting := Pending.new()
		RenderingServer.call_on_render_thread(func() -> void:
			var rd := RenderingServer.get_rendering_device()
			var texture := RenderingServer.texture_get_rd_texture(rid) if rd != null else RID()
			if not texture.is_valid() or not rd.texture_is_valid(texture):
				waiting.finish(null); return
			var format: RDTextureFormat = rd.texture_get_format(texture)
			if format == null:
				waiting.finish(null); return
			var w := int(format.width)
			var h := int(format.height)
			var error: Error = rd.texture_get_data_async(texture, 0, func(data: PackedByteArray) -> void:
				waiting.finish(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data) if data.size() == w * h * 4 else null))
			if error != OK: waiting.finish(null))
		return waiting
	var device := RenderingServer.get_rendering_device()
	if device == null or not device.has_method("texture_get_data_async"): return null
	var texture := RenderingServer.texture_get_rd_texture(viewport.get_texture().get_rid())
	if not texture.is_valid() or not device.texture_is_valid(texture): return null
	var format: RDTextureFormat = device.texture_get_format(texture)
	if format == null or format.format not in [RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB]: return null
	var width := int(format.width)
	var height := int(format.height)
	var pending := Pending.new()
	var error: Error = device.texture_get_data_async(texture, 0, func(data: PackedByteArray) -> void:
		pending.finish(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data) if data.size() == width * height * 4 else null))
	return pending if error == OK else null


## Centre-cropped to 16:9 and scaled to SIZE (box-filtered halvings, then bilinear). Any thread.
static func fit(source: Image) -> Image:
	if source == null or source.is_empty() or source.is_compressed(): return null
	var image := source.duplicate() as Image
	image.convert(Image.FORMAT_RGB8)
	var width := image.get_width()
	var height := image.get_height()
	var aspect := float(SIZE.x) / float(SIZE.y)
	var crop := Rect2i(0, 0, width, height)
	if float(width) / float(height) > aspect:
		crop.size.x = int(height * aspect); crop.position.x = (width - crop.size.x) / 2
	else:
		crop.size.y = int(width / aspect); crop.position.y = (height - crop.size.y) / 2
	image = image.get_region(crop)
	while image.get_width() >= SIZE.x * 2 and image.get_height() >= SIZE.y * 2: image.shrink_x2()
	image.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_BILINEAR)
	return image


## Writes `frame` (Image, Pending, or anything else for "no picture") as the checkpoint's
## preview. Any thread. True when a picture was written.
static func store(frame: Variant, save_path: String, wait_ms := 1000) -> bool:
	var target := CATALOGUE.preview_path(save_path)
	var image: Image = null
	if frame is Pending: image = (frame as Pending).wait(wait_ms)
	elif frame is Image: image = frame
	var fitted := fit(image)
	if fitted == null:
		if FileAccess.file_exists(target): DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
		return false
	var temporary := target + ".%d.tmp" % (randi() % 1000000)
	if fitted.save_jpg(temporary, QUALITY) != OK: return false
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(target)) == OK


## The preview as a texture for menus, or null.
static func texture(path: String) -> Texture2D:
	if path.is_empty() or not FileAccess.file_exists(path): return null
	var image := Image.new()
	if image.load(path) != OK or image.is_empty(): return null
	return ImageTexture.create_from_image(image)
