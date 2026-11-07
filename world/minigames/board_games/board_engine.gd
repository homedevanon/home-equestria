extends RefCounted
## Picks a pony's move at the game table (board_session.gd): iterative deepening inside a time
## budget, on its own copy of the game (chess_rules.gd / checkers_rules.gd), so think() can run on
## a worker thread. Her strength (board_players.json) caps the depth; a weaker player picks among
## moves close to the best one and now and then overlooks something, the way people do.
## The search: principal variation search with a transposition table, killer and history move
## ordering, late move reductions and a quiet search of captures past the horizon; in chess also
## check extensions, null-move pruning (not in checkers, where a side often has no good move) and
## the first moves from a small book of common openings (dev 2026-10-26: a better engine).
## A style (board_players.json "styles", dev 2026-10-28: "keep them at high level but personalize
## them a bit") picks her favourite openings, chooses among moves within a few hundredths of a pawn
## of the best by taste (attack, position, patience...), sets how she feels about a draw and how
## long she thinks: two ponies at the same level no longer play the same game.
const INFINITE := 1000000
const MATE := 100000
const EXACT := 0
const LOWER := 1
const UPPER := 2
## The quiet search stops this many captures deep.
const QUIET_PLIES := 8
const MAX_PLY := 128
## Per level 1..5 for each game: deepest search, thinking budget (ms), how far below the best a
## move may score and still be picked (centipawns), the chance of an oversight, and how many
## half-moves into the game she still plays from the opening book.
const LEVELS := {
	"chess": [[2, 400, 40, 0.1, 4], [3, 800, 30, 0.06, 6], [4, 1500, 20, 0.025, 8], [6, 3000, 10, 0.01, 12], [64, 4500, 0, 0.0, 16]],
	"checkers": [[2, 400, 150, 0.25, 4], [4, 800, 70, 0.1, 6], [6, 1500, 30, 0.04, 8], [8, 2500, 10, 0.01, 10], [64, 4500, 0, 0.0, 12]]}
