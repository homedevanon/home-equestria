class_name WalkPlanner
extends RefCounted
## Pure data search, safe on a worker. No SceneTree, physics or server calls.
const LIMIT := 100000
## Cells a single route search may expand; the service lowers it on the potato tier
## (quality.gd nav_search_limit) so one hopeless route cannot hold a core for seconds.
var limit := LIMIT
## false = the exact search sees every resident chunk (walk_grid_service.gd OPEN_ROUTES).
var use_corridor := true
const WANDER_LIMIT := 6000
const MAX_CORRIDOR_SAMPLES := 512
const MAX_SMOOTH_CHECKS := 4096
const CORRIDOR_STEP := WalkGrid.CELL * 0.5
const OUTPUT_STEP := 0.5
## How far from a cramped start / destination the route may begin / end (metres).
const START_REACH := 2.5
const GOAL_REACH := 3.0
var data: Dictionary:
	set(value):
		data = value
		cells.clear()
		room.clear()
		_pure_room.clear()
var profile: Dictionary:
	set(value):
		profile = value
		# Cached samples carry this profile's allowed() verdict.
		cells.clear()
		_pure_room.clear()
		_step_limit = float(value.get("step", 0.0)) + .0001
		_grade_limit = float(value.get("slope", 0.0)) + .05
		_wade_floor = maxf(float(value.get("wade", 0.0)), .01)
## WalkGrid.connected() terms, computed once per profile instead of once per edge.
var _step_limit := .0001
var _grade_limit := .05
var _wade_floor := .01
## Plain WalkGrid.has_room() results per body radius (never the seeded cramped-start room).
var _pure_room := {}
var _offsets := {}
var room := {}
var expanded := 0
var corridor := {}
var frontier := {}
var smoothing_checks := 0
var minimum_cost := .48
var cells := {}
var cancel_signal: Semaphore
var cancelled := false

func _cancelled() -> bool:
	if not cancelled and cancel_signal != null: cancelled = cancel_signal.try_wait()
	return cancelled

# One immutable snapshot per search: decode each visited cell only once. The profile's
# allowed() verdict rides along as "ok" so a link does not re-prove both cells per edge.
func _sample(key: Vector3i) -> Dictionary:
	var s: Variant = cells.get(key)
	if s == null:
		s = WalkGrid.sample(data,key)
		if not s.is_empty(): s["ok"] = WalkGrid.allowed(s,profile)
		cells[key] = s
	return s

func _point(key: Vector3i) -> Vector3:
	return Vector3((key.x+.5)*WalkGrid.CELL,_sample(key).get("height",NAN),(key.z+.5)*WalkGrid.CELL)

## WalkGrid.connected(a,b,distance,profile) for two samples from _sample().
func _link(a: Dictionary, b: Dictionary, distance: float) -> bool:
	if not a.get("ok",false) or not b.get("ok",false): return false
	var rise := absf(a.height-b.height)
	if rise <= _step_limit: return true
	var grade := rad_to_deg(atan2(rise,distance))
	return grade <= _grade_limit and maxf(a.slope,b.slope) >= grade - 1.5

## _link() when `a` is already known to be allowed.
func _link_from(a: Dictionary, b: Dictionary, distance: float) -> bool:
	if not b.get("ok",false): return false
	var rise := absf(a.height-b.height)
	if rise <= _step_limit: return true
	var grade := rad_to_deg(atan2(rise,distance))
	return grade <= _grade_limit and maxf(a.slope,b.slope) >= grade - 1.5

## Cells within `radius` of a column, in WalkGrid.has_room's order, with their distances.
func _room_offsets(radius: float) -> Array:
	var known: Variant = _offsets.get(radius)
	if known != null: return known
	var xs := PackedInt32Array(); var zs := PackedInt32Array(); var lengths := PackedFloat64Array()
	var r := ceili(radius/WalkGrid.CELL)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			if x*x+z*z == 0 or Vector2(x,z).length()*WalkGrid.CELL > radius: continue
			xs.append(x); zs.append(z); lengths.append(Vector2(x,z).length()*WalkGrid.CELL)
	known = [xs,zs,lengths]
	_offsets[radius] = known
	return known

