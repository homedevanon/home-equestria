# Local port of Impressions with July 30 DinoDino signed-delta amendment. See SOURCE.json.
extends Node
## RelationshipManager — directional relationship progress tracking.
##
## Implements design doc §2.1 (v4). For each character (canonical tag, e.g. "twi")
## and axis, the player sets a trajectory (pole + optional goal tier); the AI emits
## non-negative progress deltas which are staged per response and committed only
## when the response is accepted (see §3.2 / §3.3 for commit points).
##
## Score model: signed progress in [-100, 100]. score >= 0 is progress up the
## ACTIVE pole's ladder; score < 0 means the relationship is still in the OPPOSITE
## ladder's territory and is unwinding (produced by a standing-preserving pole flip).
##
## All AI-facing strings produced here are tier-LABELS ONLY — raw numbers must
## never reach a prompt or a generated summary.

signal relationships_changed

const TAG := "RelationshipManager"

const SCORE_MIN := -100
const SCORE_MAX := 100
const POLE_POSITIVE := "positive"
const POLE_NEGATIVE := "negative"
const FLIP_MODE_FLIP := "flip"
const FLIP_MODE_RESET := "reset"

const DEFAULT_RESPONSE_CAP := 5
const DEFAULT_SCENARIO_BUDGET := 20

