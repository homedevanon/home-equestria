extends RefCounted
## AnonPony's own pony wear (dev 2026-10-14): scarves, hats, thigh highs and the like are bought
## as briefcase items ("wear:<kind>:<colour>", world/shop/shop_items.gd). Using one in pony form
## puts it on; taking it off in the pony wardrobe puts it back in the briefcase. One piece per
## body slot. The pieces are the same fitted builders that dress town ponies
## (world/characters/accessories/pony_wardrobe.gd), attached to the player pony.
## Human clothes never come here, and these never reach Anon's human wardrobe.
const FITTED := preload("res://world/characters/accessories/pony_fitted_accessories.gd")
const WARDROBE_PATH := "res://world/characters/accessories/pony_wardrobe.gd"
## Size of pony_wardrobe.gd COLOURS (kept here so saves validate without loading the builder).
const COLOUR_COUNT := 16
const ITEMS_PATH := "res://world/shop/shop_items.gd"
## player/pony_form.gd FIRST_PERSON_HIDDEN_LAYER: hats and glasses stay out of her own eye.
const FIRST_PERSON_HIDDEN_LAYER := 1 << 17
const SLOT_LABELS := {"head": "Head", "eyes": "Eyes", "neck": "Neck", "back": "Back", "legs": "Legs"}

static func is_wear(id: String) -> bool:
	return id.begins_with("wear:") and (load(ITEMS_PATH) as GDScript).call("has", id) == true

static func kind(id: String) -> String:
	return id.get_slice(":", 1)

static func colour(id: String) -> int:
	return int(id.get_slice(":", 2))

static func display_name(id: String) -> String:
	return str((load(ITEMS_PATH) as GDScript).call("definition", id).get("name", id))

## The body slot a piece takes; a second piece for the same slot replaces the first.
static func slot(id: String) -> String:
	var piece := kind(id)
	if piece == "cape": return "back"
	var fitted := FITTED.slot(piece)
	return fitted if not fitted.is_empty() else piece

## Whether this pony's body has a fit for the piece (fitted pieces exist for adult mares).
static func fits(avatar: Node3D, id: String) -> bool:
	if avatar == null or not is_wear(id): return false
	var piece := kind(id)
	if FITTED.has(piece) or FITTED.OUTFIT.has(piece): return FITTED.supports_fitted(avatar)
	if piece in ["socks", "plain-socks"]: return avatar.find_child("MareBody", true, false) != null
	if piece in ["scarf", FITTED.CLUB_SCARF]: return FITTED.supports(avatar) or (piece == "scarf" and avatar.get("skeleton") != null)
	return avatar.get("skeleton") != null

## Dress `avatar` in exactly `items` (wear ids). Idempotent: only changed pieces are rebuilt.
static func apply(avatar: Node3D, items: Array) -> void:
	if not is_instance_valid(avatar): return
	var want := {}
	for id: Variant in items:
		if id is String and fits(avatar, id): want[kind(id)] = colour(id)
	var worn: Dictionary = avatar.get_meta("player_wear") if avatar.has_meta("player_wear") else {}
	if worn == want: return
	for piece: String in worn.keys():
		if want.has(piece) and int(want[piece]) == int(worn[piece]): continue
		for old: Node in avatar.find_children("Wear_" + piece + "*", "", true, false):
			old.get_parent().remove_child(old)
			old.queue_free()
	var builder: Node = null
	var colours: Array = []
	for piece: String in want:
		if worn.has(piece) and int(worn[piece]) == int(want[piece]): continue
		if builder == null:
			var script := load(WARDROBE_PATH) as GDScript
			builder = script.new()
			colours = script.get("COLOURS")
		builder.call("_attach", avatar, piece, colours[int(want[piece]) % colours.size()])
		if slot("wear:%s:0" % piece) in ["head", "eyes"]:
			for node: Node in avatar.find_children("Wear_" + piece + "*", "", true, false):
				if node is GeometryInstance3D: (node as GeometryInstance3D).layers = FIRST_PERSON_HIDDEN_LAYER
				for mesh: Node in node.find_children("*", "GeometryInstance3D", true, false):
					(mesh as GeometryInstance3D).layers = FIRST_PERSON_HIDDEN_LAYER
	if builder == null: builder = (load(WARDROBE_PATH) as GDScript).new()
	builder.call("_update_original_hat", avatar, want)
	builder.free()
	avatar.set_meta("player_wear", want)
	if avatar.is_inside_tree():
		var form := avatar.get_tree().get_first_node_in_group("player_pony_form")
		if form != null and form.get("avatar") == avatar and form.has_method("refresh_body_visibility"): form.refresh_body_visibility()
