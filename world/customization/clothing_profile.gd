extends RefCounted
signal changed
const PARTS := ["suit","tie","pants","shirt"]
const PATTERNS := ["plain","pinstripe","windowpane","herringbone","diagonal"]
const SCALES := [12.,24.,48.]
const PALETTES := {
	"suit":["Charcoal:34383b","Midnight:303d50","Slate:535e66","Chocolate:51443c","Olive:55584a","Taupe:777065","Wine:563e49","Stone:94948a"],
	"tie":["Burgundy:713b49","Navy:394b63","Forest:465d50","Rust:945e48","Gold:978052","Plum:65506d","Silver:96988e","Ink:34383e"],
	"pants":["Charcoal:34383b","Midnight:303d50","Slate:535e66","Chocolate:51443c","Olive:55584a","Taupe:777065","Wine:563e49","Stone:94948a"],
	"shirt":["Ivory:dfd9ca","Pearl:d5d6cf","Blue:b4c3cc","Rose:cfb9b7","Sage:bfc5b5","Lavender:c4bdcf","Sand:cfc4af","Grey:b7babc"]
}
const SAVE_FILE := preload("res://world/save_file.gd")
## Separate garments over Anon's unclothed base (world/customization/anon_garments.gd).
## Saved as clothes.worn inside the same version 1 document: older builds ignore the key, and
## a save without it loads fully dressed, so nothing undresses on migration.
const GARMENTS := preload("res://world/customization/anon_garments.gd")
const SHADER := preload("res://world/customization/anon_clothing.gdshader")
const MASK_PATH := "res://world/customization/clothing_mask.png"
const EXPRESSIONS_VARIANT := "expressions_2026_10_04"
const EXPRESSIONS_SHADER := preload("res://world/customization/anon_expressions_clothing.gdshader")
const EXPRESSIONS_MASK_PATH := "res://world/customization/anon_expressions_clothing_mask.res"
const EXPRESSIONS_SHOE_MASK_PATH := "res://world/customization/anon_expressions_shoe_mask.res"
const SHOE_COLOURS := ["Black", "Brown"]
## Bought clothes (dev 2026-10-14: "change the wardrobe to be a storage system"). A new game owns
## only the starting suit, shirt, tie, trousers and shoes in their original colours. Buying an
## outfit or the wing sandals at Rarity's Boutique adds its id to `owned` for good (never a
## briefcase item); an owned outfit unlocks its colours for its parts and its patterns for all
## parts. Saves from before this keep everything they were wearing as `colour:`/`pattern:` rows.
## AnonPony's worn pieces are briefcase items on loan to her body: `pony_wear` (plus the older
## `pony_socks` row for thigh highs), see world/customization/pony_outfit.gd.
const ITEMS_PATH := "res://world/shop/shop_items.gd"
const PONY_OUTFIT := preload("res://world/customization/pony_outfit.gd")
## Loaded at use, not preloaded: the briefcase store reaches this file through the item catalogue.
const STORE_PATH := "res://world/inventory/inventory_store.gd"
const MAX_OWNED := 256
const MAX_PONY_WEAR := 16
const WING_SANDALS := "equipment:wing-sandals"
const BROWN_SHOE_TINT := Color("65412b")
var data: Dictionary = defaults()
var saved: Dictionary = defaults()
var path := ""
var last_error := ""
var writable := true
var _materials: Array[ShaderMaterial] = []
var _actors: Array[WeakRef] = []
var _pony_actors: Array[WeakRef] = []
var flight_model: RefCounted
static func defaults() -> Dictionary:
	var result:Dictionary={}
	for part in PARTS:result[part]={"color":-1,"pattern":0,"scale":1}
	result["worn"]=dressed()
	result["pony_socks"]={"worn":false,"color":5}
	result["shoe_color"]=0
	result["wing_sandals"]=false
	result["owned"]=[]
	result["pony_wear"]=[]
	return result
static func dressed() -> Dictionary:
	var worn:Dictionary={}
	for garment:String in GARMENTS.GARMENTS:worn[garment]=true
	return worn
