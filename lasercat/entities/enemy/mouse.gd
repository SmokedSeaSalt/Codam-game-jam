class_name Mouse
extends Enemy

## A mouse. It ambles slowly around its spawn point — turning only gently as it
## goes — until the cat enters its (narrow) vision cone or gets close enough to
## startle it from any angle, then it sprints for the nearest edge of the map,
## following the navigation mesh so it routes around terrain instead of wedging
## on it. It commits to that sprint for at least flee_min_time, then crosses the
## arena rim and vanishes, emitting `escaped`. sprint_speed is well ABOVE the
## cat's chase_speed, so a mouse that spots the cat gets clean away — the cat's
## only real chance is to creep up on its blind side and pounce before it looks.
## startle_range is tiny for that reason: an approach from behind should NOT wake
## it. Getting pounced still routes through Enemy.die() / `died`. main_3d listens
## for both and spawns a fresh mouse.

signal escaped(mouse: Mouse)

enum MouseState { IDLE, FLEE }

@export_group("Vision")
@export var fov_angle_deg: float = 100.0    # full width of the vision cone — wide; the cat has to come at the mouse's back to stay unseen
@export var fov_range: float = 9.0         # how far down the cone the cat is spotted — well past the cat's stalk standoff, so any frontal creep gets caught
@export var startle_range: float = 0.6      # only a near-collision wakes it from outside the cone — a stalk from behind stays unseen

@export_group("Flee")
@export var sprint_speed: float = 11.0       # well ABOVE the cat's chase_speed — a spotted mouse gets clean away
@export var flee_min_time: float = 2.0      # commit to running at least this long before the off-map check arms
@export var flee_max_time: float = 14.0     # gone after this even if still on the map
@export var despawn_distance: float = 55.0  # distance from the world origin that counts as "off the map"
@export var flee_bob_amp: float = 0.02      # how far the model hops up while sprinting — fakes leg movement
@export var flee_bob_speed: float = 22.0    # bob cycles per second-ish while at full sprint
@export var flee_start_speed_frac: float = 0.4  # bolts at this fraction of sprint_speed, so the cat briefly gains
@export var flee_accel_time: float = 2.5    # seconds from bolting to full sprint_speed
@export var slow_flee_chance: float = 0.2   # chance a bolt NEVER accelerates — the cat runs it down and catches it
@export var slow_flee_speed_frac: float = 0.45  # fixed speed (× sprint_speed) for a non-accelerating flee — keep below the cat's pursue_speed

@export_group("Idle")
@export var walk_speed: float = 0.8                       # slow amble while it hasn't spotted the cat
@export var walk_radius: float = 3.0                      # how far it strays from where it was dropped
@export var repath_interval: Vector2 = Vector2(1.2, 3.0)  # random seconds between picking a new amble point — short = keeps scurrying
@export var idle_turn_max_deg: float = 35.0               # cap on how far each new amble point can bend the heading — keeps turns small so the cat can still sneak up
@export var idle_turn_speed: float = 1.2                  # radians/sec easing toward the amble heading — slow and gentle
@export var idle_pause_chance: float = 0.15               # fraction of amble points that are just "stop and sniff"
@export var separation_radius: float = 1.4                # start drifting apart from any mouse closer than this
@export var separation_strength: float = 0.9              # m/s of "spread out from the crowd" nudge while idling

@export_group("Debug")
## Draws a translucent wedge for the vision cone: green = hasn't seen the cat,
## orange = cat is in view, red = fleeing. Turn off once the tuning feels right.
@export var show_fov_cone: bool = false

