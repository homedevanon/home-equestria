extends Node3D
## The cider stand job (P5 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, 8.5): Applejack's cider
## stall at Sweet Apple Acres (shop_world placement "sweet-apple-acres:farm:cider") worked by Anon.
## Job row "cider_stand" in world/mechanics/data/jobs.json: open 10-18 during Cider Season, or on
## any non-winter day once Applejack or Big McIntosh hired him with [offer_job]. Everything here is
## the shared pieces put together:
##   - the stand is open for Anon while jobs.is_open("cider_stand") holds and he stands in the
##     2 x 2 m work zone behind the stall;
##   - customers are living residents leased through the shared CustomerQueue (customer_queue.gd,
##     owner "leisure:cider_stand:<id>"); each walks to a spot in front of the stall and orders with
##     a job ask (asks.create(..., "item:food:sweet-apple-acres-cider:1", "thanks", ..., "job"));
##   - Anon fills an empty mug at the stand keg (stand_keg.gd) and hands it to her mouth: the gift
##     gesture (hand_feeding.gd) makes her drink it and leaves him the empty mug; its "gave" fact
##     completes her order ask, whose "ask_done" fact makes the stand call
##     jobs.pay_unit("cider_stand", "player", ask_id, customer): 6 bits from her purse (else the town)
##     to the employer, 2 bits to Anon from Applejack (else Big Mac, else the town), a "worked" fact,
##     plus a "sold" fact with memory ("Anon sold Lyra a mug of cider at the stand.");
##   - the mug crate gives him an empty mug (hand_over.gd) at most twice a day.
## A customer waits PATIENCE_S, then her order is cancelled quietly and she goes back to her day.
## Ticks once a second; no per-frame work (the keg's VR tap check runs only while he works it).
const QUEUE := preload("res://world/mechanics/jobs/customer_queue.gd")
const KEG := preload("res://world/items/cider_keg.gd")
const LEDGER := preload("res://world/mechanics/ledger.gd")
const HAND_OVER := preload("res://world/mechanics/hand_over.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const STAND_KEG := preload("res://world/mechanics/stations/stand_keg.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
const JOB_ID := "cider_stand"
const DISPLAY_ID := "sweet-apple-acres:farm:cider"
const ORDER_WANT := "item:food:sweet-apple-acres-cider:1"
const OWNER_PREFIX := "leisure:cider_stand:"
const CUSTOMER_META := "job_customer"
const CRATE := "res://world/props/ponyville_kit/produce_crate.scn"
const TICK := 1.0
const PATIENCE_S := 300.0
const WALK_S := 120.0
const DRINK_S := 6.0
const CLOSE_GRACE_S := 20.0
const RECRUIT_EVERY_S := 12.0
const ORDER_HOURS := 2.0
const MUGS_PER_DAY := 2
const ARRIVE := 1.6
## Stall-local layout (+z faces the lane, where customers stand; Anon works on the -z side).
const ZONE_CENTER := Vector3(0.0, 0.0, -1.0)
const ZONE_HALF := Vector2(1.0, 1.0)
const KEG_AT := Vector3(1.25, 0.0, -0.65)
const CRATE_AT := Vector3(-1.2, 0.0, -0.65)
const SPOTS := [Vector3(0.0, 0.0, 1.5), Vector3(-1.1, 0.0, 2.3), Vector3(1.1, 0.0, 2.3)]

## The mug crate: a station node (station_input.gd) that hands Anon an empty mug.
class Crate extends Node3D:
	var stand: Node3D
	var station_id := "cider_stall"
	func station_hint(ui: Node, side: String) -> Dictionary: return stand.crate_hint(ui, side) if is_instance_valid(stand) else {}
	func station_use(ui: Node, side: String, down: bool) -> bool: return stand.crate_use(ui, side, down) if is_instance_valid(stand) else false

var game: Node
var jobs: Node
var stations: Node
var asks: Node
var facts: Node
var population: Node   # optional (tests); else game.population
var life: Node         # optional (tests); else game.life
var keg: Node3D
var crate: Crate
var queue: RefCounted
var visits: Dictionary = {}   # pony id -> {"actor", "spot", "phase", "order", "until", "label"}
var _timer: Timer
var _placed := false
var _last_working := -INF
var _told_day := -1
var _next_recruit := 0.0
var _subscribed: Node
## work_job.gd (WP8) finds the stand through group "mechanics_job_nodes" and this id.
var job_id := JOB_ID

func _ready() -> void:
	name = "CiderStand"
	add_to_group("mechanics_job_nodes")
	queue = QUEUE.new()
	var spec: Dictionary = jobs.spec(JOB_ID).get("customers", {}) if is_instance_valid(jobs) else {}
	queue.setup(_population(), _life(), spec)
	queue.owner_prefix = OWNER_PREFIX
	if is_instance_valid(jobs):
		var employers: Variant = jobs.spec(JOB_ID).get("employers", [])
		if employers is Array:
			for id: Variant in employers: queue.exclude.append(str(id))
	if is_instance_valid(game) and game.has_method("_population_busy"): queue.busy_check = Callable(game, "_population_busy")
	keg = STAND_KEG.new(); keg.stand = self; keg.position = KEG_AT
	add_child(keg)
	crate = Crate.new(); crate.name = "MugCrate"; crate.stand = self; crate.position = CRATE_AT
	add_child(crate)
	crate.add_to_group("mechanics_station_nodes")
	var box: Node3D = (load(CRATE) as PackedScene).instantiate() as Node3D
	if box != null:
		box.scale = Vector3.ONE * 0.55; crate.add_child(box)
	_timer = Timer.new(); _timer.wait_time = TICK; _timer.autostart = true
	_timer.timeout.connect(tick)
	add_child(_timer)
	_subscribe()
	place()

func _subscribe() -> void:
	if not is_instance_valid(facts) or _subscribed == facts or not facts.has_method("subscribe"): return
	_subscribed = facts
	facts.subscribe(PackedStringArray(["ask_done"]), _on_ask_done)

func _population() -> Node:
	if is_instance_valid(population): return population
	return game.get("population") as Node if is_instance_valid(game) and is_instance_valid(game.get("population")) else null

func _life() -> Node:
	if is_instance_valid(life): return life
	return game.get("life") as Node if is_instance_valid(game) and is_instance_valid(game.get("life")) else null

func _ui() -> Node:
	var found: Variant = game.get("inventory") if is_instance_valid(game) else null
	return found as Node if found is Node and is_instance_valid(found) else null

## Lines the stand up with the cider stall display (its table top is 0.9 m above the ground).
func place() -> bool:
	var shop: Variant = game.get("shop_world") if is_instance_valid(game) else null
	var displays: Variant = (shop as Node).get("_displays") if shop is Node and is_instance_valid(shop) else null
	var display: Variant = (displays as Dictionary).get(DISPLAY_ID) if displays is Dictionary else null
	if not display is Node3D or not is_instance_valid(display) or not (display as Node3D).is_inside_tree(): return false
	var top: Transform3D = (display as Node3D).global_transform
	global_transform = Transform3D(Basis(Vector3.UP, top.basis.get_euler().y), top.origin - Vector3.UP * 0.9)
	_placed = true
	return true

func _today() -> int:
	return int(FACTS.clock().day)

# --- Working ------------------------------------------------------------------------------------

func _anon() -> Vector3:
	var ui := _ui()
	var camera: Variant = ui.get("camera") if ui != null else null
	return (camera as Node3D).global_position if camera is Node3D and is_instance_valid(camera) else Vector3.INF

## Anon stands in the work zone behind the stall.
func in_zone(at: Vector3) -> bool:
	if not at.is_finite() or not _placed: return false
	var local := global_transform.affine_inverse() * at
	return absf(local.x - ZONE_CENTER.x) <= ZONE_HALF.x and absf(local.z - ZONE_CENTER.z) <= ZONE_HALF.y and local.y > -1.0 and local.y < 2.6

## The stand is open for Anon now: the job is open and he is behind the stall.
func working() -> bool:
	return is_instance_valid(jobs) and str(jobs.is_open(JOB_ID)).is_empty() and in_zone(_anon())

# --- WP8 contract (world/life/day/actions/work_job.gd) ----------------------------------------------

## Where a pony worker stands: the middle of the work zone behind the stall. INF before placing.
func job_work_point() -> Vector3:
	return global_transform * ZONE_CENTER if _placed else Vector3.INF

## Anon is working the stand, so a pony worker steps aside.
func player_working() -> bool:
	return working()

## One serving for a pony worker's sale, from the same stand keg Anon pours from.
func serve_one() -> bool:
	return is_instance_valid(keg) and bool(keg.call("serve_one"))

func tick() -> void:
	if not _placed and not place(): return
	_subscribe()
	queue.tick(TICK)
	if is_instance_valid(keg): keg.call("refill_check")
	var on := working()
	if is_instance_valid(keg): keg.call("watch", on)
	if on:
		_last_working = queue.clock
		if _told_day != _today():
			_told_day = _today()
			var ui := _ui()
			if ui != null: LEDGER.say(ui, "Cider stand: fill mugs at the keg and hand them to customers.")
		if queue.clock >= _next_recruit and visits.size() < int(queue.max_customers):
			_next_recruit = queue.clock + RECRUIT_EVERY_S
			_recruit()
	elif not visits.is_empty() and queue.clock - _last_working > CLOSE_GRACE_S:
		close("The stand closed")
	_update_visits()

func _spot(index: int) -> Vector3:
	return global_transform * (SPOTS[index % SPOTS.size()] as Vector3)

func _free_spot() -> int:
	var used := {}
	for id: String in visits: used[int(visits[id].spot)] = true
	for index: int in SPOTS.size():
		if not used.has(index): return index
	return -1

func _recruit() -> void:
	var spot := _free_spot()
	if spot < 0: return
	queue.population = _population(); queue.life = _life()
	for id: String in queue.candidates(global_position, 1):
		var actor := _actor(id)
		if actor == null: continue
		if not queue.claim(id, actor, {CUSTOMER_META: JOB_ID}): continue
		var nav: Node = actor.get_node_or_null("Navigator")
		if nav == null or not bool(nav.call("command_destination", _spot(spot), "walk")):
			queue.release(id, "Navigator refused destination")
			continue
		visits[id] = {"actor": actor, "spot": spot, "phase": "walk", "order": "", "until": queue.clock + WALK_S, "label": null}
		return

func _actor(id: String) -> Node3D:
	var people := _population()
	var live: Variant = people.get("live") if people != null else null
	var entry: Variant = (live as Dictionary).get(id) if live is Dictionary else null
	var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
	return actor as Node3D if is_instance_valid(actor) and actor is Node3D else null

func _update_visits() -> void:
	for id: String in visits.keys():
		var visit: Dictionary = visits[id]
		var actor: Node3D = visit.actor as Node3D if is_instance_valid(visit.get("actor")) else null
		# Her own [sit], [stand] or [approach] reply tag while Anon chats with her took her navigator
		# and ended the order (private #336): the lease takes it back and she carries on.
		if actor != null and not queue.owns(id) and queue.reclaim(id):
			print("[cider stand] %s keeps her place: a reply tag had taken her navigation" % id)
			if not _resume(id, visit, actor): continue
		if actor == null or not queue.owns(id):
			_end(id, "Left the stand"); continue
		match str(visit.phase):
			"walk":
				var nav: Node = actor.get_node_or_null("Navigator")
				var at := _spot(int(visit.spot))
				if Vector2(actor.global_position.x - at.x, actor.global_position.z - at.z).length() <= ARRIVE:
					if nav != null:
						nav.call("stay")
						if "face_point" in nav: nav.set("face_point", global_position + Vector3.UP * 0.9)
					_order(id)
				elif queue.clock > float(visit.until):
					_end(id, "Could not reach the stand")
			"wait":
				if queue.clock > float(visit.until): _end(id, "Waited too long")
				else: _label(id, "Cider, please")
			"drink":
				if queue.clock > float(visit.until): _end(id, "Drank her cider")

## After a reclaim: walking, she sets off for her spot again; waiting or drinking, she stands
## facing the stall. False when the visit ended.
func _resume(id: String, visit: Dictionary, actor: Node3D) -> bool:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return true
	if str(visit.phase) == "walk":
		if not bool(nav.call("command_destination", _spot(int(visit.spot)), "walk")):
			_end(id, "Navigator refused destination")
			return false
		return true
	if actor.has_method("posture_status") and actor.has_method("request_posture"):
		var status: Dictionary = actor.call("posture_status")
		if str(status.get("kind", "stand")) not in ["stand", ""] or str(status.get("requested", "stand")) != "stand": actor.call("request_posture", "stand")
	if "face_point" in nav: nav.set("face_point", global_position + Vector3.UP * 0.9)
	return true

## She reached her spot: her order is a job ask (no cap, no prompt line, no notebook page).
func _order(id: String) -> void:
	var visit: Dictionary = visits[id]
	if not is_instance_valid(asks): _end(id, "No orders"); return
	var made: Dictionary = asks.create(id, ORDER_WANT, "thanks", "a mug of cider", "job", ORDER_HOURS)
	if not bool(made.get("ok", false)): _end(id, str(made.get("error", "No order"))); return
	visit.order = str(made.id)
	visit.phase = "wait"
	visit.until = queue.clock + PATIENCE_S
	_label(id, "Cider, please")

## Her order ask completed (Anon handed her a full mug and she drank it): the job pays.
func _on_ask_done(fact: Dictionary) -> void:
	var ref := str(fact.get("ref", ""))
	for id: String in visits:
		var visit: Dictionary = visits[id]
		if str(visit.order) != ref or str(visit.phase) != "wait": continue
		serve(id)
		return

## Pays the served order (once, by its ask id) and lets her drink a moment before she leaves.
func serve(id: String) -> String:
	var visit: Dictionary = visits.get(id, {})
	if visit.is_empty() or str(visit.order).is_empty(): return "No order"
	var order := str(visit.order)
	var wage: int = int(jobs.unit_amount(jobs.spec(JOB_ID)))
	var reason: String = jobs.pay_unit(JOB_ID, "player", order, id, -1, {"item": KEG.MUG_FULL, "pony": visit.actor,
		"say": "Sold a mug of cider · +%d bits" % wage})
	if reason.is_empty():
		var price := int(jobs.spec(JOB_ID).get("price", 0))
		var text := "Anon sold %s a mug of cider at the stand." % _name(id)
		if is_instance_valid(facts):
			facts.add("sold", {"actor": "player", "target": id, "item": KEG.MUG_FULL, "count": 1, "amount": price, "ref": JOB_ID,
				"key": "sold:" + order}, text, [id, "player"])
	visit.phase = "drink"
	visit.until = queue.clock + DRINK_S
	_label(id, "")
	return reason

func _name(id: String) -> String:
	var director: Variant = game.get("director") if is_instance_valid(game) else null
	var characters: Variant = (director as Node).get("characters") if is_instance_valid(director) else null
	var entry: Variant = (characters as Dictionary).get(id) if characters is Dictionary else null
	var profile: Variant = (entry as Dictionary).get("profile") if entry is Dictionary else null
	return str((profile as Dictionary).get("name", id)) if profile is Dictionary else id.replace("_", " ").capitalize()

func _label(id: String, text: String) -> void:
	var visit: Dictionary = visits.get(id, {})
	if visit.is_empty(): return
	var label: Variant = visit.get("label")
	if text.is_empty():
		if is_instance_valid(label): (label as Node).queue_free()
		visit.label = null
		return
	if not is_instance_valid(label):
		var made := Label3D.new()
		made.name = "Order_" + id
		made.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		made.pixel_size = 0.003; made.font_size = 36; made.outline_size = 8
		made.modulate = Color("fff4dc"); made.outline_modulate = Color("3a2414")
		made.top_level = true
		add_child(made)
		label = made
		visit.label = made
	(label as Label3D).text = text
	var actor: Node3D = visit.actor as Node3D if is_instance_valid(visit.get("actor")) else null
	if actor != null: (label as Label3D).global_position = actor.global_position + Vector3.UP * 1.9

## Ends one visit: an open order is cancelled quietly, the label goes and she gets her day back.
func _end(id: String, reason: String) -> void:
	var visit: Dictionary = visits.get(id, {})
	visits.erase(id)
	if not visit.is_empty():
		if is_instance_valid(visit.get("label")): (visit.label as Node).queue_free()
		if str(visit.get("phase", "")) == "wait" and not str(visit.get("order", "")).is_empty() and is_instance_valid(asks):
			asks.cancel(str(visit.order), reason)
	queue.release(id, reason)

## Every customer goes back to her day (the stand closed, the node is leaving).
func close(reason: String) -> void:
	for id: String in visits.keys(): _end(id, reason)

func _exit_tree() -> void:
	close("The stand closed")

# --- Mug crate ----------------------------------------------------------------------------------

func _mugs_today() -> int:
	var saved: Variant = (jobs.call("_read") as Dictionary).get("cider_stand_mugs") if is_instance_valid(jobs) else null
	if not saved is Dictionary or int((saved as Dictionary).get("day", -1)) != _today(): return 0
	return clampi(int((saved as Dictionary).get("n", 0)), 0, MUGS_PER_DAY)

func can_take_mug() -> String:
	if not working(): return "Applejack's mug crate"
	if _mugs_today() >= MUGS_PER_DAY: return "No more spare mugs today"
	if not is_instance_valid(jobs) or not bool(jobs.call("_writable")): return "Not right now"
	return ""

## One empty mug from the crate into a free hand (else the briefcase); at most MUGS_PER_DAY a day.
func give_mug(ui: Node, side := "") -> String:
	var why := can_take_mug()
	if not why.is_empty(): return why
	var went := HAND_OVER.give_to_anon(ui, KEG.MUG_EMPTY, "" if side == "desktop" else side)
	if went.is_empty(): return "No room for a mug"
	var block: Dictionary = jobs.call("_block")
	block["cider_stand_mugs"] = {"day": _today(), "n": _mugs_today() + 1}
	(jobs.get("context") as Node).call("_changed")
	return ""

func crate_hint(ui: Node, side: String) -> Dictionary:
	var point := crate.global_position + Vector3.UP * 0.6
	if side == "desktop":
		if not HELD.looking_at(ui, point, 0.45, 3.0): return {}
	else:
		var at := HELD.point(ui, side)
		if not at.is_finite() or at.distance_to(point) > 0.5: return {}
	if not working(): return {}
	var why := can_take_mug()
	if not HELD.id(ui, side).is_empty() and why.is_empty(): return {}
	var text := ("Grip · Take an empty mug" if side != "desktop" else "Click · Take an empty mug") if why.is_empty() else why
	return {"target": crate, "text": text, "point": point + Vector3.UP * 0.2, "outline": crate.get_child(0) if crate.get_child_count() > 0 else null}

func crate_use(ui: Node, side: String, down: bool) -> bool:
	if not down: return false
	var point := crate.global_position + Vector3.UP * 0.6
	if side == "desktop":
		if not HELD.looking_at(ui, point, 0.45, 3.0) or not HELD.id(ui, side).is_empty(): return false
	else:
		var at := HELD.point(ui, side)
		if not at.is_finite() or at.distance_to(point) > 0.5: return false
	return give_mug(ui, side).is_empty()
