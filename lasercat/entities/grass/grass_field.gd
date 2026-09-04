extends Node3D

## Procedural reactive grass covering the whole floor.
##
## Builds a grid of MultiMeshInstance3D chunks (so far ones frustum/range cull),
## each packed with little grass tufts. Density comes from low-frequency noise, so
## some spots are lush and some are thin — but min_cover keeps grass everywhere.
## One shared ShaderMaterial (grass.gdshader) does the wind + the heavy cat
## parting + the tiny mouse shakes; this script just feeds it cat / mice positions
## each frame. No collision — the cat and mice walk straight through.

const GRASS_SHADER := preload("res://entities/grass/grass.gdshader")

@export_group("Coverage")
@export var area_size: float = 200.0        # square side; match the ground plane
@export var chunk_div: int = 10             # area is split into chunk_div² MultiMesh chunks
@export var density: float = 8.0            # tuft candidates per m² (before the noise keep-test)
@export var min_cover: float = 0.6          # keep-chance in the thinnest spots (1.0 in the lushest)
@export var density_freq: float = 0.02      # lower = bigger lush/thin patches
@export var density_contrast: float = 1.7   # >1 sharpens the patches
@export var cull_distance: float = 95.0     # chunks past this from the camera stop drawing
@export var cull_fade: float = 12.0

@export_group("Tufts")
@export var blades_per_tuft: int = 4
@export var blade_height: Vector2 = Vector2(0.35, 0.9)
@export var blade_width: float = 0.055
@export var tuft_scale: Vector2 = Vector2(0.8, 1.35)
@export var tilt_max_deg: float = 9.0
@export var random_seed: int = 0

@export_group("Look / reaction")
@export var color_base: Color = Color(0.21, 0.35, 0.14)    # blade base — kept well off black
@export var color_tip: Color = Color(0.47, 0.63, 0.26)
@export var color_floor: Color = Color(0.16, 0.23, 0.11)   # hard lower bound so no blade ever reads as black
@export var ambient_fill: float = 0.09                     # flat brightness lift applied before posterising
@export var dry_patch_amount: float = 0.7               # how warm/pale the thin patches get (0 = uniform)
@export var pixel_color_steps: float = 5.0
@export var anim_step: float = 0.0          # >0 = chunky stepped sway; 0 = smooth (stepped motion is hard on the eyes over a whole field)
@export var wind_strength: float = 0.08
@export var wind_speed: float = 0.7
@export var cat_bend_radius: float = 1.4      # ~the cat's footprint; tight so it doesn't read as a force field
@export var cat_bend_strength: float = 0.16   # small outward shove — blades stay covering the ground under the cat
@export var cat_press_strength: float = 0.95  # fraction of blade height crushed under the cat — grass lies flat instead of parting away
@export var mouse_shake_radius: float = 1.05
@export var mouse_shake_strength: float = 0.34      # shake amplitude for a mouse moving THROUGH the grass
@export var mouse_idle_shake_frac: float = 0.34     # a mouse just sitting in the grass still stirs it this fraction of that
@export var mouse_speed_ref: float = 0.6            # at/above this flat speed the shake is at full "moving through it" strength

@export_group("Paths")
## Worn trails through the grass: the tufts just stop, so the ground shows through
## as a bare path. They wander (path_curve) and fork (path_branch_chance) but steer
## clear of OTHER trails (path_avoid_radius) so a screen isn't criss-crossed. The
## cat walks them a touch faster (see Cat.path_speed_mult / GrassField.is_on_path).
@export var path_count: int = 3                 # seed trails, each starting from a different map edge
@export var path_width: float = 1.4          # bare strip width ≈ 2 cats
@export var path_edge_feather: float = 0.7     # metres of thinning/short grass either side of the bare strip
@export var path_bare_stubble: float = 0.04    # chance a tuft survives (stunted) right on the bare path
@export var path_step: float = 2.0            # metres between trail points
@export var path_curve: float = 0.28          # max heading change (rad) per step — the wander
@export var path_max_len_steps: int = 110     # longest a single trail runs before it stops
@export var path_avoid_radius: float = 9.0    # steer away from other trails inside this; give up the trail if boxed in
@export var path_branch_chance: float = 0.028 # per-step chance a trail forks off a child
@export var path_branch_angle: float = 0.7    # a fork diverges by this many rad
@export var path_branch_depth: int = 1        # forks-of-forks allowed this deep (1 = branches don't re-branch)
@export var path_branch_max_steps: int = 40   # a fork runs at most this long
@export var path_max_segments: int = 420      # hard cap on total generated segments

