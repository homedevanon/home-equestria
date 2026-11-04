extends "res://world/life/day/day_action.gd"
## A pony works a job (world/mechanics/jobs/jobs.gd; docs/MECHANICS_ARCHITECTURE_2026_11_01.md
## 10.3, P7): Applejack or Big McIntosh runs the cider stand when Anon does not. Target
## "job:<id>". She walks to the stand and stands behind it; every 30 game minutes she makes one sale
## to a resident who can pay (deterministic pick), served from the stand keg, paid through the one
## unit pay call (jobs.pay_unit: the customer pays the till, a worker other than the first payer gets the unit wage). She
## skips the step, or steps aside, while Anon works the stand. Unloaded, offscreen() makes the same
## sales without a body.
const JOBS := preload("res://world/mechanics/jobs/jobs.gd")
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
const MARKET := preload("res://world/mechanics/market/market.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const KEG := preload("res://world/items/cider_keg.gd")
## Job nodes (P5's cider stand) join this group with a `job_id`; optional methods:
## job_work_point() -> Vector3, player_working() -> bool, serve_one() -> bool.
const NODE_GROUP := "mechanics_job_nodes"
const SALE_MINUTES := 30.0
const STAND := "cider_stand"
var _job := ""
var _point := Vector3.INF
var _phase := "travel"
var _stay := 60.0
var _every := 60.0
var _tries := 0
var _sales := 0
var reason := ""   # why it failed, for tests/debug

static func job_node(tree: SceneTree, job_id: String) -> Node:
	if tree == null: return null
	for node: Node in tree.get_nodes_in_group(NODE_GROUP):
		if str(node.get("job_id")) == job_id: return node
	return null

## Anon is working this job's station now (the stand node says so); false without a node.
static func player_working(tree: SceneTree, job_id: String) -> bool:
	var node := job_node(tree, job_id)
	return node != null and node.has_method("player_working") and bool(node.call("player_working"))

## Where the job's worker stands: the job node's job_work_point(), else the row's "where" (ground
## height from the terrain), else its station's work point. INF when unknown.
static func job_point(tree: SceneTree, target: String) -> Vector3:
	var id := target.trim_prefix("job:")
	var node := job_node(tree, id)
	if node != null and node.has_method("job_work_point"):
		var at: Variant = node.call("job_work_point")
		if at is Vector3 and (at as Vector3).is_finite(): return at
	var jobs: Node = JOBS.of(tree)
	var row: Dictionary = jobs.spec(id) if jobs != null else {}
	var where: Variant = row.get("where")
	if where is Dictionary and (where as Dictionary).get("world") is Array and ((where as Dictionary).world as Array).size() == 3:
		var w: Array = (where as Dictionary).world
		var point := Vector3(float(w[0]), float(w[1]), float(w[2]))
		if bool((where as Dictionary).get("ground", false)) and is_instance_valid(WorldTerrain.instance):
			var height: float = WorldTerrain.instance.height_at(point)
			if is_finite(height): point.y = height
		return point
	var stations: Node = STATIONS.of(tree)
	var station := str(row.get("station", ""))
	if stations != null and not station.is_empty() and not stations.spec(station).is_empty(): return stations.work_point(station)
	return Vector3.INF

## "" when `pony` may work the job now: she is one of its employers, it is open and Anon is not at it.
static func can_work(tree: SceneTree, job_id: String, pony: String) -> String:
	var jobs: Node = JOBS.of(tree)
	if jobs == null or jobs.spec(job_id).is_empty(): return "No such work"
	var employers: Variant = jobs.spec(job_id).get("employers", [])
	if not employers is Array or not pony in (employers as Array): return "Not her work"
	var why: String = jobs.is_open(job_id)
	if not why.is_empty(): return why
	if player_working(tree, job_id): return "Anon is working it"
	return ""

## One serving from the stand: the stand node's serve_one() when it exists, else the saved stand
## keg (state.jobs.cider_stand_keg = {"day", "servings"}): a new day in an event that opens the
## stand fills it free, otherwise a pressed keg from the stand's supply refills it (8 mugs). Jobs
## without stock always serve.
static func serve(tree: SceneTree, job_id: String) -> bool:
	if job_id != STAND: return true
	var node := job_node(tree, job_id)
	if node != null and node.has_method("serve_one"): return bool(node.call("serve_one"))
	var jobs: Node = JOBS.of(tree)
	if jobs == null or not bool(jobs.call("_writable")): return false
	var block: Dictionary = jobs.call("_block")
	var keg: Dictionary = block.get("cider_stand_keg") if block.get("cider_stand_keg") is Dictionary else {}
	var today := int(FACTS.clock().day)
	var servings: int = int(keg.get("servings", 0)) if (keg.get("servings") is int or keg.get("servings") is float) else 0
	var keg_day: int = int(keg.get("day")) if (keg.get("day") is int or keg.get("day") is float) else -1
	if keg_day != today:
		keg["day"] = today
		var event := str((jobs.spec(job_id).get("open", {}) as Dictionary).get("event", "")) if jobs.spec(job_id).get("open") is Dictionary else ""
		if servings <= 0 and not event.is_empty() and bool(jobs.call("_event_active", event)): servings = KEG.SERVINGS
	var stations: Node = STATIONS.of(tree)
	if servings <= 0 and stations != null and stations.take_supply(job_id, KEG.ID, 1): servings = KEG.SERVINGS
	if servings <= 0:
		keg["servings"] = 0; block["cider_stand_keg"] = keg
		return false
	keg["servings"] = servings - 1
	block["cider_stand_keg"] = keg
	(jobs.get("context") as Node).call("_changed")
	return true

## A resident who can pay `price`, picked by `seed` (never the worker or the job's employers).
static func pick_buyer(tree: SceneTree, job_id: String, worker: String, price: int, seed: String) -> String:
	var market: Node = MARKET.of(tree)
	var jobs: Node = JOBS.of(tree)
	if market == null or jobs == null: return ""
	var people: Array[String] = market.residents()
	if people.is_empty(): return ""
	var employers: Array = jobs.spec(job_id).get("employers", [])
	var start := absi(hash(seed)) % people.size()
	for step: int in people.size():
		var who := people[(start + step) % people.size()]
		if who == worker or who in employers: continue
		if int(market.call("_ledger_purse", who)) >= price: return who
	return ""

## One sale at the job by `pony`: a serving, a buyer, the unit pay (receipt by `ref`) and a "sold"
## fact. False when there is no cider, no buyer or the pay was refused.
static func sell_one(tree: SceneTree, job_id: String, pony: String, ref: String) -> bool:
	var jobs: Node = JOBS.of(tree)
	if jobs == null: return false
	var row: Dictionary = jobs.spec(job_id)
	var price := int(row.get("price", 0)) if (row.get("price") is int or row.get("price") is float) else 0
	# A replayed sale (a reload restarts the running shift with the same refs) or a full day's work
	# never takes another serving: pay_unit would refuse or skip it after the cider was poured.
	var host: Variant = jobs.get("game")
	if not (host is Node and is_instance_valid(host)): host = jobs.call("_host")
	var receipt := "job:%s:%d:%s" % [job_id, int(jobs.call("_today")), ref]
	if host is Node and (JOBS.LEDGER.receipt_done(host, receipt) or JOBS.LEDGER.receipt_done(host, receipt + ":sale")): return false
	var cap: Variant = row.get("daily_cap")
	if (cap is int or cap is float) and int(cap) > 0 and int(jobs.units_today(job_id, pony)) >= int(cap): return false
	var buyer := pick_buyer(tree, job_id, pony, price, "%s:%s" % [job_id, ref])
	if buyer.is_empty() or not serve(tree, job_id): return false
	# The stand's first payer (Applejack) takes no wage from herself; Big Mac gets the unit wage from
	# her. The customer pays the till either way.
	var payers: Variant = row.get("payers", [])
	var own: bool = payers is Array and not (payers as Array).is_empty() and str((payers as Array)[0]) == pony
	var why: String = jobs.pay_unit(job_id, pony, ref, buyer, 0 if own else -1, {"item": KEG.MUG_FULL})
	if not why.is_empty(): return false
	var facts: Node = FACTS.of(tree)
	if facts != null:
		facts.add("sold", {"actor": pony, "target": buyer, "item": KEG.MUG_FULL, "count": 1, "amount": price, "ref": job_id, "key": "sold:%s:%s" % [job_id, ref]})
	return true

func start(ctx: Dictionary) -> bool:
	_job = str(ctx.step.get("target", "")).trim_prefix("job:")
	reason = can_work(ctx.tree, _job, str(ctx.id))
	if not reason.is_empty(): return false
	_point = job_point(ctx.tree, "job:" + _job)
	if not _point.is_finite(): reason = "Nowhere to go"; return false
	claim(ctx)
	_stay = duration(float(ctx.step.get("minutes", 60.0)))
	_every = duration(SALE_MINUTES)
	var far: bool = ctx.actor.global_position.distance_to(_point) > 40.0
	ctx.nav.go_to(_point, ctx.nav.Gait.TROT if far else ctx.nav.Gait.WALK)
	return true

func tick(ctx: Dictionary, delta: float) -> String:
	seconds += delta
	var nav: Node = ctx.nav
	match _phase:
		"travel":
			if arrived(ctx, _point, 2.0) or nav.state == nav.State.ARRIVED:
				nav.stay()
				var node := job_node(ctx.tree, _job)
				if node is Node3D: nav.face_point = (node as Node3D).global_position
				_phase = "work"; seconds = 0.0
				return "running"
			if nav.state in [nav.State.UNREACHABLE, nav.State.BLOCKED]:
				_tries += 1
				if _tries > 2: reason = "Could not reach it"; return "failed"
				nav.go_to(_point, nav.Gait.WALK)
			elif not nav._has_target and seconds > 3.0:
				nav.go_to(_point, nav.Gait.WALK)
			if seconds > 300.0: reason = "Could not reach it"; return "failed"
		"work":
			# Anon took the stand over: she steps aside (the shift so far still counts).
			if player_working(ctx.tree, _job): return "done"
			if seconds >= float(_sales + 1) * _every and float(_sales + 1) * _every <= _stay:
				sell_one(ctx.tree, _job, str(ctx.id), "%s:%d" % [str(ctx.get("step_key", "")), _sales])
				_sales += 1
			if seconds >= _stay: return "done"
	return "running"

## Her essence worked the shift while unloaded: the same sales without a body.
static func offscreen(ctx: Dictionary) -> void:
	var tree: SceneTree = ctx.get("tree")
	var step: Dictionary = ctx.get("step", {})
	var job := str(step.get("target", "")).trim_prefix("job:")
	var pony := str(ctx.get("id", ""))
	if not can_work(tree, job, pony).is_empty(): return
	var count := maxi(1, int(float(step.get("minutes", 60.0)) / SALE_MINUTES))
	var key := "%s:%d:%s" % [pony, int(ctx.get("day", -1)), str(step.get("start", ""))]
	for n: int in count:
		sell_one(tree, job, pony, "%s:o%d" % [key, n])
