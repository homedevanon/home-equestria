extends RefCounted
## Waits that end at shutdown. A coroutine still suspended when the engine exits leaves its
## pooled locals (Transform3D, AABB) alive past teardown, which logs "Pages in use exist at exit
## in PagedAllocator" (dev's bug: errors when quitting; tools/probe_exit_pools.gd reproduces it,
## whatever the coroutine awaited). The game calls begin() as its world leaves the tree: every
## pending wait resumes at once and returns false, so its caller unwinds while scripts still live.
##
##   if not await SHUTDOWN.seconds(self, 0.25): return
##   if not await SHUTDOWN.frame(self): return          # next process frame
##   if not await SHUTDOWN.physics_frame(self): return

const RT := preload("res://world/perf/render_thread.gd")

class Waiter extends RefCounted:
	signal done
	var finished := false
	var cancelled := false
	func cancel() -> void:
		cancelled = true
		finish()
	func finish() -> void:
		if finished: return
		finished = true
		done.emit()

static var active := false
static var _pending: Array[Waiter] = []

static func seconds(owner: Node, duration: float) -> bool:
	if not _usable(owner): return false
	var waiter := _waiter(owner)
	owner.get_tree().create_timer(duration).timeout.connect(waiter.finish)
	return await _finish(waiter, owner)

static func frame(owner: Node) -> bool:
	if not _usable(owner): return false
	var waiter := _waiter(owner)
	owner.get_tree().process_frame.connect(waiter.finish, CONNECT_ONE_SHOT)
	return await _finish(waiter, owner)

static func physics_frame(owner: Node) -> bool:
	if not _usable(owner): return false
	var waiter := _waiter(owner)
	owner.get_tree().physics_frame.connect(waiter.finish, CONNECT_ONE_SHOT)
	return await _finish(waiter, owner)

## RenderingServer outlives a world, so disconnect even when shutdown wins the race.
static func rendered_frame(owner: Node) -> bool:
	if not _usable(owner): return false
	if RT.active():
		# Trial render_thread: frame_post_draw is deferred to the main thread in this mode and can
		# belong to a draw from before the caller's change; wait for this frame's own draw instead.
		var f := Engine.get_process_frames()
		while Engine.get_process_frames() <= f:
			if not await frame(owner): return false
		RenderingServer.force_sync()
		return _usable(owner)
	var waiter := _waiter(owner)
	RenderingServer.frame_post_draw.connect(waiter.finish, CONNECT_ONE_SHOT)
	var usable := await _finish(waiter, owner)
	if RenderingServer.frame_post_draw.is_connected(waiter.finish):
		RenderingServer.frame_post_draw.disconnect(waiter.finish)
	return usable

## Shutdown: release every pending wait now; later waits return false at once.
static func begin() -> void:
	active = true
	var pending := _pending.duplicate()
	_pending.clear()
	for waiter: Waiter in pending: waiter.finish()

## A new world (title to game, reloads) waits normally again.
static func reset() -> void:
	active = false

static func _usable(owner: Node) -> bool:
	return not active and is_instance_valid(owner) and owner.is_inside_tree()

static func _waiter(owner: Node) -> Waiter:
	var waiter := Waiter.new()
	_pending.append(waiter)
	# tree_exiting runs while is_inside_tree() is still true. Record cancellation
	# explicitly, so removing and reattaching a node cannot revive its old work.
	owner.tree_exiting.connect(waiter.cancel, CONNECT_ONE_SHOT)
	return waiter

static func _finish(waiter: Waiter, owner: Node) -> bool:
	if not waiter.finished: await waiter.done
	_pending.erase(waiter)
	if is_instance_valid(owner) and owner.tree_exiting.is_connected(waiter.cancel):
		owner.tree_exiting.disconnect(waiter.cancel)
	return not waiter.cancelled and _usable(owner)
