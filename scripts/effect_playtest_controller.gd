extends Node3D

const SurfaceEffectAccumulatorScript := preload("res://scripts/surface_effect_accumulator.gd")
const ADVENTURER_PATH := "res://external/quaternius_modular_women_glb/Adventurer.glb"
const SOLDIER_PATH := "res://external/quaternius_modular_women_glb/Soldier.glb"
const MARKER_LIFETIME := 1.25

@onready var character_root: Node3D = $Character
@onready var camera: Camera3D = $Camera3D
@onready var accumulator: SurfaceEffectAccumulator = $SurfaceEffectAccumulator
@onready var effect_label: Label = $HUD/Panel/MarginContainer/VBox/EffectLabel
@onready var radius_label: Label = $HUD/Panel/MarginContainer/VBox/RadiusLabel
@onready var strength_label: Label = $HUD/Panel/MarginContainer/VBox/StrengthLabel
@onready var sand_label: Label = $HUD/Panel/MarginContainer/VBox/SandLabel
@onready var events_label: Label = $HUD/Panel/MarginContainer/VBox/EventsLabel
@onready var asset_label: Label = $HUD/Panel/MarginContainer/VBox/AssetLabel
@onready var status_label: Label = $HUD/Panel/MarginContainer/VBox/StatusLabel

var selected_effect_id := 1
var radius_m := 0.09
var strength := 1.0
var current_asset_index := 0
var current_asset_name := ""
var marker_materials := {}
var sand_enabled := false
var sand_direction_world := Vector3(1.0, 0.0, 0.0)
var sand_front := -10.0
var sand_speed := 0.45
var sand_amount := 0.85


func _ready() -> void:
	_load_asset(0)
	_configure_camera()
	_update_hud("ready")


func _process(delta: float) -> void:
	if sand_enabled:
		sand_front += sand_speed * delta
		accumulator.set_sand_state(sand_direction_world, sand_front, sand_amount)
	else:
		accumulator.set_sand_state(sand_direction_world, sand_front, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_apply_surface_event(mouse_event.position)
		elif mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			_start_sandstorm_from_click(mouse_event.position)
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			radius_m = clamp(radius_m + 0.01, 0.02, 0.35)
			_update_hud("radius")
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			radius_m = clamp(radius_m - 0.01, 0.02, 0.35)
			_update_hud("radius")

	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		match key_event.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4:
				selected_effect_id = int(key_event.keycode - KEY_0)
				_update_hud("effect")
			KEY_BRACKETLEFT:
				radius_m = clamp(radius_m - 0.01, 0.02, 0.35)
				_update_hud("radius")
			KEY_BRACKETRIGHT:
				radius_m = clamp(radius_m + 0.01, 0.02, 0.35)
				_update_hud("radius")
			KEY_MINUS:
				strength = clamp(strength - 0.1, 0.1, 4.0)
				_update_hud("strength")
			KEY_EQUAL:
				strength = clamp(strength + 0.1, 0.1, 4.0)
				_update_hud("strength")
			KEY_C:
				accumulator.clear_impacts()
				_update_hud("cleared")
			KEY_T:
				sand_enabled = not sand_enabled
				_update_hud("sand on" if sand_enabled else "sand off")
			KEY_F:
				start_sandstorm(sand_direction_world)
				_update_hud("sand restarted")
			KEY_Q:
				start_sandstorm(sand_direction_world.rotated(Vector3.UP, deg_to_rad(-15.0)))
			KEY_E:
				start_sandstorm(sand_direction_world.rotated(Vector3.UP, deg_to_rad(15.0)))
			KEY_R:
				accumulator.rebuild_for_character(character_root)
				_apply_test_palette()
				if sand_enabled:
					start_sandstorm(sand_direction_world)
				_update_hud("rebuilt")
			KEY_TAB:
				_load_asset((current_asset_index + 1) % 2)
				_update_hud("asset swapped")


func _load_asset(asset_index: int) -> void:
	for child in character_root.get_children():
		child.queue_free()

	current_asset_index = asset_index
	var path := ADVENTURER_PATH if asset_index == 0 else SOLDIER_PATH
	current_asset_name = "Adventurer" if asset_index == 0 else "Soldier"
	var asset_root := _load_gltf_scene(path)
	if asset_root == null:
		_create_fallback_character()
		current_asset_name = "Fallback"
	else:
		character_root.add_child(asset_root)

	for frame in 2:
		await get_tree().process_frame
	accumulator.rebuild_for_character(character_root)
	_apply_test_palette()


func _load_gltf_scene(path: String) -> Node:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(path, state)
	if error != OK:
		push_error("failed to parse glTF: %s error=%d" % [path, error])
		return null
	return document.generate_scene(state)


func _configure_camera() -> void:
	camera.global_position = Vector3(-1.75, 1.25, 2.15)
	camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	camera.fov = 34.0
	camera.current = true


func _apply_test_palette() -> void:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(character_root, meshes)
	for mesh_instance in meshes:
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface_index)
			if material is ShaderMaterial:
				material.set_shader_parameter("blood_color", Color(0.92, 0.02, 0.06, 1.0))
				material.set_shader_parameter("effect_2_color", Color(0.72, 0.52, 0.22, 1.0))
				material.set_shader_parameter("effect_3_color", Color(0.0, 0.62, 1.0, 1.0))
				material.set_shader_parameter("effect_4_color", Color(1.0, 0.74, 0.05, 1.0))


