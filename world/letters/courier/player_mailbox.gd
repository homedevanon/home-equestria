extends Node
## Anon's mailbox (docs/LETTERS_PLAN_2026_10_29.md section 10). A mailbox of his own (mailbox/*.scn:
## a rural box on a post, a door that falls open, a red flag) stands beside the path at his front
## door, wherever his home is (letter_courier.gd player_home). The replies and notes Derpy dropped
## (letter_courier.gd state mailbox) show as one letter (activity/letter.scn) lying inside it, the
## flag is up while there is mail, and the door opens while he stands at it or Derpy comes to put a
## letter in (letter_courier.gd starts her flight, mailbox_swoop.gd flies it). Until the box can
## stand (his home's ground not loaded, a door on a cloud) the letter pokes out of the kit mailbox
## nearest his house within 25 m, or lies on the ground by his front door.
##
## Taking it works like harvest_pickup.gd: VR grip through the grab router (group grab_providers),
## desktop click or E while aiming at it with a free hand. letter_courier.gd take_letter does the
## take (briefcase, hand, gift, status taken); the oldest letter comes first. In the provider groups
## only while a letter is shown, so an empty mailbox costs nothing. letter_courier.gd calls refresh()
## once a second: that places the box and wakes the door and flag; they animate per frame only while
## he is within WAKE_DISTANCE, Derpy is on her way, or they are still swinging.
##
## He can also post his finished letters in it (letter_courier.gd post_in_mailbox, started from
## letter_tool.gd: click or E aimed at the box on desktop, a VR grip let go at the letter spot). They
## lie there with the incoming mail (incoming first, each oldest first), raise the flag and can be
## taken out again the same way until Derpy collects them. The door, flag and letters make their
## sounds (interaction_sounds.gd props cues) on each change only, never when the box is built or a
## world loads. Snow and rain wetness reach the box through snow_materials.gd adopt().
const KIT_SPOTS := preload("res://world/props/ponyville_kit/kit_spots.gd")
const FITS := preload("res://world/props/ponyville_kit/kit_fits.gd")
const FLIGHT := preload("res://player/wing_flight.gd")
const SWOOP := preload("res://world/letters/courier/courier_swoop.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const SNOW := preload("res://world/seasons/snow_materials.gd")
const LETTER_TOOL := preload("res://world/letters/paper/letter_tool.gd")
const LETTER := "res://world/props/ponyville_kit/activity/letter.scn"
const MODELS := "res://world/letters/courier/mailbox/%s.scn"
const MAILBOX_REACH := 25.0
const DESKTOP_REACH := 2.4
## Metres the desktop aim ray may pass beside the letter.
const AIM_SLACK := 0.16
const VR_REACH := 0.25
## A letter by the door lies flat, a little to the side of the step.
const DOOR_OFFSET := Vector3(0.6, 0.02, 0.0)

## Where the box stands from the front door step (house_interior.gd outside()): OUT metres away from
## the house, SIDE metres to its right (negative: left), its door facing the path, then turned TURN
## radians about the vertical (negative = clockwise seen from above).
const OUT := 2.6
const SIDE := 1.5
const TURN := -PI / 2.0
## Beyond this the box fades out (its meshes' visibility range).
const SHOW_DISTANCE := 150.0
## Metres the ground at the spot may lie below or above the door step; past that (a cloud house)
## there is nothing to stand it on.
const GROUND_STEP := 4.0

## The model, in its own frame (metres): the opening (door) at -X, closed end at +X, box from y 0.98
## to 1.27. mailbox_door.scn's door sits on the opening, hinged at its bottom edge.
const DOOR_HINGE := Vector3(-0.211, 0.98, 0.0)
## Radians about Z: the door falls open, top outward (-X).
const DOOR_OPEN := 1.75
## mailbox_flag.scn lies down in its file; it sits on the box's side, pivot toward the opening. As on
## a US rural mailbox: lowered, the arm runs from the pivot toward the closed back with the red plate
## hanging below its end (the file's flag flipped 180 degrees about the arm, X); raised, it turns
## +90 degrees about Z to stand upright with the plate at the top pointing back, while there is mail.
const FLAG_AT := Vector3(-0.121, 1.129, -0.135)
const FLAG_REST := Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, -1))
const FLAG_UP := PI / 2.0
## The letter (letter.scn: origin at its top edge) lies flat on the box floor, centred on the model's
## LetterSpot empty, long edge across, top edge toward the opening.
const LETTER_LIFT := 0.005
const LETTER_BASIS := Basis(Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0))
const LETTER_HALF := 0.07
## Where Derpy's mouth puts the letter in: just outside the open door, mid-height.
const SLOT := Vector3(-0.32, 1.12, 0.0)

