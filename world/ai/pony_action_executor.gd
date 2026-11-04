extends Node
## One movement intention plus one gaze intention. Navigator/locomotion own physics.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
## Following ends only when the companion stays this far away and she is not closing in.
const FOLLOW_LOST_DISTANCE := 30.0
const FOLLOW_LOST_SECONDS := 12.0
## A lead waits longer for him than a follow: he may stop to look at something on the way.
const LEAD_LOST_SECONDS := 30.0
## Anon within this many metres walks with her on a model's go_to: she keeps his pace.
const COMPANION_RANGE := 14.0
## A failed go_to/lead tries again: the same point once the grid has sampled more, then open
## ground nearer to her, before she gives up and says so.
const ROUTE_RETRIES := 3
const NO_RETRY := ["Bakery is busy", "cannot fit", "needs a flight", "not finite"]
const MEET_TIME := preload("res://world/life/appointments/meet_time.gd")
signal outcome(event: Dictionary)
var actor: Node3D
var navigator: Node
var movement: Dictionary = {}
var gaze: Dictionary = {}
var recent: Array[Dictionary] = []
var _seen: Dictionary = {}
var _latest_turn := -1
var _tick := 0.0
var _paused := false
var _last_goal := Vector3.INF
var _last_target := Vector3.INF
var _follow_heading := Vector3.ZERO
var _waiting_for_follower := false
var _idle_route_seconds := 0.0
var _progress := Vector3.INF
var _retry_wait := 0.0
var _target_speed := 0.0
var _target_velocity := Vector3.ZERO
var _holding_formation := false
var _formation_side := ""
var _follow_lost_seconds := 0.0
var _follow_best_gap := INF
var _follow_route := -1
var _follow_route_progress := 0.0
var _companion_last := Vector3.INF
var _companion_velocity := Vector3.ZERO
var coordinator: Node
var character_id := ""

func bind(pony: Node3D) -> void:
	actor = pony
	navigator = actor.get_node_or_null("Navigator")
	if is_instance_valid(navigator):
		navigator.arrived.connect(_arrived)
		navigator.route_failed.connect(_route_failed)
	set_physics_process(false)

## wake_up(): out of her night's sleep (night_rest.gd), or up out of a bed or off a couch. The
## bed or couch notices its hold on her navigator is gone and lets her go.
func _wake_actor() -> bool:
	var id := str(actor.identity.id) if actor.get("identity") != null else str(actor.get_meta("relationship_id", ""))
	var rest: Node = get_tree().get_first_node_in_group("night_rest")
	if rest != null and rest.has_method("wake_up") and rest.wake_up(id): return true
	var owner := str(navigator.command_owner) if is_instance_valid(navigator) else ""
	var resting: bool = actor.get("sleeping") == true or owner.begins_with("leisure:") or actor.get_meta("cuddle_active", false)
	if not resting and actor.posture_status().requested not in ["lie_down", "sit"]: return false
	actor.sleeping = false
	if is_instance_valid(navigator) and owner.begins_with("leisure:"):
		navigator.stay(); navigator.command_owner = ""
	actor.request_posture("stand")
	return true

func _appointments() -> Node:
	return get_tree().get_first_node_in_group("appointments") if is_inside_tree() else null

func _pony_id() -> String:
	return character_id if not character_id.is_empty() else str(actor.get_meta("relationship_id", ""))

func _wardrobe() -> Node:
	return actor.get_tree().get_first_node_in_group("pony_wardrobe") if is_instance_valid(actor) and actor.is_inside_tree() else null

func capabilities() -> Array:
	var result: Array = []
	if not is_instance_valid(actor): return result
	if actor.has_method("set_action_gaze"): result.append("look_at")
	if is_instance_valid(navigator) and navigator.has_method("command_destination"):
		if actor.has_method("request_posture"): result.append_array(["sit", "stand", "lie_down", "sit_on_seat", "wake_up"])
		result.append_array(["approach", "follow", "go_to", "step", "lead", "stay", "resume_routine"])
	if actor.has_method("request_flight") and actor.identity.has_wings() and bool(actor.identity.get("can_fly")):
		result.append_array(["fly_to","hover","land","loop_de_loop","barrel_roll","circle_over","air_show"])
		if str(actor.identity.id) == "rainbow_dash": result.append("sonic_rainboom")
	if is_instance_valid(navigator) and (_sky_home() != null or _home_house() != null): result.append("go_home")
	# Her own bed (or her cloud nap); [go_to_bed: here] is checked when it runs (thread report 2026-11-03).
	if is_instance_valid(navigator) and actor.has_method("request_posture") and (_sky_home() != null or _home_house() != null): result.append("go_to_bed")
	if actor.has_method("send_letter"): result.append("send_letter")
	# Trixie may call her own stage show when Anon has paid for one or her week's rest is over.
	if actor.get("identity") != null and str(actor.identity.id) == "trixie":
		var show := _trixie_show()
		if show != null and show.ai_start(true): result.append("magic_show")
	# Clothes she wears or took off (pony_wardrobe.gd set_worn); offered only when there is any.
	var wardrobe := _wardrobe()
	if wardrobe != null and actor.get("identity") != null:
		var id := str(actor.identity.id)
		if not wardrobe.wanted(id, wardrobe._season()).is_empty(): result.append("take_off")
		if not (wardrobe.taken_off().get(id, []) as Array).is_empty(): result.append("put_on")
	if not result.is_empty(): result.append("cancel")
	if actor.has_meta("relationship_runtime"): result.append_array(["relationship_offer","relationship_answer","agreed","request_space","buck_player","cuddle"])
	if actor.has_meta("relationship_runtime"):
		var runtime: Node = actor.get_meta("relationship_runtime")
		if runtime.can_kiss_player(str(actor.get_meta("relationship_id", ""))): result.append("kiss_player")
		# Agreed meetings with Anon (world/life/appointments/appointments.gd).
		var appointments := _appointments()
		if appointments != null:
			result.append("meet")
			if not appointments.open_for(_pony_id()).is_empty(): result.append("meet_cancel")
	return result

