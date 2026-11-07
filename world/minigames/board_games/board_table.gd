extends Node3D
## The game table in Golden Oak's library, by the fireplace (dev 2026-10-26: "add a checker and
## chess board games at Twilight's ... play the game with ponies that will be AI controlled to
## play and give comments with each move"). golden_oak/interior.gd builds the furniture and puts
## this node on the table top; it owns the board, the pieces you see, and who sits across.
##
## Anon starts a game here: E (desktop) opens the board view (board_view.gd), where he picks the
## game and whom to ask; in VR a grip on the board asks the nearest pony for chess, on the box of
## checkers for checkers. The invitation reaches her as a moment to answer in her own words; she
## comes and sits across unless she turns him down ([board_game: no]). A pony can also set a game
## up herself ([board_game: chess], the model's call) and then waits here for him. The game in
## progress is board_session.gd, loaded by path when one starts. A game left unfinished with her
## (board_adjourned.gd) waits on the board when she sits down: it goes on where it stood, or, in
## the board view, Anon chooses between it and a new one.
const MODELS := preload("res://world/minigames/board_games/board_models.gd")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const HOUSE := preload("res://world/buildings/house_interior.gd")
const ADJOURNED := preload("res://world/minigames/board_games/board_adjourned.gd")
const SESSION := "res://world/minigames/board_games/board_session.gd"
const VIEW := "res://world/minigames/board_games/board_view.gd"
const PLAYERS := "res://world/minigames/board_games/board_players.json"
const GROUP := "board_tables"
const PLAYER_LAYER := 2048
const WAKE_RADIUS := 2.6
const DESKTOP_REACH := 2.6
## A pony this close (or anywhere in the same house) can be asked, or set a game up herself.
const INVITE_RANGE := 16.0
## Waiting for her answer before she comes anyway; walking over; waiting for Anon after she set
## the board up herself; staying seated after a game for another.
const ANSWER_SECONDS := 30.0
const COMING_SECONDS := 80.0
const WAIT_SECONDS := 150.0
const LINGER_SECONDS := 45.0
## Anon this far from the table (flat) this long ends the game.
const AWAY_METRES := 6.0
const AWAY_SECONDS := 25.0
## A VR hand within this of a piece can pick it up.
const PIECE_REACH := 0.07
## She is on her cushion within this (flat); a navigator that stops within the second is close enough.
const SEAT_REACH := 0.3
const SEAT_FALLBACK := 0.7
const VR_DROP_RANGE := 0.12
signal changed

## What holds this board: Golden Oak's interior, or the folding board's item (board_fold.gd).
var house: Node3D
## Where it is, in words for her: "at the little game table by the fireplace in the library".
var place_words := "at the little game table by the fireplace in the library"
## The play collider over the board (E there plays): its size, and its middle's height.
var body_size := Vector3(0.84, 0.05, 0.68)
var body_lift := -0.016
var player_seat: Node3D
var pony_seat: Node3D
var board: Node3D
var pieces: Node3D
var checkers_box: Node3D
var gaze_point: Node3D
var status_label: Label3D
## "chess" or "checkers": the game on the board.
var game := "chess"
var session: Node
var view: Node
## The pony at (or on her way to) the table: {id, key, name, actor, nav, token, previous, wander,
## speed, pace, gaze, state ("coming" / "seated"), game, by ("player" / "pony"), since}.
var opponent: Dictionary = {}
## Waiting for her answer to Anon's invitation: {id, key, name, actor, game, line_key, until, declined}.
var invite: Dictionary = {}
## What happened last, for the view and the VR label ("Twilight turned you down").
var notice := ""
var inventory: Node
var near := false
var _piece_nodes: Dictionary = {}
var _away := 0.0
var _clock := 0.0
var _players: Dictionary = {}
## Anon's side per pony, swapped every game with her: id -> 1 (moves first) or -1.
var _sides: Dictionary = {}
## VR hands holding a piece: side -> {square, node, home}.
var _held: Dictionary = {}
var _body: StaticBody3D