## The door opens while Anon is this close (to take his mail) or Derpy this close to the slot.
const OPEN_NEAR := 2.3
const DERPY_NEAR := 5.0
const SWING_SPEED := 5.0
## Door and flag animate per frame only while he is this close (checked once a second while idle).
const WAKE_DISTANCE := 15.0
## Desktop posting: the view ray passes this close to the middle of the box, within DESKTOP_REACH.
const POST_AIM := 0.3
## The middle of the box in its own frame.
const BOX_MIDDLE := Vector3(0.0, 1.125, 0.0)

var courier: Node
## The briefcase node: grab_router.gd matches its providers by this field.
var inventory: Node
var prop: Node3D
## Test hook: Callable(Vector3) -> float, the ground height there (NAN while unknown). Default: the
## world terrain; with no terrain at all the box is not placed.
var ground_height: Callable
## Test hook: Callable(String cue) called instead of playing a sound.
var sound_hook: Callable
var _home: Node3D
## The placed box: model, door hinge, flag pivot and collision.
var _box: Node3D
var _door: Node3D
var _flag: Node3D
var _letter_rest := Transform3D()
var _door_angle := 0.0
var _flag_angle := 0.0
var _has_mail := false
## Where the flag was last sent (up or down), so its sound plays once per change.
var _flag_heading := 0.0
## Derpy's flight bringing mail (letter_courier.gd expect()), while it lasts.
var _visitor: SWOOP
## While Derpy's letter slides from her mouth into the box.
var _slide: Tween

func setup(owner_courier: Node) -> void:
	courier = owner_courier
	set_process_unhandled_input(false)
	set_process(false)

## Places the box, then shows, moves or removes the letter for the current mailbox (letter_courier.gd
## poll and takes).
func refresh() -> void:
	inventory = courier.briefcase() if courier != null else null
	var ids := _shown_ids()
	_has_mail = not ids.is_empty()
	_keep_placed()
	_wake()
	var spot: Variant = spot_transform() if not ids.is_empty() else null
	if not spot is Transform3D:
		_clear()
		return
	if not is_instance_valid(prop):
		var scene := load(LETTER) as PackedScene
		if scene == null: return
		prop = scene.instantiate() as Node3D
		if prop == null: return
		prop.name = "MailboxLetter"
		prop.transform = spot
		add_child(prop)
	elif not prop.transform.is_equal_approx(spot) and not (_slide != null and _slide.is_running()):
		# A slide in progress owns the letter's transform until it lands.
		prop.transform = spot
	for group: String in ["grab_providers", "interaction_hint_sources"]:
		if not is_in_group(group): add_to_group(group)
	_update_input()

func _clear() -> void:
	for group: String in ["grab_providers", "interaction_hint_sources"]:
		if is_in_group(group): remove_from_group(group)
	if is_instance_valid(prop): prop.queue_free()
	prop = null
	_update_input()

## The letters in the box in the order they are shown and taken: incoming mail, then his own posted
## letters, each oldest first.
func _shown_ids() -> Array:
	if courier == null: return []
	return courier.mailbox_ids() + courier.outbox_ids()

## Clicks and E reach this node while a letter is shown (taking it) or while he is near the standing
## box (posting one with E; a click on a held letter goes through letter_tool.gd).
func _update_input() -> void:
	set_process_unhandled_input(is_instance_valid(prop) or (placed() and _player_gap() < WAKE_DISTANCE))

