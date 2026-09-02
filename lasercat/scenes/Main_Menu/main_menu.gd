extends Node3D

@onready var camera: Camera3D = $Camera3D
@onready var laser: Node3D = $Laser
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $NavigationRegion3D/Ground

func _ready() -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var center := ground.global_position
	var view_size := 10.0  # the area you want visible, in world units
	var distance := 10.0   # just needs to clear near/far clip, doesn't affect framing in ortho mode
	camera.global_position = center + Vector3(0.0, distance, distance)
	camera.look_at(center, Vector3.UP)
	var vp_size := get_viewport().get_visible_rect().size
	var aspect := vp_size.x / vp_size.y
	camera.size = view_size / aspect if aspect < 1.0 else view_size

	laser.camera = camera
	laser.ground = ground
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)

func _on_target_updated(pos: Vector3) -> void:
	cat.target_pos = pos

func _on_laser_toggled(is_on: bool) -> void:
	if not is_on:
		cat.change_state(cat.State.IDLE)
