extends Node3D
const HOUSE_SHELL_OPS := preload("res://world/buildings/house_shell_ops.gd")
const HOUSE_FLOOR_FIT := preload("res://world/buildings/house_floor_fit.gd")
const HOUSE_BEDS := preload("res://world/buildings/house_beds.gd")
const INTERIOR_RANGE := preload("res://world/buildings/interior_range.gd")
const HOUSE_ROUTING := preload("res://world/buildings/house_routing.gd")
## Authored, floor-bounded HOUSE space. The doorway is its only travel portal.
@export var floors:Array[Rect2]=[]
@export var floor_y:=0.0
@export var doorway:=Vector3.ZERO
@export var approach:=Vector3.ZERO
@export var door_width:=.12
## Seeded furniture from world/interiors (off for the wagon and other tiny homes).
@export var furnish:=true
var _ceiling_y:=0.8
const BED := preload("res://world/props/ponyville/pony_bed.scn")
## The bed placed against the wall farthest from the door, and where it sits.
var bed:Node3D
var _sleepers: Array = []
var _extra_beds: Array[Node3D] = []
var _bed_retry_at := 0

func set_sleepers(ids: Array) -> void:
	var beds_before := (_sleepers.size() + 1) / 2
	var previous := _sleepers
	_sleepers = ids.duplicate()
	_sleepers.sort()
	# New sleepers: a bed search that gave up for the old household may try again (house_beds).
	if _sleepers != previous:
		_bed_retry_at = 0
		if has_meta("bed_failures"): remove_meta("bed_failures")
	var partner_id:=str(get_meta("player_partner",""))
	if "player" in _sleepers and partner_id in _sleepers:
		_sleepers.erase("player");_sleepers.erase(partner_id)
		_sleepers.push_front(partner_id);_sleepers.push_front("player")
	# Furniture went in before these sleepers were known: make room for their beds too.
	if _furnished and (_sleepers.size() + 1) / 2 > maxi(beds_before, 1 + _extra_beds.size()):
		_furnished = false
		furnish_done = false
		# Invalidate a layout coroutine immediately, before the deferred bed search.
		furnish_gen += 1
		for node in get_children():
			if node.is_in_group("house_furniture") or node.is_in_group("house_activity_spots"):
				# queue_free alone leaves the furniture in the physics space until frame end.
				# The deferred bed search runs sooner and would see the old wardrobe/sofa.
				remove_child(node)
				node.queue_free()
		_furnish_when_ready.call_deferred()

## The arrival grant persists this requirement and reapplies it when a house streams in.
## Reserve a real, undecorated table before optional furniture can consume its space.
func require_welcome_table() -> void:
	if bool(get_meta("welcome_table_required", false)): return
	set_meta("welcome_table_required", true)
	if not _furnished: return
	_furnished = false
	furnish_done = false
	furnish_gen += 1
	for node in get_children():
		if node.is_in_group("house_furniture") or node.is_in_group("house_activity_spots"):
			remove_child(node)
			node.queue_free()
	_furnish_when_ready.call_deferred()

var _room_tops:Array[float]=[]   # measured floor top per fitted room (house-local), for furniture
var _floor_fitted:=false
var _bed_settled:=false   # the first bed was placed, or could not be
var _furnished:=false
## Furnishes the house once the floor is fitted to the walls and every bed stands (furniture
## must not take a bed's spot). Seeded by place_id, so the same house always looks the same.
func _furnish_when_ready() -> void:
	if not furnish or _furnished or not is_inside_tree():return
	if _floor_material!=null and not _floor_fitted:return
	if not _bed_settled:return
	if is_instance_valid(bed):
		for index in range(1,(_sleepers.size()+1)/2):
			if _extra_beds.size()>=index:continue
			var extra:=_create_bed(index)
			if extra==null:break
			_extra_beds.append(extra)
	_furnished=true
	# Every house of a town gets ready in the same few frames: take turns, 200 ms apart (each
	# works 4 ms a frame for about ten frames).
	var now:=Time.get_ticks_msec()
	var at:=maxi(now,_next_furnish_ms)
	_next_furnish_ms=at+200
	# dev 2026-09-26 (fireplace in front of a bookcase, clipping): set_sleepers() restarted the
	# furnishing while the first run was still working over its frames, and both runs spawned a
	# layout. Only the newest generation may finish; the furnisher checks furnish_gen.
	furnish_gen+=1
	var gen:=furnish_gen
	if at>now:get_tree().create_timer((at-now)/1000.0).timeout.connect(_do_furnish.bind(gen))
	else:_do_furnish(gen)
