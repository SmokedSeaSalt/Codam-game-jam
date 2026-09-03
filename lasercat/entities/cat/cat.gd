extends CharacterBody3D

enum State { IDLE, WALK, CHASE, STALK, PURSUE, POUNCE, RECOVER }

@export var walk_speed: float = 2.0
@export var chase_speed: float = 5.0
@export var pounce_speed: float = 8.0
@export var idle_wait_time: float = 2.0
@export var turn_speed: float = 10.0  # radians/sec, tune to taste
@export var gravity: float = 20.0
@export var step_height: float = 0.5  # match Terrain's level_height

# Body-to-ground alignment. The terrain is a STEPPED mesh (flat tops, vertical
# walls), so the physics floor normal is always straight up and never reports a
# slope. Instead we raycast down at four points around the cat and fit a plane
# through the hits — that turns a staircase of steps into a smooth ramp the body
# can lean into. The same centre raycast pins the model's height so the paws
# plant on the surface instead of floating at a fixed offset.
@export var align_to_ground: bool = true
@export var body_align_speed: float = 8.0    # how fast the lean/height chase the target
@export var body_align_max_tilt_deg: float = 40.0  # cap so a cliff edge can't stand the cat on end
@export var paw_reach: float = 0.35          # fore/aft & lateral distance of the ground samples
@export var paw_ground_offset: float = 0.0   # nudged up/down if the paws sink into / hover over the mesh
@export var ground_ray_up: float = 1.5       # ray starts this far above the cat
@export var ground_ray_down: float = 3.0     # …and reaches this far below it
@export_flags_3d_physics var ground_mask: int = 1
@export var arrive_distance: float = 0.4   # X/Z gap to a STILL laser that counts as "reached"
@export var laser_still_time: float = 0.15 # laser must hold motionless this long before the cat sits

# Hunt: enemies trump the laser. When a mouse comes within pounce_detect_range the
# cat drops the dot and STALKs it — a navmesh creep at stalk_speed with the sneak
# animation, curving toward the prey's blind side. It closes to pounce_launch_range
# and HOLDS there, facing the prey, until stalk_time has elapsed, then JUMPS: a
# ballistic arc from that standoff onto the prey. The launch braces the mouse
# (brace_for_pounce) so it can't bolt in the last split second — the leap always
# connects — then a low RECOVER pose before returning to the laser.
# If the mouse spots the cat DURING the stalk it bolts, and the cat drops into
# PURSUE — a flat-out navmesh chase. The mouse is FASTER, so a pursuit is a losing
# one: it ends when the mouse despawns off the map (or opens pursue_giveup_range).
@export var pounce_detect_range: float = 5.0    # get this near a mouse and the laser loses the cat — it commits to the hunt
@export var flee_chase_range: float = 14.0       # a mouse already sprinting is noticed (and chased) from this far — keep it > the mouse's fov_range so it can't just outrun the cat's attention
@export var stalk_speed: float = 1.5             # navmesh creep toward the standoff point; anim is time-scaled to match
@export var stalk_time: float = 1.5             # seconds of stalking before the jump is allowed to fire
@export var stalk_approach_offset: float = 1.0  # creep toward a point this far behind the prey, so the cat comes at its blind side
@export var pounce_launch_range: float = 4.5    # close to this gap, then hold and stalk in place — the jump launches from here
@export var pounce_windup_time: float = 0.0     # extra coil/pause after the stalk before the jump — the stalk IS the wind-up now
@export var pounce_giveup_range: float = 14.0   # prey (that hasn't bolted) got this far away: abandon the hunt — keep it > pounce_detect_range
@export var pursue_speed: float = 7.0           # PURSUE run speed — a lot quicker than the laser chase, but kept under the mouse's sprint_speed so it never catches up
@export var pursue_giveup_range: float = 20.0   # a bolting mouse got this far: give up the losing chase (it'll usually despawn first)
@export var pounce_hit_range: float = 0.6       # X/Z gap that counts as landing on the prey
@export var pounce_arc_height: float = 0.9      # how high (m) the leap peaks — at the MIDPOINT, then it comes back down onto the prey
@export var pounce_overshoot: float = 0.25      # aim the leap this far past the prey so the cat lands squarely on it, not at its feet
@export var pounce_max_reach: float = 5.5       # cap on the leap's horizontal distance — keep it above pounce_launch_range
@export var pounce_speed_cap_mult: float = 3.0  # ceiling on the launch's horizontal speed, as a multiple of pounce_speed
@export var pounce_recover_time: float = 1.0    # seconds crouched over the kill before resuming