@export_group("Audio")
@export var rustle_min_speed: float = 0.3           # cat's flat speed needed to stir a rustle
@export var rustle_interval: Vector2 = Vector2(1.6, 3.2)
@export var rustle_volume_db: float = -10.0

var _mat: ShaderMaterial
var _cat: Node3D
var _mice_scratch: Array = []
var _path_pts: Array = []          # Array[PackedVector2Array] — each a trail polyline in world XZ
var _path_min := Vector2(INF, INF) # overall AABB of the trail network, for a cheap query reject
var _path_max := Vector2(-INF, -INF)
var _rustle_player: AudioStreamPlayer  # non-positional — see the note in cat.gd's _setup_audio
var _rustle_timer: float = 0.0

func _ready() -> void:
	add_to_group("grass_field")  # the cat looks this up to check if it's on a trail

	var rng := RandomNumberGenerator.new()
	if random_seed != 0:
		rng.seed = random_seed
	else:
		rng.randomize()

	_mat = ShaderMaterial.new()
	_mat.shader = GRASS_SHADER
	_mat.set_shader_parameter("color_base", color_base)
	_mat.set_shader_parameter("color_tip", color_tip)
	_mat.set_shader_parameter("color_floor", color_floor)
	_mat.set_shader_parameter("ambient_fill", ambient_fill)
	_mat.set_shader_parameter("pixel_color_steps", pixel_color_steps)
	_mat.set_shader_parameter("anim_step", anim_step)
	_mat.set_shader_parameter("wind_strength", wind_strength)
	_mat.set_shader_parameter("wind_speed", wind_speed)
	_mat.set_shader_parameter("cat_bend_radius", cat_bend_radius)
	_mat.set_shader_parameter("cat_bend_strength", cat_bend_strength)
	_mat.set_shader_parameter("cat_press_strength", cat_press_strength)
	_mat.set_shader_parameter("mouse_shake_radius", mouse_shake_radius)
	_mat.set_shader_parameter("mouse_shake_strength", mouse_shake_strength)
	_mat.set_shader_parameter("mouse_count", 0)

	var dnoise := FastNoiseLite.new()
	dnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	dnoise.frequency = density_freq
	dnoise.seed = rng.randi()
	var cnoise := FastNoiseLite.new()
	cnoise.frequency = density_freq * 2.3
	cnoise.seed = rng.randi()

	var mesh := _make_tuft_mesh(rng)
	var half := area_size * 0.5
	var chunk := area_size / float(chunk_div)
	var per_chunk_tries := int(chunk * chunk * density)

	_mice_scratch.resize(8)
	_build_paths(rng, half)
	var path_infl := path_width * 0.5 + path_edge_feather + 0.75

	for cz in chunk_div:
		for cx in chunk_div:
			var centre := Vector3(-half + (cx + 0.5) * chunk, 0.0, -half + (cz + 0.5) * chunk)
			var xforms: Array[Transform3D] = []
			var colors: PackedColorArray = PackedColorArray()
			# Only the trail segments that reach into this chunk — most chunks get none.
			var chunk_segs := _segs_in_rect(centre.x, centre.z, chunk * 0.5 + path_infl)

			for _i in per_chunk_tries:
				var lx := rng.randf_range(-chunk * 0.5, chunk * 0.5)
				var lz := rng.randf_range(-chunk * 0.5, chunk * 0.5)
				var wx := centre.x + lx
				var wz := centre.z + lz

				# trample: 1 = untouched grass, 0 = on the bare trail
				var trample := 1.0
				if not chunk_segs.is_empty():
					var pd := _dist_to_segs(wx, wz, chunk_segs)
					var half_w := path_width * 0.5
					if pd < half_w:
						if rng.randf() > path_bare_stubble:
							continue          # bare dirt — no tuft here
						trample = 0.12        # rare stunted survivor
					else:
						var e: float = clampf((pd - half_w) / maxf(path_edge_feather, 0.001), 0.0, 1.0)
						trample = e * e * (3.0 - 2.0 * e)  # smoothstep in from the path edge

				var d01: float = clampf(dnoise.get_noise_2d(wx, wz) * 0.5 + 0.5, 0.0, 1.0)
				d01 = pow(d01, density_contrast)
				if rng.randf() > lerpf(min_cover, 1.0, d01) * lerpf(0.1, 1.0, trample):
					continue

				xforms.append(_tuft_xform(rng, lx, lz, d01, trample))
				colors.append(_tuft_color(rng, cnoise.get_noise_2d(wx, wz) * 0.5 + 0.5))

			if xforms.is_empty():
				continue

			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mesh
			mm.instance_count = xforms.size()
			for i in xforms.size():
				mm.set_instance_transform(i, xforms[i])
				mm.set_instance_color(i, colors[i])

			var mmi := MultiMeshInstance3D.new()
			mmi.name = "GrassChunk_%d_%d" % [cx, cz]
			mmi.multimesh = mm
			mmi.material_override = _mat
			mmi.position = centre
			# Casts its own shadow onto the ground (the shader still opts out of
			# RECEIVING shadows — see grass.gdshader — so the field stays flicker-free).
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			mmi.visibility_range_end = cull_distance
			mmi.visibility_range_end_margin = cull_fade
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			add_child(mmi)

	_cat = get_tree().get_first_node_in_group("cat") as Node3D

	_rustle_player = AudioStreamPlayer.new()
	_rustle_player.name = "RustlePlayer"
	_rustle_player.volume_db = rustle_volume_db
	add_child(_rustle_player)
	_rustle_timer = randf_range(rustle_interval.x, rustle_interval.y)

