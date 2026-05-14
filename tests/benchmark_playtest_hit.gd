extends SceneTree

const PLAYTEST_SCENE_PATH := "res://scenes/effect_playtest.tscn"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	get_root().size = Vector2i(960, 540)
	var packed_scene: PackedScene = load(PLAYTEST_SCENE_PATH)
	var scene := packed_scene.instantiate()
	get_root().add_child(scene)

	for frame in range(45):
		await process_frame

	var camera: Camera3D = scene.get_node("Camera3D")
	var accumulator: SurfaceEffectAccumulator = scene.get_node("SurfaceEffectAccumulator")
	var screen_position := Vector2(480, 270)
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_dir := camera.project_ray_normal(screen_position).normalized()

	var raycast_us := 0
	var event_us := 0
	var full_us := 0
	var hit_count := 0
	for sample_index in range(8):
		var full_start := Time.get_ticks_usec()
		var ray_start := Time.get_ticks_usec()
		var hit: Dictionary = scene.call("_raycast_visual_mesh", ray_origin, ray_dir)
		var ray_end := Time.get_ticks_usec()
		if hit.is_empty():
			continue

		var event_start := Time.get_ticks_usec()
		accumulator.add_surface_effect_at_triangle(
			1,
			hit["mesh_instance"],
			hit["surface"],
			hit["triangle_indices"],
			hit["barycentric"],
			ray_dir,
			0.06,
			1.0
		)
		var event_end := Time.get_ticks_usec()
		var full_end := Time.get_ticks_usec()

		raycast_us += ray_end - ray_start
		event_us += event_end - event_start
		full_us += full_end - full_start
		hit_count += 1
		await process_frame

	if hit_count > 0:
		print("playtest_hit_benchmark: hits=%d raycast_ms=%.3f event_ms=%.3f full_ms=%.3f" % [
			hit_count,
			float(raycast_us) / float(hit_count) / 1000.0,
			float(event_us) / float(hit_count) / 1000.0,
			float(full_us) / float(hit_count) / 1000.0,
		])
	else:
		print("playtest_hit_benchmark: no hits")

	scene.queue_free()
	for frame in range(5):
		await process_frame
	quit()