# Animations played per state. idle_wait_time is the beat spent sitting after
# arriving before the cat flops down into anim_rest.
@export var anim_move: String = "RigRoot|Loco_Trot-IP"
@export var anim_settle: String = "RigRoot|Sitting_00-IP"
@export var anim_rest: String = "RigRoot|Lying_00-IP"
@export var anim_sneak: String = "RigRoot|Loco_Sneak-IP"   # played while stalking / coiling
@export var anim_pounce: String = "RigRoot|Jump_Run-IP"    # played on the jump
@export var anim_pounce_recover: String = "RigRoot|Lying_00-IP"  # low pose held after landing
@export var anim_pounce_speed_scale: float = 1.5           # play the jump clip this much faster
@export var anim_blend: float = 0.25

# Body speed (m/s) each locomotion clip was authored to look right at. Playback
# is time-scaled by actual_speed / this so the paws plant on the ground instead
# of skating. LOWER a value to play that clip FASTER for the same travel speed
# (fix feet sliding forward); raise it if the legs windmill faster than the cat.
@export var anim_move_stride_speed: float = 2.5
@export var anim_sneak_stride_speed: float = 1.4

var current_state: State = State.IDLE
var idle_timer: float = 0.0
var _current_anim: String = ""
var _target_still_for: float = 0.0  # seconds since the laser last moved
var _last_pos: Vector3 = Vector3.ZERO
var _stuck_for: float = 0.0         # seconds we've been trying to move but haven't
var _pounce_target: Node3D = null
var _stalk_timer: float = 0.0       # counts down stalk_time; the jump fires when it hits 0
var _nav_goal_point: Vector3 = Vector3(INF, INF, INF)  # last point handed to the nav agent, to throttle re-paths
var _windup_timer: float = 0.0      # counts down the crouch before the leap
var _recover_timer: float = 0.0     # counts down the low pose held after landing a pounce
var _leaped: bool = false           # true once the hop has been applied this pounce
var _leap_speed: float = 0.0        # horizontal speed chosen for the current leap's arc
var _model_rest_y: float = 0.0      # model's planted local Y over ground; held through a pounce arc
var _snap_model_next: bool = true   # skip the height lerp for one frame (spawn, and on pounce landing)
var _facing_angle: float = 0.0      # smoothed yaw target; the full body basis is composed from this + the ground plane
var laser_active: bool = false      # mirrored from the laser so we know where to go after a hunt

@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
#@onready var model: Node3D = $Cat_body  # rename to match your instanced glb node
#@onready var anim_player: AnimationPlayer = $Cat_body/AnimationPlayer  # adjust path if nested differently
@onready var model: Node3D = $Skeleton3D
@onready var anim_player: AnimationPlayer = $AnimationPlayer


var target_pos: Vector3 = Vector3.ZERO:
	set(value):
		# Only X/Z counts as "the laser moved" — a few cm of Y wobble from the
		# surface raycast near a cliff edge must not keep waking the cat.
		var moved := Vector2(value.x - target_pos.x, value.z - target_pos.z).length() > 0.03
		target_pos = value
		# Don't hijack the nav agent while hunting — the hunt states point it at the
		# prey, and _end_hunt re-points it at the dot when they finish. (Without this
		# guard, leading the laser mid-chase yanks the cat's heading toward the dot.)
		if current_state not in [State.STALK, State.PURSUE, State.POUNCE, State.RECOVER]:
			nav_agent.target_position = value
		if moved:
			# Laser is being led: keep chasing (and don't sit) until it holds still.
			_target_still_for = 0.0
			if current_state == State.IDLE:
				change_state(State.WALK)

