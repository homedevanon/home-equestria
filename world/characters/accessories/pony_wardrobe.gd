extends Node
## Pony accessories by season and gifts (dev 2026-09-29: "hats and
## scarves and hoof socks that you can gift to your mare wife or see ponies walking around with if
## its the right temperature for it like theyll wear more accessories in winter"; "trixies
## accesories").
##
## Mare, stallion and filly scarves use fitted authored skins. Other accessory replacements
## are staged separately; accepted striped thigh highs stay unchanged.
## Dev 2026-11-11: the scarf is the winter wrap with a hanging end; thigh highs also come in one
## solid colour ("plain-socks"); only adult mares wear socks (seasonal or given); and few ponies
## dress for the cold at all ("maybe 20% of them even in dead winter because mare fur is warm":
## SCARF_SHARE, SOCKS_SHARE, BEANIE_SHARE). The /mlp/ cup scarf ("4cc-scarf") is the player's own:
## no season picks it and only CLUB_SCARF_WEARERS accept it as a gift.
## Canon ponies wear their show accessories by default (dev 2026-10-15: "add the default
## accessories for ponies like trixies cape and hat, nursie's nurse cap, etc"): DEFAULT_WEAR
## replaces seasonal clothing in the same slot; a gift still wins its slot.
## Every few seconds each loaded pony is dressed for the weather she feels (M-SEA-21, 2026-11-08):
## temperature() follows the year through season_state's progress (coldest mid-winter, warmest
## mid-summer, colder on lying snow, warmer where snow never lies), and each pony feels it a few
## degrees warmer or colder than the next. For the few who dress for it, scarves come out late in
## autumn and stay into early spring, deep winter adds thigh highs for some mares and a beanie for
## a very few; existing pieces only. Each pony makes the same choices on the same day. Summer adds
## nothing: the cowpony hat is Applejack's own (dev 2026-11-11, "nopony should wear AJ's hat").
## Cold mornings in winter also show her breath (world/life/day/actions/seasonal/cold_breath.gd). Gifts from Anon (world/relationships/hand_feeding.gd hands them over)
## are worn whatever the season, and are saved in the world ("pony_gifts").
const KINDS := ["scarf", "4cc-scarf", "beanie", "sunhat", "socks", "plain-socks", "wizard_hat", "cape", "spa-necklace", "bowtie", "necktie", "cowpony-hat", "detective-hat", "nurse-cap", "cat-eye-glasses", "aviators", "goggles", "headphones"]
const WORN_NAMES := {"scarf":"a scarf", "4cc-scarf":"a /mlp/ cup scarf", "beanie":"a detective hat", "sunhat":"a cowpony hat",
	"socks":"striped thigh-high socks", "plain-socks":"solid-colour thigh-high socks", "wizard_hat":"a wizard hat", "cape":"a cape", "spa-necklace":"a spa pendant necklace", "bowtie":"a bow tie", "necktie":"a necktie", "cowpony-hat":"a cowpony hat", "detective-hat":"a detective hat", "nurse-cap":"a nurse cap", "cat-eye-glasses":"cat-eye glasses", "aviators":"aviator glasses", "goggles":"flight goggles", "headphones":"headphones"}
## The first eight are the shop's colours; the rest are dyes for the wardrobe mirror (dev
## 2026-10-28, thread: "more sock colours"). pony_outfit.gd COLOUR_COUNT must match.
const COLOURS := [Color("c8423c"), Color("3f6fb5"), Color("e0b640"), Color("5a9a55"), Color("9b5bb5"), Color("e07aa8"), Color("f0ece0"), Color("3b3b45"),
	Color("f08a3c"), Color("6ec6e8"), Color("3aa89a"), Color("b8e06a"), Color("7a4a2e"), Color("f4c6d8"), Color("c9b3f0"), Color("1d2a5a")]
