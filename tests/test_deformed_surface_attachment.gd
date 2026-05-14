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

	provider.lift = 0.6
	var attached_world := accumulator.add_surface_effect_at_triangle(
		2,
		mesh_instance,
		0,
		PackedInt32Array([0, 1, 2]),
		Vector3.ONE / 3.0,
		Vector3.FORWARD,
		0.1,
		1.0
	)
	var visual_before := root.to_local(attached_world)
	var rest_center := _custom_rest_center_local(mesh_instance)
	var volume_before := accumulator.sample_effect_volume_local(rest_center)
	_assert(abs(visual_before.z - 0.2) < 0.001, "deformation provider did not resolve the visual hit position")
	_assert(volume_before.g > 0.1, "deformed event was not accumulated at the rest-space triangle position")
	_assert(_uses_rest_volume_position(mesh_instance), "deformed test material is not sampling rest-space volume coordinates")

	_deform_mesh_preserving_rest_attributes(mesh_instance, provider.lift)
	for frame in 3:
		await process_frame

	var visual_after := _visual_triangle_center_local(mesh_instance)
	var rest_after := _custom_rest_center_local(mesh_instance)
	var volume_after := accumulator.sample_effect_volume_local(rest_after)
	var visual_rest_delta := visual_after.distance_to(rest_after)
	_assert(abs(visual_after.z - 0.2) < 0.001, "runtime mesh deformation was not applied to the visual triangle")
	_assert(rest_after.distance_to(rest_center) < 0.001, "runtime mesh deformation changed the rest-space sampling coordinate")
	_assert(volume_after.g > 0.1, "rest-space volume event did not survive runtime mesh deformation")

	print("deformed_surface_attachment: visual_z=%.3f rest_z=%.3f volume_g=%.3f visual_rest_delta=%.3f" % [
		visual_after.z,
		rest_after.z,
		volume_after.g,
		visual_rest_delta,
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


func _deform_mesh_preserving_rest_attributes(mesh_instance: MeshInstance3D, lift: float) -> void:
	var source_mesh := mesh_instance.mesh
	var arrays := source_mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	vertices[2].z += lift
	arrays[Mesh.ARRAY_VERTEX] = vertices

	var mesh := ArrayMesh.new()
	var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	mesh.surface_set_material(0, source_mesh.surface_get_material(0))
	mesh_instance.mesh = mesh


func _visual_triangle_center_local(mesh_instance: MeshInstance3D) -> Vector3:
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return (vertices[0] + vertices[1] + vertices[2]) / 3.0


func _custom_rest_center_local(mesh_instance: MeshInstance3D) -> Vector3:
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	var rest_positions: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	_assert(rest_positions.size() >= 12, "rest-space custom attribute was not generated")
	var p0 := Vector3(rest_positions[0], rest_positions[1], rest_positions[2])
	var p1 := Vector3(rest_positions[4], rest_positions[5], rest_positions[6])
	var p2 := Vector3(rest_positions[8], rest_positions[9], rest_positions[10])
	return (p0 + p1 + p2) / 3.0


func _uses_rest_volume_position(mesh_instance: MeshInstance3D) -> bool:
	var material := mesh_instance.get_surface_override_material(0) as ShaderMaterial
	_assert(material != null, "deformed test material was not rebound")
	return bool(material.get_shader_parameter("use_rest_volume_position"))


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	failed = true
