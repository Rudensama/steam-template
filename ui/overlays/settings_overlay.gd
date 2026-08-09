extends CanvasLayer
## Reusable settings modal. Instantiate it, add it as a child, and call open();
## it dims the screen behind it and closes on ✕ or Esc. Every change is applied
## live AND persisted through the Settings autoload, so nothing is lost on exit.
##
## Used by both the main menu and the in-lobby pause flow.

signal closed

@onready var _name_edit: LineEdit = %NameEdit
@onready var _master_slider: HSlider = %MasterSlider
@onready var _voice_slider: HSlider = %VoiceSlider
@onready var _voice_check: CheckButton = %VoiceEnabledCheck
@onready var _mic_mode_option: OptionButton = %MicModeOption
@onready var _mic_option: OptionButton = %MicOption
@onready var _listen_check: CheckButton = %ListenSelfCheck
@onready var _threshold_slider: HSlider = %MicThresholdSlider
@onready var _fullscreen_check: CheckButton = %FullscreenCheck

var _master_bus: int = 0

func _ready() -> void:
	visible = false
	_master_bus = AudioServer.get_bus_index("Master")

	%CloseButton.pressed.connect(close)
	get_node("%Dim").gui_input.connect(_on_dim_input)

	if SteamManager.is_online():
		# Online, your name comes from Steam — show it, read-only.
		_name_edit.text = SteamManager.steam_username
		_name_edit.editable = false
		_name_edit.tooltip_text = "Using your Steam name"
	else:
		_name_edit.text = str(Settings.get_value("display_name"))
		_name_edit.text_changed.connect(_on_name_changed)

	_master_slider.value = Settings.get_value("master_volume")
	_master_slider.value_changed.connect(_on_master_changed)

	_voice_slider.value = Settings.get_value("voice_volume")
	_voice_slider.value_changed.connect(func(v: float) -> void:
		VoiceManager.playback_volume = v
		Settings.set_value("voice_volume", v))

	_voice_check.button_pressed = Settings.get_value("voice_enabled")
	_voice_check.toggled.connect(func(on: bool) -> void:
		VoiceManager.enabled = on
		Settings.set_value("voice_enabled", on))

	_mic_mode_option.add_item("Push to Talk (V)", VoiceManager.MicMode.PUSH_TO_TALK)
	_mic_mode_option.add_item("Open Mic", VoiceManager.MicMode.OPEN_MIC)
	_mic_mode_option.selected = Settings.get_value("mic_mode")
	_mic_mode_option.item_selected.connect(func(index: int) -> void:
		VoiceManager.mic_mode = index as VoiceManager.MicMode
		Settings.set_value("mic_mode", index))

	_refresh_mic_list()
	_mic_option.item_selected.connect(_on_mic_selected)

	_listen_check.button_pressed = Settings.get_value("listen_self")
	_listen_check.toggled.connect(func(on: bool) -> void:
		VoiceManager.set_listen_to_self(on)
		Settings.set_value("listen_self", on))

	_threshold_slider.value = Settings.get_value("mic_threshold")
	_threshold_slider.value_changed.connect(func(v: float) -> void:
		VoiceManager.mic_threshold = v
		Settings.set_value("mic_threshold", v))

	_fullscreen_check.button_pressed = Settings.get_value("fullscreen")
	_fullscreen_check.toggled.connect(_on_fullscreen_toggled)

func open() -> void:
	visible = true
	# Run the mic monitor so the level meter is live even outside a session.
	VoiceManager.set_calibrating(true)

func close() -> void:
	VoiceManager.set_calibrating(false)
	closed.emit()
	queue_free()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func _on_dim_input(event: InputEvent) -> void:
	# Click outside the panel closes the modal.
	if event is InputEventMouseButton and event.pressed:
		close()

func _on_name_changed(text: String) -> void:
	NetworkManager.display_name = text
	Settings.set_value("display_name", text)

func _on_master_changed(value: float) -> void:
	AudioServer.set_bus_volume_db(_master_bus, linear_to_db(maxf(value, 0.0001)))
	Settings.set_value("master_volume", value)

func _refresh_mic_list() -> void:
	# Godot input devices. Steam voice captures from the mic set in
	# Steam > Settings > Voice; this selects Godot's own input (level meter).
	_mic_option.clear()
	var devices: PackedStringArray = AudioServer.get_input_device_list()
	if devices.is_empty():
		_mic_option.add_item("Default")
		_mic_option.disabled = true
		return
	_mic_option.disabled = false
	for device in devices:
		_mic_option.add_item(device)
		_mic_option.set_item_metadata(_mic_option.item_count - 1, device)
	var current: String = AudioServer.input_device
	var index: int = devices.find(current)
	_mic_option.selected = index if index >= 0 else 0

func _on_mic_selected(index: int) -> void:
	var device: String = _mic_option.get_item_metadata(index)
	AudioServer.input_device = device
	Settings.set_value("mic_device", device)

func _on_fullscreen_toggled(on: bool) -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED
	)
	Settings.set_value("fullscreen", on)
