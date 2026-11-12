class_name AiConfig
extends RefCounted
## Settings for the voice loop: LLM provider, speech-to-text, text-to-speech, earshot.
##
## DEFAULTS below are the release defaults: no dialogue provider until the player sets
## one, no speech-to-text, and local Ponese voices. `res://ai_config.json` (source
## runs only, gitignored) and then `user://ai_config.json` are merged on top.
## `ai_config.example.json` documents every field; the Dialogue & microphone page writes
## the user file. docs/ALPHA_AI_AND_PORTABILITY.md lists the providers.

const OPTIONS := preload("res://world/ai/llm_options.gd")
const PATHS := ["res://ai_config.json", "user://ai_config.json"]
const USER_PATH := "user://ai_config.json"
const MOD_PROMPTS := "user://mods/prompts"

const DEFAULTS := {
	"llm": {
		"provider": "openai",           # "openai" (any OpenAI-compatible endpoint), "anthropic" or native "gemini"
		"base_url": "",
		"api_key": "",
		"model": "",
		"temperature": 0.8,
		"generation_overrides": {},
		"max_tokens": 220,
		"timeout": 90.0,
		"cache_hints": "auto",          # "auto" (Claude through OpenRouter), "on", "off": prompt-cache breakpoints on OpenAI-compatible endpoints
		"openrouter_provider": "",      # OpenRouter only: endpoint tag tried first (e.g. "deepinfra/turbo"); "" = OpenRouter routes
		"openrouter_fallbacks": true,   # OpenRouter only: false = that provider or nothing
	},
	"stt": {
		"provider": "off",              # "off"; "local" = whisper server at url (tools/ai/stt_server.sh); "openai" = {base_url}/audio/transcriptions
		"url": "http://127.0.0.1:8790/transcribe",
		"base_url": "https://api.openai.com/v1",
		"api_key": "",
		"model": "whisper-1",
		"mode": "ptt",                  # "ptt" push to talk, "vad" open mic, "off"
		"push_to_talk_action": "voice_talk",
		"vr_push_to_talk_button": "by_button",
		"input_device": "",             # AudioServer input device name; "" = system default
		"mic_source": null,             # PipeWire source for the mic stream; null = wivrn.source in XR, system default on desktop
		"vad_threshold": 0.012,         # RMS floor; adaptive noise floor sits above it
		"vad_hangover": 0.75,           # seconds of silence that end an utterance
		"vad_min_speech": 0.35,
		"vad_max_speech": 18.0,
	},
	# Photos the player shows a pony (world/ai/photo_vision.gd): "off" sends no image; "same" sends
	# it to the dialogue model above; "separate" asks this OpenAI-compatible vision model to describe it.
	"vision": {
		"mode": "off",
		"base_url": "",
		"api_key": "",
		"model": "",
	},
	"tts": {
		"provider": "none",             # "none"; "openai" = {base_url}/audio/speech; "gradio" = MOSS-TTS Gradio host at remote_url; "moss" = moss-tts at url; "remote" = Gradio via tools/ai/tts_proxy.py (legacy)
		"url": "http://127.0.0.1:8000/tts",
		"proxy_url": "http://127.0.0.1:8791/tts",
		"remote_url": "",               # Gradio host for "gradio"/"remote" (a Colab tunnel, your own box)
		"gradio_api": "synthesize",
		"base_url": "https://api.openai.com/v1",
		"api_key": "",
		"model": "gpt-4o-mini-tts",
		"voice": "alloy",               # per pony: "openai_voice" in its profile JSON
		"timeout": 60.0,
		"style_strength": 1.0,
		"voice_mode": "ponese",      # "ponese" = all local; "auto" = character TTS, unvoiced ponies Ponese; "tts" = force TTS
		"chatter_fallback": true,        # local voice when synthesis fails
	},
	# engine: "auto" = the in-process recogniser first (lip_sync_native.gd), "rhubarb" = skip it.
	"lip_sync": {"rhubarb_path": "", "engine": "auto"},  # rhubarb_path: optional absolute path to the Rhubarb executable
	"group_conversations": {"enabled": true, "ambient": true, "initial_delay_seconds": 12.0, "cooldown_seconds": 30.0,
		"ambient_radius_m":30.0, "ambient_chance_per_pony_second":.012, "ambient_reply_chance":.8,
		"ambient_cooldown_seconds":12.0, "ambient_pony_cooldown_seconds":75.0},
	"player_approaches": {"enabled":true,"radius_m":24.0,"chance":.2,"cooldown_seconds":120.0,"pony_cooldown_seconds":900.0},
	## How much the AI runs (docs/AI_TOKENS_AND_CACHING_2026_10_25.md): "full"; "talk" = only when the
	## player speaks to or touches a pony (no overheard pony chatter, approach greetings or lulls);
	## "off" = no dialogue model at all (the game runs as with --no-ai; first launch needs no provider).
	"ai_usage": "full",
	"adult_policy_hint": false,
	"earshot_m": 10.0,
	"chattiness": 1.0,               # town chatter: 1 = normal, lower = quieter day, much quieter night (world/ai/chattiness.gd)
	"history_turns": 16,
	"player_name": "Anon",
	"debug": false,
}

