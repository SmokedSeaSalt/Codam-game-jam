extends Area3D

@export var cat: CharacterBody3D
@export var level: PackedScene
@export var text_node: MeshInstance3D
@export var box_node: MeshInstance3D
@export var pulse_speed: float = 2.0
@export var pulse_amount: float = 0.08
@export var color_from: Color = Color(0.8, 0.2, 0.2)
@export var color_to: Color = Color(0.2, 0.9, 0.3)
@export var activate_time: float = 2.0
@export var reset_on_exit: bool = true
@export var press_depth: float = 0.1     # how far down it sinks, in world units
@export var press_speed: float = 10.0      # how snappy the press/release is

var triggered: bool = false
var _base_scale: Vector3 = Vector3.ONE
var _cat_on_button: bool = false
var _progress: float = 0.0
var _box_mat: StandardMaterial3D
var _base_y: float

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if text_node:
		_base_scale = text_node.scale
	if box_node:
		_box_mat = box_node.get_active_material(0) as StandardMaterial3D
		if _box_mat == null or not (box_node.material_override is StandardMaterial3D):
			_box_mat = StandardMaterial3D.new()
			box_node.material_override = _box_mat
		_box_mat.albedo_color = color_from
	_base_y = position.y

func _process(delta: float) -> void:
	if text_node:
		var s := 1.0 + sin(Time.get_ticks_msec() / 1000.0 * pulse_speed) * pulse_amount
		text_node.scale = _base_scale * s

	# Press/release the whole button, regardless of triggered state, so it still
	# feels responsive even after activation locks the color/level logic.
	var target_y := _base_y - press_depth if _cat_on_button else _base_y
	position.y = lerp(position.y, target_y, 1.0 - exp(-press_speed * delta))

	if triggered:
		return

	if _cat_on_button:
		_progress = min(_progress + delta / activate_time, 1.0)
	elif reset_on_exit:
		_progress = max(_progress - delta / activate_time, 0.0)

	if _box_mat:
		_box_mat.albedo_color = color_from.lerp(color_to, _progress)

	if _progress >= 1.0:
		triggered = true
		get_tree().change_scene_to_packed(level)

func _on_body_entered(body: Node3D) -> void:
	if body == cat:
		_cat_on_button = true

func _on_body_exited(body: Node3D) -> void:
	if body == cat:
		_cat_on_button = false