## Common openings as [name, line], from squares to squares ("e7e8q" promotes); a position reached
## by several lines offers each of their next moves, the popular ones more often, and a style's
## favourite names (board_players.json) more often still.
const BOOK_LINES := [
	["italian", "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 c2c3 g8f6 d2d3 d7d6"],
	["italian", "e2e4 e7e5 g1f3 b8c6 f1c4 g8f6 d2d3 f8e7"],
	["evans_gambit", "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 b2b4 c5b4 c2c3 b4a5"],
	["ruy_lopez", "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7 f1e1 b7b5 a4b3 d7d6"],
	["ruy_lopez", "e2e4 e7e5 g1f3 b8c6 f1b5 g8f6 e1g1 f6e4 d2d4 e4d6 b5c6 d7c6 d4e5 d6f5"],
	["scotch", "e2e4 e7e5 g1f3 b8c6 d2d4 e5d4 f3d4 g8f6 d4c6 b7c6"],
	["four_knights", "e2e4 e7e5 g1f3 b8c6 b1c3 g8f6 f1b5 f8b4"],
	["petrov", "e2e4 e7e5 g1f3 g8f6 f3e5 d7d6 e5f3 f6e4 d2d4 d6d5"],
	["philidor", "e2e4 e7e5 g1f3 d7d6 d2d4 g8f6 b1c3 b8d7"],
	["vienna", "e2e4 e7e5 b1c3 g8f6 f2f4 d7d5"],
	["kings_gambit", "e2e4 e7e5 f2f4 e5f4 g1f3 g7g5"],
	["sicilian", "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3 a7a6"],
	["sicilian", "e2e4 c7c5 g1f3 b8c6 d2d4 c5d4 f3d4 g8f6 b1c3 e7e5 d4b5 d7d6"],
	["sicilian", "e2e4 c7c5 g1f3 e7e6 d2d4 c5d4 f3d4 b8c6 b1c3 d8c7"],
	["sicilian", "e2e4 c7c5 c2c3 g8f6 e4e5 f6d5 d2d4 c5d4 g1f3 b8c6"],
	["french", "e2e4 e7e6 d2d4 d7d5 b1c3 g8f6 c1g5 f8e7 e4e5 f6d7"],
	["french", "e2e4 e7e6 d2d4 d7d5 e4e5 c7c5 c2c3 b8c6 g1f3 d8b6"],
	["french", "e2e4 e7e6 d2d4 d7d5 b1d2 c7c5 e4d5 e6d5 g1f3 b8c6"],
	["caro_kann", "e2e4 c7c6 d2d4 d7d5 b1c3 d5e4 c3e4 c8f5 e4g3 f5g6 h2h4 h7h6"],
	["caro_kann", "e2e4 c7c6 d2d4 d7d5 e4e5 c8f5 g1f3 e7e6 f1e2 c6c5"],
	["scandinavian", "e2e4 d7d5 e4d5 d8d5 b1c3 d5a5 d2d4 g8f6 g1f3 c8f5"],
	["pirc", "e2e4 d7d6 d2d4 g8f6 b1c3 g7g6 g1f3 f8g7 f1e2 e8g8"],
	["alekhine", "e2e4 g8f6 e4e5 f6d5 d2d4 d7d6 g1f3 c8g4"],
	["queens_gambit", "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6 c1g5 f8e7 e2e3 e8g8 g1f3 h7h6"],
	["queens_gambit", "d2d4 d7d5 c2c4 d5c4 g1f3 g8f6 e2e3 e7e6 f1c4 c7c5"],
	["slav", "d2d4 d7d5 c2c4 c7c6 g1f3 g8f6 b1c3 d5c4 a2a4 c8f5"],
	["kings_indian", "d2d4 g8f6 c2c4 g7g6 b1c3 f8g7 e2e4 d7d6 g1f3 e8g8 f1e2 e7e5"],
	["grunfeld", "d2d4 g8f6 c2c4 g7g6 b1c3 d7d5 c4d5 f6d5 e2e4 d5c3 b2c3 f8g7"],
	["nimzo_indian", "d2d4 g8f6 c2c4 e7e6 b1c3 f8b4 e2e3 e8g8 f1d3 d7d5"],
	["queens_indian", "d2d4 g8f6 c2c4 e7e6 g1f3 b7b6 g2g3 c8b7 f1g2 f8e7"],
	["catalan", "d2d4 g8f6 c2c4 e7e6 g2g3 d7d5 f1g2 f8e7 g1f3 e8g8"],
	["benoni", "d2d4 g8f6 c2c4 c7c5 d4d5 e7e6 b1c3 e6d5 c4d5 d7d6"],
	["london", "d2d4 d7d5 c1f4 g8f6 e2e3 e7e6 g1f3 c7c5 c2c3 b8c6"],
	["dutch", "d2d4 f7f5 g2g3 g8f6 f1g2 e7e6 g1f3 f8e7"],
	["english", "c2c4 e7e5 b1c3 g8f6 g1f3 b8c6 g2g3 d7d5 c4d5 f6d5"],
	["english", "c2c4 c7c5 g1f3 g8f6 b1c3 b8c6 g2g3 g7g6"],
	["reti", "g1f3 d7d5 g2g3 g8f6 f1g2 e7e6 e1g1 f8e7 d2d3"]]
## Checkers openings in the classic numbering (squares 1-32 from the top left, the side moving
## first on 1-12): Old Faithful, Single Corner, Cross, Second Double Corner, Ayrshire Lassie,
## Switcher, Double Corner, Dundee, Denny, Edinburgh, Bristol and others. Red here is that first side.
const CHECKERS_LINES := [
	"11-15 23-19 8-11 22-17 4-8 17-13 15-18 24-20",
	"11-15 23-19 8-11 22-17 9-13 17-14 10x17 21x14",
	"11-15 23-19 9-14 27-23 8-11 22-18 15x22 25x9 5x14",
	"11-15 23-19 7-11 22-17 9-13 17-14 10x17 21x14",
	"11-15 22-18 15x22 25x18 8-11 29-25 4-8 25-22",
	"11-15 22-18 15x22 25x18 12-16 29-25 9-13",
	"11-15 23-18 8-11 27-23 4-8 23-19",
	"11-15 23-18 9-14 18x9 5x14 22-17",
	"11-15 24-19 15x24 28x19 8-11 22-18 11-16",
	"11-15 24-20 8-11 28-24 4-8",
	"11-15 21-17 9-13 25-21 8-11 17-14",
	"11-15 22-17 8-11 17-13 4-8 25-22",
	"9-14 22-18 5-9 24-20 11-15 18x11 8x15",
	"9-14 23-19 5-9 27-23 11-16 22-17",
	"12-16 24-20 8-12 22-18 10-14",
	"10-14 24-20 6-10 22-17 11-16",
	"10-14 22-17",
	"9-13 24-20 11-15 22-18 15x22 25x18",
	"9-13 22-18 6-9 25-22 11-15 18x11 8x15",
	"11-16 24-20 16-19 23x16 12x19",
	"11-16 22-18 16-20 24-19 8-11",
	"10-15 23-18 6-10 22-17"]

