extends Node
## One game at the library table (board_table.gd): the rules, whose turn it is, the pony's
## thinking (board_engine.gd on a worker thread), the pieces moving, and her words about it.
## After each of her moves she may say something in her own voice: the model gets what just
## happened (his move, hers, how the game stands) and only "Stay in character." for how to act
## (dev 2026-10-26: telling her how to comment, and her "way at the board", made Twilight explain
## every move); she also speaks when the game starts and when it ends. A unicorn moves her
## pieces in her magic, glowing in her colour. Every move is kept (board_adjourned.gd) until the
## game ends with a result, so one left unfinished is taken up again later, replayed move by move.
##
## A match (setup_match, dev 2026-11-07: "make two ponies play and have us as a spectator that can
## still talk in the chat; the two adversaries can also talk between them"): both sides are ponies,
## each with her own level and style, thinking a little longer than against Anon so he can follow.
## They talk between themselves in short pony-to-pony exchanges (the director's ambient group, one
## model call for the whole exchange) as the game starts, after a move worth a word and at the end;
## the next move waits while its pony is still speaking. What Anon says or types reaches them as
## any conversation does, their prompts knowing the game and that he is watching. A match is not
## kept to finish later and is not one of Anon's shared activities.
signal finished
const MODELS := preload("res://world/minigames/board_games/board_models.gd")
const ENGINE := preload("res://world/minigames/board_games/board_engine.gd")
const MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const CHESS := preload("res://world/minigames/board_games/chess_rules.gd")
const ADJOURNED := preload("res://world/minigames/board_games/board_adjourned.gd")
const SIDE_NAMES := {"chess": {1: "white", -1: "black"}, "checkers": {1: "red", -1: "white"}}
## Her shortest think, so a quick engine still looks like a pony thinking.
const MIN_THINK := Vector2(1.4, 3.2)
const STEP_SECONDS := 0.32
const MAGIC_STEP_SECONDS := 0.55
const ARC := 0.05
const MAGIC_ARC := 0.12
## A match: each pony's think, the least time between two of their exchanges, how long a start or
## end exchange keeps trying for a free moment, and the longest a move waits for their talk.
const MATCH_THINK := Vector2(3.5, 8.0)
const TALK_GAP := 22.0
const TALK_TRY := 20.0
const TALK_HOLD := 25.0

var table: Node3D
var game := "chess"
var rules: RefCounted
## Anon's side: 1 moves first (white / red), -1 second; 0 in a match, where he only watches.
var player_side := 1
var opponent: Dictionary = {}
## Who plays each side: {1: who, -1: who}, {} for Anon. In a match both are ponies.
var players: Dictionary = {1: {}, -1: {}}
## Each side's last move as rules.describe gives it (plus "score" for a pony's).
var _last_by := {1: {}, -1: {}}
## A match: an exchange waiting for a free moment {request, first, until}, and when they last talked.
var _talk_pending: Dictionary = {}
var _talk_at := -1e9
var _held_since := -1
## {"over": true, "winner": 1/-1/0, "reason"} once the game has ended, else {}.
var result: Dictionary = {}
var notation: PackedStringArray = []
var last_move: Variant = null
## Pieces each side has taken: {1: [kinds], -1: [kinds]}.
var taken := {1: [], -1: []}
var thinking := false
var animating := false
var _engine: RefCounted
var _task := -1
var _think_until := 0
var _anim: Array = []
var _glow: Array = []
var _her_last := {}
var _his_last := {}
var _score_before := 0
var _line_key := ""
var _ply := 0
## The moves played (move_key), the ones from before it was set aside included.
var moves_made: Array = []
## Taken up again from an unfinished game.
var resumed := false
## Her last search's score (her view), kept with the moves.
var _score := 0

## `earlier`: the unfinished game to take up (board_adjourned.gd game_of), else a new one.
func setup(p_table: Node3D, p_game: String, side: int, who: Dictionary, earlier: Dictionary = {}) -> void:
	table = p_table
	game = p_game
	player_side = side
	opponent = who
	players = {side: {}, -side: who}
	rules = load("res://world/minigames/board_games/%s_rules.gd" % game).new()
	var keys: Array = earlier.get("moves", [])
	if not keys.is_empty():
		var then := replay(game, keys)
		if then.is_empty(): push_warning("Board game: the unfinished %s game no longer fits the rules; a new one starts" % game)
		elif bool(then.rules.status().get("over", false)):
			# Kept as its last move was played (saved or left during that move): it was decided.
			ADJOURNED.drop(str(who.get("id", "")), game)
		else:
			rules = then.rules; notation = then.notation; taken = then.taken; last_move = then.last
			moves_made = keys.duplicate(true); _ply = keys.size(); _score = int(earlier.get("score", 0)); resumed = true
	refresh()
	_say_start()
	set_process(true)
	if not player_to_move(): _start_thinking()
	else: _changed()

