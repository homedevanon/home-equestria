extends RefCounted
## The shared shift clock and wage (P4 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md, section 7.4):
## duty counts game hours while the worker is really at the station (at most one hour per count, the
## Hayburger _count_duty rule), the wage is whole and part hours times the hourly rate up to a cap,
## and end() pays it once through the ledger with the receipt "job:<id>:<day>:<serial>". Duty is
## reset only when the wage was paid, so a failed save no longer loses the wage: it is paid with
## the next clock-out.
const LEDGER := preload("res://world/mechanics/ledger.gd")
const FACTS := preload("res://world/mechanics/facts.gd")
var job_id := ""
var duty_hours := 0.0
var _clock := -1.0

## Starts counting at `now_hours` (absolute game hours; negative = no clock). Unpaid duty is kept.
func start(job: String, now_hours: float) -> void:
	job_id = job
	_clock = now_hours

## Adds the game time since the last count when `working` (at most one hour per count, never past
## `max_hours`), then moves the count mark to now.
func count(now_hours: float, working: bool, max_hours: float) -> void:
	if working and now_hours >= 0.0 and _clock >= 0.0:
		duty_hours = minf(max_hours, duty_hours + clampf(now_hours - _clock, 0.0, 1.0))
	_clock = now_hours

func wage(per_hour: int, max_hours: float) -> int:
	return int(floor(clampf(duty_hours, 0.0, max_hours) * float(per_hour)))

## Pays wage(per_hour, max_hours) to Anon from the first payer that can (`payers`, e.g.
## ["business:hayburger", "town"]). `rate` is {"per_hour", "max_hours"}; `serial` (> 0) makes the receipt.
## Without a writable world (fixtures) the town pays without a receipt, as the old path did.
## {"paid": bool, "wage": int, "reason": String}; duty resets only when paid.
func end(game: Node, payers: Array, serial: int, rate := {"per_hour": 10, "max_hours": 14.0}) -> Dictionary:
	var amount := wage(int(rate.get("per_hour", 10)), float(rate.get("max_hours", 14.0)))
	if amount <= 0:
		duty_hours = 0.0
		return {"paid": true, "wage": 0, "reason": ""}
	var opts := {"payers": payers}
	var context: Node = game.get("world_context") as Node if is_instance_valid(game) else null
	# A receipt only with a real saved serial (> 0); serial 0 would make every same-day shift a duplicate.
	if serial > 0 and is_instance_valid(context) and not bool(context.get("_read_only")) and context.get("state") is Dictionary:
		opts["receipt"] = "job:%s:%d:%d" % [job_id, int(FACTS.clock().day), serial]
	elif "town" in payers:
		opts["payers"] = ["town"]
	var reason := LEDGER.transfer(game, str(payers[0]) if not payers.is_empty() else "town", "player", amount, "wage", opts)
	if reason.is_empty(): duty_hours = 0.0
	return {"paid": reason.is_empty(), "wage": amount, "reason": reason}
