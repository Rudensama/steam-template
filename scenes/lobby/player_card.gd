extends PanelContainer
## One player in the lobby roster.
##   Top row:    talk indicator, circular avatar bordered with the player's color
##               (click your OWN avatar to recolor), name + host/you, ready badge,
##               ping.
##   Second row: per-player voice volume, mute, and host kick — other players only.
## Every player's color is shown to everyone. Cards update in place (no flicker).
## Instantiated by player_list.gd.
class_name PlayerCard

signal mute_toggled(peer_id: int, muted: bool)
signal volume_changed(peer_id: int, volume: float)
signal kick_pressed(peer_id: int)

const COLOR_PICKER: PackedScene = preload("res://ui/widgets/color_picker_popup.tscn")

## Card border reflects ready state instead of a badge.
const READY_BORDER: Color = Color(0.38, 0.78, 0.55)     ## soft green
const NOT_READY_BORDER: Color = Color(0.87, 0.44, 0.53) ## soft pinkish red

var peer_id: int = 0
var _is_local: bool = false
var _pending_avatar_sid: int = 0

@onready var _avatar_bg: Panel = %AvatarBg
@onready var _avatar_initial: Label = %AvatarInitial
@onready var _avatar_tex: TextureRect = %AvatarTex
@onready var _ring: Panel = %Ring
@onready var _avatar_button: Button = %AvatarButton
@onready var _name_label: Label = %NameLabel
@onready var _status_label: Label = %StatusLabel
@onready var _talk_dot: Panel = %TalkDot
@onready var _ping_label: Label = %PingLabel
@onready var _controls: HBoxContainer = %Controls
@onready var _mute_button: Button = %MuteButton
@onready var _volume_slider: HSlider = %VolumeSlider
@onready var _kick_button: Button = %KickButton

func setup(id: int, info: Dictionary, is_local: bool, viewer_is_host: bool) -> void:
	peer_id = id
	_is_local = is_local

	# Volume / mute / kick are for OTHER players; clicking your own avatar recolors.
	_controls.visible = not is_local
	_mute_button.visible = not is_local
	_kick_button.visible = viewer_is_host and not is_local
	_avatar_button.visible = is_local

	if not is_local:
		_mute_button.toggled.connect(_on_mute_toggled)
		_volume_slider.value_changed.connect(_on_volume_changed)
		_volume_slider.value = VoiceManager.get_peer_volume(id)
		_mute_button.button_pressed = VoiceManager.is_peer_muted(id)
		_refresh_mute_text()
	if _kick_button.visible:
		_kick_button.pressed.connect(func() -> void: kick_pressed.emit(peer_id))
	if is_local:
		_avatar_button.pressed.connect(_open_color_picker)

	_load_avatar(info)
	update(info)

func update(info: Dictionary) -> void:
	_name_label.text = info.get("name", "Player")

	var parts: Array[String] = []
	if peer_id == 1:
		parts.append("Host")
	if _is_local:
		parts.append("You")
	_status_label.text = "  •  ".join(parts)
	_status_label.visible = not parts.is_empty()

	# The whole card border signals ready (soft green) vs not ready (soft red).
	var card_sb: StyleBoxFlat = get_theme_stylebox("panel") as StyleBoxFlat
	if card_sb != null:
		card_sb.border_color = READY_BORDER if info.get("ready", false) else NOT_READY_BORDER

	var ping: int = info.get("ping", 0)
	# The host doesn't ping itself; hide a meaningless 0 for the local host card.
	_ping_label.visible = not (_is_local and peer_id == 1)
	_ping_label.text = "%d ms" % ping
	_ping_label.add_theme_color_override("font_color", _ping_color(ping))

	_apply_color()

func set_talking(on: bool) -> void:
	var sb: StyleBoxFlat = _talk_dot.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.bg_color = Color(0.29, 0.871, 0.502) if on else Color(0.235, 0.263, 0.322)

# --- Internals -------------------------------------------------------------

## Paint the avatar's ring border (and fallback background) with the player's
## color. Runs on every update so color changes replicate live for all cards.
func _apply_color() -> void:
	var color: Color = NetworkManager.get_player_color(peer_id)
	var ring_sb: StyleBoxFlat = _ring.get_theme_stylebox("panel") as StyleBoxFlat
	if ring_sb != null:
		ring_sb.border_color = color
	var bg_sb: StyleBoxFlat = _avatar_bg.get_theme_stylebox("panel") as StyleBoxFlat
	if bg_sb != null:
		bg_sb.bg_color = color.darkened(0.35)

func _ping_color(ping: int) -> Color:
	if ping <= 0:
		return Color(0.42, 0.447, 0.502)
	if ping < 80:
		return Color(0.29, 0.871, 0.502)
	if ping < 160:
		return Color(0.961, 0.62, 0.298)
	return Color(0.937, 0.325, 0.314)

func _on_mute_toggled(pressed: bool) -> void:
	VoiceManager.set_peer_muted(peer_id, pressed)
	_refresh_mute_text()
	mute_toggled.emit(peer_id, pressed)

func _refresh_mute_text() -> void:
	_mute_button.text = "Muted" if _mute_button.button_pressed else "Mute"

func _on_volume_changed(value: float) -> void:
	VoiceManager.set_peer_volume(peer_id, value)
	volume_changed.emit(peer_id, value)

func _open_color_picker() -> void:
	var popup: ColorPickerPopup = COLOR_PICKER.instantiate()
	add_child(popup)
	popup.color_chosen.connect(func(index: int) -> void: NetworkManager.set_player_color(index))
	popup.popup_hide.connect(popup.queue_free)
	popup.open_for(peer_id, _avatar_button)

func _load_avatar(info: Dictionary) -> void:
	var pname: String = info.get("name", "Player")
	_avatar_initial.text = pname.substr(0, 1).to_upper() if pname != "" else "?"

	var sid: int = info.get("steam_id", 0)
	if sid > 0 and SteamManager.is_online():
		_pending_avatar_sid = sid
		# Shared cache: returns the texture now if ready, else fires avatar_ready.
		var tex: Texture2D = SteamManager.request_avatar(sid)
		if tex != null:
			_show_avatar(tex)
		else:
			SteamManager.avatar_ready.connect(_on_avatar_ready)

func _exit_tree() -> void:
	if SteamManager.avatar_ready.is_connected(_on_avatar_ready):
		SteamManager.avatar_ready.disconnect(_on_avatar_ready)

func _on_avatar_ready(user_id: int, texture: Texture2D) -> void:
	if user_id != _pending_avatar_sid:
		return
	SteamManager.avatar_ready.disconnect(_on_avatar_ready)
	_show_avatar(texture)

func _show_avatar(texture: Texture2D) -> void:
	_avatar_tex.texture = texture
	_avatar_tex.visible = true
	_avatar_initial.visible = false
