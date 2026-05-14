class_name SurfaceEffectAccumulator
extends Node

const MAX_IMPACTS := 32
const DEFAULT_IMPACT_RADIUS_M := 0.05
const DEFAULT_SAMPLE_LIMIT := 8192
const DEFAULT_EFFECT_VOLUME_RESOLUTION := 48
const EFFECT_BULLET_IMPACT_ID := 1
const EFFECT_SAND_ID := 2
const EMPTY_EFFECT_VOLUME_COLOR := Color(0.0, 0.0, 0.0, 0.0)
const REST_VOLUME_META := "_surface_effect_rest_volume"

@export var character_root: Node3D
@export var deformation_provider: Node
@export var sample_limit := DEFAULT_SAMPLE_LIMIT
@export var effect_volume_resolution := DEFAULT_EFFECT_VOLUME_RESOLUTION
@export var use_rest_volume_attributes := true
@export var impact_radius_m := DEFAULT_IMPACT_RADIUS_M
@export var sand_front_softness := 0.45
@export var minimum_splat_voxel_span := 1.25
@export var max_effect_volume_layer_uploads_per_frame := 2
@export var max_sand_accumulation_samples := 4096
@export var sand_exposure_cell_size := 0.08
@export var sand_exposure_depth := 0.12
@export var shader: Shader = preload("res://shaders/surface_effects.gdshader")

var sampler := MeshSurfaceSampler.new()
var shader_materials: Array[ShaderMaterial] = []
var surface_events: Array[Dictionary] = []
var impact_spheres := PackedVector4Array()
var impact_dirs := PackedVector4Array()
var impact_meta := PackedVector4Array()
var impact_cursor := 0
var effect_volume_texture: Texture2DArray
var effect_volume_images: Array[Image] = []
var effect_volume_layer_data: Array[PackedByteArray] = []
var effect_volume_dirty_layers := {}
var pending_effect_volume_layers := {}
var effect_volume_origin_local := Vector3(-1.0, -1.0, -1.0)
var effect_volume_size_local := Vector3(2.0, 2.0, 2.0)
var effect_volume_inv_size := Vector3(0.5, 0.5, 0.5)
var effect_volume_dirty := true
var rest_attribute_vertex_count := 0
var total_surface_event_count := 0
var sand_direction_world := Vector3(1, 0, 0)
var sand_front := -10.0
var sand_amount := 0.0
var has_sand_accumulation_cursor := false
var sand_accumulation_direction_world := Vector3.ZERO
var sand_accumulated_front := -INF
var sand_accumulated_amount := 0.0
var has_sand_exposure_map := false
var sand_exposure_direction_world := Vector3.ZERO
var sand_exposure_axis_u := Vector3.RIGHT
var sand_exposure_axis_v := Vector3.UP
var sand_exposure_min_travel_by_cell := {}
var has_synced_character_transform := false
var last_synced_character_transform := Transform3D.IDENTITY


func _ready() -> void:
	if character_root != null:
		rebuild_for_character(character_root)


func _process(_delta: float) -> void:
	if character_root != null and not shader_materials.is_empty():
		_flush_pending_effect_volume_layers(max_effect_volume_layer_uploads_per_frame)
		_sync_transform_params_if_needed()


func rebuild_for_character(root: Node3D) -> void:
	character_root = root
	clear_impacts(false)
	sampler.rebuild(root, sample_limit)
	_rebuild_effect_volume_storage(root)
	_ensure_rest_volume_attributes(root)
	_rebuild_materials(root)
	_sync_all_shader_params()


func get_sample_count() -> int:
	return sampler.get_sample_count()


func get_material_instance_count() -> int:
	return shader_materials.size()


func get_impact_count() -> int:
	return total_surface_event_count


func estimate_memory_bytes() -> int:
	var sampler_bytes := sampler.estimate_memory_bytes()
	var impact_bytes := MAX_IMPACTS * 32
	var volume_resolution := _clamped_effect_volume_resolution()
	var volume_bytes := volume_resolution * volume_resolution * volume_resolution * 4
	var rest_attribute_bytes := rest_attribute_vertex_count * 16 if use_rest_volume_attributes else 0
	return sampler_bytes + impact_bytes + volume_bytes + rest_attribute_bytes


func get_minimum_stable_effect_radius() -> float:
	var resolution := float(_clamped_effect_volume_resolution())
	var voxel_size := effect_volume_size_local / resolution
	return max(max(voxel_size.x, voxel_size.y), voxel_size.z) * minimum_splat_voxel_span


func clear_impacts(reset_volume: bool = true) -> void:
	surface_events.clear()
	impact_spheres.clear()
	impact_dirs.clear()
	impact_meta.clear()
	impact_cursor = 0
	total_surface_event_count = 0
	effect_volume_dirty = true
	_reset_sand_accumulation_cursor()
	if reset_volume:
		_rebuild_effect_volume()
	_sync_event_uniform_params()


func add_impact(
	physics_hit_world: Vector3,
	shot_direction_world: Vector3,
	radius_m: float = impact_radius_m,
	strength: float = 1.0
) -> Vector3:
	return add_surface_effect(EFFECT_BULLET_IMPACT_ID, physics_hit_world, shot_direction_world, radius_m, strength)


func add_surface_effect(
	effect_id: int,
	physics_hit_world: Vector3,
	shot_direction_world: Vector3,
	radius_m: float = impact_radius_m,
	strength: float = 1.0
) -> Vector3:
	if character_root == null:
		return physics_hit_world

	var shot_dir_world := shot_direction_world
	if shot_dir_world.length_squared() <= 0.000001:
		shot_dir_world = Vector3.FORWARD

	var effective_radius := _effective_splat_radius(radius_m)
	var resolved_world := sampler.find_outer_surface(
		physics_hit_world,
		shot_dir_world,
		effective_radius * 1.6
	)
	_store_surface_event(effect_id, resolved_world, shot_dir_world, effective_radius, strength, {})
	return resolved_world


