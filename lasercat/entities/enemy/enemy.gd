class_name Enemy
extends CharacterBody3D

## Generic enemy the cat can pounce on. Use as-is (drop it on a scene with a
## mesh + collision shape) or subclass it for mice, bugs, rival laser dots, ...
## Every enemy adds itself to the "enemies" group; that group is what the cat
## scans when it decides to break off the laser and pounce.

signal pounced(by: Node)     # the cat's pounce connected with us
signal died(enemy: Enemy)

@export var max_health: int = 1
@export var gravity: float = 20.0

## Optional aimless scurrying so the target isn't a sitting duck.
@export var wander: bool = false
@export var wander_speed: float = 1.5
@export var wander_radius: float = 3.0
@export var wander_pause: Vector2 = Vector2(0.6, 2.0)  # min/max seconds between hops

var health: int
var _home: Vector3
var _wander_target: Vector3
var _wander_timer: float = 0.0

func _ready() -> void:
	add_to_group("enemies")
	health = max_health
	_home = global_position
	_wander_target = global_position

func _physics_process(delta: float) -> void:
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	if wander:
		_process_wander(delta)
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	move_and_slide()

# Pick a new random point near home every wander_pause seconds and amble to it.
func _process_wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		var a := randf() * TAU
		var r := randf() * wander_radius
		_wander_target = _home + Vector3(cos(a) * r, 0.0, sin(a) * r)
		_wander_timer = randf_range(wander_pause.x, wander_pause.y)

	var to := _wander_target - global_position
	to.y = 0.0
	if to.length() < 0.15:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	to = to.normalized()
	velocity.x = to.x * wander_speed
	velocity.z = to.z * wander_speed
	look_at(global_position + to, Vector3.UP)

## Called by the cat when its pounce lands. Override for a custom reaction
## (spawn a puff, drop loot, flee instead of die, ...).
func on_pounced(by: Node) -> void:
	pounced.emit(by)
	take_damage(1)

func take_damage(amount: int) -> void:
	health -= amount
	if health <= 0:
		die()

func die() -> void:
	died.emit(self)
	queue_free()
