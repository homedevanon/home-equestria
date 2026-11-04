extends Node
const CAPTURE := preload("res://world/ai/ai_capture.gd")
const PROMPT_OVERRIDES := preload("res://world/ai/prompt_overrides.gd")
const REPLY_FILTERS := preload("res://world/ai/reply_filters.gd")
const OUTPUT_LIMIT_ERROR := "model output limit reached"
## The provider's safety filter declined this prompt. The bounded retry policy below applies;
## callers use a fallback if every attempt fails, without rewriting the player's prompt.
const REFUSAL_ERROR := "model refused this prompt"
const HISTORY_BYTES := 12288
## No hard request cap any more (dev 2026-10-15: "context has exceeded 64kb ... bricks my save").
## Prompt builders keep requests small; a request above this size is still sent, and logged and
## reported in the Context page so an unbounded builder is visible instead of silent.
const SOFT_INPUT_BYTES := 49152
## Transient failures (5xx, 429, timeouts, dropped connections, empty or malformed replies) are
## retried with exponential backoff and jitter, inside one bounded time window per request.
const MAX_ATTEMPTS := 4
const RETRY_BASE_SECONDS := 1.0
const RETRY_MAX_DELAY := 8.0
const MAX_TOTAL_SECONDS := 120.0
## A server on this machine or the home network (dev 2026-10-26, a tester's intercept): it loads its
## model on the first request (30 s or more) and keeps working on a request the game hangs up on, so
## re-sending after a timeout only queued copies behind it until every try failed. There the wait is
## at least this long (unless the player set their own Timeout), a timeout is not re-sent, and
## warm_up() loads the model at start.
const LOCAL_TIMEOUT := 300.0
## Last requests and failures for the Context page (world/ui/ai_context_page.gd). Numbers and
## failure kinds only: never prompts, replies, headers or keys.
const STATUS_PATH := "user://ai/llm_status.json"
const STATUS_ROWS := 24
const EMPTY_CUE := "(No new words were said. Continue naturally, or reply [silence].)"
## Put in front of a sent transcript that opens with her own line (the Messages API wants a user
## message first). Before 2026-11-03 those opening lines were dropped instead.
const EARLIER_CUE := "(Earlier conversation.)"
## Prompt cache layout (docs/AI_TOKENS_AND_CACHING_2026_10_25.md). Prompt builders mark where the
## stable part of a system prompt ends (HEAD_END, may repeat) and where its live part begins
## (LIVE_START). build_request strips both: stable blocks stay in the system prompt (cache breakpoints
## where the provider needs them), the live part moves into the final user message after the history,
## so the rules, persona and earlier conversation form a byte-stable prefix a provider cache can reuse.
const HEAD_END := "\n<<cache:head>>\n"
const LIVE_START := "\n<<cache:live>>\n"
const LIVE_HEADER := "[Game state right now, for this reply only. Not speech. It replaces every earlier game state.]\n"
const TURN_HEADER := "\n\n[This turn]\n"
## Anthropic allows four cache breakpoints per request.
const MAX_BREAKPOINTS := 4
## The sent transcript starts on a multiple of this many messages, so its first message stays the same
## for several turns instead of moving every turn (a moving start defeats prefix caching).
const HISTORY_STEP := 8
## Generation room beyond a spoken line's stated OUTPUT BUDGET on OpenAI-compatible endpoints. Their
## reasoning models count private reasoning inside max_tokens: a tester's 31-minute capture
## (2026-10-22) had 18 of 47 220-token lines cut off, most with no visible text at all, and every
## cut line paid a second full-prompt request (output recovery). The stated budget is unchanged; only
## tokens actually generated are billed. An explicit player "Output tokens" override is sent as is.
const SPEECH_REASONING_ROOM := 1024
## One chat completion at a time against an OpenAI-compatible endpoint or the Anthropic
## Messages API. `complete(system, messages, on_done)`; `on_done(text: String, error: String)`.

## Token counts the provider reported for each finished request (accounting, never content).
signal usage_reported(usage: Dictionary)
## No request in flight any more (answered, failed or cancelled).
signal idle

@export var provider := "openai"
@export var base_url := "http://127.0.0.1:8787/v1"
@export var api_key := ""
@export var model := "sonnet"
@export var temperature := 0.8
@export var max_tokens := 220
@export var timeout := 90.0
@export var debug := false

var generation_overrides: Dictionary = {}
## OpenRouter provider routing (AI Settings): the endpoint tag tried first ("" lets OpenRouter
## route) and whether other providers may serve the request when it is unavailable.
var openrouter_provider := ""
var openrouter_fallbacks := true
var busy := false
var _request: HTTPRequest
var _on_done: Callable
var last_finish_reason := ""
var last_request_statistics: Dictionary = {}
var last_usage: Dictionary = {}
var _request_serial := 0
var _callback_generation := 0
## Empty: no status file (tests, connection checks). The director sets STATUS_PATH.
var status_path := ""
## Time source for the retry window; tests replace it.
var clock := func() -> float: return Time.get_ticks_msec() / 1000.0
## How the last request ended: ok, output_limit, refusal, transient (retries used up) or fail.
var last_outcome := ""
var _last_request: Dictionary = {}
var _attempt := 0
## Opt-in smaller retry budget for short utility requests; ordinary dialogue keeps four.
var _max_attempts := MAX_ATTEMPTS
var _started_at := 0.0
## What the next request is for (dialogue_player, lull, group, summary, ...). Callers set it right
## before complete*(); every complete*() call consumes it. Captures, status rows and usage carry it.
var purpose := ""
## "auto" (OpenRouter + Claude), "on" or "off": cache_control content parts on OpenAI-compatible
## endpoints. Anthropic Messages always gets its breakpoints.
var cache_hints := "auto"
var last_purpose := ""