## Two ponies play each other, Anon watching: `p_players` {1: who, -1: who}, each like setup's
## `who` ({id, key, name, actor, level, style}). A match always starts new.
func setup_match(p_table: Node3D, p_game: String, p_players: Dictionary) -> void:
	table = p_table
	game = p_game
	player_side = 0
	players = p_players
	opponent = players[-1]
	rules = load("res://world/minigames/board_games/%s_rules.gd" % game).new()
	refresh()
	_look_at_board()
	_queue_talk(_match_start_request(), 1)
	set_process(true)
	_start_thinking()

func is_match() -> bool:
	return player_side == 0

## Who plays `side`: {} for Anon.
func who(side: int) -> Dictionary:
	return players.get(side, {})

func is_over() -> bool:
	return not result.is_empty()

func player_to_move() -> bool:
	return result.is_empty() and not thinking and not animating and int(rules.side) == player_side

func refresh() -> void:
	if is_instance_valid(table): table.call("show_position", game, rules.board, taken)

func side_name(side: int) -> String:
	return str(SIDE_NAMES[game].get(side, ""))

# ------------------------------------------------------------------ Anon's moves

## Squares his piece on `sq` may go to (empty when it is not his turn or his piece).
func targets_from(sq: int) -> PackedInt32Array:
	if not player_to_move() or int(rules.board[sq]) * player_side <= 0: return PackedInt32Array()
	return rules.targets_from(sq)

func promotes(from: int, to: int) -> bool:
	return bool(rules.promotes(from, to))

## His move from `from` to `to` (promoting to `promo` in chess, queen when 0). "" when made.
func player_move(from: int, to: int, promo := 0) -> String:
	if not player_to_move(): return "Not your turn"
	var move: Variant = rules.find_move(from, to, promo)
	if move == null or (move is int and int(move) < 0) or (move is Dictionary and (move as Dictionary).is_empty()): return "That move isn't allowed"
	_his_last = rules.describe(move)
	_last_by[player_side] = _his_last
	_play(move, false)
	return ""

# ------------------------------------------------------------------ her moves

func _start_thinking() -> void:
	thinking = true
	var mover := who(int(rules.side))
	_score_before = int((_last_by[int(rules.side)] as Dictionary).get("score", _score if not is_match() else 0))
	_engine = ENGINE.new(rules, game, int(mover.get("level", 2)), mover.get("style", {}))
	_task = WorkerThreadPool.add_task(_engine.think, false, "board game move")
	var pause := randf_range(MIN_THINK.x, MIN_THINK.y) if not is_match() else randf_range(MATCH_THINK.x, MATCH_THINK.y)
	if game == "chess" and _ply < 4: pause *= 0.6
	_think_until = Time.get_ticks_msec() + int(pause * 1000.0)
	_look_at_board()
	_changed()

func _process(delta: float) -> void:
	if is_match(): _try_talk()
	if thinking and _task >= 0 and WorkerThreadPool.is_task_completed(_task) and Time.get_ticks_msec() >= _think_until and not _talk_holds():
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		thinking = false
		var move: Variant = _engine.result
		var info: Dictionary = _engine.info
		_engine = null
		if move == null: _end_if_over(); return
		var said: Dictionary = rules.describe(move)
		said["score"] = int(info.get("score", 0))
		said["best_score"] = int(info.get("best_score", 0))
		_last_by[int(rules.side)] = said
		if not is_match():
			_her_last = said
			_score = int(said.score)
		_play(move, true)
	if animating: _step_animation(delta)

