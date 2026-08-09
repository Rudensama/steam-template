extends Node
## Transport-agnostic multiplayer layer built on Godot's high-level
## MultiplayerAPI. The game code (chat, voice, player list) is identical no
## matter which transport is active:
##   * STEAM -> SteamMultiplayerPeer, running inside a Steam lobby (join by code
##     or Steam friend invite).
##   * LAN   -> ENetMultiplayerPeer (host, join by IP address).
##
## Autoload singleton name: NetworkManager

signal lobby_ready              ## Local peer is set up; UI should open the Lobby.
signal lobby_left               ## We left / were disconnected; UI returns to menu.
signal kicked(reason: String)   ## The host removed us from the lobby.
signal connection_failed(reason: String)
signal player_list_changed
signal chat_received(sender_name: String, text: String, steam_id: int, peer_id: int, color: int)
signal game_starting            ## Host started the match; the game scene is loading.

enum Mode { NONE, STEAM, LAN }

const DEFAULT_PORT: int = 7777
const MAX_PLAYERS: int = 8
const PING_INTERVAL: float = 1.0
## One distinct color per possible player; auto-assigned on join, changeable in the
## lobby. Used for chat bubbles and player-card accents. Keep length >= MAX_PLAYERS.
const PLAYER_COLORS: Array[Color] = [
	Color("e0555b"), Color("4f8ef7"), Color("4ade80"), Color("f5a623"),
	Color("c96ff5"), Color("34d0c4"), Color("f56fae"), Color("c9cf3a"),
]
## The scene every peer switches to when the host starts. Point this at your own
## game to build on the template.
const GAME_SCENE: String = "res://scenes/game/game.tscn"

var mode: Mode = Mode.NONE
var is_host: bool = false
var steam_lobby_id: int = 0
## Display name chosen on the main menu (falls back to Steam persona name).
var display_name: String = ""
## Set just before we return to the menu (e.g. a kick reason) so the menu can
## show it. Read once, then cleared by the reader.
var last_notice: String = ""

## peer_id -> { "name": String, "steam_id": int, "ready": bool, "ping": int,
##              "color": int }
var players: Dictionary = {}

## Host-only rolling chat log, replayed to players who join later.
const CHAT_HISTORY_MAX: int = 100
var _chat_history: Array[Dictionary] = []

var _ping_timer: Timer

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	SteamManager.invite_join_requested.connect(_on_invite_join_requested)

	_ping_timer = Timer.new()
	_ping_timer.wait_time = PING_INTERVAL
	add_child(_ping_timer)
	_ping_timer.timeout.connect(_on_ping_timer)

func get_display_name() -> String:
	# The Steam persona name is authoritative. The custom name is only a fallback
	# for offline LAN play, where there's no Steam session to read a name from.
	if SteamManager.is_online():
		return SteamManager.steam_username
	if display_name.strip_edges() != "":
		return display_name
	return "Player"

# --- STEAM transport -------------------------------------------------------

func host_steam() -> void:
	if not SteamManager.is_online():
		connection_failed.emit("Steam is not running.")
		return
	_reset()
	mode = Mode.STEAM
	is_host = true
	Steam.lobby_created.connect(_on_lobby_created, CONNECT_ONE_SHOT)
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_PLAYERS)

func _on_lobby_created(result: int, lobby_id: int) -> void:
	if result != Steam.RESULT_OK:
		connection_failed.emit("Failed to create Steam lobby (code %d)." % result)
		return
	steam_lobby_id = lobby_id
	Steam.setLobbyData(lobby_id, "name", "%s's lobby" % get_display_name())
	Steam.setLobbyJoinable(lobby_id, true)

	var peer: SteamMultiplayerPeer = SteamMultiplayerPeer.new()
	if peer.create_host(0) != OK:
		connection_failed.emit("Failed to create Steam host peer.")
		return
	multiplayer.multiplayer_peer = peer
	_register_self()
	lobby_ready.emit()

