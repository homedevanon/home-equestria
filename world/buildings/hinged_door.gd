extends AnimatableBody3D
## Hinge at the outside-left jamb. Positive Y rotation swings into the house (-Z).
@export var handle:=Vector3.ZERO
## Mirrored pairs choose their swing direction; target stays 0..open_limit() (at most PI/2).
@export var swing_direction: float = 1.0
## How far the leaf swings, at most a right angle. A house whose wall stands closer sets less
## (player bug board #33, 2026-10-28: Fluttershy's front door opened into her cottage wall).
@export var max_open := PI * .5

@export var navigation_box:=AABB()
## Writing either wakes an idle door (it stops ticking once settled, nothing near; 2026-10-14).
var holder: Node:
	set(value): holder=value;_wake()
var target:=0.0:
	set(value): target=value;_wake()
var angle_offset:=0.0
var _sound: AudioStreamPlayer3D
var _sound_cooldown:=0.0
## Open since the walk grid last heard it shut. The grid never caches a doorway sampled
## open (WalkGridService.door_settled_shut); ponies cross doors through house_travel, so a
## swing itself does not invalidate the grid.
var _nav_open:=false
var _visitors:Dictionary={}
const PASSAGE_LEASE_MS := 6000
const PASSAGE_QUEUE_RANGE := 18.0
const WATER_MASK := 1 << 15
var _passage_owner := 0
var _passage_order := 0
var _passage_crossing := false
var _close_after_passage:=false:
	set(value):
		if value!=_close_after_passage:_close_after_passage=value;_wake()
var _close_delay:=0.0:
	set(value):
		if value!=_close_delay:_close_delay=value;_wake()
static var _panel_replacements:Dictionary={}
## Arched doors hung on the outer wall face swung their tall middle through the arch's soffit and
## the room-side trim (player bug board #12, 2026-10-26). These move the hinge inward to the room
## side of the trim, in the house's own units (x12 in town): measured in front of the leaf's upper
## hinge half, plus 2.4 cm. Rectangular doors (houses B, C, D, F, Sugarcube) swing clear as they are.
const ARCH_INSETS:={"house_a:FrontDoor":.0207,"house_d:FrontDoor":.0513,"house_e:FrontDoor":.0389,"house_g:FrontDoor":.0349,
	"house_h:FrontDoor":.0378,"house_h:BalconyDoor":.0359}