func add_surface_effect_at_visual_surface(
	effect_id: int,
	visual_hit_world: Vector3,
	effect_direction_world: Vector3,
	radius_m: float = impact_radius_m,
	strength: float = 1.0
) -> Vector3:
	if character_root == null:
		return visual_hit_world

	var direction_world := effect_direction_world
	if direction_world.length_squared() <= 0.000001:
		direction_world = Vector3.FORWARD

	_store_surface_event(effect_id, visual_hit_world, direction_world, _effective_splat_radius(radius_m), strength, {})
	return visual_hit_world


func add_surface_effect_at_triangle(
	effect_id: int,
	mesh_instance: MeshInstance3D,
	surface_index: int,
	triangle_indices: PackedInt32Array,
	barycentric: Vector3,
	effect_direction_world: Vector3,
	radius_m: float = impact_radius_m,
	strength: float = 1.0,
	visual_hit_world_override: Variant = null,
	rest_center_local_override: Variant = null
) -> Vector3:
	if character_root == null or mesh_instance == null or triangle_indices.size() != 3:
		return Vector3.ZERO

	var direction_world := effect_direction_world
	if direction_world.length_squared() <= 0.000001:
		direction_world = Vector3.FORWARD

	var attachment := {
		"mesh_instance": mesh_instance,
		"surface_index": surface_index,
		"triangle_indices": PackedInt32Array(triangle_indices),
		"barycentric": barycentric,
	}
	var visual_hit_world: Vector3
	if visual_hit_world_override is Vector3:
		visual_hit_world = visual_hit_world_override
	else:
		visual_hit_world = _resolve_attachment_world(attachment)

	var rest_center_local: Vector3
	if rest_center_local_override is Vector3:
		rest_center_local = rest_center_local_override
	else:
		rest_center_local = _resolve_attachment_rest_local(attachment)

	_store_surface_event_local(
		effect_id,
		rest_center_local,
		direction_world,
		_effective_splat_radius(radius_m),
		strength,
		attachment,
		character_root.to_local(visual_hit_world)
	)
	return visual_hit_world


func resolve_vertex_world(
	mesh_instance: MeshInstance3D,
	arrays: Array,
	vertex_index: int,
	surface_index: int = -1
) -> Vector3:
	var provider_position: Variant = _try_resolve_provider_vertex_world(mesh_instance, surface_index, arrays, vertex_index)
	if provider_position is Vector3:
		return provider_position
	return mesh_instance.to_global(_resolve_vertex_mesh_local(mesh_instance, arrays, vertex_index))


func resolve_surface_vertices_world(
	mesh_instance: MeshInstance3D,
	arrays: Array,
	surface_index: int = -1,
	pose_cache: Variant = null
) -> PackedVector3Array:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var world_vertices := PackedVector3Array()
	world_vertices.resize(vertices.size())

	if _uses_custom_deformation_provider(mesh_instance):
		for vertex_index in vertices.size():
			world_vertices[vertex_index] = resolve_vertex_world(mesh_instance, arrays, vertex_index, surface_index)
		return world_vertices

	if mesh_instance.skin == null:
		for vertex_index in vertices.size():
			world_vertices[vertex_index] = mesh_instance.to_global(vertices[vertex_index])
		return world_vertices

	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	if bones.is_empty() or weights.is_empty():
		for vertex_index in vertices.size():
			world_vertices[vertex_index] = mesh_instance.to_global(vertices[vertex_index])
		return world_vertices

	var skeleton := _find_skeleton_for_mesh(mesh_instance)
	if skeleton == null:
		for vertex_index in vertices.size():
			world_vertices[vertex_index] = mesh_instance.to_global(vertices[vertex_index])
		return world_vertices

	var influences_per_vertex := int(bones.size() / max(vertices.size(), 1))
	if influences_per_vertex <= 0:
		for vertex_index in vertices.size():
			world_vertices[vertex_index] = mesh_instance.to_global(vertices[vertex_index])
		return world_vertices

	var bind_count := mesh_instance.skin.get_bind_count()
	var bind_bone_indices := PackedInt32Array()
	bind_bone_indices.resize(bind_count)
	var bind_poses: Array[Transform3D] = []
	bind_poses.resize(bind_count)
	for bind_index in bind_count:
		bind_bone_indices[bind_index] = _resolve_skin_bone_index(mesh_instance.skin, skeleton, bind_index)
		bind_poses[bind_index] = mesh_instance.skin.get_bind_pose(bind_index)

	var effective_pose_cache: Dictionary = {}
	if pose_cache is Dictionary:
		effective_pose_cache = pose_cache

	var skeleton_id := skeleton.get_instance_id()
	var bone_poses: Array = []
	if effective_pose_cache.has(skeleton_id):
		bone_poses = effective_pose_cache[skeleton_id]
	else:
		bone_poses.resize(skeleton.get_bone_count())
		for bone_index in skeleton.get_bone_count():
			bone_poses[bone_index] = skeleton.get_bone_global_pose(bone_index)
		effective_pose_cache[skeleton_id] = bone_poses

	for vertex_index in vertices.size():
		var base_position := vertices[vertex_index]
		var skeleton_local := Vector3.ZERO
		var total_weight := 0.0
		var first_influence := vertex_index * influences_per_vertex
		for influence_index in influences_per_vertex:
			var array_index := first_influence + influence_index
			if array_index >= bones.size() or array_index >= weights.size():
				break
			var weight := weights[array_index]
			if weight <= 0.0001:
				continue
			var bind_index := bones[array_index]
			if bind_index < 0 or bind_index >= bind_bone_indices.size():
				continue
			var resolved_bone_index := bind_bone_indices[bind_index]
			if resolved_bone_index < 0 or resolved_bone_index >= bone_poses.size():
				continue
			var bone_pose: Transform3D = bone_poses[resolved_bone_index]
			skeleton_local += (bone_pose * (bind_poses[bind_index] * base_position)) * weight
			total_weight += weight

		if total_weight <= 0.0001:
			world_vertices[vertex_index] = mesh_instance.to_global(base_position)
		else:
			world_vertices[vertex_index] = skeleton.global_transform * (skeleton_local / total_weight)

	return world_vertices


