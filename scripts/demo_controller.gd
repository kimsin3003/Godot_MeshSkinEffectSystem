extends Node3D

@export var show_debug_markers := true

@onready var character_root: Node3D = $Character
@onready var accumulator: SurfaceEffectAccumulator = $SurfaceEffectAccumulator
@onready var camera: Camera3D = $Camera3D

var elapsed := 0.0
var next_impact_time := 0.4
var marker_material := StandardMaterial3D.new()


func _ready() -> void:
	marker_material.albedo_color = Color(0.9, 0.05, 0.03)
	_create_layered_character()
	_configure_camera()
	accumulator.rebuild_for_character(character_root)


func _process(delta: float) -> void:
	elapsed += delta

	var wind_dir := Vector3(1.0, 0.12, 0.0).normalized()
	accumulator.set_sand_state(wind_dir, -1.2 + elapsed * 0.35, 0.75)

	if elapsed >= next_impact_time:
		next_impact_time += 0.85
		var y := 0.55 + sin(elapsed * 1.7) * 0.25
		var z := cos(elapsed * 2.1) * 0.12
		var physics_hit := character_root.global_position + Vector3(0.0, y, z)
		var resolved_hit := accumulator.add_impact(physics_hit, Vector3(1.0, -0.05, 0.0), 0.055, 1.0)
		if show_debug_markers:
			_add_hit_marker(resolved_hit)


func _create_layered_character() -> void:
	for child in character_root.get_children():
		child.free()

	_add_capsule_layer("Body", 0.38, 1.45, Color(0.55, 0.58, 0.62))
	_add_capsule_layer("Jacket", 0.43, 1.36, Color(0.26, 0.32, 0.42))
	_add_capsule_layer("Outer", 0.48, 1.16, Color(0.18, 0.22, 0.26))


func _configure_camera() -> void:
	camera.global_position = Vector3(-1.45, 0.85, 1.6)
	camera.look_at(Vector3(0.0, 0.45, 0.0), Vector3.UP)
	camera.fov = 35.0
	camera.current = true


func _add_capsule_layer(layer_name: String, radius: float, height: float, color: Color) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = layer_name

	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 48
	mesh.rings = 16
	mesh_instance.mesh = mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material = material

	character_root.add_child(mesh_instance)


func _add_hit_marker(world_position: Vector3) -> void:
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.018
	mesh.height = 0.036
	marker.mesh = mesh
	marker.material_override = marker_material
	add_child(marker)
	marker.global_position = world_position

	await get_tree().create_timer(1.4).timeout
	if is_instance_valid(marker):
		marker.queue_free()
