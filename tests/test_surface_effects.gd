extends SceneTree

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_layered_outer_surface()
	_test_multi_material_slot_binding()
	_test_artist_effect_metadata_binding()
	_test_volume_accumulates_past_debug_event_limit()
	_test_sub_voxel_impact_still_records()
	_test_sand_accumulates_in_shared_volume()
	_test_material_preservation()
	quit(1 if failed else 0)


func _test_layered_outer_surface() -> void:
	var root := Node3D.new()
	root.name = "LayeredCharacter"
	root.add_child(_make_capsule("Body", 0.38, 1.45))
	root.add_child(_make_capsule("Jacket", 0.43, 1.36))
	root.add_child(_make_capsule("Outer", 0.48, 1.16))
	get_root().add_child(root)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 8192
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	_assert(accumulator.get_sample_count() > 0, "sampler produced no samples")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "memory estimate exceeded 1 MB")

	var resolved := accumulator.add_impact(root.global_position, Vector3(1, 0, 0), 0.055, 1.0)
	var resolved_local := root.to_local(resolved)
	_assert(resolved_local.x < -0.40, "impact did not resolve to incoming outer surface")
	print("layered_outer_surface: samples=%d memory=%d resolved_x=%.3f" % [
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
		resolved_local.x,
	])

	root.queue_free()
	accumulator.queue_free()


func _test_multi_material_slot_binding() -> void:
	var root := Node3D.new()
	root.name = "SlotCharacter"
	var split_shell := _make_split_slot_shell()
	root.add_child(split_shell)
	get_root().add_child(root)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 256
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	_assert(split_shell.mesh.get_surface_count() == 2, "test mesh must have two material slots")
	_assert(accumulator.get_material_instance_count() == 2, "not every material slot received a shader instance")
	_assert(accumulator.get_sample_count() >= 8, "sampler skipped one or more mesh surfaces")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "slot test memory estimate exceeded 1 MB")

	for surface_index in split_shell.mesh.get_surface_count():
		var material := split_shell.get_surface_override_material(surface_index)
		_assert(material is ShaderMaterial, "surface override is not a ShaderMaterial")
		_assert(material.get_shader_parameter("impact_count") == 0, "rebuild did not clear old impacts")

	var resolved := accumulator.add_impact(root.global_position, Vector3(1, 0, 0), 0.055, 1.0)
	var resolved_local := root.to_local(resolved)
	_assert(resolved_local.x <= -0.49, "multi-slot hit did not resolve to the visual surface")
	print("multi_material_slot: slots=%d samples=%d memory=%d resolved_x=%.3f" % [
		accumulator.get_material_instance_count(),
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
		resolved_local.x,
	])

	for surface_index in split_shell.mesh.get_surface_count():
		var material := split_shell.get_surface_override_material(surface_index)
		_assert(material.get_shader_parameter("impact_count") == 1, "impact state was not shared across slots")
		_assert(material.get_shader_parameter("use_surface_effect_volume"), "O(1) volume path was not enabled")
		_assert(material.get_shader_parameter("surface_effect_volume") is Texture2DArray, "surface effect volume was not bound")

	var volume_sample := accumulator.sample_effect_volume_local(resolved_local)
	_assert(volume_sample.r > 0.1, "impact was not accumulated into the O(1) volume")

	accumulator.rebuild_for_character(root)
	for surface_index in split_shell.mesh.get_surface_count():
		var material := split_shell.get_surface_override_material(surface_index)
		_assert(material.get_shader_parameter("impact_count") == 0, "clothing rebuild did not reset impact state")

	root.queue_free()
	accumulator.queue_free()


func _test_artist_effect_metadata_binding() -> void:
	var root := Node3D.new()
	root.name = "ArtistEventCharacter"
	var split_shell := _make_split_slot_shell()
	root.add_child(split_shell)
	get_root().add_child(root)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 256
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var effect_id := 7
	var resolved := accumulator.add_surface_effect(effect_id, root.global_position, Vector3(1, 0, 0), 0.08, 0.35)
	var resolved_local := root.to_local(resolved)
	_assert(resolved_local.x <= -0.49, "artist event did not resolve to the visual surface")

	for surface_index in split_shell.mesh.get_surface_count():
		var material := split_shell.get_surface_override_material(surface_index)
		_assert(material is ShaderMaterial, "artist event surface override is not ShaderMaterial")
		_assert(material.get_shader_parameter("impact_count") == 1, "artist event count was not pushed to every slot")
		var spheres: PackedVector4Array = material.get_shader_parameter("impact_spheres")
		var dirs: PackedVector4Array = material.get_shader_parameter("impact_dirs")
		var meta: PackedVector4Array = material.get_shader_parameter("impact_meta")
		_assert(spheres.size() == 1, "artist event position data missing")
		_assert(dirs.size() == 1, "artist event direction data missing")
		_assert(meta.size() == 1, "artist event metadata missing")
		_assert(is_equal_approx(meta[0].x, float(effect_id)), "artist effect id was not pushed to material")
		_assert(is_equal_approx(dirs[0].w, 0.35), "artist event strength was not pushed to material")

	var volume_sample := accumulator.sample_effect_volume_local(resolved_local)
	_assert(volume_sample.a > 0.1, "artist event was not accumulated into the fourth O(1) volume channel")

	print("artist_effect_metadata: effect_id=%d resolved_x=%.3f slots=%d" % [
		effect_id,
		resolved_local.x,
		accumulator.get_material_instance_count(),
	])

	root.queue_free()
	accumulator.queue_free()