const OUTLINE:=preload("res://world/ui/interact_outline.gd")
const SFX := preload("res://world/audio/interaction_sounds.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
## Knocking (player bug board #31): right-click a shut door on desktop, or rap it twice with a fist
## in VR. The door only raps and says a knock happened; player/door_knock.gd finds who answers.
const KNOCK_SOUND := "prop_impact"
const RAP_SPEED := 0.7   # m/s toward the leaf for a fist to count as a rap
var _rap_z: Dictionary = {}
var _raps: Array[float] = []
var _knock_ready := 0.0
const OPEN_SOUND := "prop_door_open"
const CLOSE_SOUND := "prop_door_close"
const SHUT:=.02 # radians; opening past this plays the open sound, reaching 0 the close
var _shut:=true
## True while a free player hand is within grip reach; the handle glows blue then and
## while gripped (dev, 2026-09-22: "the doorhandle glows blue when your hand is hovering").
var hovered:=false
var _glow:MeshInstance3D
var _glow_level:=0.0
static var _glow_mesh:QuadMesh
static var _glow_material:ShaderMaterial
## Forgiving world-metre margin around the full visible pull, independent of hand angle.
## Dev's October 4 correction supersedes the earlier narrow 14 cm spherical target:
## nearby diagonal approaches should catch, not require a precise forward offset.
const GRIP_REACH: float = 0.18
const PULL_HALF_LENGTH: float = 0.15
const PULL_RADIUS: float = 0.02
var _pull_centers: Array[Vector3] = []
var _pull_collisions: Array[CollisionShape3D] = []
## Only ponies actually intersected by an opening leaf; release exceptions once clear.
var _opening_ponies: Array[WeakRef] = []

func opening_angle() -> float: return rotation.y * swing_direction

## Reserve before the ramp: only the owner approaches the portal; other ponies wait on
## separate real support beside their side of the door. An exit takes the next free turn.
func queue_passage(pony: Node3D, entering: bool, outside: Vector3, inside: Vector3, room: Node3D) -> Dictionary:
	if not is_instance_valid(pony): return {}
	_wake()
	var id := pony.get_instance_id()
	if pony.global_position.distance_to(global_position) > PASSAGE_QUEUE_RANGE:
		release_passage(pony)
		return {}
	_expire_visitors()
	if not _visitors.has(id):
		_passage_order += 1
		_visitors[id] = {"actor": weakref(pony), "until": 0, "order": _passage_order, "entering": entering, "wait": Vector3.INF}
	var entry: Dictionary = _visitors[id]
	entry.until = Time.get_ticks_msec() + PASSAGE_LEASE_MS
	entry.entering = entering
	_select_passage_owner()
	var admitted := _passage_owner == id and not is_instance_valid(holder)
	if not admitted and not (entry.wait as Vector3).is_finite() and Time.get_ticks_msec() >= int(entry.get("probe_after",0)):
		entry.wait = _holding_point(pony, entering, outside, inside, room)
		entry.probe_after = Time.get_ticks_msec() + 1000
	return {"admitted": admitted, "wait": entry.wait}

func _expire_visitors() -> void:
	var now := Time.get_ticks_msec()
	for id: int in _visitors.keys():
		var entry: Dictionary = _visitors[id]
		var actor: Node3D = entry.actor.get_ref() as Node3D
		if not is_instance_valid(actor) or not actor.is_inside_tree() or entry.until < now \
				or actor.global_position.distance_to(global_position) > PASSAGE_QUEUE_RANGE:
			_visitors.erase(id)
			if id == _passage_owner: _passage_owner = 0; _passage_crossing = false

func _select_passage_owner() -> void:
	if _passage_owner != 0 and _visitors.has(_passage_owner): return
	var best_order := 2147483647
	var exiting := false
	for id: int in _visitors:
		var entry: Dictionary = _visitors[id]
		var leaves := not bool(entry.entering)
		if (leaves and not exiting) or (leaves == exiting and int(entry.order) < best_order):
			_passage_owner = id; best_order = int(entry.order); exiting = leaves

## Footprint, dry support and standing-body clearance stay live. Tickets reserve the
## chosen points too, since clip-tier actors need not have an enabled physics capsule.
func _holding_point(pony: Node3D, entering: bool, outside: Vector3, inside: Vector3, room: Node3D) -> Vector3:
	var forward := inside - outside; forward.y = 0.0
	if forward.length_squared() < .001: return Vector3.INF
	forward = forward.normalized()
	var side := forward.cross(Vector3.UP)
	var base := outside if entering else inside
	var profile: Resource = pony.get("profile") if pony.get("profile") is Resource else null
	var radius: float = maxf(.35, float(profile.radius)) if profile != null else .4
	var clearance: float = float(profile.clearance) if profile != null else 1.2
	var spacing := radius * 2.0 + .3
	var exclude: Array[RID] = []
	if pony is CollisionObject3D: exclude.append(pony.get_rid())
	var space := get_world_3d().direct_space_state
	for ring in range(1, 5):
		for sign_: float in [-1.0, 1.0]:
			for depth: float in [.8, 1.8]:
				var candidate := base + side * (ring * spacing * sign_) + forward * (depth if not entering else -depth)
				var centre := Vector3.INF
				var supported := true
				for offset: Vector3 in [Vector3.ZERO, Vector3(radius,0,0), Vector3(-radius,0,0), Vector3(0,0,radius), Vector3(0,0,-radius)]:
					var query := PhysicsRayQueryParameters3D.create(candidate + offset + Vector3.UP, candidate + offset - Vector3.UP * 4.0, 1 | (1 << 18) | WATER_MASK, exclude)
					var hit := space.intersect_ray(query)
					if hit.is_empty() or hit.normal.y < .7 or (hit.collider is CollisionObject3D and hit.collider.collision_layer & WATER_MASK): supported = false; break
					if not centre.is_finite(): centre = hit.position
					elif absf(centre.y - hit.position.y) > .18: supported = false; break
				if not supported: continue
				if is_instance_valid(room) and room.contains(centre) == entering: continue
				var occupied := false
				for entry: Dictionary in _visitors.values():
					var waiting: Vector3 = entry.wait
					if waiting.is_finite() and Vector2(waiting.x-centre.x, waiting.z-centre.z).length() < spacing: occupied = true; break
					var actor: Node3D = entry.actor.get_ref() as Node3D
					if actor != pony and is_instance_valid(actor) and Vector2(actor.global_position.x-centre.x, actor.global_position.z-centre.z).length() < spacing: occupied = true; break
				if occupied: continue
				var shape := CylinderShape3D.new(); shape.radius = radius; shape.height = clearance
				var volume := PhysicsShapeQueryParameters3D.new(); volume.shape = shape
				volume.transform.origin = centre + Vector3.UP * (clearance * .5 + .06)
				volume.collision_mask = 1 | 2 | 2048 | (1 << 17) | (1 << 18); volume.exclude = exclude
				if space.intersect_shape(volume, 1).is_empty(): return centre + Vector3.UP * .02
	return Vector3.INF

func request_passage(pony:Node3D) -> bool:
	if not is_instance_valid(pony) or pony.global_position.distance_to(global_position)>6.0:return false
	if is_instance_valid(holder):return false
	_wake()
	_expire_visitors()
	if opening_angle()<.1:_close_after_passage=true
	var id := pony.get_instance_id()
	if not _visitors.has(id):
		_passage_order += 1
		_visitors[id]={"actor":weakref(pony),"until":0,"order":_passage_order,"entering":true,"wait":Vector3.INF}
	_visitors[id].until=Time.get_ticks_msec()+PASSAGE_LEASE_MS
	_select_passage_owner()
	if _passage_owner != id: return false
	target=open_limit();_close_delay=2.0
	if opening_angle()>open_limit()-.07:_passage_crossing=true;return true
	return false

func release_passage(pony:Node) -> void:
	if not is_instance_valid(pony): return
	var id := pony.get_instance_id(); _visitors.erase(id)
	if _passage_owner == id: _passage_owner = 0; _passage_crossing = false
	_select_passage_owner()

func _update_visitors(delta:float) -> void:
	_expire_visitors()
	if not _visitors.is_empty() or is_instance_valid(holder):return
	_close_delay=maxf(0,_close_delay-delta)
	if _close_after_passage and _close_delay<=0:
		target=0.0
		if opening_angle()<.001:_close_after_passage=false
func _ready() -> void:
	# Once only: offline builders run this too and may pack the moved door.
	var inset_key:=(owner.scene_file_path.get_file().get_basename() if owner!=null else "")+":"+str(name)
	if ARCH_INSETS.has(inset_key) and not has_meta("arch_inset"):
		position+=transform.basis*Vector3(0,0,-float(ARCH_INSETS[inset_key]));set_meta("arch_inset",true)
	if ARCH_INSETS.has(inset_key):_line_inset_jamb(inset_key)
	# Offline-cleaned panels preserve the artwork without overlapping triangles.
	if _panel_replacements.is_empty():
		_panel_replacements=JSON.parse_string(FileAccess.get_file_as_string("res://world/buildings/door_panels/replacements.json"))
	var artwork:=get_node_or_null("OriginalDoorArtwork") as MeshInstance3D
	if artwork!=null and _panel_replacements.has(artwork.mesh.resource_path):
		for surface in artwork.mesh.get_surface_count():artwork.set_surface_override_material(surface,null)
		artwork.material_override=null
		artwork.mesh=load(_panel_replacements[artwork.mesh.resource_path])
	collision_layer=1;collision_mask=0;sync_to_physics=false
	add_to_group("house_doors")
	_sound=get_node_or_null("Creak")
	if _sound==null:
		_sound=AudioStreamPlayer3D.new();_sound.name="Creak";add_child(_sound)
	# Recorded door foley: one on leaving shut, one on latching; shared bounded mixer.
	_sound.bus="SFX";_sound.unit_size=1;_sound.max_distance=12;_sound.volume_db=-14
	if _glow_mesh==null:
		_glow_mesh=QuadMesh.new();_glow_mesh.size=Vector2(.14,.14)
		_glow_material=ShaderMaterial.new();_glow_material.shader=preload("res://shaders/handle_glow.gdshader")
	_glow=get_node_or_null("HandleGlow") # offline builders run this too and may pack it
	if _glow==null:
		_glow=MeshInstance3D.new();_glow.name="HandleGlow";add_child(_glow)
	_glow.mesh=_glow_mesh;_glow.material_override=_glow_material
	_glow.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;_glow.position=handle;_glow.visible=false
	# HouseInterior can resize the leaf vertically later in this same ready pass.
	_build_pulls.call_deferred()
	set_process(false)
func set_hovered(value:bool) -> void:
	hovered=value;set_process(true)
	# An unavailable handle must not keep advertising a grab during a fade-out.
	if not hovered and not is_instance_valid(holder): _process(0.0)
## The pulls get the shared blue cel outline while a free hand can take them or one holds them
## (dev 2026-09-30, replacing the old glowing square "HandleGlow", which stays hidden).
func _process(delta:float) -> void:
	var want:=1.0 if hovered or is_instance_valid(holder) else 0.0
	_glow_level=move_toward(_glow_level,want,delta*6.0) if want > 0.0 else 0.0
	_glow.visible=false
	var pulls:MeshInstance3D=get_node_or_null("PullHandles") as MeshInstance3D
	if pulls!=null:OUTLINE.set_amount(pulls,_glow_level)
	if _glow_level==want:set_process(false)
func handle_world() -> Vector3:return to_global(handle)

## Hung on the room side, the leaf sits up to ~50 cm behind the back of its outer reveal, which was
## fitted to the old outside hinge: an open ring round the shut door showed the room (dev
## 2026-11-03: "the door frame around them are totally empty"). A jamb lining made in Blender
## (door_frames/<house>_<door>.res, house units, threshold left open) runs from the reveal's back to
## the leaf face, painted like the reveal. Visual only: the reveal and walls keep the collision.
func _line_inset_jamb(key:String) -> void:
	var house:=get_parent() as Node3D
	var reveal_name:="DoorReveal" if name==&"FrontDoor" else str(name)+"Reveal"
	var path:="res://world/buildings/door_frames/"+key.replace(":","_")+".res"
	if house==null or house.get_node_or_null(reveal_name+"Inset")!=null or not ResourceLoader.exists(path):return
	var jamb:=MeshInstance3D.new();jamb.name=reveal_name+"Inset";jamb.mesh=load(path)
	# Read the reveal now: window_batcher.gd merges it (and drops its mesh) on a later deferred call.
	var reveal:=house.get_node_or_null(reveal_name) as MeshInstance3D
	if reveal!=null and reveal.mesh!=null:
		jamb.material_override=reveal.get_active_material(0)
		jamb.layers=reveal.layers;jamb.cast_shadow=reveal.cast_shadow
		jamb.visibility_range_end=reveal.visibility_range_end;jamb.visibility_range_end_margin=reveal.visibility_range_end_margin
		jamb.visibility_range_fade_mode=reveal.visibility_range_fade_mode
	# The house is still adding its children; a DoorReveal* sibling joins the batched window draw.
	house.add_child.call_deferred(jamb)

## Real handles and their colliders belong to the moving leaf: desktop's existing
## body ray can hit either handle and still calls this door's toggle_door().
func _build_pulls() -> void:
	# Offline builders can pack ready-created children. Replace only our generated
	# handles so a later town instance gets metre-sized pulls at its actual scale.
	for generated_name: String in ["PullHandles", "OutsidePullCollision", "InsidePullCollision"]:
		var generated: Node = get_node_or_null(generated_name)
		if generated != null:
			remove_child(generated)
			generated.free()
	_pull_centers.clear()
	_pull_collisions.clear()
	var dimensions: Vector3 = global_basis.get_scale().abs()
	var front: float = 0.0
	var back: float = -0.004
	var art: MeshInstance3D = get_node_or_null("OriginalDoorArtwork") as MeshInstance3D
	if art != null and art.mesh != null:
		var bounds: AABB = art.transform * art.mesh.get_aabb()
		front = maxf(front, bounds.end.z)
		# HouseInterior mirrors this artwork behind the leaf (it may ready after us).
		back = minf(back, bounds.position.z - 0.0045 - bounds.end.z)
	var inside: MeshInstance3D = get_node_or_null("InsideArtwork") as MeshInstance3D
	if inside != null and inside.mesh != null:
		var bounds: AABB = inside.transform * inside.mesh.get_aabb()
		back = minf(back, bounds.position.z)
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = Color("b49657")
	material.metallic = 0.65
	material.roughness = 0.48
	surface.set_material(material)
	var inverse_scale: Basis = Basis.from_scale(Vector3.ONE / dimensions)
	for face: float in [1.0, -1.0]:
		var center: Vector3 = handle
		center.z = front + 0.035 / dimensions.z if face > 0.0 else back - 0.035 / dimensions.z
		_pull_centers.append(center)
		var bar: CapsuleMesh = CapsuleMesh.new()
		bar.radius = PULL_RADIUS
		bar.height = 2.0 * (PULL_HALF_LENGTH + PULL_RADIUS)
		bar.radial_segments = 8
		bar.rings = 2
		surface.append_from(bar, 0, Transform3D(inverse_scale, center))
		# Two short stems join the pull to the wooden leaf, beyond any painted knob.
		var leaf_z: float = 0.0 if face > 0.0 else -0.004
		for end: float in [-1.0, 1.0]:
			var stem: BoxMesh = BoxMesh.new()
			stem.size = Vector3(0.035, 0.035, absf(center.z - leaf_z) * dimensions.z)
			var position_local: Vector3 = center
			position_local.y += end * PULL_HALF_LENGTH / dimensions.y
			position_local.z = (center.z + leaf_z) * 0.5
			surface.append_from(stem, 0, Transform3D(inverse_scale, position_local))
		var collision: CollisionShape3D = CollisionShape3D.new()
		collision.name = "OutsidePullCollision" if face > 0.0 else "InsidePullCollision"
		# Packed houses also scale individual leaves vertically. Analytic capsules
		# make Jolt coerce the entire compound door to uniform scale; a convex hull
		# accepts that scale and matches the inverse-scaled visible handle exactly.
		var arrays: Array = bar.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var points: PackedVector3Array = PackedVector3Array()
		for vertex: Vector3 in vertices:
			points.append(inverse_scale * vertex)
		var shape: ConvexPolygonShape3D = ConvexPolygonShape3D.new()
		shape.points = points
		shape.margin = 0.0001
		collision.shape = shape
		collision.position = center
		add_child(collision)
		_pull_collisions.append(collision)
	var mesh: MeshInstance3D = MeshInstance3D.new()
	mesh.name = "PullHandles"
	mesh.mesh = surface.commit()
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)

