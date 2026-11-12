extends Node3D
## The railway network dev sketched on 2026-09-26 (tools/rail_sketch/, docs/RAILWAYS_2026_09_26.md).
## One train per line: a little locomotive in the line's colour and two carriages, running a
## fixed timetable worked out from TimeOfDay.active_seconds (so it needs no save data and is
## where it should be after a load). Trains stop at every station with their carriages along the
## platform and open the doors on the platform side: walk on, ride, walk off. Rack (cog) sections
## are climbed slowly; tunnels and bridges are part of the track (world/railway/track.scn).
## The living world does not use these trains yet.

const BUILT := "res://world/railway/network_built.json"
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const TRACK := "res://world/railway/track.scn"
const CRUISE := 11.0          # m/s on ordinary track
const RACK_SPEED := 6.0       # m/s on the cog sections (about 22 km/h, like a Swiss rack line)
const ACCEL := 0.5            # m/s²
const STOP_DWELL := 30.0
const END_DWELL := 50.0
const ENGINE_HALF := 3.2
const CAR_LENGTH := 12.2
const GAP := 1.0
const CAR_FLOOR := 1.1        # carriage origin above the rail top (carriage.scn)
const ACTIVE_RANGE := 2500.0  # trains farther than this from the player are hidden
## dev 2026-10-20 perf pass (rail_network was ~175 us per physics tick). Rollback: set false.
## PLACE_ONLY_MOVED: a train standing at a platform (30-50 s per stop) no longer rewrites the same
## engine/carriage transforms, door states and collision every tick; it is placed again as soon
## as its head distance, direction or stop changes, or after it was out of range.
## SCHEDULE_HINT: the timetable lookups start from the last matched schedule entry instead of
## scanning from the first; the answer is the same first-match entry.
const PLACE_ONLY_MOVED := true
const SCHEDULE_HINT := true

class Train:
	var line: Dictionary
	var points := PackedVector3Array()
	var dist := PackedFloat64Array()
	var stops: Array = []          # [{id, at}]
	var loop := false
	var schedule: Array = []       # [{t0, t1, kind, stop, d0, d1, times, dists}]
	var period := 0.0
	var offset := 0.0
	var engine: AnimatableBody3D
	var cars: Array[AnimatableBody3D] = []
	var wheels: AudioStreamPlayer3D
	var state := {}
	var collision_active := true
	var collision_sources: Array[Dictionary] = []
	var leg_segments: Array = []   # per leg: the segment ids it runs over, in order
	var delay := 0.0               # seconds held at platforms for shared track (_reserve)
	var waited := 0.0              # this hold so far, for fair turns at a block
	var granted := {}              # blocks reserved for the departure from schedule entry granted_at
	var granted_at := -1
	var last_audio_stop := -2
	var doors_audible := false
	var entry_hint := 0            # last schedule index matched (_entry_index)
	var placed := false            # vehicles placed, visible and colliding at placed_d/dir/stop
	var placed_d := 0.0
	var placed_dir := 0
	var placed_stop := -2

## Trains off for now (dev 2026-10-22). true brings every line's train and timetable back.
const TRAINS_RUNNING := false
var host: Node
var trains: Array[Train] = []
var platforms := {}               # station id -> platform Node3D
var _clock: Node

func setup(game: Node) -> void:
	host = game
	_clock = get_node_or_null("/root/TimeOfDay")
	process_physics_priority = -100
	if not FileAccess.file_exists(BUILT) or not ResourceLoader.exists(TRACK):
		push_warning("[rail] no railway network built (tools/rail_sketch)")
		return
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BUILT))
	var track: Node3D = load(TRACK).instantiate()
	add_child(track)
	for platform in track.find_children("*Platform", "Node3D", true, false):
		if platform.has_meta("station"): platforms[str(platform.get_meta("station"))] = platform
	_limit_station_ranges(track)
	if LIMIT_TUNNEL_RANGES: _limit_tunnel_ranges(track, doc)
	if not TRAINS_RUNNING:
		# Track and stations stay; no trains, timetables or per-tick work (dev 2026-10-22: "we
		# dont need those right now disable trains").
		set_physics_process(false); set_process(false)
		print("[rail] trains switched off; %d stations on the track" % platforms.size())
		return
	var segments := {}
	for seg: Dictionary in doc.segments: segments[seg.id] = seg
	for line: Dictionary in doc.lines:
		if line.legs.is_empty(): continue
		var train := _make_train(line, segments)
		trains.append(train)
	_mark_shared_track()
	print("[rail] %d lines, %d stations on the network" % [trains.size(), platforms.size()])

