extends SceneTree

const PLAYTEST_SCENE_PATH := "res://scenes/effect_playtest.tscn"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	get_root().size = Vector2i(960, 540)
	var packed_scene: PackedScene = load(PLAYTEST_SCENE_PATH)
	_assert(packed_scene != null, "failed to load effect playtest scene")
	var scene := packed_scene.instantiate()
	get_root().add_child(scene)

	for frame in range(30):
		await process_frame

	var accumulator: SurfaceEffectAccumulator = scene.get_node("SurfaceEffectAccumulator")
	_assert(accumulator.get_sample_count() > 0, "playtest scene did not build surface samples")
	var active_animation := String(scene.get("active_animation_name"))
	_assert(active_animation.ends_with("|Run") or active_animation == "Run", "playtest scene did not choose a running animation")
	_assert(bool(scene.get("animation_enabled")), "playtest animation was not enabled")
	var camera: Camera3D = scene.get_node("Camera3D")
	var screen_position := Vector2(480, 270)
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_dir := camera.project_ray_normal(screen_position).normalized()
	var visual_hit: Dictionary = scene.call("_apply_surface_event", screen_position)
	_assert(not visual_hit.is_empty(), "playtest center ray did not hit visual mesh")

	_assert(accumulator.get_impact_count() == 1, "playtest click did not add a surface effect")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "playtest memory estimate exceeded 1 MB")
	var material := _find_first_shader_material(scene)
	_assert(material != null, "playtest scene did not bind shader materials")
	var spheres: PackedVector4Array = material.get_shader_parameter("impact_spheres")
	var character_root: Node3D = scene.get_node("Character")
	var expected_local: Vector3 = character_root.to_local(visual_hit["event_position"])
	var recorded_local := Vector3(spheres[0].x, spheres[0].y, spheres[0].z)
	_assert(recorded_local.distance_to(expected_local) < 0.001, "playtest impact center did not match the clicked visual hit")

	for frame in range(5):
		await process_frame

	scene.call("start_sandstorm", Vector3(1.0, 0.0, 0.0))

	for frame in range(5):
		await process_frame

	_assert(is_equal_approx(material.get_shader_parameter("sand_amount"), 0.85), "playtest sand amount was not pushed")
	_assert(material.get_shader_parameter("sand_direction_world").is_equal_approx(Vector3(1.0, 0.0, 0.0)), "playtest sand direction was not pushed")

	print("effect_playtest_scene: samples=%d memory=%d events=%d click_error=%.4f sand=%s" % [
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
		accumulator.get_impact_count(),
		recorded_local.distance_to(expected_local),
		str(material.get_shader_parameter("sand_direction_world")),
	])

	for frame in range(90):
		await process_frame
	scene.queue_free()
	for frame in range(10):
		await process_frame
	quit(1 if failed else 0)


func _find_first_shader_material(node: Node) -> ShaderMaterial:
	if node is MeshInstance3D and node.mesh != null:
		for surface_index in node.mesh.get_surface_count():
			var material: Material = node.get_surface_override_material(surface_index)
			if material is ShaderMaterial:
				return material

	for child in node.get_children():
		var material: ShaderMaterial = _find_first_shader_material(child)
		if material != null:
			return material

	return null


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
