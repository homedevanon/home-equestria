extends AnimatableBody3D
## A snowball set down on snow and its stack (W2-SEAS-F, design 6.2): one ball rolls and grows
## with the distance rolled over snow (radius_for(), ~sqrt(metres), capped at 0.6 m) and stamps a
## rolled trail; pushed into a bigger ball it climbs on top. Three balls are a snowman, which
## takes a carrot nose, coal eyes and buttons, two stick arms and a scarf, placed by hand.
## The whole stack is one merged mesh (one draw) with a far LOD of the balls alone, rebuilt only
## when a ball or a part is added. No per-frame script work except while being rolled.
## A station node (world/mechanics/stations/station_input.gd): desktop hold-click and walk rolls a
## lone ball; a click with a part in hand dresses a snowman. VR pushes with the hands (snow_play.gd
## drives push_by_hands) and dresses by holding a part to the snowman.
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
const HELD := preload("res://world/mechanics/stations/held_items.gd")
const STATION_GROUP := "mechanics_station_nodes"
const GROUP := "snowmen"
const HAND_RADIUS := FX.MODEL_RADIUS
const ROLL_GAIN := 0.12
const MAX_RADIUS := 0.6
const MAX_BALLS := 3
## Ball centres sit this far into the ball below (packed snow squashes).
const SINK := 0.88
const ROLL_SPEED := 2.4
const TRAIL_STEP := 0.4
const LOOK_REACH := 3.2
const LOD_NEAR := 30.0
const MAX_COAL := 5
const MAX_ARMS := 2
## Snow cover (snow_cover_query) a ball must roll over to grow; the same as the scoop threshold.
const SNOW_FOR_GROWTH := 0.4

var play: Node
var id := ""
var radii: Array[float] = [HAND_RADIUS]
var rolled := 0.0
var parts := {"nose": "", "coal": 0, "arms": 0, "scarf": ""}
var made_at := 0.0
var melt := 1.0
var by := "player"
var _spin := Basis.IDENTITY
var _rolling_side := ""
var _trail_left := 0.0
var _near: MeshInstance3D
var _far: MeshInstance3D
var _shapes: Array[CollisionShape3D] = []

## Radius of a ball rolled `metres` over snow from a hand snowball.
static func radius_for(metres: float) -> float:
	return clampf(HAND_RADIUS + ROLL_GAIN * sqrt(maxf(metres, 0.0)), HAND_RADIUS, MAX_RADIUS)

## Metres of rolling a ball of `radius` stands for (inverse of radius_for).
static func rolled_for(radius: float) -> float:
	return pow(maxf(radius - HAND_RADIUS, 0.0) / ROLL_GAIN, 2.0)

func _init() -> void:
	name = "Snowman"
	sync_to_physics = false
	collision_layer = 1
	collision_mask = 0
	add_to_group(GROUP)
	_near = MeshInstance3D.new(); _near.name = "Near"
	_near.visibility_range_end = LOD_NEAR; _near.visibility_range_end_margin = 2.0
	add_child(_near)
	_far = MeshInstance3D.new(); _far.name = "Far"
	_far.visibility_range_begin = LOD_NEAR; _far.visibility_range_begin_margin = 2.0; _far.visibility_range_end = 140.0
	_far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_far)
	made_at = Time.get_unix_time_from_system()
	set_physics_process(false)

func _ready() -> void:
	rebuild()

func complete() -> bool: return radii.size() >= MAX_BALLS
func top_radius() -> float: return radii[radii.size() - 1]
func base_radius() -> float: return radii[0]

## Height of ball `i`'s centre above the ground point (this node's origin).
func ball_height(i: int) -> float:
	var y := radii[0] * SINK
	for k in range(1, mini(i + 1, radii.size())):
		y += (radii[k - 1] + radii[k]) * SINK
	return y

func ball_centre(i: int) -> Vector3:
	return global_transform * Vector3(0, ball_height(i), 0)

func height() -> float:
	return ball_height(radii.size() - 1) + top_radius()

# ------------------------------------------------------------------ look

