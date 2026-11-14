shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D screen_texture : source_color, filter_linear;
uniform float emission_energy = 0.6;

// 0 — без поворота
// 1 — 90° по часовой
// 2 — 180°
// 3 — 90° против часовой
uniform int rotation_mode : hint_range(0, 3) = 3;

void fragment() {
	vec2 screen_uv = UV;

	if (rotation_mode == 1) {
		screen_uv = vec2(UV.y, 1.0 - UV.x);
	}
	else if (rotation_mode == 2) {
		screen_uv = vec2(1.0 - UV.x, 1.0 - UV.y);
	}
	else if (rotation_mode == 3) {
		screen_uv = vec2(1.0 - UV.y, UV.x);
	}

	vec3 screen_color = texture(screen_texture, screen_uv).rgb;

	ALBEDO = screen_color;
	EMISSION = screen_color * emission_energy;
}
