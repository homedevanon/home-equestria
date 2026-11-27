extends Node
## Excitement, shown the way each kind of pony shows it. Pegasi (dev 2026-10-17: "pegasi will extend
## their wings when they're excited (kissing or prolonged head scratches or called by the ai as a
## facial expression)", "a wing flutter expression too where it'll just open and close"); earth
## ponies and unicorns (dev 2026-10-22: "earfies do single hind hoof kicks and raise hoofies and
## unicorns horns spark with magic when they're excited").
## She is excited while kissed, after PET_SECONDS of petting on her head, neck or mane (for as
## long as it lasts plus AFTERGLOW), or for SPREAD_SECONDS when her AI writes [excited] or
## [wings:spread]. Then:
## - wings (pegasi, alicorns): her open wing meshes (hybrid_open_wings.gd, shared with her flight)
##   show; [wings:flutter] flicks them open and shut FLUTTERS times. Her flight owns the wings
##   while she flies; nothing here touches them then.
## - horn (unicorns, alicorns): sparkle bursts at the horn tip every SPARK_EVERY seconds or so.
## - earth ponies: once per excited spell, one hind hoof kicked back and up (pony_hoof_hold.gd
##   kick()), then a forehoof raised and curled for as long as it lasts. Skipped if a hoof is
##   already busy (a door, a hand holding it) or she is lying or sitting.
## Far ponies (SimTier.FAR) show nothing but wings.
const WINGS := preload("res://world/characters/hybrid_mare/hybrid_open_wings.gd")
const BEAT := 0.1
const PET_SECONDS := 4.0
const AFTERGLOW := 3.0
const KISS_AFTER := 1.0
const SPREAD_SECONDS := 4.0
const FLUTTERS := 3
const FLUTTER_OPEN := 0.16
const FLUTTER_SHUT := 0.13
const SPARK_EVERY := 0.9
const KICK_SECONDS := 0.6
## A raised forehoof is held this long at most, then let down, even if she is still excited.
const RAISE_MAX_SECONDS := 12.0
const EXCITING := ["head", "neck", "mane"]
enum Hoof { IDLE, KICKING, RAISED, DONE }
var mare: Node3D
var _beat := 0.0
var _petted := 0.0
var _until := 0.0          # seconds of excitement left (kiss, petting afterglow, AI tag)
var _flutter := 0.0        # flutter clock; < 0 when none
var _shown := false
var _spark := 0.0
var _hoof := Hoof.IDLE
var _raise_leg := -1
## Beat cost (perf overhaul 2026-11-21, lane pony_tick): what her identity says about wings and horn,
## read once per beat instead of six to eight times through method calls (calls outside a beat, such as
## spread() and flutter(), read them fresh), and her Affection node kept once found. 45 ponies x 10
## beats a second. Rollback: BEAT_CACHE = false.
const BEAT_CACHE := true
var _in_beat := false
var _id_read := false
var _id_wings := false
var _id_horn := false
var _affection_node: Node

func setup(owner_mare: Node3D) -> void:
	mare = owner_mare
	_flutter = -1.0
	# The beat runs on a Timer; only a flutter needs every frame (2026-10-23 CPU pass: 44 ponies'
	# per-frame callbacks for a 10 Hz beat).
	var beat := Timer.new(); beat.name = "Beat"; beat.wait_time = BEAT; beat.autostart = true
	beat.timeout.connect(_on_beat)
	add_child(beat)
	set_process(false)

## [excited] (any pony) and [wings:spread]: excited a while. False only for a pony with wings
## who is flying (her flight has them) when wings are all she would show.
func spread(seconds := SPREAD_SECONDS) -> bool:
	if not is_instance_valid(mare): return false
	if _has_wings() and _flying() and not (_has_horn() or _earth()): return false
	_until = maxf(_until, seconds)
	_show(true)
	return true

## [wings:flutter]: a quick open-shut-open-shut, then back to how they were.
func flutter() -> bool:
	if not _has_wings() or _flying(): return false
	_flutter = 0.0
	set_process(true)
	return true

func spread_now() -> bool:
	return _shown

func excited() -> bool:
	return _until > 0.0

func _identity() -> Variant:
	return mare.get("identity") if is_instance_valid(mare) else null

## The wings and horn answers for her current identity object (BEAT_CACHE).
func _identity_facts() -> void:
	if _id_read: return
	var identity: Variant = _identity()
	_id_read = true
	_id_wings = identity != null and identity.has_wings()
	_id_horn = identity != null and identity.has_method("has_horn") and identity.has_horn()

func _has_wings() -> bool:
	if _in_beat:
		_identity_facts()
		return _id_wings
	var identity: Variant = _identity()
	return identity != null and identity.has_wings()

func _has_horn() -> bool:
	if _in_beat:
		_identity_facts()
		return _id_horn
	var identity: Variant = _identity()
	return identity != null and identity.has_method("has_horn") and identity.has_horn()

func _earth() -> bool:
	return _identity() != null and not _has_wings() and not _has_horn()

func _flying() -> bool:
	var flight: Variant = mare.get("flight")
	return flight != null and flight.active()

func _far() -> bool:
	var tier: Variant = mare.get("sim_tier")
	return tier != null and int(tier) == 2   # pony_locomotion.gd SimTier.FAR

func _process(delta: float) -> void:
	if _flutter < 0.0:
		set_process(false); return
	_flutter += delta
	var cycle := FLUTTER_OPEN + FLUTTER_SHUT
	if _flutter >= cycle * FLUTTERS or _flying():
		_flutter = -1.0
		_apply(_until > 0.0)
		set_process(false)
	else:
		_apply(fmod(_flutter, cycle) < FLUTTER_OPEN)