## Rebuild the look and the collision spheres (on change only). A lone ball is the plain snowball
## mesh scaled and turned (cheap while rolling); a stack is one merged mesh.
func rebuild() -> void:
	var s := maxf(melt, 0.05)
	_near.material_override = FX.material(); _far.material_override = FX.material()
	if radii.size() == 1:
		var xf := Transform3D(_spin.scaled(Vector3.ONE * radii[0] / FX.MODEL_RADIUS * s), Vector3(0, ball_height(0) * s, 0))
		_near.mesh = FX.mesh("Snowball_LOD0"); _far.mesh = FX.mesh("Snowball_LOD1")
		_near.transform = xf; _far.transform = xf
		_sync_shapes(s)
		return
	_near.transform = Transform3D.IDENTITY; _far.transform = Transform3D.IDENTITY
	var near_pieces: Array = []
	var far_pieces: Array = []
	for i in radii.size():
		var scale_ := radii[i] / FX.MODEL_RADIUS * s
		var turn := Basis(Vector3.UP, float(i) * 2.1 + float(absi(hash(id)) % 7))
		var xf := Transform3D(turn.scaled(Vector3.ONE * scale_), Vector3(0, ball_height(i) * s, 0))
		near_pieces.append(["Snowball_LOD0", xf])
		far_pieces.append(["Snowball_LOD1", xf])
	if complete(): near_pieces.append_array(_part_pieces(s))
	_near.mesh = FX.merge(near_pieces)
	_far.mesh = FX.merge(far_pieces)
	_sync_shapes(s)

func _part_pieces(s: float) -> Array:
	var out: Array = []
	var head := Vector3(0, ball_height(2) * s, 0)
	var rh := radii[2] * s
	var body := Vector3(0, ball_height(1) * s, 0)
	var rb := radii[1] * s
	var coal := int(parts.get("coal", 0))
	# Eyes first, then buttons down the middle ball.
	for i in mini(coal, 2):
		var dir := Vector3(-0.36 if i == 0 else 0.36, 0.3, 0.88).normalized()
		out.append(["Coal", Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * clampf(rh / 0.2, 0.6, 1.6)), head + dir * rh * 0.97)])
	for i in clampi(coal - 2, 0, 3):
		var dir := Vector3(0, 0.45 - 0.42 * i, 0.9).normalized()
		out.append(["Coal", Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * clampf(rb / 0.3, 0.6, 1.6)), body + dir * rb * 0.98)])
	if str(parts.get("nose", "")) != "":
		# The food carrot stands tip down with its origin at the tip (0.185 m long): turn the tip
		# forward (+Z) and push it out so about 0.11 m sticks out of the face.
		var nose_scale := clampf(rh / 0.22, 0.7, 1.4)
		var nose := Basis(Vector3.RIGHT, -PI / 2.0).scaled(Vector3.ONE * nose_scale)
		out.append(["Carrot", Transform3D(nose, head + Vector3(0, 0, rh * 0.96 + 0.11 * nose_scale))])
	for i in mini(int(parts.get("arms", 0)), 2):
		var side := 1.0 if i == 0 else -1.0
		var arm := Basis(Vector3.UP, 0.0 if side > 0 else PI) * Basis(Vector3.BACK, 0.35)
		out.append(["StickArm", Transform3D(arm.scaled(Vector3.ONE * clampf(rb / 0.3, 0.8, 1.5)), body + Vector3(side * rb * 0.82, rb * 0.25, 0))])
	var scarf := str(parts.get("scarf", ""))
	if scarf != "":
		var neck := ball_height(1) * s + rb * 0.75
		var ring := clampf(minf(rb, rh) * 0.82, 0.08, 0.5)
		out.append(["Scarf", Transform3D(Basis.IDENTITY.scaled(Vector3(ring, ring * 1.1, ring)), Vector3(0, neck, 0)), scarf_colour(scarf)])
	return out

## The scarf's colour from its shop id ("wear:scarf:<colour index>").
static func scarf_colour(item_id: String) -> Color:
	var parts_ := item_id.split(":")
	if parts_.size() == 3 and parts_[2].is_valid_int() and ResourceLoader.exists("res://world/characters/accessories/pony_wardrobe.gd"):
		var wardrobe: Variant = load("res://world/characters/accessories/pony_wardrobe.gd")
		var colours: Variant = (wardrobe as Script).get_script_constant_map().get("COLOURS") if wardrobe is Script else null
		if colours is Array and not (colours as Array).is_empty():
			var c: Variant = (colours as Array)[int(parts_[2]) % (colours as Array).size()]
			if c is Color: return c
	return Color(0.75, 0.12, 0.12)