## ai_origin: requested by the model (pony_action_coordinator.gd commit), not a story script.
func submit(actions: Array, targets: Dictionary, turn: int, ai_origin := false) -> void:
	if turn < _latest_turn: return
	_latest_turn = turn
	for source: Dictionary in actions:
		var request_key:=str(turn)+"/"+str(source.id)
		if _seen.has(request_key): continue
		_seen[request_key] = true
		# Old turns are rejected separately; retain recent IDs as replay protection.
		if _seen.size() > 256: _seen.erase(_seen.keys()[0])
		var action := source.duplicate(true)
		if action.type == "stay":
			# Story callers share this executor. They also receive a bounded hold.
			action.duration_s = clampf(float(action.get("duration_s", 30.0)), 0.5, 600.0)
			action.erase("until_cancel")
		if action.has("target_id"):
			var target: Variant = targets.get(action.target_id)
			if not is_instance_valid(target): _report(action, "failed", "Target disappeared"); continue
			action["target"] = weakref(target)
		action["remaining"] = float(action.get("duration_s", INF))
		action["ai"] = ai_origin
		# A model's go_to with Anon nearby is a walk together: she keeps his pace.
		if action.type == "go_to" and ai_origin and is_instance_valid(targets.get("player")): action["companion"] = weakref(targets.player)
		# [go_to_bed: here]: the bed in the house where Anon is, found when it runs.
		if action.type == "go_to_bed" and is_instance_valid(targets.get("player")): action["anon"] = weakref(targets.player)
		if action.type == "step":
			var stepped := _step_goal(str(action.get("direction", "aside")), float(action.get("distance_m", 1.5)), targets.get("player"))
			if not stepped.is_finite(): _report(action, "failed", "No room to step that way"); continue
			action["step_goal"] = stepped
			# A short shuffle, bounded like every other move.
			action["remaining"] = 20.0; action["duration_s"] = 20.0
		# Riding in the balloon (balloon.gd pauses this executor's physics): postures apply at
		# once; walking or flying waits until it lands.
		if actor.has_meta("balloon_passenger"):
			if action.type in ["sit", "stand", "lie_down"]:
				var posed: bool = actor.request_posture(action.type)
				_report(action, "completed" if posed else "failed", "Posture while riding" if posed else str(actor.posture_status().refusal))
				continue
			if action.type in ["call_pony", "send_pony", "approach", "follow", "go_to", "step", "lead", "stay", "sit_on_seat", "fly_to", "hover", "land", "loop_de_loop", "barrel_roll", "circle_over", "sonic_rainboom", "air_show", "magic_show", "go_home", "go_to_bed", "resume_routine", "use"]:
				_report(action, "failed", "Riding in the balloon; that waits until it lands")
				continue
		match action.type:
			"teleport_to_ponyville":
				if is_instance_valid(coordinator): coordinator.dispatch_arrival(character_id, action)
				else: _report(action, "failed", "Arrival story coordinator unavailable")
			"call_pony", "send_pony":
				if is_instance_valid(coordinator): coordinator.dispatch_pony(character_id, action, targets, turn)
				else: _report(action, "failed", "Pony request coordinator unavailable")
			"relationship_offer", "relationship_answer", "agreed", "request_space", "buck_player", "cuddle", "kiss_player":
				var runtime: Node=(actor.get_meta("relationship_runtime") if actor.has_meta("relationship_runtime") else null)
				if is_instance_valid(runtime):
					runtime.stage(str(actor.get_meta("relationship_id","")),source,turn,self)
					_report(action,"accepted","Waiting for spoken offer or answer to finish")
			"cancel":
				var found := false
				var runtime: Node = actor.get_meta("relationship_runtime") if actor.has_meta("relationship_runtime") else null
				if runtime != null: found = runtime.cancel_kiss_action(str(actor.get_meta("relationship_id", "")), str(action.action_id))
				if gaze.get("id") == action.action_id: _end_gaze("cancelled", "Cancelled by request"); found = true
				# [cancel] in a tag reply names no action: it stops whatever she is doing.
				if movement.get("id") == action.action_id or (action.action_id == "current" and not movement.is_empty()): _end_move("cancelled", "Cancelled by request"); found = true
				_report(action, "completed" if found else "failed", "Cancellation applied" if found else "That action is not active")
			"meet", "meet_cancel":
				# Commits at once and moves nopony: her day plan walks her there on the day.
				var appointments := _appointments()
				if appointments == null: _report(action, "failed", "Meetings unavailable"); continue
				if action.type == "meet":
					var made: Dictionary = appointments.propose(_pony_id(), str(action.get("location_id", "")), str(action.get("day", "today")), str(action.get("time", "")), "speech:%d" % turn)
					var row: Dictionary = made.get("row", {})
					_report(action, "completed" if bool(made.get("ok", false)) else "failed",
						"Meeting agreed: %s, day %d at %s" % [str(row.get("place_label", "")), int(row.get("day", 0)), MEET_TIME.clock_text(float(row.get("hour", 0.0)))] if bool(made.get("ok", false)) else str(made.get("error", "Meeting not possible")))
				else:
					var called_off: bool = appointments.cancel(_pony_id(), "speech:%d" % turn)
					_report(action, "completed" if called_off else "failed", "Meeting called off" if called_off else "You have no meeting with Anon to call off")
			"send_letter":
				var sent: bool = actor.send_letter()
				_report(action, "completed" if sent else "failed", "Letter written and sent to Princess Celestia" if sent else "Busy; cannot write a letter right now")
			"magic_show":
				var show := _trixie_show()
				var started: bool = show != null and show.ai_start()
				_report(action, "completed" if started else "failed", "Show called: fireworks over the schoolhouse stage, curtain in about three minutes" if started else "No stage show possible right now")
			"take_off", "put_on":
				var wardrobe := _wardrobe()
				var on: bool = action.type == "put_on"
				var changed: String = wardrobe.set_worn(str(actor.identity.id), str(action.kind), on) if wardrobe != null else ""
				if not changed.is_empty(): wardrobe.dress(actor, str(actor.identity.id), wardrobe._season())
				_report(action, "completed" if not changed.is_empty() else "failed",
					("Now wearing " if on else "Took off ") + changed if not changed.is_empty() else ("You have nothing like that put away" if on else "You are not wearing that"))
			"pay_player":
				if is_instance_valid(coordinator): coordinator.dispatch_pay(character_id, action)
				else: _report(action, "failed", "Payment coordinator unavailable")
			"give", "ask", "offer_job", "use", "invite", "sell", "buy":
				# [use] walks her to a station through her day card (stations.gd request_use): an earlier
				# model move lets go of her navigator first, as [resume_routine] does.
				if action.type == "use":
					_end_move("cancelled", "Off to work a station", true)
					# A finished move or posture leaves "rest_after_command", which no day step may
					# take over (day_runner._free): she is let go as [resume_routine] does.
					if is_instance_valid(navigator) and str(navigator.command_owner) == "rest_after_command":
						if actor.has_method("request_posture"): actor.request_posture("stand")
						_release(true)
				# Shared mechanics (world/mechanics/mechanics.gd dispatch); the game validates it again.
				if is_instance_valid(coordinator): coordinator.dispatch_mechanic(character_id, action)
				else: _report(action, "failed", "Unavailable")
			"give_house":
				if is_instance_valid(coordinator): coordinator.dispatch_house(character_id, action)
				else: _report(action, "failed", "House grant coordinator unavailable")
			"wake_up":
				var woke := _wake_actor()
				_report(action, "completed" if woke else "failed", "Awake and getting up" if woke else "Not asleep, in bed or on a couch")
			"resume_routine":
				var runtime: Node = actor.get_meta("relationship_runtime") if actor.has_meta("relationship_runtime") else null
				if runtime != null: runtime.cancel_kiss_action(str(actor.get_meta("relationship_id", "")))
				if actor.has_method("request_posture"): actor.request_posture("stand")
				_end_move("cancelled", "Returned to routine")
				_release(true)
				_report(action, "completed", "Routine ownership restored")
			"look_at":
				_end_gaze("cancelled", "Replaced by another gaze")
				gaze = action
				_report(gaze, "accepted", "Gaze accepted")
			_:
				# Reaffirming the same walk must not stop her or reset travel heading to gaze.
				if action.type == "follow" and movement.get("type") == "follow" and movement.get("target_id") == action.get("target_id") and navigator.command_owner == movement.id:
					movement = action
					navigator.command_owner = action.id
					_report(movement, "accepted", "Continuing existing follow")
					continue
				_end_move("cancelled", "Replaced by another movement intention")
				movement = action
				actor.set_meta("active_follow", action.type == "follow")
				_last_goal = Vector3.INF; _last_target = Vector3.INF; _follow_heading = Vector3.ZERO; _target_speed = 0.0
				_target_velocity = Vector3.ZERO; _holding_formation = false; _formation_side = ""
				_progress = actor.global_position; _idle_route_seconds = 0.0
				_follow_lost_seconds = 0.0; _follow_best_gap = INF
				_follow_route = -1; _follow_route_progress = 0.0
				_companion_last = Vector3.INF; _companion_velocity = Vector3.ZERO
				_paused = false; _waiting_for_follower = false; _retry_wait = 0.0
				navigator.command_owner = action.id
				if str(navigator.command_owner) != str(action.id):
					_report(movement, "failed", "Movement ownership refused; existing route retained")
					movement = {}; actor.remove_meta("active_follow")
					continue
				navigator.command_speed_limit = INF
				if "command_pace_target" in navigator: navigator.command_pace_target = -1.0
				navigator.stay()
				_report(movement, "accepted", "Movement accepted")
	set_physics_process(not movement.is_empty() or not gaze.is_empty())
	_tick = 0.0

