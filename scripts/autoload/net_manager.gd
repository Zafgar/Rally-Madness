extends Node
## LAN multiplayer, up to 12 drivers.
##
## One machine hosts and is authoritative. Clients send their VehicleCommand
## every physics tick and receive car transforms back; the host runs the actual
## physics for every car. That is the right trade for a game where collisions
## decide races — two peers must never disagree about who hit whom.
##
## A hosting machine can still have up to four local split-screen seats, so a
## twelve-car field might be three couches of four.

enum State { OFFLINE, HOSTING, CONNECTING, CONNECTED }

## How often the host broadcasts car state. The physics runs at 60 Hz; sending
## every tick is wasteful when interpolation covers the gaps.
const SNAPSHOT_HZ := 20.0

class PeerInfo:
	extends RefCounted
	var peer_id: int = 0
	var display_name: String = ""
	var rating: int = PlayerProfile.DEFAULT_RATING
	var local_seats: int = 1
	var ready: bool = false
	var car_spec_id: String = ""


var state: State = State.OFFLINE
var peers: Dictionary = {}          # peer_id -> PeerInfo
var _peer: ENetMultiplayerPeer
var _snapshot_accumulator: float = 0.0
## car_id -> RallyCar, maintained by the race so snapshots can address cars.
var tracked_cars: Dictionary = {}
## Latest command received from each peer, consumed by the host's race loop.
var remote_commands: Dictionary = {}   # peer_id -> VehicleCommand


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_online() -> bool:
	return state == State.HOSTING or state == State.CONNECTED


func is_host() -> bool:
	return state == State.HOSTING


## Only the host simulates. Clients render what they are told.
func has_authority() -> bool:
	return state != State.CONNECTED


# --- Session lifecycle ------------------------------------------------------

func host_game(port: int = GameConfig.DEFAULT_PORT, max_players: int = GameConfig.MAX_NET_PLAYERS) -> Error:
	shutdown()
	_peer = ENetMultiplayerPeer.new()
	# One slot is the host itself.
	var err := _peer.create_server(port, max_players - 1)
	if err != OK:
		push_error("NetManager: cannot host on port %d (%d)" % [port, err])
		_peer = null
		return err

	multiplayer.multiplayer_peer = _peer
	state = State.HOSTING

	var info := PeerInfo.new()
	info.peer_id = 1
	info.display_name = _local_display_name()
	info.local_seats = maxi(PlayerManager.seat_count(), 1)
	peers[1] = info

	_set_state(State.HOSTING)
	return OK


func join_game(address: String, port: int = GameConfig.DEFAULT_PORT) -> Error:
	shutdown()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		push_error("NetManager: cannot reach %s:%d (%d)" % [address, port, err])
		_peer = null
		return err
	multiplayer.multiplayer_peer = _peer
	_set_state(State.CONNECTING)
	return OK


func shutdown() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null
	peers.clear()
	remote_commands.clear()
	tracked_cars.clear()
	_set_state(State.OFFLINE)


func _set_state(new_state: State) -> void:
	state = new_state
	EventBus.net_state_changed.emit(state)


func total_drivers() -> int:
	var count := 0
	for id in peers:
		count += maxi(peers[id].local_seats, 1)
	return count


func has_room_for(seats: int) -> bool:
	return total_drivers() + seats <= GameConfig.MAX_NET_PLAYERS


# --- Connection callbacks ---------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if is_host():
		# The newcomer needs to know who is already here, and everyone already
		# here needs to know about them. The host is the only source of truth.
		for existing_id in peers:
			var info: PeerInfo = peers[existing_id]
			_receive_peer_info.rpc_id(
				peer_id, existing_id, info.display_name, info.rating, info.local_seats)


func _on_peer_disconnected(peer_id: int) -> void:
	peers.erase(peer_id)
	remote_commands.erase(peer_id)
	EventBus.net_peer_left.emit(peer_id)


func _on_connected_to_server() -> void:
	_set_state(State.CONNECTED)
	var seats := maxi(PlayerManager.seat_count(), 1)
	_announce_self.rpc_id(1, _local_display_name(), _local_rating(), seats)


func _on_connection_failed() -> void:
	push_error("NetManager: connection failed")
	shutdown()


func _on_server_disconnected() -> void:
	push_warning("NetManager: host closed the session")
	shutdown()


func _local_display_name() -> String:
	var seat := PlayerManager.get_seat(0)
	if seat != null and seat.profile != null:
		return seat.profile.display_name
	return "Driver"


