extends SceneTree

const MODEL_PATH := "res://external/kenney_animated_characters_3/src/Model/characterMedium.fbx"
const ANIMATION_PATHS := [
	"res://external/kenney_animated_characters_3/src/Animations/idle.fbx",
	"res://external/kenney_animated_characters_3/src/Animations/jump.fbx",
	"res://external/kenney_animated_characters_3/src/Animations/run.fbx",
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var model_scene: PackedScene = load(MODEL_PATH)
	var model_root: Node = model_scene.instantiate()
	get_root().add_child(model_root)

	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animation_players: Array[AnimationPlayer] = []
	_collect(model_root, meshes, skeletons, animation_players)

	print("kenney_model: meshes=%d skeletons=%d animation_players=%d" % [
		meshes.size(),
		skeletons.size(),
		animation_players.size(),
	])

	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		print("mesh: path=%s surfaces=%d aabb=%s skeleton_path=%s skin=%s" % [
			str(mesh_instance.get_path()),
			mesh.get_surface_count() if mesh != null else 0,
			str(mesh.get_aabb()) if mesh != null else "<none>",
			str(mesh_instance.skeleton),
			str(mesh_instance.skin != null),
		])
		if mesh != null:
			for surface_index in mesh.get_surface_count():
				var arrays: Array = mesh.surface_get_arrays(surface_index)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				var material := mesh.surface_get_material(surface_index)
				print("surface: mesh=%s index=%d vertices=%d normals=%d uvs=%d material=%s" % [
					mesh_instance.name,
					surface_index,
					vertices.size(),
					normals.size(),
					uvs.size(),
					str(material),
				])

	for skeleton in skeletons:
		print("skeleton: path=%s bones=%d" % [str(skeleton.get_path()), skeleton.get_bone_count()])

	for path in ANIMATION_PATHS:
		var animation_scene: PackedScene = load(path)
		var animation_root: Node = animation_scene.instantiate()
		get_root().add_child(animation_root)
		var animation_meshes: Array[MeshInstance3D] = []
		var animation_skeletons: Array[Skeleton3D] = []
		var players: Array[AnimationPlayer] = []
		_collect(animation_root, animation_meshes, animation_skeletons, players)
		print("kenney_animation: path=%s meshes=%d skeletons=%d players=%d" % [
			path,
			animation_meshes.size(),
			animation_skeletons.size(),
			players.size(),
		])
		for player in players:
			print("animation_player: path=%s animations=%s" % [
				str(player.get_path()),
				str(player.get_animation_list()),
			])
		animation_root.queue_free()

	model_root.queue_free()
	await process_frame
	quit(0)


func _collect(
	node: Node,
	meshes: Array[MeshInstance3D],
	skeletons: Array[Skeleton3D],
	animation_players: Array[AnimationPlayer]
) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
	if node is Skeleton3D:
		skeletons.append(node)
	if node is AnimationPlayer:
		animation_players.append(node)

	for child in node.get_children():
		_collect(child, meshes, skeletons, animation_players)
