extends RefCounted
## Eligible owned goods. Blankets retain their separate picnic deployment contract.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
## Sizes a hung print can take, times its 16 x 12 cm card (dev 2026-11-03: "put them up on my wall
## with different sizes"): snapshot to poster.
const PRINT_SIZES := [1.0, 1.5, 2.0, 3.0, 5.0]
## Degrees the wheel turns floor furniture per step.
const TURN_DEGREES := 15.0
const SURFACES := {
	"goods:footstool": "floor", "goods:bedside-table": "floor",
	"goods:rug-round": "floor", "goods:doormat": "floor",
	"goods:floor-cushion": "floor", "goods:pillow": "floor",
	"goods:clock": "floor", "goods:cottage-tea-set": "floor",
	"goods:table-lamp": "floor", "goods:potted-plant": "floor",
	"goods:curtains": "wall", "goods:picture": "wall",
}

## Finished paintings ("art:<id>", world/painting/) hang like the framed picture.
static func has(id: String) -> bool:
	return SURFACES.has(id) or id.begins_with("art:")

static func wall(id: String) -> bool:
	return SURFACES.get(id, "") == "wall" or id.begins_with("art:")

## The sizes this item can be placed at; one entry means it has no choice.
static func sizes(id: String) -> Array:
	return PRINT_SIZES if REGISTRY.is_photo(REGISTRY.art_id(id)) else [1.0]

static func valid_loan(loan: Dictionary) -> bool:
	if not loan.has("furnishing_home"): return true
	if loan.has("furnishing_size"):
		var size: Variant = loan.furnishing_size
		if not (size is float or size is int) or not float(size) in sizes(str(loan.get("id", ""))): return false
	var home: Variant = loan.furnishing_home
	return home is String and not home.is_empty() and home.length() <= 120 and has(str(loan.get("id", ""))) and loan.has("world_transform") and not loan.get("equipped", false)
