extends RefCounted
## Shop goods that are not food (bulk prompt package 10, dev 2026-09-29/30): small household
## things to carry home and set down anywhere (they persist where they are put, as owned
## drops), and Anon's outfits from Rarity's Boutique (colour and pattern sets for his existing
## suit, shirt, tie and trousers, kept in his wardrobe once bought).
## Ids: "goods:<model>" and "outfit:<name>". Prices follow docs/DECISIONS_AND_AUDIT_2026_09_30.md; every outfit and piece of
## pony wear costs 50 bits and the wing sandals 200 (dev 2026-10-22).
const VISUAL := preload("res://world/shop/shop_item_visual.gd")
const CIDER := preload("res://world/items/cider_keg.gd")
## The apple sapling sold at the farm stall (P5, planted in Anon's row at Sweet Apple Acres).
const SAPLING := preload("res://world/items/apple_sapling.gd")
const HOUSEHOLD := "res://world/props/household/%s.glb"
## model: [name, target longest edge in metres, price, description]. Every row stays a valid
## item (owned pieces persist where they were set down); only some are stocked
## (shop_world.gd PLACEMENTS; trimmed 2026-10-15, see world/shop/archived_stock.json).
const GOODS := {
	"pillow": ["Pillow", 0.55, 15, "A soft pillow. Put it anywhere."],
	"folded-blanket": ["Folded blanket", 0.5, 20, "A warm blanket, folded."],
	"cottage-tea-set": ["Tea set", 0.45, 25, "A cottage tea set on a little tray."],
	"clock": ["Clock", 0.35, 30, "A cheerful clock."],
	"floor-cushion": ["Floor cushion", 0.62, 25, "Something soft to sit on."],
	"doormat": ["Doormat", 0.9, 10, "Wipe your hooves. Or feet."],
	"footstool": ["Footstool", 0.62, 40, "A little stool for tired legs."],
	"rug-round": ["Round rug", 1.5, 45, "A round rug for any floor."],
	"bedside-table": ["Bedside table", 0.55, 60, "A small table for beside a bed or chair."],
	"curtains": ["Curtains", 1.5, 45, "Hang these at a window in your home."],
	"table-lamp": ["Table lamp", 0.6, 55, "Place it in your home, then switch its light on or off."],
	"picture": ["Framed picture", 0.65, 25, "Hang this picture on a wall in your home."],
	"potted-plant": ["Potted plant", 0.55, 20, "Set this plant on a floor or table in your home."],
	# The folding painting easel (world/painting/, 2026-10-22; the price is a proposal for dev).
	"easel": ["Folding easel", 1.55, 60, "Unfold it on flat ground to paint. Brush, pencil, scraper and paints come with it."],
	# The photo camera (world/items/photo_camera.gd, dev 2026-10-25; the price is a proposal for dev).
	"camera": ["Photo camera", 0.145, 80, "Hold the eyepiece to your eye to frame a shot (right click on desktop). Trigger or click takes the photo, and it prints."],
	# The folding chess and checkers board (world/minigames/board_games/board_fold.gd, 2026-10-26).
	"game-board": ["Folding game board", 0.5, 35, "Chess and checkers in a folding case. Unfold it on flat ground and ask a pony to play."],
	# Letter writing (world/letters/, docs/LETTERS_PLAN_2026_10_29.md; prices are proposals for dev and
	# match world/letters/stationery.gd PRICES). Fancier paper makes a letter a little nicer.
	"paper-plain": ["Plain writing paper", 0.22, 2, "A sheet for a letter. Click or trigger to start writing; start with Dear and her name."],
	"paper-cream": ["Cream writing paper", 0.22, 4, "Soft cream paper for a letter. Click or trigger to start writing."],
	"paper-floral": ["Floral writing paper", 0.22, 8, "Paper with flowers in the margin. A letter on it is a little nicer."],
	"paper-hearts": ["Writing paper with hearts", 0.22, 10, "Paper with little hearts in the margin, for a letter that means a lot."],
	# A stand-in model (the painting brush) until a quill is modelled through the Blender MCP.
	"quill": ["Quill", 0.27, 15, "In VR, hold the quill to the open paper and speak: your words are written down. Say \"scratch that\" to cross out the last sentence."],
}
## Goods that stack in one briefcase slot (the rest stack 1).
const GOODS_STACKS := {"paper-plain": 10, "paper-cream": 10, "paper-floral": 10, "paper-hearts": 10}
## Reuse installed authored models; their in-hand size is also their placed size.
const GOODS_MODELS := {
	"table-lamp": "res://world/props/lamps/kit/table_lamp.glb",
	"picture": "res://world/buildings/cloudominium/models/room_pack/rd_picture.scn",
	"potted-plant": "res://world/props/rnl/rnl_plantpot/prefab.scn",
	"easel": "res://world/painting/models/easel_folded.glb",
	"camera": "res://world/inventory/assets/camera/camera.glb",
	"paper-plain": "res://world/props/ponyville_kit/activity/letter.scn",
	"paper-cream": "res://world/props/ponyville_kit/activity/letter.scn",
	"paper-floral": "res://world/props/ponyville_kit/activity/letter.scn",
	"paper-hearts": "res://world/props/ponyville_kit/activity/letter.scn",
	"quill": "res://world/painting/models/brush.glb",
}
## Clothing profile values: part -> [colour index, pattern index, scale index]
## (world/customization/clothing_profile.gd PALETTES/PATTERNS/SCALES).
const OUTFITS := {
	"ponyville-casual": ["Ponyville casual", 50, {"suit": [4, 0, 1], "tie": [2, 0, 1], "pants": [7, 0, 1], "shirt": [4, 0, 1]}],
	"canterlot-evening": ["Canterlot evening", 50, {"suit": [1, 1, 1], "tie": [6, 0, 1], "pants": [1, 1, 1], "shirt": [1, 0, 1]}],
	"farm-work": ["Sweet Apple work clothes", 50, {"suit": [3, 3, 1], "tie": [3, 0, 1], "pants": [5, 0, 1], "shirt": [6, 0, 1]}],
	"pajamas": ["Pajamas", 50, {"suit": [6, 2, 2], "tie": [5, 0, 1], "pants": [6, 2, 2], "shirt": [5, 0, 1]}],
	"winter-tweed": ["Winter tweed", 50, {"suit": [5, 3, 0], "tie": [0, 0, 1], "pants": [0, 0, 1], "shirt": [0, 0, 1]}],
	"boutique-special": ["Rarity's boutique special", 50, {"suit": [6, 4, 1], "tie": [4, 0, 1], "pants": [0, 0, 1], "shirt": [3, 0, 1]}],
	# Added 2026-10-14 so every wardrobe colour can be bought in some outfit.
	"manehattan-business": ["Manehattan business suit", 50, {"suit": [2, 1, 1], "tie": [1, 0, 1], "pants": [2, 1, 1], "shirt": [2, 0, 1]}],
	"saddle-arabian-travel": ["Saddle Arabian travel suit", 50, {"suit": [7, 0, 1], "tie": [7, 0, 1], "pants": [3, 0, 1], "shirt": [7, 0, 1]}],
	"whitetail-tweed": ["Whitetail Woods tweed", 50, {"suit": [0, 3, 1], "tie": [2, 0, 1], "pants": [4, 0, 1], "shirt": [6, 0, 1]}],
}
## Who can wear what (dev 2026-10-14, "make sure they don't cross over"):
## - Anon's human clothes (outfits, wing sandals) are bought once and kept for good in his
##   wardrobe (world/customization/clothing_profile.gd owned); they never become briefcase items.
##   Only human Anon can buy them.
## - Pony wear ("wear:") is a briefcase item. AnonPony puts it on and takes it off back into the
##   briefcase (world/customization/pony_outfit.gd), or gives it to a mare. Only AnonPony can buy it;
##   pieces bought before this change stay in the briefcase and can still be given.
const WING_SANDALS := "equipment:wing-sandals"
## Pony accessories to give (world/characters/accessories/pony_wardrobe.gd); ids are
## "wear:<kind>:<colour index>". She wears a gift whatever the season.
const WEAR := {"scarf": ["scarf", 50], "beanie": ["detective hat", 50], "sunhat": ["cowpony hat", 50], "socks": ["striped thigh highs", 50],
	"wizard_hat": ["wizard hat", 50], "cape": ["starry cape", 50], "spa-necklace": ["spa pendant", 50], "bowtie": ["bow tie", 50], "necktie": ["necktie", 50], "cowpony-hat": ["cowpony hat", 50], "detective-hat": ["detective hat", 50], "nurse-cap": ["nurse cap", 50],
	"cat-eye-glasses": ["cat-eye glasses", 50], "aviators": ["aviator glasses", 50], "goggles": ["flight goggles", 50], "headphones": ["headphones", 50]}
