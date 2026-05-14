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
	var ray_origin := camera.project_ray_origin(Vector2(480, 270))
	var ray_dir := camera.project_ray_normal(Vector2(480, 270)).normalized()
	var hit: Dictionary = scene.call("_raycast_visual_mesh", ray_origin, ray_dir)
	if hit.is_empty():
		print("accumulation_scaling: no hit")
		quit()
		return

	var hit_costs := []
	for target_count in [1, 32, 128, 512]:
		var start := Time.get_ticks_usec()
		for i in target_count:
			accumulator.add_surface_effect_at_triangle(
				1,
				hit["mesh_instance"],
				hit["surface"],
				hit["triangle_indices"],
				hit["barycentric"],
				ray_dir,
				0.06,
				1.0,
				hit["position"],
				hit["rest_center_local"]
			)
		var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
		hit_costs.append("%.3f" % (elapsed_ms / float(target_count)))

	var wind_dir := Vector3(1.0, 0.0, 0.0)
	var min_projection: float = scene.call("_min_character_projection", wind_dir)
	var sand_costs := []
	for step in range(8):
		var front := min_projection - 0.35 + float(step) * 0.35
		var start := Time.get_ticks_usec()
		accumulator.set_sand_state(wind_dir, front, 0.85)
		var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
		sand_costs.append("%.3f" % elapsed_ms)
		await process_frame

	accumulator.clear_impacts()
	var frame_front := min_projection - 0.35
	var sand_frame_total := 0.0
	var sand_frame_max := 0.0
	for frame in range(120):
		frame_front += 0.45 / 60.0
		var start := Time.get_ticks_usec()
		accumulator.set_sand_state(wind_dir, frame_front, 0.85)
		var elapsed_ms := float(Time.get_ticks_usec() - start) / 1000.0
		sand_frame_total += elapsed_ms
		sand_frame_max = max(sand_frame_max, elapsed_ms)
		await process_frame

	print("accumulation_scaling: hits_avg_ms=%s sand_step_ms=%s sand_frame_avg_ms=%.3f sand_frame_max_ms=%.3f samples=%d events=%d" % [
		",".join(hit_costs),
		",".join(sand_costs),
		sand_frame_total / 120.0,
		sand_frame_max,
		accumulator.get_sample_count(),
		accumulator.get_impact_count(),
	])

	scene.queue_free()
	for frame in range(5):
		await process_frame
	quit()