## Keep a contiguous recent transcript, whole messages only. The current cue is never cut.
## Saved history and durable story/relationship memory are not modified.
static func recent_messages(messages: Array) -> Array:
	if messages.is_empty(): return []
	var start := messages.size() - 1
	var bytes := JSON.stringify(messages[start]).to_utf8_buffer().size()
	while start > 0:
		var next_bytes := JSON.stringify(messages[start - 1]).to_utf8_buffer().size()
		if bytes + next_bytes > HISTORY_BYTES: break
		start -= 1
		bytes += next_bytes
	if start > 0: start = mini(messages.size() - 1, ceili(start / float(HISTORY_STEP)) * HISTORY_STEP)
	# Her opening lines stay (build_request puts EARLIER_CUE in front). Skipping every leading
	# assistant line here dropped a whole history of her own lines: a tester's Rainbow Dash had 13
	# messages within budget, 12 of them hers (restored witnessed speech, greetings), and only the
	# cue was sent (paste_SWa1FKZL, thread 43671981, "sent_history_messages":1).
	return messages.slice(start).duplicate(true)


func _ready() -> void:
	_request = HTTPRequest.new()
	_request.name = "LlmRequest"
	_request.timeout = timeout
	# Threaded HTTPRequest cancellation joins a blocking socket read (measured
	# 1.35 s on a slow response). Frame-polled HTTP uses nonblocking sockets.
	_request.use_threads = false
	add_child(_request)
	_request.request_completed.connect(_on_completed)


func configure(section: Dictionary) -> void:
	provider = String(section.get("provider", provider))
	base_url = String(section.get("base_url", base_url)).rstrip("/")
	api_key = String(section.get("api_key", api_key))
	model = String(section.get("model", model))
	temperature = float(section.get("temperature", temperature))
	max_tokens = int(section.get("max_tokens", max_tokens))
	timeout = float(section.get("timeout", timeout))
	cache_hints = str(section.get("cache_hints", "auto"))
	openrouter_provider = String(section.get("openrouter_provider", openrouter_provider)).strip_edges()
	openrouter_fallbacks = section.get("openrouter_fallbacks", openrouter_fallbacks) != false
	generation_overrides = preload("res://world/ai/llm_options.gd").selected(section)
	max_tokens = int(generation_overrides.get("max_tokens", max_tokens))
	timeout = float(generation_overrides.get("timeout", timeout))
	local_server = section.get("local_server", null)
	if is_local() and not generation_overrides.has("timeout"): timeout = maxf(timeout, LOCAL_TIMEOUT)
	if _request != null:
		_request.timeout = timeout


## Settings "llm.local_server" true/false overrides the guess (local_url).
var local_server: Variant = null


func is_local() -> bool:
	return bool(local_server) if local_server is bool else local_url(base_url)


## The default ports of local model servers: Ollama, LM Studio, llama.cpp/LocalAI/llama-swap, vLLM,
## text-generation-webui, KoboldCpp, Jan. A local address on another port is usually a proxy to a
## cloud model (the Claude CLI proxy, Gemini proxies), which loads nothing and bills every request.
const LOCAL_PORTS := [11434, 1234, 8080, 8000, 5000, 5001, 1337]

## A model server on this machine or the home network (loopback, 10/8, 172.16/12, 192.168/16,
## .local) on a local model server's port.
static func local_url(url: String) -> bool:
	var authority := url.get_slice("://", 1).get_slice("/", 0).to_lower()
	var host := authority.get_slice("]", 0).trim_prefix("[") if authority.begins_with("[") else authority.get_slice(":", 0)
	var port_text := authority.get_slice("]", 1).trim_prefix(":") if authority.begins_with("[") else authority.get_slice(":", 1)
	if port_text.is_empty() or not port_text.to_int() in LOCAL_PORTS: return false
	if host in ["localhost", "::1", "0.0.0.0"] or host.ends_with(".local"): return true
	if host.begins_with("127.") or host.begins_with("10.") or host.begins_with("192.168."): return true
	var second := host.get_slice(".", 1).to_int() if host.begins_with("172.") else 0
	return second >= 16 and second <= 31


## One tiny request at start so a local server has its model loaded before anypony needs it.
func warm_up() -> void:
	if busy or not is_local(): return
	print("[llm] warming up the local model %s" % model)
	purpose = "warm_up"
	complete_limited("Reply with one word.", [{"role": "user", "content": "Hi"}], func(_reply: String, error: String) -> void:
		print("[llm] local model %s" % ("ready" if error.is_empty() else "warm-up: " + error)), {"max_attempts": 1})


