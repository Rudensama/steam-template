extends CanvasLayer
## The "Play" modal opened from the main menu. Two tabs:
##   * Online — host a Steam lobby or join one by code (friend invites happen
##     inside the lobby).
##   * Local  — host a LAN server or join one by IP address.
## Steam options disable automatically when Steam is offline.
##
## Triggers NetworkManager; the menu handles the scene change on lobby_ready.

signal closed

@onready var _name_edit: LineEdit = %NameEdit
@onready var _code_edit: LineEdit = %CodeEdit
@onready var _ip_edit: LineEdit = %IpEdit
@onready var _tabs: TabContainer = %Tabs
@onready var _status_label: Label = %StatusLabel
@onready var _lan_ip_label: Label = %LanIpLabel
@onready var _steam_note: Label = %SteamNote

func _ready() -> void:
	visible = false
	_name_edit.text = NetworkManager.get_display_name()
	if SteamManager.is_online():
		# The Steam name is used online; only editable as a LAN fallback offline.
		_name_edit.editable = false
		_name_edit.tooltip_text = "Using your Steam name"
	_ip_edit.text = "127.0.0.1"
	_lan_ip_label.text = "Others on your network join at  %s : %d" % [
		NetworkManager.get_local_ip(), NetworkManager.DEFAULT_PORT
	]

	%CloseButton.pressed.connect(close)
	get_node("%Dim").gui_input.connect(_on_dim_input)
	%HostSteamButton.pressed.connect(_on_host_steam)
	%JoinSteamButton.pressed.connect(_on_join_steam)
	%HostLanButton.pressed.connect(_on_host_lan)
	%JoinLanButton.pressed.connect(_on_join_lan)
	_code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_steam())
	_ip_edit.text_submitted.connect(func(_t: String) -> void: _on_join_lan())

	NetworkManager.connection_failed.connect(_on_connection_failed)

	var online: bool = SteamManager.is_online()
	%HostSteamButton.disabled = not online
	%JoinSteamButton.disabled = not online
	_code_edit.editable = online
	_steam_note.visible = not online
	if not online:
		_steam_note.text = "Steam is offline — Local (LAN) play only."
		_tabs.current_tab = 1

func open() -> void:
	visible = true
	_name_edit.grab_focus()

func close() -> void:
	closed.emit()
	queue_free()

func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()

func _commit_name() -> void:
	if SteamManager.is_online():
		return   # Steam name is authoritative; ignore the (disabled) field.
	NetworkManager.display_name = _name_edit.text
	Settings.set_value("display_name", _name_edit.text)

func _on_host_steam() -> void:
	_commit_name()
	_status_label.text = "Creating Steam lobby…"
	NetworkManager.host_steam()

func _on_join_steam() -> void:
	_commit_name()
	_status_label.text = "Joining lobby…"
	NetworkManager.join_steam(int(_code_edit.text.strip_edges()))

func _on_host_lan() -> void:
	_commit_name()
	_status_label.text = "Starting LAN server…"
	NetworkManager.host_lan()

func _on_join_lan() -> void:
	_commit_name()
	_status_label.text = "Connecting…"
	NetworkManager.join_lan(_ip_edit.text.strip_edges())

func _on_connection_failed(reason: String) -> void:
	_status_label.text = reason