## Where the letter sits: on the floor of his own box when it stands, else out of the door of the kit
## mailbox nearest his house (activity/fit.json letter_rest), else flat by his front door; null
## without a loaded home.
func spot_transform() -> Variant:
	if placed(): return _box.global_transform * _letter_rest
	var home: Node3D = courier.player_home() if courier != null else null
	if home == null: return null
	var door: Vector3 = home.call("outside") if home.has_method("outside") else home.global_position
	KIT_SPOTS._index()
	var best := ""
	var gap := MAILBOX_REACH * MAILBOX_REACH
	for id: String in KIT_SPOTS._by_kind.get("mailbox", []):
		var row: Dictionary = KIT_SPOTS._by_id[id]
		var distance := Vector2(float(row.x) - door.x, float(row.z) - door.z).length_squared()
		if distance < gap: gap = distance; best = id
	var fit := FITS.get_kind("mailbox")
	if not best.is_empty() and not fit.is_empty():
		var spot: Dictionary = KIT_SPOTS.by_id(best)
		var rest: Transform3D = (spot.transform as Transform3D) * FITS.transform(fit.get("letter_rest"))
		if rest.is_finite(): return rest
	var facing := home.global_basis.orthonormalized() if home.global_basis.is_finite() else Basis.IDENTITY
	return Transform3D(facing, door + facing * DOOR_OFFSET)

# --- His own box at the door ----------------------------------------------------------------------

## True while his own box stands at his door.
func placed() -> bool:
	return is_instance_valid(_box) and _box.is_inside_tree()

## The foot of the box's post (world); INF while it does not stand.
func stand_point() -> Vector3:
	return _box.global_position if placed() else Vector3.INF

## Where Derpy's mouth puts a letter in, just outside the open door (world); INF while the box does
## not stand.
func slot_point() -> Vector3:
	return _box.global_transform * SLOT if placed() else Vector3.INF

## The door's outward direction (world, level).
func door_out() -> Vector3:
	return -_box.global_basis.x.normalized() if placed() else Vector3.FORWARD

## Where a posted letter goes and a VR hand posts it: the letter spot on the box floor (world); INF
## while the box does not stand.
func post_point() -> Vector3:
	return (_box.global_transform * _letter_rest).origin if placed() else Vector3.INF

## Desktop: `camera` looks at the standing box within reach (DESKTOP_REACH, POST_AIM).
func aimed_at(camera: Camera3D) -> bool:
	if not placed() or camera == null: return false
	var middle := _box.global_transform * BOX_MIDDLE
	var eye := camera.global_position
	var ahead := -camera.global_basis.z
	var along := (middle - eye).dot(ahead)
	return along > 0.0 and along <= DESKTOP_REACH and (middle - eye - ahead * along).length() <= POST_AIM

## Plays one of the mailbox's sounds (interaction_sounds.gd cue) at the box; nothing while it does
## not stand.
func play_cue(cue: String, at := Vector3.INF) -> void:
	if sound_hook.is_valid():
		sound_hook.call(cue)
		return
	if placed(): SOUNDS.play_at(_box, cue, at)

## A world just loaded: the door shut and the flag where the mail says, without a sound.
func snap_pose() -> void:
	_door_angle = 0.0
	_flag_angle = FLAG_UP if _has_mail else 0.0
	_flag_heading = _flag_angle
	_apply_pose()

## letter_courier.gd: Derpy's flight `sortie` is coming to the box; the door opens for her as she comes.
func expect(sortie: SWOOP) -> void:
	_visitor = sortie
	if placed(): set_process(true)

