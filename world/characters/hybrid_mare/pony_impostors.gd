extends Node
## Far pony impostors (dev 2026-10-23: "impostor ponies from 100m away" ... "80m on very low, 100 on
## low, 120m on medium, 150 on high, 250 on ultra and have an unlimited"; "swapping between a
## midwalk frame and a stand frame"). Past the impostor distance a FAR-tier pony shows one
## camera-facing quad (pony_impostor.gdshader, 2 triangles, 1 draw) instead of her far mesh.
##
## The atlas is baked once per identity, after her far mesh exists (hybrid_far_mesh.gd): a copy of
## her skeleton posed from her own baked "stand" clip and the "walk" clip a quarter in (mid-stride),
## photographed from FRAMES sides in an isolated world, one camera shot per frame, a pony at a time.
## Lit flat from the front so the scene's own light shades the quad, as it shades everything else.
## Distance: Settings "video/pony_impostors" ("preset" = the quality tier's pony_impostor_from;
## 0 = never).
const FRAMES := 8
const CELL := 96
const PITCH := deg_to_rad(-8.0)
const SHADER := preload("res://world/characters/hybrid_mare/pony_impostor.gdshader")
const FAR_MESH := preload("res://world/characters/hybrid_mare/hybrid_far_mesh.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const NAME := "PonyImpostors"

static var atlases: Dictionary = {}   # identity id -> {"material": ShaderMaterial, "size": Vector2, "foot": float}
static var _quad: ArrayMesh
var _queue: Array = []                # weakrefs to ponies waiting for their identity's atlas
var _queued: Dictionary = {}          # identity id -> true while queued or baking
var _busy := false

## The node that bakes atlases; created under the tree root on first use.
static func bank(tree: SceneTree) -> Node:
	var found := tree.root.get_node_or_null(NAME)
	if found == null:
		found = (load("res://world/characters/hybrid_mare/pony_impostors.gd") as GDScript).new()
		found.name = NAME
		tree.root.add_child(found)
	return found

## Impostor hand-over distance in metres; 0 when impostors are off ("Unlimited").
static func distance() -> float:
	var settings: Node = Engine.get_main_loop().root.get_node_or_null("Settings") if Engine.get_main_loop() is SceneTree else null
	var chosen: Variant = settings.get_value("video/pony_impostors") if settings != null else "preset"
	if str(chosen) == "preset" or chosen == null:
		var quality: Node = Engine.get_main_loop().root.get_node_or_null("Quality")
		return float(quality.get_value("pony_impostor_from", 150.0)) if quality != null else 150.0
	return float(chosen)

static func quad() -> ArrayMesh:
	if _quad != null: return _quad
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(-0.5, 0.0), Vector2(0.5, 0.0), Vector2(0.5, 1.0), Vector2(-0.5, 0.0), Vector2(0.5, 1.0), Vector2(-0.5, 1.0)]
	for c: Vector2 in corners:
		st.set_uv(Vector2(c.x + 0.5, 1.0 - c.y)); st.set_normal(Vector3.BACK)
		st.add_vertex(Vector3(c.x, c.y, 0.0))
	_quad = st.commit()
	# The shader turns and places the quad; give culling a box she always fits in.
	_quad.custom_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 5, 6))
	return _quad

## The identity's atlas entry, or {} while it is being baked (queues the bake).
func atlas_for(pony: Node3D) -> Dictionary:
	var id := FAR_MESH._id(pony)
	if atlases.has(id): return atlases[id]
	if not _queued.has(id) and FAR_MESH.cached(pony) != null:
		_queued[id] = true
		_queue.append(weakref(pony))
		if not _busy: _bake_next()
	return {}

func _bake_next() -> void:
	_busy = true
	while not _queue.is_empty():
		var pony: Node3D = (_queue.pop_front() as WeakRef).get_ref()
		if not is_instance_valid(pony) or not pony.is_inside_tree(): continue
		var id := FAR_MESH._id(pony)
		var entry := await _bake(pony)
		if not is_inside_tree(): return
		if not entry.is_empty(): atlases[id] = entry
		_queued.erase(id)
	_busy = false

