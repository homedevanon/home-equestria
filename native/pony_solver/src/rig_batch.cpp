// Close ponies' body skeleton modifiers in one native batch; see rig_batch.h.
#include "rig_batch.h"

#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/classes/audio_stream_player3d.hpp>
#include <godot_cpp/classes/bone_attachment3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physical_bone_simulator3d.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <thread>
#include <unordered_set>

using namespace godot;

namespace {

// Rollback for fixtures: false runs the neck and hair links in their scripts even for batched
// ponies (the scripts' guards then must not return: rig_batch.gd stamps only the modifiers).
constexpr bool NATIVE_LINKS = true;

// GDScript's Math helpers on doubles (core/math/math_funcs.h).
inline double move_toward(double from, double to, double delta) {
	return std::abs(to - from) <= delta ? to : from + (to > from ? 1.0 : (to < from ? -1.0 : 0.0)) * delta;
}
inline double smoothstep01(double x) {
	const double s = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);
	return s * s * (3.0 - 2.0 * s);
}
inline bool equal_approx(double a, double b) {
	if (a == b) {
		return true;
	}
	double tolerance = 0.00001 * std::abs(a);
	if (tolerance < 0.00001) {
		tolerance = 0.00001;
	}
	return std::abs(a - b) < tolerance;
}

double as_double(const Variant &v, double fallback = 0.0) {
	if (v.get_type() == Variant::FLOAT) {
		return double(v);
	}
	if (v.get_type() == Variant::INT) {
		return double(int64_t(v));
	}
	return fallback;
}
int64_t as_int(const Variant &v, int64_t fallback = -1) {
	if (v.get_type() == Variant::INT) {
		return int64_t(v);
	}
	if (v.get_type() == Variant::FLOAT) {
		return int64_t(double(v));
	}
	return fallback;
}
bool as_bool(const Variant &v) {
	return v.get_type() == Variant::BOOL && bool(v);
}
Object *as_object(const Variant &v) {
	return v.get_type() == Variant::OBJECT ? (Object *)v : nullptr;
}
std::vector<int32_t> as_ints(const Variant &v) {
	std::vector<int32_t> out;
	if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
		const PackedInt32Array a = v;
		for (int64_t i = 0; i < a.size(); i++) {
			out.push_back(a[i]);
		}
	} else if (v.get_type() == Variant::ARRAY) {
		const Array a = v;
		for (int64_t i = 0; i < a.size(); i++) {
			out.push_back(int32_t(as_int(a[i])));
		}
	}
	return out;
}
std::vector<Basis> as_bases(const Variant &v) {
	std::vector<Basis> out;
	if (v.get_type() == Variant::ARRAY) {
		const Array a = v;
		for (int64_t i = 0; i < a.size(); i++) {
			out.push_back(a[i]);
		}
	}
	return out;
}
String script_path(Object *object) {
	if (object == nullptr) {
		return String();
	}
	Resource *script = Object::cast_to<Resource>(as_object(object->get_script()));
	return script != nullptr ? script->get_path() : String();
}
template <typename T>
T *live(ObjectID id) {
	return id.is_valid() ? Object::cast_to<T>(ObjectDB::get_instance(uint64_t(id))) : nullptr;
}
Transform3D compose(const Vector3 &position, const Quaternion &rotation, const Vector3 &scale) {
	// Skeleton3D's Bone::update_pose_cache().
	Transform3D pose;
	pose.basis.set_quaternion_scale(rotation, scale);
	pose.origin = position;
	return pose;
}

struct Lap {
	int64_t &total;
	std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
	explicit Lap(int64_t &p_total) :
			total(p_total) {}
	~Lap() { total += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count(); }
};

using Bone = PonyRigBatch::Bone;
using Row = PonyRigBatch::Row;

// The body rig as the engine's update sees it, on the gathered bones only.
struct Body {
	Row &row;

	int32_t slot(int32_t bone) const {
		return bone >= 0 && bone < (int32_t)row.slot_of.size() ? row.slot_of[bone] : -1;
	}
	// Skeleton3D::get_bone_global_pose() inside the update.
	const Transform3D &global(int32_t s) {
		Bone &b = row.bones[s];
		if (!b.global_ok) {
			b.global = b.parent_slot < 0 ? b.pose : global(b.parent_slot) * b.pose;
			b.global_ok = true;
		}
		return b.global;
	}
	Transform3D global_of(int32_t bone) { return global(slot(bone)); }
	void touched(int32_t s) {
		Bone &b = row.bones[s];
		b.pose = compose(b.position, b.rotation, b.scale);
		b.written = true;
		b.global_ok = false;
		for (int32_t d : row.below[s]) {
			row.bones[d].global_ok = false;
		}
	}
	// Skeleton3D::set_bone_pose(): the engine keeps position, rotation and scale.
	void set_pose(int32_t bone, const Transform3D &t) {
		const int32_t s = slot(bone);
		Bone &b = row.bones[s];
		b.position = t.origin;
		b.rotation = t.basis.get_rotation_quaternion();
		b.scale = t.basis.get_scale();
		touched(s);
	}
	void set_rotation(int32_t bone, const Quaternion &q) {
		const int32_t s = slot(bone);
		row.bones[s].rotation = q;
		touched(s);
	}
	void set_scale(int32_t bone, const Vector3 &v) {
		const int32_t s = slot(bone);
		row.bones[s].scale = v;
		touched(s);
	}
	// Skeleton3D::set_bone_global_pose().
	void set_global(int32_t bone, const Transform3D &g) {
		const int32_t s = slot(bone);
		Transform3D parent;
		if (row.bones[s].parent_slot >= 0) {
			parent = global(row.bones[s].parent_slot);
		}
		set_pose(bone, parent.affine_inverse() * g);
	}
	const Transform3D &pose(int32_t bone) const { return row.bones[slot(bone)].pose; }
	const Quaternion &rotation(int32_t bone) const { return row.bones[slot(bone)].rotation; }
	const Vector3 &scale(int32_t bone) const { return row.bones[slot(bone)].scale; }
};

} // namespace

struct PonyRigBatch::Names {
	StringName skeleton = "skeleton", head = "head", hair_skeleton = "hair_skeleton", clip_head = "_clip_head";
	StringName idle_body = "idle_body", neck_link = "neck_link", hair_link = "hair_link", secondary = "secondary";
	StringName joint_limits = "joint_limits", modifier = "modifier", native = "native", native_solver = "_native";
	StringName native_constrain = "_native_constrain", sim_tier = "sim_tier", held = "_held", interaction = "_interaction";
	StringName affection_active = "affection_active", cuddle_active = "cuddle_active", carry = "carry", blend = "blend";
	StringName conversation_target = "conversation_target", logic_steps = "_logic_steps";
	StringName clip_head_from = "clip_head_from", clip_head_to = "clip_head_to", clip_blend = "_clip_blend";
	StringName posture = "posture", progress = "progress", requested = "requested", sleep_blend = "_sleep_blend";
	StringName hidden_parked = "_hidden_parked", pivot = "pivot";
	StringName wanted = "wanted", fade = "fade", roll_ = "_roll", pitch_ = "_pitch", breath_ = "_breath";
	StringName applied_roll = "applied_roll", frame_ready = "_frame_ready", model_to_skeleton = "_model_to_skeleton";
	StringName last_pass_frame = "_last_pass_frame", offset = "offset", roll = "roll", breath = "breath";
	StringName neck_ = "_neck", parent_frames = "_parent_frames", spine = "_spine", spine_frames = "_spine_frames";
	StringName hips = "_hips", hips_parent = "_hips_parent", legs = "_legs", leg_parents = "_leg_parents";
	StringName head_ = "_head", local_width_basis = "_local_width_basis", wings = "_wings";
	StringName neck_scale = "neck_scale", head_scale = "head_scale", head_width = "head_width", wing_scale = "wing_scale";
	StringName mare = "mare", amount = "amount", rear_now = "_rear_now", applied = "_applied", motion = "_motion";
	StringName face_bound = "_face_bound", bind_mouth = "bind_mouth", buck_amount = "buck_amount";
	StringName stretch_amount = "stretch_amount", stretch_left = "stretch_left", yawn_amount = "yawn_amount";
	StringName rig_batch_step = "rig_batch_step", enabled = "enabled", linked = "_linked";
	StringName source_bones = "_source_bones", target_bones = "_target_bones", offsets = "_offsets", source_poses = "source_poses";
	StringName body_hips = "body_hips", hair_pelvis = "hair_pelvis", pelvis_offset = "pelvis_offset";
	StringName head_pairs = "head_pairs", head_offsets = "head_offsets", head_rest_inverse = "_head_rest_inverse";
	StringName skull_frame = "skull_frame", follow_head = "follow_head", skip_unchanged = "SKIP_UNCHANGED";
	StringName pelvis_written = "_pelvis_written", pelvis_valid = "_pelvis_valid", pelvis_moved = "_pelvis_moved";
	StringName head_written = "_head_written", head_valid = "_head_valid";
	StringName skeleton_updated = "skeleton_updated", pose_updated = "pose_updated";
	StringName child_entered_tree = "child_entered_tree", child_exiting_tree = "child_exiting_tree";
	StringName callable = "callable", head_attachment = "HeadAttachment";
	StringName source = "source", target = "target", hair = "hair", body = "body";
	StringName neck_demand = "neck_demand", neutral_lips = "neutral_lips", goal = "_goal", fading = "_fading", hind = "_hind";
	StringName plant = "plant", step_key = "step";
};

