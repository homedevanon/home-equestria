extends PonyTailMotionNative
## Pinned native tail with damped joints and contact constraints.
##
## Native step (2026-11-21, lane tail of the native pony step; captures/perf_2026-11-21/port_tail.md):
## the per-step body below also exists in PonyTailMotionNative.native_step()
## (native/pony_solver/src/tail_motion_native.cpp), line for line. The hot state is the native base's
## properties, under the names these variables had: pony, springs, aside_goal, _previous_velocity,
## _history, _skipped_delta, _read_bones, _to, _from_rotation, _to_rotation, _steps, _ray_floor,
## _plane_floor, _aside, _settled, _quiet, _recheck, _settle_mount, _settle_reach, _last_mount,
## _last_angles, _settled_writes, _wake_now, _pose_dirty, _solo, _solo_children. While the native
## step runs, the springs' state is held natively and reading `springs` writes it back first, so
## every caller of `tail_motion.springs` sees the current tail. native_step() returns false (and
## _script_step() below runs) for springs it does not mirror (a replaced script, the GDScript-only
## solver). Bit-identical to the script in the parity fixtures; about 3.3 us instead of 10 to 11 us per
## NEAR pony per step (rig_batch_costs.gd). Rollback: NATIVE_STEP = false (or `--tail-native=off`;
## `--tail-native=on` forces it for one run). With it off the script body runs on the native
## properties, about 5 us per pony slower than before the port; the full rollback is the script as it
## was, archive/native-pony-step-tail-2026-11-21/hybrid_tail_motion.gd.before.
## Constants used by the native step are copied there; change both.
const NATIVE_STEP := true
static var _native_on: bool = _native_wanted()
const SPRINGS := preload("res://world/characters/hybrid_mare/hybrid_tail_physics.gd")
var _pose:Array[Transform3D]=[]
var _body_ends:=PackedInt32Array()
## Tail bone poses of the last two integrations (the springs only rotate the joints; offsets and
## scales stay at rest) and the steps since the latest: _to, _from_rotation, _to_rotation, _steps.
## Tail floor contacts: real rays on the solver; in the clip tiers the plane her own floor rays
## measured (six rays every 50 ms per pony were two thirds of a clip pony's rays): _ray_floor,
## _plane_floor.
## Swing the whole tail aside about her up axis (radians; + puts the tip toward her right), eased:
## aside_goal, eased by _aside.
## The spa table sets it so the player's hands reach the back hoof the tail lay over (dev
## 2026-10-29: "her tail is in the way, it should move out of the way"). Applied after the springs,
## so their own angles and floor contacts are unchanged; clamped inside mTail1's bend limit.
const ASIDE_SPEED := 1.2

## Settled tail (0.1.0 perf pass). Standing still with the springs at rest, an integration and
## contact pass only rebuild the pose the tail already holds (about 28 us each, 20-60 times a
## second per pony). Settled, the tail keeps that pose on her rump and the springs sleep, until she
## moves, her rump drifts SETTLE_MOVE / SETTLE_TURN from where it settled, a swish or kick stirs the
## springs, or the SETTLE_RECHECK pass (the full integration and floor contact, as before) finds
## the pose changed. Thresholds sit far below what the springs answer visibly: a 0.5 degree turn of
## the rump moves their gravity rest by about 0.0004 rad. Rollback: TAIL_SETTLE = false.
const TAIL_SETTLE := true
const SETTLE_SECONDS := 0.5
const SETTLE_RECHECK := 1.0
const SETTLE_MOVE := 0.002
const SETTLE_TURN := 0.008
## Body speed (m/s), joint speed (rad/s) and joint change per integration (rad) counted as still.
const QUIET_SPEED := 0.02
const QUIET_SPIN := 0.02
const QUIET_STEP := 0.0005
## State: _settled, _quiet, _recheck, _settle_mount, _settle_reach, _last_mount, _last_angles, and
## _settled_writes (settled writes since settling: the first rewrites the held pose over the last
## in-between one), _wake_now.
## Skipped hair pass (0.1.0 perf pass). With the tail settled and nothing else posing the hair rig
## (no hair-link write, no other pose write: Skeleton3D's pose_updated), rewriting the held pose
## only re-skinned the same mane and tail every tick. Writing nothing lets Skeleton3D end the pass
## before skinning, and the skinned tail stays exactly as it was. Any pose write on the rig, another
## modifier on it, an aside swing, or petting hands (pony_touch_body reads the rig directly when no
## skin pass ran) writes as before. Rollback: HAIR_PASS_SKIP = false.
const HAIR_PASS_SKIP := true
## State: _pose_dirty, _solo, _solo_children.