func _uses_custom_deformation_provider(mesh_instance: MeshInstance3D) -> bool:
	return (
		(deformation_provider != null and deformation_provider.has_method("resolve_surface_vertex_world"))
		or mesh_instance.has_method("resolve_surface_vertex_world")
	)


func _store_surface_event(
	effect_id: int,
	center_world: Vector3,
	direction_world: Vector3,
	radius_m: float,
	strength: float,
	attachment: Dictionary
) -> void:
	var local_center := character_root.to_local(center_world)
	_store_surface_event_local(effect_id, local_center, direction_world, radius_m, strength, attachment, local_center)


func _store_surface_event_local(
	effect_id: int,
	center_local: Vector3,
	direction_world: Vector3,
	radius_m: float,
	strength: float,
	attachment: Dictionary,
	debug_center_local: Vector3
) -> void:
	var local_dir := (character_root.global_transform.basis.inverse() * direction_world.normalized()).normalized()
	var record := {
		"effect_id": effect_id,
		"center_local": center_local,
		"debug_center_local": debug_center_local,
		"direction_local": local_dir,
		"radius": radius_m,
		"strength": clamp(strength, 0.0, 4.0),
		"attachment": attachment,
	}

	total_surface_event_count += 1
	if surface_events.size() < MAX_IMPACTS:
		surface_events.append(record)
	else:
		surface_events[impact_cursor] = record
		impact_cursor = (impact_cursor + 1) % MAX_IMPACTS

	_rebuild_event_uniform_arrays()
	_splat_record_to_effect_volume(record)
	_sync_event_uniform_params()


func _effective_splat_radius(radius_m: float) -> float:
	return max(radius_m, get_minimum_stable_effect_radius())


func set_sand_state(direction_world: Vector3, front: float, amount: float) -> void:
	var next_direction: Vector3 = sand_direction_world
	if direction_world.length_squared() > 0.000001:
		next_direction = direction_world.normalized()
	var next_amount: float = clamp(amount, 0.0, 1.0)
	var changed: bool = (
		next_direction.distance_squared_to(sand_direction_world) > 0.000001
		or abs(front - sand_front) > 0.000001
		or abs(next_amount - sand_amount) > 0.000001
	)
	if not changed:
		return

	sand_direction_world = next_direction
	sand_front = front
	sand_amount = next_amount
	if sand_amount > 0.0:
		var full_accumulation := (
			not has_sand_accumulation_cursor
			or sand_direction_world.distance_squared_to(sand_accumulation_direction_world) > 0.000001
			or sand_front < sand_accumulated_front - 0.000001
			or sand_amount > sand_accumulated_amount + 0.000001
		)
		var min_travel := -INF if full_accumulation else sand_accumulated_front
		_ensure_sand_exposure_map()
		_accumulate_sand_to_effect_volume(min_travel)
		has_sand_accumulation_cursor = true
		sand_accumulation_direction_world = sand_direction_world
		sand_accumulated_front = sand_front
		sand_accumulated_amount = max(sand_accumulated_amount, sand_amount)
	_sync_sand_params()


func _rebuild_materials(root: Node) -> void:
	shader_materials.clear()
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)

	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue

		for surface_index in mesh.get_surface_count():
			var source_material := _read_surface_material(mesh_instance, surface_index)
			var material := ShaderMaterial.new()
			material.shader = shader
			_bind_source_material(material, source_material)
			mesh_instance.set_surface_override_material(surface_index, material)
			shader_materials.append(material)