## How much each trait of a move (rules' style_traits()) pleases each taste.
const TASTES := {
	"attack": {"check": 3.0, "capture": 1.0, "closer": 0.7, "near_king": 2.0, "multi": 2.0, "promote": 1.0, "retreat": -1.5},
	"flashy": {"check": 2.5, "capture": 2.0, "multi": 3.0, "promote": 3.0, "castle": -1.0, "quiet": -1.0},
	"position": {"quiet": 1.0, "develop": 2.0, "castle": 2.0, "center": 1.5, "back_row": -1.0},
	"patient": {"quiet": 1.0, "retreat": 0.5, "check": -1.0, "trade_ahead": 3.0},
	"solid": {"castle": 3.0, "quiet": 1.0, "retreat": 1.0, "back_row": -2.0, "near_king": -0.5},
	"wild": {}}
## At her best a styled player still only strays this far (centipawns) from the best move: 15
## cost a level-5 style 4 wins, 2 draws and 10 losses against the plain level 5 (dev 2026-10-28).
const STYLE_MARGIN := 8
## Her favourite openings come up this many times more often than the others.
const FAVOURITE := 8.0

## Per game, position hash -> the book's next moves there (chess: from | to << 6 | promotion << 12,
## checkers: from | to << 6), built once.
static var _books := {}
static var _book_lock := Mutex.new()

var rules: RefCounted
var game := "chess"
var depth_cap := 3
var budget_ms := 2500
var margin := 0
var loose := 0.0
var book_plies := 0
## Her style: {"openings": [names], "taste": TASTES key, "draws": centipawns (above 0 she avoids a
## draw, below she welcomes one), "pace": thinking time factor}.
var style: Dictionary = {}
var _contempt := 0
var rng := RandomNumberGenerator.new()
## Set from the main thread to stop early (the game was left).
var cancelled := false
## The chosen move once think() returns; null when there was none.
var result: Variant = null
## {"score": her view in centipawns, "depth", "nodes", "best_score"} for the comments.
var info := {}
var _deadline := 0
var _nodes := 0
var _stop := false
var _table := {}
## Chess: moves come pseudo-legal and are checked once made; passing (null moves) is allowed.
var _pseudo := false
var _null := false
var _root_depth := 0
## Per ply, the two quiet moves that last refuted a line; per side and from/to, how often a quiet
## move did.
var _killers: Array = []
var _history := PackedInt32Array()

## `game_name` "chess" or "checkers", `level` 1..5, `her_style` as above ({} plays plainly). Copies
## the position now, on the calling thread.
func _init(position: RefCounted, game_name: String, level: int, her_style: Dictionary = {}) -> void:
	rules = position.copy()
	game = game_name
	var row: Array = LEVELS.get(game, LEVELS.chess)[clampi(level, 1, 5) - 1]
	depth_cap = int(row[0]); budget_ms = int(row[1]); margin = int(row[2]); loose = float(row[3]); book_plies = int(row[4])
	style = her_style
	if not style.is_empty():
		if TASTES.has(str(style.get("taste", ""))) and rules.has_method("style_traits"): margin = maxi(margin, STYLE_MARGIN)
		_contempt = clampi(int(style.get("draws", 0)), -30, 30)
		budget_ms = int(budget_ms * clampf(float(style.get("pace", 1.0)), 0.85, 1.2))
	rng.randomize()
	_pseudo = rules.has_method("search_moves")
	_null = rules.has_method("make_null")
	_killers.resize(MAX_PLY + 1)
	for i in _killers.size(): _killers[i] = [null, null]
	_history.resize(2 * 4096)

