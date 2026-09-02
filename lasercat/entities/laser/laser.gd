extends Node3D
signal target_updated(pos: Vector3)
signal laser_toggled(active: bool)

@export var camera: Camera3D
@export var ground: MeshInstance3D
@export var cat: CharacterBody3D  # only used to exclude from surface raycasts
@export var laser_sensitivity: float = 1.0
@export var mouse_deadzone: float = 1.5
@export var dot_height: float = 0.05

@onready var dot: MeshInstance3D = $Dot

var active: bool = false
var laser_pos: Vector3 = Vector3.ZERO
var _mouse_motion: Vector2 = Vector2.ZERO

func _ready() -> void:
	_make_dot_overlay()
	dot.visible = false

# Unlit, shadowless, depth-test off so the dot always reads on top of terrain/cat.
func _make_dot_overlay() -> void:
	dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.05, 0.05)
	mat.no_depth_test = true
	mat.render_priority = 127
	dot.material_override = mat

# Called once by the main scene right after the cat's spawn point is known,
# so the laser doesn't jump from (0,0,0) the first time it's toggled on.
func start_at(pos: Vector3) -> void:
	laser_pos = Vector3(pos.x, 0.0, pos.z)
	dot.global_position = Vector3(laser_pos.x, dot_height, laser_pos.z)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		active = not active
		dot.visible = active
		laser_toggled.emit(active)
		_mouse_motion = Vector2.ZERO
		if active:
			_snap_to_mouse()
	elif event is InputEventMouseMotion and active:
		_mouse_motion += event.relative

func _snap_to_mouse() -> void:
	var m := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(m)
	var dir := camera.project_ray_normal(m)
	var hit = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
	if hit != null:
		laser_pos = _clamp_to_ground(hit)
		dot.global_position = Vector3(laser_pos.x, dot_height, laser_pos.z)
		target_updated.emit(Vector3(laser_pos.x, _surface_y(laser_pos.x, laser_pos.z), laser_pos.z))

func _process(_delta: float) -> void:
	if not active:
		return
	if _mouse_motion.length() < mouse_deadzone:
		_mouse_motion = Vector2.ZERO
	if _mouse_motion != Vector2.ZERO:
		# Screen-space motion, so this works the same whether the mouse is
		# free or MOUSE_MODE_CAPTURED (relative-only, no absolute cursor).
		var screen := camera.unproject_position(laser_pos) + _mouse_motion * laser_sensitivity
		var from := camera.project_ray_origin(screen)
		var dir := camera.project_ray_normal(screen)
		var hit = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
		if hit != null:
			laser_pos = _clamp_to_ground(hit)
	_mouse_motion = Vector2.ZERO

	dot.global_position = Vector3(laser_pos.x, dot_height, laser_pos.z)
	target_updated.emit(Vector3(laser_pos.x, _surface_y(laser_pos.x, laser_pos.z), laser_pos.z))

func _surface_y(x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	if cat:
		params.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	return hit.position.y if hit else 0.0

func _clamp_to_ground(p: Vector3) -> Vector3:
	var half: Vector2 = (ground.mesh as PlaneMesh).size * 0.5
	var c := ground.global_position
	p.x = clampf(p.x, c.x - half.x, c.x + half.x)
	p.z = clampf(p.z, c.z - half.y, c.z + half.y)
	return p
