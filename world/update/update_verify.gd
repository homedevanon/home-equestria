extends RefCounted
## Signed update checks (dev 2026-10-28: "a malicious attacker taking over my repo can't deploy
## malware to everyone through it"). A hash list in the same repo would fall with the repo, so
## every release carries update_manifest.json plus update_manifest.json.sig: base64 of an RSA
## PKCS#1 v1.5 SHA-256 signature over the manifest's exact bytes, made with dev's offline private
## key (openssl dgst -sha256 -sign). The game holds only the public key. The manifest is parsed
## after its signature checks out, and every downloaded archive must match its signed size and
## sha256 before anything is unpacked. Nothing here touches the network; world/update/updater.gd
## downloads and installs. tools/update/test_update_verify.gd checks it with a throwaway key.
##
##   {"format":1,"version":"0.0.4","channel":"stable",
##    "files":[{"name":"<release asset>","platform":"linux"|"windows"|"android","sha256":"<hex>","size":<int>}]}
##
## Several files for one platform are parts of one archive, joined in manifest order (a GitHub
## release file must stay under 2 GiB). The archive kind comes from its first bytes: a zip
## (Windows) or a gzip'd tar (Linux), both made by tools/build/release.py with one top folder
## (HomeEquestria-<version>-<platform>/). Both are unpacked as streams: the 4 GB game pack never
## sits in memory, which rules out ZIPReader.read_file.

const KEY_PATH := "res://world/update/release_public_key.pem"
const ROOTS_PATH := "res://world/update/tls_roots.pem"
const PLATFORMS := ["linux", "windows", "android"]
const CHUNK := 1 << 20
## Release names are plain; anything else (quotes, %, &, drive letters) is refused, which also
## keeps the generated install scripts free of quoting traps.
const SAFE_NAME := "^[A-Za-z0-9 ._+\\-/]+$"
const ASSET_NAME := "^[A-Za-z0-9._+\\-]+$"
## An optional fourth number marks a small fix on top of a release (0.0.6.1; dev 2026-10-28). Builds
## before 0.0.6 read only three numbers, so a fourth-number release reaches only 0.0.6 and later.
const VERSION_FORM := "^(\\d+)\\.(\\d+)\\.(\\d+)(?:\\.(\\d+))?(-[A-Za-z0-9.]+)?$"
## A signed release cannot unpack more than this (the 0.0.3 game is 4.6 GB unpacked).
const MAX_UNPACKED := 32 * 1024 * 1024 * 1024


## The public key, or null when this build carries none (the updater then stays off).
static func load_public_key(path: String = KEY_PATH) -> CryptoKey:
	if not FileAccess.file_exists(path): return null
	var key := CryptoKey.new()
	if key.load_from_string(FileAccess.get_file_as_string(path), true) != OK: return null
	return key


## TLS options that trust only the root certificates shipped in ROOTS_PATH, or null without them.
## On Windows Godot trusts only the system's root store, and Windows fills that store on demand
## (Edge/CryptoAPI fetch a missing root; Godot's TLS library never asks). An LTSC or offline PC that
## never met GitHub's roots then refuses github.com with a TLS handshake error on every network
## (player report, Win10 LTSC, 2026-10-31). The updater and the setup retry with these roots after
## exactly that error: the host name is still checked, and every download still has to match the
## signed manifest. The file holds Mozilla's roots for GitHub's CAs (Sectigo/USERTrust/COMODO for
## github.com and its API, Let's Encrypt ISRG for the file hosts, and DigiCert, which GitHub used before).
static func fallback_tls(path: String = ROOTS_PATH) -> TLSOptions:
	if not FileAccess.file_exists(path): return null
	var roots := X509Certificate.new()
	if roots.load_from_string(FileAccess.get_file_as_string(path)) != OK: return null
	return TLSOptions.client(roots)


