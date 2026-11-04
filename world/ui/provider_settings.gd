extends Control
## AI Settings page: the player's own dialogue (LLM), speech-to-text and voice
## (TTS) providers, saved to user://ai_config.json. Embedded by the title screen and the
## pause menu: `setup(surface)` (surface has `refresh()`), `open()`, `closed`, and
## `controls` (the visible focusable controls, in order). 900×840; the content scrolls.
signal closed
var setup_mode := false
var embedded := false
var _options: Dictionary = {}
var _model_picker: Control
var _model_status: Label
var _catalog: Node
var _route_picker: Control
var _route_status: Label
var _route_catalog: Node
var _route_note := ""
## OpenRouter routing of the draft connection: the endpoint tag tried first ("" = OpenRouter picks)
## and whether another provider may answer when that one is unavailable.
var openrouter_provider := ""
var openrouter_fallbacks := true
var _profile_box: VBoxContainer
var _back: Button
var _save: Button
const CONFIG:=preload("res://world/ai/ai_config.gd")
## Menu look (world/ui/menu_style.gd) and the in-page dropdown that replaced OptionButton popups.
const STYLE:=preload("res://world/ui/menu_style.gd")
const ICON:=preload("res://world/ui/menu_icon.gd")
const PICKER:=preload("res://world/ui/menu_picker.gd")
const LLM:=preload("res://world/ai/llm_client.gd")
const PROFILES := preload("res://world/ai/llm_profiles.gd")
## Presets fill protocol and base URL; the model entry is only a placeholder hint.
const PRESETS:=[
	{"name":"Anthropic","provider":"anthropic","base_url":"https://api.anthropic.com/v1","model":"e.g. claude-sonnet-4-5"},
	{"name":"OpenAI","provider":"openai","base_url":"https://api.openai.com/v1","model":"e.g. gpt-4o-mini"},
	{"name":"Google Gemini","provider":"gemini","base_url":"https://generativelanguage.googleapis.com","model":"e.g. gemini-2.5-flash"},
	{"name":"OpenRouter","provider":"openai","base_url":"https://openrouter.ai/api/v1","model":"e.g. anthropic/claude-sonnet-4.5"},
	{"name":"Ollama (local)","provider":"openai","base_url":"http://127.0.0.1:11434/v1","model":"e.g. llama3.1:8b (ollama pull it first)"},
	{"name":"llama.cpp server (local)","provider":"openai","base_url":"http://127.0.0.1:8080/v1","model":"any name; the server uses its loaded model"},
	{"name":"Custom","provider":"","base_url":"","model":"Model ID from your provider"},
]
const STT_PROVIDERS:=[["builtin","Built-in Whisper (offline, no server)"],["off","Off (type to talk)"],["local","Local Whisper server"],["openai","OpenAI-compatible Whisper API"]]
const TTS_PROVIDERS:=[["none","None (ponese)"],["openai","OpenAI-compatible /audio/speech"],["gradio","Gradio MOSS-TTS host"],["moss","Local moss-tts"]]
const VOICE_MODES:=[["ponese","Ponese only"],["auto","Character voices via server"]]
const STT_MODES:=[["ptt","Push to talk (hold T / left B)"],["vad","Open microphone"]]
## How much the AI runs (ai_config "ai_usage"; docs/AI_TOKENS_AND_CACHING_2026_10_25.md).
const USAGE_MODES:=[["full","Full: ponies also chat among themselves and come to talk"],["talk","Only when I talk: ponies answer you, nothing in the background"],["off","Off: no AI and no cost; ponies speak Ponese"]]
const CACHE_MODES:=[["auto","Automatic (Claude through OpenRouter)"],["on","On (cache hints on every request)"],["off","Off"]]
const CHATTINESS_NAMES:={1.0:"Normal",0.75:"A bit quieter",0.5:"Quiet",0.25:"Very quiet",0.1:"Almost silent"}
var ai_usage:="full"
var adult_policy_hint:=false
## Photos a pony can see (world/ai/photo_vision.gd); off by default.
## The dialogue protocols (Protocol row): native Gemini since 0.0.3.
const PROTOCOLS:=[["openai","OpenAI-compatible"],["anthropic","Anthropic Messages"],["gemini","Google Gemini (native)"]]
const VISION_MODES:=[["off","Off: photos never leave the game"],["same","My dialogue model sees them (it must accept images)"],["separate","A separate vision model describes them"]]
var vision_mode:="off"
var cache_hints:="auto"
const TEXT:=STYLE.CREAM
const WARN:=STYLE.CORAL
var config_path:="user://ai_config.json"
var profiles_path := "user://llm_profiles.json"
var profiles: RefCounted = PROFILES.new()
var _llm_values: Dictionary = CONFIG.DEFAULTS.llm.duplicate(true)
var _selected_profile := ""
var _delete_profile_confirm := ""
var _overwrite_confirm := ""
var _profile_active: Label
var _profile_pick: Button
var _profile_save: Button
var _profile_overwrite: Button
var _profile_delete: Button
var _profile_status: Label
var controls:Array[Control]=[]
var fields:Dictionary={}
var protocol:Button
var microphone:Button
var status:Label
var provider:="openai"
var input_device:=""
var panel:Node
var preset_button:Button
var test_status:Label
var stt_provider:="off"
var stt_mode:="ptt"
## Town chattiness (ai_config "chattiness", world/ai/chattiness.gd): lower = quieter day, much quieter night.
const CHATTINESS_STEPS:=[1.0,0.75,0.5,0.25,0.1]
var chattiness:=1.0
## Built-in Whisper's model (world/ai/builtin_stt.gd MODELS): bigger ones download once.
const BUILTIN_MODELS:=[["base","Base (fast, built in)"],["small","Small (better, 490 MB download)"],["medium","Medium (much better, 540 MB download)"],["turbo","Large v3 Turbo (best, 575 MB download, slower)"]]
var stt_builtin_model:="base"
var _stt_model_status: Label
var _stt_status_clock := 0.0
var tts_provider:="none"
var voice_mode:="ponese"
var _tts_choices:Array=TTS_PROVIDERS
var _buttons:Dictionary={}
var _rows:Dictionary={}
var _ordered:Array[Control]=[]
## Choice rows whose options unfold under them (choice() with options).
var _drops:Array[Button]=[]
var _warning:Label
var _scroll:ScrollContainer
var _list:VBoxContainer
var _tester:Node
var _preset:=0