## Default axis set (design doc §2.1). Romance moves slower by default.
const DEFAULT_AXIS_CONFIG := {
	"friendship": {
		"cap": 5, "budget": 20, "description": "",
		"positive": [[0, "Neutral"], [25, "Friend"], [55, "Close Friend"], [85, "Best Friend"]],
		"negative": [[0, "Neutral"], [25, "Annoying"], [55, "Enemy"], [85, "Nemesis"]],
	},
	"romance": {
		"cap": 2, "budget": 8, "description": "",
		"positive": [[0, "Neutral"], [25, "Attracted"], [55, "Strong Romantic Interest"], [85, "Soulmate"]],
		"negative": [[0, "Neutral"], [25, "Disinterested"], [55, "Unattracted"], [85, "Repulsed"]],
	},
	"respect": {
		"cap": 5, "budget": 20, "description": "",
		"positive": [[0, "Neutral"], [25, "Respect"], [55, "High Regard"], [85, "Deep Admiration"]],
		"negative": [[0, "Neutral"], [25, "Offputting"], [55, "Contempt"], [85, "Despised"]],
	},
	"emotional_closeness": {
		"cap": 5, "budget": 20, "description": "",
		"positive": [[0, "Neutral"], [25, "Comfortable"], [55, "Emotionally Close"], [85, "Deeply Intimate"]],
		"negative": [[0, "Neutral"], [25, "Awkward"], [55, "Distant"], [85, "Emotionally Toxic"]],
	},
	"humor_intellect": {
		"cap": 5, "budget": 20,
		"description": "how compatible this character finds the player's humor and way of thinking",
		"positive": [[0, "Neutral"], [25, "Compatible"], [55, "Highly Compatible"], [85, "Kindred Spirit"]],
		"negative": [[0, "Neutral"], [25, "Slightly Incompatible"], [55, "Low Compatibility"], [85, "Exhausting"]],
	},
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

var axis_list: Array[String] = []
var axis_descriptions: Dictionary = {}      # axis -> String
var axis_caps: Dictionary = {}              # axis -> int (per-response cap, >= 0)
var scenario_budgets: Dictionary = {}       # axis -> int (per-scenario budget, >= 0)
var axis_ladders: Dictionary = {}           # axis -> { "positive": Array, "negative": Array }
var axis_default_poles: Dictionary = {}     # axis -> POLE_* (pole given to new character entries)
# P7: per-axis scene-end drift. + grows toward the goal, - decays toward Neutral;
# 0 = off. This is the GLOBAL default per axis (set in Axis Config). A character may
# override it via a "decay_growth" key in their per-axis entry (Characters sub-menu);
# get_effective_decay_growth() resolves override-then-global.
var axis_decay_growth: Dictionary = {}      # axis -> int (signed; per-scene drift)

## Characters present in the current scene, captured at session_started (the roster
## is cleared by end_session before session_ended fires, so it must be read at the
## start). Used at scene end to apply per-axis decay/growth. Cleared each scene end.
var _scene_participants: Dictionary = {}     # normalized tag -> true

## Observability for the Impressions Menu ("last exchange scored: yes/no", §2.2).
## Set by the AI pipelines after each response; not persisted.
var last_exchange_scored: bool = false

# char_tag -> { axis -> { "score": int, "pole": String, "goal": int } }
var _data: Dictionary = {}
# char_tag -> { axis -> int } progress applied this scenario session
var _scenario_spent: Dictionary = {}
# token -> staged batch: { char_tag -> { axis -> int } }
var _pending: Dictionary = {}
var _next_pending_token: int = 1


# Home: Equestria supplies world persistence and the conversation lifecycle.
class QuietLog:
	static func d(_tag, _message): pass
const Log = QuietLog
func _ready() -> void:
	_install_defaults()

func _on_session_ended() -> void:
	# Order matters: apply per-axis decay/growth (which reads this scene's spend to
	# cap positive drift to the remaining budget) BEFORE the spend is cleared.
	_apply_scene_decay_growth()
	reset_scenario_spend()
	_scene_participants.clear()


## P7: at scene end, drift each participant's axes. Growth (positive) is capped by the
## axis's REMAINING per-scenario budget for that character (so AI-awarded points + growth
## never exceed the budget) and by the goal. Decay (negative) moves the other way. At or
## above Neutral, decay floors at 0 (it never flips a relationship on its own). While a
## relationship is unwinding (score < 0 after a pole flip), drift still applies: growth
## pulls back toward Neutral/goal and decay deepens the unwind, but only as far as the
## score held at the flip (the entry's "unwind_floor"). Emits relationships_changed once.
func _apply_scene_decay_growth() -> void:
	# Participants = those captured at session start, unioned with anyone the AI
	# actually scored this scene (covers characters who entered mid-scene).
	var tags := {}
	for tag in _scene_participants.keys():
		tags[tag] = true
	for tag in _scenario_spent.keys():
		tags[str(tag)] = true

	var changed := false
	for tag in tags.keys():
		for axis in axis_list:
			var dg := get_effective_decay_growth(tag, axis)
			if dg == 0:
				continue
			var old_score := get_score(tag, axis)
			var applied := dg
			if dg > 0:
				# Growth competes with AI-awarded points for the per-scenario budget.
				applied = mini(dg, get_scenario_remaining(tag, axis))
			if applied == 0:
				continue
			# Drift is additive along the signed axis. At or above Neutral the floor is
			# 0 — decay alone must never send a score negative (only a deliberate flip
			# does that). While unwinding (score < 0), growth pulls back toward Neutral/
			# goal and decay pushes further toward the old pole, but only as far as the
			# score held at the flip ("unwind_floor"); decay never passes the flip
			# magnitude. Absent a recorded flip, fall back to the current score (no deepen).
			var floor_bound := 0
			if old_score < 0:
				floor_bound = int(_peek_entry(tag, axis).get("unwind_floor", old_score))
			var new_score := clampi(old_score + applied, floor_bound, get_goal(tag, axis))
			if new_score == old_score:
				continue
			_ensure_entry(tag, axis)["score"] = new_score
			changed = true

	if changed:
		relationships_changed.emit()


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func get_score(character_tag: String, axis: String) -> int:
	var entry := _peek_entry(character_tag, axis)
	return int(entry.get("score", 0))


func get_pole(character_tag: String, axis: String) -> String:
	var entry := _peek_entry(character_tag, axis)
	return str(entry.get("pole", _default_pole_for(axis)))


func get_goal(character_tag: String, axis: String) -> int:
	var entry := _peek_entry(character_tag, axis)
	return int(entry.get("goal", SCORE_MAX))


## The threshold (Axis Config value) of the tier the current goal represents — i.e. the
## score at which the relationship reaches the chosen goal tier — as opposed to the
## internal band-top cap stored as "goal". Mirrors the goal dropdown's selection (the
## highest tier whose threshold <= goal, defaulting to the top tier). Display use.
func get_goal_tier_threshold(character_tag: String, axis: String) -> int:
	var ladder: Array = _ladder_for(axis, get_pole(character_tag, axis))
	if ladder.is_empty():
		return get_goal(character_tag, axis)
	var goal := get_goal(character_tag, axis)
	var top := SCORE_MIN
	var chosen := SCORE_MIN
	for tier in ladder:
		var t := int(tier[0])
		if t > top:
			top = t
		if t <= goal and t > chosen:
			chosen = t
	return chosen if chosen > SCORE_MIN else top


func get_scenario_remaining(character_tag: String, axis: String) -> int:
	var budget := int(scenario_budgets.get(axis, DEFAULT_SCENARIO_BUDGET))
	var spent := int(_scenario_spent.get(_normalize_tag(character_tag), {}).get(axis, 0))
	return maxi(0, budget - spent)


## Deep copy for UI use — the Impressions Menu must never touch _data directly.
func get_all_scores() -> Dictionary:
	return _data.duplicate(true)


## Tier label for the current standing, honoring the signed-progress mirror rule:
## score >= 0 reads the ACTIVE ladder; score < 0 reads the OPPOSITE ladder at abs(score).
func get_tier_label(character_tag: String, axis: String) -> String:
	var score := get_score(character_tag, axis)
	var pole := get_pole(character_tag, axis)
	var ladder_pole := pole
	if score < 0:
		ladder_pole = _opposite_pole(pole)
	return _label_on_ladder(axis, ladder_pole, absi(score))


# ---------------------------------------------------------------------------
# Player-facing mutations (the only paths that can move a score backward)
# ---------------------------------------------------------------------------

func set_score(character_tag: String, axis: String, value: int) -> void:
	if not _is_known_axis(axis):
		return
	var entry := _ensure_entry(character_tag, axis)
	# Manual edits may exceed the goal cap and may set unwinding values directly
	# (player authority outranks the goal clamp).
	entry["score"] = clampi(value, SCORE_MIN, SCORE_MAX)
	relationships_changed.emit()


## Switch the active ladder for a character/axis.
## mode == "flip" (default): keep standing by negating progress (score = -score);
## the relationship unwinds tier by tier through the old ladder. Double-flip is identity.
## mode == "reset": hard re-anchor at Neutral (score = 0).
## Both modes reset the goal to 100 (the menu offers a goal picker in the same dialog).
func set_pole(character_tag: String, axis: String, pole: String, mode: String = FLIP_MODE_FLIP) -> void:
	if not _is_known_axis(axis):
		return
	if pole != POLE_POSITIVE and pole != POLE_NEGATIVE:
		Log.d(TAG, "set_pole: invalid pole '%s'" % pole)
		return
	var entry := _ensure_entry(character_tag, axis)
	if str(entry.get("pole", "")) == pole:
		return
	entry["pole"] = pole
	if mode == FLIP_MODE_RESET:
		entry["score"] = 0
	else:
		entry["score"] = -int(entry.get("score", 0))
	# Record where this unwind begins so scene-end decay can't carry the score past the
	# flip magnitude. Only meaningful while unwinding (score < 0); cleared when the flip
	# leaves the score at/above Neutral (e.g. a double-flip back to forward progress, or
	# a reset).
	if int(entry.get("score", 0)) < 0:
		entry["unwind_floor"] = int(entry["score"])
	else:
		entry.erase("unwind_floor")
	entry["goal"] = SCORE_MAX
	relationships_changed.emit()


## Cap a trajectory short of the pole. Goal progress derives from the chosen tier's
## band on the ACTIVE ladder: one less than the NEXT tier's threshold
## (goal "Friend" with bands [25, 55) => goal = 54); the final tier => 100.
## Stored as the derived int so later ladder edits don't silently relocate goals.
func set_goal_tier(character_tag: String, axis: String, tier_index: int) -> void:
	if not _is_known_axis(axis):
		return
	var entry := _ensure_entry(character_tag, axis)
	var ladder: Array = _ladder_for(axis, str(entry.get("pole", POLE_POSITIVE)))
	if ladder.is_empty():
		return
	var idx := clampi(tier_index, 0, ladder.size() - 1)
	var this_threshold := int(ladder[idx][0])
	# Goal caps at one below the NEXT-higher threshold (smallest threshold strictly
	# greater than this tier's), found by value — independent of row order. If this
	# is the top tier (no higher threshold exists), the goal is the pole itself.
	var next_threshold := SCORE_MAX + 1
	for other in ladder:
		var t := int(other[0])
		if t > this_threshold and t < next_threshold:
			next_threshold = t
	if next_threshold > SCORE_MAX:
		entry["goal"] = SCORE_MAX
	else:
		entry["goal"] = clampi(next_threshold - 1, 0, SCORE_MAX)
	relationships_changed.emit()


# ---------------------------------------------------------------------------
# Delta application (engine path — non-negative only)
# ---------------------------------------------------------------------------

## Single owner of clamping (the parser never clamps). Three stages, in order:
##   1. Floor + per-response clamp: delta -> [0, axis_caps[axis]].
##   2. Scenario budget: delta -> min(delta, remaining budget).
##   3. Goal clamp: new score -> [SCORE_MIN, goal].
## The EFFECTIVE applied amount (stage 3 may reduce it) is what's charged to the
## scenario budget, so the budget always reflects real score movement.
## Returns the effective applied amount. Does NOT emit relationships_changed —
## commit_pending() emits once per batch.
func apply_delta(character_tag: String, axis: String, delta: int) -> int:
	if not _is_known_axis(axis):
		return 0
	# DinoDino amendment: deltas are SIGNED — hostile exchanges damage a dynamic.
	# Cap applies to magnitude; the scenario budget is charged on magnitude too.
	var cap := int(axis_caps.get(axis, DEFAULT_RESPONSE_CAP))
	var clamped := clampi(delta, -cap, cap)
	var remaining := get_scenario_remaining(character_tag, axis)
	if absi(clamped) > remaining:
		clamped = remaining * signi(clamped)
	if clamped == 0:
		return 0
	var entry := _ensure_entry(character_tag, axis)
	var old_score := int(entry.get("score", 0))
	var new_score := clampi(old_score + clamped, SCORE_MIN, int(entry.get("goal", SCORE_MAX)))
	var effective := new_score - old_score
	if effective == 0:
		return 0
	entry["score"] = new_score
	# Unwind complete (or never unwinding): drop any flip-magnitude floor so a later
	# non-flip dip can't inherit a stale one. A fresh flip re-records it.
	if new_score >= 0 and entry.has("unwind_floor"):
		entry.erase("unwind_floor")
	var tag := _normalize_tag(character_tag)
	if not _scenario_spent.has(tag):
		_scenario_spent[tag] = {}
	_scenario_spent[tag][axis] = int(_scenario_spent[tag].get(axis, 0)) + absi(effective)
	return effective


# ---------------------------------------------------------------------------
# Staging API (commit only when a response is KEPT — see §3.2 / §3.3)
# ---------------------------------------------------------------------------

## Validate and stage a parsed scoring batch. Unknown axes/tags are dropped with a
## log entry — the model writing "twilight" instead of canonical "twi" must not
## create a phantom record. Returns a token (0 if nothing survived validation).
func stage_deltas(scoring_data: Dictionary, known_tags: Array) -> int:
	var known := {}
	for raw_tag in known_tags:
		known[_normalize_tag(str(raw_tag))] = true

	var staged: Dictionary = {}
	for raw_tag in scoring_data.keys():
		var tag := _normalize_tag(str(raw_tag))
		if not known.has(tag):
			Log.d(TAG, "stage_deltas: dropping unknown character tag '%s'" % tag)
			continue
		var axes: Variant = scoring_data[raw_tag]
		if typeof(axes) != TYPE_DICTIONARY:
			continue
		var kept: Dictionary = {}
		for raw_axis in (axes as Dictionary).keys():
			var axis := str(raw_axis).strip_edges().to_lower()
			if not _is_known_axis(axis):
				Log.d(TAG, "stage_deltas: dropping unknown axis '%s' for '%s'" % [axis, tag])
				continue
			var value: Variant = (axes as Dictionary)[raw_axis]
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				continue
			var delta := int(round(float(value)))
			if delta != 0:
				kept[axis] = delta
		if not kept.is_empty():
			staged[tag] = kept

	if staged.is_empty():
		return 0
	var token := _next_pending_token
	_next_pending_token += 1
	_pending[token] = staged
	return token


## Apply a staged batch. Caps, budget, and goal are evaluated NOW — at the moment
## the exchange is accepted — not at stage time. Emits relationships_changed once.
func commit_pending(token: int) -> void:
	if token == 0 or not _pending.has(token):
		return
	var staged: Dictionary = _pending[token]
	_pending.erase(token)
	var applied_any := false
	for tag in staged.keys():
		for axis in staged[tag].keys():
			if apply_delta(str(tag), str(axis), int(staged[tag][axis])) != 0:
				applied_any = true
	if applied_any:
		relationships_changed.emit()


func discard_pending(token: int) -> void:
	if token != 0:
		_pending.erase(token)


# ---------------------------------------------------------------------------
# Axis management
# ---------------------------------------------------------------------------

## Adds an axis (normalized to lowercase snake_case — axis names double as JSON keys
## in AI output). Installs default cap, budget, and a default ladder pair.
## Returns the normalized name, or "" if rejected.
func add_axis(name: String, description: String = "") -> String:
	var axis := _normalize_axis_name(name)
	if axis.is_empty():
		Log.d(TAG, "add_axis: rejected invalid axis name '%s'" % name)
		return ""
	if _is_known_axis(axis):
		Log.d(TAG, "add_axis: axis '%s' already exists" % axis)
		return ""
	axis_list.append(axis)
	axis_caps[axis] = DEFAULT_RESPONSE_CAP
	scenario_budgets[axis] = DEFAULT_SCENARIO_BUDGET
	axis_descriptions[axis] = description.strip_edges()
	axis_default_poles[axis] = POLE_POSITIVE
	axis_decay_growth[axis] = 0
	axis_ladders[axis] = {
		POLE_POSITIVE: [[0, "Neutral"], [25, "Developing"], [55, "Strong"], [85, axis.capitalize()]],
		POLE_NEGATIVE: [[0, "Neutral"], [25, "Strained"], [55, "Poor"], [85, "Broken"]],
	}
	relationships_changed.emit()
	return axis


func remove_axis(name: String) -> void:
	var axis := _normalize_axis_name(name)
	if not _is_known_axis(axis):
		return
	axis_list.erase(axis)
	axis_caps.erase(axis)
	scenario_budgets.erase(axis)
	axis_descriptions.erase(axis)
	axis_default_poles.erase(axis)
	axis_decay_growth.erase(axis)
	axis_ladders.erase(axis)
	for tag in _data.keys():
		(_data[tag] as Dictionary).erase(axis)
	for tag in _scenario_spent.keys():
		(_scenario_spent[tag] as Dictionary).erase(axis)
	relationships_changed.emit()


func set_axis_caps(axis: String, cap: int) -> void:
	if not _is_known_axis(axis):
		return
	axis_caps[axis] = maxi(0, cap)
	relationships_changed.emit()


func set_scenario_budget(axis: String, budget: int) -> void:
	if not _is_known_axis(axis):
		return
	scenario_budgets[axis] = maxi(0, budget)
	relationships_changed.emit()


# ── P7: per-axis decay/growth (global default + per-character override) ──────────

## Global per-axis decay/growth (signed; + grows toward goal, - decays toward Neutral).
func get_axis_decay_growth(axis: String) -> int:
	return int(axis_decay_growth.get(axis, 0))


func set_axis_decay_growth(axis: String, value: int) -> void:
	if not _is_known_axis(axis):
		return
	axis_decay_growth[axis] = clampi(value, -SCORE_MAX, SCORE_MAX)
	relationships_changed.emit()


## Effective decay/growth for a specific character/axis: the per-character override
## (entry "decay_growth" key) when present, otherwise the global per-axis default.
func get_effective_decay_growth(character_tag: String, axis: String) -> int:
	var entry := _peek_entry(character_tag, axis)
	if entry.has("decay_growth"):
		return int(entry["decay_growth"])
	return int(axis_decay_growth.get(axis, 0))


## True if this character has an explicit per-axis decay/growth override.
func has_char_decay_growth_override(character_tag: String, axis: String) -> bool:
	return _peek_entry(character_tag, axis).has("decay_growth")


## Set a per-character decay/growth override (Characters sub-menu). Creating the
## entry if needed, so an override can be set before any score exists.
func set_char_decay_growth(character_tag: String, axis: String, value: int) -> void:
	if not _is_known_axis(axis):
		return
	var entry := _ensure_entry(character_tag, axis)
	entry["decay_growth"] = clampi(value, -SCORE_MAX, SCORE_MAX)
	relationships_changed.emit()


## Clear a per-character override, reverting that character/axis to the global value.
func clear_char_decay_growth(character_tag: String, axis: String) -> void:
	var entry := _peek_entry(character_tag, axis)
	if entry.has("decay_growth"):
		entry.erase("decay_growth")
		relationships_changed.emit()


func set_axis_description(axis: String, text: String) -> void:
	if not _is_known_axis(axis):
		return
	axis_descriptions[axis] = text.strip_edges()
	relationships_changed.emit()


func set_axis_default_pole(axis: String, pole: String) -> void:
	if not _is_known_axis(axis) or (pole != POLE_POSITIVE and pole != POLE_NEGATIVE):
		return
	axis_default_poles[axis] = pole
	relationships_changed.emit()


## Replace one pole's ladder. Entries are [threshold: int, label: String]; the
## manager sorts ascending, clamps thresholds to 0..100, and guarantees a Neutral
## root at threshold 0 (the menu enforces this in the UI; this is the backstop).
## Replace one pole's ladder. Entries are [threshold: int, label: String].
## Insertion order is PRESERVED (rows do not reorder when thresholds are edited);
## label lookup is threshold-based and order-independent (see _label_on_ladder).
## Thresholds must be unique within a ladder — a duplicate of an already-present
## threshold is dropped (so every score maps to exactly one tier). A Neutral root
## at threshold 0 is guaranteed.
func set_ladder(axis: String, pole: String, ladder: Array) -> void:
	if not _is_known_axis(axis) or (pole != POLE_POSITIVE and pole != POLE_NEGATIVE):
		return
	axis_ladders[axis][pole] = _clean_ladder_preserving_order(ladder)
	relationships_changed.emit()


# ---------------------------------------------------------------------------
# Scenario budget lifecycle
# ---------------------------------------------------------------------------

func reset_scenario_spend() -> void:
	_scenario_spent.clear()


# ---------------------------------------------------------------------------
# AI-facing strings (LABELS ONLY — never numbers)
# ---------------------------------------------------------------------------

## Current standing per character/axis, labels only.
## e.g. "Twilight (twi) — Friendship: Annoying; Emotional Closeness: Comfortable"
func get_relationship_context() -> String:
	var lines: Array[String] = []
	var tags := _data.keys()
	tags.sort()
	for tag in tags:
		var parts: Array[String] = []
		for axis in axis_list:
			if (_data[tag] as Dictionary).has(axis):
				parts.append("%s: %s" % [axis.capitalize(), get_tier_label(tag, axis)])
		if not parts.is_empty():
			lines.append("%s — %s" % [_format_character(tag), "; ".join(parts)])
	return "\n".join(lines)


## Output-format instruction block (§2.3). Valence-neutral framing; ONE line per
## present character per active axis — no exceptions (omitting default entries lets
## the model assume warm valence for hostile tracks: semantic inversion).
func get_scoring_instructions(known_tags: Array) -> String:
	var lines: Array[String] = []
	lines.append("## Relationship Progress Scoring (output format)")
	lines.append("Each character below has a set path for their relationship. At the end of your reply,")
	lines.append("append a single JSON object scoring how much this exchange ADVANCED each character's listed")
	lines.append("trajectory — regardless of whether the dynamic is warm or hostile. Deepening a rivalry counts")
	lines.append("as progress on a rivalry track exactly as warming counts on a friendship track.")

	for raw_tag in known_tags:
		var tag := _normalize_tag(str(raw_tag))
		if tag.is_empty():
			continue
		for axis in axis_list:
			lines.append(_trajectory_line(tag, axis))

	for axis in axis_list:
		var description := str(axis_descriptions.get(axis, "")).strip_edges()
		if not description.is_empty():
			lines.append("- %s: %s" % [axis, description])

	lines.append("Use ONLY the tags and axes listed. %s; NEGATIVE values mean the exchange" % _cap_sentence())
	lines.append("damaged that dynamic (coldness, cruelty, betrayal). Use 0 or omit the axis if the")
	lines.append("exchange did not move it. Most exchanges should produce 0 or a small value like 1 or -1.")
	lines.append("Example:")
	lines.append('{"fang": {"friendship": 1}, "trish": {"respect": -1}}')
	lines.append("Do not mention scores, trajectories, or this JSON block in the story text itself.")
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Save / load (nested inside StorySummaryManager state — see §3.1)
# ---------------------------------------------------------------------------

func get_save_state() -> Dictionary:
	return {
		"axis_list": axis_list.duplicate(),
		"axis_descriptions": axis_descriptions.duplicate(true),
		"axis_caps": axis_caps.duplicate(true),
		"scenario_budgets": scenario_budgets.duplicate(true),
		"axis_ladders": axis_ladders.duplicate(true),
		"axis_default_poles": axis_default_poles.duplicate(true),
		"axis_decay_growth": axis_decay_growth.duplicate(true),
		"data": _data.duplicate(true),
		"scenario_spent": _scenario_spent.duplicate(true),
	}


## Empty-dictionary contract: load_save_state({}) resets EVERYTHING to defaults.
## Callers rely on this for new games (see story_summary_manager.gd integration).
func load_save_state(data: Dictionary) -> void:
	_pending.clear()
	last_exchange_scored = false
	if data.is_empty():
		_install_defaults()
		relationships_changed.emit()
		return

	# Deserialized arrays are untyped in Godot 4 — assign(), never direct assignment.
	var raw_axes: Array = data.get("axis_list", [])
	var restored_axes: Array[String] = []
	for axis in raw_axes:
		restored_axes.append(str(axis))
	if restored_axes.is_empty():
		_install_defaults()
		relationships_changed.emit()
		return
	axis_list.assign(restored_axes)

	axis_descriptions = _to_string_dict(data.get("axis_descriptions", {}))
	axis_caps = _to_int_dict(data.get("axis_caps", {}), DEFAULT_RESPONSE_CAP)
	scenario_budgets = _to_int_dict(data.get("scenario_budgets", {}), DEFAULT_SCENARIO_BUDGET)
	axis_default_poles = _to_string_dict(data.get("axis_default_poles", {}))
	axis_decay_growth = _to_int_dict(data.get("axis_decay_growth", {}), 0)
	axis_ladders = {}
	var raw_ladders: Dictionary = data.get("axis_ladders", {})
	for axis in axis_list:
		var pair: Dictionary = raw_ladders.get(axis, {})
		axis_ladders[axis] = {
			POLE_POSITIVE: _sanitize_ladder(pair.get(POLE_POSITIVE, [])),
			POLE_NEGATIVE: _sanitize_ladder(pair.get(POLE_NEGATIVE, [])),
		}
		if not axis_caps.has(axis):
			axis_caps[axis] = DEFAULT_RESPONSE_CAP
		if not scenario_budgets.has(axis):
			scenario_budgets[axis] = DEFAULT_SCENARIO_BUDGET
		if not axis_default_poles.has(axis):
			axis_default_poles[axis] = POLE_POSITIVE
		if not axis_decay_growth.has(axis):
			axis_decay_growth[axis] = 0

	_data = {}
	var raw_data: Dictionary = data.get("data", {})
	for raw_tag in raw_data.keys():
		var tag := _normalize_tag(str(raw_tag))
		var axes: Variant = raw_data[raw_tag]
		if tag.is_empty() or typeof(axes) != TYPE_DICTIONARY:
			continue
		var record: Dictionary = {}
		for raw_axis in (axes as Dictionary).keys():
			var axis := str(raw_axis)
			if not _is_known_axis(axis):
				continue
			var entry: Variant = (axes as Dictionary)[raw_axis]
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var pole := str((entry as Dictionary).get("pole", _default_pole_for(axis)))
			if pole != POLE_POSITIVE and pole != POLE_NEGATIVE:
				pole = POLE_POSITIVE
			record[axis] = {
				"score": clampi(int((entry as Dictionary).get("score", 0)), SCORE_MIN, SCORE_MAX),
				"pole": pole,
				"goal": clampi(int((entry as Dictionary).get("goal", SCORE_MAX)), 0, SCORE_MAX),
			}
			# P7: preserve a per-character decay/growth override if one was saved.
			if (entry as Dictionary).has("decay_growth"):
				record[axis]["decay_growth"] = clampi(int((entry as Dictionary)["decay_growth"]), -SCORE_MAX, SCORE_MAX)
			# Preserve the unwind floor (flip magnitude) so scene-end decay still respects
			# it after a load. Only kept while the restored score is actually unwinding.
			if (entry as Dictionary).has("unwind_floor") and int(record[axis]["score"]) < 0:
				record[axis]["unwind_floor"] = clampi(int((entry as Dictionary)["unwind_floor"]), SCORE_MIN, 0)
		if not record.is_empty():
			_data[tag] = record

	_scenario_spent = {}
	var raw_spent: Dictionary = data.get("scenario_spent", {})
	for raw_tag in raw_spent.keys():
		var tag := _normalize_tag(str(raw_tag))
		if typeof(raw_spent[raw_tag]) == TYPE_DICTIONARY:
			_scenario_spent[tag] = _to_int_dict(raw_spent[raw_tag], 0)

	relationships_changed.emit()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _install_defaults() -> void:
	axis_list.assign([])
	axis_descriptions = {}
	axis_caps = {}
	scenario_budgets = {}
	axis_ladders = {}
	axis_default_poles = {}
	axis_decay_growth = {}
	_data = {}
	_scenario_spent = {}
	for axis in DEFAULT_AXIS_CONFIG.keys():
		var cfg: Dictionary = DEFAULT_AXIS_CONFIG[axis]
		axis_list.append(axis)
		axis_caps[axis] = int(cfg["cap"])
		scenario_budgets[axis] = int(cfg["budget"])
		axis_descriptions[axis] = str(cfg["description"])
		axis_default_poles[axis] = POLE_POSITIVE
		axis_decay_growth[axis] = 0
		axis_ladders[axis] = {
			POLE_POSITIVE: (cfg[POLE_POSITIVE] as Array).duplicate(true),
			POLE_NEGATIVE: (cfg[POLE_NEGATIVE] as Array).duplicate(true),
		}


func _normalize_tag(raw: String) -> String:
	return raw.strip_edges().to_lower()


func _normalize_axis_name(raw: String) -> String:
	var axis := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	var cleaned := ""
	for c in axis:
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_":
			cleaned += c
	return cleaned


func _is_known_axis(axis: String) -> bool:
	return axis in axis_list


func _default_pole_for(axis: String) -> String:
	return str(axis_default_poles.get(axis, POLE_POSITIVE))


func _opposite_pole(pole: String) -> String:
	return POLE_NEGATIVE if pole == POLE_POSITIVE else POLE_POSITIVE


func _ladder_for(axis: String, pole: String) -> Array:
	var pair: Dictionary = axis_ladders.get(axis, {})
	return pair.get(pole, [])


## Label for a given progress value. Order-independent: among all tiers whose
## threshold is <= progress, the one with the HIGHEST threshold wins. Thresholds
## are unique (enforced by set_ladder), so the winner is unambiguous.
func _label_on_ladder(axis: String, pole: String, progress: int) -> String:
	var ladder := _ladder_for(axis, pole)
	var label := "Neutral"
	var best_threshold := -1
	for entry in ladder:
		var threshold := int(entry[0])
		if progress >= threshold and threshold > best_threshold:
			best_threshold = threshold
			label = str(entry[1])
	return label


## Goal tier's label if a goal is set, otherwise the pole's final label.
func _destination_label(character_tag: String, axis: String) -> String:
	var pole := get_pole(character_tag, axis)
	var ladder := _ladder_for(axis, pole)
	if ladder.is_empty():
		return "Neutral"
	var goal := get_goal(character_tag, axis)
	if goal >= SCORE_MAX:
		return str(ladder[-1][1])
	return _label_on_ladder(axis, pole, goal)


func _trajectory_line(tag: String, axis: String) -> String:
	var current := get_tier_label(tag, axis)
	var destination := _destination_label(tag, axis)
	if get_score(tag, axis) >= get_goal(tag, axis):
		return '- %s — %s: holding steady at "%s" — its intended standing; score 0' % [tag, axis, current]
	return '- %s — %s: currently "%s", developing toward "%s"' % [tag, axis, current, destination]


## "Each value is an integer from 0 to 5 (romance: 0 to 2)" — base cap plus
## per-axis exceptions listed inline where they differ.
func _cap_sentence() -> String:
	var counts: Dictionary = {}
	for axis in axis_list:
		var cap := int(axis_caps.get(axis, DEFAULT_RESPONSE_CAP))
		counts[cap] = int(counts.get(cap, 0)) + 1
	var base_cap := DEFAULT_RESPONSE_CAP
	var best := -1
	for cap in counts.keys():
		if int(counts[cap]) > best:
			best = int(counts[cap])
			base_cap = int(cap)
	var exceptions: Array[String] = []
	for axis in axis_list:
		var cap := int(axis_caps.get(axis, DEFAULT_RESPONSE_CAP))
		if cap != base_cap:
			exceptions.append("%s: -%d to %d" % [axis, cap, cap])
	var sentence := "Each value is an integer from -%d to %d" % [base_cap, base_cap]
	if not exceptions.is_empty():
		sentence += " (%s)" % "; ".join(exceptions)
	return sentence


## "Twilight (twi)" when a display name is resolvable, otherwise just the tag.
func _format_character(tag: String) -> String:
	return tag

## Read-only lookup that does NOT create an entry (queries must not mutate state).
func _peek_entry(character_tag: String, axis: String) -> Dictionary:
	var tag := _normalize_tag(character_tag)
	if _data.has(tag) and (_data[tag] as Dictionary).has(axis):
		return (_data[tag] as Dictionary)[axis]
	return {}


func _ensure_entry(character_tag: String, axis: String) -> Dictionary:
	var tag := _normalize_tag(character_tag)
	if not _data.has(tag):
		_data[tag] = {}
	if not (_data[tag] as Dictionary).has(axis):
		_data[tag][axis] = {
			"score": 0,
			"pole": _default_pole_for(axis),
			"goal": SCORE_MAX,
		}
	return _data[tag][axis]


func _sanitize_ladder(raw: Variant) -> Array:
	return _clean_ladder_preserving_order(raw if raw is Array else [])


## Shared ladder cleaner: keeps the given order, clamps thresholds to 0..100,
## drops entries whose threshold duplicates an earlier-kept one, and guarantees a
## Neutral root at threshold 0 (prepended if absent, so it never displaces an
## author-defined tier's position otherwise).
func _clean_ladder_preserving_order(raw: Array) -> Array:
	var cleaned: Array = []
	var seen_thresholds: Dictionary = {}
	for entry in raw:
		if entry is Array and entry.size() >= 2:
			var threshold := clampi(int(entry[0]), 0, SCORE_MAX)
			if seen_thresholds.has(threshold):
				continue
			seen_thresholds[threshold] = true
			cleaned.append([threshold, str(entry[1])])
	if not seen_thresholds.has(0):
		cleaned.push_front([0, "Neutral"])
	return cleaned


func _to_string_dict(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if raw is Dictionary:
		for key in (raw as Dictionary).keys():
			out[str(key)] = str((raw as Dictionary)[key])
	return out


func _to_int_dict(raw: Variant, default_value: int) -> Dictionary:
	var out: Dictionary = {}
	if raw is Dictionary:
		for key in (raw as Dictionary).keys():
			var value: Variant = (raw as Dictionary)[key]
			out[str(key)] = int(value) if (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) else default_value
	return out

# An Equestria conversation ends after five minutes without an accepted exchange.
func reset_character_budget(id: String) -> void:
	_scenario_spent.erase(id)
