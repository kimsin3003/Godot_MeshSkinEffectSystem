extends SceneTree

const VisualBaselineScript := preload("res://tests/visual_baseline.gd")
const SHADER := preload("res://shaders/surface_effects.gdshader")
const EARLY_OUTPUT_PATH := "res://artifacts/sand_front_early.png"
const LATE_OUTPUT_PATH := "res://artifacts/sand_front_late.png"
const VOLUME_OUTPUT_PATH := "res://artifacts/sand_volume_path.png"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	get_root().size = Vector2i(960, 540)
	_ensure_artifacts_dir()
	_setup_environment()

	var material := _make_sand_material()
	var left_perpendicular := Vector3(-0.8, 0.45, 0.0)
	var right_perpendicular := Vector3(0.8, 0.45, 0.0)
	var left_parallel := Vector3(-0.8, -0.55, 0.0)

	get_root().add_child(_make_perpendicular_quad("LeftPerpendicular", left_perpendicular, material))
	get_root().add_child(_make_perpendicular_quad("RightPerpendicular", right_perpendicular, material))
	get_root().add_child(_make_parallel_quad("LeftParallel", left_parallel, material))

	var camera := Camera3D.new()
	get_root().add_child(camera)
	camera.fov = 38.0
	camera.global_position = Vector3(2.0, 0.0, 4.0)
	camera.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
	camera.current = true

	material.set_shader_parameter("sand_front", -1.25)
	var early_image := await _capture(camera, EARLY_OUTPUT_PATH)
	material.set_shader_parameter("sand_front", 0.0)
	var late_image := await _capture(camera, LATE_OUTPUT_PATH)

	var left_early := _sample_brightness(early_image, camera.unproject_position(left_perpendicular))
	var left_late := _sample_brightness(late_image, camera.unproject_position(left_perpendicular))
	var right_late := _sample_brightness(late_image, camera.unproject_position(right_perpendicular))
	var parallel_late := _sample_brightness(late_image, camera.unproject_position(left_parallel))

	_assert(left_late > left_early + 0.12, "sand front did not increase coverage after advancing")
	_assert(left_late > right_late + 0.12, "sand front did not respect wind direction")
	_assert(left_late > parallel_late + 0.12, "parallel normal was not attenuated")
	_assert(
		VisualBaselineScript.metric_in_range("render_sand_mask_smoke", "left_early", left_early),
		VisualBaselineScript.describe_failure("render_sand_mask_smoke", "left_early", left_early)
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_sand_mask_smoke", "left_late", left_late),
		VisualBaselineScript.describe_failure("render_sand_mask_smoke", "left_late", left_late)
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_sand_mask_smoke", "right_late", right_late),
		VisualBaselineScript.describe_failure("render_sand_mask_smoke", "right_late", right_late)
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_sand_mask_smoke", "parallel_late", parallel_late),
		VisualBaselineScript.describe_failure("render_sand_mask_smoke", "parallel_late", parallel_late)
	)

	var volume_probe := Vector3(0.0, -1.25, 0.0)
	var volume_material := _make_sand_material()
	_bind_empty_volume(volume_material)
	volume_material.set_shader_parameter("sand_front", 1.0)
	get_root().add_child(_make_perpendicular_quad("VolumeProbe", volume_probe, volume_material))
	var volume_image := await _capture(camera, VOLUME_OUTPUT_PATH)
	var volume_probe_brightness := _sample_brightness(volume_image, camera.unproject_position(volume_probe))
	_assert(volume_probe_brightness < 0.20, "procedural sand leaked into the accumulated volume material path")

	print("sand_mask_smoke: early=%s late=%s volume=%s left_early=%.3f left_late=%.3f right_late=%.3f parallel_late=%.3f volume_probe=%.3f" % [
		EARLY_OUTPUT_PATH,
		LATE_OUTPUT_PATH,
		VOLUME_OUTPUT_PATH,
		left_early,
		left_late,
		right_late,
		parallel_late,
		volume_probe_brightness,
	])

	quit(1 if failed else 0)


func _setup_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.01, 0.01, 0.012)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.0
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	get_root().add_child(world_environment)


func _make_sand_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("base_color", Color(0.05, 0.08, 0.12, 1.0))
	material.set_shader_parameter("sand_color", Color(1.0, 0.84, 0.32, 1.0))
	material.set_shader_parameter("sand_direction_world", Vector3(1.0, 0.0, 0.0))
	material.set_shader_parameter("sand_amount", 1.0)
	material.set_shader_parameter("sand_front_softness", 0.35)
	material.set_shader_parameter("character_inverse_world", Transform3D.IDENTITY)
	return material


func _bind_empty_volume(material: ShaderMaterial) -> void:
	var images: Array[Image] = []
	for layer in 4:
		var image := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		images.append(image)
	var volume := Texture2DArray.new()
	volume.create_from_images(images)
	material.set_shader_parameter("use_surface_effect_volume", true)
	material.set_shader_parameter("surface_effect_volume", volume)
	material.set_shader_parameter("effect_volume_depth", 4.0)
	material.set_shader_parameter("effect_volume_origin_local", Vector3(-2.0, -2.0, -2.0))
	material.set_shader_parameter("effect_volume_inv_size", Vector3(0.25, 0.25, 0.25))


func _make_perpendicular_quad(node_name: String, center: Vector3, material: ShaderMaterial) -> MeshInstance3D:
	var points := [
		center + Vector3(-0.35, -0.35, 0.0),
		center + Vector3(0.35, -0.35, 0.0),
		center + Vector3(0.35, 0.35, 0.0),
		center + Vector3(-0.35, 0.35, 0.0),
	]
	return _make_quad(node_name, points, Vector3.FORWARD, material)


func _make_parallel_quad(node_name: String, center: Vector3, material: ShaderMaterial) -> MeshInstance3D:
	var points := [
		center + Vector3(0.0, -0.35, -0.35),
		center + Vector3(0.0, 0.35, -0.35),
		center + Vector3(0.0, 0.35, 0.35),
		center + Vector3(0.0, -0.35, 0.35),
	]
	return _make_quad(node_name, points, Vector3.RIGHT, material)


func _make_quad(node_name: String, points: Array, normal: Vector3, material: ShaderMaterial) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		points[0], points[1], points[2], points[3],
		points[0], points[3], points[2], points[1],
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		normal, normal, normal, normal,
		normal, normal, normal, normal,
	])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0),
		Vector2(0, 1), Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
	])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	mesh_instance.mesh = mesh
	mesh_instance.set_surface_override_material(0, material)
	return mesh_instance


func _capture(camera: Camera3D, output_path: String) -> Image:
	for frame in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = get_root().get_texture().get_image()
	var save_result: Error = image.save_png(output_path)
	_assert(save_result == OK, "failed to save " + output_path)
	return image


func _sample_brightness(image: Image, center: Vector2) -> float:
	var total := 0.0
	var count := 0
	for y in range(int(center.y) - 12, int(center.y) + 13):
		for x in range(int(center.x) - 12, int(center.x) + 13):
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			var color: Color = image.get_pixel(x, y)
			total += (color.r + color.g + color.b) / 3.0
			count += 1
	if count == 0:
		return 0.0
	return total / float(count)


func _ensure_artifacts_dir() -> void:
	var dir: DirAccess = DirAccess.open("res://")
	if dir != null and not dir.dir_exists("artifacts"):
		dir.make_dir("artifacts")


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
