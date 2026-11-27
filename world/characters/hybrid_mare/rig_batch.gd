extends Node
## Close ponies' body skeleton modifiers in one native batch (perf overhaul 2026-11-21, lane
## rig_batch; captures/perf_2026-11-21/rig_batch.md; native/pony_solver/src/rig_batch.h).
##
## In the crowd the scripted modifiers and links of NEAR ponies cost about 46 us per pony per
## step on the main thread, mostly GDScript overhead around a little math. This node runs after
## every pose writer (physics priority 900000) and hands every eligible NEAR pony to PonyRigBatch:
## on the main thread it checks her and gathers her body rig's plain poses and the scripts' inputs,
## worker threads compute ClipHead, IdleBody, FillyProportions and AffectionPose's fidgets (the
## same formulas), and the results are written inside the engine's own body update by a native
## PonyRigBatchApply modifier, so the engine reverts them after the skin push as it reverts the
## scripts' writes. The neck and hair links run as native handlers of the same skeleton_updated
## signals. Each ported script's first line returns while its `rig_batch_step` equals the physics
## frame; their state stays in the scripts (the idle body's eases are written back every step), so
## a pony moves between the batch and the scripts at any step without a jump.
##
## A pony stays on the scripts when she is not NEAR, the camera is within SERIAL_RADIUS, she is
## held, carried, in an interaction, a conversation, a kiss, a hug or a cuddle, her affection pose
## leans, kisses or rears, her rig is parked or ragdolled, her joint limits were rebound and not yet
## copied to the native solver, or any node on her rigs is not the game's own (a mod's modifier or
## signal handler, a bone-mounted hat or prop): the lists below.
##
## Rollback: ENABLED = false (or `--rig-batch=off`); with it off this node is never created and
## the scripts' guards never return. `--rig-batch=on` turns it on for one run.
const ENABLED := false
const SERIAL_RADIUS := 1.5
## Steps between the slow audit of a pony's listeners (her rigs' children are watched at once).
const AUDIT_STEPS := 15
## Steps between checks for ponies whose rigs or links were rebuilt (re-dress, new hair).
const REBIND_STEPS := 30
const META := &"rig_batch_driver"
const BREATH_ARCH := preload("res://world/characters/locomotion/pony_secondary_motion.gd").BREATH_ARCH

## The game's own modifier scripts per rig. Body: the four ported ones and the terrain modifier, in
## this order (the native side reads them by position).
const BODY_SCRIPTS: Array[Script] = [
	preload("res://world/characters/locomotion/pony_clip_head.gd"),
	preload("res://world/life/idle/pony_idle_body.gd"),
	preload("res://world/characters/hybrid_mare/filly_proportions.gd"),
	preload("res://world/relationships/affection_pose.gd"),
	preload("res://world/characters/locomotion/pony_terrain_modifier.gd"),
]
const HEAD_SCRIPTS: Array[Script] = [
	preload("res://world/characters/openpony/pony_mouth.gd"),
	preload("res://world/characters/openpony/openpony_eye_motion.gd"),
	preload("res://world/characters/openpony/reference_face.gd"),
]
## The boop's nose press, an inner class (added to the head list in _ready).
const BOOP := preload("res://world/characters/hybrid_mare/hybrid_boop.gd")
const HAIR_SCRIPTS: Array[Script] = [preload("res://world/characters/hybrid_mare/hybrid_tail_motion.gd")]
## skeleton_updated / pose_updated handlers on her rigs that are the game's own.
const LISTENERS: Array[String] = [
	"res://world/characters/hybrid_mare/hybrid_neck_link.gd::_on_source_updated",
	"res://world/characters/hybrid_mare/hybrid_hair_link.gd::_body_updated",
	"res://world/characters/hybrid_mare/hybrid_hair_link.gd::_head_updated",
	"res://world/characters/hybrid_mare/hybrid_tail_motion.gd::_on_pose_updated",
	"res://world/characters/openpony/openpony_mare.gd::_update_eye_projection",
	"PhysicalBoneSimulator3D::PhysicalBoneSimulator3D::_pose_updated",
	"PonySolverNative::invalidate_bone_skip",
]

static var _off_by_arg := "--rig-batch=off" in OS.get_cmdline_user_args()
static var _on_by_arg := "--rig-batch=on" in OS.get_cmdline_user_args()
## Fixtures: switch it live (true keeps every pony on the scripts), and set the pool use
## (-1 every pool thread, 0 the calling thread alone, n the caller plus n pool tasks).
static var forced_off := false
static var tasks := -1
## Fixtures: their own recorders on the rigs ("script path::method"), set before the first pony.
static var extra_listeners: Array[String] = []

var batch: RefCounted
## pony instance id -> [pony, row, apply node, body, head rig, hair rig, neck link, hair link]
var _bound := {}
var _pending: Array[Node3D] = []
var _step := 0
## Fixtures: ponies batched in the last step.
var last_batched := 0


