shader_type spatial;
// Small birds on the wing (world/vfx/bird_flocks.gd). One quad per bird, placed and turned by the
// script (X = the way it flies); this only picks the wing frame. Lit by the scene like any other
// thing in the air, so a flock goes gold at sunset and sinks into the haze far off.
// The sprite row is a real asset (CC0, replaceable): `frames` cells side by side, beak to +X.
render_mode cull_disabled, shadows_disabled, specular_disabled, depth_draw_never;

uniform sampler2D sheet : source_color, filter_linear_mipmap, repeat_disable;
uniform float frames = 9.0;
uniform float frames_per_second = 15.0;
// A small bird against the sky reads as a dark shape with a little colour. At full colour the
// blue sprite could not be told from the sky behind it (checked on a shot, 2026-11-10).
uniform float shade = 0.5;

varying float v_frame;
varying float v_alpha;

void vertex() {
	// INSTANCE_CUSTOM: x = this bird's place in the wing beat (0..1), y = how visible it is.
	v_frame = floor(mod(TIME * frames_per_second + INSTANCE_CUSTOM.x * frames, frames));
	v_alpha = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec4 texel = texture(sheet, vec2((UV.x + v_frame) / frames, UV.y));
	ALBEDO = texel.rgb * shade;
	// Blended, not cut out: a cut-out sprite a few pixels wide loses most of its body to the
	// cutoff (the birds were 1 to 2 px specks at 47 m on the first shot).
	ALPHA = texel.a * v_alpha;
	// A flat card has no round body to shade: light it evenly, as from above.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}
