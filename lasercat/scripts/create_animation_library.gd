@tool
extends EditorScript

func _run():
	var folder = "res://entities/cat/Animations/"   # folder with your fbx files
	var output_path = "res://animations/merged_library.res"
	var merged_lib = AnimationLibrary.new()

	var dir = DirAccess.open(folder)
	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		if file_name.ends_with(".fbx"):
			var scene_path = folder + file_name
			var packed_scene = load(scene_path)
			var instance = packed_scene.instantiate()
			var anim_player = _find_animation_player(instance)

			if anim_player:
				for lib_name in anim_player.get_animation_library_list():
					var lib = anim_player.get_animation_library(lib_name)
					for anim_name in lib.get_animation_list():
						var anim = lib.get_animation(anim_name)
						var clean_name = file_name.get_basename()  # use filename as anim name
						merged_lib.add_animation(clean_name, anim)
						print("Added animation: ", clean_name)
			instance.queue_free()
		file_name = dir.get_next()

	var err = ResourceSaver.save(merged_lib, output_path)
	if err == OK:
		print("Saved merged library to ", output_path)
	else:
		print("Failed to save: ", err)

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result = _find_animation_player(child)
		if result:
			return result
	return null
