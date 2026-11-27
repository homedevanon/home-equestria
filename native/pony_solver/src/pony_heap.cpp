// PonyHeap: see pony_heap.h.
#include "pony_heap.h"

#include <godot_cpp/core/class_db.hpp>

#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
#define PONY_HEAP_GLIBC 1
#endif

using namespace godot;

void PonyHeap::_bind_methods() {
	ClassDB::bind_static_method("PonyHeap", D_METHOD("trim"), &PonyHeap::trim);
	ClassDB::bind_static_method("PonyHeap", D_METHOD("stats"), &PonyHeap::stats);
}

bool PonyHeap::trim() {
#ifdef PONY_HEAP_GLIBC
	return malloc_trim(0) != 0;
#else
	return false;
#endif
}

Dictionary PonyHeap::stats() {
	Dictionary out;
#ifdef PONY_HEAP_GLIBC
	struct mallinfo2 info = mallinfo2();
	out["arena"] = (int64_t)info.arena;
	out["in_use"] = (int64_t)info.uordblks;
	out["free"] = (int64_t)info.fordblks;
	out["mapped"] = (int64_t)info.hblkhd;
#endif
	return out;
}
