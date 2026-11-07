extends RefCounted
## Using held things: eating bites, outfits and flight gear, usable checks and the item sounds.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.

const SFX := preload("res://world/audio/interaction_sounds.gd")
const ITEM_FOLEY := preload("res://world/audio/props_catalogue.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const SHOP_ITEMS := preload("res://world/shop/shop_items.gd")

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Using held clothes. Since 2026-10-14 (dev) bought human clothes live in Anon's wardrobe, not
## the briefcase; a carried outfit or pair of wing sandals is an older purchase: using it keeps
## it in the wardrobe for good and puts it on, as before. AnonPony never wears those
## (world/shop/shop_items.gd wardrobe_only); a held pony piece ("wear:") goes on her instead.
func wear_outfit(item: Node) -> bool:
	var id:=str(item.get_meta("item_id", ""))
	if host.clothing==null:return false
	if host._pony():return _wear_on_pony(item, id)
	if not SHOP_ITEMS.wardrobe_only(id):return false
	if not host.clothing.keep_bought(id):return false
	if id == SHOP_ITEMS.WING_SANDALS:
		if not host.clothing.commit_wing_sandals(not bool(host.clothing.data.get("wing_sandals", false))): return false
		_play_select();SFX.play_event(host,"prop_clothing",{},host.camera.global_position); return true
	var data:Dictionary=SHOP_ITEMS.outfit(id)
	if data.is_empty():return false
	var before:Dictionary=host.clothing.data.duplicate(true)
	if not host.clothing.apply_outfit(data):return false
	var saved:bool=host.clothing.save()
	if not saved:
		host.clothing.restore(before);return false
	_play_select();SFX.play_event(host,"prop_clothing",{},host.camera.global_position)
	print("[inventory] wearing ",item.get_meta("item_id",""))
	return saved


## AnonPony puts on the held piece: it leaves her magic/mouth and the briefcase and goes on her
## body (world/customization/clothing_profile.gd wear_pony_item); a piece she wore in that slot
## goes back into the briefcase.
func _wear_on_pony(item: Node, id: String) -> bool:
	if SHOP_ITEMS.wardrobe_only(id):
		host.inventory.last_error="That is tailored for Anon's human form.";host._error();return false
	if not SHOP_ITEMS.pony_wear(id):return false
	var token:=str(item.get_meta("token",""))
	var error:String=host.clothing.wear_pony_item(host.inventory,id,token)
	if not error.is_empty():
		host.inventory.last_error=error;host._error();return false
	for side:String in host.held.keys():
		if host.held[side]==item:
			host.held.erase(side);host._track.erase(side);host._claim(side,false);host._haptic(side)
	host.loose.erase(token);item.queue_free();host._refresh_holding()
	_play_select();SFX.play_event(host,"prop_clothing",{},host.camera.global_position)
	print("[inventory] AnonPony wears ",id)
	return true


## Held clothes the use action wears: older carried human clothes for Anon, pony wear for her.
func wearable(item: Node) -> bool:
	if not is_instance_valid(item):return false
	var id:=str(item.get_meta("item_id",""))
	return SHOP_ITEMS.pony_wear(id) if host._pony() else SHOP_ITEMS.wardrobe_only(id)


func _sync_flight_equipment() -> void:
	if is_instance_valid(host.player_body) and host.player_body.has_method("set_wing_sandals_equipped"):
		host.player_body.set_wing_sandals_equipped(bool(host.clothing.data.get("wing_sandals", false)))


func _mouth()->Vector3:
	return host.PLAYER_MOUTH.point(host.camera)


func _play_purchase(item:Node3D) -> void:
	SFX.play_event(item,"prop_coins")


func _play_food_use(id:String,at:Vector3) -> void:
	if is_instance_valid(host.camera):SFX.play_event(host.camera,ITEM_FOLEY.food_cue_for_item(id),{},at)


func _play_item_pickup(item:Node3D) -> void:
	SFX.play_event(item,"prop_pickup",{"material":ITEM_FOLEY.material_for_item(str(item.get_meta("item_id","")))})


func _play_select() -> void:
	SFX.play_at(host, "select", host.hotbar.global_position if not host._desktop else host.camera.global_position)


func _play_deposit() -> void:
	SFX.play_at(host, "stow", host.case.global_position if host.case.visible else host.camera.global_position)


static func _bite_audio() -> AudioStream:
	var bites := AudioStreamRandomizer.new()
	bites.random_pitch = 1.04
	for index in range(1, 4):
		var path := "res://world/audio/eating/eat%d.wav" % index
		var sound := AudioStreamWAV.load_from_file(path)
		if sound != null: bites.add_stream(-1, sound)
	return bites if bites.streams_count > 0 else _make_crunch()


static func _make_crunch()->AudioStreamWAV:
	var wav:=AudioStreamWAV.new();wav.format=AudioStreamWAV.FORMAT_16_BITS;wav.mix_rate=22050
	var length:=3600;var bytes:=PackedByteArray();bytes.resize(length*2)
	var noise:=RandomNumberGenerator.new();noise.seed=7
	var low:=0.
	for i in length:
		var t:=float(i)/length
		# A few sharp cracks over a fading, band-limited rustle.
		var crack:=0.
		for at in [.02,.13,.27,.41]:crack+=exp(-absf(t-at)*160.)
		low=lerpf(low,noise.randf_range(-1.,1.),.35)
		var value:=low*(.25+crack)*exp(-4.*t)*.9
		bytes.encode_s16(i*2,roundi(clampf(value,-1.,1.)*32767))
	wav.data=bytes;return wav


## Something in hand that a click uses: food and drink to eat, clothes to wear (the spray bottle
## and books are handled before this), writing paper, letters and the quill (world/letters/).
## Anything else lets the click reach the world. Human clothes are Anon's only and pony wear
## AnonPony's only (wearable).
func held_usable(item: Node) -> bool:
	if not is_instance_valid(item): return false
	var id:=str(item.get_meta("item_id",""))
	if id.begins_with("goods:paper-") or id == "goods:quill" or id.begins_with("letter:") or id == "notebook" or id == "photo-journal": return true
	return id == "goods:folded-blanket" or id == "goods:easel" or id == "goods:game-board" or id in host.EDIBLE or FOOD.CATALOG.can_consume(id) or wearable(item)
