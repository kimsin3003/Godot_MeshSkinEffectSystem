class_name SurfaceEffectAccumulator
extends Node

const MAX_IMPACTS := 32
const DEFAULT_IMPACT_RADIUS_M := 0.05
const DEFAULT_SAMPLE_LIMIT := 8192
const EFFECT_BULLET_IMPACT_ID := 1

@export var character_root: Node3D
@export var sample_limit := DEFAULT_SAMPLE_LIMIT
@export var impact_radius_m := DEFAULT_IMPACT_RADIUS_M
@export var shader: Shader = preload("res://shaders/surface_effects.gdshader")

var sampler := MeshSurfaceSampler.new()
var shader_materials: Array[ShaderMaterial] = []
var impact_spheres := PackedVector4Array()
var impact_dirs := PackedVector4Array()
var impact_meta := PackedVector4Array()
var impact_cursor := 0
var sand_direction_world := Vector3(1, 0, 0)
var sand_front := -10.0
var sand_amount := 0.0


func _ready() -> void:
	if character_root != null:
		rebuild_for_character(character_root)


func _process(_delta: float) -> void:
	if character_root != null and not shader_materials.is_empty():
		_sync_transform_params()


func rebuild_for_character(root: Node3D) -> void:
	character_root = root
	clear_impacts()
	sampler.rebuild(root, sample_limit)
	_rebuild_materials(root)
	_sync_all_shader_params()


func get_sample_count() -> int:
	return sampler.get_sample_count()


func get_material_instance_count() -> int:
	return shader_materials.size()


func get_impact_count() -> int:
	return impact_spheres.size()


func estimate_memory_bytes() -> int:
	var sampler_bytes := sampler.estimate_memory_bytes()
	var impact_bytes := MAX_IMPACTS * 32
	return sampler_bytes + impact_bytes


func clear_impacts() -> void:
	impact_spheres.clear()
	impact_dirs.clear()
	impact_meta.clear()
	impact_cursor = 0
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
	_store_surface_event(effect_id, resolved_world, shot_dir_world, radius_m, strength)
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

	_store_surface_event(effect_id, visual_hit_world, direction_world, radius_m, strength)
	return visual_hit_world


func _store_surface_event(
	effect_id: int,
	center_world: Vector3,
	direction_world: Vector3,
	radius_m: float,
	strength: float
) -> void:
	var local_center := character_root.to_local(center_world)
	var local_dir := (character_root.global_transform.basis.inverse() * direction_world.normalized()).normalized()
	var sphere := Vector4(local_center.x, local_center.y, local_center.z, radius_m)
	var direction := Vector4(local_dir.x, local_dir.y, local_dir.z, clamp(strength, 0.0, 4.0))
	var meta := Vector4(float(effect_id), 0.0, 0.0, 0.0)

	if impact_spheres.size() < MAX_IMPACTS:
		impact_spheres.append(sphere)
		impact_dirs.append(direction)
		impact_meta.append(meta)
	else:
		impact_spheres[impact_cursor] = sphere
		impact_dirs[impact_cursor] = direction
		impact_meta[impact_cursor] = meta
		impact_cursor = (impact_cursor + 1) % MAX_IMPACTS

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


func _sync_sand_params() -> void:
	for material in shader_materials:
		material.set_shader_parameter("sand_direction_world", sand_direction_world)
		material.set_shader_parameter("sand_front", sand_front)
		material.set_shader_parameter("sand_amount", sand_amount)
