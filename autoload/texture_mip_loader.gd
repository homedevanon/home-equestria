extends ResourceFormatLoader
## Potato tiers: imported textures load with their top mip levels dropped (VRAM diet,
## dev 2026-09-29: "get it running on the most potato imaginable"). Registered in front of
## Godot's own .ctex loader by Settings when the stored tier has `texture_mip_drop` > 0; one
## dropped level quarters a texture's memory. Data textures (UI, anything under 256 px,
## textures without mipmaps, Basis Universal streams) fall through to the normal loader.
## Format: the CompressedTexture2D header (GST2) as written by the texture importer.
const MAGIC := "GST2"
const DATA_FORMAT_IMAGE := 0
const DATA_FORMAT_PNG := 1
const DATA_FORMAT_WEBP := 2
const SKIP_PATH_PARTS := ["/ui/", "/icons/", "/fonts/", "/aerial_map"]
var drop := 1
var min_edge := 256

func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["ctex"])

func _recognize_path(path: String, _type: StringName) -> bool:
	return path.get_extension() == "ctex"

func _handles_type(type: StringName) -> bool:
	return type in [&"Texture2D", &"CompressedTexture2D", &"Texture", &"Resource"]

func _get_resource_type(path: String) -> String:
	return "CompressedTexture2D" if path.get_extension() == "ctex" else ""

func _get_resource_script_class(_path: String) -> String:
	return ""

func _get_resource_uid(_path: String) -> int:
	return ResourceUID.INVALID_ID

func _get_dependencies(_path: String, _add_types: bool) -> PackedStringArray:
	return PackedStringArray()

func _rename_dependencies(_path: String, _renames: Dictionary) -> Error:
	return OK

func _exists(path: String) -> bool:
	return FileAccess.file_exists(path)

func _get_classes_used(_path: String) -> PackedStringArray:
	return PackedStringArray()

## Bytes of one mip level. Block formats pack 4x4 texels; the rest are bytes per texel.
static func level_bytes(w: int, h: int, format: int) -> int:
	var block := 0
	match format:
		Image.FORMAT_DXT1, Image.FORMAT_RGTC_R, Image.FORMAT_ETC, Image.FORMAT_ETC2_R11, Image.FORMAT_ETC2_R11S, Image.FORMAT_ETC2_RGB8, Image.FORMAT_ETC2_RGB8A1: block = 8
		Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGTC_RG, Image.FORMAT_BPTC_RGBA, Image.FORMAT_BPTC_RGBF, Image.FORMAT_BPTC_RGBFU, Image.FORMAT_ETC2_RG11, Image.FORMAT_ETC2_RG11S, Image.FORMAT_ETC2_RGBA8, Image.FORMAT_ETC2_RA_AS_RG, Image.FORMAT_DXT5_RA_AS_RG, Image.FORMAT_ASTC_4x4, Image.FORMAT_ASTC_4x4_HDR: block = 16
		Image.FORMAT_ASTC_8x8, Image.FORMAT_ASTC_8x8_HDR: return maxi(1, (w + 7) / 8) * maxi(1, (h + 7) / 8) * 16
	if block > 0: return maxi(1, (w + 3) / 4) * maxi(1, (h + 3) / 4) * block
	var bpp := 4
	match format:
		Image.FORMAT_L8, Image.FORMAT_R8: bpp = 1
		Image.FORMAT_LA8, Image.FORMAT_RG8, Image.FORMAT_RGBA4444, Image.FORMAT_RGB565, Image.FORMAT_RH: bpp = 2
		Image.FORMAT_RGB8: bpp = 3
		Image.FORMAT_RGBA8, Image.FORMAT_RF, Image.FORMAT_RGH, Image.FORMAT_RGBE9995: bpp = 4
		Image.FORMAT_RGBH: bpp = 6
		Image.FORMAT_RGF, Image.FORMAT_RGBAH: bpp = 8
		Image.FORMAT_RGBF: bpp = 12
		Image.FORMAT_RGBAF: bpp = 16
	return w * h * bpp

## Byte offset of mip `level` in a full chain, and the chain's total size (level = -1).
static func chain_offset(w: int, h: int, format: int, level: int) -> int:
	var total := 0; var i := 0
	while true:
		if i == level: return total
		total += level_bytes(w, h, format)
		if w == 1 and h == 1: break
		w = maxi(1, w >> 1); h = maxi(1, h >> 1); i += 1
	return total

## Null hands the file to Godot's own loader (full resolution).
func _load(path: String, original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	if drop <= 0: return null
	for part in SKIP_PATH_PARTS:
		if original_path.contains(part) or path.contains(part): return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return null
	if f.get_buffer(4).get_string_from_ascii() != MAGIC: return null
	f.get_32()  # version
	f.get_32(); f.get_32()  # custom width/height (unused: no size limit at import)
	f.get_32()  # flags
	f.get_32()  # mipmap limit
	f.get_32(); f.get_32(); f.get_32()  # reserved
	var data_format := int(f.get_32())
	var w := int(f.get_16()); var h := int(f.get_16())
	var mipmaps := int(f.get_32())
	var format := int(f.get_32()) as Image.Format
	if mipmaps <= 0 or w < min_edge or h < min_edge: return null
	var levels := mini(drop, mipmaps)
	var image: Image = null
	if data_format == DATA_FORMAT_IMAGE:
		var size := chain_offset(w, h, format, -1)
		# Only the kept levels are read: the dropped top level is about three quarters of the bytes.
		var offset := chain_offset(w, h, format, levels)
		f.seek(f.get_position() + offset)
		var data := f.get_buffer(size - offset)
		if data.size() != size - offset: return null
		var small_w := maxi(1, w >> levels); var small_h := maxi(1, h >> levels)
		image = Image.create_from_data(small_w, small_h, true, format, data)
	elif data_format == DATA_FORMAT_PNG or data_format == DATA_FORMAT_WEBP:
		for level in mipmaps + 1:
			var size := int(f.get_32())
			var bytes := f.get_buffer(size)
			if level != levels: continue
			image = Image.new()
			var err := image.load_png_from_buffer(bytes) if data_format == DATA_FORMAT_PNG else image.load_webp_from_buffer(bytes)
			if err != OK: return null
			image.generate_mipmaps()
			break
	else:
		return null
	if image == null or image.is_empty(): return null
	return ImageTexture.create_from_image(image)