var _mstate: MouseState = MouseState.IDLE
var _cat: Node3D = null
var _flee_timer: float = 0.0       # counts down flee_min_time
var _flee_elapsed: float = 0.0     # counts up toward flee_max_time
var _flee_dir: Vector3 = Vector3.ZERO   # last good escape heading (fallback when the nav path is empty)
var _flee_goal: Vector3 = Vector3.ZERO  # a point on the map rim the nav agent paths us to
var _last_pos: Vector3 = Vector3.ZERO   # previous-frame position, for wedge detection
var _stuck_for: float = 0.0        # seconds spent commanding movement but not actually moving
var _turn_timer: float = 0.0       # counts down to the next amble point
var _amble_target: Vector3 = Vector3.ZERO  # point the mouse is slowly walking toward while idling
var _amble_pause: bool = false     # current amble leg is a "stand and sniff", not a walk
var _braced: bool = false          # the cat has committed a pounce — hold still, can't flee
var _yaw: float = 0.0              # current facing yaw
var _cone: MeshInstance3D = null
var _cone_mat: StandardMaterial3D = null
var _model: Node3D = null          # the visual mesh; bobbed up/down while fleeing
var _model_base_y: float = 0.0     # its resting local Y, restored when not fleeing
var _bob_phase: float = 0.0
var _flee_speed_frac: float = 0.0  # 0..1 ramp from flee_start_speed_frac up to full sprint
var _slow_flee: bool = false       # this bolt won't accelerate — the cat is allowed to catch it

@onready var nav: NavigationAgent3D = $NavigationAgent3D

func _ready() -> void:
	super._ready()          # "enemies" group + health
	wander = false          # this script drives all movement; ignore Enemy's wander
	add_to_group("mice")
	_cat = _find_cat()
	_yaw = rotation.y
	_amble_target = global_position
	_last_pos = global_position
	_model = get_node_or_null("Model")
	if _model:
		_model_base_y = _model.position.y
	_reset_turn_timer()
	if show_fov_cone:
		_build_fov_cone()

# Hop the model up and down while it's sprinting away, so it reads as scurrying
# legs. Eases back to rest otherwise. (The pixel filter reads Model's transform,
# so this shows through it too.)
func _apply_run_bob(delta: float) -> void:
	if _model == null:
		return
	if _mstate == MouseState.FLEE and not _braced:
		# Legs cycle (and hop) faster as the sprint ramps up.
		_bob_phase += delta * flee_bob_speed * maxf(_flee_speed_frac, 0.35)
		_model.position.y = _model_base_y + absf(sin(_bob_phase)) * flee_bob_amp * maxf(_flee_speed_frac, 0.5)
	else:
		_model.position.y = lerpf(_model.position.y, _model_base_y, clampf(delta * 10.0, 0.0, 1.0))

func _physics_process(delta: float) -> void:
	if _cat == null or not is_instance_valid(_cat):
		_cat = _find_cat()

	_apply_run_bob(delta)

	# Pinned by an incoming pounce: freeze in place (gravity only) until it lands
	# or the cat gives up. The mouse doesn't get to spot the cat mid-air and slip.
	if _braced:
		velocity.x = 0.0
		velocity.z = 0.0
		if is_on_floor() and velocity.y <= 0.0:
			velocity.y = 0.0
		else:
			velocity.y -= gravity * delta
		move_and_slide()
		_update_fov_cone()
		return

	match _mstate:
		MouseState.IDLE:
			_process_idle(delta)
			if _sees_cat():
				_start_flee()
		MouseState.FLEE:
			_process_flee(delta)

	# Gravity (mirrors Enemy._physics_process, which we've replaced wholesale).
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	move_and_slide()
	_unstick_if_wedged(delta)
	_update_fov_cone()

# Unit direction (flat) toward the next navmesh corner on the way to `target`, or
# ZERO if we're basically on it / there's no path yet. Routing every move through
# here is what keeps the mouse off the terrain steps it used to grind against.
func _nav_step(target: Vector3) -> Vector3:
	nav.target_position = target
	var d: Vector3 = nav.get_next_path_position() - global_position
	d.y = 0.0
	return d.normalized() if d.length() > 0.05 else Vector3.ZERO

# Belt-and-braces for the rare concave spot the navmesh can't talk the mouse out
# of: if it's asking to move but hasn't actually travelled, lift it back onto the
# nearest navmesh point. Mirrors the cat's _update_stuck.
func _unstick_if_wedged(delta: float) -> void:
	var moved := Vector2(global_position.x - _last_pos.x, global_position.z - _last_pos.z).length()
	_last_pos = global_position
	if Vector2(velocity.x, velocity.z).length() > 0.1 and moved < 0.004:
		_stuck_for += delta
	else:
		_stuck_for = 0.0
	if _stuck_for < 0.3:
		return
	_stuck_for = 0.0
	var map := nav.get_navigation_map()
	if map.is_valid():
		var on_mesh := NavigationServer3D.map_get_closest_point(map, global_position)
		if Vector2(on_mesh.x - global_position.x, on_mesh.z - global_position.z).length() > 0.2:
			global_position = on_mesh + Vector3(0.0, 0.05, 0.0)