const FITTED_WEAR := ["spa-necklace", "bowtie", "necktie", "cowpony-hat", "detective-hat", "nurse-cap", "cat-eye-glasses", "aviators", "goggles", "headphones"]
## Index-matched with pony_wardrobe.gd COLOURS; the last eight are wardrobe-mirror dyes.
const WEAR_COLOURS := ["red", "blue", "gold", "green", "purple", "pink", "cream", "charcoal",
	"orange", "sky blue", "teal", "lime", "brown", "pastel pink", "lavender", "navy"]
static var _scenes: Dictionary = {}
static var _icons: Dictionary = {}

static func has(id: String) -> bool:
	if id == WING_SANDALS: return true
	if CIDER.is_keg(id): return true
	if SAPLING.is_sapling(id): return true
	if id.begins_with("wear:"):
		var parts := id.split(":")
		if parts.size() == 3 and parts[1] in FITTED_WEAR: return parts[2] == "0"
		return parts.size() == 3 and WEAR.has(parts[1]) and parts[2].is_valid_int() and int(parts[2]) >= 0 and int(parts[2]) < WEAR_COLOURS.size()
	if id.begins_with("goods:"): return GOODS.has(id.substr(6))
	if id.begins_with("outfit:"): return OUTFITS.has(id.substr(7))
	return false

