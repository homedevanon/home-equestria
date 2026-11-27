extends RefCounted
## Exact slices of the physics step and of the frame on the main thread, by phase, by owner and by
## pony tier (performance map 2026-11-21). Nothing here exists or runs unless the performance capture
## (world/performance/perf_capture.gd) or a profile fixture (tools/profile/step_anatomy.gd) makes one;
## everything it adds is removed again by `uninstall()`.
##
## How it measures, without touching any game script (Godot 4.5 order of one step: interpolation
## prepare, Jolt sync and query flush, SceneTree.physics_frame, node callbacks in priority then tree
## order, the process group's call queue (skeleton updates: modifiers, skinning), the global
## deferred-call queue, physics timers, tweens, transform flush, navigation server, Jolt step):
## - Phases: a handler on SceneTree.physics_frame, two edge nodes at the lowest and highest physics
##   priority, marks the edges queue into the process group's call queue and into the global
##   deferred queue, a zero-time physics SceneTreeTimer the last edge makes, and a handler on
##   SceneTree.process_frame (the navigation server, the Jolt step and the transform flushes lie
##   between that timer and the frame's process part, or the next step).
## - Owners: marker nodes placed as siblings right before each owner (root children, Game children,
##   ponies and their parts, navigators, mod nodes) with that owner's priority. Every marker closes
##   the previous segment, so each owner gets the callback time between its marker and the next one.
##   A resume marker right after a nested owner hands the time back to the owner around it.
## - Queued work: every marker also queues a mark into both queues, so the skeleton updates and the
##   deferred calls are split by the owner whose callbacks queued them.
## - Marker cost is calibrated with markers that enclose nothing and subtracted per segment.
## Pony owners are labelled by crowd tier at each tick: "pony|HERO", "part:<script>|NEAR", ...

const TIERS := ["HERO", "NEAR", "FAR"]
const MEMBERS := &"sim_ponies"
const OURS := &"step_slices_node"
const CALIBRATION := 12
## Chains: callbacks, group queue (skeletons), deferred queue; physics then frame.
enum { P_CALL, P_GROUP, P_DEFER, F_CALL, F_GROUP, F_DEFER }

## One timeline: segments between consecutive marks, summed per label.
class Chain extends RefCounted:
	var acc := PackedInt64Array()
	var hits := PackedInt64Array()
	var last := -1
	var last_t := 0
	var on := false
	var started_at := 0
	var stopped_at := 0
	func grow(count: int) -> void:
		acc.resize(count); hits.resize(count)
	func start(label: int) -> void:
		last = label; last_t = Time.get_ticks_usec(); on = true; started_at = last_t
	func hit(label: int) -> void:
		var now := Time.get_ticks_usec()
		if on and last >= 0:
			acc[last] += now - last_t
			hits[last] += 1
		last = label; last_t = now
	func stop(label: int) -> void:
		hit(label); on = false; stopped_at = last_t
	func clear() -> void:
		acc.fill(0); hits.fill(0); last = -1; on = false


class Mark extends Node:
	var owner_slices
	var label := 0
	## Pony whose tier picks label + tier (null: fixed label); `counts` on her opening marker only.
	var pony: Node
	var counts := false
	var physics := true
	func _ready() -> void:
		set_physics_process(physics); set_process(not physics)
	func _physics_process(_delta: float) -> void: _hit(true)
	func _process(_delta: float) -> void: _hit(false)
	func _hit(on_physics: bool) -> void:
		var at := label
		if pony != null:
			var tier := clampi(int(pony.get(&"sim_tier")), 0, 2)
			at += tier
			if counts: owner_slices.pony_ticks[(0 if on_physics else 3) + tier] += 1
		owner_slices.mark(on_physics, at)
		call_deferred_thread_group(&"_queued", on_physics, at)
	func _queued(on_physics: bool, at: int) -> void:
		owner_slices.queued(on_physics, at)


class Edge extends Node:
	var owner_slices
	var first := true
	func _physics_process(_delta: float) -> void:
		owner_slices.edge(true, first)
		call_deferred_thread_group(&"_queued", true)
	func _process(_delta: float) -> void:
		owner_slices.edge(false, first)
		call_deferred_thread_group(&"_queued", false)
	func _queued(on_physics: bool) -> void:
		owner_slices.queued_edge(on_physics, first)


