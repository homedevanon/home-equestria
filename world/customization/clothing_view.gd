extends Control
signal dirty
const SIZE := Vector2(1200,760)
const SAVE := Rect2(32,688,252,48)
const HEIGHT := Rect2(966,682,204,52)
var height_available := false
const CANCEL := Rect2(300,688,252,48)
const GARMENTS := preload("res://world/customization/anon_garments.gd")
## Colour rows, then one wear/remove button per garment under them.
const ROW := 116
## Cycles the starting suit and every outfit bought at Rarity's Boutique (dev 2026-10-14).
const OUTFIT := Rect2(404,22,200,68)
const LOCKED_MESSAGE := "Locked: buy an outfit with it at Rarity's Boutique."
const PROFILE_ITEMS := "res://world/shop/shop_items.gd"
var outfit_index := 0
const CLUB_SCARF := "wear:4cc-scarf:0"
## The briefcase (world/inventory/inventory_store.gd), set by clothing_customizer.gd.
var store: RefCounted
## Three garment buttons; a fourth, narrower set while Anon wears the cup scarf (take it off here).
func scarf_worn() -> bool:return profile!=null and profile.pony_items(profile.saved).has(CLUB_SCARF)
func wear_rect(index: int) -> Rect2:return Rect2(24+index*146,578,138,52) if scarf_worn() else Rect2(24+index*197,578,186,52)
func shoe_rect(index: int) -> Rect2:return Rect2(164+index*164,578,152,52)
var profile: RefCounted
var message := ""
func bind(settings: RefCounted):
	profile=settings;size=SIZE;mouse_filter=Control.MOUSE_FILTER_IGNORE
	profile.changed.connect(refresh);refresh()
