@tool
extends Area3D
class_name PatrolVehicle


# ============================================================
# VEHICLE SETTINGS
# ============================================================

@export_category("Vehicle")

@export var cat: CharacterBody3D

@export var speed: float = 4.0


@export_enum("LOOP", "PING_PONG")
var loop_mode: int = 0


# ============================================================
# AUDIO
# ============================================================

@export_category("Audio")

@export var pass_by_range: float = 10.0
@export var pass_by_cooldown: float = 3.0
@export var audio_volume_db: float = -6.0


@export_range(0.0, 1.0, 0.01)
var start_percent: float = 0.0


# ============================================================
# PATH
# ============================================================

@export_category("Path")

@export_node_path("Marker3D")
var point_a_path: NodePath


@export_node_path("Marker3D")
var point_b_path: NodePath


# ============================================================
# MODEL
# ============================================================

@export_category("Model")

@export var vehicle_model: String = "":
	set(value):
		vehicle_model = value

		# Update immediately when changed in the editor.
		_update_model_visibility()


# ============================================================
# NODES
# ============================================================

@onready var models: Node3D = $Models
@onready var collision_shape: CollisionShape3D = $CollisionShape3D


# ============================================================
# RUNTIME VARIABLES
# ============================================================

signal hit_cat

var _traveled: float = 0.0
var _total_dist: float = 0.0

var _a_pos: Vector3
var _b_pos: Vector3

var _dir: int = 1

var _sound_player: AudioStreamPlayer  # non-positional — see the note in cat.gd's _setup_audio
var _sound_timer: float = 0.0


# ============================================================
# CREATE MODEL DROPDOWN
# ============================================================

func _validate_property(property: Dictionary) -> void:

	if property.name != "vehicle_model":
		return

	var model_names: PackedStringArray = []

	var model_container := get_node_or_null("Models")

	if model_container:

		for child in model_container.get_children():

			if child is MeshInstance3D:
				model_names.append(child.name)

	if not model_names.is_empty():

		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(model_names)


# ============================================================
# READY
# ============================================================

func _ready() -> void:

	# Editor setup.
	if Engine.is_editor_hint():
		_update_model_visibility()
		return

	# Runtime setup.
	add_to_group("vehicles")

	body_entered.connect(_on_body_entered)

	_sound_player = AudioStreamPlayer.new()
	_sound_player.name = "SoundPlayer"
	_sound_player.volume_db = audio_volume_db
	add_child(_sound_player)
	_sound_timer = randf_range(0.0, pass_by_cooldown)  # stagger multiple vehicles

	# --------------------------------------------------------
	# Get path markers.
	# --------------------------------------------------------

	var point_a := get_node_or_null(point_a_path) as Marker3D
	var point_b := get_node_or_null(point_b_path) as Marker3D

	if point_a == null:
		push_error("%s: Point A marker is not assigned." % name)
		return

	if point_b == null:
		push_error("%s: Point B marker is not assigned." % name)
		return

	# Cache world-space positions.
	_a_pos = point_a.global_position
	_b_pos = point_b.global_position

	_total_dist = _a_pos.distance_to(_b_pos)

	if _total_dist <= 0.0:
		push_error(
			"%s: Point A and Point B are at the same position."
			% name
		)
		return

	# --------------------------------------------------------
	# Start at percentage along path.
	# --------------------------------------------------------

	_traveled = _total_dist * start_percent

	global_position = _a_pos.lerp(
		_b_pos,
		start_percent
	)

	# Face direction of travel.
	var forward := (_b_pos - _a_pos).normalized()

	if forward.length() > 0.01:

		look_at(
			global_position + forward,
			Vector3.UP
		)
		rotate_y(deg_to_rad(-90.0))

	# --------------------------------------------------------
	# Reset model positions.
	# --------------------------------------------------------

	var model_container := get_node_or_null("Models")

	if model_container:

		for child in model_container.get_children():

			if child is MeshInstance3D:
				child.position = Vector3.ZERO

	_update_model_visibility()


