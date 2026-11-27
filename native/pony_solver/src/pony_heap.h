// PonyHeap (lane memory, perf overhaul 2026-11-21): hands memory the C allocator holds free back
// to the system. Loading a world frees large temporary buffers (region maps, meshes, decoded
// images); glibc keeps those pages resident inside its arenas. One `malloc_trim(0)` while the
// loading cover is still opaque returned 0.23 GB of resident memory in 11 ms on High (8.66 ->
// 8.44 GB). Linux with glibc only; elsewhere both methods do nothing and return false / empty.
// Main thread or any thread; holds no state.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class PonyHeap : public RefCounted {
	GDCLASS(PonyHeap, RefCounted)

protected:
	static void _bind_methods();

public:
	// malloc_trim(0): true when the allocator gave memory back.
	static bool trim();
	// glibc mallinfo2 totals in bytes: arena, in_use, free, mapped; empty where unsupported.
	static Dictionary stats();
};

} // namespace godot
