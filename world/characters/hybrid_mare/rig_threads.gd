extends Node
## Rig updates of NEAR ponies on worker threads (perf overhaul 2026-11-21, lane skeletons).
##
## Each Skeleton3D runs its modifiers, re-propagates its bones, emits `skeleton_updated` (the neck
## and hair links write the head and hair rigs there) and pushes its skin in one update per step,
## which Godot queues into the main process group and runs one rig after another after the last
## physics callback. With 33 ponies stood close that was 2.0-2.65 ms of the main thread per step.
##
## This node runs last among the physics callbacks (after every script has posed the ponies and
## every rig's own physics callback has advanced it) and runs the updates of every pony that may go
## off the main thread itself, one WorkerThreadPool group task item per pony (body, then head, then
## hair, on one worker, the order the links need), all ponies side by side, and waits for them.
## The update each rig had queued then finds nothing left to do (about 1 us). Same pass, same step,
## same delta: nothing is a step late and nothing is computed twice. Ponies that stay on the main
## thread are left alone: the engine updates them afterwards exactly as before.
##
## Why not Godot's sub-thread process groups: in 4.5 switching a subtree's group at runtime does
## not re-home nodes deeper than the owner's children (`Node::_add_tree_to_process_thread_group`
## is not recursive), so the rigs' updates stayed queued on the main thread, and each switch leaks
## the old group record. Measured: no gain and 531 engine errors (rig_threads_bench.gd, 08:40).
##
## A pony is updated on a worker only when all of these hold, checked every step:
## - she is NEAR (HERO tails cast real floor rays; a FAR tail too), every rig of hers advances this
##   step, she is not held, carried, thrown, kissed, cuddled, in an interaction or in a conversation
##   with the player, and not within SERIAL_RADIUS of the camera (petting, a boop's start, a hoof
##   hold and riding set no flag of their own; all of them start within arm's reach);
## - every active modifier and every `skeleton_updated` / `pose_updated` listener on her rigs is in
##   the audited lists below (mods' modifiers, other bone attachments, anything new keep her on the
##   main thread): worker threads must not move a Node3D (4.5's transform-changed and interpolation
##   lists take no lock) nor read another pony;
## - the CPU labels are off (their tables are not thread safe), the pool has more than MIN_WORKERS
##   threads, and `--rig-threads=off` is not given.
## The head's voice mount (a BoneAttachment3D holding only the voice) is unbound while she is
## updated here and set by this node from the main thread right after the pass, from the same
## step's head pose: her voice stays on her head with no lag.
##
## Rollback: ENABLED = false (or `--rig-threads=off`) leaves every pony to the engine, as before.
## Default off until the parity fixture shows serial and threaded poses bit-identical
## (captures/perf_2026-11-21/skeletons.md); `--rig-threads=on` turns it on for one run.
const ENABLED := false
const SERIAL_RADIUS := 1.5
## Pools this small gain nothing worth the hand-off (weak dual cores, some handhelds).
const MIN_WORKERS := 2
## Steps between the slow audit of a pony's listeners; her rigs' children are watched at once.
const AUDIT_STEPS := 15
## Fewer eligible ponies than this stay with the engine (waking the pool costs more than it saves;
## measured break-even in captures/perf_2026-11-21/skeletons.md).
const MIN_BATCH := 3
## The voice mount is set every step while the voice plays, otherwise every MOUNT_STEPS steps.
const MOUNT_STEPS := 6
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")
const META := &"rig_threads_driver"

## Modifier scripts whose pass reads and writes only her own rigs, her own pony's plain values and
## per-pony objects (audit 2026-11-21, captures/perf_2026-11-21/skeletons.md).
const AUDITED_MODIFIERS: Array[String] = [
	"res://world/characters/locomotion/pony_terrain_modifier.gd",
	"res://world/characters/locomotion/pony_clip_head.gd",
	"res://world/life/idle/pony_idle_body.gd",
	"res://world/characters/hybrid_mare/filly_proportions.gd",
	"res://world/characters/hybrid_mare/hybrid_tail_motion.gd",
	"res://world/characters/openpony/openpony_eye_motion.gd",
	"res://world/characters/openpony/pony_mouth.gd",
	# Active on almost every NEAR pony (idle fidgets, buck, stretch, yawn). Kissing, rearing at him,
	# hugs and carried kisses also set `affection_active` or a hold, which keeps her serial.
	AFFECTION_POSE,
]
const AFFECTION_POSE := "res://world/relationships/affection_pose.gd"
## `skeleton_updated` / `pose_updated` handlers that are thread safe in the same sense, as
## "script path or engine class::method". The head's eye projection and the eye surface writes go
## to her own materials and meshes (built per pony in openpony_mare.gd and face_sculpt.gd).
const AUDITED_LISTENERS: Array[String] = [
	"res://world/characters/hybrid_mare/hybrid_neck_link.gd::_on_source_updated",
	"res://world/characters/hybrid_mare/hybrid_hair_link.gd::_body_updated",
	"res://world/characters/hybrid_mare/hybrid_hair_link.gd::_head_updated",
	"res://world/characters/hybrid_mare/hybrid_tail_motion.gd::_on_pose_updated",
	"res://world/characters/openpony/openpony_mare.gd::_update_eye_projection",
	"PhysicalBoneSimulator3D::PhysicalBoneSimulator3D::_pose_updated",
	"PonySolverNative::invalidate_bone_skip",
]
## The head's voice mount (openpony_mare.gd).
const VOICE_MOUNT := &"HeadAttachment"

