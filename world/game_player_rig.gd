extends RefCounted
## The player rig: XR, seated VR or desktop, its camera lookups, and the per-rig HUD, inventory, map, director and console.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const XR_PLAYER := preload("res://player/xr_player_physics.tscn")
const DESKTOP_PLAYER := preload("res://player/desktop_player.tscn")
const SEATED_PLAYER := preload("res://player/seated_player.tscn")
const LAUNCH_CONFIG := preload("res://world/launch_config.gd")
const AMBIENCE := preload("res://world/ambience.gd")
const INTERACTOR := preload("res://player/interactor.gd")
const DEV := preload("res://world/dev_tools.gd")
const SPECTATOR := preload("res://player/spectator_view.gd")
const DIRECTOR := preload("res://world/ai/conversation_director.gd")

var host: Node3D
## _find_camera(player) for callers asking every tick (timberwolves, forest soundscape): the
## subtree search is repeated only once the answer it gave can have changed.
var _eye_camera: Camera3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## The legacy default is a selector, never a shared runtime mirror. Explicit lab
## paths (including empty/in-memory) remain supported.
func _inventory_path() -> String:
	if host.inventory_save_path != "user://inventory/briefcase.json": return host.inventory_save_path
	return host.world_context.path.get_base_dir().path_join("inventory/briefcase.json")


