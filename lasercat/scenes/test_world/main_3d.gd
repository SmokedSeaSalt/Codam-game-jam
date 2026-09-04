extends Node3D

# Web-only pause layer: gives the cursor back when the browser drops pointer lock.
const PauseMenu := preload("res://scenes/test_world/pause_menu.gd")

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
@export var mouse_count: int = 10
@export var mouse_spawn_min_dist: float = 18.0
@export var mouse_spawn_max_dist: float = 68.0
@export var mouse_arena_radius: float = 80.0
@export var mouse_min_separation: float = 16.0  # don't drop a new mouse this close to an existing one — the map is huge, keep them scattered
@export var fence_spawn_margin: float = 6.0     # keep fresh mice at least this far inside the fence line

var _fence: Node = null  # the FenceRing, if the scene has one

# Pixel-style hunger bar (res://entities/ui/hunger_bar.tscn), bottom-middle of
# the screen. Fills one pip per mouse caught; its cap (max_value) is set on
# the HungerBar/Bar node itself so it's adjustable per-level without touching
# this script.
@onready var hunger_bar := get_node_or_null("HungerBar/Bar")

# Where the hunger bar filling sends the player next.
@export_file("*.tscn") var next_level_scene: String = "res://scenes/haris_level/main_3d.tscn"
# How long the final catch gets on screen (pounce landed, prey caught) before
# the scene freezes and the next level loads in behind it.
@export var catch_settle_time: float = 1.5

var _level_complete: bool = false  # guards against a second fill/transfer firing

var cam_offset: Vector3
var _cat_prev_xz: Vector3  # cat's flat position last frame, for the sprint-drag below

func _ready() -> void:
	laser.camera = camera
	laser.ground = ground
	laser.cat = cat
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)
	if hunger_bar:
		hunger_bar.filled.connect(_on_hunger_bar_filled)

	camera.look_at(Vector3.ZERO)
	cam_offset = camera.global_position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Wait one physics step so the navigation map has synced, then drop the cat,
	# camera and laser onto the ground.
	await get_tree().physics_frame
	var spawn_xz := Vector3(cat.global_position.x, 0.0, cat.global_position.z)
	cat.global_position.y = _surface_y(spawn_xz.x, spawn_xz.z) + 0.1
	laser.start_at(spawn_xz)
	laser.turn_on()
	camera.global_position = spawn_xz + cam_offset
	_cat_prev_xz = Vector3(cat.global_position.x, 0.0, cat.global_position.z)

	# Any mice already dropped into the scene get tracked too; then top up to count.
	for m in get_tree().get_nodes_in_group("mice"):
		_track_mouse(m)
	_top_up_mice()

	# Added last so its first frame runs after the spawn setup above. On web it
	# takes over Esc (pause + free the cursor); on desktop it disables itself.
	add_child(PauseMenu.new())

	var ambient_audio := AmbientAudio.new()
	ambient_audio.bird_enabled = false  # no pigeons in test_world — don't play their ambience
	add_child(ambient_audio)

