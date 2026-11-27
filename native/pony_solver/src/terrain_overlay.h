#pragma once

#include <godot_cpp/classes/image.hpp>

namespace godot {

class PonyTerrainOverlay : public RefCounted {
	GDCLASS(PonyTerrainOverlay, RefCounted)

protected:
	static void _bind_methods();

public:
	// Copy covered RF samples. For heights, reject non-finite samples and union the
	// mask into painted. Returns zero for the script fallback, else threads used.
	static int apply(const Ref<Image> &map, const PackedByteArray &source, const Ref<Image> &mask,
			const Rect2i &bounds, const Ref<Image> &painted);
};

} // namespace godot