PonyRigBatch::Names &PonyRigBatch::names() {
	static Names n;
	return n;
}

void PonyRigBatch::configure(const Array &p_body_scripts, const Array &p_head_scripts, const Array &p_hair_scripts,
		const PackedStringArray &p_listener_keys, double p_breath_arch, double p_serial_radius, int32_t p_audit_steps) {
	names();
	// Warm the engine-delegated math on the main thread (function-local statics).
	(void)pony::basis_from_euler(Vector3());
	(void)pony::basis_axis_angle(Vector3(1, 0, 0), 0.0);
	(void)pony::engine_exp(0.0);
	(void)pony::interpolate(Transform3D(), Transform3D(), 0.0);
	body_scripts = p_body_scripts;
	head_scripts = p_head_scripts;
	hair_scripts = p_hair_scripts;
	listener_keys = p_listener_keys;
	breath_arch = p_breath_arch;
	serial_radius = p_serial_radius;
	audit_steps = MAX(1, p_audit_steps);
}

int32_t PonyRigBatch::bind_pony(Object *p_pony, Object *p_body, Object *p_head, Object *p_hair, Object *p_neck_link,
		Object *p_hair_link, Object *p_apply) {
	ERR_FAIL_NULL_V(p_pony, -1);
	Skeleton3D *body = Object::cast_to<Skeleton3D>(p_body);
	Skeleton3D *head = Object::cast_to<Skeleton3D>(p_head);
	Skeleton3D *hair = Object::cast_to<Skeleton3D>(p_hair);
	PonyRigBatchApply *apply = Object::cast_to<PonyRigBatchApply>(p_apply);
	ERR_FAIL_COND_V(body == nullptr || head == nullptr || hair == nullptr || apply == nullptr, -1);
	int32_t id = -1;
	for (int32_t i = 0; i < (int32_t)rows.size(); i++) {
		if (!rows[i].bound) {
			id = i;
			break;
		}
	}
	if (id < 0) {
		id = (int32_t)rows.size();
		rows.emplace_back();
	}
	rows[id] = Row();
	Row &row = rows[id];
	row.bound = true;
	row.pony = ObjectID(p_pony->get_instance_id());
	row.body = ObjectID(body->get_instance_id());
	row.head = ObjectID(head->get_instance_id());
	row.hair = ObjectID(hair->get_instance_id());
	row.neck_link = p_neck_link != nullptr ? ObjectID(p_neck_link->get_instance_id()) : ObjectID();
	row.hair_link = p_hair_link != nullptr ? ObjectID(p_hair_link->get_instance_id()) : ObjectID();
	row.apply = ObjectID(apply->get_instance_id());
	apply->setup(this, id);
	// Always active: it writes only in a step that batched her. Switching `active` would mark the
	// rig dirty and run an update the scripts would not have run (a parked rig, a pass with no
	// write); pony_locomotion.gd's FAR parking skips this class.
	apply->set_active(true);
	const Names &n = names();
	if (NATIVE_LINKS) {
		body->connect(n.skeleton_updated, callable_mp(this, &PonyRigBatch::_body_updated).bind(id));
		head->connect(n.skeleton_updated, callable_mp(this, &PonyRigBatch::_head_updated).bind(id));
	}
	for (Skeleton3D *rig : { body, head, hair }) {
		rig->connect(n.child_entered_tree, callable_mp(this, &PonyRigBatch::_child_changed).bind(id));
		rig->connect(n.child_exiting_tree, callable_mp(this, &PonyRigBatch::_child_changed).bind(id));
	}
	return id;
}

void PonyRigBatch::unbind(int32_t p_row) {
	if (!row_live(p_row)) {
		return;
	}
	Row &row = rows[p_row];
	flush(row);
	const Names &n = names();
	Skeleton3D *rigs[3] = { live<Skeleton3D>(row.body), live<Skeleton3D>(row.head), live<Skeleton3D>(row.hair) };
	if (NATIVE_LINKS) {
		const Callable body_cb = callable_mp(this, &PonyRigBatch::_body_updated).bind(p_row);
		const Callable head_cb = callable_mp(this, &PonyRigBatch::_head_updated).bind(p_row);
		if (rigs[0] != nullptr && rigs[0]->is_connected(n.skeleton_updated, body_cb)) {
			rigs[0]->disconnect(n.skeleton_updated, body_cb);
		}
		if (rigs[1] != nullptr && rigs[1]->is_connected(n.skeleton_updated, head_cb)) {
			rigs[1]->disconnect(n.skeleton_updated, head_cb);
		}
	}
	const Callable child_cb = callable_mp(this, &PonyRigBatch::_child_changed).bind(p_row);
	for (Skeleton3D *rig : rigs) {
		if (rig == nullptr) {
			continue;
		}
		if (rig->is_connected(n.child_entered_tree, child_cb)) {
			rig->disconnect(n.child_entered_tree, child_cb);
		}
		if (rig->is_connected(n.child_exiting_tree, child_cb)) {
			rig->disconnect(n.child_exiting_tree, child_cb);
		}
	}
	row = Row();
}

void PonyRigBatch::mark_dirty(int32_t p_row) {
	if (row_live(p_row)) {
		rows[p_row].dirty = true;
		rows[p_row].safe = false;
	}
}

void PonyRigBatch::_child_changed(Node *p_node, int32_t p_row) {
	(void)p_node;
	mark_dirty(p_row);
	if (row_live(p_row)) {
		rows[p_row].reload = true;
	}
}

bool PonyRigBatch::row_live(int32_t id) const {
	return id >= 0 && id < (int32_t)rows.size() && rows[id].bound;
}

