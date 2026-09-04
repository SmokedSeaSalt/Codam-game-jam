extends Node3D
@onready var camera: Camera3D = $Camera3D
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $NavigationRegion3D/Ground
@onready var laser: Node3D = $Laser

enum FollowMode { LASER, CAT }

@export var camera_follow_mode: FollowMode = FollowMode.CAT
@export var camera_follow_speed: float = 9.0

# This map splits into a concrete street strip (the fence/entrance side, to
# the north) and a park (the tree- and flower-heavy side, to the south) — see
# GridMap_TREES for the decoration that gives the south its "park" read. Mice
# stick to the concrete, pigeons to the park. Boxes are center/half-extent,
# XZ only (y is ignored by both spawn picking and Bird.set_landing_bounds).
@export var concrete_center: Vector3 = Vector3(-12.0, 0.0, -47.0)
@export var concrete_half_size: Vector3 = Vector3(37.0, 0.0, 15.0)
@export var park_center: Vector3 = Vector3(-12.0, 0.0, -78.0)
@export var park_half_size: Vector3 = Vector3(37.0, 0.0, 15.0)

# Birds. Same top-up pattern as haris_level: whenever one is pounced (died), a
# replacement drops in elsewhere in the park (see park_center/park_half_size).
@export var bird_scene: PackedScene = preload("res://entities/enemy/pigeon.tscn")
@export var bird_count: int = 6
@export var bird_spawn_safe_distance: float = 6.0

# Mice. Same top-up pattern, mirroring haris_level/test_world: whenever one is
# pounced (died) or sprints off the edge (escaped), a replacement drops in
# elsewhere on the concrete (see concrete_center/concrete_half_size).
@export var mouse_scene: PackedScene = preload("res://entities/enemy/mouse.tscn")
@export var mouse_count: int = 4
@export var mouse_spawn_safe_distance: float = 6.0

# Pixel-style hunger bar (res://entities/ui/hunger_bar.tscn). Fills one pip per
# bird or mouse caught; its cap (max_value) lives on the HungerBar/Bar node itself.
@onready var hunger_bar := get_node_or_null("HungerBar/Bar")

# Where the hunger bar filling sends the player next.
@export_file("*.tscn") var next_level_scene: String = "res://scenes/Crossy_road/crossy_road.tscn"
# How long the final catch gets on screen (pounce landed, prey caught) before
# the scene freezes and the next level loads in behind it.
@export var catch_settle_time: float = 1.5

var _level_complete: bool = false  # guards against a second fill/transfer firing

var cam_offset: Vector3

func _ready() -> void:

	laser.camera = camera
	laser.ground = ground
	laser.cat = cat
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)
	if hunger_bar:
		hunger_bar.filled.connect(_on_hunger_bar_filled)

	_configure_birds()

	camera.look_at(Vector3.ZERO)
	cam_offset = camera.global_position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Wait one physics step so the navigation map has synced, then drop the
	# cat, camera and laser onto the surface.
	await get_tree().physics_frame
	var spawn_xz := Vector3(cat.global_position.x, 0.0, cat.global_position.z)
	cat.global_position.y = _surface_y(spawn_xz.x, spawn_xz.z) + 0.1
	laser.start_at(spawn_xz)
	laser.turn_on()
	camera.global_position = spawn_xz + cam_offset

	# Any birds/mice already dropped into the scene get tracked too; then top
	# up both to their counts.
	for b in get_tree().get_nodes_in_group("birds"):
		_track_bird(b)
	_top_up_birds()
	for m in get_tree().get_nodes_in_group("mice"):
		_track_mouse(m)
	_top_up_mice()

# Bird.arena_center/arena_half_size default to a 10x10 box at world origin,
# which is nowhere near this level's ground plane — left unset, a bird that
# spots the cat picks a landing spot off in that empty default box and flies
# there forever, never coming back within sight. Point every bird already in
# the scene (and every one we spawn below) at the park box instead, so pigeons
# only ever land in the park.
func _configure_birds() -> void:
	for b in get_tree().get_nodes_in_group("birds"):
		b.set_landing_bounds(park_center, park_half_size)

func _track_bird(b: Node) -> void:
	if b.has_signal("died") and not b.died.is_connected(_on_bird_gone):
		b.died.connect(_on_bird_gone)

