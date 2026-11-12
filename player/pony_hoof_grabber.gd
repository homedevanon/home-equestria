extends RefCounted
## Shares the existing grip input and visible-hand overrides with torso pickup.
var owner_node:Node
var held:Dictionary={}
## Metres from a pony's origin, per unit of body scale, past which a hand cannot touch her legs
## (a princess at scale 1 stays well inside; ponies go up to scale 4).
const FAR:=3.0
func bind(grabber:Node):owner_node=grabber
func is_holding(side:String)->bool:return held.has(side) and is_instance_valid(held[side]) and held[side].hoof_hold.active()
func pressed(side:String)->bool:
	var controller:Node=owner_node._controllers.get(side)
	if is_instance_valid(controller) and controller.has_method("get_is_active") and not controller.get_is_active():return false
	return owner_node._grip_pressed(side)
func process(_delta:float)->void:
	for side in ["left","right"]:
		var hand:Node3D=owner_node._hands.get(side)
		if held.has(side):
			if not is_instance_valid(held[side]):held.erase(side)
			elif not is_instance_valid(hand) or not pressed(side) or not held[side].hoof_hold.active():
				held[side].hoof_hold.release();held.erase(side)
			else:held[side].hoof_hold.update(hand.global_position)
		if is_holding(side) or owner_node._holding[side] or not is_instance_valid(hand) or not pressed(side):continue
		var winner:Node;var hit:={};var distance:=.09
		for pony in owner_node.ponies:
			if not is_instance_valid(pony) or pony.get("hoof_hold")==null:continue
			if owner_node.is_carrying(pony) or pony.get_meta("cuddle_active",false):continue
			# No leg is this far from its pony. Without this, candidate() posed the whole skeleton of every pony
			# in town for each clenched hand each tick (thread report 2026-11-12: about 5,600 a second in town).
			var far:float=FAR*maxf(1.0,float(pony.get("body_scale")) if pony.get("body_scale")!=null else 1.0)
			if hand.global_position.distance_squared_to(pony.global_position)>far*far:continue
			var candidate:Dictionary=pony.hoof_hold.candidate(hand.global_position,distance)
			if not candidate.is_empty():winner=pony;hit=candidate;distance=hit.distance
		if winner!=null and winner.hoof_hold.begin(hit,hand.global_position):
			held[side]=winner
			if winner.has_signal("physical_reaction") and not winner.has_meta("spa_client"):winner.physical_reaction.emit("hoofhold")
func transform(side:String)->Transform3D:return held[side].hoof_hold.grip()
func release_all()->void:
	for pony in held.values():
		if is_instance_valid(pony):pony.hoof_hold.release()
	held.clear()