## Station dressing in track.scn had no draw distance, so all 30 stations drew from anywhere
## within the camera far, kilometres away (docs/DRAW_CALLS_2026_09_26.md item 9). Each part now
## stops well past where it is a pixel: the platform slab where the track bed next to it stops,
## the fence/benches/lamp posts and buffer stops where they are ~1 px tall, the lamp cubes and
## the name boards and signs a little sooner. Nothing that already has a range is touched.
const STATION_RANGES := {"Slab": 2500.0, "Fence": 1200.0, "Lamps": 800.0, "BufferStop": 1200.0}
const SIGN_RANGE := 1500.0

func _limit_station_ranges(track: Node) -> void:
	var stations := track.get_node_or_null("Stations")
	for node: Node in track.find_children("*", "GeometryInstance3D", true, false):
		var gi := node as GeometryInstance3D
		if gi.visibility_range_end > 0.0: continue
		var end: float = STATION_RANGES.get(str(gi.name), 0.0)
		if end == 0.0 and gi is Label3D and stations != null and stations.is_ancestor_of(gi): end = SIGN_RANGE
		if end == 0.0: continue
		gi.visibility_range_end = end
		gi.visibility_range_end_margin = 60.0

## dev 2026-11-08 (board #340): a chunk that lies wholly inside a tunnel (the mountain spirals) drew
## its ballast to 2,500 m, rails to 900 m and lining to 600 m, and showed through the coarse far
## terrain over the hill. Such a chunk can only be seen down the bore, so tools/props_art/
## bake_tunnel_ranges.py works out how far down the bore (or out of the portal) each one is still
## in sight and writes that, plus the mesh margin, to TUNNEL_RANGES; those chunks stop there (never
## further than before). Long straight bores keep their view; spirals drop to 190-400 m.
## Chunks with open track (portals) keep their ranges. Load time only; fewer draws at distance.
## Rollback: set LIMIT_TUNNEL_RANGES false. The bake is skipped (old ranges) if network_built.json
## changed since it ran: rerun the tool after rebuilding the track.
const LIMIT_TUNNEL_RANGES := true
const TUNNEL_RANGES := "res://world/railway/tunnel_ranges.json"

func _limit_tunnel_ranges(track: Node, doc: Dictionary) -> void:
	if not FileAccess.file_exists(TUNNEL_RANGES): return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TUNNEL_RANGES))
	if not parsed is Dictionary: return
	var baked: Dictionary = parsed
	var source: Dictionary = baked.get("source", {})
	if str(source.get("revision", "")) != str(doc.get("revision", "")) or str(source.get("built", "")) != str(doc.get("built", "")):
		push_warning("[rail] tunnel_ranges.json is older than the track: run tools/props_art/bake_tunnel_ranges.py")
		return
	var limited := 0
	var chunks: Dictionary = baked.get("chunks", {})
	for seg_id: String in chunks:
		var holder := track.get_node_or_null(NodePath(seg_id))
		if holder == null: continue
		var rows: Dictionary = chunks[seg_id]
		for chunk_name: String in rows:
			var chunk := holder.get_node_or_null(NodePath(chunk_name))
			if chunk == null: continue
			var end := float(rows[chunk_name])
			for node: Node in chunk.get_children():
				var gi := node as GeometryInstance3D
				if gi == null: continue
				gi.visibility_range_end = end if gi.visibility_range_end <= 0.0 else minf(gi.visibility_range_end, end)
			limited += 1
	print("[rail] %d buried tunnel chunks drawn only down their bores" % limited)

# ---------------------------------------------------------------- route and timetable

