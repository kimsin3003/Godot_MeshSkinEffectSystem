shader_type spatial;

const int MAX_IMPACTS = 32;

uniform vec4 base_color : source_color = vec4(0.72, 0.73, 0.76, 1.0);
uniform vec4 blood_color : source_color = vec4(0.42, 0.02, 0.04, 1.0);
uniform vec4 effect_2_color : source_color = vec4(0.62, 0.48, 0.28, 1.0);
uniform vec4 effect_3_color : source_color = vec4(0.08, 0.56, 1.0, 1.0);
uniform vec4 effect_4_color : source_color = vec4(0.96, 0.72, 0.14, 1.0);
uniform vec4 sand_color : source_color = vec4(0.74, 0.62, 0.36, 1.0);
uniform sampler2D base_texture : source_color;
uniform bool use_base_texture = false;
uniform sampler2D normal_texture : hint_normal;
uniform bool use_normal_texture = false;
uniform float normal_scale = 1.0;
uniform sampler2D roughness_texture;
uniform bool use_roughness_texture = false;
uniform int roughness_texture_channel = 0;
uniform sampler2D orm_texture;
uniform bool use_orm_texture = false;
uniform float roughness_value = 0.52;
uniform float metallic_value = 0.0;
uniform sampler2D metallic_texture;
uniform bool use_metallic_texture = false;
uniform int metallic_texture_channel = 0;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D emission_texture : source_color;
uniform bool use_emission_texture = false;
uniform float emission_energy = 0.0;
uniform float alpha_scissor_threshold = 0.0;
uniform int blood_effect_id = 1;
uniform int impact_count = 0;
uniform vec4 impact_spheres[MAX_IMPACTS];
uniform vec4 impact_dirs[MAX_IMPACTS];
uniform vec4 impact_meta[MAX_IMPACTS];
uniform bool use_surface_effect_volume = false;
uniform sampler2DArray surface_effect_volume;
uniform float effect_volume_depth = 48.0;
uniform bool use_rest_volume_position = false;
uniform vec3 effect_volume_origin_local = vec3(-1.0, -1.0, -1.0);
uniform vec3 effect_volume_inv_size = vec3(0.5, 0.5, 0.5);
uniform mat4 character_inverse_world = mat4(1.0);
uniform vec3 sand_direction_world = vec3(1.0, 0.0, 0.0);
uniform float sand_front = -10.0;
uniform float sand_amount = 0.0;
uniform float sand_front_softness = 0.45;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 effect_pos;
varying vec3 effect_normal;
varying vec3 volume_pos;


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	effect_pos = (character_inverse_world * vec4(world_pos, 1.0)).xyz;
	effect_normal = normalize((character_inverse_world * vec4(world_normal, 0.0)).xyz);
	volume_pos = effect_pos;
	if (use_rest_volume_position) {
		volume_pos = CUSTOM0.rgb;
	}
}


vec3 color_for_effect_id(int effect_id) {
	if (effect_id == 2) {
		return effect_2_color.rgb;
	}
	if (effect_id == 3) {
		return effect_3_color.rgb;
	}
	if (effect_id == 4) {
		return effect_4_color.rgb;
	}
	return blood_color.rgb;
}


vec4 color_from_effect_masks(vec4 masks) {
	float weight = masks.r + masks.g + masks.b + masks.a;
	if (weight <= 0.0001) {
		return vec4(blood_color.rgb, 0.0);
	}

	vec3 color_sum = blood_color.rgb * masks.r;
	color_sum += effect_2_color.rgb * masks.g;
	color_sum += effect_3_color.rgb * masks.b;
	color_sum += effect_4_color.rgb * masks.a;
	float max_mask = max(max(masks.r, masks.g), max(masks.b, masks.a));
	return vec4(color_sum / weight, clamp(max_mask, 0.0, 1.0));
}


vec4 surface_event_volume_mask(vec3 pos) {
	vec3 uvw = (pos - effect_volume_origin_local) * effect_volume_inv_size;
	if (
		uvw.x < 0.0 || uvw.x > 1.0 ||
		uvw.y < 0.0 || uvw.y > 1.0 ||
		uvw.z < 0.0 || uvw.z > 1.0
	) {
		return vec4(blood_color.rgb, 0.0);
	}
	float layer = clamp(uvw.z, 0.0, 1.0) * max(effect_volume_depth - 1.0, 0.0);
	float layer0 = floor(layer);
	float layer1 = min(layer0 + 1.0, effect_volume_depth - 1.0);
	float layer_t = fract(layer);
	vec4 masks0 = texture(surface_effect_volume, vec3(uvw.xy, layer0));
	vec4 masks1 = texture(surface_effect_volume, vec3(uvw.xy, layer1));
	return color_from_effect_masks(mix(masks0, masks1, layer_t));
}