## A copy with integer fields and a complete worn set (missing garments stay on).
static func normalized(value: Dictionary) -> Dictionary:
	var result:=value.duplicate(true)
	for part in PARTS:
		for field in ["color","pattern","scale"]:result[part][field]=int(result[part][field])
	var worn:=dressed()
	var given:Variant=value.get("worn")
	if given is Dictionary:
		for garment:String in worn:
			if given.get(garment) is bool:worn[garment]=given[garment]
	result["worn"]=worn
	result["pony_socks"]=value.get("pony_socks",defaults().pony_socks).duplicate()
	result.pony_socks.color=int(result.pony_socks.color)
	result["shoe_color"]=int(value.get("shoe_color",0))
	result["wing_sandals"]=bool(value.get("wing_sandals",false))
	# Before the boutique sold clothes everything was free: keep what was being worn.
	var owned:Array=[]
	for entry:Variant in (value.owned if value.get("owned") is Array else legacy_owned(result)):
		if entry is String and owned_entry(entry) and not owned.has(entry):owned.append(entry)
	result["owned"]=owned
	var pony:Array=[]
	var slots:={}
	if value.get("pony_wear") is Array:
		for entry:Variant in value.pony_wear:
			if entry is String and PONY_OUTFIT.is_wear(entry) and PONY_OUTFIT.kind(entry)!="socks" and not slots.has(PONY_OUTFIT.slot(entry)):
				slots[PONY_OUTFIT.slot(entry)]=true;pony.append(entry)
	result["pony_wear"]=pony
	return result

static func _items() -> GDScript:
	return load(ITEMS_PATH) as GDScript

static func _store() -> GDScript:
	return load(STORE_PATH) as GDScript

## Loaded, not preloaded: the shop catalogue preloads this file for its outfit colours.
static func _outfits() -> Dictionary:
	return _items().get("OUTFITS")

## What an older save owned: the colours and patterns it was wearing, and worn wing sandals.
static func legacy_owned(value: Dictionary) -> Array:
	var owned:Array=[]
	for part in PARTS:
		var choice:Variant=value.get(part)
		if not choice is Dictionary:continue
		if int(choice.get("color",-1))>=0:owned.append("colour:%s:%d"%[part,int(choice.color)])
		var pattern:="pattern:%d"%int(choice.get("pattern",0))
		if int(choice.get("pattern",0))>0 and not owned.has(pattern):owned.append(pattern)
	if value.get("wing_sandals",false)==true:owned.append(WING_SANDALS)
	return owned

## A known `owned` row: a bought outfit or the wing sandals, or a kept colour/pattern.
static func owned_entry(entry: String) -> bool:
	if _items().call("wardrobe_only",entry):return true
	var parts:=entry.split(":")
	if parts.size()==3 and parts[0]=="colour" and parts[1] in PARTS and parts[2].is_valid_int():
		return int(parts[2])>=0 and int(parts[2])<PALETTES[parts[1]].size()
	if parts.size()==2 and parts[0]=="pattern" and parts[1].is_valid_int():
		return int(parts[1])>0 and int(parts[1])<PATTERNS.size()
	return false

## Moves bought human clothes out of an older briefcase document into `owned`. Both
## dictionaries are changed in place; true when anything moved. Loans checked out to a hand
## or the ground go too when `loans` is set (save migration, before anything is spawned).
static func adopt_items(clothes: Dictionary, inventory: Dictionary, loans: bool) -> bool:
	var owned:Array=clothes.owned if clothes.get("owned") is Array else legacy_owned(clothes)
	var moved:=false
	var checked:Variant=inventory.get("checked_out")
	var held:={}
	if checked is Dictionary:
		for token:Variant in checked.keys():
			var loan:Variant=checked[token]
			if not loan is Dictionary or not _items().call("wardrobe_only",str(loan.get("id",""))):continue
			if not loans:
				if loan.get("equipped",false):held[int(loan.get("slot",-1))]=true
				continue
			if not owned.has(str(loan.id)):owned.append(str(loan.id))
			checked.erase(token);moved=true
	var slots:Variant=inventory.get("slots")
	if slots is Array:
		for i in slots.size():
			var slot:Variant=slots[i]
			if not slot is Dictionary or held.has(i) or not _items().call("wardrobe_only",str(slot.get("id",""))):continue
			if not owned.has(str(slot.id)):owned.append(str(slot.id))
			slots[i]={};moved=true
	clothes["owned"]=owned
	return moved