## Calm beat (native pony port 2026-11-21, lane frame): nearly every beat finds her calm (45 ponies,
## 10 Hz, 5 us a beat). When nothing of an excitement is left (no time to run, no petting counted,
## wings not shown by us, no hoof of ours kicked or raised, no flutter) and neither a kiss nor petting
## on an exciting region reaches her now, the whole beat could only write values they already hold
## and set _spark to 0: the sleep or flight branch resets what is already reset, and otherwise
## _petted stays 0, _until stays 0, _apply(false) returns at once (her wings are not shown) and
## _calm() sets _spark to 0 and the hoof state to IDLE. So that is all this does; anything else runs
## the whole beat as before. Kiss and petting are tested before the spa mark (they would be masked
## by it anyway). Rollback: CALM_BEAT = false. Parity: tools/profile/port_frame_excite_parity.gd.
const CALM_BEAT := true

func _calm_beat() -> bool:
	if _until != 0.0 or _petted != 0.0 or _shown or _hoof != Hoof.IDLE or _raise_leg != -1 or _flutter >= 0.0: return false
	if not is_instance_valid(mare): return false
	var affection: Node = _affection_node if BEAT_CACHE and is_instance_valid(_affection_node) and _affection_node.get_parent() == mare \
		else mare.get_node_or_null("Affection")
	if BEAT_CACHE and affection != null: _affection_node = affection
	if affection != null and str(affection.get("kind")) == "kiss": return false
	var touch: Variant = mare.get("touch_body")
	if touch is Node and bool(touch.get("petting")) and str(touch.get("pet_region")) in EXCITING: return false
	_spark = 0.0
	return true

func _on_beat() -> void:
	if CALM_BEAT and _calm_beat(): return
	if not BEAT_CACHE:
		_beat_body()
		return
	_in_beat = true
	_id_read = false
	_beat_body()
	_in_beat = false


func _beat_body() -> void:
	if _flutter >= 0.0 or not is_instance_valid(mare): return
	var dt := BEAT
	if bool(mare.get("sleeping")) or (_has_wings() and _flying() and not _has_horn()):
		_petted = 0.0; _until = 0.0; _shown = false   # the flight (or sleep) has her
		_calm()
		return
	# A spa client's care never excites her (SPA_PLAN_2026_10_29.md section 3); her AI tags still can.
	var spa := mare.has_meta("spa_client")
	var affection: Node = _affection_node if BEAT_CACHE and is_instance_valid(_affection_node) and _affection_node.get_parent() == mare \
		else mare.get_node_or_null("Affection")
	if BEAT_CACHE and affection != null: _affection_node = affection
	if not spa and affection != null and str(affection.get("kind")) == "kiss": _until = maxf(_until, KISS_AFTER)
	var touch: Variant = mare.get("touch_body")
	var petted: bool = not spa and touch is Node and bool(touch.get("petting")) and str(touch.get("pet_region")) in EXCITING
	_petted = _petted + dt if petted else 0.0
	if _petted >= PET_SECONDS: _until = maxf(_until, AFTERGLOW)
	_until = maxf(0.0, _until - dt)
	_show(_until > 0.0, dt)

## One beat of excitement shown (or calmed) the way her kind shows it.
func _show(on: bool, dt := 0.0) -> void:
	if _has_wings(): _apply(on)
	if not on: _calm(); return
	if _far(): return
	if _has_horn():
		_spark -= dt
		if _spark <= 0.0:
			var magic: Variant = mare.get("magic")
			if magic is Node and magic.has_method("sparkle"): magic.sparkle()
			_spark = SPARK_EVERY * randf_range(.7, 1.4)
	if _earth(): _hooves()

## Earth pony: kick once, then raise a forehoof while it lasts.
func _hooves() -> void:
	var hold: Variant = mare.get("hoof_hold")
	if hold == null or not hold.has_method("kick"): return
	match _hoof:
		Hoof.IDLE:
			_hoof = Hoof.KICKING if hold.kick(randi() % 2, KICK_SECONDS) else Hoof.DONE
			if _hoof == Hoof.DONE: _raise(hold)
		Hoof.KICKING:
			if int(hold.leg_index) < 0: _raise(hold)

func _raise(hold: Variant) -> void:
	_hoof = Hoof.DONE
	if int(hold.leg_index) >= 0: return
	if hold.raise(randi() % 2, RAISE_MAX_SECONDS):
		_hoof = Hoof.RAISED; _raise_leg = int(hold.leg_index)

## Excitement over: let a raised forehoof down (only our own raise) and be ready for next time.
func _calm() -> void:
	_spark = 0.0
	if _hoof == Hoof.RAISED:
		var hold: Variant = mare.get("hoof_hold")
		if hold != null and int(hold.leg_index) == _raise_leg and float(hold.gesture_left) > 0.0: hold.release()
	_hoof = Hoof.IDLE; _raise_leg = -1

func _apply(open: bool) -> void:
	if open == _shown or not is_instance_valid(mare) or not _has_wings() or _flying(): return
	var wings := _wings()
	if wings == null: return
	wings.set_open(open)
	_shown = open

## Her flight's wing meshes (made here the same way her flight makes them, so there is one set).
func _wings() -> Node:
	if mare.has_method("_ensure_flight"): mare.call("_ensure_flight")
	var flight: Variant = mare.get("flight")
	if flight == null: return null
	if flight.wings == null:
		var made: Node = WINGS.new()
		mare.add_child(made)
		if not made.bind(mare): made.queue_free(); return null
		flight.wings = made
	return flight.wings