func _process(delta: float) -> void:
	if _mat == null:
		return
	if _cat == null or not is_instance_valid(_cat):
		_cat = get_tree().get_first_node_in_group("cat") as Node3D
	if _cat:
		_mat.set_shader_parameter("cat_pos", _cat.global_position)
	_update_rustle(delta)

	var n := 0
	for m in get_tree().get_nodes_in_group("mice"):
		if n >= 8:
			break
		if not (m is Node3D):
			continue
		# w = how hard this mouse rattles the grass: full while it's moving through it,
		# easing down to mouse_idle_shake_frac once it's just sitting there.
		var shake := mouse_idle_shake_frac
		if m is CharacterBody3D:
			var v: Vector3 = (m as CharacterBody3D).velocity
			var flat := Vector2(v.x, v.z).length()
			var move01: float = clampf((flat - 0.05) / maxf(mouse_speed_ref - 0.05, 0.01), 0.0, 1.0)
			shake = lerpf(mouse_idle_shake_frac, 1.0, move01)
		var p: Vector3 = (m as Node3D).global_position
		_mice_scratch[n] = Vector4(p.x, p.y, p.z, shake)
		n += 1
	for i in range(n, 8):
		_mice_scratch[i] = Vector4(0.0, 0.0, 0.0, 0.0)
	_mat.set_shader_parameter("mouse_data", _mice_scratch)
	_mat.set_shader_parameter("mouse_count", n)

# --- construction -----------------------------------------------------------

func _tuft_xform(rng: RandomNumberGenerator, lx: float, lz: float, d01: float, trample: float = 1.0) -> Transform3D:
	# trample < 1 (near a trail): lean the tuft over harder and cut its height, so
	# the path edge reads as flattened, worn-down grass rather than a clean mow line.
	var tilt := lerpf(tilt_max_deg, maxf(tilt_max_deg, 24.0), 1.0 - trample)
	var b := Basis(Vector3.UP, rng.randf_range(0.0, TAU))
	if tilt > 0.0:
		var axis := Vector3(rng.randf() - 0.5, 0.0, rng.randf() - 0.5)
		if axis.length() > 0.001:
			b = Basis(axis.normalized(), deg_to_rad(rng.randf_range(0.0, tilt))) * b
	var s: float = lerpf(tuft_scale.x, tuft_scale.y, rng.randf()) * (0.7 + 0.5 * d01)
	var sy: float = s * rng.randf_range(0.85, 1.25) * lerpf(0.3, 1.0, trample)
	b = b.scaled(Vector3(s, sy, s))
	return Transform3D(b, Vector3(lx, 0.0, lz))

func _tuft_color(rng: RandomNumberGenerator, dry01: float) -> Color:
	var bright := rng.randf_range(0.82, 1.14)
	# Per-instance multiply tint the shader applies over its green gradient: lush
	# patches stay neutral, thin/dry patches warm and pale out.
	var t: float = clampf(dry01, 0.0, 1.0) * dry_patch_amount
	return Color(
		bright * (1.0 + 1.1 * t),
		bright * (1.0 + 0.25 * t),
		bright * (1.0 - 0.35 * t))

