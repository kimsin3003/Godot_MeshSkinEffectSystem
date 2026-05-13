class_name MeshSurfaceSampler
extends RefCounted

const DEFAULT_MAX_SAMPLES := 8192
const DEFAULT_SEARCH_DEPTH_M := 0.8

var owner: Node3D
var local_positions := PackedVector3Array()
var local_normals := PackedVector3Array()
var max_samples := DEFAULT_MAX_SAMPLES


func rebuild(root: Node3D, sample_limit: int = DEFAULT_MAX_SAMPLES) -> void:
	owner = root
	max_samples = max(1, sample_limit)
	local_positions.clear()
	local_normals.clear()

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	if meshes.is_empty():
		return

	var total_vertices := 0
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		for surface_index in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			total_vertices += vertices.size()

	var stride: int = max(1, int(ceil(float(max(1, total_vertices)) / float(max_samples))))
	var visited: int = 0

	for mesh_instance in meshes:
		visited = _append_mesh_samples(mesh_instance, stride, visited)


func get_sample_count() -> int:
	return local_positions.size()


func estimate_memory_bytes() -> int:
	# Vector3 arrays are the dominant persistent sampler state.
	return local_positions.size() * 24


func find_outer_surface(
	physics_hit_world: Vector3,
	shot_direction_world: Vector3,
	search_radius_m: float,
	search_depth_m: float = DEFAULT_SEARCH_DEPTH_M
) -> Vector3:
	if owner == null or local_positions.is_empty():
		return physics_hit_world

	var shot_dir_world: Vector3 = shot_direction_world.normalized()
	if shot_dir_world.length_squared() <= 0.000001:
		return physics_hit_world

	var hit_local: Vector3 = owner.to_local(physics_hit_world)
	var shot_dir_local: Vector3 = (owner.global_transform.basis.inverse() * shot_dir_world).normalized()
	var best_index: int = -1
	var best_score: float = -INF
	var radius_sq: float = search_radius_m * search_radius_m
	var half_depth: float = max(search_depth_m, search_radius_m)

	for i in local_positions.size():
		var candidate: Vector3 = local_positions[i]
		var delta: Vector3 = candidate - hit_local
		var along_incoming: float = -delta.dot(shot_dir_local)
		if along_incoming < -search_radius_m or along_incoming > half_depth:
			continue

		var radial: Vector3 = delta + shot_dir_local * along_incoming
		var radial_sq: float = radial.length_squared()
		if radial_sq > radius_sq:
			continue

		var normal: Vector3 = local_normals[i]
		var facing: float = max(0.0, normal.dot(-shot_dir_local))
		var radial_penalty: float = radial_sq / max(radius_sq, 0.000001)
		var score: float = along_incoming + facing * 0.08 - radial_penalty * 0.03
		if score > best_score:
			best_score = score
			best_index = i

	if best_index < 0:
		return physics_hit_world

	return owner.to_global(local_positions[best_index])


func _collect_meshes(node: Node, out_meshes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		out_meshes.append(node)

	for child in node.get_children():
		_collect_meshes(child, out_meshes)


func _append_mesh_samples(mesh_instance: MeshInstance3D, stride: int, visited: int) -> int:
	var mesh := mesh_instance.mesh
	if mesh == null:
		return visited

	var to_owner: Transform3D = owner.global_transform.affine_inverse() * mesh_instance.global_transform

	for surface_index in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue

		var normals := PackedVector3Array()
		if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			normals = arrays[Mesh.ARRAY_NORMAL]

		for vertex_index in vertices.size():
			if local_positions.size() >= max_samples:
				return visited
			if visited % stride != 0:
				visited += 1
				continue

			var local_pos := to_owner * vertices[vertex_index]
			var local_normal := Vector3.UP
			if vertex_index < normals.size():
				local_normal = (to_owner.basis * normals[vertex_index]).normalized()

			local_positions.append(local_pos)
			local_normals.append(local_normal)
			visited += 1

	return visited
