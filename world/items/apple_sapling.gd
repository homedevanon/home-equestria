extends RefCounted
## An apple sapling from Applejack's farm stall (P5 of docs/MECHANICS_ARCHITECTURE_2026_11_01.md,
## 8.1). Plant it in Anon's row at Sweet Apple Acres (world/mechanics/stations/planting_plot.gd),
## water it on three days and it grows into a real orchard tree that joins the apple harvest.
## Tagged plant/plantable (world/inventory/item_tags.json), so it is also a gift (Applejack likes
## plantable things), sellable and something a pony can ask for.
## Identity and looks only: no preloads, so the item catalogue can load it safely. The look reuses
## an orchard tree species (world/foliage/grassy_catalogue.gd, the same meshes the orchard uses)
## at sapling size, standing in the fishing bucket as its pot. No new geometry.
const ID := "goods:apple-sapling"
const PRICE := 15
const STACK := 4
const BUCKET := "res://world/props/household/fishing-bucket.scn"
const FARM := "res://world/props/ponyville/farm_dressing.gd"
const CATALOGUE := "res://world/foliage/grassy_catalogue.gd"
## The pot: the 0.36 m fishing bucket at this scale (about 0.19 m tall).
const POT_SCALE := 0.6
const POT_SOIL := 0.16
## `scale` in build_visual is a fraction of a 5 m orchard tree, whatever the species' own size
## (0.12 = a 0.6 m sapling, 0.3 = a 1.5 m young tree).
const REFERENCE_HEIGHT := 5.0

static func is_sapling(id: String) -> bool:
	return id == ID

static func definition(id: String) -> Dictionary:
	if not is_sapling(id): return {}
	return {"name": "Apple sapling", "description": "Plant it in Anon's row at Sweet Apple Acres; water it on three days and it grows into an apple tree.",
		"stack": STACK, "price_bits": PRICE, "size_m": 0.6, "shop": true}

## The orchard species a tree id grows as (deterministic, so a sapling and its grown tree match).
static func species(seed_text: String) -> Dictionary:
	var trees: Array = (load(CATALOGUE) as Script).call("trees")
	if trees.is_empty(): return {}
	return trees[absi(hash(seed_text)) % trees.size()]

## Adds the sapling's look under `parent`: the species mesh `scale` x REFERENCE_HEIGHT tall (0.12
## is a 0.6 m sapling), its trunk base at y = 0, standing in its pot when `potted`. Returns the
## local bounds (base at y = 0) the inventory uses for collision.
static func build_visual(parent: Node3D, scale := 0.12, potted := true, seed_text := ID) -> AABB:
	var bounds := AABB(Vector3(-0.12, 0.0, -0.12), Vector3(0.24, 0.6, 0.24))
	var lift := 0.0
	if potted:
		var bucket: Node3D = (load(BUCKET) as PackedScene).instantiate()
		bucket.name = "Pot"
		bucket.scale = Vector3.ONE * POT_SCALE
		for body: CollisionObject3D in bucket.find_children("*", "CollisionObject3D", true, false):
			body.collision_layer = 0; body.collision_mask = 0
		parent.add_child(bucket)
		lift = POT_SOIL * POT_SCALE
	var entry := species(seed_text)
	var kind: Dictionary = (load(FARM) as Script).call("_species", entry) if not entry.is_empty() else {}
	if kind.has("mesh") and (kind.box as AABB).size.y > 0.01:
		scale = scale * REFERENCE_HEIGHT / (kind.box as AABB).size.y
		var tree := MeshInstance3D.new()
		tree.name = "Sapling"
		tree.mesh = kind.mesh
		var offset: Vector3 = (load(CATALOGUE) as Script).call("contact_offset", entry)
		tree.transform = Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3.UP * lift + offset * scale) * (kind.local as Transform3D)
		tree.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if (kind.box as AABB).size.y * scale < 1.0 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		parent.add_child(tree)
		var box: AABB = kind.box
		var size := box.size * scale
		bounds = AABB(Vector3(-maxf(size.x, 0.24) * 0.5, 0.0, -maxf(size.z, 0.24) * 0.5), Vector3(maxf(size.x, 0.24), size.y + lift, maxf(size.z, 0.24)))
		if potted:
			# In the hand only the pot collides: a sapling crown is not a solid box.
			bounds = AABB(Vector3(-0.12, 0.0, -0.12), Vector3(0.24, maxf(0.3, minf(size.y + lift, 0.7)), 0.24))
	return bounds
