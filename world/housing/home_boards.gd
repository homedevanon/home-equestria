extends Node
## Which houses stand empty, on the house itself (dev 2026-11-24: no boards out in front of houses; an
## empty house simply wears an "EMPTY HOUSE" sign on its front door, readable at first glance. A house
## somepony lives in wears nothing). Before that, 2026-11-19 to 2026-11-24, a notice board stood beside
## every door path with the household's names (docs/THREAD_FIX_RESIDENCY_2026_11_19.md).
## While Anon holds a house permit from the Mayor or Princess Celestia (arrival_story.gd request_home),
## aiming at an empty house's sign and pressing click or E (desktop), or gripping it (VR), makes that
## house his home (arrival_story.gd claim_home).
##
## The sign is the kit model door_sign.glb (Blender, 2026-11-24, 2498 triangles; source in the art folder
## door-sign-2026-11-24/door_sign_v2.blend): a chunky wooden board hung on twine from a pink heart
## nail, EMPTY / HOUSE in raised cream letters in the town's own font (PonyvilleMedium), the words
## part of the model. A child of the door leaf so it swings with the door, sized to the door's width.
## Cost: no per-frame callback. A 1 s Timer keeps signs on the nearest MAX_BOARDS empty houses within
## RANGE of the player (no shadow, hidden past RANGE) and frees the rest.
## Signs have no collision. Only while a claimable sign is within NEAR does this join the
## interaction-hint and grab-provider polls and read input.
## Rollback: ENABLED = false, or the launch argument --home-boards=off.
const ENABLED := true
const FLIGHT := preload("res://player/wing_flight.gd")
const APPEARANCE := preload("res://world/ui/pony_map_data.gd")
const SIGN_SCENE := "res://world/props/ponyville_kit/door_sign.glb"
const SIGN_TEXT := "EMPTY HOUSE"
const RANGE := 40.0
const MAX_BOARDS := 12
## The sign on the door: this share of the door's width (kept between MIN_WIDTH and MAX_WIDTH metres),
## its middle at HEIGHT_SHARE of the door's height, LIFT metres off the door's outer face.
const SIGN_WIDTH := 0.66
const WIDTH_SHARE := 0.85
const MIN_WIDTH := 0.6
const MAX_WIDTH := 1.0
const HEIGHT_SHARE := 0.58
const LIFT := 0.004
const NEAR := 4.0
const DESKTOP_REACH := 2.6
const VR_REACH := 0.3
## The board of door_sign.glb in its own frame (its middle is the model's origin; 0.62 by 0.38 m, the
## lettered face at z 0.03): where a hand or the view ray claims.
const FACE_CENTER := Vector3(0.0, 0.0, 0.03)
const FACE_HALF := Vector2(0.31, 0.19)

static func wanted() -> bool:
	return ENABLED and not ("--home-boards=off" in OS.get_cmdline_user_args())

var population: Node
## The briefcase node: grab_router.gd matches its providers by this field.
var inventory: Node
## place id -> {"house": Node3D, "root": Node3D, "board": Node3D, "text": String, "scale": float}
var boards: Dictionary = {}
var _scene: PackedScene
var _timer: Timer
var _near := false

func setup(owner_population: Node) -> void:
	population = owner_population
	set_process_input(false)
	_timer = Timer.new(); _timer.name = "Tick"; _timer.wait_time = 1.0
	add_child(_timer)
	_timer.timeout.connect(refresh_now)
	_timer.start()

func _exit_tree() -> void:
	_set_near(false)

## Signs for the nearest empty houses, and whether one can be claimed close by.
func refresh_now() -> void:
	if not is_inside_tree() or not is_instance_valid(population): return
	var anchor: Variant = population.get("anchor")
	if not anchor is Node3D or not is_instance_valid(anchor) or not (anchor as Node3D).is_inside_tree():
		_clear(); return
	var player: Vector3 = (anchor as Node3D).global_position
	var near_rows: Array = []
	for node: Node in get_tree().get_nodes_in_group("house_interiors"):
		var house := node as Node3D
		if not _shows(house) or text_for(house).is_empty(): continue
		var door: Vector3 = house.call("outside")
		if not door.is_finite(): continue
		var distance := Vector2(door.x - player.x, door.z - player.z).length()
		if distance <= RANGE: near_rows.append([distance, house])
	near_rows.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var keep := {}
	for row: Array in near_rows.slice(0, MAX_BOARDS): keep[str((row[1] as Node3D).call("place_id"))] = row[1]
	for place: String in boards.keys():
		var row: Dictionary = boards[place]
		if not keep.has(place) or not is_instance_valid(row.get("house")) or row.house != keep[place] or not is_instance_valid(row.get("root")): _remove(place)
	var claim_near := false
	for place: String in keep:
		if not boards.has(place): _build(keep[place])
		if not boards.has(place): continue
		var claimable := _write(place)
		var root: Node3D = boards[place].root
		if claimable and root.global_position.distance_to(player) <= NEAR + 1.8: claim_near = true
	_set_near(claim_near)