func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("action_executor", started)

func _physics_step(delta: float) -> void:
	if not is_instance_valid(actor): queue_free(); return
	_tick += delta
	if _tick < .2: return
	var dt := _tick; _tick = 0.0
	_retry_wait = maxf(0.0, _retry_wait - dt)
	if not gaze.is_empty():
		var target: Variant = gaze.target.get_ref()
		if not is_instance_valid(target): _end_gaze("failed", "Gaze target disappeared")
		else:
			var interrupted: bool = actor.has_method("action_interruption_reason") and actor.action_interruption_reason() != ""
			actor.set_action_gaze(null if interrupted else target)
			gaze.remaining -= dt
			_report(gaze, "blocked" if interrupted else "running", "Physical contact owns the head" if interrupted else "Looking toward target; speech gaze takes priority")
			if gaze.remaining <= 0: _end_gaze("completed", "Gaze duration finished")
	if movement.is_empty():
		set_physics_process(not gaze.is_empty()); return
	if not is_instance_valid(navigator): _end_move("failed", "Navigator unavailable"); return
	if str(navigator.command_owner) != str(movement.id):
		_end_move("cancelled", "Movement superseded by another owner"); return
	var target: Node3D = null
	if movement.has("target"):
		target = movement.target.get_ref()
		if not is_instance_valid(target) or not target.is_inside_tree(): _end_move("failed", "Target disappeared"); return
	var interruption: String = actor.action_interruption_reason() if actor.has_method("action_interruption_reason") else ""
	# Holding is bounded in elapsed time, including being picked up. A takeover by the story
	# ends our hold without touching its new route; the story remains the authoritative owner.
	if movement.type == "stay":
		movement.remaining -= dt
		if movement.remaining <= 0:
			_end_move("completed", "Stay duration finished", true); return
	elif movement.has("duration_s"):
		movement.remaining -= dt
		if movement.remaining <= 0:
			_end_move("failed", "Movement request timed out", true); return
	# Gentle touch can continue while accepting a resting posture; carry/flight and
	# other physical owners still block it through their existing reasons.
	var resting_touch: bool = movement.type in ["sit","lie_down"] and interruption == "Physical interaction" and actor.get("_interaction") == "PETTING"
	if interruption != "" and not resting_touch:
		if not _paused: navigator.stay(); _last_goal = Vector3.INF
		_paused = true
		_report(movement, "blocked", interruption + "; intention retained")
		return
	_paused = false
	# go_home (dev 2026-09-25): a sky home (Rainbow Dash's Cloudominium) hands her to NightRest,
	# which flies her up to rest a few minutes and brings her back down; everyone else walks to
	# the inside of her own house as an ordinary go_to. Once its walk-in interior is built that is
	# Dash's own house too: house travel flies her up to its door (dev 2026-09-28).
	if movement.type == "go_home" and not movement.has("home_goal"):
		var rest := _sky_home()
		if rest != null:
			var action := movement.duplicate()
			_end_move("completed", "Heading home to her cloud to rest a while")
			if not rest.send_home(str(actor.identity.id)): _report(action, "failed", "Could not get home to her cloud right now")
			return
		var house := _home_house()
		if house == null: _end_move("failed", "No home to go to"); return
		# The room itself, like any go_to to a house (place_directory resolve(): house travel takes the
		# door). inside() is only the first point through the doorway; going there left her standing
		# in her own doorway with the trip never confirmed (2026-10-24, tools/fluttershy/route_probe.gd).
		movement.home_goal = house.center()
	# go_to_bed (thread report 2026-11-03: "lay down in your bed" got "Fine, five minutes" and she never
	# moved): NightRest walks her to the bed, climbs her in and keeps her lying there (night_rest.gd
	# send_to_bed). Without a walk-in sky home it is her cloud nap, as for go_home.
	if movement.type == "go_to_bed":
		var action := movement.duplicate()
		var bed := _bed_for(action)
		var rest: Node = get_tree().get_first_node_in_group("night_rest")
		if bed.has("error") or rest == null:
			_end_move("failed", str(bed.get("error", "Bedtime is unavailable"))); return
		_end_move("completed", "Heading to bed: " + str(bed.label))
		var pony := str(actor.identity.id)
		var sent: bool = rest.send_home(pony) if bed.get("house") == null else rest.send_to_bed(pony, bed.house, str(bed.key))
		if not sent: _report(action, "failed", "Could not get to that bed right now")
		return
	if movement.type in ["fly_to","hover","land","loop_de_loop","barrel_roll","circle_over","sonic_rainboom","air_show"]:
		if not movement.get("flight_started",false):
			if movement.type == "air_show":
				var status: Dictionary = actor.posture_status()
				if status.kind != "stand" or not status.settled:
					actor.request_posture("stand"); return
				# Over whoever she performs for (the player unless a target is named).
				var audience: Variant = movement.get("target").get_ref() if movement.get("target") is WeakRef else null
				var centre: Vector3 = (audience as Node3D).global_position if audience is Node3D else actor.global_position
				var moves: Array = movement.get("moves", [])
				if not actor.has_method("request_show") or not actor.request_show(moves, centre):
					_end_move("failed", str(actor.flight.reason) if actor.get("flight") != null and str(actor.flight.reason) != "" else "No open sky for an air show"); return
			elif movement.type == "land":
				if actor.flight != null: actor.flight.land()
			elif movement.type in ["loop_de_loop","barrel_roll","circle_over","sonic_rainboom"]:
				var status: Dictionary = actor.posture_status()
				if status.kind != "stand" or not status.settled:
					actor.request_posture("stand"); return
				var trick: String = {"loop_de_loop":"loop","barrel_roll":"barrel_roll","circle_over":"circle","sonic_rainboom":"rainboom"}[movement.type]
				var centre := Vector3.INF
				if movement.type == "circle_over":
					var circled: Variant = movement.get("target").get_ref() if movement.get("target") is WeakRef else null
					if not is_instance_valid(circled): _end_move("failed","Nobody there to circle"); return
					centre = (circled as Node3D).global_position
				var started: bool = actor.request_trick(trick, centre) if actor.has_method("request_trick") else actor.request_fun_flight()
				if not started:
					_end_move("failed", str(actor.flight.reason) if actor.get("flight") != null and str(actor.flight.reason) != "" else "No open sky nearby for that trick"); return
			else:
				var status: Dictionary = actor.posture_status()
				if status.kind != "stand" or not status.settled:
					actor.request_posture("stand"); return
				var destination: Vector3 = navigator.command_location(movement.location_id) if movement.type == "fly_to" else actor.global_position
				if not actor.request_flight(destination,float(movement.get("duration_s",0.0)),movement.type == "fly_to"):
					_end_move("failed",actor.flight.reason); return
			movement.flight_started = true
		if actor.flight == null or not actor.flight.active(): _end_move("completed","Landed safely")
		else: _report(movement,"running","Flight: " + actor.flight.state)
		return
	if actor.get("flight") != null and actor.flight.active():
		# Ask once. land() re-plans from her current heading each call, so asking every tick kept
		# moving the touchdown spot ahead of her: she flew low loops and never landed (dev 2026-10-29).
		if not movement.get("land_asked", false):
			movement.land_asked = true
			actor.flight.land()
		_report(movement,"blocked","Landing before ground movement")
		return
	if movement.type == "sit_on_seat":
		var seating: Node = get_tree().get_first_node_in_group("pony_seating")
		if not movement.get("seat_started", false):
			if seating == null or not seating.sit(actor, 30.0): _end_move("failed", "No free bench or seat nearby"); return
			movement.seat_started = true
		var seat_phase: String = seating.phase(actor) if seating != null else ""
		if seat_phase == "seated" and actor.posture_status().settled: _end_move("completed", "Sitting on the seat")
		elif seat_phase == "": _end_move("failed", "Could not reach the seat")
		else: _report(movement, "running", "Going to sit on the seat")
		return
	if movement.type in ["sit","stand","lie_down"]:
		var status: Dictionary=actor.posture_status()
		if status.requested!=movement.type:
			if not actor.request_posture(movement.type):
				var why: String=actor.posture_status().refusal
				if why=="Wait until stopped": _report(movement,"blocked",why)
				else: _end_move("failed",why)
				return
		status=actor.posture_status()
		if movement.type in ["sit","lie_down"] and actor.get("posture") != null:
			actor.posture.intentional_rest = true
		if status.settled and status.kind==movement.type: _end_move("completed","Posture reached: "+movement.type)
		elif status.refusal!="": _end_move("failed",status.refusal)
		else: _report(movement,"running","Changing posture")
		return
	if actor.has_method("posture_status") and movement.type!="stay":
		var status: Dictionary=actor.posture_status()
		if status.kind!="stand" or not status.settled:
			actor.request_posture("stand")
			_report(movement,"blocked","Standing before walking")
			return
	if movement.type == "stay":
		_report(movement, "running", "Remaining nearby")
		return
	var goal := Vector3.INF
	var pace := str(movement.get("pace", "walk"))
	if movement.type == "go_home":
		goal = movement.home_goal
		if "command_pace_target" in navigator: navigator.command_pace_target = travel_pace(goal, null, dt)
	elif movement.type == "step":
		goal = movement.step_goal
		if _flat(actor.global_position, goal) < .35: _end_move("completed", "Stepped " + str(movement.direction)); return
	elif movement.type in ["go_to", "lead"]:
		goal = movement.alt_goal if movement.has("alt_goal") else navigator.command_location(movement.location_id)
		if not goal.is_finite(): _end_move("failed", "Mapped destination is no longer available"); return
		var companion: Node3D = target
		if movement.type == "go_to" and movement.get("companion") is WeakRef:
			companion = (movement.companion as WeakRef).get_ref() as Node3D
			if companion != null and (not companion.is_inside_tree() or _flat(companion.global_position, actor.global_position) > COMPANION_RANGE): companion = null
		if movement.type == "lead":
			var distance := actor.global_position.distance_to(target.global_position)
			var wait_limit: float = movement.wait_distance_m
			# Wait only for a follower left behind; one walking ahead toward the place (he
			# knows the way) is caught up with, not waited for (dev 2026-10-15, Derpy).
			var behind := _flat(target.global_position, goal) > _flat(actor.global_position, goal) - 1.0
			# Only his walking off ends a lead before arrival: left far behind and not coming
			# back for a while (no goodbye or routine ends it, director_holds.gd).
			var gap := _flat(actor.global_position, target.global_position)
			var returning := gap < _follow_best_gap - .5
			if gap <= FOLLOW_LOST_DISTANCE or returning: _follow_best_gap = gap
			_follow_lost_seconds = _follow_lost_seconds + dt if behind and gap > FOLLOW_LOST_DISTANCE and not returning else 0.0
			if _follow_lost_seconds >= LEAD_LOST_SECONDS:
				_end_move("cancelled", "Follower left walking range", true); return
			if behind and (distance > wait_limit or (_waiting_for_follower and distance > wait_limit * .7)):
				if not _waiting_for_follower: navigator.stay(); _last_goal = Vector3.INF
				_waiting_for_follower = true
				_companion_last = Vector3.INF
				_report(movement, "blocked", "Waiting for follower to catch up")
				return
			_waiting_for_follower = false
		# -1 hands the speed back to the navigator's own band for this gait.
		if "command_pace_target" in navigator: navigator.command_pace_target = travel_pace(goal, companion, dt)
	else:
		var target_floor: Vector3 = navigator.command_target_floor(target.global_position)
		if movement.type == "follow":
			# Far behind but closing in (galloping after a fast walker) is still following.
			var far := _flat(actor.global_position, target.global_position)
			var closing := far < _follow_best_gap - .5
			if far <= FOLLOW_LOST_DISTANCE or closing: _follow_best_gap = far
			# A real route around water or toward a bridge can initially lead away from
			# him. Forward progress along its accepted corridor is still catching up;
			# a stopped pony, a new plan or an unsupported target earns no extension.
			var advancing := _follow_route_advanced()
			var lost := not target_floor.is_finite() or (far > FOLLOW_LOST_DISTANCE and not closing and not advancing)
			_follow_lost_seconds = _follow_lost_seconds + dt if lost else 0.0
			if _follow_lost_seconds >= FOLLOW_LOST_SECONDS:
				_end_move("cancelled", "Companion left walking range", true); return
		if not target_floor.is_finite():
			if movement.type == "follow":
				navigator.stay(); _last_goal = Vector3.INF
				_report(movement, "blocked", "Waiting for target ground support; following retained")
				return
			_end_move("failed", "No verified floor beneath target"); return
		var displacement := Vector3.ZERO if not _last_target.is_finite() else target.global_position - _last_target
		displacement.y = 0
		# Smoothed horizontal speed of the target: head bob and tracking jitter must not
		# flicker the follower between gaits.
		# Smooth the velocity VECTOR: summing absolute sway distances invents
		# forward speed and rotates the formation left/right around a resting leader.
		var velocity := displacement / maxf(dt, 0.001) if displacement.length() < 2.0 else Vector3.ZERO
		_target_velocity = _target_velocity.lerp(velocity, 1.0 - exp(-dt / 0.45))
		_target_speed = _target_velocity.length()
		var speed := _target_speed
		_last_target = target.global_position
		if _follow_heading.length_squared() < .01:
			_follow_heading = -actor.global_basis.z; _follow_heading.y = 0
			_follow_heading = _follow_heading.normalized() if _follow_heading.length_squared() > .01 else Vector3.FORWARD
		elif speed > .3 and displacement.length() < 2.0:
			var heading := _follow_heading.signed_angle_to(_target_velocity.normalized(), Vector3.UP)
			_follow_heading = _follow_heading.rotated(Vector3.UP, clampf(heading, -1.8 * dt, 1.8 * dt))
		# Travel direction, not HMD turns/bobbing, owns an established formation.
		var formation_frame := Transform3D(Basis.looking_at(_follow_heading, Vector3.UP), target.global_position)
		var separation: float = movement.distance_m
		if movement.type == "follow" and str(movement.formation) == "behind_far":
			separation = follow_separation(separation, speed, actor)
		if movement.type == "approach":
			var offset := actor.global_position - target.global_position; offset.y = 0
			if offset.length() <= separation + .25 and absf(actor.global_position.y - target_floor.y) < .65 and navigator.command_target_visible(target):
				_end_move("completed", "Reached comfortable distance"); return
			goal = target.global_position + offset.normalized() * separation
		else:
			var formation: String = str(movement.formation)
			if formation in ["loose", "behind"]:
				if _formation_side.is_empty():
					_formation_side = "right" if (actor.global_position - target.global_position).dot(formation_frame.basis.x) >= 0 else "left"
				formation = _formation_side
			goal = formation_point(formation_frame, formation, separation, actor.global_position)
			# Walk with the leader, not after them: lead the slot by part of a second of
			# their motion so she is already where they are heading (dev, 2026-09-15).
			if movement.type == "follow" and speed > .4:
				goal += _follow_heading * minf(speed * .35, 1.4)
		goal.y = target_floor.y
		var projected: Vector3 = navigator.command_support(goal)
		if not projected.is_finite() and movement.type == "follow":
			# A side slot against a wall falls back behind the leader. The planner still
			# resolves the actual corridor; no direct velocity through the obstacle.
			goal = formation_point(formation_frame, "behind_far", separation, actor.global_position)
			goal.y = target_floor.y
			projected = navigator.command_support(goal)
		if projected.is_finite(): goal = projected
		if navigator.has_method("command_follow_goal"):goal=navigator.command_follow_goal(goal,target.global_position)
		var gap := _flat(actor.global_position, goal)
		var walk_top: float = actor.profile.walk_speed.y if "profile" in actor else .5
		var ceiling: float = actor.profile.max_travel_speed if "profile" in actor else 4.5
		var gain: float = navigator.follow_gain if "follow_gain" in navigator else .65
		pace = "trot" if speed > walk_top * .8 or gap > 4.0 else "walk"
		# A scripted gentle approach (world/life/arrival_story.gd; not offered to the AI): she
		# walks the whole way instead of trotting up (dev 2026-10-01).
		var gentle: bool = movement.type == "approach" and str(movement.get("pace", "")) == "walk" and movement.has("pace")
		# The target's measured speed plus formation error, capped by the calibrated
		# ceiling; the navigator adds braking, turns and route ends, the controller
		# picks trot or gallop from the resulting request.
		var limit := clampf(speed + maxf(0.0, gap - .25) * gain, .15, ceiling)
		# Never close on the leader faster than the controller can stop short of them.
		var braking: float = actor.profile.braking if "profile" in actor else 3.5
		var leader_gap := _flat(actor.global_position, target.global_position)
		var to_leader := target.global_position - actor.global_position; to_leader.y = 0.0
		var leader_ahead: float = to_leader.normalized().dot(-actor.global_basis.z) if to_leader.length() > .1 else 0.0
		# Only a leader in front of her limits the closing speed; beside or behind, the
		# side slot keeps her clear on its own.
		if leader_ahead > .6: limit = minf(limit, sqrt(2.0 * braking * maxf(0.0, leader_gap - .6)))
		if gentle: pace = "walk"; limit = minf(limit, walk_top)
		navigator.command_speed_limit = maxf(limit, .15)
		if "command_target_speed" in navigator: navigator.command_target_speed = speed
		if "command_target_velocity" in navigator: navigator.command_target_velocity = _follow_heading * speed
		if "command_pace_target" in navigator:
			navigator.command_pace_target = navigator.command_speed_limit
		var comfortable := gap < (1.1 if _holding_formation else .7)
		_holding_formation = movement.type == "follow" and comfortable and speed < .3 and absf(actor.global_position.y - goal.y) < .65
		if _holding_formation:
			if _last_goal.is_finite(): navigator.stay(); _last_goal = Vector3.INF
			_report(movement, "running", "Holding formation")
			_idle_route_seconds = 0.0
			return
	if _flat(actor.global_position, _progress) > .2:
		_progress = actor.global_position; _idle_route_seconds = 0.0
	else: _idle_route_seconds += dt
	if _idle_route_seconds > 45.0:
		if movement.type=="follow":
			_idle_route_seconds=0.0;_last_goal=Vector3.INF
			_report(movement,"blocked","Waiting for a safe route; following retained")
		else:_end_move("failed", "No route progress for 45 seconds"); return
	var refresh_distance := .6 if movement.type == "follow" else .75
	if _retry_wait <= 0.0 and (not _last_goal.is_finite() or _flat(goal, _last_goal) > refresh_distance):
		if navigator.command_destination(goal, pace, movement.type == "follow" or _last_goal.is_finite()): _last_goal = goal
	if not movement.is_empty(): _report(movement, "running", "Travelling; arrival is not yet confirmed")