func think() -> void:
	var started := Time.get_ticks_msec()
	_deadline = started + budget_ms
	var root: Array = rules.moves()
	if root.is_empty(): return
	if root.size() == 1:
		result = root[0]
		info = {"score": rules.evaluate(), "depth": 0, "nodes": 0, "best_score": rules.evaluate()}
		return
	var booked: Variant = _book_move(root)
	if booked != null:
		result = booked
		var here: int = rules.evaluate()
		info = {"score": here, "depth": 0, "nodes": 0, "best_score": here, "book": true}
		return
	_sort_root(root)
	var scored: Array = []
	var reached := 0
	for depth in range(1, depth_cap + 1):
		_root_depth = depth
		var pass_scores := _search_root(root, depth)
		if _stop and depth > 1: break
		scored = pass_scores
		reached = depth
		scored.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
		root = scored.map(func(row: Array) -> Variant: return row[0])
		if absi(int(scored[0][1])) >= MATE - 100 or _stop: break
		# The next pass takes several times this one: not worth starting what cannot finish.
		if Time.get_ticks_msec() - started > budget_ms * 0.45: break
	result = _choose(scored)
	var chosen_score := 0
	for row: Array in scored:
		if row[0] == result: chosen_score = int(row[1])
	info = {"score": chosen_score, "best_score": int(scored[0][1]), "depth": reached, "nodes": _nodes}

## Every root move's score; moves within `margin` of the best get exact scores, worse ones only
## a bound (they are never picked anyway).
func _search_root(root: Array, depth: int) -> Array:
	var out: Array = []
	var best := -INFINITE
	for move: Variant in root:
		var floor_score := best - margin - 1 if best > -INFINITE else -INFINITE
		rules.make(move)
		var score: int
		if floor_score == -INFINITE:
			score = -_negamax(depth - 1, -INFINITE, INFINITE, 1, true)
		else:
			score = -_negamax(depth - 1, -floor_score - 1, -floor_score, 1, true)
			if score > floor_score and not _stop: score = -_negamax(depth - 1, -INFINITE, -floor_score, 1, true)
		rules.unmake()
		if _stop and depth > 1: return out
		out.append([move, score])
		best = maxi(best, score)
	return out

## Picks among the moves close to the best, better ones more often; now and then an oversight.
## Never an oversight that throws away a forced win.
func _choose(scored: Array) -> Variant:
	var best := int(scored[0][1])
	if loose > 0.0 and rng.randf() < loose and best < MATE - 100: return _overlook(scored)
	var near: Array = scored.filter(func(row: Array) -> bool: return int(row[1]) >= best - margin)
	var total := 0.0
	var weights: Array = []
	var taste := str(style.get("taste", ""))
	for row: Array in near:
		var weight := 1.0 + float(int(row[1]) - (best - margin)) / maxf(1.0, float(margin))
		# Her taste: a move she likes comes up many times more often among the near-best ones.
		if taste == "wild": weight = 1.0
		elif TASTES.has(taste) and near.size() > 1: weight *= exp(0.6 * _taste(row[0], taste, best))
		weights.append(weight); total += weight
	var pick := rng.randf() * total
	for i in near.size():
		pick -= float(weights[i])
		if pick <= 0.0: return near[i][0]
	return near[0][0]

## How much a move pleases her taste (TASTES), from its traits; "trade_ahead" is a trade when she
## is ahead.
func _taste(move: Variant, taste: String, best: int) -> float:
	var traits: Dictionary = rules.style_traits(move)
	var likes: Dictionary = TASTES[taste]
	var total := 0.0
	for quality: String in likes:
		var value: Variant = traits.get(quality, false)
		if quality == "trade_ahead": value = bool(traits.get("trade", false)) and best > 80
		if quality == "closer": total += float(likes[quality]) * clampf(float(traits.get("closer", 0.0)), -2.0, 2.0)
		elif bool(value): total += float(likes[quality])
	return clampf(total, -4.0, 5.0)