func setup(surface:Node, in_tab := false)->void:
	embedded = in_tab
	theme = STYLE.theme()
	panel=surface;size=Vector2(900,840);mouse_filter=Control.MOUSE_FILTER_IGNORE
	_scroll=ScrollContainer.new();_scroll.follow_focus=true
	_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.get_v_scroll_bar().value_changed.connect(func(_value):panel.refresh())
	add_child(_scroll); _scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin:=MarginContainer.new();margin.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	# Embedded, a few pixels all round still keep a hovered row's lift and focus ring unclipped.
	margin.add_theme_constant_override("margin_left",8 if embedded else 66);margin.add_theme_constant_override("margin_right",16 if embedded else 46)
	margin.add_theme_constant_override("margin_top",4 if embedded else 36);margin.add_theme_constant_override("margin_bottom",24)
	_scroll.add_child(margin)
	_list=VBoxContainer.new();_list.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_list.add_theme_constant_override("separation",10);margin.add_child(_list)
	label("AI Settings",30).visible = not embedded
	_warning=label("",21);_warning.add_theme_color_override("font_color",WARN)
	label("How much the AI runs",27)
	label("Every pony line is a paid request to your provider. \"Only when I talk\" stops the requests the game makes on its own; \"Off\" needs no provider at all.",19)
	_buttons.usage=choice("AI usage",USAGE_MODES,_set_to.bind("ai_usage"))
	_buttons.adult_hint=choice("Adult content policy hint",[[true,"On: tell the model this prompt follows adult content policies"],[false,"Off"]],_set_to.bind("adult_policy_hint"))
	_buttons.chattiness=choice("Town chattiness",CHATTINESS_STEPS.map(func(step:float)->Array:return [step,CHATTINESS_NAMES[step]]),_set_to.bind("chattiness"))
	label("Language model (LLM)",27)
	label("Choose your provider, paste your key, then fetch or enter a model.",20)
	preset_button=choice("Provider template",range(PRESETS.size()).map(func(i:int)->Array:return [i,PRESETS[i].name]),use_preset)
	protocol=choice("Protocol",PROTOCOLS,_pick_protocol)
	field("base_url","Provider base URL","https://your-provider.example/v1")
	field("api_key","API key","Leave empty for local servers",true)
	field("model","Model","Model ID from your provider")
	action("Fetch models", "refresh").pressed.connect(fetch_models)
	_model_picker = PICKER.new(); _model_picker.placeholder = "Choose a fetched model…"
	_model_picker.redraw = func() -> void: if panel != null: panel.refresh()
	_model_picker.toggled_open.connect(func(_open: bool) -> void: refresh())
	_model_picker.entries_changed.connect(refresh)
	_model_picker.item_selected.connect(func(index: int):
		if fields.model.text != _model_picker.get_item_text(index): _model_changed()
		fields.model.text = _model_picker.get_item_text(index); _connection_changed(false); refresh())
	_list.add_child(_model_picker); _ordered.append(_model_picker.head()); _model_picker.hide()
	_model_status = label("",20)
	# OpenRouter provider routing (dev 2026-10-25: "add a providers list choices for Openrouter"):
	# list the upstream providers serving the model and pin one, shown only for OpenRouter's URL.
	_buttons.route_fetch = action("Fetch OpenRouter providers for this model", "refresh"); _buttons.route_fetch.pressed.connect(fetch_routes)
	_route_picker = PICKER.new(); _route_picker.placeholder = "Automatic (OpenRouter picks)"
	_route_picker.redraw = func() -> void: if panel != null: panel.refresh()
	_route_picker.toggled_open.connect(func(_open: bool) -> void: refresh())
	_route_picker.entries_changed.connect(refresh)
	# Endpoint labels run long: clip the shown one so a selection never widens the 900 px page.
	_route_picker.fit_to_longest_item = false; _route_picker.clip_text = true
	_route_picker.item_selected.connect(func(index: int):
		openrouter_provider = str(_route_picker.get_item_metadata(index)); _connection_changed(false); refresh())
	_list.add_child(_route_picker); _ordered.append(_route_picker.head()); _route_picker.hide()
	_buttons.route_fallback = choice("If it is unavailable", [[true, FALLBACK_TEXT[true]], [false, FALLBACK_TEXT[false]]], _pick_fallbacks)
	_route_status = label("",20)
	fields.base_url.text_changed.connect(func(_text):_update_preset_hint())
	for key in ["base_url","api_key"]:fields[key].text_changed.connect(func(_text):_connection_changed();refresh())
	fields.model.text_changed.connect(func(_text):_model_changed();_connection_changed(false);refresh())
	action("Test connection", "check").pressed.connect(test_connection)
	test_status=label("",21)
	_buttons.cache=choice("Prompt cache hints",CACHE_MODES,_set_to.bind("cache_hints"))
	label("Prompt caching bills the unchanged start of each request at a discount. Anthropic and OpenAI-style providers need nothing here; the hints are for Claude through OpenRouter or similar routers.",19)
	label("Generation options",25)
	label("Check an option to override it. Unchecked sampling options use the provider's defaults; output tokens and timeout use the game's limits. Only enable options your model supports.",19)
	_build_options()
	var profile_toggle := action("Saved presets ▸", "save")
	_profile_box = VBoxContainer.new(); _profile_box.add_theme_constant_override("separation",10)
	_list.add_child(_profile_box); _profile_box.hide()
	profile_toggle.pressed.connect(func():
		_profile_box.visible = not _profile_box.visible
		profile_toggle.text = "Saved presets ▾" if _profile_box.visible else "Saved presets ▸"; refresh())
	var main_list := _list
	_list = _profile_box
	# Presets (dev 2026-09-28): choosing a preset applies it at once. A new preset needs an
	# unused name; changing a saved one is a separate, confirmed overwrite.
	_profile_pick = choice("Preset", _profile_options, _pick_profile)
	_profile_active = label("", 21)
	field("profile_name", "New preset name", "Type a new name to save these settings")
	fields.profile_name.max_length = 64
	fields.profile_name.text_changed.connect(func(_text): _refresh_profiles())
	_profile_save = action("Save as new preset", "plus"); _profile_save.pressed.connect(save_profile)
	_profile_overwrite = action("Overwrite", "save"); _profile_overwrite.pressed.connect(overwrite_profile)
	_profile_delete = action("Delete preset", "trash"); _profile_delete.pressed.connect(delete_profile)
	_profile_delete.theme_type_variation = "Danger"
	var profile_actions := HBoxContainer.new(); profile_actions.add_theme_constant_override("separation", 8)
	_list.add_child(profile_actions)
	for action: Button in [_profile_save, _profile_overwrite, _profile_delete]:
		action.reparent(profile_actions)
		action.custom_minimum_size = Vector2(0,56)
		action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action.add_theme_font_size_override("font_size",21)
		action.clip_text = true
	_profile_pick.clip_text = true
	_profile_status = label(PRESET_HELP,20)
	_list = main_list
	label("Voices",27)
	_buttons.voice=choice("Voices",VOICE_MODES,_set_to.bind("voice_mode"))
	_buttons.tts=choice("Voice server",func()->Array:return _tts_choices,_pick_tts)
	field("tts_base_url","Speech API base URL","https://api.openai.com/v1")
	field("tts_api_key","Speech API key","",true)
	field("tts_model","Speech model","gpt-4o-mini-tts")
	field("tts_voice","Default voice (a pony's \"openai_voice\" overrides)","alloy")
	field("tts_remote_url","Gradio host URL","https://xxxx.trycloudflare.com")
	field("tts_url","moss-tts URL","http://127.0.0.1:8000/tts")
	label("Speech to text",27)
	_buttons.stt=choice("Speech to text",STT_PROVIDERS,_set_to.bind("stt_provider"))
	field("stt_url","Whisper server URL","http://127.0.0.1:8790/transcribe")
	field("stt_base_url","Whisper API base URL","https://api.openai.com/v1")
	field("stt_api_key","Whisper API key","",true)
	field("stt_model","Whisper model","whisper-1")
	_buttons.stt_builtin_model=choice("Whisper model",BUILTIN_MODELS,_set_to.bind("stt_builtin_model"))
	_stt_model_status=label("",20)
	_buttons.stt_mode=choice("Talk",STT_MODES,_set_to.bind("stt_mode"))
	microphone=choice("Microphone",_microphone_options,_set_to.bind("input_device"))
	label("Photos",27)
	label("Hold a photo from the camera while you talk to a pony and she sees it. An image costs far more than a line of speech; only the turn that shows a photo sends it.",19)
	_buttons.vision=choice("Photos",VISION_MODES,_set_to.bind("vision_mode"))
	field("vision_base_url","Vision model base URL (OpenAI-compatible)","https://openrouter.ai/api/v1")
	field("vision_api_key","Vision API key","",true)
	field("vision_model","Vision model","A model that accepts images")
	status=label("",21)
	_save = action("Save settings", "save"); _save.pressed.connect(save_connection)
	_save.theme_type_variation = "Primary"; _save.custom_minimum_size.y = 56
	_back = action("Back", "back"); _back.pressed.connect(func():closed.emit()); _back.visible = not embedded
	_back.theme_type_variation = "Ghost"
	hide()

