extends RefCounted
## Where the player's mouth is, and where a thing carried in it sits
## (docs/ANONPONY_DESIGN_2026_10_01.md section 12.7). Human Anon keeps the fixed offsets from the
## eye that eating and the desktop hand always used; AnonPony uses her own muzzle
## (player/pony_form.gd), so food, drink and carried things meet the pony's mouth.
const PONY_FORM := preload("res://player/pony_form.gd")

## The point eating and drinking aim at.
static func point(camera: Node3D) -> Vector3:
	var form: Node = _form(camera)
	if form != null: return form.mouth_world()
	var k := human_scale(camera)
	return camera.global_position - camera.global_basis.y * .08 * k - camera.global_basis.z * .04 * k

## Where a carried thing sits: AnonPony holds it in her mouth, oriented to her view; human Anon
## at `human_local` relative to the camera.
static func hold_transform(camera: Node3D, human_local: Transform3D) -> Transform3D:
	var form: Node = _form(camera)
	if form != null: return form.hold_transform()
	return camera.global_transform * Transform3D(human_local.basis, human_local.origin * human_scale(camera))

## Human Anon's offsets from the eye were set for a 6 ft Anon; on desktop they follow his chosen
## height (Settings.anon_height_scale, dev 2026-11-03), and so does seated VR's rig (desktop_player.gd
## apply_height). Room-scale VR's eye is the player's own head, so it keeps them as they were.
static func human_scale(camera: Node3D) -> float:
	if camera == null: return 1.0
	if camera is XRCamera3D:
		var rig: Node = camera.get_parent()
		while rig != null and not rig.has_method("apply_height"): rig = rig.get_parent()
		if rig == null: return 1.0
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null and tree.root != null else null
	return float(settings.call("anon_height_scale")) if settings != null and settings.has_method("anon_height_scale") else 1.0

## The player's PonyForm while its avatar exists, else null (human, room-scale VR, scene change).
static func _form(camera: Node3D) -> Node:
	if not is_instance_valid(camera) or not camera.is_inside_tree(): return null
	var form: Node = PONY_FORM.find(camera.get_tree())
	if form == null or not is_instance_valid(form.get("avatar")): return null
	return form