## An oversight, the way people make them: the move that looks best right after it is played,
## without thinking about the answer (a defended piece grabbed, a threat missed), give or take a
## little. Not one the search saw lose outright to mate.
func _overlook(scored: Array) -> Variant:
	var pick: Variant = scored[0][0]
	var best := -INFINITE
	for row: Array in scored:
		if int(row[1]) <= -MATE + 100: continue
		rules.make(row[0])
		var value := -int(rules.evaluate()) + rng.randi_range(-30, 30)
		rules.unmake()
		if value > best: best = value; pick = row[0]
	return pick

func _negamax(depth: int, alpha: int, beta: int, ply: int, can_null: bool) -> int:
	_nodes += 1
	if (_nodes & 255) == 0 and (Time.get_ticks_msec() > _deadline or cancelled): _stop = true
	if _stop: return 0
	if rules.repeated(): return _draw(ply)
	var in_check: bool = _pseudo and rules.in_check()
	# A check is answered one move deeper (within reason: long checking runs stop extending).
	if in_check and ply < 2 * _root_depth + 4: depth += 1
	if depth <= 0: return _quiet(alpha, beta, ply, 0) if _pseudo else _quiet_forced(alpha, beta, ply, 0)
	var key: int = rules.hash
	var entry: Array = _table.get(key, [])
	var hint: Variant = null
	if not entry.is_empty():
		hint = entry[3]
		if int(entry[0]) >= depth:
			var stored := int(entry[1])
			match int(entry[2]):
				EXACT: return stored
				LOWER: alpha = maxi(alpha, stored)
				UPPER: beta = mini(beta, stored)
			if alpha >= beta: return stored
	var pv := beta - alpha > 1
	# Null move: if passing still leaves her at or above beta, a real move surely does.
	if _null and can_null and not pv and not in_check and depth >= 3 and rules.null_ok() and int(rules.evaluate()) >= beta:
		rules.make_null()
		var passed := -_negamax(depth - 3 - depth / 6, -beta, -beta + 1, ply + 1, false)
		rules.unmake_null()
		if _stop: return 0
		if passed >= beta: return beta
	var moves: Array = _ordered(rules.search_moves(false) if _pseudo else rules.moves(), hint, ply)
	var start_alpha := alpha
	var best := -INFINITE
	var best_move: Variant = null
	var legal := 0
	var killers: Array = _killers[mini(ply, MAX_PLY)]
	for move: Variant in moves:
		var quiet: bool = int(rules.order_key(move)) == 0
		rules.make(move)
		if _pseudo and rules.left_in_check():
			rules.unmake()
			continue
		legal += 1
		var score: int
		if legal == 1:
			score = -_negamax(depth - 1, -beta, -alpha, ply + 1, true)
		else:
			# Late quiet moves rarely matter: a shallower look first, the full one if it surprises.
			var reduce := 0
			if depth >= 3 and legal > 3 and quiet and not in_check and move != killers[0] and move != killers[1]:
				if not (_pseudo and rules.in_check()): reduce = 1 if legal <= 6 else 2
			score = -_negamax(depth - 1 - reduce, -alpha - 1, -alpha, ply + 1, true)
			if score > alpha and reduce > 0 and not _stop: score = -_negamax(depth - 1, -alpha - 1, -alpha, ply + 1, true)
			if score > alpha and score < beta and not _stop: score = -_negamax(depth - 1, -beta, -alpha, ply + 1, true)
		rules.unmake()
		if _stop: return 0
		if score > best: best = score; best_move = move
		if score > alpha: alpha = score
		if alpha >= beta:
			if quiet:
				if move != killers[0]: killers[1] = killers[0]; killers[0] = move
				var index := _history_index(move)
				_history[index] = mini(_history[index] + depth * depth, 6000)
			break
	if legal == 0: return _end_score(ply)
	var flag := UPPER if best <= start_alpha else (LOWER if best >= beta else EXACT)
	_table[key] = [depth, best, flag, best_move]
	return best

