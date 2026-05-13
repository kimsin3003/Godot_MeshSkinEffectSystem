extends SceneTree

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")
const QUATERNIUS_ADVENTURER_PATH := "res://external/quaternius_modular_women_glb/Adventurer.glb"

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root := _load_gltf_scene(QUATERNIUS_ADVENTURER_PATH)
	_assert(root != null, "failed to load Quaternius Adventurer GLB")
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	_collect(root, meshes, skeletons)
	_assert(meshes.size() >= 4, "Quaternius Adventurer mesh parts changed")
	_assert(skeletons.size() == 1, "Quaternius Adventurer skeleton missing")
	_assert(skeletons[0].get_bone_count() == 79, "Quaternius Adventurer skeleton bone count changed")

	var surface_count := 0
	for mesh_instance in meshes:
		_assert(mesh_instance.skin != null, "Quaternius mesh part is not skinned: " + mesh_instance.name)
		surface_count += mesh_instance.mesh.get_surface_count()
	_assert(surface_count >= 12, "Quaternius Adventurer should keep many material surfaces")

	var layer_column := _find_layered_surface_column(root as Node3D, meshes)
	_assert(not layer_column.is_empty(), "no layered real surface column found")

	var hit_local := Vector3(layer_column["x"], layer_column["y"], layer_column["inner_z"])
	var physics_hit_world := (root as Node3D).to_global(hit_local)
	var shot_direction := ((root as Node3D).global_transform.basis * Vector3(0, 0, 1)).normalized()

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 32768
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root as Node3D)
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "Quaternius layered asset memory exceeded 1 MB")

	var effect_id := 11
	var resolved_world := accumulator.add_surface_effect(effect_id, physics_hit_world, shot_direction, 0.12, 0.7)
	var resolved_local := (root as Node3D).to_local(resolved_world)
	_assert(
		resolved_local.z <= float(layer_column["outer_z"]) + 0.035,
		"real layered hit did not resolve to the incoming outer surface"
	)
	_assert(
		resolved_local.z < hit_local.z - 0.08,
		"real layered hit stayed too close to the approximate physics hit"
	)

	for mesh_instance in meshes:
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface_index)
			_assert(material is ShaderMaterial, "Quaternius surface override is not ShaderMaterial")
			_assert(material.get_shader_parameter("impact_count") == 1, "real layered event was not pushed to every material")
			var meta: PackedVector4Array = material.get_shader_parameter("impact_meta")
			_assert(meta.size() == 1 and is_equal_approx(meta[0].x, float(effect_id)), "real layered effect id missing")

	print("real_layered_garment: meshes=%d surfaces=%d bones=%d samples=%d memory=%d depth=%.3f hit_z=%.3f outer_z=%.3f resolved_z=%.3f source_surfaces=%d" % [
		meshes.size(),
		surface_count,
		skeletons[0].get_bone_count(),
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
		float(layer_column["depth"]),
		hit_local.z,
		float(layer_column["outer_z"]),
		resolved_local.z,
		int(layer_column["surface_count"]),
	])

	root.queue_free()
	accumulator.queue_free()
	quit(1 if failed else 0)


func _load_gltf_scene(path: String) -> Node:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	if error != OK:
		push_error("failed to parse glTF: %s error=%d" % [path, error])
		return null
	return document.generate_scene(state)


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
				"outer_z": float(entry["min_z"]),
				"depth": depth,
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


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
