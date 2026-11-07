extends RefCounted
## Chess for the library game table (board_session.gd): legal moves with castling, en passant and
## promotion, check, mate and the draws (stalemate, fifty moves, threefold, bare kings), a score
## for the engine (board_engine.gd) and words for a move. Squares are 0..63, rank * 8 + file
## (a1 = 0, h8 = 63); white pieces are positive (1 pawn .. 6 king), black ones negative. A move is
## one int: from | to << 6 | promotion << 12 | flags << 16. White moves first (side 1).
const PAWN := 1
const KNIGHT := 2
const BISHOP := 3
const ROOK := 4
const QUEEN := 5
const KING := 6
const CAPTURE := 1
const EN_PASSANT := 2
const CASTLE := 4
const DOUBLE := 8
const NAMES := ["", "pawn", "knight", "bishop", "rook", "queen", "king"]
const LETTERS := ["", "", "N", "B", "R", "Q", "K"]
const VALUES := [0, 100, 320, 330, 500, 900, 0]
const SIDE_NAMES := {1: "white", -1: "black"}
const FIRST := 1
## Rook and bishop directions (file, rank): 0..3 straight, 4..7 diagonal.
const DIRS := [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
const KNIGHT_JUMPS := [Vector2i(1, 2), Vector2i(2, 1), Vector2i(2, -1), Vector2i(1, -2), Vector2i(-1, -2), Vector2i(-2, -1), Vector2i(-2, 1), Vector2i(-1, 2)]
## Castling rights kept after a move from or to each square (1 white short, 2 white long, 4 black
## short, 8 black long).
const START := [4, 2, 3, 5, 6, 3, 2, 4]
## PeSTO's tapered evaluation (Ronald Friederich's tables, as on the chessprogramming wiki): a
## middlegame and an endgame value for each piece and square, blended by the material left (the
## phase: knight and bishop 1, rook 2, queen 4, 24 at the start). From White's side, a8 first: a
## white piece on square s reads entry s ^ 56, a black one entry s.
const MG_VALUE := [0, 82, 337, 365, 477, 1025, 0]
const EG_VALUE := [0, 94, 281, 297, 512, 936, 0]
const PHASE_INC := [0, 0, 1, 1, 2, 4, 0]
const MG_PST := {
	PAWN: [
		0, 0, 0, 0, 0, 0, 0, 0,
		98, 134, 61, 95, 68, 126, 34, -11,
		-6, 7, 26, 31, 65, 56, 25, -20,
		-14, 13, 6, 21, 23, 12, 17, -23,
		-27, -2, -5, 12, 17, 6, 10, -25,
		-26, -4, -4, -10, 3, 3, 33, -12,
		-35, -1, -20, -23, -15, 24, 38, -22,
		0, 0, 0, 0, 0, 0, 0, 0],
	KNIGHT: [
		-167, -89, -34, -49, 61, -97, -15, -107,
		-73, -41, 72, 36, 23, 62, 7, -17,
		-47, 60, 37, 65, 84, 129, 73, 44,
		-9, 17, 19, 53, 37, 69, 18, 22,
		-13, 4, 16, 13, 28, 19, 21, -8,
		-23, -9, 12, 10, 19, 17, 25, -16,
		-29, -53, -12, -3, -1, 18, -14, -19,
		-105, -21, -58, -33, -17, -28, -19, -23],
	BISHOP: [
		-29, 4, -82, -37, -25, -42, 7, -8,
		-26, 16, -18, -13, 30, 59, 18, -47,
		-16, 37, 43, 40, 35, 50, 37, -2,
		-4, 5, 19, 50, 37, 37, 7, -2,
		-6, 13, 13, 26, 34, 12, 10, 4,
		0, 15, 15, 15, 14, 27, 18, 10,
		4, 15, 16, 0, 7, 21, 33, 1,
		-33, -3, -14, -21, -13, -12, -39, -21],
	ROOK: [
		32, 42, 32, 51, 63, 9, 31, 43,
		27, 32, 58, 62, 80, 67, 26, 44,
		-5, 19, 26, 36, 17, 45, 61, 16,
		-24, -11, 7, 26, 24, 35, -8, -20,
		-36, -26, -12, -1, 9, -7, 6, -23,
		-45, -25, -16, -17, 3, 0, -5, -33,
		-44, -16, -20, -9, -1, 11, -6, -71,
		-19, -13, 1, 17, 16, 7, -37, -26],
	QUEEN: [
		-28, 0, 29, 12, 59, 44, 43, 45,
		-24, -39, -5, 1, -16, 57, 28, 54,
		-13, -17, 7, 8, 29, 56, 47, 57,
		-27, -27, -16, -16, -1, 17, -2, 1,
		-9, -26, -9, -10, -2, -4, 3, -3,
		-14, 2, -11, -2, -5, 2, 14, 5,
		-35, -8, 11, 2, 8, 15, -3, 1,
		-1, -18, -9, 10, -15, -25, -31, -50],
	KING: [
		-65, 23, 16, -15, -56, -34, 2, 13,
		29, -1, -20, -7, -8, -4, -38, -29,
		-9, 24, 2, -16, -20, 6, 22, -22,
		-17, -20, -12, -27, -30, -25, -14, -36,
		-49, -1, -27, -39, -46, -44, -33, -51,
		-14, -14, -22, -46, -44, -30, -15, -27,
		1, 7, -8, -64, -43, -16, 9, 8,
		-15, 36, 12, -54, 8, -28, 24, 14]}
const EG_PST := {
	PAWN: [
		0, 0, 0, 0, 0, 0, 0, 0,
		178, 173, 158, 134, 147, 132, 165, 187,
		94, 100, 85, 67, 56, 53, 82, 84,
		32, 24, 13, 5, -2, 4, 17, 17,
		13, 9, -3, -7, -7, -8, 3, -1,
		4, 7, -6, 1, 0, -5, -1, -8,
		13, 8, 8, 10, 13, 0, 2, -7,
		0, 0, 0, 0, 0, 0, 0, 0],
	KNIGHT: [
		-58, -38, -13, -28, -31, -27, -63, -99,
		-25, -8, -25, -2, -9, -25, -24, -52,
		-24, -20, 10, 9, -1, -9, -19, -41,
		-17, 3, 22, 22, 22, 11, 8, -18,
		-18, -6, 16, 25, 16, 17, 4, -18,
		-23, -3, -1, 15, 10, -3, -20, -22,
		-42, -20, -10, -5, -2, -20, -23, -44,
		-29, -51, -23, -15, -22, -18, -50, -64],
	BISHOP: [
		-14, -21, -11, -8, -7, -9, -17, -24,
		-8, -4, 7, -12, -3, -13, -4, -14,
		2, -8, 0, -1, -2, 6, 0, 4,
		-3, 9, 12, 9, 14, 10, 3, 2,
		-6, 3, 13, 19, 7, 10, -3, -9,
		-12, -3, 8, 10, 13, 3, -7, -15,
		-14, -18, -7, -1, 4, -9, -15, -27,
		-23, -9, -23, -5, -9, -16, -5, -17],
	ROOK: [
		13, 10, 18, 15, 12, 12, 8, 5,
		11, 13, 13, 11, -3, 3, 8, 3,
		7, 7, 7, 5, 4, -3, -5, -3,
		4, 3, 13, 1, 2, 1, -1, 2,
		3, 5, 8, 4, -5, -6, -8, -11,
		-4, 0, -5, -1, -7, -12, -8, -16,
		-6, -6, 0, 2, -9, -9, -11, -3,
		-9, 2, 3, -1, -5, -13, 4, -20],
	QUEEN: [
		-9, 22, 22, 27, 27, 19, 10, 20,
		-17, 20, 32, 41, 58, 25, 30, 0,
		-20, 6, 9, 49, 47, 35, 19, 9,
		3, 22, 24, 45, 57, 40, 57, 36,
		-18, 28, 19, 47, 31, 34, 39, 23,
		-16, -27, 15, 6, 9, 17, 10, 5,
		-22, -23, -30, -16, -16, -23, -36, -32,
		-33, -28, -22, -43, -5, -32, -20, -41],
	KING: [
		-74, -35, -18, -18, -11, 15, 4, -17,
		-12, 17, 14, 17, 17, 38, 23, 11,
		10, 17, 23, 15, 20, 45, 44, 13,
		-8, 22, 24, 27, 26, 33, 26, 3,
		-18, -4, 21, 24, 27, 23, 9, -11,
		-19, -3, 11, 21, 23, 16, 7, -9,
		-27, -11, 4, 13, 14, 4, -5, -17,
		-53, -34, -21, -11, -28, -14, -24, -43]}
## Pawn structure on top (middlegame, endgame): a passed pawn by how far it has come (its rank
## from its own side), and a doubled or isolated one.
const PASSED_MG := [0, 0, 5, 10, 20, 35, 55, 0]
const PASSED_EG := [0, 5, 10, 20, 35, 55, 80, 0]
const DOUBLED := Vector2i(-10, -25)
const ISOLATED := Vector2i(-10, -15)
const BISHOP_PAIR := Vector2i(30, 50)

static var _knight: Array = []
static var _king: Array = []
static var _rays: Array = []
static var _rights: PackedInt32Array
static var _keys: PackedInt64Array
## PeSTO value of each piece (index piece + 6) on each square, White positive: [(piece + 6) * 64 + sq].
static var _mg: PackedInt32Array
static var _eg: PackedInt32Array

var board := PackedInt32Array()
var side := FIRST
var castling := 15
var ep := -1
var halfmove := 0
var fullmove := 1
var kings := PackedInt32Array([4, 60])
var hash := 0
## Whether `hash` holds the en-passant square: only when a pawn could really take there, so
## positions that differ only by an unusable en-passant square count as the same for repetition.
var ep_hashed := false
## Position hashes since the start, the current one last (repetitions).
var history := PackedInt64Array()
var _undo: Array = []
## Kept up to date move by move for the engine: the PeSTO sums (White's view), the phase, a hash of
## the pawns alone (the pawn structure cache) and how many of each piece (index piece + 6).
var mg := 0
var eg := 0
var phase := 0
var pawn_key := 0
var counts := PackedInt32Array()
var _pawn_cache := {}

func _init() -> void:
	_tables()
	board.resize(64)
	for file in 8:
		board[file] = START[file]
		board[8 + file] = PAWN
		board[48 + file] = -PAWN
		board[56 + file] = -START[file]
	hash = _full_hash()
	history.append(hash)
	_full_eval()

## The tables every instance shares; built on the main thread before any engine thread reads them.
static func _tables() -> void:
	if not _knight.is_empty(): return
	for sq in 64:
		var at := Vector2i(sq & 7, sq >> 3)
		var jumps := PackedInt32Array()
		for step: Vector2i in KNIGHT_JUMPS:
			var to: Vector2i = at + step
			if to.x >= 0 and to.x < 8 and to.y >= 0 and to.y < 8: jumps.append(to.y * 8 + to.x)
		_knight.append(jumps)
		var around := PackedInt32Array()
		var rays: Array = []
		for dir: Vector2i in DIRS:
			var to: Vector2i = at + dir
			if to.x >= 0 and to.x < 8 and to.y >= 0 and to.y < 8: around.append(to.y * 8 + to.x)
			var ray := PackedInt32Array()
			while to.x >= 0 and to.x < 8 and to.y >= 0 and to.y < 8:
				ray.append(to.y * 8 + to.x)
				to += dir
			rays.append(ray)
		_king.append(around)
		_rays.append(rays)
	_rights.resize(64)
	_rights.fill(15)
	_rights[0] = 13; _rights[4] = 12; _rights[7] = 14
	_rights[56] = 7; _rights[60] = 3; _rights[63] = 11
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5eed_c4e55
	_keys.resize(64 * 13 + 1 + 16 + 8)
	for i in _keys.size(): _keys[i] = (int(rng.randi()) << 32) ^ int(rng.randi())
	_mg.resize(13 * 64)
	_eg.resize(13 * 64)
	for kind in range(PAWN, KING + 1):
		for sq in 64:
			_mg[(kind + 6) * 64 + sq] = MG_VALUE[kind] + MG_PST[kind][sq ^ 56]
			_eg[(kind + 6) * 64 + sq] = EG_VALUE[kind] + EG_PST[kind][sq ^ 56]
			_mg[(6 - kind) * 64 + sq] = -(MG_VALUE[kind] + MG_PST[kind][sq])
			_eg[(6 - kind) * 64 + sq] = -(EG_VALUE[kind] + EG_PST[kind][sq])

static func _piece_key(sq: int, piece: int) -> int:
	return _keys[sq * 13 + piece + 6]

func _full_hash() -> int:
	var h := 0
	for sq in 64:
		if board[sq] != 0: h ^= _piece_key(sq, board[sq])
	if side == -1: h ^= _keys[832]
	h ^= _keys[833 + castling]
	ep_hashed = _ep_live()
	if ep_hashed: h ^= _keys[849 + (ep & 7)]
	return h

## A pawn of the side to move stands beside the pawn that just went two squares.
func _ep_live() -> bool:
	if ep < 0: return false
	var pushed := ep - 8 * side
	for df: int in [-1, 1]:
		var file := (pushed & 7) + df
		if file >= 0 and file < 8 and board[pushed + df] == PAWN * side: return true
	return false

## Sets up a position from FEN (tests and puzzles).
func load_fen(fen: String) -> void:
	var fields := fen.split(" ")
	board.fill(0)
	var rank := 7
	var file := 0
	for c in fields[0]:
		if c == "/": rank -= 1; file = 0
		elif c.is_valid_int(): file += int(c)
		else:
			var kind := " pnbrqk".find(c.to_lower())
			board[rank * 8 + file] = kind if c == c.to_upper() else -kind
			if kind == KING: kings[0 if c == c.to_upper() else 1] = rank * 8 + file
			file += 1
	side = 1 if fields.size() < 2 or fields[1] == "w" else -1
	castling = 0
	if fields.size() > 2:
		for c in fields[2]: castling |= {"K": 1, "Q": 2, "k": 4, "q": 8}.get(c, 0)
	ep = -1
	if fields.size() > 3 and fields[3] != "-": ep = (int(fields[3][1]) - 1) * 8 + "abcdefgh".find(fields[3][0])
	halfmove = int(fields[4]) if fields.size() > 4 else 0
	fullmove = int(fields[5]) if fields.size() > 5 else 1
	hash = _full_hash()
	history = PackedInt64Array([hash])
	_undo.clear()
	_full_eval()

func _full_eval() -> void:
	mg = 0; eg = 0; phase = 0; pawn_key = 0
	counts.resize(13)
	counts.fill(0)
	for sq in 64:
		var piece := board[sq]
		if piece == 0: continue
		mg += _mg[(piece + 6) * 64 + sq]
		eg += _eg[(piece + 6) * 64 + sq]
		phase += PHASE_INC[absi(piece)]
		counts[piece + 6] += 1
		if absi(piece) == PAWN: pawn_key ^= _piece_key(sq, piece)

## An independent copy for a worker thread (board_engine.gd).
func copy() -> RefCounted:
	var other: RefCounted = get_script().new()
	other.board = board.duplicate()
	other.side = side; other.castling = castling; other.ep = ep
	other.halfmove = halfmove; other.fullmove = fullmove
	other.kings = kings.duplicate(); other.hash = hash; other.ep_hashed = ep_hashed
	other.history = history.duplicate()
	other.mg = mg; other.eg = eg; other.phase = phase; other.pawn_key = pawn_key
	other.counts = counts.duplicate()
	return other

# ------------------------------------------------------------------ moves

static func from_sq(move: int) -> int: return move & 63
static func to_sq(move: int) -> int: return (move >> 6) & 63
static func promotion(move: int) -> int: return (move >> 12) & 7
static func flags(move: int) -> int: return move >> 16

## Every legal move for the side to move.
func moves() -> Array:
	return _legal(false)

## The engine's own move lists (board_engine.gd): pseudo-legal, every move or only captures and
## queen promotions; it plays each and skips the ones that left_in_check().
func search_moves(noisy_only: bool) -> PackedInt32Array:
	return _pseudo(noisy_only)

## Whether the side to move has a legal move at all (the engine's horizon tells a stalemate from
## a quiet position by it).
func has_moves() -> bool:
	for move: int in _pseudo(false):
		make(move)
		var legal := not left_in_check()
		unmake()
		if legal: return true
	return false

## After make(): the side that just moved left its own king attacked, so the move was not legal.
func left_in_check() -> bool:
	return attacked(kings[1 if side == 1 else 0], side)

## A pass, for the engine's null-move pruning: the other side moves twice.
func make_null() -> void:
	_undo.append([0, 0, castling, ep, halfmove, hash, ep_hashed, mg, eg, phase, pawn_key])
	if ep_hashed: hash ^= _keys[849 + (ep & 7)]
	ep = -1
	ep_hashed = false
	# No position before a pass repeats one after it.
	halfmove = 0
	side = -side
	hash ^= _keys[832]
	history.append(hash)

func unmake_null() -> void:
	var undo: Array = _undo.pop_back()
	history.resize(history.size() - 1)
	side = -side
	ep = undo[3]; halfmove = undo[4]; hash = undo[5]; ep_hashed = undo[6]

## Whether a pass is worth trying: the side to move has a piece besides king and pawns (with
## pawns alone, positions where any move hurts are common).
func null_ok() -> bool:
	for kind: int in [KNIGHT, BISHOP, ROOK, QUEEN]:
		if counts[kind * side + 6] > 0: return true
	return false

func _legal(captures_only: bool) -> Array:
	var out: Array = []
	var us := side
	var king_index := 0 if us == 1 else 1
	for move: int in _pseudo(captures_only):
		make(move)
		if not attacked(kings[king_index], -us): out.append(move)
		unmake()
	return out

func _pseudo(captures_only: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	for sq in 64:
		var kind := board[sq] * side
		if kind <= 0: continue
		match kind:
			PAWN: _pawn_moves(sq, out, captures_only)
			KNIGHT: _step_moves(sq, _knight[sq], out, captures_only)
			BISHOP: _slide_moves(sq, 4, 8, out, captures_only)
			ROOK: _slide_moves(sq, 0, 4, out, captures_only)
			QUEEN: _slide_moves(sq, 0, 8, out, captures_only)
			KING:
				_step_moves(sq, _king[sq], out, captures_only)
				if not captures_only: _castles(sq, out)
	return out

func _pawn_moves(sq: int, out: PackedInt32Array, captures_only: bool) -> void:
	var step := 8 * side
	var rank := sq >> 3
	var file := sq & 7
	var one := sq + step
	var last := (one >> 3) == (7 if side == 1 else 0)
	if board[one] == 0 and (not captures_only or last):
		if last:
			for promo: int in ([QUEEN] if captures_only else [QUEEN, ROOK, BISHOP, KNIGHT]): out.append(sq | one << 6 | promo << 12)
		else:
			out.append(sq | one << 6)
			if rank == (1 if side == 1 else 6) and board[one + step] == 0: out.append(sq | (one + step) << 6 | DOUBLE << 16)
	for df: int in [-1, 1]:
		if file + df < 0 or file + df > 7: continue
		var to := one + df
		if board[to] * side < 0:
			if last:
				for promo: int in ([QUEEN] if captures_only else [QUEEN, ROOK, BISHOP, KNIGHT]): out.append(sq | to << 6 | promo << 12 | CAPTURE << 16)
			else: out.append(sq | to << 6 | CAPTURE << 16)
		elif to == ep: out.append(sq | to << 6 | (CAPTURE | EN_PASSANT) << 16)

func _step_moves(sq: int, targets: PackedInt32Array, out: PackedInt32Array, captures_only: bool) -> void:
	for to in targets:
		var there := board[to] * side
		if there > 0: continue
		if there < 0: out.append(sq | to << 6 | CAPTURE << 16)
		elif not captures_only: out.append(sq | to << 6)

func _slide_moves(sq: int, first: int, last: int, out: PackedInt32Array, captures_only: bool) -> void:
	var rays: Array = _rays[sq]
	for d in range(first, last):
		for to: int in rays[d]:
			var there := board[to] * side
			if there == 0:
				if not captures_only: out.append(sq | to << 6)
				continue
			if there < 0: out.append(sq | to << 6 | CAPTURE << 16)
			break

func _castles(sq: int, out: PackedInt32Array) -> void:
	var home := 0 if side == 1 else 56
	if sq != home + 4: return
	var short_right := 1 if side == 1 else 4
	var long_right := 2 if side == 1 else 8
	if castling & short_right and board[home + 5] == 0 and board[home + 6] == 0 and board[home + 7] == ROOK * side \
			and not attacked(home + 4, -side) and not attacked(home + 5, -side) and not attacked(home + 6, -side):
		out.append(sq | (home + 6) << 6 | CASTLE << 16)
	if castling & long_right and board[home + 3] == 0 and board[home + 2] == 0 and board[home + 1] == 0 and board[home] == ROOK * side \
			and not attacked(home + 4, -side) and not attacked(home + 3, -side) and not attacked(home + 2, -side):
		out.append(sq | (home + 2) << 6 | CASTLE << 16)

## Whether `by` (1 white, -1 black) attacks square `sq`.
func attacked(sq: int, by: int) -> bool:
	var file := sq & 7
	var from := sq - 8 * by
	if from >= 0 and from < 64:
		if file > 0 and board[from - 1] == PAWN * by: return true
		if file < 7 and board[from + 1] == PAWN * by: return true
	for at: int in _knight[sq]:
		if board[at] == KNIGHT * by: return true
	for at: int in _king[sq]:
		if board[at] == KING * by: return true
	var rays: Array = _rays[sq]
	for d in 8:
		for at: int in rays[d]:
			var piece := board[at]
			if piece == 0: continue
			var kind := piece * by
			if kind == QUEEN or (kind == ROOK and d < 4) or (kind == BISHOP and d >= 4): return true
			break
	return false

func in_check() -> bool:
	return attacked(kings[0 if side == 1 else 1], -side)

func make(move: int) -> void:
	var from := move & 63
	var to := (move >> 6) & 63
	var promo := (move >> 12) & 7
	var flag := move >> 16
	var piece := board[from]
	var taken_at := to - 8 * side if flag & EN_PASSANT else to
	var taken := board[taken_at]
	_undo.append([move, taken, castling, ep, halfmove, hash, ep_hashed, mg, eg, phase, pawn_key])
	hash ^= _keys[833 + castling]
	if ep_hashed: hash ^= _keys[849 + (ep & 7)]
	hash ^= _piece_key(from, piece)
	board[from] = 0
	mg -= _mg[(piece + 6) * 64 + from]
	eg -= _eg[(piece + 6) * 64 + from]
	if taken != 0:
		hash ^= _piece_key(taken_at, taken)
		board[taken_at] = 0
		mg -= _mg[(taken + 6) * 64 + taken_at]
		eg -= _eg[(taken + 6) * 64 + taken_at]
		phase -= PHASE_INC[absi(taken)]
		counts[taken + 6] -= 1
		if absi(taken) == PAWN: pawn_key ^= _piece_key(taken_at, taken)
	var placed := piece if promo == 0 else promo * side
	board[to] = placed
	hash ^= _piece_key(to, placed)
	mg += _mg[(placed + 6) * 64 + to]
	eg += _eg[(placed + 6) * 64 + to]
	if piece * side == PAWN:
		pawn_key ^= _piece_key(from, piece)
		if promo == 0: pawn_key ^= _piece_key(to, piece)
		else:
			phase += PHASE_INC[promo]
			counts[piece + 6] -= 1
			counts[placed + 6] += 1
	if flag & CASTLE:
		var rook_from := to + 1 if to & 7 == 6 else to - 2
		var rook_to := to - 1 if to & 7 == 6 else to + 1
		var rook := board[rook_from]
		board[rook_from] = 0; board[rook_to] = rook
		hash ^= _piece_key(rook_from, rook) ^ _piece_key(rook_to, rook)
		mg += _mg[(rook + 6) * 64 + rook_to] - _mg[(rook + 6) * 64 + rook_from]
		eg += _eg[(rook + 6) * 64 + rook_to] - _eg[(rook + 6) * 64 + rook_from]
	if piece * side == KING: kings[0 if side == 1 else 1] = to
	castling &= _rights[from] & _rights[to]
	ep = (from + to) >> 1 if flag & DOUBLE else -1
	halfmove = 0 if piece * side == PAWN or taken != 0 else halfmove + 1
	if side == -1: fullmove += 1
	side = -side
	hash ^= _keys[832] ^ _keys[833 + castling]
	ep_hashed = _ep_live()
	if ep_hashed: hash ^= _keys[849 + (ep & 7)]
	history.append(hash)

func unmake() -> void:
	var undo: Array = _undo.pop_back()
	var move: int = undo[0]
	history.resize(history.size() - 1)
	side = -side
	if side == -1: fullmove -= 1
	var from := move & 63
	var to := (move >> 6) & 63
	var flag := move >> 16
	var piece := PAWN * side if (move >> 12) & 7 != 0 else board[to]
	board[from] = piece
	board[to] = 0
	var taken: int = undo[1]
	if flag & EN_PASSANT: board[to - 8 * side] = taken
	else: board[to] = taken
	if flag & CASTLE:
		var rook_from := to + 1 if to & 7 == 6 else to - 2
		var rook_to := to - 1 if to & 7 == 6 else to + 1
		board[rook_from] = board[rook_to]; board[rook_to] = 0
	if piece * side == KING: kings[0 if side == 1 else 1] = from
	castling = undo[2]; ep = undo[3]; halfmove = undo[4]; hash = undo[5]; ep_hashed = undo[6]
	mg = undo[7]; eg = undo[8]; phase = undo[9]; pawn_key = undo[10]
	if taken != 0: counts[taken + 6] += 1
	if (move >> 12) & 7 != 0:
		counts[((move >> 12) & 7) * side + 6] -= 1
		counts[PAWN * side + 6] += 1

# ------------------------------------------------------------------ the game's end

## {"over": false} or {"over": true, "winner": 1/-1/0, "reason": "checkmate"/"stalemate"/...}.
func status() -> Dictionary:
	if moves().is_empty():
		if in_check(): return {"over": true, "winner": -side, "reason": "checkmate"}
		return {"over": true, "winner": 0, "reason": "stalemate"}
	if halfmove >= 100: return {"over": true, "winner": 0, "reason": "fifty moves without a capture or pawn move"}
	if history.count(hash) >= 3: return {"over": true, "winner": 0, "reason": "the same position three times"}
	if _bare(): return {"over": true, "winner": 0, "reason": "not enough pieces left to checkmate"}
	return {"over": false}

## The position already came up since the last capture or pawn move (the engine scores it a draw).
func repeated() -> bool:
	var last := history.size() - 1
	var oldest := maxi(0, last - halfmove)
	for i in range(last - 2, oldest - 1, -2):
		if history[i] == hash: return true
	return false

## Kings alone, or with a single bishop or knight.
func _bare() -> bool:
	var minors := 0
	for piece in board:
		var kind := absi(piece)
		if kind == PAWN or kind == ROOK or kind == QUEEN: return false
		if kind == KNIGHT or kind == BISHOP: minors += 1
	return minors <= 1

## The engine's score for a position with no legal move, `ply` moves into its search.
func terminal_score(ply: int) -> int:
	return -100000 + ply if in_check() else 0

# ------------------------------------------------------------------ the engine's score

## Material and placement from the side to move's view, in centipawns.
func evaluate() -> int:
	var p := mini(phase, 24)
	var mid := mg
	var end := eg
	var pawns: PackedInt32Array
	if _pawn_cache.has(pawn_key): pawns = _pawn_cache[pawn_key]
	else:
		pawns = _pawn_structure()
		_pawn_cache[pawn_key] = pawns
	mid += pawns[0]
	end += pawns[1]
	if counts[BISHOP + 6] >= 2: mid += BISHOP_PAIR.x; end += BISHOP_PAIR.y
	if counts[6 - BISHOP] >= 2: mid -= BISHOP_PAIR.x; end -= BISHOP_PAIR.y
	var score := (mid * p + end * (24 - p)) / 24
	if p <= 8 and absi(score) > 300: score += _mop_up(signi(score))
	return score * side

## Passed, doubled and isolated pawns for both sides, White's view: [middlegame, endgame].
func _pawn_structure() -> PackedInt32Array:
	var files := PackedInt32Array()
	files.resize(16)
	# Per file, White's lowest pawn rank and Black's highest (who can still stop a passer).
	var white_low := PackedInt32Array([8, 8, 8, 8, 8, 8, 8, 8])
	var black_high := PackedInt32Array([-1, -1, -1, -1, -1, -1, -1, -1])
	var pawns := PackedInt32Array()
	for sq in 64:
		var piece := board[sq]
		if absi(piece) != PAWN: continue
		pawns.append(sq)
		var file := sq & 7
		var rank := sq >> 3
		if piece > 0:
			files[file] += 1
			white_low[file] = mini(white_low[file], rank)
		else:
			files[8 + file] += 1
			black_high[file] = maxi(black_high[file], rank)
	var mid := 0
	var end := 0
	for sq in pawns:
		var white := board[sq] > 0
		var file := sq & 7
		var rank := sq >> 3
		var own := 0 if white else 8
		var passed := true
		var neighbours := 0
		for f in range(maxi(0, file - 1), mini(7, file + 1) + 1):
			if f != file: neighbours += files[own + f]
			if white and black_high[f] > rank: passed = false
			if not white and white_low[f] < rank: passed = false
		var sign := 1 if white else -1
		if passed:
			var advanced := rank if white else 7 - rank
			mid += sign * PASSED_MG[advanced]
			end += sign * PASSED_EG[advanced]
		if neighbours == 0:
			mid += sign * ISOLATED.x
			end += sign * ISOLATED.y
	for f in 8:
		if files[f] > 1: mid += DOUBLED.x * (files[f] - 1); end += DOUBLED.y * (files[f] - 1)
		if files[8 + f] > 1: mid -= DOUBLED.x * (files[8 + f] - 1); end -= DOUBLED.y * (files[8 + f] - 1)
	return PackedInt32Array([mid, end])

## A winning side in the endgame herds the lone king to the edge and walks its own king over.
func _mop_up(winner: int) -> int:
	var loser_king := kings[1 if winner == 1 else 0]
	var winner_king := kings[0 if winner == 1 else 1]
	var lx := loser_king & 7
	var ly := loser_king >> 3
	var edge := maxi(3 - lx, lx - 4) + maxi(3 - ly, ly - 4)
	var near := 14 - (absi(lx - (winner_king & 7)) + absi(ly - (winner_king >> 3)))
	return winner * (edge * 10 + near * 4)

## How promising a move looks before searching it (captures of big pieces by small ones first).
func order_key(move: int) -> int:
	var key := 0
	if (move >> 16) & CAPTURE:
		var victim := absi(board[(move >> 6) & 63]) if not (move >> 16) & EN_PASSANT else PAWN
		key += 10000 + VALUES[victim] * 10 - VALUES[absi(board[move & 63])] / 10
	if (move >> 12) & 7 != 0: key += 8000 + VALUES[(move >> 12) & 7]
	return key

# ------------------------------------------------------------------ words

static func square_name(sq: int) -> String:
	return "abcdefgh"[sq & 7] + str((sq >> 3) + 1)

func piece_at(sq: int) -> int:
	return board[sq]

## The move from `from` to `to` (promoting to `promo`, queen when 0), or -1 when it is not legal.
func find_move(from: int, to: int, promo := 0) -> int:
	var found := -1
	for move: int in moves():
		if move & 63 != from or (move >> 6) & 63 != to: continue
		var p := (move >> 12) & 7
		if p == 0 or p == (promo if promo != 0 else QUEEN): return move
		found = move
	return found

## Squares the piece on `from` can move to.
func targets_from(from: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for move: int in moves():
		if move & 63 == from and not out.has((move >> 6) & 63): out.append((move >> 6) & 63)
	return out

## Whether moving from `from` to `to` promotes a pawn (the board asks which piece first).
func promotes(from: int, to: int) -> bool:
	return absi(board[from]) == PAWN and (to >> 3) in [0, 7]

## Before the move is made: {"san", "words", "piece", "captured", "check", "mate", "castle", "promotion"}.
func describe(move: int) -> Dictionary:
	var from := move & 63
	var to := (move >> 6) & 63
	var flag := move >> 16
	var promo := (move >> 12) & 7
	var kind := absi(board[from])
	var taken := PAWN if flag & EN_PASSANT else absi(board[to])
	var san := ""
	var castle := ""
	if flag & CASTLE:
		castle = "kingside" if to & 7 == 6 else "queenside"
		san = "O-O" if castle == "kingside" else "O-O-O"
	else:
		if kind == PAWN:
			if taken != 0: san = "abcdefgh"[from & 7]
		else:
			san = LETTERS[kind] + _disambiguation(move, kind)
		if taken != 0: san += "x"
		san += square_name(to)
		if promo != 0: san += "=" + LETTERS[promo]
	make(move)
	var check := in_check()
	var mate := check and moves().is_empty()
	unmake()
	if mate: san += "#"
	elif check: san += "+"
	var words := ""
	if castle != "": words = "castles %s" % castle
	else:
		words = "%s from %s to %s" % [NAMES[kind], square_name(from), square_name(to)]
		if taken != 0: words += ", taking a " + NAMES[taken] + (" en passant" if flag & EN_PASSANT else "")
		if promo != 0: words += ", promoting to a " + NAMES[promo]
	if mate: words += ", checkmate"
	elif check: words += ", check"
	return {"san": san, "words": words, "piece": NAMES[kind], "captured": NAMES[taken] if taken != 0 else "",
		"check": check, "mate": mate, "castle": castle, "promotion": NAMES[promo] if promo != 0 else "",
		"from": square_name(from), "to": square_name(to)}

## What kind of move this is, for a player's style (board_engine.gd TASTES): a capture or a trade,
## a check, castling, a promotion, developing a minor piece, a retreat, the centre, and how much
## closer it brings the piece to the enemy king.
func style_traits(move: int) -> Dictionary:
	var from := move & 63
	var to := (move >> 6) & 63
	var flag := move >> 16
	var kind := absi(board[from])
	var taken := PAWN if flag & EN_PASSANT else absi(board[to])
	var enemy_king := kings[1 if side == 1 else 0]
	var before := maxi(absi((from & 7) - (enemy_king & 7)), absi((from >> 3) - (enemy_king >> 3)))
	var after := maxi(absi((to & 7) - (enemy_king & 7)), absi((to >> 3) - (enemy_king >> 3)))
	var rank_from := from >> 3 if side == 1 else 7 - (from >> 3)
	var rank_to := to >> 3 if side == 1 else 7 - (to >> 3)
	make(move)
	var check := in_check()
	unmake()
	return {"capture": taken != 0, "trade": taken != 0 and absi(VALUES[taken] - VALUES[kind]) <= 30, "check": check,
		"castle": flag & CASTLE != 0, "promote": (move >> 12) & 7 != 0, "closer": float(before - after) if kind != KING else 0.0,
		"near_king": after <= 2 and kind != KING, "develop": (kind == KNIGHT or kind == BISHOP) and rank_from == 0,
		"retreat": rank_to < rank_from and kind != PAWN, "center": to in [27, 28, 35, 36], "quiet": taken == 0 and not check,
		"multi": false, "back_row": false}

func _disambiguation(move: int, kind: int) -> String:
	var from := move & 63
	var to := (move >> 6) & 63
	var same_file := false
	var same_rank := false
	var other := false
	for m: int in moves():
		var f := m & 63
		if f == from or (m >> 6) & 63 != to or absi(board[f]) != kind: continue
		other = true
		if f & 7 == from & 7: same_file = true
		if f >> 3 == from >> 3: same_rank = true
	if not other: return ""
	if not same_file: return "abcdefgh"[from & 7]
	if not same_rank: return str((from >> 3) + 1)
	return square_name(from)

## Material each side has on the board, in pawns: {1: white, -1: black}.
func material() -> Dictionary:
	var total := {1: 0, -1: 0}
	for piece in board:
		if piece != 0 and absi(piece) != KING: total[signi(piece)] += VALUES[absi(piece)] / 100
	return total

## The pieces `owner` (1/-1) has lost, biggest first ("queen, 2 pawns").
func losses(owner: int) -> String:
	var start := {PAWN: 8, KNIGHT: 2, BISHOP: 2, ROOK: 2, QUEEN: 1}
	for piece in board:
		if piece * owner > 0 and start.has(piece * owner): start[piece * owner] -= 1
	var parts: PackedStringArray = []
	for kind: int in [QUEEN, ROOK, BISHOP, KNIGHT, PAWN]:
		var lost: int = start[kind]
		if lost == 1: parts.append("a " + NAMES[kind])
		elif lost > 1: parts.append("%d %ss" % [lost, NAMES[kind]])
	return ", ".join(parts)

## Where `owner`'s pieces stand, by kind ("king g1, queen d1, rooks a1 f1, ..., pawns a2 b2").
func position_words(owner: int) -> String:
	var parts: PackedStringArray = []
	for kind: int in [KING, QUEEN, ROOK, BISHOP, KNIGHT, PAWN]:
		var squares: PackedStringArray = []
		for i in 64:
			var sq := (i & 7) * 8 + (i >> 3)  # file by file, a to h
			if board[sq] == kind * owner: squares.append(square_name(sq))
		if not squares.is_empty(): parts.append("%s%s %s" % [NAMES[kind], "s" if squares.size() > 1 else "", " ".join(squares)])
	return ", ".join(parts)