func _spawn_player() -> void:
	host.headset_view = _try_start_xr()
	host.seated_vr = host.headset_view and LAUNCH_CONFIG.seated()
	host.xr_active = host.headset_view and not host.seated_vr
	host.player = (XR_PLAYER if host.xr_active else (SEATED_PLAYER if host.seated_vr else DESKTOP_PLAYER)).instantiate()
	host.add_child(host.player)
	host.player.global_position = host.spawn.global_position

	if host.headset_view:
		if host.xr_active:
			XRServer.world_scale = host.VR_PLAYER_SCALE
			# The visible body scales itself: anon_body.gd starts from world_scale
			# and then fits the model's eye height to the measured headset height.
		else:
			# Seated: the eye height comes from the rig (apply_scale below), not the room.
			XRServer.world_scale = 1.0
		Quality.set_xr_mode(true)
		# Sound goes to the headset. WiVRn exposes a PipeWire sink while a
		# headset is connected; the desktop default device is the speakers
		# (dev, headset round 2: "force the game to play through my headset").
		var devices := AudioServer.get_output_device_list()
		var routed := false
		for device in devices:
			if "wivrn" in String(device).to_lower():
				AudioServer.output_device = device
				routed = true
				print("[game] audio -> ", device)
				break
		if not routed and OS.get_name()=="Linux":
			print("[game] no WiVRn audio sink among ", devices)
	if not host.xr_active and host.player.has_method("apply_scale"):
		host.player.apply_scale(host.PLAYER_SCALE)
	if not host.xr_active:
		host.desktop_presentation = preload("res://player/desktop_anon.gd").new()
		host.desktop_presentation.name = "DesktopPresentation"; host.player.add_child(host.desktop_presentation)
		host.desktop_presentation.setup(_find_camera(host.player), host.player)
	if host.seated_vr:
		# Menus, hotbar and prompts on a floating screen; a gaze reticle / mouse dot to aim with.
		host.virtual_screen = preload("res://world/ui/virtual_screen.gd").new()
		host.virtual_screen.name = "VirtualScreen"; host.add_child(host.virtual_screen); host.virtual_screen.setup(host)
		var cursor: Node = preload("res://world/ui/headset_cursor.gd").new()
		cursor.name = "HeadsetCursor"; host.add_child(cursor); cursor.setup(host)

	# World outline removed (dev 2026-09-29: "world outline set to off and remove the option").
	# Pony ink is its own stencil pass; --style N still attaches the pass for the perf/lab paths.
	# No world ink, so no pony needs the passes that mask her out of it.
	preload("res://world/post_outline_exclusion.gd").enabled = false
	# Wind, birds, crickets and footsteps around whoever is listening.
	var ambience: Node3D = AMBIENCE.new()
	ambience.name = "Ambience"
	host.add_child(ambience)
	ambience.setup(host.player.get_node("Body") if host.xr_active else host.player, _find_camera(host.player))
	ambience.connect_stepper(host.player.find_child("AnonBody", true, false))
	host.flight_audio = preload("res://player/flight_audio.gd").new()
	host.flight_audio.name = "FlightAudio"; host.add_child(host.flight_audio); host.flight_audio.setup(host)
	var cam := _find_camera(host.player)
	if cam != null:
		var water_view := preload("res://world/water/player_water_view.gd").new()
		water_view.name = "PlayerWaterView"
		water_view.body = host.player.get_node("Body") if host.xr_active else host.player
		cam.add_child(water_view)
		var fps_debug:=preload("res://world/ui/debug_fps.gd").new()
		fps_debug.name="DebugFPS";host.add_child(fps_debug);fps_debug.setup(cam,host.xr_active)
		# Player builds leave the profiler out, also when the debug tools are unlocked.
		if DEV.enabled() and ResourceLoader.exists("res://world/debug/render_profiler.gd"):
			var render_profiler: Node = load("res://world/debug/render_profiler.gd").new()
			render_profiler.name = "RenderProfiler"; host.add_child(render_profiler)
			var measure: Node = load("res://world/debug/pony_measure.gd").new()
			measure.name = "PonyMeasure"; host.add_child(measure)
		# Performance capture (--perf-capture, world/performance/perf_capture.gd): nothing is made unless asked for.
		preload("res://world/performance/perf_capture.gd").install(host)
		var interactor: Node = INTERACTOR.new()
		cam.add_child(interactor)
		if host.xr_active:
			host.world_map = preload("res://world/ui/world_map_vr.gd").new(); host.add_child(host.world_map)
			host.world_map.setup(cam, host.player.find_child("XRControllerLeft", true, false),
				host.player.find_child("XRControllerRight", true, false), host.player.get_node("Body"))
		else:
			host.world_map = preload("res://world/ui/world_map_hud.gd").new(); host.add_child(host.world_map)
			host.world_map.bind(cam)
			host.world_map.expanded_changed.connect(func(open): host.player.controls_locked = open)
		host.inventory = preload("res://world/inventory/briefcase_inventory.gd").new()
		host.inventory.name = "BriefcaseInventory"
		host.add_child(host.inventory)
		host.inventory.setup(cam, host.player.get_node("Body") if host.xr_active else host.player,
			host.player.find_child("PhysicsHandLeft", true, false), host.player.find_child("PhysicsHandRight", true, false),
			host.player.find_child("XRControllerLeft", true, false), host.player.find_child("XRControllerRight", true, false), host.world_map, _inventory_path())
		host.inventory.setup_inspector(host.world_context)
		if not host.xr_active:
			host.inventory.desktop_presentation = host.desktop_presentation
			host.desktop_interactions = preload("res://player/desktop_interactions.gd").new()
			host.desktop_interactions.name = "DesktopInteractions"; host.add_child(host.desktop_interactions)
			host.desktop_interactions.setup(cam, host.player, host.inventory, interactor)
		# Candles in homes: a trigger press on a wick (VR) or E (desktop) lights them.
		var candle_lighter:=preload("res://world/props/candles/candle_lighter.gd").new()
		candle_lighter.inventory=host.inventory;candle_lighter.name="CandleLighter";host.add_child(candle_lighter)
		var lamp_switch:=preload("res://world/props/lamps/lamp_switch.gd").new()
		lamp_switch.inventory=host.inventory;lamp_switch.name="LampSwitch";host.add_child(lamp_switch)
		if host.xr_active:
			var door_grip:=preload("res://player/door_grip.gd").new()
			door_grip.inventory=host.inventory;door_grip.name="DoorGrip";host.add_child(door_grip)
	# The voice loop: mic -> STT -> character in earshot -> LLM -> TTS -> visemes.
	# AI usage "off" (Settings → AI) leaves the director out exactly like --no-ai.
	if "--no-ai" not in preload("res://world/dev_tools.gd").user_args() and preload("res://world/ai/ai_config.gd").ai_enabled():
		host.director = DIRECTOR.new()
		host.director.world_context=host.world_context
		if is_instance_valid(host.inventory): host.director.awareness.held_items = host.inventory.visible_held_items
		host.director.name = "ConversationDirector"
		host.add_child(host.director)
		host.director.setup(cam, host.xr_active, [host.player.find_child("XRControllerLeft", true, false),
			host.player.find_child("XRControllerRight", true, false)])
		if not host.xr_active:
			var chat := preload("res://world/ui/chat_box.gd").new()
			chat.name = "ChatBox"; host.add_child(chat); chat.setup(host.director, host.player, host.inventory)
		var freeze: Node = preload("res://world/ai/talk_freeze.gd").new()
		freeze.name = "TalkFreeze"; host.add_child(freeze)
		freeze.setup(host.director, host.get_node_or_null("ChatBox"), cam)
	# Always made: it answers ` and Settings > Debug only while the developer tools are on
	# (world/dev_tools.gd), so unlocking them in a player build works at once.
	var console: Node = load("res://world/debug/command_console.gd").new()
	console.name = "CommandConsole"; host.add_child(console); console.setup(host)
	# --spectator [1-4]: a second, smoothed/third-person window for recording.
	var args := preload("res://world/dev_tools.gd").user_args()
	if "--spectator" in args:
		var spectator: Node = SPECTATOR.new()
		spectator.name = "Spectator"
		var wanted: String = host._arg_value(args, "--spectator")
		if wanted.is_valid_int():
			spectator.mode = clampi(int(wanted), 1, 4)
		var size: String = host._arg_value(args, "--spectator-size")
		spectator.embed = not ("--spectator-separate" in args)
		if "x" in size:
			spectator.window_size = Vector2i(int(size.get_slice("x", 0)), int(size.get_slice("x", 1)))
		host.add_child(spectator)
		host._pending_spectator = spectator
		spectator.setup(cam, host.player.find_child("Body", true, false), null)

	print("[game] player rig: %s (scale %.2f)" % [
		"XR" if host.xr_active else ("seated VR" if host.seated_vr else "desktop"), host.PLAYER_SCALE])