## letter_courier.gd, at Derpy's drop: the letter is shown gliding from `from` (her mouth) to where it
## rests in the box.
func slide_in(from: Transform3D, seconds := 0.35) -> void:
	refresh()
	if not is_instance_valid(prop): return
	var rest := prop.transform
	prop.global_transform = from
	if _slide != null and _slide.is_valid(): _slide.kill()
	_slide = create_tween()
	_slide.tween_property(prop, "transform", rest, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	play_cue("prop_mailbox_letter", rest.origin)

## letter_courier.gd, at Derpy's pickup: a letter is shown gliding from the box to `to` (her mouth);
## the box then shows what is left in it.
func slide_out(to: Transform3D, seconds := 0.35) -> void:
	var scene := load(LETTER) as PackedScene
	var from: Variant = prop.transform if is_instance_valid(prop) else (_box.global_transform * _letter_rest if placed() else null)
	refresh()
	if scene == null or not from is Transform3D: return
	var ghost := scene.instantiate() as Node3D
	if ghost == null: return
	ghost.name = "LeavingLetter"
	ghost.transform = from
	add_child(ghost)
	var glide := create_tween()
	glide.tween_property(ghost, "transform", to, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	glide.tween_callback(ghost.queue_free)

## Places the box at his home (again if he moved house); removes it while he has none. A spot whose
## ground is not loaded yet is tried again on the next refresh.
func _keep_placed() -> void:
	var home: Node3D = courier.player_home() if courier != null else null
	if home != null and is_instance_valid(_home) and home == _home and is_instance_valid(_box): return
	_remove_box()
	if home == null: return
	var at: Variant = _stand_transform(home)
	if not at is Transform3D: return
	_box = _build(at)
	if _box != null: _home = home

func _remove_box() -> void:
	if is_instance_valid(_box): _box.queue_free()
	_box = null
	_door = null
	_flag = null
	_home = null
	set_process(false)

## Beside the path out of the front door, its door facing the path, on the ground; null while that
## ground is unknown or too far from the door step. The usual spot (OUT, SIDE) when it is open ground
## (_open_ground); else, where houses stand close to the street, the first open one beside the ramp
## toe (TOE_SIDES), then by the front corners (CORNER_SPOTS); none open: the usual spot anyway.
func _stand_transform(home: Node3D) -> Variant:
	if not home.has_method("outside"): return null
	var door: Vector3 = home.call("outside")
	var middle: Vector3 = home.call("center") if home.has_method("center") else home.global_position
	var out := Vector3(door.x - middle.x, 0.0, door.z - middle.z)
	if out.length_squared() < 0.01: return null
	out = out.normalized()
	var right := out.cross(Vector3.UP).normalized()
	var at := door + out * OUT + right * SIDE
	var ground := _ground(at)
	if not is_finite(ground) or absf(ground - door.y) > GROUND_STEP: return null
	at.y = ground
	# Its opening (-X) faces the path: toward -right (to the left when SIDE is negative), so +X points away.
	var front := -right if SIDE >= 0.0 else right
	var facing := Basis(-front, Vector3.UP, (-front).cross(Vector3.UP))
	var turned := Basis(Vector3.UP, TURN) * facing
	if _open_ground(at, home):
		return Transform3D(turned, at)
	for spot: Vector3 in _other_spots(home, door, out, right):
		var height := _ground(spot)
		if not is_finite(height) or absf(height - door.y) > GROUND_STEP: continue
		spot.y = height
		if _open_ground(spot, home):
			return Transform3D(turned, spot)
	return Transform3D(turned, at)

## Beside the ramp toe: metres to its right (negative: left), nearest first.
const TOE_SIDES: Array[float] = [0.8, 1.2, -0.8, -1.2]
## By the front corners: (metres back from the front of the house's floors, metres out past its side),
## the right side first.
const CORNER_SPOTS: Array[Vector2] = [Vector2(0.6, 1.2), Vector2(0.6, 1.8)]
## The space the box needs, half extents (m): its footprint, and up past the eaves of a house.
const ROOM_HALF := Vector3(0.25, 3.5, 0.25)
## A spot whose ground paint is this much street or path (terrain_paths.gd weight) is on the street.
const STREET_PAINT := 0.5
const WATER_MASK := 1 << 15
var _paths: RefCounted

## The other spots, in the order tried: beside the ramp toe, then by the front corners.
func _other_spots(home: Node3D, door: Vector3, out: Vector3, right: Vector3) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	for side: float in TOE_SIDES:
		spots.append(door + right * side)
	var floors: Variant = home.get("floors")
	if not floors is Array or (floors as Array).is_empty(): return spots
	# The house's floors seen from the door: their front edge along `out`, their sides along `right`.
	var front := -INF
	var low := INF
	var high := -INF
	for rect: Variant in floors:
		if not rect is Rect2: continue
		var r: Rect2 = rect
		for corner: Vector2 in [r.position, r.end, Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.position.y)]:
			var p := home.to_global(Vector3(corner.x, 0.0, corner.y)) - door
			front = maxf(front, p.dot(out))
			low = minf(low, p.dot(right))
			high = maxf(high, p.dot(right))
	if not is_finite(front): return spots
	for edge: float in [high, low]:
		for spot: Vector2 in CORNER_SPOTS:
			spots.append(door + out * (front - spot.x) + right * (edge + signf(edge - (low + high) * 0.5) * spot.y))
	return spots

## Open ground for the box at `at` (on the ground): no street or path paint, no water over the ground,
## and nothing static (a roof or eaves, a wall, another house, the ramp, paving, a fence, a tree) in
## its space. Checks it cannot make (no physics world, no terrain paint) pass.
func _open_ground(at: Vector3, home: Node3D) -> bool:
	if _street_paint(at) >= STREET_PAINT: return false
	var world: World3D = home.get_world_3d() if home.is_inside_tree() else null
	if world == null: return true
	var space := world.direct_space_state
	var water := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 3.0, at + Vector3.DOWN * 0.5, WATER_MASK)
	water.hit_back_faces = true
	var wet := space.intersect_ray(water)
	if not wet.is_empty() and (wet.position as Vector3).y > at.y + 0.05: return false
	var box := BoxShape3D.new()
	box.size = ROOM_HALF * 2.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.collision_mask = 1
	query.collide_with_areas = false
	# From just under the ground, so paving and a ramp's foot count; the ground itself does not.
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * (ROOM_HALF.y - 0.1))
	for hit: Dictionary in space.intersect_shape(query, 16):
		var collider: Variant = hit.get("collider")
		if not collider is Node or collider is CharacterBody3D or collider is RigidBody3D or collider is PhysicalBone3D: continue
		var node := collider as Node
		if is_ancestor_of(node): continue
		var ground := false
		for i in 3:
			if node == null: break
			if node.is_in_group("world_terrain"): ground = true; break
			node = node.get_parent()
		if not ground: return false
	return true