## `seat_near` is Anon's cushion seat (room side, +Z of this node), `seat_far` hers.
func setup(frame: Node3D, seat_near: Node3D, seat_far: Node3D) -> void:
	house = frame
	player_seat = seat_near
	pony_seat = seat_far
	add_to_group(GROUP)
	board = Node3D.new(); board.name = "Board"
	# This node is the table top; the board lies on it, playing surface up (it once sank into the
	# table and its squares flickered through the top, dev 2026-10-26 screenshot).
	board.position.y = MODELS.LIFT
	add_child(board)
	MODELS.build_board(board)
	pieces = Node3D.new(); pieces.name = "Pieces"
	board.add_child(pieces)
	_body = StaticBody3D.new(); _body.name = "BoardBody"
	_body.collision_layer = 1; _body.collision_mask = 0
	var shape := CollisionShape3D.new(); var box := BoxShape3D.new()
	# The whole table top, so looking at any of it offers the game.
	box.size = body_size
	shape.shape = box; shape.position.y = body_lift
	_body.add_child(shape); add_child(_body)
	_body.set_meta("board_table", self)
	_build_checkers_box()
	gaze_point = Node3D.new(); gaze_point.name = "GazePoint"; gaze_point.position = Vector3(0, 0.08, 0)
	add_child(gaze_point)
	status_label = Label3D.new(); status_label.name = "Status"
	status_label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	status_label.font_size = 40; status_label.pixel_size = 0.0011; status_label.outline_size = 10
	status_label.position = Vector3(0, 0.55, -0.15)
	status_label.no_depth_test = true; status_label.hide()
	add_child(status_label)
	var wake := Area3D.new(); wake.name = "Wake"
	wake.collision_layer = 0; wake.collision_mask = PLAYER_LAYER
	wake.monitorable = false; wake.monitoring = true
	var sphere := SphereShape3D.new(); sphere.radius = WAKE_RADIUS
	var holder := CollisionShape3D.new(); holder.shape = sphere
	wake.add_child(holder); wake.position = Vector3(0, 0.3, 0)
	add_child(wake)
	wake.body_entered.connect(_on_body_entered)
	wake.body_exited.connect(_on_body_exited)
	show_position("chess", _start_position("chess"))
	set_physics_process(false)

## A small open wooden box of checkers at the table's corner (a VR grip there asks for checkers).
func _build_checkers_box() -> void:
	checkers_box = Node3D.new(); checkers_box.name = "CheckersBox"
	checkers_box.position = Vector3(MODELS.half_size() + 0.075, 0.0, -0.24)
	add_child(checkers_box)
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color("6b3b28"); wood.roughness = 0.7
	for part: Array in [[Vector3(0.11, 0.012, 0.13), Vector3(0, 0.006, 0)], [Vector3(0.11, 0.03, 0.008), Vector3(0, 0.015, 0.061)],
			[Vector3(0.11, 0.03, 0.008), Vector3(0, 0.015, -0.061)], [Vector3(0.008, 0.03, 0.13), Vector3(0.051, 0.015, 0)], [Vector3(0.008, 0.03, 0.13), Vector3(-0.051, 0.015, 0)]]:
		var side := MeshInstance3D.new(); var mesh := BoxMesh.new(); mesh.size = part[0]
		side.mesh = mesh; side.material_override = wood; side.position = part[1]
		checkers_box.add_child(side)
	for i in 6:
		var disc := MeshInstance3D.new()
		disc.mesh = MODELS.piece_mesh("checkers", 1)
		disc.material_override = MODELS.piece_material("checkers", 1 if i < 3 else -1)
		disc.position = Vector3(-0.025 if i < 3 else 0.025, 0.012 + (i % 3) * MODELS.SQUARE * 0.13, -0.02 + (i % 2) * 0.03)
		checkers_box.add_child(disc)

# ------------------------------------------------------------------ the pieces you see

static func _start_position(game_name: String) -> PackedInt32Array:
	var rules: RefCounted = load("res://world/minigames/board_games/%s_rules.gd" % game_name).new()
	return rules.board

## Lays the board out: `position` from the rules, `taken` the pieces each side has captured
## ({1: [kinds], -1: [kinds]}), lined up beside the board on the capturer's right.
func show_position(game_name: String, position: PackedInt32Array, taken: Dictionary = {}) -> void:
	game = game_name
	# Freed at the end of the frame, still in the tree until then: a fading magic glow that follows
	# a piece (magic_aura.gd) then finds it gone rather than detached.
	for node: Node in pieces.get_children():
		if not node.is_queued_for_deletion(): node.queue_free()
	_piece_nodes.clear()
	for sq in 64:
		if position[sq] != 0: _piece_nodes[sq] = _piece(game_name, position[sq], MODELS.square_position(sq))
	for owner: int in [1, -1]:
		var kinds: Array = taken.get(owner, [])
		for i in kinds.size():
			var victim := -owner * int(kinds[i])
			var x := (MODELS.half_size() + 0.03 + (i % 2) * 0.042) * owner
			var z := (0.19 - (i / 2) * 0.044) * owner
			var node := _piece(game_name, victim, Vector3(x, -MODELS.LIFT, z))
			node.scale = Vector3.ONE * 0.8
			node.name = "Taken"