var tree: SceneTree
var labels: PackedStringArray = []
var _index := {}
var chains: Array[Chain] = [Chain.new(), Chain.new(), Chain.new(), Chain.new(), Chain.new(), Chain.new()]
## Pony callback ticks per tier: physics HERO, NEAR, FAR, then frame HERO, NEAR, FAR.
var pony_ticks := PackedInt64Array([0, 0, 0, 0, 0, 0])
var _nodes: Array[Node] = []
var _owners := false
## Phase sums in microseconds, and per-step totals for the distribution.
var phases := {}
var step_totals: PackedInt64Array = []
var frame_walls: PackedFloat64Array = []
var frame_steps: PackedInt32Array = []
var ticks := 0
var frames := 0
var _t_sig := 0
var _t_first := 0
var _t_last := 0
var _t_timer := 0
var _t_proc := 0
var _t_proc_prev := 0
var _t_pfirst := 0
var _t_plast := 0
var _steps_this_frame := 0
var _open_post := false
var _step_sum := 0
var _l_start := 0
var _l_end := 0
var _l_unmarked := 0
var _l_calib := 0
var marker_count := 0
const STEP_PHASES := ["signal_to_first", "callbacks", "group_queue", "ugc_and_deferred", "timers", "post_step"]
const FRAME_PHASES := ["proc_pre", "proc_callbacks", "proc_group_queue", "proc_deferred"]


func _label(name: String) -> int:
	if _index.has(name): return int(_index[name])
	_index[name] = labels.size()
	labels.append(name)
	for chain: Chain in chains: chain.grow(labels.size())
	return labels.size() - 1


## Three consecutive labels name|HERO, name|NEAR, name|FAR; returns the first.
func _tiered(name: String) -> int:
	var base := _label(name + "|" + TIERS[0])
	_label(name + "|" + TIERS[1]); _label(name + "|" + TIERS[2])
	return base


## Phase timing (always) and, with `owners`, the owner markers. `detail` 2 also splits every
## processing node inside a pony and the Game children's children into owners (fixtures only).
func install(scene_tree: SceneTree, game: Node, owners: bool, detail: int = 1) -> void:
	tree = scene_tree
	_l_start = _label("(before first marker)"); _l_end = _label("(end)"); _l_unmarked = _label("(unmarked)")
	_l_calib = _label("(marker calibration)")
	for kind: String in STEP_PHASES + FRAME_PHASES: phases[kind] = 0
	var first := Edge.new(); first.owner_slices = self; first.first = true
	first.process_physics_priority = -2000000000; first.process_priority = -2000000000
	var last := Edge.new(); last.owner_slices = self; last.first = false
	last.process_physics_priority = 2000000000; last.process_priority = 2000000000
	for edge: Edge in [first, last]:
		edge.name = "StepSlicesEdge"; edge.add_to_group(OURS); tree.root.add_child(edge); _nodes.append(edge)
	tree.physics_frame.connect(_on_physics_frame)
	tree.process_frame.connect(_on_process_frame)
	_owners = owners
	if owners:
		_place_owners(game, detail)
		# Calibration: markers that enclose nothing, at the end of the root's priority-0 block.
		for i in CALIBRATION:
			for physics: bool in [true, false]:
				tree.root.add_child(_mark(_l_calib, null, physics, 0))


func uninstall() -> void:
	if tree == null: return
	if tree.physics_frame.is_connected(_on_physics_frame): tree.physics_frame.disconnect(_on_physics_frame)
	if tree.process_frame.is_connected(_on_process_frame): tree.process_frame.disconnect(_on_process_frame)
	for node: Node in _nodes:
		if is_instance_valid(node): node.queue_free()
	_nodes.clear()


func reset() -> void:
	for chain: Chain in chains: chain.clear()
	pony_ticks.fill(0)
	for key: String in phases: phases[key] = 0
	step_totals.clear(); frame_walls.clear(); frame_steps.clear()
	ticks = 0; frames = 0; _t_proc_prev = 0; _open_post = false; _steps_this_frame = 0