# Amble slowly around the spawn point, turning gently toward each new point (with
# the odd "stop and sniff" pause). The unhurried pace is the window the cat has to
# sneak in before being spotted.
func _process_idle(delta: float) -> void:
	_turn_timer -= delta
	if _turn_timer <= 0.0:
		_pick_amble_target()
		_reset_turn_timer()

	var step := Vector3.ZERO if _amble_pause else _nav_step(_amble_target)
	var sep := _separation() * separation_strength   # always shove out of a clump, even while paused
	if step == Vector3.ZERO:
		velocity.x = sep.x
		velocity.z = sep.z
	else:
		velocity.x = step.x * walk_speed + sep.x
		velocity.z = step.z * walk_speed + sep.z
		_yaw = lerp_angle(_yaw, atan2(step.x, step.z), clampf(delta * idle_turn_speed, 0.0, 1.0))
	rotation.y = _yaw

# A gentle push away from every mouse crowding this one, so clumps drift apart on
# their own — overlapping mice were confusing the cat's target picking and stalk.
func _separation() -> Vector3:
	var push := Vector3.ZERO
	for other in get_tree().get_nodes_in_group("mice"):
		if other == self or not (other is Node3D):
			continue
		var d: Vector3 = global_position - (other as Node3D).global_position
		d.y = 0.0
		var dist := d.length()
		if dist > 0.001 and dist < separation_radius:
			push += d.normalized() * (1.0 - dist / separation_radius)
	return push if push.length() <= 1.0 else push.normalized()

# A fresh point to amble to: a short step whose heading bends at most
# idle_turn_max_deg off the current facing (so turns stay small), kept within
# walk_radius of where the mouse was dropped so it doesn't drift across the arena.
func _pick_amble_target() -> void:
	_amble_pause = randf() < idle_pause_chance
	var heading := _yaw + deg_to_rad(randf_range(-idle_turn_max_deg, idle_turn_max_deg))
	var dist := randf_range(0.8, walk_radius)
	var p := global_position + Vector3(sin(heading), 0.0, cos(heading)) * dist
	var from_home := p - _home
	from_home.y = 0.0
	if from_home.length() > walk_radius:
		p = _home + from_home.normalized() * walk_radius
	_amble_target = p

# Sprint for the map rim, following the navmesh path to _flee_goal so terrain
# steps get routed around instead of run into. Despawns once it's had its minimum
# run AND crossed the arena edge, or unconditionally after flee_max_time.
func _process_flee(delta: float) -> void:
	_flee_timer -= delta
	_flee_elapsed += delta

	var step := _nav_step(_flee_goal)
	if step == Vector3.ZERO:
		step = _flee_dir  # path exhausted / not ready — keep going the last good way
	_flee_dir = step

	# Most bolts ease from a slow start up to full sprint over flee_accel_time (the
	# cat closes for a beat, then the mouse pulls clear). But slow_flee_chance of
	# them never accelerate — those stay catchable.
	if _slow_flee:
		_flee_speed_frac = slow_flee_speed_frac
	else:
		var t := clampf(_flee_elapsed / maxf(flee_accel_time, 0.01), 0.0, 1.0)
		_flee_speed_frac = lerpf(flee_start_speed_frac, 1.0, t * t)
	var spd := sprint_speed * _flee_speed_frac
	velocity.x = step.x * spd
	velocity.z = step.z * spd

	# Face the run direction (+Z is forward — see _sees_cat).
	_yaw = lerp_angle(_yaw, atan2(step.x, step.z), clampf(delta * 10.0, 0.0, 1.0))
	rotation.y = _yaw

	var off_map := _flee_timer <= 0.0 and _distance_from_origin() >= despawn_distance
	if off_map or _flee_elapsed >= flee_max_time:
		escaped.emit(self)
		queue_free()

func _reset_turn_timer() -> void:
	_turn_timer = randf_range(repath_interval.x, repath_interval.y)

func _find_cat() -> Node3D:
	return get_tree().get_first_node_in_group("cat") as Node3D

