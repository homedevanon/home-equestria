extends Node
## Receives a spoken line from a voice server while the server is still rendering it, and hands on
## each piece of sound as it arrives (signal pcm_chunk), so a pony can start talking after about
## 200 ms of audio instead of after the whole clip. From the breeze-tts-pny mod by nak (MIT),
## 2026-11-10; the wire format is that mod's "framed-v1" (its docs/PROTOCOL.md):
##   HTTP 200, Content-Type application/vnd.home-equestria.pcm-stream,
##   X-Sample-Format s16le, X-Sample-Rate 24000, X-Channels 1, then frames independent of HTTP
##   chunk boundaries: u32 little-endian byte count + that many bytes of mono PCM16, repeated;
##   the end is a zero count, the u32 total byte count and the 32-byte SHA-256 of all samples.
## A server that answers the same request with a complete audio/wav body is accepted too.
## When the line is complete, response_completed carries it as a WAV file image, so callers that
## want a file (prefetch, a speaker without stream playback) get the same thing a WAV server gives.
signal pcm_chunk(data: PackedByteArray)
signal response_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray)

const TYPE := "application/vnd.home-equestria.pcm-stream"
const RATE := 24000
const MAX_PCM := RATE * 2 * 60
const MAX_WAV := 12 * 1024 * 1024
const MAX_FRAME := 65536

var active := false
var first_pcm_ms := -1
var buffer_ready_ms := -1
var received := 0
var debug := false
var _http: HTTPClient
var _request: Dictionary
var _sent := false
var _responded := false
var _framed := false
var _headers := PackedStringArray()
var _code := 0
var _start := 0
var _deadline := 0
var _expected := -1
var _wire := PackedByteArray()
var _pcm := PackedByteArray()
var _wav := PackedByteArray()
var _hash: HashingContext
var _receipt := false
var _bad := false


func _init() -> void:
	set_process(false)


func start(url: String, body: String, timeout: float) -> Error:
	cancel()
	# HTTPS reaches a remote server (a Colab tunnel); certificates are verified.
	var tls := url.begins_with("https://")
	if not tls and not url.begins_with("http://"): return ERR_INVALID_PARAMETER
	var scheme := "https://" if tls else "http://"
	var authority := url.trim_prefix(scheme).get_slice("/", 0)
	var host := authority.get_slice(":", 0)
	var port := authority.get_slice(":", 1).to_int() if ":" in authority else (443 if tls else 80)
	var path := url.substr(scheme.length() + authority.length())
	if path.is_empty(): path = "/"
	_request = {"path": path, "body": body}
	reset_decoder()
	_sent = false; _responded = false; _framed = false; _code = 0; _headers.clear(); _wav.clear(); _expected = -1
	_start = Time.get_ticks_msec(); _deadline = _start + int(timeout * 1000.0)
	_http = HTTPClient.new(); _http.blocking_mode_enabled = false
	var error := _http.connect_to_host(host, port, TLSOptions.client() if tls else null)
	if error != OK: return error
	active = true; set_process(true)
	return OK


func cancel() -> void:
	if active and debug:
		print("[pcm-stream] ", JSON.stringify({"event": "cancel", "bytes": received, "elapsed_ms": Time.get_ticks_msec() - _start}))
	active = false; set_process(false)
	if _http != null: _http.close()
	_http = null


func reset_decoder() -> void:
	_wire.clear(); _pcm.clear(); _receipt = false; _bad = false
	received = 0; first_pcm_ms = -1; buffer_ready_ms = -1
	_hash = HashingContext.new(); _hash.start(HashingContext.HASH_SHA256)