static var _next_furnish_ms:=0
var furnish_done:=false
var furnish_gen:=0
func _do_furnish(gen:int) -> void:
	if not is_inside_tree() or gen!=furnish_gen:return
	if not FURNISHER.props_loaded():
		get_tree().create_timer(0.25).timeout.connect(_do_furnish.bind(gen))
		return
	var furnisher=FURNISHER.new()
	await furnisher.furnish(self)
	# tree_exiting wakes a cancelled worker before is_inside_tree() becomes false.
	# Do not start candle/rendering work while this house is being torn down.
	if not is_inside_tree() or gen!=furnish_gen or not furnisher._alive():return
	if furnish_log:set_meta("furnisher",furnisher)
	furnish_done=true
	# Candle clusters on some of the tables (dev 2026-09-28), lit by a trigger press on a wick.
	preload("res://world/props/candles/candles.gd").scatter(self,place_id())
	_apply_interior_range()
	if OS.is_stdout_verbose() or furnish_log:print("\n".join(furnisher.report))
static var furnish_log:=false
const FURNISHER:=preload("res://world/interiors/interior_furnisher.gd")
## Interior-only dressing (inside door art) was drawn from every house in
## town, out to the camera far (performance pass 2026-09-27). Past these distances it is a pixel
## or two seen through tinted glass: thin trim stops at TRIM_RANGE, props fade out at PROP_RANGE
## (furniture already fades at 40 m, the pony bed stops at 60 m). Never reached indoors.
const TRIM_RANGE:=80.0
const PROP_RANGE:=100.0
static func limit_range(root:Node,end:float,fade:bool) -> void:
	INTERIOR_RANGE.limit_range(root, end, fade)