static func wanted() -> bool:
	return (ENABLED or _on_by_arg) and not _off_by_arg and ClassDB.class_exists(&"PonyRigBatch")


## A hybrid mare whose neck link is linked (hybrid_neck_link.gd); bound once her hair rig is there.
static func register(pony: Node3D) -> void:
	if not wanted() or pony == null or not pony.is_inside_tree(): return
	var driver := _driver(pony.get_tree())
	if driver != null and not driver._pending.has(pony): driver._pending.append(pony)


static func _driver(tree: SceneTree) -> Node:
	var root := tree.root
	if root.has_meta(META):
		var found: Variant = root.get_meta(META)
		if found is Node and is_instance_valid(found): return found
	var driver: Node = load("res://world/characters/hybrid_mare/rig_batch.gd").new()
	driver.name = "RigBatch"
	root.set_meta(META, driver)
	root.add_child.call_deferred(driver)
	return driver


static func driver_of(root: Node) -> Node:
	if not root.has_meta(META): return null
	var found: Variant = root.get_meta(META)
	return found if found is Node and is_instance_valid(found) else null


func _ready() -> void:
	process_physics_priority = 900000
	batch = ClassDB.instantiate(&"PonyRigBatch")
	var head_scripts: Array = HEAD_SCRIPTS.duplicate()
	head_scripts.append(BOOP.NosePress)
	batch.configure(BODY_SCRIPTS, head_scripts, HAIR_SCRIPTS, PackedStringArray(LISTENERS + extra_listeners), BREATH_ARCH, SERIAL_RADIUS, AUDIT_STEPS)


func _exit_tree() -> void:
	for id: int in _bound.keys(): _unbind(id)


func _physics_process(delta: float) -> void:
	_step += 1
	if not _pending.is_empty(): _bind_pending()
	if _step % REBIND_STEPS == 0: _check_rebuilt()
	if forced_off:
		batch.release_all()
		last_batched = 0
		return
	batch.set_tasks(tasks)
	var eye := Vector3.INF
	var camera := get_viewport().get_camera_3d()
	if camera != null: eye = camera.global_position
	last_batched = batch.step(eye, delta)


func _bind_pending() -> void:
	for i in range(_pending.size() - 1, -1, -1):
		var pony := _pending[i]
		if not is_instance_valid(pony) or not pony.is_inside_tree():
			_pending.remove_at(i)
			continue
		if _bind(pony): _pending.remove_at(i)


func _bind(pony: Node3D) -> bool:
	var body: Skeleton3D = pony.get(&"skeleton")
	var head_node: Variant = pony.get(&"head")
	var head: Skeleton3D = (head_node as Node).get(&"skeleton") if head_node is Node else null
	var hair: Skeleton3D = pony.get(&"hair_skeleton")
	var neck_link: Variant = pony.get(&"neck_link")
	var hair_link: Variant = pony.get(&"hair_link")
	if body == null or head == null or hair == null or not neck_link is Object or not hair_link is Object: return false
	var id := pony.get_instance_id()
	if _bound.has(id):
		var old: Array = _bound[id]
		if old[3] == body and old[4] == head and old[5] == hair and old[6] == neck_link and old[7] == hair_link: return true
		_unbind(id)
	var apply: SkeletonModifier3D = ClassDB.instantiate(&"PonyRigBatchApply")
	apply.name = "RigBatchApply"
	apply.active = true # always: it writes only in a step that batched her
	body.add_child(apply)
	var row: int = batch.bind_pony(pony, body, head, hair, neck_link, hair_link, apply)
	if row < 0:
		apply.queue_free()
		return false
	_bound[id] = [pony, row, apply, body, head, hair, neck_link, hair_link]
	return true


func _unbind(id: int) -> void:
	var entry: Array = _bound[id]
	_bound.erase(id)
	batch.unbind(entry[1])
	if is_instance_valid(entry[2]): (entry[2] as Node).queue_free()


## Re-dressed or rebuilt ponies get a fresh row; freed ones are dropped.
func _check_rebuilt() -> void:
	for id: int in _bound.keys():
		var entry: Array = _bound[id]
		if not is_instance_valid(entry[0]):
			_unbind(id)
			continue
		var reason: String = batch.why(entry[1])
		if reason == "rigs changed" or reason == "links changed" or reason == "freed":
			_unbind(id)
			if (entry[0] as Node).is_inside_tree() and not _pending.has(entry[0]): _pending.append(entry[0])


## Fixtures and notes: the row of a pony, or -1.
func row_of(pony: Node) -> int:
	var entry: Variant = _bound.get(pony.get_instance_id())
	return int(entry[1]) if entry is Array else -1


func why_serial(pony: Node) -> String:
	var row := row_of(pony)
	return "not bound" if row < 0 else String(batch.why(row))


func stats() -> Dictionary:
	return batch.stats()