func _ready() -> void:
	add_to_group("cat")  # mice look this up to run their vision checks against
	# Several imported clips aren't flagged to loop; force the locomotion one so
	# the cat keeps trotting instead of freezing after a single gait cycle.
	for clip_name in [anim_move, anim_sneak]:
		var clip := anim_player.get_animation(clip_name)
		if clip:
			clip.loop_mode = Animation.LOOP_LINEAR
	_facing_angle = model.rotation.y
	change_state(State.IDLE)

func _physics_process(delta: float) -> void:
	_target_still_for += delta  # reset to 0 by the target_pos setter whenever the laser moves

	# Enemies win over the laser: if one is close enough, break off and start stalking.
	if current_state not in [State.STALK, State.PURSUE, State.POUNCE, State.RECOVER]:
		var prey := _closest_enemy_in_range()
		if prey:
			_begin_stalk(prey)

	match current_state:
		State.IDLE:
			_process_idle(delta)
		State.WALK:
			_process_walk(delta)
		State.CHASE:
			_process_chase(delta)
		State.STALK:
			_process_stalk(delta)
		State.PURSUE:
			_process_pursue(delta)
		State.POUNCE:
			_process_pounce(delta)
		State.RECOVER:
			_process_recover(delta)

	_apply_gravity(delta)
	move_and_slide()
	_update_stuck(delta)
	_update_animation()
	_update_facing(delta)
	_update_body_orientation(delta)

# If the cat is commanding movement but physically isn't going anywhere (wedged
# in a concave bit of the stepped mesh), force a fresh path and, if it has
# drifted off the navmesh entirely, lift it back onto the nearest mesh point.
func _update_stuck(delta: float) -> void:
	# Pounces are short and deliberately straight-line, so the navmesh-unwedge
	# logic below stays out of them.
	var trying := current_state in [State.WALK, State.CHASE, State.STALK, State.PURSUE]
	var moved_flat := Vector2(global_position.x - _last_pos.x, global_position.z - _last_pos.z).length()
	_last_pos = global_position
	if trying and Vector2(velocity.x, velocity.z).length() > 0.1 and moved_flat < 0.005:
		_stuck_for += delta
	else:
		_stuck_for = 0.0
	if _stuck_for < 0.4:
		return
	_stuck_for = 0.0
	# Recompute the route — toward the prey if we're hunting, else the dot.
	nav_agent.target_position = (_pounce_target.global_position
		if current_state in [State.STALK, State.PURSUE] and _target_alive() else target_pos)
	_nav_goal_point = Vector3(INF, INF, INF)  # let _move_toward_point re-issue next frame
	var map := nav_agent.get_navigation_map()
	if map.is_valid():
		var on_mesh := NavigationServer3D.map_get_closest_point(map, global_position)
		if Vector2(on_mesh.x - global_position.x, on_mesh.z - global_position.z).length() > 0.3:
			global_position = on_mesh + Vector3(0.0, 0.1, 0.0)
	
func _apply_gravity(delta: float) -> void:
	# `velocity.y <= 0` so a fresh pounce hop isn't cancelled the same frame it's set.
	if is_on_floor() and velocity.y <= 0.0:
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
		State.STALK:
			_stalk_timer = stalk_time  # restart the pre-jump creep clock
			_nav_goal_point = Vector3(INF, INF, INF)  # force a fresh path
		State.PURSUE:
			_nav_goal_point = Vector3(INF, INF, INF)
		State.POUNCE:
			_windup_timer = pounce_windup_time
			_leaped = false
			_stop()
			# Commit: pin the prey so it can't bolt in the split second before we land.
			if _target_alive() and _pounce_target.has_method("brace_for_pounce"):
				_pounce_target.brace_for_pounce()
		State.RECOVER:
			_recover_timer = pounce_recover_time
			_stop()

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

