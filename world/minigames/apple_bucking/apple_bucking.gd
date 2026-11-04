extends Node3D
## Physical orchard activity. Host owns persistence and the atomic harvest/wallet
## commit; this node never opens a save file or calls a paid dialogue provider.
signal changed
signal markers_changed
signal invitation_available(invitation: Dictionary)
signal harvest_completed(tree_id: String, receipt: String)
signal claim_lost(body: RigidBody3D, owner: Node)
const SFX := preload("res://world/audio/interaction_sounds.gd")
const STATE := preload("res://world/minigames/apple_bucking/harvest_state.gd")
const COLLECTOR := preload("res://world/minigames/apple_bucking/applejack_collector.gd")
const HANDS := preload("res://world/minigames/apple_bucking/apple_bucking_hands.gd")
const APPLE: PackedScene = preload("res://world/inventory/assets/apple.tscn")
const CELL: float = 16.0
const MAX_LOOSE: int = 72
var host: Node
var orchard: Node3D
var ledger: RefCounted = STATE.new()
## (receipt: String, bits: int, proposed_snapshot: Dictionary) -> bool.
## Must atomically checkpoint wallet AND activity. Unset/refused means no payout.
var commit_harvest: Callable
var collector: Node
var hands: Node
var trees: Dictionary = {}
var loose: Dictionary = {}
var baskets: Dictionary = {}
var _basket_navigation: Dictionary = {}
var _stored_drops: Dictionary = {}
var _cells: Dictionary = {}
var _bounds: AABB
## The authored grid's bounds only: the farm sign stays where it always stood when Anon's row
## (planted trees, ids "saa:pNN") widens the orchard.
var _grid_bounds: AABB
var _grid_count: int = 0
var _bound: bool = false
var _clock: Node
var _settings: Node
var _slow: float = 0.0
var _ripe_count: int = -1
var _invited_cycle: int = -1
var _sign: Node3D
var _notice: Label3D
var _drop_mesh: Mesh
var _configured: bool = false
var _claims: Dictionary = {}

func setup(game: Node) -> void:
	if _configured: return
	_configured = true
	host = game
	_clock = get_node_or_null("/root/TimeOfDay")
	_settings = get_node_or_null("/root/Settings")
	collector = COLLECTOR.new(); collector.name = "ApplejackCollector"
	add_child(collector); collector.setup(self)
	hands = HANDS.new(); hands.name = "BuckingHands"
	add_child(hands); hands.setup(self)
	_find_orchard()

func _find_orchard() -> void:
	if is_instance_valid(orchard): return
	var farm: Node3D = get_tree().get_first_node_in_group("apple_orchards") as Node3D
	if farm != null: attach_orchard(farm)

func attach_orchard(farm: Node3D) -> void:
	if orchard == farm: return
	if is_instance_valid(orchard): return # one activity per orchard; never duplicate fruit
	orchard = farm
	if farm.has_signal("orchard_ready") and not farm.is_connected("orchard_ready", _bind_trees):
		farm.connect("orchard_ready", _bind_trees)
	# Trees planted in Anon's row (farm_dressing.add_tree, P5) join the harvest as they grow.
	if farm.has_signal("tree_added") and not farm.is_connected("tree_added", _add_row):
		farm.connect("tree_added", _add_row)
	if farm.has_signal("tree_removed") and not farm.is_connected("tree_removed", _remove_row):
		farm.connect("tree_removed", _remove_row)
	_bind_trees()

func _bind_trees() -> void:
	if _bound or not is_instance_valid(orchard): return
	var rows: Array = orchard.get("orchard_trees")
	for source: Dictionary in rows: _add_row(source, false)
	if trees.is_empty(): return
	_bound = true
	_make_sign()
	refresh()