func _follow_route_advanced() -> bool:
	if not navigator.has_method("command_follow_progress"): return false
	var sample: Vector2 = navigator.command_follow_progress()
	var route := int(sample.x)
	if route < 0:
		_follow_route = -1
		return false
	if route != _follow_route:
		_follow_route = route
		_follow_route_progress = sample.y
		return false
	if sample.y <= _follow_route_progress + .5: return false
	_follow_route_progress = sample.y
	return true

## Travel speed for go_to/lead in m/s, or -1 to keep the navigator's own band. A model's "walk"
## outdoors is the everyday stroll (the slow trot, dev 2026-10-14), not the 0.3 m/s four-beat walk
## that crawled Derpy to Sugarcube Corner (dev 2026-10-15); scripted story walks keep theirs. With a
## companion beside or behind her she matches his measured speed, faster when he presses close;
## with him ahead toward the place she catches up, up to the calibrated gallop ceiling.
func travel_pace(goal: Vector3, companion: Node3D, dt: float) -> float:
	var profile: Variant = actor.get("profile")
	var trot_floor: float = profile.trot_speed.x if profile != null else 2.2
	var walk_top: float = profile.walk_speed.y if profile != null else .36
	var ceiling: float = profile.max_travel_speed if profile != null else 4.5
	var travel: Variant = navigator.get("house_travel")
	var indoors: bool = travel != null and travel.has_method("here") and travel.here(actor) != null
	var pace := -1.0
	if movement.get("ai", false):
		pace = walk_top if indoors else trot_floor * (1.2 if str(movement.get("pace", "walk")) == "trot" else .7)
		# Nobody holds one exact speed: her own slow drift of a few percent (dev 2026-10-31).
		if not indoors: pace *= 1.0 + .07 * sin(Time.get_ticks_msec() * .00021 + float(absi(hash(String(actor.name))) % 628) * .01)
	if companion == null or indoors:
		_companion_last = Vector3.INF
		return pace
	var moved := Vector3.ZERO if not _companion_last.is_finite() else companion.global_position - _companion_last
	moved.y = 0.0
	_companion_last = companion.global_position
	var velocity := moved / maxf(dt, .001) if moved.length() < 3.0 else Vector3.ZERO
	_companion_velocity = _companion_velocity.lerp(velocity, 1.0 - exp(-dt / .45))
	var speed := _companion_velocity.length()
	var gap := _flat(actor.global_position, companion.global_position)
	var gain: float = navigator.follow_gain if "follow_gain" in navigator else .65
	var ahead := _flat(companion.global_position, goal) < _flat(actor.global_position, goal) - 1.0
	if speed < .3 and not ahead: return pace
	var matched := speed + (gap * gain if ahead else maxf(0.0, 2.5 - gap) * gain)
	return clampf(maxf(pace, matched), .15, ceiling)