## WalkGrid.has_room(data,key,profile with this radius), from this search's samples.
func _has_room_r(key: Vector3i, radius: float) -> bool:
	var center := _sample(key)
	if not center.get("ok",false): return false
	var offsets := _room_offsets(radius)
	var xs: PackedInt32Array = offsets[0]; var zs: PackedInt32Array = offsets[1]; var lengths: PackedFloat64Array = offsets[2]
	for i in xs.size():
		var x := key.x+xs[i]; var z := key.z+zs[i]
		var found := false
		for span in WalkGrid.SPANS:
			if _link_from(center,_sample(Vector3i(x,span,z)),lengths[i]): found = true; break
		if not found: return false
	return true

## Memoised _has_room_r: A*, endpoint snapping and smoothing ask about the same cells.
func _pure_room_check(key: Vector3i, radius: float) -> bool:
	var rooms: Variant = _pure_room.get(radius)
	if rooms == null: rooms = {}; _pure_room[radius] = rooms
	var known: Variant = rooms.get(key)
	if known == null:
		known = _has_room_r(key,radius)
		rooms[key] = known
	return known

func _has_room(key: Vector3i) -> bool:
	return _pure_room_check(key,float(profile.radius))

## WalkGrid.nearest(data,pos,profile,radius) from this search's samples and room results.
func _nearest(pos: Vector3, radius := 1.0) -> Vector3i:
	var c := WalkGrid.column(pos)
	var best := Vector3i(0,-1,0)
	var best_d := radius*radius
	var r := ceili(radius/WalkGrid.CELL)
	var body := float(profile.radius)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			for span in WalkGrid.SPANS:
				var key := Vector3i(c.x+x,span,c.y+z)
				if not _sample(key).get("ok",false): continue
				var d := _point(key).distance_squared_to(pos)
				if d <= best_d and _pure_room_check(key,body): best_d = d; best = key
	return best

## Room results outlive one search: the service hands every search the same `shared`
## dictionary. A chunk's entries are dropped when it or a neighbour changes or leaves the
## snapshot (room looks across chunk borders), so a result is never older than its data.
## Wander searches used to spend ~95 % of their time recomputing the same body-room checks.
var shared: Dictionary = {}
var _sharing := false
var _shared_room: Dictionary = {}  # chunk -> {cell key: bool}, for this search's profile
const SHARED_ROOM_LIMIT := 400000

## Per chunk view: the lowest cost multiplier it can offer (plan()'s heuristic bound).
## Array(paint).min() over 384 resident chunks was ~12k Variants per chunk per plan.
var _cost_floor: Dictionary = {}

func _sync_shared() -> void:
	_sharing = shared.has("views")
	_shared_room = {}
	_cost_floor = {}
	if not _sharing: return
	var views: Dictionary = shared.views
	var stale: Array[Vector2i] = []
	for c in data:
		if not views.has(c) or not is_same(views[c], data[c]):
			views[c] = data[c]; stale.append(c)
	for c in views.keys():
		if not data.has(c): views.erase(c); stale.append(c)
	if not shared.has("costs"): shared["costs"] = {}
	_cost_floor = shared.costs
	for c in stale: _cost_floor.erase(c)
	var profiles: Dictionary = shared.profiles
	if int(shared.get("entries", 0)) > SHARED_ROOM_LIMIT:
		profiles.clear(); shared.entries = 0
	for sig in profiles:
		var chunks: Dictionary = profiles[sig]
		for c in stale:
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					chunks.erase(c + Vector2i(dx, dz))
	var sig := profile.hash()
	if not profiles.has(sig): profiles[sig] = {}
	_shared_room = profiles[sig]

func _room(key: Vector3i) -> bool:
	var result: Variant = room.get(key)
	if result != null: return result
	var known: Dictionary = {}
	var chunk := WalkGrid.chunk_of(Vector2i(key.x,key.z))
	if _sharing:
		if not _shared_room.has(chunk): _shared_room[chunk] = {}
		known = _shared_room[chunk]
	if known.has(key): result = known[key]
	else:
		result = _has_room(key)
		if _sharing: known[key] = result; shared.entries = int(shared.get("entries", 0)) + 1
	room[key] = result
	if not result and not _sample(key).is_empty():
		var r := ceili(profile.radius/WalkGrid.CELL)
		for d in [Vector2i(-r,0),Vector2i(r,0),Vector2i(0,-r),Vector2i(0,r)]:
			var c := WalkGrid.chunk_of(Vector2i(key.x,key.z)+d)
			if not data.has(c): frontier[c] = true
	return result

