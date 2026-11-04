extends Control
const CURRENCY := preload("res://world/ui/currency.gd")
## Flat, event-driven interior. The same coordinates serve fingertip and mouse input.
signal dirty
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const HOTBAR := preload("res://world/inventory/wrist_hotbar.gd")
const SIZE := Vector2(1200,712)
const CLOSE := Rect2(1010,24,158,54)
const TAKE := Rect2(46,601,248,67)
const STORE := Rect2(318,601,270,67)
const GRID_ORIGIN := Vector2(48,120)
const CELL := Vector2(124,128)
const BITS_WIDTH := 272.0
const BITS_FONT_SIZE := 24
var inventory: RefCounted
var selected := -1
var hovered := -1
var message := ""
var carrying := ""
var _icons: Dictionary = {}
var _message_colour := Color("ff5252")
var _message_tween: Tween
func flash_message() -> void:
	if _message_tween != null: _message_tween.kill()
	_message_colour = Color("ff5252")
	_message_tween = create_tween()
	for pulse in 2:
		_message_tween.tween_method(_flash_colour, Color("ff5252"), Color("a52626"), 0.22)
		_message_tween.tween_method(_flash_colour, Color("a52626"), Color("ff5252"), 0.22)
	refresh()
func _flash_colour(colour: Color) -> void:
	_message_colour = colour; refresh()
func bind(store: RefCounted):
	inventory=store;size=SIZE;mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_to_group(CATALOG.ICON_CAMERA.GROUP)
	for id in CATALOG.ITEMS: _icons[id]=CATALOG.icon(id)
	store.changed.connect(refresh)
	refresh()
func refresh(): queue_redraw();dirty.emit()
## item_icon_camera.gd took this item's picture.
func icon_ready(id: String):
	_icons.erase(id);refresh()
func slot_rect(index: int) -> Rect2:
	return Rect2(GRID_ORIGIN+Vector2(index%9,index/9)*CELL,Vector2(116,118))
func slot_at(point: Vector2) -> int:
	for i in 27:
		if slot_rect(i).has_point(point):return i
	return -1
func bits_text() -> String:
	return CURRENCY.amount(inventory.bits if inventory != null else 0)
func text(value: String, at: Vector2, font_size: int, color: Color, width: float = -1):
	draw_string(CURRENCY.font(),at,CURRENCY.text(value),HORIZONTAL_ALIGNMENT_LEFT,width,font_size,color)
func _draw():
	draw_rect(Rect2(Vector2.ZERO,SIZE),Color("323734"))
	draw_rect(Rect2(16,16,1168,680),Color("a8a48b"),false,2)
	text("ANON'S BRIEFCASE",Vector2(46,66),36,Color("ede6ce"))
	text(bits_text(),Vector2(722,65),BITS_FONT_SIZE,_message_colour if message == "insufficient funds!" else Color("dac586"),BITS_WIDTH)
	draw_rect(CLOSE,Color("545951"));text("Close lid",Vector2(1021,62),28,Color("eee7d4"))
	text("BELONGINGS",Vector2(48,105),19,Color("bfc4b4"))
	# The first slots ride on the wrist (desktop: the bottom bar) as quick slots.
	draw_rect(Rect2(GRID_ORIGIN+Vector2(0,-6),Vector2(CELL.x*HOTBAR.SLOTS-8,3)),Color("dac586"))
	for i in 27:
		var rect:=slot_rect(i)
		draw_rect(rect,Color("202722"))
		draw_rect(Rect2(rect.position+Vector2(4,4),rect.size-Vector2(8,8)),Color("4a5145"))
		draw_rect(rect,Color("edcd84") if selected==i else Color("809681") if hovered==i else Color("929b82"),false,4 if selected==i else 2)
		if i<HOTBAR.SLOTS:text(str(i+1),rect.position+Vector2(8,26),18,Color("dac586"))
		if inventory==null or inventory.slots[i].is_empty() or int(inventory.slots[i].count)<=0:continue
		var entry:Dictionary=inventory.slots[i]
		if not _icons.has(entry.id):_icons[entry.id]=CATALOG.icon(entry.id)
		var icon:Texture2D=_icons.get(entry.id)
		if icon!=null:draw_texture_rect(icon,Rect2(rect.position+Vector2(19,9),Vector2(78,78)),false,Color(1,1,1,.35 if entry.count==0 else 1.))
		text(str(int(entry.count)),rect.position+Vector2(81,107),27,Color("faf2db"))
	var name_text:="Choose an item"
	var description:="Aim and press trigger to equip. Release items over the case to store."
	if selected>=0 and not inventory.slots[selected].is_empty():
		var def:Dictionary=CATALOG.definition(inventory.slots[selected].id)
		name_text=def.name;description=def.description
	text(name_text,Vector2(48,544),32,Color("f0e7ce"))
	text(message if not message.is_empty() else description,Vector2(48,579),22,_message_colour if message == "insufficient funds!" else Color("c6ccb6"))
	draw_rect(TAKE,Color("626e54"));text("Equip",Vector2(82,645),30,Color("fff0d3"))
	draw_rect(STORE,Color("535f53"));text("Put away",Vector2(356,645),30,Color("fff0d3"))
	text("Holding: "+(CATALOG.definition(carrying).get("name","") if not carrying.is_empty() else "nothing"),Vector2(621,641),25,Color("ddd7c1"))
	text("27 slots   ·   1-%d are your quick slots   ·   Grip handle to move   ·   Close lid to dismiss" % HOTBAR.SLOTS,Vector2(48,687),18,Color("bfc4b4"))
