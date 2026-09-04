class_name Bird
extends Enemy

## A bird. Idles on the ground until the cat enters its vision cone (a plain
## distance + angle check against the cat, polled every physics frame — same
## approach Mouse uses; an Area3D "vision area" collision box used to do this
## via body_entered, but it was misaligned/unreliable and, worse, kept firing
## while the cat had already committed to a pounce, letting the bird take off
## out from under a leap that was already in the air), then flies a short arc
## to a random landing spot elsewhere in the arena. While flying it can't be
## pounced (see is_catchable()). Landing on the cat itself never happens by
## design — choose_landing_spot() rejects spots too close to it.
## A pounce that connects while it's grounded routes through Enemy.die() same
## as everything else, so main_3d's existing died-listener respawn logic just
## works without a bird-specific signal.

enum State { IDLE, FLY }

@export var flight_duration: float = 10
@export var fly_height: float = 5.0
@export var safe_distance: float = 1.0
@export var landing_margin: float = 0.5

@export_group("Vision")
@export var fov_angle_deg: float = 100.0
@export var fov_range: float = 9.0
@export var startle_range: float = 0.6  # a near-approach wakes it even from outside the cone

@export_group("Landing Safety")
## Landing spots that overlap anything on this mask are rejected — layer 1
## (buildings/terrain) + layer 3 (invisible blockers like the lake boxes),
## matching what the cat itself collides with. Anywhere the cat can't walk, a
## pigeon shouldn't land either.
@export_flags_3d_physics var obstacle_mask: int = 5
@export var landing_check_radius: float = 0.5   # roughly a cat-sized footprint
@export var landing_check_height: float = 0.4   # probe height above ground_y
## The flat ground/floor body — shares obstacle_mask's layer with real
## obstacles, but as an infinite plane it "overlaps" every point on its solid
## side, so it has to be excluded explicitly or every spot reads as blocked.
@export_node_path("StaticBody3D") var ground_body_path: NodePath = ^"../Ground/StaticBody3D"

@export_group("Debug")
@export var show_fov_cone: bool = true

@onready var cat: Node3D = $"../Cat"
@onready var sprite: AnimatedSprite3D = $AnimatedSprite3D

var arena_center: Vector3
var arena_half_size: Vector3 = Vector3(10, 0, 10)

var state: State = State.IDLE
var start_position: Vector3
var target_position: Vector3
var flight_progress: float = 0.0
var ground_y: float
var _braced: bool = false  # the cat has committed a pounce — can't take off mid-catch

var _cone: MeshInstance3D = null
var _cone_mat: StandardMaterial3D = null
var _landing_probe: SphereShape3D = null
var _ground_body_rid: RID

func _ready() -> void:
	super._ready()        # "enemies" group + health, via Enemy
	wander = false         # Bird drives its own movement, not Enemy's wander
	add_to_group("birds")  # so main_3d's top-up count can see it
	ground_y = global_position.y
	sprite.play("idle")
	_landing_probe = SphereShape3D.new()
	_landing_probe.radius = landing_check_radius
	var ground_body := get_node_or_null(ground_body_path) as CollisionObject3D
	if ground_body:
		_ground_body_rid = ground_body.get_rid()
	if show_fov_cone:
		_build_fov_cone()

func _physics_process(delta: float) -> void:
	# Pinned by an incoming pounce: freeze (gravity only) until it lands or the
	# cat gives up. Mirrors Mouse — the bird doesn't get to spot the cat and
	# take off while a leap is already committed to it.
	if _braced:
		velocity.x = 0.0
		velocity.z = 0.0
		if is_on_floor() and velocity.y <= 0.0:
			velocity.y = 0.0
		else:
			velocity.y -= gravity * delta
		move_and_slide()
		_update_fov_cone()
		return

	if state == State.IDLE and _sees_cat():
		start_flying()

	if state == State.FLY:
		fly(delta)
	

	# Gravity mirrors Enemy._physics_process, which we've replaced wholesale
	# (same reason Mouse does it: FLY needs its own velocity control, not wander).
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()
	_update_fov_cone()

# Cat inside the vision cone (or inside startle_range from any angle).
func _sees_cat() -> bool:
	if not is_instance_valid(cat):
		return false
	var to: Vector3 = cat.global_position - global_position
	to.y = 0.0
	var d := to.length()
	if d <= startle_range:
		return true
	if d > fov_range:
		return false
	var fwd := global_transform.basis.x
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return false
	return fwd.normalized().angle_to(to / d) <= deg_to_rad(fov_angle_deg * 0.5)