# Fired the instant a bird is pounced. It's mid-queue_free and we're inside its
# signal, so defer the refill to the end of the frame.
func _on_bird_gone(_who: Node) -> void:
	_top_up_birds.call_deferred()
	if hunger_bar:
		hunger_bar.feed()

func _top_up_birds() -> void:
	var missing := bird_count - get_tree().get_nodes_in_group("birds").size()
	for i in missing:
		_spawn_bird()

func _spawn_bird() -> void:
	if bird_scene == null:
		return
	var pos := _pick_bird_spawn()
	pos.y = _surface_y(pos.x, pos.z) + 0.2
	var b := bird_scene.instantiate()
	b.position = pos  # set before add_child so Bird._ready() sees the real spawn spot
	add_child(b)
	b.set_landing_bounds(park_center, park_half_size)
	_track_bird(b)

# A point inside the park box, at least bird_spawn_safe_distance from the cat.
func _pick_bird_spawn() -> Vector3:
	for attempt in range(30):
		var local_point := Vector3(
			randf_range(-park_half_size.x, park_half_size.x),
			0.0,
			randf_range(-park_half_size.z, park_half_size.z)
		)
		var pos := park_center + local_point
		if is_instance_valid(cat):
			var cat_pos := cat.global_position
			cat_pos.y = pos.y
			if pos.distance_to(cat_pos) < bird_spawn_safe_distance:
				continue
		return pos
	return park_center

func _track_mouse(m: Node) -> void:
	if m.has_signal("died") and not m.died.is_connected(_on_mouse_gone):
		m.died.connect(_on_mouse_gone)
	if m.has_signal("escaped") and not m.escaped.is_connected(_on_mouse_escaped):
		m.escaped.connect(_on_mouse_escaped)

# Fired the instant a mouse is pounced. It's mid-queue_free and we're inside
# its signal, so defer the refill to the end of the frame.
func _on_mouse_gone(_who: Node) -> void:
	_top_up_mice.call_deferred()
	if hunger_bar:
		hunger_bar.feed()

# Fired when a mouse sprints off the edge uncaught — same refill, no feed.
func _on_mouse_escaped(_who: Node) -> void:
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
	# Position BEFORE add_child: Enemy._ready() fires during add_child and
	# captures _home = global_position, so the mouse has to already be at its
	# spawn point or it ends up homed on the origin and ambles back there.
	m.position = pos
	add_child(m)
	_track_mouse(m)

# A point inside the concrete box, at least mouse_spawn_safe_distance from the cat.
func _pick_mouse_spawn() -> Vector3:
	for attempt in range(30):
		var local_point := Vector3(
			randf_range(-concrete_half_size.x, concrete_half_size.x),
			0.0,
			randf_range(-concrete_half_size.z, concrete_half_size.z)
		)
		var pos := concrete_center + local_point
		if is_instance_valid(cat):
			var cat_pos := cat.global_position
			cat_pos.y = pos.y
			if pos.distance_to(cat_pos) < mouse_spawn_safe_distance:
				continue
		return pos
	return concrete_center

# Bar's full — the cat's had its fill here. Hand off to the next level.
func _on_hunger_bar_filled() -> void:
	if _level_complete:
		return
	_level_complete = true
	_transition_to_next_level()

# Let the catch that filled the bar hold on screen for a beat, then freeze the
# whole tree (pause) and load the next level in the background so the swap
# lands with no hitch.
func _transition_to_next_level() -> void:
	await get_tree().create_timer(catch_settle_time).timeout
	get_tree().paused = true

	var err := ResourceLoader.load_threaded_request(next_level_scene)
	if err != OK:
		push_warning("Failed to start loading %s (error %d)" % [next_level_scene, err])
		get_tree().paused = false
		get_tree().change_scene_to_file(next_level_scene)
		return

	# process_frame keeps firing while paused, so this loop still advances.
	var status := ResourceLoader.load_threaded_get_status(next_level_scene)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(next_level_scene)

	get_tree().paused = false
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		push_warning("Failed to load %s (status %d)" % [next_level_scene, status])
		get_tree().change_scene_to_file(next_level_scene)
		return

	var packed := ResourceLoader.load_threaded_get(next_level_scene) as PackedScene
	get_tree().change_scene_to_packed(packed)

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
	if not is_on:
		cat.change_state(cat.State.IDLE)

func _surface_y(x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	params.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	return hit.position.y if hit else 0.0
