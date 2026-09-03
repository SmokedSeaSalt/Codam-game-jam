extends Node3D
@onready var camera: Camera3D = $Camera3D
@onready var laser: Node3D = $Laser
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $NavigationRegion3D/Ground

func _ready() -> void:
	# Hide the OS pointer and feed the laser relative motion only, exactly like the
	# game scene — otherwise the dot drifts out of sync with the visible cursor.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	laser.camera = camera
	laser.ground = ground
	laser.cat = cat
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)

	# Seeds laser_pos + dot position from the cat's current spot, so the first
	# toggle-on doesn't snap the dot in from (0,0,0).
	laser.start_at(Vector3(cat.global_position.x, 0.0, cat.global_position.z))

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().quit()

func _on_target_updated(pos: Vector3) -> void:
	cat.target_pos = pos

func _on_laser_toggled(is_on: bool) -> void:
	cat.laser_active = is_on
	# Only the laser-following states get parked on IDLE when the dot goes out —
	# a stalk / chase / pounce / recover on a mouse must run to its own finish.
	if not is_on and cat.current_state in [cat.State.WALK, cat.State.CHASE]:
		cat.change_state(cat.State.IDLE)