# Creep (on the navmesh) toward the prey's blind side, hold at pounce_launch_range
# once there, and JUMP when stalk_time has elapsed. The instant the mouse spots
# the cat and bolts, abandon the stalk and drop into PURSUE — no jump. Bails if a
# still-unaware mouse somehow gets far away.
func _process_stalk(delta: float) -> void:
	if not _target_alive():
		_end_hunt()
		return
	if _prey_fleeing():
		change_state(State.PURSUE)
		return
	var flat := _flat_distance_to(_pounce_target.global_position)
	if flat > pounce_giveup_range:
		_end_hunt()
		return
	_stalk_timer -= delta
	if _stalk_timer <= 0.0 and flat <= pounce_max_reach:
		change_state(State.POUNCE)
		return
	if flat <= pounce_launch_range:
		# At the standoff: hold position, keep facing the prey, let the sneak play.
		_stop()
		_face_point(_pounce_target.global_position, delta)
	else:
		# Aim a bit behind the prey so the approach curves onto its blind side.
		var goal: Vector3 = _pounce_target.global_position
		var prey_fwd: Vector3 = _pounce_target.global_transform.basis.z
		prey_fwd.y = 0.0
		if prey_fwd.length() > 0.01:
			goal -= prey_fwd.normalized() * stalk_approach_offset
		_move_toward_point(goal, stalk_speed)

# Prey has bolted. Run it down along the navmesh (so terrain steps don't wedge
# the cat) — but the mouse is faster, so this is a chase the cat loses. It ends
# when the mouse despawns off the map, or opens up pursue_giveup_range.
func _process_pursue(_delta: float) -> void:
	if not _target_alive():
		_end_hunt()
		return
	if _flat_distance_to(_pounce_target.global_position) > pursue_giveup_range:
		_end_hunt()
		return
	_move_toward_point(_pounce_target.global_position, pursue_speed)

# Like _move_toward_nav_target but for an arbitrary point (a stalk standoff, or
# the fleeing mouse) instead of the laser: path to it across the navmesh so
# terrain steps don't wedge the cat. The nav target is only re-issued when the
# goal shifts a fair bit, so a moving prey doesn't thrash the pathfinder every
# frame; a straight line covers the gap until the first path is ready.
func _move_toward_point(p: Vector3, speed: float) -> void:
	if _nav_goal_point.distance_to(p) > 0.4:
		nav_agent.target_position = p
		_nav_goal_point = p
	var dir: Vector3 = nav_agent.get_next_path_position() - global_position
	dir.y = 0.0
	if dir.length() < 0.2:
		dir = p - global_position
		dir.y = 0.0
	if dir.length() < 0.05:
		_stop()
		return
	dir = dir.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

