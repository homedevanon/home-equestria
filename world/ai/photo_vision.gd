extends RefCounted
## Opt-in photo vision (dev 2026-10-25): when the player talks to a pony while holding a photo
## from the photo camera (world/items/photo_camera.gd), the pony sees it.
## AI Settings → "Photos": "off" (the default: no image ever leaves the game), "same" (the dialogue
## model gets the picture itself; it must accept images), or "separate" (a vision model of the
## player's choice describes the picture in words, which the dialogue model reads).
## An image costs far more input tokens than a line of speech, and only the turn that shows the
## photo carries it.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const MODES := ["off", "same", "separate"]
## Longest side sent to a provider; small enough to stay cheap, big enough to recognise ponies.
const MAX_SIDE := 768
const SHOWN_NOTE := "(Anon is holding up a photo he took so you can see it.)"
const DESCRIBED_NOTE := "(Anon is holding up a photo he took so you can see it. The photo shows: %s)"
const DESCRIBE_SYSTEM := "You describe photos for someone who cannot see them. In two or three plain sentences say who and what is in the picture, where it seems to be, and the main colours. Characters are ponies from My Little Pony: Friendship is Magic; name one only when you are sure who she is. No preamble."
const DESCRIBE_ASK := "Describe this photo."
## Paintings and drawings from the easel (M-AI-13) are shown the same way; with_note() then says he
## painted it instead of took it, so no request is added and the photo wording stays as it was.
const PHOTO_WORDS := "a photo he took"
const PAINTED_WORDS := "a picture he painted"
## Whether the last held_photo() found a painting rather than a photo (read by with_note()).
static var _painted := false

static func mode(config: RefCounted) -> String:
	var value := str(config.get_value("vision/mode", "off"))
	return value if value in MODES else "off"

## The photo (or painting) file the player holds in a hand (desktop or VR), or "" when none.
static func held_photo(tree: SceneTree) -> String:
	_painted = false
	if tree == null or tree.root == null: return ""
	var inventory := tree.root.find_child("BriefcaseInventory", true, false)
	if inventory == null: return ""
	var held: Variant = inventory.get("held")
	if not held is Dictionary: return ""
	for item: Variant in (held as Dictionary).values():
		if not is_instance_valid(item): continue
		var id := REGISTRY.art_id(str((item as Node).get_meta("item_id", "")))
		if id.is_empty(): continue
		var path := REGISTRY.art_path(id)
		if FileAccess.file_exists(path):
			_painted = not REGISTRY.is_photo(id)
			return path
	return ""

## The photo as a base64 JPEG no larger than MAX_SIDE, or "" when it cannot be read.
static func encode(path: String) -> String:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty(): return ""
	var longest := maxi(image.get_width(), image.get_height())
	if longest > MAX_SIDE:
		var scale := float(MAX_SIDE) / float(longest)
		image.resize(roundi(image.get_width() * scale), roundi(image.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var bytes := image.save_jpg_to_buffer(0.85)
	return Marshalls.raw_to_base64(bytes) if not bytes.is_empty() else ""

## The last user message of `messages` with `note` added (a copy; the stored history keeps the line).
static func with_note(messages: Array, note: String) -> Array:
	var out := messages.duplicate()
	if out.is_empty(): return out
	var last: Dictionary = (out[-1] as Dictionary).duplicate()
	if _painted: note = note.replace(PHOTO_WORDS, PAINTED_WORDS).replace("The photo shows", "The picture shows")
	last.content = str(last.get("content", "")) + "\n" + note
	out[-1] = last
	return out