## Nearest point along the pull on the hand's own face, including the full bar.
## Keep all reach tolerances in metres even on differently scaled town houses.
func grip_point(from: Vector3) -> Vector3:
	if _pull_centers.size() != 2:
		return handle_world()
	var local: Vector3 = to_local(from)
	var middle: float = (_pull_centers[0].z + _pull_centers[1].z) * 0.5
	var center: Vector3 = _pull_centers[0] if local.z >= middle else _pull_centers[1]
	var half_length: float = PULL_HALF_LENGTH / global_basis.y.length()
	center.y = clampf(local.y, center.y - half_length, center.y + half_length)
	return to_global(center)

func can_grip(point: Vector3) -> bool:
	if not point.is_finite() or is_instance_valid(holder):
		return false
	var contact: Vector3 = grip_point(point)
	# A leaf-aligned box around the bar avoids clipping the diagonal corners of the
	# grab zone. Normalize axes so scaled houses retain the same real-world margin.
	var offset: Vector3 = point - contact
	if absf(offset.dot(global_basis.x.normalized())) > GRIP_REACH \
			or absf(offset.dot(global_basis.y.normalized())) > GRIP_REACH \
			or absf(offset.dot(global_basis.z.normalized())) > GRIP_REACH:
		return false
	if point.distance_squared_to(contact) < 0.00000001:
		# Keep a nonzero ray for hit_from_inside at the exact bar centre too.
		contact += global_basis.y.normalized() * 0.001
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(point, contact, 1)
	# Do not let the leaf's own early hit hide a jamb/wall farther along this ray. The doorway's
	# own reveal lining sits right beside the pull on some houses and blocked a hand that was
	# already on the bar (door survey 2026-09-30); a real wall between hand and pull still counts.
	var skip: Array[RID] = [get_rid()]
	skip.append_array(_frame_rids())
	query.exclude = skip
	query.hit_from_inside = true
	query.hit_back_faces = true
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

