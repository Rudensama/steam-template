extends Control
## The lobby, composed from reusable pieces: a PlayerListPanel (roster) and a
## ChatPanel do their own work; this script only wires the top bar (join info /
## copy / invite / settings), the bottom bar (voice hint / ready / start / leave),
## and the settings overlay. All transport-agnostic (Steam or LAN).

const MAIN_MENU: String = "res://scenes/main_menu/main_menu.tscn"
const SETTINGS_OVERLAY: PackedScene = preload("res://ui/overlays/settings_overlay.tscn")

@onready var _chat_panel: ChatPanel = %ChatPanel
@onready var _join_info_label: Label = %JoinInfoLabel
@onready var _invite_button: Button = %InviteButton
@onready var _copy_button: Button = %CopyButton
@onready var _ready_button: Button = %ReadyButton
@onready var _start_button: Button = %StartButton
@onready var _info_label: Label = %InfoLabel
@onready var _invite_overlay: FriendInvitePanel = %InviteOverlay

var _copy_default: String = "Copy Code"
var _settings: CanvasLayer

func _ready() -> void:
	NetworkManager.player_list_changed.connect(_update_controls)
	NetworkManager.lobby_left.connect(_return_to_menu)
	NetworkManager.kicked.connect(func(_reason: String) -> void: _return_to_menu())
	Settings.changed.connect(func(_key: String) -> void: _update_voice_hint())

	%LeaveButton.pressed.connect(func() -> void: NetworkManager.leave())
	%SettingsButton.pressed.connect(_open_settings)
	_ready_button.toggled.connect(func(on: bool) -> void: NetworkManager.set_ready(on))
	_invite_button.pressed.connect(func() -> void: _invite_overlay.open())
	_copy_button.pressed.connect(_on_copy)
	_start_button.pressed.connect(func() -> void: NetworkManager.start_game())
	_invite_overlay.friend_invited.connect(_on_friend_invited)

	if NetworkManager.mode == NetworkManager.Mode.STEAM:
		_join_info_label.text = "Lobby code:  %d" % NetworkManager.steam_lobby_id
		_invite_button.visible = true
		_copy_default = "Copy Code"
	else:
		_join_info_label.text = "LAN:  %s : %d" % [NetworkManager.get_local_ip(), NetworkManager.DEFAULT_PORT]
		_invite_button.visible = false
		_copy_default = "Copy IP"
	_copy_button.text = _copy_default

	_start_button.visible = NetworkManager.is_host
	_update_voice_hint()
	_update_controls()
	_chat_panel.system_line("Entered lobby.")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_open_settings()
		get_viewport().set_input_as_handled()

func _update_controls() -> void:
	_ready_button.set_pressed_no_signal(NetworkManager.is_ready())
	_ready_button.text = "Ready ✓" if NetworkManager.is_ready() else "Ready"
	if NetworkManager.is_host:
		_start_button.disabled = not NetworkManager.everyone_ready()

func _on_friend_invited(friend_id: int) -> void:
	_chat_panel.system_line("Invite sent to %s." % Steam.getFriendPersonaName(friend_id))

func _on_copy() -> void:
	if NetworkManager.mode == NetworkManager.Mode.STEAM:
		DisplayServer.clipboard_set(str(NetworkManager.steam_lobby_id))
	else:
		DisplayServer.clipboard_set(NetworkManager.get_local_ip())
	_copy_button.text = "Copied!"
	await get_tree().create_timer(1.5).timeout
	if is_instance_valid(_copy_button):
		_copy_button.text = _copy_default

func _open_settings() -> void:
	if is_instance_valid(_settings):
		return
	_settings = SETTINGS_OVERLAY.instantiate()
	add_child(_settings)
	_settings.open()

func _update_voice_hint() -> void:
	_info_label.text = "Open mic — just speak" if VoiceManager.mic_mode == VoiceManager.MicMode.OPEN_MIC \
		else "Hold V to talk"

func _return_to_menu() -> void:
	get_tree().change_scene_to_file(MAIN_MENU)