## A match: her move waits while she is still speaking, or while the two of them are in the
## middle of an exchange (at most TALK_HOLD past her think).
func _talk_holds() -> bool:
	if not is_match(): return false
	var mover: Variant = who(int(rules.side)).get("actor")
	if is_instance_valid(mover) and (mover as Node).has_method("is_speaking") and bool((mover as Node).call("is_speaking")):
		if _held_since < 0: _held_since = Time.get_ticks_msec()
		return Time.get_ticks_msec() - _held_since < int(TALK_HOLD * 1000.0)
	var director := _director()
	var group: Variant = director.get("group") if director != null else null
	var talking: bool = group is Object and bool((group as Object).call("active")) and str(who(int(rules.side)).get("key", "")) in (group as Object).get("members")
	if not talking:
		_held_since = -1
		return false
	if _held_since < 0: _held_since = Time.get_ticks_msec()
	return Time.get_ticks_msec() - _held_since < int(TALK_HOLD * 1000.0)

## Plays `move` on the rules and starts the pieces moving.
func _play(move: Variant, hers: bool) -> void:
	var path: PackedInt32Array = PackedInt32Array([rules.from_sq(move), rules.to_sq(move)])
	if game == "checkers": path = (move as Dictionary).path
	var removed := captures(game, rules, move)
	var mover := int(rules.side)
	var castle_rook := []
	if game == "chess" and CHESS.flags(move) & CHESS.CASTLE:
		var to: int = rules.to_sq(move)
		castle_rook = [to + 1 if to & 7 == 6 else to - 2, to - 1 if to & 7 == 6 else to + 1]
	notation.append(str((_last_by[mover] as Dictionary).get("san", "")))
	last_move = move
	_ply += 1
	for row: Array in removed: (taken[mover] as Array).append(int(row[1]))
	_animate(path, removed, castle_rook, who(mover).get("actor") if hers else null)
	moves_made.append(move_key(game, move))
	rules.make(move)
	# A move that ends the game leaves nothing to take up later, even while it is still moving
	# (a save or a walk away then); _end_if_over() gives the result once it lands. A match is never kept.
	var clock := get_node_or_null("/root/TimeOfDay")
	if is_match(): pass
	elif bool(rules.status().get("over", false)): ADJOURNED.drop(str(opponent.get("id", "")), game)
	else: ADJOURNED.keep(str(opponent.get("id", "")), game, player_side, moves_made, _score, int(clock.get("day")) if clock != null else 0)
	# Her prompt: the board after this move, like the move list (the pieces are still on their way).
	_update_context()

# ------------------------------------------------------------------ kept moves, played again

## What board_adjourned.gd keeps of `move`: chess [from, to, promotion], checkers the squares landed on.
static func move_key(game_name: String, move: Variant) -> Array:
	if game_name == "checkers": return Array((move as Dictionary).path)
	return [CHESS.from_sq(move), CHESS.to_sq(move), CHESS.promotion(move)]

## The legal move on `rules` that `key` names, or null.
static func move_of(game_name: String, rules_now: RefCounted, key: Array) -> Variant:
	if game_name == "chess":
		var found: int = rules_now.find_move(int(key[0]), int(key[1]), int(key[2]) if key.size() > 2 else 0)
		return found if found >= 0 and CHESS.promotion(found) == (int(key[2]) if key.size() > 2 else 0) else null
	var path := PackedInt32Array(key)
	for move: Dictionary in rules_now.moves():
		if move.path == path: return move
	return null

## The pieces `move` takes, before it is made: [[square, kind], ...].
static func captures(game_name: String, rules_now: RefCounted, move: Variant) -> Array:
	var removed: Array = []
	if game_name == "checkers":
		for sq: int in (move as Dictionary).taken: removed.append([sq, absi(int(rules_now.board[sq]))])
		return removed
	var to: int = rules_now.to_sq(move)
	var victim_sq := to - 8 * int(rules_now.side) if CHESS.flags(move) & CHESS.EN_PASSANT else to
	if rules_now.board[victim_sq] != 0: removed.append([victim_sq, absi(int(rules_now.board[victim_sq]))])
	return removed

## The game after `keys` on new rules: {rules, notation, taken, last}, or {} when a move no longer
## fits (the rules changed since the game was kept).
static func replay(game_name: String, keys: Array) -> Dictionary:
	var rules_now: RefCounted = load("res://world/minigames/board_games/%s_rules.gd" % game_name).new()
	var moves_said: PackedStringArray = []
	var lost := {1: [], -1: []}
	var last: Variant = null
	for key: Variant in keys:
		var move: Variant = move_of(game_name, rules_now, key) if key is Array else null
		if move == null: return {}
		moves_said.append(str(rules_now.describe(move).get("san", "")))
		for row: Array in captures(game_name, rules_now, move): (lost[int(rules_now.side)] as Array).append(int(row[1]))
		rules_now.make(move)
		last = move
	return {"rules": rules_now, "notation": moves_said, "taken": lost, "last": last}