## Big sizes are section headings (a little gap above them), the rest quiet notes and statuses.
func label(text:String,font:=30)->Label:
	var node:=Label.new();node.text=text;node.custom_minimum_size.x=0
	node.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	if font>=25:
		node.theme_type_variation="Heading";node.add_theme_font_size_override("font_size",font-1)
		var gap:=Control.new();gap.custom_minimum_size.y=8;_list.add_child(gap)
	else:
		node.theme_type_variation="Muted";node.add_theme_font_size_override("font_size",font-3)
	_list.add_child(node);return node

func button(text:String)->Button:
	var node:=Button.new();node.text=text;node.custom_minimum_size=Vector2(0,48)
	node.add_theme_font_size_override("font_size",21);node.focus_entered.connect(panel.refresh)
	node.mouse_entered.connect(panel.refresh);node.mouse_exited.connect(panel.refresh)
	_list.add_child(node);_ordered.append(node);return node

## A button that does something, with its picture.
func action(text:String,icon_kind:String)->Button:
	var node:=button(text);node.icon=ICON.texture(icon_kind,22);return node

## A row showing a choice: its caption on the left, the current choice on the right (set_choice).
## Pressing it unfolds every option under it to pick from directly (dev 2026-10-27: "a choice
## direct instead of cycling by clicking"): `options` is the [value, label] pairs (or a Callable
## giving them when it unfolds), `pick` takes the chosen value.
func choice(caption:String,options:Variant=null,pick:=Callable())->Button:
	var node:=button("");node.theme_type_variation="Choice";node.custom_minimum_size.y=56
	var line:=HBoxContainer.new();line.mouse_filter=Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);line.offset_left=16;line.offset_right=-14
	line.add_theme_constant_override("separation",12);node.add_child(line)
	var name_label:=Label.new();name_label.text=caption;name_label.theme_type_variation="Muted"
	name_label.add_theme_font_size_override("font_size",18);name_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	name_label.size_flags_vertical=Control.SIZE_SHRINK_CENTER;line.add_child(name_label)
	var value:=Label.new();value.add_theme_font_override("font",STYLE.BOLD);value.add_theme_font_size_override("font_size",19)
	value.size_flags_horizontal=Control.SIZE_EXPAND_FILL;value.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT
	value.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;value.mouse_filter=Control.MOUSE_FILTER_IGNORE
	value.size_flags_vertical=Control.SIZE_SHRINK_CENTER;line.add_child(value)
	var more:=TextureRect.new();more.texture=STYLE.icon("chevron_down");more.modulate=STYLE.PINK.lightened(0.3)
	more.size_flags_vertical=Control.SIZE_SHRINK_CENTER;more.mouse_filter=Control.MOUSE_FILTER_IGNORE;line.add_child(more)
	node.set_meta("value",value)
	node.resized.connect(func()->void:_fit_choice.call_deferred(node))
	if options!=null:
		var drop:=VBoxContainer.new();drop.hide();_list.add_child(drop)
		node.set_meta("drop",drop);node.set_meta("entries",[]);_drops.append(node)
		node.pressed.connect(_unfold.bind(node,options,pick))
	return node

