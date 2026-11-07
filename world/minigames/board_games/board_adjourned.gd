extends RefCounted
## Unfinished board games (dev 2026-10-27: "have a game, leave, have another game with another
## pony and then finish the first one later"): one per pony and game, kept from move to move by
## board_session.gd until the game ends with a result. A game Anon set aside, walked away from,
## that she put away or left, or that was running when the world was saved, is taken up again
## where it stood at any game board. The moves are kept, not the board: the session replays them
## (board_session.gd replay). Saved beside books.json and in each checkpoint under the additive
## "board_games" key (game_saves.gd).
##
## Always loaded (saves, prompts), so it preloads nothing of the board game itself.
const SAVE_FILE = preload("res://world/save_file.gd")
const VERSION := 1
const MAX_GAMES := 64
const MAX_PLIES := 600
const GAMES := ["chess", "checkers"]
const SIDE_NAMES := {"chess": {1: "white", -1: "black"}, "checkers": {1: "red", -1: "white"}}
static var _path := ""
## "pony_id:game" -> {"game", "side" (Anon's, 1/-1), "moves" (keys), "score" (hers), "day"}.
static var _games := {}

static func open_world(world_dir: String) -> void:
	_path = world_dir.path_join("board_games.json") if not world_dir.is_empty() else ""
	_games = {}
	if not _path.is_empty() and FileAccess.file_exists(_path):
		var value: Variant = SAVE_FILE.parse(_path)
		if valid_state(value): _games = _clean(value)

static func snapshot() -> Dictionary:
	return {"version": VERSION, "games": _games.duplicate(true)}

static func valid_state(value: Variant) -> bool:
	if not value is Dictionary: return false
	var doc: Dictionary = value
	if doc.has("version") and not (_number(doc.version) and int(doc.version) == VERSION): return false
	var games: Variant = doc.get("games", {})
	if not games is Dictionary or (games as Dictionary).size() > MAX_GAMES: return false
	for key: Variant in games:
		var row: Variant = games[key]
		if not key is String or not row is Dictionary: return false
		if not row.get("game") is String or not GAMES.has(row.game) or not (key as String).ends_with(":" + str(row.game)): return false
		if not _number(row.get("side")) or absi(int(row.side)) != 1: return false
		if not _number(row.get("score", 0)) or not _number(row.get("day", 0)): return false
		var moves: Variant = row.get("moves")
		if not moves is Array or (moves as Array).is_empty() or (moves as Array).size() > MAX_PLIES: return false
		for move: Variant in moves:
			if not move is Array or (move as Array).size() < 2 or (move as Array).size() > 13: return false
			for sq: Variant in move:
				if not _number(sq) or int(sq) < 0 or int(sq) > 63: return false
	return true

## A checkpoint's games replace the current ones.
static func restore(value: Variant) -> bool:
	if not valid_state(value): return false
	_games = _clean(value)
	_write()
	return true

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

## JSON numbers come back as floats: the rows as ints again.
static func _clean(value: Dictionary) -> Dictionary:
	var out := {}
	var games: Dictionary = value.get("games", {})
	for key: String in games:
		var row: Dictionary = games[key]
		var moves: Array = []
		for move: Array in row.moves: moves.append(move.map(func(sq: Variant) -> int: return int(sq)))
		out[key] = {"game": str(row.game), "side": int(row.side), "moves": moves, "score": int(row.get("score", 0)), "day": int(row.get("day", 0))}
	return out

static func _write() -> void:
	if not _path.is_empty(): SAVE_FILE.write(_path, snapshot())

# ------------------------------------------------------------------ the games

## The unfinished `game` with `pony`, or {}.
static func game_of(pony: String, game: String) -> Dictionary:
	return (_games.get(pony + ":" + game, {}) as Dictionary).duplicate(true)

static func keep(pony: String, game: String, side: int, moves: Array, score: int, day: int) -> void:
	if pony == "" or moves.is_empty() or moves.size() > MAX_PLIES: return
	var key := pony + ":" + game
	if not _games.has(key) and _games.size() >= MAX_GAMES: return
	_games[key] = {"game": game, "side": side, "moves": moves.duplicate(true), "score": score, "day": day}
	_write()

static func drop(pony: String, game: String) -> void:
	if _games.erase(pony + ":" + game): _write()

## Her unfinished games with Anon, for her prompt ("" when none).
static func prompt_line(pony: String, today: int) -> String:
	var parts: PackedStringArray = []
	var verbs: PackedStringArray = []
	for game: String in GAMES:
		var row := game_of(pony, game)
		if row.is_empty(): continue
		var ago := today - int(row.day)
		var when := "today" if ago <= 0 else ("yesterday" if ago == 1 else "%d days ago" % ago)
		var score := int(row.score)
		var stood := "you were ahead" if score > 250 else ("Anon was ahead" if score < -250 else "it was about even")
		var moves := ceili((row.moves as Array).size() / 2.0)
		parts.append("%s (left %s after %d move%s, you with %s, %s)" % [game, when, moves, "" if moves == 1 else "s",
			SIDE_NAMES[game][-int(row.side)], stood])
		verbs.append("[board_game: %s]" % game)
	if parts.is_empty(): return ""
	return "- Unfinished games with Anon: %s. At a game board, %s takes it up again where you left it." % ["; ".join(parts), " or ".join(verbs)]
