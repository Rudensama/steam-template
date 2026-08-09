extends Control
## A live microphone level meter. The filled bar is your current input level; the
## vertical marker is the noise-gate threshold. Anything left of the marker is
## treated as background noise and is NOT transmitted, so you can literally see
## where the static ends and set the threshold just above it.
##
## Reads VoiceManager.get_mic_level() and VoiceManager.mic_threshold every frame.
class_name MicMeter

## Level (and threshold) are mapped 0..MAX_DISPLAY across the full width. Keep it
## in sync with the threshold slider's max_value so the marker lines up.
const MAX_DISPLAY: float = 0.15

var _bg: StyleBoxFlat = StyleBoxFlat.new()
var _fill: StyleBoxFlat = StyleBoxFlat.new()

func _ready() -> void:
	custom_minimum_size.y = 20
	for sb: StyleBoxFlat in [_bg, _fill]:
		sb.corner_radius_top_left = 6
		sb.corner_radius_top_right = 6
		sb.corner_radius_bottom_right = 6
		sb.corner_radius_bottom_left = 6
	_bg.bg_color = Color(0.09, 0.102, 0.129)

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	draw_style_box(_bg, Rect2(0, 0, w, h))

	var raw: float = VoiceManager.get_mic_level()
	var level: float = clampf(raw / MAX_DISPLAY, 0.0, 1.0)
	var thr: float = clampf(VoiceManager.mic_threshold / MAX_DISPLAY, 0.0, 1.0)

	if level > 0.001:
		# Green while you're above the gate (transmitting), grey while it's just noise.
		_fill.bg_color = Color(0.29, 0.871, 0.502) if raw >= VoiceManager.mic_threshold \
			else Color(0.38, 0.42, 0.49)
		draw_style_box(_fill, Rect2(0, 0, maxf(w * level, 8.0), h))

	var x: float = w * thr
	draw_line(Vector2(x, 2), Vector2(x, h - 2), Color(0.96, 0.97, 1.0, 0.9), 2.0)