## This request's whole time window: at least the old 120 s, else room for one full Timeout.
func _window() -> float:
	return maxf(MAX_TOTAL_SECONDS, timeout + RETRY_MAX_DELAY + 10.0)


## Request body and headers for the configured provider (also used by the tests).
func build_request(system: String, messages: Array, limits: Dictionary = {}) -> Dictionary:
	# The live part (situation, memories, places, actions) goes after the history (see LIVE_START).
	var live := ""
	var live_at := system.find(LIVE_START)
	if live_at >= 0:
		live = system.substr(live_at + LIVE_START.length())
		system = system.left(live_at)
	var live_mode := live_at >= 0
	var notes := PackedStringArray()
	var recent := recent_messages(messages)
	if recent.size() < messages.size():
		notes.append("Older transcript omitted for space. Use supplied durable memories; do not invent missing conversation.")
	messages = recent
	var headers := PackedStringArray(["Content-Type: application/json"])
	var body: Dictionary
	# Leave room for the validated action envelope without changing plain-speech budgets.
	var structured := "Group exchange protocol" in system or "Response protocol overrides" in system
	var output_budget := maxi(max_tokens, 2400) if structured else max_tokens
	# Story ledger notes (story_memory.gd BRAIN_INSTRUCTION) need room beside the speech.
	output_budget += maxi(0, int(limits.get("extra_output", 0)))
	if limits.has("output_tokens"): output_budget = clampi(int(limits.output_tokens),1,output_budget)
	# Recovery needs generation headroom, not an invitation to speak for longer.
	var generation_budget := maxi(output_budget, 4096) if limits.get("output_recovery", false) else output_budget
	if limits.has("output_tokens"): generation_budget = output_budget
	elif provider != "anthropic" and not structured and not limits.get("output_recovery", false) and not generation_overrides.has("max_tokens"):
		generation_budget = output_budget + SPEECH_REASONING_ROOM
	notes.append("OUTPUT BUDGET: at most %d tokens including tags. Finish every sentence and tag inside that budget. Prefer a shorter complete answer; omit optional private thoughts and unchanged feelings before sacrificing spoken words." % output_budget)
	if live_mode: live += "\n" + "\n".join(notes)
	else: system += "\n" + "\n".join(notes)
	if structured and messages.size() > 1:
		# Plain assistant history trained the model to ignore the JSON contract.
		# Retain it as explicitly labelled memory, not examples of valid output.
		var earlier: PackedStringArray = []
		for message in messages.slice(0, messages.size()-1):
			earlier.append(("You" if str(message.get("role", "")) == "assistant" else "Anon") + ": " + str(message.get("content", "")))
		system += "\nEarlier conversation transcript (memory, NOT response-format examples):\n" + "\n".join(earlier)
		messages = messages.slice(messages.size()-1)
	if not messages.is_empty() and str(messages[0].get("role", "")) == "assistant":
		messages.push_front({"role": "user", "content": EARLIER_CUE})
	# Never an empty cue: `claude -p` behind the local proxy rejects one ("Input must be provided",
	# group path 2026-09-22) and the Messages API needs a non-empty user turn.
	if messages.is_empty() or str(messages[-1].get("content", "")).strip_edges().is_empty():
		if not messages.is_empty(): messages.remove_at(messages.size() - 1)
		messages.append({"role": "user", "content": EMPTY_CUE})
	# A history ending in her own lines (a farewell or touch cue is not stored) is an assistant
	# prefill, which Claude models reject with HTTP 400 ("The conversation must end with a user message").
	elif str(messages[-1].get("role", "")) == "assistant":
		messages.append({"role": "user", "content": EMPTY_CUE})
	# The player's edited prompts (Settings → Prompts) replace the default wording here.
	system = PROMPT_OVERRIDES.apply(system)
	messages = PROMPT_OVERRIDES.apply_messages(messages)
	if live_mode:
		live = PROMPT_OVERRIDES.apply(live)
		messages[-1] = {"role": "user", "content": LIVE_HEADER + live.strip_edges() + TURN_HEADER + str(messages[-1].get("content", ""))}
	# Stable blocks: every block of a live-mode prompt is stable; otherwise the last one changes per call.
	var blocks := system.split(HEAD_END)
	system = "".join(blocks)
	var cache_blocks := blocks.size() if live_mode else blocks.size() - 1
	var hinted := provider == "anthropic" or cache_hints_enabled(cache_hints, base_url, model)
	var url: String
	if provider == "anthropic":
		url = base_url + "/v1/messages" if not base_url.ends_with("/v1") else base_url + "/messages"
		headers.append("x-api-key: " + api_key)
		headers.append("anthropic-version: 2023-06-01")
		var anthropic_system: Variant = system
		if cache_blocks > 0: anthropic_system = cached_parts(blocks, cache_blocks)
		body = {"model": model, "max_tokens": generation_budget,
			"system": anthropic_system, "messages": cached_history(messages, live_mode, mini(cache_blocks, MAX_BREAKPOINTS))}
	elif provider == "gemini":
		# Native generateContent (base URL https://generativelanguage.googleapis.com). Gemini caches a
		# repeated prefix implicitly: the stable system text and history need no markers.
		var endpoint := base_url if base_url.ends_with("/v1beta") or base_url.ends_with("/v1") else base_url + "/v1beta"
		var model_id := model.trim_prefix("models/")
		url = endpoint + "/models/" + model_id.uri_encode() + ":generateContent"
		if api_key != "": headers.append("x-goog-api-key: " + api_key)
		var contents: Array = []
		for message: Variant in messages:
			if message is Dictionary: contents.append(gemini_content(message))
		if not str(limits.get("image_jpeg", "")).is_empty() and not contents.is_empty():
			contents[-1].parts.push_front({"inlineData": {"mimeType": "image/jpeg", "data": str(limits.image_jpeg)}})
		var config := {"maxOutputTokens": generation_budget}
		# As on the OpenAI-compatible route below: thinking models count their thoughts inside the
		# output cap, so conversation asks for little thinking and keeps room for the spoken line.
		var version := model_id.to_lower().get_slice("-", 1).to_float() if model_id.to_lower().begins_with("gemini-") else 0.0
		if version >= 3.0: config.thinkingConfig = {"thinkingLevel": "low"}
		elif version >= 2.5: config.thinkingConfig = {"thinkingBudget": 1024}
		if version >= 2.5 and not limits.has("output_tokens"):
			config.maxOutputTokens = maxi(output_budget, 16384 if limits.get("output_recovery", false) else 8192)
		if limits.has("output_tokens") and int(limits.get("reasoning_room", 0)) > 0:
			config.maxOutputTokens = output_budget + int(limits.reasoning_room)
		for key: String in GEMINI_OPTIONS:
			if generation_overrides.has(key): config[GEMINI_OPTIONS[key]] = generation_overrides[key]
		body = {"systemInstruction": {"parts": [{"text": system}]}, "contents": contents, "generationConfig": config}
	else:
		url = base_url + "/chat/completions"
		if api_key != "":
			headers.append("Authorization: Bearer " + api_key)
		var all: Array = [{"role": "system", "content": cached_parts(blocks, cache_blocks) if hinted and cache_blocks > 0 else system}]
		all.append_array(cached_history(messages, live_mode, mini(cache_blocks, MAX_BREAKPOINTS)) if hinted else messages)
		body = {"model": model, "max_tokens": generation_budget, "messages": all}
		# Automatic prefix caches (OpenAI, DeepSeek, Gemini, GLM, xAI) need nothing in the request,
		# only the stable prefix above. OpenAI routes requests sharing a key to the same cache, and
		# OpenRouter keeps a session on the provider that holds its cache. Neither value identifies
		# the player: one fixed key, and a session id drawn fresh each launch.
		var host := base_url.to_lower()
		if "api.openai.com" in host: body.prompt_cache_key = "home-equestria"
		elif "openrouter.ai" in host: body.session_id = session_id()
		# Gemini counts private reasoning inside max_tokens. A speech-sized cap can
		# expire before the first spoken token. Keep the visible prompt budget, but
		# reserve reasoning space and explicitly request low effort for conversation.
		if "gemini-3" in model.to_lower() or "gemini-2.5" in model.to_lower():
			body.reasoning_effort = "low"
			if not limits.has("output_tokens"):
				body.max_tokens = maxi(output_budget, 16384 if limits.get("output_recovery", false) else 8192)
		# A hard cap (ambient chatter) can opt into bounded thinking room on top of its visible
		# budget: reasoning models behind OpenAI-compatible endpoints count private reasoning inside
		# max_tokens, so a speech-sized cap cut whole conversations off. Callers without it keep theirs.
		if limits.has("output_tokens") and int(limits.get("reasoning_room", 0)) > 0:
			body.max_tokens = output_budget + int(limits.reasoning_room)
		# Other OpenAI-compatible servers may reject the unknown field, so it goes to OpenRouter only.
		if not openrouter_provider.is_empty() and preload("res://world/ai/ai_config.gd").is_openrouter(base_url):
			body.provider = {"order": [openrouter_provider], "allow_fallbacks": openrouter_fallbacks}
	# Gemini's sampling options were mapped into generationConfig above.
	if provider != "gemini":
		for key: String in generation_overrides:
			if key not in ["max_tokens", "timeout"]: body[key] = generation_overrides[key]
	# A photo the player shows (world/ai/photo_vision.gd, opt-in): the picture rides on the last
	# user message only, in each protocol's own image format.
	if not str(limits.get("image_jpeg", "")).is_empty() and provider != "gemini":
		attach_image(body.messages, str(limits.image_jpeg), provider == "anthropic")
	return {"url": url, "headers": headers, "body": JSON.stringify(body)}