func _sync_shapes(s: float) -> void:
	while _shapes.size() < radii.size():
		var shape := CollisionShape3D.new(); shape.shape = SphereShape3D.new()
		add_child(shape); _shapes.append(shape)
	while _shapes.size() > radii.size():
		var gone: CollisionShape3D = _shapes.pop_back(); gone.queue_free()
	for i in radii.size():
		(_shapes[i].shape as SphereShape3D).radius = maxf(radii[i] * s, 0.02)
		_shapes[i].position = Vector3(0, ball_height(i) * s, 0)

# ------------------------------------------------------------------ rolling and stacking

## Ground height under a world point: the terrain, else a ray, else the current height.
func _ground(at: Vector3) -> float:
	if is_instance_valid(WorldTerrain.instance) and WorldTerrain.instance.has_ground(at): return WorldTerrain.instance.height_at(at)
	if is_inside_tree():
		var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.5, at + Vector3.DOWN * 3.0, 1, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty(): return (hit.position as Vector3).y
	return global_position.y

## Rolls a lone ball by a flat step. Over snow it grows; into a bigger ball's stack it climbs on
## (this node is then gone; returns "stacked"). Returns "moved", "blocked" or "stacked".
func roll_by(step: Vector3) -> String:
	if radii.size() != 1 or not is_inside_tree(): return "blocked"
	step.y = 0.0
	if not step.is_finite() or step.length() < 0.0005: return "moved"
	var to := global_position + step
	if is_instance_valid(play):
		for other: Node in play.call("stacks"):
			if other == self or not is_instance_valid(other): continue
			var o := other as Node3D
			var gap := Vector2(to.x - o.global_position.x, to.z - o.global_position.z).length()
			var other_base: float = other.call("base_radius")
			if gap >= other_base + base_radius() * 0.75: continue
			if other.call("accepts", base_radius()):
				other.call("add_ball", base_radius())
				play.call("_stack_merged", self, other)
				return "stacked"
			return "blocked"
	# Walls, fences and trunks stop it (one ray from the centre, only while rolling).
	var centre := ball_centre(0)
	var ahead := centre + step + step.normalized() * radii[0]
	var excluded: Array[RID] = [get_rid()]
	if is_instance_valid(play):
		for other: Node in play.call("stacks"):
			if other is CollisionObject3D and is_instance_valid(other): excluded.append((other as CollisionObject3D).get_rid())
	if not get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(centre, ahead, 1, excluded)).is_empty():
		return "blocked"
	var moved := step.length()
	var snow: float = play.call("cover_at", to) if is_instance_valid(play) else 1.0
	if snow > SNOW_FOR_GROWTH:
		rolled += moved
		var grown := radius_for(rolled)
		if grown > radii[0] + 0.004:
			radii[0] = grown
		_trail_left -= moved
		if _trail_left <= 0.0:
			_trail_left = TRAIL_STEP
			if is_instance_valid(play): play.call("stamp_trail", to, radii[0])
	var axis := Vector3.UP.cross(step.normalized())
	if axis.length() > 0.001: _spin = (Basis(axis.normalized(), moved / maxf(radii[0], 0.03)) * _spin).orthonormalized()
	to.y = _ground(to)
	global_position = to
	rebuild()
	return "moved"

## A ball of `radius` can go on top: fewer than three balls and smaller than the current top.
func accepts(radius: float) -> bool:
	return radii.size() < MAX_BALLS and radius < top_radius() - 0.01 and melt >= 1.0

func add_ball(radius: float) -> void:
	radii.append(radius)
	rebuild()
	if complete() and is_instance_valid(play): play.call("_on_snowman_complete", self)

## VR: palms (world points) and their velocities this tick. A ball moves with the hands that
## touch it and push into it; a ball bigger than 0.25 m needs both hands.
func push_by_hands(points: Array, velocities: Array, delta: float) -> String:
	if radii.size() != 1: return "blocked"
	var centre := ball_centre(0)
	var touching := 0
	var push := Vector3.ZERO
	for i in points.size():
		var p: Vector3 = points[i]
		var v: Vector3 = velocities[i]
		if not p.is_finite() or not v.is_finite(): continue
		if p.distance_to(centre) > radii[0] + 0.14: continue
		var into := centre - p; into.y = 0.0
		var flat := Vector3(v.x, 0, v.z)
		if into.length() < 0.001 or flat.dot(into.normalized()) <= 0.05: continue
		touching += 1
		push += flat
	if touching == 0 or (radii[0] > 0.25 and touching < 2): return "blocked"
	var step := (push / float(touching)) * delta
	return roll_by(step.limit_length(ROLL_SPEED * delta))

