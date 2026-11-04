extends RefCounted
## Serializable orchard ledger; no nodes, wallet calls or filesystem access.
const VERSION: int = 2
const REWARD: int = 20
## Baskets (trees) Applejack takes on per in-game day (dev 2026-10-26, player bug board #16: 20 bits
## a basket, six a day). Each tree row remembers the day it was started ("day", optional in older
## saves); an unfinished basket can always be finished.
const DAILY_BASKETS: int = 6
var trees: Dictionary = {}
var _committing: bool = false
## Today's basket limit and basket pay: DAILY_BASKETS and REWARD unless a town event changes them
## (apple_bucking.refresh() reads the town calendar's "daily_baskets" and "basket_pay" effects,
## world/mechanics/data/events.json Applebuck Season). Not saved: the snapshot is unchanged.
var daily_baskets: int = DAILY_BASKETS
var reward: int = REWARD

## Trees fruit from spring to autumn and stand bare in winter (dev 2026-10-28: a new game starts
## in spring, and autumn-only apples left the job empty for 40 in-game days). "cycle" is the day
## number, so every basket has its own receipt; "season" paces Applejack's invitation.
static func calendar(day: float, season_days: int) -> Dictionary:
	var length: int = maxi(1, season_days)
	var season: int = int(floor(maxf(day, 0.0) / length))
	var ripe: bool = season % 4 != 3
	return {"cycle": int(floor(maxf(day, 0.0))), "season": season, "ripe": ripe, "growth": 1.0 if ripe else 0.0}

## A picked tree grows a new crop in REGROW_DAYS. Older saves stored next autumn instead and no
## pick day; those trees bear again at once (at most two days early) rather than standing bare
## until next autumn.
const REGROW_DAYS: int = 2

static func regrown_day(row: Dictionary) -> int:
	if not row.has("day"): return 0
	return mini(int(row.get("next_ripe_day", 0)), int(row.day) + REGROW_DAYS)

func available(id: String, day: float, season_days: int) -> bool:
	var now: Dictionary = calendar(day, season_days)
	var prior: Dictionary = trees.get(id, {})
	# A crop started ripe. Keep its attached fruit harvestable after a season
	# change; calendar changes must not strand an unpaid partial harvest.
	if not prior.is_empty() and not prior.paid:
		return prior.released.size() < int(prior.count)
	if not now.ripe or baskets_on(day) >= daily_baskets: return false
	return prior.is_empty() or (prior.paid and int(prior.cycle) < int(now.cycle) and day >= float(regrown_day(prior)))

## Baskets started on this in-game day.
func baskets_on(day: float) -> int:
	var today: int = int(floor(maxf(day, 0.0)))
	var count: int = 0
	for row: Dictionary in trees.values():
		if int(row.get("day", -1)) == today: count += 1
	return count

func growth(id: String, day: float, season_days: int) -> float:
	var now: Dictionary = calendar(day, season_days)
	var prior: Dictionary = trees.get(id, {})
	if not prior.is_empty() and not prior.paid: return 1.0
	if prior.is_empty() or not now.ripe: return float(now.growth)
	var started: float = float(prior.get("day", regrown_day(prior) - REGROW_DAYS))
	return clampf((day - started) / float(maxi(1, regrown_day(prior) - int(started))), 0.0, 1.0)

func begin(id: String, count: int, day: float, season_days: int) -> bool:
	if _committing or id.is_empty() or count < 1 or count > 64 or not available(id, day, season_days): return false
	var prior: Dictionary = trees.get(id, {})
	if not prior.is_empty() and not prior.paid: return false
	var now: Dictionary = calendar(day, season_days)
	var today: int = int(floor(maxf(day, 0.0)))
	trees[id] = {"cycle": int(now.cycle), "count": count, "released": [], "collected": [], "paid": false,
		"next_ripe_day": today + REGROW_DAYS, "day": today}
	return true

## Stable original fruit indices, released exactly once by a certified strike.
func release_cluster(id: String, count: int) -> Array[int]:
	var indices: Array[int] = []
	if _committing or not trees.has(id) or count < 1 or count > 64: return indices
	var row: Dictionary = trees[id]
	if row.paid: return indices
	for index: int in remaining_canopy(id):
		row.released.append(index)
		indices.append(index)
		if indices.size() >= count: break
	return indices

