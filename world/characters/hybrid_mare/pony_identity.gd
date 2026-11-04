class_name PonyIdentity
extends Resource
## Who a hybrid mare is: colours, race, hair, mark, lashes, personality knobs, persona.
##
## One scene and one script (hybrid_mare.tscn / .gd) serve every Mane 6 member; only this
## resource differs. Defaults are Rainbow Dash so an unset identity behaves as before.
## Colours: mlpvector.club Friendship is Magic colour guide (coat fill / outline / shadow fill).

enum Race { EARTH, PEGASUS, UNICORN, ALICORN }
enum LashStyle { STANDARD, PINKIE, FLUTTERSHY, RARITY }

@export var id := "rainbow_dash"
## The character whose body and character-specific behaviour this pony has, when that is not her own
## id: a mod's stand-in or copy of a canon pony ("pinkie_pie" for a mod's pinkie_pie_copy_3) gets
## Pinkie's bounce, Celestia's size or Vinyl's glasses without pretending to be her. Empty: her own id.
## Code that asks "is this Pinkie's body/behaviour?" reads character(); code about who she is (memory,
## relationships, saves, prompts) keeps reading id.
@export var character_id := ""
@export var stallion := false
## A filly (dev 2026-09-23): the adult body at filly proportions (hybrid_mare.gd FILLY_*):
## smaller overall, bigger head, shorter neck, sturdier legs. No separate rig.
@export var filly := false
## Folded wing size (Scootaloo's are comically small) and whether a pegasus can fly at all.
@export var wing_scale := 1.0
@export var can_fly := true
@export var display_name := "Rainbow Dash"
@export var race := Race.PEGASUS
@export var coat_fill := Color("9BDBF5")
@export var coat_line := Color("6BABDA")
@export var coat_shade := Color("8CC7E7")
## Line colour on the mane and tail (the strand fills come from the hair GLB's materials).
@export var mane_line := Color("1B98D1")
@export var iris_color := Color("C42B7B")
@export var lash_style := LashStyle.STANDARD
## Alpha 0 = use the canonical palette, or ordinary coat shading if none is listed.
@export var eyeshadow_color := Color(0.72, 0.88, 0.94, 0.0)
## Alpha 0 = no freckles. Applejack's six cheek freckles (face_sculpt.gd FRECKLE_SPOTS).
@export var freckle_color := Color(0.99, 0.87, 0.58, 0.0)
static var _eyelid_palette: Dictionary = {}
## Swapped onto the native body's Cutie mark.L/.R patches; null keeps the export's texture.
@export var cutie_mark: Texture2D
## Devkit mane + tail GLB (tools/extract_devkit_hair.py) and the node-name prefix inside it.
@export var hair_scene := "res://world/characters/hybrid_mare/dash_devkit_hair.glb"
@export var hair_prefix := "Dash"
## Tail seat in the hybrid pivot's frame (hip-relative), tuned per hair.
@export var tail_mount_offset := Vector3(0.0, 0.075, -0.025)
## Moves the whole mane relative to the head (model space: +Y up, -Z forward), for library
## hair whose automatic fit sits off the scalp.
@export var mane_offset := Vector3.ZERO
@export var tail_angle_limits_deg: Array[float] = [5.0, 8.0, 10.0, 12.0, 14.0, 14.0]
## Full hair articulation for physical draping; old small limits describe sway only.
@export var tail_bend_limits_deg: Array[float] = [60.0, 75.0, 80.0, 80.0, 75.0, 70.0]
@export var tail_terminal_length := 0.21088 * 0.82
@export var tail_segment_radii: Array[float] = [0.045, 0.065, 0.085, 0.075, 0.05, 0.016]
## Legacy serialized field; ignored. Fit mesh AND rest bones in the exporter.
## Scaling this chain at runtime detached the hair root from the rump.
@export var tail_scale := 1.0
## Extra hair-GLB nodes to show (hat, hair tie); everything not mane/tail/LOD is hidden otherwise.
@export var accessories: Array[String] = []
@export var heart_colors: Array[Color] = [Color("ff5c8a"), Color("ff2f5f"), Color("ff86b0")]
@export var blush_color := Color(1.0, 0.42, 0.58)
## Horn magic aura. Alpha 0 = the canonical colour from world/characters/magic_colors.json
## (MLP Vector Club colour guide), else one derived from the iris (UnicornMagic.color_for).
@export var magic_color := Color(0.0, 0.0, 0.0, 0.0)
## Personality knobs (hybrid_attention.gd / hybrid_expressions.gd).
@export var notice_distance := 5.0
@export var close_distance := 1.8
@export var rest_smile := 1.0  # the default face (dev 2026-10-01): the closed smile at full
@export var interest_smile := 0.5
@export var ai_profile := "res://world/ai/characters/rainbow_dash.json"


## Explicit identity override, then the vector guide's named eyelid colour.
## Transparent means ordinary coat with a light expressive-lid tint, not makeup.
func eyeshadow() -> Color:
	if eyeshadow_color.a > 0.0: return eyeshadow_color
	if _eyelid_palette.is_empty():
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://world/characters/eyelid_colors.json"))
		_eyelid_palette = data.ponies
	if not _eyelid_palette.has(id): return Color.TRANSPARENT
	return Color(_eyelid_palette[id].color)


func has_wings() -> bool:
	return race in [Race.PEGASUS, Race.ALICORN]


func has_horn() -> bool:
	return race in [Race.UNICORN, Race.ALICORN]


## The character whose body and behaviour she has: character_id when a mod set one, else her id.
func character() -> String:
	return character_id if not character_id.is_empty() else id