## Unfolds `node`'s options under it (folding any other), or folds them again.
func _unfold(node:Button,options:Variant,pick:Callable)->void:
	var was_open:bool=(node.get_meta("drop") as Control).visible
	_fold_all()
	if was_open:refresh();return
	var shown:=(node.get_meta("value") as Label).text
	var well:=PanelContainer.new()
	well.add_theme_stylebox_override("panel",STYLE.box(Color(0.05,0.02,0.09,0.55),Color(STYLE.PINK,0.35),1,14,6,6))
	(node.get_meta("drop") as Control).add_child(well)
	var list:=VBoxContainer.new();list.add_theme_constant_override("separation",2);well.add_child(list)
	var entries:Array=[]
	for option:Array in (options.call() if options is Callable else options):
		var entry:=Button.new();entry.theme_type_variation="Ghost";entry.text=str(option[1])
		entry.alignment=HORIZONTAL_ALIGNMENT_LEFT;entry.custom_minimum_size.y=44
		entry.add_theme_font_size_override("font_size",19);entry.set_meta("no_sparkle",true)
		if str(option[1])==shown:
			entry.add_theme_color_override("font_color",STYLE.PINK)
			entry.icon=ICON.texture("check",16);entry.icon_alignment=HORIZONTAL_ALIGNMENT_RIGHT
			entry.add_theme_color_override("icon_normal_color",STYLE.PINK)
		entry.pressed.connect(_choose.bind(option[0],pick))
		entry.mouse_entered.connect(panel.refresh);entry.mouse_exited.connect(panel.refresh);entry.focus_entered.connect(panel.refresh)
		list.add_child(entry);entries.append(entry)
	node.set_meta("entries",entries)
	(node.get_meta("drop") as Control).show()
	refresh()

func _choose(value:Variant,pick:Callable)->void:
	_fold_all()
	if pick.is_valid():pick.call(value)
	refresh()

func _fold_all()->void:
	for node in _drops:
		var drop:Control=node.get_meta("drop")
		if not drop.visible:continue
		drop.hide();node.set_meta("entries",[])
		for child in drop.get_children():child.queue_free()

## A choice row's pick that only sets one of this page's values.
func _set_to(value:Variant,property:String)->void:
	set(property,value)

const FALLBACK_TEXT:={true:"let OpenRouter use another provider",false:"fail, never switch provider"}

func _pick_protocol(value:Variant)->void:
	if str(value)==provider:return
	provider=str(value);_connection_changed()

func _pick_fallbacks(value:Variant)->void:
	if bool(value)==openrouter_fallbacks:return
	openrouter_fallbacks=bool(value);_connection_changed(false)

func _pick_tts(value:Variant)->void:
	tts_provider=str(value)
	if tts_provider!="none" and voice_mode=="ponese":voice_mode="auto"

func _profile_options()->Array:
	return profiles.names().map(func(name:String)->Array:return [name,name])

func _pick_profile(value:Variant)->void:
	_selected_profile=str(value);use_profile()

func _microphone_options()->Array:
	var out:Array=[["","System default"]]
	for device:String in AudioServer.get_input_device_list():
		if device!="Default":out.append([device,device])
	return out

## Shows `text` as a choice row's value (a plain button takes it as its text).
func set_choice(node:Button,text:String)->void:
	if node.has_meta("value"):
		var value:Label=node.get_meta("value")
		if value.text==text:return
		value.text=text
		node.tooltip_text=text
		_fit_choice.call_deferred(node)
	else:node.text=text

## A choice row as tall as its value's wrapped lines, once they are laid out at the row's width.
func _fit_choice(node:Button)->void:
	if not is_instance_valid(node):return
	var lines:=maxi(1,(node.get_meta("value") as Label).get_line_count())
	var tall:=56.0 if lines<=1 else 32.0+lines*24.0
	if node.custom_minimum_size.y!=tall:node.custom_minimum_size.y=tall;if panel!=null:panel.refresh()

## A caption + line edit pair; `fields[key]` is the LineEdit, hidden together via `_rows`.
func field(key:String,caption:String,placeholder:String,secret:=false)->LineEdit:
	var row:=VBoxContainer.new();row.add_theme_constant_override("separation",4);_list.add_child(row)
	var name_label:=Label.new();name_label.text=caption;name_label.theme_type_variation="Muted"
	name_label.add_theme_font_size_override("font_size",18);row.add_child(name_label)
	var edit:=LineEdit.new();edit.custom_minimum_size=Vector2(0,46);edit.placeholder_text=placeholder
	edit.add_theme_font_size_override("font_size",20);edit.secret=secret
	edit.text_changed.connect(func(_text):panel.refresh());edit.focus_entered.connect(panel.refresh)
	row.add_child(edit);_ordered.append(edit);fields[key]=edit;_rows[key]=row;return edit

