// FrameOwnersNative: see frame_owners_native.h.
#include "frame_owners_native.h"

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/plane.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

void FrameOwnersNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("crowd_view_changes", "camera", "xr", "members", "pivots", "radii"),
			&FrameOwnersNative::crowd_view_changes);
}

// pony_crowd.gd _unprofiled_process, the loop after the camera test:
//   center = pony.global_position + Vector3.UP * .7      (Vector3 * double: the double is cast to float)
//   xr:   draw = (center - camera.global_position).dot(-camera.global_basis.z) >= -radius
//   else: draw is false at the first frustum plane with plane.distance_to(center) > radius
//   if not draw and visual.visible: hide   elif draw and pony.has_meta(HIDDEN): show
// The camera is read once: nothing in the loop moves it (the script applies the changes after).
PackedInt32Array FrameOwnersNative::crowd_view_changes(Object *p_camera, bool p_xr, const Array &p_members,
		const Array &p_pivots, const PackedFloat32Array &p_radii) const {
	PackedInt32Array changes;
	PackedInt32Array decline;
	decline.push_back(-1);
	Camera3D *camera = Object::cast_to<Camera3D>(p_camera);
	const int64_t count = p_members.size();
	if (camera == nullptr || p_pivots.size() != count || p_radii.size() != count) {
		return decline;
	}
	static const StringName hidden_meta("crowd_hidden");
	const Vector3 up_offset = Vector3(0, 1, 0) * (real_t)0.7;
	Vector3 eye;
	Vector3 ahead;
	TypedArray<Plane> plane_array;
	Plane planes[16];
	int64_t plane_count = 0;
	if (p_xr) {
		eye = camera->get_global_position();
		ahead = -camera->get_global_basis().get_column(2);
	} else {
		plane_array = camera->get_frustum();
		plane_count = plane_array.size();
		if (plane_count > 16) {
			return decline;
		}
		for (int64_t i = 0; i < plane_count; i++) {
			planes[i] = plane_array[i];
		}
	}
	const float *radii = p_radii.ptr();
	for (int64_t index = 0; index < count; index++) {
		Object *pony_object = p_members[index].get_validated_object();
		if (pony_object == nullptr) {
			continue;
		}
		Node3D *pony = Object::cast_to<Node3D>(pony_object);
		if (pony == nullptr) {
			return decline;
		}
		if (!pony->is_inside_tree()) {
			continue;
		}
		const Vector3 center = pony->get_global_position() + up_offset;
		const float radius = radii[index];
		bool draw = true;
		if (p_xr) {
			draw = (center - eye).dot(ahead) >= -radius;
		} else {
			for (int64_t i = 0; i < plane_count; i++) {
				if (planes[i].distance_to(center) > radius) {
					draw = false;
					break;
				}
			}
		}
		Node3D *visual = Object::cast_to<Node3D>(p_pivots[index].get_validated_object());
		if (visual == nullptr) {
			continue;
		}
		if (!draw && visual->is_visible()) {
			changes.push_back(int32_t(index * 2 + 1));
		} else if (draw && pony->has_meta(hidden_meta)) {
			changes.push_back(int32_t(index * 2));
		}
	}
	return changes;
}

} // namespace godot
