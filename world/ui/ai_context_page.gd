extends Control
## AI context page (dev 2026-10-15: "a context section in the main menu to know whats going on"):
## per world, what the ponies remember and how big it is, what one request sends, and how the
## last requests went (world/ai/llm_client.gd status file). Read only. Same embedding as
## provider_settings.gd: `setup(surface)`, `open()`, `closed`, `controls`; the title gives it its
## page shape with `relayout()`. Look (dev 2026-10-27: "not that good looking and there isn't
## anything clickable to go back"): the world and four tabs on top, cards in between, Back always
## in view at the bottom.
signal closed
const STORE := preload("res://world/ai/memory/story_store.gd")
const LLM := preload("res://world/ai/llm_client.gd")
const PROMPTS := preload("res://world/ai/director_prompts.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const SHELF := preload("res://world/saves/save_shelf.gd")
const STYLE := preload("res://world/ui/menu_style.gd")
const ICON := preload("res://world/ui/menu_icon.gd")
const PANEL := preload("res://world/ui/spatial_menu_panel.gd")
const PONY_DATA := preload("res://world/ui/pony_map_data.gd")
const SUBTITLE_COLORS := preload("res://world/ai/subtitle_colors.gd")
const TEXT := STYLE.CREAM
const WARN := STYLE.CORAL
## Pony cards shown at first per world, biggest memory first; a button adds the rest.
const PONY_ROWS := 30
## A story summary shows about this many characters (cut at a word) until "Read all".
const SUMMARY_PEEK := 200
## Requests listed on the Requests tab, newest first.
const REQUEST_ROWS := 12
## [title, icon, about the chosen world].
const TABS := [["Memories", "heart", true], ["Model use", "gem", true], ["Requests", "clock", false], ["How it works", "info", false]]
## Pony cards stand two side by side from this page width.
const TWO_COLUMNS := 1000.0
const FONT := 20
## A summary line's section name ("Encounters: …").
const SECTION := "^([A-Z][A-Za-z ]{1,24}):\\s+(.*)$"
var worlds_root := CATALOGUE.ROOT
var status_path := LLM.STATUS_PATH
var controls: Array[Control] = []
var panel: Node
var worlds: Array[String] = []
var world_index := 0
var _tab := 0
var _columns := 1
var _report: Dictionary = {}
var _status: Dictionary = {}
var _page: VBoxContainer
var _tabs: Array[Button] = []
var _world_box: HBoxContainer
var _world_badge: Panel
var _world_name: Label
var _world_line: Label
var _previous: Button
var _next: Button
var _scroll: ScrollContainer
var _body: VBoxContainer
var _back: Button
## Buttons inside the cards (Read all, Show the other ponies), for the focus keys.
var _extra: Array[Control] = []
var _pony_columns: Array[VBoxContainer] = []
var _biggest := 1


func setup(surface: Node) -> void:
	panel = surface; mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = STYLE.theme()
	_page = VBoxContainer.new(); _page.add_theme_constant_override("separation", 12); add_child(_page)
	var head := HBoxContainer.new(); head.add_theme_constant_override("separation", 12)
	head.custom_minimum_size.y = FONT * 2.6; _page.add_child(head)
	var mark := ICON.make("chat", FONT + 10, STYLE.PINK); mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(mark)
	var title := STYLE.label("AI context", "Heading", FONT + 14); title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL; head.add_child(title)
	_world_box = HBoxContainer.new(); _world_box.add_theme_constant_override("separation", 10); head.add_child(_world_box)
	_previous = _round(_world_box, "back", "Previous world", _step_world.bind(-1))
	_world_badge = Panel.new(); _world_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_badge.custom_minimum_size = Vector2.ONE * FONT * 2.2; _world_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_world_box.add_child(_world_badge)
	var names := VBoxContainer.new(); names.add_theme_constant_override("separation", 0)
	names.custom_minimum_size.x = FONT * 15; names.size_flags_vertical = Control.SIZE_SHRINK_CENTER; _world_box.add_child(names)
	_world_name = _clipped(STYLE.label("", "Subheading", FONT + 1)); names.add_child(_world_name)
	_world_line = _clipped(STYLE.label("", "Faint", FONT - 5)); names.add_child(_world_line)
	_next = _round(_world_box, "forward", "Next world", _step_world.bind(1))
	var strip := HBoxContainer.new(); strip.add_theme_constant_override("separation", 8); _page.add_child(strip)
	for i in TABS.size():
		var chip := _button(strip, str(TABS[i][0]), _show_tab.bind(i), "Chip")
		chip.toggle_mode = true; chip.icon = ICON.texture(str(TABS[i][1]), FONT - 2)
		chip.add_theme_font_size_override("font_size", FONT - 3); chip.custom_minimum_size.y = FONT * 2.0
		_tabs.append(chip)
	_scroll = ScrollContainer.new(); _scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; _scroll.follow_focus = true
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void: _refresh_panel())
	_page.add_child(_scroll)
	# Room for a hovered button's focus ring inside the scroll's clip, and for the scroll bar.
	var holder := MarginContainer.new(); holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "top", "bottom"]: holder.add_theme_constant_override("margin_" + side, 4)
	holder.add_theme_constant_override("margin_right", 16); _scroll.add_child(holder)
	_body = VBoxContainer.new(); _body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12); holder.add_child(_body)
	# Summaries settle their height a frame late: draw the panel again once they have.
	_body.resized.connect(_refresh_panel)
	var footer := HBoxContainer.new(); _page.add_child(footer)
	_back = _button(footer, "Back", func() -> void: closed.emit())
	_back.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _back.icon = ICON.texture("back", FONT + 2)
	_back.custom_minimum_size.y = (FONT + 2) * 1.9; _back.add_theme_font_size_override("font_size", FONT + 2)
	relayout(Vector2(PANEL.PIXELS))
	hide()


