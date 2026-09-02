extends Node3D
@onready var camera: Camera3D = $Camera3D
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $Ground
@onready var terrain: Node3D = $Terrain
@onready var laser: Node3D = $Laser

enum FollowMode { LASER, CAT }

@export var camera_follow_mode: FollowMode = FollowMode.CAT
@export var camera_follow_speed: float = 9.0

var cam_offset: Vector3

func _ready() -> void:
	_fit_ground_to_terrain()

	laser.camera = camera
	laser.ground = ground
	laser.cat = cat
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)

	camera.look_at(Vector3.ZERO)
	cam_offset = camera.global_position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Wait one physics step so terrain's runtime-built collider exists,
	# then drop the cat, camera and laser onto the surface.
	await get_tree().physics_frame
	var spawn_xz := Vector3(cat.global_position.x, 0.0, cat.global_position.z)
	cat.global_position.y = _surface_y(spawn_xz.x, spawn_xz.z) + 0.1
	laser.start_at(spawn_xz)
	camera.global_position = spawn_xz + cam_offset

# Terrain sizes itself from the heightmap png, so match the invisible clamp
# plane to its footprint (children run _ready before us, so cols/rows are set).
func _fit_ground_to_terrain() -> void:
	var pm := ground.mesh as PlaneMesh
	if pm and "cols" in terrain:
		pm.size = Vector2(terrain.cols * terrain.tile_size, terrain.rows * terrain.tile_size)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().quit()

func _process(delta: float) -> void:
	var cam_target := _camera_focus() + cam_offset
	var t := 1.0 - exp(-camera_follow_speed * delta)
	camera.global_position = camera.global_position.lerp(cam_target, t)
	if camera.global_position.distance_to(cam_target) < 0.01:
		camera.global_position = cam_target

func _camera_focus() -> Vector3:
	match camera_follow_mode:
		FollowMode.CAT:
			return Vector3(cat.global_position.x, 0.0, cat.global_position.z)
		_:
			return Vector3(laser.laser_pos.x, 0.0, laser.laser_pos.z)

func _on_target_updated(pos: Vector3) -> void:
	cat.target_pos = pos

func _on_laser_toggled(is_on: bool) -> void:
	if not is_on:
		cat.change_state(cat.State.IDLE)

func _surface_y(x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	params.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	return hit.position.y if hit else 0.0