func _test_volume_accumulates_past_debug_event_limit() -> void:
	var root := Node3D.new()
	root.name = "PersistentVolumeCharacter"
	var split_shell := _make_split_slot_shell()
	root.add_child(split_shell)
	get_root().add_child(root)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 256
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var first_local := Vector3(-0.5, -0.055, -0.018)
	accumulator.add_surface_effect_at_visual_surface(
		2,
		root.to_global(first_local),
		Vector3.LEFT,
		0.045,
		1.0
	)

	for event_index in range(1, 80):
		var y: float = lerp(-0.055, 0.055, float(event_index % 16) / 15.0)
		var z_step := int(event_index / 16) % 5
		var z: float = lerp(-0.018, 0.018, float(z_step) / 4.0)
		accumulator.add_surface_effect_at_visual_surface(
			1,
			root.to_global(Vector3(-0.5, y, z)),
			Vector3.LEFT,
			0.035,
			1.0
		)

	_assert(accumulator.get_impact_count() == 80, "persistent event count did not include all accumulated events")
	var material := split_shell.get_surface_override_material(0) as ShaderMaterial
	_assert(material != null, "persistent volume material was not rebound")
	_assert(material.get_shader_parameter("impact_count") == SurfaceEffectAccumulator.MAX_IMPACTS, "debug event uniform should keep only the recent ring")

	var first_volume_sample := accumulator.sample_effect_volume_local(first_local)
	_assert(first_volume_sample.g > 0.1, "first event was lost after the debug event ring wrapped")
	print("volume_accumulates_past_debug_limit: total=%d debug=%d first_g=%.3f" % [
		accumulator.get_impact_count(),
		int(material.get_shader_parameter("impact_count")),
		first_volume_sample.g,
	])

	root.queue_free()
	accumulator.queue_free()


func _test_sub_voxel_impact_still_records() -> void:
	var root := Node3D.new()
	root.name = "SubVoxelImpactCharacter"
	var split_shell := _make_split_slot_shell()
	root.add_child(split_shell)
	get_root().add_child(root)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 256
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var hit_local := Vector3(-0.5, 0.03, 0.012)
	accumulator.add_surface_effect_at_visual_surface(
		1,
		root.to_global(hit_local),
		Vector3.LEFT,
		0.005,
		1.0
	)

	var volume_sample := accumulator.sample_effect_volume_local(hit_local)
	_assert(volume_sample.r > 0.1, "sub-voxel impact did not write the nearest effect volume cell")
	print("sub_voxel_impact: radius=0.005 red=%.3f" % volume_sample.r)

	root.queue_free()
	accumulator.queue_free()


func _test_sand_accumulates_in_shared_volume() -> void:
	var root := Node3D.new()
	root.name = "PersistentSandCharacter"
	var panel := _make_sand_panel()
	root.add_child(panel)
	get_root().add_child(root)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 32
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var left_local := Vector3(-0.5, -0.05, 0.0)
	var right_local := Vector3(0.5, -0.05, 0.0)
	accumulator.set_sand_state(Vector3.RIGHT, -0.25, 1.0)
	var left_after_first := accumulator.sample_effect_volume_local(left_local)
	var right_after_first := accumulator.sample_effect_volume_local(right_local)
	_assert(left_after_first.g > 0.1, "sand did not accumulate into the shared volume from the first direction")
	_assert(right_after_first.g < 0.1, "sand ignored the first wind front direction")

	accumulator.set_sand_state(Vector3.LEFT, -0.25, 1.0)
	var left_after_second := accumulator.sample_effect_volume_local(left_local)
	var right_after_second := accumulator.sample_effect_volume_local(right_local)
	_assert(left_after_second.g > 0.1, "previous sand accumulation was lost after changing direction")
	_assert(right_after_second.g > 0.1, "sand did not accumulate into the shared volume after changing direction")
	print("sand_accumulates_in_shared_volume: left=%.3f right=%.3f" % [
		left_after_second.g,
		right_after_second.g,
	])

	root.queue_free()
	accumulator.queue_free()


func _make_capsule(layer_name: String, radius: float, height: float) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = layer_name

	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 48
	mesh.rings = 16
	mesh_instance.mesh = mesh

	return mesh_instance