func _collect_meshes(node: Node, out_meshes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		out_meshes.append(node)

	for child in node.get_children():
		_collect_meshes(child, out_meshes)


func _read_surface_material(mesh_instance: MeshInstance3D, surface_index: int) -> Material:
	var override_material := mesh_instance.get_surface_override_material(surface_index)
	if override_material is BaseMaterial3D:
		return override_material
	if mesh_instance.mesh != null:
		var source_material := mesh_instance.mesh.surface_get_material(surface_index)
		if source_material != null:
			return source_material
	return override_material


func _bind_source_material(target_material: ShaderMaterial, source_material: Material) -> void:
	if not source_material is BaseMaterial3D:
		target_material.set_shader_parameter("base_color", Color(0.72, 0.73, 0.76, 1.0))
		target_material.set_shader_parameter("use_base_texture", false)
		return

	var base_material := source_material as BaseMaterial3D
	target_material.set_shader_parameter("base_color", base_material.albedo_color)
	_set_optional_texture(target_material, "base_texture", "use_base_texture", base_material.albedo_texture)

	var normal_enabled: bool = base_material.get("normal_enabled")
	if normal_enabled:
		_set_optional_texture(target_material, "normal_texture", "use_normal_texture", base_material.get("normal_texture"))
	else:
		target_material.set_shader_parameter("use_normal_texture", false)
	target_material.set_shader_parameter("normal_scale", float(base_material.get("normal_scale")))

	target_material.set_shader_parameter("roughness_value", base_material.roughness)
	_set_optional_texture(target_material, "roughness_texture", "use_roughness_texture", base_material.get("roughness_texture"))
	target_material.set_shader_parameter("roughness_texture_channel", int(base_material.get("roughness_texture_channel")))
	_set_optional_texture(target_material, "orm_texture", "use_orm_texture", base_material.get("orm_texture"))
	target_material.set_shader_parameter("metallic_value", base_material.metallic)
	_set_optional_texture(target_material, "metallic_texture", "use_metallic_texture", base_material.get("metallic_texture"))
	target_material.set_shader_parameter("metallic_texture_channel", int(base_material.get("metallic_texture_channel")))

	var emission_enabled: bool = base_material.get("emission_enabled")
	if emission_enabled:
		target_material.set_shader_parameter("emission_color", base_material.get("emission"))
		target_material.set_shader_parameter("emission_energy", float(base_material.get("emission_energy_multiplier")))
		_set_optional_texture(target_material, "emission_texture", "use_emission_texture", base_material.get("emission_texture"))
	else:
		target_material.set_shader_parameter("emission_color", Color.BLACK)
		target_material.set_shader_parameter("emission_energy", 0.0)
		target_material.set_shader_parameter("use_emission_texture", false)

	target_material.set_shader_parameter("alpha_scissor_threshold", base_material.alpha_scissor_threshold)


func _set_optional_texture(
	target_material: ShaderMaterial,
	texture_parameter: StringName,
	flag_parameter: StringName,
	texture: Texture2D
) -> void:
	if texture != null:
		target_material.set_shader_parameter(texture_parameter, texture)
		target_material.set_shader_parameter(flag_parameter, true)
	else:
		target_material.set_shader_parameter(flag_parameter, false)


func _sync_all_shader_params() -> void:
	_sync_transform_params()
	_sync_surface_effect_resource_params()
	_sync_event_uniform_params()
	_sync_sand_params()


func _sync_transform_params_if_needed() -> void:
	var character_transform := Transform3D.IDENTITY
	if character_root != null:
		character_transform = character_root.global_transform
	if has_synced_character_transform and character_transform == last_synced_character_transform:
		return
	_sync_transform_params()


func _sync_transform_params() -> void:
	var character_inverse_world := Transform3D.IDENTITY
	if character_root != null:
		character_inverse_world = character_root.global_transform.affine_inverse()
		last_synced_character_transform = character_root.global_transform
	else:
		last_synced_character_transform = Transform3D.IDENTITY
	has_synced_character_transform = true

	for material in shader_materials:
		material.set_shader_parameter("character_inverse_world", character_inverse_world)


func _sync_impact_params() -> void:
	_sync_surface_effect_resource_params()
	_sync_event_uniform_params()


func _sync_surface_effect_resource_params() -> void:
	for material in shader_materials:
		material.set_shader_parameter("use_surface_effect_volume", effect_volume_texture != null)
		if effect_volume_texture != null:
			material.set_shader_parameter("surface_effect_volume", effect_volume_texture)
			material.set_shader_parameter("effect_volume_depth", float(_clamped_effect_volume_resolution()))
		material.set_shader_parameter("use_rest_volume_position", use_rest_volume_attributes and rest_attribute_vertex_count > 0)
		material.set_shader_parameter("effect_volume_origin_local", effect_volume_origin_local)
		material.set_shader_parameter("effect_volume_inv_size", effect_volume_inv_size)


func _sync_event_uniform_params() -> void:
	for material in shader_materials:
		material.set_shader_parameter("impact_count", impact_spheres.size())
		material.set_shader_parameter("impact_spheres", impact_spheres)
		material.set_shader_parameter("impact_dirs", impact_dirs)
		material.set_shader_parameter("impact_meta", impact_meta)


func _rebuild_event_uniform_arrays() -> void:
	impact_spheres.clear()
	impact_dirs.clear()
	impact_meta.clear()

	for record in surface_events:
		var center_local: Vector3 = record["debug_center_local"]
		var direction_local: Vector3 = record["direction_local"]
		impact_spheres.append(Vector4(center_local.x, center_local.y, center_local.z, float(record["radius"])))
		impact_dirs.append(Vector4(direction_local.x, direction_local.y, direction_local.z, float(record["strength"])))
		impact_meta.append(Vector4(float(record["effect_id"]), 0.0, 0.0, 0.0))


func sample_effect_volume_local(local_position: Vector3) -> Color:
	if effect_volume_layer_data.is_empty():
		return EMPTY_EFFECT_VOLUME_COLOR

	var uvw := _local_to_effect_volume_uv(local_position)
	if uvw.x < 0.0 or uvw.x > 1.0 or uvw.y < 0.0 or uvw.y > 1.0 or uvw.z < 0.0 or uvw.z > 1.0:
		return EMPTY_EFFECT_VOLUME_COLOR

	var resolution := _clamped_effect_volume_resolution()
	var x := clampi(int(floor(uvw.x * float(resolution))), 0, resolution - 1)
	var y := clampi(int(floor(uvw.y * float(resolution))), 0, resolution - 1)
	var z := clampi(int(floor(uvw.z * float(resolution))), 0, resolution - 1)
	var data := effect_volume_layer_data[z]
	var byte_index := _effect_volume_byte_index(x, y, 0)
	return Color(
		float(data[byte_index]) / 255.0,
		float(data[byte_index + 1]) / 255.0,
		float(data[byte_index + 2]) / 255.0,
		float(data[byte_index + 3]) / 255.0
	)


func _rebuild_effect_volume_storage(root: Node3D) -> void:
	_update_effect_volume_bounds(root)
	effect_volume_images.clear()
	effect_volume_layer_data.clear()

	var resolution := _clamped_effect_volume_resolution()
	for z in resolution:
		var data := PackedByteArray()
		data.resize(resolution * resolution * 4)
		data.fill(0)
		var image := Image.create_from_data(resolution, resolution, false, Image.FORMAT_RGBA8, data)
		effect_volume_layer_data.append(data)
		effect_volume_images.append(image)

	effect_volume_texture = Texture2DArray.new()
	effect_volume_texture.create_from_images(effect_volume_images)
	effect_volume_dirty = false
	effect_volume_dirty_layers.clear()
	pending_effect_volume_layers.clear()


func _update_effect_volume_bounds(root: Node3D) -> void:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)

	var has_bounds := false
	var bounds := AABB()
	var to_character := root.global_transform.affine_inverse()
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue

		var to_local := to_character * mesh_instance.global_transform
		for corner in _aabb_corners(mesh.get_aabb()):
			var local_corner := to_local * corner
			if not has_bounds:
				bounds = AABB(local_corner, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(local_corner)

	if not has_bounds:
		bounds = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))

	var margin: float = max(impact_radius_m * 2.0, 0.12)
	bounds = bounds.grow(margin)
	effect_volume_origin_local = bounds.position
	effect_volume_size_local = Vector3(
		max(bounds.size.x, 0.001),
		max(bounds.size.y, 0.001),
		max(bounds.size.z, 0.001)
	)
	effect_volume_inv_size = Vector3(
		1.0 / effect_volume_size_local.x,
		1.0 / effect_volume_size_local.y,
		1.0 / effect_volume_size_local.z
	)