func _make_train(line: Dictionary, segments: Dictionary) -> Train:
	var t := Train.new()
	t.line = line
	t.loop = bool(line.get("loop", false))
	var rack_spans: Array = []
	for leg: Dictionary in line.legs:
		if t.stops.is_empty(): t.stops.append({"id": leg.from, "at": 0.0})
		var ids: Array = []
		for step in leg.path: ids.append(str(step[0]))
		t.leg_segments.append(ids)
		for step in leg.path:
			var seg: Dictionary = segments[step[0]]
			var pts: Array = seg.points
			var d: Array = seg.distances
			var forward := int(step[1]) > 0
			var base := t.dist[-1] if not t.dist.is_empty() else 0.0
			var count := pts.size()
			for k in count:
				var i := k if forward else count - 1 - k
				if not t.points.is_empty() and k == 0: continue
				var p: Array = pts[i]
				t.points.append(Vector3(p[0], p[1], p[2]))
				var along := float(d[i]) if forward else float(seg.length) - float(d[i])
				t.dist.append(base + along)
			for span in seg.rack:
				var a := float(span[0])
				var b := float(span[1])
				if not forward:
					var c := a
					a = float(seg.length) - b
					b = float(seg.length) - c
				rack_spans.append([base + a, base + b])
		t.stops.append({"id": leg.to, "at": t.dist[-1]})
	# speed limit every sample, then accelerate out of and brake into every stop
	var limit := PackedFloat64Array()
	limit.resize(t.dist.size())
	for i in t.dist.size():
		limit[i] = CRUISE
		for span in rack_spans:
			if t.dist[i] >= float(span[0]) - 20 and t.dist[i] <= float(span[1]) + 20: limit[i] = RACK_SPEED; break
	for s in t.stops.size() - 1:
		var i0 := t.dist.bsearch(float(t.stops[s].at))
		var i1 := clampi(t.dist.bsearch(float(t.stops[s + 1].at)), i0 + 1, t.dist.size() - 1)
		var v := PackedFloat64Array(); v.resize(i1 - i0 + 1)
		for k in v.size(): v[k] = limit[i0 + k]
		v[0] = 0.0; v[v.size() - 1] = 0.0
		for k in range(1, v.size()):
			v[k] = minf(v[k], sqrt(v[k - 1] * v[k - 1] + 2 * ACCEL * (t.dist[i0 + k] - t.dist[i0 + k - 1])))
		for k in range(v.size() - 2, -1, -1):
			v[k] = minf(v[k], sqrt(v[k + 1] * v[k + 1] + 2 * ACCEL * (t.dist[i0 + k + 1] - t.dist[i0 + k])))
		var times := PackedFloat64Array([0.0]); var dists := PackedFloat64Array([t.dist[i0]])
		for k in range(1, v.size()):
			var ds := t.dist[i0 + k] - t.dist[i0 + k - 1]
			times.append(times[-1] + ds / maxf(0.3, (v[k] + v[k - 1]) * 0.5))
			dists.append(t.dist[i0 + k])
		t.schedule.append({"kind": "move", "times": times, "dists": dists, "from": s, "to": s + 1})
	# the timetable: dwell, move, dwell, ... out and (unless a loop) back
	var plan: Array = []
	var clock := 0.0
	var legs := t.schedule.duplicate()
	t.schedule.clear()
	var order := []
	for k in legs.size(): order.append([k, 1])
	if not t.loop:
		for k in range(legs.size() - 1, -1, -1): order.append([k, -1])
	for step in order:
		var leg: Dictionary = legs[step[0]]
		var at_stop: int = leg.from if step[1] > 0 else leg.to
		var terminal := at_stop == 0 or at_stop == t.stops.size() - 1
		var dwell := END_DWELL if terminal and not t.loop else STOP_DWELL
		plan.append({"kind": "dwell", "t0": clock, "t1": clock + dwell, "stop": at_stop, "dir": step[1]})
		clock += dwell
		var duration: float = leg.times[-1]
		plan.append({"kind": "move", "t0": clock, "t1": clock + duration, "leg": leg, "dir": step[1]})
		clock += duration
	t.schedule = plan
	t.period = clock
	t.offset = float(absi(str(line.id).hash()) % 100000) / 100000.0 * t.period
	_make_vehicles(t)
	return t