func _process(_delta: float) -> void:
	if not active: return
	if Time.get_ticks_msec() >= _deadline: _deliver(HTTPRequest.RESULT_TIMEOUT); return
	if _http.poll() != OK:
		# A validated receipt is authoritative even when HTTPClient reports EOF.
		_deliver(HTTPRequest.RESULT_SUCCESS if _has_complete_response() else HTTPRequest.RESULT_CONNECTION_ERROR)
		return
	var status := _http.get_status()
	if not _sent and status == HTTPClient.STATUS_CONNECTED:
		var error := _http.request(HTTPClient.METHOD_POST, str(_request.path), PackedStringArray(["Content-Type: application/json"]), str(_request.body))
		if error != OK: _deliver(HTTPRequest.RESULT_REQUEST_FAILED); return
		_sent = true; return
	if _http.has_response() and not _responded:
		_responded = true; _code = _http.get_response_code(); _headers = _http.get_response_headers()
		_expected = _http.get_response_body_length()
		var values := {}
		for header: String in _headers:
			var at := header.find(":")
			if at >= 0: values[header.left(at).to_lower()] = header.substr(at + 1).strip_edges()
		var content_type := str(values.get("content-type", "")).get_slice(";", 0)
		_framed = content_type == TYPE and _code == 200
		if _code == 200 and not _framed and content_type != "audio/wav":
			_deliver(HTTPRequest.RESULT_REQUEST_FAILED); return
		if _framed and (values.get("x-sample-format") != "s16le" or values.get("x-sample-rate") != str(RATE) or values.get("x-channels") != "1"):
			_deliver(HTTPRequest.RESULT_REQUEST_FAILED); return
	if status == HTTPClient.STATUS_BODY:
		for _i in 4:
			if _http.get_status() != HTTPClient.STATUS_BODY: break
			var chunk := _http.read_response_body_chunk()
			if chunk.is_empty(): break
			if _framed:
				feed(chunk)
				if not active: return
				if _bad: _deliver(HTTPRequest.RESULT_REQUEST_FAILED); return
			else:
				_wav.append_array(chunk)
				if _wav.size() > MAX_WAV: _deliver(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED); return
	if _responded and status in [HTTPClient.STATUS_CONNECTED, HTTPClient.STATUS_DISCONNECTED]:
		var valid := complete() if _framed else (_expected < 0 or _expected == _wav.size())
		_deliver(HTTPRequest.RESULT_SUCCESS if valid else HTTPRequest.RESULT_REQUEST_FAILED)
	elif status in [HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
		_deliver(HTTPRequest.RESULT_SUCCESS if _has_complete_response() else HTTPRequest.RESULT_CONNECTION_ERROR)


## The frame decoder alone, independent of sockets: counts split across pieces and odd byte
## splits are fine (tools/voice/test_pcm_stream.gd feeds it directly).
func feed(chunk: PackedByteArray) -> void:
	if _bad: return
	if _receipt and not chunk.is_empty(): _bad = true; return
	_wire.append_array(chunk)
	while _wire.size() >= 4:
		var size := _wire.decode_u32(0)
		if size == 0:
			if _wire.size() < 40: return
			if _wire.decode_u32(4) != received or received == 0 or _wire.slice(8, 40) != _hash.finish():
				_bad = true; return
			_wire = _wire.slice(40); _receipt = true
			if not _wire.is_empty(): _bad = true
			return
		if size > MAX_FRAME or size % 2 != 0 or received + size > MAX_PCM:
			_bad = true; return
		if _wire.size() < size + 4: return
		var data := _wire.slice(4, size + 4); _wire = _wire.slice(size + 4)
		received += size; _pcm.append_array(data); _hash.update(data)
		if first_pcm_ms < 0:
			first_pcm_ms = Time.get_ticks_msec() - _start
			if debug: print("[pcm-stream] ", JSON.stringify({"event": "first_pcm", "elapsed_ms": first_pcm_ms, "bytes": received}))
		if buffer_ready_ms < 0 and received >= 9600: buffer_ready_ms = Time.get_ticks_msec() - _start
		pcm_chunk.emit(data)


func complete() -> bool:
	return _receipt and not _bad and _wire.is_empty()


func bad() -> bool:
	return _bad


## Everything received, as a mono 16-bit WAV file image.
func wav_bytes() -> PackedByteArray:
	var header := PackedByteArray(); header.resize(44)
	for pair: Array in [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [36, "data"]]:
		var chars: PackedByteArray = str(pair[1]).to_ascii_buffer()
		for i in chars.size(): header[int(pair[0]) + i] = chars[i]
	header.encode_u32(4, 36 + received); header.encode_u32(16, 16)
	header.encode_u16(20, 1); header.encode_u16(22, 1); header.encode_u32(24, RATE)
	header.encode_u32(28, RATE * 2); header.encode_u16(32, 2); header.encode_u16(34, 16)
	header.encode_u32(40, received); header.append_array(_pcm)
	return header


func _deliver(result: int) -> void:
	var body := wav_bytes() if _framed and complete() else _wav
	var code := _code; var headers := _headers
	# Always logged, one line per spoken line: the first-sound time is the number this exists for.
	print("[pcm-stream] ", JSON.stringify({"event": "complete", "result": result, "code": code, "transport": "pcm" if _framed else "wav-fallback", "bytes": received, "first_pcm_ms": first_pcm_ms, "buffer_200ms_ms": buffer_ready_ms, "elapsed_ms": Time.get_ticks_msec() - _start}))
	active = false # Normal completion must not be logged as a cancellation.
	cancel()
	response_completed.emit(result, code, headers, body)


func _has_complete_response() -> bool:
	if not _responded: return false
	return complete() if _framed else (_expected >= 0 and _wav.size() == _expected)


func _exit_tree() -> void:
	cancel()