func _rebuild_effect_volume() -> void:
	if effect_volume_texture == null or effect_volume_layer_data.is_empty():
		return

	for layer_index in effect_volume_layer_data.size():
		effect_volume_layer_data[layer_index].fill(0)

	for event_index in impact_spheres.size():
		_splat_event_to_effect_volume(event_index)

	_update_all_effect_volume_layers()
	effect_volume_dirty = false


func _splat_record_to_effect_volume(record: Dictionary) -> void:
	if effect_volume_texture == null or effect_volume_layer_data.is_empty():
		return

	var center_local: Vector3 = record["center_local"]
	effect_volume_dirty_layers.clear()
	_splat_effect_to_volume(
		int(record["effect_id"]),
		center_local,
		float(record["radius"]),
		float(record["strength"])
	)
	_queue_dirty_effect_volume_layers()
	effect_volume_dirty = false


func _splat_event_to_effect_volume(event_index: int) -> void:
	var sphere := impact_spheres[event_index]
	var radius: float = max(sphere.w, 0.001)
	var center := Vector3(sphere.x, sphere.y, sphere.z)
	_splat_effect_to_volume(
		int(floor(impact_meta[event_index].x + 0.5)),
		center,
		radius,
		clamp(impact_dirs[event_index].w, 0.0, 4.0)
	)


func _splat_effect_to_volume(effect_id: int, center: Vector3, radius: float, strength: float) -> void:
	var uvw := _local_to_effect_volume_uv(center)
	var resolution := _clamped_effect_volume_resolution()
	var effective_radius: float = max(radius, 0.001)
	var radius_uv := Vector3(
		effective_radius * effect_volume_inv_size.x,
		effective_radius * effect_volume_inv_size.y,
		effective_radius * effect_volume_inv_size.z
	)

	var min_x := clampi(int(floor((uvw.x - radius_uv.x) * float(resolution))), 0, resolution - 1)
	var max_x := clampi(int(ceil((uvw.x + radius_uv.x) * float(resolution))), 0, resolution - 1)
	var min_y := clampi(int(floor((uvw.y - radius_uv.y) * float(resolution))), 0, resolution - 1)
	var max_y := clampi(int(ceil((uvw.y + radius_uv.y) * float(resolution))), 0, resolution - 1)
	var min_z := clampi(int(floor((uvw.z - radius_uv.z) * float(resolution))), 0, resolution - 1)
	var max_z := clampi(int(ceil((uvw.z + radius_uv.z) * float(resolution))), 0, resolution - 1)
	var channel := _effect_volume_channel(effect_id)
	var clamped_strength: float = clamp(strength, 0.0, 4.0)
	var wrote_voxel := false

	for z in range(min_z, max_z + 1):
		var local_z := effect_volume_origin_local.z + (float(z) + 0.5) / float(resolution) * effect_volume_size_local.z
		for y in range(min_y, max_y + 1):
			var local_y := effect_volume_origin_local.y + (float(y) + 0.5) / float(resolution) * effect_volume_size_local.y
			for x in range(min_x, max_x + 1):
				var local_x := effect_volume_origin_local.x + (float(x) + 0.5) / float(resolution) * effect_volume_size_local.x
				var local_position := Vector3(local_x, local_y, local_z)
				var distance01: float = local_position.distance_to(center) / effective_radius
				var mask: float = (1.0 - _smoothstep(0.55, 1.0, distance01)) * clamped_strength
				if mask <= 0.0:
					continue

				_write_effect_volume_byte(x, y, z, channel, mask)
				effect_volume_dirty_layers[z] = true
				wrote_voxel = true

	if not wrote_voxel:
		_write_effect_volume_sample(effect_id, center, clamped_strength)


func _accumulate_sand_to_effect_volume(min_travel: float = -INF) -> void:
	if character_root == null or effect_volume_texture == null or effect_volume_layer_data.is_empty():
		return
	if sampler.local_positions.is_empty():
		return

	var direction_world: Vector3 = sand_direction_world.normalized()
	if direction_world.length_squared() <= 0.000001:
		return

	effect_volume_dirty_layers.clear()
	var to_world_basis: Basis = character_root.global_transform.basis
	var max_travel := sand_front + sand_front_softness
	var sample_stride := _sand_sample_stride()
	for sample_index in range(0, sampler.local_positions.size(), sample_stride):
		var local_position: Vector3 = sampler.local_positions[sample_index]
		var world_position: Vector3 = character_root.to_global(local_position)
		var travel: float = world_position.dot(direction_world)
		if travel < min_travel or travel > max_travel:
			continue
		if not _is_sand_sample_exposed(world_position, travel):
			continue

		var front_mask: float = 1.0 - _smoothstep(sand_front, sand_front + sand_front_softness, travel)
		if front_mask <= 0.0:
			continue

		var normal_world: Vector3 = (to_world_basis * sampler.local_normals[sample_index]).normalized()
		var normal_factor: float = 1.0 - abs(normal_world.dot(direction_world))
		var mask: float = clamp(front_mask * normal_factor * sand_amount, 0.0, 1.0)
		if mask <= 0.01:
			continue

		_write_effect_volume_sample(EFFECT_SAND_ID, local_position, mask)

	_queue_dirty_effect_volume_layers()
	effect_volume_dirty = false