static var _off_by_arg := "--rig-threads=off" in OS.get_cmdline_user_args()
static var _on_by_arg := "--rig-threads=on" in OS.get_cmdline_user_args()
## Fixtures switch it live, and may add their own audited listener.
static var forced_off := false
static var extra_listeners: Array[String] = []
## Fixtures: at most this many ponies on workers (-1 no limit) to find the break-even.
static var batch_limit := -1
static var min_batch_override := -1
## Fixtures: 0 the pool, 1 the same pass on the main thread, 2 the pool with one worker.
static var pass_mode := 0
## Fixtures: skip the reach test (it reads her global transform).
static var skip_reach := false
## Fixtures (parity bisection): no kiss-settings preload; a driver that does nothing per step.
static var debug_no_prewarm := false
static var debug_inert := false


class Entry:
	var pony: Node3D
	var id := 0
	var pivot: Node3D
	var rigs: Array[Skeleton3D] = []
	var dirty := true
	var safe := false
	## Updated on a worker this step.
	var threaded := false
	## The head's voice mount, unbound while she is threaded, its rig, bone and voice.
	var mount: BoneAttachment3D
	var mount_rig: Skeleton3D
	var mount_bone := -1
	var voice: Node
	var unbound := false


var _entries: Array[Entry] = []
var _by_id := {}
var _batch: Array[Entry] = []
var _step := 0
var _workers := 0
## Pony-steps updated on workers and on the main thread since the start (fixtures read them).
var threaded_steps := 0
var serial_steps := 0
var last_batch := 0
## Fixtures: main-thread microseconds spent waiting for the worker passes (summed).
var wait_usec := 0
## True while the worker pass runs (fixtures read it from their listeners).
var in_pass := false


## A hybrid mare (the neck link registers her once her body and head rigs are linked).
static func register(pony: Node3D) -> void:
	if not (ENABLED or _on_by_arg) or pony == null or not pony.is_inside_tree(): return
	var driver := _driver(pony.get_tree())
	if driver != null: driver._add(pony)


static func _driver(tree: SceneTree) -> Node:
	var root := tree.root
	if root.has_meta(META):
		var found: Variant = root.get_meta(META)
		if found is Node and is_instance_valid(found): return found
	var driver: Node = load("res://world/characters/hybrid_mare/rig_threads.gd").new()
	driver.name = "RigThreads"
	root.set_meta(META, driver)
	root.add_child.call_deferred(driver)
	return driver


static func set_enabled(_root: Node, on: bool) -> void:
	forced_off = not on


static func threaded_count(root: Node) -> int:
	if not root.has_meta(META): return 0
	var driver: Variant = root.get_meta(META)
	return int(driver.last_batch) if driver is Node and is_instance_valid(driver) else 0


## `--rig-threads=on` runs (benches): one log line per 600 steps with the ponies on workers.
var _report_steps := 0
var _report_ponies := 0
var _report_max := 0
var _report_wait := 0


func _report() -> void:
	_report_steps += 1
	_report_ponies += _batch.size()
	_report_max = maxi(_report_max, _batch.size())
	if _report_steps < 600: return
	print("[rig-threads] %d steps: %.1f ponies on workers per step (max %d), main thread waited %.0f us per step, %d registered" % [
		_report_steps, float(_report_ponies) / _report_steps, _report_max, float(wait_usec - _report_wait) / _report_steps, _entries.size()])
	_report_steps = 0; _report_ponies = 0; _report_max = 0; _report_wait = wait_usec


func _ready() -> void:
	process_physics_priority = 900000
	var setting := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	_workers = setting if setting > 0 else OS.get_processor_count()
	# AffectionPose loads its shared kiss settings lazily on first use (a rear); load them here, on
	# the main thread, so no worker ever writes that static Dictionary.
	var affection: Script = load(AFFECTION_POSE) if not debug_no_prewarm else null
	if affection != null: affection.call(&"kiss_settings")