// Everything on her rigs is game-owned and known (strict: one unknown node keeps her on script);
// refreshes the static data the modifiers read. Runs when a rig's children change and every
// `audit_steps` steps (listeners a pack connects at run time).
bool PonyRigBatch::audit(Row &row) {
	const Names &n = names();
	row.dirty = false;
	row.safe = false;
	Object *pony = live<Object>(row.pony);
	Skeleton3D *body = live<Skeleton3D>(row.body);
	Skeleton3D *head = live<Skeleton3D>(row.head);
	Skeleton3D *hair = live<Skeleton3D>(row.hair);
	if (pony == nullptr || body == nullptr || head == nullptr || hair == nullptr) {
		row.reason = "freed";
		return false;
	}
	Object *head_node = as_object(pony->get(n.head));
	if (as_object(pony->get(n.skeleton)) != body || head_node == nullptr || as_object(head_node->get(n.skeleton)) != head ||
			as_object(pony->get(n.hair_skeleton)) != hair) {
		row.reason = "rigs changed";
		return false;
	}
	if (body->is_show_rest_only()) {
		row.reason = "rest only";
		return false;
	}
	Object *clip = as_object(pony->get(n.clip_head));
	Object *idle = as_object(pony->get(n.idle_body));
	Object *secondary = as_object(pony->get(n.secondary));
	Object *limits = as_object(pony->get(n.joint_limits));
	Object *terrain = as_object(pony->get(n.modifier));
	if (as_object(pony->get(n.neck_link)) != live<Object>(row.neck_link) || as_object(pony->get(n.hair_link)) != live<Object>(row.hair_link) ||
			!row.neck_link.is_valid() || !row.hair_link.is_valid()) {
		row.reason = "links changed";
		return false;
	}
	if (secondary == nullptr || limits == nullptr) {
		row.reason = "no secondary or limits";
		return false;
	}
	// Body rig: the four ported modifiers, the terrain modifier, the engine's bone simulator, ours.
	Object *found[5] = { nullptr, nullptr, nullptr, nullptr, nullptr };
	Object *simulator = nullptr;
	std::vector<int32_t> order;
	PonyRigBatchApply *apply = live<PonyRigBatchApply>(row.apply);
	for (int32_t i = 0; i < body->get_child_count(); i++) {
		Node *child = body->get_child(i);
		if (Object::cast_to<BoneAttachment3D>(child) != nullptr) {
			continue; // engine node, updated from this rig on the main thread as before
		}
		if (Object::cast_to<SkeletonModifier3D>(child) == nullptr) {
			continue;
		}
		if (child == apply) {
			continue;
		}
		if (Object::cast_to<PhysicalBoneSimulator3D>(child) != nullptr && script_path(child).is_empty()) {
			simulator = child;
			continue;
		}
		Object *script = as_object(child->get_script());
		int32_t kind = -1;
		for (int32_t k = 0; k < body_scripts.size() && k < 5; k++) {
			if (script != nullptr && as_object(body_scripts[k]) == script) {
				kind = k;
			}
		}
		if (kind < 0 || found[kind] != nullptr) {
			row.reason = "modifier " + String(child->get_name()) + " " + script_path(child);
			return false;
		}
		found[kind] = child;
		if (kind < 4) {
			order.push_back(kind);
		}
	}
	if ((found[0] != nullptr && found[0] != clip) || (found[1] != nullptr && found[1] != idle) || (found[4] != nullptr && found[4] != terrain)) {
		row.reason = "modifier not the pony's own";
		return false;
	}
	// Head and hair: only the game's own modifiers, the head's voice mount and nothing else mounted.
	Skeleton3D *others[2] = { head, hair };
	const Array *allowed[2] = { &head_scripts, &hair_scripts };
	for (int32_t r = 0; r < 2; r++) {
		for (int32_t i = 0; i < others[r]->get_child_count(); i++) {
			Node *child = others[r]->get_child(i);
			if (Object::cast_to<BoneAttachment3D>(child) != nullptr) {
				continue; // engine node, updated from this rig on the main thread as before
			}
			if (Object::cast_to<SkeletonModifier3D>(child) == nullptr) {
				continue;
			}
			if (Object::cast_to<PhysicalBoneSimulator3D>(child) != nullptr && script_path(child).is_empty()) {
				continue;
			}
			Object *script = as_object(child->get_script());
			bool ok = false;
			for (int64_t k = 0; k < allowed[r]->size(); k++) {
				ok = ok || (script != nullptr && as_object((*allowed[r])[k]) == script);
			}
			if (!ok) {
				row.reason = "modifier " + String(child->get_name()) + " " + script_path(child);
				return false;
			}
		}
	}
	// Listeners: the audited keys only (any pack's handler keeps her on script).
	Skeleton3D *rigs[3] = { body, head, hair };
	for (Skeleton3D *rig : rigs) {
		for (const StringName &signal : { n.skeleton_updated, n.pose_updated }) {
			const TypedArray<Dictionary> connections = rig->get_signal_connection_list(signal);
			for (int64_t i = 0; i < connections.size(); i++) {
				const Dictionary c = connections[i];
				const Callable callable = c[n.callable];
				Object *target = callable.get_object();
				// Our handlers, and bone attachments (hats, props, the voice mount): engine nodes that
				// follow the rig on the main thread exactly as before.
				if (target == this || Object::cast_to<BoneAttachment3D>(target) != nullptr) {
					continue;
				}
				const String path = script_path(target);
				const String key = (path.is_empty() ? (target != nullptr ? target->get_class() : String()) : path) + String("::") + String(callable.get_method());
				if (!listener_keys.has(key)) {
					row.reason = "listener " + key;
					return false;
				}
			}
		}
	}
	// Static data, from the same objects the scripts read.
	row.clip = clip != nullptr && found[0] == clip ? ObjectID(clip->get_instance_id()) : ObjectID();
	row.idle = idle != nullptr && found[1] == idle ? ObjectID(idle->get_instance_id()) : ObjectID();
	row.filly = found[2] != nullptr ? ObjectID(found[2]->get_instance_id()) : ObjectID();
	row.affection = found[3] != nullptr ? ObjectID(found[3]->get_instance_id()) : ObjectID();
	row.terrain = found[4] != nullptr ? ObjectID(found[4]->get_instance_id()) : ObjectID();
	row.simulator = simulator != nullptr ? ObjectID(simulator->get_instance_id()) : ObjectID();
	row.secondary = ObjectID(secondary->get_instance_id());
	row.limits = ObjectID(limits->get_instance_id());
	Object *limits_solver = as_object(limits->get(n.native_solver));
	row.limits_solver = limits_solver != nullptr ? ObjectID(limits_solver->get_instance_id()) : ObjectID();
	Object *clip_solver = clip != nullptr ? as_object(clip->get(n.native)) : nullptr;
	row.clip_solver = clip_solver != nullptr ? ObjectID(clip_solver->get_instance_id()) : ObjectID();
	row.order = order;
	row.breath_arch = breath_arch;
	row.affection_mare_ok = found[3] != nullptr && as_object(found[3]->get(n.mare)) == pony;
	// Links: what their scripts set in link() and bind() (a new link object rebinds the pony).
	Object *neck = live<Object>(row.neck_link);
	Object *hair_link = live<Object>(row.hair_link);
	Object *link_source = as_object(neck->get(n.source));
	Object *link_target = as_object(neck->get(n.target));
	row.link_source = link_source != nullptr ? ObjectID(link_source->get_instance_id()) : ObjectID();
	row.link_target = link_target != nullptr ? ObjectID(link_target->get_instance_id()) : ObjectID();
	row.neck_source_bones = as_ints(neck->get(n.source_bones));
	row.neck_target_bones = as_ints(neck->get(n.target_bones));
	row.neck_offsets.clear();
	{
		const Array offsets = neck->get(n.offsets);
		for (int64_t i = 0; i < offsets.size(); i++) {
			row.neck_offsets.push_back(offsets[i]);
		}
	}
	if (row.neck_target_bones.size() != row.neck_source_bones.size() || row.neck_offsets.size() < row.neck_source_bones.size()) {
		row.reason = "neck link data";
		return false;
	}
	Object *link_hair = as_object(hair_link->get(n.hair));
	Object *link_body = as_object(hair_link->get(n.body));
	Object *link_head = as_object(hair_link->get(n.head));
	row.link_hair = link_hair != nullptr ? ObjectID(link_hair->get_instance_id()) : ObjectID();
	row.link_body = link_body != nullptr ? ObjectID(link_body->get_instance_id()) : ObjectID();
	row.link_head = link_head != nullptr ? ObjectID(link_head->get_instance_id()) : ObjectID();
	row.body_hips = int32_t(as_int(hair_link->get(n.body_hips)));
	row.hair_pelvis = int32_t(as_int(hair_link->get(n.hair_pelvis)));
	row.head_pairs.clear();
	row.head_offsets.clear();
	{
		const Array pairs = hair_link->get(n.head_pairs);
		const Array offsets = hair_link->get(n.head_offsets);
		for (int64_t i = 0; i < pairs.size(); i++) {
			row.head_pairs.push_back(pairs[i]);
		}
		for (int64_t i = 0; i < offsets.size(); i++) {
			row.head_offsets.push_back(offsets[i]);
		}
	}
	if (row.head_offsets.size() < row.head_pairs.size() || (row.head_pairs.size() > 0 && row.head_pairs.size() < 3)) {
		row.reason = "hair link data";
		return false;
	}
	row.head_rest_inverse = hair_link->get(n.head_rest_inverse);
	row.skull_frame = hair_link->get(n.skull_frame);
	{
		const Variant skip = hair_link->get(n.skip_unchanged);
		row.skip_unchanged = skip.get_type() == Variant::BOOL ? bool(skip) : true;
	}
	row.clip_bones = as_ints(secondary->get(n.neck_));
	row.clip_frames = as_bases(secondary->get(n.parent_frames));
	if (row.clip_frames.size() != row.clip_bones.size()) {
		row.reason = "clip head frames";
		return false;
	}
	std::vector<int32_t> refs = row.clip_bones;
	row.hips = row.hips_parent = -1;
	row.legs.clear();
	row.leg_parents.clear();
	row.spine.clear();
	row.spine_frames.clear();
	if (idle != nullptr) {
		row.hips = int32_t(as_int(idle->get(n.hips)));
		row.hips_parent = int32_t(as_int(idle->get(n.hips_parent)));
		row.legs = as_ints(idle->get(n.legs));
		row.leg_parents = as_ints(idle->get(n.leg_parents));
		row.spine = as_ints(secondary->get(n.spine));
		row.spine_frames = as_bases(secondary->get(n.spine_frames));
		if (row.legs.size() != row.leg_parents.size() || row.spine.size() != row.spine_frames.size()) {
			row.reason = "idle body bones";
			return false;
		}
		refs.push_back(row.hips);
		refs.push_back(row.hips_parent);
		refs.insert(refs.end(), row.legs.begin(), row.legs.end());
		refs.insert(refs.end(), row.leg_parents.begin(), row.leg_parents.end());
		refs.insert(refs.end(), row.spine.begin(), row.spine.end());
	}
	row.filly_neck = row.filly_head = -1;
	row.wings.clear();
	if (Object *filly = found[2]) {
		row.filly_neck = int32_t(as_int(filly->get(n.neck_)));
		row.filly_head = int32_t(as_int(filly->get(n.head_)));
		row.filly_width = filly->get(n.local_width_basis);
		row.wings = as_ints(filly->get(n.wings));
		refs.push_back(row.filly_neck);
		refs.push_back(row.filly_head);
		refs.insert(refs.end(), row.wings.begin(), row.wings.end());
	}
	const char *sides[2] = { "L", "R" };
	for (int32_t s = 0; s < 2; s++) {
		row.flank[s] = body->find_bone(String("pony_flank_") + sides[s]);
		row.leg_lower[s] = body->find_bone(String("pony_legLower_") + sides[s]);
		row.tarsal[s] = body->find_bone(String("pony_tarsal_") + sides[s]);
		if (found[3] != nullptr) {
			refs.push_back(row.flank[s]);
			refs.push_back(row.leg_lower[s]);
			refs.push_back(row.tarsal[s]);
		}
	}
	row.neck1 = body->find_bone("pony_neck1");
	row.head_bone = body->find_bone("pony_head");
	if (found[3] != nullptr) {
		refs.push_back(row.neck1);
		refs.push_back(row.head_bone);
	}
	// Gathered bones: every referenced bone and its ancestors, parents first.
	const int32_t count = body->get_bone_count();
	std::vector<uint8_t> need(count, 0);
	for (int32_t bone : refs) {
		for (int32_t b = bone; b >= 0 && b < count && !need[b]; b = body->get_bone_parent(b)) {
			need[b] = 1;
		}
	}
	std::vector<int32_t> depth(count, -1);
	std::function<int32_t(int32_t)> depth_of = [&](int32_t b) -> int32_t {
		if (depth[b] < 0) {
			const int32_t p = body->get_bone_parent(b);
			depth[b] = p < 0 ? 0 : depth_of(p) + 1;
		}
		return depth[b];
	};
	std::vector<int32_t> list;
	for (int32_t b = 0; b < count; b++) {
		if (need[b]) {
			if (!body->is_bone_enabled(b)) {
				row.reason = "bone disabled";
				return false;
			}
			depth_of(b);
			list.push_back(b);
		}
	}
	std::stable_sort(list.begin(), list.end(), [&](int32_t a, int32_t b) { return depth[a] < depth[b]; });
	row.slot_of.assign(count, -1);
	row.bones.assign(list.size(), Bone());
	for (int32_t s = 0; s < (int32_t)list.size(); s++) {
		row.slot_of[list[s]] = s;
		row.bones[s].index = list[s];
	}
	row.below.assign(list.size(), {});
	for (int32_t s = 0; s < (int32_t)list.size(); s++) {
		const int32_t p = body->get_bone_parent(list[s]);
		row.bones[s].parent_slot = p >= 0 ? row.slot_of[p] : -1;
		for (int32_t a = p; a >= 0; a = body->get_bone_parent(a)) {
			row.below[row.slot_of[a]].push_back(s);
		}
	}
	row.reason = "";
	row.safe = true;
	return true;
}