var data: Dictionary = {}
## Human-readable problems met while loading (an invalid user file, say); the
## provider page shows them.
var warnings: PackedStringArray = []


static func load_config(paths: Array = PATHS, platform: String = OS.get_name(), public_release: bool = OS.has_feature("public_release")) -> RefCounted:
	# load() rather than the class name: headless runs without an import scan do not know it.
	var config: RefCounted = (load("res://world/ai/ai_config.gd") as GDScript).new()
	config.data = DEFAULTS.duplicate(true)
	if public_release:
		config.data.llm.merge({"base_url":"","api_key":"","model":""},true)
		# Desktop testers start with offline Whisper. Other platforms require an
		# explicitly configured remote service; never send audio by default.
		config.data.stt.provider="builtin" if supports_builtin_stt(platform) else "off"
		config.data.debug=false
	for path in paths:
		# res:// overrides are a source-run convenience; exported builds read only user://.
		if path.begins_with("res://") and (OS.has_feature("public_release") or not OS.has_feature("editor")): continue
		if not FileAccess.file_exists(path):
			continue
		var text := FileAccess.get_file_as_string(path)
		var parser := JSON.new()
		var parsed: Variant = parser.data if parser.parse(text) == OK else null
		if parsed is Dictionary:
			if parsed.get("llm") is Dictionary:
				var legacy: Dictionary = parsed.llm
				if not legacy.has("generation_overrides") and legacy.has("temperature"):
					legacy.generation_overrides = OPTIONS.selected(legacy)
			var rejected: Array[String] = []
			_merge(config.data, parsed, DEFAULTS, "", rejected)
			for key_path: String in rejected:
				var warning := "AiConfig: invalid shape for %s, ignored" % key_path
				push_warning(warning)
				config.warnings.append(warning)
		else:
			var warning := "AiConfig: configuration is not a JSON object, ignored. Saving keeps a .broken backup."
			push_warning(warning)
			config.warnings.append(warning)
	return config