## Shared track (dev's bug: trains passed through one another). Lines share single track
## around Ponyville and the Heartland, with one track through each hub platform, and each
## train only knew its own timetable. Connected shared segments form blocks (BLOCKS): a train
## enters a block only when no other train is in it, waiting at its last stop outside, and
## leaves it by running on. Holds shift that train's timetable later. Only the Frontier Loop
## crosses two blocks, so a train inside never waits on one that waits on it: no gridlock.
func _mark_shared_track() -> void:
	var users := {}
	for t in trains:
		for ids: Array in t.leg_segments:
			for id: String in ids:
				if not users.has(id): users[id] = {}
				users[id][str(t.line.get("id", ""))] = true
	# Union shared segments that a train runs from one straight into the other, platforms included.
	var parent := {}
	for id: String in users:
		if users[id].size() > 1: parent[id] = id
	for t in trains:
		var run: Array = []
		for ids: Array in t.leg_segments: run.append_array(ids)
		if t.loop and not run.is_empty(): run.append(run[0])
		for k in range(1, run.size()):
			if parent.has(run[k - 1]) and parent.has(run[k]): _union(parent, run[k - 1], run[k])
	for t in trains:
		for entry: Dictionary in t.schedule:
			var near: Array = []
			if entry.kind == "move":
				near = t.leg_segments[int(entry.leg.from)]
			else:
				var stop: int = entry.stop
				if stop > 0: near.append(t.leg_segments[stop - 1][-1])
				if stop < t.leg_segments.size(): near.append(t.leg_segments[stop][0])
				if t.loop and stop == 0: near.append(t.leg_segments[-1][-1])
			var blocks := {}
			for id: String in near:
				if parent.has(id): blocks[_find(parent, id)] = true
			entry["blocks"] = blocks

static func _find(parent: Dictionary, id: String) -> String:
	while parent[id] != id: id = parent[id]
	return id

static func _union(parent: Dictionary, a: String, b: String) -> void:
	parent[_find(parent, a)] = _find(parent, b)

## [schedule index, local timetable seconds] of the train at clock `time`.
func _entry_at(t: Train, time: float) -> Array:
	var local := fposmod(time - t.delay + t.offset, t.period)
	var k := _entry_index(t, local)
	return [k if k >= 0 else t.schedule.size() - 1, local]

## The first schedule entry ending at or after `local`, or -1 past the last one. Local time moves
## forward between ticks (holds add delay, the period wraps), so the last match or the next entry
## nearly always answers; entry ends never decrease, so a hit is that same first match.
func _entry_index(t: Train, local: float) -> int:
	var count := t.schedule.size()
	var k := t.entry_hint
	if SCHEDULE_HINT and k < count:
		if local <= float(t.schedule[k].t1) and (k == 0 or local > float(t.schedule[k - 1].t1)): return k
		k += 1
		if k < count and local <= float(t.schedule[k].t1) and local > float(t.schedule[k - 1].t1):
			t.entry_hint = k
			return k
	for i in count:
		if local <= float(t.schedule[i].t1):
			t.entry_hint = i
			return i
	return -1

## Trains about to leave a stop into a block someone else is in wait; among several asking
## for the same free block, the one that has waited longest goes.
func _reserve(time: float, delta: float) -> void:
	var at: Array = []
	var inside := {}   # block -> train indices in it now
	for i in trains.size():
		var place := _entry_at(trains[i], time)
		at.append(place)
		# A grant holds its blocks until the train actually pulls out of that stop.
		if trains[i].granted_at != int(place[0]): trains[i].granted = {}; trains[i].granted_at = -1
		var holding: Dictionary = trains[i].schedule[int(place[0])].get("blocks", {}).duplicate()
		holding.merge(trains[i].granted)
		for block: String in holding:
			if not inside.has(block): inside[block] = []
			inside[block].append(i)
	var asking := {}   # block -> [train index] wanting to enter it this tick
	var wants: Array = []
	for i in trains.size():
		wants.append({})
		var t := trains[i]
		var entry: Dictionary = t.schedule[int(at[i][0])]
		if entry.kind != "dwell" or float(entry.t1) - float(at[i][1]) > delta * 1.5 + .05: continue
		var next: Dictionary = t.schedule[(int(at[i][0]) + 1) % t.schedule.size()]
		for block: String in next.get("blocks", {}):
			if entry.get("blocks", {}).has(block) or t.granted.has(block): continue   # already its own
			wants[i][block] = true
			if not asking.has(block): asking[block] = []
			asking[block].append(i)
	# One turn per free block, decided from this tick's waits before any of them change.
	var winner := {}
	for block: String in asking:
		var best := -1
		for other: int in asking[block]:
			if best < 0 or trains[other].waited > trains[best].waited: best = other
		winner[block] = best
	for i in trains.size():
		var go := true
		for block: String in wants[i]:
			if (inside.has(block) and not inside[block].is_empty()) or winner[block] != i: go = false; break
		if go:
			trains[i].waited = 0.0
			if not wants[i].is_empty():
				trains[i].granted.merge(wants[i]); trains[i].granted_at = int(at[i][0])
			# Claim at once so a later train this tick sees the block taken.
			for block: String in wants[i]:
				if not inside.has(block): inside[block] = []
				inside[block].append(i)
		else:
			trains[i].delay += delta
			trains[i].waited += delta