# One tuft = blades_per_tuft tapered quads fanned around the origin, base on the
# ground (y = 0), UV.y carrying the 0..1 height the shader bends by.
func _make_tuft_mesh(rng: RandomNumberGenerator) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	for bi in blades_per_tuft:
		var a := bi * TAU / float(blades_per_tuft) + rng.randf_range(-0.5, 0.5)
		var dir := Vector3(sin(a), 0.0, cos(a))
		var right := Vector3(cos(a), 0.0, -sin(a))
		var h := rng.randf_range(blade_height.x, blade_height.y)
		var w0 := blade_width * rng.randf_range(0.8, 1.2)
		var w1 := w0 * 0.12
		# base sits ~4 cm INTO the ground so it never z-fights the floor plane and
		# the hard bottom edge is buried in the dirt
		var c0 := dir * rng.randf_range(0.0, 0.06) + Vector3(0.0, -0.04, 0.0)
		var tip := c0 + dir * (h * rng.randf_range(0.15, 0.4)) + Vector3(0.0, h, 0.0)
		var n := (Vector3.UP + dir * 0.25).normalized()

		var base := verts.size()
		verts.push_back(c0 - right * w0 * 0.5)
		verts.push_back(c0 + right * w0 * 0.5)
		verts.push_back(tip - right * w1 * 0.5)
		verts.push_back(tip + right * w1 * 0.5)
		for _k in 4:
			norms.push_back(n)
		uvs.push_back(Vector2(0.0, 0.0))
		uvs.push_back(Vector2(1.0, 0.0))
		uvs.push_back(Vector2(0.0, 1.0))
		uvs.push_back(Vector2(1.0, 1.0))
		idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

# --- paths ----------------------------------------------------------------------

# Grow `path_count` trails. Each starts on its own map edge (spread evenly, not
# random, so they don't clump) heading inward, walks in `path_step` hops while its
# heading drifts by up to `path_curve` per hop (plus a slow sine meander, so the
# wander reads as a curve), and now and then forks a child at `path_branch_angle`.
# As a trail walks it steers AWAY from every already-laid trail within
# `path_avoid_radius` and gives up if it can't get clear — so trails branch and
# spread but rarely cross. Capped by `path_max_len_steps` per trail and
# `path_max_segments` overall.
func _build_paths(rng: RandomNumberGenerator, half: float) -> void:
	_path_pts.clear()
	_path_min = Vector2(INF, INF)
	_path_max = Vector2(-INF, -INF)
	if path_count <= 0 or path_width <= 0.0:
		return

	var budget := path_max_segments
	var jobs: Array = []   # each: {pos, dir, life, depth, ph, grace}
	for i in path_count:
		var m := half * 0.92
		var pos: Vector2
		var dir: Vector2
		match i % 4:
			0: pos = Vector2(rng.randf_range(-m, m), -m); dir = Vector2(0.0, 1.0)
			1: pos = Vector2(rng.randf_range(-m, m), m); dir = Vector2(0.0, -1.0)
			2: pos = Vector2(-m, rng.randf_range(-m, m)); dir = Vector2(1.0, 0.0)
			_: pos = Vector2(m, rng.randf_range(-m, m)); dir = Vector2(-1.0, 0.0)
		dir = dir.rotated(rng.randf_range(-0.6, 0.6))
		# grace: steps before avoidance switches on (a fresh seed can't collide yet;
		# a branch needs a moment to clear the parent it sprouted from).
		jobs.append({"pos": pos, "dir": dir, "life": path_max_len_steps, "depth": 0, "ph": rng.randf() * TAU, "grace": 0})

	while not jobs.is_empty() and budget > 0:
		var job: Dictionary = jobs.pop_back()
		var pos: Vector2 = job["pos"]
		var dir: Vector2 = (job["dir"] as Vector2).normalized()
		var life: int = job["life"]
		var depth: int = job["depth"]
		var ph: float = job["ph"]
		var grace: int = job["grace"]
		# Snapshot of the trails that already exist — this trail avoids these, not
		# its own body (which it necessarily runs alongside).
		var others: Array = _path_pts.duplicate()
		var pts := PackedVector2Array([pos])
		while life > 0 and budget > 0:
			life -= 1
			budget -= 1
			ph += 0.35
			var turn := rng.randf_range(-path_curve, path_curve) + sin(ph) * path_curve * 0.5
			dir = dir.rotated(turn).normalized()

			if grace > 0:
				grace -= 1
			elif path_avoid_radius > 0.0 and not others.is_empty():
				var rep := _repulsion_from(pos, others, path_avoid_radius)
				var near: float = rep.w
				if near < path_width:
					break  # boxed in against another trail — stop here rather than merge
				if rep.x != 0.0 or rep.y != 0.0:
					# bend the heading toward "away", harder the closer the other trail
					var w: float = clampf(1.0 - near / path_avoid_radius, 0.0, 1.0)
					var away := Vector2(rep.x, rep.y).normalized()
					dir = (dir + away * (1.6 * w)).normalized()

			pos += dir * path_step
			pts.append(pos)
			if absf(pos.x) > half + path_step or absf(pos.y) > half + path_step:
				break
			if depth < path_branch_depth and rng.randf() < path_branch_chance:
				var side := 1.0 if rng.randf() < 0.5 else -1.0
				jobs.append({
					"pos": pos,
					"dir": dir.rotated(path_branch_angle * side),
					"life": clampi(life / 2, 6, path_branch_max_steps),
					"depth": depth + 1,
					"ph": rng.randf() * TAU,
					"grace": 3,
				})
		if pts.size() >= 2:
			_path_pts.append(pts)
			for p in pts:
				_path_min = _path_min.min(p)
				_path_max = _path_max.max(p)

