extends "res://world/life/day/actions/go_to.gd"
## A pony goes shopping (docs/MECHANICS_ARCHITECTURE_2026_11_01.md 10.3, P7): the day table's
## "buy" (and "buy_cider") step. She walks to the place like go_to.gd and, on arrival, buys from
## its stalls (world/mechanics/market/market.gd pony_buy: the first untaken thing she likes that her
## purse covers, else anything she can afford). The visible item leaves a loaded stall, the keeper
## keeps her bits, food is eaten (facts only) and anything else becomes her belonging, shown in her
## home. A "bought" fact with text lets nearby ponies talk about it. She leaves with her basket as
## before. A place without stalls is a plain outing. Target "job:cider_stand": a mug from the stand
## (when Anon staffs it she stays by it so his customer queue can take her). Unloaded, offscreen()
## buys facts-only: her purse and the keeper's, no stock change, no text.
const MARKET := preload("res://world/mechanics/market/market.gd")
const JOBS := preload("res://world/mechanics/jobs/jobs.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const WORK_JOB := preload("res://world/life/day/actions/work_job.gd")
const WITNESS_RANGE := 15.0
var purchase: Dictionary = {}   # what she bought ({} when nothing), for tests/debug

func place_point(ctx: Dictionary, target: String) -> Vector3:
	if target.begins_with("job:"): return WORK_JOB.job_point(ctx.tree, target)
	return super(ctx, target)

func tick(ctx: Dictionary, delta: float) -> String:
	var before := _phase
	var result := super(ctx, delta)
	if before == "travel" and _phase == "stay" and result == "running":
		var target := str(ctx.step.get("target", ""))
		# Anon runs the stand: she stays by it, free, so his customer queue can take her.
		if target.begins_with("job:") and WORK_JOB.player_working(ctx.tree, target.trim_prefix("job:")): return "done"
		purchase = buy(ctx.tree, str(ctx.id), ctx.step, false, witnesses(ctx), label(ctx.tree, target))
	return result

## The ponies within WITNESS_RANGE of her (her first), loaded bodies only.
static func witnesses(ctx: Dictionary) -> Array:
	var who: Array = [str(ctx.id)]
	var population: Variant = ctx.get("population")
	var live: Variant = (population as Node).get("live") if is_instance_valid(population) and population is Node else null
	var actor: Node3D = ctx.get("actor")
	if not live is Dictionary or not is_instance_valid(actor): return who
	for other: Variant in live:
		var entry: Variant = (live as Dictionary)[other]
		var body: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
		if str(other) != str(ctx.id) and is_instance_valid(body) and body is Node3D and (body as Node3D).is_inside_tree() \
				and (body as Node3D).global_position.distance_to(actor.global_position) <= WITNESS_RANGE:
			who.append(str(other))
	return who

## Her purchase for a step: the place's stalls (shops.json landmarks) or a job's stand.
static func buy(tree: SceneTree, pony: String, step: Dictionary, offscreen_only: bool, seen: Array = [], place := "") -> Dictionary:
	var target := str(step.get("target", ""))
	if target.begins_with("job:"): return buy_from_job(tree, pony, target.trim_prefix("job:"), offscreen_only, seen)
	var market: Node = MARKET.of(tree)
	var displays: Variant = MARKET.shops().landmarks.get(target, [])
	if market == null or not displays is Array or (displays as Array).is_empty(): return {}
	return market.pony_buy(pony, displays, offscreen_only, seen, place)

## A mug at an open stand, off-screen from its keeper (no queue): one serving from the stand keg,
## her bits to the till (whoever hired Anon today, else the first employer), a "bought" fact.
static func buy_from_job(tree: SceneTree, pony: String, job_id: String, offscreen_only: bool, seen: Array = []) -> Dictionary:
	var jobs: Node = JOBS.of(tree)
	var market: Node = MARKET.of(tree)
	if jobs == null or market == null or not bool(market.call("economy_on")) or not str(jobs.is_open(job_id)).is_empty(): return {}
	var row: Dictionary = jobs.spec(job_id)
	var price := int(row.get("price", 0)) if (row.get("price") is int or row.get("price") is float) else 0
	var employers: Array = row.get("employers", [])
	var seller: String = jobs.hired_by(job_id)
	if seller.is_empty() and not employers.is_empty(): seller = str(employers[0])
	if price <= 0 or seller.is_empty() or seller == pony or int(market.call("_ledger_purse", pony)) < price: return {}
	if not WORK_JOB.serve(tree, job_id): return {}
	if not str(market.call("_transfer", pony, seller, price, "sale", {})).is_empty(): return {}
	var item := WORK_JOB.KEG.MUG_FULL
	var text := "" if offscreen_only else "%s bought a mug of cider at the %s." % [pony.replace("_", " ").capitalize(), str(row.get("name", job_id.replace("_", " ")))]
	var facts: Node = FACTS.of(tree)
	if facts != null:
		facts.add("bought", {"actor": pony, "target": seller, "item": item, "count": 1, "amount": price, "ref": job_id}, text, seen if not text.is_empty() else [])
	return {"item": item, "price": price, "seller": seller, "display": job_id}

## Her essence went shopping while unloaded: facts only.
static func offscreen(ctx: Dictionary) -> void:
	buy(ctx.get("tree"), str(ctx.get("id", "")), ctx.get("step", {}), true)