## Trains start each session settled: replay the last SETTLE_SECONDS of clock with holds from
## no delay. A function of the clock alone, so a reload puts every train back in the same place.
const SETTLE_SECONDS := 1800.0
func _settle(time: float) -> void:
	for t in trains:
		t.delay = 0.0; t.waited = 0.0; t.granted = {}; t.granted_at = -1
	var at := maxf(0.0, time - SETTLE_SECONDS)
	while at < time:
		var step := minf(1.0, time - at)
		at += step
		_reserve(at, step)

## Where the train's head is at timetable time `time`: {"d": distance, "dir": ±1, "stop": index or -1}.
func _locate(t: Train, time: float) -> Dictionary:
	var local := fposmod(time - t.delay + t.offset, t.period)
	# A NaN clock matched the first entry in the old scan (`local > t1` is false); keep that.
	var k := 0 if is_nan(local) and not t.schedule.is_empty() else _entry_index(t, local)
	if k >= 0:
		var entry: Dictionary = t.schedule[k]
		if entry.kind == "dwell":
			return {"d": float(t.stops[entry.stop].at), "dir": int(entry.dir), "stop": int(entry.stop)}
		var leg: Dictionary = entry.leg
		var times: PackedFloat64Array = leg.times
		var dists: PackedFloat64Array = leg.dists
		var elapsed: float = local - entry.t0
		if int(entry.dir) < 0: elapsed = times[-1] - elapsed
		var i := clampi(times.bsearch(elapsed), 1, times.size() - 1)
		var f := clampf((elapsed - times[i - 1]) / maxf(times[i] - times[i - 1], 1e-6), 0.0, 1.0)
		return {"d": lerpf(dists[i - 1], dists[i], f), "dir": int(entry.dir), "stop": -1}
	return {"d": 0.0, "dir": 1, "stop": 0}

func _position(t: Train, d: float) -> Vector3:
	if t.points.is_empty(): return Vector3.ZERO
	if t.points.size() < 2: return t.points[0]
	# Coach centres extend past a terminal while the head is at the platform.
	# Clamping both tangent samples stacked the coaches and produced a zero basis
	# every physics tick. Continue the end segment; closed routes wrap instead.
	var value := fposmod(d, t.dist[-1]) if t.loop and t.dist[-1] > 0.0 else d
	var i := clampi(t.dist.bsearch(value), 1, t.dist.size() - 1)
	return t.points[i - 1].lerp(t.points[i], (value - t.dist[i - 1]) / maxf(t.dist[i] - t.dist[i - 1], 1e-6))

func _frame(t: Train, d: float, facing: int) -> Transform3D:
	var forward := (_position(t, d + 2.5) - _position(t, d - 2.5)).normalized() * facing
	# Keep degenerate imported segments out of the physics server too.
	if forward.length_squared() < 0.5: forward = Vector3.FORWARD * facing
	var up := Vector3.RIGHT if absf(forward.dot(Vector3.UP)) > 0.999 else Vector3.UP
	var right := forward.cross(up).normalized()
	return Transform3D(Basis(right, right.cross(forward), -forward), _position(t, d))