## Writes the provider page's sections into the user file, keeping every other key.
## `connection` is the llm section; `sections` may carry "stt" and "tts" dictionaries
## (merged key by key). An unreadable existing file is kept as `<file>.broken`.
## Returns "" on success, "!<note>" on success with a note, else the failure message.
static func save_connection(connection:Dictionary,input_device:String,path:=USER_PATH,sections:={},preserve_input_device:=false)->String:
	var usage := str(sections.get("ai_usage", ""))
	if not usage.is_empty() and usage not in USAGE_MODES: return "Choose how much the AI runs."
	var cache := str(connection.get("cache_hints", "auto"))
	if cache not in CACHE_HINTS: return "Choose a prompt cache setting."
	# With the AI off there is nothing to connect to: whatever is typed is kept, not checked.
	var llm_error := "" if usage == "off" else validate_llm(connection)
	if not llm_error.is_empty(): return llm_error
	var endpoint:=str(connection.get("base_url","")).strip_edges().rstrip("/")
	var stt_in:Dictionary=sections.get("stt",{})
	var vision_in:Dictionary=sections.get("vision",{})
	if not vision_in.is_empty():
		if str(vision_in.get("mode","off")) not in ["off","same","separate"]:return "Choose a photo vision setting."
		var vision_url:=str(vision_in.get("base_url","")).strip_edges().rstrip("/")
		if str(vision_in.mode)=="separate" and (not valid_url(vision_url) or str(vision_in.get("model","")).strip_edges().is_empty()):
			return "Enter the vision model's HTTP or HTTPS base URL and model name, or turn photo vision off."
	var tts_in:Dictionary=sections.get("tts",{})
	for key in ["url","base_url"]:
		if stt_in.has(key) and str(stt_in[key]).strip_edges()!="" and not valid_url(str(stt_in[key]).strip_edges().rstrip("/")):return "Enter an HTTP or HTTPS speech-to-text address."
	for key in ["url","base_url","remote_url"]:
		if tts_in.has(key) and str(tts_in[key]).strip_edges()!="" and not valid_url(str(tts_in[key]).strip_edges().rstrip("/")):return "Enter an HTTP or HTTPS voice server address."
	var absolute:=ProjectSettings.globalize_path(path)
	var data:Dictionary={}
	var note:=""
	if FileAccess.file_exists(path):
		var parser:=JSON.new()
		var readable:=parser.parse(FileAccess.get_file_as_string(path))==OK and parser.data is Dictionary
		if readable:
			data=parser.data
			for key in ["llm","stt","tts"]:
				if not data.get(key,{}) is Dictionary:readable=false
		if not readable:
			var backup:=absolute+".broken"
			var n:=1
			while FileAccess.file_exists(backup):
				backup=absolute+".broken.%d"%n;n+=1
			if DirAccess.copy_absolute(absolute,backup)!=OK:return "Existing settings could not be read or backed up; file preserved."
			data={};note=" The unreadable old file was kept as %s."%backup.get_file()
	var section:Dictionary=data.get("llm",{}).duplicate(true)
	for key in ["provider","base_url","model","api_key"]:section[key]=str(connection.get(key,"")).strip_edges()
	for key in ["temperature", "max_tokens", "timeout"]:
		if connection.has(key): section[key] = connection[key]
	section.generation_overrides = OPTIONS.selected(connection)
	section.cache_hints = cache
	section.openrouter_provider=str(connection.get("openrouter_provider","")).strip_edges()
	section.openrouter_fallbacks=connection.get("openrouter_fallbacks",true)!=false
	section.base_url=endpoint;data.llm=section
	var stt:Dictionary=data.get("stt",{}).duplicate(true)
	# Named LLM presets apply only dialogue, leaving microphone/voice configuration intact.
	if not preserve_input_device: stt.input_device=input_device
	for key in stt_in:stt[key]=str(stt_in[key]).strip_edges().rstrip("/") if stt_in[key] is String and key.ends_with("url") else stt_in[key]
	if not preserve_input_device or not stt_in.is_empty(): data.stt=stt
	if sections.has("chattiness"): data.chattiness=clampf(float(sections.chattiness),0.0,1.0)
	if not usage.is_empty(): data.ai_usage=usage
	if sections.has("adult_policy_hint"): data.adult_policy_hint=bool(sections.adult_policy_hint)
	if not vision_in.is_empty():
		var vision:Dictionary=data.get("vision",{}).duplicate(true)
		for key in ["mode","base_url","api_key","model"]:vision[key]=str(vision_in.get(key,"")).strip_edges()
		vision.base_url=str(vision.base_url).rstrip("/")
		data.vision=vision
	if not tts_in.is_empty():
		var tts:Dictionary=data.get("tts",{}).duplicate(true)
		for key in tts_in:tts[key]=str(tts_in[key]).strip_edges().rstrip("/") if tts_in[key] is String and key.ends_with("url") else tts_in[key]
		data.tts=tts
	var err:=DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	if err!=OK:return "Could not create the settings folder."
	var file:=FileAccess.open(absolute+".tmp",FileAccess.WRITE)
	if file==null:return "Could not write connection settings."
	file.store_string(JSON.stringify(data,"\t"));file.flush();err=file.get_error();file.close()
	if err!=OK:return "Could not finish writing connection settings."
	# API keys live in this file: owner read/write only where the OS supports it.
	if OS.get_name()!="Windows":FileAccess.set_unix_permissions(absolute+".tmp",FileAccess.UNIX_READ_OWNER|FileAccess.UNIX_WRITE_OWNER)
	if DirAccess.rename_absolute(absolute+".tmp",absolute)!=OK:return "Could not replace connection settings."
	return "" if note.is_empty() else "!"+note


static func validate_llm(connection: Dictionary) -> String:
	var options_error := OPTIONS.validate(connection.get("generation_overrides", {}))
	if not options_error.is_empty(): return options_error
	if connection.get("provider") not in ["openai", "anthropic", "gemini"]: return "Choose a provider protocol."
	for key in ["base_url", "model", "api_key"]:
		if not connection.get(key, "") is String: return "Dialogue fields must be text."
	if not connection.get("openrouter_provider", "") is String or not connection.get("openrouter_fallbacks", true) is bool:
		return "Invalid OpenRouter provider settings."
	if not valid_url(str(connection.get("base_url", "")).strip_edges().rstrip("/")):
		return "Enter the provider's HTTP or HTTPS base URL."
	if str(connection.get("model", "")).strip_edges().is_empty(): return "Enter the model name from your provider."
	for key in ["temperature", "max_tokens", "timeout"]:
		if not connection.has(key): continue
		var value: Variant = connection[key]
		if not (value is int or value is float): return "Invalid dialogue generation settings."
		if not is_finite(float(value)): return "Invalid dialogue generation settings."
		if key == "temperature" and (float(value) < 0.0 or float(value) > 2.0): return "Temperature must be between 0 and 2."
		if key == "max_tokens" and (float(value) < 1.0 or float(value) != floor(float(value))): return "Output token limit must be a positive whole number."
		if key == "timeout" and float(value) <= 0.0: return "Timeout must be greater than zero."
	return ""