## True when sig_text (base64, line breaks allowed) is a valid signature over these exact bytes.
static func signature_ok(manifest_bytes: PackedByteArray, sig_text: String, key: CryptoKey) -> bool:
	if key == null or manifest_bytes.is_empty(): return false
	var compact := sig_text.strip_edges().replace("\n", "").replace("\r", "").replace(" ", "")
	if compact.is_empty(): return false
	var signature := Marshalls.base64_to_raw(compact)
	if signature.size() < 128: return false
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256); hashing.update(manifest_bytes)
	return Crypto.new().verify(HashingContext.HASH_SHA256, hashing.finish(), signature, key)


## The checked manifest, or {"error": why}. Order: signature, then parse, then the version must be
## newer than the running one (an old signed manifest cannot roll a player back).
static func verified_manifest(manifest_bytes: PackedByteArray, sig_text: String, key: CryptoKey, current_version: String) -> Dictionary:
	if not signature_ok(manifest_bytes, sig_text, key): return {"error": "bad signature"}
	var parsed: Variant = JSON.parse_string(manifest_bytes.get_string_from_utf8())
	if not (parsed is Dictionary): return {"error": "manifest is not an object"}
	var manifest: Dictionary = parsed
	if not (manifest.get("format") is float or manifest.get("format") is int) or int(manifest.get("format")) != 1: return {"error": "unknown manifest format"}
	if str(manifest.get("channel", "")) != "stable": return {"error": "not the stable channel"}
	var version := str(manifest.get("version", ""))
	if version_parts(version).is_empty(): return {"error": "bad version %s" % version}
	if not newer(version, current_version): return {"error": "version %s is not newer than %s" % [version, current_version]}
	if not (manifest.get("files") is Array): return {"error": "no file list"}
	var name_form := RegEx.create_from_string(ASSET_NAME)
	var hex_form := RegEx.create_from_string("^[0-9a-f]{64}$")
	for entry: Variant in manifest.files:
		if not (entry is Dictionary): return {"error": "bad file entry"}
		var file: Dictionary = entry
		var name := str(file.get("name", ""))
		if name_form.search(name) == null or name.begins_with("."): return {"error": "bad file name %s" % name}
		if not str(file.get("platform", "")) in PLATFORMS: return {"error": "bad platform for %s" % name}
		if hex_form.search(str(file.get("sha256", "")).to_lower()) == null: return {"error": "bad sha256 for %s" % name}
		var size: Variant = file.get("size")
		if not (size is float or size is int) or float(size) != floorf(float(size)) or float(size) <= 0.0: return {"error": "bad size for %s" % name}
	return manifest


## [major, minor, patch, fix] for "0.0.4", "0.0.3-maredev" or "0.0.6.1", [] when it is not a release version.
static func version_parts(version: String) -> Array[int]:
	var found := RegEx.create_from_string(VERSION_FORM).search(version.strip_edges())
	if found == null: return []
	return [int(found.get_string(1)), int(found.get_string(2)), int(found.get_string(3)), int(found.get_string(4)) if found.get_string(4) != "" else 0]


## Strictly newer by number. The same number with another label is not an update, and a
## running version that is not a release number ("dev") never sees one as newer.
static func newer(candidate: String, current: String) -> bool:
	var a := version_parts(candidate)
	var b := version_parts(current)
	if a.is_empty() or b.is_empty(): return false
	for i in 4:
		if a[i] != b[i]: return a[i] > b[i]
	return false