# Cat inside the vision cone (or inside startle_range from any angle).
func _sees_cat() -> bool:
	if _cat == null or not is_instance_valid(_cat):
		return false
	var to: Vector3 = _cat.global_position - global_position
	to.y = 0.0
	var d := to.length()
	if d <= startle_range:
		return true
	if d > fov_range:
		return false
	var fwd := global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return false
	return fwd.normalized().angle_to(to / d) <= deg_to_rad(fov_angle_deg * 0.5)

# Flat unit vector pointing from the cat to the mouse (the escape heading).
func _away_from_cat() -> Vector3:
	if _cat == null or not is_instance_valid(_cat):
		return Vector3(sin(_yaw), 0.0, cos(_yaw))  # keep going the way we were headed
	var away: Vector3 = global_position - _cat.global_position
	away.y = 0.0
	if away.length() < 0.01:
		return Vector3(sin(_yaw), 0.0, cos(_yaw))
	return away.normalized()

func _distance_from_origin() -> float:
	return Vector2(global_position.x, global_position.z).length()

func _start_flee() -> void:
	_mstate = MouseState.FLEE
	_flee_timer = flee_min_time
	_flee_elapsed = 0.0
	_slow_flee = randf() < slow_flee_chance
	_flee_speed_frac = slow_flee_speed_frac if _slow_flee else flee_start_speed_frac
	_flee_dir = _escape_heading()
	# Aim way past the rim in the escape direction; the navmesh clamps that to a
	# real point on the map edge and paths the mouse there around any terrain.
	var far := global_position + _flee_dir * (despawn_distance * 2.0)
	var map := nav.get_navigation_map()
	_flee_goal = NavigationServer3D.map_get_closest_point(map, far) if map.is_valid() else far

# The escape heading: straight away from the cat, nudged toward "radially out from
# the arena centre" so the mouse heads for the nearest edge rather than deeper
# into the map. Used to place _flee_goal and as the fallback while it runs.
func _escape_heading() -> Vector3:
	var away := _away_from_cat()
	var outward := Vector3(global_position.x, 0.0, global_position.z)
	if outward.length() > 0.5:
		away += outward.normalized() * 0.5
		away.y = 0.0
		if away.length() > 0.01:
			away = away.normalized()
	return away

## The cat's hunt logic polls this to swap its slow stalk for a full-speed chase.
func is_fleeing() -> bool:
	return _mstate == MouseState.FLEE

## True for the slow_flee_chance of bolts that never accelerate — the cat is
## allowed to run these down and catch them mid-chase.
func is_catchable_flee() -> bool:
	return _mstate == MouseState.FLEE and _slow_flee

## Called by the cat the instant it launches its pounce. From here the mouse is
## caught: it stops dead and can't start fleeing, so seeing the cat in mid-air no
## longer lets it slip away. Cleared by release_pounce() if the cat bails.
func brace_for_pounce() -> void:
	_braced = true
	velocity = Vector3.ZERO

func release_pounce() -> void:
	_braced = false

# --- Debug vision cone ------------------------------------------------------

# A flat translucent wedge, +Z forward, spanning fov_angle_deg out to fov_range.
# Parented to the mouse so it turns with it.
func _build_fov_cone() -> void:
	var half := deg_to_rad(fov_angle_deg * 0.5)
	var segments := 28
	var y := 0.05
	var verts := PackedVector3Array()
	verts.append(Vector3(0.0, y, 0.0))
	for i in range(segments + 1):
		var a := lerpf(-half, half, float(i) / float(segments))
		verts.append(Vector3(sin(a) * fov_range, y, cos(a) * fov_range))
	var idx := PackedInt32Array()
	for i in range(segments):
		idx.append(0)
		idx.append(i + 1)
		idx.append(i + 2)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	_cone_mat = StandardMaterial3D.new()
	_cone_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cone_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cone_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_cone = MeshInstance3D.new()
	_cone.name = "FovConeDebug"
	_cone.mesh = mesh
	_cone.material_override = _cone_mat
	_cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cone)

func _update_fov_cone() -> void:
	if _cone_mat == null:
		return
	if _mstate == MouseState.FLEE:
		_cone_mat.albedo_color = Color(1.0, 0.15, 0.1, 0.33)
	elif _sees_cat():
		_cone_mat.albedo_color = Color(1.0, 0.55, 0.05, 0.28)
	else:
		_cone_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.14)