static func _native_wanted() -> bool:
	var args := OS.get_cmdline_user_args()
	if "--tail-native=off" in args: return false
	return (NATIVE_STEP or "--tail-native=on" in args) and TAIL_SETTLE and HAIR_PASS_SKIP

func bind(owner_pony: Node3D) -> void:
	pony = owner_pony
	springs = SPRINGS.new()
	springs.bone_names = ["mTail1","mTail2","mTail3","mTail4","mTail5","mTail6"]
	springs.mount_name = "mPelvis"
	var identity: Resource = pony.get("identity")
	if identity != null:
		var limits: Array = []
		for deg in identity.tail_bend_limits_deg: limits.append(deg_to_rad(float(deg)))
		springs.angle_limits = limits
		springs.terminal_length = identity.tail_terminal_length
		springs.segment_radii = PackedFloat32Array(identity.tail_segment_radii)
	else:
		springs.angle_limits = [deg_to_rad(60),deg_to_rad(75),deg_to_rad(80),deg_to_rad(80),deg_to_rad(75),deg_to_rad(70)]
		springs.terminal_length = .21088 * .82
		springs.segment_radii = PackedFloat32Array([.045,.065,.085,.075,.05,.016])
	springs.bind(pony,get_skeleton())
	_ray_floor = springs.floor_probe
	if pony.has_method("clip_floor_hit"):
		_plane_floor = Callable(pony, "clip_floor_hit")
	_pose.clear();_body_ends.clear()
	var read_bones:=PackedInt32Array()
	var sk:=get_skeleton()
	for i in sk.get_bone_count():_pose.append(sk.get_bone_rest(i))
	# Only the mount and its ancestors: apply_pose() rewrites every tail joint from its rest.
	for tip in springs.bones:
		var bone:int=sk.get_bone_parent(tip)
		while bone>=0:
			if bone not in read_bones and bone not in springs.bones:read_bones.append(bone)
			bone=sk.get_bone_parent(bone)
	_read_bones=read_bones
	for name in ["pony_hips","pony_spine3"]:_body_ends.append(pony.skeleton.find_bone(name))
	_settled = false; _quiet = 0.0; _settled_writes = 0; _last_angles = PackedVector3Array(); _wake_now = false
	_pose_dirty = true; _solo_children = -1
	if not sk.pose_updated.is_connected(_on_pose_updated): sk.pose_updated.connect(_on_pose_updated)


## Forget the motion remembered from the last integration (hybrid_mare.gd _rigs_unparked, after a
## hidden spell with parked rigs, when no pass ran): her body velocity and the springs' rump turn
## history. The next integration starts as the first one does, with no acceleration read across
## the gap, so the tail does not whip on the first frame she is seen again.
func reset_history() -> void:
	_history = false
	if springs != null:
		springs._mount_history = false
		springs._previous_mount_velocity = Vector3.ZERO


## Skeleton3D emits pose_updated as a pass begins when any plain pose on the rig was written since
## the last pass (hair link, rig-rate wake, anything): that pass skins, so the tail must write.
func _on_pose_updated() -> void:
	_pose_dirty = true

const PROFILE := preload("res://tools/crowd_cpu_profile.gd")

func _process_modification_with_delta(delta: float) -> void:
	if _native_on and not PROFILE.enabled and native_step(delta): return
	_script_step(delta)


## The step as it was, on the native base's properties: the fallback and rollback path.
func _script_step(delta: float) -> void:
	if springs == null or not is_instance_valid(pony) or not pony.is_inside_tree(): return
	var dirty := _pose_dirty
	_pose_dirty = false
	if _settled and _settled_writes > 0 and HAIR_PASS_SKIP and not dirty and _skip_hair_pass(delta): return
	if not PROFILE.enabled:
		_springs_tick(delta)
		_apply_aside(delta)
		return
	var started := Time.get_ticks_usec()
	var integrated := _springs_tick(delta)
	_apply_aside(delta)
	PROFILE.record("tail_springs", started)
	# Integration ticks alone (includes the record above, about 1.5 us); the rest only interpolate.
	if integrated: PROFILE.record("tail_springs_integrate", started)