func _reset_sand_accumulation_cursor() -> void:
	has_sand_accumulation_cursor = false
	sand_accumulation_direction_world = Vector3.ZERO
	sand_accumulated_front = -INF
	sand_accumulated_amount = 0.0
	has_sand_exposure_map = false
	sand_exposure_min_travel_by_cell.clear()


func _sand_sample_stride() -> int:
	if max_sand_accumulation_samples <= 0:
		return 1
	return max(1, int(ceil(float(sampler.local_positions.size()) / float(max_sand_accumulation_samples))))


func _ensure_sand_exposure_map() -> void:
	if (
		has_sand_exposure_map
		and sand_direction_world.distance_squared_to(sand_exposure_direction_world) <= 0.000001
	):
		return
	_rebuild_sand_exposure_map()


func _rebuild_sand_exposure_map() -> void:
	sand_exposure_min_travel_by_cell.clear()
	has_sand_exposure_map = false
	if character_root == null or sampler.local_positions.is_empty():
		return

	var direction_world := sand_direction_world.normalized()
	if direction_world.length_squared() <= 0.000001:
		return

	var axis_u := direction_world.cross(Vector3.UP)
	if axis_u.length_squared() <= 0.000001:
		axis_u = direction_world.cross(Vector3.RIGHT)
	sand_exposure_axis_u = axis_u.normalized()
	sand_exposure_axis_v = sand_exposure_axis_u.cross(direction_world).normalized()
	sand_exposure_direction_world = direction_world

	for sample_index in sampler.local_positions.size():
		var world_position: Vector3 = character_root.to_global(sampler.local_positions[sample_index])
		var travel := world_position.dot(direction_world)
		var cell_key := _sand_exposure_cell_key(world_position)
		if (
			not sand_exposure_min_travel_by_cell.has(cell_key)
			or travel < float(sand_exposure_min_travel_by_cell[cell_key])
		):
			sand_exposure_min_travel_by_cell[cell_key] = travel

	has_sand_exposure_map = true


func _is_sand_sample_exposed(world_position: Vector3, travel: float) -> bool:
	if not has_sand_exposure_map:
		return true
	var cell_key := _sand_exposure_cell_key(world_position)
	if not sand_exposure_min_travel_by_cell.has(cell_key):
		return true
	var exposed_travel: float = sand_exposure_min_travel_by_cell[cell_key]
	return travel <= exposed_travel + max(sand_exposure_depth, 0.001)


func _sand_exposure_cell_key(world_position: Vector3) -> Vector2i:
	var cell_size: float = max(sand_exposure_cell_size, 0.001)
	var u: int = int(floor(world_position.dot(sand_exposure_axis_u) / cell_size))
	var v: int = int(floor(world_position.dot(sand_exposure_axis_v) / cell_size))
	return Vector2i(u, v)


func _write_effect_volume_sample(effect_id: int, local_position: Vector3, strength: float, voxel_radius: int = 0) -> void:
	var uvw := _local_to_effect_volume_uv(local_position)
	if uvw.x < 0.0 or uvw.x > 1.0 or uvw.y < 0.0 or uvw.y > 1.0 or uvw.z < 0.0 or uvw.z > 1.0:
		return

	var resolution := _clamped_effect_volume_resolution()
	var x := clampi(int(floor(uvw.x * float(resolution))), 0, resolution - 1)
	var y := clampi(int(floor(uvw.y * float(resolution))), 0, resolution - 1)
	var z := clampi(int(floor(uvw.z * float(resolution))), 0, resolution - 1)
	var mask: float = clamp(strength, 0.0, 1.0)
	var channel: int = _effect_volume_channel(effect_id)
	var min_x: int = clampi(x - voxel_radius, 0, resolution - 1)
	var max_x: int = clampi(x + voxel_radius, 0, resolution - 1)
	var min_y: int = clampi(y - voxel_radius, 0, resolution - 1)
	var max_y: int = clampi(y + voxel_radius, 0, resolution - 1)
	var min_z: int = clampi(z - voxel_radius, 0, resolution - 1)
	var max_z: int = clampi(z + voxel_radius, 0, resolution - 1)

	for write_z in range(min_z, max_z + 1):
		for write_y in range(min_y, max_y + 1):
			for write_x in range(min_x, max_x + 1):
				_write_effect_volume_byte(write_x, write_y, write_z, channel, mask)
				effect_volume_dirty_layers[write_z] = true


func _write_effect_volume_byte(x: int, y: int, z: int, channel: int, mask: float) -> void:
	var value := clampi(int(round(clamp(mask, 0.0, 1.0) * 255.0)), 0, 255)
	var byte_index := _effect_volume_byte_index(x, y, channel)
	var data := effect_volume_layer_data[z]
	if value > data[byte_index]:
		data[byte_index] = value


func _effect_volume_byte_index(x: int, y: int, channel: int) -> int:
	var resolution := _clamped_effect_volume_resolution()
	return (y * resolution + x) * 4 + channel


func _update_dirty_effect_volume_layers() -> void:
	if effect_volume_texture == null:
		return

	for layer in effect_volume_dirty_layers.keys():
		var layer_index := int(layer)
		if layer_index >= 0 and layer_index < effect_volume_layer_data.size():
			_update_effect_volume_layer_texture(layer_index)
	effect_volume_dirty_layers.clear()


func _queue_dirty_effect_volume_layers() -> void:
	for layer in effect_volume_dirty_layers.keys():
		pending_effect_volume_layers[layer] = true
	effect_volume_dirty_layers.clear()


