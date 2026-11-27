extends RefCounted
## Applejack waits beside her broken apple wagon (wagon_wheel.gd) from the break until the wheel is
## fitted or the favour runs out: a story encounter (world/ai/encounters/encounter_runtime.gd) keeps
## her day plan from taking her away and pins what she knows into her conversations, and this
## navigator owner walks her to her spot. After the fix she stays RELEASE_AFTER seconds to thank Anon
## and offer to pay. With no body loaded, her living-world record waits at the spot instead
## (world/life/essence.gd), so she is there when Anon comes. The encounter id is saved ("held"), so a
## reloaded world still lets her go once it is over. Ticked once a second by the wagon wheel.
const ESSENCE := preload("res://world/life/essence.gd")
const LIFE_CORE := preload("res://world/life/living_world.gd")
const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")
const APPLEJACK := "applejack"
const OWNER := "wagon_wheel:"
const ENCOUNTER := "wagon_wheel:%s"
const RELEASE_AFTER := 45.0
const WAIT_SIDE := 1.9          # metres from the wagon's middle, on the barn side
const NEAR_SPOT := 1.2
const WAIT_REASON := "Waiting by her broken apple wagon for Anon's help"
## What Applejack knows while she waits (her AI hears it in every conversation of the encounter).
const KNOWS := "A wheel broke on your apple wagon in the farmyard at Sweet Apple Acres, and you wrote to Anon asking for his help. The spare is in the barn, leaning against the back wall. You need him to grab it and put it on while you hold the wagon steady."
const COMMITMENT := "Wait by your broken wagon until Anon puts the spare wheel on."
const ALLOWED := "Stay by your wagon until the new wheel is on. If Anon asks you to go somewhere, follow him or sit down, it has to wait until it's fixed."
## Her spoken lines (overhead, no AI call): at a break Anon watches, and at his fix (one picked by a
## hash of the favour id), with a little hop. Only with her body loaded this near the wagon and no
## conversation steering her.
const BREAK_LINE := "Aw, horseapples! Not the wheel again!"
const FIT_LINES := ["Yee-haw! Good as new!", "Now that's a fine job, sugarcube!", "Whoo-ee! She'll roll again!"]
const BREAK_HEARS := 25.0
const FIT_HEARS := 12.0
const HOP := 2.6
const SPEECH_SECONDS := 3.5

var wheel: Node   # wagon_wheel.gd
var _release_in := -1.0   # seconds until she goes back to her day after the fix
var _speech: Node3D
## Tests: the last line she said.
var last_line := ""

func _init(owner_wheel: Node) -> void:
	wheel = owner_wheel

## The wheel is on: she stays a little to thank Anon.
func thank() -> void:
	_release_in = RELEASE_AFTER

## Another world or checkpoint: no thank-you window carries over.
func reset() -> void:
	_release_in = -1.0

## Once a second. While the wheel is broken (and RELEASE_AFTER seconds after the fix) she is held at
## her spot by the wagon, facing it; otherwise whatever hold this made is let go.
func keep() -> void:
	if _release_in > 0.0: _release_in -= 1.0
	var saved: Dictionary = wheel.state()
	var broken: bool = wheel.broken()
	if not (broken or _release_in > 0.0):
		if saved.has("held") or saved.has("paused"): release()
		return
	if broken and str(saved.get("held", "")) != str(saved.get("ask_id", "")):
		saved["held"] = str(saved.get("ask_id", ""))
		wheel.save()
	var key := ENCOUNTER % str(saved.get("held", ""))
	var encounters := _encounters()
	if encounters != null and broken and not bool(encounters.active(key)): encounters.begin(key, _story())
	var spot: Variant = wheel.wait_spot()
	if spot == null: return
	var actor := _applejack()
	if actor != null:
		_lift_essence_pause()
		_walk_to_spot(actor, spot as Vector3, wheel.middle())
	elif broken:
		_park_essence(spot as Vector3)

func _story() -> Dictionary:
	return {
		"title": "waiting by her broken apple wagon", "place": "Sweet Apple Acres farmyard",
		"participants": [APPLEJACK], "movers": {APPLEJACK: [OWNER]}, "hold": true,
		"knows": {APPLEJACK: [KNOWS]}, "commitment": {APPLEJACK: COMMITMENT}, "allowed": ALLOWED,
		"beats": []}

func _game() -> Node:
	return wheel.game()

func _encounters() -> Node:
	var host := _game()
	var found: Variant = host.get("encounters") if host != null else null
	return found as Node if is_instance_valid(found) else null

func _population() -> Node:
	var host := _game()
	var found: Variant = host.get("population") if host != null else null
	return found as Node if is_instance_valid(found) else null

