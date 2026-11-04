extends Node3D
## River activity lifecycle. Deck enters physics before navigation samples the bank;
## player adapters and nearby companions start once the game is ready.
const DOCK := preload("res://world/minigames/fishing/fishing_dock.gd")
const HANDS := preload("res://world/minigames/fishing/fishing_hands.gd")
const COMPANIONS := preload("res://world/minigames/fishing/fishing_companions.gd")
const STATIONS := preload("res://world/mechanics/stations/stations.gd")
var host: Node
var dock: Node3D
var hands: Node
var companions: Node
var _catch_index: int = 0

func prepare(game: Node, ground_height: Callable) -> void:
	if is_instance_valid(dock): return
	host=game
	dock=DOCK.new();dock.name="RiverDock";dock.ground_height=ground_height
	add_child(dock)
	dock.fish_landed.connect(_landed)

func setup() -> void:
	if is_instance_valid(hands) or not is_instance_valid(dock): return
	hands=HANDS.new();hands.name="FishingHands";add_child(hands);hands.setup(dock,host.inventory)
	companions=COMPANIONS.new();companions.name="FishingCompanions";add_child(companions)
	companions.setup(host,dock,hands)

func _landed(rod: Node3D, at: Vector3) -> void:
	if not is_instance_valid(host) or not is_instance_valid(host.inventory): return
	var pony: Node3D = companions.actor_for_rod(rod) if is_instance_valid(companions) else null
	if rod.holder!="player" and pony==null: return
	# A landed catch is a tangible inventory-owned body. The player can collect it
	# with the free hand; companions put their catch beside the shared basket.
	var point: Vector3 = at
	if pony!=null:
		point=dock.landing_point()+Vector3(((_catch_index%3)-1)*.06,.13,0)
	var pose: Transform3D = Transform3D(Basis(Vector3.UP,float(_catch_index)*.71),point)
	var fish: RigidBody3D = host.inventory.spawn_owned_drop("river-fish",pose)
	if fish==null: return
	preload("res://world/audio/interaction_sounds.gd").play_at(fish, "prop_fish_land")
	_catch_index+=1
	# Stations adapter (world/mechanics/stations/stations.gd, row fishing_dock): the "caught" fact,
	# counters only; shared_activity owns the memory.
	var catcher := "player"
	if pony != null:
		catcher = ""
		for lease: Dictionary in companions.leases:
			if lease.get("actor") == pony: catcher = str(lease.get("id", ""))
	STATIONS.note(self, "fishing_dock", catcher, ["river-fish"], "caught")
	if is_instance_valid(host.get("relationship_runtime")) and is_instance_valid(companions) and companions._player_fishing():
		var participants:Array=[]
		for lease:Dictionary in companions.leases:participants.append(str(lease.id))
		if not participants.is_empty():host.relationship_runtime.shared_activity("fishing",dock.global_position,"fish_%d_%d"%[get_instance_id(),_catch_index],participants)
	fish.linear_velocity=Vector3.ZERO
	fish.angular_velocity=Vector3(0,.35,0)

func _exit_tree() -> void:
	if is_instance_valid(companions):companions.release_all()
	if is_instance_valid(hands):hands.release()
