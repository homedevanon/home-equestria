extends Node
## The displayed VR grab offer is the transaction a squeeze commits. Providers own
## holding/dragging/release; only this router chooses and starts new world grabs.
const TARGETS := preload("res://world/inventory/grab_targets.gd")
const SIDES := ["left", "right"]
var inventory: Node
var offers: Dictionary = {}
var down: Dictionary = {"left": true, "right": true}
var armed: Dictionary = {"left": false, "right": false}
var _elapsed := 0.0
var consumed: Dictionary = {"left": false, "right": false}
func _ready() -> void: process_physics_priority = -100
func available() -> bool:
	return is_instance_valid(inventory) and is_instance_valid(inventory.player_body) and not inventory._desktop and not get_tree().paused \
		and not inventory.player_body.controls_locked and not inventory.case.visible \
		and not inventory.customizer.opened and not inventory._map_open() \
		and (inventory.inspector == null or not inventory.inspector.active)
static func palm(sample: Dictionary) -> Vector3:
	var pose: Transform3D = sample.get("pose", sample.get("aim", Transform3D.IDENTITY))
	return sample.get("grip_position", pose.origin)
func offer(side: String) -> Dictionary:
	if not available() or (inventory.hand_busy(side) and not inventory.equipped_only(side)): return {}
	var value: Dictionary = offers.get(side, {})
	return value if is_instance_valid(value.get("target")) else {}
func select(side: String, sample: Dictionary) -> Dictionary:
	if not available() or not sample.get("active", false): return {}
	if inventory.hand_busy(side) and not inventory.equipped_only(side): return {}
	var point := palm(sample)
	var tracking: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	if not point.is_finite() or not tracking.is_finite(): return {}
	var best := {}
	var distance := INF
	for provider: Node in get_tree().get_nodes_in_group("grab_providers"):
		if provider.get("inventory") != inventory: continue
		var candidate: Dictionary = provider.grab_offer(side, sample)
		if candidate.is_empty() or not is_instance_valid(candidate.get("target")): continue
		var gap: float = candidate.get("distance", point.distance_to(candidate.target.global_position))
		if gap < distance:
			best = candidate; best.provider = provider; distance = gap
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	pose.origin = point
	var item: Dictionary = TARGETS.pick(inventory, pose, sample.get("aim", pose))
	if not item.is_empty() and (best.is_empty() or (not item.get("pointed", false) and float(item.distance) < distance)):
		best = item; best.provider = inventory
		# Generic acquisition validates the palm that earned this displayed offer.
		# The next squeeze may arrive between refreshes after the hand has moved.
		best.grab_pose = pose
	return best
func commit(side: String, sample: Dictionary) -> bool:
	var selected := offer(side)
	if selected.is_empty() or not available(): return false
	var provider: Node = selected.get("provider")
	if not is_instance_valid(provider): offers.erase(side); return false
	if inventory.hand_busy(side) and not inventory.equipped_only(side): offers.erase(side); return false
	# Taking the offered object must win over an equipped hotbar item or passive UI.
	if inventory.equipped_only(side) and not inventory._store_held(side): return false
	var accepted: bool = provider.grab_take(side, selected, sample)
	offers.erase(side)
	if accepted:
		for other: String in SIDES:
			if offers.get(other, {}).get("target") == selected.target: offers.erase(other)
		consumed[side] = not inventory.hand_busy(side)
		inventory._pressed[side] = true
		inventory._dismiss_quick_strip()
		inventory.wrist.hide()
	return accepted
## Toggle-held items release on a squeeze; that same squeeze cannot take them again.
func consume(side: String) -> void:
	consumed[side]=true
	offers.erase(side)

func _physics_process(delta: float) -> void:
	if not available():
		# Reset once; on desktop this ran every tick, building two dictionaries (W2 perf pass).
		if not offers.is_empty() or armed.size() != 2 or armed.get("left") != false or armed.get("right") != false \
				or down.size() != 2 or down.get("left") != true or down.get("right") != true:
			offers.clear(); armed = {"left":false,"right":false}; down = {"left":true,"right":true}
		return
	_elapsed += delta
	var refresh := _elapsed >= .08
	if refresh: _elapsed = 0.0
	for side: String in SIDES:
		var sample: Dictionary = inventory.hand_sample(side)
		var tracking: Transform3D = sample.get("pose", Transform3D.IDENTITY)
		if not sample.get("active", false) or not palm(sample).is_finite() or not tracking.is_finite():
			offers.erase(side); armed[side] = false; down[side] = true; continue
		var pressed: bool = float(sample.get("grip", 0.0)) > (.25 if down[side] else .45)
		if not pressed: armed[side] = true; consumed[side] = false
		if pressed and consumed[side]: offers.erase(side); down[side] = pressed; continue
		if not armed[side]: offers.erase(side); down[side]=pressed; continue
		var edge: bool = pressed and not down[side] and armed[side]
		# Commit the visible offer before refreshing it. No independent re-pick can
		# substitute another nearby object between highlight and grip.
		if edge:
			if offer(side).is_empty(): offers[side] = select(side, sample)
			commit(side, sample)
		elif refresh:
			offers[side] = select(side, sample)
			if pressed: commit(side, sample)
		down[side] = pressed