func _flush_pending_effect_volume_layers(max_layers: int = -1) -> void:
	if effect_volume_texture == null or pending_effect_volume_layers.is_empty():
		return

	var uploaded_layers := 0
	for layer in pending_effect_volume_layers.keys():
		var layer_index := int(layer)
		if layer_index >= 0 and layer_index < effect_volume_layer_data.size():
			_update_effect_volume_layer_texture(layer_index)
			uploaded_layers += 1
		pending_effect_volume_layers.erase(layer)
		if max_layers > 0 and uploaded_layers >= max_layers:
			break


func _update_all_effect_volume_layers() -> void:
	if effect_volume_texture == null:
		return

	for layer_index in effect_volume_layer_data.size():
		_update_effect_volume_layer_texture(layer_index)
	effect_volume_dirty_layers.clear()
	pending_effect_volume_layers.clear()


func _update_effect_volume_layer_texture(layer_index: int) -> void:
	var resolution := _clamped_effect_volume_resolution()
	var image := Image.create_from_data(
		resolution,
		resolution,
		false,
		Image.FORMAT_RGBA8,
		effect_volume_layer_data[layer_index]
	)
	effect_volume_images[layer_index] = image
	effect_volume_texture.update_layer(image, layer_index)


func _local_to_effect_volume_uv(local_position: Vector3) -> Vector3:
	return Vector3(
		(local_position.x - effect_volume_origin_local.x) * effect_volume_inv_size.x,
		(local_position.y - effect_volume_origin_local.y) * effect_volume_inv_size.y,
		(local_position.z - effect_volume_origin_local.z) * effect_volume_inv_size.z
	)