const HEADWEAR := ["beanie", "sunhat", "cowpony-hat", "detective-hat", "nurse-cap", "wizard_hat", "goggles", "headphones"]
const TRIXIE := "trixie"
## Show defaults that reuse fitted adult-mare pieces. Hair-export defaults (Applejack's hat)
## and character attachments (Vinyl's glasses, Braeburn's hat) are owned elsewhere.
## Trixie's wizard hat and cape are left off for the 0.0.1-maredev release (dev 2026-10-23:
## "remove trixie's cape and hat for the release build we can add them later"); restore
## "trixie": {"wizard_hat": 0, "cape": 0} here to bring them back.
const DEFAULT_WEAR := {
	"nurse_redheart": {"nurse-cap": 0},
	"octavia_melody": {"bowtie": 0},
}
const THIGH_HIGHS := preload("res://world/characters/accessories/pony_thigh_highs.gd")
const FITTED := preload("res://world/characters/accessories/pony_fitted_accessories.gd")
## Original source props, now only for shop displays and held gifts.
const TRIXIE_SOURCE := "res://world/characters/accessories/trixie/"
var game: Node
var _tick := 0.0
const CLIMATE := preload("res://world/seasons/climate_map.gd")
const BREATH := preload("res://world/life/day/actions/seasonal/cold_breath.gd")
const SEASON_ORDER := ["spring", "summer", "autumn", "winter"]
## Feels-like thresholds in degrees C (temperature() plus her own -3..+3).
const SCARF_BELOW := 8.0
const SOCKS_BELOW := 1.0
const BEANIE_BELOW := -1.0
## Breath shows on mornings colder than this.
const BREATH_BELOW := 3.0
const SUNHAT_ABOVE := 21.0
## Out of 1000 ponies, how many own each cold-weather piece and put it on when it is cold enough
## for it. Each is its own stable draw, so about one pony in five wears something in deep winter.
const SCARF_SHARE := 130
const SOCKS_SHARE := 70
## Hats are very rare: there are only a few hat models, so a crowd in them looks like a uniform.
const BEANIE_SHARE := 6
## The cowpony hat is Applejack's. No season puts it on anypony, and only she accepts one.
const COWPONY_HATS := ["sunhat", "cowpony-hat"]
const COWPONY_HAT_WEARERS := ["applejack"]
const SOCK_KINDS := ["socks", "plain-socks"]
## The only ponies who take the cup scarf as a gift (Anonfilly exists while her mod is on).
const CLUB_SCARF_WEARERS := ["anonfilly"]
## Where snow never lies (climate map R under 0.2: desert, jungle, coast) it feels this much warmer.
const SNOWLESS_WARMTH := 6.0
## id -> warmth of the climate she was last dressed in (wanted() without a position reuses it).
var _warmth := {}

## Read at prompt construction, never every frame. Attached items, not gift history
## or seasonal wishes, establish what is currently worn.
static func situation_line(pony: Node) -> String:
	var items: PackedStringArray = []
	for piece: Node in pony.find_children("Wear_*", "", true, false):
		if piece.is_queued_for_deletion(): continue
		var kind := String(piece.name).trim_prefix("Wear_")
		if WORN_NAMES.has(kind) and not items.has(WORN_NAMES[kind]): items.append(WORN_NAMES[kind])
	if items.is_empty(): return "- You currently have no seasonal or gifted clothing equipped."
	return "- You are currently wearing %s. You know you are wearing these items; a comment about your hat or clothes can refer to them." % ", ".join(items)

func setup(host: Node) -> void:
	game = host
	add_to_group("pony_wardrobe")

func gifts() -> Dictionary:
	var state: Dictionary = game.world_context.state
	if not state.get("pony_gifts") is Dictionary: state["pony_gifts"] = {}
	return state.pony_gifts

## Validate before the inventory transaction so a failed consume cannot grant a gift.
func can_give(pony_id: String, item_id: String, pony: Node3D = null) -> bool:
	if pony_id == TRIXIE: return false
	var parts := item_id.split(":")
	if parts.size() != 3 or parts[1] not in KINDS: return false
	if not preload("res://world/shop/shop_items.gd").has(item_id): return false
	if parts[1] == FITTED.CLUB_SCARF and pony_id not in CLUB_SCARF_WEARERS: return false
	if parts[1] in SOCK_KINDS and pony != null and not wears_socks(pony): return false
	if parts[1] in COWPONY_HATS and pony_id not in COWPONY_HAT_WEARERS: return false
	# Validate the recipient before taking the physical item from inventory.
	if (FITTED.has(parts[1]) or FITTED.OUTFIT.has(parts[1])) and not FITTED.supports_fitted(pony): return false
	return item_id not in gifts().get(pony_id, [])

