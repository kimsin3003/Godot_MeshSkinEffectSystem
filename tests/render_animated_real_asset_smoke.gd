extends SceneTree

const VisualBaselineScript := preload("res://tests/visual_baseline.gd")
const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")
const SOPHIA_SCENE_PATH := "res://addons/gdquest_sophia/sophia_skin.tscn"
const OUTPUT_PATH := "res://artifacts/sophia_animated_surface_effects.png"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	get_root().size = Vector2i(960, 540)
	_ensure_artifacts_dir()

	var root := _instantiate_scene(SOPHIA_SCENE_PATH)
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animation_players: Array[AnimationPlayer] = []
	var animation_trees: Array[AnimationTree] = []
	_collect(root, meshes, skeletons, animation_players, animation_trees)

	var mesh_instance := _find_largest_mesh(meshes)
	_assert(mesh_instance != null, "animated Sophia render mesh not found")
	_assert(skeletons.size() == 1, "animated Sophia skeleton not found")
	_assert(animation_players.size() == 1, "animated Sophia animation player not found")

	var skeleton := skeletons[0]
	var player := animation_players[0]
	var before_poses := _capture_bone_poses(skeleton)

	for animation_tree in animation_trees:
		animation_tree.active = false
	player.play("Run")
	player.seek(0.45, true)
	player.advance(0.0)
	for frame in range(8):
		await process_frame

	var pose_delta := _max_pose_delta(before_poses, _capture_bone_poses(skeleton))
	_assert(pose_delta > 0.02, "Sophia animation pose did not change before effect test")

	var bounds := _compute_world_bounds(mesh_instance)
	var center := bounds.get_center()
	var size := bounds.size
	var camera_position := center + Vector3(-max(size.x * 2.0, 1.2), size.y * 0.15, max(size.z * 1.05, 0.7))
	var shot_direction := (center - camera_position).normalized()

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 8192
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)
	_set_test_impact_color(mesh_instance)
	var impact_radius: float = max(size.length() * 0.24, 0.42)
	var resolved_impact: Vector3 = accumulator.add_impact(center, shot_direction, impact_radius, 1.0)

	var light := DirectionalLight3D.new()
	get_root().add_child(light)
	light.light_energy = 3.0
	light.global_rotation = Vector3(-0.9, -0.5, 0.0)

	var camera := Camera3D.new()
	get_root().add_child(camera)
	camera.fov = 30.0
	camera.global_position = camera_position
	camera.look_at(center + Vector3(0, size.y * 0.1, 0), Vector3.UP)
	camera.current = true

	for frame in range(45):
		await process_frame
	await RenderingServer.frame_post_draw

	var image: Image = get_root().get_texture().get_image()
	var save_result: Error = image.save_png(OUTPUT_PATH)
	_assert(save_result == OK, "failed to save animated Sophia render smoke screenshot")

	var non_background := _count_non_background_samples(image)
	var impact_samples := _count_magenta_samples(image)
	var total_samples := _count_total_samples(image)
	_assert(non_background > int(float(total_samples) * 0.05), "animated Sophia screenshot appears blank")
	_assert(impact_samples > 0, "animated Sophia impact color was not visible")
	_assert(
		VisualBaselineScript.metric_in_range("render_animated_real_asset_smoke", "pose_delta", pose_delta),
		VisualBaselineScript.describe_failure("render_animated_real_asset_smoke", "pose_delta", pose_delta)
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_animated_real_asset_smoke", "non_background", float(non_background)),
		VisualBaselineScript.describe_failure("render_animated_real_asset_smoke", "non_background", float(non_background))
	)
	_assert(
		VisualBaselineScript.metric_in_range("render_animated_real_asset_smoke", "impact_samples", float(impact_samples)),
		VisualBaselineScript.describe_failure("render_animated_real_asset_smoke", "impact_samples", float(impact_samples))
	)

	print("animated_real_visual_smoke: output=%s pose_delta=%.3f non_background=%d/%d impact_samples=%d resolved=%s radius=%.3f" % [
		OUTPUT_PATH,
		pose_delta,
		non_background,
		total_samples,
		impact_samples,
		str(resolved_impact),
		impact_radius,
	])

	root.queue_free()
	accumulator.queue_free()
	light.queue_free()
	camera.queue_free()
	for frame in range(10):
		await process_frame
	quit(1 if failed else 0)