func open()->void:
	_save.text = "Save and continue" if setup_mode else "Save settings"
	_back.text = "Quit" if setup_mode else "Back"
	_connection_changed()
	var config:RefCounted=CONFIG.load_config() if config_path == CONFIG.USER_PATH else CONFIG.load_config([config_path])
	var connection:Dictionary=config.section("llm")
	_llm_values = connection.duplicate(true)
	_load_options(connection)
	provider=str(connection.get("provider","openai"))
	for key in ["base_url","model","api_key"]:fields[key].text=str(connection.get(key,""))
	_load_route(connection)
	chattiness=float(config.get_value("chattiness",1.0))
	if not CHATTINESS_STEPS.has(chattiness):chattiness=1.0
	ai_usage=CONFIG.usage_of(config)
	adult_policy_hint=bool(config.get_value("adult_policy_hint",false))
	cache_hints=str(connection.get("cache_hints","auto"))
	if cache_hints not in CONFIG.CACHE_HINTS:cache_hints="auto"
	var stt:Dictionary=config.section("stt")
	input_device=str(stt.get("input_device",""))
	stt_provider=str(stt.get("provider","off"))
	stt_provider = setup_stt_provider(stt_provider, str(stt.get("url", "")))
	stt_mode=str(stt.get("mode","ptt"))
	stt_builtin_model=str(stt.get("builtin_model","base"))
	if stt_builtin_model not in ["base","small","medium","turbo"]:stt_builtin_model="base"
	if stt_mode not in ["ptt","vad"]:stt_mode="ptt"
	fields.stt_url.text=str(stt.get("url",""));fields.stt_base_url.text=str(stt.get("base_url",""))
	fields.stt_api_key.text=str(stt.get("api_key",""));fields.stt_model.text=str(stt.get("model","whisper-1"))
	var tts:Dictionary=config.section("tts")
	tts_provider=str(tts.get("provider","none"));voice_mode=str(tts.get("voice_mode","ponese")).replace("animalese","ponese")
	_tts_choices=TTS_PROVIDERS.duplicate()
	# The developer's Python proxy path stays selectable only where it is already in use.
	if tts_provider=="remote":_tts_choices.append(["remote","Gradio host via local proxy (tools/ai)"])
	for key in ["base_url","api_key","model","voice","remote_url","url"]:fields["tts_"+key].text=str(tts.get(key,""))
	var vision:Dictionary=config.section("vision")
	vision_mode=str(vision.get("mode","off"))
	if vision_mode not in ["off","same","separate"]:vision_mode="off"
	for key in ["base_url","api_key","model"]:fields["vision_"+key].text=str(vision.get(key,""))
	_warning.text="\n".join(config.warnings)
	_warning.visible=not config.warnings.is_empty()
	test_status.text=""
	status.text="Without a voice server every pony speaks local ponese."
	profiles.open(profiles_path)
	_delete_profile_confirm = ""; _overwrite_confirm = ""
	fields.profile_name.text = ""
	# The active preset is the saved one that matches the live dialogue settings, if any.
	_selected_profile = ""
	for name: String in profiles.names():
		if not _differs(profiles.get_profile(name)): _selected_profile = name; break
	_refresh_profiles()
	_profile_status.text = profiles.error if not profiles.error.is_empty() else PRESET_HELP
	_update_preset_hint()
	show();refresh();_scroll.scroll_vertical=0;preset_button.grab_focus()

func refresh()->void:
	set_choice(protocol,_caption(PROTOCOLS,provider))
	set_choice(preset_button,PRESETS[_preset].name)
	_refresh_profiles()
	set_choice(microphone,"System default" if input_device.is_empty() else input_device)
	set_choice(_buttons.usage,_caption(USAGE_MODES,ai_usage))
	set_choice(_buttons.chattiness,str(CHATTINESS_NAMES.get(chattiness,"Normal")))
	_buttons.chattiness.visible=ai_usage=="full"
	set_choice(_buttons.adult_hint,"On: tell the model this prompt follows adult content policies" if adult_policy_hint else "Off")
	_buttons.adult_hint.visible=ai_usage!="off"
	set_choice(_buttons.cache,_caption(CACHE_MODES,cache_hints))
	set_choice(_buttons.stt,_caption(STT_PROVIDERS,stt_provider))
	set_choice(_buttons.stt_mode,_caption(STT_MODES,stt_mode))
	set_choice(_buttons.voice,_caption(VOICE_MODES,"auto" if voice_mode=="tts" else voice_mode))
	set_choice(_buttons.tts,_caption(_tts_choices,tts_provider))
	_rows.stt_url.visible=stt_provider=="local"
	for key in ["stt_base_url","stt_api_key","stt_model"]:_rows[key].visible=stt_provider=="openai"
	_buttons.stt_mode.visible=stt_provider!="off";microphone.visible=stt_provider!="off"
	set_choice(_buttons.stt_builtin_model,_caption(BUILTIN_MODELS,stt_builtin_model))
	_buttons.stt_builtin_model.visible=stt_provider=="builtin"
	_stt_model_status.visible=stt_provider=="builtin" or (setup_mode and stt_provider=="off" and not CONFIG.supports_builtin_stt(platform_name()))
	_update_stt_model_status()
	for key in ["tts_base_url","tts_api_key","tts_model","tts_voice"]:_rows[key].visible=tts_provider=="openai"
	_rows.tts_remote_url.visible=tts_provider in ["gradio","remote"]
	_rows.tts_url.visible=tts_provider=="moss"
	set_choice(_buttons.vision,_caption(VISION_MODES,vision_mode))
	for key in ["vision_base_url","vision_api_key","vision_model"]:_rows[key].visible=vision_mode=="separate"
	var openrouter:=provider=="openai" and CONFIG.is_openrouter(fields.base_url.text)
	_buttons.route_fetch.visible=openrouter
	_route_picker.visible=openrouter
	_buttons.route_fallback.visible=openrouter and not openrouter_provider.is_empty()
	set_choice(_buttons.route_fallback,FALLBACK_TEXT[openrouter_fallbacks])
	_route_status.visible=openrouter
	_route_status.text="OpenRouter provider: "+("automatic (OpenRouter picks)" if openrouter_provider.is_empty() else openrouter_provider)+("\n"+_route_note if not _route_note.is_empty() else "")
	# A row hidden while its options show folds them.
	for node in _drops:
		if (node.get_meta("drop") as Control).visible and not node.visible:_fold_all()
	# Rebuilt in place: hosts keep a reference to this array for focus stepping.
	controls.clear()
	for control in _ordered:
		if control.is_visible_in_tree():controls.append(control)
		if control is Button and control in _drops:
			for entry:Control in control.get_meta("entries"):controls.append(entry)
		# An unfolded dropdown's entries follow its head (stick focus reaches them).
		for picker:Control in [_model_picker,_route_picker]:
			if picker!=null and control==picker.head() and picker.is_open():controls.append_array(picker.controls)
	if panel!=null:panel.refresh()

func _caption(choices:Array,value:String)->String:
	for choice in choices:
		if choice[0]==value:return choice[1]
	return value

const PRESET_HELP := "Presets keep dialogue settings and their key on this computer. Choosing a preset applies it immediately."

## True when the page's dialogue fields are not the settings of `saved`.
func _differs(saved: Dictionary) -> bool:
	if saved.is_empty(): return true
	var now := _llm_connection()
	# Presets saved before OpenRouter routing existed read as its defaults.
	for key in ["provider", "base_url", "model", "api_key", "openrouter_provider", "openrouter_fallbacks"]:
		if str(now.get(key, CONFIG.DEFAULTS.llm[key])) != str(saved.get(key, CONFIG.DEFAULTS.llm[key])): return true
	var current_options: Dictionary = CONFIG.OPTIONS.selected(now)
	var saved_options: Dictionary = CONFIG.OPTIONS.selected(saved)
	if current_options.size() != saved_options.size(): return true
	for key: String in current_options:
		if not saved_options.has(key) or not is_equal_approx(float(current_options[key]), float(saved_options[key])): return true
	return false

