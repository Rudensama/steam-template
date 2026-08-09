extends Node
## Initializes the Steamworks API, pumps its callbacks every frame, and exposes
## the local user's identity. Also routes Steam friend-invite / overlay joins.
##
## Autoload singleton name: SteamManager

signal steam_ready(ok: bool)
## Emitted when the user accepts a Steam invite (overlay, friends list, or the
## game was launched via an invite). Carries the lobby id to join.
signal invite_join_requested(lobby_id: int)
## A requested avatar finished loading (or was already cached). UI listens for its
## own steam_id to swap in the texture. See request_avatar().
signal avatar_ready(steam_id: int, texture: Texture2D)

## Spacewar test app. Replace with your own App ID for a real game (also update
## steam_appid.txt). 480 lets anyone test without owning your app.
const APP_ID: int = 480

var initialized: bool = false
var steam_id: int = 0
var steam_username: String = "Player"

## steam_id -> rounded Texture2D. Avatars are fetched and processed ONCE here and
## shared by every player card / chat bubble, instead of each re-downloading and
## re-rounding the same image.
var _avatar_cache: Dictionary = {}

func _init() -> void:
	# Make sure the Steam client can associate this process with the app even
	# when running from the editor. steam_appid.txt covers exported builds.
	OS.set_environment("SteamAppId", str(APP_ID))
	OS.set_environment("SteamGameId", str(APP_ID))

func _ready() -> void:
	var result: Dictionary = Steam.steamInitEx()
	# status 0 == STEAM_API_INIT_RESULT_OK
	if result.get("status", 1) != 0:
		push_warning("Steam init failed: %s" % result.get("verbal", "unknown error"))
		initialized = false
		steam_ready.emit(false)
		return

	initialized = true
	steam_id = Steam.getSteamID()
	steam_username = Steam.getPersonaName()

	Steam.join_requested.connect(_on_join_requested)
	Steam.lobby_invite.connect(_on_lobby_invite)
	Steam.avatar_loaded.connect(_on_avatar_loaded)

	steam_ready.emit(true)
	_check_launch_command_line()

func _process(_delta: float) -> void:
	if initialized:
		Steam.run_callbacks()

## True when we have a usable Steam session (needed for Steam lobbies AND voice).
func is_online() -> bool:
	return initialized

## Open the Steam overlay so the local user can invite friends to the lobby.
func invite_friends(lobby_id: int) -> void:
	if initialized and lobby_id > 0:
		Steam.activateGameOverlayInviteDialog(lobby_id)

## All friends currently online (excluding the offline/invisible ones), as
## [{ "steam_id": int, "name": String, "state": int }]. Empty when offline.
func get_online_friends() -> Array[Dictionary]:
	var friends: Array[Dictionary] = []
	if not initialized:
		return friends
	var count: int = Steam.getFriendCount(Steam.FRIEND_FLAG_IMMEDIATE)
	for i: int in count:
		var friend_id: int = Steam.getFriendByIndex(i, Steam.FRIEND_FLAG_IMMEDIATE)
		if friend_id <= 0:
			continue
		var state: int = Steam.getFriendPersonaState(friend_id)
		if state == Steam.PERSONA_STATE_OFFLINE:
			continue
		friends.append({
			"steam_id": friend_id,
			"name": Steam.getFriendPersonaName(friend_id),
			"state": state,
		})
	return friends

## Send a direct lobby invite to one specific friend. Returns true if Steam
## accepted the invite.
func invite_friend(lobby_id: int, friend_id: int) -> bool:
	if not initialized or lobby_id <= 0 or friend_id <= 0:
		return false
	return Steam.inviteUserToLobby(lobby_id, friend_id)

# --- Invite handling -------------------------------------------------------

func _check_launch_command_line() -> void:
	# When a friend accepts an invite while our game is closed, Steam launches us
	# with "+connect_lobby <id>" on the command line.
	var args: PackedStringArray = OS.get_cmdline_args()
	var idx: int = args.find("+connect_lobby")
	if idx != -1 and idx + 1 < args.size():
		var lobby_id: int = int(args[idx + 1])
		if lobby_id > 0:
			invite_join_requested.emit(lobby_id)

func _on_join_requested(lobby_id: int, _friend_id: int) -> void:
	# Friend accepted our invite / clicked "Join Game" while we are running.
	invite_join_requested.emit(lobby_id)

func _on_lobby_invite(_inviter: int, lobby_id: int, _game_id: int) -> void:
	invite_join_requested.emit(lobby_id)

# --- Avatars (fetched + rounded once, cached, shared) -----------------------

## Return the cached rounded avatar for a Steam user if we already have it. If
## not, kick off a fetch and return null — connect to `avatar_ready` and match on
## `steam_id` to receive it when it arrives. No-op (returns null) when offline or
## the id is invalid.
func request_avatar(target_id: int) -> Texture2D:
	if _avatar_cache.has(target_id):
		return _avatar_cache[target_id]
	if not initialized or target_id <= 0:
		return null
	# Steam replies on the global avatar_loaded callback, handled below. If it's
	# already cached in Steam, the callback fires (near-)immediately.
	Steam.getPlayerAvatar(Steam.AVATAR_MEDIUM, target_id)
	return null

func _on_avatar_loaded(user_id: int, avatar_size: int, buffer: PackedByteArray) -> void:
	if avatar_size <= 0 or buffer.is_empty():
		return
	var image: Image = Image.create_from_data(avatar_size, avatar_size, false, Image.FORMAT_RGBA8, buffer)
	_round_image(image)
	var texture: Texture2D = ImageTexture.create_from_image(image)
	_avatar_cache[user_id] = texture
	avatar_ready.emit(user_id, texture)

## Zero the alpha outside the inscribed circle so a square Steam avatar renders as
## a round icon.
static func _round_image(image: Image) -> void:
	var w: int = image.get_width()
	var h: int = image.get_height()
	var cx: float = w / 2.0
	var cy: float = h / 2.0
	var r: float = minf(cx, cy)
	var r2: float = r * r
	for y: int in h:
		for x: int in w:
			var dx: float = (x + 0.5) - cx
			var dy: float = (y + 0.5) - cy
			if dx * dx + dy * dy > r2:
				var c: Color = image.get_pixel(x, y)
				c.a = 0.0
				image.set_pixel(x, y, c)
