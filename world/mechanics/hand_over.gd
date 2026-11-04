extends RefCounted
## Something a pony hands Anon (docs/MECHANICS_ARCHITECTURE_2026_11_01.md 4.5): it goes into his
## briefcase first (the one durable owner of his things), then into a free hand when one is free,
## so he sees and holds what she gave him. The hand loop is the same one letter_paper.put_in_hand
## uses for a delivered letter.

## Grants `id` into the briefcase, then takes it into a free hand (VR: an active hand that is not
## busy; desktop: nothing held). Returns "hand", "briefcase" or "" (inventory.inventory.last_error
## says why: no room, or a read-only briefcase).
static func give_to_anon(inventory: Node, id: String, prefer_side := "") -> String:
	if not is_instance_valid(inventory) or id.is_empty(): return ""
	var store: Object = inventory.get("inventory")
	if store == null: return ""
	var index: int = int(store.call("grant", id, 1))
	if index < 0: return ""
	var sides: Array = [prefer_side] if not prefer_side.is_empty() else (["desktop"] if bool(inventory.get("_desktop")) else ["right", "left"])
	for hand: String in sides:
		if not inventory.has_method("hand_busy") or bool(inventory.call("hand_busy", hand)): continue
		var pose := Transform3D.IDENTITY
		if hand == "desktop":
			var eye: Camera3D = inventory.get("camera") as Camera3D
			if eye != null: pose = eye.global_transform
		else:
			var sample: Dictionary = inventory.call("hand_sample", hand)
			if not bool(sample.get("active", false)): continue
			pose = sample.pose
		if bool(inventory.call("take_slot", hand, index, pose, false)): return "hand"
	return "briefcase"
