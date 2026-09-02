extends Node3D

@onready var camera: Camera3D = $Camera3D
@onready var red_dot: MeshInstance3D = $RedDot
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $Ground
@onready var terrain: Node3D = $Terrain

enum FollowMode { LASER, CAT }  # what the camera keeps centred — flip to switch

@export var camera_follow_mode: FollowMode = FollowMode.CAT
@export var camera_follow_speed: float = 9.0
@export var laser_sensitivity: float = 1.0   # screen-space: 1.0 = dot tracks the mouse 1:1
@export var mouse_deadzone: float = 1.5     # px/frame below this is treated as "not moving"
@export var dot_height: float = 0.05        # fixed Y the dot rides at, terrain ignored

var cam_offset: Vector3
var laser_pos: Vector3 = Vector3.ZERO
var _mouse_motion: Vector2 = Vector2.ZERO

func _ready() -> void:
	_fit_ground_to_terrain()
	_make_dot_overlay()
	camera.look_at(Vector3.ZERO)
	cam_offset = camera.global_position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Wait one physics step so the terrain's runtime-built collider exists,
	# then drop the cat, the laser and the camera onto the surface.
	await get_tree().physics_frame
	laser_pos = Vector3(cat.global_position.x, 0.0, cat.global_position.z)
	cat.global_position.y = _surface_y(laser_pos.x, laser_pos.z) + 0.1
	camera.global_position = laser_pos + cam_offset

# The laser is light from the player's POV: it must never be hidden behind
# terrain, the cat or anything else. Draw it unlit, shadowless, and with the
# depth test off so it always renders on top of the scene.
func _make_dot_overlay() -> void:
	red_dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.05, 0.05)
	mat.no_depth_test = true
	mat.render_priority = 127
	red_dot.material_override = mat

# Terrain sizes itself from the heightmap png, so match the invisible clamp
# plane to its footprint (children run _ready before us, so cols/rows are set).
func _fit_ground_to_terrain() -> void:
	var pm := ground.mesh as PlaneMesh
	if pm and "cols" in terrain:
		pm.size = Vector2(terrain.cols * terrain.tile_size, terrain.rows * terrain.tile_size)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# Just bank the motion; it's applied once per frame in _process so bursty
		# input events don't translate into jittery laser movement.
		_mouse_motion += event.relative
	elif event.is_action_pressed("ui_cancel"):
		# Esc quits (mouse is captured, so this is the way out).
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().quit()

func _process(delta: float) -> void:
	# Ignore sub-deadzone jitter so a resting hand lets the camera fully settle.
	if _mouse_motion.length() < mouse_deadzone:
		_mouse_motion = Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _mouse_motion != Vector2.ZERO:
		# Move the laser in SCREEN space, then drop it back onto the ground plane.
		# Tracks the mouse 1:1 on screen: mouse straight up -> dot straight up,
		# regardless of the camera's tilt / foreshortening.
		var screen := camera.unproject_position(laser_pos) + _mouse_motion * laser_sensitivity
		var from := camera.project_ray_origin(screen)
		var dir := camera.project_ray_normal(screen)
		var hit = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
		if hit != null:
			laser_pos = _clamp_to_ground(hit)
	_mouse_motion = Vector2.ZERO

	# The laser is light, not an object: it rides at a constant height and is
	# drawn on top of everything, so terrain bumps never touch it. Only X/Z move,
	# straight from the mouse, so the motion is exactly as smooth as the input.
	red_dot.global_position = Vector3(laser_pos.x, dot_height, laser_pos.z)
	# The cat, though, needs the goal ON the terrain: the navmesh sits on the
	# hills, so a Y=0 target would snap to the nearest ground point instead of
	# the spot under the dot. Drop it onto the surface first.
	cat.target_pos = Vector3(laser_pos.x, _surface_y(laser_pos.x, laser_pos.z), laser_pos.z)

	# Frame-rate-independent easing toward whatever the camera is following. In
	# LASER mode it converges dead-centre once the mouse stops (the deadzone above
	# freezes laser_pos, so this target stops moving and the camera catches up).
	var cam_target := _camera_focus() + cam_offset
	var t := 1.0 - exp(-camera_follow_speed * delta)
	camera.global_position = camera.global_position.lerp(cam_target, t)
	if camera.global_position.distance_to(cam_target) < 0.01:
		camera.global_position = cam_target

# What the camera keeps centred. Switch with camera_follow_mode (export or at
# runtime); the laser and the cat both stay fully functional in either mode.
func _camera_focus() -> Vector3:
	match camera_follow_mode:
		FollowMode.CAT:
			return Vector3(cat.global_position.x, 0.0, cat.global_position.z)
		_:
			return laser_pos

func _surface_y(x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	params.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	return hit.position.y if hit else 0.0

func _clamp_to_ground(p: Vector3) -> Vector3:
	var half: Vector2 = (ground.mesh as PlaneMesh).size * 0.5
	var c := ground.global_position
	p.x = clampf(p.x, c.x - half.x, c.x + half.x)
	p.z = clampf(p.z, c.z - half.y, c.z + half.y)# PlaneMesh.size.y is the Z extent
	return p
