extends CharacterBody3D

enum State { IDLE, WALK, CHASE, POUNCE }

@export var walk_speed: float = 2.0
@export var chase_speed: float = 5.0
@export var pounce_speed: float = 8.0
@export var idle_wait_time: float = 2.0
@export var turn_speed: float = 10.0  # radians/sec, tune to taste
@export var gravity: float = 20.0
@export var step_height: float = 0.5  # match Terrain's level_height

var current_state: State = State.IDLE
var idle_timer: float = 0.0

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
#@onready var model: Node3D = $Cat_body  # rename to match your instanced glb node
#@onready var anim_player: AnimationPlayer = $Cat_body/AnimationPlayer  # adjust path if nested differently
@onready var model: Node3D = $Skeleton3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer


var target_pos: Vector3 = Vector3.ZERO:
	set(value):
		target_pos = value
		nav_agent.target_position = value
		if current_state != State.CHASE and current_state != State.POUNCE:
			change_state(State.WALK)

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

	_apply_gravity(delta)
	move_and_slide()
	_update_animation()
	_update_facing(delta)
	
func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta



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

func _process_walk(_delta: float) -> void:
	if nav_agent.is_navigation_finished():
		change_state(State.IDLE)
		return
	_move_toward_nav_target(walk_speed)

func _process_chase(_delta: float) -> void:
	if nav_agent.is_navigation_finished():
		change_state(State.IDLE)
		return
	_move_toward_nav_target(chase_speed)

func _process_pounce(_delta: float) -> void:
	_move_toward_nav_target(pounce_speed)

func _move_toward_nav_target(speed: float) -> void:
	var next_pos: Vector3 = nav_agent.get_next_path_position()
	var direction: Vector3 = (next_pos - global_position)
	direction.y = 0.0
	direction = direction.normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

func _update_facing(delta: float) -> void:
	var move_dir := Vector3(velocity.x, 0, velocity.z)
	if move_dir.length() < 0.01:
		return
	# atan2 args depend on your model's forward axis (glTF default forward is -Z).
	# If it faces backwards or sideways after this, swap signs/order here.
	var target_angle := atan2(move_dir.x, move_dir.z)
	model.rotation.y = lerp_angle(model.rotation.y, target_angle, delta * turn_speed)
	
func _update_animation() -> void:
	var anim_name := "RigRoot|Loco_Trot-IP" if current_state == State.POUNCE else \
		("RigRoot|Loco_Trot-IP" if velocity.length() > 0.1 else "RigRoot|Loco_Trot-IP")
	if anim_player.has_animation(anim_name) and anim_player.current_animation != anim_name:
		anim_player.play(anim_name)

#const DIRECTIONS := ["up", "up_right", "right", "down_right", "down", "left_down", "left", "left_up"]
#@onready var camera: Camera3D = get_viewport().get_camera_3d()
#
#func _get_direction_name(move_dir: Vector3) -> String:
	#if move_dir.length() < 0.01:
		#return "down"
#
	## Rotate move_dir into camera-relative space so "up" means
	## "away from camera on screen", not world -Z.
	#var cam_basis := camera.global_transform.basis
	#var cam_yaw := atan2(cam_basis.z.x, cam_basis.z.z)
	#var rotated := move_dir.rotated(Vector3.UP, cam_yaw)
#
	#var angle := atan2(rotated.x, -rotated.z) - deg_to_rad(-90)
	#if angle < 0:
		#angle += TAU
	#var index := int(round(angle / (TAU / 8.0))) % 8
	#return DIRECTIONS[index]
#
#func _update_animation() -> void:
	#var move_dir := Vector3(velocity.x, 0, velocity.z)
	#var direction_name := _get_direction_name(move_dir)
	#var state_name := "attack" if current_state == State.POUNCE else "idle"
	#var anim_name := "%s_%s" % [state_name, direction_name]
	#if sprite.sprite_frames.has_animation(anim_name) and sprite.animation != anim_name:
		#sprite.play(anim_name)
