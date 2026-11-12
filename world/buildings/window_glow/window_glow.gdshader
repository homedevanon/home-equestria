shader_type spatial;
// Far-house window glow cards (window_glow.gd). One flat cartoon pane per window, drawn only
// past begin_distance from its house: nearer, the authored lining shows the real room.
// By day a soft sky-to-warm pane; at night lit only while its household has a lamp on
// (world/life/house_lamps.gd, dev 2026-10-17; INSTANCE_CUSTOM.w >= 1), dark otherwise. Time of day comes from the sky's interior_light global
// (world/sky_controller.gd), the same value the room shaders read.
render_mode unshaded, cull_back, shadows_disabled, depth_draw_opaque;

global uniform vec4 interior_light;
uniform float begin_distance = 55.0;
uniform float fade_width = 4.0;
uniform vec3 day_sky : source_color = vec3(0.66, 0.80, 0.92);
uniform vec3 day_warm : source_color = vec3(0.90, 0.80, 0.64);
uniform vec3 night_lit : source_color = vec3(1.0, 0.74, 0.40);
uniform vec3 night_dark : source_color = vec3(0.10, 0.12, 0.20);

varying float v_fade;
varying float v_day;
varying float v_lit;
varying float v_shade;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void vertex() {
	// INSTANCE_CUSTOM: xyz = the house's world centre, w = its seed in [0, 1), +1 while lit.
	float dist = distance(CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.xyz);
	v_fade = clamp((dist - begin_distance) / fade_width, 0.0, 1.0);
	// Collapse near cards: no fragments at all while the lining is the view.
	if (dist < begin_distance) {
		VERTEX = vec3(0.0);
	}
	float luma = dot(interior_light.rgb, vec3(0.2126, 0.7152, 0.0722));
	v_day = smoothstep(0.12, 0.35, luma);
	float seed = fract(INSTANCE_CUSTOM.w);
	v_lit = step(1.0, INSTANCE_CUSTOM.w);
	// A little per-window brightness so a lit house is not one flat block.
	v_shade = 0.82 + 0.18 * hash11(float(INSTANCE_ID) * 3.17 + seed * 57.0);
	// Look 2026-11-10: a lit window breathes a little, like lamp and firelight behind glass
	// (each house on its own slow rhythm). Delete these two lines for a steady glow.
	float breath = sin(TIME * (1.7 + seed * 1.9) + seed * 40.0) * sin(TIME * 0.61 + seed * 17.0);
	v_shade *= 1.0 + 0.07 * breath * v_lit;
}

void fragment() {
	// Dithered fade-in over fade_width (opaque: no sorting against the glass).
	float noise = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (v_fade <= noise) {
		discard;
	}
	vec2 p = UV * 2.0 - 1.0;
	float soft = 1.0 - 0.28 * smoothstep(0.2, 1.0, length(p * vec2(0.9, 1.0)));
	vec3 day = mix(day_sky, day_warm, smoothstep(0.15, 0.95, UV.y)) * 0.62;
	vec3 night = mix(night_dark * 0.6, night_lit * 1.6 * v_shade, v_lit);
	ALBEDO = mix(night, day, v_day) * soft;
}
