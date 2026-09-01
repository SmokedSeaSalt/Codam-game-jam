extends Node3D

@onready var camera: Camera3D = $Camera3D
@onready var red_dot: MeshInstance3D = $RedDot
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $Ground

func _ready() -> void:
	camera.look_at(Vector3.ZERO)

func _process(_delta: float) -> void:
	var m := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(m)
	var dir := camera.project_ray_normal(m)

	# Unbounded point: where the mouse ray crosses the ground plane (y = 0).
	# No collider involved, so this works anywhere, not just over terrain.
	var flat = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)

	# Physics ray is now only used to notice walls / raised terrain tops.
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 1000.0)
	q.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)

	var dot_pos: Vector3
	var target: Vector3
	if not hit.is_empty():
			if absf(hit.normal.y) < 0.5:
					# Aimed at a wall: drop the dot straight down to its base.
					dot_pos = _ground_under(hit.position + hit.normal * 0.02, hit.collider)
			else:
					dot_pos = hit.position
			target = dot_pos
	elif flat != null:
			dot_pos = flat
			target = flat
	else:
			return
	red_dot.global_position = dot_pos + Vector3(0.0, 0.03, 0.0)
	cat.target_pos = _clamp_to_ground(target)

func _clamp_to_ground(p: Vector3) -> Vector3:
	var half: Vector2 = (ground.mesh as PlaneMesh).size * 0.5
	var c := ground.global_position
	p.x = clampf(p.x, c.x - half.x, c.x + half.x)
	p.z = clampf(p.z, c.z - half.y, c.z + half.y)# PlaneMesh.size.y is the Z extent
	return p

func _mouse_ray() -> Dictionary:
	var m := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(m)
	var to := from + camera.project_ray_normal(m) * 1000.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [cat.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)

func _ground_under(xz: Vector3, skip: Object) -> Vector3:
	var from := Vector3(xz.x, xz.y + 50.0, xz.z)
	var to := Vector3(xz.x, -50.0, xz.z)
	var excludes: Array[RID] = [cat.get_rid()]
	if skip is CollisionObject3D:
		excludes.append(skip.get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = excludes
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return Vector3(xz.x, 0.0, xz.z)
	return hit.position