func _mark(label: int, pony: Node, physics: bool, priority: int, counts := false) -> Mark:
	var mark := Mark.new()
	mark.name = "StepSlicesMark"
	mark.owner_slices = self; mark.label = label; mark.pony = pony; mark.physics = physics; mark.counts = counts
	if physics: mark.process_physics_priority = priority
	else: mark.process_priority = priority
	mark.add_to_group(OURS)
	_nodes.append(mark)
	marker_count += 1
	return mark


static func key_of(node: Node) -> String:
	var script: Script = node.get_script()
	if script != null and not script.resource_path.is_empty(): return script.resource_path.trim_prefix("res://")
	return node.get_class()


static func _processes(node: Node, physics: bool) -> bool:
	if physics: return node.is_physics_processing() or node.is_physics_processing_internal()
	return node.is_processing() or node.is_processing_internal()


## Every processing node under `node` (itself included), per kind.
static func _busy(node: Node, physics: bool) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_in_group(OURS): continue
		if _processes(n, physics): out.append(n)
		stack.append_array(n.get_children())
	return out


static func is_mod(node: Node) -> bool:
	var script: Script = node.get_script()
	if script == null: return false
	var path := script.resource_path
	return not path.is_empty() and not (path.begins_with("res://world/") or path.begins_with("res://player/") \
		or path.begins_with("res://autoload/") or path.begins_with("res://addons/") or path.begins_with("res://tools/"))


## Owner targets: [node, label base, tier pony or null, parent label base, parent tier pony, counts].
func _place_owners(game: Node, detail: int) -> void:
	var targets: Array = []
	var player: Node = game.get(&"player") if game != null and &"player" in game else null
	for child: Node in tree.root.get_children():
		if child.is_in_group(OURS) or child == game: continue
		var root_label := _label("root/" + str(child.name) + " " + key_of(child))
		targets.append([child, root_label, null, _l_unmarked, null, false])
		# The mod container: one owner per mod (detail 2, or always for the Mods node).
		if detail >= 2 or str(child.name) == "Mods":
			for sub: Node in child.get_children():
				if sub.is_in_group(OURS) or sub.is_in_group(MEMBERS) or (_busy(sub, true).is_empty() and _busy(sub, false).is_empty()): continue
				targets.append([sub, _label("root/" + str(child.name) + " > " + str(sub.name) + " " + key_of(sub)), null, root_label, null, false])
	if game != null:
		var self_label := _label("game self " + key_of(game))
		targets.append([game, self_label, null, _l_unmarked, null, false])
		for child: Node in game.get_children():
			if child.is_in_group(OURS): continue
			if child.is_in_group(MEMBERS):
				targets.append([child, _tiered("pony"), child, self_label, null, true])
				_place_pony_parts(child, detail, targets)
			else:
				var own := _label("game/" + key_of(child))
				targets.append([child, own, null, self_label, null, false])
				if detail >= 2 or child == player:
					for sub: Node in child.get_children():
						if sub.is_in_group(OURS) or (_busy(sub, true).is_empty() and _busy(sub, false).is_empty()): continue
						targets.append([sub, _label("game/" + key_of(child) + " > " + key_of(sub)), null, own, null, false])
	# Ponies living elsewhere (boarded on the balloon, inside a house node).
	for pony: Node in tree.get_nodes_in_group(MEMBERS):
		if game != null and pony.get_parent() == game: continue
		targets.append([pony, _tiered("pony"), pony, _l_unmarked, null, true])
		_place_pony_parts(pony, detail, targets)
	# A processing node whose priority differs from its owner's runs outside the owner's window:
	# it becomes its own owner.
	var targeted := {}
	for target: Array in targets: targeted[target[0]] = target
	for physics: bool in [true, false]:
		for node: Node in _busy(tree.root, physics):
			if targeted.has(node): continue
			var up: Node = node.get_parent()
			while up != null and not targeted.has(up): up = up.get_parent()
			if up == null: continue
			var mine := node.process_physics_priority if physics else node.process_priority
			var theirs := up.process_physics_priority if physics else up.process_priority
			if mine != theirs:
				var row: Array = targeted[up]
				var name := ("part:" if row[2] != null else "prio:") + key_of(node) + " @" + str(mine)
				var target := [node, _tiered(name) if row[2] != null else _label(name), row[2], row[1], row[2], false]
				targets.append(target); targeted[node] = target
	for target: Array in targets:
		var node: Node = target[0]
		var parent := node.get_parent()
		if parent == null: continue
		for physics: bool in [true, false]:
			if target[2] == null and _busy(node, physics).is_empty(): continue
			var priority := node.process_physics_priority if physics else node.process_priority
			var before := _mark(int(target[1]), target[2], physics, priority, bool(target[5]))
			var after := _mark(int(target[3]), target[4], physics, priority)
			parent.add_child(before); parent.move_child(before, node.get_index())
			parent.add_child(after); parent.move_child(after, node.get_index() + 1)


