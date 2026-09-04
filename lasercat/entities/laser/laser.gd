extends Node3D
signal target_updated(pos: Vector3)
signal laser_toggled(active: bool)

@export var camera: Camera3D
@export var ground: MeshInstance3D
@export var cat: CharacterBody3D  # only used to exclude from surface raycasts
@export var laser_sensitivity: float = 1.0
@export var mouse_deadzone: float = 1.5
@export var screen_margin: float = 48.0  # keep the dot at least this many pixels inside the viewport edge
@export var dot_height: float = 0.02  # lift off the surface, measured along its normal
# Sizes are in ON-SCREEN pixels, not metres, and converted to world units fresh
# every frame from the camera's current zoom (see _world_size_for_px). A dot with
# a fixed metre size shrinks to nothing once the camera pulls back over the open
# grass field — pinning it to a pixel size is what keeps it readable at any zoom.
@export var dot_target_px: float = 34.0   # light pool
@export var core_target_px: float = 14.0  # crisp centre point
@export var spark_amount: int = 5     # 0 disables the sparks entirely; rate is amount / lifetime
@export var spawn_ahead: float = 0.6  # metres in front of the cat's nose when toggled on
@export var bounds_half: float = 0.0  # >0: also clamp the dot to ±this on X/Z (keeps it inside the fence)

const DOT_SHADER := preload("res://entities/laser/laser_dot.gdshader")

@onready var dot: MeshInstance3D = $Dot

var active: bool = false
var laser_pos: Vector3 = Vector3.ZERO
var _mouse_motion: Vector2 = Vector2.ZERO
var _fence_rids: Array[RID] = []   # fence barrier bodies; the ground raycast skips them
var _fence_scanned: bool = false
var _core: MeshInstance3D = null   # billboarded speck sitting in the middle of the pool
var _sparks: CPUParticles3D = null

func _ready() -> void:
	_make_dot()
	_make_sparks()
	_show_dot(false)

# The dot is two quads sharing laser_dot.gdshader (its header explains why): a
# wide soft POOL laid flat against the surface normal, so the light looks like
# it's landing on the ground / rock / cat it's pointed at rather than hovering
# over it, plus a small billboarded CORE that stays square to the camera — the
# game camera is orthogonal at a shallow angle and would otherwise foreshorten
# the flat pool into an easy-to-lose sliver.
func _make_dot() -> void:
	dot.mesh = QuadMesh.new()
	dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Full intensity: under premultiplied alpha a value below 1.0 darkens the red
	# rather than fading it, which muddies the bloom instead of softening it.
	# alpha_boost 1.8: the pool's alpha is a wide soft gradient, so without a push
	# most of its area sits at low, grass-tinted opacity and reads as a pale pink
	# smear rather than solid red.
	dot.material_override = _dot_material(false, 0.05, 0.5, 3.5, 1.0, 1.0, 1.8)

	# squash < 1 keeps the speck from reading as a ball sitting up in the pool —
	# it flattens into a wide ellipse, the shape a round dot actually makes on the
	# ground under this camera. The steep falloff keeps it a hard little point with
	# almost no halo of its own, the way a real pointer reads; its alpha_boost is
	# milder since the core is already mostly opaque by construction.
	_core = MeshInstance3D.new()
	_core.name = "Core"
	_core.mesh = QuadMesh.new()
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core.material_override = _dot_material(true, 0.28, 0.5, 3.0, 1.0, 0.5, 1.3)
	add_child(_core)