## One orchard row into the harvest: trees, the lookup cells and the bounds. Idempotent per id.
## A planted tree arriving after the bind refreshes at once (its fruit state, the ripe count).
func _add_row(source: Dictionary, live: bool = true) -> void:
	if source.is_empty() or not is_instance_valid(orchard) or trees.has(str(source.get("id", ""))): return
	var row: Dictionary = source.duplicate()
	row.position = orchard.to_global(source.position)
	var fruit: Array[Transform3D] = []
	for transform: Transform3D in source.apples: fruit.append(orchard.global_transform * transform)
	row.apples = fruit
	trees[row.id] = row
	var cell: Vector2i = _cell(row.position)
	if not _cells.has(cell): _cells[cell] = []
	_cells[cell].append(row.id)
	if trees.size() == 1: _bounds = AABB(row.position, Vector3.ZERO)
	else: _bounds = _bounds.expand(row.position)
	if not str(row.id).begins_with("saa:p"):
		_grid_count += 1
		if _grid_count == 1: _grid_bounds = AABB(row.position, Vector3.ZERO)
		else: _grid_bounds = _grid_bounds.expand(row.position)
	if live and _bound: refresh()

## A planted tree left the orchard (farm_dressing.remove_tree, a loaded save without it). The
## harvest ledger row goes with the save restore that follows; the bounds only ever grow.
func _remove_row(tree_id: String) -> void:
	if not trees.has(tree_id): return
	var cell: Vector2i = _cell(trees[tree_id].position)
	if _cells.has(cell): (_cells[cell] as Array).erase(tree_id)
	trees.erase(tree_id)
	if _bound: refresh()

static func _cell(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x / CELL), floori(point.z / CELL))

func nearby_trees(point: Vector3, radius: float = 2.0) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if not point.is_finite(): return found
	var center: Vector2i = _cell(point)
	var span: int = ceili(radius / CELL)
	for z: int in range(center.y - span, center.y + span + 1):
		for x: int in range(center.x - span, center.x + span + 1):
			for id: String in _cells.get(Vector2i(x, z), []):
				var tree: Dictionary = trees[id]
				var offset: Vector3 = point - Vector3(tree.position)
				if Vector2(offset.x, offset.z).length_squared() <= radius * radius: found.append(tree)
	return found

func player_position() -> Vector3:
	if not is_instance_valid(host): return Vector3.INF
	var inventory: Node = host.get("inventory") as Node
	var body: Node3D = inventory.get("player_body") as Node3D if is_instance_valid(inventory) else null
	if not is_instance_valid(body): body = host.get("player") as Node3D
	if not is_instance_valid(body): return Vector3.INF
	var camera: Camera3D = inventory.get("camera") as Camera3D if is_instance_valid(inventory) else null
	# The XR rig root stays at spawn; Body moves with the stick, while its capsule
	# follows the headset in room scale. Match that capsule, keeping Body's floor y.
	if camera is XRCamera3D and body.is_ancestor_of(camera):
		return Vector3(camera.global_position.x, body.global_position.y, camera.global_position.z)
	return body.global_position

func player_near_orchard(distance: float) -> bool:
	if trees.is_empty(): return false
	var point: Vector3 = player_position()
	if not point.is_finite(): return false
	return point.x >= _bounds.position.x - distance and point.x <= _bounds.end.x + distance \
		and point.z >= _bounds.position.z - distance and point.z <= _bounds.end.z + distance

func day() -> float:
	return float(_clock.day) + float(_clock.hours) / 24.0 if is_instance_valid(_clock) else 0.0

func season_days() -> int:
	return maxi(1, int(_settings.season_days())) if is_instance_valid(_settings) else 20

func _physics_process(delta: float) -> void:
	if not _configured: return
	_settle_drops(delta)
	_slow -= delta
	if _slow > 0.0: return
	_slow = 1.0
	_find_orchard()
	refresh()

## Bucked apples settle near where they land instead of rolling down orchard slopes (thread
## report 2026-10-31). Jolt has no rolling resistance and damping alone only slows a roll, so on
## the ground a drop gets strong rolling damping, and once slow or after SETTLE_ROLL_S of ground
## contact its rotation locks and ground friction holds it where it is. Only these harvest drops
## (apple.tscn and every other apple are untouched); a carried apple tumbles freely when thrown.
const GROUND_LINEAR_DAMP: float = 1.2
const GROUND_ANGULAR_DAMP: float = 4.0
const SETTLE_SPEED: float = .6
const SETTLE_ROLL_S: float = 1.0
const SPAWN_DAMP: float = .7