static func valid(value: Variant) -> bool:
	if not value is Dictionary:return false
	# Unknown rows (from a newer catalogue) are dropped by normalized(), not the save.
	for key:String in ["owned","pony_wear"]:
		if not value.has(key):continue
		if not value[key] is Array or value[key].size()>(MAX_OWNED if key=="owned" else MAX_PONY_WEAR):return false
		for entry:Variant in value[key]:
			if not entry is String or entry.length()>96:return false
	if value.has("wing_sandals") and not value.wing_sandals is bool: return false
	if value.has("shoe_color"):
		var shoe:Variant=value.shoe_color
		if not (shoe is int or shoe is float):return false
		if not is_finite(float(shoe)) or shoe!=int(shoe) or shoe<0 or shoe>=SHOE_COLOURS.size():return false
	if value.has("pony_socks"):
		var socks:Variant=value.pony_socks
		if not socks is Dictionary or not socks.get("worn") is bool:return false
		var colour:Variant=socks.get("color")
		if not (colour is int or colour is float):return false
		if not is_finite(float(colour)) or colour!=int(colour) or colour<0 or colour>=PONY_OUTFIT.COLOUR_COUNT:return false
	if value.has("worn"):
		if not value.worn is Dictionary:return false
		for garment:String in GARMENTS.GARMENTS:
			if value.worn.has(garment) and not value.worn[garment] is bool:return false
	for part in PARTS:
		if not value.get(part) is Dictionary:return false
		for field in ["color","pattern","scale"]:
			var n=value[part].get(field)
			if not n is int and not n is float:return false
			if n!=int(n):return false
		if value[part].color < -1 or value[part].color>=PALETTES[part].size():return false
		if value[part].pattern<0 or value[part].pattern>=PATTERNS.size():return false
		if value[part].scale<0 or value[part].scale>=SCALES.size():return false
	return true
func open(save_file: String = path):
	path=save_file
	data=defaults();saved=data.duplicate(true);writable=true;last_error=""
	if not path.is_empty() and (FileAccess.file_exists(path) or FileAccess.file_exists(path+".previous")):
		# A newer build's outfit is left alone (read-only); a damaged one falls back to
		# clothing.json.previous, else it is kept aside and the default outfit is used.
		var loaded:=SAVE_FILE.read_checked(path,1<<20,func(value:Variant)->String:
			if value is Dictionary and (value.get("version") is float or value.get("version") is int) and value.version>1:return SAVE_FILE.NEWER
			return "" if value is Dictionary and value.get("version")==1 and valid(value.get("clothes")) else "invalid outfit")
		if loaded.status!="ok":last_error=loaded.message;push_warning("[clothing] "+last_error)
		if loaded.status=="newer":writable=false
		if loaded.doc!=null:data=normalized(loaded.doc.clothes)
	saved=data.duplicate(true)
func choose(part: String, field: String, value: int) -> bool:
	if part not in PARTS or field not in ["color","pattern","scale"]:return false
	var next:=data.duplicate(true);next[part][field]=value
	if not valid(next):return false
	data=next;apply_materials();changed.emit();return true
func choose_shoe_colour(value: int) -> bool:
	if not can_color_shoes() or value<0 or value>=SHOE_COLOURS.size():return false
	data["shoe_color"]=value;apply_materials();changed.emit();return true
func reset(part: String):
	if part not in PARTS:return
	data[part]=defaults()[part];apply_materials();changed.emit()
func revert():data=saved.duplicate(true);apply_materials();apply_garments();changed.emit()
## A world save's clothes (world/game_saves.gd); legacy saves without worn stay dressed.
func restore(value: Dictionary):data=normalized(value);apply_materials();apply_garments();changed.emit()
func is_worn(garment: String) -> bool:return bool(data.get("worn",{}).get(garment,true))
func set_worn(garment: String, value: bool) -> bool:
	if not can_remove_garments(): return false
	if garment not in GARMENTS.GARMENTS:return false
	data["worn"]=data.get("worn",dressed()).duplicate();data.worn[garment]=value
	if garment == "shoes": data["wing_sandals"] = false
	apply_garments();changed.emit();return true