## Following distance grows with the leader's speed by part of the stopping distance,
## so a leader who stops dead is never walked into; at rest it is the requested gap.
static func follow_separation(distance: float, leader_speed: float, actor: Node) -> float:
	var braking: float = actor.profile.braking if "profile" in actor else 3.5
	return distance + leader_speed * leader_speed / (2.0 * braking) * 0.6


## Slots are beside the leader and a little ahead, inside their view, facing the way
## they walk (dev, 2026-09-15). "behind" and "loose" pick whichever side she is already
## on; "behind_far" is the old trailing slot for leading/marching.
static func formation_point(frame: Transform3D, formation: String, distance: float, follower: Vector3) -> Vector3:
	var forward := -frame.basis.z; forward.y = 0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var lateral := clampf(distance, 1.0, 2.5)
	const AHEAD := .45
	match formation:
		"left": return frame.origin - right * lateral + forward * AHEAD
		"right": return frame.origin + right * lateral + forward * AHEAD
		"behind_far": return frame.origin - forward * distance
	var side := 1.0 if (follower - frame.origin).dot(right) >= 0 else -1.0
	return frame.origin + right * lateral * side + forward * AHEAD

## A short move relative to her own body, or out of the player's way (dev 2026-10-06: a pony
## blocking a doorway should move aside). Checked for floor and a clear line; the navigator
## still plans the actual steps.
func _step_goal(direction: String, distance: float, player: Variant) -> Vector3:
	if not is_instance_valid(navigator) or not navigator.has_method("command_support"): return Vector3.INF
	var forward: Vector3 = -actor.global_basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > .01 else Vector3.FORWARD
	var right: Vector3 = forward.cross(Vector3.UP)
	var away := Vector3.ZERO
	if player is Node3D and is_instance_valid(player):
		away = actor.global_position - (player as Node3D).global_position
		away.y = 0.0
	var options: Array[Vector3] = []
	match direction:
		"forward": options = [forward]
		"back": options = [-forward]
		"left": options = [-right]
		"right": options = [right]
		"away": options = [away.normalized() if away.length() > .1 else -forward]
		_:
			# Across the line between her and the player, so she leaves their path; either side.
			var across: Vector3 = away.cross(Vector3.UP).normalized() if away.length() > .1 else right
			options = [across, -across, -forward]
	var chest := Vector3.UP * .5
	var space := actor.get_world_3d().direct_space_state
	for way: Vector3 in options:
		for scale: float in [1.0, .6]:
			var projected: Vector3 = navigator.command_support(actor.global_position + way * distance * scale)
			if not projected.is_finite() or _flat(projected, actor.global_position) < .5: continue
			var ray := PhysicsRayQueryParameters3D.create(actor.global_position + chest, projected + chest, 1 | 2, [actor.get_rid()])
			if space.intersect_ray(ray).is_empty(): return projected
	return Vector3.INF

