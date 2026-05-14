class_name SurfaceEffectAccumulator
extends Node

const MAX_IMPACTS := 32
const DEFAULT_IMPACT_RADIUS_M := 0.05
const DEFAULT_SAMPLE_LIMIT := 8192
const DEFAULT_EFFECT_VOLUME_RESOLUTION := 48
const EFFECT_BULLET_IMPACT_ID := 1
const EMPTY_EFFECT_VOLUME_COLOR := Color(0.0, 0.0, 0.0, 0.0)

@export var character_root: Node3D
@export var deformation_provider: Node
@export var sample_limit := DEFAULT_SAMPLE_LIMIT
@export var effect_volume_resolution := DEFAULT_EFFECT_VOLUME_RESOLUTION
@export var impact_radius_m := DEFAULT_IMPACT_RADIUS_M
@export var shader: Shader = preload("res://shaders/surface_effects.gdshader")

var sampler := MeshSurfaceSampler.new()
var shader_materials: Array[ShaderMaterial] = []
var surface_events: Array[Dictionary] = []
var impact_spheres := PackedVector4Array()
var impact_dirs := PackedVector4Array()
var impact_meta := PackedVector4Array()
var impact_cursor := 0
var effect_volume_texture: ImageTexture3D
var effect_volume_images: Array[Image] = []
var effect_volume_origin_local := Vector3(-1.0, -1.0, -1.0)
var effect_volume_size_local := Vector3(2.0, 2.0, 2.0)
var effect_volume_inv_size := Vector3(0.5, 0.5, 0.5)
var effect_volume_dirty := true
var sand_direction_world := Vector3(1, 0, 0)
var sand_front := -10.0
var sand_amount := 0.0


func _ready() -> void:
	if character_root != null:
		rebuild_for_character(character_root)


func _process(_delta: float) -> void:
	if character_root != null and not shader_materials.is_empty():
		_rebuild_event_uniform_arrays()
		if effect_volume_dirty or _has_attached_events():
			_rebuild_effect_volume()
		_sync_impact_params()
		_sync_transform_params()


func rebuild_for_character(root: Node3D) -> void:
	character_root = root
	clear_impacts()
	sampler.rebuild(root, sample_limit)
	_rebuild_effect_volume_storage(root)
	_rebuild_materials(root)
	_sync_all_shader_params()


func get_sample_count() -> int:
	return sampler.get_sample_count()


func get_material_instance_count() -> int:
	return shader_materials.size()


func get_impact_count() -> int:
	return surface_events.size()


func estimate_memory_bytes() -> int:
	var sampler_bytes := sampler.estimate_memory_bytes()
	var impact_bytes := MAX_IMPACTS * 32
	var volume_resolution := _clamped_effect_volume_resolution()
	var volume_bytes := volume_resolution * volume_resolution * volume_resolution * 4
	return sampler_bytes + impact_bytes + volume_bytes


func clear_impacts() -> void:
	surface_events.clear()
	impact_spheres.clear()
	impact_dirs.clear()
	impact_meta.clear()
	impact_cursor = 0
	effect_volume_dirty = true
	_rebuild_effect_volume()
	_sync_impact_params()


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

	var resolved_world := sampler.find_outer_surface(
		physics_hit_world,
		shot_dir_world,
		radius_m * 1.6
	)
	_store_surface_event(effect_id, resolved_world, shot_dir_world, radius_m, strength, {})
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

	_store_surface_event(effect_id, visual_hit_world, direction_world, radius_m, strength, {})
	return visual_hit_world