## A Ponyville home with a door step on the ground (not a shop, the hall or a cloud house).
func _shows(house: Node3D) -> bool:
	if house == null or not is_instance_valid(house) or not house.is_inside_tree() or house.is_queued_for_deletion(): return false
	if not house.has_method("place_id") or not house.has_method("outside"): return false
	if not str(house.call("place_id")).begins_with("house:"): return false
	return not (house.has_method("sky_home") and bool(house.call("sky_home")))

## Where the sign hangs: on the outer face of the front door leaf, in the leaf's own frame. {} while
## the house has no door leaf with its panel (an open doorway).
func _mount(house: Node3D) -> Dictionary:
	if not house.has_method("door"): return {}
	var found: Variant = house.call("door")
	if not found is Node3D or not is_instance_valid(found): return {}
	var leaf := found as Node3D
	var art := leaf.get_node_or_null("OriginalDoorArtwork") as MeshInstance3D
	if art == null or art.mesh == null: return {}
	# The panel in the leaf's frame: wide along X, tall along Y, its outer face at the far Z (the
	# inside artwork of house_floor_fit.gd _dress_door hangs on the near Z).
	var box: AABB = art.transform * art.mesh.get_aabb()
	if box.size.z > minf(box.size.x, box.size.y): return {}
	# Door leaves are scaled nodes in some houses: the sign is sized in metres, then brought into the
	# leaf's own units.
	var leaf_scale := leaf.global_basis.get_scale()
	if leaf_scale.x < 0.001 or leaf_scale.y < 0.001 or leaf_scale.z < 0.001: return {}
	var size := clampf(box.size.x * leaf_scale.x * WIDTH_SHARE, MIN_WIDTH, MAX_WIDTH) / SIGN_WIDTH
	var at := Vector3(box.position.x + box.size.x * 0.5, box.position.y + box.size.y * HEIGHT_SHARE, box.end.z + LIFT / leaf_scale.z)
	return {"parent": leaf, "local": Transform3D(Basis.from_scale(Vector3(size / leaf_scale.x, size / leaf_scale.y, size / leaf_scale.z)), at), "scale": size}

func _build(house: Node3D) -> void:
	var mount := _mount(house)
	if mount.is_empty(): return
	if _scene == null and ResourceLoader.exists(SIGN_SCENE): _scene = load(SIGN_SCENE) as PackedScene
	if _scene == null: return
	var board := _scene.instantiate() as Node3D
	if board == null: return
	for solid: Node in board.find_children("*", "CollisionObject3D", true, false): solid.free()
	for mesh: Node in board.find_children("*", "GeometryInstance3D", true, false):
		var geometry := mesh as GeometryInstance3D
		geometry.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		geometry.visibility_range_end = RANGE + 5.0
		geometry.visibility_range_end_margin = 4.0
		geometry.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	board.name = "Board"
	var root := Node3D.new()
	root.name = "DoorSign"
	root.add_child(board)
	(mount.parent as Node3D).add_child(root)
	root.transform = mount.local
	var place := str(house.call("place_id"))
	boards[place] = {"house": house, "root": root, "board": board, "text": SIGN_TEXT, "scale": float(mount.scale)}

func _remove(place: String) -> void:
	var row: Dictionary = boards.get(place, {})
	boards.erase(place)
	if is_instance_valid(row.get("root")): (row.root as Node).queue_free()

func _clear() -> void:
	for place: String in boards.keys(): _remove(place)
	_set_near(false)

## The words on this house's door: SIGN_TEXT on an empty plot house, "" (no sign) on every other.
func text_for(house: Node3D) -> String:
	if not str(house.get_path()).contains("PonyvilleTown/plot"): return ""
	if str(house.get_meta("reserved_for", "")) == "player" or bool(house.get_meta("shared_player_home", false)): return ""
	for id: String in population.residents_of(str(house.call("place_id"))):
		if id != "player": return ""
	return SIGN_TEXT

## True when Anon may claim this sign's house now.
func _write(place: String) -> bool:
	return _claimable(boards[place].house)

func _story() -> Node:
	return get_tree().get_first_node_in_group("arrival_story") if is_inside_tree() else null

func _claimable(house: Node3D) -> bool:
	var story := _story()
	return story != null and story.has_method("can_claim") and bool(story.call("can_claim", house))

## Spends his permit on this sign's house. True when it is his now.
func claim(place: String) -> bool:
	var row: Dictionary = boards.get(place, {})
	var story := _story()
	if row.is_empty() or story == null or not story.has_method("claim_home") or not is_instance_valid(row.get("house")): return false
	var why := str(story.call("claim_home", row.house))
	if not why.is_empty():
		print("[home boards] claim refused at ", place, ": ", why)
		return false
	print("[home boards] Anon claimed ", place)
	refresh_now()
	return true

