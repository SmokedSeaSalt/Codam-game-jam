extends Node3D
signal target_updated(pos: Vector3)
signal laser_toggled(active: bool)

@export var camera: Camera3D
@export var ground: MeshInstance3D
@export var cat: CharacterBody3D  # only used to exclude from surface raycasts
@export var laser_sensitivity: float = 1.0
@export var mouse_deadzone: float = 1.5
@export var screen_margin: float = 48.0  # keep the dot at least this many pixels inside the viewport edge
@export var dot_height: float = 0.05
@export var spawn_ahead: float = 0.6  # metres in front of the cat's nose when toggled on
@export var bounds_half: float = 0.0  # >0: also clamp the dot to ±this on X/Z (keeps it inside the fence)

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

# Shift the dot by a world-space offset and re-feed the cat, snapping back to the
# real surface height. The test world uses this to make the dot travel along with
# the cat while it sprints; harmless (no-op) when the laser is off.
func nudge(offset: Vector3) -> void:
	if not active or offset == Vector3.ZERO:
		return
	var p := _clamp_to_ground(laser_pos + offset)
	p.y = _surface_y(p.x, p.z)
	p = _clamp_to_screen(p)
	laser_pos = p
	dot.global_position = laser_pos + Vector3(0.0, dot_height, 0.0)
	target_updated.emit(laser_pos)

func _process(_delta: float) -> void:
	if not active:
		return

	# The camera pans to follow the cat; if that has carried the dot past the edge
	# of the view, walk it back on-screen even while the player isn't moving the
	# mouse. Leaves laser_pos untouched (and stays quiet) whenever it's visible.
	var rescued := _clamp_to_screen(laser_pos)
	if rescued != laser_pos:
		laser_pos = rescued
		dot.global_position = laser_pos + Vector3(0.0, dot_height, 0.0)
		target_updated.emit(laser_pos)

	if _mouse_motion.length() < mouse_deadzone:
		_mouse_motion = Vector2.ZERO
	if _mouse_motion == Vector2.ZERO:
		return  # mouse at rest: stop feeding the cat so it can settle and sit

	# Screen-space motion, so this works the same whether the mouse is free or
	# MOUSE_MODE_CAPTURED (relative-only, no absolute cursor).
	var screen := _clamp_screen_point(camera.unproject_position(laser_pos) + _mouse_motion * laser_sensitivity)
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

# Clamp a screen-space point to the visible viewport rect, kept screen_margin
# pixels off every edge so the dot never rides the very border.
func _clamp_screen_point(sp: Vector2) -> Vector2:
	if camera == null:
		return sp
	var vp: Vector2 = camera.get_viewport().get_visible_rect().size
	var m: float = minf(screen_margin, minf(vp.x, vp.y) * 0.5)
	return Vector2(clampf(sp.x, m, vp.x - m), clampf(sp.y, m, vp.y - m))

# Pull a world point back onto the surface directly under an on-screen pixel if
# its projection currently falls outside the viewport (or behind the camera).
# Returns the point unchanged when it's already comfortably in view.
func _clamp_to_screen(world_pos: Vector3) -> Vector3:
	if camera == null:
		return world_pos
	var vp: Vector2 = camera.get_viewport().get_visible_rect().size
	var sp: Vector2 = camera.unproject_position(world_pos)
	if camera.is_position_behind(world_pos):
		sp = vp * 0.5  # unproject sign-flips behind the camera; aim back at centre
	var clamped := _clamp_screen_point(sp)
	if clamped.is_equal_approx(sp):
		return world_pos
	return _screen_to_surface(clamped)

func _clamp_to_ground(p: Vector3) -> Vector3:
	var half: Vector2 = (ground.mesh as PlaneMesh).size * 0.5
	var c := ground.global_position
	p.x = clampf(p.x, c.x - half.x, c.x + half.x)
	p.z = clampf(p.z, c.z - half.y, c.z + half.y)
	# Keep the dot inside the fenced play area so the cat never chases it into a wall.
	if bounds_half > 0.0:
		p.x = clampf(p.x, -bounds_half, bounds_half)
		p.z = clampf(p.z, -bounds_half, bounds_half)
	return p