var _frames: Array[RID] = []
var _frames_found := false
## Collision of this doorway's own reveal lining ("DoorReveal*" beside the leaf in its house).
func _frame_rids() -> Array[RID]:
	if _frames_found: return _frames
	_frames_found = true
	var walk: Node = get_parent()
	for level in 3:
		if walk == null: break
		for child: Node in walk.get_children():
			if not str(child.name).contains("DoorReveal"): continue
			for body: Node in [child] + child.find_children("*", "CollisionObject3D", true, false):
				if body is CollisionObject3D: _frames.append((body as CollisionObject3D).get_rid())
		walk = walk.get_parent()
	return _frames

## A unicorn opening the door lifts the handle with magic: the handle area glows in her
## colour on her side of the leaf, swinging with it (UnicornMagic.burst).
func open_limit() -> float:
	return clampf(max_open, 0.0, PI * .5)

func magic_glow(color:Color,seconds:float,from:Vector3) -> void:
	var side:=signf(to_local(from).z-handle.z)
	if side==0.0:side=1.0
	preload("res://world/characters/magic/unicorn_magic.gd").burst(self,handle+Vector3(0,0,side*.06),color,seconds,.22)
func toggle_door() -> void:
	if not is_instance_valid(holder):target=0.0 if opening_angle()>.7 else open_limit()