static func _flat(a: Vector3, b: Vector3) -> float: return Vector2(a.x - b.x, a.z - b.z).length()

func _arrived() -> void:
	if movement.is_empty(): return
	if movement.type in ["go_to", "lead", "step"]: _end_move("completed", "Navigator confirmed arrival" + (" as close as the paths allow" if movement.has("alt_goal") else ""))
	elif movement.type == "go_home": _end_move("completed", "Home: navigator confirmed arrival")
	elif movement.type == "follow": _last_goal = Vector3.INF
	# Approach checks distance to the target, not just arrival at a snapped waypoint.

func _route_failed(reason: String) -> void:
	if movement.get("type") == "follow":
		_last_goal = Vector3.INF; _retry_wait = 1.0
		_report(movement, "blocked", reason + "; will retry following")
		return
	if movement.is_empty(): return
	var tries := int(movement.get("retries", 0))
	# go_home retries too: a first search can run out of budget on unsampled ground and the trip
	# home failed outright (2026-10-24 route probe). It keeps its own goal (no named place).
	if movement.type in ["go_to", "lead", "go_home"] and tries < ROUTE_RETRIES and NO_RETRY.all(func(word: String) -> bool: return not (word in reason)):
		movement.retries = tries + 1
		var nearer := _nearer_goal(tries + 1) if movement.has("location_id") else Vector3.INF
		if nearer.is_finite(): movement.alt_goal = nearer
		_last_goal = Vector3.INF; _retry_wait = 1.5
		_report(movement, "blocked", reason + "; trying another way there")
		return
	_end_move("failed", reason)

