extends RefCounted
## Owned items in the world: building item bodies, loose drops, and the save sweep of dropped items.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.

const SFX := preload("res://world/audio/interaction_sounds.gd")
const ITEM_FOLEY := preload("res://world/audio/props_catalogue.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const FURNISHING := preload("res://world/housing/home_furnishing.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const SHOP_ITEMS := preload("res://world/shop/shop_items.gd")
const TIDY := preload("res://world/inventory/loose_tidy.gd")
const SHOP_PURCHASE := preload("res://world/shop/shop_purchase.gd")
## Loaded only where an open owned easel exists (world/painting/).
const EASEL_FOLD := "res://world/painting/easel_fold.gd"

var host: Node3D
## When each spawn_owned_drop refusal line was last shown. Stations retry a pending output every
## second (world/mechanics/stations/stations.gd _tick); the same reason is said again only after
## REFUSAL_REPEAT_MS, so the hotbar does not blink it forever while the briefcase stays full.
const REFUSAL_REPEAT_MS := 30000
var _refusals: Dictionary = {}


func _init(owner_node: Node3D) -> void:
	host = owner_node


func _make_item(token: String, id: String, visual: Node3D) -> RigidBody3D:
	id = CATALOG.canonical(id)
	var item:=RigidBody3D.new();item.name="InventoryItem";item.set_meta("token",token);item.set_meta("item_id",id)
	item.mass=.15;item.collision_layer=1<<17;item.collision_mask=1;item.continuous_cd=true;item.freeze=true
	var shape:=CollisionShape3D.new()
	if id=="apple":
		var sphere:=SphereShape3D.new();sphere.radius=.042;shape.shape=sphere
	elif id=="carrot":
		var capsule:=CapsuleShape3D.new();capsule.radius=.019;capsule.height=.155;shape.shape=capsule;shape.position.y=-.014
	elif CATALOG.is_book(id):
		var cover:=BoxShape3D.new();cover.size=preload("res://world/books/book_item.gd").SIZE;shape.shape=cover
	elif SHOP_ITEMS.has(id):
		# Shop goods: an estimate until the real-size model is measured in the tree (below).
		var edge:=float(SHOP_ITEMS.definition(id).get("size_m",.3))
		var goods_box:=BoxShape3D.new();goods_box.size=Vector3(edge,edge*.5,edge);shape.shape=goods_box;shape.position.y=edge*.25
	else:
		var box:=BoxShape3D.new();box.size=Vector3(.11,.032,.15);shape.shape=box
	item.add_child(shape);item.add_child(visual)
	if FOOD.has(id):
		FOOD.configure(item,visual,shape)
		FOOD.restore_bites(item,int(host.inventory.loans.get(token,{}).get("bites",0)))
	elif visual.has_method("configure_body"):visual.configure_body(item,shape)
	host.add_child(item)
	if host.inventory.loans.get(token, {}).has("cooking"):
		preload("res://world/cooking/cooking_station.gd").presentation(item, true)
	if SHOP_ITEMS.has(id) and "bounds" in visual:
		(shape.shape as BoxShape3D).size=(visual.bounds as AABB).size.max(Vector3.ONE*.02);shape.position=(visual.bounds as AABB).get_center()
	if host.inventory.loans.get(token, {}).get("picnic_deployed", false):
		item.call_deferred("set", "freeze", true)
		host._configure_picnic.call_deferred(item, token)
	if host.inventory.loans.get(token, {}).get("easel_open", false):
		item.call_deferred("set", "freeze", true)
		Callable(load(EASEL_FOLD), "configure").call_deferred(item, token)
	if host.inventory.loans.get(token, {}).has("furnishing_home"):
		item.set_meta("furnishing_size", float(host.inventory.loans[token].get("furnishing_size", 1.0)))
		FURNISHING.configure(item, true)
	item.contact_monitor = true; item.max_contacts_reported = 1
	item.body_entered.connect(func(_body: Node):
		if item.freeze or item.get_meta("impact_played", false): return
		item.set_meta("impact_played", true)
		SFX.play_event(item,"prop_impact",{"material":ITEM_FOLEY.material_for_item(str(item.get_meta("item_id",""))),"intensity":clampf(item.linear_velocity.length()/4.0,.3,1.0)}))
	return item


## Physical activity reward: commit ownership and its world placement together,
## then expose the body. A rejected transaction never spawns a free duplicate.
## At the loose-item cap a leftover is tidied first, as buying does (loose_tidy.gd); a catch,
## painting or station output that still cannot be placed says why on the hotbar instead of
## vanishing (M-INV-01; the spa's hoof file too, M-SPA-01).
func spawn_owned_drop(id:String,pose:Transform3D)->RigidBody3D:
	id = CATALOG.canonical(id)
	if not pose.is_finite() or not CATALOG.has(id):return null
	if STORE._place(host.inventory.slots,id,-1)<0:
		_refuse(TIDY.not_placed_text(host,id,false));return null
	if host.inventory.loans.size()>=host.MAX_LOOSE and not TIDY.make_room(host):
		_refuse(TIDY.not_placed_text(host,id,true));return null
	# Tidying can fill the last free slot with the leftover.
	var slot:int=STORE._place(host.inventory.slots,id,-1)
	if slot<0:
		_refuse(TIDY.not_placed_text(host,id,false));return null
	var scene:PackedScene=CATALOG.scene(id)
	if scene==null:return null
	var visual:Node3D=scene.instantiate()
	var token:String="activity_%d_%d"%[Time.get_ticks_usec(),visual.get_instance_id()]
	var checked:Dictionary=host.inventory.loans.duplicate(true)
	checked[token]={"id":id,"slot":slot,"world_transform":STORE.encode_pose(pose)}
	if not host.inventory._commit(host.inventory.slots,checked):
		visual.free();return null
	var item:RigidBody3D=_make_item(token,id,visual)
	item.global_transform=pose
	item.freeze=false
	host.loose[token]=item
	return item


func _refuse(text: String) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_refusals.get(text, -REFUSAL_REPEAT_MS)) < REFUSAL_REPEAT_MS: return
	if _refusals.size() > 16: _refusals.clear()
	_refusals[text] = now
	SHOP_PURCHASE._say(host, text)


