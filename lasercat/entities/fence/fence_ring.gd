extends Node3D

## A closed fence running around the whole play area, plus the invisible wall that
## actually keeps the cat and the mice inside it.
##
## The fence asset is a Sketchfab import with a huge baked scale and a rotated
## pivot, so nothing here assumes its size or orientation: one copy is instanced
## and measured at runtime, then every placed copy is scaled so its long side
## spans `segment_length` world metres and its base sits on y = 0. The barrier is
## a separate StaticBody3D of four box walls (`wall_height` tall, well above
## anything the cat can climb or pounce over) sitting on the fence line, so
## containment never depends on the visual mesh lining up perfectly.
##
## Added to the "fence" group; `contains()` is what the mice poll to tell whether
## they have slipped outside and should die + respawn.

@export var fence_scene: PackedScene = preload("res://assets/low_poly_fence.glb")
## Half the side length of the square: the fence sits at x = ±half_extent and
## z = ±half_extent. Keep it inside the ground plane and outside the navmesh.
@export var half_extent: float = 95.0
## World length each instanced fence copy is scaled to cover along its long axis.
@export var segment_length: float = 8.0
## Height of the invisible containment wall. The real barrier — make it taller
## than the cat's pounce arc so nothing gets over it.
@export var wall_height: float = 4.0
## Thickness of each containment wall box (centred on the fence line).
@export var wall_thickness: float = 1.5
## Lift every fence copy this far into the ground so the base never floats on
## uneven spots.
@export var sink: float = 0.05

func _ready() -> void:
	add_to_group("fence")
	var aabb := _measure_segment()
	if aabb.size.x <= 0.0 or aabb.size.z <= 0.0:
		push_warning("FenceRing: could not measure the fence asset; skipping visuals.")
	else:
		_build_visual(aabb)
	_build_barrier()

## True while `p` (world space) is inside the fenced square. The mice call this.
func contains(p: Vector3) -> bool:
	return absf(p.x) <= half_extent and absf(p.z) <= half_extent

# --- visual ------------------------------------------------------------------

# Instance one fence, fold every VisualInstance3D's AABB back into this node's
# local space, free it, and hand back the combined box.
func _measure_segment() -> AABB:
	var probe := fence_scene.instantiate()
	add_child(probe)
	var to_local := global_transform.affine_inverse()
	var visuals: Array[VisualInstance3D] = []
	_gather_visuals(probe, visuals)
	var box := AABB()
	var have := false
	for vi in visuals:
		var world_box: AABB = (to_local * vi.global_transform) * vi.get_aabb()
		if have:
			box = box.merge(world_box)
		else:
			box = world_box
			have = true
	remove_child(probe)
	probe.free()
	return box

func _gather_visuals(node: Node, out: Array[VisualInstance3D]) -> void:
	if node is VisualInstance3D:
		out.append(node)
	for child in node.get_children():
		_gather_visuals(child, out)

func _build_visual(aabb: AABB) -> void:
	var length_is_x: bool = aabb.size.x >= aabb.size.z
	var seg_len: float = aabb.size.x if length_is_x else aabb.size.z
	var k := segment_length / seg_len
	# Rotate the asset so its long axis lies along local +X before we scale it.
	var pre_rot := Basis.IDENTITY if length_is_x else Basis(Vector3.UP, PI * 0.5)
	var centre := aabb.position + aabb.size * 0.5
	# Recentre on the origin (long axis mid-point at x = 0, footprint mid-point at
	# z = 0) and drop the base onto y = 0, then apply pre-rotation + uniform scale.
	var recentre := Transform3D(Basis.IDENTITY, Vector3(-centre.x, -aabb.position.y, -centre.z))
	var shape := Transform3D(Basis().scaled(Vector3(k, k, k)) * pre_rot, Vector3.ZERO) * recentre

	var n := int(ceil(2.0 * half_extent / segment_length))
	var run := n * segment_length

	var sides := [
		{ "basis": Basis.IDENTITY, "along": Vector3.RIGHT, "fixed": Vector3(0, -sink, -half_extent) },
		{ "basis": Basis(Vector3.UP, PI), "along": Vector3.RIGHT, "fixed": Vector3(0, -sink, half_extent) },
		{ "basis": Basis(Vector3.UP, PI * 0.5), "along": Vector3.BACK, "fixed": Vector3(-half_extent, -sink, 0) },
		{ "basis": Basis(Vector3.UP, -PI * 0.5), "along": Vector3.BACK, "fixed": Vector3(half_extent, -sink, 0) },
	]

	var pieces := Node3D.new()
	pieces.name = "Pieces"
	add_child(pieces)
	for side in sides:
		for i in n:
			var o := -run * 0.5 + segment_length * (i + 0.5)
			var slot: Vector3 = side["fixed"] + (side["along"] as Vector3) * o
			var copy := fence_scene.instantiate()
			pieces.add_child(copy)
			copy.transform = Transform3D(side["basis"], slot) * shape

# --- barrier ---------------------------------------------------------------

func _build_barrier() -> void:
	var body := StaticBody3D.new()
	body.name = "Barrier"
	add_child(body)
	var h := wall_height
	var t := wall_thickness
	var span := 2.0 * half_extent + 2.0 * t  # overlap at the corners, no gaps
	var walls := [
		{ "size": Vector3(span, h, t), "pos": Vector3(0, h * 0.5, -half_extent) },
		{ "size": Vector3(span, h, t), "pos": Vector3(0, h * 0.5, half_extent) },
		{ "size": Vector3(t, h, span), "pos": Vector3(-half_extent, h * 0.5, 0) },
		{ "size": Vector3(t, h, span), "pos": Vector3(half_extent, h * 0.5, 0) },
	]
	for w in walls:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = w["size"]
		cs.shape = box
		cs.position = w["pos"]
		body.add_child(cs)
