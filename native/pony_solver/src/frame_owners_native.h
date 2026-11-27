// FrameOwnersNative (native pony port, lane frame, 2026-11-21): the per-frame work of small owners
// that are not pony walking, modifiers, links or navigation, done in C++ on plain engine calls.
//
// crowd_view_changes(): pony_crowd.gd's per-frame view test (its untrimmed _unprofiled_process loop)
// for every member, in member order, with the same reads, the same float operations and the same
// tests. It changes nothing: it returns the members whose state must change, index * 2 + 1 to hide
// and index * 2 to show, and the script applies them in that order. It returns [-1] (decline,
// nothing read past the first odd input) when the arrays do not line up or a member is not a Node3D,
// where the script loop would have stopped with an error; the script then runs its own loop.
// Main thread only; holds no state.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

class FrameOwnersNative : public RefCounted {
	GDCLASS(FrameOwnersNative, RefCounted)

protected:
	static void _bind_methods();

public:
	PackedInt32Array crowd_view_changes(Object *p_camera, bool p_xr, const Array &p_members, const Array &p_pivots,
			const PackedFloat32Array &p_radii) const;
};

} // namespace godot