func set_wing_sandals(worn: bool) -> bool:
	if not writable or not can_remove_garments(): return false
	data["wing_sandals"] = worn
	apply_garments(); changed.emit(); return true

## Boutique ownership. Unlocks are written at once (they are paid for), so `data` and `saved`
## always agree on them.
func owns(id: String) -> bool:return data.get("owned",[]).has(id)

func owned_outfits() -> Array[String]:
	var result:Array[String]=[]
	for id:String in _outfits():
		if owns("outfit:"+id):result.append("outfit:"+id)
	return result

## Original colours are always there; the rest come with a bought outfit (or an older save).
func colour_unlocked(part: String, index: int) -> bool:
	if index<0 or owns("colour:%s:%d"%[part,index]):return true
	for id:String in owned_outfits():
		if int(_outfits()[id.substr(7)][2].get(part,[-1])[0])==index:return true
	return false

## Plain is always there; a bought outfit's patterns can be used on any part.
func pattern_unlocked(index: int) -> bool:
	if index==0 or owns("pattern:%d"%index):return true
	for id:String in owned_outfits():
		for row:Array in _outfits()[id.substr(7)][2].values():
			if int(row[1])==index:return true
	return false

## Paid boutique purchase: the clothes go into the wardrobe and the bits leave the briefcase,
## each written once; a failed wallet write puts the clothing file back. "" or the reason.
func buy_unlock(store: RefCounted, id: String, price: int) -> String:
	if not _items().call("wardrobe_only",id):return "That is not something Anon wears."
	if owns(id):return "Already in your wardrobe."
	if not writable or not store.writable:return "Clothes cannot be saved right now."
	if price<0 or store.bits<price:return "insufficient funds!"
	var next:Dictionary=saved.duplicate(true);next.owned.append(id)
	if not path.is_empty() and SAVE_FILE.write(path,{"version":1,"clothes":next})!=OK:return "Could not save clothing."
	if price>0 and not store._commit(store.slots,store.loans,store.bits-price):
		if not path.is_empty():SAVE_FILE.write(path,{"version":1,"clothes":saved})
		return store.last_error if not store.last_error.is_empty() else "Purchase failed. Bits unchanged."
	saved=next;data["owned"]=next.owned.duplicate();last_error="";changed.emit();return ""

## A bought outfit or pair of sandals from before the wardrobe kept clothes, still carried or
## lying about: it is Anon's already, so it joins the wardrobe without payment.
func keep_bought(id: String) -> bool:
	if owns(id):return true
	if not writable or not _items().call("wardrobe_only",id):return false
	var next:Dictionary=saved.duplicate(true);next.owned.append(id)
	if not path.is_empty() and SAVE_FILE.write(path,{"version":1,"clothes":next})!=OK:last_error="Could not save clothing.";return false
	saved=next;data["owned"]=next.owned.duplicate();changed.emit();return true

## An older briefcase still holding bought outfits or sandals: they move into the wardrobe.
## The clothing file is written first, so a failed briefcase write only leaves a copy behind.
func adopt_from_store(store: RefCounted) -> bool:
	if not writable or store==null or not store.writable:return false
	var doc:Dictionary=store.document()
	var next:Dictionary=saved.duplicate(true)
	if not adopt_items(next,doc,false):return false
	if not path.is_empty() and SAVE_FILE.write(path,{"version":1,"clothes":next})!=OK:return false
	saved=next;data["owned"]=next.owned.duplicate();changed.emit()
	if not store._commit(doc.slots,doc.checked_out):return false
	print("[clothing] moved bought clothes from the briefcase into the wardrobe: ",next.owned)
	return true

## Footwear for the wardrobe: "shoes", "sandals" (when owned) or "barefoot".
func footwear() -> String:
	if data.get("wing_sandals",false):return "sandals"
	return "shoes" if is_worn("shoes") else "barefoot"

