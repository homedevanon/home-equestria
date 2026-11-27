// See terrain_reads.h. Each function names the Terrain3D 1.0.2-stable code it repeats; the
// expressions keep its order and types (real_t is float), so the floats come out the same.
#include "terrain_reads.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cmath>
#include <cstring>

using namespace godot;

namespace pony {

namespace {

struct Names {
	const StringName terrain = StringName("terrain");
	const StringName data = StringName("data");
	const StringName get_vertex_spacing = StringName("get_vertex_spacing");
	const StringName get_region_size = StringName("get_region_size");
	const StringName get_region = StringName("get_region");
	const StringName get_region_id = StringName("get_region_id");
	const StringName is_deleted = StringName("is_deleted");
	const StringName get_height_map = StringName("get_height_map");
	const StringName get_control_map = StringName("get_control_map");
	const String stock_script = String("res://world/terrain/world_terrain.gd");
};

const Names &names() {
	static const Names n;
	return n;
}

const Vector3 UP(0, 1, 0);

// terrain_3d_util.h
inline uint32_t as_uint(const float p_value) {
	uint32_t bits;
	std::memcpy(&bits, &p_value, sizeof(bits));
	return bits;
}

inline bool is_hole(const uint32_t p_pixel) {
	return (p_pixel >> 2 & 0x1) == 1;
}

inline real_t bilerp(const real_t p_v00, const real_t p_v01, const real_t p_v10, const real_t p_v11,
		const Vector2 &p_pos00, const Vector2 &p_pos11, const Vector2 &p_pos) {
	real_t x2x1 = p_pos11.x - p_pos00.x;
	real_t y2y1 = p_pos11.y - p_pos00.y;
	real_t x2x = p_pos11.x - p_pos.x;
	real_t y2y = p_pos11.y - p_pos.y;
	real_t xx1 = p_pos.x - p_pos00.x;
	real_t yy1 = p_pos.y - p_pos00.y;
	return (p_v00 * x2x * y2y +
				   p_v01 * x2x * yy1 +
				   p_v10 * xx1 * y2y +
				   p_v11 * xx1 * yy1) /
			(x2x1 * y2y1);
}

inline real_t bilerp(const real_t p_v00, const real_t p_v01, const real_t p_v10, const real_t p_v11,
		const Vector3 &p_pos00, const Vector3 &p_pos11, const Vector3 &p_pos) {
	Vector2 pos00 = Vector2(p_pos00.x, p_pos00.z);
	Vector2 pos11 = Vector2(p_pos11.x, p_pos11.z);
	Vector2 pos = Vector2(p_pos.x, p_pos.z);
	return bilerp(p_v00, p_v01, p_v10, p_v11, pos00, pos11, pos);
}

} // namespace

bool TerrainReads::bind(Object *p_terrain) {
	ok = false;
	has_data = false;
	data = Variant();
	regions.clear();
	index.clear();
	last = 0;
	if (p_terrain == nullptr) {
		return false;
	}
	const Names &n = names();
	Resource *script = Object::cast_to<Resource>(static_cast<Object *>(p_terrain->get_script()));
	if (script == nullptr || script->get_path() != n.stock_script) {
		return false;
	}
	Object *terrain = p_terrain->get(n.terrain);
	if (terrain == nullptr) {
		return false;
	}
	data = terrain->get(n.data);
	has_data = data.get_type() == Variant::OBJECT && static_cast<Object *>(data) != nullptr;
	spacing = float(double(terrain->call(n.get_vertex_spacing)));
	region_size = int(int64_t(terrain->call(n.get_region_size)));
	ok = region_size > 0 && spacing > 0.0f && std::isfinite(spacing);
	return ok;
}

bool TerrainReads::read_map(const Variant &p_image, PackedByteArray &r_data) {
	Image *image = p_image.get_type() == Variant::OBJECT ? Object::cast_to<Image>(static_cast<Object *>(p_image)) : nullptr;
	if (image == nullptr) {
		return true; // no map: Terrain3D reads COLOR_NAN, as does pixel() with empty data
	}
	if (image->get_format() != Image::FORMAT_RF || image->get_width() != region_size || image->get_height() != region_size) {
		ok = false;
		return false;
	}
	r_data = image->get_data(); // shares the image's buffer (copy on write), no copy
	if (r_data.size() < int64_t(region_size) * region_size * int64_t(sizeof(float))) {
		r_data = PackedByteArray();
		ok = false;
		return false;
	}
	return true;
}

const TerrainReads::Region &TerrainReads::region(const Vector2i &p_loc) {
	if (last < regions.size() && regions[last].loc == p_loc) {
		return regions[last];
	}
	const int64_t key = (int64_t(p_loc.x) << 32) ^ int64_t(uint32_t(p_loc.y));
	const auto found = index.find(key);
	if (found != index.end()) {
		last = found->second;
		return regions[last];
	}
	const Names &n = names();
	Region r;
	r.loc = p_loc;
	// Terrain3DData::get_region_ptr(): in the region dictionary; get_pixel(): and not deleted.
	Variant region = data.call(n.get_region, p_loc);
	if (region.get_type() == Variant::OBJECT && static_cast<Object *>(region) != nullptr) {
		r.present = !bool(region.call(n.is_deleted));
		if (r.present) {
			r.height_ok = read_map(region.call(n.get_height_map), r.height);
			r.control_ok = read_map(region.call(n.get_control_map), r.control);
			// Raw pointers into the held arrays (valid while `r.height` / `r.control` live).
			r.height_px = r.height.is_empty() ? nullptr : reinterpret_cast<const float *>(r.height.ptr());
			r.control_px = r.control.is_empty() ? nullptr : reinterpret_cast<const float *>(r.control.ptr());
		}
	}
	r.id = int(int64_t(data.call(n.get_region_id, p_loc)));
	last = regions.size();
	index.emplace(key, last);
	regions.push_back(std::move(r));
	return regions[last];
}

// Terrain3DData::get_region_location()
Vector2i TerrainReads::region_location(const Vector3 &p_position) const {
	Vector2 descaled_position = Vector2(p_position.x, p_position.z) / spacing;
	return Vector2i((descaled_position / real_t(region_size)).floor());
}

// Terrain3DData::get_pixel(map, position).r, Image::get_pixelv() on FORMAT_RF.
float TerrainReads::pixel(int p_map, const Vector3 &p_position) {
	const Vector2i region_loc = region_location(p_position);
	const Region &r = region(region_loc);
	const float *map = p_map == 0 ? r.height_px : r.control_px;
	if (!r.present || map == nullptr) {
		return NAN;
	}
	Vector2i global_offset = region_loc * region_size;
	Vector3 descaled_pos = p_position / spacing;
	Vector2i img_pos = Vector2i(descaled_pos.x - global_offset.x, descaled_pos.z - global_offset.y);
	img_pos = img_pos.clamp(Vector2i(0, 0), Vector2i(region_size - 1, region_size - 1));
	const uint32_t ofs = uint32_t(img_pos.y * region_size + img_pos.x);
	return map[ofs];
}

// Terrain3DData::get_control()
uint32_t TerrainReads::control(const Vector3 &p_position) {
	const float val = pixel(1, p_position);
	return std::isnan(val) ? UINT32_MAX : as_uint(val);
}

// Terrain3DData::get_height()
float TerrainReads::height(const Vector3 &p_global_position) {
	if (is_hole(control(p_global_position))) {
		return NAN;
	}
	Vector3 pos = p_global_position;
	const real_t &step = spacing;
	pos.y = 0.f;
	// Round to nearest vertex
	Vector3 pos_round = pos.snapped(Vector3(step, 0.f, step));
	// If requested position is close to a vertex, return its height
	if ((pos - pos_round).length_squared() < 0.0001f) {
		return pixel(0, pos);
	} else {
		// Otherwise, bilinearly interpolate 4 surrounding vertices
		Vector3 pos00 = Vector3(std::floor(pos.x / step) * step, 0.f, std::floor(pos.z / step) * step);
		real_t ht00 = pixel(0, pos00);
		Vector3 pos01 = pos00 + Vector3(0.f, 0.f, step);
		real_t ht01 = pixel(0, pos01);
		Vector3 pos10 = pos00 + Vector3(step, 0.f, 0.f);
		real_t ht10 = pixel(0, pos10);
		Vector3 pos11 = pos00 + Vector3(step, 0.f, step);
		real_t ht11 = pixel(0, pos11);
		return bilerp(ht00, ht01, ht10, ht11, pos00, pos11, pos);
	}
}

// Terrain3DData::get_normal()
Vector3 TerrainReads::normal(const Vector3 &p_global_position) {
	if (region(region_location(p_global_position)).id < 0 || is_hole(control(p_global_position))) {
		return Vector3(NAN, NAN, NAN);
	}
	real_t h = height(p_global_position);
	real_t u = h - height(p_global_position + Vector3(spacing, 0.0f, 0.0f));
	real_t v = h - height(p_global_position + Vector3(0.f, 0.f, spacing));
	Vector3 normal = Vector3(u, spacing, v);
	normal.normalize();
	return normal;
}

// world_terrain.gd height_at()
double TerrainReads::height_at(const Vector3 &p_position) {
	if (!has_data) {
		return NAN;
	}
	return double(height(p_position));
}

// world_terrain.gd normal_at()
Vector3 TerrainReads::normal_at(const Vector3 &p_position) {
	if (!has_data) {
		return UP;
	}
	const Vector3 n = normal(p_position);
	return n.is_finite() && double(n.length_squared()) > 0.5 ? n : UP;
}

} // namespace pony