func _settle_drops(delta: float) -> void:
	for value: Variant in loose.values():
		if not is_instance_valid(value): continue
		var body: RigidBody3D = value
		if body.freeze:
			# Held: thrown, it flies and tumbles as it did when it first fell.
			if body.lock_rotation: body.lock_rotation = false
			body.linear_damp = SPAWN_DAMP; body.angular_damp = SPAWN_DAMP
			body.set_meta("ground_s", 0.0)
			continue
		if body.lock_rotation or body.get_contact_count() == 0: continue
		body.linear_damp = GROUND_LINEAR_DAMP; body.angular_damp = GROUND_ANGULAR_DAMP
		var rolled: float = float(body.get_meta("ground_s", 0.0)) + delta
		body.set_meta("ground_s", rolled)
		if body.linear_velocity.length() < SETTLE_SPEED or rolled >= SETTLE_ROLL_S: body.lock_rotation = true

func refresh() -> void:
	if not is_instance_valid(orchard): return
	# Town events (world/mechanics/calendar/town_calendar.gd): Applebuck Season takes more baskets
	# a day and pays more per basket; without a calendar (fixtures) the defaults stand.
	var calendar: Node = get_tree().get_first_node_in_group("town_calendar") if is_inside_tree() else null
	ledger.daily_baskets = int(calendar.call("effect", "daily_baskets", STATE.DAILY_BASKETS)) if calendar != null else STATE.DAILY_BASKETS
	ledger.reward = int(calendar.call("effect", "basket_pay", STATE.REWARD)) if calendar != null else STATE.REWARD
	var when: float = day()
	var length: int = season_days()
	var count: int = 0
	for id: String in trees:
		var growth: float = snappedf(ledger.growth(id, when, length), 1.0 / 128.0)
		var record: Dictionary = ledger.trees.get(id, {})
		orchard.set_fruit_state(id, growth, record.get("released", []) if not record.get("paid", true) else [])
		if ledger.available(id, when, length): count += 1
	if count != _ripe_count:
		_ripe_count = count
		markers_changed.emit()
	var now: Dictionary = STATE.calendar(when, length)
	if count > 0 and _invited_cycle != int(now.season):
		_invited_cycle = int(now.season)
		invitation_available.emit({"id":"apple_bucking", "pony_id":"applejack",
			"text":"The apples are ripe. Buck a trunk and I'll gather them into the baskets.", "markers":activity_markers()})
	if _notice != null:
		# A farm sign, not an instruction board (dev 2026-09-30); the trunk prompt shows how.
		var done_today: bool = count == 0 and bool(now.ripe) and ledger.baskets_on(when) >= ledger.daily_baskets
		var harvest_line: String = "\nApplebuck Season" if calendar != null and bool(calendar.call("active", "applebuck_season")) else "\nHarvest time"
		_notice.text = "Sweet Apple Acres" + (harvest_line if count > 0 else ("\nBaskets full today" if done_today else ""))
	# No remote physics bodies: suspended apples resume at saved positions when
	# the player returns. Only the bounded loose set is inspected once a second.
	if not player_near_orchard(55.0):
		if collector != null: collector.release()
		_suspend_drops()
	else:
		_materialize_pending()
		_recover_unsupported_drops()
		_collect_basket_apples()
	_register_basket_navigation()
	for id: String in ledger.trees:
		if ledger.pending_payment(id) and ledger.pay(id, commit_harvest, snapshot()):
			changed.emit(); harvest_completed.emit(id, ledger.receipt(id))

func activity_markers() -> Array[Dictionary]:
	var markers: Array[Dictionary] = []
	if _ripe_count <= 0 or trees.is_empty(): return markers
	var at: Vector3 = _sign.global_position if is_instance_valid(_sign) else _bounds.get_center()
	markers.append({"id":"activity:apple_bucking", "name":"Apple bucking · %d ripe trees" % _ripe_count,
		"kind":"farm", "position":Vector2(at.x, at.z), "activity":"apple_bucking", "ripe":true})
	return markers