func remaining_canopy(id: String) -> Array[int]:
	var indices: Array[int] = []
	var row: Dictionary = trees.get(id, {})
	if row.is_empty() or row.paid: return indices
	for index: int in int(row.count):
		if index not in row.released: indices.append(index)
	return indices

func collect(id: String, index: int) -> bool:
	if _committing or not is_outstanding(id, index): return false
	trees[id].collected.append(index)
	return true

## Frequent hand/provider checks need no temporary list of every loose index.
func is_outstanding(id: String, index: int) -> bool:
	var row: Dictionary = trees.get(id, {})
	return not row.is_empty() and not row.paid and index >= 0 and index < int(row.count) \
		and index in row.released and index not in row.collected

func outstanding(id: String) -> Array[int]:
	var indices: Array[int] = []
	var row: Dictionary = trees.get(id, {})
	if row.is_empty() or row.paid: return indices
	for index: int in row.released:
		if index not in row.collected: indices.append(index)
	return indices

func pending_payment(id: String) -> bool:
	var row: Dictionary = trees.get(id, {})
	return not row.is_empty() and not row.paid and row.collected.size() == int(row.count)

func receipt(id: String) -> String:
	return "apple-bucking:%s:%d" % [id, int(trees[id].cycle)] if trees.has(id) else ""

## Sink must durably commit BOTH proposed activity state and +20 bits, atomically.
## False leaves this ledger unpaid. Stable receipt supports retry after interruption.
func pay(id: String, sink: Callable, envelope: Dictionary) -> bool:
	if _committing or not pending_payment(id) or not sink.is_valid(): return false
	var proposed: Dictionary = snapshot()
	proposed.trees[id].paid = true
	var next: Dictionary = envelope.duplicate(true)
	next.ledger = proposed
	_committing = true
	var accepted: bool = sink.call(receipt(id), reward, next) == true
	_committing = false
	if accepted: trees[id].paid = true
	return accepted

func snapshot() -> Dictionary:
	return {"version": VERSION, "trees": trees.duplicate(true)}

static func valid(value: Variant) -> bool:
	if not value is Dictionary or (value.get("version") != 1 and value.get("version") != VERSION) or not value.get("trees") is Dictionary: return false
	if value.trees.size() > 1024: return false
	for id: Variant in value.trees:
		if not id is String or id.is_empty() or id.length() > 128: return false
		var row: Variant = value.trees[id]
		if not row is Dictionary or not row.get("paid") is bool or not row.get("collected") is Array: return false
		for key: String in ["cycle", "count", "next_ripe_day"]:
			var number: Variant = row.get(key)
			if not (number is int or number is float) or not is_finite(float(number)) or float(number) != floor(float(number)) or float(number) < 0: return false
		if row.count < 1 or row.count > 64 or row.cycle > 10000000 or row.next_ripe_day > 1000000000: return false
		if row.has("day"):
			var started: Variant = row.day
			if not (started is int or started is float) or not is_finite(float(started)) or float(started) != floor(float(started)) or float(started) < 0 or float(started) > 1000000000: return false
		var released: Dictionary = {}
		if value.version == VERSION:
			if not row.get("released") is Array: return false
			for index: Variant in row.released:
				if not (index is int or index is float) or not is_finite(float(index)) or float(index) != floor(float(index)): return false
				if index < 0 or index >= row.count or released.has(int(index)): return false
				released[int(index)] = true
		else:
			for index: int in int(row.count): released[index] = true
		var seen: Dictionary = {}
		for index: Variant in row.collected:
			if not (index is int or index is float) or not is_finite(float(index)) or float(index) != floor(float(index)): return false
			if index < 0 or index >= row.count or seen.has(int(index)) or not released.has(int(index)): return false
			seen[int(index)] = true
		if row.paid and seen.size() != int(row.count): return false
	return true

func restore(value: Variant) -> bool:
	if _committing or not valid(value): return false
	trees = value.trees.duplicate(true)
	# JSON numbers are floats; Array membership distinguishes them from ints.
	for id: String in trees:
		var row: Dictionary = trees[id]
		for key: String in ["cycle", "count", "next_ripe_day"]: row[key] = int(row[key])
		if row.has("day"): row.day = int(row.day)
		var indices: Array = []
		for index: Variant in row.collected: indices.append(int(index))
		row.collected = indices
		var released: Array = []
		if value.version == 1:
			for index: int in int(row.count): released.append(index)
		else:
			for index: Variant in row.released: released.append(int(index))
		row.released = released
	return true
