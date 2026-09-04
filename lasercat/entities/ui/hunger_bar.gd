extends Control

## Pixel-style hunger meter drawn as chunky pips instead of a smooth fill, so
## it reads as retro/pixel-art UI at any resolution without needing a bitmap
## font or texture asset. Self-contained and reusable: drop
## res://entities/ui/hunger_bar.tscn into any level (it anchors itself to the
## bottom-middle of the viewport) and drive it with feed()/set_value(). Every
## level can size it to its own catch goal via max_value instead of the bar
## being hardcoded to one number.

@export var max_value: int = 8:
	set(v):
		max_value = maxi(v, 1)
		value = mini(value, max_value)
		_layout()

@export_range(0, 999) var value: int = 0:
	set(v):
		value = clampi(v, 0, max_value)
		queue_redraw()

@export_group("Pixel style")
@export var pip_size: Vector2 = Vector2(20, 20)
@export var pip_gap: float = 5.0
@export var border_thickness: float = 3.0
@export var fill_color: Color = Color("e0562f")
@export var empty_color: Color = Color("332b2b")
@export var border_color: Color = Color("f5f0e6")
@export var shadow_offset: Vector2 = Vector2(3, 3)
@export var shadow_color: Color = Color(0, 0, 0, 0.4)
@export var bottom_margin: float = 22.0

func _ready() -> void:
	_layout()

func feed(amount: int = 1) -> void:
	value += amount

func reset() -> void:
	value = 0

# Resizes/repositions this Control to hug the bottom-middle of the viewport,
# sized to fit exactly max_value pips, then redraws.
func _layout() -> void:
	var width: float = max_value * pip_size.x + (max_value - 1) * pip_gap + border_thickness * 2.0
	var height: float = pip_size.y + border_thickness * 2.0
	custom_minimum_size = Vector2(width, height)
	size = custom_minimum_size
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -width / 2.0
	offset_right = width / 2.0
	offset_bottom = -bottom_margin
	offset_top = offset_bottom - height
	queue_redraw()

func _draw() -> void:
	# Drop shadow first so it peeks out from behind the border for a bit of depth.
	draw_rect(Rect2(shadow_offset, size), shadow_color, true)
	# Border frame.
	draw_rect(Rect2(Vector2.ZERO, size), border_color, true)
	# Interior tray (shows through the gaps between pips).
	var inset := Vector2(border_thickness, border_thickness)
	draw_rect(Rect2(inset, size - inset * 2.0), empty_color, true)
	# Pips, left to right, filled up to `value`.
	for i in max_value:
		var pos := Vector2(border_thickness + i * (pip_size.x + pip_gap), border_thickness)
		var col := fill_color if i < value else empty_color
		draw_rect(Rect2(pos, pip_size), col, true)
