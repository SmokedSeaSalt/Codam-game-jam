extends Node3D

## Scatters thousands of grass "cards" (crossed alpha-cut quads) across a square
## patch centred on the origin, mixing the five clump textures from the
## realistic-grass-pack. One MultiMeshInstance3D per grass type — each is a single
## draw call — so the whole field is cheap even at high counts. The ground plane
## keeps its own grass texture; these are the tufts standing on top of it.
##
## The .blend meshes in that pack need Blender 3.6+ to import (this project only
## has 3.0), so the cards are built here from the pack's diffuse+opacity PNGs,
## which import fine on their own.

const TEX_DIR := "res://assets/grass_medium_02_4k.blend/textures/realistic-grass-pack-for-games-free/textures/"

# diffuse+opacity PNG, matching normal map, and how much of the total to make this type.
const GRASS_TYPES := [
	{ "diff": "Grass_Clumps_A_png-Grass_Clumps_A_Opacity_png.png", "norm": "Grass_Clumps_A_Normal.png", "weight": 3.0 },
	{ "diff": "Grass_Clumps_B_png-Grass_Clumps_B_Opacity_png.png", "norm": "Grass_Clumps_B_Normal.png", "weight": 3.0 },
	{ "diff": "Grass_Clumps_C_2_png-Grass_Clumps_C_3_png.png",     "norm": "Grass_Clumps_C_Normal.png", "weight": 2.0 },
	{ "diff": "WheatGrass_Clump_Diffuse-WheatGrass_Clump_Opacity.png", "norm": "WheatGrass_Clump_Normal.png", "weight": 1.5 },
	{ "diff": "WheatGrass_Diffuse-WheatGrass_Opacity.png",         "norm": "WheatGrass_Normal_Normal.png", "weight": 1.5 },
]

@export var area_size: float = 160.0                 # grass fills a square this wide, centred on the origin
@export var total_instances: int = 50000             # split across the types by weight
@export var card_size: float = 0.75                  # width & height of one grass card, before per-instance scale
@export var scale_range: Vector2 = Vector2(0.6, 1.7) # random uniform scale per clump
@export var tilt_max_deg: float = 7.0                # random lean off vertical
@export var clear_radius: float = 2.0                # keep a bare patch at the spawn point
@export var random_seed: int = 0                     # 0 = different every run; non-zero = fixed layout
@export var cast_shadows: bool = false               # thousands of shadow casters is pricey on GL compat
@export var alpha_scissor_threshold: float = 0.33

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	if random_seed != 0:
		rng.seed = random_seed
	else:
		rng.randomize()

	var total_weight := 0.0
	for t in GRASS_TYPES:
		total_weight += t["weight"]

	var mesh := _make_card_mesh(card_size)
	var half := area_size * 0.5
	var clear_sq := clear_radius * clear_radius

	for ti in GRASS_TYPES.size():
		var t: Dictionary = GRASS_TYPES[ti]
		var count := int(round(total_instances * float(t["weight"]) / total_weight))
		if count <= 0:
			continue

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = count

		for i in count:
			var pos := Vector3.ZERO
			for _attempt in 4:
				pos = Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half))
				if pos.x * pos.x + pos.z * pos.z >= clear_sq:
					break

			var b := Basis(Vector3.UP, rng.randf_range(0.0, TAU))
			if tilt_max_deg > 0.0:
				var td := rng.randf_range(0.0, TAU)
				b = Basis(Vector3(cos(td), 0.0, sin(td)), deg_to_rad(rng.randf_range(0.0, tilt_max_deg))) * b
			var s := rng.randf_range(scale_range.x, scale_range.y)
			b = b.scaled(Vector3(s, s * rng.randf_range(0.85, 1.2), s))

			mm.set_instance_transform(i, Transform3D(b, pos))
			mm.set_instance_color(i, _tint(rng))

		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Grass_%d" % ti
		mmi.multimesh = mm
		mmi.material_override = _make_card_material(
			load(TEX_DIR + t["diff"]) as Texture2D,
			load(TEX_DIR + t["norm"]) as Texture2D)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)

# Two vertical quads crossed at 90°, pivot at the base so scaling grows the clump
# upward from the ground. cull_mode is disabled on the material, so all four faces
# show and no billboarding is needed at this camera angle.
func _make_card_mesh(size: float) -> ArrayMesh:
	var w := size * 0.5
	var h := size
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	for q in [
		{ "right": Vector3(1, 0, 0), "n": Vector3(0, 0, 1) },
		{ "right": Vector3(0, 0, -1), "n": Vector3(1, 0, 0) },
	]:
		var r: Vector3 = q["right"] * w
		var n: Vector3 = q["n"]
		var base := verts.size()
		verts.push_back(-r)
		verts.push_back(r)
		verts.push_back(Vector3(0.0, h, 0.0) + r)
		verts.push_back(Vector3(0.0, h, 0.0) - r)
		for _k in 4:
			norms.push_back(n)
		uvs.push_back(Vector2(0.0, 1.0))
		uvs.push_back(Vector2(1.0, 1.0))
		uvs.push_back(Vector2(1.0, 0.0))
		uvs.push_back(Vector2(0.0, 0.0))
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

func _make_card_material(diff: Texture2D, norm: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = diff
	# Alpha-scissor keeps the cutout crisp and shadow-castable; alpha-to-coverage
	# then dithers that hard edge across the MSAA subsamples so it isn't a jagged
	# stair-step. Anisotropic mip filtering kills the shimmer on the blades at a
	# distance. Together with the project's MSAA + FXAA this is what stops the
	# grass from crawling.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = alpha_scissor_threshold
	mat.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	mat.alpha_antialiasing_edge = 0.15
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true  # MultiMesh per-instance colour tints the clump
	if norm:
		mat.normal_enabled = true
		mat.normal_texture = norm
	return mat

# Subtle per-clump variation: random brightness plus a small warm/cool shift.
func _tint(rng: RandomNumberGenerator) -> Color:
	var b := rng.randf_range(0.72, 1.08)
	var warm := rng.randf_range(-0.06, 0.12)
	return Color(
		clampf(b + warm, 0.0, 1.3),
		clampf(b, 0.0, 1.3),
		clampf(b - warm * 0.6, 0.0, 1.3))
