extends "res://world/customization/clothing_view.gd"
## AnonPony's wardrobe (dev 2026-10-14): pony wear is a briefcase item. Pieces she wears are
## listed with Take off (back into the briefcase); pieces in the briefcase with Put on. Each
## change is saved at once (world/customization/clothing_profile.gd wear_pony_item /
## take_off_pony_item), so Done only closes. Anon's human clothes never show here.
const PONY_OUTFIT := preload("res://world/customization/pony_outfit.gd")
const WORN_TOP := 150
const CARRIED_TOP := 466
const ROW_HEIGHT := 50
const WORN_ROWS := 5
const CARRIED_ROWS := 4

## Dye swatches inside the worn thigh highs' row (dev 2026-10-28: more sock colours).
func sock_swatch_rect(row: Rect2, colour: int) -> Rect2: return Rect2(row.position.x + 96 + colour * 20, row.position.y + 12, 17, 20)

func _socks_colour(id: String) -> int:
	return PONY_OUTFIT.colour(id) if PONY_OUTFIT.kind(id) in ["socks", "plain-socks"] else -1

func worn_rect(index: int) -> Rect2: return Rect2(24, WORN_TOP + index * ROW_HEIGHT, 580, ROW_HEIGHT - 6)
func carried_rect(index: int) -> Rect2: return Rect2(24 + (index % 2) * 294, CARRIED_TOP + (index / 2) * ROW_HEIGHT, 286, ROW_HEIGHT - 6)

func set_store(value: RefCounted) -> void:
	if store != null and store.changed.is_connected(refresh): store.changed.disconnect(refresh)
	store = value
	if store != null: store.changed.connect(refresh)
	refresh()

func _exit_tree() -> void:
	if store != null and store.changed.is_connected(refresh): store.changed.disconnect(refresh)

func _worn() -> Array[String]:
	return profile.pony_items(profile.saved)

## Briefcase slots holding pony wear: [[slot index, id], ...], one row per kind of piece.
func _carried() -> Array:
	var rows: Array = []
	if store == null: return rows
	var seen := {}
	for index in store.slots.size():
		var id := str(store.slots[index].get("id", ""))
		if seen.has(id) or not PONY_OUTFIT.is_wear(id) or store.available(index) <= 0: continue
		seen[id] = true; rows.append([index, id])
	return rows

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SIZE), Color("282f32"))
	text("PONY WARDROBE", Vector2(34, 54), 35, Color("eadfc7"))
	text("Bought pony wear. Use a held piece, or the buttons here.", Vector2(36, 84), 19, Color("aebbae"))
	text("WEARING", Vector2(34, 136), 21, Color("cbd0c0"))
	var worn := _worn()
	if worn.is_empty(): text("Nothing yet.", Vector2(40, WORN_TOP + 30), 21, Color("909889"))
	for i in mini(worn.size(), WORN_ROWS):
		var rect := worn_rect(i)
		draw_rect(rect, Color("39413e"))
		var dyed := _socks_colour(worn[i])
		if dyed >= 0:
			text("Solid:" if PONY_OUTFIT.kind(worn[i]) == "plain-socks" else "Socks:", rect.position + Vector2(14, 30), 21, Color("f2e7d0"))
			var palette: Array = (load(PONY_OUTFIT.WARDROBE_PATH) as GDScript).get("COLOURS")
			for c in palette.size():
				var swatch := sock_swatch_rect(rect, c)
				if c == dyed: draw_rect(swatch.grow(3), Color("f2e7d0"))
				draw_rect(swatch, palette[c])
		else:
			text(PONY_OUTFIT.SLOT_LABELS.get(PONY_OUTFIT.slot(worn[i]), "") + ":  " + PONY_OUTFIT.display_name(worn[i]), rect.position + Vector2(14, 30), 21, Color("f2e7d0"))
		var button := Rect2(rect.end.x - 150, rect.position.y + 5, 140, rect.size.y - 10)
		draw_rect(button, Color("667b5c")); text("Take off", button.position + Vector2(26, 26), 19, Color("fff2d9"))
	text("IN YOUR BRIEFCASE", Vector2(34, CARRIED_TOP - 14), 21, Color("cbd0c0"))
	var carried := _carried()
	if carried.is_empty(): text("No pony wear. Rarity's Boutique sells some.", Vector2(40, CARRIED_TOP + 30), 21, Color("909889"))
	for i in mini(carried.size(), CARRIED_ROWS * 2):
		var rect := carried_rect(i)
		draw_rect(rect, Color("39413e"))
		text(PONY_OUTFIT.display_name(str(carried[i][1])), rect.position + Vector2(10, 28), 17, Color("f2e7d0"))
		var button := Rect2(rect.end.x - 86, rect.position.y + 5, 80, rect.size.y - 10)
		draw_rect(button, Color("667b5c")); text("Put on", button.position + Vector2(11, 26), 17, Color("fff2d9"))
	if carried.size() > CARRIED_ROWS * 2: text("and %d more in the briefcase" % (carried.size() - CARRIED_ROWS * 2), Vector2(330, CARRIED_TOP - 14), 17, Color("909889"))
	text("LIVE MIRROR", Vector2(821, 55), 25, Color("cbd0c0"))
	text(message, Vector2(34, 671), 21, Color("d9cfac"))
	draw_rect(SAVE, Color("667b5c")); text("Done", Vector2(128, 721), 27, Color("fff2d9"))
	for rect in [Rect2(680,682,72,52),Rect2(766,682,99,52),Rect2(879,682,72,52)]: draw_rect(rect, Color("515957"))
	text("‹", Vector2(703,719), 34, Color("dfdccb")); text("Front", Vector2(780,717), 24, Color("dfdccb")); text("›", Vector2(902,719), 34, Color("dfdccb"))

func choose(pixel: Vector2) -> bool:
	var worn := _worn()
	for i in mini(worn.size(), WORN_ROWS):
		if _socks_colour(worn[i]) >= 0:
			for c in PONY_OUTFIT.COLOUR_COUNT:
				if sock_swatch_rect(worn_rect(i), c).grow(1).has_point(pixel):
					message = profile.dye_pony_socks(store, c) if store != null else "The briefcase is not here."
					refresh(); return message.is_empty()
		if worn_rect(i).has_point(pixel) and (_socks_colour(worn[i]) < 0 or pixel.x >= worn_rect(i).end.x - 150):
			message = profile.take_off_pony_item(store, worn[i]) if store != null else "The briefcase is not here."
			refresh(); return message.is_empty()
	var carried := _carried()
	for i in mini(carried.size(), CARRIED_ROWS * 2):
		if carried_rect(i).has_point(pixel):
			message = profile.wear_pony_item(store, str(carried[i][1]), "", int(carried[i][0])) if store != null else "The briefcase is not here."
			refresh(); return message.is_empty()
	return false