// Main thread, every step: may she use the batch now, and what do the modifiers read.
bool PonyRigBatch::gather(Row &row, int32_t index, const Vector3 &camera, double delta, int64_t p_frame, bool p_was) {
	const Names &n = names();
	const int64_t frame = p_frame;
	// Entering, or an update since her last batched one ran her scripts: read their state again.
	const bool was = p_was && !row.reload;
	Object *pony = live<Object>(row.pony);
	Node3D *pony3d = Object::cast_to<Node3D>(pony);
	Skeleton3D *body = live<Skeleton3D>(row.body);
	if (pony3d == nullptr || body == nullptr || !pony3d->is_inside_tree() || !body->is_inside_tree()) {
		row.reason = "not in tree";
		return false;
	}
	if (row.fixture_hold) {
		row.reason = "held by fixture";
		return false;
	}
	// Contact and tier rules (rig_threads.gd _contact_free).
	if (as_int(pony->get(n.sim_tier)) != 1) {
		row.reason = "tier";
		return false;
	}
	if (camera.is_finite() && pony3d->get_global_position().distance_squared_to(camera) < serial_radius * serial_radius) {
		row.reason = "within reach";
		return false;
	}
	if (as_bool(pony->get(n.held)) || !String(pony->get(n.interaction)).is_empty() || pony->has_meta(n.affection_active) ||
			pony->has_meta(n.cuddle_active)) {
		row.reason = "contact";
		return false;
	}
	if (Object *carry = as_object(pony->get(n.carry))) {
		if (as_double(carry->get(n.blend)) > 0.0) {
			row.reason = "carried";
			return false;
		}
	}
	const Variant talk = pony->get(n.conversation_target);
	if (talk.get_type() == Variant::OBJECT && as_object(talk) != nullptr) {
		row.reason = "conversation";
		return false;
	}
	if (row.dirty) {
		// A rig's children changed (a hat put on or off, a modifier added): on the scripts this
		// step, audited for the next one.
		audit(row);
		if (row.safe) {
			row.reason = "rig changed this step";
		}
		return false;
	}
	if (!row.safe || (frame + index) % audit_steps == 0) {
		if (!audit(row)) {
			return false;
		}
	}
	if (!body->is_physics_processing_internal() || body->get_modifier_callback_mode_process() != Skeleton3D::MODIFIER_CALLBACK_MODE_PROCESS_PHYSICS) {
		row.reason = "rig parked";
		return false;
	}
	if (SkeletonModifier3D *terrain = live<SkeletonModifier3D>(row.terrain)) {
		if (terrain->is_active()) {
			row.reason = "terrain modifier";
			return false;
		}
	}
	if (PhysicalBoneSimulator3D *simulator = live<PhysicalBoneSimulator3D>(row.simulator)) {
		if (simulator->is_simulating_physics()) {
			row.reason = "ragdoll";
			return false;
		}
	}
	Object *limits = live<Object>(row.limits);
	if (limits == nullptr || !as_bool(limits->get(n.native_constrain)) || as_object(limits->get(n.native_solver)) != live<Object>(row.limits_solver) ||
			live<PonySolverNative>(row.limits_solver) == nullptr) {
		row.reason = "limits not native";
		return false;
	}
	Object *secondary = live<Object>(row.secondary);
	row.limits_ptr = live<PonySolverNative>(row.limits_solver);
	row.clip_ptr = live<PonySolverNative>(row.clip_solver);
	row.delta = delta;
	row.frame = frame;
	// Clip head (pony_clip_head.gd _apply up to the native call).
	SkeletonModifier3D *clip = live<SkeletonModifier3D>(row.clip);
	row.clip_on = false;
	if (clip != nullptr && clip->is_active() && !row.clip_bones.empty()) {
		if (row.clip_ptr == nullptr) {
			row.reason = "clip head not native";
			return false;
		}
		const double t = pony::minf(1.0, double(as_int(pony->get(n.logic_steps), 0) + 1) / 3.0); // logic_alpha() in NEAR
		const PackedVector3Array from = pony->get(n.clip_head_from);
		const PackedVector3Array to = pony->get(n.clip_head_to);
		if (from.size() < 3 || to.size() < 3) {
			row.reason = "clip head input";
			return false;
		}
		double weight = smoothstep01(as_double(pony->get(n.clip_blend)));
		Object *posture = as_object(pony->get(n.posture));
		bool rest = false;
		if (posture != nullptr) {
			rest = as_double(posture->get(n.progress)) > 0.0 || String(posture->get(n.requested)) != String("stand");
		}
		row.clip_on = true;
		row.clip_rest = rest;
		if (rest) {
			weight *= 1.0 - smoothstep01(as_double(posture->get(n.sleep_blend)));
			if (weight <= 0.0) {
				row.clip_on = false;
			}
		}
		row.clip_weight = weight;
		row.clip_head = from[0].lerp(to[0], t) * weight;
		row.clip_gaze = from[1].lerp(to[1], t) * weight;
		row.clip_neck_gaze = from[2].lerp(to[2], t) * weight;
	}
	// Idle body (pony_idle_body.gd _process_modification_with_delta and _apply's inputs).
	SkeletonModifier3D *idle = live<SkeletonModifier3D>(row.idle);
	row.idle_on = idle != nullptr && idle->is_active();
	row.idle_wrote_state = false;
	if (idle != nullptr && !was) {
		// Entering: the script's eased state. While she stays batched the batch owns it (written back
		// every step it changes; nothing else writes it while she is NEAR and her rig ticks: tier
		// changes, catch_up() after a parked rig and shown_pose() at a HERO hand-off all happen
		// while she is off the batch).
		row.idle_fade = as_double(idle->get(n.fade));
		row.idle_roll = as_double(idle->get(n.roll_));
		row.idle_pitch = as_double(idle->get(n.pitch_));
		row.idle_breath = as_double(idle->get(n.breath_));
		row.idle_applied_roll = as_double(idle->get(n.applied_roll));
		row.idle_frame_ready = as_bool(idle->get(n.frame_ready));
		row.idle_model_to_skeleton = idle->get(n.model_to_skeleton);
	}
	if (row.idle_on) {
		row.idle_skip = as_bool(pony->get(n.hidden_parked));
		row.idle_wanted = as_bool(idle->get(n.wanted));
		row.idle_fade_in = row.idle_fade;
		row.idle_applied_in = row.idle_applied_roll;
		row.idle_frame_in = row.idle_frame_ready;
		row.idle_eased = false;
		row.sec_offset = secondary->get(n.offset);
		row.sec_roll = as_double(secondary->get(n.roll));
		row.sec_breath = as_double(secondary->get(n.breath));
		row.idle_can_apply = row.idle_frame_ready;
		if (!row.idle_frame_ready) {
			Node3D *pivot = Object::cast_to<Node3D>(as_object(pony->get(n.pivot)));
			if (pivot != nullptr && pivot->is_inside_tree()) {
				row.idle_model_to_skeleton = (pivot->get_global_basis().orthonormalized().inverse() * body->get_global_basis().orthonormalized()).inverse();
				row.idle_can_apply = true;
			}
		}
	}
	// Filly proportions.
	SkeletonModifier3D *filly = live<SkeletonModifier3D>(row.filly);
	row.filly_on = filly != nullptr && filly->is_active();
	if (row.filly_on) {
		row.neck_scale = as_double(filly->get(n.neck_scale), 1.0);
		row.head_scale = as_double(filly->get(n.head_scale), 1.0);
		row.head_width = as_double(filly->get(n.head_width), 1.0);
		row.wing_scale = as_double(filly->get(n.wing_scale), 1.0);
	}
	// Affection pose: only the fidgets; anything else it would do keeps her on script.
	SkeletonModifier3D *affection = live<SkeletonModifier3D>(row.affection);
	row.affection_on = affection != nullptr && affection->is_active();
	if (row.affection_on) {
		const Variant bind_mouth = affection->get(n.bind_mouth);
		if (!row.affection_mare_ok || as_double(affection->get(n.amount)) > 0.001 || as_double(affection->get(n.rear_now)) > 0.0 ||
				bind_mouth.get_type() != Variant::VECTOR3 || Vector3(bind_mouth).is_finite()) {
			row.reason = "affection pose busy";
			return false;
		}
	}
	if (row.affection_on && !was) {
		// Entering: the state its idle pass resets every step (_applied, _motion, neck_demand,
		// neutral_lips, the hind plants, _fading, _goal) must already be reset (one script pass does
		// it), and its face bound. Only its own lean, kiss and rear passes change them, and those keep
		// her on the scripts.
		SkeletonModifier3D *affection = live<SkeletonModifier3D>(row.affection);
		if (as_double(affection->get(n.applied)) != 0.0 || as_double(affection->get(n.motion)) != 0.0 || !as_bool(affection->get(n.face_bound))) {
			row.reason = "affection pose busy";
			return false;
		}
		const Variant neck_demand = affection->get(n.neck_demand);
		const Variant neutral_lips = affection->get(n.neutral_lips);
		const Variant goal = affection->get(n.goal);
		bool reset = !as_bool(affection->get(n.fading)) && neck_demand.get_type() == Variant::VECTOR3 && Vector3(neck_demand) == Vector3() &&
				neutral_lips.get_type() == Variant::VECTOR3 && !Vector3(neutral_lips).is_finite() && goal.get_type() == Variant::VECTOR3 &&
				!Vector3(goal).is_finite();
		const Variant hind = affection->get(n.hind);
		if (reset && hind.get_type() == Variant::ARRAY) {
			const Array legs = hind;
			for (int64_t i = 0; i < legs.size() && reset; i++) {
				const Dictionary leg = legs[i];
				const Variant plant = leg.get(n.plant, Variant());
				reset = plant.get_type() == Variant::VECTOR3 && !Vector3(plant).is_finite() && as_double(leg.get(n.step_key, Variant())) == -1.0;
			}
		} else {
			reset = false;
		}
		if (!reset) {
			row.reason = "affection pose settling";
			return false;
		}
	}
	if (row.affection_on) {
		SkeletonModifier3D *affection = live<SkeletonModifier3D>(row.affection);
		row.buck = as_double(affection->get(n.buck_amount));
		row.stretch = as_double(affection->get(n.stretch_amount));
		row.yawn = as_double(affection->get(n.yawn_amount));
		row.stretch_left = as_bool(affection->get(n.stretch_left));
		if (row.buck > 0.001 || row.stretch > 0.001 || row.yawn > 0.001) {
			row.affection_axis = body->get_global_basis().inverse().xform(pony3d->get_global_basis().get_column(0)).normalized();
		}
	}
	// Links: their per-step switches, and on entry the hair link's skip state.
	{
		Object *neck = live<Object>(row.neck_link);
		Object *hair_link = live<Object>(row.hair_link);
		row.neck_on = as_bool(neck->get(n.enabled)) && as_bool(neck->get(n.linked));
		row.hair_enabled = as_bool(hair_link->get(n.enabled));
		row.pelvis_offset = hair_link->get(n.pelvis_offset);
		row.follow_head = as_double(hair_link->get(n.follow_head));
		if (!row.hair_state_held || !was) {
			row.pelvis_written = hair_link->get(n.pelvis_written);
			row.pelvis_valid = as_bool(hair_link->get(n.pelvis_valid));
			row.pelvis_moved = as_bool(hair_link->get(n.pelvis_moved));
			row.head_valid = as_bool(hair_link->get(n.head_valid));
			row.head_written.clear();
			const Array written = hair_link->get(n.head_written);
			for (int64_t i = 0; i < written.size(); i++) {
				row.head_written.push_back(written[i]);
			}
			row.hair_state_held = true;
		}
	}
	row.reload = false;
	// Her body rig's plain poses, as the engine's update will start from them.
	Lap lap(gather_bones_ns);
	for (Bone &b : row.bones) {
		b.position = body->get_bone_pose_position(b.index);
		b.rotation = body->get_bone_pose_rotation(b.index);
		b.scale = body->get_bone_pose_scale(b.index);
		b.pose = compose(b.position, b.rotation, b.scale);
		b.global_ok = false;
		b.written = false;
	}
	return true;
}