func set_footwear(kind: String) -> bool:
	if not can_remove_garments() or kind not in ["shoes","sandals","barefoot"]:return false
	if kind=="sandals" and not owns(WING_SANDALS):return false
	if flight_model!=null and bool(flight_model.get("active")) and (kind=="sandals")!=bool(data.get("wing_sandals",false)):
		last_error="Land before changing the wing sandals.";return false
	data["worn"]=data.get("worn",dressed()).duplicate()
	data.worn["shoes"]=kind!="barefoot"
	data["wing_sandals"]=kind=="sandals"
	apply_garments();changed.emit();return true

## AnonPony's worn pieces: thigh highs live in the older pony_socks row, the rest in pony_wear.
static func pony_items(value: Dictionary) -> Array[String]:
	var items:Array[String]=[]
	for id:Variant in value.get("pony_wear",[]):items.append(str(id))
	var socks:Variant=value.get("pony_socks")
	if socks is Dictionary and socks.get("worn",false)==true:items.append("wear:socks:%d"%int(socks.get("color",0)))
	return items

static func _with_pony_items(value: Dictionary, items: Array) -> Dictionary:
	var next:=value.duplicate(true)
	var socks:Dictionary=(value.get("pony_socks",defaults().pony_socks) as Dictionary).duplicate()
	socks["worn"]=false
	var rest:Array=[]
	for id:String in items:
		if PONY_OUTFIT.kind(id)=="socks":socks={"worn":true,"color":PONY_OUTFIT.colour(id)}
		else:rest.append(id)
	next["pony_socks"]=socks;next["pony_wear"]=rest
	return next

func _pony_avatar() -> Node3D:
	for ref:WeakRef in _pony_actors:
		var actor:Node3D=ref.get_ref()
		if is_instance_valid(actor):return actor
	return null

## Puts a briefcase piece on AnonPony: the held loan `token`, else one unit from `slot`. What
## she wore in that body slot goes back into the briefcase. "" or the reason it did not.
func wear_pony_item(store: RefCounted, id: String, token: String = "", slot: int = -1) -> String:
	if not PONY_OUTFIT.is_wear(id):return "Only pony wear goes on a pony."
	var avatar:=_pony_avatar()
	if avatar!=null and not PONY_OUTFIT.fits(avatar,id):return "That does not fit this pony."
	var items:=pony_items(saved)
	var returned:=""
	for other:String in items:
		if PONY_OUTFIT.slot(other)==PONY_OUTFIT.slot(id):returned=other
	if not returned.is_empty():items.erase(returned)
	items.append(id)
	var next_slots:Array=store.slots.duplicate(true)
	var checked:Dictionary=store.loans.duplicate(true)
	if not token.is_empty():
		if not checked.has(token) or str(checked[token].get("id",""))!=id:return "That is not in your briefcase."
		if checked[token].get("equipped",false):_store().call("_remove_unit",next_slots,int(checked[token].slot))
		checked.erase(token)
	else:
		if slot<0 or slot>=next_slots.size() or str(next_slots[slot].get("id",""))!=id or store.available(slot)<=0:return "That is not in your briefcase."
		_store().call("_remove_unit",next_slots,slot)
	if not returned.is_empty():
		var at:int=_store().call("_place",next_slots,returned,-1)
		if at<0:return "No room in the briefcase for the %s."%PONY_OUTFIT.display_name(returned).to_lower()
		_store().call("_add_unit",next_slots,at,{"id":returned})
	return _commit_pony(store,items,next_slots,checked)

## Re-dyes the thigh highs AnonPony is wearing at the wardrobe mirror (pony_clothing_view.gd).
func dye_pony_socks(store: RefCounted, colour: int) -> String:
	if colour<0 or colour>=PONY_OUTFIT.COLOUR_COUNT:return "No such colour."
	var items:=pony_items(saved)
	for i in items.size():
		if PONY_OUTFIT.kind(items[i]) in ["socks","plain-socks"]:
			items[i]="wear:%s:%d"%[PONY_OUTFIT.kind(items[i]),colour]
			return _commit_pony(store,items,store.slots.duplicate(true),store.loans.duplicate(true))
	return "She is not wearing thigh highs."