func _applejack() -> Node3D:
	var population := _population()
	var live: Variant = population.get("live") if population != null else null
	var row: Variant = (live as Dictionary).get(APPLEJACK) if live is Dictionary else null
	var actor: Variant = (row as Dictionary).get("actor") if row is Dictionary else null
	return actor as Node3D if is_instance_valid(actor) and actor is Node3D and (actor as Node3D).is_inside_tree() else null

## Someone else steering her right now (a conversation turning her to Anon): leave her be.
static func _steered(nav: Node) -> bool:
	var owner_now := str(nav.command_owner) if nav != null else ""
	return not owner_now.is_empty() and not owner_now.begins_with(OWNER) and not owner_now.begins_with("ai:")

func _walk_to_spot(actor: Node3D, spot: Vector3, face: Vector3) -> void:
	actor.set_meta("event_placed", true)
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null or _steered(nav): return
	var owner_now := str(nav.command_owner)
	if not owner_now.begins_with(OWNER):
		nav.stay()
		nav.command_owner = OWNER + APPLEJACK
		nav.wander_enabled = false
	var away := Vector2(actor.global_position.x - spot.x, actor.global_position.z - spot.z).length()
	var walking: bool = nav.state in [nav.State.WAITING, nav.State.MOVING, nav.State.INTERRUPTED]
	if away > NEAR_SPOT:
		if not walking: nav.go_to(spot, nav.Gait.TROT)
		nav.face_point = Vector3.INF
	else:
		if walking: nav.stay()
		nav.face_point = face

## Anon is far off and she has no body: her living-world self waits at the spot.
func _park_essence(spot: Vector3) -> void:
	var population := _population()
	if population == null or not ESSENCE.unloaded(population, APPLEJACK): return
	var resident := ESSENCE.record(population, APPLEJACK)
	if resident.is_empty(): return
	var core: RefCounted = ESSENCE.core(population)
	var saved: Dictionary = wheel.state()
	if not saved.has("paused"):
		ESSENCE.leave_outing(population, APPLEJACK, WAIT_REASON)
		if core != null and resident.get("paused", false) != true:
			core.pause_resident(APPLEJACK, true, WAIT_REASON)
			saved["paused"] = true
			wheel.save()
	resident.position = LIFE_CORE.vector(spot)
	resident.last_reason = WAIT_REASON

func _lift_essence_pause() -> void:
	var saved: Dictionary = wheel.state()
	if not saved.has("paused"): return
	saved.erase("paused")
	wheel.save()
	var core: RefCounted = ESSENCE.core(_population())
	if core != null: core.pause_resident(APPLEJACK, false)

## The wheel just broke in front of Anon. True when she said it.
func say_break() -> bool:
	return _say(BREAK_LINE, BREAK_HEARS) != null

## Anon fitted the wheel of favour `key`: a line and one small hop. True when she said it.
func say_fit(key: String) -> bool:
	var actor := _say(FIT_LINES[hash(key) % FIT_LINES.size()], FIT_HEARS)
	if actor == null: return false
	if actor.has_method("jump"): actor.jump(HOP)   # only when she stands on the floor
	return true

## Her body within `reach` of the wagon, not in a conversation: `text` over her head for
## SPEECH_SECONDS. Her body, or null when she said nothing.
func _say(text: String, reach: float) -> Node3D:
	var actor := _applejack()
	var middle: Vector3 = wheel.middle()
	if actor == null or not middle.is_finite() or actor.global_position.distance_to(middle) > reach: return null
	if _steered(actor.get_node_or_null("Navigator")): return null
	if is_instance_valid(_speech): _speech.queue_free()
	var speech: OVERHEAD = OVERHEAD.new()
	speech.name = "ApplejackSays"
	var identity: Variant = actor.get("identity")
	var speaker := str((identity as Resource).get("display_name")) if identity is Resource else "Applejack"
	speech.set_fallback_labels(null, null, speaker)
	speech.text = text
	speech.caption_full = text
	wheel.add_child(speech)
	speech.show_for(actor, wheel.get_viewport().get_camera_3d())
	_speech = speech
	last_line = text
	speech.create_tween().tween_callback(speech.queue_free).set_delay(SPEECH_SECONDS)
	return actor

## Lets her go: the encounter ends, her navigator and living-world record are hers again.
func release() -> void:
	_release_in = -1.0
	var saved: Dictionary = wheel.state()
	var held := str(saved.get("held", ""))
	saved.erase("held")
	wheel.save()
	_lift_essence_pause()
	var encounters := _encounters()
	if encounters != null and not held.is_empty(): encounters.complete(ENCOUNTER % held)
	var actor := _applejack()
	if actor == null: return
	if actor.has_meta("event_placed"): actor.remove_meta("event_placed")
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav != null and str(nav.command_owner).begins_with(OWNER):
		nav.face_point = Vector3.INF
		nav.stay()
		nav.command_owner = ""
		nav.wander_enabled = true
	print("[wagon_wheel] Applejack goes back to her day")
