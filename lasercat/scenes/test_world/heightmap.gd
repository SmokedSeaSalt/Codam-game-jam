@tool
extends Node3D

# The terrain mesh, its trimesh collider and the navigation mesh are expensive to
# build — several seconds native, far worse under WASM on itch.io. So they are
# baked ONCE in the editor and shipped as binary .res files:
#
#   1. Open scenes/test_world/main_3d.tscn, select the Terrain node.
#   2. Tick "Rebake Terrain" in the inspector (Bake group). It writes
#      scenes/test_world/baked/{terrain_mesh,terrain_collision,terrain_navmesh}.res
#   3. Commit those files.
#
# At runtime _ready() just loads them. If they are missing it falls back to
# generating everything on the fly (with a warning) so the scene still runs.
# Re-bake whenever the heightmap image or any generation parameter below changes.

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

# ---- bake --------------------------------------------------------------
@export_group("Bake")
## Tick in the editor to regenerate the baked .res files from the current
## heightmap and parameters. Unticks itself once the bake finishes.
@export var rebake_terrain: bool = false:
	set(value):
		rebake_terrain = false
		if value and Engine.is_editor_hint():
			call_deferred("_bake_to_disk")
## Downsample the heightmap by this integer factor before meshing (block-max, so
## ledges survive). 1 = full resolution. World size is held constant by scaling
## the tile up to match. Raise this if the baked .res files are too big for a
## web build — a noisy heightmap barely benefits from greedy meshing otherwise.
@export_range(1, 16, 1) var bake_downscale: int = 1

const BAKE_DIR := "res://scenes/test_world/baked"
const BAKED_MESH := BAKE_DIR + "/terrain_mesh.res"
const BAKED_COLLISION := BAKE_DIR + "/terrain_collision.res"
const BAKED_NAVMESH := BAKE_DIR + "/terrain_navmesh.res"
const BAKED_INFO := BAKE_DIR + "/terrain_bake.info" # signature to catch stale bakes in dev builds

var nav_region: NavigationRegion3D

var heights: Array = []
var _y_scale: float = 1.0 # multiplies every terrain Y so the peak lands on max_height
var _eff_tile: float = 0.0 # tile_size after bake_downscale; set by _build_heights()
var skip_runtime_build: bool = false # set by the headless bake runner so _ready() doesn't also generate

# ======================================================================
#  Startup
# ======================================================================
func _ready() -> void:
	if Engine.is_editor_hint() or skip_runtime_build:
		return
	if _baked_data_present():
		_load_baked()
	else:
		push_warning("Terrain: no baked data in %s — generating at runtime (slow, especially on web). Select the Terrain node and tick 'Rebake Terrain', then commit the .res files." % BAKE_DIR)
		_generate_runtime()

func _baked_data_present() -> bool:
	return ResourceLoader.exists(BAKED_MESH) \
		and ResourceLoader.exists(BAKED_COLLISION) \
		and ResourceLoader.exists(BAKED_NAVMESH)

# Fast path: load the pre-baked resources and wire up the nodes. No SurfaceTool,
# no trimesh build, no Recast.
func _load_baked() -> void:
	var mesh := load(BAKED_MESH) as ArrayMesh
	var shape := load(BAKED_COLLISION) as Shape3D
	var nav_mesh := load(BAKED_NAVMESH) as NavigationMesh
	if mesh == null or shape == null or nav_mesh == null:
		push_warning("Terrain: baked data failed to load — falling back to runtime generation.")
		_generate_runtime()
		return

	_spawn_mesh(mesh)
	_spawn_body(shape)
	_spawn_nav(nav_mesh)

	if OS.is_debug_build() and FileAccess.file_exists(BAKED_INFO):
		var stored := FileAccess.get_file_as_string(BAKED_INFO).strip_edges()
		if stored != _current_signature():
			push_warning("Terrain: baked data looks stale (heightmap or parameters changed since the last bake). Re-bake the Terrain node.")

