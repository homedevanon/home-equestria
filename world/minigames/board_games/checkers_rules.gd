extends RefCounted
## Checkers (English draughts) for the library game table (board_session.gd): men step and take
## diagonally forward, kings both ways one square at a time; taking is compulsory and a piece
## that can jump again must, but any capturing line may be chosen; a man reaching the far row is
## crowned and his move ends there. Red moves first. Squares are 0..63 like chess_rules.gd and
## only the dark ones (rank + file even) are used; red starts on ranks 1-3 and is positive
## (1 man, 2 king), white negative. A move is {"path": squares landed on from the start square,
## "taken": squares jumped, "crown": bool}. The engine (board_engine.gd) calls the same functions
## as on chess_rules.gd, and noisy_moves() / has_moves() for its quiet search past the horizon.
const MAN := 1
const KING := 2
const SIDE_NAMES := {1: "red", -1: "white"}
const FIRST := 1
## Without a capture or a man moving for this many moves in all (40 each), the game is drawn.
const QUIET_LIMIT := 80
const DIAGONALS := [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]

static var _next: Array = []
static var _keys: PackedInt64Array
## The 32 playable squares, bottom row first.
static var _dark := PackedInt32Array()
## Every plain step, made once and shared (moves are never changed once made): (from * 64 + to) * 2
## + crown. Built whole in _tables() and only read afterwards, so engines on worker threads can share
## it (filling it during searches raced and crashed, Codex review 2026-10-29).
static var _steps := {}
static var NO_TAKES := PackedInt32Array()
static var _built := false
static var _build_lock := Mutex.new()

var board := PackedInt32Array()
var side := FIRST
var halfmove := 0
var hash := 0
var history := PackedInt64Array()
var _undo: Array = []

func _init() -> void:
	_tables()
	board.resize(64)
	for sq in 64:
		if ((sq >> 3) + (sq & 7)) % 2 != 0: continue
		if sq >> 3 <= 2: board[sq] = MAN
		elif sq >> 3 >= 5: board[sq] = -MAN
	hash = _full_hash()
	history.append(hash)

## The shared tables, built once (by whichever thread comes first; the others wait) into locals and
## published whole.
static func _tables() -> void:
	if _built: return
	_build_lock.lock()
	if not _built:
		var dark := PackedInt32Array()
		var next: Array = []
		for sq in 64:
			if ((sq >> 3) + (sq & 7)) % 2 == 0: dark.append(sq)
		for sq in 64:
			var at := Vector2i(sq & 7, sq >> 3)
			var steps := PackedInt32Array()
			for dir: Vector2i in DIAGONALS:
				var to: Vector2i = at + dir
				steps.append(to.y * 8 + to.x if to.x >= 0 and to.x < 8 and to.y >= 0 and to.y < 8 else -1)
			next.append(steps)
		var made := {}
		for sq in dark:
			for to: int in next[sq]:
				if to < 0: continue
				for crown: bool in [false, true]:
					made[(sq * 64 + to) * 2 + int(crown)] = {"path": PackedInt32Array([sq, to]), "taken": NO_TAKES, "crown": crown}
		var keys := PackedInt64Array()
		var rng := RandomNumberGenerator.new()
		rng.seed = 0xc4ec_4e25
		keys.resize(64 * 5 + 1)
		for i in keys.size(): keys[i] = (int(rng.randi()) << 32) ^ int(rng.randi())
		_dark = dark; _next = next; _steps = made; _keys = keys
		_built = true
	_build_lock.unlock()

func _full_hash() -> int:
	var h := 0
	for sq in 64:
		if board[sq] != 0: h ^= _keys[sq * 5 + board[sq] + 2]
	if side == -1: h ^= _keys[320]
	return h

func copy() -> RefCounted:
	var other: RefCounted = get_script().new()
	other.board = board.duplicate()
	other.side = side; other.halfmove = halfmove; other.hash = hash
	other.history = history.duplicate()
	return other

# ------------------------------------------------------------------ moves

static func from_sq(move: Dictionary) -> int: return (move.path as PackedInt32Array)[0]
static func to_sq(move: Dictionary) -> int: return (move.path as PackedInt32Array)[-1]

## Diagonal directions (DIAGONALS indices) a piece may move in: a man only forward.
func _directions(piece: int) -> Array:
	if absi(piece) == KING: return [0, 1, 2, 3]
	return [0, 1] if piece > 0 else [2, 3]

func _crowns(piece: int, sq: int) -> bool:
	return absi(piece) == MAN and (sq >> 3) == (7 if piece > 0 else 0)

## Every legal move: the captures when there are any, else the plain steps.
func moves() -> Array:
	var jumps: Array = []
	for sq in _dark:
		if board[sq] * side > 0: _jumps_from(sq, jumps)
	if not jumps.is_empty(): return jumps
	var steps: Array = []
	for sq in _dark:
		var piece := board[sq]
		if piece * side <= 0: continue
		for d: int in _directions(piece):
			var to: int = _next[sq][d]
			if to >= 0 and board[to] == 0:
				steps.append(_steps[(sq * 64 + to) * 2 + int(_crowns(piece, to))])
	return steps

