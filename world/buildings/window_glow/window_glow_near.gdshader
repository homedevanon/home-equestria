shader_type spatial;
// Warm light in the windows of a lit house seen from close by (window_glow.gd NearGlow).
// Look 2026-11-10: within begin_distance the far cards are off and the real room shows through
// the glass. Its lamps light the room, but through blue glass at night the window stays dim
// while the house throws light pools on the snow (measured on a shot from 10 m). This layer
// adds the lamp's glow over the room, on the same cards: the room stays visible, the window
// reads as lit. It adds light only (no sorting, no depth written), fades out where the far card
// takes over and again right at the glass, where the player looks into the real room.
render_mode unshaded, blend_add, cull_back, shadows_disabled, depth_draw_never;

global uniform vec4 interior_light;
uniform float begin_distance = 55.0;
uniform float fade_width = 4.0;
uniform vec3 night_lit : source_color = vec3(1.0, 0.66, 0.30);
uniform float strength = 0.72;
// Metres from the house centre: no glow at the first, full at the second.
uniform vec2 close_fade = vec2(5.0, 11.0);

varying float v_glow;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void vertex() {
	// INSTANCE_CUSTOM: xyz = the house's world centre, w = its seed in [0, 1), +1 while lit.
	float dist = distance(CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.xyz);
	float luma = dot(interior_light.rgb, vec3(0.2126, 0.7152, 0.0722));
	float night = 1.0 - smoothstep(0.12, 0.35, luma);
	float seed = fract(INSTANCE_CUSTOM.w);
	float lit = step(1.0, INSTANCE_CUSTOM.w);
	float near = smoothstep(close_fade.x, close_fade.y, dist) * (1.0 - clamp((dist - begin_distance) / fade_width, 0.0, 1.0));
	float shade = 0.82 + 0.18 * hash11(float(INSTANCE_ID) * 3.17 + seed * 57.0);
	float breath = sin(TIME * (1.7 + seed * 1.9) + seed * 40.0) * sin(TIME * 0.61 + seed * 17.0);
	v_glow = lit * night * near * shade * (1.0 + 0.07 * breath);
	if (v_glow <= 0.001) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float soft = 1.0 - 0.28 * smoothstep(0.2, 1.0, length(p * vec2(0.9, 1.0)));
	ALBEDO = night_lit * strength * v_glow * soft;
}
