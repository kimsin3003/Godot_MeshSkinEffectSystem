extends SceneTree

const SOPHIA_SCENE_PATH := "res://addons/gdquest_sophia/sophia_skin.tscn"
const SOPHIA_GLB_PATH := "res://addons/gdquest_sophia/model/sophia.glb"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_inspect_scene(SOPHIA_SCENE_PATH)
	_inspect_scene(SOPHIA_GLB_PATH)
	quit(0)


func _inspect_scene(path: String) -> void:
	var packed_scene: PackedScene = load(path)
	var root: Node = packed_scene.instantiate()
	get_root().add_child(root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animation_players: Array[AnimationPlayer] = []
	var animation_trees: Array[AnimationTree] = []
	_collect(root, meshes, skeletons, animation_players, animation_trees)

	var surface_count := 0
	var vertex_count := 0
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		surface_count += mesh.get_surface_count()
		for surface_index in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			vertex_count += vertices.size()
			print("sophia_surface: source=%s mesh=%s index=%d vertices=%d material=%s skeleton_path=%s skin=%s" % [
				path,
				str(mesh_instance.get_path()),
				surface_index,
				vertices.size(),
				str(mesh.surface_get_material(surface_index)),
				str(mesh_instance.skeleton),
				str(mesh_instance.skin != null),
			])

	print("sophia_asset: source=%s meshes=%d surfaces=%d vertices=%d skeletons=%d animation_players=%d animation_trees=%d" % [
		path,
		meshes.size(),
		surface_count,
		vertex_count,
		skeletons.size(),
		animation_players.size(),
		animation_trees.size(),
	])

	for skeleton in skeletons:
		print("sophia_skeleton: source=%s path=%s bones=%d" % [
			path,
			str(skeleton.get_path()),
			skeleton.get_bone_count(),
		])

	for player in animation_players:
		print("sophia_animation_player: source=%s path=%s animations=%s" % [
			path,
			str(player.get_path()),
			str(player.get_animation_list()),
		])

	root.queue_free()
	await process_frame


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