## `mover`: the pony moving the piece (a unicorn lifts it in her magic), null for Anon.
var _anim_actor: Node = null
func _animate(path: PackedInt32Array, removed: Array, castle_rook: Array, mover: Variant) -> void:
	_anim.clear()
	_anim_actor = mover as Node if is_instance_valid(mover) else null
	var magic := _anim_actor != null and _anim_actor.get("magic") != null
	var node: Node3D = table.call("piece_node", path[0])
	if node != null:
		node.top_level = false
		var points: Array = []
		for sq in path: points.append(MODELS.square_position(sq))
		_anim.append({"node": node, "points": points, "t": 0.0, "step": MAGIC_STEP_SECONDS if magic else STEP_SECONDS, "arc": MAGIC_ARC if magic else ARC})
		if magic:
			_glow.append_array(_anim_actor.magic.glow_object(node, 0.8))
			_anim_actor.magic.hold(true)
	if not castle_rook.is_empty():
		var rook: Node3D = table.call("piece_node", int(castle_rook[0]))
		if rook != null:
			_anim.append({"node": rook, "points": [MODELS.square_position(castle_rook[0]), MODELS.square_position(castle_rook[1])], "t": 0.0, "step": 0.45, "arc": 0.04})
	for row: Array in removed:
		var gone: Node3D = table.call("piece_node", int(row[0]))
		if gone != null: _anim.append({"node": gone, "fade": true, "t": 0.0, "step": 0.35})
	animating = true
	_changed()

func _step_animation(delta: float) -> void:
	var done := true
	for row: Dictionary in _anim:
		var node: Node3D = row.node
		if not is_instance_valid(node): continue
		row.t = float(row.t) + delta
		if row.has("fade"):
			# A taken piece waits for the mover to land, then shrinks away.
			var start: float = (_anim[0].points.size() - 1) * float(_anim[0].step) * 0.8 if _anim[0].has("points") else 0.0
			var u := clampf((float(row.t) - start) / float(row.step), 0.0, 1.0)
			node.scale = Vector3.ONE * (1.0 - u)
			if u < 1.0: done = false
			continue
		var points: Array = row.points
		var legs := points.size() - 1
		var u := clampf(float(row.t) / (float(row.step) * legs), 0.0, 1.0)
		var leg := mini(int(u * legs), legs - 1)
		var w := u * legs - leg
		var eased := w * w * (3.0 - 2.0 * w)
		var at: Vector3 = (points[leg] as Vector3).lerp(points[leg + 1], eased)
		at.y += sin(PI * w) * float(row.arc)
		node.position = at
		if u < 1.0: done = false
	if not done: return
	animating = false
	MAGIC.unglow_object(_glow)
	_glow.clear()
	if is_instance_valid(_anim_actor) and _anim_actor.get("magic") != null: _anim_actor.magic.hold(false)
	_anim_actor = null
	SOUNDS.play_at(table, "prop_contact_wood")
	refresh()
	# Resigned or abandoned while the piece was moving: the game is over, nopony moves again.
	if not result.is_empty():
		_changed()
		return
	var just_hers := int(rules.side) == player_side
	if _end_if_over(): return
	if is_match():
		_after_match_move(-int(rules.side))
		_start_thinking()
	elif just_hers: _say_move()
	else: _start_thinking()
	_changed()

func _end_if_over() -> bool:
	var state: Dictionary = rules.status()
	if not bool(state.get("over", false)): return false
	_finish(state)
	return true

# ------------------------------------------------------------------ the end

## `side` (1/-1) gives up.
func resign(side: int) -> void:
	if not result.is_empty(): return
	_stop_thinking()
	_finish({"over": true, "winner": -side, "reason": "%s resigned" % ("Anon" if side == player_side else str(who(side).get("name", "she")))})

## Anon stops here to finish another time: she hears it, and the game is kept like any left unfinished.
func set_aside() -> void:
	if not result.is_empty(): return
	abandon("Game set aside")
	_say(_game_frame() + " Anon stops the game here, to finish it with you another time. Stay in character.", "aside", _ply)