func join_steam(lobby_id: int) -> void:
	if not SteamManager.is_online():
		connection_failed.emit("Steam is not running.")
		return
	if lobby_id <= 0:
		connection_failed.emit("Invalid lobby code.")
		return
	_reset()
	mode = Mode.STEAM
	is_host = false
	Steam.lobby_joined.connect(_on_lobby_joined, CONNECT_ONE_SHOT)
	Steam.joinLobby(lobby_id)

func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	# response 1 == k_EChatRoomEnterResponseSuccess
	if response != 1:
		connection_failed.emit("Could not join lobby (code %d)." % response)
		return
	steam_lobby_id = lobby_id
	var host_id: int = Steam.getLobbyOwner(lobby_id)
	var peer: SteamMultiplayerPeer = SteamMultiplayerPeer.new()
	if peer.create_client(host_id, 0) != OK:
		connection_failed.emit("Failed to create Steam client peer.")
		return
	multiplayer.multiplayer_peer = peer
	# We register with the host once connected_to_server fires.
	lobby_ready.emit()

# --- LAN transport ---------------------------------------------------------

func host_lan(port: int = DEFAULT_PORT) -> void:
	_reset()
	mode = Mode.LAN
	is_host = true
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	if peer.create_server(port, MAX_PLAYERS) != OK:
		connection_failed.emit("Failed to start LAN server on port %d." % port)
		return
	multiplayer.multiplayer_peer = peer
	_register_self()
	lobby_ready.emit()

func join_lan(ip: String, port: int = DEFAULT_PORT) -> void:
	if ip.strip_edges() == "":
		connection_failed.emit("Enter the host's IP address.")
		return
	_reset()
	mode = Mode.LAN
	is_host = false
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	if peer.create_client(ip, port) != OK:
		connection_failed.emit("Failed to connect to %s:%d." % [ip, port])
		return
	multiplayer.multiplayer_peer = peer
	# Registration happens on connected_to_server.
	lobby_ready.emit()

## Best-effort local IPv4 for showing the host address on the LAN.
func get_local_ip() -> String:
	for addr in IP.get_local_addresses():
		if addr.count(".") == 3 and not addr.begins_with("127."):
			return addr
	return "127.0.0.1"

# --- Leaving ---------------------------------------------------------------

func leave() -> void:
	VoiceManager.stop_all()
	if mode == Mode.STEAM and steam_lobby_id != 0:
		Steam.leaveLobby(steam_lobby_id)
	_reset()
	lobby_left.emit()

func _reset() -> void:
	if _ping_timer != null:
		_ping_timer.stop()
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null and not (peer is OfflineMultiplayerPeer):
		peer.close()
	multiplayer.multiplayer_peer = null
	players.clear()
	_chat_history.clear()
	steam_lobby_id = 0
	mode = Mode.NONE
	is_host = false

# --- MultiplayerAPI callbacks ---------------------------------------------

func _on_peer_connected(_id: int) -> void:
	# Host waits for the newcomer to send its info via _register_player.
	pass

func _on_peer_disconnected(id: int) -> void:
	if is_host:
		players.erase(id)
		_sync_players.rpc(players)
		player_list_changed.emit()

func _on_connected_to_server() -> void:
	# Client announces itself to the host (peer id 1).
	_register_player.rpc_id(1, get_display_name(), SteamManager.steam_id)

func _on_connection_failed() -> void:
	_reset()
	connection_failed.emit("Connection failed.")

func _on_server_disconnected() -> void:
	_reset()
	lobby_left.emit()

func _on_invite_join_requested(lobby_id: int) -> void:
	join_steam(lobby_id)

# --- Player roster (host authoritative) -----------------------------------

func _register_self() -> void:
	players.clear()
	players[1] = _new_player(get_display_name(), SteamManager.steam_id, _first_unused_color())
	_ping_timer.start()
	player_list_changed.emit()

