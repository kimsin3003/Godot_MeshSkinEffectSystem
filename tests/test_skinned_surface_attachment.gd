extends SceneTree

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")
const SOPHIA_SCENE_PATH := "res://addons/gdquest_sophia/sophia_skin.tscn"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root := _instantiate_scene(SOPHIA_SCENE_PATH)
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animation_players: Array[AnimationPlayer] = []
	var animation_trees: Array[AnimationTree] = []
	_collect(root, meshes, skeletons, animation_players, animation_trees)

	var mesh_instance := _find_largest_mesh(meshes)
	_assert(mesh_instance != null, "Sophia mesh not found")
	_assert(animation_players.size() == 1, "Sophia animation player not found")
	for animation_tree in animation_trees:
		animation_tree.active = false

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 8192
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	var player := animation_players[0]
	_seek_animation(player, 0.0)
	for frame in range(5):
		await process_frame

	var candidate := _find_moving_triangle(accumulator, mesh_instance, player)
	_assert(not candidate.is_empty(), "no moving Sophia triangle found")

	_seek_animation(player, 0.0)
	for frame in range(5):
		await process_frame
	var attached_world := accumulator.add_surface_effect_at_triangle(
		9,
		mesh_instance,
		candidate["surface_index"],
		candidate["triangle_indices"],
		Vector3.ONE / 3.0,
		Vector3(1, 0, 0),
		0.12,
		1.0
	)
	var visual_before: Vector3 = root.to_local(attached_world)
	var rest_center_local := _rest_triangle_center_local(
		root,
		mesh_instance,
		candidate["surface_index"],
		candidate["triangle_indices"],
		Vector3.ONE / 3.0
	)
	var volume_before := accumulator.sample_effect_volume_local(rest_center_local)
	_assert(volume_before.a > 0.1, "attached event was not accumulated at the rest-space triangle position")
	_assert(_uses_rest_volume_position(mesh_instance, candidate["surface_index"]), "attached material is not sampling rest-space volume coordinates")

	_seek_animation(player, 0.45)
	for frame in range(12):
		await process_frame

	var visual_after: Vector3 = root.to_local(_triangle_center_world(
		accumulator,
		mesh_instance,
		candidate["surface_index"],
		candidate["triangle_indices"]
	))
	var attachment_delta: float = visual_before.distance_to(visual_after)
	var volume_after := accumulator.sample_effect_volume_local(rest_center_local)
	_assert(attachment_delta > 0.02, "selected triangle did not move enough to validate skinned deformation")
	_assert(volume_after.a > 0.1, "rest-space volume event did not persist after skinned deformation")

	print("skinned_surface_attachment: surface=%d movement=%.3f attachment_delta=%.3f rest_alpha=%.3f before=%s after=%s" % [
		int(candidate["surface_index"]),
		float(candidate["movement"]),
		attachment_delta,
		volume_after.a,
		str(visual_before),
		str(visual_after),
	])

	root.queue_free()
	accumulator.queue_free()
	for frame in range(10):
		await process_frame
	quit(1 if failed else 0)


func _instantiate_scene(path: String) -> Node:
	var packed_scene: PackedScene = load(path)
	_assert(packed_scene != null, "failed to load scene: " + path)
	return packed_scene.instantiate()


func _seek_animation(player: AnimationPlayer, time: float) -> void:
	player.speed_scale = 0.0
	player.play("Run")
	player.seek(time, true)
	player.advance(0.0)


func _find_moving_triangle(
	accumulator: SurfaceEffectAccumulator,
	mesh_instance: MeshInstance3D,
	player: AnimationPlayer
) -> Dictionary:
	var before := _sample_triangle_centers(accumulator, mesh_instance)
	_seek_animation(player, 0.45)
	var after := _sample_triangle_centers(accumulator, mesh_instance)

	var best := {}
	var best_movement := 0.0
	for key in before.keys():
		if not after.has(key):
			continue
		var movement := (before[key] as Vector3).distance_to(after[key])
		if movement > best_movement:
			var parts: PackedStringArray = key.split(":")
			best_movement = movement
			best = {
				"surface_index": int(parts[0]),
				"triangle_indices": PackedInt32Array([
					int(parts[1]),
					int(parts[2]),
					int(parts[3]),
				]),
				"movement": movement,
			}
	return best


func _sample_triangle_centers(accumulator: SurfaceEffectAccumulator, mesh_instance: MeshInstance3D) -> Dictionary:
	var centers := {}
	for surface_index in mesh_instance.mesh.get_surface_count():
		var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
			indices = arrays[Mesh.ARRAY_INDEX]

		var triangle_count := indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
		for triangle_index in range(0, triangle_count, 64):
			var i0 := indices[triangle_index * 3] if not indices.is_empty() else triangle_index * 3
			var i1 := indices[triangle_index * 3 + 1] if not indices.is_empty() else triangle_index * 3 + 1
			var i2 := indices[triangle_index * 3 + 2] if not indices.is_empty() else triangle_index * 3 + 2
			var center := (
				accumulator.resolve_vertex_world(mesh_instance, arrays, i0, surface_index)
				+ accumulator.resolve_vertex_world(mesh_instance, arrays, i1, surface_index)
				+ accumulator.resolve_vertex_world(mesh_instance, arrays, i2, surface_index)
			) / 3.0
			centers["%d:%d:%d:%d" % [surface_index, i0, i1, i2]] = center
	return centers


func _triangle_center_world(
	accumulator: SurfaceEffectAccumulator,
	mesh_instance: MeshInstance3D,
	surface_index: int,
	triangle_indices: PackedInt32Array
) -> Vector3:
	var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
	return (
		accumulator.resolve_vertex_world(mesh_instance, arrays, triangle_indices[0], surface_index)
		+ accumulator.resolve_vertex_world(mesh_instance, arrays, triangle_indices[1], surface_index)
		+ accumulator.resolve_vertex_world(mesh_instance, arrays, triangle_indices[2], surface_index)
	) / 3.0


func _rest_triangle_center_local(
	root: Node3D,
	mesh_instance: MeshInstance3D,
	surface_index: int,
	triangle_indices: PackedInt32Array,
	barycentric: Vector3
) -> Vector3:
	var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var to_character := root.global_transform.affine_inverse() * mesh_instance.global_transform
	var p0 := to_character * vertices[triangle_indices[0]]
	var p1 := to_character * vertices[triangle_indices[1]]
	var p2 := to_character * vertices[triangle_indices[2]]
	return p0 * barycentric.x + p1 * barycentric.y + p2 * barycentric.z


func _uses_rest_volume_position(mesh_instance: MeshInstance3D, surface_index: int) -> bool:
	var material := mesh_instance.get_surface_override_material(surface_index) as ShaderMaterial
	_assert(material != null, "Sophia material was not rebound")
	return bool(material.get_shader_parameter("use_rest_volume_position"))


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
			var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			vertex_count += vertices.size()
		if vertex_count > best_vertex_count:
			best_vertex_count = vertex_count
			best_mesh = mesh_instance
	return best_mesh


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error(message)
	failed = true