## Open ground short of the destination on her side of it, further out on each try. The first
## retry keeps the destination itself: its grid may simply not have been sampled yet.
func _nearer_goal(attempt: int) -> Vector3:
	if attempt < 2 or not is_instance_valid(navigator) or not navigator.has_method("command_support"): return Vector3.INF
	var place: Vector3 = navigator.command_location(movement.location_id)
	if not place.is_finite(): return Vector3.INF
	var side := actor.global_position - place; side.y = 0.0
	if side.length() < 2.0: return Vector3.INF
	return navigator.command_support(place + side.normalized() * minf(8.0 * float(attempt - 1), side.length() * .5))

func _end_gaze(status: String, reason: String) -> void:
	if gaze.is_empty(): return
	_report(gaze, status, reason)
	gaze = {}
	if is_instance_valid(actor): actor.set_action_gaze(null)

## NightRest when this pony's home is up in the sky (NightRest.SKY_HOMES) with no walk-in
## house of her own there yet, else null.
func _sky_home() -> Node:
	var population := get_tree().get_first_node_in_group("pony_populations")
	if population == null or not ("host" in population) or not is_instance_valid(population.host): return null
	var rest: Node = population.host.get_node_or_null("NightRest")
	if rest == null or not rest.SKY_HOMES.has(str(actor.identity.id)): return null
	return null if _home_house() != null else rest

