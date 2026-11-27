// Native hand-off of the batched route follower (lane follow, 2026-11-21). See nav_follow_native.h.
// Each block below names the line of native_follow_driver.gd or pony_navigator.gd it repeats.
#include "nav_follow_native.h"

#include "pony_navigation_native.h"

#include <godot_cpp/classes/character_body3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/geometry3d.hpp>
#include <godot_cpp/classes/navigation_agent3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

namespace godot {

namespace {

constexpr int64_t INPUT_STRIDE = 13;
constexpr int64_t COMMAND_STRIDE = 4;
const char *NAVIGATOR_PATH = "res://world/characters/navigation/pony_navigator.gd";

// Names read and written on navigators and ponies, made once.
struct Names {
	StringName native_row_frame{ "_native_row_frame" };
	StringName native_handle{ "_native_handle" };
	StringName native_service{ "_native_service" };
	StringName native_inputs{ "_native_inputs" };
	StringName pony{ "pony" };
	StringName followers{ "_followers" };
	StringName ground_velocity{ "_ground_velocity" };
	StringName native_follow_sync{ "native_follow_sync" };
	StringName stop{ "stop" };
	StringName native_apply{ "_native_apply" };
	StringName on_native_event{ "_on_native_event" };
	StringName slot{ "slot" };
	StringName generation{ "generation" };
	StringName instance{ "instance" };
	StringName state{ "state" };
	StringName reason{ "reason" };
	StringName accept_navigation_motion{ "accept_navigation_motion" };
	StringName native_mode{ "_native_mode" };
	StringName native_progress{ "_native_progress" };
	StringName native_reason{ "_native_reason" };
	StringName native_wait{ "_native_wait" };
	StringName desired_velocity{ "_desired_velocity" };
	StringName avoid_last_position{ "_avoid_last_position" };
	StringName avoid_submit_intent{ "_avoid_submit_intent" };
	StringName native_intent{ "_native_intent" };
	StringName agent{ "agent" };
	StringName path{ "path" };
	StringName waypoint{ "_waypoint" };
	StringName lookahead_cache{ "_lookahead_cache" };
	StringName stuck_time{ "_stuck_time" };
	String following_route{ "Following route" };
	String turning{ "Turning round (stepping)" };
	String yielding{ "Yielding to other ponies" };
	String braking{ "No safe arc; braking" };
	String waiting_extension{ "Waiting for route extension" };
};

Names &names() {
	static Names value;
	return value;
}

// is_instance_valid() by id, without the binding lookup when the object is gone.
Object *alive(ObjectID p_id) {
	if (!p_id.is_valid() || internal::gdextension_interface_object_get_instance_from_id(uint64_t(p_id)) == nullptr) {
		return nullptr;
	}
	return ObjectDB::get_instance(p_id);
}

PackedInt64Array handle_of(Object *p_navigator) {
	Variant held = p_navigator->get(names().native_handle);
	return held.get_type() == Variant::PACKED_INT64_ARRAY ? PackedInt64Array(held) : PackedInt64Array();
}

Vector3 ground_velocity_of(Object *p_pony) {
	Variant velocity = p_pony->get(names().ground_velocity);
	return velocity.get_type() == Variant::VECTOR3 ? Vector3(velocity) : Vector3();
}

// pony_navigator.gd _flat_distance: GDScript subtracts the components as doubles, then builds a Vector2.
real_t flat_distance(const Vector3 &p_a, const Vector3 &p_b) {
	return Vector2(double(p_a.x) - double(p_b.x), double(p_a.z) - double(p_b.z)).length();
}

} // namespace

void PonyNavFollowDriverNative::native_configure(const Ref<Script> &p_backend) {
	backend = p_backend;
}

void PonyNavFollowDriverNative::native_submit(Object *p_navigator) {
	// submit(): _rows.append(navigator). A null is kept as a row the batch skips (is_instance_valid).
	rows.push_back(p_navigator != nullptr ? ObjectID(p_navigator->get_instance_id()) : ObjectID());
}

void PonyNavFollowDriverNative::native_invalidate_peers() {
	peers_dirty = true;
}

// _refresh_peer_snapshot()
void PonyNavFollowDriverNative::refresh_peers() {
	if (!peers_dirty) {
		return;
	}
	peers_dirty = false;
	peer_navs.clear();
	peer_ponies.clear();
	peer_keys.clear();
	peer_slots.clear();
	SceneTree *tree = get_tree();
	TypedArray<Node> group = tree != nullptr ? tree->get_nodes_in_group("pony_navigators") : TypedArray<Node>();
	for (int64_t i = 0; i < group.size(); i++) {
		Node *navigator = Object::cast_to<Node>(group[i]);
		if (navigator == nullptr) {
			continue;
		}
		// _peer_slots[navigator] = size: a navigator listed twice keeps her last slot, as a Dictionary does.
		peer_slots[uint64_t(navigator->get_instance_id())] = int64_t(peer_navs.size());
		peer_navs.push_back(ObjectID(navigator->get_instance_id()));
		Node3D *pony = Object::cast_to<Node3D>(navigator->get(names().pony));
		peer_ponies.push_back(pony != nullptr ? ObjectID(pony->get_instance_id()) : ObjectID());
		PackedInt64Array handle = handle_of(navigator);
		peer_keys.push_back(handle.size() == 2 ? ((handle[0] << 32) | handle[1])
											   : ((int64_t(1) << 62) | (int64_t(navigator->get_instance_id()) & int64_t(0xffffffffffff))));
	}
	peer_stamp.assign(peer_navs.size(), -1);
	peer_refreshes += 1;
}

const PonyNavFollowDriverNative::ApplyScript &PonyNavFollowDriverNative::apply_script_of(Object *p_navigator) {
	static const ApplyScript none;
	Ref<Script> script = p_navigator->get_script();
	if (script.is_null()) {
		return none;
	}
	uint64_t key = uint64_t(script->get_instance_id());
	auto found = apply_scripts.find(key);
	if (found != apply_scripts.end()) {
		return found->second;
	}
	ApplyScript entry;
	if (script->get_path() == NAVIGATOR_PATH) {
		Dictionary constants = script->get_script_constant_map();
		entry.native = bool(constants.get("NATIVE_FOLLOW_STATE", false));
		Dictionary states = constants.get("State", Dictionary());
		entry.state_moving = int64_t(states.get("MOVING", 0));
		entry.state_waiting = int64_t(states.get("WAITING", 0));
		entry.leg_start_speed = double(constants.get("LEG_START_SPEED", 0.05));
		entry.mode_travel = int64_t(constants.get("NATIVE_MODE_TRAVEL", 1));
		entry.mode_step_turn = int64_t(constants.get("NATIVE_MODE_STEP_TURN", 2));
		Array reasons = constants.get("NATIVE_REASONS", Array());
		for (int64_t i = 0; i < reasons.size(); i++) {
			entry.reasons.push_back(String(reasons[i]));
		}
		Array informational = constants.get("NATIVE_INFORMATIONAL", Array());
		for (int64_t i = 0; i < informational.size(); i++) {
			entry.informational.push_back(int64_t(informational[i]));
		}
		if (!states.has("MOVING") || !states.has("WAITING") || reasons.is_empty()) {
			entry.native = false;
		}
	}
	return apply_scripts.emplace(key, entry).first->second;
}

// pony_navigator.gd _native_apply, for a navigator whose script is exactly pony_navigator.gd.
void PonyNavFollowDriverNative::apply_row(Object *p_navigator, Node3D *p_pony, const ApplyScript &p_script,
		const PackedFloat32Array &p_commands, const PackedFloat32Array &p_states, const Vector3 &p_preferred, int64_t p_row) {
	Names &n = names();
	const int64_t at = p_row * 4;
	const float *commands = p_commands.ptr();
	const float *states = p_states.ptr();
	NavigationAgent3D *agent = Object::cast_to<NavigationAgent3D>(p_navigator->get(n.agent));
	if (commands[at] == 0.0f || agent == nullptr) {
		// The follower no longer owns her (rare), or no agent: the script's own body.
		p_navigator->call(n.native_apply, p_commands, p_states, p_preferred, p_row);
		return;
	}
	double speed = double(commands[at + 1]);
	const int64_t mode = int64_t(commands[at + 3]);
	if (speed > 0.0 && speed <= p_script.leg_start_speed && int64_t(p_pony->get(n.state)) == 0 && mode != p_script.mode_step_turn) {
		speed = mode == p_script.mode_travel && double(p_preferred.length()) > p_script.leg_start_speed ? p_script.leg_start_speed + 0.01 : 0.0;
	}
	p_pony->call(n.accept_navigation_motion, speed, double(commands[at + 2]), mode, double(p_preferred.length()));
	const int64_t si = p_row * 8;
	p_navigator->set(n.native_mode, mode);
	p_navigator->set(n.native_progress, double(states[si]));
	const int64_t reason = int64_t(states[si + 5]);
	p_navigator->set(n.native_reason, reason);
	const bool informational = std::find(p_script.informational.begin(), p_script.informational.end(), reason) != p_script.informational.end();
	p_navigator->set(n.native_wait, informational || reason < 0 || reason >= int64_t(p_script.reasons.size()) ? String() : p_script.reasons[reason]);
	int64_t state = p_script.state_moving;
	const String *text = &n.following_route;
	switch (reason) {
		case 1: text = &n.turning; break;
		case 2: text = &n.yielding; break;
		case 3: text = &n.braking; break;
		case 4:
		case 15: state = p_script.state_waiting; text = &n.waiting_extension; break;
		default: break;
	}
	p_navigator->set(n.state, state);
	p_navigator->set(n.reason, *text);
	p_navigator->set(n.desired_velocity, p_preferred);
	const Vector3 last = p_navigator->get(n.avoid_last_position);
	if (!last.is_finite() || p_pony->get_global_position().distance_squared_to(last) > 9.0) {
		Variant ground = p_pony->get(n.ground_velocity);
		Vector3 actual;
		if (ground.get_type() == Variant::VECTOR3) {
			actual = ground;
		} else {
			CharacterBody3D *body = Object::cast_to<CharacterBody3D>(p_pony);
			actual = body != nullptr ? body->get_velocity() : Vector3(p_pony->get("velocity"));
		}
		agent->set_velocity_forced(Vector3(actual.x, 0.0, actual.z));
	}
	p_navigator->set(n.avoid_last_position, p_pony->get_global_position());
	agent->set_velocity(p_preferred);
	p_navigator->set(n.avoid_submit_intent, p_navigator->get(n.native_intent));
	// The route point she has passed, never going back.
	const Vector3 position = p_pony->get_global_position();
	const PackedVector3Array path = p_navigator->get(n.path);
	const int64_t waypoint = p_navigator->get(n.waypoint);
	int64_t best = waypoint;
	double nearest = std::numeric_limits<double>::infinity();
	Geometry3D *geometry = Geometry3D::get_singleton();
	const int64_t end = std::min(waypoint + 4, int64_t(path.size()));
	for (int64_t i = std::max(waypoint, int64_t(1)); i < end; i++) {
		const Vector3 closest = geometry->get_closest_point_to_segment(position, path[i - 1], path[i]);
		const double gap = flat_distance(position, closest);
		if (gap < nearest - 0.001) {
			nearest = gap;
			best = i;
		}
	}
	p_navigator->set(n.waypoint, std::max(waypoint, best));
	const double lookahead = double(states[si + 2]);
	const Vector3 forward = p_preferred.length_squared() > 1e-6 ? p_preferred.normalized() : -p_pony->get_global_basis().get_column(2);
	p_navigator->set(n.lookahead_cache, position + forward * real_t(lookahead));
	p_navigator->set(n.stuck_time, 0.0);
}

int64_t PonyNavFollowDriverNative::native_batch(double p_delta) {
	Names &n = names();
	if (rows.empty()) {
		return 0;
	}
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	const int64_t frame = int64_t(Engine::get_singleton()->get_physics_frames());
	PonyNavigationNative *native = backend.is_valid() ? Object::cast_to<PonyNavigationNative>(backend->call(n.instance)) : nullptr;
	if (native == nullptr) {
		rows.clear();
		return 0;
	}
	// Followers first, in submission order; rows from an earlier frame are dropped.
	std::vector<Object *> followers;
	std::vector<ObjectID> follower_ids;
	followers.reserve(rows.size());
	for (const ObjectID &id : rows) {
		Object *navigator = alive(id);
		if (navigator == nullptr) {
			continue;
		}
		if (int64_t(navigator->get(n.native_row_frame)) == frame && handle_of(navigator).size() == 2) {
			followers.push_back(navigator);
			follower_ids.push_back(id);
		}
	}
	rows.clear();
	// The script's reused _followers buffer holds this batch's followers, as before (labs read it).
	Variant listed = get(n.followers);
	if (listed.get_type() == Variant::ARRAY) {
		Array list = listed;
		list.clear();
		for (Object *navigator : followers) {
			list.append(navigator);
		}
	}
	if (followers.empty()) {
		return 0;
	}
	std::vector<Object *> services;
	for (Object *navigator : followers) {
		Object *service = navigator->get(n.native_service);
		if (service != nullptr && alive(ObjectID(service->get_instance_id())) != nullptr &&
				std::find(services.begin(), services.end(), service) == services.end()) {
			services.push_back(service);
		}
	}
	for (Object *service : services) {
		service->call(n.native_follow_sync);
	}
	const int64_t count = int64_t(followers.size());
	// Built in plain vectors (a packed array's set/push_back is one engine call per value), then copied
	// into the packed buffers step_batch takes.
	std::vector<int64_t> key_rows(count * 2);
	std::vector<Vector3> position_rows(count);
	std::vector<Vector3> velocity_rows(count);
	std::vector<float> heading_rows(count);
	std::vector<float> input_rows;
	input_rows.reserve(size_t(count + peer_navs.size()) * INPUT_STRIDE);
	for (int64_t i = 0; i < count; i++) {
		Object *navigator = followers[i];
		Node3D *pony = Object::cast_to<Node3D>(navigator->get(n.pony));
		if (pony == nullptr) {
			// The script stops here with an error (pony.global_position on null).
			UtilityFunctions::push_error("Native follow driver: a queued navigator has no pony");
			return 1;
		}
		PackedInt64Array handle = handle_of(navigator);
		const int64_t *held = handle.ptr();
		key_rows[i * 2] = held[0];
		key_rows[i * 2 + 1] = held[1];
		position_rows[i] = pony->get_global_position();
		velocity_rows[i] = ground_velocity_of(pony);
		heading_rows[i] = pony->get_rotation().y;
		PackedFloat32Array row = navigator->get(n.native_inputs);
		const float *values = row.ptr();
		input_rows.insert(input_rows.end(), values, values + row.size());
	}
	// Observers: every other navigating pony is a neighbour (OBSERVER_CACHE path).
	refresh_peers();
	for (Object *navigator : followers) {
		auto slot = peer_slots.find(uint64_t(navigator->get_instance_id()));
		if (slot != peer_slots.end() && slot->second >= 0) {
			peer_stamp[slot->second] = frame;
		}
	}
	int64_t observers = 0;
	for (size_t i = 0; i < peer_navs.size(); i++) {
		if (peer_stamp[i] == frame) {
			continue;
		}
		Node *navigator = Object::cast_to<Node>(alive(peer_navs[i]));
		if (navigator == nullptr) {
			continue;
		}
		Node3D *pony = Object::cast_to<Node3D>(alive(peer_ponies[i]));
		if (pony == nullptr || !pony->is_inside_tree()) {
			continue;
		}
		if (!navigator->is_inside_tree()) {
			continue;
		}
		observers += 1;
		key_rows.push_back(-1);
		key_rows.push_back(peer_keys[i]);
		position_rows.push_back(pony->get_global_position());
		velocity_rows.push_back(ground_velocity_of(pony));
		heading_rows.push_back(pony->get_rotation().y);
		input_rows.insert(input_rows.end(), size_t(INPUT_STRIDE), 0.0f);
	}
	keys.resize(int64_t(key_rows.size()));
	std::copy(key_rows.begin(), key_rows.end(), keys.ptrw());
	positions.resize(int64_t(position_rows.size()));
	std::copy(position_rows.begin(), position_rows.end(), positions.ptrw());
	velocities.resize(int64_t(velocity_rows.size()));
	std::copy(velocity_rows.begin(), velocity_rows.end(), velocities.ptrw());
	headings.resize(int64_t(heading_rows.size()));
	std::copy(heading_rows.begin(), heading_rows.end(), headings.ptrw());
	inputs.resize(int64_t(input_rows.size()));
	std::copy(input_rows.begin(), input_rows.end(), inputs.ptrw());
	const int64_t total = count + observers;
	const uint64_t gathered = Time::get_singleton()->get_ticks_usec();
	last_gather_us = int64_t(gathered - started);
	PackedFloat32Array commands = native->step_batch(keys, positions, velocities, headings, p_delta, inputs);
	const uint64_t stepped = Time::get_singleton()->get_ticks_usec();
	last_step_us = int64_t(stepped - gathered);
	batches += 1;
	rows_stepped += count;
	observers_added += observers;
	if (commands.size() != total * COMMAND_STRIDE) {
		// Never leave yesterday's velocity running: every follower stops and replans.
		invalid_buffers += 1;
		UtilityFunctions::push_error(vformat("Native follower returned %d command floats for %d rows; stopping the followers", commands.size(), total));
		for (Object *navigator : followers) {
			Object *pony = navigator->get(n.pony);
			if (pony != nullptr) {
				pony->call(n.stop);
			}
		}
		last_apply_us = 0;
		last_batch_us = int64_t(Time::get_singleton()->get_ticks_usec() - started);
		return 1;
	}
	PackedFloat32Array states = native->batch_state();
	PackedVector3Array preferred_rows = native->batch_preferred_velocities();
	const Vector3 *preferred = preferred_rows.ptr();
	for (int64_t i = 0; i < count; i++) {
		Object *navigator = alive(follower_ids[i]);
		if (navigator == nullptr) {
			continue;
		}
		Node3D *pony = Object::cast_to<Node3D>(navigator->get(n.pony));
		if (pony == nullptr || alive(ObjectID(pony->get_instance_id())) == nullptr) {
			continue;
		}
		const ApplyScript &script = apply_script_of(navigator);
		if (script.native) {
			apply_row(navigator, pony, script, commands, states, preferred[i], i);
		} else {
			navigator->call(n.native_apply, commands, states, preferred[i], i);
		}
	}
	Array events = native->take_follow_events();
	for (int64_t e = 0; e < events.size(); e++) {
		Dictionary event = events[e];
		const int64_t slot = int64_t(event.get(n.slot, -1));
		const int64_t generation = int64_t(event.get(n.generation, -1));
		for (const ObjectID &id : follower_ids) {
			Object *navigator = alive(id);
			if (navigator == nullptr) {
				continue;
			}
			PackedInt64Array handle = handle_of(navigator);
			if (handle.size() >= 2 && handle[0] == slot && handle[1] == generation) {
				navigator->call(n.on_native_event, event);
				break;
			}
		}
	}
	const uint64_t ended = Time::get_singleton()->get_ticks_usec();
	last_apply_us = int64_t(ended - stepped);
	last_batch_us = int64_t(ended - started);
	return 1;
}

TypedArray<Node> PonyNavFollowDriverNative::native_nearby_navigators(const Vector3 &p_at, double p_radius) {
	// nearby_navigators(): the snapshot's navigators whose pony stands within the radius.
	TypedArray<Node> result;
	for (const ObjectID &id : peer_navs) {
		Node *navigator = Object::cast_to<Node>(alive(id));
		if (navigator == nullptr) {
			continue;
		}
		Node3D *pony = Object::cast_to<Node3D>(navigator->get(names().pony));
		if (pony == nullptr || alive(ObjectID(pony->get_instance_id())) == nullptr) {
			continue;
		}
		if (double(pony->get_global_position().distance_squared_to(p_at)) <= p_radius * p_radius) {
			result.append(navigator);
		}
	}
	return result;
}

Array PonyNavFollowDriverNative::native_last_buffers() const {
	Array result;
	result.append(keys);
	result.append(positions);
	result.append(velocities);
	result.append(headings);
	result.append(inputs);
	return result;
}

void PonyNavFollowDriverNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("native_configure", "backend"), &PonyNavFollowDriverNative::native_configure);
	ClassDB::bind_method(D_METHOD("native_submit", "navigator"), &PonyNavFollowDriverNative::native_submit);
	ClassDB::bind_method(D_METHOD("native_invalidate_peers"), &PonyNavFollowDriverNative::native_invalidate_peers);
	ClassDB::bind_method(D_METHOD("native_batch", "delta"), &PonyNavFollowDriverNative::native_batch);
	ClassDB::bind_method(D_METHOD("native_nearby_navigators", "at", "radius"), &PonyNavFollowDriverNative::native_nearby_navigators);
	ClassDB::bind_method(D_METHOD("native_last_buffers"), &PonyNavFollowDriverNative::native_last_buffers);