## True when this step ran the springs pass rather than only the in-between write.
func _springs_tick(delta: float) -> bool:
	var sk := get_skeleton()
	# Integrate at the mare's own rate: hero_divisor for HERO (60/30 Hz), her 20 Hz logic beat
	# in the clip tiers (pony_locomotion.is_logic_tick). In between, the modifier writes the tail
	# interpolated between the last two integrated poses, one integration behind, since
	# Skeleton3D reverts modifier writes after skinning (dev 2026-09-25: logic at 20 Hz,
	# visuals every step).
	var near: bool = pony.get("sim_tier") == 1
	var divisor: int = pony.LOGIC_DIVISOR if near else maxi(int(pony.hero_divisor), 1)
	_skipped_delta += delta
	var integrate: bool = pony.is_logic_tick() if near else (divisor <= 1 or ((pony._tick + pony.sim_phase) % divisor) == 0)
	if _settled:
		if integrate:
			var wake := _wake_now
			_wake_now = false
			if not wake and _settle_holds(sk):
				_skipped_delta = 0.0
				_write_settled(sk)
				return false
			_settled = false
			_quiet = SETTLE_SECONDS if _recheck <= 0.0 else 0.0
		else:
			_write_settled(sk)
			return false
	if not integrate and _history:
		_steps += 1
		_write_between(sk, float(_steps + 1) / divisor)
		return false
	springs.cheap_floor=true  # dev 2026-09-17: jigglebones + floor for every tier, no skin scan
	springs.contact_iterations=4
	# The body capsule feeds only the skin scan; the floor-only pass never reads it.
	if not springs.cheap_floor:
		# Read the prepared FK, not Skeleton3D's temporarily restored pre-modifier pose.
		var frame:Transform3D=pony.global_transform*pony.pivot.transform*pony._model_frame
		var body_pose:Array=pony.corrected_pose if not pony.corrected_pose.is_empty() else pony.profile.rest
		var ends:Array[Vector3]=[]
		for b in _body_ends:
			var local:Transform3D=body_pose[b]
			var parent:int=pony.profile.parents[b]
			while parent>=0:local=body_pose[parent]*local;parent=pony.profile.parents[parent]
			ends.append((frame*local).origin)
		springs.body_capsules.assign([{"a":ends[0],"b":ends[1],"radius":.11}])
	# The spring solver reads only the tail mount's ancestry; it writes the six tail joints.
	# All other hair-skeleton bones remain untouched by this modifier.
	for i in _read_bones:_pose[i]=sk.get_bone_pose(i)
	var stepped := 0.0
	if not pony.motion_paused and integrate:
		var step := _skipped_delta
		_skipped_delta = 0.0
		stepped = step
		var acceleration: Vector3 = (pony.velocity - _previous_velocity) / maxf(step,.001) if _history else Vector3.ZERO
		_previous_velocity = pony.velocity
		_history = true
		springs.update(step,acceleration)
	# NEAR: contact projection only on integrate ticks and with two passes instead of
	# the full budget; the weighted contact scan was 3.2 ms per tick for 16 ponies.
	var plane: bool = near and _plane_floor.is_valid()
	springs.floor_probe = _plane_floor if plane else _ray_floor
	# One plane for the whole chain: her floor plane is the same for every tip until the next ray.
	springs.floor_is_plane = plane
	springs._contact_enabled=not pony.motion_paused and (integrate or not near)
	springs.apply_pose(_pose)
	var bones: Array = springs.bones
	var fresh := _to.size() != bones.size()
	if fresh:
		_to.resize(bones.size())
		_to_rotation.resize(bones.size())
	# The previous target becomes the start; reuse the two buffers instead of copying.
	var previous := _from_rotation
	_from_rotation = _to_rotation
	_to_rotation = previous
	if _to_rotation.size() != bones.size(): _to_rotation.resize(bones.size())
	for k in bones.size():
		_to[k] = _pose[bones[k]]
		_to_rotation[k] = _to[k].basis.get_rotation_quaternion()
	if fresh:
		_from_rotation = _to_rotation.duplicate()
	_steps = 0
	_write_between(sk, 1.0 / divisor)
	if TAIL_SETTLE and stepped > 0.0: _watch_settle(sk, stepped)
	return true


## After an integration: count quiet time, and settle once the tail has been at rest SETTLE_SECONDS.
func _watch_settle(sk: Skeleton3D, step: float) -> void:
	var mount := sk.global_transform * sk.get_bone_global_pose(springs._mount) if springs._mount >= 0 else Transform3D.IDENTITY
	var angles: Array = springs.angles
	var turn := SETTLE_TURN * .1 * mount.basis.x.length()
	turn *= turn
	var quiet: bool = _last_angles.size() == angles.size() and pony.velocity.length_squared() < QUIET_SPEED * QUIET_SPEED \
		and mount.origin.distance_squared_to(_last_mount.origin) < SETTLE_MOVE * SETTLE_MOVE * .01 \
		and mount.basis.x.distance_squared_to(_last_mount.basis.x) < turn and mount.basis.z.distance_squared_to(_last_mount.basis.z) < turn
	if quiet:
		var spin: Array = springs.angular_velocity
		for k in angles.size():
			if (spin[k] as Vector3).length_squared() > QUIET_SPIN * QUIET_SPIN \
					or (angles[k] as Vector3).distance_squared_to(_last_angles[k]) > QUIET_STEP * QUIET_STEP:
				quiet = false
				break
	_last_mount = mount
	_last_angles = PackedVector3Array(angles)
	_quiet = _quiet + step if quiet else 0.0
	if _quiet < SETTLE_SECONDS or _to.size() != springs.bones.size(): return
	# Settle on the pose just written in full (t = 1 of the next in-between writes is _to).
	_settled = true
	_settled_writes = 0
	_recheck = SETTLE_RECHECK
	_settle_mount = mount
	_settle_reach = mount.basis.x.length()
	springs.angular_velocity.fill(Vector3.ZERO)


