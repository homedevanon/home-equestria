extends RefCounted
## One observed event per pickup, including desktop and independent VR hands.
var elapsed := 0.0
var start := Vector3.ZERO
var head_start := Vector3.ZERO
var active := false
var sent := false
## Struggling out of an unwanted hold (carry_struggle.gd); ticked here, before the event below.
var struggle := preload("res://world/characters/locomotion/carry_struggle.gd").new()
func update(actor: Node3D, delta: float) -> void:
	var wants_down: bool = struggle.update(actor, delta)
	if not actor.get("_held"):
		active = false; elapsed = 0.0; sent = false
		return
	# She wants down, so the "enjoy being held" event does not fit her: it is not sent.
	if wants_down: sent = true
	var camera: Camera3D = preload("res://world/player_view.gd").camera(actor)
	var head: Vector3 = camera.global_position if camera != null else actor.global_position
	if not active:
		active = true; start = actor.global_position; head_start = head
	elapsed += delta
	if sent: return
	var moved: bool = Vector2(head.x-head_start.x, head.z-head_start.z).length() >= 1.5 and actor.global_position.distance_to(start) >= 1.5
	if elapsed >= 5.0 or moved:
		sent = true
		actor.emit_signal("physical_reaction", "carried_away" if moved else "carried")
