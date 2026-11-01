extends SceneTree
## Run against the source project or an export containing the fix, with an isolated
## XDG_DATA_HOME containing "private-notes-test". No model or microphone is used.
var CONTROLS: Script
var DIRECTOR: Script
var SCHEMA: Script
var GROUP: Script
var TTS: Script
var MEMORY: Script
var failures := 0
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	print("PRIVATE_NOTES ", "PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func run() -> void:
	if not OS.get_environment("XDG_DATA_HOME").contains("private-notes-test"):
		printerr("PRIVATE_NOTES_REFUSED: use an isolated XDG_DATA_HOME")
		quit(1); return
	# External --script files parse before autoloads mount the exported update packs.
	CONTROLS = load("res://world/ai/speech_controls.gd")
	DIRECTOR = load("res://world/ai/conversation_director.gd")
	SCHEMA = load("res://world/ai/pony_action_schema.gd")
	GROUP = load("res://world/ai/pony_group_conversation.gd")
	TTS = load("res://world/ai/tts_client.gd")
	MEMORY = load("res://world/ai/memory/story_memory.gd")
	var cases := [
		["<brain>WANT pinkie_pie: keep a secret.</brain>Hello!", "Hello!", "normal block"],
		["WANT: private plan.\nELSEWHERE: private event.\nNEXT: private plan.\nDONE: settled.\n</brain>Let's find a book!", "Let's find a book!", "observed missing opener shape"],
		["WANT: private plan.\n</brain>", "", "notes without any dialogue"],
		["Hello! <brain>private unfinished note", "Hello!", "unclosed block"],
		["<brain>private unfinished note", "", "unclosed notes only"],
		["< BRAIN >private note</ BRAIN >Hello!", "Hello!", "case and whitespace"],
		["<brain mode='private'>secret</brain>Hello!", "Hello!", "tag attributes"],
		["<story>private note</story>Hello!", "Hello!", "legacy story block"],
		["private note</ STORY >Hello!", "Hello!", "orphan story closer"],
		["<brain>outer<story>nested</story>outer</brain>Hello!", "Hello!", "nested blocks"],
		["<brain>first</brain>Hello!<story>second</story> Goodbye!", "Hello! Goodbye!", "multiple blocks preserve dialogue"],
		["Hello!<brain/> Goodbye!", "Hello! Goodbye!", "empty block"],
		["Hello!<brain", "Hello!", "partial opener"],
		["private note</brain", "", "partial orphan closer"],
		["Let's use our brains and find a book.", "Let's use our brains and find a book.", "ordinary dialogue preserved"],
		["The book says WANT: a new beginning.", "The book says WANT: a new beginning.", "labels without note delimiters preserved"],
		["[brain]WANT: find a book.\nNEXT: read it.[/brain]Hello!", "Hello!", "square brain wrappers"],
		["private note[/brain]Hello!", "Hello!", "square orphan closer"],
		["<brain>private note[/brain]Hello!", "Hello!", "mixed wrapper styles"],
		["[story]private note[/story]Hello!", "Hello!", "square story wrappers"],
		["WANT: find a book.\nELSEWHERE: a shop closes.\nNEXT: choose a book.\nDONE: lunch.\nHello!", "Hello!", "bare director block"],
		["Hello!\nWANT luna: find a book.\nNEXT: choose a book.", "Hello!", "bare notes after speech with pony id"],
		["luna: WANT: find a book.\nluna: NEXT: choose a book.\nluna: Hello!", "luna: Hello!", "speaker-prefixed bare notes"],
		["NEXT: turn left at the gate.", "NEXT: turn left at the gate.", "single label stays speech"],
	]
	var director: Node = DIRECTOR.new()
	director.set("_current", "pinkie_pie")
	director.set("characters", {"pinkie_pie": {"profile": {"name": "Pinkie Pie"}}})
	director.set("_tag_regex", RegEx.create_from_string(DIRECTOR.EMOTION_TAG))
	var tts: Node = TTS.new()
	for row: Array in cases:
		check(CONTROLS.without_private_notes(row[0]) == row[1], row[2])
		check(director.take_story_notes(row[0], false) == row[1], row[2] + " without database")
		check(tts.spoken_text(row[0]) == row[1], row[2] + " final voice boundary")
	check(tts.voice_text("[happy] <brain>secret</brain>Hello!") == "[happy] Hello!", "MOSS emotion survives")
	check(director.clean_reply("[happy] secret</brain>Hello!") == "Hello!", "orphan prefix stays private in final cleaner")
	var context := {"actor_id": "pinkie_pie", "capabilities": ["look_at", "follow"], "targets": {"player": {}}}
	var text: String = director.take_story_notes("<brain>WANT: secret [follow: player]</brain>Hello! [look_at: player]", false)
	var decoded: Dictionary = SCHEMA.decode(text, "pinkie_pie", 1, context, true)
	check(not decoded.has("error") and decoded.actions.size() == 1 and decoded.actions[0].type == "look_at", "private action tags never reach execution")
	var group: RefCounted = GROUP.new()
	group.members.append("pinkie_pie")
	text = director.take_story_notes("WANT: private plan.\n</brain>\npinkie_pie: Hello! [look_at: player]", true)
	decoded = group.decode(text, 1, {"pinkie_pie": context}, true)
	check(not decoded.has("error") and decoded.get("beats", []).size() == 1 and decoded.beats[0].speech == "Hello!", "group parser receives speech after orphan closer")
	# Retain normal journal behavior: valid private notes still get stored.
	var memory: RefCounted = MEMORY.new()
	check(memory.open("user://private-notes.sqlite"), "synthetic story database opens")
	var script := GDScript.new()
	script.source_code = "extends Node\nvar story: RefCounted\n"
	check(script.reload() == OK, "synthetic world loads")
	var world := Node.new()
	world.set_script(script)
	world.set("story", memory)
	director.set("world_context", world)
	text = director.take_story_notes("<brain>WANT pinkie_pie: find a library book.</brain>Hello!", false)
	var notes: Array = memory.store._rows("SELECT kind FROM lines WHERE kind = 'brain';")
	check(text == "Hello!" and notes.size() == 1, "valid notes stored privately and speech preserved")
	text = director.take_story_notes("WANT: private plan.</brain>Hello!", false)
	check(text == "Hello!", "orphan closer also suppressed with database open")
	memory.store.close()
	director.free(); tts.free(); world.free()
	print("PRIVATE_NOTES_DONE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
