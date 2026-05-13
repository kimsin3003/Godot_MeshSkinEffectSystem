extends SceneTree

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")
const SOPHIA_SCENE_PATH := "res://addons/gdquest_sophia/sophia_skin.tscn"
const KENNEY_MODEL_PATH := "res://external/kenney_animated_characters_3/src/Model/characterMedium.fbx"
const KENNEY_ANIMATION_PATHS := [
	"res://external/kenney_animated_characters_3/src/Animations/idle.fbx",
	"res://external/kenney_animated_characters_3/src/Animations/jump.fbx",
	"res://external/kenney_animated_characters_3/src/Animations/run.fbx",
]

var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_sophia_multi_slot_skinned_character()
	_test_kenney_skinned_character_and_animation_assets()
	quit(1 if failed else 0)


func _test_sophia_multi_slot_skinned_character() -> void:
	var root := _instantiate_scene(SOPHIA_SCENE_PATH)
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animation_players: Array[AnimationPlayer] = []
	var animation_trees: Array[AnimationTree] = []
	_collect(root, meshes, skeletons, animation_players, animation_trees)

	var mesh_instance := _find_largest_mesh(meshes)
	_assert(mesh_instance != null, "Sophia mesh not found")
	_assert(mesh_instance.mesh.get_surface_count() == 4, "Sophia must keep four material slots")
	_assert(skeletons.size() == 1, "Sophia skeleton not found")
	_assert(skeletons[0].get_bone_count() == 93, "Sophia skeleton bone count changed")
	_assert(animation_players.size() == 1, "Sophia animation player not found")
	_assert(animation_players[0].get_animation_list().size() >= 8, "Sophia animations were not imported")
	_assert(animation_trees.size() == 1, "Sophia skin scene animation tree not found")

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 8192
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)

	_assert(accumulator.get_material_instance_count() == 4, "Sophia material slots were not rebound")
	_assert(accumulator.get_sample_count() > 5000, "Sophia sampler produced too few samples")
	_assert(accumulator.get_sample_count() <= accumulator.sample_limit, "Sophia sampler exceeded the sample cap")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "Sophia memory estimate exceeded 1 MB")

	var aabb: AABB = mesh_instance.mesh.get_aabb()
	var center_local: Vector3 = aabb.get_center()
	var hit_world: Vector3 = mesh_instance.to_global(center_local)
	var shot_direction_world := Vector3(1.0, 0.0, 0.0)
	var resolved_world := accumulator.add_impact(hit_world, shot_direction_world, 0.12, 1.0)
	var resolved_local: Vector3 = mesh_instance.to_local(resolved_world)
	_assert(resolved_local.x <= center_local.x - 0.10, "Sophia hit was not moved toward the incoming exterior")

	accumulator.set_sand_state(Vector3(1, 0.2, 0), aabb.position.x, 0.85)
	var textured_slot_count := 0
	var normal_slot_count := 0
	var roughness_slot_count := 0
	var orm_slot_count := 0
	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_surface_override_material(surface_index)
		_assert(material is ShaderMaterial, "Sophia surface override is not ShaderMaterial")
		_assert(material.get_shader_parameter("impact_count") == 1, "Sophia impact state not pushed to every slot")
		_assert(is_equal_approx(material.get_shader_parameter("sand_amount"), 0.85), "Sophia sand state not pushed to every slot")
		if material.get_shader_parameter("use_base_texture"):
			textured_slot_count += 1
		if material.get_shader_parameter("use_normal_texture"):
			normal_slot_count += 1
		if material.get_shader_parameter("use_roughness_texture"):
			roughness_slot_count += 1
		if material.get_shader_parameter("use_orm_texture"):
			orm_slot_count += 1
	_assert(textured_slot_count > 0, "Sophia albedo texture was not preserved")
	_assert(normal_slot_count > 0, "Sophia normal texture was not preserved")
	_assert(roughness_slot_count > 0 or orm_slot_count > 0, "Sophia roughness/ORM texture was not preserved")

	accumulator.rebuild_for_character(root)
	for surface_index in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_surface_override_material(surface_index)
		_assert(material.get_shader_parameter("impact_count") == 0, "Sophia clothing rebuild did not clear impacts")

	print("real_sophia: meshes=%d surfaces=%d bones=%d animations=%d samples=%d memory=%d resolved_x=%.3f center_x=%.3f textured=%d normal=%d roughness=%d orm=%d" % [
		meshes.size(),
		mesh_instance.mesh.get_surface_count(),
		skeletons[0].get_bone_count(),
		animation_players[0].get_animation_list().size(),
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
		resolved_local.x,
		center_local.x,
		textured_slot_count,
		normal_slot_count,
		roughness_slot_count,
		orm_slot_count,
	])

	root.queue_free()
	accumulator.queue_free()


func _test_kenney_skinned_character_and_animation_assets() -> void:
	var root := _instantiate_scene(KENNEY_MODEL_PATH)
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animation_players: Array[AnimationPlayer] = []
	var animation_trees: Array[AnimationTree] = []
	_collect(root, meshes, skeletons, animation_players, animation_trees)

	var mesh_instance := _find_largest_mesh(meshes)
	_assert(mesh_instance != null, "Kenney mesh not found")
	_assert(mesh_instance.mesh.get_surface_count() == 1, "Kenney model surface count changed")
	_assert(skeletons.size() == 1, "Kenney skeleton not found")
	_assert(skeletons[0].get_bone_count() == 58, "Kenney skeleton bone count changed")
	_assert(mesh_instance.skin != null, "Kenney mesh is not skinned")

	var accumulator: SurfaceEffectAccumulator = SurfaceEffectAccumulatorScript.new()
	accumulator.sample_limit = 8192
	get_root().add_child(accumulator)
	accumulator.rebuild_for_character(root)
	_assert(accumulator.get_sample_count() > 1000, "Kenney sampler produced too few samples")
	_assert(accumulator.estimate_memory_bytes() < 1024 * 1024, "Kenney memory estimate exceeded 1 MB")

	var imported_animation_count := 0
	for path in KENNEY_ANIMATION_PATHS:
		var animation_root := _instantiate_scene(path)
		get_root().add_child(animation_root)
		var anim_meshes: Array[MeshInstance3D] = []
		var anim_skeletons: Array[Skeleton3D] = []
		var anim_players: Array[AnimationPlayer] = []
		var anim_trees: Array[AnimationTree] = []
		_collect(animation_root, anim_meshes, anim_skeletons, anim_players, anim_trees)
		_assert(anim_meshes.is_empty(), "Kenney animation file unexpectedly contains visual mesh")
		_assert(anim_skeletons.size() == 1, "Kenney animation skeleton missing")
		_assert(anim_players.size() == 1, "Kenney animation player missing")
		imported_animation_count += anim_players[0].get_animation_list().size()
		animation_root.queue_free()

	print("real_kenney: meshes=%d surfaces=%d bones=%d samples=%d memory=%d animation_clips=%d" % [
		meshes.size(),
		mesh_instance.mesh.get_surface_count(),
		skeletons[0].get_bone_count(),
		accumulator.get_sample_count(),
		accumulator.estimate_memory_bytes(),
		imported_animation_count,
	])

	root.queue_free()
	accumulator.queue_free()


func _instantiate_scene(path: String) -> Node:
	var packed_scene: PackedScene = load(path)
	_assert(packed_scene != null, "failed to load scene: " + path)
	return packed_scene.instantiate()


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


func _assert(condition: bool, message: String) -> void:
	if condition:
		return

	push_error(message)
	failed = true
