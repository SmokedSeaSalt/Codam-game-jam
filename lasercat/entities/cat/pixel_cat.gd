## Renders ONLY the cat into a low-resolution SubViewport and composites it back
## over the scene, so the cat reads as a chunky pixel-art 3D model while the rest
## of the game stays crisp.
##
## Occlusion (cat walking behind hills) is done with CPU line-of-sight rays, and
## the cat DISSOLVES via a screen-locked dither as it's blocked. Nothing compares
## rendered colours per frame, so there is no colour flicker.
##
## SELF-CONTAINED — touches no other script or scene file:
##   * add pixel_cat.tscn as a child of Main, next to Camera3D / Cat
##   * at runtime it reparents the cat's *visual* nodes (Skeleton3D + AnimationPlayer)
##     into the pixel world; the CharacterBody3D, collision and navigation stay put
##   * to revert: delete the PixelCat node. Nothing else changes.
extends Node

@export_node_path("Camera3D") var main_camera_path: NodePath = ^"../Camera3D"
@export_node_path("Node3D") var cat_path: NodePath = ^"../Cat"
@export_node_path("DirectionalLight3D") var sun_path: NodePath = ^"../DirectionalLight3D"

@export_range(1, 16) var pixel_scale: int = 5       ## bigger = chunkier pixels
@export var snap_cat_to_pixels: bool = true         ## pin the cat to the pixel grid — no crawl/boil as it moves
@export var snap_camera_to_pixels: bool = false     ## also grid-snap the camera (can 1px-judder while it eases)
@export var crunch_cat_textures: bool = false       ## nearest-filter the cat's textures — OFF is more temporally stable
@export var flatten_cat_shading: bool = true        ## drop specular + normal map
@export var unshaded_cat: bool = true               ## pure albedo, zero lighting — kills shade strobing
@export var flat_color: bool = false               ## replace the cat's texture with one solid colour (most stable of all)
@export var flat_color_value: Color = Color(0.85, 0.42, 0.12)
@export_range(0, 32) var color_levels: int = 6      ## posterise the composite; snaps shade wobble to fixed steps (0 = off)
@export var ambient_energy: float = 0.30            ## fill light in the pixel world (keep low or the cat blows out to white)
@export var sun_energy_scale: float = 0.55          ## fraction of the real sun's energy used in the pixel world (capped at 0.9)

@export_group("Occlusion")
@export var occlusion_smooth: float = 16.0          ## how fast the dissolve reacts (higher = snappier)
@export var occlusion_slop: float = 0.35            ## a ray that only grazes terrain within this of the target isn't a real blocker
@export var occlusion_reach: float = 1.0            ## scales the ray-target cloud; raise if the cat's a bigger model
@export var hard_cut: bool = false                  ## true = pop in/out instead of dither-dissolve

@onready var _sub: SubViewport = $SubViewport
@onready var _mirror_cam: Camera3D = $SubViewport/MirrorCamera
@onready var _sub_sun: DirectionalLight3D = $SubViewport/Sun
@onready var _rig: Node3D = $SubViewport/Rig
@onready var _display: TextureRect = $CanvasLayer/Display

var _main_cam: Camera3D
var _cat: Node3D
var _cat_rid: RID
var _ok := false
var _vis := 1.0
var _snap_px := Vector2.INF

func _ready() -> void:
	# Let the cat's own _ready() and the runtime terrain build finish first.
	await get_tree().process_frame
	await get_tree().process_frame

	_main_cam = get_node_or_null(main_camera_path) as Camera3D
	_cat = get_node_or_null(cat_path) as Node3D
	var sun := get_node_or_null(sun_path) as DirectionalLight3D
	if _main_cam == null or _cat == null:
		push_warning("PixelCat: could not resolve main_camera_path / cat_path — effect disabled.")
		return
	if _cat is CollisionObject3D:
		_cat_rid = (_cat as CollisionObject3D).get_rid()

	_configure_pixel_world()

	# Move the cat's VISUAL subtree into the pixel world, keeping Skeleton3D and
	# AnimationPlayer siblings so "../Skeleton3D" animation tracks still resolve.
	var ap: AnimationPlayer = _cat.get_node_or_null("AnimationPlayer")
	for child_name in ["Skeleton3D", "AnimationPlayer"]:
		var n: Node = _cat.get_node_or_null(child_name)
		if n:
			n.reparent(_rig, false)
	if ap:
		ap.root_node = ap.root_node  # force the mixer to re-cache track paths

	if crunch_cat_textures or flatten_cat_shading:
		_style_cat_materials()
	_mirror_sun(sun)

	_display.texture = _sub.get_texture()
	var mat := _display.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("pixel_scale", float(pixel_scale))
		mat.set_shader_parameter("color_levels", color_levels)
	_ok = true

func _configure_pixel_world() -> void:
	_sub.transparent_bg = true
	_sub.msaa_3d = Viewport.MSAA_DISABLED
	_sub.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_sub.use_taa = false
	_sub.use_debanding = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _sub.world_3d == null:
		_sub.world_3d = World3D.new()

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = ambient_energy
	_sub.world_3d.environment = env

	get_window().size_changed.connect(_resize)
	_resize()

func _resize() -> void:
	var s := get_window().size / maxi(1, pixel_scale)
	_sub.size = Vector2i(maxi(1, s.x), maxi(1, s.y))

