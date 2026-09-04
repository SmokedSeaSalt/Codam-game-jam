extends MeshInstance3D

## Keeps the blob pinned flat on the ground so it doesn't ride up when its parent
## jumps / pounces / bobs. X and Z still follow the parent.

@export var ground_y: float = 0.03

func _process(_delta: float) -> void:
	global_position.y = ground_y