func _make_split_slot_shell() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "SplitSlotShell"

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _make_shell_surface_arrays(-0.07, 0.0))
	mesh.surface_set_material(0, _make_standard_material(Color(0.2, 0.35, 0.75)))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _make_shell_surface_arrays(0.0, 0.07))
	mesh.surface_set_material(1, _make_standard_material(Color(0.75, 0.32, 0.18)))
	mesh_instance.mesh = mesh

	return mesh_instance


func _make_sand_panel() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "SandPanel"

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, -0.05, 0.0),
		Vector3(0.5, -0.05, 0.0),
		Vector3(0.5, 0.05, 0.0),
		Vector3(-0.5, 0.05, 0.0),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP,
		Vector3.UP,
		Vector3.UP,
		Vector3.UP,
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _make_standard_material(Color(0.45, 0.48, 0.52)))
	mesh_instance.mesh = mesh
	return mesh_instance


func _make_shell_surface_arrays(y_min: float, y_max: float) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, y_min, -0.025),
		Vector3(-0.5, y_max, -0.025),
		Vector3(-0.5, y_max, 0.025),
		Vector3(-0.5, y_min, 0.025),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.LEFT,
		Vector3.LEFT,
		Vector3.LEFT,
		Vector3.LEFT,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.91, 0.73),
		Vector2(0.12, 0.86),
		Vector2(0.34, 0.05),
		Vector2(0.77, 0.18),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	return arrays


func _make_standard_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	return material


func _test_material_preservation() -> void:
	var root := Node3D.new()
	root.name = "MaterialCharacter"
	var mesh_instance := _make_material_quad()
	root.add_child(mesh_instance)
	get_root().add_child(root)

	var source_material := StandardMaterial3D.new()
	source_material.albedo_color = Color(0.25, 0.5, 0.75, 0.42)
	source_material.albedo_texture = _make_texture(Color(0.8, 0.7, 0.6, 0.5))
	source_material.normal_enabled = true
	source_material.normal_scale = 0.6
	source_material.normal_texture = _make_texture(Color(0.5, 0.5, 1.0, 1.0))
	source_material.roughness = 0.37
	source_material.roughness_texture = _make_texture(Color(0.3, 0.4, 0.5, 1.0))
	source_material.orm_texture = _make_texture(Color(1.0, 0.45, 0.2, 1.0))
	source_material.metallic = 0.28
	source_material.metallic_texture = _make_texture(Color(0.9, 0.8, 0.7, 1.0))
	source_material.emission_enabled = true
	source_material.emission = Color(0.2, 0.3, 0.4, 1.0)
	source_material.emission_energy_multiplier = 1.7
	source_material.emission_texture = _make_texture(Color(0.1, 0.2, 0.3, 1.0))
	source_material.alpha_scissor_threshold = 0.21
	mesh_instance.mesh.surface_set_material(0, source_material)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var shader_material := mesh_instance.get_surface_override_material(0) as ShaderMaterial
	_assert(shader_material != null, "material preservation did not create shader material")
	_assert(shader_material.get_shader_parameter("base_color").is_equal_approx(source_material.albedo_color), "albedo color was not preserved")
	_assert(shader_material.get_shader_parameter("use_base_texture"), "albedo texture was not preserved")
	_assert(shader_material.get_shader_parameter("use_normal_texture"), "normal texture was not preserved")
	_assert(is_equal_approx(shader_material.get_shader_parameter("normal_scale"), 0.6), "normal scale was not preserved")
	_assert(is_equal_approx(shader_material.get_shader_parameter("roughness_value"), 0.37), "roughness value was not preserved")
	_assert(shader_material.get_shader_parameter("use_roughness_texture"), "roughness texture was not preserved")
	_assert(shader_material.get_shader_parameter("use_orm_texture"), "ORM texture was not preserved")
	_assert(is_equal_approx(shader_material.get_shader_parameter("metallic_value"), 0.28), "metallic value was not preserved")
	_assert(shader_material.get_shader_parameter("use_metallic_texture"), "metallic texture was not preserved")
	_assert(shader_material.get_shader_parameter("use_emission_texture"), "emission texture was not preserved")
	_assert(shader_material.get_shader_parameter("emission_color").is_equal_approx(source_material.emission), "emission color was not preserved")
	_assert(is_equal_approx(shader_material.get_shader_parameter("emission_energy"), 1.7), "emission energy was not preserved")
	_assert(is_equal_approx(shader_material.get_shader_parameter("alpha_scissor_threshold"), 0.21), "alpha scissor was not preserved")

	print("material_preservation: albedo normal roughness orm emission alpha")

	root.queue_free()
	accumulator.queue_free()


func _make_material_quad() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _make_shell_surface_arrays(-0.05, 0.05))
	mesh_instance.mesh = mesh
	return mesh_instance


func _make_texture(color: Color) -> ImageTexture:
	var image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	for y in 2:
		for x in 2:
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