func refresh():queue_redraw();dirty.emit()
func swatch_rect(row: int, index: int) -> Rect2:return Rect2(38+index*61,140+row*ROW,50,33)
func pattern_rect(row: int) -> Rect2:return Rect2(38,180+row*ROW,276,33)
func scale_rect(row: int) -> Rect2:return Rect2(327,180+row*ROW,158,33)
func reset_rect(row: int) -> Rect2:return Rect2(498,180+row*ROW,89,33)
func text(value: String, at: Vector2, pixels: int, color: Color):draw_string(ThemeDB.fallback_font,at,value,HORIZONTAL_ALIGNMENT_LEFT,-1,pixels,color)
func _draw():
	draw_rect(Rect2(Vector2.ZERO,SIZE),Color("282f32"))
	text("ANON'S WARDROBE",Vector2(34,54),35,Color("eadfc7"))
	text("Clothes bought at Rarity's Boutique",Vector2(36,84),21,Color("aebbae"))
	var outfits:=_outfit_cycle()
	draw_rect(OUTFIT,Color("505b52"));draw_rect(OUTFIT,Color("909889"),false,1)
	text("Outfit  ›" if outfits.size()>1 else "Outfit",OUTFIT.position+Vector2(12,26),21,Color("f2e7d0"))
	text(_outfit_name(outfits[outfit_index%outfits.size()]) if outfits.size()>1 else "Starting suit only",OUTFIT.position+Vector2(12,54),16,Color("cbd0c0"))
	text("LIVE MIRROR",Vector2(821,55),25,Color("cbd0c0"))
	for row in 4:
		var part:String=profile.PARTS[row];var choice:Dictionary=profile.data[part];var y:=102+row*ROW
		draw_rect(Rect2(24,y,580,112),Color("39413e"))
		text(part.capitalize(),Vector2(38,y+30),27,Color("f2e7d0"))
		var palette_name:String="Original" if choice.color<0 else profile.PALETTES[part][int(choice.color)].split(":")[0]
		text(palette_name,Vector2(219,y+29),21,Color("cbd0c0"))
		for i in 9:
			var rect:=swatch_rect(row,i)
			var color:=Color("333a3d") if i==0 else Color(profile.PALETTES[part][i-1].split(":")[1])
			var unlocked:bool=profile.colour_unlocked(part,i-1)
			draw_rect(rect,color if unlocked else color.darkened(.62))
			draw_rect(rect,Color("ebce8d") if int(choice.color)==i-1 else Color("909889"),false,3 if int(choice.color)==i-1 else 1)
			if i==0:text("↺",rect.position+Vector2(15,26),27,Color("dfd8c3"))
			elif not unlocked:_lock(rect.get_center())
		for rect in [pattern_rect(row),scale_rect(row),reset_rect(row)]:draw_rect(rect,Color("505b52"))
		text("Pattern: "+profile.PATTERNS[int(choice.pattern)].capitalize()+"  ›",Vector2(48,y+103),21,Color("e1e2ce"))
		text(["Large","Medium","Fine"][int(choice.scale)]+"  ›",Vector2(340,y+103),21,Color("e1e2ce"))
		text("Reset",Vector2(513,y+103),21,Color("e1e2ce"))
	for i in (GARMENTS.GARMENTS.size() if profile.can_remove_garments() else 0):
		var garment:String=GARMENTS.GARMENTS[i];var on:bool=profile.is_worn(garment);var rect:=wear_rect(i)
		var label:String=GARMENTS.LABELS[garment]
		var state:="Wearing  ·  take off" if on else "Off  ·  put on"
		if garment=="shoes" and profile.owns(profile.WING_SANDALS):
			var feet:String=profile.footwear()
			on=feet!="barefoot";label="Footwear"
			state={"shoes":"Shoes","sandals":"Wing sandals","barefoot":"Barefoot"}[feet]+"  ·  change"
		var narrow:=scarf_worn()
		if narrow:
			label={"top":"Jacket & shirt"}.get(garment,label)
			state=state.replace("Wearing  ·  take off","On · take off").replace("Off  ·  put on","Off · put on").replace("  ·  change"," · change")
		draw_rect(rect,Color("667b5c") if on else Color("464d4b"))
		draw_rect(rect,Color("ebce8d") if on else Color("909889"),false,2)
		text(label,rect.position+Vector2(8 if narrow else 12,22),15 if narrow else 18,Color("f2e7d0"))
		text(state,rect.position+Vector2(8 if narrow else 12,44),13 if narrow else 17,Color("cbd0c0"))
	if scarf_worn() and profile.can_remove_garments():
		var rect:=wear_rect(GARMENTS.GARMENTS.size())
		draw_rect(rect,Color("667b5c"));draw_rect(rect,Color("ebce8d"),false,2)
		text("/mlp/ cup scarf",rect.position+Vector2(8,22),15,Color("f2e7d0"))
		text("On · take off",rect.position+Vector2(8,44),13,Color("cbd0c0"))
	if profile.can_color_shoes():
		text("Shoes",Vector2(38,610),27,Color("f2e7d0"))
		for i in profile.SHOE_COLOURS.size():
			var rect:=shoe_rect(i);var selected:bool=int(profile.data.get("shoe_color",0))==i
			draw_rect(rect,Color("667b5c") if selected else Color("464d4b"))
			draw_rect(rect,Color("ebce8d") if selected else Color("909889"),false,2)
			text(profile.SHOE_COLOURS[i],rect.position+Vector2(28,34),25,Color("f2e7d0"))
	text(message,Vector2(34,661),21,Color("d9cfac"))
	draw_rect(SAVE,Color("667b5c"));text("Save outfit",Vector2(78,721),27,Color("fff2d9"))
	draw_rect(CANCEL,Color("515957"));text("Cancel",Vector2(375,721),27,Color("e0dfcf"))
	for rect in [Rect2(680,682,72,52),Rect2(766,682,99,52),Rect2(879,682,72,52)]:draw_rect(rect,Color("515957"))
	if height_available:
		draw_rect(HEIGHT,Color("667b5c"));text("Calibrate height",HEIGHT.position+Vector2(12,34),23,Color("fff2d9"))
	text("‹",Vector2(703,719),34,Color("dfdccb"));text("Front",Vector2(780,717),24,Color("dfdccb"));text("›",Vector2(902,719),34,Color("dfdccb"))
