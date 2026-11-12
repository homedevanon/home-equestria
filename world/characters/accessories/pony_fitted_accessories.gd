extends RefCounted
## Blender-authored garments share the existing body rig and cached resources.
const SCARF := preload("res://world/characters/accessories/fitted/scarf.scn")
const SCARF_STALLION := preload("res://world/characters/accessories/fitted/scarf-stallion.scn")
const SCARF_FILLY := preload("res://world/characters/accessories/fitted/scarf-filly.scn")
const SCARF_DISPLAY := preload("res://world/characters/accessories/fitted/scarf-display.res")
## The /mlp/ team's cup scarf (dev 2026-11-11): the player's own, and Anonfilly's when that mod is
## on (pony_wardrobe.gd CLUB_SCARF_WEARERS). One picture, no colours; same three body fits.
const CLUB_SCARF := "4cc-scarf"
const CLUB_SCARF_SCENES := {
	"mare": preload("res://world/characters/accessories/fitted/4cc-scarf.scn"),
	"stallion": preload("res://world/characters/accessories/fitted/4cc-scarf-stallion.scn"),
	"filly": preload("res://world/characters/accessories/fitted/4cc-scarf-filly.scn"),
}
const CLUB_SCARF_DISPLAY := preload("res://world/characters/accessories/fitted/4cc-scarf-display.res")
const CLUB_SCARF_PICTURE := preload("res://world/characters/accessories/fitted/4cc-scarf-albedo.res")
## Textured pieces retain their source palette; each currently has an adult-mare fit.
const PIECES := {
	"spa-necklace": {"slot": "neck", "scene": preload("res://world/characters/accessories/fitted/spa-necklace.scn"), "display": preload("res://world/characters/accessories/fitted/spa-necklace-display.res")},
	"bowtie": {"slot": "neck", "scene": preload("res://world/characters/accessories/fitted/bowtie.scn"), "display": preload("res://world/characters/accessories/fitted/bowtie-display.res")},
	"necktie": {"slot": "neck", "scene": preload("res://world/characters/accessories/fitted/necktie.scn"), "display": preload("res://world/characters/accessories/fitted/necktie-display.res")},

	"cowpony-hat": {"slot": "head", "scene": preload("res://world/characters/accessories/fitted/cowpony-hat.scn"), "display": preload("res://world/characters/accessories/fitted/cowpony-hat-display.res")},
	"detective-hat": {"slot": "head", "scene": preload("res://world/characters/accessories/fitted/detective-hat.scn"), "unicorn": preload("res://world/characters/accessories/fitted/detective-hat-unicorn.scn"), "display": preload("res://world/characters/accessories/fitted/detective-hat-display.res")},
	"nurse-cap": {"slot": "head", "scene": preload("res://world/characters/accessories/fitted/nurse-cap.scn"), "display": preload("res://world/characters/accessories/fitted/nurse-cap-display.res")},
	"cat-eye-glasses": {"slot": "eyes", "scene": preload("res://world/characters/accessories/fitted/cat-eye-glasses.scn"), "display": preload("res://world/characters/accessories/fitted/cat-eye-glasses-display.res")},
	"aviators": {"slot": "eyes", "scene": preload("res://world/characters/accessories/fitted/aviators.scn"), "display": preload("res://world/characters/accessories/fitted/aviators-display.res")},
	"goggles": {"slot": "head", "scene": preload("res://world/characters/accessories/fitted/goggles.scn"), "display": preload("res://world/characters/accessories/fitted/goggles-display.res")},
	"headphones": {"slot": "head", "scene": preload("res://world/characters/accessories/fitted/headphones.scn"), "display": preload("res://world/characters/accessories/fitted/headphones-display.res")},
}
## Trixie's showmare hat and cape, refitted 2026-10-15 to her current standing snapshot and
## skinned to her own bones (hat: head; cape: neck, spine and hips) so they follow walking,
## sitting and lying. The October 7 rigid mounts used the bone rest instead of the posed body.
## Shop and held items keep the original source props (pony_wardrobe._wizard_hat/_cape).
const OUTFIT := {
	"wizard_hat": preload("res://world/characters/accessories/fitted/trixie-hat.scn"),
	"cape": preload("res://world/characters/accessories/fitted/trixie-cape.scn"),
}
const HAT_ALIASES := {"beanie": "detective-hat", "sunhat": "cowpony-hat"}
## Each hat was fitted at one height that clears the tallest manes, so on most mares it hovered
## (dev 2026-11-11: "they're floating above most mare heads"). This table says, for every mane,
## how many metres the hat comes down (or up) to rest on it; ears and horn pass through the brim.
## Measured by tools/accessories/measure_hat_seats.gd; rebuild it after adding a mane. A mane
## that is not listed gets the table's "default" row.
const HAT_SEATS := "res://world/characters/accessories/hat_seats.json"
static var _seats: Dictionary = {}
static var _seats_read := false
static var _seated_skins: Dictionary = {}
static var _materials: Dictionary = {}
static var _display_materials: Dictionary = {}
static var _club_material: StandardMaterial3D