## Takes a piece off AnonPony and puts it back in the briefcase.
func take_off_pony_item(store: RefCounted, id: String) -> String:
	var items:=pony_items(saved)
	if not items.has(id):return "She is not wearing that."
	items.erase(id)
	var next_slots:Array=store.slots.duplicate(true)
	var at:int=_store().call("_place",next_slots,id,-1)
	if at<0:return "No room in the briefcase."
	_store().call("_add_unit",next_slots,at,{"id":id})
	return _commit_pony(store,items,next_slots,store.loans.duplicate(true))

## Clothing first, then the briefcase; a failed briefcase write puts the clothing file back,
## so a piece is never both worn and carried, nor lost.
func _commit_pony(store: RefCounted, items: Array, next_slots: Array, checked: Dictionary) -> String:
	if not writable or not store.writable:return "Clothes cannot be saved right now."
	var next:=_with_pony_items(saved,items)
	if not path.is_empty() and SAVE_FILE.write(path,{"version":1,"clothes":next})!=OK:return "Could not save clothing."
	if not store._commit(next_slots,checked):
		if not path.is_empty():SAVE_FILE.write(path,{"version":1,"clothes":saved})
		return store.last_error if not store.last_error.is_empty() else "Could not save the briefcase."
	saved=next;data=_with_pony_items(data,items);last_error=""
	apply_garments();changed.emit();return ""

## Physical equipment changes publish only after persistence succeeds. A failed
## write must not briefly remove flight permission while the player is airborne.
func commit_wing_sandals(worn: bool) -> bool:
	if not writable or not can_remove_garments(): return false
	var next := data.duplicate(true); next["wing_sandals"] = worn
	if not path.is_empty() and SAVE_FILE.write(path, {"version": 1, "clothes": next}) != OK:
		last_error = "Could not save clothing."; return false
	data = next; saved = next.duplicate(true); last_error = ""
	apply_garments(); changed.emit(); return true
## A bought outfit (world/shop/shop_items.gd): its colour rows, and it is put on.
func apply_outfit(rows: Dictionary) -> bool:
	var next:=data.duplicate(true)
	for part:String in rows:
		if part not in PARTS:continue
		for field in ["color","pattern","scale"]:next[part][field]=int(rows[part][field])
	for garment:String in ["top","trousers"]:next.worn[garment]=true
	if not valid(next):return false
	data=next;apply_materials();apply_garments();changed.emit();return true
func save() -> bool:
	if not writable:return false
	if not path.is_empty():
		if SAVE_FILE.write(path,{"version":1,"clothes":data})!=OK:last_error="Could not save clothing.";return false
	saved=data.duplicate(true);last_error="";changed.emit();return true
## A stand-in Anon made for a moment (couch or bed rest, knockdown) wears what the player wears
## (2026-10-28 player report: lying down to sleep showed the stock suit). Finds the profile through
## the briefcase that owns this player body.
static func dress_like_player(body: Node, actor: Node) -> void:
	if not is_instance_valid(body) or not is_instance_valid(actor) or not body.is_inside_tree(): return
	for source: Node in body.get_tree().get_nodes_in_group("interaction_hint_sources"):
		if source.get("player_body") == body and source.get("clothing") != null:
			source.clothing.attach(actor)
			return

func attach(actor: Node):
	if actor==null:return
	if "wing_flight" in actor: actor.wing_flight = flight_model
	var expressions := _expressions_actor(actor)
	if not expressions: GARMENTS.assemble(actor)
	_actors.append(weakref(actor))
	# Stand-ins (dress_like_player) come and go with every rest and knockdown; their materials
	# leave the list with them instead of piling up for the whole session.
	_materials.assign(_materials.filter(func(mat:ShaderMaterial)->bool:return not mat.has_meta("clothing_actor") or (mat.get_meta("clothing_actor") as WeakRef).get_ref()!=null))
	for mesh in actor.find_children("*","MeshInstance3D",true,false):
		if expressions:
			if String(mesh.name) != "AnonBody": continue
		elif String(mesh.name) not in ["torso0_smd","head_smd","Trousers"]:continue
		for surface in mesh.mesh.get_surface_count():
			var original:Material=mesh.get_active_material(surface)
			if original is not ShaderMaterial:continue
			var mat:ShaderMaterial=original.duplicate()
			mat.shader=EXPRESSIONS_SHADER if expressions else SHADER
			mat.set_shader_parameter("clothing_mask",load(EXPRESSIONS_MASK_PATH if expressions else MASK_PATH))
			if expressions:mat.set_shader_parameter("shoe_mask",load(EXPRESSIONS_SHOE_MASK_PATH))
			# Keep the original source texture, UV settings and outline next-pass.
			mat.set_meta("clothing_actor",weakref(actor))
			mesh.set_surface_override_material(surface,mat);_materials.append(mat)
	apply_materials();apply_garments()