## Chess past the horizon: standing pat or one of the captures (every move when in check).
func _quiet(alpha: int, beta: int, ply: int, depth: int) -> int:
	_nodes += 1
	if (_nodes & 255) == 0 and (Time.get_ticks_msec() > _deadline or cancelled): _stop = true
	if _stop: return 0
	var in_check: bool = rules.in_check()
	# At the horizon, a side with no move at all is stalemated: a draw, not a material count (a
	# mate shows below, where every move is searched). Deeper in the captures this is rare and
	# left out for speed.
	if depth == 0 and not in_check and not bool(rules.has_moves()): return _end_score(ply)
	var best := -INFINITE
	if not in_check or depth >= QUIET_PLIES:
		var stand: int = rules.evaluate()
		if stand >= beta or depth >= QUIET_PLIES: return stand
		alpha = maxi(alpha, stand)
		best = stand
	var legal := 0
	for move: Variant in _ordered(rules.search_moves(not in_check), null, -1):
		rules.make(move)
		if rules.left_in_check():
			rules.unmake()
			continue
		legal += 1
		var score := -_quiet(-beta, -alpha, ply + 1, depth + 1)
		rules.unmake()
		if _stop: return 0
		if score > best: best = score
		if score > alpha: alpha = score
		if alpha >= beta: break
	if in_check and legal == 0: return _end_score(ply)
	return best

## Checkers past the horizon: captures are compulsory, so no standing pat while one is on.
func _quiet_forced(alpha: int, beta: int, ply: int, depth: int) -> int:
	_nodes += 1
	if (_nodes & 255) == 0 and (Time.get_ticks_msec() > _deadline or cancelled): _stop = true
	if _stop: return 0
	# At the horizon, a side with no move at all is beaten: a result, not a material count.
	# Deeper in the captures this is rare and left out for speed.
	if depth == 0 and not bool(rules.has_moves()): return _end_score(ply)
	var forced: bool = rules.noisy_forced()
	var moves: Array = rules.noisy_moves()
	var stand: int = rules.evaluate()
	if depth >= QUIET_PLIES: return stand
	if moves.is_empty(): return stand
	if not forced:
		if stand >= beta: return stand
		alpha = maxi(alpha, stand)
	var best := -INFINITE if forced else stand
	for move: Variant in _ordered(moves, null, -1):
		rules.make(move)
		var score := -_quiet_forced(-beta, -alpha, ply + 1, depth + 1)
		rules.unmake()
		if _stop: return 0
		if score > best: best = score
		if score > alpha: alpha = score
		if alpha >= beta: break
	return best

## A draw `ply` moves into the search, from the side to move's view: worth less than nothing to
## her when she plays on (draws above 0), a little to her when she is glad of one.
func _draw(ply: int) -> int:
	return -_contempt if ply % 2 == 0 else _contempt

## A position with no move: mate (or a checkers loss) as the rules score it, a stalemate as a draw.
func _end_score(ply: int) -> int:
	var score: int = rules.terminal_score(ply)
	return _draw(ply) if score == 0 else score

func _history_index(move: Variant) -> int:
	return (0 if int(rules.side) == 1 else 4096) + int(rules.from_sq(move)) * 64 + int(rules.to_sq(move))

## Best-looking first: the move this position remembered, then captures (rules' order_key()),
## then this ply's killer moves, then quiet moves by their history. `ply` -1: no killers/history.
func _ordered(moves: Variant, hint: Variant, ply: int) -> Array:
	var killers: Array = _killers[mini(ply, MAX_PLY)] if ply >= 0 else [null, null]
	if moves is PackedInt32Array:
		# Chess moves are ints: the key above the move in one int64, sorted natively.
		var keyed := PackedInt64Array()
		keyed.resize(moves.size())
		var hint_move: int = int(hint) if hint != null else -1
		var i := 0
		for move: int in moves:
			var key: int
			if move == hint_move: key = 1 << 22
			else:
				key = int(rules.order_key(move))
				if key == 0 and ply >= 0:
					if killers[0] != null and move == int(killers[0]): key = 7000
					elif killers[1] != null and move == int(killers[1]): key = 6900
					else: key = _history[_history_index(move)]
			keyed[i] = (key << 21) | move
			i += 1
		keyed.sort()
		var out: Array = []
		out.resize(keyed.size())
		for j in keyed.size(): out[j] = keyed[keyed.size() - 1 - j] & 0x1FFFFF
		return out
	var rows: Array = []
	for move: Variant in moves:
		var key: int
		if hint != null and move == hint: key = 1 << 22
		else:
			key = int(rules.order_key(move))
			if key == 0 and ply >= 0:
				if move == killers[0]: key = 7000
				elif move == killers[1]: key = 6900
				else: key = _history[_history_index(move)]
		rows.append([key, move])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	return rows.map(func(row: Array) -> Variant: return row[1])

