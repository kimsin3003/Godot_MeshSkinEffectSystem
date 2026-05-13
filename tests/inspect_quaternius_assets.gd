extends SceneTree

const CANDIDATE_PATHS := [
	"res://external/quaternius_modular_women_glb/Soldier.glb",
	"res://external/quaternius_modular_women_glb/Adventurer.glb",
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for path in CANDIDATE_PATHS:
		_inspect_path(path)
	quit()


func _inspect_path(path: String) -> void:
	var root := _load_gltf_scene(path)
	print("asset_path=%s loaded=%s" % [path, root != null])
	if root == null:
		return

	get_root().add_child(root)
	var meshes: Array[MeshInstance3D] = []
	var skeletons: Array[Skeleton3D] = []
	var animations: Array[AnimationPlayer] = []
	_collect(root, meshes, skeletons, animations)
	print("  meshes=%d skeletons=%d animation_players=%d" % [meshes.size(), skeletons.size(), animations.size()])
	for mesh_instance in meshes:
		var vertex_count := 0
		var surface_count := 0
		if mesh_instance.mesh != null:
			surface_count = mesh_instance.mesh.get_surface_count()
			for surface_index in surface_count:
				var arrays := mesh_instance.mesh.surface_get_arrays(surface_index)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				vertex_count += vertices.size()
		print("  mesh=%s surfaces=%d vertices=%d aabb=%s skin=%s" % [
			mesh_instance.name,
			surface_count,
			vertex_count,
			mesh_instance.get_aabb(),
			mesh_instance.skin != null,
		])
	for skeleton in skeletons:
		print("  skeleton=%s bones=%d" % [skeleton.name, skeleton.get_bone_count()])
	root.queue_free()


func _load_gltf_scene(path: String) -> Node:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	if error != OK:
		push_error("failed to parse glTF: %s error=%d" % [path, error])
		return null
	return document.generate_scene(state)


func _collect(
	node: Node,
	meshes: Array[MeshInstance3D],
	skeletons: Array[Skeleton3D],
	animations: Array[AnimationPlayer]
) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
	if node is Skeleton3D:
		skeletons.append(node)
	if node is AnimationPlayer:
		animations.append(node)

	for child in node.get_children():
		_collect(child, meshes, skeletons, animations)