// Worker: the body modifiers in rig order, on the row only.
void PonyRigBatch::compute_row(Row &row) {
	Body body{ row };
	const PonySolverNative *clip_solver = row.clip_ptr;
	const PonySolverNative *limits = row.limits_ptr;
	for (int32_t kind : row.order) {
		if (kind == 0 && row.clip_on && clip_solver != nullptr) {
			// face.cpp clip_head().
			for (size_t i = 0; i < row.clip_bones.size(); i++) {
				const int32_t bone = row.clip_bones[i];
				const Basis &parent = row.clip_frames[i];
				if (row.clip_rest) {
					const Vector3 look = (i == 2 ? row.clip_gaze - row.clip_neck_gaze * 0.55 : row.clip_neck_gaze * 0.275).limit_length(pony::deg_to_rad(50.0));
					Transform3D posed = body.pose(bone);
					posed.basis = parent.inverse() * pony::basis_from_euler(look) * parent * posed.basis;
					body.set_pose(bone, posed);
					continue;
				}
				const double share = i == 2 ? 0.3 : 0.35;
				const Vector3 angles = row.clip_head * share + (i == 2 ? row.clip_gaze - row.clip_neck_gaze * 0.55 : row.clip_neck_gaze * 0.275);
				Transform3D pose = body.pose(bone);
				pose.basis = clip_solver->constrain_basis(bone, parent.inverse() * pony::basis_from_euler(angles) * parent * pose.basis);
				body.set_pose(bone, pose);
			}
		} else if (kind == 1 && row.idle_on && !row.idle_skip) {
			// pony_idle_body.gd.
			row.idle_wrote_state = true;
			row.idle_last_pass = row.frame;
			row.idle_fade = move_toward(row.idle_fade, row.idle_wanted ? 1.0 : 0.0, row.delta / 0.6);
			if (row.idle_fade <= 0.0 || row.hips < 0 || !row.idle_can_apply || limits == nullptr) {
				continue;
			}
			row.idle_frame_ready = true;
			row.idle_eased = true;
			const double fade = row.idle_fade;
			const double ease = 1.0 - pony::engine_exp(-row.delta / 0.08);
			row.idle_roll = pony::lerpf(row.idle_roll, row.sec_roll, ease);
			row.idle_pitch = pony::lerpf(row.idle_pitch, double(row.sec_offset.z) * 0.8, ease);
			row.idle_breath = pony::lerpf(row.idle_breath, row.sec_breath, ease);
			row.idle_applied_roll = pony::maxf(row.idle_applied_roll, std::abs(row.idle_roll * fade));
			std::vector<Basis> leg_globals;
			for (int32_t bone : row.legs) {
				leg_globals.push_back(body.global_of(bone).basis);
			}
			const Basis &m = row.idle_model_to_skeleton;
			const Basis turn = m * pony::basis_from_euler(Vector3(row.idle_pitch, 0.0, row.idle_roll) * fade) * m.inverse();
			const Basis parent = row.hips_parent >= 0 ? body.global_of(row.hips_parent).basis.orthonormalized() : Basis();
			Transform3D hips = body.pose(row.hips);
			hips.basis = parent.inverse() * turn * parent * hips.basis;
			body.set_pose(row.hips, hips);
			if (row.spine.size() == 2 && std::abs(row.idle_breath) > 0.0005) {
				for (int32_t i = 0; i < 2; i++) {
					const int32_t bone = row.spine[i];
					const Basis &frame = row.spine_frames[i];
					const double pitch = row.breath_arch * row.idle_breath * fade * (i == 0 ? 1.0 : -1.0);
					Transform3D pose = body.pose(bone);
					pose.basis = limits->constrain_basis(bone, frame.inverse() * pony::basis_axis_angle(Vector3(1, 0, 0), pitch) * frame * pose.basis);
					body.set_pose(bone, pose);
				}
			}
			for (size_t i = 0; i < row.legs.size(); i++) {
				const int32_t bone = row.legs[i];
				const Basis moved = body.global_of(row.leg_parents[i]).basis;
				Transform3D pose = body.pose(bone);
				pose.basis = limits->constrain_basis(bone, moved.inverse() * leg_globals[i]);
				body.set_pose(bone, pose);
			}
		} else if (kind == 2 && row.filly_on && row.filly_neck >= 0 && row.filly_head >= 0) {
			// filly_proportions.gd.
			if (!equal_approx(row.neck_scale, 1.0)) {
				body.set_scale(row.filly_neck, body.scale(row.filly_neck) * row.neck_scale);
			}
			const double head_factor = row.head_scale / row.neck_scale;
			if (!equal_approx(head_factor, 1.0)) {
				body.set_scale(row.filly_head, body.scale(row.filly_head) * head_factor);
			}
			if (!equal_approx(row.head_width, 1.0)) {
				Transform3D posed = body.global_of(row.filly_head);
				posed.basis = posed.basis * row.filly_width;
				body.set_global(row.filly_head, posed);
			}
			if (!equal_approx(row.wing_scale, 1.0)) {
				for (int32_t wing : row.wings) {
					body.set_scale(wing, body.scale(wing) * row.wing_scale);
				}
			}
		} else if (kind == 3 && row.affection_on && limits != nullptr) {
			// affection_pose.gd: buck, stretch and yawn (_rotate and _limit).
			auto rotate = [&](int32_t bone, double angle) {
				if (bone < 0) {
					return;
				}
				Transform3D pose = body.global_of(bone);
				pose.basis = pony::basis_axis_angle(row.affection_axis, angle) * pose.basis;
				body.set_global(bone, pose);
				const Basis held = limits->constrain_basis(bone, Basis(body.rotation(bone)));
				body.set_rotation(bone, held.get_rotation_quaternion());
			};
			if (row.buck > 0.001) {
				rotate(row.flank[0], pony::deg_to_rad(-55) * row.buck);
				rotate(row.flank[1], pony::deg_to_rad(-55) * row.buck);
				rotate(row.leg_lower[0], pony::deg_to_rad(25) * row.buck);
				rotate(row.leg_lower[1], pony::deg_to_rad(25) * row.buck);
			}
			if (row.stretch > 0.001 || row.yawn > 0.001) {
				if (row.stretch > 0.001) {
					const int32_t s = row.stretch_left ? 0 : 1;
					rotate(row.flank[s], pony::deg_to_rad(-24) * row.stretch);
					rotate(row.leg_lower[s], pony::deg_to_rad(10) * row.stretch);
					rotate(row.tarsal[s], pony::deg_to_rad(-18) * row.stretch);
				}
				if (row.yawn > 0.001) {
					rotate(row.neck1, pony::deg_to_rad(10) * row.yawn);
					rotate(row.head_bone, pony::deg_to_rad(22) * row.yawn);
				}
			}
		}
	}
}