func _piece(game_name: String, piece: int, at: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = MODELS.piece_mesh(game_name, absi(piece))
	node.material_override = MODELS.piece_material(game_name, signi(piece))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = at
	node.set_meta("height", MODELS.piece_height(game_name, absi(piece)))
	# Knights look at the other player.
	node.rotation.y = PI if piece > 0 else 0.0
	pieces.add_child(node)
	return node

func piece_node(sq: int) -> MeshInstance3D:
	var node: Variant = _piece_nodes.get(sq)
	return node as MeshInstance3D if is_instance_valid(node) else null

## Turns the board so Anon's pieces are on his side (+Z faces his cushion).
func face_board(player_side: int) -> void:
	board.rotation.y = 0.0 if player_side == 1 else PI

## A world point on the playing surface -> square (in board terms), or -1.
func square_at_world(point: Vector3) -> int:
	return MODELS.square_at(board.to_local(point))

func square_world(sq: int) -> Vector3:
	return board.to_global(MODELS.square_position(sq))

# ------------------------------------------------------------------ who can play

func _players_data() -> Dictionary:
	if _players.is_empty():
		var file := FileAccess.open(PLAYERS, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
		_players = parsed if parsed is Dictionary else {"default": {"chess": 2, "checkers": 2}, "ponies": {}}
	return _players

## {"chess": level, "checkers": level} for a pony id.
func skill(id: String) -> Dictionary:
	var data := _players_data()
	var row: Dictionary = (data.get("default", {}) as Dictionary).duplicate()
	row.merge(data.get("ponies", {}).get(id, {}), true)
	return row

## Her playing style (board_players.json "styles", board_engine.gd), or {} for none.
func style_of(id: String) -> Dictionary:
	var name := str(skill(id).get("style", ""))
	var styles: Variant = _players_data().get("styles", {})
	return (styles as Dictionary).get(name, {}) if styles is Dictionary else {}

static func pony_id(actor: Node) -> String:
	var identity: Variant = actor.get("identity") if is_instance_valid(actor) else null
	return str(identity.get("id")) if identity is Resource else ""

static func pony_name(actor: Node) -> String:
	var identity: Variant = actor.get("identity") if is_instance_valid(actor) else null
	var named: Variant = identity.get("display_name") if identity is Resource else null
	return str(named) if named != null and str(named) != "" else pony_id(actor).capitalize()

func _house() -> Node3D:
	return HOUSE.at(get_tree(), global_position)

func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## A pony who could come and play: awake, free, nearby (or in this house), with legs to walk.
func can_play(actor: Node3D) -> bool:
	if not is_instance_valid(actor) or not actor.is_inside_tree() or actor.get_node_or_null("Navigator") == null: return false
	if actor.get("sleeping") == true or actor.get("_held") == true or pony_id(actor) == "": return false
	if actor.has_meta("fishing_companion") or actor.has_meta("balloon_passenger"): return false
	var flight: Variant = actor.get("flight")
	if flight is Object and is_instance_valid(flight) and flight.has_method("active") and flight.active(): return false
	if absf(actor.global_position.y - global_position.y) > 3.0 and HOUSE.at(get_tree(), actor.global_position) != _house(): return false
	return _flat(actor.global_position, global_position) < INVITE_RANGE or (HOUSE.at(get_tree(), actor.global_position) == _house() and _house() != null)

## Ponies Anon could ask, nearest first: [{actor, id, name}].
func candidates() -> Array:
	var out: Array = []
	for pony: Node in get_tree().get_nodes_in_group("sim_ponies"):
		var actor := pony as Node3D
		if not can_play(actor): continue
		if not opponent.is_empty() and opponent.actor == actor: continue
		out.append({"actor": actor, "id": pony_id(actor), "name": pony_name(actor), "distance": actor.global_position.distance_to(global_position)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.distance) < float(b.distance))
	return out

## For the action menu (pony_action_executor.gd capabilities): she is near enough to set a game up
## or is playing here.
func available_to(actor: Node3D) -> bool:
	if not opponent.is_empty() and opponent.actor == actor: return true
	return can_play(actor)

# ------------------------------------------------------------------ the director

func _director() -> Node:
	return get_tree().get_first_node_in_group("conversation_director")

## Her key in the conversation director, or "".
func director_key(actor: Node) -> String:
	var director := _director()
	var cast: Variant = director.get("characters") if director != null else null
	if not cast is Dictionary: return ""
	for key: String in cast:
		if (cast as Dictionary)[key].get("node") == actor: return key
	return ""

# ------------------------------------------------------------------ inviting and coming over

## Anon asks `actor` to play `game_name`. "" when asked, else why not.
func ask(actor: Node3D, game_name: String) -> String:
	if session != null and is_instance_valid(session) and not bool(session.call("is_over")): return "A game is already going"
	if not can_play(actor): return "%s can't come right now" % pony_name(actor)
	if not opponent.is_empty() and opponent.actor == actor:
		opponent.game = game_name
		game = game_name
		_show_waiting(game_name)
		_begin_if_ready()
		return ""
	var director := _director()
	var key := director_key(actor)
	notice = ""
	if director == null or key == "" or not director.has_method("queue_generated_intent"):
		_summon(actor, game_name, "player")
		return ""
	var line_key := "board-invite:%d:%d" % [get_instance_id(), Time.get_ticks_msec()]
	invite = {"id": pony_id(actor), "key": key, "name": pony_name(actor), "actor": actor, "game": game_name, "line_key": line_key,
		"until": _clock + ANSWER_SECONDS, "declined": false}
	director.queue_generated_intent(key, ("Anon is %s and asks you to play %s with him. It is your choice: answer him in your own words, "
		+ "as you really feel about it right now. If you say yes, add [board_game: %s] and come over to sit down and play; to turn him down, add [board_game: no].") % [place_words, game_name, game_name],
		line_key, func() -> bool: return invite.get("line_key", "") == line_key,
		func() -> void: _invite_answered(line_key), true)
	changed.emit()
	return ""

func _invite_answered(line_key: String) -> void:
	# Her [board_game: no] commits only once her line is spoken; give it a moment to land.
	await get_tree().create_timer(1.2).timeout
	if invite.get("line_key", "") != line_key: return
	var asked: Dictionary = invite
	invite = {}
	if bool(asked.declined): return
	if is_instance_valid(asked.actor): _summon(asked.actor, str(asked.game), "player")
	changed.emit()

## She comes to the table and sits across from Anon's place.
func _summon(actor: Node3D, game_name: String, by: String) -> bool:
	if not opponent.is_empty():
		if opponent.actor == actor:
			opponent.game = game_name
			if by == "player": opponent.by = "player"
			_begin_if_ready()
			return true
		if session != null and is_instance_valid(session) and not bool(session.call("is_over")): return false
		release_opponent("another pony took the seat")
	var nav: Node = actor.get_node_or_null("Navigator")
	if nav == null: return false
	var id := pony_id(actor)
	var token := "leisure:board:%d:%s" % [get_instance_id(), id]
	opponent = {"id": id, "key": director_key(actor), "name": pony_name(actor), "actor": actor, "nav": nav, "token": token,
		"previous": nav.command_owner, "wander": nav.wander_enabled, "speed": nav.command_speed_limit, "pace": nav.get("command_pace_target"),
		"gaze": nav.face_point, "state": "coming", "game": game_name, "by": by, "since": _clock}
	nav.stay()
	nav.command_owner = token
	nav.command_speed_limit = INF
	if "command_pace_target" in nav: nav.command_pace_target = -1.0
	nav.face_point = Vector3.INF
	actor.set_meta("board_game_player", token)
	pony_seat.set_meta("occupant", actor)
	if not _walk_to_seat():
		release_opponent("%s could not find a way to the table" % opponent.name)
		return false
	game = game_name
	if session == null or not is_instance_valid(session): _show_waiting(game_name)
	set_physics_process(true)
	changed.emit()
	return true

## Walks her onto her cushion. (The seating service counts 0.6 m as there, for benches she hops
## onto; on a floor cushion that would sit her beside it.)
func _walk_to_seat() -> bool:
	var nav: Node = opponent.nav
	var target := pony_seat.global_position
	var goal: Vector3 = nav.command_support(target) if nav.has_method("command_support") else target
	if not goal.is_finite(): goal = target
	opponent.walk_at = _clock
	return bool(nav.command_destination(goal, "walk"))

func _owned() -> bool:
	return not opponent.is_empty() and is_instance_valid(opponent.actor) and is_instance_valid(opponent.nav) and opponent.nav.command_owner == opponent.token

## She gets up and goes back to her day. `why` shows in the view.
func release_opponent(why := "") -> void:
	if opponent.is_empty(): return
	var actor: Node3D = opponent.actor if is_instance_valid(opponent.actor) else null
	if why != "": notice = why
	if _owned():
		var nav: Node = opponent.nav
		nav.stay()
		# Back to her routine. Whatever else owned her walk when she came (a follow or approach
		# from a reply) was cancelled by taking it: its owner restored would leave her held by a
		# command nothing runs any more, and the living world would keep waiting on it.
		var previous := str(opponent.previous)
		nav.command_owner = previous if previous.begins_with("life:") else ""
		nav.wander_enabled = opponent.wander
		nav.command_speed_limit = opponent.speed
		if "command_pace_target" in nav and opponent.pace != null: nav.command_pace_target = opponent.pace
		nav.face_point = opponent.gaze
		var game_root: Node = get_tree().current_scene
		var life: Node = game_root.get("life") as Node if game_root != null else null
		if is_instance_valid(life) and life.get("actors") is Dictionary and life.actors.has(opponent.id): life.actors[opponent.id].goal = Vector3.INF
	if actor != null:
		if actor.get_meta("board_game_player", "") == opponent.token: actor.remove_meta("board_game_player")
		if pony_seat.get_meta("occupant", null) == actor: pony_seat.remove_meta("occupant")
		if actor.get("action_gaze_target") == gaze_point and actor.has_method("set_action_gaze"): actor.set_action_gaze(null)
		if actor.has_method("request_posture") and actor.has_method("posture_status") and str(actor.posture_status().get("kind", "")) == "sit":
			actor.request_posture("stand")
	opponent = {}
	# A finished game goes with her; the view falls back to the notice and asking somepony.
	if session != null and is_instance_valid(session) and bool(session.call("is_over")): session.call("close")
	changed.emit()

## A reason she can no longer play, or "".
func _lost_reason() -> String:
	if opponent.is_empty(): return ""
	var actor: Variant = opponent.actor
	if not is_instance_valid(actor) or not (actor as Node).is_inside_tree(): return "%s is gone" % opponent.name
	if not _owned(): return "%s went off to do something else" % opponent.name
	if actor.get("_held") == true: return "%s was picked up" % opponent.name
	if actor.get("sleeping") == true: return "%s fell asleep" % opponent.name
	return ""

## On her cushion, turned to the board and sitting (asked for here, one step at a time).
func _seated() -> bool:
	if opponent.is_empty(): return false
	var actor: Node3D = opponent.actor
	var nav: Node = opponent.nav
	var off := _flat(actor.global_position, pony_seat.global_position)
	var walking: bool = nav.get("_has_target") == true
	if off > SEAT_REACH and off < 1.1 and walking and not opponent.has("overshoot"):
		# The navigator stops ~0.3 m short of its goal: on the last stretch aim a little past the
		# cushion, so she ends up on it.
		var on := pony_seat.global_position - actor.global_position
		on.y = 0.0
		opponent.overshoot = true
		nav.command_destination(pony_seat.global_position + on.normalized() * 0.28, "walk")
		opponent.walk_at = _clock
		return false
	if off > SEAT_REACH:
		# Stopped short: close enough after a moment, else ask again.
		if walking or _clock - float(opponent.get("walk_at", 0.0)) < 2.5: return false
		if off > SEAT_FALLBACK:
			_walk_to_seat()
			return false
	if walking: nav.stay()
	if str(actor.posture_status().get("kind", "")) == "sit": return true
	if not opponent.has("arrived_at"): opponent.arrived_at = _clock
	var facing := -pony_seat.global_basis.z
	var ahead := -actor.global_basis.z
	ahead.y = 0.0
	if actor.has_method("face_direction") and ahead.normalized().dot(facing) < 0.985 and _clock - float(opponent.arrived_at) < 4.0:
		actor.face_direction(facing)
		return false
	actor.request_posture("sit")
	return false

## A game starts once she sits and Anon is here: at once when he asked her, on his E/grip when she
## set it up herself. With a game of theirs left unfinished, the open board view asks him first.
func _begin_if_ready() -> void:
	if opponent.is_empty() or opponent.state != "seated": return
	if session != null and is_instance_valid(session) and not bool(session.call("is_over")): return
	if is_instance_valid(view) and has_unfinished(str(opponent.game)):
		changed.emit()
		return
	if opponent.by == "player" and (is_instance_valid(view) or near): start_game(str(opponent.game))

## A game with the pony at the table: the one they left unfinished, or with `fresh` (or none left)
## a new one, for which Anon's side swaps every game with the same pony.
func start_game(game_name: String, fresh := false) -> bool:
	if opponent.is_empty() or opponent.state != "seated": return false
	if session != null and is_instance_valid(session): session.call("close")
	var earlier: Dictionary = {} if fresh else ADJOURNED.game_of(str(opponent.id), game_name)
	if fresh: ADJOURNED.drop(str(opponent.id), game_name)
	var side: int = int(earlier.side) if not earlier.is_empty() else -int(_sides.get(opponent.id, -1))
	_sides[opponent.id] = side
	var level_row := skill(str(opponent.id))
	var script := load(SESSION) as Script
	if script == null: return false
	session = script.new()
	session.name = "BoardSession"
	add_child(session)
	game = game_name
	opponent.game = game_name
	opponent.by = "player"
	face_board(side)
	session.call("setup", self, game_name, side, {"id": opponent.id, "key": opponent.key, "name": opponent.name, "actor": opponent.actor,
		"level": int(level_row.get(game_name, 2)), "style": style_of(str(opponent.id))}, earlier)
	session.connect("finished", _on_finished)
	notice = ""
	changed.emit()
	return true

## A game of `game_name` with the pony at the table, left unfinished.
func has_unfinished(game_name: String, pony := "") -> bool:
	if pony == "": pony = str(opponent.get("id", ""))
	return pony != "" and not ADJOURNED.game_of(pony, game_name).is_empty()

## The board as she sits down: their unfinished game where it stood, else the opening position.
func _show_waiting(game_name: String) -> void:
	var row := ADJOURNED.game_of(str(opponent.get("id", "")), game_name)
	var script := load(SESSION) as Script
	var then: Dictionary = script.call("replay", game_name, row.moves) if not row.is_empty() and script != null else {}
	if then.is_empty():
		show_position(game_name, _start_position(game_name))
		return
	face_board(int(row.side))
	show_position(game_name, (then.rules as RefCounted).get("board"), then.taken)

func session_closed(closed: Node) -> void:
	if session == closed: session = null
	changed.emit()

func _on_finished() -> void:
	opponent["since"] = _clock
	changed.emit()

# ------------------------------------------------------------------ the model's own moves

## [board_game: chess / checkers / resign / stop / no] in her reply (pony_action_executor.gd).
func model_action(executor: Node, action: Dictionary) -> void:
	var actor: Node3D = executor.get("actor") as Node3D
	var what := str(action.get("game", "chess"))
	var mine: bool = not opponent.is_empty() and opponent.actor == actor
	match what:
		"no":
			if not invite.is_empty() and invite.actor == actor:
				invite.declined = true
				notice = "%s would rather not play right now" % invite.name
				changed.emit()
				executor._report(action, "completed", "You turned him down")
			elif mine and (session == null or not is_instance_valid(session)):
				release_opponent("%s changed her mind" % opponent.name)
				executor._report(action, "completed", "You left the table")
			else: executor._report(action, "failed", "Nopony asked you to play")
		"resign":
			if mine and session != null and is_instance_valid(session) and not bool(session.call("is_over")):
				session.call("resign", -int(session.get("player_side")))
				executor._report(action, "completed", "You resigned the game")
			else: executor._report(action, "failed", "You are not playing a game")
		"stop":
			if mine:
				if session != null and is_instance_valid(session) and not bool(session.call("is_over")): session.call("abandon", "%s put the game away" % opponent.name)
				release_opponent("%s put the game away" % opponent.name)
				executor._report(action, "completed", "You put the board away")
			else: executor._report(action, "failed", "You are not at the game table")
		_:
			if session != null and is_instance_valid(session) and not bool(session.call("is_over")) and not mine:
				executor._report(action, "failed", "Somepony is already playing there")
				return
			# Her yes to Anon's invitation: he asked, so the game starts once she sits.
			var asked: bool = not invite.is_empty() and invite.actor == actor
			if asked: invite = {}
			if mine and session != null and is_instance_valid(session) and not bool(session.call("is_over")):
				executor._report(action, "completed", "You are already playing")
				return
			var by := "player" if asked or (mine and opponent.by == "player") else "pony"
			if _summon(actor, what, by): executor._report(action, "accepted", "Going to the game table to play %s with Anon" % what)
			else: executor._report(action, "failed", "Cannot get to the game table")

# ------------------------------------------------------------------ every tick while someone is here

func _physics_process(delta: float) -> void:
	_clock += delta
	_poll_near()
	if not invite.is_empty() and (_clock > float(invite.until) or not is_instance_valid(invite.actor)):
		var asked: Dictionary = invite
		invite = {}
		if not bool(asked.declined) and is_instance_valid(asked.actor): _summon(asked.actor, str(asked.game), "player")
	if not opponent.is_empty():
		var why := _lost_reason()
		if why != "":
			if session != null and is_instance_valid(session) and not bool(session.call("is_over")): session.call("abandon", why)
			release_opponent(why)
		elif opponent.state == "coming":
			if _seated():
				opponent.state = "seated"
				opponent.since = _clock
				if opponent.actor.has_method("set_action_gaze"): opponent.actor.set_action_gaze(gaze_point)
				changed.emit()
				_begin_if_ready()
			elif _clock - float(opponent.since) > COMING_SECONDS: release_opponent("%s couldn't get to the table" % opponent.name)
		else:
			var playing: bool = session != null and is_instance_valid(session) and not bool(session.call("is_over"))
			var waited := _clock - float(opponent.since)
			if not playing and not is_instance_valid(view) and waited > (WAIT_SECONDS if opponent.by == "pony" and session == null else LINGER_SECONDS):
				release_opponent()
	_check_away(delta)
	_tick_held()
	_update_label()
	if opponent.is_empty() and invite.is_empty() and _held.is_empty() and (session == null or not is_instance_valid(session)) and not near: set_physics_process(false)

## Anon walking off ends a game he left running.
func _check_away(delta: float) -> void:
	var playing: bool = session != null and is_instance_valid(session) and not bool(session.call("is_over"))
	var feet := _player_feet()
	if not playing or not feet.is_finite() or _flat(feet, global_position) < AWAY_METRES:
		_away = 0.0
		return
	_away += delta
	if _away > AWAY_SECONDS:
		_away = 0.0
		session.call("abandon", "Anon walked away from the game")
		release_opponent()

func _player_feet() -> Vector3:
	if not is_instance_valid(inventory): inventory = _find_inventory()
	var body: Variant = inventory.get("player_body") if is_instance_valid(inventory) else null
	return (body as Node3D).global_position if body is Node3D else Vector3.INF

func _find_inventory() -> Node:
	var scene := get_tree().current_scene
	var found: Variant = scene.get("inventory") if scene != null else null
	return found as Node if found is Node and is_instance_valid(found) else null

## The wake area only wakes the table; whether Anon is near is his distance, polled while awake:
## sitting down on his cushion turns his collider off, which the area reads as leaving.
func _on_body_entered(body: Node) -> void:
	if not body is CollisionObject3D or ((body as CollisionObject3D).collision_layer & PLAYER_LAYER) == 0: return
	if not is_instance_valid(inventory): inventory = _find_inventory()
	_set_near(true)
	set_physics_process(true)

func _on_body_exited(body: Node) -> void:
	if not body is CollisionObject3D or ((body as CollisionObject3D).collision_layer & PLAYER_LAYER) == 0: return
	set_physics_process(true)

func _poll_near() -> void:
	var feet := _player_feet()
	_set_near(feet.is_finite() and _flat(feet, global_position) < WAKE_RADIUS + 0.3 and absf(feet.y - global_position.y) < 2.0)

func _set_near(value: bool) -> void:
	if near == value: return
	near = value
	if near:
		add_to_group("interaction_hint_sources"); add_to_group("grab_providers")
		_begin_if_ready()
		return
	if is_in_group("interaction_hint_sources"): remove_from_group("interaction_hint_sources")
	if is_in_group("grab_providers"): remove_from_group("grab_providers")
	for side: String in _held.keys(): _drop_held(side, false)

# ------------------------------------------------------------------ what it says

## One line for the view and the VR label.
func status_text() -> String:
	if session != null and is_instance_valid(session): return str(session.call("status_text"))
	if not invite.is_empty(): return "Asking %s…" % invite.name
	if not opponent.is_empty():
		if opponent.state == "coming": return "%s is coming to play %s" % [opponent.name, opponent.game]
		return "%s is waiting to play %s" % [opponent.name, opponent.game]
	return notice

func _update_label() -> void:
	var vr := is_instance_valid(inventory) and not bool(inventory.get("_desktop"))
	var text := status_text() if vr and near else ""
	status_label.visible = text != ""
	if text != "" and status_label.text != text: status_label.text = text

# ------------------------------------------------------------------ desktop

func _desktop_ready() -> bool:
	if not near or not is_instance_valid(inventory) or not bool(inventory.get("_desktop")): return false
	if _headset(): return false
	if DESKTOP_OWNER.current(inventory) != null or inventory.hand_busy("desktop"): return false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or get_tree().paused: return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	return not (focus is LineEdit or focus is TextEdit)

## A headset on the desktop rig (seated VR with keyboard and mouse): no camera of our own there.
func _headset() -> bool:
	var root := get_tree().current_scene
	return root != null and bool(root.get("headset_view"))

## The camera ray landing on this table's board or top.
func _looked_at() -> Dictionary:
	var camera: Camera3D = inventory.get("camera") as Camera3D
	if camera == null: return {}
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, camera.global_position - camera.global_basis.z * DESKTOP_REACH, 1)
	var body: Variant = inventory.get("player_body")
	if body is CollisionObject3D: query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit.collider is Node) or not (hit.collider as Node).has_meta("board_table") or (hit.collider as Node).get_meta("board_table") != self: return {}
	return hit