func _sort_root(root: Array) -> void:
	var ordered := _ordered(PackedInt32Array(root) if _pseudo else root, null, -1)
	for i in root.size(): root[i] = ordered[i]

# ------------------------------------------------------------------ the opening book

## A book move for this position, or null: early in the game, and less of the book for a weaker
## player.
func _book_move(root: Array) -> Variant:
	if book_plies <= 0 or rules.get("history") == null: return null
	if (rules.history as PackedInt64Array).size() - 1 >= book_plies: return null
	_book_lock.lock()
	if not _books.has(game): _build_book()
	var options: Array = (_books[game] as Dictionary).get(rules.hash, [])
	_book_lock.unlock()
	if options.is_empty(): return null
	# Each option is [move key, line name]; her favourite lines weigh FAVOURITE times more.
	var favourites: Array = style.get("openings", []) if game == "chess" else []
	var total := 0.0
	for option: Array in options: total += FAVOURITE if str(option[1]) in favourites else 1.0
	var pick := rng.randf() * total
	var key: int = int(options[0][0])
	for option: Array in options:
		pick -= FAVOURITE if str(option[1]) in favourites else 1.0
		if pick <= 0.0: key = int(option[0]); break
	for move: Variant in root:
		if _move_key(move) == key: return move
	return null

func _move_key(move: Variant) -> int:
	return int(move) & 0x7FFF if move is int else int(rules.from_sq(move)) | int(rules.to_sq(move)) << 6

## Plays every book line from the start, noting each position's next move (on the thread that
## thinks first; the lock keeps a second one out until it is done).
func _build_book() -> void:
	var book := {}
	var start: RefCounted = rules.get_script().new()
	for entry: Variant in (BOOK_LINES if game == "chess" else CHECKERS_LINES):
		var line := str(entry[1]) if entry is Array else str(entry)
		var named := str(entry[0]) if entry is Array else ""
		var position: RefCounted = start.copy()
		for token: String in line.split(" ", false):
			var key := _token_key(token) if game == "chess" else _checkers_key(token)
			var found: Variant = null
			for move: Variant in position.moves():
				if _move_key(move) == key: found = move
			if found == null:
				push_warning("board_engine: book line stops at %s: %s" % [token, line])
				break
			var next: Array = book.get(position.hash, [])
			next.append([key, named])
			book[position.hash] = next
			position.make(found)
	_books[game] = book

## "11-15" or "15x22" in the classic numbering: square 1 is the top left playable one as the side
## moving second sees the board; here the first side (red) plays up from the bottom, so the board
## turns half round.
static func _checkers_key(token: String) -> int:
	var ends := token.replace("x", "-").split("-")
	var squares := PackedInt32Array()
	for end: String in [ends[0], ends[-1]]:
		var index := int(end) - 1
		var row := index / 4
		var file := (index % 4) * 2 + (1 if row % 2 == 0 else 0)
		squares.append(row * 8 + (7 - file))
	return squares[0] | squares[1] << 6

static func _token_key(token: String) -> int:
	var from := "abcdefgh".find(token[0]) + (int(token[1]) - 1) * 8
	var to := "abcdefgh".find(token[2]) + (int(token[3]) - 1) * 8
	var promo := " pnbrq".find(token[4]) if token.length() > 4 else 0
	return from | to << 6 | maxi(promo, 0) << 12