func can_strike(id: String, strength: float = 1.0) -> bool:
	if not is_finite(strength) or strength <= 0.0: return false
	if not trees.has(id) or not player_near_orchard(6.0) or ledger._committing: return false
	var tree: Dictionary = trees[id]
	if player_position().distance_to(tree.position) > 3.2: return false
	if not ledger.available(id, day(), season_days()): return false
	var portion: int = _strike_portion(id, strength)
	return portion > 0 and loose.size() + portion <= MAX_LOOSE

## Why a trunk in reach cannot be bucked now, for the hint; "" when no reason worth showing.
func strike_block_reason(id: String) -> String:
	if not trees.has(id) or ledger._committing: return ""
	if not ledger.available(id, day(), season_days()):
		return "No ripe apples on this tree yet" if bool(STATE.calendar(day(), season_days()).ripe) else "Apples are out of season"
	var portion: int = _strike_portion(id, 1.0)
	if portion > 0 and loose.size() + portion > MAX_LOOSE: return "Pick up the fallen apples first"
	return ""

func _strike_portion(id: String, strength: float) -> int:
	var tree: Dictionary = trees[id]
	var count: int = tree.apples.size()
	if count < 1 or count > 64: return 0
	var portion: int = maxi(1, ceili(float(count) / 3.0 * clampf(strength, .65, 1.35)))
	var record: Dictionary = ledger.trees.get(id, {})
	var remaining: int = count if record.is_empty() or record.paid else ledger.remaining_canopy(id).size()
	return mini(portion, remaining)

## Called only after input has certified an intentional contact with this trunk.
func strike(id: String, strength: float = 1.0) -> bool:
	if not can_strike(id, strength): return false
	var tree: Dictionary = trees[id]
	var count: int = tree.apples.size()
	var portion: int = _strike_portion(id, strength)
	var record: Dictionary = ledger.trees.get(id, {})
	if not _ensure_basket(id): return false
	if (record.is_empty() or record.paid) and not ledger.begin(id, count, day(), season_days()): return false
	var released: Array[int] = ledger.release_cluster(id, portion)
	if released.is_empty(): return false
	SFX.play_event(self, "prop_tree", {"intensity":clampf(strength, .65, 1.35), "material":"wood"}, Vector3(tree.position) + Vector3.UP)
	_update_basket(id)
	orchard.set_fruit_state(id, 1.0, ledger.trees[id].released)
	orchard.shake_tree(id, strength)
	for index: int in released: _spawn_drop(id, index)
	changed.emit()
	refresh()
	return true

func _key(id: String, index: int) -> String:
	return "%s/apple:%02d" % [id, index]

func _spawn_drop(id: String, index: int) -> void:
	var key: String = _key(id, index)
	if loose.has(key) or loose.size() >= MAX_LOOSE or not trees.has(id): return
	var tree: Dictionary = trees[id]
	if index >= tree.apples.size(): return
	var transform: Transform3D = tree.apples[index]
	var saved: Dictionary = _stored_drops.get(key, {})
	var body: RigidBody3D = RigidBody3D.new()
	body.name = "HarvestApple_%s_%d" % [id.replace(":", "_"), index]
	body.mass = .16; body.collision_layer = 8; body.collision_mask = 1
	body.continuous_cd = true; body.linear_damp = SPAWN_DAMP; body.angular_damp = SPAWN_DAMP
	body.contact_monitor = true; body.max_contacts_reported = 1
	body.set_meta("tree_id", id); body.set_meta("apple_index", index); body.set_meta("harvest_apple", true)
	var shape: CollisionShape3D = CollisionShape3D.new()
	var sphere: SphereShape3D = SphereShape3D.new(); sphere.radius = .10; shape.shape = sphere
	body.add_child(shape)
	var visual: Node3D = APPLE.instantiate(); visual.scale = transform.basis.get_scale(); body.add_child(visual)
	add_child(body)
	body.add_to_group("harvest_apples")
	body.set_meta("harvest_falling", saved.is_empty())
	body.body_entered.connect(_apple_first_contact.bind(body))
	body.global_transform = Transform3D(transform.basis.orthonormalized(), transform.origin)
	if not saved.is_empty():
		body.global_position = _vector(saved.position)
		body.linear_velocity = _vector(saved.velocity)
	else:
		var rng: RandomNumberGenerator = RandomNumberGenerator.new()
		rng.seed = hash(key + ":" + str(ledger.trees[id].cycle))
		# The physical buck shakes fruit outward so it clears the trunk's flat
		# collision cap instead of balancing there beyond AJ's reach.
		var outward: Vector3 = transform.origin - Vector3(tree.position)
		outward.y = 0.0
		if outward.length_squared() < .001: outward = Vector3.RIGHT.rotated(Vector3.UP, rng.randf() * TAU)
		body.linear_velocity = outward.normalized() * rng.randf_range(1.25, 1.65) + Vector3.DOWN * .2
	loose[key] = body
	_stored_drops.erase(key)