## Only adult mares wear socks (dev 2026-11-11). The princesses count: they have their own pairs.
static func wears_socks(pony: Node) -> bool:
	var identity: Resource = pony.get("identity") if pony != null else null
	return identity != null and identity.get("stallion") != true and identity.get("filly") != true

## Her own stable draw for one piece: 0..999, the same every day.
static func _draw(id: String, piece: String) -> int:
	return absi(hash(id + ":" + piece)) % 1000

## A gift from Anon ("wear:<kind>:<colour index>"); she keeps and wears it.
func give(pony_id: String, item_id: String, pony: Node3D = null) -> bool:
	if not can_give(pony_id, item_id, pony): return false
	var list: Array = gifts().get(pony_id, [])
	list.append(item_id); gifts()[pony_id] = list
	# A new piece of a kind she had taken off is worn again.
	var off: Array = taken_off().get(pony_id, [])
	off.erase(item_id.split(":")[1])
	if game.world_context.has_method("_changed"): game.world_context._changed()
	return true

## Player bug board #32 ("i want her to remove them so I can touch her hoofa"): asked in
## conversation, she takes a piece off ([take_off: ITEM]) and keeps it off until she puts it back on
## ([put_on: ITEM]) or is given a new one of that kind. Saved with the world ("pony_off").
func taken_off() -> Dictionary:
	var state: Dictionary = game.world_context.state
	if not state.get("pony_off") is Dictionary: state["pony_off"] = {}
	return state.pony_off

## Words a pony may use for a piece, beyond its own name ("hat" means whichever hat she wears).
const ITEM_WORDS := {"hat": HEADWEAR, "cap": ["nurse-cap", "beanie"], "glasses": ["cat-eye-glasses", "aviators", "goggles"],
	"sunglasses": ["aviators"], "stockings": SOCK_KINDS, "thigh_highs": SOCK_KINDS, "leggings": SOCK_KINDS, "sock": SOCK_KINDS, "socks": SOCK_KINDS,
	"necklace": ["spa-necklace"], "pendant": ["spa-necklace"], "tie": ["necktie", "bowtie"], "bow_tie": ["bowtie"]}

## The kinds among `among` that a spoken item name means.
static func match_item(spoken: String, among: Array) -> Array:
	var word := spoken.strip_edges().to_lower().replace(" ", "_").replace("-", "_").trim_prefix("my_").trim_prefix("the_").trim_prefix("your_")
	var found: Array = []
	if word.length() < 3: return found
	for kind: String in among:
		var plain := kind.replace("-", "_")
		if word == plain or word == plain.trim_suffix("s") or str(WORN_NAMES.get(kind, "")).replace(" ", "_").replace("-", "_").ends_with(word): found.append(kind)
	if found.is_empty():
		for kind: Variant in ITEM_WORDS.get(word, ITEM_WORDS.get(word.trim_suffix("s"), [])):
			if kind in among: found.append(kind)
	return found

## Take off (on = false) or put back on: what she did, or "" when she has nothing by that name.
func set_worn(id: String, spoken: String, on: bool) -> String:
	var off: Array = taken_off().get(id, [])
	var kinds := match_item(spoken, off if on else wanted(id, _season()).keys())
	if kinds.is_empty(): return ""
	for kind: String in kinds:
		if on: off.erase(kind)
		elif kind not in off: off.append(kind)
	if off.is_empty(): taken_off().erase(id)
	else: taken_off()[id] = off
	if game.world_context.has_method("_changed"): game.world_context._changed()
	return ", ".join(kinds.map(func(kind: String) -> String: return str(WORN_NAMES.get(kind, kind))))

func _season() -> String:
	var weather: Node = game.get_node_or_null("Weather")
	return str(weather.get("season")) if weather != null else "spring"