func _apply_surface_event(screen_position: Vector2) -> void:
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_dir := camera.project_ray_normal(screen_position).normalized()
	var hit := _raycast_visual_mesh(ray_origin, ray_dir)
	if hit.is_empty():
		_update_hud("miss")
		return

	var visual_hit: Vector3 = hit["position"]
	accumulator.add_surface_effect_at_visual_surface(selected_effect_id, visual_hit, ray_dir, radius_m, strength)
	_add_marker(visual_hit, _color_for_effect(selected_effect_id))
	_update_hud("hit " + str(hit["mesh"]))


func _start_sandstorm_from_click(screen_position: Vector2) -> void:
	var hit := _raycast_visual_mesh(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position).normalized())
	if hit.is_empty():
		_update_hud("sand miss")
		return

	var hit_position: Vector3 = hit["position"]
	var wind_dir := (hit_position - camera.global_position).normalized()
	start_sandstorm(wind_dir)
	_update_hud("sand from camera")


func start_sandstorm(direction_world: Vector3) -> void:
	if direction_world.length_squared() <= 0.000001:
		return

	sand_direction_world = direction_world.normalized()
	sand_front = _min_character_projection(sand_direction_world) - 0.35
	sand_enabled = true
	accumulator.set_sand_state(sand_direction_world, sand_front, sand_amount)


func _min_character_projection(direction_world: Vector3) -> float:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(character_root, meshes)
	var min_projection := INF
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		var bounds := mesh.get_aabb()
		for corner in _aabb_corners(bounds):
			var projection := mesh_instance.to_global(corner).dot(direction_world)
			min_projection = min(min_projection, projection)
	return min_projection if min_projection < INF else -1.0


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


func _raycast_visual_mesh(ray_origin: Vector3, ray_dir: Vector3) -> Dictionary:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(character_root, meshes)

	var best := {}
	var best_t := INF
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		for surface_index in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if vertices.is_empty():
				continue

			var indices := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array:
				indices = arrays[Mesh.ARRAY_INDEX]

			var triangle_count := indices.size() / 3 if not indices.is_empty() else vertices.size() / 3
			for triangle_index in triangle_count:
				var i0 := indices[triangle_index * 3] if not indices.is_empty() else triangle_index * 3
				var i1 := indices[triangle_index * 3 + 1] if not indices.is_empty() else triangle_index * 3 + 1
				var i2 := indices[triangle_index * 3 + 2] if not indices.is_empty() else triangle_index * 3 + 2
				var v0 := mesh_instance.to_global(vertices[i0])
				var v1 := mesh_instance.to_global(vertices[i1])
				var v2 := mesh_instance.to_global(vertices[i2])
				var t := _intersect_ray_triangle(ray_origin, ray_dir, v0, v1, v2)
				if t > 0.0 and t < best_t:
					best_t = t
					best = {
						"position": ray_origin + ray_dir * t,
						"mesh": mesh_instance.name,
						"surface": surface_index,
					}
	return best


func _intersect_ray_triangle(origin: Vector3, dir: Vector3, v0: Vector3, v1: Vector3, v2: Vector3) -> float:
	var edge1 := v1 - v0
	var edge2 := v2 - v0
	var pvec := dir.cross(edge2)
	var determinant := edge1.dot(pvec)
	if abs(determinant) < 0.000001:
		return -1.0

	var inv_det := 1.0 / determinant
	var tvec := origin - v0
	var u := tvec.dot(pvec) * inv_det
	if u < 0.0 or u > 1.0:
		return -1.0

	var qvec := tvec.cross(edge1)
	var v := dir.dot(qvec) * inv_det
	if v < 0.0 or u + v > 1.0:
		return -1.0

	var t := edge2.dot(qvec) * inv_det
	return t if t > 0.0001 else -1.0


func _collect_meshes(node: Node, meshes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh != null:
		meshes.append(node)

	for child in node.get_children():
		_collect_meshes(child, meshes)


func _create_fallback_character() -> void:
	_add_capsule_layer("Body", 0.38, 1.45, Color(0.55, 0.58, 0.62))
	_add_capsule_layer("Jacket", 0.43, 1.36, Color(0.26, 0.32, 0.42))
	_add_capsule_layer("Outer", 0.48, 1.16, Color(0.18, 0.22, 0.26))


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


func _add_marker(world_position: Vector3, color: Color) -> void:
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = max(radius_m * 0.08, 0.01)
	mesh.height = mesh.radius * 2.0
	marker.mesh = mesh
	marker.material_override = _marker_material(color)
	add_child(marker)
	marker.global_position = world_position

	await get_tree().create_timer(MARKER_LIFETIME).timeout
	if is_instance_valid(marker):
		marker.queue_free()


func _marker_material(color: Color) -> StandardMaterial3D:
	var key := str(color)
	if marker_materials.has(key):
		return marker_materials[key]

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.35
	marker_materials[key] = material
	return material


func _color_for_effect(effect_id: int) -> Color:
	match effect_id:
		2:
			return Color(0.72, 0.52, 0.22, 1.0)
		3:
			return Color(0.0, 0.62, 1.0, 1.0)
		4:
			return Color(1.0, 0.74, 0.05, 1.0)
	return Color(0.92, 0.02, 0.06, 1.0)


func _update_hud(status: String) -> void:
	effect_label.text = "Effect %d" % selected_effect_id
	radius_label.text = "Radius %.2f m" % radius_m
	strength_label.text = "Strength %.1f" % strength
	sand_label.text = "Sand %s %.2f %.2f %.2f" % [
		"on" if sand_enabled else "off",
		sand_direction_world.x,
		sand_direction_world.y,
		sand_direction_world.z,
	]
	events_label.text = "Events %d / %d" % [accumulator.get_impact_count(), SurfaceEffectAccumulator.MAX_IMPACTS]
	asset_label.text = "Asset " + current_asset_name
	status_label.text = status
