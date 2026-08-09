extends Control
## Game-style main menu: Play, Settings, Quit. Play opens the Online/Local modal;
## Settings opens the shared settings modal. Both are overlays, so the menu stays
## put behind them.

const LOBBY: String = "res://scenes/lobby/lobby.tscn"
const PLAY_OVERLAY: PackedScene = preload("res://ui/overlays/play_overlay.tscn")
const SETTINGS_OVERLAY: PackedScene = preload("res://ui/overlays/settings_overlay.tscn")

@onready var _status_label: Label = %StatusLabel

var _overlay: CanvasLayer

func _ready() -> void:
	%PlayButton.pressed.connect(_open_play)
	%SettingsButton.pressed.connect(_open_settings)
	%QuitButton.pressed.connect(func() -> void: get_tree().quit())

	NetworkManager.lobby_ready.connect(_on_lobby_ready)
	SteamManager.steam_ready.connect(func(_ok: bool) -> void: _update_status())
	_update_status()

	# A notice carried over from the lobby (e.g. "you were kicked").
	if NetworkManager.last_notice != "":
		_status_label.text = NetworkManager.last_notice
		NetworkManager.last_notice = ""

func _update_status() -> void:
	if SteamManager.is_online():
		_status_label.text = "Signed in to Steam as %s" % SteamManager.steam_username
	else:
		_status_label.text = "Steam offline — Local (LAN) play only"

func _open_play() -> void:
	_show_overlay(PLAY_OVERLAY)

func _open_settings() -> void:
	_show_overlay(SETTINGS_OVERLAY)

func _show_overlay(scene: PackedScene) -> void:
	if is_instance_valid(_overlay):
		return
	_overlay = scene.instantiate()
	add_child(_overlay)
	_overlay.open()

func _on_lobby_ready() -> void:
	get_tree().change_scene_to_file(LOBBY)