## The game stops without a result (`why` shows in the view). What was played stays kept
## (board_adjourned.gd) to take up again; a game nopony moved in is not worth keeping.
func abandon(why: String) -> void:
	if not result.is_empty(): return
	_stop_thinking()
	if moves_made.is_empty() and not is_match(): ADJOURNED.drop(str(opponent.get("id", "")), game)
	result = {"over": true, "winner": 0, "reason": why, "abandoned": true, "kept": not moves_made.is_empty() and not is_match()}
	_release_gaze()
	finished.emit()
	_changed()

func _finish(state: Dictionary) -> void:
	result = state
	_release_gaze()
	var winner := int(state.get("winner", 0))
	if is_match():
		_talk_pending = {}
		_queue_talk(_match_end_request(winner, str(state.get("reason", ""))), winner if winner != 0 else 1)
		finished.emit()
		_changed()
		return
	ADJOURNED.drop(str(opponent.get("id", "")), game)
	var memory: Node = get_tree().current_scene.get("relationship_runtime") as Node if get_tree().current_scene != null else null
	if is_instance_valid(memory) and memory.has_method("shared_activity"):
		memory.shared_activity(game, table.global_position, "board_%d_%d" % [get_instance_id(), _ply], [str(opponent.get("id", ""))])
	_say_end(winner, str(state.get("reason", "")))
	finished.emit()
	_changed()

func _stop_thinking() -> void:
	if _engine != null: _engine.cancelled = true
	if _task >= 0: WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_engine = null
	thinking = false

func close() -> void:
	_stop_thinking()
	MAGIC.unglow_object(_glow)
	_glow.clear()
	_release_gaze()
	if is_instance_valid(table): table.call("session_closed", self)
	queue_free()

func _exit_tree() -> void:
	_stop_thinking()
	MAGIC.unglow_object(_glow)

func _look_at_board() -> void:
	for side: int in [1, -1]:
		var actor: Variant = who(side).get("actor")
		if is_instance_valid(actor) and actor.has_method("set_action_gaze"): actor.set_action_gaze(table.get("gaze_point"))

func _release_gaze() -> void:
	for side: int in [1, -1]:
		var actor: Variant = who(side).get("actor")
		if is_instance_valid(actor) and actor.get("action_gaze_target") == table.get("gaze_point") and actor.has_method("set_action_gaze"): actor.set_action_gaze(null)

func _changed() -> void:
	if is_instance_valid(table):
		table.emit_signal("changed")
		_update_context()

# ------------------------------------------------------------------ what it looks like in words

func status_text() -> String:
	if is_match(): return _match_status()
	var her := str(opponent.get("name", "She"))
	if not result.is_empty():
		if bool(result.get("abandoned", false)):
			var why := str(result.reason) if str(result.reason) != "" else "Game over"
			return why + (". You can finish it later" if bool(result.get("kept", false)) else "")
		var winner := int(result.get("winner", 0))
		var how := str(result.get("reason", ""))
		if winner == 0: return "Draw: %s" % how
		return ("You win" if winner == player_side else "%s wins" % her) + (": %s" % how if how != "" else "")
	if thinking or (animating and int(rules.side) != player_side): return "%s is thinking…" % her
	if animating: return "%s moves…" % her
	var text := "Your move (%s)" % side_name(player_side)
	if rules.in_check(): text += ": check!"
	return text

## Recent moves as "1. e4 e5  2. Nf3 …".
func moves_text(limit := 12) -> String:
	var parts: PackedStringArray = []
	var first := maxi(0, notation.size() - limit)
	if first % 2 == 1: first -= 1
	for i in range(first, notation.size()):
		parts.append(("%d. " % (i / 2 + 1) if i % 2 == 0 else "") + notation[i])
	return "  ".join(parts)

## How the game stands for her, from her search's score (her view, in pawns x100).
func _standing(score: int) -> String:
	if score >= 90000: return "you can force a win now"
	if score <= -90000: return "you are about to lose"
	if score > 600: return "you are clearly winning"
	if score > 250: return "you are ahead"
	if score > 80: return "you are a little better"
	if score >= -80: return "the game is about even"
	if score >= -250: return "you are a little worse"
	if score >= -600: return "you are behind"
	return "you are losing badly"

