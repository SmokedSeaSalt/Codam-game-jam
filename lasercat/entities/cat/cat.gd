extends CharacterBody3D

enum State { IDLE, WALK, CHASE, POUNCE }

@export var walk_speed: float = 2.0
@export var chase_speed: float = 5.0
@export var pounce_speed: float = 8.0
@export var idle_wait_time: float = 2.0
@export var turn_speed: float = 10.0  # radians/sec, tune to taste
@export var gravity: float = 20.0
@export var step_height: float = 0.5  # match Terrain's level_height
@export var arrive_distance: float = 0.4   # X/Z gap to a STILL laser that counts as "reached"
@export var laser_still_time: float = 0.15 # laser must hold motionless this long before the cat sits

# Animations played per state. idle_wait_time is the beat spent sitting after
# arriving before the cat flops down into anim_rest.
@export var anim_move: String = "RigRoot|Loco_Trot-IP"
@export var anim_settle: String = "RigRoot|Sitting_00-IP"
@export var anim_rest: String = "RigRoot|Lying_00-IP"
@export var anim_blend: float = 0.25

var current_state: State = State.IDLE
var idle_timer: float = 0.0
var _current_anim: String = ""
var _target_still_for: float = 0.0  # seconds since the laser last moved

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
#@onready var model: Node3D = $Cat_body  # rename to match your instanced glb node
#@onready var anim_player: AnimationPlayer = $Cat_body/AnimationPlayer  # adjust path if nested differently
@onready var model: Node3D = $Skeleton3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer


var target_pos: Vector3 = Vector3.ZERO:
	set(value):
		var moved := value.distance_to(target_pos) > 0.02
		target_pos = value
		nav_agent.target_position = value
		if moved:
			# Laser is being led: keep chasing (and don't sit) until it holds still.
			_target_still_for = 0.0
			if current_state == State.IDLE:
				change_state(State.WALK)

func _ready() -> void:
	# Several imported clips aren't flagged to loop; force the locomotion one so
	# the cat keeps trotting instead of freezing after a single gait cycle.
	var move_clip := anim_player.get_animation(anim_move)
	if move_clip:
		move_clip.loop_mode = Animation.LOOP_LINEAR
	change_state(State.IDLE)

func _physics_process(delta: float) -> void:
	_target_still_for += delta  # reset to 0 by the target_pos setter whenever the laser moves

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
	# Reached the laser: hold position until it moves away again (see target_pos).
	velocity = Vector3.ZERO
	if idle_timer > 0.0:
		idle_timer -= delta  # counts down the "sitting" beat, then _update_animation lies down

func _process_walk(_delta: float) -> void:
	if _should_sit():
		_stop()
		change_state(State.IDLE)
		return
	_move_toward_nav_target(walk_speed)

func _process_chase(_delta: float) -> void:
	if _should_sit():
		_stop()
		change_state(State.IDLE)
		return
	_move_toward_nav_target(chase_speed)

func _process_pounce(_delta: float) -> void:
	_move_toward_nav_target(pounce_speed)

func _move_toward_nav_target(speed: float) -> void:
	# Always query so the agent keeps its path in sync with a moving target.
	var next_pos: Vector3 = nav_agent.get_next_path_position()
	var goal: Vector3 = next_pos
	# When the agent has no real path yet (map still syncing) or the laser sits
	# just off the navmesh, get_next_path_position() just returns our own spot.
	# Fall back to steering straight at the laser so the cat never freezes
	# mid-chase — the terrain is gentle enough for that to look fine.
	if next_pos.distance_to(global_position) < 0.05:
		goal = target_pos
	var direction: Vector3 = goal - global_position
	direction.y = 0.0
	if direction.length() < 0.05:
		_stop()
		return
	direction = direction.normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

# Horizontal (X/Z) gap to the laser. Y is ignored on purpose: the navmesh and
# the cat's body rest at slightly different heights, so a full 3D check never
# settles and the cat creeps forever.
func _flat_distance_to_target() -> float:
	var d := target_pos - global_position
	d.y = 0.0
	return d.length()

# Sit only when the cat is close to the laser AND the laser has stopped moving.
# While the player is still leading it, _target_still_for keeps resetting, so the
# cat stays in WALK and trails the dot instead of stop-starting every few steps.
# (is_navigation_finished() is deliberately never consulted — it flips true on any
# empty path query and used to latch the cat into IDLE after one step.)
func _should_sit() -> bool:
	return _flat_distance_to_target() <= arrive_distance and _target_still_for >= laser_still_time

func _stop() -> void:
	velocity.x = 0.0
	velocity.z = 0.0

func _update_facing(delta: float) -> void:
	var move_dir := Vector3(velocity.x, 0, velocity.z)
	if move_dir.length() < 0.01:
		return
	# atan2 args depend on your model's forward axis (glTF default forward is -Z).
	# If it faces backwards or sideways after this, swap signs/order here.
	var target_angle := atan2(move_dir.x, move_dir.z)
	model.rotation.y = lerp_angle(model.rotation.y, target_angle, delta * turn_speed)
	
func _update_animation() -> void:
	var want := anim_move
	var hold := false  # pose clips play once and stay on the last frame
	if current_state == State.IDLE:
		# Sit for idle_wait_time seconds after arriving, then lie down and stay.
		want = anim_settle if idle_timer > 0.0 else anim_rest
		hold = true
	_play(want, hold)

# Start playback when the intended clip changes, or when a movement clip has run
# out (belt-and-braces in case the resource still isn't looping). Finished pose
# clips are left alone so the cat doesn't twitch on their last frame.
func _play(anim_name: String, hold: bool) -> void:
	if not anim_player.has_animation(anim_name):
		return
	var changed := anim_name != _current_anim
	var ran_out := not hold and not anim_player.is_playing()
	if not changed and not ran_out:
		return
	_current_anim = anim_name
	anim_player.play(anim_name, anim_blend if changed else 0.0)

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