func checkpoint_drops() -> bool:
	var poses := {}
	for token in host.loose:
		var item: RigidBody3D = host.loose[token]
		if is_instance_valid(item) and item not in host.held.values():
			if host.inventory.loans.get(token, {}).has("furnishing_home"): continue
			# Only checkpoint supported objects. Streamed-out floors must not turn a
			# valid saved placement into a falling object under the world.
			if _drop_supported(item.global_transform,str(item.get_meta("item_id",""))): poses[token] = item.global_transform
	return host.inventory.update_drops(poses)


func _drop_supported(pose: Transform3D, id: String = "") -> bool:
	var support:Vector3=pose.origin-Vector3.UP*FOOD.rest_height(id,pose.basis) if FOOD.has(id) else pose.origin
	var query := PhysicsRayQueryParameters3D.create(support + Vector3.UP * .15, support + Vector3.DOWN * .4, 1)
	return not host.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _sync_dropped_items() -> void:
	checkpoint_drops()
	for token in host.loose.keys():
		var item: RigidBody3D = host.loose[token]
		if item in host.held.values(): continue
		var record: Dictionary = host.inventory.loans.get(token, {})
		if not record.has("world_transform"): continue
		if record.has("furnishing_home") and FURNISHING.home(host.get_tree(), str(record.furnishing_home)) == null:
			host.loose.erase(token); item.queue_free(); continue
		var saved := STORE.decode_pose(record.world_transform)
		if item.global_position.distance_to(host.camera.global_position) > 90.0 or item.global_position.y < saved.origin.y - 2.0:
			host.loose.erase(token); item.queue_free()
	for token in host.inventory.loans:
		if host.loose.has(token): continue
		var loan: Dictionary = host.inventory.loans[token]
		if not loan.has("world_transform"): continue
		var pose := STORE.decode_pose(loan.world_transform)
		if pose.origin.distance_to(host.camera.global_position) > 80.0: continue
		var furnished: bool = loan.has("furnishing_home")
		if furnished and FURNISHING.home(host.get_tree(), str(loan.furnishing_home)) == null: continue
		if not furnished and not _drop_supported(pose,loan.id):
			# A save can occur between release and the first floor contact. Resolve
			# that short fall only when streamed collision exists underneath it.
			var hit := host.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(pose.origin,pose.origin+Vector3.DOWN*4.0,1))
			if hit.is_empty(): continue
			pose.origin.y = hit.position.y + (FOOD.rest_height(loan.id,pose.basis) if FOOD.has(loan.id) else .1)

		var scene: PackedScene = CATALOG.scene(loan.id)
		if scene == null: continue
		var item := _make_item(token, loan.id, scene.instantiate())
		item.global_transform = pose
		# Stay parked until picked up; streaming cannot make a restored object fall.
		item.freeze = true
		host.loose[token] = item

	COOKING.restore(host)


func restore_drops() -> void:
	for side in host.held.keys(): host._claim(side, false)
	host.held.clear()
	for item in host.loose.values(): item.queue_free()
	host.loose.clear()
	_sync_dropped_items()
