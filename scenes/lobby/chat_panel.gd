extends PanelContainer
## Lobby text chat: renders each message as an avatar + rounded bubble row
## (ChatMessage), tinted with the sender's lobby color. system_line() posts a
## centered gray status note. Self-contained; talks to NetworkManager directly.
class_name ChatPanel

const CHAT_MESSAGE: PackedScene = preload("res://scenes/lobby/chat_message.tscn")

@onready var _scroll: ScrollContainer = %MessageScroll
@onready var _list: VBoxContainer = %MessageList
@onready var _input: LineEdit = %ChatInput

func _ready() -> void:
	NetworkManager.chat_received.connect(_on_received)
	%SendButton.pressed.connect(_send)
	_input.text_submitted.connect(func(_t: String) -> void: _send())

## Post a non-player status line (joins, invites, host actions).
func system_line(text: String) -> void:
	var label: Label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(0.42, 0.447, 0.502))
	label.add_theme_font_size_override("font_size", 12)
	_list.add_child(label)
	_scroll_to_bottom()

func _send() -> void:
	var text: String = _input.text
	_input.clear()
	_input.grab_focus()
	NetworkManager.send_chat(text)

func _on_received(sender_name: String, text: String, steam_id: int, peer_id: int, color: int) -> void:
	var is_own: bool = NetworkManager.is_own_message(steam_id, peer_id)
	var tint: Color = NetworkManager.PLAYER_COLORS[clampi(color, 0, NetworkManager.PLAYER_COLORS.size() - 1)]
	var msg: ChatMessage = CHAT_MESSAGE.instantiate()
	_list.add_child(msg)
	msg.setup(sender_name, text, steam_id, tint, is_own)
	_scroll_to_bottom()

func _scroll_to_bottom() -> void:
	# Wait for the new row to lay out (bubble autowrap height) before scrolling.
	await get_tree().process_frame
	await get_tree().process_frame
	# The lobby may have been torn down during those frames (e.g. left / kicked).
	if not is_instance_valid(_scroll):
		return
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