## How much street or path paint the terrain has at `at` (0..1); 0 without terrain paint.
func _street_paint(at: Vector3) -> float:
	if not is_instance_valid(WorldTerrain.instance) or WorldTerrain.instance.terrain == null: return 0.0
	# Bound again when a reloaded world brings new terrain data.
	if _paths == null or not is_instance_valid(_paths.get("data")):
		var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(WorldTerrain.TEXTURES))
		_paths = preload("res://world/navigation/terrain_paths.gd").new()
		_paths.call("bind", WorldTerrain.instance.terrain.data, (doc as Dictionary).get("textures", []) if doc is Dictionary else [])
	return float(_paths.call("weight_at", at))

func _ground(at: Vector3) -> float:
	if ground_height.is_valid(): return float(ground_height.call(at))
	if is_instance_valid(WorldTerrain.instance): return WorldTerrain.instance.height_at(at)
	return NAN

## The box, its hinged door and flag and something solid to bump into, at `at`; null when a model is
## missing.
func _build(at: Transform3D) -> Node3D:
	for part: String in ["mailbox", "mailbox_door", "mailbox_flag"]:
		if not ResourceLoader.exists(MODELS % part): return null
	var box_scene := load(MODELS % "mailbox") as PackedScene
	var door_scene := load(MODELS % "mailbox_door") as PackedScene
	var flag_scene := load(MODELS % "mailbox_flag") as PackedScene
	if box_scene == null or door_scene == null or flag_scene == null: return null
	var box := box_scene.instantiate() as Node3D
	if box == null: return null
	var root := Node3D.new()
	root.name = "AnonMailbox"
	box.name = "Mailbox"
	root.add_child(box)
	var spot := box.find_child("LetterSpot", true, false) as Node3D
	var centre := (box.transform * spot.transform).origin if spot != null else Vector3(0.0, 1.0, 0.0)
	_letter_rest = Transform3D(LETTER_BASIS, centre + Vector3(-LETTER_HALF, LETTER_LIFT, 0.0))
	_flag = Node3D.new()
	_flag.name = "FlagPivot"
	_flag.position = FLAG_AT
	root.add_child(_flag)
	_flag.add_child(flag_scene.instantiate())
	_door = Node3D.new()
	_door.name = "DoorHinge"
	_door.position = DOOR_HINGE
	root.add_child(_door)
	var door := door_scene.instantiate() as Node3D
	door.name = "Door"
	_door.add_child(door)
	# The post and the back of the box are solid; the front stays open to the desktop aim ray, which
	# desktop_offer() checks against layer 1.
	var solid := StaticBody3D.new()
	solid.name = "Collision"
	solid.collision_layer = 1
	solid.collision_mask = 0
	var post := CollisionShape3D.new()
	var post_shape := BoxShape3D.new()
	post_shape.size = Vector3(0.1, 0.98, 0.1)
	post.shape = post_shape
	post.position = Vector3(0.0, 0.49, 0.0)
	solid.add_child(post)
	var back := CollisionShape3D.new()
	var back_shape := BoxShape3D.new()
	back_shape.size = Vector3(0.305, 0.29, 0.26)
	back.shape = back_shape
	back.position = Vector3(0.0525, 1.125, 0.0)
	solid.add_child(back)
	root.add_child(solid)
	_far_fade(root, SHOW_DISTANCE)
	_door_angle = 0.0
	_flag_angle = FLAG_UP if _has_mail else 0.0
	_flag_heading = _flag_angle
	# Transform before add_child: a body keeps the scale it entered with (Jolt).
	root.transform = at
	add_child(root)
	_apply_pose()
	# Snow and rain wetness on the box in their seasons (the door and flag are left as they are).
	SNOW.adopt(root)
	return root

