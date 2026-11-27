extends RefCounted
## A pony who does not want to be held squirms out of Anon's arms (player bug board card 48,
## 2026-11-20). Ticked by carry_reaction.gd on the pony's own physics step, only while she is held
## or while her short after-release beat (landing, a buck, stepping away) runs; idle otherwise.
##
## Who: a pony Anon carries with his hands (the VR pony grabber) or the desktop carry, while she
## is still a stranger or nearly one (player_bonds.gd knowledge and familiarity, the same reading
## as her prompt's "nearly a stranger" line), or angry with him, or has asked him for space.
## Friends and closer never struggle, and neither does a sleeping pony, a pony in the bridal
## carry, a pony a story encounter has reserved, or a pony anything else (telekinesis, a mod)
## holds through the same pony functions.
##
## What: calm for a moment, then the carry pose's own swing and head springs (pony_carry.gd, both
## written through the joint limits) are driven harder and harder until she is free. The hold ends
## through the carrier's own drop path (interactor.gd _drop, pony_grabber.gd let_go), she lands,
## and steps out of his reach. Picked up again before they parted (AGAIN_WINDOW), she is free much
## sooner and bucks him: her accepted work-buck kick (pony_affection.gd), a recorded impact sample
## and a short push of his body, no knockdown and nothing on the screen.
## She remembers: one world-event record per break-free, and the unwelcome-contact call.