func _place_pony_parts(pony: Node, detail: int, targets: Array) -> void:
	var pony_label := _tiered("pony")
	var seen := {}
	for physics: bool in [true, false]:
		for node: Node in _busy(pony, physics):
			if node == pony or seen.has(node): continue
			var key := key_of(node)
			if not (detail >= 2 or key.ends_with("pony_navigator.gd") or is_mod(node)): continue
			# Only the outermost wanted node of a branch: nested ones stay inside it.
			var up := node.get_parent()
			var nested := false
			while up != null and up != pony:
				if seen.has(up): nested = true; break
				up = up.get_parent()
			if nested: continue
			seen[node] = true
			targets.append([node, _tiered("part:" + key), pony, pony_label, pony, false])


func mark(physics: bool, label: int) -> void:
	chains[P_CALL if physics else F_CALL].hit(label)
	_deferred.call_deferred(physics, label)


func queued(physics: bool, label: int) -> void:
	chains[P_GROUP if physics else F_GROUP].hit(label)


func _deferred(physics: bool, label: int) -> void:
	chains[P_DEFER if physics else F_DEFER].hit(label)


func edge(physics: bool, first: bool) -> void:
	var now := Time.get_ticks_usec()
	var chain := chains[P_CALL if physics else F_CALL]
	if first:
		if physics: _t_first = now
		else: _t_pfirst = now
		chain.start(_l_start)
	else:
		if physics: _t_last = now
		else: _t_plast = now
		chain.stop(_l_end)
		if physics: tree.create_timer(0.0, true, true).timeout.connect(_on_step_timer)
	_deferred_edge.call_deferred(physics, first)


func queued_edge(physics: bool, first: bool) -> void:
	var chain := chains[P_GROUP if physics else F_GROUP]
	if first: chain.start(_l_start)
	else: chain.stop(_l_end)


func _deferred_edge(physics: bool, first: bool) -> void:
	var chain := chains[P_DEFER if physics else F_DEFER]
	if first: chain.start(_l_start)
	else:
		chain.stop(_l_end)
		if not physics:
			var group := chains[F_GROUP]
			if group.stopped_at >= _t_plast and chain.started_at >= group.stopped_at:
				phases.proc_group_queue += group.stopped_at - _t_plast
				phases.proc_deferred += chain.stopped_at - chain.started_at


func _on_physics_frame() -> void:
	var now := Time.get_ticks_usec()
	_close_step(now)
	_t_sig = now


func _close_step(now: int) -> void:
	if not _open_post: return
	phases.post_step += now - _t_timer
	_step_sum += now - _t_timer
	step_totals.append(_step_sum)
	_open_post = false


func _on_step_timer() -> void:
	_t_timer = Time.get_ticks_usec()
	var group := chains[P_GROUP]
	var defer := chains[P_DEFER]
	ticks += 1
	_steps_this_frame += 1
	phases.signal_to_first += _t_first - _t_sig
	phases.callbacks += _t_last - _t_first
	phases.group_queue += group.stopped_at - _t_last
	phases.ugc_and_deferred += defer.stopped_at - group.stopped_at
	phases.timers += _t_timer - defer.stopped_at
	_step_sum = _t_timer - _t_sig
	_open_post = true