func start_flying() -> void:
	if not choose_landing_spot():
		return
	state = State.FLY
	sprite.play("fly")
	start_position = global_position
	flight_progress = 0.0

func fly(delta: float) -> void:
	flight_progress += delta / flight_duration
	flight_progress = min(flight_progress, 1.0)
	var t := flight_progress
	var desired_position := start_position.lerp(target_position, t)
	desired_position.y += 4.0 * fly_height * t * (1.0 - t)
	velocity = (desired_position - global_position) / delta

	if flight_progress >= 1.0:
		global_position = target_position
		velocity = Vector3.ZERO
		state = State.IDLE
		sprite.play("idle")

func set_landing_bounds(center: Vector3, half_size: Vector3) -> void:
	arena_center = center
	arena_half_size = half_size

func choose_landing_spot() -> bool:
	for attempt in range(30):
		var local_point := Vector3(
			randf_range(-arena_half_size.x + landing_margin, arena_half_size.x - landing_margin),
			0.0,
			randf_range(-arena_half_size.z + landing_margin, arena_half_size.z - landing_margin)
		)
		var spot := arena_center + local_point
		# Measure THIS spot's real surface height rather than reusing the
		# spawn-time ground_y — terrain isn't flat everywhere (raised blocks,
		# the lake), so a stale height can land the bird floating above (or
		# inside) something that isn't actually there at the original spot.
		spot.y = _local_surface_y(spot.x, spot.z, ground_y)
		if is_instance_valid(cat):
			var cat_pos := cat.global_position
			cat_pos.y = ground_y
			if spot.distance_to(cat_pos) < safe_distance:
				continue
		if _is_spot_blocked(spot):
			continue
		target_position = spot
		return true
	return false

# True if a cat-sized footprint at `spot` would overlap anything on
# obstacle_mask (buildings, fences, lake collision boxes, ...) — the same
# layer the cat itself collides with, so pigeons never land somewhere the cat
# couldn't actually walk.
func _is_spot_blocked(spot: Vector3) -> bool:
	if _landing_probe == null:
		return false
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _landing_probe
	params.transform = Transform3D(Basis(), spot + Vector3(0.0, landing_check_height, 0.0))
	params.collision_mask = obstacle_mask
	params.collide_with_bodies = true
	params.collide_with_areas = false
	if _ground_body_rid.is_valid():
		params.exclude = [_ground_body_rid]
	return space.intersect_shape(params, 1).size() > 0

# Real surface height at (x, z): a straight-down raycast from well above
# `fallback` to well below it. Falls back to `fallback` itself if nothing's
# there (shouldn't happen over solid ground, but keeps this safe).
func _local_surface_y(x: float, z: float, fallback: float) -> float:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(x, fallback + 50.0, z), Vector3(x, fallback - 50.0, z))
	params.exclude = [get_rid()]
	var hit := space.intersect_ray(params)
	return hit.position.y if hit else fallback

## The cat's hunt logic checks this before AND during a stalk/pounce.
func is_catchable() -> bool:
	return state == State.IDLE

## Birds don't have a distinct sprint state — always the normal detect range
## and stalk speed rather than the mouse's full-speed chase.
func is_fleeing() -> bool:
	return false

## Called by the cat the instant it launches its pounce. From here the bird is
## caught: it stops dead and can't take off, so seeing the cat mid-air no
## longer lets it slip away. Cleared by release_pounce() if the cat bails.
func brace_for_pounce() -> void:
	_braced = true
	velocity = Vector3.ZERO

func release_pounce() -> void:
	_braced = false

# --- Debug vision cone ------------------------------------------------------

func _build_fov_cone() -> void:
	var half := deg_to_rad(fov_angle_deg * 0.5)
	var segments := 28
	var y := 0.05
	var verts := PackedVector3Array()
	verts.append(Vector3(0.0, y, 0.0))
	for i in range(segments + 1):
		var a := lerpf(-half, half, float(i) / float(segments))
		verts.append(Vector3(cos(a) * fov_range, y, sin(a) * fov_range))
	var idx := PackedInt32Array()
	for i in range(segments):
		idx.append(0)
		idx.append(i + 1)
		idx.append(i + 2)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_cone_mat = StandardMaterial3D.new()
	_cone_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cone_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cone_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_cone = MeshInstance3D.new()
	_cone.name = "FovConeDebug"
	_cone.mesh = mesh
	_cone.material_override = _cone_mat
	_cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cone)

func _update_fov_cone() -> void:
	if _cone_mat == null:
		return
	if state == State.FLY:
		_cone_mat.albedo_color = Color(1.0, 0.15, 0.1, 0.33)
	else:
		_cone_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.14)