# ---------------------------------------------------------------- vehicles

func _make_vehicles(t: Train) -> void:
	t.engine = _make_engine(Color(str(t.line.color)))
	t.engine.name = "%sEngine" % str(t.line.id).to_pascal_case()
	add_child(t.engine)
	for i in 2:
		var car: AnimatableBody3D = load("res://world/railway/carriage.scn").instantiate()
		car.name = "%sCarriage%d" % [str(t.line.id).to_pascal_case(), i]
		for label in car.find_children("*", "Label3D", true, false): (label as Label3D).text = str(t.line.name).to_upper()
		add_child(car)
		t.cars.append(car)
	if ResourceLoader.exists("res://world/audio/designed/foley/train_roll_loop.res"):
		t.wheels = AudioStreamPlayer3D.new(); t.wheels.stream = load("res://world/audio/designed/foley/train_roll_loop.res")
		t.wheels.bus = "WorldSFX" if AudioServer.get_bus_index("WorldSFX") >= 0 else "SFX"
		t.wheels.volume_db = -26.0; t.wheels.max_distance = 60.0
		t.cars[0].add_child(t.wheels)

## A small cute steam engine in the line's colour: boiler, smokebox, chimney, dome, cab, wheels.
## The fourteen parts are one mesh with a surface per paint (5 draws, was 14); same geometry.
func _make_engine(colour: Color) -> AnimatableBody3D:
	var body := AnimatableBody3D.new(); body.collision_layer = 1; body.collision_mask = 0
	var paint := _mat(colour); var dark := _mat(Color("2e2b2b")); var gold := _mat(Color("d8b25a"))
	var cream := _mat(Color("efdfbc")); var steel := _mat(Color("55575e"))
	var parts := {}  # material -> merged arrays, in first-use order
	_cylinder(parts, Vector3(0, 1.75, 0.6), 0.85, 3.8, paint, Vector3(PI / 2, 0, 0))
	_cylinder(parts, Vector3(0, 1.75, -1.55), 0.9, 0.5, dark, Vector3(PI / 2, 0, 0))
	_cylinder(parts, Vector3(0, 2.95, -1.2), 0.22, 0.9, dark, Vector3.ZERO)
	_cylinder(parts, Vector3(0, 2.7, 0.8), 0.32, 0.45, gold, Vector3.ZERO)
	_box(parts, Vector3(0, 1.9, 2.55), Vector3(2.3, 2.4, 1.6), cream)
	_box(parts, Vector3(0, 3.2, 2.55), Vector3(2.6, 0.2, 1.9), paint)
	_box(parts, Vector3(0, 0.75, 0.6), Vector3(2.0, 0.35, 5.8), dark)
	_box(parts, Vector3(0, 0.6, -2.3), Vector3(2.2, 0.5, 0.4), gold)
	for side in [-1.0, 1.0]:
		for z in [-0.9, 0.5, 1.9]:
			_cylinder(parts, Vector3(side * 0.85, 0.5, z), 0.5, 0.18, steel, Vector3(0, 0, PI / 2))
	var mesh := ArrayMesh.new()
	for mat: Material in parts:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface_arrays(parts[mat]))
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	var mi := MeshInstance3D.new(); mi.name = "Body"; mi.mesh = mesh; body.add_child(mi)
	var shape := CollisionShape3D.new(); var box := BoxShape3D.new(); box.size = Vector3(2.4, 3.2, 6.2)
	shape.shape = box; shape.position = Vector3(0, 1.7, 0.2); body.add_child(shape)
	return body

func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = c; m.roughness = 0.7; return m