# Fallback path: the old behaviour, kept so a missing bake never hard-stops.
func _generate_runtime() -> void:
	heights = _build_heights()
	if heights.is_empty():
		return # _build_heights() already logged why
	_y_scale = _compute_y_scale()

	var mesh := _build_mesh()
	_spawn_mesh(mesh)
	_spawn_body(mesh.create_trimesh_shape())

	var nav_mesh := _make_navmesh()
	_bake_navmesh_from_scene(nav_mesh) # parses the collider we just spawned
	_sync_nav_map(nav_mesh)
	nav_region = NavigationRegion3D.new()
	nav_region.name = "TerrainNav"
	add_child(nav_region)
	nav_region.navigation_mesh = nav_mesh

# ---- shared node construction ----------------------------------------
func _spawn_mesh(mesh: ArrayMesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh
	mi.material_override = _build_material()
	add_child(mi)

func _spawn_body(shape: Shape3D) -> void:
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	add_child(body)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

func _spawn_nav(nav_mesh: NavigationMesh) -> void:
	_sync_nav_map(nav_mesh) # match the map's cell size to the mesh BEFORE it's assigned
	nav_region = NavigationRegion3D.new()
	nav_region.name = "TerrainNav"
	add_child(nav_region)
	nav_region.navigation_mesh = nav_mesh # pre-baked polygons; no Recast here

# The navigation MAP re-rasterises region edges at its own cell size; if that
# doesn't match the mesh we baked, the edges misalign and connections drop out.
func _sync_nav_map(nav_mesh: NavigationMesh) -> void:
	var map := get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(map, nav_mesh.cell_size)
	NavigationServer3D.map_set_cell_height(map, nav_mesh.cell_height)

# ======================================================================
#  Editor bake
# ======================================================================
func _bake_to_disk() -> void:
	heights = _build_heights()
	if heights.is_empty():
		push_error("Terrain: bake aborted — heightmap unreadable.")
		return
	_y_scale = _compute_y_scale()

	var mesh := _build_mesh()
	var shape := mesh.create_trimesh_shape()

	# Recast parses colliders under `self`, so the shape has to be in the tree.
	var tmp_body := StaticBody3D.new()
	var tmp_cs := CollisionShape3D.new()
	tmp_cs.shape = shape
	tmp_body.add_child(tmp_cs)
	add_child(tmp_body)

	var nav_mesh := _make_navmesh()
	_bake_navmesh_from_scene(nav_mesh)

	remove_child(tmp_body)
	tmp_body.queue_free()

	if not DirAccess.dir_exists_absolute(BAKE_DIR):
		DirAccess.make_dir_recursive_absolute(BAKE_DIR)

	var e1 := ResourceSaver.save(mesh, BAKED_MESH)
	var e2 := ResourceSaver.save(shape, BAKED_COLLISION)
	var e3 := ResourceSaver.save(nav_mesh, BAKED_NAVMESH)
	var info := FileAccess.open(BAKED_INFO, FileAccess.WRITE)
	if info:
		info.store_string(_current_signature())
		info.close()

	if e1 == OK and e2 == OK and e3 == OK:
		var vtx := mesh.surface_get_array_len(0)
		var tris := mesh.surface_get_array_index_len(0) / 3
		print("Terrain: baked to %s  (%d verts, %d tris, %d nav polys)" % [
			BAKE_DIR, vtx, tris, nav_mesh.get_polygon_count()])
	else:
		push_error("Terrain: bake save failed (mesh=%d collision=%d nav=%d)" % [e1, e2, e3])

func _bake_navmesh_from_scene(nav_mesh: NavigationMesh) -> void:
	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	NavigationMeshGenerator.parse_source_geometry_data(nav_mesh, source_geometry, self)
	NavigationMeshGenerator.bake_from_source_geometry_data(nav_mesh, source_geometry)

# Recast voxelises the terrain collider before tracing the walkable mesh, so the
# cells must resolve a single tile and agent_max_climb must clear the per-tile
# rise — otherwise the stepped surface bakes into thousands of tiny unclimbable
# ledges (which is what made pathfinding fall apart).
#
# cell_size / agent_max_climb track the effective tile (coarser tiles => bigger
# voxels and a steeper rise between them). agent_radius / agent_height describe
# the CAT, not the tessellation, so they stay fixed — scaling agent_radius with
# bake_downscale erodes the whole navmesh away and the cat can't path anywhere.
func _make_navmesh() -> NavigationMesh:
	var t := _eff_tile if _eff_tile > 0.0 else tile_size
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = t                      # one voxel column per terrain tile
	nav_mesh.cell_height = t * 0.5
	nav_mesh.agent_radius = maxf(tile_size * 4.0, t)  # cat clearance; never below one voxel
	nav_mesh.agent_max_climb = t * 1.5        # ~walk <=55 deg slopes, steeper reads as wall
	nav_mesh.agent_height = 1.0
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	return nav_mesh

# Everything that, if changed, invalidates a bake. Written next to the .res files
# and compared on load in debug builds.
func _current_signature() -> String:
	if heightmap_texture == null:
		return "noimg"
	var img := heightmap_texture.get_image()
	if img == null:
		return "noimg"
	if img.is_compressed():
		img.decompress()
	return "%d|%d|%s|%s|%d|%s|%s|%s|%d|%d" % [
		img.get_width(), img.get_height(), tile_size, level_height,
		max_level, max_height, flip_x, flip_z, bake_downscale, _img_checksum(img)]

# Cheap strided checksum — enough to notice the heightmap image changed, not a
# cryptographic digest. (PackedByteArray has no .hash() in 4.x.)
func _img_checksum(img: Image) -> int:
	var data := img.get_data()
	var acc := 2166136261
	var i := 0
	var n := data.size()
	while i < n:
		acc = ((acc ^ data[i]) * 16777619) & 0x7FFFFFFF
		i += 7
	return acc

# ======================================================================
#  Heightfield
# ======================================================================
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
	var full_cols := img.get_width()
	var full_rows := img.get_height()

	var full: Array = []
	for z in full_rows:
			var row := PackedInt32Array()
			row.resize(full_cols)
			for x in full_cols:
					var sx: int = (full_cols - 1 - x) if flip_x else x
					var sz: int = (full_rows - 1 - z) if flip_z else z
					var v := img.get_pixel(sx, sz).r # 0..1 brightness; grey png -> r == g == b
					row[x] = clampi(int(round(v * max_level)), 0, max_level)
			full.append(row)

	var ds := clampi(bake_downscale, 1, 16)
	if ds == 1:
		cols = full_cols
		rows = full_rows
		_eff_tile = tile_size
		return full

	# Block-max downsample: keep the tallest tile in each ds×ds block so ledges
	# the cat can stand on don't drop out. Tile grows by ds to hold world size.
	cols = full_cols / ds
	rows = full_rows / ds
	_eff_tile = tile_size * ds
	var h: Array = []
	for z in rows:
			var row := PackedInt32Array()
			row.resize(cols)
			for x in cols:
					var best := 0
					for bz in ds:
							var fr: PackedInt32Array = full[z * ds + bz]
							for bx in ds:
									best = maxi(best, fr[x * ds + bx])
					row[x] = best
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

# ======================================================================
#  Mesh (greedy)
# ======================================================================
# Coplanar tiles of equal height are merged into big rectangles instead of one
# quad per tile, and wall faces are merged into runs. On a terrain with any flat
# regions this cuts vertex/triangle count by an order of magnitude — which speeds
# up the bake, the collider, the render, and the .pck download.
func _build_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()

	var s := _eff_tile
	var ox := -cols * s * 0.5 # centre the map on the origin
	var oz := -rows * s * 0.5

	_greedy_tops(verts, norms, indices, s, ox, oz)
	_greedy_walls(verts, norms, indices, s, ox, oz)

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

func _add_quad(verts: PackedVector3Array, norms: PackedVector3Array, indices: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3) -> void:
	var base := verts.size()
	verts.push_back(p0)
	verts.push_back(p1)
	verts.push_back(p2)
	verts.push_back(p3)
	for _i in 4:
		norms.push_back(n)
	indices.push_back(base)
	indices.push_back(base + 1)
	indices.push_back(base + 2)
	indices.push_back(base)
	indices.push_back(base + 2)
	indices.push_back(base + 3)

# Merge equal-height tiles: grow a rectangle in +X, then in +Z while the whole
# span stays at the same height, emit one top quad, mark the span consumed.
func _greedy_tops(verts: PackedVector3Array, norms: PackedVector3Array, indices: PackedInt32Array,
		s: float, ox: float, oz: float) -> void:
	var used := PackedByteArray()
	used.resize(cols * rows) # zero-filled

	for z in rows:
		for x in cols:
			if used[z * cols + x] == 1:
				continue
			var h: int = heights[z][x]

			var w := 1
			while x + w < cols and used[z * cols + x + w] == 0 and heights[z][x + w] == h:
				w += 1

			var d := 1
			var extend := true
			while z + d < rows and extend:
				for k in w:
					var xx := x + k
					if used[(z + d) * cols + xx] == 1 or heights[z + d][xx] != h:
						extend = false
						break
				if extend:
					d += 1

			for dz in d:
				var row_base := (z + dz) * cols
				for dx in w:
					used[row_base + x + dx] = 1

			var y: float = h * level_height * _y_scale
			var x0 := ox + x * s
			var x1 := ox + (x + w) * s
			var z0 := oz + z * s
			var z1 := oz + (z + d) * s
			_add_quad(verts, norms, indices,
				Vector3(x0, y, z0), Vector3(x1, y, z0),
				Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP)

# One vertical face wherever a tile is taller than a neighbour, merged along the
# shared edge while both the tile height and the neighbour height stay equal.
func _greedy_walls(verts: PackedVector3Array, norms: PackedVector3Array, indices: PackedInt32Array,
		s: float, ox: float, oz: float) -> void:
	var ys := level_height * _y_scale

	# LEFT / RIGHT faces: fixed X edge, runs merge along Z.
	for x in cols:
		var z := 0
		while z < rows:
			var h: int = heights[z][x]
			var nh: int = _height_at(x - 1, z)
			if nh >= h:
				z += 1
				continue
			var run := 1
			while z + run < rows and heights[z + run][x] == h and _height_at(x - 1, z + run) == nh:
				run += 1
			var xw := ox + x * s
			var z0 := oz + z * s
			var z1 := oz + (z + run) * s
			_add_quad(verts, norms, indices,
				Vector3(xw, nh * ys, z1), Vector3(xw, nh * ys, z0),
				Vector3(xw, h * ys, z0), Vector3(xw, h * ys, z1), Vector3.LEFT)
			z += run

	for x in cols:
		var z := 0
		while z < rows:
			var h: int = heights[z][x]
			var nh: int = _height_at(x + 1, z)
			if nh >= h:
				z += 1
				continue
			var run := 1
			while z + run < rows and heights[z + run][x] == h and _height_at(x + 1, z + run) == nh:
				run += 1
			var xw := ox + (x + 1) * s
			var z0 := oz + z * s
			var z1 := oz + (z + run) * s
			_add_quad(verts, norms, indices,
				Vector3(xw, nh * ys, z0), Vector3(xw, nh * ys, z1),
				Vector3(xw, h * ys, z1), Vector3(xw, h * ys, z0), Vector3.RIGHT)
			z += run

	# FORWARD / BACK faces: fixed Z edge, runs merge along X.
	for z in rows:
		var x := 0
		while x < cols:
			var h: int = heights[z][x]
			var nh: int = _height_at(x, z - 1)
			if nh >= h:
				x += 1
				continue
			var run := 1
			while x + run < cols and heights[z][x + run] == h and _height_at(x + run, z - 1) == nh:
				run += 1
			var zw := oz + z * s
			var x0 := ox + x * s
			var x1 := ox + (x + run) * s
			_add_quad(verts, norms, indices,
				Vector3(x0, nh * ys, zw), Vector3(x1, nh * ys, zw),
				Vector3(x1, h * ys, zw), Vector3(x0, h * ys, zw), Vector3.FORWARD)
			x += run

	for z in rows:
		var x := 0
		while x < cols:
			var h: int = heights[z][x]
			var nh: int = _height_at(x, z + 1)
			if nh >= h:
				x += 1
				continue
			var run := 1
			while x + run < cols and heights[z][x + run] == h and _height_at(x + run, z + 1) == nh:
				run += 1
			var zw := oz + (z + 1) * s
			var x0 := ox + x * s
			var x1 := ox + (x + run) * s
			_add_quad(verts, norms, indices,
				Vector3(x1, nh * ys, zw), Vector3(x0, nh * ys, zw),
				Vector3(x0, h * ys, zw), Vector3(x1, h * ys, zw), Vector3.BACK)
			x += run

# ======================================================================
#  Material
# ======================================================================
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
