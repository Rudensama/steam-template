extends PanelContainer
## A single invite row: friend avatar (left), name (middle), and an "Invite"
## button (right). FriendInvitePanel instantiates one of these per online friend.
class_name FriendInviteRow

signal invite_requested(friend_id: int)

var steam_id: int = 0

func setup(friend: Dictionary) -> void:
	steam_id = friend.get("steam_id", 0)
	%NameLabel.text = friend.get("name", "Unknown")
	if steam_id > 0 and SteamManager.is_online():
		Steam.avatar_loaded.connect(_on_avatar_loaded)
		Steam.getPlayerAvatar(Steam.AVATAR_SMALL, steam_id)

func _ready() -> void:
	%InviteButton.pressed.connect(_emit_invite)

func _exit_tree() -> void:
	if Steam.avatar_loaded.is_connected(_on_avatar_loaded):
		Steam.avatar_loaded.disconnect(_on_avatar_loaded)

func _emit_invite() -> void:
	invite_requested.emit(steam_id)

func _on_avatar_loaded(user_id: int, avatar_size: int, buffer: PackedByteArray) -> void:
	if user_id != steam_id:
		return
	Steam.avatar_loaded.disconnect(_on_avatar_loaded)
	if avatar_size <= 0 or buffer.is_empty():
		return
	var image: Image = Image.create_from_data(avatar_size, avatar_size, false, Image.FORMAT_RGBA8, buffer)
	%AvatarRect.texture = ImageTexture.create_from_image(image)