func _ready() -> void:
	preload("res://world/interiors/shell_repairs.gd").apply(get_parent())
	preload("res://world/interiors/mare_home_lining.gd").install(self)
	add_to_group("house_interiors")
	# A town house reserved for one household (the Apple family's beside the Sweet Apple Acres barn,
	# dev 2026-10-22): the reservation rides on the house root in town.tscn (move_houses.gd).
	if get_parent() != null and get_parent().has_meta("reserved_for") and not has_meta("reserved_for"):
		set_meta("reserved_for", get_parent().get_meta("reserved_for"))
	for mesh:MeshInstance3D in get_parent().find_children("*","MeshInstance3D",true,false):
		# Keep the same normally lit surfaces on both sides of the doorway.
		# Packed houses contain room-face duplicates and legacy blackout seals.
		if mesh.get_meta("house_lighting_shell", "") == "outside":
			mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		elif mesh.get_meta("house_lighting_shell", "") == "room":
			mesh.visible=mesh.get_meta("outside_backfaces",false)
			# A room face (the strip beside the door) shows only from the room or through a window:
			# it stops with the room lining (60 m), perf push 2026-10-14.
			if mesh.visible and mesh.visibility_range_end<=0.0:
				mesh.visibility_range_end=INTERIOR_RANGE.SHUT_BACK_RANGE
				mesh.visibility_range_end_margin=INTERIOR_RANGE.SHUT_BACK_MARGIN
			for i in mesh.mesh.get_surface_count():
				var material:=mesh.get_active_material(i) as ShaderMaterial
				if material!=null:material.set_shader_parameter("interior_view",false)
		if mesh.name=="Exterior":
			var bounds:AABB=(global_transform.affine_inverse()*mesh.global_transform)*mesh.get_aabb()
			_ceiling_y=maxf(_ceiling_y,bounds.end.y)
	var house:=get_parent()
	# One mesh per material for the static window pieces (~90 draws per house -> ~5). Deferred:
	# the house is still setting up its children here, and the steps below may hide pieces.
	if house is Node3D: Callable(preload("res://world/buildings/window_batcher.gd"), "merge").call_deferred(house)
	# Generated shells collide one-sided: from inside, a wall's back face let the player walk
	# straight out. Two-sided here too for houses placed outside the town (labs, tests).
	for holder:CollisionShape3D in house.find_children("*","CollisionShape3D",true,false):
		if holder.shape is ConcavePolygonShape3D:(holder.shape as ConcavePolygonShape3D).backface_collision=true
	_dress_floor(house)
	_dress_door()
	_open_wing(house)
	preload("res://world/interiors/house_finishes.gd").apply(house)
	var terrain_ramp:=house.get_parent().get_node_or_null("TerrainStairApproaches/"+str(house.name))
	if terrain_ramp!=null:
		# Instanced prefab children survive a PackedScene bake. Disable the
		# level-ground ramp when this plot supplies its fitted replacement.
		var base:StaticBody3D=house.get_node("StairBrush")
		base.collision_layer=0
		for mesh:MeshInstance3D in base.find_children("*","MeshInstance3D",true,false):
			mesh.visible=false
		var spec:Dictionary=terrain_ramp.get_meta("stair_spec")
		approach=Vector3(spec.center_x,spec.toe_y,spec.toe_z+.09)
	_clear_ramp(house, terrain_ramp)
	_place_bed.call_deferred()
	INTERIOR_RANGE.start_door_detail(self)
	# The authored roof already has inward-facing surfaces. An extra flat sheet sampled
	# above the floor cut through the sloping eaves and appeared as a blank slab indoors.

## The entrance ramp sits over the prefab's stoop steps. With two-sided collision the backs of
## those steps (and any stoop faces under the ramp) stuck up through the ramp's slope and
## stopped you walking up it (dev 2026-09-23). Drop every house collision triangle that lies
## inside the active ramp's volume, up to 6 cm above its surface, from this house's own copy.
func _clear_ramp(house:Node3D, terrain_ramp:Node) -> void:
	HOUSE_SHELL_OPS._clear_ramp(self, house, terrain_ramp)

const WOOD:=preload("res://world/buildings/textures/wood_floor.res")
const INTERIOR:=preload("res://world/buildings/interior_surface.gdshader")
## Every house gets the wood plank floor (dev 2026-09-23), a shade of its own between
## dark and light brown; the plain tan floors and the pale stone threshold slab are gone.
func _dress_floor(house:Node3D) -> void:
	HOUSE_FLOOR_FIT._dress_floor(self, house)

var _floor_material:ShaderMaterial
## True once the floor and at least two walls of every room answer rays: the house's collision
## is really in the physics world (towns attach their bodies a few per frame).
func _walls_ready() -> bool:
	return HOUSE_FLOOR_FIT._walls_ready(self)

var _fitted_rooms:Array[Rect2]=[]   # floor rects moved to the real wall faces (_fit_floor)
## The real room, measured for the furniture placer. The floor rects are only approximate:
## measured against the shells, walls stand up to 28 cm beyond them or 52 cm inside them, raised
## rooms sit 23-56 cm above floor_y, and horizontal rays 1-6 cm above the floor escaped under the
## walls (captures/house-walls/floorgap.gd). So per rect: find the real floor height and move each
## side to the wall's inner face. (The wood underlay and skirting boards once laid from these
## measurements were retired on 2026-10-13: the approved linings draw floor and trim.)
var _fit_tries:=0
func _fit_floor() -> void:
	HOUSE_FLOOR_FIT._fit_floor(self)