static func supports(pony: Node3D) -> bool:
	var identity: Resource = pony.get("identity")
	# A colt combines the stallion body with foal proportions; it is not the
	# separately authored filly mesh. Keep that unvalidated combination guarded.
	return identity != null and not (identity.filly and identity.stallion)

static func material(colour: Color) -> StandardMaterial3D:
	if not _materials.has(colour):
		var result := SCARF_DISPLAY.surface_get_material(0).duplicate() as StandardMaterial3D
		result.albedo_color = colour
		# Preserve worn-scarf culling; the laid-out cloth needs its inside visible.
		result.cull_mode = BaseMaterial3D.CULL_BACK
		_materials[colour] = result
	return _materials[colour]

static func supports_fitted(pony: Node3D) -> bool:
	if pony == null: return false
	var identity: Resource = pony.get("identity")
	return identity != null and not identity.filly and not identity.stallion

static func canonical_kind(kind: String) -> String:
	return str(HAT_ALIASES.get(kind, kind))

static func has(kind: String) -> bool:
	return PIECES.has(canonical_kind(kind))

static func slot(kind: String) -> String:
	if kind == "scarf" or kind == CLUB_SCARF: return "neck"
	# Striped and solid thigh highs are one pair of legs.
	if kind == "socks" or kind == "plain-socks": return "legs"
	if kind == "wizard_hat": return "head"
	# The cape's collar closes around the neck, where a scarf or bow tie would sit.
	if kind == "cape": return "neck"
	return str(PIECES.get(canonical_kind(kind), {}).get("slot", ""))

static func attach_fitted(pony: Node3D, kind: String) -> MeshInstance3D:
	if not has(kind) or not supports_fitted(pony): return null
	var entry: Dictionary = PIECES[canonical_kind(kind)]
	var identity: Resource = pony.get("identity")
	var scene: PackedScene = entry.get("unicorn", entry.scene) if identity.has_horn() else entry.scene
	var piece := _attach(pony, scene)
	if piece != null:
		piece.name = "Wear_" + kind
		piece.skin = _seated(piece.skin, hat_seat(pony, kind))
	return piece

## Metres this hat comes down from its authored height on this pony's mane (negative: up).
static func hat_seat(pony: Node3D, kind: String) -> float:
	if not _seats_read:
		_seats_read = true
		if FileAccess.file_exists(HAT_SEATS):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HAT_SEATS))
			if parsed is Dictionary: _seats = parsed
	var identity: Resource = pony.get("identity") if pony != null else null
	if identity == null: return 0.0
	var manes: Dictionary = _seats.get("manes", {})
	var row: Dictionary = manes.get(str(identity.hair_scene), _seats.get("default", {}))
	return float(row.get(canonical_kind(kind), 0.0))

