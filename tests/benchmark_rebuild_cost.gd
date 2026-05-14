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

	var character_root: Node3D = scene.get_node("Character")
	var accumulator: SurfaceEffectAccumulator = scene.get_node("SurfaceEffectAccumulator")

	var breakdown_start := Time.get_ticks_usec()
	accumulator.clear_impacts(false)
	var clear_ms := float(Time.get_ticks_usec() - breakdown_start) / 1000.0

	breakdown_start = Time.get_ticks_usec()
	accumulator.sampler.rebuild(character_root, accumulator.sample_limit)
	var sampler_ms := float(Time.get_ticks_usec() - breakdown_start) / 1000.0

	breakdown_start = Time.get_ticks_usec()
	accumulator.call("_rebuild_effect_volume_storage", character_root)
	var volume_ms := float(Time.get_ticks_usec() - breakdown_start) / 1000.0

	breakdown_start = Time.get_ticks_usec()
	accumulator.call("_ensure_rest_volume_attributes", character_root)
	var rest_ms := float(Time.get_ticks_usec() - breakdown_start) / 1000.0

	breakdown_start = Time.get_ticks_usec()
	accumulator.call("_rebuild_materials", character_root)
	var material_ms := float(Time.get_ticks_usec() - breakdown_start) / 1000.0

	breakdown_start = Time.get_ticks_usec()
	accumulator.call("_sync_all_shader_params")
	var sync_ms := float(Time.get_ticks_usec() - breakdown_start) / 1000.0

	var rebuild_costs := []
	for sample in range(4):
		var start := Time.get_ticks_usec()
		accumulator.rebuild_for_character(character_root)
		rebuild_costs.append("%.3f" % (float(Time.get_ticks_usec() - start) / 1000.0))
		await process_frame

	var swap_start := Time.get_ticks_usec()
	await scene.call("_load_asset", 1)
	var swap_ms := float(Time.get_ticks_usec() - swap_start) / 1000.0

	print("rebuild_cost: parts_ms=clear %.3f sampler %.3f volume %.3f rest %.3f material %.3f sync %.3f rebuild_ms=%s swap_ms=%.3f samples=%d memory=%d" % [
		clear_ms,
		sampler_ms,
		volume_ms,
		rest_ms,
		material_ms,
		sync_ms,
		",".join(rebuild_costs),
		swap_ms,
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
	])

	scene.queue_free()
	for frame in range(5):
		await process_frame
	quit()