## The door's inside face was a plain pink board: show the outside artwork there too,
## mirrored through the leaf so it sits just behind the back face.
func _dress_door() -> void:
	HOUSE_FLOOR_FIT._dress_door(self)

## Houses with a wing are two closed volumes: the main box and the wing each have their own
## wall where they meet, sealing the wing off (dev 2026-09-23). Cut a wide, doorway-height
## opening through every wall face standing on the shared edge of the two floor areas, in
## the visible shell and its collision. Done once per design; instances share the result.
static var _opened_meshes: Dictionary:
	get: return HOUSE_SHELL_OPS._opened_meshes
	set(value): HOUSE_SHELL_OPS._opened_meshes = value
static func _prefab_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	return HOUSE_SHELL_OPS._prefab_transform(node, ancestor)

func _open_wing(house:Node3D) -> void:
	HOUSE_SHELL_OPS._open_wing(self, house)

## The partition between a room and its wing is often one big panel that carries on as the
## outside wall (dev 2026-09-23). Cut a doorway out of it: of each wall triangle lying in the
## partition's plane, keep only the parts outside the opening (outside the shared span along
## the wall, or below the floor / above door height). Other triangles are returned whole.
## Pieces are polygons of barycentric coordinates of the original triangle.
static func _pieces(tri:Array,cut:Dictionary) -> Array:
	return HOUSE_SHELL_OPS._pieces(tri, cut)

## Sutherland-Hodgman: keep the part of a barycentric polygon where sign*(coord[axis]-value) >= 0.
static func _clip(poly:Array,coord:Callable,axis:int,sign:int,value:float) -> Array:
	return HOUSE_SHELL_OPS._clip(poly, coord, axis, sign, value)

static func _cut_mesh(source:Mesh,xf:Transform3D,cut:Dictionary) -> Mesh:
	return HOUSE_SHELL_OPS._cut_mesh(source, xf, cut)

## Append one vertex to every per-vertex array, blended from a triangle by barycentrics.
static func _interpolate_vertex(arrays:Array,ids:Array,w:Vector3) -> int:
	return HOUSE_SHELL_OPS._interpolate_vertex(arrays, ids, w)

const BED_SIZE:=Vector3(2.05,1.1,2.1)
var _bed_tries:=0

## Every house picks its own spot (seeded by the house, not its design): headboard to a
## wall, and usually one long side against the next wall too. A candidate must stay on the
## floor plan, keep clear of the door and hit no wall, window or door when box-tested.
func _place_bed() -> void:
	HOUSE_BEDS._place_bed(self)

func _create_bed(index: int) -> Node3D:
	return HOUSE_BEDS._create_bed(self, index)

## Physics may not yet contain a bed added this frame. Test the rectangles too,
## including the floor space existing sleepers need when they climb down.
func _clear_other_beds(xf: Transform3D, check_access: bool = true) -> bool:
	return HOUSE_BEDS._clear_other_beds(self, xf, check_access)

func _bed_access_clear(at: Vector3, reserved: Array[Transform3D]) -> bool:
	return HOUSE_BEDS._bed_access_clear(self, at, reserved)

func _bed_candidates() -> Array:
	return HOUSE_BEDS._bed_candidates(self)

## Nearest solid from the bed centre along a bed-space direction. A thin slab the width of
## the bed is swept (house walls are one-sided meshes that rays pass through from inside).
func _wall_distance(xf:Transform3D,direction:Vector3,exclude:Array[RID]=[]) -> float:
	return HOUSE_BEDS._wall_distance(self, xf, direction, exclude)

## The floor plan only approximates the walls: measure them. Headboard 3 cm off its wall,
## a corner bed's long side 3 cm off the side wall; then back off until the box is clear.
func _snug(xf:Transform3D,corner:bool) -> Variant:
	return HOUSE_BEDS._snug(self, xf, corner)