void PonyRigBatch::compute_job(void *data, uint32_t index) {
	PonyRigBatch *self = static_cast<PonyRigBatch *>(data);
	Row &row = self->rows[self->batch[index]];
	compute_row(row);
	row.thread = std::hash<std::thread::id>()(std::this_thread::get_id());
}

namespace {
struct Shifted {
	void (*job)(void *, uint32_t);
	void *data;
};
void run_shifted(void *user, uint32_t index) {
	const Shifted *s = static_cast<const Shifted *>(user);
	s->job(s->data, index + 1);
}
} // namespace

// Main thread, after the batch: the idle body's eased state back into its script, and this step's
// stamp on every ported script (their first line returns while it equals the physics frame).
void PonyRigBatch::post(Row &row) {
	const Names &n = names();
	if (row.idle_wrote_state) {
		if (Object *idle = live<Object>(row.idle)) {
			// Only what this pass changed (the rest already equals the script's).
			idle->set(n.last_pass_frame, row.idle_last_pass);
			if (row.idle_fade != row.idle_fade_in) {
				idle->set(n.fade, row.idle_fade);
			}
			if (row.idle_eased) {
				idle->set(n.roll_, row.idle_roll);
				idle->set(n.pitch_, row.idle_pitch);
				idle->set(n.breath_, row.idle_breath);
			}
			if (row.idle_applied_roll != row.idle_applied_in) {
				idle->set(n.applied_roll, row.idle_applied_roll);
			}
			if (row.idle_frame_ready && !row.idle_frame_in) {
				idle->set(n.frame_ready, true);
				idle->set(n.model_to_skeleton, row.idle_model_to_skeleton);
			}
		}
	}
	const ObjectID stamped[6] = { row.clip, row.idle, row.filly, row.affection, row.neck_link, row.hair_link };
	for (int32_t i = 0; i < 6; i++) {
		if (!NATIVE_LINKS && i >= 4) {
			break;
		}
		if (Object *object = live<Object>(stamped[i])) {
			object->set(n.rig_batch_step, row.frame);
		}
	}
	row.out_frame = row.frame;
}