const USAGE_MODES := ["full", "talk", "off"]
const CACHE_HINTS := ["auto", "on", "off"]

## "full", "talk" or "off" from a loaded config; anything unknown counts as "full".
static func usage_of(config: Variant) -> String:
	var value: String = str(config.get_value("ai_usage", "full")) if config != null and config.has_method("get_value") else "full"
	return value if value in USAGE_MODES else "full"

## Background requests the game starts on its own (overheard chatter, approach greetings, lulls) run
## only in "full".
static func background_allowed(config: Variant) -> bool:
	return usage_of(config) == "full"

## The dialogue model runs unless the player chose "off". Reads the user file when no config is given.
static func ai_enabled(config: Variant = null) -> bool:
	if config == null: config = load_config()
	return usage_of(config) != "off"

static func save_llm(connection: Dictionary, path := USER_PATH) -> String:
	return save_connection(connection, "", path, {}, true)


static func valid_url(endpoint:String)->bool:
	var pattern:=RegEx.new();pattern.compile("^https?://[^/@\\s?#]+(?:/[^\\s?#]*)?$")
	return pattern.search(endpoint)!=null


## True for OpenRouter's API: only it understands the `provider` routing field and lists endpoints.
static func is_openrouter(endpoint: String) -> bool:
	var url := endpoint.strip_edges().to_lower()
	var scheme := url.find("://")
	if scheme < 0: return false
	var host := url.substr(scheme + 3).get_slice("/", 0).get_slice(":", 0)
	return host == "openrouter.ai" or host.ends_with(".openrouter.ai")


## A persona or system prompt file, preferring the player's copy in
## user://mods/prompts/<same file name> when one exists.
static func prompt_text(path:String)->String:
	if path.is_empty():return ""
	var override:=MOD_PROMPTS.path_join(path.get_file())
	if FileAccess.file_exists(override):return FileAccess.get_file_as_string(override)
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


static func _merge(into: Dictionary, from: Dictionary, schema: Dictionary = DEFAULTS, prefix := "", rejected: Array[String] = []) -> void:
	for key in from:
		if schema.has(key):
			var key_path := prefix + str(key)
			var expected: Variant = schema[key]
			var supplied: Variant = from[key]
			if key_path == "llm/generation_overrides":
				if not OPTIONS.validate(supplied).is_empty(): rejected.append(key_path)
				else: into[key] = supplied.duplicate()
				continue
			if expected is Dictionary:
				if not supplied is Dictionary:
					rejected.append(key_path); continue
				if not into.get(key) is Dictionary: into[key] = expected.duplicate(true)
				_merge(into[key], supplied, expected, key_path + "/", rejected)
				continue
			var valid := false
			if key_path == "stt/mic_source": valid = supplied == null or supplied is String
			elif expected is String: valid = supplied is String
			elif expected is bool: valid = supplied is bool
			elif expected is int or expected is float: valid = (supplied is int or supplied is float) and is_finite(float(supplied))
			if not valid:
				rejected.append(key_path); continue
			into[key] = supplied
		else:
			# Preserve unrecognized extension keys; their names/values never enter warnings.
			if into.get(key) is Dictionary and from[key] is Dictionary:
				_merge(into[key], from[key], {}, "", rejected)
			else: into[key] = from[key]


func section(name: String) -> Dictionary:
	var value: Variant = data.get(name, {})
	return value if value is Dictionary else {}


func get_value(path: String, fallback: Variant = null) -> Variant:
	var node: Variant = data
	for part in path.split("/"):
		if node is Dictionary and node.has(part):
			node = node[part]
		else:
			return fallback
	return node

## Android (Quest standalone) runs Whisper inside the game (native/whisper_stt, player board #13).
static func supports_builtin_stt(platform: String) -> bool:
	return platform in ["Windows", "Linux"] or (platform == "Android" and ClassDB.class_exists("WhisperSTT"))

static func builtin_unavailable(platform: String) -> String:
	return "Built-in Whisper is unavailable on %s. Choose a reachable Whisper server or OpenAI-compatible Whisper API in Speech to text, or leave it Off. Audio is sent only to the service you configure." % platform