func _material_line() -> String:
	var her_side := -player_side
	if game == "chess":
		var lost_hers: String = rules.losses(her_side)
		var lost_his: String = rules.losses(player_side)
		return "Taken so far: from you %s; from Anon %s." % [lost_hers if lost_hers != "" else "nothing", lost_his if lost_his != "" else "nothing"]
	var count: Dictionary = rules.material()
	return "Pieces left: you %d (%d kings), Anon %d (%d kings)." % [int(count[her_side].men) + int(count[her_side].kings), int(count[her_side].kings),
		int(count[player_side].men) + int(count[player_side].kings), int(count[player_side].kings)]

func _game_frame() -> String:
	return "You are playing %s with Anon %s; you have %s, he has %s." % [game, str(table.get("place_words")), side_name(-player_side), side_name(player_side)]

## How she plays, from her style (board_players.json), for her words to match her moves.
func _style_line() -> String:
	var about := str((opponent.get("style", {}) as Dictionary).get("about", ""))
	return " Your style at the board: " + about if about != "" else ""

## Where every piece stands, as a list by kind: models read that far better than a drawn grid or
## a FEN string (dev 2026-10-26: she only had the moves, the early ones dropping off the list).
func _position_line() -> String:
	var her_side := -player_side
	var way := " (your men move toward rank %d)" % (8 if her_side == 1 else 1) if game == "checkers" else ""
	return "Board now%s. Your pieces: %s; Anon's pieces: %s." % [way, rules.position_words(her_side), rules.position_words(player_side)]

## The game in her prompt while it lasts (director_prompts.gd situation_block reads the meta).
func _update_context() -> void:
	if is_match():
		for side: int in [1, -1]: _update_match_context(side)
		return
	var actor: Variant = opponent.get("actor")
	if not is_instance_valid(actor): return
	if not result.is_empty():
		if (actor as Node).has_meta("board_game_context"): (actor as Node).remove_meta("board_game_context")
		return
	var turn := "It is Anon's turn." if int(rules.side) == player_side else "It is your turn; you are thinking about your move."
	var line := "- " + _game_frame() + _style_line() + " Moves so far: %s. %s %s %s If you want, [board_game: resign] gives up the game and [board_game: stop] puts it away." % [moves_text(16) if not notation.is_empty() else "none yet", turn, _position_line(), _material_line()]
	(actor as Node).set_meta("board_game_context", line)

# ------------------------------------------------------------------ her words

func _director() -> Node:
	return get_tree().get_first_node_in_group("conversation_director") if is_inside_tree() else null

func _say(text: String, kind: String, fresh_for_ply: int) -> void:
	var director := _director()
	var key := str(opponent.get("key", ""))
	if director == null or key == "" or not director.has_method("queue_generated_intent"): return
	# A newer moment replaces one she has not started saying; one she is saying, she finishes.
	var pending: Variant = director.get("_authored_lines")
	var row: Dictionary = (pending as Dictionary).get(_line_key, {}) if pending is Dictionary else {}
	if not row.is_empty() and not bool(row.get("started", false)) and str(director.get("_authored_active")) != _line_key and director.has_method("cancel_authored_line"):
		director.cancel_authored_line(_line_key)
	_line_key = "board:%d:%s:%d" % [get_instance_id(), kind, _ply]
	var ply_then := fresh_for_ply
	director.queue_generated_intent(key, text, _line_key, func() -> bool:
		return is_inside_tree() and (_ply <= ply_then + 1 or not result.is_empty()), Callable(), true)

func _say_start() -> void:
	if resumed:
		var whose := "It is your move." if int(rules.side) != player_side else "It is Anon's move."
		_say(_game_frame() + " You take up again the game you two left unfinished, where it stood after %d moves. %s Stay in character." % [ceili(_ply / 2.0), whose], "start", _ply)
		return
	var first := "You move first." if player_side == -1 else "Anon moves first."
	_say(_game_frame() + " The pieces are set up and the game is starting. " + first + _style_line() + " Stay in character.", "start", 0)

func _say_move() -> void:
	var parts: PackedStringArray = [_game_frame()]
	if not _his_last.is_empty(): parts.append("Anon's last move: %s (%s)." % [_his_last.words, _his_last.san])
	parts.append("Your move just now: %s (%s)." % [_her_last.words, _her_last.san])
	var score := int(_her_last.get("score", 0))
	var swing := int(_her_last.get("best_score", score)) - _score_before
	if not _his_last.is_empty() and _ply > 2:
		if swing > 180: parts.append("Anon's move was a mistake you could take advantage of.")
		elif swing < -180: parts.append("Anon's move was a strong one that hurt your position.")
	parts.append("Right now %s. %s" % [_standing(score), _material_line()])
	if bool(_her_last.get("check", false)): parts.append("Your move gives check.")
	parts.append("Stay in character.")
	_say(" ".join(parts), "move", _ply)