func _player_eye_camera() -> Camera3D:
	var cached := _eye_camera
	if is_instance_valid(cached) and cached.is_inside_tree() and is_instance_valid(host.player) and host.player.is_ancestor_of(cached) \
			and (cached is XRCamera3D or (not host.xr_active and cached.current and cached.get_viewport() == host.get_viewport())):
		return cached
	_eye_camera = _search_camera(host.player) as Camera3D if is_instance_valid(host.player) else null
	return _eye_camera


## The player's real eye camera. The XR rig also carries a disabled cinematic-view
## camera ahead of the headset camera in tree order, so prefer the current camera,
## then an XRCamera3D, then any Camera3D.
## Perf 0.1.0: asked about the player rig itself (most of ~50 callers, some every tick) it answers
## from _player_eye_camera(), the same search's result kept while it is still that answer
## (in the rig, an XR camera or the viewport's current camera); a full search took ~10 us.
func _find_camera(node: Node) -> Node3D:
	if FIND_CAMERA_CACHE and node != null and node == host.player and is_instance_valid(node):
		var eye: Camera3D = _player_eye_camera()
		if eye != null: return eye
	return _search_camera(node)

const FIND_CAMERA_CACHE := true

func _search_camera(node: Node) -> Node3D:
	var cameras: Array[Node] = node.find_children("*", "Camera3D", true, false)
	if node is Camera3D:
		cameras.push_front(node)
	for c in cameras:
		if c is XRCamera3D:
			return c as Node3D
	for c in cameras:
		# "current" is per viewport: a camera inside a sub-window is current there too.
		if (c as Camera3D).current and c.get_viewport() == host.get_viewport():
			return c as Node3D
	if not cameras.is_empty():
		return cameras[0] as Node3D
	return null


## OpenXR failing is the normal case on this dev box (no headset attached), so
## it must degrade to the desktop rig rather than being treated as an error.
func _try_start_xr() -> bool:
	var iface := XRServer.find_interface("OpenXR")
	if iface == null or not iface.is_initialized():
		return false
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	host.get_viewport().use_xr = true
	return true