## The page shape the title gives its pages (the window's on desktop, the panel's own in a
## headset): the page fills it inside the card's margins, as Settings does.
func relayout(page_size: Vector2) -> void:
	var inner := (page_size - Vector2(80, 50)).max(Vector2(400, 300))
	position = Vector2(40, 28); size = inner; _page.size = inner
	var columns := 2 if inner.x >= TWO_COLUMNS else 1
	if columns == _columns: return
	_columns = columns
	if visible: _show()


func open() -> void:
	worlds = world_ids(worlds_root)
	world_index = clampi(world_index, 0, maxi(0, worlds.size() - 1))
	_status = LLM.read_status(status_path)
	_tab = 0; _load_world()
	show(); _show(); _tabs[0].grab_focus()


## World folders, most recently changed first.
static func world_ids(root: String) -> Array[String]:
	var found: Array = []
	var dir := DirAccess.open(root)
	if dir == null: return []
	for id: String in dir.get_directories():
		var folder := root.path_join(id)
		if not FileAccess.file_exists(folder.path_join("context.json")) and not FileAccess.file_exists(folder.path_join("story.db")): continue
		var stamp := maxi(FileAccess.get_modified_time(folder.path_join("context.json")), FileAccess.get_modified_time(folder.path_join("story.db")))
		found.append({"id": id, "stamp": stamp})
	found.sort_custom(func(a, b): return a.stamp > b.stamp)
	var ids: Array[String] = []
	for row: Dictionary in found: ids.append(str(row.id))
	return ids


static func size_text(bytes: int) -> String:
	return "%s (~%s tokens)" % [short_size(bytes), tokens_text(bytes)]


## "0.4 KB", "1.2 MB".
static func short_size(bytes: int) -> String:
	if bytes > 0 and bytes < 103: return "<0.1 KB"
	return ("%.1f MB" % (bytes / 1048576.0)) if bytes >= 1048576 else ("%.1f KB" % (bytes / 1024.0))


## About how many tokens `bytes` of text make: "130", "4.1k", "2.3M".
static func tokens_text(bytes: int) -> String:
	return count_text(int(ceil(bytes / 3.6)))


static func count_text(count: int) -> String:
	if count >= 1000000: return "%.1fM" % (count / 1000000.0)
	return ("%.1fk" % (count / 1000.0)) if count >= 1000 else str(count)


static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return 0
	var length := int(file.get_length()); file.close()
	return length


static func _name(id: String) -> String:
	return "Anon" if id == "player" else id.replace("_", " ").capitalize()


## Everything the page shows for one world, as data (also checked by tools/ai/test_ai_context.gd).
static func world_report(root: String, id: String) -> Dictionary:
	var folder := root.path_join(id)
	var report := {"id": id, "name": CATALOGUE.world_title(root, id), "story_bytes": _file_size(folder.path_join("story.db")),
		"context_bytes": _file_size(folder.path_join("context.json")), "save_bytes": 0, "saves": 0, "lines": 0,
		"ponies": [], "usage": {}, "error": ""}
	var saves := DirAccess.open(folder.path_join("saves"))
	if saves != null:
		for file: String in saves.get_files():
			if file.ends_with(".json") or file.ends_with(".story.db"):
				report.save_bytes += _file_size(folder.path_join("saves").path_join(file))
				if file.ends_with(".json"): report.saves += 1
	if not FileAccess.file_exists(folder.path_join("story.db")):
		report.error = "No story journal yet." if STORE.available() else "Story journal needs the SQLite addon."
		return report
	var store := STORE.new()
	if not store.open(folder.path_join("story.db")):
		report.error = "Story journal could not be opened: " + store.error
		return report
	report.lines = store.line_count()
	report.usage = store.usage_totals()
	for row: Dictionary in store.pony_totals():
		var pony := str(row.pony)
		if pony == "player": continue
		var summary: Dictionary = store.summary("pony:" + pony)
		report.ponies.append({"id": pony, "name": _name(pony), "lines": int(row.lines),
			"bytes": int(row.chars if row.chars != null else 0), "summary": str(summary.text)})
	store.close()
	return report


