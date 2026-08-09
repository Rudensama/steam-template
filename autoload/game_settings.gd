extends Node
## Persists user settings to `user://settings.cfg` and applies them to the audio
## system, voice manager, window and network identity. Load happens on startup so
## every choice (volumes, mic, voice mode/threshold, fullscreen, name) survives a
## restart — a real game needs this and a template should ship it.
##
## Autoload singleton name: Settings  (must load AFTER VoiceManager).

signal changed(key: String)

const PATH: String = "user://settings.cfg"
const SECTION: String = "settings"

## Defaults used the first time the game runs (no config file yet).
var _defaults: Dictionary = {
	"master_volume": 1.0,
	"voice_volume": 1.0,
	"voice_enabled": true,
	"mic_mode": VoiceManager.MicMode.PUSH_TO_TALK,
	"mic_device": "",            # "" = leave Godot's current input device
	"mic_threshold": 0.02,
	"listen_self": false,
	"fullscreen": false,
	"display_name": "",
}

var _data: Dictionary = {}

func _ready() -> void:
	_data = _defaults.duplicate()
	_load()
	# Defer so the other autoloads have finished their own _ready() first.
	call_deferred("apply_all")

func get_value(key: String) -> Variant:
	return _data.get(key, _defaults.get(key))

## Store a value and persist immediately. Applying it to the live game is the
## caller's job (settings UI does this so sliders feel instant).
func set_value(key: String, value: Variant) -> void:
	_data[key] = value
	_save()
	changed.emit(key)

func _load() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for key: String in _defaults:
		if cfg.has_section_key(SECTION, key):
			_data[key] = cfg.get_value(SECTION, key)

func _save() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	for key: String in _data:
		cfg.set_value(SECTION, key, _data[key])
	cfg.save(PATH)

## Push every stored value into the running game. Called once on boot and safe to
## call again after a bulk change.
func apply_all() -> void:
	var master_bus: int = AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master_bus, linear_to_db(maxf(get_value("master_volume"), 0.0001)))

	VoiceManager.playback_volume = get_value("voice_volume")
	VoiceManager.enabled = get_value("voice_enabled")
	VoiceManager.mic_mode = get_value("mic_mode")
	VoiceManager.mic_threshold = get_value("mic_threshold")
	VoiceManager.set_listen_to_self(get_value("listen_self"))

	var device: String = get_value("mic_device")
	if device != "" and device in AudioServer.get_input_device_list():
		AudioServer.input_device = device

	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if get_value("fullscreen")
		else DisplayServer.WINDOW_MODE_WINDOWED
	)

	var saved_name: String = get_value("display_name")
	if saved_name.strip_edges() != "":
		NetworkManager.display_name = saved_name
