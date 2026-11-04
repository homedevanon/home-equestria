extends RefCounted
## A drawn symbol for ponies whose cutie mark is blank in the map icon atlas but who do have one
## (world/ui/pony_map_icons.json marks the princesses "blank": their marks are painted into the
## fitted body texture). Thread 43671981: Celestia's journal and AI-context portrait was an empty
## white disc. Fillies without a cutie mark keep the plain disc. The icons and tints match the
## journal picture's princess looks (journal_page.gd LOOK_TINTS, journal_picture.gd LOOK_NAMES),
## deepened where her coat is pale so the symbol reads on it.
const ICON := preload("res://world/ui/menu_icon.gd")
const SYMBOLS := {"celestia": ["sun", Color("e0a028")], "luna": ["moon", Color("aabdff")]}


static func has_symbol(id: String) -> bool:
	return SYMBOLS.has(id)


## Adds her symbol inside `disc` (a square portrait control of `side` pixels); false when she has none.
static func add_to(disc: Control, id: String, side: float) -> bool:
	if not SYMBOLS.has(id) or disc == null: return false
	var entry: Array = SYMBOLS[id]
	var icon: Control = ICON.make(str(entry[0]), side * 0.62, entry[1])
	icon.name = "PonySymbol"
	icon.position = Vector2.ONE * side * 0.19
	disc.add_child(icon)
	return true