## Player sampling overrides (llm_options.gd) under their generationConfig names; Gemini has no min_p.
const GEMINI_OPTIONS := {"temperature": "temperature", "top_p": "topP", "top_k": "topK", "seed": "seed",
	"frequency_penalty": "frequencyPenalty", "presence_penalty": "presencePenalty"}

## One message as Gemini content: role "model" for her lines, its text parts in order. The API
## rejects an empty text part.
static func gemini_content(message: Dictionary) -> Dictionary:
	var parts: Array = []
	var content: Variant = message.get("content", "")
	for part: Variant in (content if content is Array else [{"text": str(content)}]):
		if part is Dictionary and part.get("text") is String and not str(part.text).strip_edges().is_empty():
			parts.append({"text": str(part.text)})
	if parts.is_empty(): parts.append({"text": "..."})
	return {"role": "model" if str(message.get("role", "")) == "assistant" else "user", "parts": parts}

static func attach_image(messages: Array, jpeg_base64: String, anthropic: bool) -> void:
	if messages.is_empty(): return
	var last: Dictionary = (messages[-1] as Dictionary).duplicate()
	var parts: Array = []
	var content: Variant = last.get("content", "")
	if content is Array: parts = (content as Array).duplicate()
	else: parts = [{"type": "text", "text": str(content)}]
	if anthropic: parts.push_front({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": jpeg_base64}})
	else: parts.append({"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + jpeg_base64}})
	last.content = parts
	messages[-1] = last


## Text parts for the stable system blocks; the first `cached` blocks end with a cache breakpoint
## (at most MAX_BREAKPOINTS - 1, keeping one for the history; the latest ones win).
static func cached_parts(blocks: PackedStringArray, cached: int) -> Array:
	var parts: Array = []
	var first_marked := maxi(0, cached - (MAX_BREAKPOINTS - 1))
	for i in blocks.size():
		if blocks[i].is_empty(): continue
		var part := {"type": "text", "text": blocks[i]}
		if i < cached and i >= first_marked: part["cache_control"] = {"type": "ephemeral"}
		parts.append(part)
	return parts

## Live-mode history: a breakpoint on the last message before this turn, so the whole earlier
## conversation is reused next turn. `used` system breakpoints leave room within the provider's four.
static func cached_history(messages: Array, live_mode: bool, used: int) -> Array:
	if not live_mode or messages.size() < 2 or used >= MAX_BREAKPOINTS: return messages
	var out := messages.duplicate(true)
	var text := str(out[-2].get("content", ""))
	if text.strip_edges().is_empty(): return out
	out[-2] = {"role": str(out[-2].get("role", "user")), "content": [{"type": "text", "text": text, "cache_control": {"type": "ephemeral"}}]}
	return out

static var _session_id := ""

## A random id for this launch, shared by every request (OpenRouter sticky cache routing).
static func session_id() -> String:
	if _session_id.is_empty(): _session_id = "he-%016x" % (randi() * 4294967296 + randi())
	return _session_id

## Whether OpenAI-compatible requests carry cache_control parts: always "on", never "off"; "auto"
## only for Claude models through OpenRouter (the routes that need explicit breakpoints and accept
## content parts; OpenAI-family providers cache prefixes automatically).
static func cache_hints_enabled(setting: String, url: String, model_name: String) -> bool:
	if setting == "on": return true
	if setting != "auto": return false
	var lowered := model_name.to_lower()
	return "openrouter.ai" in url.to_lower() and ("claude" in lowered or lowered.begins_with("anthropic/"))


func complete(system: String, messages: Array, on_done: Callable) -> bool:
	return _complete(system, messages, on_done, {})


## Only the director's single repair attempt may expand a clipped response budget.
## Does not change configured limits for later turns or background chatter.
func complete_with_output_recovery(system: String, messages: Array, on_done: Callable) -> bool:
	return _complete(system, messages, on_done, {"output_recovery":true})


func complete_limited(system: String, messages: Array, on_done: Callable, limits: Dictionary) -> bool:
	return _complete(system, messages, on_done, limits)


func _complete(system: String, messages: Array, on_done: Callable, limits: Dictionary) -> bool:
	var label := str(limits.get("purpose", purpose))
	purpose = ""
	if busy:
		return false
	if label.is_empty(): label = {"SummaryLlm": "summary", "ConnectionTest": "connection_test"}.get(String(name), "dialogue")
	last_purpose = label + ("_recovery" if limits.get("output_recovery", false) else "")
	_request_serial += 1
	if base_url.is_empty() or model.is_empty():
		_reset_accounting()
		_defer_failure(on_done, "Set your dialogue provider and model in Settings → AI Settings.")
		return true
	var req := build_request(system, messages, limits)
	var request_bytes := str(req.body).to_utf8_buffer().size()
	if limits.has("input_bytes") and request_bytes > int(limits.input_bytes): return false
	_reset_accounting()
	last_request_statistics = {"id":_request_serial,"input_bytes":request_bytes,"system_chars":system.length(),
		"history_messages":messages.size(),"sent_history_messages":recent_messages(messages).size()}
	if request_bytes > SOFT_INPUT_BYTES:
		last_request_statistics.oversize = true
		push_warning("[ai] llm: large request, %d bytes (soft budget %d); sent anyway" % [request_bytes, SOFT_INPUT_BYTES])
	print("[llm-request] ", JSON.stringify(last_request_statistics))
	busy = true
	_on_done = on_done
	_last_request = req
	_attempt = 1
	_max_attempts = clampi(int(limits.get("max_attempts", MAX_ATTEMPTS)), 1, MAX_ATTEMPTS)
	_started_at = float(clock.call())
	if debug:
		print("[llm] %s %s (%d messages)" % [provider, req.url, messages.size()])
	_send()
	return true


func _reset_accounting() -> void:
	last_request_statistics = {}
	last_usage = {}
	last_finish_reason = ""
	last_outcome = ""
	_last_request = {}
	_attempt = 0
	_started_at = float(clock.call())


## One attempt. Its HTTP timeout never runs past the request's whole retry window.
func _send() -> void:
	_capture("request", {"body": str(_last_request.get("body", ""))})
	if _request != null:
		var left := _window() - (float(clock.call()) - _started_at)
		_request.timeout = clampf(left, 5.0, maxf(timeout, 5.0))
	var err := _dispatch_request(_last_request)
	if err != OK:
		_defer_failure(_on_done, "request error %d" % err)


## An accepted local failure owns the same cancellation boundary as a network request.
## Never re-enter the caller before complete() has returned its acceptance result.
func _defer_failure(on_done: Callable, error: String) -> void:
	busy = true
	_on_done = on_done
	_callback_generation += 1
	_deliver_failure.call_deferred(_callback_generation, error)


func _deliver_failure(generation: int, error: String) -> void:
	if generation != _callback_generation or not busy: return
	_finish("", error, "fail")


func _dispatch_request(req: Dictionary) -> Error:
	if _request == null: return ERR_UNCONFIGURED
	return _request.request(req.url, req.headers, HTTPClient.METHOD_POST, req.body)


func cancel() -> void:
	var was_busy := busy
	if busy: _capture("cancel", {"seconds": snappedf(float(clock.call()) - _started_at, 0.1)})
	_callback_generation += 1
	if _request != null: _request.cancel_request()
	busy = false
	_on_done = Callable()
	if was_busy: idle.emit()


func _on_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if not busy or not _on_done.is_valid(): return
	var text := body.get_string_from_utf8()
	_capture("response", {"result": result, "http_status": code, "body": text})
	var verdict := classify(result, code, headers, text)
	if verdict.kind == "retry":
		if result == HTTPRequest.RESULT_TIMEOUT and is_local():
			_finish("", "the local server did not answer within %d s (still loading or working); raise Timeout in AI Settings" % int(timeout), "transient")
			return
		if not _schedule_retry(verdict): _finish("", str(verdict.error), "transient")
		return
	if verdict.kind == "refusal":
		# A declined HTTP 200 response can still be billed. Count only the numeric
		# usage actually supplied by the provider, including on intermediate retries.
		last_usage = usage_counts(verdict.get("parsed"))
		last_finish_reason = finish_reason(verdict.get("parsed"))
		if not last_usage.is_empty(): usage_reported.emit(_labelled(last_usage))
		# Retried unchanged like any transient failure: prompts are never softened for one
		# provider's filter (dev 2026-10-15); the caller speaks a fallback line if every try fails.
		if not _schedule_retry(verdict): _finish("", REFUSAL_ERROR, "refusal")
		return
	if verdict.kind != "ok":
		_finish("", str(verdict.error), "fail")
		return
	var parsed: Variant = verdict.parsed
	last_usage = usage_counts(parsed)
	print("[llm-usage] request=", _request_serial, " ", JSON.stringify(last_usage))
	last_finish_reason = finish_reason(parsed)
	var reply := extract_text(parsed)
	_report_usage(reply)
	# An in-band refusal: provider boilerplate as ordinary text with a normal stop (Gemini, thread
	# 43671981: "I cannot fulfill this request."). Retried unchanged like any refusal; boilerplate
	# beside real lines is dropped later by the director (reply_filters.gd).
	if REPLY_FILTERS.refusal_only(reply):
		var declined := {"kind": "refusal", "error": REFUSAL_ERROR + " (in reply text)"}
		if not _schedule_retry(declined): _finish("", REFUSAL_ERROR, "refusal")
		return
	if last_finish_reason in ["length", "max_tokens", "max_output_tokens", "model_context_window_exceeded"]:
		_finish(reply, OUTPUT_LIMIT_ERROR, "output_limit")
		return
	if reply == "":
		var empty := {"kind":"retry", "error":"no text in reply: " + text.left(200)}
		if not _schedule_retry(empty): _finish("", str(empty.error), "transient")
		return
	_finish(reply, "", "ok")


func _finish(reply: String, error: String, outcome: String) -> void:
	_capture("complete", {"reply": reply, "error": error, "outcome": outcome})
	var done := _on_done
	_on_done = Callable()
	busy = false
	last_outcome = outcome
	_record_status(outcome, error)
	if done.is_valid(): done.call(reply, error)
	if not busy: idle.emit()


## Another attempt after exponential backoff with jitter (or the server's Retry-After), only
## while the request's time window still leaves the attempt room to answer.
func _schedule_retry(verdict: Dictionary) -> bool:
	if _attempt >= _max_attempts or _last_request.is_empty() or not is_inside_tree(): return false
	var delay := retry_delay(_attempt, float(verdict.get("retry_after", -1.0)), randf())
	if float(clock.call()) - _started_at + delay + 10.0 > _window(): return false
	_attempt += 1
	push_warning("[ai] llm: %s; retry %d of %d in %.1f s" % [str(verdict.error).left(120), _attempt - 1, _max_attempts - 1, delay])
	var generation := _callback_generation
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		if generation != _callback_generation or not busy: return
		_send())
	return true


## HTTPRequest results worth another attempt: timeouts and dropped or refused connections.
const RETRY_RESULTS := [HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH, HTTPRequest.RESULT_CANT_CONNECT,
	HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_NO_RESPONSE, HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED,
	HTTPRequest.RESULT_REQUEST_FAILED, HTTPRequest.RESULT_TIMEOUT]

## {kind: ok|retry|refusal|fail, error, parsed (ok), retry_after (429)}. A refusal is reported
## by a provider as stop/finish reason "refusal"/"content_filter", by the local claude CLI proxy
## as HTTP 422 (older proxy builds: a 502 whose detail says stop_reason "refusal").
static func classify(result: int, code: int, headers: PackedStringArray, text: String) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"kind": "retry" if result in RETRY_RESULTS else "fail", "error": "http result %d" % result}
	if (code < 200 or code >= 300) and "refusal" in text.to_lower():
		return {"kind": "refusal", "error": REFUSAL_ERROR}
	if code == 429:
		return {"kind": "retry", "error": "http 429: rate limited", "retry_after": retry_after(headers)}
	if code == 408 or code >= 500:
		return {"kind": "retry", "error": "http %d: %s" % [code, text.left(200)]}
	if code < 200 or code >= 300:
		return {"kind": "fail", "error": "http %d: %s" % [code, text.left(200)]}
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return {"kind": "retry", "error": "malformed reply: " + text.left(120)}
	# Gemini: a blocked candidate's finishReason, or "blocked" when the prompt itself was refused.
	if finish_reason(parser.data) in ["refusal", "content_filter", "safety", "prohibited_content", "blocklist", "spii", "image_safety", "blocked"]:
		return {"kind": "refusal", "error": REFUSAL_ERROR, "parsed": parser.data}
	return {"kind": "ok", "parsed": parser.data}


## Seconds from a Retry-After header, or -1 when absent or an HTTP date.
static func retry_after(headers: PackedStringArray) -> float:
	for header: String in headers:
		if header.to_lower().begins_with("retry-after:"):
			var value := header.substr(12).strip_edges()
			if value.is_valid_float(): return maxf(0.0, float(value))
	return -1.0


## Backoff before retry `attempt` (1 = first retry): 1, 2, 4, 8 s, each ±25 % jitter
## (`jitter` 0..1); a server's Retry-After is honoured as given.
static func retry_delay(attempt: int, server_after: float, jitter: float) -> float:
	if server_after >= 0.0: return server_after
	var base := minf(RETRY_MAX_DELAY, RETRY_BASE_SECONDS * pow(2.0, maxi(0, attempt - 1)))
	return base * (0.75 + 0.5 * clampf(jitter, 0.0, 1.0))


func _record_status(outcome: String, error: String) -> void:
	if status_path.is_empty(): return
	var doc := read_status(status_path)
	var rows: Array = doc.get("requests", []) if doc.get("requests") is Array else []
	var input_bytes := int(last_request_statistics.get("input_bytes", 0))
	rows.append({"at": Time.get_datetime_string_from_system(), "client": String(name), "purpose": last_purpose, "outcome": outcome,
		"attempts": _attempt, "input_bytes": input_bytes, "tokens_estimate": int(ceil(input_bytes / 3.6)),
		"seconds": snappedf(float(clock.call()) - _started_at, 0.1), "error": _status_error(error, outcome)})
	while rows.size() > STATUS_ROWS: rows.pop_front()
	var totals: Dictionary = doc.get("totals", {}) if doc.get("totals") is Dictionary else {}
	totals[outcome] = int(totals.get(outcome, 0)) + 1
	if _attempt > 1: totals["retried"] = int(totals.get("retried", 0)) + 1
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(status_path.get_base_dir()))
	var file := FileAccess.open(status_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"version": 1, "requests": rows, "totals": totals}, "\t"))
		file.close()