static func kind(id: String) -> String:
	return id.get_slice(":", 0) if has(id) else ""

## Human-only clothes: unlocked in Anon's wardrobe when bought, never carried.
static func wardrobe_only(id: String) -> bool:
	return id == WING_SANDALS or (id.begins_with("outfit:") and OUTFITS.has(id.substr(7)))

## Pony-only wear: a briefcase item AnonPony can put on.
static func pony_wear(id: String) -> bool:
	return id.begins_with("wear:") and has(id)

## The line under a price card: who it is for.
static func form_note(id: String, owned: bool = false) -> String:
	if wardrobe_only(id): return "In your wardrobe" if owned else "Anon's wardrobe (human)"
	if pony_wear(id): return "Pony wear · or a gift for a pony"
	return ""

## What comes with a good when it is bought (into the briefcase, same payment).
static func extras(id: String) -> Array[String]:
	if id == CIDER.ID: return [CIDER.MUG_EMPTY, CIDER.MUG_EMPTY]
	return []

static func definition(id: String) -> Dictionary:
	if CIDER.is_keg(id): return CIDER.definition(id)
	if SAPLING.is_sapling(id): return SAPLING.definition(id)
	if id == WING_SANDALS:
		return {"name": "Hercules wing sandals", "description": "Kept in Anon's wardrobe once bought: choose them as footwear there. F takes off; hold Space to flap, release to glide, S to brake; left/right mouse banks left/right. In VR use A to take off and flap, B to land. Wingbeats use stamina; gliding restores it.", "stack": 1, "price_bits": 200, "shop": true}
	if id.begins_with("goods:") and GOODS.has(id.substr(6)):
		var row: Array = GOODS[id.substr(6)]
		return {"name": row[0], "description": row[3], "stack": int(GOODS_STACKS.get(id.substr(6), 1)), "price_bits": row[2], "size_m": row[1], "shop": true}
	if id.begins_with("wear:") and has(id):
		var parts := id.split(":")
		var noun: String = WEAR[parts[1]][0]
		var name: String = noun.capitalize() if parts[1] in FITTED_WEAR or parts[1] in ["wizard_hat", "cape", "beanie", "sunhat"] else (str(WEAR_COLOURS[int(parts[2])]).capitalize() + " " + noun)
		if parts[1] in FITTED_WEAR:
			return {"name": name, "description": "Pony wear for an adult mare. As a pony, use it to put it on; or hold it up to a mare to give it to her.", "stack": 1, "price_bits": WEAR[parts[1]][1], "shop": true}
		return {"name": name, "description": "Pony wear. As a pony, use it to put it on; or hold it up to a pony to give it to her.", "stack": 1, "price_bits": WEAR[parts[1]][1], "shop": true}
	if id.begins_with("outfit:") and OUTFITS.has(id.substr(7)):
		var row: Array = OUTFITS[id.substr(7)]
		return {"name": row[0], "description": "Anon's clothes. Bought once, kept in his wardrobe for good.", "stack": 1, "price_bits": row[1], "shop": true}
	return {}

static func price_bits(id: String) -> int:
	return int(definition(id).get("price_bits", 0))

## Clothing profile data (clothing_profile.gd format) for an outfit.
static func outfit(id: String) -> Dictionary:
	if not id.begins_with("outfit:") or not OUTFITS.has(id.substr(7)): return {}
	var parts: Dictionary = OUTFITS[id.substr(7)][2]
	var result := {}
	for part: String in parts:
		result[part] = {"color": int(parts[part][0]), "pattern": int(parts[part][1]), "scale": int(parts[part][2])}
	return result

static func scene(id: String) -> PackedScene:
	if not has(id): return null
	if not _scenes.has(id):
		var visual: Node3D = VISUAL.new()
		visual.name = "ShopItem"
		visual.item_id = id
		var packed := PackedScene.new()
		var result := packed.pack(visual)
		visual.free()
		if result != OK: return null
		_scenes[id] = packed
	return _scenes[id]

## A small flat badge: the item's initials on its colour (outfits: the suit colour).
static func icon(id: String) -> Texture2D:
	if not has(id): return null
	if _icons.has(id): return _icons[id]
	var colour := Color("8a6a4a")
	if CIDER.is_keg(id): colour = Color("c98b3a")
	if SAPLING.is_sapling(id): colour = Color("6f9a3c")
	if kind(id) == "outfit":
		var suit: Array = OUTFITS[id.substr(7)][2].suit
		colour = Color(str(preload("res://world/customization/clothing_profile.gd").PALETTES.suit[int(suit[0])]).get_slice(":", 1))
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length()
			if d < 30.0: image.set_pixel(x, y, colour.darkened(0.25) if d > 26.0 else colour)
	var texture := ImageTexture.create_from_image(image)
	_icons[id] = texture
	return texture