## The game's TrixieShow (show_runtime.gd), or null.
func _trixie_show() -> Node:
	var population := get_tree().get_first_node_in_group("pony_populations")
	if population == null or not ("host" in population) or not is_instance_valid(population.host): return null
	var show: Node = population.host.get_node_or_null("TrixieShow")
	return show if show != null and show.has_method("ai_start") else null

## The bed a go_to_bed means: {"house", "key", "label"} ("key" is the house's bed key: her id for her
## own bed, "" for the house's first bed; no "house" = her cloud nap), or {"error"}.
func _bed_for(action: Dictionary) -> Dictionary:
	var own := _home_house()
	if str(action.get("bed", "own")) != "here":
		if own != null: return {"house": own, "key": str(actor.identity.id), "label": "your own bed"}
		return {"house": null, "key": "", "label": "a nap on your cloud"} if _sky_home() != null else {"error": "You have no bed of your own"}
	var anon: Node3D = (action.anon as WeakRef).get_ref() as Node3D if action.get("anon") is WeakRef else null
	if anon == null or not anon.is_inside_tree(): return {"error": "Anon is not here to show you a bed"}
	for house: Node in get_tree().get_nodes_in_group("house_interiors"):
		if not house.has_method("bed_side") or not house.has_method("contains") or not house.contains(anon.global_position): continue
		if house == own: return {"house": own, "key": str(actor.identity.id), "label": "your own bed"}
		return {"house": house, "key": "", "label": "the bed in the house where Anon is"}
	return {"error": "Anon is not in a house with a bed"}

## Her own house in town, or null.
func _home_house() -> Node3D:
	var population := get_tree().get_first_node_in_group("pony_populations")
	if population == null or not population.has_method("home_house") or actor.get("identity") == null: return null
	return population.home_house(str(actor.identity.id))

func _end_move(status: String, reason: String, routine := false) -> void:
	if movement.is_empty(): return
	var owns_navigator: bool = is_instance_valid(navigator) and str(navigator.command_owner) == str(movement.id)
	if owns_navigator and status=="cancelled" and movement.type in ["sit","lie_down"] and actor.has_method("request_posture"): actor.request_posture("stand")
	if owns_navigator and status == "cancelled" and actor.get("flight") != null and actor.flight.active(): actor.flight.land()
	_report(movement, status, reason)
	movement = {}
	if is_instance_valid(actor): actor.remove_meta("active_follow")
	if owns_navigator: _release(routine)

func _release(routine: bool) -> void:
	if not is_instance_valid(navigator): return
	navigator.stay()
	if "reserved_by" in navigator and not str(navigator.reserved_by).is_empty():
		# The reservation supplies the continuing presence hold. Leave no generated owner
		# behind to suppress normal wandering after the encounter releases her.
		navigator.command_owner = ""
		navigator.command_speed_limit = INF
		if "command_pace_target" in navigator: navigator.command_pace_target = -1.0
		return
	navigator.command_owner = "" if routine else "rest_after_command"
	navigator.command_speed_limit = INF
	if "command_pace_target" in navigator: navigator.command_pace_target = -1.0
	if routine:
		navigator.wander_enabled = true
		var schedule := actor.get_node_or_null("Schedule") if is_instance_valid(actor) else null
		if schedule != null and schedule.has_method("_apply"): schedule._apply()

func _report(action: Dictionary, status: String, reason: String) -> void:
	if action.get("status") == status and action.get("reason") == reason: return
	action.status = status; action.reason = reason
	var event := {"id": action.id, "type": action.type, "status": status, "reason": reason}
	recent.append(event)
	if recent.size() > 12: recent.pop_front()
	outcome.emit(event)

## Where her current model-asked trip goes ("" when none): the place a "walk with me" means.
func ai_destination() -> String:
	if movement.is_empty() or not bool(movement.get("ai", false)) or str(movement.get("type", "")) not in ["go_to", "lead"]: return ""
	return str(movement.get("location_id", ""))

func context_lines() -> String:
	var lines := PackedStringArray()
	for action in [movement, gaze]:
		if not action.is_empty(): lines.append("Active %s: %s (%s)." % [action.id, action.type, action.get("status", "accepted")])
	for event in recent.slice(maxi(0, recent.size() - 4)):
		lines.append("Action %s / %s: %s — %s" % [event.id, event.type, event.status, event.reason])
	return "\n".join(lines)

func _exit_tree() -> void:
	var owns_navigator: bool = is_instance_valid(navigator) and not movement.is_empty() and str(navigator.command_owner) == str(movement.id)
	if is_instance_valid(actor): actor.remove_meta("active_follow")
	if is_instance_valid(actor) and actor.has_method("set_action_gaze"): actor.set_action_gaze(null)
	if owns_navigator: _release(true)