## The captures, which the side to move must make (nothing for the quiet search to add otherwise).
func noisy_moves() -> Array:
	var jumps: Array = []
	for sq in _dark:
		if board[sq] * side > 0: _jumps_from(sq, jumps)
	return jumps

func noisy_forced() -> bool:
	return true

## Any legal move at all: with none, the side to move has lost.
func has_moves() -> bool:
	return not moves().is_empty()

func _jumps_from(sq: int, out: Array) -> void:
	var piece := board[sq]
	# The piece has left its square: a king's ring of jumps may land on it again.
	board[sq] = 0
	_jump_on(sq, piece, PackedInt32Array([sq]), PackedInt32Array(), out)
	board[sq] = piece

func _jump_on(at: int, piece: int, path: PackedInt32Array, taken: PackedInt32Array, out: Array) -> void:
	var further := false
	for d: int in _directions(piece):
		var over: int = _next[at][d]
		if over < 0 or board[over] * side >= 0 or taken.has(over): continue
		var land: int = _next[over][d]
		if land < 0 or board[land] != 0: continue
		further = true
		var next_path := path.duplicate(); next_path.append(land)
		var next_taken := taken.duplicate(); next_taken.append(over)
		if _crowns(piece, land): out.append({"path": next_path, "taken": next_taken, "crown": true})
		else: _jump_on(land, piece, next_path, next_taken, out)
	if not further and taken.size() > 0:
		out.append({"path": path, "taken": taken, "crown": false})

func make(move: Dictionary) -> void:
	var path: PackedInt32Array = move.path
	var taken: PackedInt32Array = move.taken
	var from := path[0]
	var to := path[-1]
	var piece := board[from]
	var removed := PackedInt32Array()
	for sq in taken: removed.append(board[sq])
	_undo.append([move, piece, removed, halfmove, hash])
	hash ^= _keys[from * 5 + piece + 2]
	board[from] = 0
	for i in taken.size():
		hash ^= _keys[taken[i] * 5 + removed[i] + 2]
		board[taken[i]] = 0
	var placed := piece * KING if bool(move.crown) else piece
	board[to] = placed
	hash ^= _keys[to * 5 + placed + 2]
	halfmove = 0 if absi(piece) == MAN or not taken.is_empty() else halfmove + 1
	side = -side
	hash ^= _keys[320]
	history.append(hash)

func unmake() -> void:
	var undo: Array = _undo.pop_back()
	var move: Dictionary = undo[0]
	var path: PackedInt32Array = move.path
	var taken: PackedInt32Array = move.taken
	var removed: PackedInt32Array = undo[2]
	history.resize(history.size() - 1)
	side = -side
	board[path[-1]] = 0
	board[path[0]] = undo[1]
	for i in taken.size(): board[taken[i]] = removed[i]
	halfmove = undo[3]; hash = undo[4]

func in_check() -> bool:
	return false

# ------------------------------------------------------------------ the game's end

func status() -> Dictionary:
	if moves().is_empty():
		var left := false
		for piece in board:
			if piece * side > 0: left = true
		return {"over": true, "winner": -side, "reason": "no moves left" if left else "every piece taken"}
	if halfmove >= QUIET_LIMIT: return {"over": true, "winner": 0, "reason": "forty moves each without a capture or a man moving"}
	if history.count(hash) >= 3: return {"over": true, "winner": 0, "reason": "the same position three times"}
	return {"over": false}

func repeated() -> bool:
	var last := history.size() - 1
	var oldest := maxi(0, last - halfmove)
	for i in range(last - 2, oldest - 1, -2):
		if history[i] == hash: return true
	return false

func terminal_score(ply: int) -> int:
	return -100000 + ply

# ------------------------------------------------------------------ the engine's score

## Material, advance, a kept back row and the middle, from the side to move's view. (A richer
## evaluation, the bridge, endgame advance, kings closing in, tested even against this one over
## 40 games and 5 king endings, dev 2026-10-28: kept simple.)
func evaluate() -> int:
	var score := 0
	var red := 0
	var white := 0
	for sq in _dark:
		var piece := board[sq]
		if piece == 0: continue
		var owner := signi(piece)
		if owner == 1: red += 1
		else: white += 1
		var rank := sq >> 3 if owner == 1 else 7 - (sq >> 3)
		var file := sq & 7
		var value := 160 if absi(piece) == KING else 100 + rank * 4
		if absi(piece) == MAN and rank == 0: value += 10
		if rank >= 2 and rank <= 5 and file >= 2 and file <= 5: value += 6
		if absi(piece) == KING and (file == 0 or file == 7): value -= 8
		score += value * owner
	# Ahead, trade down; few pieces left, the stronger side's kings close in.
	var total := red + white
	if score != 0 and total <= 10:
		score += signi(score) * (24 - total) * 3
	return score * side