func _mirror_sun(sun: DirectionalLight3D) -> void:
	_sub_sun.shadow_enabled = false
	if sun == null:
		_sub_sun.rotation_degrees = Vector3(-50, -40, 0)
		_sub_sun.light_energy = 0.7
		return
	_sub_sun.global_transform = Transform3D(sun.global_transform.basis, Vector3.ZERO)
	_sub_sun.light_color = sun.light_color
	# Scaled + capped so the orange cat never clips to white on faces toward the sun.
	_sub_sun.light_energy = minf(sun.light_energy * sun_energy_scale, 0.9)

func _style_cat_materials() -> void:
	for node in _rig.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i)
			if src == null:
				continue
			var dup := src.duplicate() as BaseMaterial3D
			if dup == null:
				continue
			dup.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST if crunch_cat_textures \
				else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			if flat_color:
				dup.albedo_texture = null
				dup.albedo_color = flat_color_value
				dup.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			elif unshaded_cat:
				dup.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			elif flatten_cat_shading:
				dup.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				dup.metallic = 0.0
				dup.roughness = 1.0
				dup.normal_enabled = false
				dup.rim_enabled = false
				dup.clearcoat_enabled = false
			mi.set_surface_override_material(i, dup)

func _process(delta: float) -> void:
	if not _ok:
		return

	var t := _main_cam.global_transform
	_mirror_cam.projection = _main_cam.projection
	_mirror_cam.size = _main_cam.size
	_mirror_cam.fov = _main_cam.fov
	_mirror_cam.near = _main_cam.near
	_mirror_cam.far = _main_cam.far
	_mirror_cam.keep_aspect = _main_cam.keep_aspect

	if snap_camera_to_pixels and _main_cam.projection == Camera3D.PROJECTION_ORTHOGONAL and _sub.size.y > 0:
		var wpp0 := _main_cam.size / float(_sub.size.y)
		var r := t.basis.x.normalized()
		var u := t.basis.y.normalized()
		var o := t.origin
		o += r * (round(o.dot(r) / wpp0) * wpp0 - o.dot(r))
		o += u * (round(o.dot(u) / wpp0) * wpp0 - o.dot(u))
		t.origin = o
	_mirror_cam.global_transform = t

	# Put the visual rig where the real (physics) cat is...
	_rig.global_transform = _cat.global_transform

	# ...then nudge it so its origin sits on a whole low-res pixel (hysteresis so a
	# near-still cat doesn't oscillate between two pixels).
	if snap_cat_to_pixels and _sub.size.y > 0:
		var vp_h := float(_sub.size.y)
		var wpp := _mirror_cam.size / vp_h
		if _mirror_cam.projection != Camera3D.PROJECTION_ORTHOGONAL:
			var dist := _mirror_cam.global_position.distance_to(_rig.global_position)
			wpp = 2.0 * dist * tan(deg_to_rad(_mirror_cam.fov) * 0.5) / vp_h
		var sp := _mirror_cam.unproject_position(_rig.global_position)
		if _snap_px == Vector2.INF or sp.distance_to(_snap_px) > 0.75:
			_snap_px = sp.round()
		var off := _snap_px - sp
		var b := _mirror_cam.global_transform.basis
		_rig.global_position += b.x.normalized() * (off.x * wpp) - b.y.normalized() * (off.y * wpp)

	# Occlusion: line-of-sight rays from the camera to points across the cat.
	var target := _line_of_sight()
	if hard_cut:
		target = 1.0 if target >= 0.5 else 0.0
	elif target >= 0.85:
		target = 1.0  # ignore one stray blocked ray so the dither never fires in the open
	_vis = lerp(_vis, target, clampf(delta * occlusion_smooth, 0.0, 1.0))
	if _vis > 0.995:
		_vis = 1.0
	var mat := _display.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("visibility", _vis)

func _line_of_sight() -> float:
	var world := _main_cam.get_world_3d()
	var space := world.direct_space_state if world else null
	if space == null:
		return 1.0
	var cam := _main_cam.global_position
	var clear := 0
	var pts := _sample_points()
	for p in pts:
		var q := PhysicsRayQueryParameters3D.create(cam, p)
		q.exclude = [_cat_rid]
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			clear += 1
		elif (hit.position as Vector3).distance_to(cam) >= cam.distance_to(p) - occlusion_slop:
			clear += 1  # only grazed terrain right at the target — not a real blocker
	return float(clear) / float(pts.size())

# A tight cloud over the cat's torso/head, built from its transform (so it scales
# with the cat) — NOT from the skinned mesh AABB, which Godot inflates well past
# the visible body and made rays clip the ground.
func _sample_points() -> PackedVector3Array:
	var b := _cat.global_transform.basis
	var base := _cat.global_position
	var offs := [
		Vector3(0.0, 0.25, 0.0), Vector3(0.0, 0.5, 0.0), Vector3(0.0, 0.72, 0.0),
		Vector3(0.22, 0.45, 0.0), Vector3(-0.22, 0.45, 0.0),
		Vector3(0.0, 0.45, 0.22), Vector3(0.0, 0.45, -0.22),
	]
	var pts := PackedVector3Array()
	for o in offs:
		pts.append(base + b * (o * occlusion_reach))
	return pts
