// Registers PonySolverNative (native pony leg/pose solver, docs/NATIVE_SOLVER_2026_09_25.md)
// PonyNavigationNative (native navigation, docs/NAVIGATION_PHASE_1_2026_10_02.md),
// PonyAirNavigation (native 3D flight routes, docs/NAVIGATION_PHASE_5_2026_10_02.md) and
// PonyTextureCodec (runtime BC1/BC3 for exported builds, texture_codec.h). The classes share no state.
#include "face_modifiers_native.h"
#include "foliage_fill.h"
#include "frame_owners_native.h"
#include "pony_air_navigation.h"
#include "pony_clip_step_native.h"
#include "pony_column_sampler.h"
#include "pony_gait_sampler.h"
#include "pony_heap.h"
#include "pony_navigation_native.h"
#include "pony_ponese_voice.h"
#include "pony_wander_job.h"
#include "rig_batch.h"
#include "tail_motion_native.h"
#include "body_modifiers_native.h"
#include "rig_links_native.h"
#include "nav_follow_native.h"
#include "pony_solver_native.h"
#include "terrain_overlay.h"
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
	GDREGISTER_CLASS(PonyTerrainOverlay);
	GDREGISTER_CLASS(PonyFoliageFill); // dev 2026-10-20 multithreading: foliage cell fill
	GDREGISTER_CLASS(PonyPoneseVoice); // 2026-11-02 ponese v3: WORLD vocoder syllables
	GDREGISTER_CLASS(PonyTrailWeights); // 2026-10-24 script profile: walk-grid trail weights per chunk
	GDREGISTER_CLASS(PonyHeap); // 2026-11-21 lane memory: malloc_trim once the loading cover is up
	GDREGISTER_CLASS(PonyRigBatch); // 2026-11-21 lane rig_batch: close ponies' body modifiers in one native batch
	GDREGISTER_CLASS(PonyRigBatchApply);
	GDREGISTER_CLASS(FrameOwnersNative); // 2026-11-21 lane frame: small per-frame owners (crowd view test)
	GDREGISTER_CLASS(PonyClipStepNative); // 2026-11-21 native pony step, lane step: the clip tiers' walking step
	GDREGISTER_CLASS(PonyEyeMotionNative); GDREGISTER_CLASS(PonyMouthNative); // 2026-11-21 lane face: eye motion and mouth modifiers
	GDREGISTER_CLASS(PonyTailMotionNative); // 2026-11-21 lane tail: hybrid_tail_motion.gd native base
	GDREGISTER_CLASS(PonyIdleBodyNative); // 2026-11-21 native pony step, lane body
	GDREGISTER_CLASS(PonyClipHeadNative);
	GDREGISTER_CLASS(PonyFillyProportionsNative);
	GDREGISTER_CLASS(HybridNeckLinkNative); // 2026-11-21 lane links: neck link state and update
	GDREGISTER_CLASS(HybridHairLinkNative); // 2026-11-21 lane links: hair link state and updates
	GDREGISTER_CLASS(PonyNavFollowDriverNative); // 2026-11-21 native pony step, lane follow: the follow driver gather and apply
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
