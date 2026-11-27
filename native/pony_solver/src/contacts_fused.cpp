// Perf 2026-11-21 (lane native_calls): pony_locomotion.gd _update_contacts_native() with its
// probes made here. The script did: contacts_begin(); four _probe() calls at the references
// (each PonySolverNative.probe()); contacts_plant(); a _probe() at each re-sample point;
// contacts_finish(). These run the very same functions in the very same order, so the feet,
// the plants and every ray are the same; what goes is the script's per-probe calls and the
// dictionaries handed back and forth. The caller keeps its old path when this binary lacks these
// methods or when a script overrides _probe() (a mod's override must still see every ray).
#include "pony_solver_native.h"

using namespace godot;

namespace {

bool ray_arguments(const PackedFloat64Array &p_ray, double &r_hip, int64_t &r_mask, double &r_slope) {
	if (p_ray.size() != 3) {
		return false;
	}
	r_hip = p_ray[0];
	r_mask = int64_t(p_ray[1]);
	r_slope = p_ray[2];
	return true;
}

} // namespace

Array PonySolverNative::contacts_begin_plant(const Array &p_source_pose, const Array &p_feet, const Transform3D &p_global,
		const Transform3D &p_pivot, const Transform3D &p_model_frame, double p_delta, const PackedFloat64Array &p_timing,
		const PackedFloat64Array &p_motion, const PackedInt32Array &p_state, const PackedFloat64Array &p_scalars,
		const PackedFloat64Array &p_ray) {
	double hip = 0.0;
	int64_t mask = 0;
	double slope = 0.0;
	ERR_FAIL_COND_V(!ray_arguments(p_ray, hip, mask, slope), Array());
	contact_resample_points = PackedVector3Array();
	contact_resample = PackedByteArray();
	const PackedVector3Array references = contacts_begin(p_source_pose, p_feet, p_global, p_pivot, p_model_frame, p_delta,
			p_timing, p_motion);
	ERR_FAIL_COND_V(references.size() != 4, Array());
	Array hits;
	hits.resize(4);
	for (int i = 0; i < 4; i++) {
		hits[i] = probe(references[i], 0.0, hip, mask, slope);
	}
	Array planted = contacts_plant(p_feet, hits, p_state, p_scalars);
	if (planted.size() >= 2) {
		contact_resample_points = planted[0];
		contact_resample = planted[1];
	}
	return planted;
}

void PonySolverNative::contacts_resample_finish(const Array &p_feet, double p_delta, const PackedInt32Array &p_state,
		const Transform3D &p_global, const Transform3D &p_model_frame, const PackedFloat64Array &p_ray) {
	double hip = 0.0;
	int64_t mask = 0;
	double slope = 0.0;
	ERR_FAIL_COND(!ray_arguments(p_ray, hip, mask, slope));
	ERR_FAIL_COND(contact_resample_points.size() != 4 || contact_resample.size() != 4);
	Array contacts;
	contacts.resize(4);
	for (int i = 0; i < 4; i++) {
		contacts[i] = contact_resample[i] ? probe(contact_resample_points[i], 0.0, hip, mask, slope) : Dictionary();
	}
	contact_resample_points = PackedVector3Array();
	contact_resample = PackedByteArray();
	contacts_finish(p_feet, contacts, p_delta, p_state, p_global, p_model_frame);
}
