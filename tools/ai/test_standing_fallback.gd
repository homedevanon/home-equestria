extends SceneTree
## Replay the start of the cottage follow with the shipped rig and furnished room.
const FEET := Vector3(145.435440, -19.001106, -7.635595)
const YAW := .061817925
const DT := 1.0 / 60.0

var checks := 0
var failures := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("STANDING_FALLBACK ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func settle(pony: CharacterBody3D, kind: String) -> bool:
	for tick in 300:
		var status: Dictionary = pony.posture_status()
		if status.kind == kind and status.settled: return true
		pony.posture.update(DT)
	return false

func run() -> void:
	var room: Node3D = load("res://world/buildings/fluttershy/cottage.tscn").instantiate()
	room.position = Vector3(151, -19.863147, -10)
	room.rotation.y = -1.51204
	root.add_child(room)
	var pony: CharacterBody3D = load("res://world/characters/mane6/fluttershy.tscn").instantiate()
	pony.position = FEET
	pony.rotation.y = YAW
	root.add_child(pony)
	pony.set_physics_process(false)
	await physics_frame
	await physics_frame
	# Step the real body manually for the cottage rise. The obstruction cases below
	# step just the pose so the test obstacle cannot physically shove her aside.
	pony.velocity = Vector3.DOWN * .25
	pony.move_and_slide()
	check(pony.grounded() and pony.global_position.distance_to(FEET) < .01, "recorded cottage footing")
	var capsule: Shape3D = pony._collision.shape
	var placement: Transform3D = pony._collision.transform
	check(pony.request_posture("sit") and settle(pony, "sit"), "native sit settles")
	var pose: RefCounted = pony.posture
	check(not pose.clearance("stand"), "full sit-to-stand envelope is blocked at the recorded pose")
	pony.request_posture("stand")
	pony._physics_process(DT)
	check(pose.phase == "exit" and pose.refusal.is_empty(), "rise starts on first update")
	check(pony._collision.shape == capsule and pony._collision.transform == placement, "first rise frame uses the actual standing body")
	var updates := 1
	var kept_capsule := true
	while pose.active() and updates < 300:
		await physics_frame
		pony._physics_process(DT)
		updates += 1
		kept_capsule = kept_capsule and pony._collision.shape == capsule and pony._collision.transform == placement
	var status: Dictionary = pony.posture_status()
	check(kept_capsule and status.kind == "stand" and status.settled, "capsule stays fitted through animation and recovery")
	check(pony.global_position.distance_to(FEET) < .02, "the motor gets up in place")
	if not pose.active(): print("STANDING_FALLBACK cottage stand seconds=", updates * DT)

	pose.reset()
	pony.request_posture("sit")
	settle(pony, "sit")
	var obstacle := StaticBody3D.new()
	obstacle.position = pony.global_position + Vector3.UP * .55
	var shape := CollisionShape3D.new()
	var block := BoxShape3D.new()
	block.size = Vector3(.15, .2, .15)
	shape.shape = block
	obstacle.add_child(shape)
	root.add_child(obstacle)
	await physics_frame
	await physics_frame
	pony.request_posture("stand")
	for tick in 30: pose.update(DT)
	check(pose.phase == "hold" and not pose.refusal.is_empty() and pony._collision.shape != capsule, "an occupied standing body keeps the pony seated")
	obstacle.free()
	await physics_frame
	check(settle(pony, "stand") and pose.refusal.is_empty(), "blocked rise retries after the obstacle leaves")

	pony.request_posture("sit")
	for tick in 10: pose.update(DT)
	pony.request_posture("stand")
	pose.update(DT)
	check(pose.phase == "reverse" and pony._collision.shape == capsule, "interrupted lowering can reverse on its standing body")
	pony.request_posture("sit")
	check(settle(pony, "sit") and pony._collision.shape != capsule, "a new sit request survives the interrupted rise")

	pose.reset()
	pony.request_posture("lie_down")
	check(settle(pony, "lie_down") and pose.clearance("stand"), "the original lie-to-stand envelope fits here")
	pony.request_posture("stand")
	pose.update(DT)
	check(pose.phase == "exit" and pony._collision.shape != capsule, "ordinary rise uses its full animation collider")
	check(settle(pony, "stand") and pony._collision.shape == capsule, "ordinary rise restores the standing body")
	pony.free()
	room.free()
	print("STANDING_FALLBACK_DONE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