## Every sampled point of the footprint lies on this house's floor plan.
func _bed_on_floor(xf:Transform3D,slack:=0.0) -> bool:
	return HOUSE_BEDS._bed_on_floor(self, xf, slack)

## The bed's volume (just above the floor) touches no wall, window, door or other solid.
func bed_clear(xf:Transform3D,exclude:Array[RID]=[]) -> bool:
	return HOUSE_BEDS.bed_clear(self, xf, exclude)

## The long side open to the room (or the foot end), in bed space.
func _pick_bed_side(xf:Transform3D, reserved: Array[Transform3D] = []) -> Variant:
	return HOUSE_BEDS._pick_bed_side(self, xf, reserved)

func _bed_index(id: String) -> int:
	return HOUSE_BEDS._bed_index(self, id)

func ensure_bed(id: String = "") -> Node3D:
	return HOUSE_BEDS.ensure_bed(self, id)

func bed_shared(id: String) -> bool:
	return HOUSE_BEDS.bed_shared(self, id)

## Floor point beside the bed, where a pony stands before climbing in.
func bed_side(id: String = "") -> Vector3:
	return HOUSE_BEDS.bed_side(self, id)

## Where she lies: on the mattress, head toward the pillows.
func bed_rest(id: String = "") -> Transform3D:
	return HOUSE_BEDS.bed_rest(self, id)

## Loaded residents retain their world position, including on top of a mattress.
## Test the assigned bed's surface, not distance to the approach marker on the floor.
func on_mattress(point: Vector3, id: String = "") -> bool:
	return HOUSE_BEDS.on_mattress(self, point, id)

## 0.1.0 perf: the id string is rebuilt only when the house has moved (callers ask ~57 times per
## physics tick). Rollback: PLACE_ID_CACHE = false.
const PLACE_ID_CACHE:=true
var _place_id_at:=Vector3.INF
var _place_id_text:=""
func place_id() -> String:
	var p:=global_position
	if PLACE_ID_CACHE and p==_place_id_at:return _place_id_text
	_place_id_at=p
	_place_id_text="house:%d:%d:%d"%[roundi(p.x*10),roundi(p.y*10),roundi(p.z*10)]
	return _place_id_text
func label() -> String:return "House "+str(get_parent().name)
func door() -> Node:return get_parent().get_node_or_null("FrontDoor")

## Potato tier (dev 2026-09-29: "have the insides of houses be loaded in only when the door is
## open OR when you're close enough to see through the window, within 20 m"): every interior
## geometry instance stops drawing past `interior_range` metres (quality.gd, Very Low 20) while
## the front door is shut; an open door shows the room from any distance.
var _range_cap:=0.0
var _range_originals:Dictionary={}   # GeometryInstance3D -> its own visibility_range_end
var _range_door_open:=false
func _apply_interior_range() -> void:
	INTERIOR_RANGE._apply_interior_range(self)

func _tend_interior_range() -> void:
	INTERIOR_RANGE._tend_interior_range(self)

func _set_interior_range(open:bool) -> void:
	INTERIOR_RANGE._set_interior_range(self, open)

## Far door detail: pull and shut-leaf draw ranges (interior_range.gd), every half second.
var _door_detail:Dictionary={}
func _tend_door_detail() -> void:
	INTERIOR_RANGE.tend_door_detail(self, _door_detail)

func contains(at:Vector3,lighting:bool=false) -> bool:
	var p:=to_local(at)
	if p.y<floor_y-.025 or p.y>(_ceiling_y if lighting else floor_y+.25):return false
	for rect:Rect2 in floors:
		if rect.has_point(Vector2(p.x,p.z)):
			if absf(rect.end.y-doorway.z)<.06 and absf(p.x-doorway.x)<door_width*.55 and p.z>doorway.z-.002:continue
			return true
	return false