func _local_rating() -> int:
	var seat := PlayerManager.get_seat(0)
	if seat != null and seat.profile != null:
		return seat.profile.rating
	return PlayerProfile.DEFAULT_RATING


# --- Lobby RPCs -------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _announce_self(display_name: String, rating: int, local_seats: int) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Clamp what a client can claim: nothing stops a modified client asking for
	# eight seats, and the host is the one enforcing the twelve-car ceiling.
	local_seats = clampi(local_seats, 1, GameConfig.MAX_LOCAL_PLAYERS)
	if not has_room_for(local_seats):
		_reject.rpc_id(sender, "Session is full")
		return

	var info := PeerInfo.new()
	info.peer_id = sender
	info.display_name = display_name.substr(0, 24)
	info.rating = rating
	info.local_seats = local_seats
	peers[sender] = info

	# Tell everyone, including the newcomer, about the newcomer.
	_receive_peer_info.rpc(sender, info.display_name, info.rating, info.local_seats)
	EventBus.net_peer_joined.emit(sender, info.display_name)


@rpc("authority", "call_remote", "reliable")
func _receive_peer_info(peer_id: int, display_name: String, rating: int, local_seats: int) -> void:
	var info: PeerInfo = peers.get(peer_id)
	if info == null:
		info = PeerInfo.new()
		info.peer_id = peer_id
		peers[peer_id] = info
		EventBus.net_peer_joined.emit(peer_id, display_name)
	info.display_name = display_name
	info.rating = rating
	info.local_seats = local_seats


@rpc("authority", "call_remote", "reliable")
func _reject(reason: String) -> void:
	push_warning("NetManager: rejected by host — %s" % reason)
	shutdown()


@rpc("any_peer", "call_local", "reliable")
func set_ready(is_ready: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	var info: PeerInfo = peers.get(sender)
	if info != null:
		info.ready = is_ready


func everyone_ready() -> bool:
	if peers.is_empty():
		return false
	for id in peers:
		if not peers[id].ready:
			return false
	return true


## Average rating of the lobby, shown so players can see what level of field
## they are about to join.
func lobby_average_rating() -> int:
	if peers.is_empty():
		return PlayerProfile.DEFAULT_RATING
	var sum := 0
	for id in peers:
		sum += peers[id].rating
	return int(sum / peers.size())


# --- In-race replication ----------------------------------------------------

func _physics_process(delta: float) -> void:
	if not is_online():
		return
	if is_host():
		_snapshot_accumulator += delta
		var interval := 1.0 / SNAPSHOT_HZ
		if _snapshot_accumulator >= interval:
			_snapshot_accumulator -= interval
			_broadcast_snapshot()


## Clients call this every tick with their driver's intent.
func send_local_command(command: VehicleCommand) -> void:
	if state != State.CONNECTED:
		return
	_receive_command.rpc_id(1, command.encode())


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_command(payload: PackedByteArray) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var command: VehicleCommand = remote_commands.get(sender)
	if command == null:
		command = VehicleCommand.new()
		remote_commands[sender] = command
	command.decode(payload)


func _broadcast_snapshot() -> void:
	if tracked_cars.is_empty():
		return
	var payload := PackedFloat32Array()
	for car_id in tracked_cars:
		var car: RallyCar = tracked_cars[car_id]
		if car == null or not is_instance_valid(car):
			continue
		payload.append(float(car_id))
		payload.append(car.global_position.x)
		payload.append(car.global_position.y)
		payload.append(car.rotation)
		payload.append(car.linear_velocity.x)
		payload.append(car.linear_velocity.y)
		payload.append(car.angular_velocity)
		payload.append(car.height)
	_receive_snapshot.rpc(payload)


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_snapshot(payload: PackedFloat32Array) -> void:
	const STRIDE := 8
	var count := payload.size() / STRIDE
	for i in count:
		var base := i * STRIDE
		var car_id := int(payload[base])
		var car: RallyCar = tracked_cars.get(car_id)
		if car == null or not is_instance_valid(car):
			continue
		# Clients snap to the host's answer rather than trying to predict it.
		# Smoothing lives in the car's visual node, not the physics body, so
		# the authoritative position is never quietly wrong.
		car.apply_network_state(
			Vector2(payload[base + 1], payload[base + 2]),
			payload[base + 3],
			Vector2(payload[base + 4], payload[base + 5]),
			payload[base + 6],
			payload[base + 7])
