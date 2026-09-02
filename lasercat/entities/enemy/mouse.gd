class_name Mouse
extends Enemy

## A mouse. It idles in place — glancing around at random intervals — until the
## cat enters its vision cone (or gets close enough to startle it from any
## angle), then it sprints in a straight line directly away from the cat. It
## commits to that sprint for at least flee_min_time so the cat gets a real
## chase, then runs off the edge of the play area and vanishes, emitting
## `escaped`. Getting pounced still routes through Enemy.die() / `died`.
## main_3d listens for both and spawns a fresh mouse away from the cat.

signal escaped(mouse: Mouse)

enum MouseState { IDLE, FLEE }

@export_group("Vision")
@export var fov_angle_deg: float = 130.0    # full width of the vision cone
@export var fov_range: float = 8.0          # how far down the cone the cat is spotted
@export var startle_range: float = 1.6      # cat this close is felt from any direction

@export_group("Flee")
@export var sprint_speed: float = 3.5       # keep this BELOW the cat's chase_speed so the cat visibly gains
@export var flee_min_time: float = 2.0      # commit to running at least this long (the "chase for a sec")
@export var flee_max_time: float = 7.0      # gone after this even if still on the map
@export var despawn_distance: float = 16.0  # distance from the world origin that counts as "off the map"

@export_group("Idle")
@export var idle_turn_interval: Vector2 = Vector2(3.0, 7.0)  # random seconds between glances — sparse enough to sneak up on
@export var idle_turn_range: Vector2 = Vector2(60.0, 200.0)  # degrees swept when it does glance
@export var idle_turn_speed: float = 6.0                     # radians/sec while turning toward the new heading

@export_group("Debug")
## Draws a translucent wedge for the vision cone: green = hasn't seen the cat,
## orange = cat is in view, red = fleeing. Turn off once the tuning feels right.
@export var show_fov_cone: bool = true

var _mstate: MouseState = MouseState.IDLE
var _cat: Node3D = null
var _flee_timer: float = 0.0       # counts down flee_min_time
var _flee_elapsed: float = 0.0     # counts up toward flee_max_time
var _turn_timer: float = 0.0       # counts down to the next idle glance
var _yaw: float = 0.0              # current facing yaw
var _yaw_target: float = 0.0       # yaw we're easing toward while idling
var _cone: MeshInstance3D = null
var _cone_mat: StandardMaterial3D = null

func _ready() -> void:
	super._ready()          # "enemies" group + health
	wander = false          # this script drives all movement; ignore Enemy's wander
	add_to_group("mice")
	_cat = _find_cat()
	_yaw = rotation.y
	_yaw_target = _yaw
	_reset_turn_timer()
	if show_fov_cone:
		_build_fov_cone()

func _physics_process(delta: float) -> void:
	if _cat == null or not is_instance_valid(_cat):
		_cat = _find_cat()

	match _mstate:
		MouseState.IDLE:
			_process_idle(delta)
			if _sees_cat():
				_start_flee()
		MouseState.FLEE:
			_process_flee(delta)

	# Gravity (mirrors Enemy._physics_process, which we've replaced wholesale).
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()
	_update_fov_cone()

# Stand still and, every idle_turn_interval seconds, pick a new heading and
# swing toward it. The gaps between glances are the window the cat sneaks in.
func _process_idle(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0

	_turn_timer -= delta
	if _turn_timer <= 0.0:
		var sweep := deg_to_rad(randf_range(idle_turn_range.x, idle_turn_range.y))
		if randf() < 0.5:
			sweep = -sweep
		_yaw_target = _yaw + sweep
		_reset_turn_timer()

	_yaw = lerp_angle(_yaw, _yaw_target, clampf(delta * idle_turn_speed, 0.0, 1.0))
	rotation.y = _yaw

# Sprint straight away from the cat. Despawns once it's had its minimum run AND
# cleared the arena edge, or unconditionally after flee_max_time.
func _process_flee(delta: float) -> void:
	_flee_timer -= delta
	_flee_elapsed += delta

	var dir := _away_from_cat()
	velocity.x = dir.x * sprint_speed
	velocity.z = dir.z * sprint_speed

	# Face the run direction (+Z is forward — see _sees_cat).
	_yaw = lerp_angle(_yaw, atan2(dir.x, dir.z), clampf(delta * 12.0, 0.0, 1.0))
	rotation.y = _yaw

	var off_map := _flee_timer <= 0.0 and _distance_from_origin() >= despawn_distance
	if off_map or _flee_elapsed >= flee_max_time:
		escaped.emit(self)
		queue_free()

func _reset_turn_timer() -> void:
	_turn_timer = randf_range(idle_turn_interval.x, idle_turn_interval.y)

func _find_cat() -> Node3D:
	return get_tree().get_first_node_in_group("cat") as Node3D

# Cat inside the vision cone (or inside startle_range from any angle).
func _sees_cat() -> bool:
	if _cat == null or not is_instance_valid(_cat):
		return false
	var to: Vector3 = _cat.global_position - global_position
	to.y = 0.0
	var d := to.length()
	if d <= startle_range:
		return true
	if d > fov_range:
		return false
	var fwd := global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return false
	return fwd.normalized().angle_to(to / d) <= deg_to_rad(fov_angle_deg * 0.5)

# Flat unit vector pointing from the cat to the mouse (the escape heading).
func _away_from_cat() -> Vector3:
	if _cat == null or not is_instance_valid(_cat):
		return Vector3(sin(_yaw), 0.0, cos(_yaw))  # keep going the way we were headed
	var away: Vector3 = global_position - _cat.global_position
	away.y = 0.0
	if away.length() < 0.01:
		return Vector3(sin(_yaw), 0.0, cos(_yaw))
	return away.normalized()

func _distance_from_origin() -> float:
	return Vector2(global_position.x, global_position.z).length()

func _start_flee() -> void:
	_mstate = MouseState.FLEE
	_flee_timer = flee_min_time
	_flee_elapsed = 0.0

## The cat's hunt logic polls this to swap its slow stalk for a full-speed chase.
func is_fleeing() -> bool:
	return _mstate == MouseState.FLEE

# --- Debug vision cone ------------------------------------------------------

# A flat translucent wedge, +Z forward, spanning fov_angle_deg out to fov_range.
# Parented to the mouse so it turns with it.
func _build_fov_cone() -> void:
	var half := deg_to_rad(fov_angle_deg * 0.5)
	var segments := 28
	var y := 0.05
	var verts := PackedVector3Array()
	verts.append(Vector3(0.0, y, 0.0))
	for i in range(segments + 1):
		var a := lerpf(-half, half, float(i) / float(segments))
		verts.append(Vector3(sin(a) * fov_range, y, cos(a) * fov_range))
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
	if _mstate == MouseState.FLEE:
		_cone_mat.albedo_color = Color(1.0, 0.15, 0.1, 0.33)
	elif _sees_cat():
		_cone_mat.albedo_color = Color(1.0, 0.55, 0.05, 0.28)
	else:
		_cone_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.14)