const OUTCOMES := {"ok": "Answered", "output_limit": "Answered, cut short", "refusal": "Refused by the model's safety filter",
	"transient": "Server trouble, gave up", "fail": "Failed"}
## Recent request outcomes from the dialogue client's status file, newest first: {at, outcome,
## purpose, bytes, attempts, seconds, error}.
static func request_rows(doc: Dictionary, limit := REQUEST_ROWS) -> Array[Dictionary]:
	var rows: Array = doc.get("requests", []) if doc.get("requests") is Array else []
	var out: Array[Dictionary] = []
	for i in range(rows.size() - 1, maxi(-1, rows.size() - 1 - limit), -1):
		var row: Dictionary = rows[i] if rows[i] is Dictionary else {}
		out.append({"at": str(row.get("at", "")), "outcome": str(row.get("outcome", "?")), "purpose": str(row.get("purpose", "")),
			"bytes": int(row.get("input_bytes", 0)), "attempts": int(row.get("attempts", 1)), "seconds": float(row.get("seconds", 0.0)),
			"error": str(row.get("error", ""))})
	return out


## Recent request outcomes from the dialogue client's status file, as lines.
static func status_lines(path: String, limit := 8) -> PackedStringArray:
	var doc: Dictionary = LLM.read_status(path)
	var lines: PackedStringArray = []
	var totals: Dictionary = doc.get("totals", {}) if doc.get("totals") is Dictionary else {}
	if totals.is_empty():
		lines.append("No dialogue requests recorded yet.")
		return lines
	lines.append("Since the record began: %d answered, %d refused, %d gave up after retries, %d failed, %d needed a retry." % [
		int(totals.get("ok", 0)) + int(totals.get("output_limit", 0)), int(totals.get("refusal", 0)), int(totals.get("transient", 0)),
		int(totals.get("fail", 0)), int(totals.get("retried", 0))])
	var words := {"ok": "answered", "output_limit": "answered (cut short)", "refusal": "REFUSED by the model's safety filter",
		"transient": "server trouble, gave up", "fail": "FAILED"}
	for row: Dictionary in request_rows(doc, limit):
		var line := "%s  %s, sent %s, %d %s, %.1f s" % [str(row.at).substr(11, 5), words.get(row.outcome, row.outcome), size_text(int(row.bytes)),
			int(row.attempts), "try" if int(row.attempts) == 1 else "tries", float(row.seconds)]
		if str(row.error) != "" and row.outcome != "ok": line += "\n      " + str(row.error).left(140)
		lines.append(line)
	return lines


## What each kind of request is for, in words a player can act on (Settings → AI → AI usage
## turns the background ones off).
const USAGE_NAMES := {"dialogue_player": "Answering you", "dialogue": "Answering you", "group": "Answering you in a group",
	"group_ambient": "Ponies chatting among themselves", "greeting": "Ponies coming over to talk",
	"lull": "Filling a silence", "farewell": "Saying goodbye", "story_purpose": "Story moments",
	"summary": "Memory diaries", "feedback_classifier": "Your feedback notes", "variety_revision": "Rewording a repeat",
	"group_variety_revision": "Rewording a repeat"}
const BACKGROUND := ["group_ambient", "greeting", "lull"]
static func purpose_name(kind: String) -> String:
	var base := kind.trim_suffix("_recovery").trim_suffix("_repair")
	if kind != base: return "Re-asking a cut-off or broken reply"
	if base.begins_with("contact_"): return "Touch reactions"
	return USAGE_NAMES.get(base, base.replace("_", " ").capitalize())


## What each kind of request cost in this world, biggest first: {name, calls, input, background}.
static func usage_rows(totals: Dictionary) -> Array[Dictionary]:
	var grouped := {}
	for kind: String in totals:
		if kind == "all" or not totals[kind] is Dictionary: continue
		var what := purpose_name(kind)
		var row: Dictionary = grouped.get(what, {"name": what, "calls": 0, "input": 0, "background": kind in BACKGROUND})
		row.calls += int(totals[kind].get("calls", 0)); row.input += int(totals[kind].get("input", 0))
		grouped[what] = row
	var rows: Array[Dictionary] = []
	for what: String in grouped: rows.append(grouped[what])
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.input) > int(b.input))
	return rows