func add_surface_effect_at_triangle(
	effect_id: int,
	mesh_instance: MeshInstance3D,
	surface_index: int,
	triangle_indices: PackedInt32Array,
	barycentric: Vector3,
	effect_direction_world: Vector3,
	radius_m: float = impact_radius_m,
	strength: float = 1.0
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
	var visual_hit_world := _resolve_attachment_world(attachment)
	_store_surface_event(effect_id, visual_hit_world, direction_world, radius_m, strength, attachment)
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


func _store_surface_event(
	effect_id: int,
	center_world: Vector3,
	direction_world: Vector3,
	radius_m: float,
	strength: float,
	attachment: Dictionary
) -> void:
	var local_center := character_root.to_local(center_world)
	var local_dir := (character_root.global_transform.basis.inverse() * direction_world.normalized()).normalized()
	var record := {
		"effect_id": effect_id,
		"center_local": local_center,
		"direction_local": local_dir,
		"radius": radius_m,
		"strength": clamp(strength, 0.0, 4.0),
		"attachment": attachment,
	}

	if surface_events.size() < MAX_IMPACTS:
		surface_events.append(record)
	else:
		surface_events[impact_cursor] = record
		impact_cursor = (impact_cursor + 1) % MAX_IMPACTS

	_rebuild_event_uniform_arrays()
	_rebuild_effect_volume()
	_sync_impact_params()


func set_sand_state(direction_world: Vector3, front: float, amount: float) -> void:
	if direction_world.length_squared() > 0.000001:
		sand_direction_world = direction_world.normalized()
	sand_front = front
	sand_amount = clamp(amount, 0.0, 1.0)
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
	var material := mesh_instance.get_surface_override_material(surface_index)
	if material == null and mesh_instance.mesh != null:
		material = mesh_instance.mesh.surface_get_material(surface_index)
	return material


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
	_sync_impact_params()
	_sync_sand_params()


func _sync_transform_params() -> void:
	var character_inverse_world := Transform3D.IDENTITY
	if character_root != null:
		character_inverse_world = character_root.global_transform.affine_inverse()

	for material in shader_materials:
		material.set_shader_parameter("character_inverse_world", character_inverse_world)


func _sync_impact_params() -> void:
	for material in shader_materials:
		material.set_shader_parameter("impact_count", impact_spheres.size())
		material.set_shader_parameter("impact_spheres", impact_spheres)
		material.set_shader_parameter("impact_dirs", impact_dirs)
		material.set_shader_parameter("impact_meta", impact_meta)
		material.set_shader_parameter("use_surface_effect_volume", effect_volume_texture != null)
		if effect_volume_texture != null:
			material.set_shader_parameter("surface_effect_volume", effect_volume_texture)
		material.set_shader_parameter("effect_volume_origin_local", effect_volume_origin_local)
		material.set_shader_parameter("effect_volume_inv_size", effect_volume_inv_size)


func _rebuild_event_uniform_arrays() -> void:
	impact_spheres.clear()
	impact_dirs.clear()
	impact_meta.clear()

	for record in surface_events:
		var center_local: Vector3 = record["center_local"]
		var attachment: Dictionary = record["attachment"]
		if not attachment.is_empty():
			center_local = character_root.to_local(_resolve_attachment_world(attachment))

		var direction_local: Vector3 = record["direction_local"]
		impact_spheres.append(Vector4(center_local.x, center_local.y, center_local.z, float(record["radius"])))
		impact_dirs.append(Vector4(direction_local.x, direction_local.y, direction_local.z, float(record["strength"])))
		impact_meta.append(Vector4(float(record["effect_id"]), 0.0, 0.0, 0.0))


func sample_effect_volume_local(local_position: Vector3) -> Color:
	if effect_volume_images.is_empty():
		return EMPTY_EFFECT_VOLUME_COLOR

	var uvw := _local_to_effect_volume_uv(local_position)
	if uvw.x < 0.0 or uvw.x > 1.0 or uvw.y < 0.0 or uvw.y > 1.0 or uvw.z < 0.0 or uvw.z > 1.0:
		return EMPTY_EFFECT_VOLUME_COLOR

	var resolution := _clamped_effect_volume_resolution()
	var x := clampi(int(floor(uvw.x * float(resolution))), 0, resolution - 1)
	var y := clampi(int(floor(uvw.y * float(resolution))), 0, resolution - 1)
	var z := clampi(int(floor(uvw.z * float(resolution))), 0, resolution - 1)
	return effect_volume_images[z].get_pixel(x, y)


func _rebuild_effect_volume_storage(root: Node3D) -> void:
	_update_effect_volume_bounds(root)
	effect_volume_images.clear()

	var resolution := _clamped_effect_volume_resolution()
	for z in resolution:
		var image := Image.create_empty(resolution, resolution, false, Image.FORMAT_RGBA8)
		image.fill(EMPTY_EFFECT_VOLUME_COLOR)
		effect_volume_images.append(image)

	effect_volume_texture = ImageTexture3D.new()
	effect_volume_texture.create(Image.FORMAT_RGBA8, resolution, resolution, resolution, false, effect_volume_images)
	effect_volume_dirty = true
	_rebuild_effect_volume()


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
	if effect_volume_texture == null or effect_volume_images.is_empty():
		return

	for image in effect_volume_images:
		image.fill(EMPTY_EFFECT_VOLUME_COLOR)

	for event_index in impact_spheres.size():
		_splat_event_to_effect_volume(event_index)

	effect_volume_texture.update(effect_volume_images)
	effect_volume_dirty = false


func _splat_event_to_effect_volume(event_index: int) -> void:
	var sphere := impact_spheres[event_index]
	var radius: float = max(sphere.w, 0.001)
	var center := Vector3(sphere.x, sphere.y, sphere.z)
	var uvw := _local_to_effect_volume_uv(center)
	var resolution := _clamped_effect_volume_resolution()
	var radius_uv := Vector3(
		radius * effect_volume_inv_size.x,
		radius * effect_volume_inv_size.y,
		radius * effect_volume_inv_size.z
	)

	var min_x := clampi(int(floor((uvw.x - radius_uv.x) * float(resolution))), 0, resolution - 1)
	var max_x := clampi(int(ceil((uvw.x + radius_uv.x) * float(resolution))), 0, resolution - 1)
	var min_y := clampi(int(floor((uvw.y - radius_uv.y) * float(resolution))), 0, resolution - 1)
	var max_y := clampi(int(ceil((uvw.y + radius_uv.y) * float(resolution))), 0, resolution - 1)
	var min_z := clampi(int(floor((uvw.z - radius_uv.z) * float(resolution))), 0, resolution - 1)
	var max_z := clampi(int(ceil((uvw.z + radius_uv.z) * float(resolution))), 0, resolution - 1)
	var channel := _effect_volume_channel(int(floor(impact_meta[event_index].x + 0.5)))
	var strength: float = clamp(impact_dirs[event_index].w, 0.0, 4.0)

	for z in range(min_z, max_z + 1):
		var local_z := effect_volume_origin_local.z + (float(z) + 0.5) / float(resolution) * effect_volume_size_local.z
		for y in range(min_y, max_y + 1):
			var local_y := effect_volume_origin_local.y + (float(y) + 0.5) / float(resolution) * effect_volume_size_local.y
			for x in range(min_x, max_x + 1):
				var local_x := effect_volume_origin_local.x + (float(x) + 0.5) / float(resolution) * effect_volume_size_local.x
				var local_position := Vector3(local_x, local_y, local_z)
				var distance01: float = local_position.distance_to(center) / radius
				var mask: float = (1.0 - _smoothstep(0.55, 1.0, distance01)) * strength
				if mask <= 0.0:
					continue

				var image := effect_volume_images[z]
				var color := image.get_pixel(x, y)
				match channel:
					0:
						color.r = max(color.r, clamp(mask, 0.0, 1.0))
					1:
						color.g = max(color.g, clamp(mask, 0.0, 1.0))
					2:
						color.b = max(color.b, clamp(mask, 0.0, 1.0))
					_:
						color.a = max(color.a, clamp(mask, 0.0, 1.0))
				image.set_pixel(x, y, color)


func _local_to_effect_volume_uv(local_position: Vector3) -> Vector3:
	return Vector3(
		(local_position.x - effect_volume_origin_local.x) * effect_volume_inv_size.x,
		(local_position.y - effect_volume_origin_local.y) * effect_volume_inv_size.y,
		(local_position.z - effect_volume_origin_local.z) * effect_volume_inv_size.z
	)


func _effect_volume_channel(effect_id: int) -> int:
	return clampi(effect_id - 1, 0, 3)


func _has_attached_events() -> bool:
	for record in surface_events:
		var attachment: Dictionary = record["attachment"]
		if not attachment.is_empty():
			return true
	return false


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