func _say_end(winner: int, how: String) -> void:
	var outcome := "The game is a draw (%s)." % how
	if winner == -player_side: outcome = "You won the game against Anon (%s)." % how
	elif winner == player_side: outcome = "Anon won the game against you (%s)." % how
	var last := ""
	if not _his_last.is_empty() and winner == player_side: last = " His last move was %s." % _his_last.words
	_say(_game_frame() + " " + outcome + last + " Stay in character.", "end", _ply)

# ------------------------------------------------------------------ a match: two ponies, Anon watching

func _match_status() -> String:
	if not result.is_empty():
		if bool(result.get("abandoned", false)): return str(result.reason) if str(result.reason) != "" else "Game over"
		var winner := int(result.get("winner", 0))
		var how := str(result.get("reason", ""))
		if winner == 0: return "Draw: %s" % how
		return "%s wins" % str(who(winner).get("name", "")) + (": %s" % how if how != "" else "")
	var mover := str(who(int(rules.side)).get("name", ""))
	if thinking or animating: return "%s is thinking… (%s)" % [mover, side_name(int(rules.side))] if thinking else "%s moves…" % mover
	return "%s to move (%s)" % [mover, side_name(int(rules.side))]

## "You are playing chess against Spike at ...; you have white, he has black."
func _match_frame(side: int) -> String:
	return "You are playing %s against %s %s; you have %s, %s has %s. Anon is watching the game." % [game, str(who(-side).get("name", "")),
		str(table.get("place_words")), side_name(side), str(who(-side).get("name", "")), side_name(-side)]

func _match_material(side: int) -> String:
	var rival := str(who(-side).get("name", ""))
	if game == "chess":
		var mine: String = rules.losses(side)
		var hers: String = rules.losses(-side)
		return "Taken so far: from you %s; from %s %s." % [mine if mine != "" else "nothing", rival, hers if hers != "" else "nothing"]
	var count: Dictionary = rules.material()
	return "Pieces left: you %d (%d kings), %s %d (%d kings)." % [int(count[side].men) + int(count[side].kings), int(count[side].kings),
		rival, int(count[-side].men) + int(count[-side].kings), int(count[-side].kings)]

func _update_match_context(side: int) -> void:
	var actor: Variant = who(side).get("actor")
	if not is_instance_valid(actor): return
	if not result.is_empty():
		if (actor as Node).has_meta("board_game_context"): (actor as Node).remove_meta("board_game_context")
		return
	var rival := str(who(-side).get("name", ""))
	var turn := "It is your turn; you are thinking about your move." if int(rules.side) == side else "It is %s's turn." % rival
	var way := " (your men move toward rank %d)" % (8 if side == 1 else 1) if game == "checkers" else ""
	var about := str((who(side).get("style", {}) as Dictionary).get("about", ""))
	var line := "- " + _match_frame(side) + (" Your style at the board: " + about if about != "" else "") + " Moves so far: %s. %s Board now%s. Your pieces: %s; %s's pieces: %s. %s If you want, [board_game: resign] gives up the game and [board_game: stop] puts it away." % [
		moves_text(16) if not notation.is_empty() else "none yet", turn, way, rules.position_words(side), rival, rules.position_words(-side), _match_material(side)]
	(actor as Node).set_meta("board_game_context", line)

## After a move in a match: a word between them when it was worth one (a capture, a check, a
## blunder or a strong move) or now and then, never sooner than TALK_GAP after the last.
func _after_match_move(side: int) -> void:
	var said: Dictionary = _last_by[side]
	var swing := int(said.get("best_score", said.get("score", 0))) - _score_before
	var notable := str(said.get("captured", "")) != "" or bool(said.get("check", false)) or str(said.get("promotion", "")) != "" or absi(swing) > 180
	if not notable and randf() > 0.3: return
	if (Time.get_ticks_msec() - _talk_at) < int(TALK_GAP * 1000.0): return
	_queue_talk(_match_move_request(side, swing), -side if randf() < 0.5 else side)

