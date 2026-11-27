extends StaticBody3D
## A fixed rubbish bin (player board card 69): one beside Anon's front door and one in the Ponyville
## market, placed by world/props/rubbish_bins.gd. It is the fishing bucket the portable rubbish bucket
## already uses (world/props/household/fishing-bucket.scn), standing still; no new model.
##
## VR: let go of a held thing over its mouth (or throw one in) and it is thrown away for good.
## Desktop: with a thing in hand and the crosshair on the bin, the hint reads "Click · Throw away"
## and the click throws it in, like the Hayburger kitchen's scraps bin. Both go through
## world/inventory/rubbish_rules.gd: kept things (books, letters, the notebook, the photo journal,
## handed-out tools, wardrobe clothes) are refused with a hotbar line and stay in the hand, a stack
## goes in whole, nothing is refunded, and the recorded deposit sound plays.
##
## Cost: no per-frame work while idle. The desktop hint and click are answered through the station
## adapter (world/mechanics/stations/station_input.gd, group mechanics_station_nodes), which only
## asks nodes within reach; the mouth's physics callback runs only while a thing is inside it.
const RULES := preload("res://world/inventory/rubbish_rules.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const MODEL := "res://world/props/household/fishing-bucket.scn"
const ITEM_LAYER := 1 << 17
## The model's measured size (tools/saves/measure_bin_models.gd): 0.36 x 0.48 x 0.35 m.
const SIZE := Vector3(0.36, 0.48, 0.35)
## Where the desktop crosshair aims and the prompt sits: the middle of the bucket.
const MIDDLE := Vector3(0.0, 0.26, 0.0)
## The view line may pass this far beside MIDDLE (anywhere on the bin) within REACH metres.
const AIM_RADIUS := 0.3
const REACH := 2.6
## VR: a held thing this close (level metres) to the mouth, up to MOUTH_HEIGHT above the rim, shows
## the hint.
const VR_NEAR := 0.35
const MOUTH_HEIGHT := 0.5
## Beyond this the bin fades out, like Anon's mailbox.
const SHOW_DISTANCE := 150.0

var _inside: Array[RigidBody3D] = []

func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	var packed := load(MODEL) as PackedScene
	if packed != null:
		var model := packed.instantiate()
		model.name = "Model"
		add_child(model)
		_far_fade(model)
	var solid := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	solid.shape = box
	solid.position = Vector3(0.0, SIZE.y * 0.5, 0.0)
	add_child(solid)
	# The mouth: from just under the rim to a hand's width above it, a little wider than the bucket so
	# a VR hand need not be exact (the portable bucket's mouth, rubbish_bucket_item.gd, is 0.9 x size).
	var mouth := Area3D.new()
	mouth.name = "RubbishMouth"
	mouth.collision_layer = 0
	mouth.collision_mask = ITEM_LAYER
	mouth.monitorable = false
	var shape := CollisionShape3D.new()
	var opening := BoxShape3D.new()
	opening.size = Vector3(SIZE.x * 1.2, 0.34, SIZE.z * 1.2)
	shape.shape = opening
	shape.position = Vector3(0.0, SIZE.y + 0.12, 0.0)
	mouth.add_child(shape)
	add_child(mouth)
	mouth.body_entered.connect(_entered)
	mouth.body_exited.connect(_exited)
	add_to_group("mechanics_station_nodes")
	add_to_group("rubbish_bins")
	set_physics_process(false)

func _far_fade(node: Node) -> void:
	if node is GeometryInstance3D:
		var mesh := node as GeometryInstance3D
		mesh.visibility_range_end = SHOW_DISTANCE
		mesh.visibility_range_end_margin = 4.0
		mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	for child: Node in node.get_children(): _far_fade(child)

# --- VR (and anything dropped or thrown in) ---------------------------------------------------------

func _entered(body: Node3D) -> void:
	if body is RigidBody3D and body.has_meta("token") and not _inside.has(body):
		_inside.append(body)
		# Held over the mouth: the stack it came from goes in with it.
		RULES.remember(body)
		set_physics_process(true)

func _exited(body: Node3D) -> void:
	_inside.erase(body)
	RULES.forget(body)
	if _inside.is_empty(): set_physics_process(false)

## Runs only while something is in the mouth: a dropped thing is taken on the next tick, one held
## over it waits until it is let go.
func _physics_process(_delta: float) -> void:
	for body: RigidBody3D in _inside.duplicate():
		_try(body)
	if _inside.is_empty(): set_physics_process(false)

func _try(body: RigidBody3D) -> void:
	if not is_instance_valid(body):
		_inside.erase(body); return
	var bag := RULES.bag_of(body)
	if bag == null:
		_inside.erase(body); return
	if body in (bag.get("held") as Dictionary).values(): return
	var loose: Variant = bag.get("loose")
	var token := str(body.get_meta("token", ""))
	# Not a loose owned thing, or resting where it was restored or placed: not thrown in.
	if not loose is Dictionary or (loose as Dictionary).get(token) != body or body.freeze:
		_inside.erase(body); return
	_inside.erase(body)
	RULES.throw_away(bag, body, global_transform * MIDDLE, self)

# --- Hints and the desktop click (world/mechanics/stations/station_input.gd) -----------------------

## Desktop: the crosshair on the bin with a thing in hand. VR: a held thing over the mouth.
func station_hint(ui: Node, side: String) -> Dictionary:
	var body := HELD.body(ui, side)
	if body == null: return {}
	if side == "desktop":
		if not aimed(ui) or _own_click(ui): return {}
	elif not _over_mouth(body.global_position):
		return {}
	var refused := RULES.refusal(str(body.get_meta("item_id", "")))
	var text := refused
	if refused.is_empty():
		# VR: the hand is over the mouth now, so the stack it is drawn from goes in when it lets go.
		if side != "desktop": RULES.remember(body)
		var count := RULES.stack_count(ui, body)
		var words := "Throw away" if count <= 1 else "Throw away all %d" % count
		text = ("Click · " if side == "desktop" else "Release grip · ") + words
	return {"target": self, "text": text, "point": global_transform * MIDDLE + Vector3.UP * (0.35 if side != "desktop" else 0.0), "visible_pick": true}

## Desktop click with a thing in hand, aimed at the bin: thrown away, or refused and kept in hand.
## The click is the bin's either way, so it never eats or uses the thing by mistake.
func station_use(ui: Node, side: String, down: bool) -> bool:
	if side != "desktop" or not down: return false
	var body := HELD.body(ui, side)
	if body == null or not aimed(ui) or _own_click(ui): return false
	RULES.throw_away(ui, body, global_transform * MIDDLE, self)
	return true

## Desktop: the thing in hand has a click of its own that the briefcase hints wherever he looks (the
## camera, spray bottle, folded easel, quill, writing paper, journal: briefcase_inventory.gd
## interaction_hint). That hint wins over the bin's in interaction_hints.gd, so the bin leaves the
## click to it too; such a thing goes in with Q (throw) or Shift+Q (set down) over the bin.
func _own_click(ui: Node) -> bool:
	if not ui.has_method("interaction_hint"): return false
	var own: Variant = ui.call("interaction_hint")
	return own is Dictionary and not (own as Dictionary).is_empty()

## Desktop: the view line passes over the bin within reach, with nothing solid in between.
func aimed(ui: Node) -> bool:
	var middle: Vector3 = global_transform * MIDDLE
	if not HELD.looking_at(ui, middle, AIM_RADIUS, REACH): return false
	var camera: Node3D = ui.get("camera") as Node3D
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, middle, 1)
	var player: Variant = ui.get("player_body")
	if player is CollisionObject3D and is_instance_valid(player): query.exclude = [(player as CollisionObject3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or hit.get("collider") == self

func _over_mouth(at: Vector3) -> bool:
	var local: Vector3 = global_transform.affine_inverse() * at
	return Vector2(local.x, local.z).length() <= VR_NEAR and local.y >= SIZE.y - 0.1 and local.y <= SIZE.y + MOUTH_HEIGHT