func _on_process_frame() -> void:
	_t_proc = Time.get_ticks_usec()
	_close_step(_t_proc)
	# One frame = process_frame to process_frame: the previous frame's process part and drawing,
	# then this iteration's physics steps.
	if _t_proc_prev > 0:
		frames += 1
		frame_walls.append((_t_proc - _t_proc_prev) / 1000.0)
		frame_steps.append(_steps_this_frame)
		if _t_pfirst > _t_proc_prev and _t_plast > _t_pfirst:
			phases.proc_pre += _t_pfirst - _t_proc_prev
			phases.proc_callbacks += _t_plast - _t_pfirst
	_t_proc_prev = _t_proc
	_steps_this_frame = 0


## Marker cost per segment (us), from the calibration markers.
func overhead(chain: Chain) -> float:
	var hits := int(chain.hits[_l_calib])
	return float(chain.acc[_l_calib]) / hits if hits > 0 else 0.0


## Owners of one chain: [label, us per step (or frame), segments per step, us per segment],
## marker cost subtracted, largest first.
func owners(which: int) -> Array:
	var chain := chains[which]
	var per := maxi(1, ticks if which < F_CALL else frames)
	var cost := overhead(chain)
	var rows: Array = []
	for i in labels.size():
		var hits := int(chain.hits[i])
		if hits == 0 or i == _l_calib: continue
		var us := maxf(0.0, float(chain.acc[i]) - cost * hits)
		rows.append([labels[i], us / per, float(hits) / per, us / hits])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	return rows


static func _dist(values: PackedInt64Array) -> Dictionary:
	if values.is_empty(): return {}
	var sorted := Array(values); sorted.sort()
	var sum := 0
	for v: int in sorted: sum += v
	return {"mean_us": snappedf(float(sum) / sorted.size(), 0.1), "p50_us": sorted[sorted.size() / 2],
		"p95_us": sorted[int(sorted.size() * 0.95)], "max_us": sorted[-1], "n": sorted.size()}


## The phase table and (with owners) the owner tables, per step and per frame.
func report() -> Dictionary:
	var per_tick := maxi(1, ticks)
	var per_frame := maxi(1, frames)
	var out := {"ticks": ticks, "frames": frames, "markers": marker_count, "step_us": _dist(step_totals)}
	var step := {}
	for key: String in STEP_PHASES: step[key] = snappedf(float(phases[key]) / per_tick, 0.1)
	out["step_phases_us"] = step
	var proc := {}
	for key: String in FRAME_PHASES: proc[key] = snappedf(float(phases[key]) / per_frame, 0.1)
	out["frame_phases_us"] = proc
	var plain: Array[float] = []
	var stepped: Array[float] = []
	for i in frame_walls.size():
		(stepped if frame_steps[i] > 0 else plain).append(frame_walls[i])
	out["plain_frame_ms"] = _mean(plain)
	out["step_frame_ms"] = _mean(stepped)
	out["frames_with_two_steps"] = Array(frame_steps).count(2)
	out["steps_per_frame"] = snappedf(float(ticks) / per_frame, 0.001)
	if _owners:
		var names := ["step_callbacks", "step_group_queue", "step_deferred", "frame_callbacks", "frame_group_queue", "frame_deferred"]
		var costs := {}
		for i in chains.size():
			costs[names[i]] = snappedf(overhead(chains[i]), 0.01)
			out["owners_" + names[i]] = _rows(owners(i))
		out["marker_us"] = costs
		var counts := {}
		for i in 3:
			counts["step_" + TIERS[i]] = snappedf(float(pony_ticks[i]) / per_tick, 0.01)
			counts["frame_" + TIERS[i]] = snappedf(float(pony_ticks[3 + i]) / per_frame, 0.01)
		out["ponies_per_tick"] = counts
	return out


static func _mean(values: Array[float]) -> float:
	if values.is_empty(): return 0.0
	var sum := 0.0
	for v: float in values: sum += v
	return snappedf(sum / values.size(), 0.001)


static func _rows(rows: Array) -> Array:
	var out: Array = []
	for row: Array in rows:
		if float(row[1]) < 0.05: continue
		out.append([row[0], snappedf(float(row[1]), 0.1), snappedf(float(row[2]), 0.01), snappedf(float(row[3]), 0.01)])
	return out
