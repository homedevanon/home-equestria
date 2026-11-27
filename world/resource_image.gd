extends RefCounted
## Imported project images stay readable inside a PCK; user-painted files stay raw.
static func read(path:String)->Image:
	# A source run reads the raw file, except an image that only a mounted mod pack supplies: that one
	# exists as an imported texture only, as in an exported game.
	var imported_only:=not OS.has_feature("editor") or not FileAccess.file_exists(ProjectSettings.globalize_path(path))
	if path.begins_with("res://") and imported_only and ResourceLoader.exists(path):
		var texture:=load(path) as Texture2D
		if texture==null:return null
		var image:=texture.get_image()
		if image!=null and image.is_compressed():image.decompress()
		return image
	# Source runs read the raw file by absolute path: a res:// path warns "will not work on export".
	return Image.load_from_file(ProjectSettings.globalize_path(path) if OS.has_feature("editor") else path)


## A GPU texture for an image built at runtime (wallpaper, artwork, timber, terrain layers):
## mipmapped and S3TC-compressed so it costs a quarter of RGBA8 on the card (VRAM diet,
## dev 2026-09-29). Runs on the CPU in a few milliseconds per 1024 texture.
static func upload(image:Image)->ImageTexture:
	if image==null or image.is_empty():return null
	if image.is_compressed():return ImageTexture.create_from_image(image)
	if image.get_width()%4!=0 or image.get_height()%4!=0:
		image.resize(maxi(4,(image.get_width()+3)/4*4),maxi(4,(image.get_height()+3)/4*4),Image.INTERPOLATE_LANCZOS)
	if image.get_format()!=Image.FORMAT_RGBA8:image.convert(Image.FORMAT_RGBA8)
	if not image.has_mipmaps():image.generate_mipmaps()
	# Android templates ship no texture encoder at all (Quest): halve the edges instead, a
	# quarter of the raw bytes.
	if OS.has_feature("android"):
		if image.get_width()>=512 and image.get_height()>=512:
			image.resize(image.get_width()/2,image.get_height()/2,Image.INTERPOLATE_BILINEAR)
			image.generate_mipmaps()
		return ImageTexture.create_from_image(image)
	# Export templates have no BC encoder: the game's own native codec (PonyTextureCodec in
	# native/pony_solver) compresses there instead; the editor keeps Godot's encoder.
	if OS.has_feature("editor"):
		if image.compress(Image.COMPRESS_S3TC,Image.COMPRESS_SOURCE_GENERIC)!=OK:push_warning("[image] compression failed; uploading raw")
	elif ClassDB.class_exists("PonyTextureCodec"):
		var packed:Image=ClassDB.class_call_static("PonyTextureCodec","compress",image)
		if packed!=null:image=packed
	return ImageTexture.create_from_image(image)
