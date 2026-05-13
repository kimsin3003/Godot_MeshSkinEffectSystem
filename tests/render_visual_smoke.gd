extends SceneTree

const VisualBaselineScript := preload("res://tests/visual_baseline.gd")
const OUTPUT_PATH := "res://artifacts/demo_snapshot.png"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	get_root().size = Vector2i(960, 540)
	_ensure_artifacts_dir()

	var packed_scene: PackedScene = load("res://scenes/demo.tscn")
	var scene: Node = packed_scene.instantiate()
	scene.set("show_debug_markers", false)
	get_root().add_child(scene)

	for frame in range(30):
		await process_frame
	await RenderingServer.frame_post_draw

	var image: Image = get_root().get_texture().get_image()
	var save_result: Error = image.save_png(OUTPUT_PATH)
	_assert(save_result == OK, "failed to save visual smoke screenshot")

	var non_background := _count_non_background_samples(image)
	var total_samples: int = _count_total_samples(image)
	_assert(non_background > int(float(total_samples) * 0.03), "visual smoke screenshot appears blank")
	_assert(
		VisualBaselineScript.metric_in_range("render_visual_smoke", "non_background", float(non_background)),
		VisualBaselineScript.describe_failure("render_visual_smoke", "non_background", float(non_background))
	)

	print("visual_smoke: output=%s non_background=%d/%d" % [OUTPUT_PATH, non_background, total_samples])
	scene.queue_free()
	for frame in range(10):
		await process_frame
	quit(1 if failed else 0)


func _ensure_artifacts_dir() -> void:
	var dir: DirAccess = DirAccess.open("res://")
	if dir != null and not dir.dir_exists("artifacts"):
		dir.make_dir("artifacts")


func _count_non_background_samples(image: Image) -> int:
	var background: Color = image.get_pixel(0, 0)
	var count := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var color: Color = image.get_pixel(x, y)
			if abs(color.r - background.r) + abs(color.g - background.g) + abs(color.b - background.b) > 0.08:
				count += 1
	return count


func _count_total_samples(image: Image) -> int:
	var x_count := int(ceil(float(image.get_width()) / 8.0))
	var y_count := int(ceil(float(image.get_height()) / 8.0))
	return x_count * y_count


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