static func usage_lines(totals: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	for row: Dictionary in usage_rows(totals):
		lines.append("  %s%s: %d calls, about %dk tokens sent" % [row.name, " (background)" if row.background else "", int(row.calls), int(row.input) / 1000])
	return lines


## A story summary for a card: each "Section: words" line with its section name in `tint`; the
## start only (about SUMMARY_PEEK characters, cut at a word) unless `full`.
static func summary_bbcode(text: String, full: bool, tint: Color) -> String:
	var section := RegEx.create_from_string(SECTION)
	var lines: PackedStringArray = []
	var left := SUMMARY_PEEK
	for raw: String in text.split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty(): continue
		if not full and left <= 0: break
		var head := ""
		var found := section.search(line)
		if found != null: head = found.get_string(1); line = found.get_string(2)
		if not full:
			if line.length() > left:
				var cut := line.left(left)
				line = (cut.left(cut.rfind(" ")) if cut.rfind(" ") > left * 0.5 else cut).rstrip(" ,;:.") + "…"
				left = 0
			else:
				left -= line.length() + head.length()
		var words := line.replace("[", "[lb]")
		lines.append(("[color=#%s][b]%s[/b][/color]  %s" % [tint.to_html(false), head.replace("[", "[lb]"), words]) if head != "" else words)
	return "\n".join(lines)


# ------------------------------------------------------------------ the page
func _load_world() -> void:
	_report = world_report(worlds_root, worlds[world_index]) if not worlds.is_empty() else {}


func _step_world(direction: int) -> void:
	if worlds.size() < 2: return
	world_index = posmod(world_index + direction, worlds.size())
	_load_world(); _show()


func _show_tab(index: int) -> void:
	_tab = index; _show()


func _show() -> void:
	for child in _body.get_children():
		_body.remove_child(child); child.queue_free()
	_extra.clear(); _pony_columns.clear()
	for i in _tabs.size(): _tabs[i].set_pressed_no_signal(i == _tab)
	_show_world()
	match _tab:
		0: _show_memories()
		1: _show_usage()
		2: _show_requests()
		_: _show_how()
	_scroll.scroll_vertical = 0
	_list_controls()
	_refresh_panel()


func _list_controls() -> void:
	controls = []
	controls.append_array(_tabs)
	if _world_box.visible and worlds.size() > 1: controls.append_array([_previous, _next])
	controls.append_array(_extra)
	controls.append(_back)


## The header's world: its folder picture and colour from the saves browser, its name, when it began.
func _show_world() -> void:
	_world_box.visible = bool(TABS[_tab][2])
	_previous.disabled = worlds.size() < 2; _next.disabled = worlds.size() < 2
	var tint := STYLE.FAINT
	var kind := "sparkle"
	if worlds.is_empty():
		_world_name.text = "No worlds yet"; _world_line.text = "A new game makes one"
	else:
		var id := worlds[world_index]
		var look := SHELF.world_look(id, SHELF.read(worlds_root.path_join(id)))
		tint = STYLE.SWATCHES[int(look.color) % STYLE.SWATCHES.size()]; kind = str(look.icon)
		_world_name.text = str(_report.get("name", id))
		var bits: Array[String] = []
		if CATALOGUE.world_started(id) != "": bits.append("started " + CATALOGUE.world_started(id))
		bits.append("world %d of %d" % [world_index + 1, worlds.size()])
		_world_line.text = " · ".join(bits)
	_world_name.add_theme_color_override("font_color", tint.lerp(Color.WHITE, 0.25))
	for child in _world_badge.get_children(): child.queue_free()
	_world_badge.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(tint, 0.22), Color(tint, 0.7), 1, 99, 0, 0)))
	var picture := ICON.make(kind, _world_badge.custom_minimum_size.x * 0.62, tint)
	picture.position = _world_badge.custom_minimum_size * 0.19
	_world_badge.add_child(picture)