func _add(pony: Node3D) -> void:
	if _by_id.has(pony.get_instance_id()): return
	var entry := Entry.new()
	entry.pony = pony
	entry.id = pony.get_instance_id()
	_entries.append(entry)
	_by_id[entry.id] = entry


func _physics_process(_delta: float) -> void:
	if debug_inert: return
	_step += 1
	_batch.clear()
	var allowed := (ENABLED or _on_by_arg) and not _off_by_arg and not forced_off and _workers > MIN_WORKERS and not PROFILE.enabled
	var eye := Vector3.INF
	if allowed:
		var camera := get_viewport().get_camera_3d()
		if camera != null: eye = camera.global_position
	for i in range(_entries.size() - 1, -1, -1):
		var entry := _entries[i]
		if not is_instance_valid(entry.pony):
			_by_id.erase(entry.id)
			_entries.remove_at(i)
			continue
		var want := allowed and entry.pony.is_inside_tree() and _contact_free(entry.pony, eye)
		if want:
			if entry.dirty or (_step + i) % AUDIT_STEPS == 0: _audit(entry)
			want = entry.safe and _ticking(entry)
		entry.threaded = want
		if want: _batch.append(entry)
		else:
			if entry.unbound: _rebind(entry)
			serial_steps += 1
	# Too few to pay for waking the pool: all of them stay with the engine this step.
	if _batch.size() < (min_batch_override if min_batch_override >= 0 else MIN_BATCH) or batch_limit == 0:
		for entry: Entry in _batch:
			entry.threaded = false
			if entry.unbound: _rebind(entry)
		serial_steps += _batch.size()
		_batch.clear()
	elif batch_limit > 0 and _batch.size() > batch_limit:
		for k in range(batch_limit, _batch.size()):
			_batch[k].threaded = false
			if _batch[k].unbound: _rebind(_batch[k])
		serial_steps += _batch.size() - batch_limit
		_batch.resize(batch_limit)
	for entry: Entry in _batch:
		if entry.mount != null and not entry.unbound and is_instance_valid(entry.mount):
			entry.mount.use_external_skeleton = true   # no skeleton_updated handler on a worker
			entry.unbound = true
	last_batch = _batch.size()
	if _on_by_arg: _report()
	if _batch.is_empty(): return
	threaded_steps += _batch.size()
	var started := Time.get_ticks_usec()
	in_pass = true
	if pass_mode == 1:
		for k in _batch.size(): _update_pony(k)
	else:
		var task := WorkerThreadPool.add_group_task(_update_pony, _batch.size(), 1 if pass_mode == 2 else -1, true, "rig_threads")
		WorkerThreadPool.wait_for_group_task_completion(task)
	wait_usec += Time.get_ticks_usec() - started
	in_pass = false
	for entry: Entry in _batch:
		if entry.mount == null or entry.mount_bone < 0 or not is_instance_valid(entry.mount_rig): continue
		var playing: bool = is_instance_valid(entry.voice) and (entry.voice.get(&"playing") == true or entry.voice.is_physics_processing_internal())
		if playing or (_step + entry.id) % MOUNT_STEPS == 0:
			entry.mount.transform = entry.mount_rig.get_bone_global_pose(entry.mount_bone)


## Worker: one pony's rigs in link order. Only her own nodes and per-pony objects are touched.
## Node's thread checks would refuse every signal the update emits (skeleton_updated, pose_updated,
## modification_processed) on a pool thread outside a process group, so they are off for this
## item only (thread-local, restored before the thread returns to the pool). What runs here is the
## audited list above; the fixture rig_threads_bench.gd lists every guarded call it makes.
func _update_pony(index: int) -> void:
	Thread.set_thread_safety_checks_enabled(false)
	for rig: Skeleton3D in _batch[index].rigs:
		rig.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	Thread.set_thread_safety_checks_enabled(true)


func _rebind(entry: Entry) -> void:
	entry.unbound = false
	if is_instance_valid(entry.mount): entry.mount.use_external_skeleton = false


## NEAR, not within reach of the player, not held, carried, in an interaction or talking to him.
func _contact_free(pony: Node3D, eye: Vector3) -> bool:
	if int(pony.get(&"sim_tier")) != 1: return false
	if eye.is_finite() and not skip_reach and pony.global_position.distance_squared_to(eye) < SERIAL_RADIUS * SERIAL_RADIUS: return false
	if pony.get(&"_held") == true or pony.get(&"_interaction") != "": return false
	if pony.has_meta(&"affection_active") or pony.has_meta(&"cuddle_active"): return false
	var carry: Variant = pony.get(&"carry")
	if carry is Object and float((carry as Object).get(&"blend")) > 0.0: return false
	var talk: Variant = pony.get(&"conversation_target")
	if talk is Object and is_instance_valid(talk): return false
	return true


