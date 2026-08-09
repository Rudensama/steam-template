extends Control
## Entry screen. Shows Steam connection status, then continues to the main menu.
## Also catches invite-at-launch: if the game was opened via a Steam invite,
## NetworkManager emits lobby_ready and we jump straight into the lobby.

const MAIN_MENU: String = "res://scenes/main_menu/main_menu.tscn"
const LOBBY: String = "res://scenes/lobby/lobby.tscn"

@onready var status_label: Label = %StatusLabel
@onready var continue_button: Button = %ContinueButton

func _ready() -> void:
	_update_status(SteamManager.is_online())
	SteamManager.steam_ready.connect(_update_status)
	NetworkManager.lobby_ready.connect(_on_lobby_ready)
	continue_button.pressed.connect(_on_continue)

func _update_status(ok: bool) -> void:
	if ok:
		status_label.text = "Steam connected as %s" % SteamManager.steam_username
	else:
		status_label.text = "Steam offline — LAN only"

func _on_continue() -> void:
	get_tree().change_scene_to_file(MAIN_MENU)

func _on_lobby_ready() -> void:
	get_tree().change_scene_to_file(LOBBY)