int32_t PonyRigBatch::step(const Vector3 &p_camera, double p_delta) {
	Time *time = Time::get_singleton();
	const int64_t frame = int64_t(Engine::get_singleton()->get_physics_frames());
	const uint64_t started = time->get_ticks_usec();
	last_link_ns = update_link_ns;
	last_gather_bones_ns = gather_bones_ns;
	gather_bones_ns = 0;
	int64_t slots = 0;
	for (const Row &r : rows) {
		slots += r.bound ? int64_t(r.bones.size()) : 0;
	}
	last_slots = slots;
	last_apply_ns = update_apply_ns;
	update_link_ns = update_apply_ns = 0;
	batch.clear();
	for (int32_t i = 0; i < (int32_t)rows.size(); i++) {
		Row &row = rows[i];
		if (!row.bound) {
			continue;
		}
		const bool was = row.batched;
		row.batched = gather(row, i, p_camera, p_delta, frame, was);
		if (row.batched) {
			batch.push_back(i);
		} else {
			flush(row);
		}
	}
	const uint64_t gathered = time->get_ticks_usec();
	const uint32_t count = (uint32_t)batch.size();
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (count > 0) {
		if (tasks == 0 || count < 2 || pool == nullptr) {
			for (uint32_t i = 0; i < count; i++) {
				compute_job(this, i);
			}
		} else {
			// The calling thread runs block 0 while the pool runs the rest (navigation_parallel.cpp).
			Shifted shifted{ &PonyRigBatch::compute_job, this };
			const WorkerThreadPool::GroupID group = pool->add_native_group_task(&run_shifted, &shifted, int(count - 1),
					tasks < 0 ? -1 : tasks, true, String("Pony rig batch"));
			compute_job(this, 0);
			pool->wait_for_group_task_completion(group);
		}
	}
	const uint64_t computed = time->get_ticks_usec();
	std::unordered_set<size_t> threads;
	for (int32_t i : batch) {
		post(rows[i]);
		threads.insert(rows[i].thread);
	}
	const uint64_t posted = time->get_ticks_usec();
	last_gather_usec = int64_t(gathered - started);
	last_compute_usec = int64_t(computed - gathered);
	last_post_usec = int64_t(posted - computed);
	last_batched = int32_t(count);
	last_workers = int32_t(threads.size());
	total_batched += count;
	total_steps += 1;
	return int32_t(count);
}

// PonyRigBatchApply, inside the engine's body update: the step's writes, nothing else.
void PonyRigBatch::apply_row(int32_t p_row, Skeleton3D *p_skeleton) {
	if (!row_live(p_row) || p_skeleton == nullptr) {
		return;
	}
	Row &row = rows[p_row];
	Engine *engine = Engine::get_singleton();
	if (!row.batched || row.out_frame != int64_t(engine->get_physics_frames()) || !engine->is_in_physics_frame() ||
			live<Skeleton3D>(row.body) != p_skeleton) {
		row.reload = true; // her body modifiers ran in their scripts this update
		return;
	}
	apply_calls++;
	Lap lap(update_apply_ns);
	for (const Bone &b : row.bones) {
		if (!b.written) {
			continue;
		}
		p_skeleton->set_bone_pose_position(b.index, b.position);
		p_skeleton->set_bone_pose_rotation(b.index, b.rotation);
		p_skeleton->set_bone_pose_scale(b.index, b.scale);
	}
}

// hybrid_neck_link.gd _on_source_updated and hybrid_hair_link.gd _body_updated for a batched pony,
// inside her body's skeleton_updated (their scripts return this step). Static link data comes from
// the audit, the switches from this step's gather, the hair link's skip state from the row.
void PonyRigBatch::_body_updated(int32_t p_row) {
	if (!row_live(p_row)) {
		return;
	}
	Row &row = rows[p_row];
	Engine *engine = Engine::get_singleton();
	if (!row.batched || row.out_frame != int64_t(engine->get_physics_frames()) || !engine->is_in_physics_frame()) {
		row.reload = true; // the scripts ran this update: read their state again on entry
		return;
	}
	link_calls++;
	Lap lap(update_link_ns);
	Skeleton3D *body = live<Skeleton3D>(row.body);
	Skeleton3D *source = live<Skeleton3D>(row.link_source);
	Skeleton3D *target = live<Skeleton3D>(row.link_target);
	if (row.neck_on && source != nullptr && target != nullptr && source->is_inside_tree() && target->is_inside_tree()) {
		// Read each time, never held: a held reference kept the script's Dictionary (and its
		// Transform3D values) alive past the engine's Variant pool check at exit.
		Dictionary source_poses = live<Object>(row.neck_link)->get(names().source_poses);
		const Transform3D into_target = target->get_global_transform().affine_inverse();
		for (size_t i = 0; i < row.neck_source_bones.size(); i++) {
			const int32_t bone = row.neck_source_bones[i];
			const Transform3D source_pose = source->get_bone_global_pose(bone);
			source_poses[bone] = source_pose;
			const Transform3D world = source->get_global_transform() * source_pose * row.neck_offsets[i];
			target->set_bone_global_pose(row.neck_target_bones[i], into_target * world);
		}
	}
	Skeleton3D *hair = live<Skeleton3D>(row.link_hair);
	if (!row.hair_enabled || hair == nullptr || !hair->is_inside_tree()) {
		invalidate_hair(row);
		return;
	}
	Skeleton3D *link_body = row.link_body.is_valid() ? live<Skeleton3D>(row.link_body) : body;
	if (link_body == nullptr) {
		return;
	}
	const Transform3D world = link_body->get_global_transform() * link_body->get_bone_global_pose(row.body_hips) * row.pelvis_offset;
	const Transform3D aim = hair->get_global_transform().affine_inverse() * world;
	if (!(row.skip_unchanged && row.pelvis_valid && aim.is_equal_approx(row.pelvis_written))) {
		hair->set_bone_global_pose(row.hair_pelvis, aim);
		// Written through to the script, so its own pass (off the batch, or an update between
		// steps) starts from the same state.
		Object *link = live<Object>(row.hair_link);
		const Names &n = names();
		row.pelvis_written = aim;
		link->set(n.pelvis_written, aim);
		if (!row.pelvis_valid) {
			row.pelvis_valid = true;
			link->set(n.pelvis_valid, true);
		}
		if (!row.pelvis_moved) {
			row.pelvis_moved = true;
			link->set(n.pelvis_moved, true);
		}
	}
}