## Appends a primitive's own CPU arrays, moved by `xf` (SurfaceTool.append_from would read each
## primitive back from the GPU).
func _part(parts: Dictionary, mat: Material, mesh: PrimitiveMesh, xf: Transform3D) -> void:
	if not parts.has(mat):
		parts[mat] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "t": PackedFloat32Array(), "uv": PackedVector2Array(), "i": PackedInt32Array()}
	var into: Dictionary = parts[mat]
	var src := mesh.get_mesh_arrays()
	var v: PackedVector3Array = into.v; var n: PackedVector3Array = into.n; var t: PackedFloat32Array = into.t
	var uv: PackedVector2Array = into.uv; var index: PackedInt32Array = into.i
	var base := v.size()
	var normal_basis := xf.basis.inverse().transposed()
	for p: Vector3 in src[Mesh.ARRAY_VERTEX]: v.append(xf * p)
	for q: Vector3 in src[Mesh.ARRAY_NORMAL]: n.append((normal_basis * q).normalized())
	var tangents: PackedFloat32Array = src[Mesh.ARRAY_TANGENT]
	for k in range(0, tangents.size(), 4):
		var d := (xf.basis * Vector3(tangents[k], tangents[k + 1], tangents[k + 2])).normalized()
		t.append(d.x); t.append(d.y); t.append(d.z); t.append(tangents[k + 3])
	uv.append_array(src[Mesh.ARRAY_TEX_UV])
	for k: int in src[Mesh.ARRAY_INDEX]: index.append(base + k)
	into.v = v; into.n = n; into.t = t; into.uv = uv; into.i = index

static func _surface_arrays(part: Dictionary) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = part.v; arrays[Mesh.ARRAY_NORMAL] = part.n; arrays[Mesh.ARRAY_TANGENT] = part.t
	arrays[Mesh.ARRAY_TEX_UV] = part.uv; arrays[Mesh.ARRAY_INDEX] = part.i
	return arrays

