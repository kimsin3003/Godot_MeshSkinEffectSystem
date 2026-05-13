extends SceneTree

const VisualBaselineScript := preload("res://tests/visual_baseline.gd")
const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")
const QUATERNIUS_ADVENTURER_PATH := "res://external/quaternius_modular_women_glb/Adventurer.glb"
const OUTPUT_PATH := "res://artifacts/quaternius_layered_seam_effects.png"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	get_root().size = Vector2i(960, 540)
	_ensure_artifacts_dir()
	_setup_environment()

	var root := _load_gltf_scene(QUATERNIUS_ADVENTURER_PATH)
	_assert(root != null, "failed to load Quaternius Adventurer GLB")
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	_collect(root, meshes, skeletons)
	var layer_column := _find_layered_surface_column(root as Node3D, meshes)
	_assert(not layer_column.is_empty(), "no layered real surface column found for seam render")

	var hit_local := Vector3(layer_column["x"], layer_column["y"], layer_column["inner_z"])
	var shot_direction := ((root as Node3D).global_transform.basis * Vector3(0, 0, 1)).normalized()
	var physics_hit_world := (root as Node3D).to_global(hit_local)

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 32768
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root as Node3D)
	_set_test_impact_color(meshes)
	var resolved_world := accumulator.add_impact(physics_hit_world, shot_direction, 0.22, 1.0)

	var camera := Camera3D.new()
	get_root().add_child(camera)
	camera.fov = 28.0
	camera.global_position = resolved_world - shot_direction * 1.75 + Vector3(0.0, 0.08, 0.0)
	camera.look_at(resolved_world + Vector3(0.0, 0.04, 0.0), Vector3.UP)
	camera.current = true

	var light := OmniLight3D.new()
	get_root().add_child(light)
	light.light_energy = 4.0
	light.omni_range = 5.0
	light.global_position = camera.global_position

	for frame in range(45):
		await process_frame
	await RenderingServer.frame_post_draw

	var image: Image = get_root().get_texture().get_image()
	var save_result := image.save_png(OUTPUT_PATH)
	_assert(save_result == OK, "failed to save real seam render screenshot")

	var total_samples := _count_total_samples(image)
	var non_background := _count_non_background_samples(image)
	var impact_samples := _count_magenta_samples(image)
	var projected := camera.unproject_position(resolved_world)
	var left_samples := _count_magenta_window(image, projected + Vector2(-18, 0), 18)
	var right_samples := _count_magenta_window(image, projected + Vector2(18, 0), 18)
	var vertical_samples := _count_magenta_window(image, projected + Vector2(0, 18), 18)

	_assert(non_background > int(float(total_samples) * 0.04), "real seam screenshot appears blank")
	_assert(impact_samples > 0, "real seam impact color was not visible")
	_assert(left_samples > 0 and right_samples > 0, "impact did not render on both sides of the real boundary")
	_assert(vertical_samples > 0, "impact did not cover the nearby real layered surface")
	_assert(
		VisualBaselineScript.metric_in_range("render_real_seam_boundary_smoke", "non_background", float(non_background)),
		VisualBaselineScript.describe_failure("render_real_seam_boundary_smoke", "non_background", float(non_background))
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_real_seam_boundary_smoke", "impact_samples", float(impact_samples)),
		VisualBaselineScript.describe_failure("render_real_seam_boundary_smoke", "impact_samples", float(impact_samples))
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_real_seam_boundary_smoke", "left_samples", float(left_samples)),
		VisualBaselineScript.describe_failure("render_real_seam_boundary_smoke", "left_samples", float(left_samples))
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_real_seam_boundary_smoke", "right_samples", float(right_samples)),
		VisualBaselineScript.describe_failure("render_real_seam_boundary_smoke", "right_samples", float(right_samples))
	)

	print("real_seam_boundary_smoke: output=%s non_background=%d/%d impact_samples=%d left=%d right=%d vertical=%d resolved=%s surfaces=%d" % [
		OUTPUT_PATH,
		non_background,
		total_samples,
		impact_samples,
		left_samples,
		right_samples,
		vertical_samples,
		str(resolved_world),
		int(layer_column["surface_count"]),
	])

	root.queue_free()
	accumulator.queue_free()
	camera.queue_free()
	light.queue_free()
	for frame in range(10):
		await process_frame
	quit(1 if failed else 0)


