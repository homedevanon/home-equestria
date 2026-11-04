// Registers PonySolverNative (native pony leg/pose solver, docs/NATIVE_SOLVER_2026_09_25.md)
// PonyNavigationNative (native navigation, docs/NAVIGATION_PHASE_1_2026_10_02.md),
// PonyAirNavigation (native 3D flight routes, docs/NAVIGATION_PHASE_5_2026_10_02.md) and
// PonyTextureCodec (runtime BC1/BC3 for exported builds, texture_codec.h). The classes share no state.
#include "foliage_fill.h"
#include "pony_air_navigation.h"
#include "pony_column_sampler.h"
#include "pony_gait_sampler.h"
#include "pony_navigation_native.h"
#include "pony_ponese_voice.h"
#include "pony_wander_job.h"
#include "pony_solver_native.h"
#include "texture_codec.h"
#include "trail_weights.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_pony_solver(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(PonySolverNative);
	GDREGISTER_CLASS(PonyGaitSampler);
	GDREGISTER_CLASS(PonyWanderJob); // dev 2026-10-20 multithreading: before its factory
	GDREGISTER_CLASS(PonyColumnSampler); // dev 2026-10-20 multithreading
	GDREGISTER_CLASS(PonyNavigationNative);
	GDREGISTER_CLASS(PonyAirNavigation);
	GDREGISTER_CLASS(PonyTextureCodec);
	GDREGISTER_CLASS(PonyFoliageFill); // dev 2026-10-20 multithreading: foliage cell fill
	GDREGISTER_CLASS(PonyPoneseVoice); // 2026-11-02 ponese v3: WORLD vocoder syllables
	GDREGISTER_CLASS(PonyTrailWeights); // 2026-10-24 script profile: walk-grid trail weights per chunk
}

void uninitialize_pony_solver(ModuleInitializationLevel p_level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT pony_solver_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_pony_solver);
	init_obj.register_terminator(uninitialize_pony_solver);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
