extends RefCounted
## The /mlp/ cup scarf on human Anon (dev 2026-11-11). One mesh in his neck bone's own space
## (tools/accessories/bake_4cc_scarf_anon.gd), so it follows the neck without skin weights.
## The pony fits live in world/characters/accessories/pony_fitted_accessories.gd.
const MESH_PATH := "res://world/customization/club_scarf_anon.res"
const FITTED := preload("res://world/characters/accessories/pony_fitted_accessories.gd")
const ITEM := "wear:4cc-scarf:0"
const NODE := "ClubScarf"
const BONE := "Neck"

static func apply(actor: Node, worn: bool) -> void:
	var skeleton := actor.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null: return
	var old := skeleton.get_node_or_null(NODE)
	if not worn:
		if old != null: old.free()
		return
	if old != null or skeleton.find_bone(BONE) < 0: return
	var attachment := BoneAttachment3D.new(); attachment.name = NODE
	attachment.bone_name = BONE
	skeleton.add_child(attachment)
	var piece := MeshInstance3D.new(); piece.name = "Scarf"
	piece.mesh = load(MESH_PATH)
	piece.material_override = FITTED.club_material()
	attachment.add_child(piece)
