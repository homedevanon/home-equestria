#include "terrain_overlay.h"

#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <array>
#include <cstring>
#include <thread>

using namespace godot;

namespace {
constexpr int MAX_BLOCKS = 16;

struct Block {
	std::thread::id thread;
	bool valid = true;
};

struct Tile {
	const uint8_t *source;
	const uint8_t *mask;
	uint8_t *output;
	uint8_t *painted;
	Rect2i bounds;
	int width;
	int blocks;
	std::array<Block, MAX_BLOCKS> results;
};

// The caller owns the packed buffers until the join. Each job has exclusive
// output rows. No job reads an Image, a resource, a node or a rendering RID.
void copy_rows(Tile &tile, int index) {
	Block &block = tile.results[index];
	block.thread = std::this_thread::get_id();
	const Rect2i &rect = tile.bounds;
	const int first = rect.position.y + rect.size.y * index / tile.blocks;
	const int end = rect.position.y + rect.size.y * (index + 1) / tile.blocks;
	for (int y = first; y < end; ++y) {
		const int64_t start = int64_t(y) * tile.width + rect.position.x;
		for (int64_t i = start; i < start + rect.size.x; ++i) {
			if (tile.mask[i] == 0) {
				continue;
			}
			uint32_t bits;
			std::memcpy(&bits, tile.source + 4 * i, sizeof(bits));
			if (tile.painted) {
				if ((bits & 0x7f800000u) == 0x7f800000u) {
					block.valid = false;
					return;
				}
				tile.painted[i] = 255;
			}
			// Terrain controls use RF as a raw 32-bit bitfield.
			std::memcpy(tile.output + 4 * i, &bits, sizeof(bits));
		}
	}
}

void pool_rows(void *data, uint32_t index) {
	copy_rows(*static_cast<Tile *>(data), index + 1);
}
} // namespace

int PonyTerrainOverlay::apply(const Ref<Image> &map, const PackedByteArray &source, const Ref<Image> &mask,
		const Rect2i &bounds, const Ref<Image> &painted) {
	if (map.is_null() || mask.is_null() || map->get_format() != Image::FORMAT_RF ||
			mask->get_format() != Image::FORMAT_L8 || mask->get_size() != map->get_size()) {
		return 0;
	}
	const Vector2i size = map->get_size();
	if (source.size() != int64_t(size.x) * size.y * 4 || bounds.position.x < 0 || bounds.position.y < 0 ||
			bounds.size.x < 0 || bounds.size.y < 0 || bounds.position.x > size.x - bounds.size.x ||
			bounds.position.y > size.y - bounds.size.y) {
		return 0;
	}
	if (painted.is_valid() && (painted->get_format() != Image::FORMAT_L8 || painted->get_size() != size)) {
		return 0;
	}
	if (!bounds.has_area()) {
		return 1;
	}
	PackedByteArray output = map->get_data();
	const PackedByteArray coverage = mask->get_data();
	PackedByteArray merged = painted.is_valid() ? painted->get_data() : PackedByteArray();
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	// Amortize pool wakeups over at least 32K samples per block.
	const int blocks = pool ? std::clamp(bounds.get_area() / 32768, 1, std::min(MAX_BLOCKS, bounds.size.y)) : 1;
	Tile tile{ source.ptr(), coverage.ptr(), output.ptrw(), painted.is_valid() ? merged.ptrw() : nullptr,
		bounds, size.x, blocks, {} };
	if (blocks > 1) {
		const auto group = pool->add_native_group_task(&pool_rows, &tile, blocks - 1, -1, true, "Terrain overlay");
		copy_rows(tile, 0);
		pool->wait_for_group_task_completion(group);
	} else {
		copy_rows(tile, 0);
	}
	int threads = 0;
	for (int i = 0; i < blocks; ++i) {
		if (!tile.results[i].valid) {
			return 0;
		}
		const auto same_thread = [&](const Block &b) { return b.thread == tile.results[i].thread; };
		threads += std::none_of(tile.results.begin(), tile.results.begin() + i, same_thread);
	}
	map->set_data(size.x, size.y, map->has_mipmaps(), map->get_format(), output);
	if (painted.is_valid()) {
		painted->set_data(size.x, size.y, painted->has_mipmaps(), painted->get_format(), merged);
	}
	return threads;
}

void PonyTerrainOverlay::_bind_methods() {
	ClassDB::bind_static_method("PonyTerrainOverlay", D_METHOD("apply", "map", "source", "mask", "bounds", "painted"), &PonyTerrainOverlay::apply);
}