func _physics_process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or game == null: return
	_tick = 4.0
	var season := _season()
	var breath := _breath_weather(season)
	for pony: Variant in game.mares:
		if not is_instance_valid(pony) or not (pony as Node3D).is_inside_tree(): continue
		var identity: Resource = pony.get("identity")
		if identity == null: continue
		var at: Vector3 = (pony as Node3D).global_position
		var id := str(identity.id)
		_warmth[id] = 0.0 if season == "summer" or CLIMATE.sample(Vector2(at.x, at.z), 0) >= 0.2 else SNOWLESS_WARMTH
		dress(pony, id, season)
		var tier: Variant = pony.get("sim_tier")
		BREATH.set_on(pony, breath and float(_warmth[id]) <= 0.0 and tier is int and int(tier) == 0)
	BREATH.set_camera(self, breath)

## The season node (group season_state), or null in fixtures without one.
func _season_state() -> Node:
	return get_tree().get_first_node_in_group("season_state") if is_inside_tree() else null

## Degrees C for `season` at `progress` (0..1 through it) with `snow` cover 0..1: a smooth year,
## about 24 mid-summer, 11 mid-spring/autumn, 2 at the turn of winter and -2 mid-winter.
static func temperature(season: String, progress: float, snow := 0.0) -> float:
	var index := maxi(0, SEASON_ORDER.find(season))
	var year := (float(index) + clampf(progress, 0.0, 1.0)) / 4.0
	return 11.0 + 13.0 * cos(TAU * (year - 0.375)) - 3.0 * clampf(snow, 0.0, 1.0)

## Today's temperature for `season` (the live progress and snow when it is the live season, else
## the middle of it).
func _temperature(season: String) -> float:
	var state := _season_state()
	if state != null and str(state.call("season")) == season:
		return temperature(season, float(state.call("progress")), float(state.call("snow_cover")))
	return temperature(season, 0.5)

## Winter mornings (05:00-10:30) cold enough to see breath, with seasonal effects on.
func _breath_weather(season: String) -> bool:
	if season != "winter" and season != "autumn" and season != "spring": return false
	var state := _season_state()
	if state != null and state.has_method("effects_level") and int(state.call("effects_level")) <= 0: return false
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	var hours: float = float(clock.get("hours")) if clock != null else 12.0
	return hours >= 5.0 and hours <= 10.5 and _temperature(season) < BREATH_BELOW

## What she wears now: {kind: colour index}.
func wanted(id: String, season: String) -> Dictionary:
	var result := {}
	var roll := absi(hash(id))
	var colour := roll % COLOURS.size()
	# Her own sense of cold: -3..+3 degrees, the same every day.
	var feel := _temperature(season) + float(_warmth.get(id, 0.0)) + float(absi(hash(id + ":cold")) % 7) - 3.0
	if feel < SCARF_BELOW and _draw(id, "scarf") < SCARF_SHARE: result.scarf = colour
	# Half of the sock wearers knit theirs striped, half solid. dress() keeps socks to mares.
	if feel < SOCKS_BELOW and _draw(id, "socks") < SOCKS_SHARE: result[SOCK_KINDS[roll % 2]] = (colour + 5) % COLOURS.size()
	if feel < BEANIE_BELOW and _draw(id, "beanie") < BEANIE_SHARE: result.beanie = (colour + 3) % COLOURS.size()
	var defaults: Dictionary = DEFAULT_WEAR.get(id, {})
	for kind: String in defaults:
		var default_slot := FITTED.slot(kind)
		for other: String in result.keys():
			if not default_slot.is_empty() and FITTED.slot(other) == default_slot: result.erase(other)
		result[kind] = int(defaults[kind])
	# Trixie keeps her showmare outfit; gifts are not fitted to her covered mane yet.
	if id == TRIXIE: return result
	for gift: String in gifts().get(id, []):
		var parts := gift.split(":")
		if parts.size() != 3: continue
		# The latest gift wins within its physical slot, preserving gift history.
		var slot := FITTED.slot(parts[1])
		if not slot.is_empty():
			for kind: String in result.keys():
				if FITTED.slot(kind) == slot: result.erase(kind)
		result[parts[1]] = int(parts[2])
	for kind: Variant in taken_off().get(id, []): result.erase(kind)
	return result