func _names(first: int) -> Array[String]:
	var out: Array[String] = [str(who(first).get("key", "")), str(who(-first).get("key", ""))]
	return out

func _match_place() -> String:
	return "%s, with Anon standing by the table watching" % str(table.get("place_words"))

const _TALK_FORM := " Write the whole exchange now, all at once, each line marked [to: listener_id] (the other player). Whoever is spoken to answers. Only the moves named here happened; never invent moves, pieces or results. Stay in character."

func _match_start_request() -> String:
	return ("%s and %s are sitting down across a %s board %s, to play each other: %s has %s and moves first, %s has %s. A short, natural exchange between the two of them as the game starts (2 to 4 short lines): greetings across the board, a friendly challenge, nerves or confidence, whatever fits them." + _TALK_FORM) % [
		str(who(1).get("name", "")), str(who(-1).get("name", "")), game, _match_place(), str(who(1).get("name", "")), side_name(1), str(who(-1).get("name", "")), side_name(-1)]

func _match_move_request(side: int, swing: int) -> String:
	var said: Dictionary = _last_by[side]
	var mover := str(who(side).get("name", ""))
	var other := str(who(-side).get("name", ""))
	var verdict := ""
	if _ply > 2 and swing > 180: verdict = " It was a strong move that hurt %s's position." % other
	elif _ply > 2 and swing < -180: verdict = " It was a mistake %s could take advantage of." % other
	return ("%s and %s are in the middle of a game of %s %s. %s (%s) just played %s (%s).%s As %s sees it, %s. Moves so far: %s. 1 to 3 short lines between the two of them: a reaction to the move, banter, a tease, a groan, a question, or something else on their minds; it need not be about the game every time." + _TALK_FORM) % [
		mover, other, game, _match_place(), mover, side_name(side), str(said.get("words", "")), str(said.get("san", "")), verdict, mover, _standing(int(said.get("score", 0))).replace("you are", mover + " is").replace("you can", mover + " can"), moves_text(10)]

func _match_end_request(winner: int, how: String) -> String:
	var outcome := "The game is a draw (%s)." % how
	if winner != 0: outcome = "%s won the game against %s (%s)." % [str(who(winner).get("name", "")), str(who(-winner).get("name", "")), how]
	return ("%s and %s just finished their game of %s %s. %s 2 to 4 short lines between the two of them reacting to it in character: the winner and the loser as they really feel, a good game, maybe a rematch." + _TALK_FORM) % [
		str(who(1).get("name", "")), str(who(-1).get("name", "")), game, _match_place(), outcome]

## Keeps the exchange until the director is free (at most TALK_TRY); a newer one replaces it.
func _queue_talk(request: String, first: int) -> void:
	_talk_pending = {"request": request, "first": first, "until": Time.get_ticks_msec() + int(TALK_TRY * 1000.0)}
	_try_talk()

## The two of them talk (conversation_director's ambient group, as friends settling in do,
## director_company.gd): only while the director is idle, nopony else is talking and the daily
## background budget allows it; Anon's own words always come first.
func _try_talk() -> void:
	if _talk_pending.is_empty(): return
	if Time.get_ticks_msec() > int(_talk_pending.until): _talk_pending = {}; return
	var director := _director()
	if director == null or not director.has_method("_begin_group") or str(director.get("state")) != "idle": return
	var group: Variant = director.get("group")
	if not group is Object or bool((group as Object).call("active")): return
	var budget: Variant = director.get("ambient_budget")
	if budget is Object and (budget as Object).has_method("available") and not bool((budget as Object).call("available")): return
	var cast: Variant = director.get("characters")
	var ids := _names(int(_talk_pending.first))
	for id: String in ids:
		if id == "" or not (cast is Dictionary and (cast as Dictionary).has(id)): _talk_pending = {}; return
		# One of them still has a line of her own to say (an answer, a story beat): wait for it.
		if director.has_method("_authored_holds") and bool(director.call("_authored_holds", id)): return
	var speech: Variant = director.get("speech")
	if speech is Object and str((speech as Object).get("state")) == "hearing": return
	director.set("_current", ids[0])
	director.set("_turn_id", int(director.get("_turn_id")) + 1)
	director.set("_player_text", "")
	director.set("_rewrite_used", false)
	director.set("_group_request", str(_talk_pending.request))
	_talk_pending = {}
	_talk_at = Time.get_ticks_msec()
	director.call("_begin_group", ids, true)