## Same candidates, order and frontier marks as testing each (direction, span) pair on its
## own; chunk and source checks are per direction, and the source is proved allowed once.
func neighbors(key: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var source := _sample(key)
	var source_ok: bool = source.get("ok",false)
	for direction: Vector2i in WalkGrid.DIRECTIONS:
		var x := key.x+direction.x; var z := key.z+direction.y
		var chunk := WalkGrid.chunk_of(Vector2i(x,z))
		if not data.has(chunk): frontier[chunk] = true; continue
		if not corridor.is_empty() and not corridor.has(chunk): continue
		if not source_ok: continue
		var distance := Vector2(direction).length()*WalkGrid.CELL
		var diagonal := direction.x != 0 and direction.y != 0
		for span in WalkGrid.SPANS:
			var other := Vector3i(x,span,z)
			var dest := _sample(other)
			if not _link_from(source,dest,distance) or not _room(other): continue
			if diagonal and not (_via(key,Vector2i(direction.x,0),source,dest) and _via(key,Vector2i(0,direction.y),source,dest)): continue
			out.append(other)
	return out

## A diagonal step needs a roomy side cell joined to both ends (no squeezing past corners).
func _via(key: Vector3i, side: Vector2i, source: Dictionary, dest: Dictionary) -> bool:
	for s in WalkGrid.SPANS:
		var between := Vector3i(key.x+side.x,s,key.z+side.y)
		var mid := _sample(between)
		if _room(between) and _link_from(source,mid,WalkGrid.CELL) and _link_from(mid,dest,WalkGrid.CELL): return true
	return false

func cost(a: Vector3i, b: Vector3i) -> float:
	var s := _sample(b)
	var water: float = 1.0 + 4.0*s.water/_wade_floor
	return Vector2(a.x-b.x,a.z-b.z).length()*WalkGrid.CELL*(1.0+s.slope/45.0)*water*s.paint

func plan(snapshot: Dictionary, from: Vector3, to: Vector3, settings: Dictionary, any_floor := false, relaxed := false) -> Dictionary:
	data = snapshot
	cancelled = false
	profile = settings
	room.clear(); cells.clear()
	_sync_shared()
	corridor.clear(); frontier.clear()
	expanded = 0
	smoothing_checks = 0
	# An admissible lower bound from this snapshot's actual terrain costs. The
	# old unconditional .48 turned an ordinary 92m crossing into 72k expansions
	# even when no discounted trail or ford existed anywhere in the search.
	minimum_cost = INF
	for c in data:
		var bound: Variant = _cost_floor.get(c)
		if bound == null:
			bound = _chunk_cost_floor(data[c])
			if _sharing: _cost_floor[c] = bound
		minimum_cost = minf(minimum_cost, bound)
	if not is_finite(minimum_cost): minimum_cost = .48
	# Keep the actual supporting surface; nearby roomy ground may be below a ramp.
	var start := _nearest_allowed(from,1.0)
	if start.y < 0: start = _nearest_allowed(from,START_REACH)
	if start.y >= 0 and not _room(start):
		if start.y >= 0:
			var r := ceili(profile.radius/WalkGrid.CELL)
			for z in range(-r,r+1):
				for x in range(-r,r+1):
					for span in WalkGrid.SPANS:
						var key := Vector3i(start.x+x,span,start.z+z)
						if WalkGrid.allowed(_sample(key),profile): room[key] = true
	var goal := _nearest(to)
	var goals := {}
	if goal.y >= 0: goals[goal] = true
	# A destination with no room within a metre (the player beside a wall, on a step, among
	# props) is not unreachable: she goes as close as the grid allows. Every room cell within
	# GOAL_REACH is a goal; the heuristic still aims at the exact spot, so the search ends on
	# the nearest reachable one (dev 2026-09-18: "walk around to a spot where they don't
	# think it's unreachable").
	if goals.is_empty() or any_floor:
		var c := WalkGrid.column(to)
		var reach := ceili(GOAL_REACH/WalkGrid.CELL)
		var nearest_d := INF
		for z in range(-reach,reach+1):
			for x in range(-reach,reach+1):
				if Vector2(x,z).length()*WalkGrid.CELL > GOAL_REACH: continue
				for span in WalkGrid.SPANS:
					var candidate := Vector3i(c.x+x,span,c.y+z)
					if not _room(candidate): continue
					goals[candidate] = true
					var d := _point(candidate).distance_squared_to(to)
					if d < nearest_d: nearest_d = d; goal = candidate
	if start.y < 0 or goals.is_empty(): return {"path":PackedVector3Array(),"reason":"No safe floor at start or destination"}
	# First search chunk portals, then exact cells in that corridor plus one chunk.
	# A chunk can contain separate islands: the cell pass is authoritative, and
	# retries the complete resident snapshot if the coarse abstraction chose one.
	corridor = _chunk_corridor(start,goal)
	var result := _cell_plan(start,goal,goals,relaxed)
	if result.path.is_empty() and not corridor.is_empty() and not cancelled:
		corridor.clear(); expanded = 0
		result = _cell_plan(start,goal,goals,relaxed)
	result["frontier"] = frontier.keys()
	cells.clear(); _pure_room.clear()
	return result

func _chunk_cost_floor(chunk: Dictionary) -> float:
	var paint: PackedByteArray = chunk.paint_cost
	var trails: PackedByteArray = chunk.get("trail_weight", PackedByteArray())
	var terrain_discount := lerpf(1.0, .6, float(Array(trails).max()) / 255.0) if not trails.is_empty() else 1.0
	return float(Array(paint).min()) / WalkGrid.PAINT_SCALE * terrain_discount

func _cell_plan(start: Vector3i, goal: Vector3i, goals: Dictionary, relaxed: bool) -> Dictionary:
	var parents := {}
	var scores := {start:0.0}
	var heap: Array = []
	_push(heap,[0.0,start,0.0])
	while not heap.is_empty() and expanded < limit:
		if expanded % 128 == 0 and _cancelled(): return {"path":PackedVector3Array(),"expanded":expanded,"reason":"Cancelled"}
		var entry: Array = _pop(heap)
		var key: Vector3i = entry[1]
		if entry[2] > scores.get(key,INF): continue
		expanded += 1
		if goals.has(key):
			var raw: Array[Vector3i] = [key]
			while key != start: key = parents[key]; raw.append(key)
			raw.reverse()
			return {"path":_smooth(raw,relaxed),"expanded":expanded,"reason":""}
		for next in neighbors(key):
			var score: float = scores[key] + cost(key,next)
			if score >= scores.get(next,INF): continue
			scores[next] = score
			parents[next] = key
			# Snapshot lower bound retains optimal-cost search, including trails and fords.
			var h := Vector2(next.x-goal.x,next.z-goal.z).length()*WalkGrid.CELL*minimum_cost
			_push(heap,[score+h,next,score])
	return {"path":PackedVector3Array(),"expanded":expanded,"reason":"Search budget reached" if expanded >= limit else "Destination is disconnected in sampled terrain"}

## Nearest cell the profile may stand on, ignoring body room (for a cramped start).
func _nearest_allowed(pos: Vector3, radius: float) -> Vector3i:
	var c := WalkGrid.column(pos)
	var best := Vector3i(0,-1,0)
	var best_d := radius*radius
	var r := ceili(radius/WalkGrid.CELL)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			for span in WalkGrid.SPANS:
				var key := Vector3i(c.x+x,span,c.y+z)
				if not WalkGrid.allowed(_sample(key),profile): continue
				var d := _point(key).distance_squared_to(pos)
				if d < best_d: best_d = d; best = key
	return best


func _portal(a: Vector2i, b: Vector2i) -> bool:
	var direction := b-a
	for i in WalkGrid.CHUNK_CELLS:
		var cell := a*WalkGrid.CHUNK_CELLS
		if direction.x != 0:
			cell += Vector2i(WalkGrid.CHUNK_CELLS-1 if direction.x>0 else 0,i)
		else:
			cell += Vector2i(i,WalkGrid.CHUNK_CELLS-1 if direction.y>0 else 0)
		for span in WalkGrid.SPANS:
			var k := Vector3i(cell.x,span,cell.y)
			if not _room(k): continue
			for other_span in WalkGrid.SPANS:
				var next := Vector3i(cell.x+direction.x,other_span,cell.y+direction.y)
				if _room(next) and _link(_sample(k),_sample(next),WalkGrid.CELL): return true
	return false

func _chunk_corridor(start: Vector3i, goal: Vector3i) -> Dictionary:
	var a := WalkGrid.chunk_of(Vector2i(start.x,start.z))
	var b := WalkGrid.chunk_of(Vector2i(goal.x,goal.z))
	if a == b or data.size() < 16 or not use_corridor: return {}
	var heap: Array = []; _push(heap,[0.0,a,0.0])
	var scores := {a:0.0}; var parents := {}; var portals := {}
	while not heap.is_empty():
		if _cancelled(): return {}
		var entry := _pop(heap); var c: Vector2i = entry[1]
		if entry[2] > scores.get(c,INF): continue
		if c == b:
			var selected := {}
			while true:
				for z in range(-1,2):
					for x in range(-1,2): selected[c+Vector2i(x,z)] = true
				if c == a: break
				c = parents[c]
			return selected
		for direction in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
			var next: Vector2i = c+direction
			if not data.has(next): continue
			var edge := [c,next]
			if not portals.has(edge): portals[edge] = _portal(c,next)
			if not portals[edge]: continue
			var score: float = scores[c]+1.0
			if score >= scores.get(next,INF): continue
			scores[next] = score; parents[next] = c
			_push(heap,[score+Vector2(next-b).length(),next,score])
	return {}

func _raw_points(raw: Array[Vector3i]) -> PackedVector3Array:
	var result := PackedVector3Array()
	for key in raw: result.append(_point(key))
	return result


func _smooth(raw: Array[Vector3i], relaxed := false) -> PackedVector3Array:
	var fallback := _raw_points(raw)
	if raw.size() < 2: return fallback
	var anchors := PackedVector3Array([fallback[0]])
	var i := 0
	while i < raw.size()-1:
		var best := i+1
		var reference := 0.0
		# Bound shortcut work; retain height samples across crests and floor changes.
		for j in range(i+1,mini(i+33,raw.size())):
			reference += cost(raw[j-1],raw[j])
			var direct := _certify_segment(fallback[i],fallback[j],reference*1.03)
			if direct.get("valid",false): best = j
		i = best
		anchors.append(fallback[i])
	var certified := _certify_polyline(anchors)
	if not certified.get("valid",false): return fallback
	var shape := _rounded_shape(anchors)
	if relaxed: shape = _relaxed_shape(shape)
	certified = _certify_polyline(shape,float(certified.cost)*(1.06 if relaxed else 1.03))
	if not certified.get("valid",false):
		certified = _certify_polyline(anchors)
		if not certified.get("valid",false): return fallback
	return _decimate(certified.points)


func _rounded_shape(anchors: PackedVector3Array) -> PackedVector3Array:
	if anchors.size() < 3: return anchors
	var result := PackedVector3Array([anchors[0]])
	for i in range(1,anchors.size()-1):
		var a := anchors[i-1]; var b := anchors[i]; var c := anchors[i+1]
		var incoming := Vector2(b.x-a.x,b.z-a.z)
		var outgoing := Vector2(c.x-b.x,c.z-b.z)
		if incoming.length() < .01 or outgoing.length() < .01:
			result.append(b); continue
		incoming = incoming.normalized(); outgoing = outgoing.normalized()
		var alignment := incoming.dot(outgoing)
		if alignment > .995 or alignment < -.8:
			result.append(b); continue
		var distance := minf(1.5,minf(Vector2(b.x-a.x,b.z-a.z).length(),Vector2(c.x-b.x,c.z-b.z).length())*.22)
		var rounded := PackedVector3Array()
		for attempt in 3:
			var enter := b-Vector3(incoming.x,0,incoming.y)*distance
			var leave := b+Vector3(outgoing.x,0,outgoing.y)*distance
			enter.y = lerpf(a.y,b.y,1.0-distance/maxf(.001,Vector2(b.x-a.x,b.z-a.z).length()))
			leave.y = lerpf(b.y,c.y,distance/maxf(.001,Vector2(c.x-b.x,c.z-b.z).length()))
			var candidate := PackedVector3Array([enter])
			var curve_steps := maxi(3,ceili(distance*2.0/OUTPUT_STEP))
			for step in range(1,curve_steps):
				var t := float(step)/curve_steps
				candidate.append(enter*(1.0-t)*(1.0-t)+b*2.0*(1.0-t)*t+leave*t*t)
			candidate.append(leave)
			var reference := _certify_polyline(PackedVector3Array([enter,b,leave]))
			var check := _certify_polyline(candidate,float(reference.get("cost",INF))*1.03)
			if reference.get("valid",false) and check.get("valid",false):
				rounded = candidate; break
			distance *= .5
		if rounded.is_empty(): result.append(b)
		else:
			for point in rounded: result.append(point)
	result.append(anchors[-1])
	return result


func _relaxed_shape(shape: PackedVector3Array) -> PackedVector3Array:
	if shape.size() < 2: return shape
	var total := _shape_length(shape)
	var direct := Vector2(shape[-1].x-shape[0].x,shape[-1].z-shape[0].z)
	if total < 6.0 or direct.length()/total < .9: return shape
	var amplitude := minf(1.0,total*.06)
	# Prove the whole base corridor has room for the lateral displacement first.
	if not _certify_polyline(shape,INF,amplitude+.1).get("valid",false): return shape
	var normal := Vector2(-direct.y,direct.x).normalized()
	var seed := Vector2(shape[0].x+shape[-1].z,shape[0].z-shape[-1].x)
	if _stable_fraction(seed,313) < .5: normal = -normal
	var result := PackedVector3Array([shape[0]])
	var walked := 0.0
	for i in range(1,shape.size()):
		var segment := Vector2(shape[i].x-shape[i-1].x,shape[i].z-shape[i-1].z).length()
		var steps := maxi(1,ceili(segment/2.0))
		for step in range(1,steps+1):
			var local := float(step)/steps
			var point := shape[i-1].lerp(shape[i],local)
			var progress := (walked+segment*local)/total
			var offset := normal*amplitude*sin(PI*progress)
			point.x += offset.x; point.z += offset.y
			result.append(point)
		walked += segment
	var base := _certify_polyline(shape)
	var bent := _certify_polyline(result,float(base.get("cost",INF))*1.06)
	return result if base.get("valid",false) and bent.get("valid",false) else shape


func _shape_length(shape: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1,shape.size()): total += Vector2(shape[i].x-shape[i-1].x,shape[i].z-shape[i-1].z).length()
	return total


## Pure worker-side segment authority for route smoothing and follower lookahead. Returned
## points follow one connected sampled floor. Empty means the radius-eroded corridor, floor
## continuity, terrain limits, or paint-cost bound could not be proved.
func corridor_segment(a: Vector3, b: Vector3, cost_limit := INF, extra_clearance := 0.0) -> PackedVector3Array:
	smoothing_checks=0
	var result := _certify_segment(a,b,cost_limit,extra_clearance)
	return result.get("points",PackedVector3Array()) if result.get("valid",false) else PackedVector3Array()


func segment_is_clear(a: Vector3, b: Vector3, cost_limit := INF, extra_clearance := 0.0) -> bool:
	return not corridor_segment(a,b,cost_limit,extra_clearance).is_empty()


func _certify_polyline(shape: PackedVector3Array, cost_limit := INF, extra_clearance := 0.0) -> Dictionary:
	if shape.is_empty(): return {"valid":false}
	if shape.size() == 1: return _certify_segment(shape[0],shape[0],cost_limit,extra_clearance)
	var points := PackedVector3Array(); var total := 0.0
	for i in range(1,shape.size()):
		var segment := _certify_segment(shape[i-1],shape[i],cost_limit-total,extra_clearance)
		if not segment.get("valid",false): return {"valid":false}
		total += float(segment.cost)
		for point in segment.points:
			if points.is_empty() or point.distance_squared_to(points[-1]) > .000001: points.append(point)
	return {"valid":true,"points":points,"cost":total}


func _certify_segment(a: Vector3, b: Vector3, cost_limit: float, extra_clearance := 0.0) -> Dictionary:
	if not a.is_finite() or not b.is_finite(): return {"valid":false}
	var distance := Vector2(b.x-a.x,b.z-a.z).length()
	var steps := maxi(1,ceili(distance/CORRIDOR_STEP))
	if steps>MAX_CORRIDOR_SAMPLES or smoothing_checks+steps+1>MAX_SMOOTH_CHECKS: return {"valid":false}
	smoothing_checks+=steps+1
	# WalkGrid.has_room is already the profile-radius erosion of sampled occupancy.
	# Curves are sampled twice per cell, so requiring every touched eroded cell keeps
	# the curve inside that certified corridor without inventing another grid-cell moat.
	# Room verdicts are shared by every segment of the search (smoothing re-tests the same
	# cells up to 32 times per anchor).
	var radius := float(profile.radius)+maxf(0.0,extra_clearance)
	var points := PackedVector3Array()
	var previous := Vector3i(0,-1,0); var total := 0.0
	for step in range(steps+1):
		var t := float(step)/steps
		var position := a.lerp(b,t)
		var column := WalkGrid.column(position)
		var key := _corridor_floor(column,position.y,previous,radius)
		if key.y < 0: return {"valid":false}
		var sample := _sample(key)
		if previous.y >= 0 and key != previous:
			var before := _sample(previous)
			if not _corridor_connected(previous,key,before,sample,radius): return {"valid":false}
		var grounded := Vector3(position.x,float(sample.height),position.z)
		points.append(grounded)
		if step > 0:
			var stride := distance/steps
			var water: float = 1.0+4.0*float(sample.water)/_wade_floor
			total += stride*(1.0+float(sample.slope)/45.0)*water*float(sample.paint)
			if total > cost_limit: return {"valid":false}
		previous = key
	return {"valid":true,"points":points,"cost":total}


func _corridor_floor(column: Vector2i, expected_y: float, previous: Vector3i, radius: float) -> Vector3i:
	var best := Vector3i(0,-1,0); var score := INF
	for span in WalkGrid.SPANS:
		var key := Vector3i(column.x,span,column.y)
		if not _pure_room_check(key,radius): continue
		var sample := _sample(key)
		if previous.y >= 0 and key != previous:
			var before := _sample(previous)
			if not _corridor_connected(previous,key,before,sample,radius): continue
		var candidate := absf(float(sample.height)-expected_y)
		if candidate < score: score = candidate; best = key
	return best


func _corridor_connected(a: Vector3i,b: Vector3i,source: Dictionary,dest: Dictionary,radius: float) -> bool:
	var delta := Vector2i(b.x-a.x,b.z-a.z)
	if absi(delta.x)>1 or absi(delta.y)>1: return false
	if not _link(source,dest,Vector2(delta).length()*WalkGrid.CELL): return false
	if delta.x==0 or delta.y==0: return true
	# A diagonal sample may not squeeze between two touching blocked cells.
	for side in [Vector2i(delta.x,0),Vector2i(0,delta.y)]:
		var via := false
		for span in WalkGrid.SPANS:
			var key := Vector3i(a.x+side.x,span,a.z+side.y)
			if not _pure_room_check(key,radius): continue
			var mid := _sample(key)
			if _link(source,mid,WalkGrid.CELL) and _link(mid,dest,WalkGrid.CELL):
				via=true; break
		if not via: return false
	return true


func _decimate(points: PackedVector3Array) -> PackedVector3Array:
	if points.size() <= 2: return points
	var result := PackedVector3Array([points[0]])
	var i := 0
	while i<points.size()-1:
		var best := i+1
		var reference := 0.0
		for j in range(i+1,points.size()):
			var stride := Vector2(points[j].x-points[j-1].x,points[j].z-points[j-1].z).length()
			if stride>OUTPUT_STEP*1.5 and j>i+1: break
			reference+=_sampled_stride_cost(points[j],stride)
			var check := _certify_segment(points[i],points[j],reference*1.03)
			if check.get("valid",false) and _height_follows(points,i,j): best=j
			if Vector2(points[j].x-points[i].x,points[j].z-points[i].z).length()>=OUTPUT_STEP: break
		i=best
		result.append(points[i])
	return result


func _sampled_stride_cost(point: Vector3,stride: float) -> float:
	var column := WalkGrid.column(point); var selected := {}
	var error := INF
	for span in WalkGrid.SPANS:
		var sample := _sample(Vector3i(column.x,span,column.y))
		if sample.is_empty(): continue
		var candidate := absf(float(sample.height)-point.y)
		if candidate<error: error=candidate; selected=sample
	if selected.is_empty(): return INF
	var water := 1.0+4.0*float(selected.water)/_wade_floor
	return stride*(1.0+float(selected.slope)/45.0)*water*float(selected.paint)


func _height_follows(points: PackedVector3Array,a: int,b: int) -> bool:
	if b<=a+1: return true
	for i in range(a+1,b):
		var t := float(i-a)/(b-a)
		if absf(points[i].y-lerpf(points[a].y,points[b].y,t))>.035: return false
	return true


static func _stable_fraction(pos: Vector2, salt: int) -> float:
	var value: int = (floori(pos.x/WalkGrid.CELL)*73856093) ^ (floori(pos.y/WalkGrid.CELL)*19349663) ^ (salt*83492791)
	value = ((value^(value>>13))*1274126177)&0x7fffffff
	return float(value%100000)/100000.0

## Wander samples the reachable component from her feet, never a guessed roof.
## `rng` (dev 2026-10-20 multithreading): a seeded stream instead of the global randf(), so the
## equivalence fixture can replay the native wander (PonyWanderJob) roll for roll.
func wander(snapshot: Dictionary, from: Vector3, settings: Dictionary, radius: float, interest: Vector3 = Vector3.INF, home: Vector3 = Vector3.INF, leash := INF, context := {}, rng: RandomNumberGenerator = null) -> Vector3:
	cancelled = false
	data = snapshot; profile = settings; room.clear(); cells.clear(); corridor.clear(); frontier.clear()
	_sync_shared()
	var start := _nearest(from)
	if start.y < 0: return Vector3.INF
	var queue: Array[Vector3i] = [start]
	var seen := {start:true}
	var chosen := Vector3.INF
	var total := 0.0
	var road_chosen := Vector3.INF
	var road_total := 0.0
	var index := 0
	while index < queue.size() and index < WANDER_LIMIT:
		if index % 128 == 0 and _cancelled(): return Vector3.INF
		var key := queue[index]; index += 1
		var pos := _point(key)
		var distance := Vector2(pos.x-from.x,pos.z-from.z).length()
		if distance >= 3.0 and (not home.is_finite() or Vector2(pos.x-home.x,pos.z-home.z).length()<=leash):
			var weight := _wander_weight(pos,from,radius,interest,context)
			var trail := float(_sample(key).get("trail",0.0))
			weight *= lerpf(1.0, 14.0, trail)
			total += weight
			var roll := rng.randf() if rng != null else randf()
			if roll*total < weight: chosen = pos
			if trail > .5:
				road_total += weight
				if roll*road_total < weight: road_chosen = pos
		for next in neighbors(key):
			if seen.has(next): continue
			seen[next] = true
			if Vector2(next.x-start.x,next.z-start.z).length()*WalkGrid.CELL <= radius: queue.append(next)
	# Once on a street, an unassigned stroll continues along it. Explicit visits
	# and hot spots may still leave the street, as may a pony starting off-road.
	if not interest.is_finite() and road_chosen.is_finite() and float(_sample(start).get("trail",0.0)) > .5:
		return road_chosen
	return chosen


func _wander_weight(pos: Vector3,from: Vector3,radius: float,interest: Vector3,context: Dictionary) -> float:
	# Prefer making use of the available radius, while reachability remains owned by
	# the component walk in wander(). Every multiplier has a positive floor.
	var distance := Vector2(pos.x-from.x,pos.z-from.z).length()
	var radial := clampf(distance/maxf(radius,WalkGrid.CELL),0.0,1.0)
	var weight := .35+1.65*radial*radial
	if interest.is_finite():
		var progress := (from.distance_to(interest)-pos.distance_to(interest))/maxf(radius,1.0)
		weight *= exp(clampf(progress*2.0,-1.2,1.6))
	for recent: Vector3 in context.get("recent",[]):
		var separation := Vector2(pos.x-recent.x,pos.z-recent.z).length()
		if separation < 4.0: weight *= lerpf(.12,1.0,separation/4.0)
	var heading: Vector3 = context.get("heading",Vector3.ZERO)
	var heading_xz := Vector2(heading.x,heading.z)
	var travel := Vector2(pos.x-from.x,pos.z-from.z)
	if heading_xz.length_squared()>.01 and travel.length_squared()>.01:
		# A mild forward preference avoids repetitive reversals without forcing a line.
		weight *= lerpf(.78,1.18,(heading_xz.normalized().dot(travel.normalized())+1.0)*.5)
	return maxf(weight,.001)

static func _push(heap: Array, value: Array) -> void:
	heap.append(value)
	var i := heap.size()-1
	while i > 0:
		var p := (i-1)/2
		if heap[p][0] <= value[0]: break
		heap[i] = heap[p]; i = p
	heap[i] = value

static func _pop(heap: Array) -> Array:
	var first: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty(): return first
	var i := 0
	while i*2+1 < heap.size():
		var child := i*2+1
		if child+1 < heap.size() and heap[child+1][0] < heap[child][0]: child += 1
		if last[0] <= heap[child][0]: break
		heap[i] = heap[child]; i = child
	heap[i] = last
	return first