func dress(pony: Node3D, id: String, season: String) -> void:
	var want := wanted(id, season)
	if not wears_socks(pony):
		for kind: String in SOCK_KINDS: want.erase(kind)
	if want.has(FITTED.CLUB_SCARF) and id not in CLUB_SCARF_WEARERS: want.erase(FITTED.CLUB_SCARF)
	if id not in COWPONY_HAT_WEARERS:
		for kind: String in COWPONY_HATS: want.erase(kind)
	if not FITTED.supports_fitted(pony):
		for kind: String in want.keys():
			if FITTED.has(kind) or FITTED.OUTFIT.has(kind): want.erase(kind)
	var worn: Dictionary = pony.get_meta("wardrobe", {})
	if worn == want: return
	for kind: String in worn.keys():
		if not want.has(kind) or int(want[kind]) != int(worn[kind]):
			for old: Node in pony.find_children("Wear_" + kind + "*", "", true, false):
				# Release the name before attaching its replacement in this tick.
				# Deferred deletion alone renames the new piece, losing awareness
				# and preventing the next outfit change from finding it.
				old.get_parent().remove_child(old)
				old.queue_free()
	for kind: String in want:
		if worn.has(kind) and int(worn[kind]) == int(want[kind]): continue
		_attach(pony, kind, COLOURS[int(want[kind]) % COLOURS.size()])
	pony.set_meta("wardrobe", want.duplicate())
	_update_original_hat(pony, want)

## Canonical hair exports can include a hat. Replace it while a gift is worn,
## including cached near/far meshes, and restore it when the gift is removed.
func _update_original_hat(pony: Node3D, want: Dictionary) -> void:
	var hair: Node3D = pony.get("hair")
	var identity: Resource = pony.get("identity")
	if hair == null or identity == null: return
	var original_hats: Array[MeshInstance3D] = []
	for name: String in identity.accessories:
		if not name.ends_with("Hat"): continue
		var mesh := hair.find_child(name, true, false) as MeshInstance3D
		if mesh != null: original_hats.append(mesh)
	if original_hats.is_empty(): return
	var covered := false
	for kind: String in HEADWEAR:
		if want.has(kind): covered = true; break
	if covered == bool(pony.get_meta("wardrobe_covers_hat", false)): return
	var variant := str(pony.get_meta("geometry_variant", "")).replace("|wardrobe-hat", "")
	pony.refresh_geometry_variant(variant + ("|wardrobe-hat" if covered else ""))
	for mesh: MeshInstance3D in original_hats: mesh.visible = not covered
	pony.set_meta("wardrobe_covers_hat", covered)

func _attach(pony: Node3D, kind: String, colour: Color) -> void:
	var body: Skeleton3D = pony.get("skeleton")
	if FITTED.has(kind):
		FITTED.attach_fitted(pony, kind)
		return
	if FITTED.OUTFIT.has(kind):
		# The wizard hat rests on the whole mane since its 2026-11-11 refit (no cut-out mane).
		FITTED.attach_outfit(pony, kind)
		return
	match kind:
		"scarf":
			if FITTED.supports(pony):
				FITTED.attach_scarf(pony, colour)
				return
			# Around the neck: the ring's axis follows the neck toward the head.
			var up := Vector3.UP
			if body != null and body.find_bone("pony_neck1") >= 0 and body.find_bone("pony_head") >= 0:
				up = (_bone_world(body, "pony_head").origin - _bone_world(body, "pony_neck1").origin).normalized()
			_on_bone(body, "pony_neck1", kind, _legacy_scarf(colour), pony, Vector3.ZERO, _basis_with_up(pony, up))
		"4cc-scarf":
			FITTED.attach_club_scarf(pony)
		"socks", "plain-socks":
			THIGH_HIGHS.attach(pony, colour, kind)

static func _bone_world(skeleton: Skeleton3D, bone: String) -> Transform3D:
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone))