## Desktop rolling while the click is held (station_use engaged).
func _physics_process(delta: float) -> void:
	if _rolling_side != "desktop" or not is_instance_valid(play):
		set_physics_process(false); return
	var ui: Node = play.call("ui")
	var camera: Variant = ui.get("camera") if is_instance_valid(ui) else null
	if not camera is Node3D or not is_instance_valid(camera) or radii.size() != 1:
		stop_rolling(); return
	var eye: Vector3 = (camera as Node3D).global_position
	var ahead: Vector3 = -(camera as Node3D).global_basis.z; ahead.y = 0.0
	if ahead.length() < 0.01: return
	ahead = ahead.normalized()
	var want := eye + ahead * (radii[0] + 0.55)
	var step := Vector3(want.x - global_position.x, 0, want.z - global_position.z)
	if Vector2(step.x, step.z).length() > 2.5: stop_rolling(); return
	if roll_by(step.limit_length(ROLL_SPEED * delta)) == "stacked": return

func start_rolling(side: String) -> bool:
	if radii.size() != 1 or melt < 1.0: return false
	_rolling_side = side
	set_physics_process(true)
	FX.sound(self, "snow_play_roll", global_position)
	return true

func stop_rolling() -> void:
	if _rolling_side.is_empty(): return
	_rolling_side = ""
	set_physics_process(false)
	if is_instance_valid(play): play.call("mark_dirty")

func rolling() -> bool: return not _rolling_side.is_empty()

# ------------------------------------------------------------------ dressing

## Whether this snowman takes a part ("nose", "coal", "arm", "scarf").
func wants(part: String) -> bool:
	if not complete() or melt < 1.0: return false
	match part:
		"nose": return str(parts.get("nose", "")) == ""
		"coal": return int(parts.get("coal", 0)) < MAX_COAL
		"arm": return int(parts.get("arms", 0)) < MAX_ARMS
		"scarf": return str(parts.get("scarf", "")) == ""
	return false

## Puts a part on (the caller has already used the item up).
func dress(part: String, item_id: String) -> bool:
	if not wants(part): return false
	match part:
		"nose": parts["nose"] = item_id
		"coal": parts["coal"] = int(parts.get("coal", 0)) + 1
		"arm": parts["arms"] = int(parts.get("arms", 0)) + 1
		"scarf": parts["scarf"] = item_id
	rebuild()
	FX.sound(self, "snow_play_scoop", attach_point(part))
	if is_instance_valid(play): play.call("mark_dirty")
	return true

## Where a part goes, in world space (VR hold target and desktop look target).
func attach_point(part: String) -> Vector3:
	if not complete(): return ball_centre(radii.size() - 1)
	var face := global_basis.z.normalized()
	match part:
		"nose", "coal": return ball_centre(2) + face * radii[2] if part == "nose" or int(parts.get("coal", 0)) < 2 else ball_centre(1) + face * radii[1]
		"arm": return ball_centre(1) + global_basis.x.normalized() * radii[1] * (1.0 if int(parts.get("arms", 0)) == 0 else -1.0)
		"scarf": return global_transform * Vector3(0, ball_height(1) + radii[1] * 0.75, radii[1] * 0.8)
	return ball_centre(radii.size() - 1)

# ------------------------------------------------------------------ station node (desktop click, VR hint)

func _part_in(ui: Node, side: String) -> String:
	return str(play.call("part_for", HELD.id(ui, side))) if is_instance_valid(play) else ""

