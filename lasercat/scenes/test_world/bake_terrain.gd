extends SceneTree

# Headless one-shot bake: mirrors the Terrain node's parameters from main_3d.tscn
# and calls _bake_to_disk(). Run with:
#   godot --headless --script scenes/test_world/bake_terrain.gd
#   godot --headless --script scenes/test_world/bake_terrain.gd -- 4   # downscale ×4
# In the editor, tick "Rebake Terrain" on the Terrain node instead.

var _terrain: Node3D
var _done := false

func _initialize() -> void:
	var script := load("res://scenes/test_world/heightmap.gd")
	_terrain = Node3D.new()
	_terrain.set_script(script)
	_terrain.skip_runtime_build = true
	_terrain.tile_size = 0.1
	_terrain.level_height = 0.1
	_terrain.max_level = 200
	_terrain.max_height = 3.0
	_terrain.texture_tile_size = 1.0
	_terrain.bake_downscale = 1 # matches the Terrain node in main_3d.tscn; override with `-- N`
	_terrain.heightmap_texture = load("res://scenes/test_world/heightmap_512x512.png")

	for a in OS.get_cmdline_user_args():
		if a.is_valid_int():
			_terrain.bake_downscale = a.to_int()
	print("Terrain: baking at downscale ×%d" % _terrain.bake_downscale)
	get_root().add_child(_terrain)

# Wait one frame so the node (and the temp collider the nav bake parses) are
# actually inside the tree, then bake and exit.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var start := Time.get_ticks_msec()
	_terrain._bake_to_disk()
	print("Terrain: bake took %d ms" % (Time.get_ticks_msec() - start))
	return true