func _dot_material(billboard: bool, core_r: float, glow_r: float, falloff: float,
		intensity: float, squash: float, alpha_boost: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = DOT_SHADER
	mat.render_priority = 127
	mat.set_shader_parameter("billboard", billboard)
	mat.set_shader_parameter("core_radius", core_r)
	mat.set_shader_parameter("glow_radius", glow_r)
	mat.set_shader_parameter("glow_falloff", falloff)
	mat.set_shader_parameter("intensity", intensity)
	mat.set_shader_parameter("squash", squash)
	mat.set_shader_parameter("alpha_boost", alpha_boost)
	return mat

# A thin sputter of sparks off the dot. local_coords is OFF on purpose: every
# spark is left behind in world space where it was born, so a fast flick of the
# mouse draws a short glowing trail the eye can follow back to the dot — which is
# the whole point, a bare dot is easy to lose against the grass.
func _make_sparks() -> void:
	if spark_amount <= 0:
		return
	_sparks = CPUParticles3D.new()  # CPU, not GPU: the project renders on GL Compatibility / web
	_sparks.name = "Sparks"
	_sparks.local_coords = false
	_sparks.amount = spark_amount
	_sparks.lifetime = 0.9  # with amount 5 that's ~5 sparks/sec — an occasional sputter, not a fountain
	_sparks.randomness = 1.0
	_sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_sparks.emission_sphere_radius = 0.02
	_sparks.spread = 50.0
	_sparks.initial_velocity_min = 0.35
	_sparks.initial_velocity_max = 1.2
	_sparks.gravity = Vector3(0.0, -2.5, 0.0)
	_sparks.damping_min = 1.0
	_sparks.damping_max = 3.0
	_sparks.scale_amount_min = 0.015
	_sparks.scale_amount_max = 0.04
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sparks.mesh = QuadMesh.new()
	_sparks.material_override = _spark_material()

	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	_sparks.scale_amount_curve = shrink

	# Red, not the usual orange/white spark heat — they have to read as flecks of
	# the laser. Endpoints first: add_point() shifts every index after it.
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.28, 0.20, 1.0))
	ramp.set_color(1, Color(1.0, 0.0, 0.0, 0.0))
	ramp.add_point(0.3, Color(1.0, 0.06, 0.0, 0.95))
	_sparks.color_ramp = ramp

	add_child(_sparks)

# Soft round billboard so each spark reads as a point of light instead of a
# square; additive and depth-test-free to match the dot.
func _spark_material() -> StandardMaterial3D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	grad.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 32
	tex.height = 32

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true  # let the particle colour ramp tint it
	mat.albedo_texture = tex
	mat.no_depth_test = true
	mat.render_priority = 126
	return mat

# Pool, core and sparks go on and off together.
func _show_dot(on: bool) -> void:
	dot.visible = on
	if _core:
		_core.visible = on
	if _sparks:
		_sparks.emitting = on

# World-space size that currently renders as target_px on screen, so the dot
# holds a constant APPARENT size instead of a constant metre size. A metre-sized
# dot is what disappears the moment the camera pulls back over open grass (a
# bigger ortho `size`, or just a smaller browser window under the "expand"
# stretch mode both shrink world-units-per-pixel) — this makes it grow to
# compensate, i.e. bigger whenever the view is more zoomed out.
func _world_size_for_px(target_px: float) -> float:
	if camera == null:
		return 0.2
	var vp_h: float = camera.get_viewport().get_visible_rect().size.y
	if vp_h <= 0.0:
		return 0.2
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return target_px * camera.size / vp_h
	# Perspective fallback: world units per pixel grow with distance from camera.
	var dist := camera.global_position.distance_to(laser_pos)
	var world_per_px := 2.0 * dist * tan(deg_to_rad(camera.fov) * 0.5) / vp_h
	return target_px * world_per_px

# Put the whole rig on the surface at laser_pos: the pool laid flat against the
# ground normal there, the core squared up on top of it, and the spark emitter
# spitting away from the surface. Sizes are recomputed from the current camera
# zoom every call (see _world_size_for_px) — cheap, and it's what keeps the dot
# from shrinking away when the view zooms/resizes out. Every place that moves
# the dot, and _process every active frame, goes through here.
func _place_dot() -> void:
	var n := _surface_normal(laser_pos.x, laser_pos.z)
	var axis := Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD  # anything not parallel to n
	var bx := axis.cross(n).normalized()
	var by := n.cross(bx).normalized()
	var at := laser_pos + n * dot_height
	var pool_sz := _world_size_for_px(dot_target_px)
	var core_sz := _world_size_for_px(core_target_px)
	# A QuadMesh faces its own local +Z, so mapping +Z onto the surface normal is
	# what lies the pool flat against whatever the dot is resting on.
	dot.global_transform = Transform3D(Basis(bx * pool_sz, by * pool_sz, n * pool_sz), at)
	if _core:
		_core.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * core_sz), at + n * 0.01)
	if _sparks:
		_sparks.global_position = at
		_sparks.direction = n

# Called once by the main scene right after the cat's spawn point is known,
# so the laser doesn't jump from (0,0,0) the first time it's toggled on.
func start_at(pos: Vector3) -> void:
	laser_pos = Vector3(pos.x, _surface_y(pos.x, pos.z), pos.z)
	_place_dot()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		active = not active
		_show_dot(active)
		laser_toggled.emit(active)
		_mouse_motion = Vector2.ZERO
		if active:
			_snap_to_cat()
	elif event is InputEventMouseMotion and active:
		_mouse_motion += event.relative

