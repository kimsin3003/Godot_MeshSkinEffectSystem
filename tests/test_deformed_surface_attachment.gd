extends SceneTree

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")


class DeformProvider:
	extends Node

	var lift := 0.0

	func resolve_surface_vertex_world(
		mesh_instance: MeshInstance3D,
		_surface_index: int,
		vertex_index: int,
		base_position: Vector3
	) -> Vector3:
		var position := base_position
		if vertex_index == 2:
			position.z += lift
		return mesh_instance.to_global(position)


var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root := Node3D.new()
	get_root().add_child(root)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _create_triangle_mesh()
	root.add_child(mesh_instance)

	var provider := DeformProvider.new()
	get_root().add_child(provider)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.deformation_provider = provider
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var attached_world := accumulator.add_surface_effect_at_triangle(
		12,
		mesh_instance,
		0,
		PackedInt32Array([0, 1, 2]),
		Vector3.ONE / 3.0,
		Vector3.FORWARD,
		0.1,
		1.0
	)
	var local_before := _first_event_center(mesh_instance)
	_assert(local_before.distance_to(root.to_local(attached_world)) < 0.001, "deformed event initialized at wrong position")

	provider.lift = 0.6
	for frame in 3:
		await process_frame

	var local_after := _first_event_center(mesh_instance)
	var delta := local_before.distance_to(local_after)
	_assert(abs(local_after.z - 0.2) < 0.001, "deformed event did not follow provider vertex position")
	_assert(delta > 0.19, "deformed event did not move enough")

	print("deformed_surface_attachment: delta=%.3f before=%s after=%s" % [
		delta,
		str(local_before),
		str(local_after),
	])

	root.queue_free()
	provider.queue_free()
	accumulator.queue_free()
	for frame in 3:
		await process_frame
	quit(1 if failed else 0)


func _create_triangle_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(0, 1, 0),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, StandardMaterial3D.new())
	return mesh


func _first_event_center(mesh_instance: MeshInstance3D) -> Vector3:
	var material := mesh_instance.get_surface_override_material(0) as ShaderMaterial
	_assert(material != null, "deformed test material was not rebound")
	var spheres: PackedVector4Array = material.get_shader_parameter("impact_spheres")
	_assert(not spheres.is_empty(), "deformed event uniform was not pushed")
	return Vector3(spheres[0].x, spheres[0].y, spheres[0].z)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	failed = true