#define FOLLOW_COUNTER(m_name)                                                                              \
	ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &PonyNavFollowDriverNative::set_##m_name);   \
	ClassDB::bind_method(D_METHOD("get_" #m_name), &PonyNavFollowDriverNative::get_##m_name);            \
	ADD_PROPERTY(PropertyInfo(Variant::INT, #m_name), "set_" #m_name, "get_" #m_name);
	FOLLOW_COUNTER(batches)
	FOLLOW_COUNTER(rows_stepped)
	FOLLOW_COUNTER(observers_added)
	FOLLOW_COUNTER(invalid_buffers)
	FOLLOW_COUNTER(last_batch_us)
	FOLLOW_COUNTER(peer_refreshes)
#undef FOLLOW_COUNTER
	ClassDB::bind_method(D_METHOD("get_last_gather_us"), &PonyNavFollowDriverNative::get_last_gather_us);
	ClassDB::bind_method(D_METHOD("get_last_step_us"), &PonyNavFollowDriverNative::get_last_step_us);
	ClassDB::bind_method(D_METHOD("get_last_apply_us"), &PonyNavFollowDriverNative::get_last_apply_us);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "last_gather_us"), "", "get_last_gather_us");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "last_step_us"), "", "get_last_step_us");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "last_apply_us"), "", "get_last_apply_us");
}

} // namespace godot