func _box(parts: Dictionary, at: Vector3, size: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new(); mesh.size = size
	_part(parts, mat, mesh, Transform3D(Basis.IDENTITY, at))

func _cylinder(parts: Dictionary, at: Vector3, radius: float, height: float, mat: Material, rot: Vector3) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius; mesh.bottom_radius = radius; mesh.height = height; mesh.radial_segments = 16
	_part(parts, mat, mesh, Transform3D(Basis.from_euler(rot), at))

# ---------------------------------------------------------------- running

var _last_clock := -1.0

## Each train on the world map (bulk prompt package 13, "train map markers"), every 2 s.
var _marker_timer := 0.0
func _update_markers(time: float) -> void:
	var markers: Array[Dictionary] = []
	for t in trains:
		var where := _locate(t, time)
		var at := _position(t, where.d)
		var name := str(t.line.get("name", "Train"))
		markers.append({"id": "activity:train:" + str(t.line.get("id", name)), "name": name + (" · at the station" if int(where.stop) >= 0 else ""),
			"kind": "train", "position": Vector2(at.x, at.z), "activity": "train"})
	for map_view: Node in get_tree().get_nodes_in_group("world_map_views"):
		map_view.set_activity_markers("railway", markers)

func _physics_process(_delta: float) -> void:
	if not CPU_PROFILE.enabled:
		_profiled_physics_process(_delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_physics_process(_delta)
	CPU_PROFILE.record("rail_network", started)

func _profiled_physics_process(_delta: float) -> void:
	if trains.is_empty() or _clock == null: return
	var time: float = _clock.active_seconds
	# Holds count timetable seconds; a sleep or load jump is not a wait at the platform.
	if _last_clock < 0.0: _settle(time)
	var step := time - _last_clock
	_last_clock = time
	if step > 0.0 and step < 1.0: _reserve(time, step)
	_marker_timer -= _delta
	if _marker_timer <= 0.0:
		_marker_timer = 2.0
		_update_markers(time)
	var viewer := _viewer()
	for t in trains:
		var where := _locate(t, time)
		var stop: int = int(where.stop)
		# Only actual timetable transitions make a sound. Entry, sleep and load
		# relocate trains silently, including trains outside the visible range.
		var sound_transition := t.last_audio_stop != -2 and t.last_audio_stop != stop and step > 0.0 and step < 1.0
		t.last_audio_stop = stop
		t.doors_audible = sound_transition
		# the head stops at the station; the 70 m platform takes the train from either side
		var head: float = where.d
		var dir: int = where.dir
		var near := viewer.distance_to(_position(t, head)) < ACTIVE_RANGE
		if not near:
			_set_train_collisions(t, false)
			if t.engine.visible: t.engine.visible = false
			for car in t.cars:
				if car.visible: car.visible = false
			if t.wheels != null and t.wheels.playing: t.wheels.stop()
			t.placed = false
			continue
		# Standing exactly where it was last placed (PLACE_ONLY_MOVED): poses, doors, collision and
		# visibility are already current. A stop change (and so every stop/departure sound) re-places.
		var still := PLACE_ONLY_MOVED and t.placed and head == t.placed_d and dir == t.placed_dir and stop == t.placed_stop
		if not still:
			t.engine.global_transform = _frame(t, head - dir * ENGINE_HALF, dir)
			if sound_transition:
				SOUNDS.play_at(t.engine, "prop_train_stop" if stop >= 0 else "prop_train_departure")
			var offset := ENGINE_HALF * 2 + GAP + CAR_LENGTH * 0.5
			for i in t.cars.size():
				var car := t.cars[i]
				car.global_transform = _frame(t, head - dir * (offset + i * (CAR_LENGTH + GAP)), dir).translated_local(Vector3(0, CAR_FLOOR, 0))
				_doors(t, car, stop)
			# Dormant bodies remain at their last rendered frame. Restore every current vehicle
			# pose before collisions/visibility return, so a teleport cannot meet an old blocker.
			_set_train_collisions(t, true)
			if not t.engine.visible: t.engine.visible = true
			for car in t.cars:
				if not car.visible: car.visible = true
			t.placed = true; t.placed_d = head; t.placed_dir = dir; t.placed_stop = stop
		if t.wheels != null:
			var moving: bool = where.stop < 0 and t.wheels.global_position.distance_squared_to(viewer) < t.wheels.max_distance * t.wheels.max_distance
			if moving and not t.wheels.playing: t.wheels.play()
			elif not moving and t.wheels.playing: t.wheels.stop()

## Capture authored participation once, including any nested vehicle collision body/area.
## Writes happen only on activation changes; near trains keep their full physics cadence.
func _set_train_collisions(t: Train, active: bool) -> void:
	if t.collision_sources.is_empty():
		var vehicles: Array[AnimatableBody3D] = [t.engine]
		vehicles.append_array(t.cars)
		for vehicle in vehicles:
			var objects: Array[Node] = [vehicle]
			objects.append_array(vehicle.find_children("*", "CollisionObject3D", true, false))
			for object: CollisionObject3D in objects:
				t.collision_sources.append({"body": weakref(object), "layer": object.collision_layer, "mask": object.collision_mask})
	if t.collision_active == active: return
	for entry: Dictionary in t.collision_sources:
		var body: CollisionObject3D = entry.body.get_ref() as CollisionObject3D
		if not is_instance_valid(body): continue
		body.collision_layer = int(entry.layer) if active else 0
		body.collision_mask = int(entry.mask) if active else 0
	t.collision_active = active

## Open the carriage doors on the platform side while stopped at a station.
func _doors(t: Train, car: Node3D, stop: int) -> void:
	var open_side := 0
	if stop >= 0:
		var platform: Node3D = platforms.get(str(t.stops[stop].id))
		if platform != null:
			open_side = 1 if (platform.global_position - car.global_position).dot(car.global_basis.x) > 0 else -1
	for name in ["DoorLeft", "DoorRight"]:
		var door := car.get_node_or_null(name)
		if door == null: continue
		var side := -1 if name == "DoorLeft" else 1
		var opened := side == open_side
		if bool(door.get("disabled")) != opened: door.set_deferred("disabled", opened)
		var panel := door.get_node_or_null("Panel")
		if panel != null and panel.visible == opened:
			panel.visible = not opened
			if t.doors_audible and not t.cars.is_empty() and car == t.cars[0]:
				SOUNDS.play_at(car, "prop_train_door")

func _viewer() -> Vector3:
	var camera := preload("res://world/player_view.gd").camera(self)
	return camera.global_position if camera != null else Vector3.ZERO

## Stations and lines for the map and for talk: {station id: [line names]}.
func lines_at() -> Dictionary:
	var out := {}
	for t in trains:
		for stop in t.stops:
			if not out.has(stop.id): out[stop.id] = []
			if not str(t.line.name) in out[stop.id]: out[stop.id].append(str(t.line.name))
	return out