vec4 surface_event_array_mask(vec3 pos, vec3 normal) {
	float max_mask = 0.0;
	float weight = 0.0;
	vec3 color_sum = vec3(0.0);

	for (int i = 0; i < MAX_IMPACTS; i++) {
		if (i >= impact_count) {
			break;
		}

		vec3 center = impact_spheres[i].xyz;
		float radius = max(impact_spheres[i].w, 0.001);
		vec3 shot_dir = normalize(impact_dirs[i].xyz);
		float strength = impact_dirs[i].w;
		float distance01 = length(pos - center) / radius;
		float sphere = 1.0 - smoothstep(0.55, 1.0, distance01);
		float facing = smoothstep(-0.15, 0.5, dot(normal, -shot_dir));
		float event_mask = clamp(sphere * mix(0.45, 1.0, facing) * strength, 0.0, 1.0);
		int effect_id = int(floor(impact_meta[i].x + 0.5));
		color_sum += color_for_effect_id(effect_id) * event_mask;
		weight += event_mask;
		max_mask = max(max_mask, event_mask);
	}

	if (weight <= 0.0001) {
		return vec4(blood_color.rgb, 0.0);
	}
	return vec4(color_sum / weight, clamp(max_mask, 0.0, 1.0));
}


float sand_mask(vec3 pos_world, vec3 normal_world) {
	vec3 wind_dir = normalize(sand_direction_world);
	float travel = dot(pos_world, wind_dir);
	float front = 1.0 - smoothstep(sand_front, sand_front + sand_front_softness, travel);
	float normal_factor = 1.0 - abs(dot(normalize(normal_world), wind_dir));
	return clamp(front * normal_factor * sand_amount, 0.0, 1.0);
}


float sample_channel(vec4 value, int channel) {
	if (channel == 1) {
		return value.g;
	}
	if (channel == 2) {
		return value.b;
	}
	if (channel == 3) {
		return value.a;
	}
	return value.r;
}


void fragment() {
	vec4 surface_event = surface_event_array_mask(effect_pos, normalize(effect_normal));
	if (use_surface_effect_volume) {
		surface_event = surface_event_volume_mask(volume_pos);
	}
	float blood = surface_event.a;
	float sand = 0.0;
	if (!use_surface_effect_volume) {
		sand = sand_mask(world_pos, world_normal);
	}
	vec4 base_sample = base_color;
	if (use_base_texture) {
		base_sample *= texture(base_texture, UV);
	}

	if (use_normal_texture) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
		NORMAL_MAP_DEPTH = normal_scale;
	}

	vec3 color = mix(base_sample.rgb, sand_color.rgb, sand * 0.85);
	color = mix(color, surface_event.rgb, blood);

	float roughness_sample = roughness_value;
	float metallic_sample = metallic_value;
	float ao_sample = 1.0;
	if (use_orm_texture) {
		vec4 orm_sample = texture(orm_texture, UV);
		ao_sample = orm_sample.r;
		roughness_sample *= orm_sample.g;
		metallic_sample *= orm_sample.b;
	}
	if (use_roughness_texture) {
		roughness_sample *= sample_channel(texture(roughness_texture, UV), roughness_texture_channel);
	}
	if (use_metallic_texture) {
		metallic_sample *= sample_channel(texture(metallic_texture, UV), metallic_texture_channel);
	}

	vec3 emission_sample = emission_color.rgb * emission_energy;
	if (use_emission_texture) {
		emission_sample *= texture(emission_texture, UV).rgb;
	}

	ALBEDO = color;
	ROUGHNESS = mix(clamp(roughness_sample, 0.0, 1.0), 0.9, max(sand, blood * 0.4));
	METALLIC = clamp(metallic_sample, 0.0, 1.0);
	AO = clamp(ao_sample, 0.0, 1.0);
	EMISSION = emission_sample;
	ALPHA = base_sample.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
}