func _refresh_profiles() -> void:
	if _profile_pick == null: return
	var names: Array = profiles.names()
	if _selected_profile not in names: _selected_profile = ""
	var edited := not _selected_profile.is_empty() and _differs(profiles.get_profile(_selected_profile))
	set_choice(_profile_pick, (_selected_profile if not _selected_profile.is_empty() else "none") if not names.is_empty() else "No saved presets yet")
	_profile_pick.tooltip_text = _selected_profile
	_profile_pick.disabled = names.is_empty()
	_profile_active.text = "Active: " + ("custom settings, not a saved preset" if _selected_profile.is_empty() else _selected_profile + (" (edited, not saved)" if edited else ""))
	var typed: String = fields.profile_name.text.strip_edges()
	var taken: bool = profiles.profiles.has(typed)
	_profile_save.text = "Name already used" if taken else "Save as new preset"
	_profile_save.disabled = typed.is_empty() or taken
	_profile_overwrite.visible = edited
	_profile_overwrite.text = ("Confirm overwrite" if _overwrite_confirm == _selected_profile else "Overwrite \"" + _selected_profile + "\"") if edited else "Overwrite"
	_profile_delete.disabled = _selected_profile.is_empty()
	_profile_delete.text = "Confirm delete" if _delete_profile_confirm == _selected_profile and not _selected_profile.is_empty() else "Delete preset"
	if panel != null: panel.refresh()

## A new, unused name only: saving never replaces an existing preset. The new preset becomes active.
func save_profile() -> void:
	var name: String = fields.profile_name.text.strip_edges()
	if profiles.profiles.has(name):
		_profile_status.text = "A preset called " + name + " already exists. Pick another name, or switch to it and use Overwrite."
		_refresh_profiles(); return
	if not profiles.save_profile(name, _llm_connection()):
		_profile_status.text = profiles.error; _refresh_profiles(); return
	_selected_profile = name
	use_profile()
	_profile_status.text = "Saved new preset " + name + " and switched to it."

## Replace the active preset with the edited fields: a second press confirms. Then applies it.
func overwrite_profile() -> void:
	if _selected_profile.is_empty() or not _differs(profiles.get_profile(_selected_profile)): return
	if _overwrite_confirm != _selected_profile:
		_overwrite_confirm = _selected_profile
		_profile_status.text = "Press Confirm overwrite to replace the saved preset " + _selected_profile + " with the settings shown."
		_refresh_profiles(); return
	_overwrite_confirm = ""
	if not profiles.save_profile(_selected_profile, _llm_connection()):
		_profile_status.text = profiles.error; _refresh_profiles(); return
	var name := _selected_profile
	use_profile()
	_profile_status.text = "Overwrote preset " + name + " and applied it."

func use_profile() -> void:
	var connection: Dictionary = profiles.get_profile(_selected_profile)
	if connection.is_empty(): return
	var error: String = CONFIG.save_llm(connection, config_path)
	if not error.is_empty() and not error.begins_with("!"):
		_profile_status.text = error; _refresh_profiles(); return
	# Cancel an old connection test so its late result cannot label this preset.
	if is_instance_valid(_tester): _tester.cancel(); _tester.queue_free(); _tester = null
	_connection_changed()
	_llm_values = connection.duplicate(true)
	_load_options(connection)
	provider = str(connection.provider)
	for key in ["base_url", "model", "api_key"]: fields[key].text = str(connection.get(key, ""))
	_load_route(connection)
	fields.profile_name.text = ""
	test_status.text = ""; _delete_profile_confirm = ""; _overwrite_confirm = ""
	_update_preset_hint()
	var director: Node = get_tree().get_first_node_in_group("conversation_director")
	var note := ""
	if director != null and director.has_method("reload_config"): note = str(director.reload_config())
	_profile_status.text = "Switched to preset " + _selected_profile + "." + (" " + note if not note.is_empty() else "") + (error.substr(1) if error.begins_with("!") else "")
	refresh()

func delete_profile() -> void:
	if _selected_profile.is_empty(): return
	if _delete_profile_confirm != _selected_profile:
		_delete_profile_confirm = _selected_profile
		_profile_status.text = "Press Confirm delete to remove this saved preset. Active dialogue settings will stay as they are."
	else:
		var name := _selected_profile
		_profile_status.text = "Deleted preset: " + name if profiles.delete_profile(name) else profiles.error
		_delete_profile_confirm = ""
	_refresh_profiles()

func _preset_name()->String:
	var url:String=fields.base_url.text.strip_edges().rstrip("/")
	for preset in PRESETS:
		if preset.base_url!="" and preset.base_url==url and preset.provider==provider:return preset.name
	return "Custom"

## Recognises the preset from the typed URL (Custom when none matches).
func _update_preset_hint()->void:
	var current:=_preset_name()
	for i in PRESETS.size():
		if PRESETS[i].name==current:_preset=i
	fields.model.placeholder_text=PRESETS[_preset].model
	if preset_button!=null:set_choice(preset_button,current)

## Fills protocol and base URL from preset `index` (Custom keeps them).
func use_preset(index:Variant)->void:
	_preset=int(index)
	var preset:Dictionary=PRESETS[_preset]
	if preset.provider!="":
		provider=preset.provider;fields.base_url.text=preset.base_url
		fields.api_key.clear(); fields.model.clear()
		openrouter_provider=""; openrouter_fallbacks=true
	_connection_changed()
	fields.model.placeholder_text=preset.model
	test_status.text=""
	refresh()


func _llm_connection()->Dictionary:
	var connection:Dictionary=_llm_values.duplicate(true)
	connection.provider = provider
	for key in ["base_url","model","api_key"]:connection[key]=fields[key].text.strip_edges()
	# Routing means nothing to other servers: keep their saved settings at the defaults.
	var openrouter:=CONFIG.is_openrouter(str(connection.base_url))
	connection.openrouter_provider=openrouter_provider if openrouter else ""
	connection.openrouter_fallbacks=openrouter_fallbacks or not openrouter
	connection.generation_overrides = {}
	for key: String in _options:
		if _options[key].check.button_pressed:
			connection.generation_overrides[key] = _options[key].value.value
	connection.base_url=str(connection.base_url).rstrip("/")
	connection.cache_hints=cache_hints
	return connection

