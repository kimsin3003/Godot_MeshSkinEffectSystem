extends SceneTree

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root := Node3D.new()
	root.name = "RuntimeCharacter"
	get_root().add_child(root)

	var body := MeshInstance3D.new()
	body.name = "RuntimeBody"
	body.mesh = _make_box_mesh(Vector3(0.44, 1.45, 0.30), 1, Color(0.22, 0.28, 0.34))
	root.add_child(body)

	var outer := MeshInstance3D.new()
	outer.name = "RuntimeOuterwear"
	outer.mesh = _make_box_mesh(Vector3(0.55, 1.28, 0.40), 2, Color(0.48, 0.22, 0.18))
	root.add_child(outer)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 4096
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var first_samples := accumulator.get_sample_count()
	_assert(first_samples > 0, "initial runtime mesh produced no samples")
	_assert(accumulator.get_material_instance_count() == 3, "initial runtime material slots were not rebound")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "initial runtime memory exceeded 1 MB")

	var first_physics_hit := root.to_global(Vector3(0.0, 0.0, 0.40))
	var resolved_first := accumulator.add_impact(first_physics_hit, Vector3(1, 0, 0), 0.14, 1.0)
	var first_local := root.to_local(resolved_first)
	_assert(first_local.x < -0.48, "initial impact did not resolve to runtime outerwear")
	_assert(accumulator.get_impact_count() == 1, "initial runtime impact was not recorded")

	outer.mesh = _make_box_mesh(Vector3(0.72, 1.18, 0.48), 3, Color(0.18, 0.36, 0.56))
	accumulator.rebuild_for_character(root)

	var swapped_samples := accumulator.get_sample_count()
	_assert(swapped_samples > first_samples, "clothing swap did not rebuild sampler for new runtime mesh")
	_assert(accumulator.get_material_instance_count() == 4, "clothing swap did not rebind new material slots")
	_assert(accumulator.get_impact_count() == 0, "clothing swap did not clear accumulated impacts")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "swapped runtime memory exceeded 1 MB")

	for surface_index in outer.mesh.get_surface_count():
		var material := outer.get_surface_override_material(surface_index)
		_assert(material is ShaderMaterial, "swapped runtime slot is not using effect shader")
		_assert(material.get_shader_parameter("impact_count") == 0, "swapped runtime slot kept stale impact state")

	var second_physics_hit := root.to_global(Vector3(0.0, 0.0, 0.48))
	var resolved_second := accumulator.add_impact(second_physics_hit, Vector3(1, 0, 0), 0.18, 1.0)
	var second_local := root.to_local(resolved_second)
	_assert(second_local.x < -0.65, "post-swap impact did not resolve to larger outerwear")

	print("runtime_clothing_swap: first_samples=%d swapped_samples=%d first_x=%.3f second_x=%.3f materials=%d memory=%d" % [
		first_samples,
		swapped_samples,
		first_local.x,
		second_local.x,
		accumulator.get_material_instance_count(),
		accumulator.estimate_memory_bytes(),
	])

	root.queue_free()
	accumulator.queue_free()
	quit(1 if failed else 0)


func _make_box_mesh(extents: Vector3, surface_count: int, color: Color) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for surface_index in surface_count:
		var surface_color := color.lightened(float(surface_index) * 0.08)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _make_box_surface(extents, surface_index, surface_count))
		mesh.surface_set_material(surface_index, _make_material(surface_color))
	return mesh


func _make_box_surface(extents: Vector3, surface_index: int, surface_count: int) -> Array:
	var min_y := -extents.y * 0.5 + extents.y * float(surface_index) / float(surface_count)
	var max_y := -extents.y * 0.5 + extents.y * float(surface_index + 1) / float(surface_count)
	var x := extents.x
	var z := extents.z

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	_append_quad(vertices, normals, uvs, indices, [
		Vector3(-x, min_y, -z),
		Vector3(-x, max_y, -z),
		Vector3(-x, max_y, z),
		Vector3(-x, min_y, z),
	], Vector3.LEFT)
	_append_quad(vertices, normals, uvs, indices, [
		Vector3(x, min_y, z),
		Vector3(x, max_y, z),
		Vector3(x, max_y, -z),
		Vector3(x, min_y, -z),
	], Vector3.RIGHT)
	_append_quad(vertices, normals, uvs, indices, [
		Vector3(-x, min_y, z),
		Vector3(-x, max_y, z),
		Vector3(x, max_y, z),
		Vector3(x, min_y, z),
	], Vector3.FORWARD)
	_append_quad(vertices, normals, uvs, indices, [
		Vector3(x, min_y, -z),
		Vector3(x, max_y, -z),
		Vector3(-x, max_y, -z),
		Vector3(-x, min_y, -z),
	], Vector3.BACK)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


func _append_quad(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	points: Array,
	normal: Vector3
) -> void:
	var start := vertices.size()
	for point in points:
		vertices.append(point)
		normals.append(normal)
	uvs.append_array(PackedVector2Array([
		Vector2(0.93, 0.17),
		Vector2(0.11, 0.82),
		Vector2(0.76, 0.94),
		Vector2(0.34, 0.06),
	]))
	indices.append_array(PackedInt32Array([
		start,
		start + 1,
		start + 2,
		start,
		start + 2,
		start + 3,
	]))


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	return material


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