## This platform's files in manifest order (several = parts of one archive).
static func files_for(manifest: Dictionary, platform: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Variant in manifest.get("files", []):
		if entry is Dictionary and str((entry as Dictionary).get("platform", "")) == platform: out.append(entry)
	return out


## Lower-case sha256 of a file read in chunks, "" when it cannot be read. `stop` (optional)
## returns true to abandon the work.
static func sha256_file(path: String, stop: Callable = Callable()) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return ""
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	while file.get_position() < file.get_length():
		hashing.update(file.get_buffer(CHUNK))
		if stop.is_valid() and bool(stop.call()): return ""
	return hashing.finish().hex_encode()


## "" when the file has the signed size and sha256, else why not.
static func file_matches(path: String, size: int, sha256: String, stop: Callable = Callable()) -> String:
	if not FileAccess.file_exists(path): return "missing"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return "unreadable"
	var length := file.get_length(); file.close()
	if length != size: return "size %d, signed %d" % [length, size]
	var got := sha256_file(path, stop)
	if got.is_empty(): return "unreadable"
	if got != sha256.to_lower(): return "sha256 mismatch"
	return ""


## An archive entry name as a clean relative path, or "" when it is refused: absolute paths,
## drive letters, backslashes, "..", control characters or anything outside SAFE_NAME.
static func safe_entry(name: String) -> String:
	if name.is_empty() or name.begins_with("/") or "\\" in name or ":" in name: return ""
	if RegEx.create_from_string(SAFE_NAME).search(name) == null: return ""
	var parts: PackedStringArray = []
	for part in name.split("/"):
		if part == "" or part == ".": continue
		if part == ".." or part.strip_edges() != part: return ""
		parts.append(part)
	return "/".join(parts)


## Unpack a verified archive into dest. Returns {"files": [relative paths written], "error": ""}.
## Symlinks, hard links, devices, encrypted or unknown entries refuse the whole archive.
## progress(done_bytes, total_bytes) is called now and then; stop() true abandons it.
static func extract(archive: String, dest: String, progress: Callable = Callable(), stop: Callable = Callable()) -> Dictionary:
	var file := FileAccess.open(archive, FileAccess.READ)
	if file == null: return {"files": [], "error": "cannot open archive"}
	var magic := file.get_buffer(2); file.close()
	DirAccess.make_dir_recursive_absolute(dest)
	if magic.size() == 2 and magic[0] == 0x50 and magic[1] == 0x4b: return _extract_zip(archive, dest, progress, stop)
	if magic.size() == 2 and magic[0] == 0x1f and magic[1] == 0x8b: return _extract_tar_gz(archive, dest, progress, stop)
	return {"files": [], "error": "unknown archive kind"}


# ------------------------------------------------------------------ zip
## The central directory: [{name, method, crc, csize, usize, offset, flags, symlink}] or {"error"}.
static func zip_entries(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"error": "cannot open zip"}
	var length := file.get_length()
	var tail_size := mini(length, 65557)
	file.seek(length - tail_size)
	var tail := file.get_buffer(tail_size)
	var eocd := -1
	for i in range(tail.size() - 22, -1, -1):
		if tail.decode_u32(i) == 0x06054b50: eocd = i; break
	if eocd < 0: return {"error": "no zip directory"}
	var count := tail.decode_u16(eocd + 10)
	var dir_size: int = tail.decode_u32(eocd + 12)
	var dir_offset: int = tail.decode_u32(eocd + 16)
	if count == 0xFFFF or dir_size == 0xFFFFFFFF or dir_offset == 0xFFFFFFFF:
		# Zip64 (the 4.2 GB game pack): the locator sits just before the classic record.
		if eocd < 20 or tail.decode_u32(eocd - 20) != 0x07064b50: return {"error": "no zip64 locator"}
		file.seek(tail.decode_u64(eocd - 20 + 8))
		var record := file.get_buffer(56)
		if record.size() < 56 or record.decode_u32(0) != 0x06064b50: return {"error": "bad zip64 record"}
		count = record.decode_u64(32); dir_size = record.decode_u64(40); dir_offset = record.decode_u64(48)
	if dir_offset + dir_size > length or dir_size > 64 * 1024 * 1024: return {"error": "bad zip directory"}
	file.seek(dir_offset)
	var central := file.get_buffer(dir_size)
	var entries: Array[Dictionary] = []
	var at := 0
	for n in count:
		if at + 46 > central.size() or central.decode_u32(at) != 0x02014b50: return {"error": "bad zip entry"}
		var name_len := central.decode_u16(at + 28)
		var extra_len := central.decode_u16(at + 30)
		var comment_len := central.decode_u16(at + 32)
		var entry := {"made_by": central.decode_u16(at + 4) >> 8, "flags": central.decode_u16(at + 8),
			"method": central.decode_u16(at + 10), "crc": central.decode_u32(at + 16),
			"csize": central.decode_u32(at + 20), "usize": central.decode_u32(at + 24),
			"attr": central.decode_u32(at + 38), "offset": central.decode_u32(at + 42),
			"name": central.slice(at + 46, at + 46 + name_len).get_string_from_utf8()}
		# Zip64 extra: only the fields that read 0xFFFFFFFF above, in this order.
		var extra := central.slice(at + 46 + name_len, at + 46 + name_len + extra_len)
		var e := 0
		while e + 4 <= extra.size():
			var id := extra.decode_u16(e); var size := extra.decode_u16(e + 2)
			if id == 0x0001:
				var f := e + 4
				for field: String in ["usize", "csize", "offset"]:
					if int(entry[field]) == 0xFFFFFFFF and f + 8 <= e + 4 + size: entry[field] = extra.decode_u64(f); f += 8
			e += 4 + size
		var unix_mode := (int(entry.attr) >> 16) & 0xF000
		entry["symlink"] = int(entry.made_by) == 3 and unix_mode == 0xA000
		entry["special"] = int(entry.made_by) == 3 and unix_mode != 0 and unix_mode != 0x8000 and unix_mode != 0x4000
		entries.append(entry)
		at += 46 + name_len + extra_len + comment_len
	return {"entries": entries, "error": ""}


static func _extract_zip(archive: String, dest: String, progress: Callable, stop: Callable) -> Dictionary:
	var listing := zip_entries(archive)
	if str(listing.error) != "": return {"files": [], "error": listing.error}
	var total := 0
	# Every name is checked before the first byte is written.
	for entry: Dictionary in listing.entries:
		var raw := str(entry.name)
		var directory := raw.ends_with("/")
		if safe_entry(raw.trim_suffix("/") if directory else raw) == "": return {"files": [], "error": "refused entry name %s" % raw}
		if bool(entry.symlink) or bool(entry.special): return {"files": [], "error": "refused link or device %s" % raw}
		if int(entry.flags) & 1: return {"files": [], "error": "encrypted entry %s" % raw}
		if not int(entry.method) in [0, 8]: return {"files": [], "error": "unknown compression in %s" % raw}
		total += int(entry.usize)
	if total > MAX_UNPACKED: return {"files": [], "error": "archive unpacks too large"}
	var source := FileAccess.open(archive, FileAccess.READ)
	var written: Array[String] = []
	var done := 0
	for entry: Dictionary in listing.entries:
		var raw := str(entry.name)
		if raw.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(dest.path_join(safe_entry(raw.trim_suffix("/")))); continue
		var relative := safe_entry(raw)
		source.seek(int(entry.offset))
		var local := source.get_buffer(30)
		if local.size() < 30 or local.decode_u32(0) != 0x04034b50: return {"files": written, "error": "bad local header for %s" % raw}
		source.seek(int(entry.offset) + 30 + local.decode_u16(26) + local.decode_u16(28))
		var target := dest.path_join(relative)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null: return {"files": written, "error": "cannot write %s" % relative}
		var left := int(entry.csize)
		var gz: StreamPeerGZIP = null
		if int(entry.method) == 8:
			# Raw deflate wrapped as gzip: a 10-byte header in front, the entry's CRC and size
			# behind, so zlib checks the CRC from the zip directory too.
			gz = StreamPeerGZIP.new(); gz.start_decompression(false, CHUNK)
			if not _pump(gz, PackedByteArray([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]), out): return {"files": written, "error": "inflate failed in %s" % relative}
		while left > 0:
			var piece := source.get_buffer(mini(left, CHUNK))
			if piece.is_empty(): out.close(); return {"files": written, "error": "archive ends early in %s" % relative}
			left -= piece.size()
			if gz == null: out.store_buffer(piece)
			elif not _pump(gz, piece, out): out.close(); return {"files": written, "error": "inflate failed in %s" % relative}
			if stop.is_valid() and bool(stop.call()): out.close(); return {"files": written, "error": "stopped"}
		if gz != null:
			var trailer := PackedByteArray(); trailer.resize(8)
			trailer.encode_u32(0, int(entry.crc)); trailer.encode_u32(4, int(entry.usize) & 0xFFFFFFFF)
			if not _pump(gz, trailer, out): out.close(); return {"files": written, "error": "crc mismatch in %s" % relative}
		var length := out.get_length(); var failed := out.get_error() != OK
		out.close()
		if failed or length != int(entry.usize): return {"files": written, "error": "size mismatch in %s" % relative}
		written.append(relative)
		done += int(entry.usize)
		if progress.is_valid(): progress.call(done, total)
	return {"files": written, "error": ""}


## Feed compressed bytes in and write everything that comes out. False on a stream error.
static func _pump(gz: StreamPeerGZIP, data: PackedByteArray, out: FileAccess) -> bool:
	var at := 0
	while at < data.size():
		var result: Array = gz.put_partial_data(data if at == 0 else data.slice(at))
		if int(result[0]) != OK: return false
		at += int(result[1])
		var ready := gz.get_available_bytes()
		if int(result[1]) == 0 and ready == 0: return false
		while ready > 0:
			var got: Array = gz.get_partial_data(ready)
			if int(got[0]) != OK: return false
			if out != null: out.store_buffer(got[1])
			ready = gz.get_available_bytes()
	return true


# ------------------------------------------------------------------ tar.gz
## A ustar/pax stream reader fed with decompressed bytes. Regular files and folders only.
class TarSink:
	var dest := ""
	var verify: Script            # this file, for safe_entry
	var limit := 0
	var written: Array[String] = []
	var error := ""
	var ended := false
	var unpacked := 0
	var _header := PackedByteArray()
	var _out: FileAccess = null
	var _meta := PackedByteArray()
	var _meta_kind := ""          # "pax", "longname" or "skip" while reading a metadata entry
	var _left := 0
	var _pad := 0
	var _relative := ""
	var _exec := false
	var _next_name := ""
	var _next_size := -1

	func feed(data: PackedByteArray) -> void:
		var at := 0
		while at < data.size() and error == "" and not ended:
			if _left > 0:
				var n := mini(_left, data.size() - at)
				var piece := data.slice(at, at + n)
				if _out != null: _out.store_buffer(piece)
				elif _meta_kind != "skip": _meta.append_array(piece)
				_left -= n; at += n
				if _left == 0: _end_entry()
			elif _pad > 0:
				var n := mini(_pad, data.size() - at)
				_pad -= n; at += n
			else:
				var n := mini(512 - _header.size(), data.size() - at)
				_header.append_array(data.slice(at, at + n)); at += n
				if _header.size() == 512:
					_read_header(_header); _header = PackedByteArray()

	func _read_header(h: PackedByteArray) -> void:
		var blank := true
		for b in h:
			if b != 0: blank = false; break
		if blank: ended = true; return
		var sum := 0
		for i in 512: sum += 32 if i >= 148 and i < 156 else h[i]
		if sum != _octal(h, 148, 8): error = "bad tar header checksum"; return
		var size := _number(h, 124, 12)
		if size < 0: error = "bad tar entry size"; return
		var kind := h[156]
		var name := _text(h, 0, 100)
		if h.slice(257, 262).get_string_from_ascii() == "ustar" and _text(h, 345, 155) != "": name = _text(h, 345, 155) + "/" + name
		if kind == 0x78 or kind == 0x67 or kind == 0x4c:   # x pax, g global pax, L GNU long name
			_meta = PackedByteArray(); _meta_kind = str({0x78: "pax", 0x67: "skip", 0x4c: "longname"}[kind])
			_start_data(size); return
		if _next_name != "": name = _next_name
		if _next_size >= 0: size = _next_size
		_next_name = ""; _next_size = -1
		var directory := kind == 0x35
		var relative := str(verify.call("safe_entry", name.trim_suffix("/") if directory or name.ends_with("/") else name))
		if relative == "": error = "refused entry name %s" % name; return
		if directory: DirAccess.make_dir_recursive_absolute(dest.path_join(relative)); _start_data(0); return
		if kind != 0x30 and kind != 0: error = "refused link or device %s" % name; return
		unpacked += size
		if unpacked > limit: error = "archive unpacks too large"; return
		var target := dest.path_join(relative)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		_out = FileAccess.open(target, FileAccess.WRITE)
		if _out == null: error = "cannot write %s" % relative; return
		_meta_kind = ""; _relative = relative
		_exec = (_octal(h, 100, 8) & 73) != 0   # any x bit (0o111)
		_start_data(size)

	func _start_data(size: int) -> void:
		_left = size; _pad = (512 - size % 512) % 512
		if size == 0: _end_entry()

	func _end_entry() -> void:
		if _out != null:
			var failed := _out.get_error() != OK
			_out.close(); _out = null
			if failed: error = "cannot write %s" % _relative; return
			var target := dest.path_join(_relative)
			if _exec and OS.has_feature("linuxbsd"):
				FileAccess.set_unix_permissions(target, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER
					| FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_EXECUTE_GROUP | FileAccess.UNIX_READ_OTHER | FileAccess.UNIX_EXECUTE_OTHER)
			written.append(_relative)
		elif _meta_kind == "longname":
			_next_name = _meta.get_string_from_utf8()
		elif _meta_kind == "pax":
			# Records: "<length> key=value\n".
			for line in _meta.get_string_from_utf8().split("\n", false):
				var record := line.substr(line.find(" ") + 1)
				if record.begins_with("path="): _next_name = record.substr(5)
				elif record.begins_with("size="): _next_size = int(record.substr(5))
		_meta_kind = ""

	static func _text(h: PackedByteArray, from: int, length: int) -> String:
		var raw := h.slice(from, from + length)
		var end := raw.find(0)
		return (raw if end < 0 else raw.slice(0, end)).get_string_from_utf8()

	static func _octal(h: PackedByteArray, from: int, length: int) -> int:
		var digits := _text(h, from, length).strip_edges()
		if digits.is_empty(): return 0
		var value := 0
		for c in digits:
			if c < "0" or c > "7": return -1
			value = value * 8 + int(c)
		return value

	## Sizes past 8 GiB use base-256 (high bit set) instead of octal.
	static func _number(h: PackedByteArray, from: int, length: int) -> int:
		if h[from] & 0x80:
			var value := h[from] & 0x7f
			for i in range(from + 1, from + length): value = (value << 8) | h[i]
			return value
		return _octal(h, from, length)


static func _extract_tar_gz(archive: String, dest: String, progress: Callable, stop: Callable) -> Dictionary:
	var source := FileAccess.open(archive, FileAccess.READ)
	var total := source.get_length()
	var gz := StreamPeerGZIP.new(); gz.start_decompression(false, CHUNK)
	var sink := TarSink.new(); sink.dest = dest; sink.limit = MAX_UNPACKED
	sink.verify = load("res://world/update/update_verify.gd")
	while source.get_position() < total and sink.error == "" and not sink.ended:
		var piece := source.get_buffer(CHUNK)
		var at := 0
		while at < piece.size() and sink.error == "" and not sink.ended:
			var result: Array = gz.put_partial_data(piece if at == 0 else piece.slice(at))
			if int(result[0]) != OK: return {"files": sink.written, "error": "gzip stream error"}
			at += int(result[1])
			var ready := gz.get_available_bytes()
			if int(result[1]) == 0 and ready == 0: return {"files": sink.written, "error": "gzip stream stuck"}
			while ready > 0 and sink.error == "" and not sink.ended:
				var got: Array = gz.get_partial_data(ready)
				sink.feed(got[1])
				ready = gz.get_available_bytes()
		if progress.is_valid(): progress.call(source.get_position(), total)
		if stop.is_valid() and bool(stop.call()): return {"files": sink.written, "error": "stopped"}
	if sink.error == "" and not sink.ended: return {"files": sink.written, "error": "archive ends early"}
	return {"files": sink.written, "error": sink.error}
