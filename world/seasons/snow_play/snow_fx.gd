extends RefCounted
## Shared look and sound for physical snow (W2-SEAS-F 2026-11-08, design 6.2 'Physical snow'):
## the Blender MCP props in world/props/seasons/ (art source art-source/
## seasons-snow-play-2026-11-08/snow_play.blend), one vertex-colour material for all of them, the
## 24-particle snow puff and the real snow recordings (world/audio/designed/environment/snow_*.ogg).
## Static and cached; nothing here runs per frame.
const SOUNDS := preload("res://world/audio/interaction_sounds.gd")
const ENVIRONMENT := preload("res://world/audio/environment_catalogue.gd")
const SNOWBALL_GLB := "res://world/props/seasons/snowball.glb"
const PARTS_GLB := "res://world/props/seasons/snowman_parts.glb"
const RAKE_GLB := "res://world/props/seasons/rake.glb"
const CARROT_GLB := "res://world/props/food/carrot.glb"
## Radius of the modelled hand snowball (snowball.glb); rolled balls are the same mesh scaled.
const MODEL_RADIUS := 0.065
const PUFF_PARTICLES := 24
## Sound cues registered once with the shared bounded mixer (real snow footstep recordings,
## pitched down for a heavier impact).
const EVENTS := {
	"snow_play_hit": {"streams": ENVIRONMENT.SNOW, "volume_db": -10.0, "distance": 16.0, "cooldown": 0.05, "pitch_min": 0.72, "pitch_max": 0.9},
	"snow_play_scoop": {"streams": ENVIRONMENT.SNOW, "volume_db": -17.0, "distance": 8.0, "cooldown": 0.12, "pitch_min": 1.05, "pitch_max": 1.25},
	"snow_play_roll": {"streams": ENVIRONMENT.SNOW, "volume_db": -20.0, "distance": 8.0, "cooldown": 0.3, "pitch_min": 0.8, "pitch_max": 0.95},
	"snow_play_burst": {"streams": ENVIRONMENT.SNOW, "volume_db": -8.0, "distance": 18.0, "cooldown": 0.1, "pitch_min": 0.6, "pitch_max": 0.75},
	# The rake through leaves: the real leaf footstep recordings, softer and slower.
	"snow_play_rake": {"streams": ENVIRONMENT.LEAVES, "volume_db": -16.0, "distance": 10.0, "cooldown": 0.25, "pitch_min": 0.85, "pitch_max": 1.0},
}

static var _meshes: Dictionary = {}      # node name -> [Mesh, Transform3D]
static var _material: StandardMaterial3D
static var _puff_process: ParticleProcessMaterial
static var _puff_mesh: QuadMesh
static var _registered: WeakRef

## The mesh named `part` in one of the prop GLBs ("Snowball_LOD0", "Snowball_LOD1", "Coal",
## "StickArm", "Scarf", "Rake", "Carrot") with its node transform, or [null, IDENTITY].
static func part(name: String) -> Array:
	if _meshes.has(name): return _meshes[name]
	var file := SNOWBALL_GLB if name.begins_with("Snowball") else RAKE_GLB if name == "Rake" else CARROT_GLB if name == "Carrot" else PARTS_GLB
	if ResourceLoader.exists(file):
		var scene: Variant = load(file)
		if scene is PackedScene:
			var root: Node = (scene as PackedScene).instantiate()
			for node: Node in root.find_children("*", "MeshInstance3D", true, false):
				var mesh_node := node as MeshInstance3D
				# The food carrot's orange root is "edible_carrot" (its greens are separate meshes).
				var key := "Carrot" if file == CARROT_GLB and str(mesh_node.name) == "edible_carrot" else str(mesh_node.name)
				if not _meshes.has(key): _meshes[key] = [mesh_node.mesh, _relative(mesh_node, root), _srgb(mesh_node)]
			root.free()
	if not _meshes.has(name): _meshes[name] = [null, Transform3D.IDENTITY, false]
	return _meshes[name]

## Whether the imported part's own material reads its vertex colours as sRGB.
static func _srgb(node: MeshInstance3D) -> bool:
	var m: Material = node.material_override
	if m == null and node.mesh != null and node.mesh.get_surface_count() > 0: m = node.mesh.surface_get_material(0)
	return m is BaseMaterial3D and (m as BaseMaterial3D).vertex_color_is_srgb

