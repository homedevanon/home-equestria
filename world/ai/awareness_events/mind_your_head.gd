extends RefCounted
## M-ACT-05 "mind your head" (board #14 thread notes, UD-014): Anon is tall for pony doorways,
## ceilings and low branches. When something solid sits just above his crown (or right in front of
## it), ponies who can see him get one recent-event line ("Anon had to duck under the low
## doorway"), so the director can have her say "mind your head!" in her own words. No extra AI
## request: the line rides in her next prompt's recent events like a boop or a pickup.
##
## Wiring (pony_awareness.gd belongs to W2-SEAS-H this wave; hook note for W3-INTEGRATION): in
## pony_awareness.gd sample(), next to the other player events, after sample.player_visible is set:
##     var duck: Dictionary = MIND_YOUR_HEAD.event_for(id, observer, player, now, bool(sample.player_visible))
##     if not duck.is_empty(): events.append(duck)
## with `const MIND_YOUR_HEAD := preload("res://world/ai/awareness_events/mind_your_head.gd")`.
##
## Cost: two short rays at most every CHECK_EVERY_MS for the whole town (shared static cache), only
## while some pony is sampling with Anon in view; nothing per frame.
const HOUSE := preload("res://world/buildings/house_interior.gd")
## His crown is this far above the eyes (player/anon_body.gd: 12 cm).
const CROWN_ABOVE_EYES := 0.12
## Something solid this close above his crown counts.
const CLEARANCE := 0.10
## And this far ahead of his crown, at crown height (walking into a lintel).
const LOOK_AHEAD := 0.30
const CHECK_EVERY_MS := 500
## A duck stays news this long (real seconds) and each pony hears of it at most every COOLDOWN_S.
## conversation_director.gd samples one nearby pony every 0.1 s in turn (_physics_step), so with
## many characters a pony's next sample can be several seconds away: FRESH_S covers that round.
const FRESH_S := 10.0
const COOLDOWN_S := 45.0
const RANGE_M := 10.0
const DOOR_M := 1.6
const WORLD_LAYER := 1
const TEXTS := {
	"doorway": "Anon had to duck his head under the low doorway; he is tall for pony doors.",
	"ceiling": "Anon's head nearly bumped the low ceiling; he has to stoop in here.",
	"branch": "Anon had to duck under a low branch.",
}
static var _checked_ms := -100000
static var _last: Dictionary = {}
static var _told: Dictionary = {}

## The event for pony `id` watching `player` (his eyes), or {}: {"time": now, "text": ...}.
static func event_for(id: String, observer: Node3D, player: Node3D, now: float, player_visible: bool) -> Dictionary:
	if not player_visible or not is_instance_valid(observer) or not is_instance_valid(player) or not player.is_inside_tree(): return {}
	if observer.global_position.distance_to(player.global_position) > RANGE_M: return {}
	var duck := latest(player, now)
	if duck.is_empty() or now - float(_told.get(id, -INF)) < COOLDOWN_S: return {}
	_told[id] = now
	return {"time": now, "text": str(duck.text)}

## The newest duck, refreshed at most every CHECK_EVERY_MS; {} when none is fresh.
static func latest(player: Node3D, now: float) -> Dictionary:
	var ms := Time.get_ticks_msec()
	if ms - _checked_ms >= CHECK_EVERY_MS:
		_checked_ms = ms
		var kind := detect(player)
		if not kind.is_empty(): _last = {"at": now, "kind": kind, "text": TEXTS[kind]}
	if _last.is_empty() or now - float(_last.at) > FRESH_S or now < float(_last.at): return {}
	return _last

## "doorway", "ceiling", "branch", or "" when nothing is low over his head.
static func detect(player: Node3D) -> String:
	var world := player.get_world_3d()
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if space == null: return ""
	var eyes := player.global_position
	var crown := eyes + Vector3.UP * CROWN_ABOVE_EYES
	var ahead := -player.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized() if ahead.length_squared() > 0.0001 else Vector3.FORWARD
	var hit := _ray(space, eyes, crown + Vector3.UP * CLEARANCE)
	if hit.is_empty(): hit = _ray(space, crown, crown + ahead * LOOK_AHEAD)
	if hit.is_empty(): return ""
	var point: Vector3 = hit.position
	var tree := player.get_tree()
	if tree != null:
		for house: Node in tree.get_nodes_in_group("house_interiors"):
			var door: Variant = house.call("door") if house.has_method("door") else null
			if door is Node3D and Vector2((door as Node3D).global_position.x - point.x, (door as Node3D).global_position.z - point.z).length() < DOOR_M: return "doorway"
		if HOUSE.at(tree, point) != null: return "ceiling"
	return "branch"

## The first static hit between two points, skipping bodies that move (him, ponies).
static func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, WORLD_LAYER)
	query.collide_with_areas = false
	var skip: Array[RID] = []
	for _try in 3:
		query.exclude = skip
		var hit := space.intersect_ray(query)
		if hit.is_empty(): return {}
		var body: Variant = hit.get("collider")
		if body is CharacterBody3D or body is RigidBody3D:
			skip.append(hit.rid); continue
		return hit
	return {}

## Tests and world reloads.
static func reset() -> void:
	_checked_ms = -100000
	_last = {}
	_told = {}
