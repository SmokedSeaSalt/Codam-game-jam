extends CharacterBody3D

enum State { IDLE, WALK, CHASE, POUNCE }

@export var walk_speed: float = 2.0
@export var chase_speed: float = 5.0
@export var pounce_speed: float = 8.0
@export var idle_wait_time: float = 2.0

var current_state: State = State.IDLE
var idle_timer: float = 0.0

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var sprite: Sprite3D = $Sprite3D

func _ready() -> void:
	change_state(State.IDLE)

func _physics_process(delta: float) -> void:
	match current_state:
		State.IDLE:
			_process_idle(delta)
		State.WALK:
			_process_walk(delta)
		State.CHASE:
			_process_chase(delta)
		State.POUNCE:
			_process_pounce(delta)

	move_and_slide()
	_update_sprite_facing()

func change_state(new_state: State) -> void:
	current_state = new_state
	# Reset per-state values on entry
	match new_state:
		State.IDLE:
			idle_timer = idle_wait_time
		State.WALK:
			pass
		State.CHASE:
			pass
		State.POUNCE:
			pass

func _process_idle(delta: float) -> void:
	velocity = Vector3.ZERO
	idle_timer -= delta
	if idle_timer <= 0.0:
		change_state(State.WALK)
		_pick_random_walk_target()

func _process_walk(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		change_state(State.IDLE)
		return
	_move_toward_nav_target(walk_speed)

func _process_chase(delta: float) -> void:
	if nav_agent.is_navigation_finished():
		change_state(State.IDLE)
		return
	_move_toward_nav_target(chase_speed)

func _process_pounce(delta: float) -> void:
	_move_toward_nav_target(pounce_speed)

func _move_toward_nav_target(speed: float) -> void:
	var next_pos: Vector3 = nav_agent.get_next_path_position()
	var direction: Vector3 = (next_pos - global_position)
	direction.y = 0.0
	direction = direction.normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

func _pick_random_walk_target() -> void:
	# Replace with real logic - random point within radius, etc.
	var random_offset := Vector3(randf_range(-5, 5), 0, randf_range(-5, 5))
	nav_agent.target_position = global_position + random_offset

func _update_sprite_facing() -> void:
	if velocity.x != 0.0:
		sprite.flip_h = velocity.x < 0.0