static func at(tree:SceneTree,point:Vector3) -> Node3D:
	for home:Node3D in tree.get_nodes_in_group("house_interiors"):
		# Most houses are far away: a distance check skips their to_local and floor rects.
		if (home.global_position-point).length_squared()>home._reach_squared():continue
		if home.contains(point):return home
	return null
var _reach_sq:=-1.0
## Squared world distance from the origin beyond which contains() is always false.
func _reach_squared() -> float:
	if _reach_sq<0.0:
		var r:=0.0
		for rect:Rect2 in floors:
			for corner:Vector2 in [rect.position,rect.end,Vector2(rect.position.x,rect.end.y),Vector2(rect.end.x,rect.position.y)]:
				r=maxf(r,corner.length())
		var h:=maxf(absf(floor_y-.025),maxf(absf(_ceiling_y),absf(floor_y+.25)))
		var s:=global_basis.get_scale()
		var k:=maxf(s.x,maxf(s.y,s.z))
		_reach_sq=(r*r+h*h)*k*k+.01
	return _reach_sq
func inside() -> Vector3:return to_global(Vector3(doorway.x,floor_y,doorway.z-maxf(.20,door_width+.06)))
func outside() -> Vector3:return to_global(approach)
func center() -> Vector3:
	var rect:Rect2=floors[0];var mid:=rect.get_center()
	return to_global(Vector3(mid.x,floor_y,mid.y))
func slots() -> Array[Vector3]:
	var points:Array[Vector3]=[]
	var mid:Vector3=to_local(center())
	for offset:Vector3 in [Vector3(-.07,0,-.07),Vector3(.07,0,-.07),Vector3(-.07,0,.07),Vector3(.07,0,.07)]:
		points.append(to_global(mid+offset))
	return points
func fits(profile:Resource) -> bool:
	return door_width*global_basis.x.length()>profile.radius*2+.08 and .20*global_basis.y.length()>profile.clearance+.1
## Two-room houses: where the rooms actually connect. Some designs have a wall between the
## main room and the wing with one opening in it; walking the straight line (or the old
## fixed corner) pinned ponies against that wall. Measured once with rays at pony height
## along the shared edge; the centre of the widest clear run is the passage (local space).
var _passage:=Vector3.INF
var _passage_open_all:=false
var _passage_done:=false
func _measure_passage() -> void:
	HOUSE_ROUTING._measure_passage(self)

## Furniture stands off the furnisher's walking lanes (inside the door, the room centres, the
## opening or corner between rooms: interior_furnisher._mark_lanes), not off every straight
## line across a room. A pony sent straight across stopped against a wardrobe and a fireplace
## in house D (dev's bug: ponies stuck in houses). A line furniture blocks goes by the lanes,
## always forward along them, never back. INF when the straight line is clear or no lane helps.
const LINE_CLEARANCE:=.22   # metres: the body's half width at chest height
const LINE_CHEST:=.5        # metres above the floor
var _around_cache:Dictionary={}
func _around_furniture(from:Vector3,to:Vector3) -> Vector3:
	return HOUSE_ROUTING._around_furniture(self, from, to)

static func horizontal_distance(a:Vector3,b:Vector3) -> float:
	return HOUSE_ROUTING.horizontal_distance(a, b)

## The lane points between two places in the house, in walking order.
func _lane_route(from:Vector3,to:Vector3) -> Array[Vector3]:
	return HOUSE_ROUTING._lane_route(self, from, to)

func _room_centre(room:int) -> Vector3:
	return HOUSE_ROUTING._room_centre(self, room)

## Furniture or a wall across a straight walk at chest height (ponies are on another layer).
func _blocked_line(a:Vector3,b:Vector3) -> bool:
	return HOUSE_ROUTING._blocked_line(self, a, b)

func _room_of(point:Vector3) -> int:
	return HOUSE_ROUTING._room_of(self, point)

func local_waypoint(from:Vector3,to:Vector3) -> Vector3:
	return HOUSE_ROUTING.local_waypoint(self, from, to)