## Provider bodies can echo credentials or conversation text. Keep only known error kinds
## and numeric transport codes in the persistent Context page, never raw provider detail.
static func _status_error(error: String, outcome: String) -> String:
	if error.is_empty(): return ""
	for prefix: String in ["http result ", "http ", "request error "]:
		if error.begins_with(prefix):
			var number := error.trim_prefix(prefix).get_slice(":", 0).strip_edges()
			if number.is_valid_int(): return prefix + str(int(number))
	for kind: String in ["malformed reply", "no text in reply"]:
		if error.begins_with(kind + ":"): return kind
	if error in [REFUSAL_ERROR, OUTPUT_LIMIT_ERROR]: return error
	return outcome


static func read_status(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

## Emits the provider's counts, or an estimate when it reports none (a local proxy reports 0):
## request bytes / 3.6 and reply characters / 3.6, marked "estimated".
func _report_usage(reply: String) -> void:
	var counted := last_usage.duplicate()
	if int(counted.get("prompt_tokens", counted.get("input_tokens", 0))) <= 0:
		counted = {"prompt_tokens": int(ceil(float(last_request_statistics.get("input_bytes", 0)) / 3.6)),
			"completion_tokens": int(ceil(reply.length() / 3.6)), "estimated": true}
	usage_reported.emit(_labelled(counted))

## Usage rows carry the request's purpose label (a string beside the numeric counts).
func _labelled(usage: Dictionary) -> Dictionary:
	var row := usage.duplicate()
	if not last_purpose.is_empty(): row["purpose"] = last_purpose
	return row

## Numeric accounting only: never log prompts, account details, headers or credentials.
static func usage_counts(parsed: Variant) -> Dictionary:
	if parsed is Dictionary and parsed.get("usageMetadata") is Dictionary: return gemini_usage(parsed.usageMetadata)
	if not parsed is Dictionary or not parsed.get("usage") is Dictionary: return {}
	var usage: Dictionary = parsed.usage
	var result := {}
	for key: String in ["prompt_tokens", "completion_tokens", "total_tokens", "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]:
		if usage.get(key) is int or usage.get(key) is float: result[key] = maxi(0, int(usage[key]))
	# Cache reads: OpenAI, OpenRouter, GLM and Gemini's compatibility layer use prompt_tokens_details,
	# the Responses shape input_tokens_details, DeepSeek its own prompt_cache_hit_tokens.
	for details: String in ["prompt_tokens_details", "input_tokens_details"]:
		var detail: Variant = usage.get(details, {})
		if detail is Dictionary and (detail.get("cached_tokens") is int or detail.get("cached_tokens") is float):
			result["cached_tokens"] = maxi(0, int(detail.cached_tokens))
	if not result.has("cached_tokens") and (usage.get("prompt_cache_hit_tokens") is int or usage.get("prompt_cache_hit_tokens") is float):
		result["cached_tokens"] = maxi(0, int(usage.prompt_cache_hit_tokens))
	var completion: Variant = usage.get("completion_tokens_details", {})
	if completion is Dictionary and (completion.get("reasoning_tokens") is int or completion.get("reasoning_tokens") is float):
		result["reasoning_tokens"] = maxi(0, int(completion.reasoning_tokens))
	return result

## Gemini usageMetadata in the OpenAI names. Its candidate count leaves out thoughts, which the
## OpenAI shape counts inside completion_tokens, so they are added back.
static func gemini_usage(usage: Dictionary) -> Dictionary:
	var result := {}
	for pair: Array in [["promptTokenCount", "prompt_tokens"], ["totalTokenCount", "total_tokens"], ["thoughtsTokenCount", "reasoning_tokens"], ["cachedContentTokenCount", "cached_tokens"], ["candidatesTokenCount", "completion_tokens"]]:
		if usage.get(pair[0]) is int or usage.get(pair[0]) is float: result[pair[1]] = maxi(0, int(usage[pair[0]]))
	if result.has("reasoning_tokens"): result.completion_tokens = int(result.get("completion_tokens", 0)) + int(result.reasoning_tokens)
	return result

## Providers expose truncation separately from their text; never count a cut draft as complete.
static func finish_reason(parsed: Variant) -> String:
	if not parsed is Dictionary: return ""
	if parsed.get("choices") is Array and not parsed.choices.is_empty() and parsed.choices[0] is Dictionary:
		return str(parsed.choices[0].get("finish_reason", "")).to_lower()
	if parsed.get("candidates") is Array and not parsed.candidates.is_empty() and parsed.candidates[0] is Dictionary:
		return str(parsed.candidates[0].get("finishReason", "")).to_lower()
	if parsed.get("promptFeedback") is Dictionary and not str(parsed.promptFeedback.get("blockReason", "")).is_empty(): return "blocked"
	return str(parsed.get("stop_reason", "")).to_lower()


## The assistant text out of any provider's JSON.
static func extract_text(parsed: Variant) -> String:
	if not (parsed is Dictionary):
		return ""
	var d: Dictionary = parsed
	if d.has("choices"):
		if not d.choices is Array or d.choices.is_empty() or not d.choices[0] is Dictionary: return ""
		var message: Variant = d.choices[0].get("message", {})
		if message is Dictionary and message.has("content"):
			var content: Variant = message.content
			if content is String: return content.strip_edges()
			if content is Array:
				var parts: PackedStringArray = []
				for block: Variant in content:
					if block is Dictionary and block.get("type", "text") in ["text", "output_text"] and block.get("text") is String:
						parts.append(str(block.text))
				return "".join(parts).strip_edges()
	if d.has("content") and d.content is Array:
		var parts: PackedStringArray = []
		for block in d.content:
			if block is Dictionary and block.get("type", "") == "text" and block.get("text") is String:
				parts.append(str(block.text))
		return " ".join(parts).strip_edges()
	if d.get("candidates") is Array and not d.candidates.is_empty() and d.candidates[0] is Dictionary:
		var candidate: Variant = d.candidates[0].get("content", {})
		if not candidate is Dictionary or not candidate.get("parts") is Array: return ""
		var parts: PackedStringArray = []
		for part: Variant in candidate.parts:
			# Thought summaries are private reasoning, not her reply.
			if part is Dictionary and part.get("text") is String and part.get("thought", false) != true: parts.append(str(part.text))
		return "".join(parts).strip_edges()
	return ""


func _capture(event: String, details: Dictionary) -> void:
	if CAPTURE.folder().is_empty(): return
	details["client"] = get_instance_id()
	details["request"] = _request_serial
	details["attempt"] = _attempt
	details["provider"] = provider
	details["purpose"] = last_purpose
	CAPTURE.record("llm", event, details, api_key)