func _bake(pony: Node3D) -> Dictionary:
	var mesh: ArrayMesh = FAR_MESH.cached(pony)
	var source: Skeleton3D = pony.get("skeleton")
	var model: Node3D = pony.get("_model")
	var library: AnimationLibrary = pony.get("_baked")
	if mesh == null or source == null or model == null or library == null: return {}
	var body: MeshInstance3D = model.find_child("MareBody", true, false)
	if body == null or not library.has_animation("stand"): return {}
	var hitch_label := "impostor bake " + FAR_MESH._id(pony)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(CELL, CELL)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var world := Node3D.new(); viewport.add_child(world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new(); we.environment = environment; world.add_child(we)
	var light := DirectionalLight3D.new(); light.light_energy = 0.7; world.add_child(light)
	var skeleton := Skeleton3D.new()
	for bone in source.get_bone_count():
		skeleton.add_bone(source.get_bone_name(bone))
	for bone in source.get_bone_count():
		skeleton.set_bone_parent(bone, source.get_bone_parent(bone))
		skeleton.set_bone_rest(bone, source.get_bone_rest(bone))
	world.add_child(skeleton)
	var view := MeshInstance3D.new()
	view.mesh = mesh; view.skin = body.skin
	skeleton.add_child(view); view.skeleton = view.get_path_to(skeleton)
	var eyes_mesh: ArrayMesh = FAR_MESH.eyes_cache.get(FAR_MESH._id(pony))
	if eyes_mesh != null and eyes_mesh.get_surface_count() > 0:
		var eyes := MeshInstance3D.new(); eyes.mesh = eyes_mesh; eyes.skin = body.skin
		skeleton.add_child(eyes); eyes.skeleton = eyes.get_path_to(skeleton)
		eyes.set_instance_shader_parameter("brow_amount", 0.0)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	world.add_child(camera)
	add_child(viewport)
	# The skeleton's place under her model: its frame relative to her root.
	skeleton.transform = pony.global_transform.affine_inverse() * source.global_transform
	var poses := [["stand", 0.0], ["walk" if library.has_animation("walk") else "stand", 0.25]]
	var bounds := AABB()
	# Frame both poses with one box so the stand and stride frames line up.
	for p: Array in poses:
		_pose(skeleton, library.get_animation(p[0]), float(p[1]))
		var box := skeleton.transform * _posed_bounds(skeleton, mesh)
		bounds = box if bounds.size == Vector3.ZERO else bounds.merge(box)
	var height := bounds.size.y * 1.08
	var width := maxf(bounds.size.x, bounds.size.z) * 1.08
	var side := maxf(height, width)
	camera.size = side
	var centre := bounds.get_center()
	var image := Image.create(CELL * FRAMES, CELL * 2, false, Image.FORMAT_RGBA8)
	# Shots read back asynchronously (thread 43671981 D1): a synchronous get_image() waits for the
	# GPU to finish every frame in flight, and 16 of them per identity were the ~10 s of 70-200 ms
	# frames after loading (tools/profile/play_bench.gd --post-load). Each shot's pixels arrive a
	# few frames later into `shots`; get_image() remains the fallback where async readback is not
	# available (no RenderingDevice, unexpected format).
	var shots: Array = []        # per shot: [cell, Image or null]; Image null until it arrives
	var outstanding: Array = [0] # async readbacks still in flight (shared with the callbacks)
	for row in poses.size():
		_pose(skeleton, library.get_animation(poses[row][0]), float(poses[row][1]))
		for k in FRAMES:
			var angle := TAU * k / FRAMES
			var direction := Vector3(-sin(angle), 0.0, -cos(angle))
			var eye := centre + direction * 20.0 + Vector3.UP * 20.0 * tan(-PITCH)
			camera.look_at_from_position(eye, centre, Vector3.UP)
			light.global_transform = camera.global_transform
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			preload("res://world/debug/hitch_monitor.gd").mark(hitch_label)
			# Read back a frame later: the shot from this frame's update is not always ready.
			if not await SHUTDOWN.rendered_frame(self) or not await SHUTDOWN.rendered_frame(self) \
					or not is_instance_valid(viewport):
				if is_instance_valid(viewport): viewport.queue_free()
				return {}
			var entry := [Vector2i(k * CELL, row * CELL), null]
			shots.append(entry)
			if not _read_async(viewport, entry, outstanding):
				entry[1] = viewport.get_texture().get_image()
	# The copy for each request runs before the next shot renders over the target; the data comes
	# back once that frame has finished on the GPU (frame queue size frames later).
	var waited := 0
	while outstanding[0] > 0 and waited < 30:
		if not await SHUTDOWN.rendered_frame(self):
			viewport.queue_free()
			return {}
		waited += 1
	for entry: Array in shots:
		var shot: Image = entry[1]
		if shot == null or shot.is_empty(): continue
		shot.convert(Image.FORMAT_RGBA8)
		image.blit_rect(shot, Rect2i(Vector2i.ZERO, Vector2i(CELL, CELL)), entry[0])
	viewport.queue_free()
	image.fix_alpha_edges()
	image.generate_mipmaps()
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("atlas", ImageTexture.create_from_image(image))
	material.set_shader_parameter("frames", float(FRAMES))
	# The camera frames a side x side square around the box centre; the quad matches it.
	var foot := centre.y - side * 0.5
	material.set_shader_parameter("size", Vector2(side, side))
	material.set_shader_parameter("foot", foot)
	return {"material": material, "size": Vector2(side, side), "foot": foot}

## Starts an asynchronous readback of the viewport into entry[1]; false when the renderer cannot
## (the caller reads synchronously instead). Callbacks run on the main thread (the game renders
## there, quality.gd).
static func _read_async(viewport: SubViewport, entry: Array, outstanding: Array) -> bool:
	var device := RenderingServer.get_rendering_device()
	if device == null or not device.has_method("texture_get_data_async"): return false
	var texture := RenderingServer.texture_get_rd_texture(viewport.get_texture().get_rid())
	if not texture.is_valid() or not device.texture_is_valid(texture): return false
	var format: RDTextureFormat = device.texture_get_format(texture)
	if format == null or format.format not in [RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB]: return false
	var width := int(format.width)
	var height := int(format.height)
	var error: Error = device.texture_get_data_async(texture, 0, func(data: PackedByteArray) -> void:
		if data.size() == width * height * 4:
			entry[1] = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
		outstanding[0] = int(outstanding[0]) - 1)
	if error != OK: return false
	outstanding[0] = int(outstanding[0]) + 1
	return true

## Bone poses from one baked clip at `fraction` of its length (rotation/position/scale tracks
## addressed "<path>:<bone>").
static func _pose(skeleton: Skeleton3D, clip: Animation, fraction: float) -> void:
	if clip == null: return
	skeleton.reset_bone_poses()
	var time := clip.length * fraction
	for track in clip.get_track_count():
		var bone := skeleton.find_bone(String(clip.track_get_path(track).get_concatenated_subnames()))
		if bone < 0: continue
		match clip.track_get_type(track):
			Animation.TYPE_ROTATION_3D: skeleton.set_bone_pose_rotation(bone, clip.rotation_track_interpolate(track, time))
			Animation.TYPE_POSITION_3D: skeleton.set_bone_pose_position(bone, clip.position_track_interpolate(track, time))
			Animation.TYPE_SCALE_3D: skeleton.set_bone_pose_scale(bone, clip.scale_track_interpolate(track, time))
	skeleton.force_update_all_bone_transforms()

## The mesh's bind-space box carried through every bone's pose (cheap, generous).
static func _posed_bounds(skeleton: Skeleton3D, mesh: Mesh) -> AABB:
	var box := AABB()
	var first := true
	for bone in skeleton.get_bone_count():
		var at := skeleton.get_bone_global_pose(bone).origin
		if first: box = AABB(at, Vector3.ZERO); first = false
		else: box = box.expand(at)
	var bind := mesh.get_aabb()
	# Bones run through the middle of the body; widen by the mesh's own half thickness.
	return box.grow(minf(bind.size.x, bind.size.y) * 0.18)