static func _far_fade(node: Node, distance: float) -> void:
	if node is GeometryInstance3D:
		var mesh := node as GeometryInstance3D
		mesh.visibility_range_end = distance
		mesh.visibility_range_end_margin = 4.0
		mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for child: Node in node.get_children():
		_far_fade(child, distance)

# --- Door and flag --------------------------------------------------------------------------------

## Once a second (refresh): per-frame animation on while he is near, Derpy is coming or a swing is
## unfinished.
func _wake() -> void:
	if not placed() or is_processing(): return
	if is_instance_valid(_visitor) or not _settled() or _player_gap() < WAKE_DISTANCE: set_process(true)
	_update_input()

func _process(delta: float) -> void:
	if not placed():
		set_process(false)
		return
	var gap := _player_gap()
	var open := gap < OPEN_NEAR or _derpy_at_door()
	var was := _door_angle
	_door_angle = move_toward(_door_angle, DOOR_OPEN if open else 0.0, SWING_SPEED * delta)
	if was == 0.0 and _door_angle > 0.0: play_cue("prop_mailbox_open")
	elif was > 0.0 and _door_angle == 0.0: play_cue("prop_mailbox_close")
	var flag_target := FLAG_UP if _has_mail else 0.0
	if flag_target != _flag_heading:
		_flag_heading = flag_target
		if _flag_angle != flag_target: play_cue("prop_mailbox_flag")
	_flag_angle = move_toward(_flag_angle, flag_target, SWING_SPEED * 0.6 * delta)
	_apply_pose()
	if gap >= WAKE_DISTANCE and not is_instance_valid(_visitor) and _settled(): set_process(false)
	_update_input()

## Level metres from him to the door hinge; INF when he cannot be found.
func _player_gap() -> float:
	var player: Vector3 = courier.player_point() if courier != null else Vector3.INF
	if not player.is_finite() or not placed(): return INF
	var front := _box.global_transform * DOOR_HINGE
	return Vector2(player.x - front.x, player.z - front.z).length()

func _derpy_at_door() -> bool:
	if not is_instance_valid(_visitor) or _visitor.phase not in ["approach", "hold", "fumble_fall", "fumble_dip"]: return false
	var body := _visitor.body
	return is_instance_valid(body) and body.is_inside_tree() and body.global_position.distance_to(slot_point()) < DERPY_NEAR

func _settled() -> bool:
	return is_zero_approx(_door_angle) and is_equal_approx(_flag_angle, FLAG_UP if _has_mail else 0.0)