# Switches the laser on programmatically — call after start_at() so every level
# opens with the dot already live in front of the cat, instead of making the
# player click once just to begin. No-op if it's already on.
func turn_on() -> void:
	if active:
		return
	active = true
	_show_dot(true)
	laser_toggled.emit(true)
	_mouse_motion = Vector2.ZERO
	_snap_to_cat()

# The mouse is captured, so there is no absolute cursor to read: on toggle-on the
# dot appears on the ground a little in front of the sitting cat (so it isn't
# hidden under the body), then the player leads it away with relative motion.
func _snap_to_cat() -> void:
	var base := global_position
	if cat:
		base = cat.global_position + cat.facing_dir() * spawn_ahead
	laser_pos = Vector3(base.x, _surface_y(base.x, base.z), base.z)
	_place_dot()
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
	_place_dot()
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
		target_updated.emit(laser_pos)

	# camera is assigned by the level's _ready() right after instancing the
	# laser, but turn_on() now fires the moment the level starts (no more
	# waiting for the player's first click) — if any mouse motion lands before
	# that assignment (or during a scene transition, between the old level's
	# laser being freed and the new one's _ready() wiring the new camera in),
	# camera is still null here. Drop that motion rather than crash on it.
	if camera != null and _mouse_motion.length() >= mouse_deadzone:
		# Screen-space motion, so this works the same whether the mouse is free or
		# MOUSE_MODE_CAPTURED (relative-only, no absolute cursor).
		var screen := _clamp_screen_point(camera.unproject_position(laser_pos) + _mouse_motion * laser_sensitivity)
		var np := _screen_to_surface(screen)
		if np.distance_to(laser_pos) >= 0.002:  # sub-millimetre: treat as no move, don't re-trigger the chase
			laser_pos = np
			# Dot sits exactly where the cat is told to go: same terrain point,
			# lifted a hair and drawn on top so it never hides behind a slope.
			target_updated.emit(laser_pos)
	_mouse_motion = Vector2.ZERO

	# Re-placed every active frame, not just when laser_pos actually moves, so a
	# live camera zoom or a browser window resize keeps the dot pinned to its
	# on-screen size instead of only catching up the next time it's nudged.
	_place_dot()

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

# Straight-down ray onto whatever the dot is resting on at an XZ column. Shared
# by the height lookup and by _place_dot's surface alignment.
func _surface_hit(x: float, z: float) -> Dictionary:
	var params := PhysicsRayQueryParameters3D.create(Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	# Skip the cat and the fence's invisible containment wall. The barrier sits on
	# the same collision layer as the ground and is 2 m tall, so without this the
	# downward "how high is the ground here?" ray hits the top of the wall as the
	# pointer crosses the fence line and the dot teleports up to y≈2.
	var ex := _fence_exclude_rids().duplicate()
	if cat:
		ex.append(cat.get_rid())
	params.exclude = ex
	return get_world_3d().direct_space_state.intersect_ray(params)

func _surface_y(x: float, z: float) -> float:
	var hit := _surface_hit(x, z)
	return hit.position.y if hit else 0.0

# Normal of the surface under the dot, so the pool can be painted flat onto it.
# Falls back to straight up on a miss (or a degenerate normal) — the stepped
# terrain reports UP almost everywhere anyway; this is what makes the dot lie
# along a slope or the tilted top of a prop instead of always facing the sky.
func _surface_normal(x: float, z: float) -> Vector3:
	var hit := _surface_hit(x, z)
	if hit.is_empty():
		return Vector3.UP
	var n: Vector3 = hit.normal
	return n.normalized() if n.length_squared() > 0.001 else Vector3.UP

# RIDs of every CollisionObject3D under the FenceRing (the "Barrier" walls), found
# once and cached. Retried each call until the fence exists, so node ready-order
# doesn't matter; empty (no exclusions) if the scene has no fence.
func _fence_exclude_rids() -> Array[RID]:
	if _fence_scanned:
		return _fence_rids
	var fence := get_tree().get_first_node_in_group("fence")
	if fence == null:
		return _fence_rids
	_fence_scanned = true
	var stack: Array[Node] = [fence]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionObject3D:
			_fence_rids.append((n as CollisionObject3D).get_rid())
		stack.append_array(n.get_children())
	return _fence_rids

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