# Coil (hold still, face the prey), then launch a ballistic arc onto it.
func _process_pounce(delta: float) -> void:
	if not _target_alive():
		_end_hunt()
		return

	if _windup_timer > 0.0:
		_windup_timer -= delta
		_stop()
		_face_point(_pounce_target.global_position, delta)
		return

	var to: Vector3 = _pounce_target.global_position - global_position
	to.y = 0.0
	var flat := to.length()

	if not _leaped:
		# Launch a real parabola: rise to pounce_arc_height at the MIDPOINT and come
		# back down to launch height as the horizontal gap closes, so the cat
		# descends ONTO the prey instead of stalling at its apex above it. Aim a
		# little past the prey (pounce_overshoot) so it lands squarely on the mouse.
		# Pick the vertical speed for that peak height, derive the air time from it,
		# then set the horizontal speed to cover that reach in the same time.
		# Gravity in _apply_gravity handles the fall — we never touch velocity.y again.
		_leaped = true
		var h := maxf(pounce_arc_height, 0.02)
		var air_time := 2.0 * sqrt(2.0 * h / gravity)
		var dir := to.normalized() if flat > 0.01 else Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))
		var reach := minf(flat + pounce_overshoot, pounce_max_reach)
		_leap_speed = minf(reach / air_time, pounce_speed * pounce_speed_cap_mult)
		velocity.x = dir.x * _leap_speed
		velocity.z = dir.z * _leap_speed
		velocity.y = sqrt(2.0 * gravity * h)
		return

	# Airborne (velocity.y > 0 also covers the first frame, before the body has
	# physically left the floor): keep driving the horizontal velocity straight at
	# the prey for the WHOLE arc so the cat comes down on the mouse — cutting
	# forward speed early is what left it hanging at the apex on top of the prey.
	# Y is left to gravity.
	if not is_on_floor() or velocity.y > 0.0:
		var d := to.normalized() if flat > 0.01 else Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))
		velocity.x = d.x * _leap_speed
		velocity.z = d.z * _leap_speed
		return

	# Feet are back on the ground. Landed on the prey -> that's the pounce.
	if flat <= pounce_hit_range:
		if _pounce_target.has_method("on_pounced"):
			_pounce_target.on_pounced(self)
		_snap_model_next = true  # plant the model this frame, no easing into the lying pose
		change_state(State.RECOVER)  # hold a low pose over the kill before resuming
		return
	# Landed short. If the prey bolted mid-air, the jump's over — chase it (and
	# lose). Otherwise it just shuffled a little; close the last gap on foot.
	if _prey_fleeing():
		change_state(State.PURSUE)
		return
	var dir2 := to.normalized() if flat > 0.01 else Vector3.ZERO
	velocity.x = dir2.x * pounce_speed
	velocity.z = dir2.z * pounce_speed

# Crouched over the kill for pounce_recover_time, then back to the laser (or idle).
func _process_recover(delta: float) -> void:
	_stop()
	_recover_timer -= delta
	if _recover_timer <= 0.0:
		_end_hunt()

func _target_alive() -> bool:
	return _pounce_target != null and is_instance_valid(_pounce_target)

# True while the current prey is actively sprinting away (a Mouse that has spotted
# the cat). Drives the stalk -> full-speed-chase switch and skips the pounce coil.
func _prey_fleeing() -> bool:
	return _target_alive() and _pounce_target.has_method("is_fleeing") and _pounce_target.is_fleeing()

# Nearest node in the "enemies" group we're willing to break off the laser for
# (X/Z distance only), or null. A settled enemy has to be within
# pounce_detect_range; one that's already fleeing counts out to flee_chase_range
# so a mouse can't spot the cat and sprint clear before the cat even reacts.
func _closest_enemy_in_range() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node3D) or not is_instance_valid(e):
			continue
		var node := e as Node3D
		var reach := pounce_detect_range
		if node.has_method("is_fleeing") and node.is_fleeing():
			reach = flee_chase_range
		var d := _flat_distance_to(node.global_position)
		if d <= reach and d < best_d:
			best_d = d
			best = node
	return best

func _begin_stalk(target: Node3D) -> void:
	_pounce_target = target
	change_state(State.STALK)

func _end_hunt() -> void:
	# If we bail with the prey still alive (rare — a braced mouse almost always
	# gets caught), let it move again.
	if _target_alive() and _pounce_target.has_method("release_pounce"):
		_pounce_target.release_pounce()
	_pounce_target = null
	_windup_timer = 0.0
	_recover_timer = 0.0
	_leaped = false
	_stop()
	_nav_goal_point = Vector3(INF, INF, INF)
	nav_agent.target_position = target_pos  # point the agent back at the dot
	# Back to business: chase the dot if the laser's on, otherwise settle.
	change_state(State.WALK if laser_active else State.IDLE)

# Horizontal (X/Z) gap between the cat and an arbitrary world point.
func _flat_distance_to(p: Vector3) -> float:
	var d := p - global_position
	d.y = 0.0
	return d.length()