func begin_grip(hand: Node, point: Vector3) -> bool:
	if not is_instance_valid(hand) or not can_grip(point):return false
	return begin_offered_grip(hand,point)

## The router commits the already displayed offer before its next refresh. Do not
## re-run a narrower/new contact query after visible-palm motion or leaf pushing.
func begin_offered_grip(hand:Node,point:Vector3)->bool:
	if not is_instance_valid(hand) or is_instance_valid(holder) or not point.is_finite():return false
	holder=hand;angle_offset=opening_angle()-hand_angle(point);target=opening_angle();_close_after_passage=false;set_process(true)
	return true
func drag(point: Vector3) -> void:
	if not is_instance_valid(holder) or not point.is_finite():return
	target=clampf(hand_angle(point)+angle_offset,0,open_limit())
func end_grip() -> void:
	holder=null;target=opening_angle();set_process(true)
	if not hovered: _process(0.0)
## Palm push (dev 2026-09-30: doors should be "WAY more ... dynamic"): an open hand pressed
## against the leaf moves it, with no grip. `side` names the hand. The side of the leaf the palm
## approached from is remembered while it is 5-25 cm away; within PUSH_CLEAR of the face it
## pushes, the leaf swinging just far enough to keep the palm on its own side (one Newton step
## per tick on the leaf angle). Near the pull the hand is gripping, not pushing.
const PUSH_CLEAR: float = 0.035
var _push_side: Dictionary = {}
func palm_push(side: String, point: Vector3) -> bool:
	if is_instance_valid(holder) or not point.is_finite() or not has_node("LeafCollision"):
		_push_side.erase(side); return false
	var collision: CollisionShape3D = $LeafCollision
	var box: AABB = collision.transform * collision.shape.get_debug_mesh().get_aabb()
	var local: Vector3 = to_local(point)
	var hinge_margin: float = 0.12 / maxf(0.001, global_basis.x.length())
	var along: float = local.x if box.get_center().x >= 0.0 else -local.x
	var reach: float = maxf(absf(box.position.x), absf(box.end.x))
	if along < hinge_margin or along > reach or local.y < box.position.y or local.y > box.end.y:
		_push_side.erase(side); return false
	var z: float = _leaf_z(point, opening_angle())
	if absf(z) > 0.25: _push_side.erase(side); return false
	if absf(z) > 0.05: _push_side[side] = signf(z); return false
	if not _push_side.has(side) or point.distance_to(grip_point(point)) < GRIP_REACH: return false
	var sigma: float = _push_side[side]
	if sigma * z >= PUSH_CLEAR: return false
	var angle: float = opening_angle()
	var slope: float = (_leaf_z(point, angle + 0.01) - z) / 0.01
	if absf(slope) < 0.001: return false
	target = clampf(angle + (sigma * PUSH_CLEAR - z) / slope, 0.0, open_limit())
	_close_after_passage = false
	return true

