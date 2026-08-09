extends Control
## Full-screen popup listing the local user's online friends as invite rows.
## Embeds FriendInviteRow instances into its list on open().
class_name FriendInvitePanel

signal friend_invited(friend_id: int)
signal closed

const FRIEND_ROW_SCENE: PackedScene = preload("res://ui/widgets/friend_invite_row.tscn")

@onready var _friend_list: VBoxContainer = %FriendList

func open() -> void:
	for child: Node in _friend_list.get_children():
		child.queue_free()
	var friends: Array[Dictionary] = SteamManager.get_online_friends()
	if friends.is_empty():
		var empty: Label = Label.new()
		empty.text = "No online friends to invite."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_friend_list.add_child(empty)
	else:
		for friend: Dictionary in friends:
			var row: FriendInviteRow = FRIEND_ROW_SCENE.instantiate()
			_friend_list.add_child(row)
			row.setup(friend)
			row.invite_requested.connect(_on_row_invite)
	visible = true

func close() -> void:
	visible = false
	closed.emit()

func _ready() -> void:
	%CloseButton.pressed.connect(close)
	%OverlayInviteButton.pressed.connect(_on_overlay_invite)

func _on_row_invite(friend_id: int) -> void:
	if SteamManager.invite_friend(NetworkManager.steam_lobby_id, friend_id):
		friend_invited.emit(friend_id)
		close()

func _on_overlay_invite() -> void:
	visible = false
	SteamManager.invite_friends(NetworkManager.steam_lobby_id)