## The piece's skin moved straight down by `drop` in the model's own frame, so the hat keeps
## following the head bone. One copy per skin and millimetre.
static func _seated(skin: Skin, drop: float) -> Skin:
	if skin == null or absf(drop) < 0.0005: return skin
	var key := "%d|%d" % [skin.get_instance_id(), roundi(drop * 1000.0)]
	if not _seated_skins.has(key):
		var moved := skin.duplicate() as Skin
		var shift := Transform3D(Basis.IDENTITY, Vector3(0.0, -drop, 0.0))
		for i in moved.get_bind_count(): moved.set_bind_pose(i, moved.get_bind_pose(i) * shift)
		_seated_skins[key] = moved
	return _seated_skins[key]

static func attach_outfit(pony: Node3D, kind: String) -> MeshInstance3D:
	if not OUTFIT.has(kind) or not supports_fitted(pony): return null
	var piece := _attach(pony, OUTFIT[kind])
	if piece != null:
		piece.name = "Wear_" + kind
		# The showmare hat was fitted on Trixie's own mane; on another mare it rests on hers.
		if kind == "wizard_hat": piece.skin = _seated(piece.skin, hat_seat(pony, kind))
	return piece

static func display_fitted(kind: String) -> MeshInstance3D:
	var piece := MeshInstance3D.new()
	piece.name = kind
	piece.mesh = PIECES[canonical_kind(kind)].display
	piece.rotation.y = PI
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return piece

static func attach_scarf(pony: Node3D, colour: Color) -> MeshInstance3D:
	if not supports(pony): return null
	var identity: Resource = pony.get("identity")
	var scene: PackedScene = SCARF_FILLY if identity.filly else (SCARF_STALLION if identity.stallion else SCARF)
	var piece := _attach(pony, scene)
	if piece == null: return null
	piece.material_override = material(colour)
	return piece

## The folded loop shows both of its faces, so nothing is culled.
static func club_material() -> StandardMaterial3D:
	if _club_material == null:
		_club_material = StandardMaterial3D.new()
		_club_material.albedo_texture = CLUB_SCARF_PICTURE
		_club_material.roughness = 0.95
		_club_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _club_material

static func attach_club_scarf(pony: Node3D) -> MeshInstance3D:
	if not supports(pony): return null
	var identity: Resource = pony.get("identity")
	var piece := _attach(pony, CLUB_SCARF_SCENES["filly" if identity.filly else ("stallion" if identity.stallion else "mare")])
	if piece == null: return null
	piece.name = "Wear_" + CLUB_SCARF
	piece.material_override = club_material()
	return piece

static func display_club_scarf() -> MeshInstance3D:
	var piece := MeshInstance3D.new()
	piece.name = "ClubScarf"
	piece.mesh = CLUB_SCARF_DISPLAY
	piece.material_override = club_material()
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return piece

static func _attach(pony: Node3D, scene: PackedScene) -> MeshInstance3D:
	var body: Skeleton3D = pony.get("skeleton")
	var pivot: Node3D = pony.get("pivot")
	if body == null or pivot == null: return null
	var piece := scene.instantiate() as MeshInstance3D
	# Skin transforms are local to the mesh instance. Share the body's moving
	# frame; parenting to the actor root loses flight banking and posture tilt.
	pivot.add_child(piece)
	piece.transform = pony.get("_model_frame")
	piece.skeleton = piece.get_path_to(body)
	var form := pony.get_tree().get_first_node_in_group("player_pony_form")
	if form != null and form.get("avatar") == pony: form.refresh_body_visibility()
	return piece

static func display_scarf(colour: Color) -> MeshInstance3D:
	var piece := MeshInstance3D.new()
	piece.name = "Scarf"
	piece.mesh = SCARF_DISPLAY
	piece.material_override = display_material(colour)
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return piece

static func display_material(colour: Color) -> StandardMaterial3D:
	if not _display_materials.has(colour):
		var result := material(colour).duplicate() as StandardMaterial3D
		result.cull_mode = BaseMaterial3D.CULL_DISABLED
		_display_materials[colour] = result
	return _display_materials[colour]

