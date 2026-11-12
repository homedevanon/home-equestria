extends Node
## Time stops while Anon talks (dev 2026-10-29): while he types in the chat box or speaks into
## the mic, the ponies he is talking with freeze, body and animation, so nopony walks off
## mid-sentence: his conversation partners (director engaged()) and the pony he faced as he began
## (director addressed_now()). Ponies merely passing walk on (player board #55: freezing every pony
## within RADIUS stopped passers-by wherever they were, and long chats left a crowd around him).
## A pony following him or busy with a command is never frozen (FREE_OWNERS): she walks up to him
## and waits there on her own.
## A second switch freezes the pony who is thinking up her answer (slow local models). A third
## adds a dark vignette and slowed audio while he talks. Settings → World.
## Freezing is the node's process_mode (world/life/luna_dream.gd does the same to the world):
## locomotion, skeleton modifiers, tail springs and her own voice all stop with it.

const KEY_TALK := "ai/freeze_while_talking"
const KEY_THINK := "ai/freeze_while_thinking"
const KEY_EFFECT := "ai/freeze_effect"
## Partners farther than this from the player's head are not frozen.
const RADIUS := 30.0
## Partners are looked up a few times a second, not every frame.
const REFRESH_SECONDS := 0.25
## Navigator owners whose pony may freeze: her own life, a chat or a day step. Anything else is a
## shared state machine outside her node (the spa, a minigame, a bed, a hoof in his hand, a kiss):
## frozen mid-step it would wait on her forever (dev 2026-10-29 evening: stuck after the spa
## bell, then "cant move or open my console or anything").
const FREE_OWNERS: Array[String] = ["life:", "social:", "day:", "chat:", "sleep:", "visit:", "lamp:"]
const EFFECT_SECONDS := 0.35
const VIGNETTE_AMOUNT := 0.55
const AUDIO_SPEED := 0.7

var director: Node
var chat: Node
var camera: Camera3D
var _frozen: Dictionary = {}   # node -> process_mode before the freeze
var _effect := 0.0
var _talking_before := false
var _addressed := ""
var _refresh := 0.0
var _talk_set: Dictionary = {}   # node -> true: partners in RADIUS at the last refresh
var _quad: MeshInstance3D
var _material: ShaderMaterial


func setup(conversation_director: Node, chat_box: Node, view: Camera3D) -> void:
	director = conversation_director
	chat = chat_box
	camera = view


func player_talking() -> bool:
	if is_instance_valid(chat) and chat.visible: return true
	if not is_instance_valid(director): return false
	if str(director.state) == "transcribing": return true
	var speech: Variant = director.get("speech")
	return is_instance_valid(speech) and str(speech.state) == "hearing"


func _process(delta: float) -> void:
	if not is_instance_valid(director):
		_thaw_all()
		_set_effect(0.0, delta)
		return
	var talking: bool = bool(Settings.get_value(KEY_TALK)) and player_talking()
	if talking and not _talking_before:
		_addressed = str(director.call("addressed_now")) if director.has_method("addressed_now") else ""
		_refresh = 0.0
	_talking_before = talking
	var wanted: Dictionary = {}
	if talking and is_instance_valid(camera):
		_refresh -= delta
		if _refresh <= 0.0:
			_refresh = REFRESH_SECONDS
			_talk_set = _talk_targets(camera.global_position)
		for node: Variant in _talk_set:
			if _freezable(node): wanted[node] = true
	elif not _talk_set.is_empty():
		_talk_set = {}
	if bool(Settings.get_value(KEY_THINK)) and str(director.state) == "thinking":
		var current: String = str(director.get("_current"))
		if director.characters.has(current):
			var node: Variant = director.characters[current].node
			if _freezable(node): wanted[node] = true
	for node: Variant in _frozen.keys():
		if not wanted.has(node): _thaw(node)
	for node: Variant in wanted:
		if not _frozen.has(node):
			_frozen[node] = node.process_mode
			node.process_mode = Node.PROCESS_MODE_DISABLED
	_set_effect(VIGNETTE_AMOUNT if talking and bool(Settings.get_value(KEY_EFFECT)) else 0.0, delta)


## His partners and the pony he addressed, within RADIUS of his head.
func _talk_targets(head: Vector3) -> Dictionary:
	var result := {}
	for id: String in director.characters:
		var node: Variant = director.characters[id].node
		if not is_instance_valid(node) or not (node is Node3D): continue
		if id != _addressed and not (director.has_method("engaged") and bool(director.call("engaged", id))): continue
		if (node as Node3D).global_position.distance_to(head) <= RADIUS: result[node] = true
	return result


## Nopony in his hands or in a shared activity (see FREE_OWNERS) freezes.
static func _freezable(node: Variant) -> bool:
	if not is_instance_valid(node) or not (node is Node3D) or not node.is_inside_tree(): return false
	if node.get("_held") == true or node.has_meta("spa_client"): return false
	if node.has_method("action_interruption_reason") and not str(node.action_interruption_reason()).is_empty(): return false
	var nav: Node = node.get_node_or_null("Navigator")
	if nav == null: return true
	var owner := str(nav.get("command_owner"))
	if owner.is_empty(): return true
	for prefix: String in FREE_OWNERS:
		if owner.begins_with(prefix): return true
	return false


func _thaw(node: Variant) -> void:
	if is_instance_valid(node): node.process_mode = int(_frozen[node])
	_frozen.erase(node)


func _thaw_all() -> void:
	for node: Variant in _frozen.keys(): _thaw(node)


func _set_effect(goal: float, delta: float) -> void:
	if is_zero_approx(_effect) and is_zero_approx(goal): return
	_effect = move_toward(_effect, goal, delta * VIGNETTE_AMOUNT / EFFECT_SECONDS)
	AudioServer.playback_speed_scale = lerpf(1.0, AUDIO_SPEED, _effect / VIGNETTE_AMOUNT)
	if is_zero_approx(_effect):
		_effect = 0.0
		if _quad != null: _quad.visible = false
		return
	if _quad == null: _build_quad()
	if _quad == null: return
	_quad.visible = true
	_material.set_shader_parameter("amount", _effect)


func _build_quad() -> void:
	if not is_instance_valid(camera): return
	_material = ShaderMaterial.new()
	_material.shader = preload("res://player/buck_vignette.gdshader")
	_material.render_priority = 126
	_quad = MeshInstance3D.new()
	_quad.name = "TalkFreezeVignette"
	var plane := QuadMesh.new(); plane.size = Vector2(0.9, 0.7)
	_quad.mesh = plane
	_quad.material_override = _material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.position = Vector3(0, 0, -0.12)
	camera.add_child(_quad)


func _exit_tree() -> void:
	_thaw_all()
	AudioServer.playback_speed_scale = 1.0
	if is_instance_valid(_quad): _quad.queue_free()