## What kind of move this is, for a player's style (board_engine.gd TASTES): a capture (several in a
## row, a trade), a crowning, leaving the back row, the centre, a king retreating, and how much
## closer it brings the piece to the nearest enemy piece.
func style_traits(move: Dictionary) -> Dictionary:
	var path: PackedInt32Array = move.path
	var from := path[0]
	var to := path[-1]
	var piece := board[from]
	var taken := (move.taken as PackedInt32Array).size()
	var rank_from := from >> 3 if side == 1 else 7 - (from >> 3)
	var rank_to := to >> 3 if side == 1 else 7 - (to >> 3)
	var before := 14
	var after := 14
	for sq in _dark:
		if board[sq] * side >= 0: continue
		before = mini(before, maxi(absi((from & 7) - (sq & 7)), absi((from >> 3) - (sq >> 3))))
		after = mini(after, maxi(absi((to & 7) - (sq & 7)), absi((to >> 3) - (sq >> 3))))
	return {"capture": taken > 0, "multi": taken > 1, "trade": taken == 1, "check": false, "castle": false,
		"promote": bool(move.crown), "closer": float(before - after), "near_king": after <= 1, "develop": false,
		"retreat": rank_to < rank_from, "center": (to & 7) >= 2 and (to & 7) <= 5 and (to >> 3) >= 2 and (to >> 3) <= 5,
		"quiet": taken == 0, "back_row": absi(piece) == MAN and rank_from == 0}

func order_key(move: Dictionary) -> int:
	return (move.taken as PackedInt32Array).size() * 1000 + (500 if bool(move.crown) else 0)

# ------------------------------------------------------------------ words

static func square_name(sq: int) -> String:
	return "abcdefgh"[sq & 7] + str((sq >> 3) + 1)

func piece_at(sq: int) -> int:
	return board[sq]

## The legal move from `from` ending on `to`, or {} (the longest capture when several share both).
func find_move(from: int, to: int, _promo := 0) -> Dictionary:
	var found: Dictionary = {}
	for move: Dictionary in moves():
		if from_sq(move) != from or to_sq(move) != to: continue
		if found.is_empty() or (move.taken as PackedInt32Array).size() > (found.taken as PackedInt32Array).size(): found = move
	return found

func targets_from(from: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for move: Dictionary in moves():
		if from_sq(move) == from and not out.has(to_sq(move)): out.append(to_sq(move))
	return out

func promotes(_from: int, _to: int) -> bool:
	return false

func describe(move: Dictionary) -> Dictionary:
	var path: PackedInt32Array = move.path
	var taken: int = (move.taken as PackedInt32Array).size()
	var kind := "king" if absi(board[path[0]]) == KING else "man"
	var names: PackedStringArray = []
	for sq in path: names.append(square_name(sq))
	var notation := ("x" if taken > 0 else "-").join(names)
	var words := ""
	if taken == 0: words = "%s from %s to %s" % [kind, names[0], names[-1]]
	elif taken == 1: words = "%s jumps from %s to %s, taking a piece" % [kind, names[0], names[-1]]
	else: words = "%s jumps %d pieces in a row, from %s to %s" % [kind, taken, names[0], names[-1]]
	if bool(move.crown): words += ", and is crowned king"
	return {"san": notation, "words": words, "piece": kind, "captured": ("%d pieces" % taken if taken > 1 else ("a piece" if taken == 1 else "")),
		"check": false, "mate": false, "castle": "", "promotion": "king" if bool(move.crown) else "",
		"from": names[0], "to": names[-1], "taken": taken}

## Pieces each side has: {1: {"men", "kings"}, -1: {...}}.
func material() -> Dictionary:
	var total := {1: {"men": 0, "kings": 0}, -1: {"men": 0, "kings": 0}}
	for piece in board:
		if piece == 0: continue
		total[signi(piece)]["kings" if absi(piece) == KING else "men"] += 1
	return total

func losses(owner: int) -> String:
	var left := 0
	for piece in board:
		if piece * owner > 0: left += 1
	return "" if left == 12 else "%d of 12 pieces" % (12 - left)

## Where `owner`'s pieces stand, kings first ("kings d4, men a7 c7 e7").
func position_words(owner: int) -> String:
	var parts: PackedStringArray = []
	for kind: int in [KING, MAN]:
		var squares: PackedStringArray = []
		for i in 64:
			var sq := (i & 7) * 8 + (i >> 3)  # file by file, a to h
			if board[sq] == kind * owner: squares.append(square_name(sq))
		if squares.is_empty(): continue
		var word := ("king" if kind == KING else "man") if squares.size() == 1 else ("kings" if kind == KING else "men")
		parts.append("%s %s" % [word, " ".join(squares)])
	return ", ".join(parts) if not parts.is_empty() else "none"