## One tiny request with the unsaved fields through a throwaway LLM client.
func test_connection()->void:
	var connection:=_llm_connection()
	if not CONFIG.valid_url(connection.base_url):test_status.text="Enter the provider's HTTP or HTTPS base URL.";panel.refresh();return
	if str(connection.model).is_empty():test_status.text="Enter the model name first.";panel.refresh();return
	if is_instance_valid(_tester):_tester.cancel();_tester.queue_free()
	_tester=LLM.new();_tester.name="ConnectionTest";add_child(_tester)
	connection.max_tokens = 16; connection.timeout = 25.0
	connection.generation_overrides.erase("max_tokens"); connection.generation_overrides.erase("timeout")
	_tester.configure(connection)
	test_status.add_theme_color_override("font_color",TEXT);test_status.text="Testing…";panel.refresh()
	var tester:=_tester
	var started:bool=_tester.complete("You are a connection test. Reply with the single word OK.",[{"role":"user","content":"Say OK."}],
		func(text:String,error:String)->void:
			if tester!=_tester:return
			test_status.add_theme_color_override("font_color",TEXT if error.is_empty() else WARN)
			test_status.text=("Connection works. Reply: \"%s\""%text.left(60)) if error.is_empty() else "Connection failed: "+_friendly(error)
			_tester.queue_free();_tester=null;panel.refresh())
	if not started:test_status.text="Could not start the test request.";panel.refresh()

func _friendly(error:String)->String:
	if error.begins_with("http result"):return error+" (server unreachable, wrong address or timeout)"
	if error.begins_with("http 401") or error.begins_with("http 403"):return "the key was refused ("+error.left(120)+")"
	if error.begins_with("http 404"):return "not found; check the base URL and model ("+error.left(120)+")"
	return error.left(200)

func _stt_section()->Dictionary:
	return {"provider":stt_provider,"mode":stt_mode,"url":fields.stt_url.text,"base_url":fields.stt_base_url.text,
		"api_key":fields.stt_api_key.text.strip_edges(),"model":fields.stt_model.text.strip_edges(),"builtin_model":stt_builtin_model}

func _tts_section()->Dictionary:
	var section:={"provider":tts_provider,"voice_mode":voice_mode}
	for key in ["base_url","api_key","model","voice","remote_url","url"]:section[key]=fields["tts_"+key].text.strip_edges()
	return section

func _vision_section()->Dictionary:
	var section:={"mode":vision_mode}
	for key in ["base_url","api_key","model"]:section[key]=fields["vision_"+key].text.strip_edges()
	return section

func save_connection()->void:
	var error:=CONFIG.save_connection(_llm_connection(),input_device,config_path,{"stt":_stt_section(),"tts":_tts_section(),"chattiness":chattiness,"ai_usage":ai_usage,"adult_policy_hint":adult_policy_hint,"vision":_vision_section()})
	status.add_theme_color_override("font_color",WARN if not error.is_empty() and not error.begins_with("!") else TEXT)
	if not error.is_empty() and not error.begins_with("!"):
		status.text=error;panel.refresh();return
	if setup_mode: Settings.set_value("setup/completed", true)
	if setup_mode: closed.emit(); return
	var note:=error.substr(1)
	var director:Node=get_tree().get_first_node_in_group("conversation_director") if is_inside_tree() else null
	if director!=null and director.has_method("reload_config"):
		var applied:String=director.reload_config()
		status.text="Saved and applied."+(" "+applied if not applied.is_empty() else "")+note
		if ai_usage=="off":status.text+=" The AI sends nothing from now on; it is fully gone the next time you enter Equestria."
	else:
		status.text="Saved. Your connection will be used when you enter Equestria."+note
	_warning.visible=false
	refresh()

## Creates user://mods/prompts with a README and opens it in the file manager.
func open_persona_folder()->void:
	var folder:=ProjectSettings.globalize_path(CONFIG.MOD_PROMPTS)
	DirAccess.make_dir_recursive_absolute(folder)
	var readme:=folder.path_join("README.txt")
	if not FileAccess.file_exists(readme):
		var file:=FileAccess.open(readme,FileAccess.WRITE)
		if file!=null:file.store_string(_readme_text());file.close()
	var err:=OS.shell_open(folder)
	status.add_theme_color_override("font_color",TEXT)
	status.text=("Persona folder: "+folder) if err==OK else ("Could not open a file manager. The folder is "+folder)
	panel.refresh()

func _readme_text()->String:
	var names:PackedStringArray=[]
	for dir in ["res://world/ai/prompts","res://world/characters/background/ai","res://world/characters/princesses"]:
		for file in DirAccess.get_files_at(dir):
			if file.ends_with(".md"):names.append(file)
	return """Home: Equestria persona overrides
==================================

A .md file in this folder replaces the game's prompt file with the same name:

  system.md          shared dialogue rules for every pony
  <pony>.md          one pony's persona, e.g. rainbow_dash.md, derpy_hooves.md

Write plain text, like the originals: who she is, how she talks, what she cares about.
Delete a file to go back to the game's version. Changes apply the next time you save the
AI Settings page, or when you next enter Equestria.

The originals ship inside the game; the source release has them in world/ai/prompts/,
world/characters/background/ai/ and world/characters/princesses/.

Prompt file names in this build:
  """+"\n  ".join(names)+"\n"


## Observes the existing recognizer only; opening this page never starts a microphone.
func _process(delta: float) -> void:
	if not is_visible_in_tree() or stt_provider != "builtin": return
	_stt_status_clock -= delta
	if _stt_status_clock > 0.0: return
	_stt_status_clock = 0.35
	_update_stt_model_status()

func _update_stt_model_status() -> void:
	if _stt_model_status == null or not is_inside_tree(): return
	if not CONFIG.supports_builtin_stt(platform_name()):
		_stt_model_status.text = CONFIG.builtin_unavailable(platform_name())
		return
	var service: Node = get_tree().get_first_node_in_group("builtin_speech_services")
	var text := "Selected: " + _caption(BUILTIN_MODELS, stt_builtin_model)
	if service == null:
		text += " · Speech recognition starts when you enter Equestria."
	else:
		var state: Dictionary = service.model_state()
		if str(state.selected) != stt_builtin_model: text += " · Save settings to apply.\n"
		else: text = "" if str(state.status).begins_with("Selected:") else text + " · "
		text += str(state.status)
	if _stt_model_status.text == text: return
	_stt_model_status.text = text
	if panel != null: panel.refresh()

