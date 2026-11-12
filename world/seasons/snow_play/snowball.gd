extends RigidBody3D
## One hand snowball (W2-SEAS-F). It is a frozen body while held or lying (no simulation, no
## script work); only a thrown ball simulates. A throw that lands hard bursts into a snow puff
## with a real snow impact sample, and a pony it hits gets physical_reaction("snowball_hit")
## (the conversation director's contact path; only for the player's throws) and a brief
## surprised look. A gentle landing lies
## still and is cleaned up REST_SECONDS after coming to rest. Owned by snow_play.gd (pool, caps).
const FX := preload("res://world/seasons/snow_play/snow_fx.gd")
const REST_SECONDS := 20.0
const FLIGHT_SECONDS := 12.0
## A ball launched at least this fast bursts at its first contact.
const BURST_SPEED := 3.0
const LAYER_FLYING := 8
const MASK_FLYING := 1 | 2

var play: Node
var state := "held"      # held | flying | resting
var thrower: Node
var launch_speed := 0.0
var made_at := 0.0
var _epoch := 0

func _init() -> void:
	name = "Snowball"
	mass = 0.15
	continuous_cd = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	collision_layer = 0
	collision_mask = 0
	contact_monitor = true
	max_contacts_reported = 2
	can_sleep = true
	linear_damp = 0.05
	angular_damp = 0.6
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new(); sphere.radius = FX.MODEL_RADIUS
	shape.shape = sphere
	add_child(shape)
	var near := FX.instance("Snowball_LOD0")
	near.name = "LOD0"; near.visibility_range_end = 9.0; near.visibility_range_end_margin = 1.0
	near.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	add_child(near)
	var far := FX.instance("Snowball_LOD1")
	far.name = "LOD1"; far.visibility_range_begin = 9.0; far.visibility_range_begin_margin = 1.0; far.visibility_range_end = 60.0
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(far)
	# Shape signals also report RID-only colliders (terrain collision has no node).
	body_shape_entered.connect(_on_body_shape_entered)
	sleeping_state_changed.connect(_on_sleeping_changed)
	made_at = Time.get_ticks_msec() * 0.001

## Held in a hand (or a pony's): frozen and touching nothing.
func hold() -> void:
	_epoch += 1
	state = "held"
	freeze = true
	collision_layer = 0; collision_mask = 0
	linear_velocity = Vector3.ZERO; angular_velocity = Vector3.ZERO

## Let go with this velocity; `by` (the player body or a pony) never collides with its own throw.
func throw(velocity: Vector3, by: Node = null) -> void:
	if not velocity.is_finite(): velocity = Vector3.ZERO
	_epoch += 1
	state = "flying"
	thrower = by
	launch_speed = velocity.length()
	if by is PhysicsBody3D and is_instance_valid(by): add_collision_exception_with(by)
	collision_layer = LAYER_FLYING; collision_mask = MASK_FLYING
	freeze = false
	sleeping = false
	linear_velocity = velocity
	angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6)) if launch_speed > 1.0 else Vector3.ZERO
	var epoch := _epoch
	if is_inside_tree(): get_tree().create_timer(FLIGHT_SECONDS, false).timeout.connect(_flight_timeout.bind(epoch))

func _flight_timeout(epoch: int) -> void:
	if epoch == _epoch and state == "flying": _rest()

func _on_sleeping_changed() -> void:
	if sleeping and state == "flying": _rest()

## Lying still: frozen, no collision, gone after REST_SECONDS unless picked up again.
func _rest() -> void:
	_epoch += 1
	state = "resting"
	freeze = true
	collision_layer = 0; collision_mask = 0
	linear_velocity = Vector3.ZERO; angular_velocity = Vector3.ZERO
	if is_instance_valid(thrower) and thrower is PhysicsBody3D: remove_collision_exception_with(thrower)
	var epoch := _epoch
	if is_inside_tree(): get_tree().create_timer(REST_SECONDS, false).timeout.connect(_rest_timeout.bind(epoch))

func _rest_timeout(epoch: int) -> void:
	if epoch == _epoch and state == "resting": despawn()

func _on_body_shape_entered(_rid: RID, body: Node, _shape: int, _local: int) -> void:
	if state != "flying" or (body != null and body == thrower): return
	var actor := reactor(body)
	if actor == null and launch_speed < BURST_SPEED: return
	hit(body, actor)

## The pony (or dragon) a collider belongs to: the first ancestor with physical_reaction.
static func reactor(body: Node) -> Node:
	if body == null: return null
	var at: Node = body
	while at != null and not at.has_signal("physical_reaction"): at = at.get_parent()
	return at

## Bursts here: puff, impact sample, trail stamp, the reaction, then the ball is gone.
func hit(body: Node, actor: Node = null) -> void:
	if state == "gone": return
	var at := global_position
	var level := int(play.call("effects_level")) if is_instance_valid(play) and play.has_method("effects_level") else 2
	FX.puff(get_parent() if get_parent() != null else self, at, 1.0, level)
	FX.sound(self, "snow_play_hit", at)
	if actor != null:
		# The conversation director reads physical_reaction as the player's doing: a pony's own
		# snowball fight (W2-SEAS-H) only shows on her face and through snow_play.snowball_hit.
		var by_pony := is_instance_valid(thrower) and thrower.has_signal("physical_reaction")
		if not by_pony and actor.has_signal("physical_reaction"): actor.emit_signal("physical_reaction", "snowball_hit")
		var looks: Variant = actor.get("expressions")
		if looks is Object and is_instance_valid(looks) and (looks as Object).has_method("boop"): (looks as Object).call("boop")
	if is_instance_valid(play) and play.has_method("_on_snowball_hit"): play.call("_on_snowball_hit", self, body, actor, at)
	despawn()

func despawn() -> void:
	if state == "gone": return
	state = "gone"
	_epoch += 1
	if is_instance_valid(play) and play.has_method("_forget_snowball"): play.call("_forget_snowball", self)
	queue_free()