func _show_memories() -> void:
	if worlds.is_empty():
		_empty("heart", "No worlds yet", "Each world keeps its own story journal. Start a new game and what the ponies remember shows here."); return
	var ponies: Array = _report.ponies
	var tiles := _tiles()
	_tile(tiles, "Story journal", short_size(int(_report.story_bytes)), "%s lines · ~%s tokens" % [count_text(int(_report.lines)), tokens_text(int(_report.story_bytes))])
	_tile(tiles, "Recent events", short_size(int(_report.context_bytes)), "~%s tokens" % tokens_text(int(_report.context_bytes)))
	_tile(tiles, "Saves", str(int(_report.saves)), short_size(int(_report.save_bytes)) if int(_report.saves) > 0 else "none yet")
	_tile(tiles, "Ponies", str(ponies.size()), "with memories of this world")
	if str(_report.error) != "": _note(str(_report.error), WARN)
	_note("Ponies remember everything: the story journal keeps every line and event in full, with no size limit. A request sends only a small, summarised slice of it (How it works).")
	if ponies.is_empty(): return
	_section("What each pony remembers", "biggest first")
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 12); _body.add_child(row)
	for i in _columns:
		var column := VBoxContainer.new(); column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_theme_constant_override("separation", 10); row.add_child(column); _pony_columns.append(column)
	_biggest = 1
	for pony: Dictionary in ponies: _biggest = maxi(_biggest, int(pony.bytes))
	_add_ponies(ponies.slice(0, PONY_ROWS), 0)
	if ponies.size() > PONY_ROWS:
		var rest := _button(_body, "Show the other %d ponies" % (ponies.size() - PONY_ROWS), Callable(), "Ghost")
		rest.icon = ICON.texture("plus", FONT); rest.custom_minimum_size.y = FONT * 2.2
		rest.pressed.connect(func() -> void:
			_extra.erase(rest); rest.queue_free()
			_add_ponies(ponies.slice(PONY_ROWS), PONY_ROWS)
			_list_controls(); _refresh_panel())
		_extra.append(rest)


## Cards go to the columns in turn, so the biggest memories stay at the top of each.
func _add_ponies(ponies: Array, first: int) -> void:
	for i in ponies.size(): _pony_card(_pony_columns[(first + i) % _pony_columns.size()], ponies[i])


## A pony's card: her cutie mark on her coat in a ring of her subtitle colour, her name in its fill,
## how much of the journal is hers, and the start of her story summary.
func _pony_card(parent: Control, pony: Dictionary) -> void:
	var id := str(pony.id)
	var look := PONY_DATA.appearance(id)
	var palette := SUBTITLE_COLORS.for_pony(id, str(look.name))
	if palette.is_empty(): palette = SUBTITLE_COLORS.derived(look.coat, look.coat)
	var tint: Color = palette.fill
	var card := _card(parent, 12)
	var rows := VBoxContainer.new(); rows.add_theme_constant_override("separation", 7); card.add_child(rows)
	var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 12); rows.add_child(top)
	top.add_child(_portrait(id, look.coat, palette.outline))
	var names := VBoxContainer.new(); names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.size_flags_vertical = Control.SIZE_SHRINK_CENTER; names.add_theme_constant_override("separation", 0); top.add_child(names)
	var who := _clipped(STYLE.label(str(look.name), "Subheading", FONT)); who.add_theme_color_override("font_color", tint)
	names.add_child(who)
	var text := str(pony.summary).strip_edges()
	names.add_child(_clipped(STYLE.label("%s %s · %s · ~%s tokens%s" % [count_text(int(pony.lines)), "line" if int(pony.lines) == 1 else "lines",
		short_size(int(pony.bytes)), tokens_text(int(pony.bytes)), " · no story summary yet" if text.is_empty() else ""], "Faint", FONT - 5)))
	rows.add_child(_bar(float(pony.bytes) / _biggest, palette.outline.lerp(tint, 0.45)))
	if text.is_empty(): return
	var caption := HBoxContainer.new(); rows.add_child(caption)
	var about := STYLE.label("STORY SUMMARY · ~%s TOKENS" % tokens_text(text.to_utf8_buffer().size()), "Faint", FONT - 7)
	about.size_flags_horizontal = Control.SIZE_EXPAND_FILL; about.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	caption.add_child(about)
	var words := RichTextLabel.new(); words.bbcode_enabled = true; words.fit_content = true; words.scroll_active = false
	words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; words.mouse_filter = Control.MOUSE_FILTER_PASS
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	words.add_theme_color_override("default_color", STYLE.MUTED)
	for kind: String in ["normal_font_size", "bold_font_size"]: words.add_theme_font_size_override(kind, FONT - 3)
	words.add_theme_constant_override("line_separation", 3)
	words.text = summary_bbcode(text, false, tint)
	rows.add_child(words)
	if words.text == summary_bbcode(text, true, tint): return
	var more := _button(caption, "Read all", Callable(), "Chip")
	more.add_theme_font_size_override("font_size", FONT - 6); more.custom_minimum_size.y = FONT * 1.5
	more.pressed.connect(func() -> void:
		var full := more.text == "Read all"
		words.text = summary_bbcode(text, full, tint); more.text = "Show less" if full else "Read all"
		_refresh_panel())
	_extra.append(more)


