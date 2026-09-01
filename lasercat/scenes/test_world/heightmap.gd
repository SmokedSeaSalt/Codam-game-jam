extends Node3D

# ---- map size ----------------------------------------------------------
@export var cols: int = 100 # tiles along X(100 * 0.5 = 50 world units)
@export var rows: int = 100 # tiles along Z
@export var tile_size: float = 0.5# smaller = finer steps; for 0.25 set cols/rows to 200
@export var level_height: float = 0.5 # world units per height level — MUST equal Cat.gd step_height

# ---- hill shape ------------------------------------------------------
@export var max_level: int = 8# height at the hill corner
@export var run: float = 6.0# tiles travelled per one level of drop (bigger = gentler)
@export_enum("Square", "Rounded", "Diagonal") var contour: int = 0

# ---- look ----------------------------------------------------------
@export var texture: Texture2D# e.g. res://icon.svg
@export var texture_tile_size: float = 4.0# world units per texture repeat

@export var noise_seed: int = 1337
@export var contour_warp: float = 20.0# tiles — how much the terrace edges wander
@export var roughness: float = 3.0# levels of high-frequency bumpiness
@export var hill_noise_freq: float = 0.01 # lower = broader lumps in the outline
@export var rough_noise_freq: float = 0.08# higher = finer grain on surfaces
@export var peak_shape: float = 1.0 # 1 = rounded dome; >1 sharper peak; <1 flatter top

@onready var nav_region: NavigationRegion3D

func _bake_navigation(_mi: MeshInstance3D) -> void:
	nav_region = NavigationRegion3D.new()
	add_child(nav_region)

	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_max_climb = level_height * 3 + 0.05
	nav_mesh.agent_radius = 0.3
	nav_mesh.agent_height = 1.0
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationMeshGenerator.parse_source_geometry_data(nav_mesh, source_geometry, self)
	NavigationMeshGenerator.bake_from_source_geometry_data(nav_mesh, source_geometry)

	nav_region.navigation_mesh = nav_mesh
	
var heights: Array = []

func _ready() -> void:
	_init_noise()
	heights = _build_heights()
	var mesh := _build_mesh()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _build_material()
	add_child(mi)

	var body := StaticBody3D.new()
	add_child(body)
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	
	#because level is generated runtime, baking needs to be runtime as well
	_bake_navigation(mi) 

# --------------------------------------------------------------------
var _n_hill := FastNoiseLite.new()
var _n_rough := FastNoiseLite.new()

func _init_noise() -> void:
	_n_hill.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_hill.frequency = hill_noise_freq
	_n_hill.seed = noise_seed
	_n_rough.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_rough.frequency = rough_noise_freq
	_n_rough.seed = noise_seed + 1
	
func _build_heights() -> Array:
	var h: Array = []
	for z in rows:
			var row := PackedInt32Array()
			row.resize(cols)
			for x in cols:
					var cx := float(x)
					var cz := float((rows - 1) - z)# corner (0, rows-1) = screen-left

					var dist: float
					match contour:
							0: dist = maxf(cx, cz)
							1: dist = Vector2(cx, cz).length()
							_: dist = cx + cz
					dist += _n_hill.get_noise_2d(x, z) * contour_warp # organic, rounded edges

					var reach := float(max_level) * run
					var t := clampf(1.0 - dist / reach, 0.0, 1.0)
					var base := float(max_level) * pow(smoothstep(0.0, 1.0, t), peak_shape)

					var rough := _n_rough.get_noise_2d(x, z) * roughness

					row[x] = clampi(int(round(base + rough)), 0, max_level)
			h.append(row)
	return h

func _height_at(x: int, z: int) -> int:
	if x < 0 or x >= cols or z < 0 or z >= rows:
			return 0
	return heights[z][x]

func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var s := tile_size
	var ox := -cols * s * 0.5 # centre the map on the origin
	var oz := -rows * s * 0.5

	for z in rows:
			for x in cols:
					var hh: int = heights[z][x]
					var y: float = hh * level_height
					var x0 := ox + x * s
					var x1 := ox + (x + 1) * s
					var z0 := oz + z * s
					var z1 := oz + (z + 1) * s

					_quad(st, Vector3(x0, y, z0), Vector3(x1, y, z0),
										Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP)

					_wall(st, hh, _height_at(x - 1, z), Vector3(x0, 0, z1), Vector3(x0, 0, z0), Vector3.LEFT)
					_wall(st, hh, _height_at(x + 1, z), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3.RIGHT)
					_wall(st, hh, _height_at(x, z - 1), Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3.FORWARD)
					_wall(st, hh, _height_at(x, z + 1), Vector3(x1, 0, z1), Vector3(x0, 0, z1), Vector3.BACK)

	return st.commit()

func _wall(st: SurfaceTool, h: int, nh: int, a: Vector3, b: Vector3, n: Vector3) -> void:
	if nh >= h:
			return
	var yb := nh * level_height
	var yt := h * level_height
	_quad(st, Vector3(a.x, yb, a.z), Vector3(b.x, yb, b.z),
						Vector3(b.x, yt, b.z), Vector3(a.x, yt, a.z), n)

func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3) -> void:
	for v in [p0, p1, p2, p0, p2, p3]:
			st.set_normal(n)
			st.add_vertex(v)

func _build_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED # no face can vanish regardless of winding
	if texture:
			mat.albedo_texture = texture
			mat.uv1_triplanar = true
			mat.uv1_world_triplanar = true # projects the texture from world axes
			mat.uv1_scale = Vector3.ONE / texture_tile_size
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS# LINEAR_… for soft
	else:
			mat.albedo_color = Color(0.4, 0.6, 0.35)
	return mat