const PLAYER_BONDS := preload("res://world/relationships/player_bonds.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
## Navigator owner while she lands, kicks and steps away.
const OWNER := "carry_struggle"

## Seconds calm in his arms before she squirms, then seconds of squirming until she is free.
const CALM_SECONDS := 0.8
const SQUIRM_SECONDS := 3.2
## Picked up again soon after getting free: much sooner out, and she bucks him.
const AGAIN_CALM := 0.2
const AGAIN_SQUIRM := 1.0
const AGAIN_WINDOW := 60.0
## Squirm strength (swing spring force, radians per second squared; head yaw drive) at full effort.
const SWING_FORCE := 38.0
const HEAD_FORCE := 40.0
## After release: she steps until this far from him, or for at most STEP_SECONDS.
const CLEAR_DISTANCE := 1.8
const STEP_SPEED := 0.9
const STEP_SECONDS := 3.0
const LAND_SECONDS := 1.5
const TURN_SECONDS := 0.5
## Her kick reaches him this far behind her (as pony_affection.gd buck), at this point of the kick.
const KICK_REACH := 2.0
const KICK_AT := 0.8
## The knock: a step back, eased out, never a fall.
const PUSH_DISTANCE := 0.4
const PUSH_SECONDS := 0.22
const REMEMBER := "Anon picked you up against your wishes; you struggled free."
const REMEMBER_BUCK := "Anon picked you up again against your will, so you broke free and bucked him."

## "" idle, "held" in his arms, then "land", "turn", "kick", "step" after she got free.
var phase := ""
var elapsed := 0.0
var wants_down := false
var again := false
var freed_at := -1e9
var kicked := false
var _faced := false
var _claimed := false
var _nav_owner := ""
var _nav_wander := true
var _pushed := Vector3.ZERO


## True while the after-release beat still needs the pony's tick.
func busy() -> bool:
	return phase != "" and phase != "held"


## One tick. True while she is held and wants down (her "enjoying the ride" event is then skipped).
func update(actor: Node3D, delta: float) -> bool:
	if actor.get("_held") == true:
		if phase != "held": _begin_hold(actor)
		return _hold_tick(actor, delta)
	if phase == "held":
		# He set her down (or threw her) before she got free.
		_calm_face(actor)
		phase = ""
	elif busy():
		_after_tick(actor, delta)
	return false


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _begin_hold(actor: Node3D) -> void:
	if busy(): _finish(actor) # Picked up again mid-step.
	phase = "held"; elapsed = 0.0; _faced = false
	wants_down = _carrier(actor) != null and unwilling(actor)
	again = wants_down and _now() - freed_at < AGAIN_WINDOW


func _hold_tick(actor: Node3D, delta: float) -> bool:
	if not wants_down: return false
	var carry: Object = actor.get("carry")
	# Asleep, or lifted into the bridal carry: she is content (cradle_rest.gd).
	var cradle: Variant = carry.get("cradle") if carry != null else null
	if actor.get("sleeping") == true or (carry != null and carry.get("cradle_goal") == true) or (cradle is float and float(cradle) > 0.0):
		wants_down = false
		_calm_face(actor)
		return false
	elapsed += delta
	var calm := AGAIN_CALM if again else CALM_SECONDS
	var total := calm + (AGAIN_SQUIRM if again else SQUIRM_SECONDS)
	if elapsed < calm: return true
	if not _faced:
		_faced = true
		if actor.has_method("set_dialogue_expression"): actor.set_dialogue_expression("annoyed")
	if elapsed >= total:
		_break_free(actor)
		return true
	# Harder as it goes on: two drives out of step so the wriggle never settles into a rhythm.
	var effort := lerpf(0.35, 1.0, smoothstep(calm, total, elapsed))
	var t := elapsed
	if carry != null:
		var swing := Vector2(sin(t * 9.0), sin(t * 13.0 + 1.3)) * SWING_FORCE * effort
		carry.set("swing_velocity", Vector2(carry.get("swing_velocity")) + swing * delta)
		var head := Vector3(0.25 * sin(t * 7.0), sin(t * 8.5), 0.0) * HEAD_FORCE * effort
		carry.set("head_velocity", Vector3(carry.get("head_velocity")) + head * delta)
	return true


## She is still a stranger or nearly one, angry with him, or asked for space; never a friend.
static func unwilling(actor: Node) -> bool:
	if not actor.has_meta("relationship_runtime"): return false
	var runtime: Variant = actor.get_meta("relationship_runtime")
	var id := str(actor.get_meta("relationship_id", "")) if actor.has_meta("relationship_id") else ""
	if not (runtime is Object) or not is_instance_valid(runtime) or id.is_empty(): return false
	var bonds: Variant = (runtime as Object).get("bonds")
	if not (bonds is Object) or not is_instance_valid(bonds): return false
	# A story encounter that reserved her keeps her (its own carry, if it needs one).
	var nav: Node = actor.get_node_or_null("Navigator")
	var reserved: Variant = nav.get("reserved_by") if nav != null else null
	if reserved is String and not (reserved as String).is_empty(): return false
	var row: Dictionary = bonds.record_for(id)
	if PLAYER_BONDS.STAGES.find(str(row.get("stage", "acquaintance"))) >= 1: return false
	if float(bonds.anger(id)) >= 35.0: return true
	var cooldowns: Dictionary = row.get("cooldowns", {})
	if float(bonds.now()) < float(cooldowns.get("boundary", 0.0)): return true
	var known: Dictionary = bonds.knowledge(id)
	if not bool(known.get("met", false)) and not bool(known.get("unknown", false)): return true
	return float(row.get("familiarity", 0.0)) < PLAYER_BONDS.NEW_ACQUAINTANCE


static func _game(actor: Node) -> Object:
	if not actor.has_meta("relationship_runtime"): return null
	var runtime: Variant = actor.get_meta("relationship_runtime")
	if not (runtime is Object) or not is_instance_valid(runtime): return null
	var game: Variant = (runtime as Object).get("game")
	return game as Object if game is Object and is_instance_valid(game) else null


## The VR pony grabber or the desktop carry holding her, or null (telekinesis, a mod, a test hold).
static func _carrier(actor: Node) -> Object:
	var game := _game(actor)
	if game == null: return null
	var grabber: Variant = game.get("grabber")
	if grabber is Object and is_instance_valid(grabber) and (grabber as Object).has_method("is_carrying") and grabber.is_carrying(actor):
		return grabber
	var desktop: Variant = game.get("desktop_interactions")
	var interactor: Variant = (desktop as Object).get("interactor") if desktop is Object and is_instance_valid(desktop) else null
	if interactor is Object and is_instance_valid(interactor) and (interactor as Object).get("held") == actor:
		return interactor
	return null


static func _player(actor: Node) -> Node3D:
	var game := _game(actor)
	var inventory: Variant = game.get("inventory") if game != null else null
	var body: Variant = (inventory as Object).get("player_body") if inventory is Object and is_instance_valid(inventory) else null
	return body as Node3D if body is Node3D and is_instance_valid(body) else null


func _break_free(actor: Node3D) -> void:
	var carrier := _carrier(actor)
	# The carrier's own let-go, so its hands, hints and held state all end with her hold.
	if carrier != null and carrier.has_method("let_go"): carrier.call("let_go", actor)
	elif carrier != null and carrier.has_method("_drop"): carrier.call("_drop")
	if actor.get("_held") == true and actor.has_method("end_interaction"): actor.end_interaction()
	freed_at = _now()
	phase = "land"; elapsed = 0.0; kicked = false
	_claim(actor)
	var id := str(actor.get_meta("relationship_id", "")) if actor.has_meta("relationship_id") else ""
	var game := _game(actor)
	var context: Variant = game.get("world_context") if game != null else null
	if context is Object and is_instance_valid(context) and not id.is_empty():
		(context as Object).call("record", "physical_contact", REMEMBER_BUCK if again else REMEMBER, [id], ["player", id])
	var runtime: Variant = actor.get_meta("relationship_runtime")
	var bonds: Variant = (runtime as Object).get("bonds") if runtime is Object and is_instance_valid(runtime) else null
	if bonds is Object and is_instance_valid(bonds) and not id.is_empty(): (bonds as Object).call("unwanted_contact", id, "carry")
	print("[struggle] %s struggled free%s" % [actor.name, " and bucks" if again else ""])


func _after_tick(actor: Node3D, delta: float) -> void:
	elapsed += delta
	var player := _player(actor)
	var toward := (player.global_position - actor.global_position) if player != null else Vector3.ZERO
	toward.y = 0.0
	match phase:
		"land":
			if actor.has_method("grounded") and not actor.grounded() and elapsed < LAND_SECONDS: return
			phase = "turn" if again and player != null else "step"; elapsed = 0.0
		"turn":
			# Her rear to him, as pony_affection.gd's buck turns her.
			var yaw := atan2(toward.x, toward.z)
			actor.rotation.y = rotate_toward(actor.rotation.y, yaw, delta * 7.0)
			if elapsed < TURN_SECONDS and absf(angle_difference(actor.rotation.y, yaw)) > 0.15: return
			var affection: Node = actor.get_node_or_null("Affection")
			var kicking: bool = affection != null and affection.has_method("work_buck") and affection.work_buck()
			phase = "kick" if kicking else "step"; elapsed = 0.0
		"kick":
			var affection: Node = actor.get_node_or_null("Affection")
			var clock: float = affection.buck_time() if affection != null else -1.0
			if not kicked and clock >= KICK_AT:
				kicked = true
				if toward.length() < KICK_REACH and toward.length() > 0.01 and toward.normalized().dot(actor.global_basis.z.normalized()) > 0.5:
					_knock(actor, player, toward.normalized())
			if clock < 0.0 or elapsed > 2.0:
				phase = "step"; elapsed = 0.0
		"step":
			if player == null or toward.length() >= CLEAR_DISTANCE or elapsed >= STEP_SECONDS:
				_finish(actor)
				return
			if actor.has_method("set_desired_velocity"): actor.set_desired_velocity(-toward.normalized() * STEP_SPEED)


## A short push of his body away from her kick, with a recorded impact. No fall, no screen effect.
func _knock(actor: Node3D, player: Node3D, away: Vector3) -> void:
	if player.get("controls_locked") == true or player.has_meta("knocked_down") or is_instance_valid(player.get("seat")): return
	SFX.play_event(player, "prop_impact", {"material": "soft", "intensity": 1.0}, player.global_position + Vector3.UP * 0.9)
	if not (player is PhysicsBody3D): return
	_pushed = Vector3.ZERO
	var tween := actor.create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_method(_push_to.bind(player, away * PUSH_DISTANCE), 0.0, 1.0, PUSH_SECONDS).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	print("[struggle] %s bucked the player back" % actor.name)


func _push_to(amount: float, body: PhysicsBody3D, offset: Vector3) -> void:
	if not is_instance_valid(body): return
	var goal := offset * amount
	body.move_and_collide(goal - _pushed)
	_pushed = goal


func _finish(actor: Node3D) -> void:
	var affection: Node = actor.get_node_or_null("Affection")
	if affection != null and affection.has_method("cancel_work_buck"): affection.cancel_work_buck()
	if actor.has_method("stop"): actor.stop()
	_release(actor)
	_calm_face(actor)
	phase = ""; elapsed = 0.0


func _calm_face(actor: Node) -> void:
	if not _faced: return
	_faced = false
	var expressions: Variant = actor.get("expressions")
	if expressions is Object and str((expressions as Object).get("dialogue_face")) == "annoyed" and actor.has_method("finish_dialogue_expression"):
		actor.finish_dialogue_expression()


func _claim(actor: Node) -> void:
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or _claimed: return
	_nav_owner = str(nav.get("command_owner")); _nav_wander = bool(nav.get("wander_enabled"))
	nav.stay(); nav.set("command_owner", OWNER); nav.set("wander_enabled", false)
	_claimed = str(nav.get("command_owner")) == OWNER


func _release(actor: Node) -> void:
	if not _claimed: return
	_claimed = false
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null and str(nav.get("command_owner")) == OWNER:
		nav.stay(); nav.set("command_owner", _nav_owner); nav.set("wander_enabled", _nav_wander)