func _instantiate_scene(path: String) -> Node:
	var packed_scene: PackedScene = load(path)
	_assert(packed_scene != null, "failed to load scene: " + path)
	return packed_scene.instantiate()


func _collect(
	node: Node,
	meshes: Array[MeshInstance3D],
	skeletons: Array[Skeleton3D],
	animation_players: Array[AnimationPlayer],
	animation_trees: Array[AnimationTree]
) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
	if node is Skeleton3D:
		skeletons.append(node)
	if node is AnimationPlayer:
		animation_players.append(node)
	if node is AnimationTree:
		animation_trees.append(node)

	for child in node.get_children():
		_collect(child, meshes, skeletons, animation_players, animation_trees)


func _find_largest_mesh(meshes: Array[MeshInstance3D]) -> MeshInstance3D:
	var best_mesh: MeshInstance3D = null
	var best_vertex_count := -1
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			continue
		var vertex_count := 0
		for surface_index in mesh_instance.mesh.get_surface_count():
			var arrays: Array = mesh_instance.mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			vertex_count += vertices.size()
		if vertex_count > best_vertex_count:
			best_vertex_count = vertex_count
			best_mesh = mesh_instance
	return best_mesh


func _capture_bone_poses(skeleton: Skeleton3D) -> Array[Transform3D]:
	var poses: Array[Transform3D] = []
	for bone_index in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_global_pose(bone_index))
	return poses


func _max_pose_delta(before: Array[Transform3D], after: Array[Transform3D]) -> float:
	var max_delta := 0.0
	for i in min(before.size(), after.size()):
		var origin_delta := before[i].origin.distance_to(after[i].origin)
		var basis_delta := (
			before[i].basis.x.distance_to(after[i].basis.x)
			+ before[i].basis.y.distance_to(after[i].basis.y)
			+ before[i].basis.z.distance_to(after[i].basis.z)
		)
		max_delta = max(max_delta, origin_delta + basis_delta)
	return max_delta


func _set_test_impact_color(mesh_instance: MeshInstance3D) -> void:
	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_surface_override_material(surface_index)
		if material is ShaderMaterial:
			material.set_shader_parameter("blood_color", Color(1.0, 0.0, 1.0, 1.0))


func _compute_world_bounds(mesh_instance: MeshInstance3D) -> AABB:
	var local_bounds := mesh_instance.mesh.get_aabb()
	var corners := [
		Vector3(local_bounds.position.x, local_bounds.position.y, local_bounds.position.z),
		Vector3(local_bounds.end.x, local_bounds.position.y, local_bounds.position.z),
		Vector3(local_bounds.position.x, local_bounds.end.y, local_bounds.position.z),
		Vector3(local_bounds.end.x, local_bounds.end.y, local_bounds.position.z),
		Vector3(local_bounds.position.x, local_bounds.position.y, local_bounds.end.z),
		Vector3(local_bounds.end.x, local_bounds.position.y, local_bounds.end.z),
		Vector3(local_bounds.position.x, local_bounds.end.y, local_bounds.end.z),
		Vector3(local_bounds.end.x, local_bounds.end.y, local_bounds.end.z),
	]
	var first := mesh_instance.to_global(corners[0])
	var min_point := first
	var max_point := first
	for corner in corners:
		var world_corner := mesh_instance.to_global(corner)
		min_point = min_point.min(world_corner)
		max_point = max_point.max(world_corner)
	return AABB(min_point, max_point - min_point)


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


func _count_magenta_samples(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var color: Color = image.get_pixel(x, y)
			if color.r > 0.25 and color.b > 0.25 and color.g < 0.15:
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
