extends SceneTree

var checks := 0
var failures := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("CONVERSATION_QUIET_FAIL ", label)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var fixture := GDScript.new()
	fixture.source_code = """
extends "res://world/ai/conversation_director.gd"
static var clock := 1000.0
var reactions: Array[String] = []
static func _now() -> float: return clock
func _ready() -> void:
	set_process(false)
	set_physics_process(false)
	_awareness_wait = INF
func _earshot(_id: String) -> float: return 5.0
func _on_physical_reaction(kind: String, id: String, _deferred := false, _summary := "") -> void:
	reactions.append(kind + ":" + id)
func elapse(seconds: float) -> void:
	clock += seconds
	_physics_step(seconds)
"""
	if fixture.reload() != OK:
		printerr("Conversation director fixture failed to load")
		quit(1)
		return
	var director: Node = fixture.new()
	root.add_child(director)
	director.player_head = Node3D.new()
	director.add_child(director.player_head)
	# Leave the real input node outside the tree so the test never opens a microphone.
	var mic: Node = load("res://world/ai/speech_input.gd").new()
	director.speech = mic
	mic.state = "listening"
	mic._available = true
	var pony := Node3D.new()
	director.add_child(pony)
	var entry := {"node":pony, "chat_last":director._now(), "lull_after":15.0}
	director.characters.starlight_glimmer = entry

	# Starlight answered first. Others used the shared channel for another 20 seconds.
	director.group.members.assign(["starlight_glimmer", "cloudchaser"])
	director._current = "cloudchaser"
	director.state = "speaking"
	director.elapse(16.0)
	director.state = "group_gap"
	director.elapse(4.0)
	director.state = "idle"
	director.elapse(1.0)
	director.group.clear()
	director.elapse(14.0)
	check(director.reactions.is_empty(), "another speaker's turn leaves a full response window")
	director.elapse(1.0)
	check(director.reactions == ["quiet:starlight_glimmer"], "a genuine pause still permits a contribution")

	director.reactions.clear()
	director._holds._lull_next_at = -INF
	entry.chat_last = director._now()
	entry.lull_after = 15.0
	director.elapse(14.0)
	mic._interrupt_held = true
	director.elapse(2.0)
	check(director.reactions.is_empty(), "PTT takes the floor before any audio arrives")
	mic._interrupt_held = false
	mic.state = "hearing"
	director.elapse(3.0)
	mic.state = "muted"
	director.state = "transcribing"
	director.elapse(10.0)
	# Empty/failed STT returns to idle without adding any player words.
	director.state = "idle"
	mic.state = "listening"
	director.elapse(14.0)
	check(director.reactions.is_empty() and entry.get("lull_used") != entry.chat_last,
		"speech input restarts the response window without consuming the lull")
	director.elapse(1.0)
	check(director.reactions == ["quiet:starlight_glimmer"], "idle listening allows a later genuine lull")

	# A held utterance takes priority even in the frame before processing resumes.
	entry.chat_last = director._now()
	entry.lull_after = 15.0
	director._holds._lull_next_at = -INF
	director.reactions.clear()
	director.elapse(14.0)
	director._held_utterance = [PackedByteArray(), 1.0, false]
	director.elapse(2.0)
	director._held_utterance.clear()
	director.elapse(1.0)
	check(director.reactions.is_empty(), "a queued utterance keeps its turn")
	director.state = "thinking"
	director.elapse(280.0)
	director.state = "rendering"
	director.elapse(12.0)
	director.state = "idle"
	director.elapse(1.0)
	check(director.reactions.is_empty(), "a long voice turn does not trigger a quiet goodbye on completion")
	director.elapse(1.0)
	director.reactions.clear()
	entry.chat_last = director._now()
	entry.lull_used = entry.chat_last
	director.elapse(301.0)
	check(director.reactions == ["farewell:starlight_glimmer"], "five minutes of actual quiet still allows a goodbye")
	mic.free()
	director.free()
	print("CONVERSATION_QUIET_DONE checks=", checks, " failures=", failures)
	quit(1 if failures else 0)