## Desktop: three raps. True when it counts as a knock.
func knock_from_desktop() -> bool:
	if is_instance_valid(holder) or opening_angle() > SHUT: return false
	_rap_times(3)
	return knock()

func _rap_times(count: int) -> void:
	for i in count:
		SFX.play_at(self, KNOCK_SOUND, handle_world())
		if i < count - 1 and not await SHUTDOWN.seconds(self, 0.24): return

## A knock is heard inside at most every few seconds.
func knock() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now < _knock_ready or opening_angle() > SHUT or not is_inside_tree(): return false
	_knock_ready = now + 4.0
	return true

## VR: a fist reaching the shut leaf fast is a rap (its own sound); two within 1.5 s are a knock
## (returns true then).
func hand_rap(side: String, point: Vector3, delta: float) -> bool:
	if is_instance_valid(holder) or opening_angle() > SHUT or not point.is_finite() or not has_node("LeafCollision"):
		_rap_z.erase(side); return false
	var collision: CollisionShape3D = $LeafCollision
	var box: AABB = collision.transform * collision.shape.get_debug_mesh().get_aabb()
	var local: Vector3 = to_local(point)
	var along: float = local.x if box.get_center().x >= 0.0 else -local.x
	if along < 0.0 or along > maxf(absf(box.position.x), absf(box.end.x)) or local.y < box.position.y or local.y > box.end.y:
		_rap_z.erase(side); return false
	var z: float = absf(_leaf_z(point, 0.0))
	var before: float = _rap_z.get(side, INF)
	_rap_z[side] = z
	if before == INF or before < 0.05 or z >= 0.05 or (before - z) / maxf(delta, 0.001) < RAP_SPEED: return false
	SFX.play_at(self, KNOCK_SOUND, point)
	var now := Time.get_ticks_msec() / 1000.0
	_raps = _raps.filter(func(t: float) -> bool: return now - t < 1.5)
	_raps.append(now)
	if _raps.size() < 2: return false
	_raps.clear()
	return knock()