func _new_player(player_name: String, sid: int, color_index: int) -> Dictionary:
	return { "name": player_name, "steam_id": sid, "ready": false, "ping": 0, "color": color_index }

@rpc("any_peer", "call_remote", "reliable")
func _register_player(player_name: String, sid: int) -> void:
	if not is_host:
		return
	var id: int = multiplayer.get_remote_sender_id()
	players[id] = _new_player(player_name, sid, _first_unused_color())
	_sync_players.rpc(players)
	player_list_changed.emit()
	# Catch the newcomer up on messages sent before they joined. The connection is
	# established by now (they just RPC'd us) and their lobby/chat panel is loaded.
	if not _chat_history.is_empty():
		_send_chat_history.rpc_id(id, _chat_history)

@rpc("authority", "call_remote", "reliable")
func _sync_players(new_players: Dictionary) -> void:
	players = new_players
	player_list_changed.emit()

# --- Player colors (host authoritative, unique per player) -----------------

## Lowest palette index not currently used by any player (for auto-assign on join).
func _first_unused_color() -> int:
	var used: Dictionary = {}
	for id in players:
		used[int(players[id].get("color", -1))] = true
	for i in PLAYER_COLORS.size():
		if not used.has(i):
			return i
	return 0

## Change the local player's color. Host applies directly; clients ask the host,
## who rejects the change if another player already holds that color.
func set_player_color(index: int) -> void:
	if is_host:
		_apply_color(multiplayer.get_unique_id(), index)
	else:
		_request_color.rpc_id(1, index)

@rpc("any_peer", "call_remote", "reliable")
func _request_color(index: int) -> void:
	if is_host:
		_apply_color(multiplayer.get_remote_sender_id(), index)

func _apply_color(peer_id: int, index: int) -> void:
	if not is_host or index < 0 or index >= PLAYER_COLORS.size() or not players.has(peer_id):
		return
	if is_color_taken(index, peer_id):
		return
	players[peer_id].color = index
	_sync_players.rpc(players)
	player_list_changed.emit()

func get_color_index(peer_id: int) -> int:
	return int(players.get(peer_id, {}).get("color", 0))

func get_player_color(peer_id: int) -> Color:
	return PLAYER_COLORS[clampi(get_color_index(peer_id), 0, PLAYER_COLORS.size() - 1)]

## True if `index` is already held by a player other than `exclude_peer`.
func is_color_taken(index: int, exclude_peer: int = -1) -> bool:
	for id in players:
		if id != exclude_peer and int(players[id].get("color", -1)) == index:
			return true
	return false

# --- Ready-up (host authoritative) -----------------------------------------

## Toggle the local player's ready state. Host applies directly; clients ask the
## host, who is the source of truth for the roster.
func set_ready(on: bool) -> void:
	if is_host:
		if players.has(1):
			players[1].ready = on
			_sync_players.rpc(players)
			player_list_changed.emit()
	else:
		_request_ready.rpc_id(1, on)

func is_ready() -> bool:
	return players.get(multiplayer.get_unique_id(), {}).get("ready", false)

## True when every player in the lobby has readied up.
func everyone_ready() -> bool:
	if players.is_empty():
		return false
	for id in players:
		if not players[id].get("ready", false):
			return false
	return true

@rpc("any_peer", "call_remote", "reliable")
func _request_ready(on: bool) -> void:
	if not is_host:
		return
	var id: int = multiplayer.get_remote_sender_id()
	if players.has(id):
		players[id].ready = on
		_sync_players.rpc(players)
		player_list_changed.emit()

# --- Starting the game -----------------------------------------------------

## Host-only. Once everyone is ready, tell every peer (including us) to load the
## game scene. Swap GAME_SCENE for your own scene to build the actual game.
func start_game() -> void:
	if not is_host or not everyone_ready():
		return
	_enter_game.rpc()

