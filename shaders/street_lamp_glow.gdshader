shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
instance uniform vec4 glow_color : source_color = vec4(1.0, 0.74, 0.42, 1.0);
instance uniform float glow_level = 0.0;
// Look 2026-11-10: the halo is a real glow sprite (world/vfx/textures/glint_soft.png, CC0,
// replaceable) instead of a computed disc. use_halo = false brings the old disc back.
uniform bool use_halo = false;
uniform sampler2D halo : filter_linear_mipmap, repeat_disable;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	// Place the small flare at the glass surface, outside its opaque native mesh.
	MODELVIEW_MATRIX[3].z += 0.28;
}

void fragment() {
	float radius = length(UV * 2.0 - 1.0);
	float halo_disc = pow(max(0.0, 1.0 - radius), 3.0);
	float core = 1.0 - smoothstep(0.0, 0.16, radius);
	if (use_halo) {
		float sprite = texture(halo, UV).a;
		ALBEDO = glow_color.rgb * (0.7 + sprite);
		ALPHA = clamp(sprite * 1.15, 0.0, 1.0) * glow_level * 0.9;
	} else {
		ALBEDO = glow_color.rgb * (0.65 + core);
		ALPHA = (halo_disc * 0.45 + core * 0.45) * glow_level;
	}
}