func station_hint(ui: Node, side: String) -> Dictionary:
	if not is_instance_valid(play) or melt < 1.0: return {}
	var part := _part_in(ui, side)
	var vr := side != "desktop"
	if part != "":
		if not wants(part): return {}
		var at := attach_point(part)
		if vr:
			var hand := HELD.point(ui, side)
			if not hand.is_finite() or hand.distance_to(at) > 0.8: return {}
		elif not HELD.looking_at(ui, at, maxf(top_radius(), 0.25), LOOK_REACH): return {}
		var word: String = {"nose": "Add the carrot nose", "coal": "Add coal", "arm": "Add a stick arm", "scarf": "Wrap the scarf"}[part]
		return {"target": self, "point": at, "text": ("Hold it there · " if vr else "Click · ") + word, "outline": null}
	if radii.size() != 1 or not HELD.id(ui, side).is_empty(): return {}
	var centre := ball_centre(0)
	if vr:
		var palm := HELD.point(ui, side)
		if not palm.is_finite() or palm.distance_to(centre) > radii[0] + 0.5: return {}
		return {"target": self, "point": centre + Vector3.UP * radii[0], "text": "Push it %s · Roll the snowball bigger" % ("with both hands" if radii[0] > 0.25 else "along"), "outline": null}
	if not HELD.looking_at(ui, centre, radii[0] + 0.15, LOOK_REACH): return {}
	return {"target": self, "point": centre + Vector3.UP * radii[0], "text": "Hold click and walk · Roll it bigger, into a bigger ball to stack it", "outline": null}

func station_use(ui: Node, side: String, down: bool) -> bool:
	if not down:
		if _rolling_side == side: stop_rolling(); return true
		return false
	if not is_instance_valid(play) or side != "desktop": return false
	var part := _part_in(ui, side)
	if part != "":
		if not wants(part) or not HELD.looking_at(ui, attach_point(part), maxf(top_radius(), 0.25), LOOK_REACH): return false
		return bool(play.call("dress_from_hand", self, ui, side, part))
	if radii.size() != 1 or not HELD.id(ui, side).is_empty(): return false
	if not HELD.looking_at(ui, ball_centre(0), radii[0] + 0.15, LOOK_REACH): return false
	return start_rolling(side)

# ------------------------------------------------------------------ save

func record() -> Dictionary:
	var p := global_position if is_inside_tree() else position
	return {"id": id, "p": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
		"yaw": snappedf(global_rotation.y if is_inside_tree() else rotation.y, 0.01),
		"r": radii.map(func(r: float) -> float: return snappedf(r, 0.001)), "rolled": snappedf(rolled, 0.01),
		"parts": parts.duplicate(), "made": made_at, "melt": snappedf(melt, 0.01), "by": by}

func apply_record(data: Dictionary) -> bool:
	var p: Variant = data.get("p")
	if not p is Array or (p as Array).size() != 3: return false
	var at := Vector3(float(p[0]), float(p[1]), float(p[2]))
	if not at.is_finite(): return false
	var r: Variant = data.get("r")
	if not r is Array or (r as Array).is_empty(): return false
	radii.clear()
	for value: Variant in (r as Array).slice(0, MAX_BALLS):
		if not (value is float or value is int): return false
		radii.append(clampf(float(value), HAND_RADIUS * 0.5, MAX_RADIUS))
	id = str(data.get("id", id))
	rolled = maxf(float(data.get("rolled", rolled_for(radii[0]))), 0.0) if (data.get("rolled") is float or data.get("rolled") is int) else rolled_for(radii[0])
	var saved_parts: Variant = data.get("parts")
	if saved_parts is Dictionary:
		parts = {"nose": str((saved_parts as Dictionary).get("nose", "")), "coal": clampi(int((saved_parts as Dictionary).get("coal", 0)), 0, MAX_COAL),
			"arms": clampi(int((saved_parts as Dictionary).get("arms", 0)), 0, MAX_ARMS), "scarf": str((saved_parts as Dictionary).get("scarf", ""))}
	made_at = float(data.get("made", made_at)) if (data.get("made") is float or data.get("made") is int) else made_at
	melt = clampf(float(data.get("melt", 1.0)), 0.0, 1.0) if (data.get("melt") is float or data.get("melt") is int) else 1.0
	by = str(data.get("by", "player"))
	position = at
	rotation = Vector3(0, float(data.get("yaw", 0.0)) if (data.get("yaw") is float or data.get("yaw") is int) else 0.0, 0)
	return true

## Lets it melt by `amount` (0..1 of its size); true once gone.
func melt_by(amount: float) -> bool:
	if amount <= 0.0: return melt <= 0.0
	stop_rolling()
	melt = maxf(melt - amount, 0.0)
	if melt <= 0.0: return true
	rebuild()
	return false

## Joins or leaves the station group (snow_play turns stations off outside snow play).
func set_station(on: bool) -> void:
	if on and not is_in_group(STATION_GROUP): add_to_group(STATION_GROUP)
	elif not on and is_in_group(STATION_GROUP): remove_from_group(STATION_GROUP)