func interaction_hint() -> Dictionary:
	if not _desktop_ready(): return {}
	var hit := _looked_at()
	if hit.is_empty(): return {}
	var text := "[E] Play chess or checkers"
	if session != null and is_instance_valid(session) and not bool(session.call("is_over")): text = "[E] Back to the game"
	elif not opponent.is_empty() and opponent.state == "seated":
		text = ("[E] Finish your %s game with %s" if has_unfinished(str(opponent.game)) else "[E] Play %s with %s") % [opponent.game, opponent.name]
	return {"target": board, "text": text, "point": hit.position, "collider": hit.collider, "outline": null}

## E or a click on the table (player/interactor.gd): the board view.
func desktop_begin() -> bool:
	if not near or not is_instance_valid(inventory) or not bool(inventory.get("_desktop")) or _headset(): return false
	if is_instance_valid(view): return true
	if not DESKTOP_OWNER.available(inventory): return false
	var script := load(VIEW) as Script
	if script == null: return false
	view = script.new()
	view.name = "BoardView"
	add_child(view)
	if not bool(view.call("open", self, inventory)):
		view.queue_free(); view = null
		return false
	if not opponent.is_empty() and opponent.state == "seated" and (session == null or not is_instance_valid(session)) and not has_unfinished(str(opponent.game)):
		start_game(str(opponent.game))
	set_physics_process(true)
	return true