## A basis turned from the pony's own (x right, y up, -z forward) so its y points along `up`.
static func _basis_with_up(pony: Node3D, up: Vector3) -> Basis:
	var frame := pony.global_basis.orthonormalized()
	var axis := frame.y.cross(up)
	if axis.length() < 0.0001: return frame
	return Basis(axis.normalized(), frame.y.angle_to(up)) * frame

## Parent `piece` to a bone. With `pony` given, the piece is laid out in the pony's body frame
## (`frame`, offset in that frame from the bone) as she stands now, then follows the bone.
func _on_bone(skeleton: Skeleton3D, bone: String, kind: String, piece: Node3D, pony: Node3D = null, offset := Vector3.ZERO, frame := Basis.IDENTITY) -> void:
	if skeleton == null or skeleton.find_bone(bone) < 0: piece.free(); return
	var attachment := BoneAttachment3D.new()
	attachment.name = "Wear_" + kind
	attachment.bone_name = bone
	skeleton.add_child(attachment)
	attachment.add_child(piece)
	if pony != null:
		var at := _bone_world(skeleton, bone)
		var scale := pony.global_basis.get_scale().x
		piece.transform = at.affine_inverse() * Transform3D(frame.scaled(Vector3.ONE * scale), at.origin + frame * offset * scale)
	for mesh: GeometryInstance3D in piece.find_children("*", "GeometryInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func _mat(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = colour; m.roughness = 0.95
	return m

static func _mesh(parent: Node3D, mesh: Mesh, colour: Color, at := Vector3.ZERO, rot := Vector3.ZERO, scale := Vector3.ONE) -> MeshInstance3D:
	var node := MeshInstance3D.new(); node.mesh = mesh; node.material_override = _mat(colour)
	node.position = at; node.rotation = rot; node.scale = scale
	parent.add_child(node)
	return node

static func _scarf(colour: Color) -> Node3D:
	return FITTED.display_scarf(colour)

## Retained for bodies whose replacement fit has not yet been validated.
static func _legacy_scarf(colour: Color) -> Node3D:
	var root := Node3D.new(); root.name = "Scarf"
	var ring := TorusMesh.new(); ring.inner_radius = 0.075; ring.outer_radius = 0.115; ring.rings = 24; ring.ring_segments = 10
	_mesh(root, ring, colour, Vector3(0, 0.03, 0), Vector3.ZERO, Vector3(1.0, 1.6, 1.0))
	var stripe := TorusMesh.new(); stripe.inner_radius = 0.106; stripe.outer_radius = 0.12; stripe.rings = 24; stripe.ring_segments = 6
	_mesh(root, stripe, colour.lightened(0.45), Vector3(0, 0.03, 0))
	var tail := BoxMesh.new(); tail.size = Vector3(0.05, 0.14, 0.02)
	_mesh(root, tail, colour, Vector3(0.03, -0.04, 0.11), Vector3(0.3, 0, 0.15))
	_mesh(root, tail, colour, Vector3(-0.02, -0.06, 0.115), Vector3(0.35, 0, -0.1))
	return root

## Legacy inventory IDs retain their stock keys, now showing the authored replacements.
static func _beanie(_colour: Color) -> Node3D:
	return FITTED.display_fitted("beanie")

static func _sunhat() -> Node3D:
	return FITTED.display_fitted("sunhat")

## Original Source props for shop displays and held gifts; canonical textures are retained.
static func _wizard_hat(_colour: Color) -> Node3D:
	if not ResourceLoader.exists(TRIXIE_SOURCE.path_join("hat.scn")): return Node3D.new()
	var scene := load(TRIXIE_SOURCE.path_join("hat.scn")) as PackedScene
	return scene.instantiate() as Node3D if scene != null else Node3D.new()

static func _cape(_colour: Color) -> Node3D:
	if not ResourceLoader.exists(TRIXIE_SOURCE.path_join("cape.scn")): return Node3D.new()
	var scene := load(TRIXIE_SOURCE.path_join("cape.scn")) as PackedScene
	return scene.instantiate() as Node3D if scene != null else Node3D.new()

## The shop and held accessory use the same shaped, knitted thigh highs as the wearer.
static func _sock(colour: Color, plain := false) -> Node3D:
	return THIGH_HIGHS.display_pair(colour, plain)
