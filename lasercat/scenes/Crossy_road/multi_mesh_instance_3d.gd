extends MultiMeshInstance3D

@export var road_piece_mesh: Mesh
@export var map_length: float = 200.0
@export var axis: Vector3 = Vector3(0, 1, 0)

func _ready() -> void:
	if not road_piece_mesh:
		return
	var piece_size := road_piece_mesh.get_aabb().size
	var piece_length: float = absf(piece_size.x * axis.x + piece_size.y * axis.y + piece_size.z * axis.z)
	if piece_length <= 0.0:
		return
	var count := int(ceil(map_length / piece_length))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = road_piece_mesh
	mm.instance_count = count
	for i in count:
		mm.set_instance_transform(i, Transform3D(Basis(), axis * piece_length * i))
	multimesh = mm