func view_closed(closed: Node) -> void:
	if view == closed: view = null
	if not opponent.is_empty(): opponent.since = _clock

# ------------------------------------------------------------------ VR hands

func _usable_vr() -> bool:
	return near and is_instance_valid(inventory) and not bool(inventory.get("_desktop")) and not get_tree().paused

func grab_offer(side: String, sample: Dictionary) -> Dictionary:
	if not _usable_vr() or _held.has(side) or not sample.get("active", false): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var palm: Vector3 = sample.get("grip_position", pose.origin)
	if not palm.is_finite(): return {}
	var local := board.to_local(palm)
	var on_board := absf(local.x) < MODELS.half_size() + 0.03 and absf(local.z) < MODELS.half_size() + 0.03 and local.y > -0.03 and local.y < 0.16
	var playing: bool = session != null and is_instance_valid(session) and not bool(session.call("is_over"))
	if playing:
		# One piece in hand at a time: a move rebuilds the board, which would free the other.
		if not bool(session.call("player_to_move")) or not _held.is_empty(): return {}
		var best := -1
		var gap := PIECE_REACH
		for sq: int in _piece_nodes:
			var piece: int = session.get("rules").board[sq]
			if piece * int(session.get("player_side")) <= 0: continue
			var node: Node3D = piece_node(sq)
			if node == null: continue
			var d := palm.distance_to(node.global_position + Vector3.UP * MODELS.SQUARE * 0.5)
			if d < gap: gap = d; best = sq
		if best < 0: return {}
		return {"target": piece_node(best), "point": piece_node(best).global_position, "text": side.capitalize() + " grip · Move", "kind": "piece", "square": best, "distance": gap}
	var near_box := palm.distance_to(checkers_box.global_position + Vector3.UP * 0.03) < 0.1
	if not on_board and not near_box: return {}
	var want := "checkers" if near_box else "chess"
	if not opponent.is_empty():
		if opponent.state != "seated": return {}
		return {"target": checkers_box if near_box else board, "point": palm, "text": side.capitalize() + " grip · Play %s with %s" % [want, opponent.name],
			"kind": "start", "game": want, "distance": 0.05, "outline": null}
	if not invite.is_empty(): return {}
	var who := candidates()
	if who.is_empty(): return {}
	return {"target": checkers_box if near_box else board, "point": palm, "text": side.capitalize() + " grip · Ask %s to play %s" % [who[0].name, want],
		"kind": "ask", "game": want, "actor": who[0].actor, "distance": 0.05, "outline": null}