func _set_near(value: bool) -> void:
	if value and not is_instance_valid(inventory) and is_instance_valid(population):
		var host: Variant = population.get("host")
		var found: Variant = (host as Node).get("inventory") if host is Node and is_instance_valid(host) else null
		if found is Node and is_instance_valid(found): inventory = found
	value = value and is_instance_valid(inventory)
	if value == _near: return
	_near = value
	if value:
		add_to_group("grab_providers"); add_to_group("interaction_hint_sources")
	else:
		if is_in_group("grab_providers"): remove_from_group("grab_providers")
		if is_in_group("interaction_hint_sources"): remove_from_group("interaction_hint_sources")
	set_process_input(value)

## The painted face of one sign in the world, +Z out of it, in metres (the sign's size taken out).
func _face(row: Dictionary) -> Transform3D:
	var root := (row.root as Node3D).global_transform
	return Transform3D(root.basis.orthonormalized(), root * FACE_CENTER)

## Half the painted face of one sign in metres.
func _half(row: Dictionary) -> Vector2:
	return FACE_HALF * float(row.get("scale", 1.0))

func _available() -> bool:
	if not is_instance_valid(inventory): return false
	var body: Variant = inventory.get("player_body")
	return not (body is Node and is_instance_valid(body) and bool((body as Node).get("controls_locked")))

## Desktop: the claimable sign the view ray meets within reach, front side, nothing in between.
func desktop_offer() -> Dictionary:
	if not _near or not _available() or not bool(inventory.get("_desktop")) or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return {}
	if inventory.has_method("hand_busy") and bool(inventory.call("hand_busy", "desktop")): return {}
	var camera := inventory.get("camera") as Camera3D
	if camera == null: return {}
	var from := camera.global_position
	var direction := -camera.global_basis.z
	var best := {}
	var gap := DESKTOP_REACH
	for place: String in boards:
		var row: Dictionary = boards[place]
		if not is_instance_valid(row.get("house")) or not is_instance_valid(row.get("root")) or not _claimable(row.house): continue
		var face := _face(row)
		var normal := face.basis.z.normalized()
		var facing := direction.dot(normal)
		if facing >= -0.05: continue
		var t := (face.origin - from).dot(normal) / facing
		if t <= 0.0 or t > gap: continue
		var hit := from + direction * t
		var local := face.affine_inverse() * hit
		var half := _half(row)
		if absf(local.x) > half.x + 0.05 or absf(local.y) > half.y + 0.1: continue
		var query := PhysicsRayQueryParameters3D.create(from, hit - direction * 0.03, 1)
		var body: Variant = inventory.get("player_body")
		if body is CollisionObject3D: query.exclude = [(body as CollisionObject3D).get_rid()]
		if not camera.get_world_3d().direct_space_state.intersect_ray(query).is_empty(): continue
		gap = t
		best = {"target": row.board, "point": hit, "text": "Click / E · Make this house your home", "place": place}
	return best

func interaction_hint() -> Dictionary:
	return desktop_offer()

func _input(event: InputEvent) -> void:
	if not _near or not _available() or not bool(inventory.get("_desktop")): return
	var pressed: bool = event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
	pressed = pressed or (event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo and (event as InputEventKey).physical_keycode == KEY_E)
	if not pressed or FLIGHT.reserves_mouse(event, inventory.get("player_body")): return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	var offer := desktop_offer()
	if not offer.is_empty() and claim(str(offer.place)): get_viewport().set_input_as_handled()

## VR: a free palm at the face of a claimable sign.
func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not _near or not _available() or bool(inventory.get("_desktop")) or not sample.get("active", false): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var palm: Vector3 = sample.get("grip_position", pose.origin)
	if not palm.is_finite(): return {}
	var best := {}
	var gap := INF
	for place: String in boards:
		var row: Dictionary = boards[place]
		if not is_instance_valid(row.get("house")) or not is_instance_valid(row.get("root")) or not _claimable(row.house): continue
		var face := _face(row)
		var local := face.affine_inverse() * palm
		var half := _half(row)
		if local.z < -0.05 or local.z > VR_REACH or absf(local.x) > half.x + 0.05 or absf(local.y) > half.y + 0.05: continue
		var distance := maxf(local.z, 0.0)
		if distance < gap:
			gap = distance
			best = {"target": row.board, "point": face.origin, "distance": distance, "place": place,
				"text": side.capitalize() + " grip · Make this house your home"}
	return best

func grab_take(side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	var taken := claim(str(offer.get("place", "")))
	if taken and is_instance_valid(inventory) and inventory.has_method("_haptic"): inventory.call("_haptic", side)
	return taken
