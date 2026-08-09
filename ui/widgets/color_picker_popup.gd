extends PopupPanel
## A small grid of the lobby color palette (NetworkManager.PLAYER_COLORS). Colors
## already taken by OTHER players are disabled. Emits color_chosen(index) when a
## free color is picked. Opened by a player's own card.
class_name ColorPickerPopup

signal color_chosen(index: int)

@onready var _grid: GridContainer = %Grid

## Build the swatches for `owner_peer` (their current color stays selectable) and
## show the popup just below `anchor`.
func open_for(owner_peer: int, anchor: Control) -> void:
	for child: Node in _grid.get_children():
		child.queue_free()
	for i: int in NetworkManager.PLAYER_COLORS.size():
		var color: Color = NetworkManager.PLAYER_COLORS[i]
		var swatch: Button = Button.new()
		swatch.custom_minimum_size = Vector2(40, 40)
		swatch.add_theme_stylebox_override("normal", _swatch_style(color))
		swatch.add_theme_stylebox_override("hover", _swatch_style(color.lightened(0.15)))
		swatch.add_theme_stylebox_override("pressed", _swatch_style(color))
		swatch.add_theme_stylebox_override("disabled", _swatch_style(color.darkened(0.6)))
		if NetworkManager.is_color_taken(i, owner_peer):
			swatch.disabled = true
		else:
			var idx: int = i
			swatch.pressed.connect(func() -> void:
				color_chosen.emit(idx)
				hide())
		_grid.add_child(swatch)
	popup(Rect2i(Vector2i(anchor.get_screen_position()) + Vector2i(0, int(anchor.size.y) + 4), Vector2i(0, 0)))

static func _swatch_style(color: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(10)
	return sb
