extends Area3D
## One easel's proximity gate (docs/PAINTING_STATION_2026_10_22.md section 2). It never
## processes: its code runs from body_entered/body_exited and, only while the player is within
## 3 m, from the grab router and the hint poll (both every 0.08 s) through the two groups it joins
## then. The first grip on a tool or the canvas (VR), or E/click on the PaintPanel (desktop),
## loads the painting runtime by path; nothing here keeps the runtime's Script.
const RUNTIME := "res://world/painting/easel_runtime.gd"
const BUILD := preload("res://world/painting/easel_build.gd")
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const LEAVE_SECONDS := 2.0
const TOOL_REACH := 0.12
## Within this a tool or the canvas always wins over the easel body behind it (distance 0);
## an owned easel's whole frame is one grabbable item, so a reach for a tool must never fold it.
const PRIORITY_REACH := 0.12
const CANVAS_REACH := 0.08
const DESKTOP_REACH := 2.5
## A blank canvas held this close to an empty easel's canvas face goes up on it (M-ACT-03).
const MOUNT_REACH := 0.35
const LEDGER := "res://world/mechanics/ledger.gd"
const TOOLS := {"brush": "Hook_Brush", "pencil": "Hook_Pencil", "scraper": "Hook_Scraper"}
var easel: Node3D
var key := ""
var owned := false
var inventory: Node
var runtime: Node
var near := false
var _leave_serial := 0
var _hooks: Dictionary = {}
var _face := Transform3D.IDENTITY
var _half := Vector2.ZERO
var _panel: CollisionObject3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node) -> void:
	if not body is CollisionObject3D or ((body as CollisionObject3D).collision_layer & BUILD.PLAYER_LAYER) == 0: return
	if not is_instance_valid(inventory): inventory = _find_inventory()
	near = true; _leave_serial += 1
	cache_markers()
	add_to_group("grab_providers"); add_to_group("interaction_hint_sources")

func _on_body_exited(body: Node) -> void:
	if not body is CollisionObject3D or ((body as CollisionObject3D).collision_layer & BUILD.PLAYER_LAYER) == 0: return
	near = false
	_leave_groups()
	if is_instance_valid(runtime): _close_later()

func _close_later() -> void:
	_leave_serial += 1
	var serial := _leave_serial
	if not await SHUTDOWN.seconds(self, LEAVE_SECONDS): return
	if serial != _leave_serial or near: return
	if is_instance_valid(runtime): runtime.call("close", true)

func _leave_groups() -> void:
	if is_in_group("grab_providers"): remove_from_group("grab_providers")
	if is_in_group("interaction_hint_sources"): remove_from_group("interaction_hint_sources")

func _find_inventory() -> Node:
	var scene := get_tree().current_scene
	var found: Variant = scene.get("inventory") if scene != null else null
	return found as Node if found is Node and is_instance_valid(found) else null

## Hook, canvas and panel positions, read once on entry (and after the canvas turns).
func cache_markers() -> void:
	if not is_instance_valid(easel) or not easel.is_inside_tree(): return
	_hooks.clear()
	for tool: String in TOOLS:
		var hook := BUILD.marker(easel, TOOLS[tool])
		if hook != null: _hooks[tool] = hook.global_position
	var face := BUILD.canvas_face(easel)
	if face != null: _face = face.global_transform.orthonormalized()
	_half = (BUILD.FACE_SIZE.get(str(easel.get_meta("painting_orient", "P")), BUILD.FACE_SIZE.P) as Vector2) * 0.5
	_panel = easel.get_node_or_null("PaintPanel") as CollisionObject3D

## Loads the painting runtime (once) and returns it; null when it cannot load.
func begin(_side: String = "") -> Node:
	if is_instance_valid(runtime): return runtime
	if not is_instance_valid(easel) or not easel.is_inside_tree(): return null
	if not is_instance_valid(inventory): inventory = _find_inventory()
	if not is_instance_valid(inventory): return null
	if _hooks.is_empty(): cache_markers()
	var script := load(RUNTIME) as Script
	if script == null or not script.can_instantiate(): return null
	runtime = script.new()
	runtime.name = "PaintingRuntime"
	easel.add_child(runtime)
	runtime.call("setup", easel, self, key, inventory)
	return runtime

## E or a click on the PaintPanel (player/interactor.gd, briefcase_inventory.gd). On an emptied
## easel (bought canvases) E with a blank canvas in hand puts it up instead.
func desktop_begin() -> bool:
	if not is_instance_valid(inventory): inventory = _find_inventory()
	if not is_instance_valid(inventory): return false
	if bare():
		if held_canvas("desktop") != null: return mount_canvas_from_hand("desktop")
		_say("Put a blank canvas up on the easel first.")
		return false
	if inventory.hand_busy("desktop"): return false
	if not DESKTOP_OWNER.available(inventory): return false
	var started := begin("desktop")
	return started != null and bool(started.call("desktop_begin"))

## Folding or freeing the easel: bake and free the runtime now.
func shutdown_now() -> void:
	near = false
	_leave_serial += 1
	_leave_groups()
	if is_instance_valid(runtime): runtime.call("close", true)
	runtime = null

func runtime_closed(closed: Node) -> void:
	if runtime == closed: runtime = null

func _usable() -> bool:
	return near and is_instance_valid(inventory) and is_instance_valid(easel) and easel.is_inside_tree() and not get_tree().paused

## An owned easel waiting for a bought canvas (painting_registry.is_bare).
func bare() -> bool:
	return REGISTRY.is_bare(key)