func _apple_first_contact(_surface: Node, body: RigidBody3D) -> void:
	if not _registered_apple(body) or not body.get_meta("harvest_falling", false): return
	body.set_meta("harvest_falling", false)
	if claim_owner(body) != null: return
	SFX.play_event(body, "prop_place", {"material":"soft", "intensity":clampf(body.linear_velocity.length() / 5.0, .3, 1.0)}, body.global_position)

func _materialize_pending() -> void:
	for id: String in ledger.trees:
		if not trees.has(id): continue
		if Vector3(trees[id].position).distance_to(player_position()) > 40.0: continue
		if not _ensure_basket(id): continue
		for index: int in ledger.outstanding(id): _spawn_drop(id, index)

func _suspend_drops() -> void:
	_release_claims()
	for key: String in loose.keys():
		var body: RigidBody3D = loose[key]
		if is_instance_valid(body):
			_stored_drops[key] = _drop_state(body)
			body.queue_free()
	loose.clear()

func _drop_state(body: RigidBody3D) -> Dictionary:
	return {"position":_array(body.global_position), "velocity":_array(body.linear_velocity)}

func next_apple(from: Vector3) -> RigidBody3D:
	var best: RigidBody3D
	var distance: float = INF
	for body: RigidBody3D in loose.values():
		if not apple_available(body): continue
		if body.linear_velocity.length() > .5: continue
		var gap: float = from.distance_squared_to(body.global_position)
		if gap < distance: best = body; distance = gap
	return best

func basket_for(id: String) -> Vector3:
	var basket: Node3D = baskets.get(id)
	return basket.global_position + Vector3.UP * .28 if is_instance_valid(basket) else Vector3.INF

func _ensure_basket(id: String) -> bool:
	if baskets.has(id): return true
	if not trees.has(id): return false
	var origin: Vector3 = trees[id].position
	var place: Vector3 = Vector3.INF
	for direction: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var guess: Vector3 = origin + direction * 1.6
		var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(guess + Vector3.UP * 1.0, guess - Vector3.UP * 2.0, 1))
		if hit.is_empty() or Vector3(hit.normal).y < .8: continue
		var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
		var box: BoxShape3D = BoxShape3D.new(); box.size = Vector3(.8,.6,.7)
		query.shape = box; query.collision_mask = 1
		query.transform.origin = Vector3(hit.position) + Vector3.UP * .35
		if get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty(): place = hit.position; break
	if not place.is_finite(): return false
	var basket: StaticBody3D = StaticBody3D.new(); basket.name = "HarvestBasket"
	basket.collision_layer = 1; basket.collision_mask = 0; add_child(basket)
	basket.global_position = place
	for spec: Array in [[Vector3(0,.03,0),Vector3(.65,.06,.55)], [Vector3(-.32,.17,0),Vector3(.045,.32,.55)], [Vector3(.32,.17,0),Vector3(.045,.32,.55)], [Vector3(0,.17,-.26),Vector3(.65,.32,.045)], [Vector3(0,.17,.26),Vector3(.65,.32,.045)]]:
		_box(basket, spec[0], spec[1], Color("a77743"))
		var shape: CollisionShape3D = CollisionShape3D.new()
		var box: BoxShape3D = BoxShape3D.new(); box.size = spec[1]
		shape.shape = box; shape.position = spec[0]; basket.add_child(shape)
	baskets[id] = basket
	_register_basket_navigation()
	_update_basket(id)
	return true

