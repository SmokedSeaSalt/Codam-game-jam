extends Node3D

# ---- map size ----------------------------------------------------------
@export var cols: int = 100 # tiles along X(100 * 0.5 = 50 world units)
@export var rows: int = 100 # tiles along Z
@export var tile_size: float = 0.5# smaller = finer steps; for 0.25 set cols/rows to 200
@export var level_height: float = 0.5 # world units per height level — MUST equal Cat.gd step_height

# ---- height range --------------------------------------------------
@export var max_level: int = 64 # white in the heightmap = this many levels tall.
								# an 8-bit png holds 256 grey values, so up to 255 is meaningful.
@export var max_height: float = 3 # world units from the lowest point to the tallest.
									# the whole terrain is scaled to fit this, whatever max_level says.

# ---- heightmap source --------------------------------------------
@export var heightmap_texture: Texture2D # grayscale png; black = low, white = high.
										 # cols/rows above are auto-set from its pixel size.
@export var flip_x: bool = false # mirror left/right if the terrain comes out reversed
@export var flip_z: bool = false # mirror front/back

# ---- look ----------------------------------------------------------
@export var texture: Texture2D# surface texture, e.g. res://icon.svg
@export var texture_tile_size: float = 4.0# world units per texture repeat

@onready var nav_region: NavigationRegion3D

func _bake_navigation(_mi: MeshInstance3D) -> void:
	nav_region = NavigationRegion3D.new()
	add_child(nav_region)

	var nav_mesh := NavigationMesh.new()
	# Recast voxelises the terrain collider before tracing the walkable mesh, so
	# the cells must resolve a single tile and agent_max_climb must clear the
	# per-tile rise — otherwise the stepped surface bakes into thousands of tiny
	# unclimbable ledges (which is what made pathfinding fall apart).
	nav_mesh.cell_size = tile_size              # one voxel column per terrain tile
	nav_mesh.cell_height = tile_size * 0.5
	nav_mesh.agent_radius = tile_size * 2.0     # small, so narrow ledges survive erosion
	nav_mesh.agent_max_climb = tile_size * 1.5  # ~walk <=55 deg slopes, steeper reads as wall
	nav_mesh.agent_height = 1.0
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationMeshGenerator.parse_source_geometry_data(nav_mesh, source_geometry, self)
	NavigationMeshGenerator.bake_from_source_geometry_data(nav_mesh, source_geometry)

	# The navigation MAP re-rasterises region edges at its own cell size; if that
	# doesn't match the mesh we just baked, the edges misalign and connections
	# drop out. Bring the map down to our resolution.
	var map := get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, nav_mesh.cell_size)
	NavigationServer3D.map_set_cell_height(map, nav_mesh.cell_height)

	nav_region.navigation_mesh = nav_mesh
	
var heights: Array = []
var _y_scale: float = 1.0 # multiplies every terrain Y so the peak lands on max_height

func _ready() -> void:
	heights = _build_heights()
	if heights.is_empty():
		return # no heightmap assigned / unreadable — _build_heights() already logged why
	_y_scale = _compute_y_scale()
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
func _build_heights() -> Array:
	if heightmap_texture == null:
		push_error("Terrain: no heightmap_texture assigned on the Terrain node")
		return []

	var img := heightmap_texture.get_image()
	if img == null:
		push_error("Terrain: heightmap_texture has no readable image — set its import Compress mode to Lossless")
		return []
	if img.is_compressed():
		img.decompress()

	# the world resizes to whatever png you feed it: one pixel = one tile
	cols = img.get_width()
	rows = img.get_height()

	var h: Array = []
	for z in rows:
			var row := PackedInt32Array()
			row.resize(cols)
			for x in cols:
					var sx: int = (cols - 1 - x) if flip_x else x
					var sz: int = (rows - 1 - z) if flip_z else z
					var v := img.get_pixel(sx, sz).r # 0..1 brightness; grey png -> r == g == b
					row[x] = clampi(int(round(v * max_level)), 0, max_level)
			h.append(row)
	return h

func _height_at(x: int, z: int) -> int:
	if x < 0 or x >= cols or z < 0 or z >= rows:
			return 0
	return heights[z][x]

func _compute_y_scale() -> float:
	var peak := 0
	for row in heights:
			for v in row:
					peak = maxi(peak, v)
	var raw := peak * level_height
	return (max_height / raw) if raw > 0.0 else 1.0

func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var s := tile_size
	var ox := -cols * s * 0.5 # centre the map on the origin
	var oz := -rows * s * 0.5

	for z in rows:
			for x in cols:
					var hh: int = heights[z][x]
					var y: float = hh * level_height * _y_scale
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
	var yb := nh * level_height * _y_scale
	var yt := h * level_height * _y_scale
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