## World metres from the leaf's centre plane to `point` if the leaf stood at `angle`.
func _leaf_z(point: Vector3, angle: float) -> float:
	var p: Vector3 = get_parent().to_local(point) - position
	var leaf: Basis = Basis(Vector3.UP, angle * swing_direction) * Basis.from_scale(scale)
	var collision: CollisionShape3D = $LeafCollision
	var centre: float = (collision.transform * collision.shape.get_debug_mesh().get_aabb()).get_center().z
	return ((leaf.inverse() * p).z - centre) * global_basis.z.length()

func hand_angle(point: Vector3) -> float:
	var p:Vector3=get_parent().to_local(point)-position
	return atan2(-p.z,p.x) * swing_direction
func _physics_process(delta: float) -> void:
	_update_visitors(delta)
	_sound_cooldown=maxf(0,_sound_cooldown-delta)
	if opening_angle()>.001 and not _nav_open:_nav_open=true;add_to_group("open_house_doors")
	var next:=move_toward(opening_angle(),target,2.3*delta)
	if is_equal_approx(next,opening_angle()):
		# A still leaf only drops pony exceptions once they walked clear: two shape queries five
		# times a second instead of every tick (doors held open by passing ponies, 2026-11-08).
		if not _opening_ponies.is_empty():
			_overlap_wait -= delta
			if _overlap_wait <= 0.0:
				_overlap_wait = OVERLAP_REFRESH
				_allow_opening_pony_overlap(global_transform)
		if _nav_open and opening_angle()<=.001:_notify_navigation()
		_sleep_if_settled()
		return
	# Opening clips through ponies (dev October 7); players and loose items still stop it.
	# Closing retains the occupied-doorway stop.
	if next < opening_angle(): _clear_opening_ponies()
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=$LeafCollision.shape
	var leaf_transform: Transform3D = get_parent().global_transform * Transform3D(Basis(Vector3.UP,next*swing_direction).scaled(scale),position)
	query.transform=leaf_transform*$LeafCollision.transform
	query.collision_mask=2048|(1<<17)|(2 if next < opening_angle() else 0);query.exclude=[get_rid()];query.margin=.001
	if not get_world_3d().direct_space_state.intersect_shape(query,1).is_empty():
		if not is_instance_valid(holder):target=opening_angle()
		return
	# The added solid pulls must respect the same occupied-doorway stop as the leaf.
	for collision: CollisionShape3D in _pull_collisions:
		query.shape = collision.shape
		query.transform = leaf_transform * collision.transform
		if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			if not is_instance_valid(holder):target=opening_angle()
			return
	if next > opening_angle(): _allow_opening_pony_overlap(leaf_transform)
	_overlap_wait = 0.0
	rotation.y=next*swing_direction
	if next>.001 and not _nav_open:_nav_open=true;add_to_group("open_house_doors")
	if _shut and next>=SHUT:_shut=false;_play(OPEN_SOUND)
	elif not _shut and next<=.001:_shut=true;_play(CLOSE_SOUND)