func _portrait(id: String, coat: Color, ring: Color) -> Control:
	var side := FONT * 2.4
	var disc := Panel.new(); disc.custom_minimum_size = Vector2(side, side); disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(coat, ring, 2, 99, 0, 0)))
	PONY_DATA.load_icons()
	var icon: Dictionary = PONY_DATA.icons.get(id, {})
	# The princesses' marks are blank in the atlas: their sun / moon instead of an empty disc.
	if icon.is_empty() or PONY_DATA.atlas == null or bool(icon.get("blank", false)):
		preload("res://world/ui/pony_symbol.gd").add_to(disc, id, side)
		return disc
	# The inscribed square keeps every pixel of the mark inside the disc (world/ui/world_map_view.gd).
	var mark := TextureRect.new(); mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var region := AtlasTexture.new(); region.atlas = PONY_DATA.atlas
	var rect: Array = icon.rect
	region.region = Rect2(rect[0], rect[1], rect[2], rect[3])
	mark.texture = region; mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.size = Vector2.ONE * side * 0.66; mark.position = Vector2.ONE * side * 0.17
	disc.add_child(mark)
	return disc


func _show_usage() -> void:
	if worlds.is_empty():
		_empty("gem", "No worlds yet", "What the AI cost in each world shows here."); return
	var totals: Dictionary = _report.usage
	var all: Dictionary = totals.get("all", {}) if totals.get("all") is Dictionary else {}
	if all.is_empty():
		_empty("gem", "Nothing sent yet", "No request has gone to the AI from this world yet."); return
	var sent := int(all.get("input", 0))
	var cached := int(all.get("cached", 0))
	var tiles := _tiles()
	_tile(tiles, "Requests", count_text(int(all.get("calls", 0))), "in this world")
	_tile(tiles, "Sent", "~" + count_text(sent), "tokens")
	_tile(tiles, "Received", "~" + count_text(int(all.get("output", 0))), "tokens")
	if cached > 0: _tile(tiles, "From the cache", "%d%%" % roundi(100.0 * cached / maxi(1, sent)), "~%s tokens, billed at a discount" % count_text(cached), STYLE.MINT)
	else: _tile(tiles, "From the cache", "none", "no cache reads recorded")
	_section("Where it went", "by tokens sent")
	var card := _card(_body, 14)
	var list := VBoxContainer.new(); list.add_theme_constant_override("separation", 12); card.add_child(list)
	var rows := usage_rows(totals)
	var most := 1
	for row: Dictionary in rows: most = maxi(most, int(row.input))
	for row: Dictionary in rows:
		var line := VBoxContainer.new(); line.add_theme_constant_override("separation", 5); list.add_child(line)
		var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 10); line.add_child(top)
		var what := _clipped(STYLE.label(str(row.name), "", FONT - 2)); what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(what)
		if row.background: top.add_child(_tag("background", STYLE.PERIWINKLE))
		top.add_child(STYLE.label("%s %s · ~%s tokens sent" % [count_text(int(row.calls)), "call" if int(row.calls) == 1 else "calls", count_text(int(row.input))], "Muted", FONT - 4))
		line.add_child(_bar(float(row.input) / most, STYLE.PERIWINKLE if row.background else STYLE.PINK))
	_note("Background requests can be turned off: Settings → AI Settings → AI usage → Only when I talk.")


func _show_requests() -> void:
	var totals: Dictionary = _status.get("totals", {}) if _status.get("totals") is Dictionary else {}
	if totals.is_empty():
		_empty("clock", "No requests yet", "Once you talk with a pony, each request to the AI shows here: how it went, how much it sent and how long it took."); return
	_section("Since the record began", "every world")
	var tiles := _tiles()
	_tile(tiles, "Answered", count_text(int(totals.get("ok", 0)) + int(totals.get("output_limit", 0))), "", STYLE.MINT)
	_tile(tiles, "Refused", count_text(int(totals.get("refusal", 0))), "by a safety filter", WARN if int(totals.get("refusal", 0)) > 0 else TEXT)
	_tile(tiles, "Gave up", count_text(int(totals.get("transient", 0))), "server trouble", STYLE.PEACH if int(totals.get("transient", 0)) > 0 else TEXT)
	_tile(tiles, "Failed", count_text(int(totals.get("fail", 0))), "", WARN if int(totals.get("fail", 0)) > 0 else TEXT)
	_tile(tiles, "Retried", count_text(int(totals.get("retried", 0))), "then answered or not")
	var rows := request_rows(_status)
	if rows.is_empty(): return
	_section("Last requests", "newest first")
	var card := _card(_body, 14)
	var list := VBoxContainer.new(); list.add_theme_constant_override("separation", 10); card.add_child(list)
	var today := Time.get_date_string_from_system()
	for i in rows.size():
		var row: Dictionary = rows[i]
		if i > 0: list.add_child(_rule())
		var colour: Color = {"ok": STYLE.MINT, "output_limit": STYLE.BUTTER, "transient": STYLE.PEACH}.get(row.outcome, WARN)
		var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 10); list.add_child(top)
		var dot := Panel.new(); dot.custom_minimum_size = Vector2.ONE * 10; dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(colour, Color.TRANSPARENT, 0, 99, 0, 0))); top.add_child(dot)
		var outcome := STYLE.label(OUTCOMES.get(row.outcome, str(row.outcome)), "", FONT - 2)
		outcome.add_theme_font_override("font", STYLE.BOLD); outcome.add_theme_color_override("font_color", colour.lerp(Color.WHITE, 0.2))
		top.add_child(outcome)
		var purpose := _clipped(STYLE.label("· " + purpose_name(str(row.purpose)) if str(row.purpose) != "" else "", "Muted", FONT - 3))
		purpose.size_flags_horizontal = Control.SIZE_EXPAND_FILL; top.add_child(purpose)
		var at := str(row.at)
		top.add_child(STYLE.label(at.substr(11, 5) if at.left(10) == today else "%s %s" % [_short_date(at), at.substr(11, 5)], "Faint", FONT - 5))
		var details := STYLE.label("sent %s · ~%s tokens · %d %s · %.1f s" % [short_size(int(row.bytes)), tokens_text(int(row.bytes)),
			int(row.attempts), "try" if int(row.attempts) == 1 else "tries", float(row.seconds)], "Faint", FONT - 5)
		details.add_theme_constant_override("line_spacing", 0); list.add_child(_indented(details))
		if str(row.error) != "" and row.outcome != "ok":
			var error := STYLE.label(str(row.error).left(300), "", FONT - 5)
			error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; error.add_theme_color_override("font_color", Color(WARN, 0.85))
			list.add_child(_indented(error))