func _move_toward_nav_target(speed: float) -> void:
	var flat := _flat_distance_to_target()
	# Close enough: hold still rather than overshoot and buzz around the dot.
	# (Going fully IDLE is still gated on the laser being still — see _should_sit.)
	if flat <= arrive_distance:
		_stop()
		return

	var direction: Vector3 = _nav_goal() - global_position
	direction.y = 0.0
	if direction.length() < 0.05:
		_stop()
		return
	direction = direction.normalized()
	# Ease down over the last half-metre so arrival doesn't stop-start jitter.
	var v := speed * clampf(flat / 0.5, 0.35, 1.0)
	velocity.x = direction.x * v
	velocity.z = direction.z * v

# A point that is ALWAYS on the navmesh, so the body is never steered straight
# into a cliff (which is how it wedges). Normally the next path corner; if there
# is no path — cat drifted off the mesh, or the laser is on unreachable ground —
# the closest reachable point instead. Falls back to "stay put" if even that is
# where we already are.
func _nav_goal() -> Vector3:
	var next_pos: Vector3 = nav_agent.get_next_path_position()
	if next_pos.distance_to(global_position) > 0.05:
		return next_pos
	var map := nav_agent.get_navigation_map()
	if map.is_valid():
		var reachable := NavigationServer3D.map_get_closest_point(map, target_pos)
		if reachable.distance_to(global_position) > 0.05:
			return reachable
	return global_position

# Horizontal (X/Z) gap to the laser. Y is ignored on purpose: the navmesh and
# the cat's body rest at slightly different heights, so a full 3D check never
# settles and the cat creeps forever.
func _flat_distance_to_target() -> float:
	return _flat_distance_to(target_pos)

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
	if move_dir.length() < 0.2:  # ignore micro-velocities so the model doesn't spin in place
		return
	_face_dir(move_dir, delta)

# Turn the model to look at a world point (used during the pounce wind-up, when
# the cat is standing still and _update_facing has no velocity to work from).
func _face_point(p: Vector3, delta: float) -> void:
	var to := p - global_position
	to.y = 0.0
	if to.length() < 0.05:
		return
	_face_dir(to, delta)

func _face_dir(dir: Vector3, delta: float) -> void:
	# atan2 args depend on your model's forward axis (glTF default forward is -Z).
	# If it faces backwards or sideways after this, swap signs/order here.
	# Only the yaw target is tracked here; _update_body_orientation folds it
	# together with the ground slope into the model's final transform.
	var target_angle := atan2(dir.x, dir.z)
	_facing_angle = lerp_angle(_facing_angle, target_angle, delta * turn_speed)

# Tilt the model to sit flush with the ground and pin its height so the paws
# plant on the surface. Yaw comes from _facing_angle; pitch/roll from a plane
# fitted through four downward raycasts around the body.
func _update_body_orientation(delta: float) -> void:
	var t := clampf(delta * body_align_speed, 0.0, 1.0)
	var up := _sampled_ground_normal() if align_to_ground else Vector3.UP

	# Compose the target basis: forward is _facing_angle flattened, then leaned
	# onto the ground plane; up is the sampled normal; right closes the frame.
	var flat_fwd := Vector3(sin(_facing_angle), 0.0, cos(_facing_angle))
	var fwd := flat_fwd - up * flat_fwd.dot(up)
	if fwd.length() < 0.001:
		fwd = flat_fwd
	fwd = fwd.normalized()
	var right := up.cross(fwd).normalized()
	var target_basis := Basis(right, up, fwd).orthonormalized()
	model.transform.basis = model.transform.basis.slerp(target_basis, t).orthonormalized()

	# Plant the paws: raycast straight down at the body centre and chase that
	# height. While airborne (a pounce) the collision body itself does the arcing,
	# so the model just holds its planted offset (_model_rest_y) and rides along —
	# easing to 0 here would float the model high and leave it sinking into place
	# after landing. On the frame the pounce connects we snap with no lerp so the
	# cat is flat on the ground the instant the lying pose starts.
	if align_to_ground:
		if is_on_floor():
			var hit := _ground_ray(global_position)
			if not hit.is_empty():
				var local_y: float = hit.position.y - global_position.y + paw_ground_offset
				_model_rest_y = local_y
				var yt := 1.0 if (current_state == State.RECOVER or _snap_model_next) else t
				model.position.y = lerpf(model.position.y, local_y, yt)
		else:
			model.position.y = lerpf(model.position.y, _model_rest_y, t)
	_snap_model_next = false