func _register_basket_navigation() -> void:
	if baskets.is_empty(): return
	for navigation: Node in get_tree().get_nodes_in_group("pony_navigation"):
		if not navigation.has_method("set_blocker"): continue
		var service_id: int = navigation.get_instance_id()
		if not _basket_navigation.has(service_id):
			_basket_navigation[service_id] = {"service":weakref(navigation), "ids":{}}
		var registered: Dictionary = _basket_navigation[service_id].ids
		for id: String in baskets:
			if registered.has(id): continue
			var basket: Node3D = baskets[id]
			var occupied: AABB = AABB(basket.global_position - Vector3(.35, .05, .30), Vector3(.70, .45, .60))
			if not navigation.bounds.intersects(occupied): continue
			var token: StringName = StringName("apple-basket:%d:%s" % [get_instance_id(), id])
			# A shallow open basket is occupied, even if grid rays hit its bottom.
			navigation.set_blocker(token, occupied)
			registered[id] = token

func _update_basket(id: String) -> void:
	var basket: Node3D = baskets.get(id)
	if basket == null: return
	var batch: MultiMeshInstance3D = basket.get_node_or_null("GatheredFruit") as MultiMeshInstance3D
	if batch == null:
		batch = MultiMeshInstance3D.new(); batch.name = "GatheredFruit"; basket.add_child(batch)
		var sample: Node3D = APPLE.instantiate()
		var source: MeshInstance3D = sample.get_node("Body") as MeshInstance3D
		_drop_mesh = source.mesh; sample.free()
		batch.multimesh = MultiMesh.new(); batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D; batch.multimesh.mesh = _drop_mesh
	var record: Dictionary = ledger.trees.get(id, {})
	var count: int = record.get("collected", []).size()
	batch.multimesh.instance_count = count
	for index: int in count:
		var offset: Vector3 = Vector3((index % 4 - 1.5) * .13, .10 + int(index / 12) * .10, (int(index / 4) % 3 - 1) * .14)
		batch.multimesh.set_instance_transform(index, Transform3D(Basis.from_scale(Vector3.ONE * 1.5), offset))

func _registered_apple(body: RigidBody3D) -> bool:
	if not is_instance_valid(body): return false
	var id: String = str(body.get_meta("tree_id", ""))
	var index: int = int(body.get_meta("apple_index", -1))
	var key: String = _key(id, index)
	return loose.get(key) == body and ledger.is_outstanding(id, index)

func claim_owner(body: RigidBody3D) -> Node:
	if not _registered_apple(body): return null
	var key: String = _key(str(body.get_meta("tree_id", "")), int(body.get_meta("apple_index", -1)))
	var reference: WeakRef = _claims.get(key) as WeakRef
	return reference.get_ref() as Node if reference != null else null

func apple_available(body: RigidBody3D) -> bool:
	if not _registered_apple(body): return false
	var key: String = _key(str(body.get_meta("tree_id", "")), int(body.get_meta("apple_index", -1)))
	if _claims.has(key) and claim_owner(body) == null:
		_claims.erase(key)
		body.set_meta("apple_carried", false)
		body.freeze = false; body.collision_layer = 8
	return not _claims.has(key)

func claim_apple(body: RigidBody3D, owner: Node) -> bool:
	if not is_instance_valid(owner) or not apple_available(body): return false
	var key: String = _key(str(body.get_meta("tree_id", "")), int(body.get_meta("apple_index", -1)))
	_claims[key] = weakref(owner)
	body.set_meta("apple_carried", true)
	body.freeze = true; body.collision_layer = 0
	body.linear_velocity = Vector3.ZERO; body.angular_velocity = Vector3.ZERO
	SFX.play_event(body, "prop_pickup", {"material":"soft"}, body.global_position)
	return true

