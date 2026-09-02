extends Node3D
signal target_updated(pos: Vector3)
signal laser_toggled(active: bool)

@export var camera: Camera3D
@export var ground: MeshInstance3D
@export var cat: CharacterBody3D  # only used to exclude from surface raycasts
@export var laser_sensitivity: float = 1.0
@export var mouse_deadzone: float = 1.5
@export var dot_height: float = 0.05
@export var spawn_ahead: float = 0.6  # metres in front of the cat's nose when toggled on

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
	laser_pos = Vector3(pos.x, _surface_y(pos.x, pos.z), pos.z)
	dot.global_position = laser_pos + Vector3(0.0, dot_height, 0.0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		active = not active
		dot.visible = active
		laser_toggled.emit(active)
		_mouse_motion = Vector2.ZERO
		if active:
			_snap_to_cat()
	elif event is InputEventMouseMotion and active:
		_mouse_motion += event.relative

# The mouse is captured, so there is no absolute cursor to read: on toggle-on the
# dot appears on the ground a little in front of the sitting cat (so it isn't
# hidden under the body), then the player leads it away with relative motion.
func _snap_to_cat() -> void:
	var base := global_position
	if cat:
		base = cat.global_position + cat.facing_dir() * spawn_ahead
	laser_pos = Vector3(base.x, _surface_y(base.x, base.z), base.z)
	dot.global_position = laser_pos + Vector3(0.0, dot_height, 0.0)
	target_updated.emit(laser_pos)

func _process(_delta: float) -> void:
	if not active:
		return
	if _mouse_motion.length() < mouse_deadzone:
		_mouse_motion = Vector2.ZERO
	if _mouse_motion == Vector2.ZERO:
		return  # mouse at rest: stop feeding the cat so it can settle and sit

	# Screen-space motion, so this works the same whether the mouse is free or
	# MOUSE_MODE_CAPTURED (relative-only, no absolute cursor).
	var screen := camera.unproject_position(laser_pos) + _mouse_motion * laser_sensitivity
	_mouse_motion = Vector2.ZERO
	var np := _screen_to_surface(screen)
	if np.distance_to(laser_pos) < 0.002:
		return  # sub-millimetre: treat as no move, don't re-trigger the chase

	laser_pos = np
	# Dot sits exactly where the cat is told to go: same terrain point, lifted a
	# hair and drawn on top so it never hides behind a slope.
	dot.global_position = laser_pos + Vector3(0.0, dot_height, 0.0)
	target_updated.emit(laser_pos)

# Where on the ground is the player pointing? Intersect the camera ray with a
# HORIZONTAL plane at the dot's CURRENT height, then look up the real terrain
# height there. We deliberately do NOT raycast the terrain mesh: the camera looks
# in at a shallow angle, so a mesh ray skims over cliff tops and lands on the
# ground far behind them — the dot appears to teleport straight down. A flat
# plane has no silhouette to skim, and anchoring it at laser_pos.y keeps it
# tracking the surface height as the dot moves, so there's little parallax.
func _screen_to_surface(screen: Vector2) -> Vector3:
	var from := camera.project_ray_origin(screen)
	var dir := camera.project_ray_normal(screen)
	var hit = Plane(Vector3.UP, laser_pos.y).intersects_ray(from, dir)
	if hit == null:
		return laser_pos
	var p := _clamp_to_ground(hit)
	p.y = _surface_y(p.x, p.z)
	return p

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