func _unhandled_input(event: InputEvent) -> void:
	# Desktop: Esc quits outright. On web, Esc is the pause key (handled by
	# PauseMenu) and the browser eats the keystroke for pointer-lock exit anyway.
	if event.is_action_pressed("ui_cancel") and not OS.has_feature("web"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().quit()

func _process(delta: float) -> void:
	# Test-world only: while the cat is sprinting, the laser dot rides along with
	# it — carried by the cat's own movement each frame so it keeps its lead
	# instead of the cat reeling it in.
	var cat_xz := Vector3(cat.global_position.x, 0.0, cat.global_position.z)
	if laser.active and cat.has_method("is_sprinting") and cat.is_sprinting():
		laser.nudge(cat_xz - _cat_prev_xz)
	_cat_prev_xz = cat_xz

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
	if m.has_signal("escaped") and not m.escaped.is_connected(_on_mouse_escaped):
		m.escaped.connect(_on_mouse_escaped)
	if m.has_signal("died") and not m.died.is_connected(_on_mouse_caught):
		m.died.connect(_on_mouse_caught)

# Fired when a mouse sprints off the map uncaught. It's mid-queue_free and we're
# inside its signal, so defer the refill to the end of the frame.
func _on_mouse_escaped(_who: Node) -> void:
	_top_up_mice.call_deferred()

# Fired the instant a mouse is pounced. Refill it and fill one pip of the hunger bar.
func _on_mouse_caught(_who: Node) -> void:
	_top_up_mice.call_deferred()
	if hunger_bar:
		hunger_bar.feed()

# Bar's full — the cat's had its fill here. Hand off to the next level.
func _on_hunger_bar_filled() -> void:
	if _level_complete:
		return
	_level_complete = true
	_transition_to_next_level()

# Let the catch that filled the bar hold on screen for a beat, then freeze the
# whole tree (pause — see pause_menu.gd for the same trick) and load the next
# level in the background so the swap lands with no hitch.
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

func _top_up_mice() -> void:
	var missing := mouse_count - get_tree().get_nodes_in_group("mice").size()
	for i in missing:
		_spawn_mouse()

func _spawn_mouse() -> void:
	if mouse_scene == null:
		return
	var pos := _clamp_inside_fence(_pick_mouse_spawn())
	pos.y = _surface_y(pos.x, pos.z) + 0.2
	var m := mouse_scene.instantiate()
	# Position BEFORE add_child: Enemy._ready() fires during add_child and captures
	# _home = global_position, so the mouse has to already be at its spawn point or
	# every mouse ends up homed on the world origin and ambles back into one stack.
	m.position = pos
	add_child(m)
	_track_mouse(m)

# An XZ point at least mouse_spawn_min_dist from the cat and inside the arena.
# Clamping a random offset to the arena edge can collapse it back onto the cat
# (cat near the rim, offset pointing outward), so try several directions and, if
# none clear the gap, take the farthest-from-cat candidate we saw.
func _pick_mouse_spawn() -> Vector3:
	var cat_xz := Vector2(cat.global_position.x, cat.global_position.z)
	var best := cat_xz
	var best_score := -INF
	for i in 48:
		var ang := randf() * TAU
		var dist := randf_range(mouse_spawn_min_dist, mouse_spawn_max_dist)
		var p := cat_xz + Vector2(cos(ang), sin(ang)) * dist
		if p.length() > mouse_arena_radius:
			p = p.normalized() * mouse_arena_radius
		var gap := p.distance_to(cat_xz)
		if gap >= mouse_spawn_min_dist and _clear_of_mice(p):
			return Vector3(p.x, 0.0, p.y)
		# No clean spot yet — keep the candidate that's most in the clear: distance
		# to the nearest mouse, then distance from the cat as the tie-breaker.
		var score := _nearest_mouse_dist(p) + gap * 0.01
		if score > best_score:
			best_score = score
			best = p
	return Vector3(best.x, 0.0, best.y)

# Distance from `p` (XZ) to the closest live mouse, or a big number if there are none.
func _nearest_mouse_dist(p: Vector2) -> float:
	var nearest := 1.0e9
	for m in get_tree().get_nodes_in_group("mice"):
		if not (m is Node3D):
			continue
		nearest = minf(nearest, Vector2(m.global_position.x, m.global_position.z).distance_to(p))
	return nearest

# True if `p` (XZ) is at least mouse_min_separation from every live mouse, so a
# fresh spawn doesn't land on top of the pack.
func _clear_of_mice(p: Vector2) -> bool:
	for m in get_tree().get_nodes_in_group("mice"):
		if not (m is Node3D):
			continue
		if Vector2(m.global_position.x, m.global_position.z).distance_to(p) < mouse_min_separation:
			return false
	return true

# Pull an XZ spawn point back inside the fence (square) so no mouse is ever
# dropped on or past the fence line. No-op when the scene has no fence.
func _clamp_inside_fence(p: Vector3) -> Vector3:
	if _fence == null or not is_instance_valid(_fence):
		_fence = get_tree().get_first_node_in_group("fence")
	if _fence == null or not ("half_extent" in _fence):
		return p
	var lim: float = maxf(_fence.half_extent - fence_spawn_margin, 1.0)
	p.x = clampf(p.x, -lim, lim)
	p.z = clampf(p.z, -lim, lim)
	return p

func _surface_y(x: float, z: float) -> float:
	var params := PhysicsRayQueryParameters3D.create(Vector3(x, 100.0, z), Vector3(x, -100.0, z))
	params.exclude = [cat.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	return hit.position.y if hit else 0.0