const OVERLAP_REFRESH := 0.2
var _overlap_wait := 0.0

## A settled door with nobody queued, holding or overlapping stops its physics tick (51 town doors
## idled every tick, 2026-10-14). Every input that can move it (target, holder, a passage request,
## the close-after-passage timer) wakes it again; see _wake.
func _sleep_if_settled() -> void:
	if _visitors.is_empty() and not is_instance_valid(holder) and not _close_after_passage and _close_delay<=0.0 \
			and _sound_cooldown<=0.0 and _opening_ponies.is_empty() and is_equal_approx(target,opening_angle()):
		set_physics_process(false)

func _wake() -> void:
	if not is_physics_processing():set_physics_process(true)

## Ignoring the obstruction query alone still lets AnimatableBody shove a pony's capsule.
## Pairwise exceptions permit real clipping without changing any world/pony collision layer.
func _allow_opening_pony_overlap(leaf_transform: Transform3D) -> void:
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 2; query.exclude = [get_rid()]; query.margin = .001
	var intersecting: Array[PhysicsBody3D] = []
	var shapes: Array[CollisionShape3D] = [$LeafCollision]
	shapes.append_array(_pull_collisions)
	for collision: CollisionShape3D in shapes:
		query.shape = collision.shape; query.transform = leaf_transform * collision.transform
		for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 32):
			var pony: PhysicsBody3D = hit.get("collider") as PhysicsBody3D
			if pony != null and not intersecting.has(pony): intersecting.append(pony)
	for ref: WeakRef in _opening_ponies:
		var pony: PhysicsBody3D = ref.get_ref() as PhysicsBody3D
		if pony != null and not intersecting.has(pony): remove_collision_exception_with(pony)
	_opening_ponies.clear()
	for pony: PhysicsBody3D in intersecting:
		add_collision_exception_with(pony); _opening_ponies.append(weakref(pony))

func _clear_opening_ponies() -> void:
	for ref: WeakRef in _opening_ponies:
		var pony: PhysicsBody3D = ref.get_ref() as PhysicsBody3D
		if pony != null: remove_collision_exception_with(pony)
	_opening_ponies.clear()

func _play(event: String) -> void:
	# A hand wobbling the leaf at the jamb must not machine-gun the latch.
	if _sound_cooldown>0:return
	SFX.play_at(self, event)
	_sound_cooldown=.6

func navigation_world_box() -> AABB:
	return get_parent().global_transform*Transform3D(Basis.IDENTITY,position)*navigation_box

func _notify_navigation() -> void:
	_nav_open=false;remove_from_group("open_house_doors")
	var box:=navigation_world_box()
	for grid: Node in get_tree().get_nodes_in_group("pony_navigation"):
		if grid.has_method("door_settled_shut"):grid.door_settled_shut(box)