static func _expressions_actor(actor: Node) -> bool:
	if not is_instance_valid(actor): return false
	if actor.has_meta("anon_model_variant") and str(actor.get_meta("anon_model_variant")) == EXPRESSIONS_VARIANT: return true
	for mesh: Node in actor.find_children("AnonBody", "MeshInstance3D", true, false):
		if mesh.has_meta("anon_model_variant") and str(mesh.get_meta("anon_model_variant")) == EXPRESSIONS_VARIANT: return true
		if str(mesh.name) == "AnonBody": return true
	return false

func can_color_shoes() -> bool:
	for ref:WeakRef in _actors:
		var actor:Node=ref.get_ref()
		if is_instance_valid(actor) and _expressions_actor(actor):return true
	return false

func can_remove_garments() -> bool:
	for ref: WeakRef in _actors:
		var actor: Node = ref.get_ref()
		if is_instance_valid(actor) and _expressions_actor(actor): return false
	return true
## Shows worn garments on every attached Anon (player and wardrobe mirror). The avatar then
## re-measures its sleeve so the forearm strip sits on what is actually visible.
func apply_garments():
	apply_pony_socks()
	for ref:WeakRef in _actors.duplicate():
		var actor:Node=ref.get_ref()
		if actor==null:_actors.erase(ref);continue
		if _expressions_actor(actor): continue
		var worn: Dictionary = data.get("worn",dressed()).duplicate()
		if data.get("wing_sandals", false): worn["shoes"] = false
		GARMENTS.apply(actor,worn)
		preload("res://world/customization/wing_sandals.gd").apply(actor, data.get("wing_sandals", false), flight_model)
		# The cup scarf is one worn piece for both of Anon's forms (pony_items).
		preload("res://world/customization/club_scarf.gd").apply(actor, pony_items(data).has(preload("res://world/customization/club_scarf.gd").ITEM))
		if actor.has_method("refresh_forearm_clearance"):actor.refresh_forearm_clearance()

func attach_pony(actor:Node3D) -> void:
	for ref:WeakRef in _pony_actors:
		if ref.get_ref()==actor:return
	_pony_actors.append(weakref(actor));apply_pony_socks()

func set_pony_socks(worn:bool, colour:int) -> bool:
	if colour<0 or colour>=PONY_OUTFIT.COLOUR_COUNT:return false
	data["pony_socks"]={"worn":worn,"color":colour}
	apply_pony_socks();changed.emit();return true

## Dresses AnonPony in her worn pieces (thigh highs and pony_wear), changed pieces only.
func apply_pony_socks() -> void:
	var items:=pony_items(data)
	for ref:WeakRef in _pony_actors.duplicate():
		var actor:Node3D=ref.get_ref()
		if actor==null:_pony_actors.erase(ref);continue
		PONY_OUTFIT.apply(actor,items)
func apply_materials():
	for mat in _materials:
		if mat.shader==EXPRESSIONS_SHADER:
			mat.set_shader_parameter("shoe_tint",BROWN_SHOE_TINT if int(data.get("shoe_color",0))==1 else Color(0,0,0,0))
		for part in PARTS:
			var choice:Dictionary=data[part];var tint:=Color(0,0,0,0)
			if choice.color>=0:tint=Color(PALETTES[part][int(choice.color)].split(":")[1])
			mat.set_shader_parameter(part+"_tint",tint)
			mat.set_shader_parameter(part+"_pattern",load("res://world/customization/patterns/%s.svg"%PATTERNS[int(choice.pattern)]))
			mat.set_shader_parameter(part+"_scale",SCALES[int(choice.scale)])
			mat.set_shader_parameter(part+"_pattern_on",choice.pattern!=0)
