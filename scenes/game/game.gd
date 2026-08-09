extends Control
## Placeholder game scene. Every peer lands here when the host presses Start in
## the lobby (NetworkManager.start_game -> _enter_game RPC -> this scene).
##
## The network peer, roster, voice and chat all persist across the scene change
## because they live on autoloads — so this is where you build the actual game.
## Replace the contents, spawn your world, read NetworkManager.players, etc.

const MAIN_MENU: String = "res://scenes/main_menu/main_menu.tscn"

@onready var _player_count: Label = %PlayerCountLabel

func _ready() -> void:
	NetworkManager.lobby_left.connect(_return_to_menu)
	NetworkManager.kicked.connect(func(_reason: String) -> void: _return_to_menu())
	NetworkManager.player_list_changed.connect(_update_count)
	%LeaveButton.pressed.connect(func() -> void: NetworkManager.leave())
	_update_count()

func _update_count() -> void:
	_player_count.text = "%d players connected" % NetworkManager.players.size()

func _return_to_menu() -> void:
	get_tree().change_scene_to_file(MAIN_MENU)