func _show_how() -> void:
	_note("Ponies remember everything: each world's story journal keeps every line and event in full, with no size limit. A request sends only a small, summarised slice of it, because every token is paid in full on every call.", TEXT, FONT - 1)
	_section("What one request sends", "")
	var holder: BoxContainer
	if _columns > 1: holder = HBoxContainer.new()
	else: holder = VBoxContainer.new()
	holder.add_theme_constant_override("separation", 12); _body.add_child(holder)
	_explain(holder, "pony", STYLE.PINK, "Talking with one pony", ["Her persona and her situation", "Up to %s of her memories" % size_text(4200),
		"Up to %s of world facts" % size_text(1200), "The last %s of your chat with her" % size_text(LLM.HISTORY_BYTES)])
	_explain(holder, "chat", STYLE.SKY, "A group", ["The shared rules", "A slice for each pony, smaller as more join",
		"All of it under %s" % size_text(PROMPTS.GROUP_PROMPT_BYTES)])
	_explain(holder, "butterfly", STYLE.PERIWINKLE, "Ponies among themselves", ["Three or more ponies chatting on their own share one request",
		"Under %s" % size_text(PROMPTS.AMBIENT_PROMPT_BYTES)])
	_note("Token counts here are estimates (about 3.6 bytes of text per token); each provider counts its own way.", STYLE.FAINT, FONT - 5)


func _explain(parent: Control, kind: String, tint: Color, title: String, points: Array) -> void:
	var card := _card(parent, 14); card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rows := VBoxContainer.new(); rows.add_theme_constant_override("separation", 8); card.add_child(rows)
	var top := HBoxContainer.new(); top.add_theme_constant_override("separation", 10); rows.add_child(top)
	var disc := Panel.new(); disc.custom_minimum_size = Vector2.ONE * FONT * 2; disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(tint, 0.2), Color(tint, 0.6), 1, 99, 0, 0)))
	var picture := ICON.make(kind, FONT * 1.24, tint); picture.position = Vector2.ONE * FONT * 0.38; disc.add_child(picture)
	top.add_child(disc)
	var heading := STYLE.label(title, "Subheading", FONT); heading.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL; top.add_child(heading)
	for point: String in points:
		var line := HBoxContainer.new(); line.add_theme_constant_override("separation", 10); rows.add_child(line)
		var dot := Panel.new(); dot.custom_minimum_size = Vector2.ONE * 6; dot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		dot.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(tint, Color.TRANSPARENT, 0, 99, 0, 0)))
		var nudge := MarginContainer.new(); nudge.add_theme_constant_override("margin_top", int(FONT * 0.45)); nudge.add_child(dot)
		line.add_child(nudge)
		var words := STYLE.label(point, "Muted", FONT - 3); words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		words.size_flags_horizontal = Control.SIZE_EXPAND_FILL; line.add_child(words)