# ============================================================
# MODEL SELECTION
# ============================================================

func _update_model_visibility() -> void:

	var model_container := get_node_or_null("Models")

	if model_container == null:
		return


	var selected_mesh: MeshInstance3D = null


	# --------------------------------------------------------
	# Find selected model.
	# --------------------------------------------------------

	if vehicle_model != "":

		for child in model_container.get_children():

			if child is MeshInstance3D:

				if child.name == vehicle_model:

					selected_mesh = child
					break


	# --------------------------------------------------------
	# If nothing selected, use first model.
	# --------------------------------------------------------

	if selected_mesh == null:

		for child in model_container.get_children():

			if child is MeshInstance3D:

				selected_mesh = child

				# Only automatically save this at runtime.
				if not Engine.is_editor_hint():
					vehicle_model = child.name

				break


	# --------------------------------------------------------
	# Show selected model and hide everything else.
	# --------------------------------------------------------

	for child in model_container.get_children():

		if child is MeshInstance3D:

			child.visible = (child == selected_mesh)


	# --------------------------------------------------------
	# Update collision.
	# --------------------------------------------------------

	if selected_mesh:

		_fit_collision_to_mesh(selected_mesh)


# ============================================================
# COLLISION
# ============================================================

func _fit_collision_to_mesh(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance == null:
		return

	if mesh_instance.mesh == null:
		return

	var collision := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision == null:
		return

	# Get the actual bounds of this MeshInstance3D,
	# including its transform.
	var aabb := mesh_instance.get_aabb()

	# Create a fresh collision shape for this vehicle.
	var box := BoxShape3D.new()
	box.size = aabb.size

	collision.shape = box

	# Position the collision box at the center of the mesh.
	collision.position = aabb.position + aabb.size * 0.5


# ============================================================
# MOVEMENT
# ============================================================

func _process(delta: float) -> void:

	# Never move while editing the level.
	if Engine.is_editor_hint():
		return

	if _total_dist <= 0.0:
		return

	_update_pass_sound(delta)

	_traveled += speed * delta * _dir


	# --------------------------------------------------------
	# Reached Point B.
	# --------------------------------------------------------

	if _traveled >= _total_dist:

		match loop_mode:

			# LOOP
			0:
				_traveled = 0.0

			# PING PONG
			1:
				_traveled = _total_dist
				_dir = -1


	# --------------------------------------------------------
	# Reached Point A travelling backwards.
	# --------------------------------------------------------

	elif _traveled <= 0.0 and _dir == -1:

		_traveled = 0.0
		_dir = 1


	# --------------------------------------------------------
	# Calculate position.
	# --------------------------------------------------------

	var t := _traveled / _total_dist

	global_position = _a_pos.lerp(
		_b_pos,
		t
	)


	# --------------------------------------------------------
	# Rotate vehicle.
	# --------------------------------------------------------

	var forward := (
		_b_pos - _a_pos
	).normalized() * _dir


	if forward.length() > 0.01:

		look_at(
			global_position + forward,
			Vector3.UP
		)
		rotate_y(deg_to_rad(-90.0))

# ============================================================
# CAT HIT
# ============================================================

func _on_body_entered(body: Node3D) -> void:

	if body == cat:
		hit_cat.emit()


# ============================================================
# SOUND
# ============================================================

# An engine pass-by clip whenever the cat is close enough to hear it, throttled
# by pass_by_cooldown so it doesn't loop a short recording back to back.
func _update_pass_sound(delta: float) -> void:

	if _sound_timer > 0.0:
		_sound_timer -= delta

	if cat == null or not is_instance_valid(cat) or _sound_timer > 0.0:
		return

	if global_position.distance_to(cat.global_position) <= pass_by_range:

		var stream := SoundLibrary.random("vehicle/car")

		if stream:
			_sound_player.stream = stream
			_sound_player.pitch_scale = randf_range(0.95, 1.08)
			_sound_player.play()
			_sound_timer = pass_by_cooldown
