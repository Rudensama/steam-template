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
		# Shared cache: returns the texture now if ready, else fires avatar_ready.
		var tex: Texture2D = SteamManager.request_avatar(steam_id)
		if tex != null:
			%AvatarRect.texture = tex
		else:
			SteamManager.avatar_ready.connect(_on_avatar_ready)

func _ready() -> void:
	%InviteButton.pressed.connect(_emit_invite)

func _exit_tree() -> void:
	if SteamManager.avatar_ready.is_connected(_on_avatar_ready):
		SteamManager.avatar_ready.disconnect(_on_avatar_ready)

func _emit_invite() -> void:
	invite_requested.emit(steam_id)

func _on_avatar_ready(user_id: int, texture: Texture2D) -> void:
	if user_id != steam_id:
		return
	SteamManager.avatar_ready.disconnect(_on_avatar_ready)
	%AvatarRect.texture = texture
