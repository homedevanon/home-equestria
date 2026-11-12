extends Node
## Wall intervals between process entries, with sampled engine monitors for context.
## These monitors may describe an earlier interval; they do not attribute the stall.
## dev (2026-09-14): a
## flank smack still stalls the game for about a second with the error flood
## gone. Monotonic elapsed time catches stalls even when engine delta is clamped or
## scaled. Process/physics samples, pipeline changes and XR state remain observations,
## not proof of what caused the elapsed interval.
##
## Anything can stamp an event with `HitchMonitor.mark("flank impact")`; the
## next hitch line reports the last stamp and its age.

## 30 ms = about three dropped headset frames (dev 2026-09-25: spikes while walking, none
## of them reached the old 100 ms line).
const THRESHOLD_MS := 30.0
const META := &"hitch_monitor_event"
## Frames under this are summarised, not printed one by one.
const SPIKE_MS := 70.0
const SUMMARY_SECONDS := 5.0
var _slow := 0
var _slow_worst := 0.0
var _slow_physics := 0.0
var _summary_usec := 0
var _previous_process_usec := -1

var _last_compiles: Dictionary = {}
var _last_confidence := -99
var _confidence_changed_usec := 0
var _session_state := "unknown"
var _session_changed_usec := 0


## The last few stamps, newest last ([what, usec] each): one stall can hold several (a far mesh
## gather, then an impostor shot), and only the newest was named before (W1-PERF-HITCH 2026-11-08).
const RECENT := &"hitch_monitor_recent"
const RECENT_KEEP := 4

static func mark(what: String) -> void:
	var tree := Engine.get_main_loop()
	if tree != null:
		var stamp := [what, Time.get_ticks_usec()]
		tree.set_meta(META, stamp)
		var recent: Array = tree.get_meta(RECENT) if tree.has_meta(RECENT) else []
		if not recent.is_empty() and str(recent[-1][0]) == what: recent[-1] = stamp
		else:
			recent.append(stamp)
			if recent.size() > RECENT_KEEP: recent.pop_front()
		tree.set_meta(RECENT, recent)


func _ready() -> void:
	process_priority = 1000  # after everything else this frame
	_last_compiles = _compiles()
	var xr := XRServer.primary_interface
	if xr != null:
		for sig in ["session_focussed", "session_visible", "session_loss_pending", "session_stopping", "pose_recentered"]:
			if xr.has_signal(sig):
				xr.connect(sig, _on_session.bind(sig))
	print("[hitch] monitor armed, threshold %d ms" % int(THRESHOLD_MS))


func _on_session(sig: String) -> void:
	_session_state = sig
	_session_changed_usec = Time.get_ticks_usec()
	print("[hitch] openxr %s at frame %d" % [sig, Engine.get_process_frames()])


func _clock_usec() -> int:
	return Time.get_ticks_usec()

func _sample_ms(monitor: int) -> float:
	return Performance.get_monitor(monitor) * 1000.0

func _log_line(line: String) -> void:
	print(line)

func _process(_delta: float) -> void:
	var now := _clock_usec()
	var previous := _previous_process_usec
	_previous_process_usec = now
	var confidence := _head_confidence()
	if confidence != _last_confidence:
		if _last_confidence != -99:
			print("[hitch] head tracking confidence %s -> %s at frame %d" % [_name(_last_confidence), _name(confidence), Engine.get_process_frames()])
		_last_confidence = confidence
		_confidence_changed_usec = now
	if previous < 0:
		_flush_summary(now)
		return
	var wall_ms := maxf(0.0, float(now - previous) / 1000.0)
	if wall_ms < THRESHOLD_MS:
		_flush_summary(now)
		return
	# Smaller slow intervals are counted in a summary rather than printed individually (dev
	# 2026-09-25: "hitches spammed"). Real stalls still get their own line.
	if wall_ms < SPIKE_MS:
		_slow += 1
		_slow_worst = maxf(_slow_worst, wall_ms)
		_slow_physics = maxf(_slow_physics, _sample_ms(Performance.TIME_PHYSICS_PROCESS))
		_flush_summary(now)
		return
	var compiles := _compiles()
	var grew: Array[String] = []
	for key in compiles:
		var d: int = int(compiles[key]) - int(_last_compiles.get(key, 0))
		if d > 0: grew.append("%s+%d" % [key, d])
	_last_compiles = compiles
	var event := "none"
	var tree := get_tree()
	if tree.has_meta(META):
		var stamp: Array = tree.get_meta(META)
		event = "%s %.0f ms ago" % [stamp[0], (now - int(stamp[1])) / 1000.0]
	# Other stamps made inside this interval (older than the last one).
	if tree.has_meta(RECENT):
		var also: Array[String] = []
		for stamp: Array in tree.get_meta(RECENT):
			var age := (now - int(stamp[1])) / 1000.0
			if age <= wall_ms and not event.begins_with(str(stamp[0]) + " "): also.append("%s %.0f ms ago" % [stamp[0], age])
		if not also.is_empty(): event += " (also in this interval: " + ", ".join(also) + ")"
	_log_line("[hitch] %.0f ms wall interval | sampled process %.1f ms sampled physics %.1f ms | compiles %s | head %s (changed %.0f ms ago) | session %s (%.0f ms ago) | last event: %s" % [
		wall_ms,
		_sample_ms(Performance.TIME_PROCESS),
		_sample_ms(Performance.TIME_PHYSICS_PROCESS),
		"none" if grew.is_empty() else ",".join(grew),
		_name(confidence), (now - _confidence_changed_usec) / 1000.0,
		_session_state, (now - _session_changed_usec) / 1000.0,
		event])
	_flush_summary(now)


func _flush_summary(now: int) -> void:
	if _summary_usec == 0: _summary_usec = now
	if now - _summary_usec < SUMMARY_SECONDS * 1e6: return
	if _slow > 0:
		_log_line("[hitch] %d wall intervals from %d to below %d ms in the last %d s (worst %.0f ms, sampled physics up to %.1f ms)" % [
			_slow, int(THRESHOLD_MS), int(SPIKE_MS), int(SUMMARY_SECONDS), _slow_worst, _slow_physics])
	_slow = 0; _slow_worst = 0.0; _slow_physics = 0.0; _summary_usec = now


func _head_confidence() -> int:
	var head := XRServer.get_tracker("head")
	if head == null or not head.has_pose("default"):
		return -1
	var pose: XRPose = head.get_pose("default")
	return int(pose.tracking_confidence) if pose != null else -1


func _name(confidence: int) -> String:
	match confidence:
		0: return "NONE"
		1: return "LOW"
		2: return "HIGH"
	return "n/a"


func _compiles() -> Dictionary:
	return {
		"mesh": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH),
		"surface": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE),
		"draw": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW),
		"spec": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION),
	}