// hybrid_hair_link.gd _head_updated for a batched pony, inside her head's skeleton_updated.
void PonyRigBatch::_head_updated(int32_t p_row) {
	if (!row_live(p_row)) {
		return;
	}
	Row &row = rows[p_row];
	Engine *engine = Engine::get_singleton();
	if (!row.batched || row.out_frame != int64_t(engine->get_physics_frames()) || !engine->is_in_physics_frame()) {
		row.reload = true; // the scripts ran this update: read their state again on entry
		return;
	}
	link_calls++;
	Lap lap(update_link_ns);
	Skeleton3D *hair = live<Skeleton3D>(row.link_hair);
	Skeleton3D *head = live<Skeleton3D>(row.link_head);
	if (!row.hair_enabled || hair == nullptr || !hair->is_inside_tree() || head == nullptr) {
		invalidate_hair(row);
		return;
	}
	static const double FOLLOW_SHARE[2] = { 0.6, 1.0 };
	const std::vector<Vector2i> &pairs = row.head_pairs;
	bool changed = !row.skip_unchanged || !row.head_valid || row.pelvis_moved || pairs.size() != row.head_written.size();
	const Transform3D into_hair = hair->get_global_transform().affine_inverse();
	Transform3D targets[8];
	const size_t count = MIN(pairs.size(), size_t(8));
	for (size_t i = 0; i < count; i++) {
		const Vector2i pair = pairs[i];
		Transform3D posed = head->get_bone_global_pose(pair.x);
		if (i < 2 && row.follow_head > 0.0) {
			const Transform3D skull = head->get_bone_global_pose(pairs[2].x) * row.head_rest_inverse;
			posed = pony::interpolate(posed, skull * head->get_bone_global_rest(pair.x), row.follow_head * FOLLOW_SHARE[i]);
		}
		if (i == 2) {
			const Transform3D motion = posed * row.head_rest_inverse;
			posed = motion * row.skull_frame * motion.affine_inverse() * posed;
		}
		const Transform3D world = head->get_global_transform() * posed * Transform3D(Basis(), row.head_offsets[i]);
		targets[i] = into_hair * world;
		if (!changed && !targets[i].is_equal_approx(row.head_written[i])) {
			changed = true;
		}
	}
	if (changed) {
		for (size_t i = 0; i < count; i++) {
			hair->set_bone_global_pose(pairs[i].y, targets[i]);
		}
		row.head_written.assign(targets, targets + count);
		const Names &n = names();
		Object *link = live<Object>(row.hair_link);
		// `_head_written = targets`: a new typed array, as the script assigns.
		TypedArray<Transform3D> fresh;
		for (size_t i = 0; i < count; i++) {
			fresh.push_back(targets[i]);
		}
		link->set(n.head_written, fresh);
		if (!row.head_valid) {
			row.head_valid = true;
			link->set(n.head_valid, true);
		}
		if (row.pelvis_moved) {
			row.pelvis_moved = false;
			link->set(n.pelvis_moved, false);
		}
	}
}

void PonyRigBatch::invalidate_hair(Row &row) {
	const Names &n = names();
	Object *link = live<Object>(row.hair_link);
	if (row.pelvis_valid) {
		row.pelvis_valid = false;
		link->set(n.pelvis_valid, false);
	}
	if (row.head_valid) {
		row.head_valid = false;
		link->set(n.head_valid, false);
	}
}

// The step she leaves the batch (or the batch lets go of her): the held copies of script state are
// dropped (every change was written through), so her next entry reads them again.
void PonyRigBatch::flush(Row &row) {
	row.hair_state_held = false;
}

void PonyRigBatch::release_all() {
	for (Row &row : rows) {
		if (row.bound) {
			flush(row);
			row.batched = false;
			row.reason = "released";
		}
	}
	last_batched = 0;
}

void PonyRigBatch::hold(int32_t p_row, bool p_hold) {
	if (row_live(p_row)) {
		rows[p_row].fixture_hold = p_hold;
	}
}

void PonyRigBatch::set_tasks(int32_t p_tasks) {
	tasks = p_tasks;
}

bool PonyRigBatch::is_batched(int32_t p_row) const {
	return row_live(p_row) && rows[p_row].batched;
}

String PonyRigBatch::why(int32_t p_row) const {
	if (!row_live(p_row)) {
		return "not bound";
	}
	return rows[p_row].batched ? String() : rows[p_row].reason;
}

Dictionary PonyRigBatch::stats() const {
	Dictionary d;
	d["gather_usec"] = last_gather_usec;
	d["compute_usec"] = last_compute_usec;
	d["post_usec"] = last_post_usec;
	d["batched"] = last_batched;
	d["workers"] = last_workers;
	d["total_batched"] = total_batched;
	d["total_steps"] = total_steps;
	d["link_calls"] = link_calls;
	d["link_usec"] = double(last_link_ns) / 1000.0;
	d["apply_usec"] = double(last_apply_ns) / 1000.0;
	d["gather_bones_usec"] = double(last_gather_bones_ns) / 1000.0;
	d["slots"] = last_slots;
	d["apply_calls"] = apply_calls;
	int32_t bound = 0;
	for (const Row &row : rows) {
		bound += row.bound ? 1 : 0;
	}
	d["bound"] = bound;
	return d;
}

void PonyRigBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "body_scripts", "head_scripts", "hair_scripts", "listener_keys", "breath_arch", "serial_radius",
								 "audit_steps"),
			&PonyRigBatch::configure);
	ClassDB::bind_method(D_METHOD("bind_pony", "pony", "body", "head", "hair", "neck_link", "hair_link", "apply"), &PonyRigBatch::bind_pony);
	ClassDB::bind_method(D_METHOD("unbind", "row"), &PonyRigBatch::unbind);
	ClassDB::bind_method(D_METHOD("mark_dirty", "row"), &PonyRigBatch::mark_dirty);
	ClassDB::bind_method(D_METHOD("step", "camera", "delta"), &PonyRigBatch::step);
	ClassDB::bind_method(D_METHOD("set_tasks", "tasks"), &PonyRigBatch::set_tasks);
	ClassDB::bind_method(D_METHOD("release_all"), &PonyRigBatch::release_all);
	ClassDB::bind_method(D_METHOD("hold", "row", "hold"), &PonyRigBatch::hold);
	ClassDB::bind_method(D_METHOD("is_batched", "row"), &PonyRigBatch::is_batched);
	ClassDB::bind_method(D_METHOD("why", "row"), &PonyRigBatch::why);
	ClassDB::bind_method(D_METHOD("stats"), &PonyRigBatch::stats);
}

void PonyRigBatchApply::setup(Object *p_batch, int32_t p_row) {
	batch = p_batch != nullptr ? ObjectID(p_batch->get_instance_id()) : ObjectID();
	row = p_row;
}

void PonyRigBatchApply::_process_modification_with_delta(double p_delta) {
	(void)p_delta;
	PonyRigBatch *owner = live<PonyRigBatch>(batch);
	if (owner != nullptr) {
		owner->apply_row(row, get_skeleton());
	}
}

void PonyRigBatchApply::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "batch", "row"), &PonyRigBatchApply::setup);
}
