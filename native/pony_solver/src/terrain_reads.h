// Terrain heights and normals read straight from Terrain3D's region images (perf 2026-11-21, lane
// native_calls). WorldTerrain.height_at() / normal_at() (world/terrain/world_terrain.gd) through
// Terrain3D 1.0.2-stable's Terrain3DData::get_height() / get_normal() cost about 2 to 6 us a call,
// almost all of it Terrain3D's own per-pixel dictionary lookups, instance-binding locks and image
// method calls. This reads the same float pixels from the images' shared data with the same
// arithmetic (Terrain3DData::get_pixel, get_height, get_normal, is_hole, bilerp, copied from the
// 1.0.2-stable source), so the results are the same values on the same machine.
//
// One TerrainReads lives for one sampling call: regions are looked up when first touched (one
// get_region, is_deleted, get_region_id and two image reads per region) and their image data is
// held by reference (Godot's copy-on-write arrays: no copy, read only). Thread notes: everything it
// calls on Terrain3D is a read (its region dictionary, region flags, the images' data handles);
// reference counts are atomic. It is safe on a worker while the main thread only draws, as long as
// nothing loads, removes or edits regions meanwhile (WorldTerrain does that in _process, on the
// main thread, outside the draw).
//
// bind() refuses (returns false, and callers keep their old path) unless `terrain` runs the stock
// world/terrain/world_terrain.gd (a mod that replaces or extends it keeps its own height_at), its
// Terrain3D node answers vertex spacing and region size, and every region image it meets is
// FORMAT_RF at region size (otherwise that one read falls back to the script call).
#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace pony {

class TerrainReads {
public:
	// `terrain`: WorldTerrain.instance (or null). False: use the script calls instead.
	bool bind(godot::Object *p_terrain);
	// WorldTerrain.height_at(): NAN where there is no region (or no data) or a hole.
	double height_at(const godot::Vector3 &p_position);
	// WorldTerrain.normal_at(): Terrain3D's normal, or UP when it is not finite or too short.
	godot::Vector3 normal_at(const godot::Vector3 &p_position);
	// False after an image this could not read: the caller then asks the script for this column.
	bool usable() const { return ok; }

private:
	struct Region {
		godot::Vector2i loc;
		bool present = false; // in Terrain3D's region dictionary and not deleted
		int id = -1; // Terrain3DData::get_region_id()
		bool height_ok = false;
		bool control_ok = false;
		godot::PackedByteArray height; // FORMAT_RF, region_size squared floats, shared not copied
		godot::PackedByteArray control;
		const float *height_px = nullptr; // into `height`
		const float *control_px = nullptr; // into `control`
	};
	const Region &region(const godot::Vector2i &p_loc);
	godot::Vector2i region_location(const godot::Vector3 &p_position) const;
	// Terrain3DData::get_pixel(map, position).r; map 0 = height, 1 = control.
	float pixel(int p_map, const godot::Vector3 &p_position);
	uint32_t control(const godot::Vector3 &p_position);
	float height(const godot::Vector3 &p_position);
	godot::Vector3 normal(const godot::Vector3 &p_position);
	bool read_map(const godot::Variant &p_image, godot::PackedByteArray &r_data);

	bool ok = false;
	bool has_data = false;
	godot::Variant data; // Terrain3DData
	float spacing = 1.0f;
	int region_size = 0;
	std::vector<Region> regions;
	std::unordered_map<int64_t, size_t> index; // (x << 32) ^ y -> regions
	size_t last = 0;
};

} // namespace pony