# Sum of "push away" vectors from every point on `others` within `radius` of `p`,
# weighted by nearness. Returns Vector4(push.x, push.y, 0, nearest_distance).
func _repulsion_from(p: Vector2, others: Array, radius: float) -> Vector4:
	var push := Vector2.ZERO
	var nearest := INF
	var r2 := radius * radius
	for pts in others:
		for q in pts:
			var to: Vector2 = p - q
			var d2 := to.length_squared()
			if d2 > r2 or d2 < 1e-6:
				continue
			var d := sqrt(d2)
			nearest = minf(nearest, d)
			push += to / d * (1.0 - d / radius)
	return Vector4(push.x, push.y, 0.0, nearest)

# Trail segments whose AABB overlaps the square of half-size `ext` centred on
# (cx, cz). Returned as Vector4(ax, az, bx, bz) so the distance test stays flat.
func _segs_in_rect(cx: float, cz: float, ext: float) -> Array:
	var out: Array = []
	for pts in _path_pts:
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			if cx < minf(a.x, b.x) - ext or cx > maxf(a.x, b.x) + ext:
				continue
			if cz < minf(a.y, b.y) - ext or cz > maxf(a.y, b.y) + ext:
				continue
			out.append(Vector4(a.x, a.y, b.x, b.y))
	return out

func _dist_to_segs(x: float, z: float, segs: Array) -> float:
	var best := INF
	for s in segs:
		best = minf(best, _seg_dist_sq(x, z, s.x, s.y, s.z, s.w))
	return sqrt(best)

func _seg_dist_sq(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
	var abx := bx - ax
	var abz := bz - az
	var denom := abx * abx + abz * abz
	var t := 0.0
	if denom > 1e-9:
		t = clampf(((px - ax) * abx + (pz - az) * abz) / denom, 0.0, 1.0)
	var dx := px - (ax + abx * t)
	var dz := pz - (az + abz * t)
	return dx * dx + dz * dz

# Public: is this world point on a worn trail? `margin` widens the test (the cat
# passes ~half its body radius so a paw on the edge still counts). Cheap AABB
# reject first, then a straight scan of every segment (a few hundred at most).
func is_on_path(world_pos: Vector3, margin: float = 0.0) -> bool:
	return path_distance(world_pos) <= path_width * 0.5 + margin

# A rustling-grass one-shot while the cat is actually moving through the field —
# silent while it stands still so the field doesn't hiss at an idle cat.
func _update_rustle(delta: float) -> void:
	_rustle_timer -= delta
	if _rustle_timer > 0.0:
		return
	if _cat == null or not is_instance_valid(_cat) or not (_cat is CharacterBody3D):
		return
	var v: Vector3 = (_cat as CharacterBody3D).velocity
	if Vector2(v.x, v.z).length() < rustle_min_speed:
		return
	var stream := SoundLibrary.random("ambient/rustle")
	if stream == null:
		return
	_rustle_timer = randf_range(rustle_interval.x, rustle_interval.y)
	_rustle_player.stream = stream
	_rustle_player.pitch_scale = randf_range(0.9, 1.1)
	_rustle_player.play()

# Distance from a world point to the nearest trail centre-line (INF if no trails).
func path_distance(world_pos: Vector3) -> float:
	if _path_pts.is_empty():
		return INF
	var x := world_pos.x
	var z := world_pos.z
	var pad := path_width * 0.5 + path_edge_feather
	if x < _path_min.x - pad or x > _path_max.x + pad or z < _path_min.y - pad or z > _path_max.y + pad:
		return INF
	var best := INF
	for pts in _path_pts:
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			best = minf(best, _seg_dist_sq(x, z, a.x, a.y, b.x, b.y))
			if best <= 0.0001:
				return 0.0
	return sqrt(best)