## The blank canvas ("goods:canvas") in that hand, or null.
func held_canvas(side: String) -> Node3D:
	var held: Variant = inventory.get("held") if is_instance_valid(inventory) else null
	var item: Variant = (held as Dictionary).get(side) if held is Dictionary else null
	if not is_instance_valid(item) or not item is Node3D: return null
	return item as Node3D if str((item as Node3D).get_meta("item_id", "")) == REGISTRY.CANVAS_ITEM else null

## Puts the blank canvas in that hand up on this emptied easel: the canvas item is used up (the
## briefcase loan ends) and the easel shows a fresh canvas again. True when it went up.
func mount_canvas_from_hand(side: String) -> bool:
	if not bare() or not is_instance_valid(inventory): return false
	var item := held_canvas(side)
	if item == null: return false
	var store: Variant = inventory.get("inventory")
	var token := str(item.get_meta("token", ""))
	if not store is Object or not bool((store as Object).call("consume", token)): return false
	var held: Dictionary = inventory.get("held")
	held.erase(side)
	var loose: Variant = inventory.get("loose")
	if loose is Dictionary: (loose as Dictionary).erase(token)
	var track: Variant = inventory.get("_track")
	if track is Dictionary: (track as Dictionary).erase(side)
	if inventory.has_method("_claim"): inventory.call("_claim", side, false)
	item.queue_free()
	if inventory.has_method("_refresh_holding"): inventory.call("_refresh_holding")
	REGISTRY.set_bare(key, false)
	BUILD.refresh_canvas(easel)
	cache_markers()
	preload("res://world/audio/interaction_sounds.gd").play_event(easel, "prop_blanket", {"intensity": .4})
	return true

func _say(text: String) -> void:
	var ledger: Script = load(LEDGER) as Script
	if ledger != null and is_instance_valid(inventory): ledger.call("say", inventory, text)

func _blank() -> bool:
	if is_instance_valid(runtime): return not bool(runtime.call("has_paint"))
	return REGISTRY.wip(key).is_empty()

## VR: a free palm near a hanging tool or the canvas. The router picks the nearest offer.
func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not _usable() or not sample.get("active", false) or bare(): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var palm: Vector3 = sample.get("grip_position", pose.origin)
	if not palm.is_finite(): return {}
	var best := {}
	var gap := INF
	for tool: String in _hooks:
		if is_instance_valid(runtime) and bool(runtime.call("is_held", tool)): continue
		var distance := palm.distance_to(_hooks[tool])
		if distance < TOOL_REACH and distance < gap:
			gap = distance
			best = {"target": _tool_target(tool), "point": _hooks[tool], "text": side.capitalize() + " grip · Take " + tool,
				"kind": "tool", "tool": tool, "distance": 0.0 if distance < PRIORITY_REACH else distance}
	var local := _face.affine_inverse() * palm
	if absf(local.z) < CANVAS_REACH and absf(local.x) < _half.x + CANVAS_REACH and absf(local.y) < _half.y + CANVAS_REACH:
		var distance := absf(local.z)
		if distance < gap:
			best = {"target": easel.get_node_or_null("Canvas"), "point": _face.origin, "kind": "canvas",
				"text": side.capitalize() + " grip · " + ("Turn canvas" if _blank() else "Take painting off"),
				"distance": 0.0 if distance < CANVAS_REACH else distance}
	return best if is_instance_valid(best.get("target")) else {}

func grab_take(side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	var live := begin(side)
	if live == null: return false
	if str(offer.get("kind", "")) == "canvas": return bool(live.call("canvas_grip", side))
	return bool(live.call("take_tool", side, str(offer.get("tool", "brush"))))

func _tool_target(tool: String) -> Node3D:
	if is_instance_valid(runtime):
		var live: Variant = runtime.call("tool_node", tool)
		if live is Node3D: return live
	return BUILD.marker(easel, "HookedTools")

## Desktop, near and not yet painting: looking at the easel offers E. An emptied easel (bought
## canvases): VR puts a blank canvas up as soon as a hand holds one to the frame; desktop offers
## E with a canvas in hand. Polled only while the player is within WAKE_RADIUS.
func interaction_hint() -> Dictionary:
	if not _usable(): return {}
	if bare() and not bool(inventory.get("_desktop")):
		for side: String in ["left", "right"]:
			var canvas := held_canvas(side)
			if canvas != null and canvas.global_position.distance_to(_face.origin) <= MOUNT_REACH: mount_canvas_from_hand(side)
		return {}
	if not bool(inventory.get("_desktop")): return {}
	if bare():
		if DESKTOP_OWNER.current(inventory) != null or held_canvas("desktop") == null: return {}
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return {}
		var at := panel_hit(inventory)
		if at.is_empty(): return {}
		return {"target": easel, "text": "[E] Put up the blank canvas", "point": at.position, "collider": at.collider}
	if DESKTOP_OWNER.current(inventory) != null or inventory.hand_busy("desktop"): return {}
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return {}
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return {}
	var hit := panel_hit(inventory)
	if hit.is_empty(): return {}
	return {"target": easel.get_node_or_null("Canvas"), "text": "[E] Paint", "point": hit.position, "collider": hit.collider}

## The camera ray (2.5 m, world layer) when it lands on this easel's PaintPanel (or another
## collider of this easel, such as the station's frame).
func panel_hit(ui: Node) -> Dictionary:
	var camera: Camera3D = ui.get("camera") as Camera3D
	if camera == null or not is_instance_valid(_panel): return {}
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, camera.global_position - camera.global_basis.z * DESKTOP_REACH, 1)
	var body: Variant = ui.get("player_body")
	if body is CollisionObject3D: query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return {}
	var collider: Variant = hit.collider
	if collider == _panel: return hit
	return hit if collider is Node and is_instance_valid(collider) and (collider as Node).has_meta("painting_easel") and (collider as Node).get_meta("painting_easel") == self else {}