func _load_gltf_scene(path: String) -> Node:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	if error != OK:
		push_error("failed to parse glTF: %s error=%d" % [path, error])
		return null
	return document.generate_scene(state)


func _setup_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.01, 0.01, 0.012)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 1.1
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	get_root().add_child(world_environment)


func _set_test_impact_color(meshes: Array[MeshInstance3D]) -> void:
	for mesh_instance in meshes:
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface_index)
			if material is ShaderMaterial:
				material.set_shader_parameter("blood_color", Color(1.0, 0.0, 1.0, 1.0))


func _find_layered_surface_column(root: Node3D, meshes: Array[MeshInstance3D]) -> Dictionary:
	var columns := {}
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		var to_root := root.global_transform.affine_inverse() * mesh_instance.global_transform
		for surface_index in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var point := to_root * vertex
				if abs(point.x) > 0.45 or point.y < 1.12 or point.y > 1.58:
					continue
				var key := "%d:%d" % [int(round(point.x * 20.0)), int(round(point.y * 20.0))]
				if not columns.has(key):
					columns[key] = {
						"x": point.x,
						"y": point.y,
						"min_z": point.z,
						"max_z": point.z,
						"surfaces": {},
					}
				var entry: Dictionary = columns[key]
				entry["min_z"] = min(float(entry["min_z"]), point.z)
				entry["max_z"] = max(float(entry["max_z"]), point.z)
				var surfaces: Dictionary = entry["surfaces"]
				surfaces["%s:%d" % [mesh_instance.name, surface_index]] = true

	var best := {}
	var best_depth := 0.0
	for entry in columns.values():
		var surfaces: Dictionary = entry["surfaces"]
		var depth := float(entry["max_z"]) - float(entry["min_z"])
		if surfaces.size() < 2 or depth < 0.18:
			continue
		if depth > best_depth:
			best_depth = depth
			best = {
				"x": float(entry["x"]),
				"y": float(entry["y"]),
				"inner_z": lerp(float(entry["min_z"]), float(entry["max_z"]), 0.55),
				"surface_count": surfaces.size(),
			}
	return best


func _collect(node: Node, meshes: Array[MeshInstance3D], skeletons: Array[Skeleton3D]) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
	if node is Skeleton3D:
		skeletons.append(node)

	for child in node.get_children():
		_collect(child, meshes, skeletons)


func _ensure_artifacts_dir() -> void:
	var dir: DirAccess = DirAccess.open("res://")
	if dir != null and not dir.dir_exists("artifacts"):
		dir.make_dir("artifacts")


func _count_non_background_samples(image: Image) -> int:
	var background := image.get_pixel(0, 0)
	var count := 0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var color := image.get_pixel(x, y)
			if abs(color.r - background.r) + abs(color.g - background.g) + abs(color.b - background.b) > 0.08:
				count += 1
	return count


func _count_magenta_samples(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			if _is_magenta(image.get_pixel(x, y)):
				count += 1
	return count


func _count_magenta_window(image: Image, center: Vector2, radius: int) -> int:
	var count := 0
	for y in range(int(center.y) - radius, int(center.y) + radius + 1):
		for x in range(int(center.x) - radius, int(center.x) + radius + 1):
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			if _is_magenta(image.get_pixel(x, y)):
				count += 1
	return count


func _is_magenta(color: Color) -> bool:
	return color.r > 0.25 and color.b > 0.25 and color.g < 0.18


func _count_total_samples(image: Image) -> int:
	var x_count := int(ceil(float(image.get_width()) / 8.0))
	var y_count := int(ceil(float(image.get_height()) / 8.0))
	return x_count * y_count


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