func release_apple(body: RigidBody3D, owner: Node, velocity: Vector3 = Vector3.ZERO) -> bool:
	if not is_instance_valid(owner) or claim_owner(body) != owner or not velocity.is_finite(): return false
	var key: String = _key(str(body.get_meta("tree_id", "")), int(body.get_meta("apple_index", -1)))
	_claims.erase(key)
	body.set_meta("apple_carried", false)
	body.freeze = false; body.collision_layer = 8
	body.linear_velocity = velocity.limit_length(12.0)
	return true

func _release_claims() -> void:
	for key: String in _claims.keys():
		var body: RigidBody3D = loose.get(key) as RigidBody3D
		var owner: Node = claim_owner(body)
		if is_instance_valid(body):
			if is_instance_valid(owner): release_apple(body, owner)
			else:
				body.set_meta("apple_carried", false)
				body.freeze = false; body.collision_layer = 8
			claim_lost.emit(body, owner)
	_claims.clear()

func _basket_contains(id: String, point: Vector3) -> bool:
	var basket: Node3D = baskets.get(id) as Node3D
	if basket == null or not point.is_finite(): return false
	var local: Vector3 = basket.to_local(point)
	# The apple's centre must enter the open interior, above the basket floor.
	return absf(local.x) <= .275 and absf(local.z) <= .215 and local.y >= .08 and local.y <= .43

func deposit(body: RigidBody3D, owner: Node = null) -> bool:
	if not _registered_apple(body): return false
	var claimant: Node = claim_owner(body)
	if claimant != null and claimant != owner: return false
	if claimant == null and owner != null: return false
	if claimant == null and body.linear_velocity.length_squared() > .25: return false
	var id: String = str(body.get_meta("tree_id", ""))
	var index: int = int(body.get_meta("apple_index", -1))
	var key: String = _key(id, index)
	if not _basket_contains(id, body.global_position): return false
	if not ledger.collect(id, index): return false
	_claims.erase(key)
	loose.erase(key); _stored_drops.erase(key)
	SFX.play_event(self, "prop_harvest_deposit", {"material":"soft"}, basket_for(id))
	body.queue_free(); _update_basket(id)
	changed.emit()
	return true

func _collect_basket_apples() -> void:
	# At most MAX_LOOSE bodies, once per second. A release into the basket is
	# still a physical deposit; never score a held apple passing over its rim.
	for key: String in loose.keys():
		var body: RigidBody3D = loose[key]
		if apple_available(body): deposit(body)

func _recover_unsupported_drops() -> void:
	# Streaming can remove terrain collision. Preserve a suspended fruit at its
	# last support height; never count it as gathered or silently lose a reward.
	for key: String in loose.keys():
		var body: RigidBody3D = loose[key]
		if not is_instance_valid(body) or body.get_meta("apple_carried", false): continue
		var id: String = str(body.get_meta("tree_id"))
		var floor_y: float = Vector3(trees[id].position).y
		if body.global_position.y < floor_y - 3.0:
			var point: Vector3 = body.global_position
			var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				Vector3(point.x, floor_y + 1.0, point.z), Vector3(point.x, point.y - 2.0, point.z), 1))
			# A fruit rolling onto genuinely lower terrain stays there.
			if not hit.is_empty():
				floor_y = Vector3(hit.position).y
				if point.y >= floor_y - .3: continue
			_stored_drops[key] = {"position":_array(Vector3(body.global_position.x, floor_y + .15, body.global_position.z)), "velocity":[0,0,0]}
			body.queue_free(); loose.erase(key)

## Capture on the main thread: reads live body transforms, without mutating them.
## The returned detached data can then be validated/serialized by the save worker.
func snapshot() -> Dictionary:
	var drops: Dictionary = _stored_drops.duplicate(true)
	for key: String in loose:
		var body: RigidBody3D = loose[key]
		if is_instance_valid(body): drops[key] = _drop_state(body)
	return {"version":2, "ledger":ledger.snapshot(), "drops":drops}

