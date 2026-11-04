extends RefCounted
## Things in the hands: hold poses, release velocity, taking from the case, shelves and the ground, stowing and dropping.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.

const STORE := preload("res://world/inventory/inventory_store.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const FURNISHING := preload("res://world/housing/home_furnishing.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const GRAB := preload("res://world/inventory/grab_targets.gd")
const LIBRARY := preload("res://world/books/book_library.gd")
const DROP_ANGULAR_DAMP := 6.0
const DROP_LINEAR_DAMP := 0.6

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Where a held item sits: the hand pose times the item's grip, easing in after a grab.
static func hold_local(id:String)->Transform3D:
	if FOOD.has(id):return FOOD.hold_local(id)
	match id:
		"carrot":return Transform3D(Basis.IDENTITY,Vector3(0,.025,-.025))
		"notebook":return Transform3D(Basis.IDENTITY,Vector3(0,-.01,-.06))
		"photo-journal":return Transform3D(Basis.IDENTITY,Vector3(0,-.01,-.06))
		"river-fish":return Transform3D(Basis(Vector3.UP,PI*.5),Vector3(0,-.02,-.09))
	if CATALOG.is_book(id):return Transform3D(Basis.IDENTITY,Vector3(0,-.014,-.12))
	# The folded easel: one hand at the strap, mid-stick (world/painting/). A finished painting
	# is carried by the top of its frame (centred, it filled the desktop view in the review run).
	if id=="goods:easel":return Transform3D(Basis.IDENTITY,Vector3(0,-.05,-.04))
	if id.begins_with("art:"):return Transform3D(Basis.IDENTITY,Vector3(0,-.40,-.06))
	return Transform3D(Basis.IDENTITY,Vector3(0,0,-.012))


func _held_world(item:RigidBody3D,pose:Transform3D,sample:Dictionary={})->Transform3D:
	var target:Transform3D=pose.orthonormalized()*item.get_meta("hold_offset",hold_local(String(item.get_meta("item_id",""))))
	if not host._desktop and CATALOG.is_book(str(item.get_meta("item_id",""))) and sample.get("active",false):
		target=preload("res://world/books/book_hold.gd").from_hand(sample,host.camera.global_transform,item.global_basis,host._book_open(item))
	var blend:float=item.get_meta("hold_blend",1.)
	if blend<1.:
		blend=minf(1.,blend+host.get_physics_process_delta_time()/float(item.get_meta("hold_blend_seconds",.12)));item.set_meta("hold_blend",blend)
		if blend>=1. and item.has_meta("hold_blend_seconds"):item.remove_meta("hold_blend_seconds")
		target=Transform3D(item.get_meta("hold_from")).interpolate_with(target,smoothstep(0.,1.,blend))
	return target


## A held thing stops at walls, counters and doors instead of passing through them (dev
## 2026-09-30: grabbing "needs to be WAY more ... reliable"). The item sweeps its own shape from
## where it is toward the hand and halts at the first world contact; one that starts touching
## something (just taken off a shelf) moves freely until clear, and one left more than 0.6 m
## behind the hand (walked through a doorway around a corner) catches up at once.
func _held_clear(item:RigidBody3D,target:Transform3D)->Transform3D:
	var from:Transform3D=item.global_transform
	var motion:Vector3=target.origin-from.origin
	if motion.length_squared()<.0000001 or motion.length()>.6 or not target.is_finite():return target
	var shape_node:CollisionShape3D
	for child:Node in item.get_children():
		if child is CollisionShape3D and child.shape!=null and not child.disabled:shape_node=child;break
	if shape_node==null:return target
	var query:=PhysicsShapeQueryParameters3D.new()
	query.shape=shape_node.shape
	query.transform=Transform3D(target.basis,from.origin)*shape_node.transform
	query.collision_mask=1
	var skip:Array[RID]=[item.get_rid()]
	if host.player_body is CollisionObject3D:skip.append((host.player_body as CollisionObject3D).get_rid())
	query.exclude=skip
	var space:=host.get_world_3d().direct_space_state
	if not space.intersect_shape(query,1).is_empty():return target
	query.motion=motion
	var safe:PackedFloat32Array=space.cast_motion(query)
	if safe.size()<1 or safe[0]>=1.:return target
	return Transform3D(target.basis,from.origin+motion*safe[0])


func _track_item(side:String,item:RigidBody3D):
	var samples:Array=host._track.get(side,[])
	samples.append([Time.get_ticks_usec()*.000001,item.global_transform])
	if samples.size()>8:samples.pop_front()
	host._track[side]=samples


## Hand velocity over the last ~0.1 s, so a release throws instead of dropping dead.
func _release_velocity(side:String)->Array:
	var samples:Array=host._track.get(side,[])
	if samples.size()<2:return [Vector3.ZERO,Vector3.ZERO]
	var last:Array=samples[-1];var first:Array=samples[0]
	for s:Array in samples:
		if float(last[0])-float(s[0])<=.1:first=s;break
	var dt:=float(last[0])-float(first[0])
	if dt<.008:return [Vector3.ZERO,Vector3.ZERO]
	var a:Transform3D=first[1];var b:Transform3D=last[1]
	var velocity:=(b.origin-a.origin)/dt
	if velocity.length()>18.:velocity=velocity.normalized()*18.
	var turn:=(b.basis.orthonormalized()*a.basis.orthonormalized().inverse()).get_rotation_quaternion()
	var spin:=turn.get_axis()*turn.get_angle()/dt if turn.get_angle()>.001 else Vector3.ZERO
	if not velocity.is_finite():velocity=Vector3.ZERO
	if not spin.is_finite() or spin.length()>40.:spin=Vector3.ZERO
	return [velocity,spin]


func take_slot(side: String, index: int, pose := Transform3D.IDENTITY, from_case := true) -> bool:
	if host.hand_busy(side) or index<0 or index>=STORE.SLOT_COUNT or (from_case and not host.case.opened):return false
	if host.inventory.loans.size()>=host.MAX_LOOSE:
		host.case.ui.message="Put some loose items away first.";host.case.ui.refresh();return false
	var slot:Dictionary=host.inventory.slots[index]
	if slot.is_empty() or slot.count<=0:return false
	var scene:PackedScene=CATALOG.scene(slot.id)
	if scene==null:return false
	var visual:Node3D=scene.instantiate()
	var token:String=host.inventory.take(index)
	if token.is_empty():visual.free();host._error();return false
	var item: RigidBody3D = host._make_item(token, slot.id, visual)
	item.set_meta("hold_offset",hold_local(slot.id))
	item.global_transform=_held_world(item,pose,host.hand_sample(side))
	host.loose[token]=item;host.held[side]=item;host._track.erase(side);host._claim(side,true);_refresh_holding();host._haptic(side)
	return true


func _take_nearby(side: String, pose: Transform3D, aim: Variant = null) -> bool:
	if host.hand_busy(side) or not pose.is_finite():return false
	# The same pick the blue highlight shows (world/inventory/grab_targets.gd); a VR hand may
	# also take what it points at, which then flies into the hand.
	var pick:Dictionary=GRAB.pick(host,pose,aim) if aim is Transform3D and side!="desktop" else GRAB.nearest(host,pose.origin)
	return host._take_pick(side, pick, pose)


func grab_take(side: String, offer: Dictionary, sample: Dictionary) -> bool:
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	pose.origin = sample.get("grip_position", pose.origin)
	pose = offer.get("grab_pose", pose)
	return host._take_pick(side, offer, pose)


## A library book off a house shelf becomes one checked-out unit in the hand.
## The shelf remembers it was taken; stowing later stacks copies of the same story.
func _take_shelf_book(side: String, book: Node3D, pose: Transform3D) -> bool:
	if not is_instance_valid(book) or not book.is_in_group("shelf_books") or not book.is_visible_in_tree(): return false
	if host.hand_busy(side) or not pose.is_finite(): return false
	if host.inventory.loans.size() >= host.MAX_LOOSE:
		host.case.ui.message = "Put some loose items away first."; host.case.ui.refresh(); return false
	var id:String=String(book.get_meta("item_id",""))
	var key := str(book.get_meta("shelf_key", ""))
	var scene: PackedScene = CATALOG.scene(id)
	if key.is_empty() or scene == null: return false
	var slot := STORE._place(host.inventory.slots, id, -1)
	if slot < 0:
		host.case.ui.message = "No room in the briefcase."; host.case.ui.refresh(); return false
	var visual: Node3D = scene.instantiate()
	var before_shelf := LIBRARY.snapshot()
	if not LIBRARY.mark_taken(key): visual.free(); return false
	# Borrow directly into one persisted loan. grant() followed by take_slot()
	# could store the book and empty its shelf even when the second step failed.
	var token := "book_%d_%d" % [Time.get_ticks_usec(), book.get_instance_id()]
	var checked: Dictionary = host.inventory.loans.duplicate(true)
	checked[token] = {"id": id, "slot": slot}
	if not host.inventory._commit(host.inventory.slots, checked):
		LIBRARY.restore(before_shelf)
		visual.free(); host._error(); return false
	var item: RigidBody3D = host._make_item(token, id, visual)
	item.set_meta("hold_offset", hold_local(id))
	item.global_transform = _held_world(item, pose, host.hand_sample(side))
	host.loose[token] = item; host.held[side] = item
	host._track.erase(side); host._claim(side, true); _refresh_holding(); host._haptic(side)
	book.remove_from_group("shelf_books")
	book.hide()
	book.collision_layer = 0
	host._play_deposit()
	return true


func _store_held(side: String, index: int = -1) -> bool:
	if not host.held.has(side):return false
	var item:RigidBody3D=host.held[side];var token:String=item.get_meta("token")
	if host._book_open(item):item.get_node("BookItem").close_book()
	if not host.inventory.put(token,index):host._error();return false
	host._unglow(item)
	host.held.erase(side);host._track.erase(side);host._eat_time.erase(side);host.loose.erase(token);host._claim(side,false);item.queue_free();_refresh_holding();host._play_deposit();return true


func _return_held(side: String) -> bool:
	if host.held.has(side) and host.held[side].has_meta("world_pick"):
		_release_to_world(side);return true
	return _store_held(side)


## VR: a free thing picked up in the world and let go anywhere but a wrist slot or the open
## briefcase goes back to the world, unowned (dev 2026-10-01: picking something up "shouldn't
## automatically go into your inventory unless you drag it to one of the slots on your wrist ...
## or to your briefcase").
func _release_to_world(side:String)->void:
	var item:RigidBody3D=host.held[side]
	var token:=String(item.get_meta("token",""))
	var motion:=_release_velocity(side)
	if not host.inventory.consume(token):_drop(side);return
	host._unglow(item)
	host.held.erase(side);host.loose.erase(token);host._track.erase(side);host._eat_time.erase(side);host._claim(side,false)
	for key:String in ["token","hold_offset","hold_blend","hold_from","world_pick"]:
		if item.has_meta(key):item.remove_meta(key)
	var scene:Node=host.get_tree().current_scene if host.get_tree().current_scene!=null else host.get_tree().root
	item.reparent(scene,true)
	item.add_to_group("world_food")
	item.freeze=false;item.linear_velocity=motion[0];item.angular_velocity=motion[1]
	_settle(item)
	_refresh_holding()


func _settle(item:RigidBody3D)->void:
	item.angular_damp_mode=RigidBody3D.DAMP_MODE_REPLACE;item.angular_damp=DROP_ANGULAR_DAMP
	item.linear_damp_mode=RigidBody3D.DAMP_MODE_REPLACE;item.linear_damp=DROP_LINEAR_DAMP
	item.can_sleep=true


func shelf_offer(side: String) -> Node3D:
	if not host.held.has(side): return null
	var item: RigidBody3D = host.held[side]
	if not CATALOG.is_book(str(item.get_meta("item_id", ""))): return null
	var shelves = preload("res://world/books/shelf_books.gd")
	if side == "desktop" and is_instance_valid(host.camera):
		return shelves.aimed_slot(host.get_tree(), host.camera.global_position, -host.camera.global_basis.z)
	return shelves.return_slot(host.get_tree(), item)


func _shelve_held(side: String) -> bool:
	if not host.held.has(side): return false
	var item: RigidBody3D = host.held[side]
	if not CATALOG.is_book(str(item.get_meta("item_id", ""))): return false
	var shelves = preload("res://world/books/shelf_books.gd")
	var slot: Node3D = shelf_offer(side)
	if slot == null: return false
	var token := str(item.get_meta("token"))
	if not shelves.return_book(slot, host.inventory, token): return false
	if host._book_open(item): item.get_node("BookItem").close_book()
	host._unglow(item)
	host.held.erase(side); host._track.erase(side); host._eat_time.erase(side); host.loose.erase(token)
	host._claim(side, false); item.queue_free(); _refresh_holding(); host._play_deposit(); host._haptic(side)
	return true


func _drop(side: String, push := Vector3.ZERO):
	if not host.held.has(side):return
	if push.length() < 2.0 and COOKING.activate(host, side): return
	if push.length() < 2.0 and _shelve_held(side): return
	if push.length() < 2.0 and FURNISHING.place(host, side): return
	var item:RigidBody3D=host.held[side]
	if host._book_open(item):item.get_node("BookItem").close_book()
	if side in host.SIDES and host._over_wrist_icon(item):
		host._store_at_wrist(item);return
	if side == "desktop" and host.case.visible:
		item.global_transform = Transform3D(host.camera.global_basis,host.camera.project_ray_origin(host._mouse_position)+host.camera.project_ray_normal(host._mouse_position)*.36)
	var motion:=_release_velocity(side)
	if side == "desktop" and not host.case.visible:motion[1]=Vector3.ZERO
	if not host.inventory.set_dropped(String(item.get_meta("token")), item.global_transform): host._error(); return
	host._unglow(item)
	if side == "desktop" and host.case.visible: item.set_meta("outside_drop",true)
	item.set_meta("impact_played", false)
	item.freeze=false;item.linear_velocity=motion[0]+push;item.angular_velocity=motion[1]
	if push!=Vector3.ZERO:item.angular_velocity+=host.camera.global_basis.x*randf_range(4.,9.)
	_settle(item)
	item.remove_meta("hold_offset");item.remove_meta("hold_blend")
	host.held.erase(side);host._track.erase(side);host._eat_time.erase(side);host._claim(side,false);_refresh_holding()


func _release_case():
	if not host.holding_case.is_empty():host._claim(host.holding_case,false)
	host.holding_case=""


func _refresh_holding():
	if host._quick_open: host._place_hotbar()
	if not host.held.has("desktop"):
		host._desktop_eating = false;host._clear_desktop_item_pose()
	for side: String in host._selected_slots:
		if not host.held.has(side): host._selected_slots[side] = -1
	if host.hotbar != null:
		var side: String = "desktop" if host._desktop else "right"
		host.hotbar.select(int(host._selected_slots[side]))
	host.case.ui.carrying=""
	for item in host.held.values():host.case.ui.carrying=item.get_meta("item_id");break
	host.case.ui.refresh()