@rpc("authority", "call_local", "reliable")
func _enter_game() -> void:
	game_starting.emit()
	get_tree().change_scene_to_file(GAME_SCENE)

# --- Kick (host authoritative) ---------------------------------------------

func kick(peer_id: int) -> void:
	if not is_host or peer_id == 1 or not players.has(peer_id):
		return
	_kicked.rpc_id(peer_id, "You were removed from the lobby by the host.")
	# Let the notice reach them before we drop the connection.
	await get_tree().create_timer(0.2).timeout
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null and peer.has_method("disconnect_peer"):
		peer.disconnect_peer(peer_id)
	players.erase(peer_id)
	_sync_players.rpc(players)
	player_list_changed.emit()

@rpc("authority", "call_remote", "reliable")
func _kicked(reason: String) -> void:
	last_notice = reason
	VoiceManager.stop_all()
	_reset()
	kicked.emit(reason)

# --- Ping (host pings everyone, then shares the results) --------------------

func _on_ping_timer() -> void:
	if not is_host:
		return
	# Share last round's measurements, then start a new round.
	_sync_pings.rpc(_ping_map())
	_ping.rpc(Time.get_ticks_msec())

func _ping_map() -> Dictionary:
	var map: Dictionary = {}
	for id in players:
		map[id] = players[id].get("ping", 0)
	return map

@rpc("authority", "call_remote", "unreliable")
func _ping(host_time: int) -> void:
	_pong.rpc_id(1, host_time)

@rpc("any_peer", "call_remote", "unreliable")
func _pong(host_time: int) -> void:
	if not is_host:
		return
	var id: int = multiplayer.get_remote_sender_id()
	if players.has(id):
		players[id].ping = Time.get_ticks_msec() - host_time

@rpc("authority", "call_remote", "unreliable")
func _sync_pings(map: Dictionary) -> void:
	for id in map:
		if players.has(id):
			players[id].ping = map[id]
	player_list_changed.emit()

# --- Text chat -------------------------------------------------------------

func send_chat(text: String) -> void:
	if text.strip_edges() == "":
		return
	var my: int = multiplayer.get_unique_id()
	# Stamp the message with our identity + color so it renders correctly forever,
	# even in replayed history after the sender's peer has changed or left.
	_recv_chat.rpc(get_display_name(), text, SteamManager.steam_id, my, get_color_index(my))

@rpc("any_peer", "call_local", "reliable")
func _recv_chat(sender_name: String, text: String, sid: int, peer_id: int, color: int) -> void:
	# The host keeps the log so players who join later can be caught up (pushed to
	# them from _register_player).
	if is_host:
		_chat_history.append({ "name": sender_name, "text": text, "sid": sid, "peer_id": peer_id, "color": color })
		if _chat_history.size() > CHAT_HISTORY_MAX:
			_chat_history.pop_front()
	chat_received.emit(sender_name, text, sid, peer_id, color)

@rpc("authority", "call_remote", "reliable")
func _send_chat_history(history: Array) -> void:
	for m in history:
		chat_received.emit(m.get("name", ""), m.get("text", ""), int(m.get("sid", 0)), int(m.get("peer_id", 0)), int(m.get("color", 0)))

## True when a chat message was sent by the local player. Prefers the stable Steam
## identity (survives reconnects / peer-id changes); falls back to peer id when
## Steam IDs collide (e.g. testing two instances on ONE Steam account).
func is_own_message(msg_steam_id: int, msg_peer_id: int) -> bool:
	var my_sid: int = SteamManager.steam_id
	if my_sid != 0 and _steam_id_unique(my_sid):
		return msg_steam_id == my_sid
	return msg_peer_id == multiplayer.get_unique_id()

func _steam_id_unique(sid: int) -> bool:
	var count: int = 0
	for id: int in players:
		if int(players[id].get("steam_id", 0)) == sid:
			count += 1
	return count <= 1
