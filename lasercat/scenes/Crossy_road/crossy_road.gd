extends Node3D
@onready var camera: Camera3D = $Camera3D
@onready var laser: Node3D = $Laser
@onready var cat: CharacterBody3D = $Cat
@onready var ground: MeshInstance3D = $NavigationRegion3D/Ground

# Camera rig: track the cat down the road (Z) but stay locked to the centre of the
# level across it (X). camera_follow_smoothing is how fast Z chases the cat —
# raise for snappier, set to 0 for a hard lock.
@export var camera_follow_smoothing: float = 5.0
@export var camera_center_x: float = 0.0  # X the camera is pinned to — the level's middle
# Where the camera sits relative to the cat: Y is its height, Z is how far it
# trails behind. Defaults match the camera's authored spot in the scene. On
# _ready the camera is snapped to cat.z + this, so it starts framed on the cat.
@export var camera_offset := Vector3(0.0, 20, 10)
# Crossy-Road ratchet: the camera only ever advances up the road with the cat,
# never scrolls back down. "Forward" is inferred from camera_offset.z (the camera
# trails behind, so forward is the opposite world-Z direction).
@export var camera_advance_only: bool = true

var _cam_z_locked: float = 0.0   # furthest-forward Z the camera has reached
var _forward_sign: float = -1.0  # world-Z direction that counts as "forward / up the road"
var _cat_spawn_pos: Vector3 = Vector3.ZERO  # cat's authored scene position; respawn point

func _ready() -> void:
	_cat_spawn_pos = cat.global_position  # cat hasn't moved yet — this is the authored start

	# Hide the OS pointer and feed the laser relative motion only, exactly like the
	# game scene — otherwise the dot drifts out of sync with the visible cursor.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	laser.camera = camera
	laser.ground = ground
	laser.cat = cat
	laser.target_updated.connect(_on_target_updated)
	laser.laser_toggled.connect(_on_laser_toggled)

	# Seeds laser_pos + dot position from the cat's current spot, so the first
	# toggle-on doesn't snap the dot in from (0,0,0).
	laser.start_at(Vector3(cat.global_position.x, 0.0, cat.global_position.z))

	# Every vehicle registers in the "vehicles" group from its own _ready, which has
	# already run by the time this (the root's) _ready fires — listen for a hit.
	for v in get_tree().get_nodes_in_group("vehicles"):
		if not v.hit_cat.is_connected(_on_vehicle_hit_cat):
			v.hit_cat.connect(_on_vehicle_hit_cat)

	# Snap the camera onto the cat straight away so it opens framed on it.
	_forward_sign = -1.0 if camera_offset.z >= 0.0 else 1.0
	_snap_camera_to_cat()

func _snap_camera_to_cat() -> void:
	var z := cat.global_position.z + camera_offset.z
	camera.global_position = Vector3(camera_center_x, camera_offset.y, z)
	_cam_z_locked = z

func _on_vehicle_hit_cat() -> void:
	cat.respawn(_cat_spawn_pos)
	# The camera only ever advances (camera_advance_only) — without this it would
	# be left stranded up the road, framing empty space where the cat used to be.
	_snap_camera_to_cat()

func _process(delta: float) -> void:
	var pos := camera.global_position
	pos.x = camera_center_x
	pos.y = camera_offset.y
	var target_z := cat.global_position.z + camera_offset.z
	if camera_advance_only:
		# Ratchet: keep the target only if it's further up the road than where we are.
		if (target_z - _cam_z_locked) * _forward_sign > 0.0:
			_cam_z_locked = target_z
		target_z = _cam_z_locked
	if camera_follow_smoothing > 0.0:
		pos.z = lerpf(pos.z, target_z, clampf(delta * camera_follow_smoothing, 0.0, 1.0))
	else:
		pos.z = target_z
	camera.global_position = pos

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_tree().quit()

func _on_target_updated(pos: Vector3) -> void:
	cat.target_pos = pos

func _on_laser_toggled(is_on: bool) -> void:
	cat.laser_active = is_on
	# Only the laser-following states get parked on IDLE when the dot goes out —
	# a stalk / chase / pounce / recover on a mouse must run to its own finish.
	if not is_on and cat.current_state in [cat.State.WALK, cat.State.CHASE]:
		cat.change_state(cat.State.IDLE)