func platform_name() -> String:
	return OS.get_name()

func setup_stt_provider(selected: String, url: String) -> String:
	if CONFIG.supports_builtin_stt(platform_name()) and setup_mode and (selected == "off" or (selected == "local" and url in ["http://127.0.0.1:8790/transcribe", "http://localhost:8790/transcribe"])): return "builtin"
	return selected


func _build_options() -> void:
	# Rows flow two abreast where the page is wide and one under another where it is not.
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation",16); grid.add_theme_constant_override("v_separation",6); _list.add_child(grid)
	for key: String in CONFIG.OPTIONS.SPECS:
		var spec: Array = CONFIG.OPTIONS.SPECS[key]
		var row := HBoxContainer.new(); row.custom_minimum_size.x = 300; grid.add_child(row)
		var check := CheckBox.new(); check.text = str(spec[0]); check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		check.add_theme_font_size_override("font_size",19); row.add_child(check)
		var value := SpinBox.new(); value.min_value = float(spec[1]); value.max_value = float(spec[2])
		value.step = float(spec[3]); value.value = float(spec[4]); value.custom_minimum_size.x = 115
		value.add_theme_font_size_override("font_size",19); value.editable = false; row.add_child(value)
		_options[key] = {"check":check,"value":value}
		_ordered.append(check); _ordered.append(value.get_line_edit())
		check.toggled.connect(func(enabled: bool): value.editable = enabled; _connection_changed(false); refresh())
		value.value_changed.connect(func(_number): _connection_changed(false); refresh())

func _load_options(connection: Dictionary) -> void:
	var selected: Dictionary = CONFIG.OPTIONS.selected(connection)
	for key: String in _options:
		var option: Dictionary = _options[key]
		option.check.set_pressed_no_signal(selected.has(key))
		option.value.set_value_no_signal(float(selected.get(key, CONFIG.OPTIONS.SPECS[key][4])))
		option.value.editable = selected.has(key)

func _connection_changed(clear_models := true) -> void:
	_overwrite_confirm = ""
	if is_instance_valid(_tester): _tester.cancel(); _tester.queue_free(); _tester = null
	if test_status != null: test_status.text = ""
	if clear_models:
		if is_instance_valid(_catalog): _catalog.cancel(); _catalog.queue_free(); _catalog = null
		_model_picker.clear(); _model_picker.hide(); _model_status.text = ""
		_clear_routes()

## The pinned OpenRouter provider served the previous model; a new model starts on automatic routing.
func _model_changed() -> void:
	openrouter_provider = ""; openrouter_fallbacks = true
	_clear_routes()

func _load_route(connection: Dictionary) -> void:
	openrouter_provider = str(connection.get("openrouter_provider", "")).strip_edges()
	openrouter_fallbacks = connection.get("openrouter_fallbacks", true) != false
	_route_items([])

## Forgets the fetched provider list (not the choice): it belonged to another model or address.
func _clear_routes() -> void:
	if is_instance_valid(_route_catalog): _route_catalog.cancel(); _route_catalog.queue_free(); _route_catalog = null
	_route_note = ""
	_route_items([])

## Automatic, the fetched endpoints, and the current choice even when no fetch lists it, so a
## pinned provider can always be cleared. False when the choice had to be added that way.
func _route_items(endpoints: Array) -> bool:
	if _route_picker == null: return true
	_route_picker.clear()
	_route_picker.add_item("Automatic (OpenRouter picks)"); _route_picker.set_item_metadata(0, "")
	for endpoint: Dictionary in endpoints:
		_route_picker.add_item(str(endpoint.label)); _route_picker.set_item_metadata(_route_picker.item_count - 1, str(endpoint.tag))
	for index in _route_picker.item_count:
		if str(_route_picker.get_item_metadata(index)) == openrouter_provider: _route_picker.selected = index; return true
	_route_picker.add_item(openrouter_provider + "  (saved)"); _route_picker.set_item_metadata(_route_picker.item_count - 1, openrouter_provider)
	_route_picker.selected = _route_picker.item_count - 1
	return false

func fetch_routes() -> void:
	_clear_routes()
	_route_catalog = preload("res://world/ai/openrouter_providers.gd").new(); add_child(_route_catalog)
	var catalog := _route_catalog
	_route_catalog.completed.connect(func(endpoints: Array, error: String):
		if catalog != _route_catalog: return
		_route_note = error if not error.is_empty() else "%d providers serve this model. Choose one below." % endpoints.size()
		if not _route_items(endpoints) and not endpoints.is_empty(): _route_note += " Your chosen provider is not in this list now."
		_route_catalog.queue_free(); _route_catalog = null; refresh())
	_route_note = "Fetching providers…"; refresh()
	_route_catalog.fetch(_llm_connection())

func fetch_models() -> void:
	_connection_changed()
	_catalog = preload("res://world/ai/model_catalog.gd").new(); add_child(_catalog)
	var catalog := _catalog
	_catalog.completed.connect(func(models: PackedStringArray, error: String):
		if catalog != _catalog: return
		_model_status.text = error if not error.is_empty() else "%d models available. Choose one below or enter its ID." % models.size()
		_model_picker.clear()
		for model_id: String in models: _model_picker.add_item(model_id)
		_model_picker.selected = Array(models).find(fields.model.text.strip_edges()); _model_picker.visible = not models.is_empty()
		_model_picker.set_open(not models.is_empty())
		_catalog.queue_free(); _catalog = null; refresh())
	_model_status.text = "Fetching models…"; panel.refresh()
	_catalog.fetch(_llm_connection())

func _notification(what: int) -> void:
	# Perf 0.1.0: the status poll (_process) runs only while this page is shown.
	if what == NOTIFICATION_READY or what == NOTIFICATION_VISIBILITY_CHANGED: set_process(is_visible_in_tree())
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if is_instance_valid(_catalog): _catalog.cancel()
		if is_instance_valid(_route_catalog): _route_catalog.cancel()
		if is_instance_valid(_tester): _tester.cancel()
