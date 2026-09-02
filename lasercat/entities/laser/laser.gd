extends Node3D
signal target_updated(pos: Vector3)
signal laser_toggled(active: bool)

@export var camera: Camera3D
@export var ground: MeshInstance3D
@onready var dot: MeshInstance3D = $Dot

var active: bool = false

func _ready() -> void:
	dot.visible = false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		active = not active
		dot.visible = active
		laser_toggled.emit(active)

func _process(_delta: float) -> void:
	if not active or camera == null or ground == null:
		return
	var m := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(m)
	var dir := camera.project_ray_normal(m)
	var flat = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 1000.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var dot_pos: Vector3
	var target: Vector3
	if not hit.is_empty():
		if absf(hit.normal.y) < 0.5:
			dot_pos = _ground_under(hit.position + hit.normal * 0.02, hit.collider)
		else:
			dot_pos = hit.position
		target = dot_pos
	elif flat != null:
		dot_pos = flat
		target = flat
	else:
		return
	dot.global_position = dot_pos + Vector3(0.0, 0.03, 0.0)
	target_updated.emit(_clamp_to_ground(target))

func _clamp_to_ground(p: Vector3) -> Vector3:
	var half: Vector2 = (ground.mesh as PlaneMesh).size * 0.5
	var c := ground.global_position
	p.x = clampf(p.x, c.x - half.x, c.x + half.x)
	p.z = clampf(p.z, c.z - half.y, c.z + half.y)
	return p

func _ground_under(xz: Vector3, skip: Object) -> Vector3:
	var from := Vector3(xz.x, xz.y + 50.0, xz.z)
	var to := Vector3(xz.x, -50.0, xz.z)
	var excludes: Array[RID] = []
	if skip is CollisionObject3D:
		excludes.append(skip.get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = excludes
	q.collision_mask = 1  # only layer 1 (Ground)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return Vector3(xz.x, 0.0, xz.z)
	return hit.position