## Settled: true while nothing would move the tail. Keeps the springs' rump history current, so the
## integration after a wake starts from this frame and sees no stored-up turn.
func _settle_holds(sk: Skeleton3D) -> bool:
	_recheck -= _skipped_delta
	if _recheck <= 0.0 or springs._mount < 0: return false
	if pony.velocity.length_squared() > QUIET_SPEED * QUIET_SPEED: return false
	for spin: Vector3 in springs.angular_velocity:
		if spin != Vector3.ZERO: return false   # a swish (pony_idle_twitches) or kick
	var mount := sk.global_transform * sk.get_bone_global_pose(springs._mount)
	if mount.origin.distance_squared_to(_settle_mount.origin) > SETTLE_MOVE * SETTLE_MOVE: return false
	# Basis columns scaled like the rig: a column moves `reach * angle` when the rump turns.
	var limit := SETTLE_TURN * _settle_reach
	limit *= limit
	if mount.basis.x.distance_squared_to(_settle_mount.basis.x) > limit or mount.basis.y.distance_squared_to(_settle_mount.basis.y) > limit \
			or mount.basis.z.distance_squared_to(_settle_mount.basis.z) > limit:
		return false
	springs._previous_mount_basis = mount.basis.orthonormalized()
	springs._previous_mount_velocity = Vector3.ZERO
	_previous_velocity = pony.velocity
	return true


func _write_settled(sk: Skeleton3D) -> void:
	_settled_writes += 1
	_steps = 0
	_write_between(sk, 1.0)


## A settled tail whose held pose the last skin pass already shows. Advances what the pass would
## have advanced (the in-between clock, the aside ease) and decides whether to write at all.
func _skip_hair_pass(delta: float) -> bool:
	if absf(_aside) >= .0001 or absf(aside_goal) >= .0001: return false
	var sk := get_skeleton()
	if sk == null: return false
	if sk.get_child_count() != _solo_children:
		_solo_children = sk.get_child_count()
		_solo = true
		for child in sk.get_children():
			if child != self and child is SkeletonModifier3D:
				_solo = false
				break
	if not _solo: return false
	var touch: Object = pony.get("touch_body")
	if touch != null and bool(touch.get("active")): return false
	# _springs_tick's settled branch without the write: integration ticks run the wake test.
	var near: bool = pony.get("sim_tier") == 1
	var divisor: int = pony.LOGIC_DIVISOR if near else maxi(int(pony.hero_divisor), 1)
	_skipped_delta += delta
	var integrate: bool = pony.is_logic_tick() if near else (divisor <= 1 or ((pony._tick + pony.sim_phase) % divisor) == 0)
	if not integrate: return true
	if _settle_holds(sk):
		_skipped_delta = 0.0
		return true
	_skipped_delta -= delta   # _springs_tick adds it again
	_wake_now = true          # and wakes without testing (and counting the recheck) twice
	return false


func _apply_aside(delta: float) -> void:
	var limit: float = float(springs.angle_limits[0]) * .9 if not springs.angle_limits.is_empty() else .5
	_aside = move_toward(_aside, clampf(aside_goal, -limit, limit), delta * ASIDE_SPEED)
	if absf(_aside) < .0001 or springs.bones.is_empty(): return
	var sk := get_skeleton()
	var bone: int = springs.bones[0]
	var parent := sk.get_bone_parent(bone)
	var parent_rotation := sk.get_bone_global_pose(parent).basis.get_rotation_quaternion() if parent >= 0 else Quaternion.IDENTITY
	var axis := (sk.global_basis.orthonormalized().inverse() * pony.global_basis.y.normalized()).normalized()
	var global := parent_rotation * sk.get_bone_pose_rotation(bone)
	sk.set_bone_pose_rotation(bone, parent_rotation.inverse() * Quaternion(axis, _aside) * global)


## Tail pose `t` of the way from the previous integration's result to the latest one.
func _write_between(sk: Skeleton3D, t: float) -> void:
	var bones: Array = springs.bones
	if t >= 1.0:
		for k in bones.size(): sk.set_bone_pose(bones[k], _to[k])
		return
	for k in bones.size():
		sk.set_bone_pose_position(bones[k], _to[k].origin)
		sk.set_bone_pose_rotation(bones[k], _from_rotation[k].slerp(_to_rotation[k], t))