# ------------------------------------------------------------------ pieces
func _empty(kind: String, title: String, text: String) -> void:
	var box := VBoxContainer.new(); box.add_theme_constant_override("separation", 10); _body.add_child(box)
	var gap := Control.new(); gap.custom_minimum_size.y = FONT * 4; box.add_child(gap)
	var picture := ICON.make(kind, FONT * 2.6, STYLE.FAINT); picture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(picture)
	var heading := STYLE.label(title, "Subheading", FONT + 2); heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; box.add_child(heading)
	var words := STYLE.label(text, "Muted", FONT - 3); words.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; box.add_child(words)


func _section(title: String, aside: String) -> void:
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 10); _body.add_child(row)
	row.add_child(STYLE.label(title, "Subheading", FONT + 2))
	if aside != "":
		var note := STYLE.label(aside, "Faint", FONT - 5); note.size_flags_vertical = Control.SIZE_SHRINK_CENTER; row.add_child(note)


func _note(text: String, colour := STYLE.MUTED, font := FONT - 3) -> Label:
	var node := STYLE.label(text, "", font); node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.add_theme_color_override("font_color", colour); node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(node); return node


func _tiles() -> HBoxContainer:
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 10); _body.add_child(row)
	return row


## A number with its caption above and a few words under it.
func _tile(parent: Control, caption: String, value: String, under: String, tint := TEXT) -> void:
	var card := _card(parent, 10); card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rows := VBoxContainer.new(); rows.add_theme_constant_override("separation", 1); card.add_child(rows)
	rows.add_child(_clipped(STYLE.label(caption.to_upper(), "Faint", FONT - 7)))
	var number := _clipped(STYLE.label(value, "", FONT + 8)); number.add_theme_font_override("font", STYLE.BOLD)
	number.add_theme_color_override("font_color", tint); rows.add_child(number)
	if under != "":
		var words := STYLE.label(under, "Faint", FONT - 6); words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; rows.add_child(words)


func _card(parent: Control, padding: int) -> PanelContainer:
	var card := PanelContainer.new(); card.mouse_filter = Control.MOUSE_FILTER_PASS
	card.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(1, 1, 1, 0.045), Color(1, 1, 1, 0.08), 1, 16, 16, padding)))
	parent.add_child(card); return card


## How much of the biggest `share` is, as a thin rounded bar.
func _bar(share: float, colour: Color) -> ProgressBar:
	var bar := ProgressBar.new(); bar.show_percentage = false; bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.min_value = 0.0; bar.max_value = 1.0; bar.step = 0.0; bar.value = clampf(share, 0.015, 1.0)
	bar.custom_minimum_size.y = 6
	bar.add_theme_stylebox_override("background", STYLE.rounded(STYLE.box(Color(1, 1, 1, 0.07), Color.TRANSPARENT, 0, 99, 0, 0)))
	bar.add_theme_stylebox_override("fill", STYLE.rounded(STYLE.box(colour, Color.TRANSPARENT, 0, 99, 0, 0)))
	return bar


func _tag(text: String, tint: Color) -> Control:
	var box := PanelContainer.new(); box.size_flags_vertical = Control.SIZE_SHRINK_CENTER; box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_stylebox_override("panel", STYLE.rounded(STYLE.box(Color(tint, 0.16), Color(tint, 0.5), 1, 99, 9, 1)))
	var words := STYLE.label(text, "", FONT - 7); words.add_theme_color_override("font_color", tint.lerp(Color.WHITE, 0.3))
	box.add_child(words); return box


func _rule() -> Control:
	var line := ColorRect.new(); line.color = Color(1, 1, 1, 0.06); line.custom_minimum_size.y = 1
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE; return line


## Under a request's outcome dot, in line with its words.
func _indented(node: Control) -> MarginContainer:
	var box := MarginContainer.new(); box.add_theme_constant_override("margin_left", 20); box.add_child(node)
	return box


static func _short_date(at: String) -> String:
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var month := int(at.substr(5, 2))
	return "%s %d" % [months[month - 1], int(at.substr(8, 2))] if month >= 1 and month <= 12 else at.left(10)


func _clipped(node: Label) -> Label:
	node.clip_text = true; node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return node


func _button(parent: Node, text: String, action: Callable, variation := "") -> Button:
	var node := Button.new(); node.text = text; node.theme_type_variation = variation
	if action.is_valid(): node.pressed.connect(action)
	node.focus_entered.connect(_refresh_panel)
	node.mouse_entered.connect(_refresh_panel); node.mouse_exited.connect(_refresh_panel)
	parent.add_child(node); return node


func _round(parent: Node, kind: String, tip: String, action: Callable) -> Button:
	var node := _button(parent, "", action, "Round"); node.tooltip_text = tip
	node.icon = ICON.texture(kind, FONT); node.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	node.custom_minimum_size = Vector2.ONE * FONT * 2; node.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return node


func _refresh_panel() -> void:
	if panel != null and panel.has_method("refresh"): panel.refresh()
