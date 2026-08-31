extends Node2D

var is_on: bool = false
var radius: float = 3.0

func _ready() -> void:
	visible = is_on

func _process(_delta: float) -> void:
	global_position = get_global_mouse_position()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color.RED)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		is_on = !is_on
		visible = is_on
		queue_redraw()