## Pure data validation. Never access nodes, autoloads, servers or mutable statics:
## GameSaves calls this on its worker thread with a detached snapshot.
static func valid_snapshot(value: Variant) -> bool:
	if not value is Dictionary or (value.get("version") != 1 and value.get("version") != 2) or not STATE.valid(value.get("ledger")) or not value.get("drops") is Dictionary: return false
	if value.drops.size() > 65536: return false
	for key: Variant in value.drops:
		if not key is String or key.length() > 160: return false
		var tree_id: String = key.get_slice("/apple:", 0)
		var index: int = key.get_slice("/apple:", 1).to_int()
		if key != "%s/apple:%02d" % [tree_id, index] or not value.ledger.trees.has(tree_id): return false
		var tree: Dictionary = value.ledger.trees[tree_id]
		if tree.paid or index < 0 or index >= int(tree.count) or index in tree.collected or float(index) in tree.collected: return false
		if value.ledger.version == 2 and index not in tree.released and float(index) not in tree.released: return false
		var row: Variant = value.drops[key]
		if not row is Dictionary: return false
		for field: String in ["position", "velocity"]:
			var xyz: Variant = row.get(field)
			if not xyz is Array or xyz.size() != 3: return false
			for number: Variant in xyz:
				if not (number is int or number is float) or not is_finite(float(number)) or absf(float(number)) > 100000: return false
	return true

func restore(value: Variant) -> bool:
	if ledger._committing or not valid_snapshot(value): return false
	if collector != null: collector.release()
	_release_claims()
	for body: RigidBody3D in loose.values():
		if is_instance_valid(body): body.queue_free()
	loose.clear()
	if not ledger.restore(value.ledger): return false
	_stored_drops = value.drops.duplicate(true)
	for id: String in baskets: _update_basket(id)
	refresh()
	return true

static func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

static func _vector(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _make_sign() -> void:
	if is_instance_valid(_sign): return
	_sign = Node3D.new(); _sign.name = "OrchardNotice"; add_child(_sign)
	var area: AABB = _grid_bounds if _grid_count > 0 else _bounds
	var at: Vector3 = Vector3(area.get_center().x, area.position.y, area.end.z + 2.0)
	# Orchard bounds span a hillside: their lowest Y is not the ground here.
	var height: float = NAN
	if is_instance_valid(WorldTerrain.instance):
		height = WorldTerrain.instance.height_at(at)
	if not is_finite(height):
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			Vector3(at.x, 400, at.z), Vector3(at.x, -400, at.z), 1)
		var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			var support: Vector3 = hit.position
			height = support.y
	if is_finite(height): at.y = height
	_sign.global_position = at
	_box(_sign, Vector3(0,.55,-.065), Vector3(.08,1.1,.08), Color("976c43"))
	_box(_sign, Vector3(0,1.15,0), Vector3(1.6,.65,.045), Color("e2c995"))
	_notice = Label3D.new(); _notice.pixel_size = .0023; _notice.font_size = 28
	_notice.modulate = Color("382418"); _notice.position = Vector3(0,1.15,.027)
	_notice.outline_size = 0
	_notice.no_depth_test = false; _sign.add_child(_notice)

static func _box(parent: Node3D, position: Vector3, size: Vector3, color: Color) -> void:
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box: BoxMesh = BoxMesh.new(); box.size = size; mesh.mesh = box
	var material: StandardMaterial3D = StandardMaterial3D.new(); material.albedo_color = color; material.roughness = .9
	mesh.material_override = material; mesh.position = position; parent.add_child(mesh)

func _exit_tree() -> void:
	if collector != null: collector.release()
	_release_claims()
	for record: Dictionary in _basket_navigation.values():
		var navigation: Node = record.service.get_ref() as Node
		if is_instance_valid(navigation):
			for token: StringName in record.ids.values(): navigation.remove_blocker(token)
