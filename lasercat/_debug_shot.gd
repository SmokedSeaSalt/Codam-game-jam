extends Node

func _ready() -> void:
	var scene = load("res://scenes/haris_level/main_3d.tscn").instantiate()
	add_child(scene)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var gm: GridMap = scene.get_node("GridMap")
	print("GridMap collision_layer=", gm.collision_layer, " collision_mask=", gm.collision_mask)
	var cat := scene.get_node("Cat")
	print("Cat collision_layer=", cat.collision_layer, " collision_mask=", cat.collision_mask)

	# Find a cell using item 14 (mountain) and item 8 (forest) and raycast into it
	var used_cells := gm.get_used_cells()
	var by_item := {}
	for c in used_cells:
		var item := gm.get_cell_item(c)
		if not by_item.has(item):
			by_item[item] = c
	print("sample cell per item: ", by_item)

	var space := scene.get_world_3d().direct_space_state
	for item_id in [8, 14, 9, 10, 7]:
		if not by_item.has(item_id):
			continue
		var cell = by_item[item_id]
		var world_pos: Vector3 = gm.map_to_local(cell)
		world_pos = gm.global_transform * world_pos
		var from := world_pos + Vector3(0, 20, 0)
		var to := world_pos + Vector3(0, -20, 0)
		var params := PhysicsRayQueryParameters3D.create(from, to)
		var hit := space.intersect_ray(params)
		print("item ", item_id, " at ", world_pos, " ray hit: ", hit)

	await get_tree().create_timer(0.2).timeout
	get_tree().quit()