func _effect_volume_channel(effect_id: int) -> int:
	return clampi(effect_id - 1, 0, 3)


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t: float = clamp((value - edge0) / max(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _clamped_effect_volume_resolution() -> int:
	return clampi(effect_volume_resolution, 16, 64)


func _aabb_corners(bounds: AABB) -> Array[Vector3]:
	return [
		Vector3(bounds.position.x, bounds.position.y, bounds.position.z),
		Vector3(bounds.end.x, bounds.position.y, bounds.position.z),
		Vector3(bounds.position.x, bounds.end.y, bounds.position.z),
		Vector3(bounds.end.x, bounds.end.y, bounds.position.z),
		Vector3(bounds.position.x, bounds.position.y, bounds.end.z),
		Vector3(bounds.end.x, bounds.position.y, bounds.end.z),
		Vector3(bounds.position.x, bounds.end.y, bounds.end.z),
		Vector3(bounds.end.x, bounds.end.y, bounds.end.z),
	]


func _ensure_rest_volume_attributes(root: Node3D) -> void:
	rest_attribute_vertex_count = 0
	if not use_rest_volume_attributes:
		return

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	if _all_meshes_are_rest_volume_meshes(meshes):
		rest_attribute_vertex_count = sampler.get_source_vertex_count()
		return

	for mesh_instance in meshes:
		_add_rest_volume_attributes(mesh_instance)


func _add_rest_volume_attributes(mesh_instance: MeshInstance3D) -> void:
	var source_mesh := mesh_instance.mesh
	if source_mesh == null:
		return
	if _mesh_has_rest_volume_attributes(source_mesh):
		rest_attribute_vertex_count += _count_mesh_vertices(source_mesh)
		return

	var array_mesh := ArrayMesh.new()
	array_mesh.resource_name = source_mesh.resource_name + "_RestVolume"
	array_mesh.set_meta(REST_VOLUME_META, true)
	var to_character := character_root.global_transform.affine_inverse() * mesh_instance.global_transform

	for surface_index in source_mesh.get_surface_count():
		var arrays := source_mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue

		var rest_positions := PackedFloat32Array()
		rest_positions.resize(vertices.size() * 4)
		for vertex_index in vertices.size():
			var local_position := to_character * vertices[vertex_index]
			var base_index := vertex_index * 4
			rest_positions[base_index] = local_position.x
			rest_positions[base_index + 1] = local_position.y
			rest_positions[base_index + 2] = local_position.z
			rest_positions[base_index + 3] = 1.0

		arrays[Mesh.ARRAY_CUSTOM0] = rest_positions
		var primitive := Mesh.PRIMITIVE_TRIANGLES
		if source_mesh.has_method("surface_get_primitive_type"):
			primitive = source_mesh.call("surface_get_primitive_type", surface_index)
		var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		array_mesh.add_surface_from_arrays(
			primitive,
			arrays,
			[],
			{},
			flags
		)
		array_mesh.surface_set_material(surface_index, source_mesh.surface_get_material(surface_index))
		rest_attribute_vertex_count += vertices.size()

	mesh_instance.mesh = array_mesh


func _mesh_has_rest_volume_attributes(mesh: Mesh) -> bool:
	if mesh.has_meta(REST_VOLUME_META) and bool(mesh.get_meta(REST_VOLUME_META)):
		return true
	if not String(mesh.resource_name).ends_with("_RestVolume"):
		return false
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var rest_positions = arrays[Mesh.ARRAY_CUSTOM0]
		if vertices.is_empty():
			continue
		if not rest_positions is PackedFloat32Array:
			return false
		if (rest_positions as PackedFloat32Array).size() != vertices.size() * 4:
			return false
	return true


func _all_meshes_are_rest_volume_meshes(meshes: Array[MeshInstance3D]) -> bool:
	if meshes.is_empty():
		return false
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			return false
		if not _mesh_has_rest_volume_attributes(mesh_instance.mesh):
			return false
	return true


func _count_mesh_vertices(mesh: Mesh) -> int:
	var count := 0
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		count += vertices.size()
	return count


func _resolve_attachment_world(attachment: Dictionary) -> Vector3:
	var mesh_instance: MeshInstance3D = attachment["mesh_instance"]
	if not is_instance_valid(mesh_instance):
		return character_root.global_position if character_root != null else Vector3.ZERO

	var surface_index: int = attachment["surface_index"]
	var triangle_indices: PackedInt32Array = attachment["triangle_indices"]
	var barycentric: Vector3 = attachment["barycentric"]
	var mesh := mesh_instance.mesh
	if mesh == null or surface_index < 0 or surface_index >= mesh.get_surface_count():
		return mesh_instance.global_position

	var arrays := mesh.surface_get_arrays(surface_index)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if triangle_indices[0] >= vertices.size() or triangle_indices[1] >= vertices.size() or triangle_indices[2] >= vertices.size():
		return mesh_instance.global_position

	var p0 := resolve_vertex_world(mesh_instance, arrays, triangle_indices[0], surface_index)
	var p1 := resolve_vertex_world(mesh_instance, arrays, triangle_indices[1], surface_index)
	var p2 := resolve_vertex_world(mesh_instance, arrays, triangle_indices[2], surface_index)
	return p0 * barycentric.x + p1 * barycentric.y + p2 * barycentric.z


func _resolve_attachment_rest_local(attachment: Dictionary) -> Vector3:
	var mesh_instance: MeshInstance3D = attachment["mesh_instance"]
	if not is_instance_valid(mesh_instance):
		return Vector3.ZERO

	var surface_index: int = attachment["surface_index"]
	var triangle_indices: PackedInt32Array = attachment["triangle_indices"]
	var barycentric: Vector3 = attachment["barycentric"]
	var mesh := mesh_instance.mesh
	if mesh == null or surface_index < 0 or surface_index >= mesh.get_surface_count():
		return character_root.to_local(mesh_instance.global_position)

	var arrays := mesh.surface_get_arrays(surface_index)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if triangle_indices[0] >= vertices.size() or triangle_indices[1] >= vertices.size() or triangle_indices[2] >= vertices.size():
		return character_root.to_local(mesh_instance.global_position)

	var to_character := character_root.global_transform.affine_inverse() * mesh_instance.global_transform
	var p0 := to_character * vertices[triangle_indices[0]]
	var p1 := to_character * vertices[triangle_indices[1]]
	var p2 := to_character * vertices[triangle_indices[2]]
	return p0 * barycentric.x + p1 * barycentric.y + p2 * barycentric.z


func _try_resolve_provider_vertex_world(
	mesh_instance: MeshInstance3D,
	surface_index: int,
	arrays: Array,
	vertex_index: int
) -> Variant:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var base_position := vertices[vertex_index]
	if deformation_provider != null and deformation_provider.has_method("resolve_surface_vertex_world"):
		return deformation_provider.call(
			"resolve_surface_vertex_world",
			mesh_instance,
			surface_index,
			vertex_index,
			base_position
		)
	if mesh_instance.has_method("resolve_surface_vertex_world"):
		return mesh_instance.call("resolve_surface_vertex_world", surface_index, vertex_index, base_position)
	return null


func _resolve_vertex_mesh_local(mesh_instance: MeshInstance3D, arrays: Array, vertex_index: int) -> Vector3:
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var base_position := vertices[vertex_index]
	if mesh_instance.skin == null:
		return base_position

	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	if bones.is_empty() or weights.is_empty():
		return base_position

	var skeleton := _find_skeleton_for_mesh(mesh_instance)
	if skeleton == null:
		return base_position

	var influences_per_vertex := int(bones.size() / max(vertices.size(), 1))
	if influences_per_vertex <= 0:
		return base_position

	var skeleton_local := Vector3.ZERO
	var total_weight := 0.0
	var first_influence := vertex_index * influences_per_vertex
	for influence_index in influences_per_vertex:
		var array_index := first_influence + influence_index
		if array_index >= bones.size() or array_index >= weights.size():
			break
		var weight := weights[array_index]
		if weight <= 0.0001:
			continue
		var bind_index := bones[array_index]
		var bone_index := _resolve_skin_bone_index(mesh_instance.skin, skeleton, bind_index)
		if bone_index < 0:
			continue
		var bind_pose := mesh_instance.skin.get_bind_pose(bind_index)
		var bone_pose := skeleton.get_bone_global_pose(bone_index)
		skeleton_local += (bone_pose * (bind_pose * base_position)) * weight
		total_weight += weight

	if total_weight <= 0.0001:
		return base_position

	var skeleton_world := skeleton.global_transform * (skeleton_local / total_weight)
	return mesh_instance.to_local(skeleton_world)


func _find_skeleton_for_mesh(mesh_instance: MeshInstance3D) -> Skeleton3D:
	if not mesh_instance.skeleton.is_empty() and mesh_instance.has_node(mesh_instance.skeleton):
		var node := mesh_instance.get_node(mesh_instance.skeleton)
		if node is Skeleton3D:
			return node

	var parent := mesh_instance.get_parent()
	while parent != null:
		if parent is Skeleton3D:
			return parent
		parent = parent.get_parent()

	if character_root != null:
		return _find_first_skeleton(character_root)
	return null


func _find_first_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var skeleton := _find_first_skeleton(child)
		if skeleton != null:
			return skeleton
	return null


func _resolve_skin_bone_index(skin: Skin, skeleton: Skeleton3D, bind_index: int) -> int:
	var bone_index := skin.get_bind_bone(bind_index)
	if bone_index >= 0:
		return bone_index

	var bind_name := skin.get_bind_name(bind_index)
	if not String(bind_name).is_empty():
		return skeleton.find_bone(bind_name)
	return -1


func _sync_sand_params() -> void:
	for material in shader_materials:
		material.set_shader_parameter("sand_direction_world", sand_direction_world)
		material.set_shader_parameter("sand_front", sand_front)
		material.set_shader_parameter("sand_amount", sand_amount)
		material.set_shader_parameter("sand_front_softness", sand_front_softness)