static func _relative(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var at: Node = node
	while at != null and at != root:
		if at is Node3D: xf = (at as Node3D).transform * xf
		at = at.get_parent()
	return xf

static func mesh(name: String) -> Mesh:
	return part(name)[0] as Mesh

## One shared material: the props carry their colours as vertex colours (one draw per object).
static func material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		# Read the colours the way the snowball's own imported material does.
		_material.vertex_color_is_srgb = bool(part("Snowball_LOD0")[2])
		_material.roughness = 0.85
	return _material

## A MeshInstance3D of a prop part with the shared material.
static func instance(name: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var found := part(name)
	node.mesh = found[0] as Mesh
	node.transform = found[1]
	node.material_override = material()
	return node

## Merges pieces [[part name, Transform3D, Color tint], ...] into one single-surface ArrayMesh
## (positions, normals, colours), so a whole snowman is one draw.
static func merge(pieces: Array) -> ArrayMesh:
	var verts := PackedVector3Array(); var normals := PackedVector3Array(); var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for piece: Array in pieces:
		var found := part(str(piece[0]))
		var source := found[0] as Mesh
		if source == null or source.get_surface_count() == 0: continue
		var xf: Transform3D = (piece[1] as Transform3D) * (found[1] as Transform3D)
		var tint: Color = piece[2] if piece.size() > 2 and piece[2] is Color else Color.WHITE
		# A part stored the other way (the food carrot keeps sRGB colours) is converted.
		var convert := bool(found[2]) != material().vertex_color_is_srgb
		var to_linear := bool(found[2])
		var basis_n := xf.basis.inverse().transposed()
		for surface in source.get_surface_count():
			var arrays: Array = source.surface_get_arrays(surface)
			var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var sn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var sc: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			# A part without vertex colours (the food carrot) takes its material's albedo.
			var plain := Color.WHITE
			var own: Material = source.surface_get_material(surface)
			if sc.is_empty() and own is BaseMaterial3D:
				plain = (own as BaseMaterial3D).albedo_color
				if not material().vertex_color_is_srgb: plain = plain.srgb_to_linear()
			var si: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var base := verts.size()
			for i in sv.size():
				verts.append(xf * sv[i])
				normals.append((basis_n * sn[i]).normalized() if i < sn.size() else Vector3.UP)
				var c: Color = sc[i] if i < sc.size() else plain
				if convert and i < sc.size(): c = c.srgb_to_linear() if to_linear else c.linear_to_srgb()
				colors.append(c * tint)
			if si.is_empty():
				for i in sv.size(): indices.append(base + i)
			else:
				for index in si: indices.append(base + index)
	var out := ArrayMesh.new()
	if verts.is_empty(): return out
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors; arrays[Mesh.ARRAY_INDEX] = indices
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	out.surface_set_material(0, material())
	return out

static func _register(source: Node) -> void:
	var tree := source.get_tree()
	var root: Node = tree.root.get_node_or_null("InteractionSounds") if tree != null else null
	if root != null and _registered != null and _registered.get_ref() == root: return
	SOUNDS.register_catalogue(source, EVENTS)
	root = tree.root.get_node_or_null("InteractionSounds") if tree != null else null
	_registered = weakref(root) if root != null else null

## A real snow recording at `at` (cue from EVENTS).
static func sound(source: Node3D, cue: String, at: Vector3) -> void:
	if not is_instance_valid(source) or not source.is_inside_tree(): return
	_register(source)
	SOUNDS.play_at(source, cue, at)

## A one-shot puff of PUFF_PARTICLES snow particles (fewer with reduced seasonal effects, none
## when they are off); frees itself.
static func puff(host: Node, at: Vector3, size := 1.0, level := 2) -> void:
	if level <= 0 or not is_instance_valid(host) or not host.is_inside_tree() or not at.is_finite(): return
	if _puff_process == null:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3.UP; pm.spread = 75.0
		pm.initial_velocity_min = 0.6; pm.initial_velocity_max = 1.8
		pm.gravity = Vector3(0, -4.0, 0); pm.damping_min = 1.5; pm.damping_max = 3.0
		pm.scale_min = 0.6; pm.scale_max = 1.4
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE; pm.emission_sphere_radius = 0.05
		var fade := Gradient.new(); fade.set_color(0, Color(1, 1, 1, 0.95)); fade.set_color(1, Color(1, 1, 1, 0))
		var ramp := GradientTexture1D.new(); ramp.gradient = fade
		pm.color_ramp = ramp
		_puff_process = pm
		var quad := QuadMesh.new(); quad.size = Vector2(0.07, 0.07)
		var sm := StandardMaterial3D.new()
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.vertex_color_use_as_albedo = true
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		var dot := GradientTexture2D.new(); dot.fill = GradientTexture2D.FILL_RADIAL
		dot.fill_from = Vector2(0.5, 0.5); dot.fill_to = Vector2(1.0, 0.5)
		var g := Gradient.new(); g.set_color(0, Color(0.95, 0.97, 1.0, 1)); g.set_color(1, Color(0.95, 0.97, 1.0, 0)); dot.gradient = g
		sm.albedo_texture = dot
		quad.material = sm
		_puff_mesh = quad
	var p := GPUParticles3D.new()
	p.name = "SnowPuff"
	p.amount = PUFF_PARTICLES if level >= 2 else PUFF_PARTICLES / 2
	p.lifetime = 0.9; p.one_shot = true; p.explosiveness = 1.0
	p.process_material = _puff_process; p.draw_pass_1 = _puff_mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	p.scale = Vector3.ONE * clampf(size, 0.5, 4.0)
	host.add_child(p)
	p.global_position = at
	p.emitting = true
	host.get_tree().create_timer(1.6, false).timeout.connect(p.queue_free)