# Fit a plane through four ground samples (fore, aft, left, right of the cat)
# and return its up-facing normal, clamped to body_align_max_tilt_deg so a cliff
# edge or a missed ray can't throw the body vertical.
func _sampled_ground_normal() -> Vector3:
	var fwd := Vector3(sin(_facing_angle), 0.0, cos(_facing_angle)) * paw_reach
	var side := Vector3(cos(_facing_angle), 0.0, -sin(_facing_angle)) * paw_reach
	var hf := _ground_ray(global_position + fwd)
	var hb := _ground_ray(global_position - fwd)
	var hr := _ground_ray(global_position + side)
	var hl := _ground_ray(global_position - side)
	if hf.is_empty() or hb.is_empty() or hr.is_empty() or hl.is_empty():
		return Vector3.UP
	var fb: Vector3 = hf.position - hb.position
	var lr: Vector3 = hr.position - hl.position
	var n := fb.cross(lr).normalized()
	if n.y < 0.0:
		n = -n
	if n.is_equal_approx(Vector3.ZERO):
		return Vector3.UP
	var ang := Vector3.UP.angle_to(n)
	var max_tilt := deg_to_rad(body_align_max_tilt_deg)
	if ang > max_tilt:
		n = Vector3.UP.slerp(n, max_tilt / ang).normalized()
	return n

# Downward ray at a world XZ position; returns the intersect_ray dictionary
# ({} on a miss). Starts above the cat and reaches below it so it catches the
# surface whichever step the sample point sits on.
func _ground_ray(at: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(at.x, global_position.y + ground_ray_up, at.z),
		Vector3(at.x, global_position.y - ground_ray_down, at.z))
	params.collision_mask = ground_mask
	params.exclude = [get_rid()]
	return space.intersect_ray(params)

# World-space direction the cat is currently facing, flattened to the ground.
# _update_facing aligns the model's local +Z with the travel direction, so +Z is
# forward here. (If the laser ends up spawning BEHIND the cat, negate this.)
func facing_dir() -> Vector3:
	var f := model.global_transform.basis.z
	f.y = 0.0
	f = f.normalized()
	return f if f.length() > 0.01 else Vector3.FORWARD
	
func _update_animation() -> void:
	var want := anim_move
	var hold := false  # pose clips play once and stay on the last frame
	var speed_scale := 1.0
	if current_state == State.IDLE:
		# Sit for idle_wait_time seconds after arriving, then lie down and stay.
		want = anim_settle if idle_timer > 0.0 else anim_rest
		hold = true
	elif current_state == State.STALK:
		want = anim_sneak
		speed_scale = _stride_scale(anim_sneak_stride_speed)
	elif current_state == State.PURSUE:
		# Flat-out run after the bolting mouse.
		want = anim_move
		speed_scale = _stride_scale(anim_move_stride_speed)
	elif current_state == State.POUNCE:
		if not _leaped:
			# Coiling: hold a near-frozen sneak pose until the jump fires.
			want = anim_sneak
			speed_scale = 0.15
		else:
			want = anim_pounce
			hold = true  # one-shot jump clip: play it, don't restart it every frame
			speed_scale = anim_pounce_speed_scale
	elif current_state == State.RECOVER:
		want = anim_pounce_recover
		hold = true  # low pose, held for pounce_recover_time
	else:  # WALK / CHASE
		speed_scale = _stride_scale(anim_move_stride_speed)
	anim_player.speed_scale = speed_scale
	_play(want, hold)

# Match clip playback to how fast the body is actually travelling so the paws
# grip the ground. speed_scale 1.0 == "clip looks right at stride_speed m/s".
func _stride_scale(stride_speed: float) -> float:
	if stride_speed <= 0.0:
		return 1.0
	var h := Vector2(velocity.x, velocity.z).length()
	return clampf(h / stride_speed, 0.15, 2.5)

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
