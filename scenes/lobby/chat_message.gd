extends MarginContainer
## One chat message. Other players' messages sit on the LEFT with a round avatar
## (Steam avatar, or a colored initial) + name + bubble. Your OWN messages sit on
## the RIGHT with no avatar/name (Messenger / Instagram style). Bubbles hug their
## text up to MAX_BUBBLE_WIDTH, then wrap, and are tinted with the sender's color.
## Instantiated by chat_panel.gd.
class_name ChatMessage

const MAX_BUBBLE_WIDTH: float = 360.0

@onready var _avatar: Control = %Avatar
@onready var _avatar_bg: Panel = %AvatarBg
@onready var _avatar_initial: Label = %AvatarInitial
@onready var _avatar_tex: TextureRect = %AvatarTex
@onready var _name_label: Label = %NameLabel
@onready var _text_label: Label = %TextLabel
@onready var _bubble: PanelContainer = %Bubble

var _sid: int = 0

func setup(sender_name: String, text: String, steam_id: int, color: Color, is_own: bool = false) -> void:
	_text_label.text = text
	_size_to_text(text)

	var bubble_sb: StyleBoxFlat = _bubble.get_theme_stylebox("panel") as StyleBoxFlat
	if bubble_sb != null:
		bubble_sb.bg_color = color.darkened(0.5)
		bubble_sb.border_color = color.darkened(0.2)

	if is_own:
		_layout_own(bubble_sb)
	else:
		_layout_other(sender_name, steam_id, color)

## Make the bubble hug the text: width = natural text width, capped at the max
## (the label wraps within that cap for long messages).
func _size_to_text(text: String) -> void:
	var font: Font = _text_label.get_theme_font("font")
	if font == null:
		return
	var font_size: int = _text_label.get_theme_font_size("font")
	var natural: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_text_label.custom_minimum_size.x = minf(natural, MAX_BUBBLE_WIDTH)

## Right-aligned, avatar + name hidden, bubble corner mirrored.
func _layout_own(bubble_sb: StyleBoxFlat) -> void:
	_avatar.visible = false
	_name_label.visible = false
	add_theme_constant_override("margin_left", 60)
	add_theme_constant_override("margin_right", 4)
	_bubble.size_flags_horizontal = Control.SIZE_SHRINK_END
	if bubble_sb != null:
		bubble_sb.corner_radius_top_left = 12
		bubble_sb.corner_radius_top_right = 4

## Left-aligned with the sender's avatar and name; bubble hugs the left.
func _layout_other(sender_name: String, steam_id: int, color: Color) -> void:
	_name_label.text = sender_name
	_name_label.add_theme_color_override("font_color", color)
	_avatar_initial.text = sender_name.substr(0, 1).to_upper() if sender_name != "" else "?"
	var avatar_sb: StyleBoxFlat = _avatar_bg.get_theme_stylebox("panel") as StyleBoxFlat
	if avatar_sb != null:
		avatar_sb.bg_color = color.darkened(0.1)
	_bubble.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	_sid = steam_id
	if steam_id > 0 and SteamManager.is_online():
		# Shared cache: returns the texture now if ready, else fires avatar_ready.
		var tex: Texture2D = SteamManager.request_avatar(steam_id)
		if tex != null:
			_show_avatar(tex)
		else:
			SteamManager.avatar_ready.connect(_on_avatar_ready)

func _exit_tree() -> void:
	if SteamManager.avatar_ready.is_connected(_on_avatar_ready):
		SteamManager.avatar_ready.disconnect(_on_avatar_ready)

func _on_avatar_ready(user_id: int, texture: Texture2D) -> void:
	if user_id != _sid:
		return
	SteamManager.avatar_ready.disconnect(_on_avatar_ready)
	_show_avatar(texture)

func _show_avatar(texture: Texture2D) -> void:
	_avatar_tex.texture = texture
	_avatar_tex.visible = true
	_avatar_initial.visible = false
