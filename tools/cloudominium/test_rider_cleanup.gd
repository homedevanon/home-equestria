extends SceneTree
## Reproduce typed-array validation after rider disposal, including frame boundaries
## and allocation churn. No dialogue, TTS, real character rig or player save.
class Rider extends Node3D:
	var moving_support: Node3D
	func set_moving_support(value: Node3D) -> void: moving_support = value
class Navigator extends Node:
	var pony: Node3D
var checks := 0
var failures := 0
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	printerr("CLOUD_RIDER ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("cloud-rider-test"):
		printerr("CLOUD_RIDER_REFUSED: use isolated validation runner"); quit(1); return
	var arguments := OS.get_cmdline_user_args()
	var path: String = arguments[0] if not arguments.is_empty() else "res://world/buildings/cloudominium/cloud_drift.gd"
	var drift_script: Script = load(path)
	check(drift_script != null and drift_script.can_instantiate(), "loads the production rider logic")
	if drift_script == null or not drift_script.can_instantiate(): quit(1); return
	var world := Node3D.new(); root.add_child(world)
	var frame := Node3D.new(); world.add_child(frame)
	var drift: Node = drift_script.new(); world.add_child(drift); drift.frame = frame
	drift.set_physics_process(false)
	var aboard := Rider.new(); world.add_child(aboard); aboard.moving_support = frame
	var immediate := Rider.new(); world.add_child(immediate); immediate.moving_support = frame
	var queued := Rider.new(); world.add_child(queued); queued.moving_support = frame
	drift._riders.assign([immediate, aboard, queued])
	immediate.free()
	printerr("CLOUD_RIDER before immediate cleanup")
	drift._update_riders()
	check(drift._riders.size() == 2, "immediate disposal removes its rider entry")
	queued.queue_free()
	printerr("CLOUD_RIDER before frame boundary")
	await process_frame; await process_frame
	printerr("CLOUD_RIDER resumed after frame boundary")
	check(not is_instance_valid(queued), "queued rider has been disposed")
	printerr("CLOUD_RIDER before deferred cleanup")
	drift._update_riders()
	check(drift._riders.size() == 1 and drift._riders.has(aboard), "deferred disposal removes its rider entry")
	var departed := Rider.new(); world.add_child(departed)
	departed.moving_support = frame; departed.position = Vector3(100, 0, 0)
	var other_support := Node3D.new(); world.add_child(other_support)
	var transferred := Rider.new(); world.add_child(transferred); transferred.moving_support = other_support
	drift._riders.append(departed); drift._riders.append(transferred)
	drift._update_riders()
	check(departed.moving_support == null, "leaving the home releases its moving support")
	check(transferred.moving_support == other_support, "leaving the list preserves another platform's support")
	check(drift._riders.size() == 1 and aboard.moving_support == frame, "live aboard rider stays attached")
	var boarder := Rider.new(); world.add_child(boarder)
	var nav := Navigator.new(); boarder.add_child(nav); nav.pony = boarder; nav.add_to_group("pony_navigators")
	drift._update_riders(); drift._update_riders()
	check(drift._riders.size() == 2 and drift._riders.has(boarder) and boarder.moving_support == frame, "nearby navigator boards once and remains attached")
	boarder.queue_free(); await process_frame; await process_frame
	drift._update_riders()
	check(drift._riders.size() == 1 and not is_instance_valid(nav), "queued rider and its navigator are both discarded")
	# The live log reported AudioStreamPlaybackWAV where a Node was expected.
	# Allocate genuine playback objects between disposal and
	# cleanup; never play audio or contact a provider.
	var clip := AudioStreamWAV.new(); clip.format = AudioStreamWAV.FORMAT_16_BITS; clip.mix_rate = 24000
	var samples := PackedByteArray(); samples.resize(96); clip.data = samples
	var bounded := true
	for i in 32:
		var temporary := Rider.new(); world.add_child(temporary); temporary.moving_support = frame
		drift._riders.append(temporary); temporary.queue_free()
		await process_frame; await process_frame
		var playback_churn: Array = []
		for j in 32: playback_churn.append(clip.instantiate_playback())
		drift._update_riders()
		bounded = bounded and drift._riders.size() == 1 and drift._riders.has(aboard)
	check(bounded, "repeated queued disposal and playback allocations retain no stale riders")
	world.free()
	printerr("CLOUD_RIDER_DONE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