func _apply_pose() -> void:
	if is_instance_valid(_door): _door.basis = Basis(Vector3.BACK, _door_angle)
	if is_instance_valid(_flag): _flag.basis = Basis(Vector3.BACK, _flag_angle) * FLAG_REST

# --- Taking the letter ----------------------------------------------------------------------------

func letter_point() -> Vector3:
	return prop.global_position if is_instance_valid(prop) and prop.is_inside_tree() else Vector3.INF

func _available() -> bool:
	if not is_instance_valid(prop) or not is_instance_valid(inventory): return false
	var camera: Variant = inventory.get("camera")
	var body: Variant = inventory.get("player_body")
	if not camera is Camera3D or not is_instance_valid(camera) or not body is Node or not is_instance_valid(body): return false
	if bool((body as Node).get("controls_locked")): return false
	return not (inventory.has_method("_quick_blocked") and bool(inventory.call("_quick_blocked")))

func desktop_offer() -> Dictionary:
	if not _available() or bool(inventory.call("hand_busy", "desktop")): return {}
	var camera: Camera3D = inventory.get("camera")
	var point := letter_point()
	var eye := camera.global_position
	var ahead := -camera.global_basis.z
	var along := (point - eye).dot(ahead)
	if along <= 0.0 or along > DESKTOP_REACH: return {}
	if (point - eye - ahead * along).length() > AIM_SLACK: return {}
	var excluded: Array[RID] = []
	var body: Variant = inventory.get("player_body")
	if body is CollisionObject3D: excluded.append((body as CollisionObject3D).get_rid())
	var hit: Dictionary = prop.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(eye, point, 1, excluded))
	if not hit.is_empty() and (hit.position as Vector3).distance_to(point) > 0.15: return {}
	return {"target": prop, "point": point, "text": "Click / E · Take letter", "visible_pick": true}

func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not _available() or not sample.get("active", false): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var from: Vector3 = sample.get("grip_position", pose.origin)
	var point := letter_point()
	if not from.is_finite() or not point.is_finite(): return {}
	var distance := from.distance_to(point)
	if distance > VR_REACH: return {}
	return {"target": prop, "point": point, "distance": distance, "text": side.capitalize() + " grip · Take letter"}

func grab_take(side: String, _offer: Dictionary, _sample: Dictionary) -> bool:
	return take(side)

## Takes the first letter shown: his incoming mail, else his own posted letter back as the draft.
func take(side: String) -> bool:
	if not _available(): return false
	var ids: Array = courier.mailbox_ids()
	var outgoing: Array = courier.outbox_ids()
	if ids.is_empty() and outgoing.is_empty(): return false
	var at := letter_point()
	var taken: bool = courier.take_letter(str(ids[0]), side) if not ids.is_empty() else courier.take_back(str(outgoing[0]), side)
	if taken:
		play_cue("prop_mailbox_letter", at)
		if inventory.has_method("_haptic") and side != "desktop": inventory.call("_haptic", side)
	return taken

func interaction_hint() -> Dictionary:
	if not is_instance_valid(inventory) or not bool(inventory.get("_desktop")): return {}
	return desktop_offer()

func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(inventory) or not bool(inventory.get("_desktop")): return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT.reserves_mouse(event, inventory.get("player_body")): return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	var key_e: bool = event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E
	var pressed: bool = key_e or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)
	if not pressed: return
	# A sendable letter in hand, aimed at the box: E posts it (a click goes to letter_tool.gd first).
	var held: Variant = inventory.get("held")
	var item: Variant = (held as Dictionary).get("desktop") if held is Dictionary else null
	if key_e and item is Node3D and is_instance_valid(item) and LETTER_TOOL.handles(item as Node3D):
		var tool := LETTER_TOOL.on(item as Node3D)
		if tool.can_post(inventory, "desktop"):
			tool.post_in_mailbox(inventory)
			get_viewport().set_input_as_handled()
		return
	if not is_instance_valid(prop) or desktop_offer().is_empty(): return
	if take("desktop"): get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	for group: String in ["grab_providers", "interaction_hint_sources"]:
		if is_in_group(group): remove_from_group(group)