## A small padlock over a colour still for sale.
func _lock(at: Vector2) -> void:
	draw_arc(at+Vector2(0,-3),5.5,PI,TAU,10,Color("cfc6ad"),2.0)
	draw_rect(Rect2(at+Vector2(-7.5,-3),Vector2(15,11)),Color("cfc6ad"))

## The starting suit ("") and every bought outfit, in shop order.
func _outfit_cycle() -> Array[String]:
	var result:Array[String]=[""]
	result.append_array(profile.owned_outfits())
	return result

func _outfit_name(id: String) -> String:
	if id.is_empty():return "Starting suit"
	return str((load(PROFILE_ITEMS) as GDScript).call("definition",id).get("name",id))

## The next outfit's colours and patterns (still a draft until Save outfit).
func _next_outfit() -> bool:
	var outfits:=_outfit_cycle()
	if outfits.size()<2:message="Outfits bought at Rarity's Boutique hang here.";refresh();return true
	outfit_index=(outfit_index+1)%outfits.size()
	var id:=outfits[outfit_index]
	var rows:Dictionary={}
	if id.is_empty():
		for part:String in profile.PARTS:rows[part]=profile.defaults()[part]
	else:rows=(load(PROFILE_ITEMS) as GDScript).call("outfit",id)
	message=""
	return profile.apply_outfit(rows)

## The next pattern this wardrobe has (plain, then any bought pattern).
func _next_pattern(current: int) -> int:
	for step in range(1,profile.PATTERNS.size()+1):
		var index:int=(current+step)%int(profile.PATTERNS.size())
		if profile.pattern_unlocked(index):return index
	return 0

func choose(pixel: Vector2) -> bool:
	if OUTFIT.has_point(pixel):return _next_outfit()
	if profile.can_color_shoes():
		for i in profile.SHOE_COLOURS.size():
			if shoe_rect(i).has_point(pixel):return profile.choose_shoe_colour(i)
	if scarf_worn() and profile.can_remove_garments() and wear_rect(GARMENTS.GARMENTS.size()).has_point(pixel):
		# Back into the briefcase, saved at once like every pony-wear change.
		message=profile.take_off_pony_item(store,CLUB_SCARF) if store!=null else "The briefcase is not here."
		refresh();return true
	for i in (GARMENTS.GARMENTS.size() if profile.can_remove_garments() else 0):
		if wear_rect(i).has_point(pixel):
			var garment:String=GARMENTS.GARMENTS[i]
			if garment=="shoes" and profile.owns(profile.WING_SANDALS):
				var order:=["shoes","sandals","barefoot"]
				var next:String=order[(order.find(profile.footwear())+1)%order.size()]
				var done:bool=profile.set_footwear(next)
				message="" if done else profile.last_error
				if not done:refresh()
				return done
			return profile.set_worn(garment,not profile.is_worn(garment))
	for row in 4:
		var part:String=profile.PARTS[row]
		for i in 9:
			if swatch_rect(row,i).has_point(pixel):
				if not profile.colour_unlocked(part,i-1):message=LOCKED_MESSAGE;refresh();return true
				message="";return profile.choose(part,"color",i-1)
		if pattern_rect(row).has_point(pixel):
			var pattern:=_next_pattern(int(profile.data[part].pattern))
			if pattern==int(profile.data[part].pattern):message="More patterns come with outfits from Rarity's Boutique.";refresh();return true
			message="";return profile.choose(part,"pattern",pattern)
		if scale_rect(row).has_point(pixel):return profile.choose(part,"scale",(int(profile.data[part].scale)+1)%profile.SCALES.size())
		if reset_rect(row).has_point(pixel):profile.reset(part);return true
	return false