## Every rig of hers advances this step (per-step mode, so its update is already queued): a
## parked rig (frozen, hidden in the crowd, between tiers) is left to the engine, which runs it
## only when something writes a pose, as before. A pose written after the driver (set_sim_tier's
## deferred _update_rig_rates forcing one last pass) queues a fresh update that the engine runs on
## the main thread at its next flush, as before.
func _ticking(entry: Entry) -> bool:
	for rig: Skeleton3D in entry.rigs:
		if not is_instance_valid(rig) or rig.modifier_callback_mode_process != Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS \
				or not rig.is_physics_processing_internal():
			return false
	return not entry.rigs.is_empty()


## Every modifier and listener on her rigs is audited (sets entry.safe).
func _audit(entry: Entry) -> void:
	entry.dirty = false
	entry.safe = false
	var pivot: Node3D = entry.pony.get(&"pivot")
	if pivot == null or not pivot.is_inside_tree(): return
	entry.pivot = pivot
	var rigs: Array[Skeleton3D] = []
	for node: Node in pivot.find_children("*", "Skeleton3D", true, false):
		rigs.append(node as Skeleton3D)
	if rigs != entry.rigs:
		for rig: Skeleton3D in rigs:
			var watch := _mark_dirty.bind(entry)
			if not rig.child_entered_tree.is_connected(watch): rig.child_entered_tree.connect(watch)
		entry.rigs = rigs
	var mount: BoneAttachment3D = null
	for rig: Skeleton3D in rigs:
		for child: Node in rig.get_children():
			if child is SkeletonModifier3D:
				if (child as SkeletonModifier3D).active and not AUDITED_MODIFIERS.has(_script_path(child)): return
			elif child is BoneAttachment3D:
				# Only the head's voice mount holding nothing but the voice is handled here.
				if child.name != VOICE_MOUNT or mount != null or child.get_child_count() != 1 \
						or not child.get_child(0) is AudioStreamPlayer3D: return
				if (child as BoneAttachment3D).use_external_skeleton and not (entry.unbound and entry.mount == child): return
				mount = child as BoneAttachment3D
		for sig: StringName in [&"skeleton_updated", &"pose_updated"]:
			for c: Dictionary in rig.get_signal_connection_list(sig):
				var callable: Callable = c.callable
				var target: Object = callable.get_object()
				if target == mount: continue
				var path := _script_path(target)
				var key := "%s::%s" % [path if path != "" else (target.get_class() if target != null else ""), callable.get_method()]
				if not AUDITED_LISTENERS.has(key) and not extra_listeners.has(key): return
	if mount != entry.mount:
		if entry.unbound: _rebind(entry)
		entry.mount = mount
		entry.mount_rig = mount.get_parent() as Skeleton3D if mount != null else null
		entry.mount_bone = mount.bone_idx if mount != null else -1
		entry.voice = mount.get_child(0) if mount != null else null
	entry.safe = true


func _mark_dirty(_child: Node, entry: Entry) -> void:
	entry.dirty = true
	entry.safe = false   # a new child is not run on a worker before the next audit (this step)


static func _script_path(object: Object) -> String:
	var script: Variant = object.get_script() if object != null else null
	return (script as Script).resource_path if script is Script else ""


## Fixtures and the notes: why this pony stays on the main thread ("" when she would go to a worker).
func why_serial(pony: Node3D) -> String:
	var entry: Entry = _by_id.get(pony.get_instance_id())
	if entry == null: return "not registered"
	if int(pony.get(&"sim_tier")) != 1: return "tier %d" % int(pony.get(&"sim_tier"))
	var camera := get_viewport().get_camera_3d()
	if camera != null and pony.global_position.distance_to(camera.global_position) < SERIAL_RADIUS: return "within reach"
	if not _contact_free(pony, Vector3.INF): return "contact or conversation"
	for rig: Skeleton3D in entry.rigs:
		if not is_instance_valid(rig): continue
		for child: Node in rig.get_children():
			if child is SkeletonModifier3D and (child as SkeletonModifier3D).active and not AUDITED_MODIFIERS.has(_script_path(child)):
				return "modifier %s %s" % [child.name, _script_path(child)]
			if child is BoneAttachment3D and child != entry.mount:
				return "attachment %s on %s" % [child.name, rig.get_parent().name]
		for sig: StringName in [&"skeleton_updated", &"pose_updated"]:
			for c: Dictionary in rig.get_signal_connection_list(sig):
				var callable: Callable = c.callable
				var target: Object = callable.get_object()
				if target == entry.mount: continue
				var path := _script_path(target)
				var key := "%s::%s" % [path if path != "" else (target.get_class() if target != null else ""), callable.get_method()]
				if not AUDITED_LISTENERS.has(key) and not extra_listeners.has(key): return "listener " + key
	if not _ticking(entry): return "rig parked"
	return "" if entry.safe else "not audited yet"