func grab_take(side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	match str(offer.get("kind", "")):
		"piece":
			var sq := int(offer.square)
			var node := piece_node(sq)
			if node == null: return false
			var hand: Node = inventory.hands.get(side)
			if is_instance_valid(hand): hand.set_meta("inventory_busy", true)
			_held[side] = {"square": sq, "node": node, "home": node.global_transform}
			node.top_level = true
			if inventory.has_method("_haptic"): inventory._haptic(side)
			set_physics_process(true)
			return true
		"start":
			return start_game(str(offer.game))
		"ask":
			return ask(offer.actor, str(offer.game)) == ""
	return false

func _tick_held() -> void:
	for side: String in _held.keys():
		var row: Dictionary = _held[side]
		# Checked before typing: a rebuilt board may have freed it.
		var held_node: Variant = row.get("node")
		var sample: Dictionary = inventory.hand_sample(side) if is_instance_valid(inventory) else {}
		var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
		var palm: Vector3 = sample.get("grip_position", pose.origin)
		if not is_instance_valid(held_node) or not sample.get("active", false) or not palm.is_finite():
			_drop_held(side, false); continue
		var node := held_node as Node3D
		if float(sample.get("grip", 0.0)) < 0.25:
			_drop_held(side, true); continue
		node.global_position = palm - Vector3.UP * MODELS.SQUARE * 0.4

## Lets go of a piece: on a square it may move to, that is his move; anywhere else it goes back.
func _drop_held(side: String, place: bool) -> void:
	var row: Dictionary = _held.get(side, {})
	_held.erase(side)
	var hand: Node = inventory.hands.get(side) if is_instance_valid(inventory) else null
	if is_instance_valid(hand): hand.remove_meta("inventory_busy")
	var held_node: Variant = row.get("node")
	if not is_instance_valid(held_node): return
	var node := held_node as Node3D
	var moved := false
	if place and session != null and is_instance_valid(session):
		var local := board.to_local(node.global_position)
		var to := MODELS.square_at(local)
		var from := int(row.square)
		# Its own square counts only for a checkers king's ring of jumps that ends where it began.
		if to >= 0 and local.y < VR_DROP_RANGE and (to != from or (session.call("targets_from", from) as PackedInt32Array).has(from)):
			moved = str(session.call("player_move", from, to)) == ""
	if not moved:
		if session != null and is_instance_valid(session): session.call("refresh")
		else: show_position(game, _start_position(game))

func _exit_tree() -> void:
	for side: String in _held.keys(): _drop_held(side, false)
	if session != null and is_instance_valid(session): session.call("abandon", "")
	release_opponent()
