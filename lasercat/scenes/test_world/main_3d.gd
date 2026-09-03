extends Node3D
@onready var camera: Camera3D = $Camera3D
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $Ground
@onready var laser: Node3D = $Laser

enum FollowMode { LASER, CAT }

@export var camera_follow_mode: FollowMode = FollowMode.CAT
@export var camera_follow_speed: float = 9.0

# Mice. The world keeps mouse_count of them alive: whenever one is pounced (died)
# or sprints off the edge of the map (escaped), a replacement is dropped onto the
# surface a random distance from the cat, between mouse_spawn_min/max_dist away
# and never further from the origin than mouse_arena_radius.
@export var mouse_scene: PackedScene = preload("res://entities/enemy/mouse.tscn")
@export var mouse_count: int = 5
@export var mouse_spawn_min_dist: float = 15.0
@export var mouse_spawn_max_dist: float = 38.0
@export var mouse_arena_radius: float = 45.0
@export var mouse_min_separation: float = 6.0  # don't drop a new mouse this close to an existing one

var cam_offset: Vector3

func _ready() -> void:
	laser.camera = camera
	laser.ground = ground
	laser.cat = cat
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)

	camera.look_at(Vector3.ZERO)
	cam_offset = camera.global_position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Wait one physics step so the navigation map has synced, then drop the cat,
	# camera and laser onto the ground.
	await get_tree().physics_frame
	var spawn_xz := Vector3(cat.global_position.x, 0.0, cat.global_position.z)
	cat.global_position.y = _surface_y(spawn_xz.x, spawn_xz.z) + 0.1
	laser.start_at(spawn_xz)
	camera.global_position = spawn_xz + cam_offset

	# Any mice already dropped into the scene get tracked too; then top up to count.
	for m in get_tree().get_nodes_in_group("mice"):
		_track_mouse(m)
	_top_up_mice()

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
	cat.laser_active = is_on
	# Only the laser-following states get parked on IDLE when the dot goes out —
	# a stalk / chase / pounce / recover on a mouse must run to its own finish.
	if not is_on and cat.current_state in [cat.State.WALK, cat.State.CHASE]:
		cat.change_state(cat.State.IDLE)

func _track_mouse(m: Node) -> void:
	if m.has_signal("escaped") and not m.escaped.is_connected(_on_mouse_gone):
		m.escaped.connect(_on_mouse_gone)
	if m.has_signal("died") and not m.died.is_connected(_on_mouse_gone):
		m.died.connect(_on_mouse_gone)

# Fired the instant a mouse is pounced or escapes. It's mid-queue_free and we're
# inside its signal, so defer the refill to the end of the frame.
func _on_mouse_gone(_who: Node) -> void:
	_top_up_mice.call_deferred()

func _top_up_mice() -> void:
	var missing := mouse_count - get_tree().get_nodes_in_group("mice").size()
	for i in missing:
		_spawn_mouse()

func _spawn_mouse() -> void:
	if mouse_scene == null:
		return
	var pos := _pick_mouse_spawn()
	pos.y = _surface_y(pos.x, pos.z) + 0.2
	var m := mouse_scene.instantiate()
	add_child(m)
	m.global_position = pos
	_track_mouse(m)

# An XZ point at least mouse_spawn_min_dist from the cat and inside the arena.
# Clamping a random offset to the arena edge can collapse it back onto the cat
# (cat near the rim, offset pointing outward), so try several directions and, if
# none clear the gap, take the farthest-from-cat candidate we saw.
func _pick_mouse_spawn() -> Vector3:
	var cat_xz := Vector2(cat.global_position.x, cat.global_position.z)
	var best := cat_xz
	var best_gap := -1.0
	for i in 16:
		var ang := randf() * TAU
		var dist := randf_range(mouse_spawn_min_dist, mouse_spawn_max_dist)
		var p := cat_xz + Vector2(cos(ang), sin(ang)) * dist
		if p.length() > mouse_arena_radius:
			p = p.normalized() * mouse_arena_radius
		var gap := p.distance_to(cat_xz)
		if gap >= mouse_spawn_min_dist and _clear_of_mice(p):
			return Vector3(p.x, 0.0, p.y)
		if gap > best_gap:
			best_gap = gap
			best = p
	return Vector3(best.x, 0.0, best.y)

# True if `p` (XZ) is at least mouse_min_separation from every live mouse, so a
# fresh spawn doesn't land on top of the pack.
func _clear_of_mice(p: Vector2) -> bool:
	for m in get_tree().get_nodes_in_group("mice"):
		if not (m is Node3D):
			continue
		if Vector2(m.global_position.x, m.global_position.z).distance_to(p) < mouse_min_separation:
			return false
	return true

func _surface_y(x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	params.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	return hit.position.y if hit else 0.0
